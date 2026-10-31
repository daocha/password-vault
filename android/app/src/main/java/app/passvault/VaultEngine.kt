package app.passvault

import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher

/**
 * Background queue for UI work. VaultAccess also serializes whole transactions across engine instances, including status reads made
 * outside this queue; queue scheduling alone cannot protect the shared files or a reserved final password attempt.
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
val vaultQueue = Dispatchers.IO.limitedParallelism(1)

/**
 * The real vault's way back into the decoy, so it can give the decoy a new password without losing its contents: [owner] is an X25519
 * public key whose secret key is sealed under the real vault's data key ([ownerSecret]), and [key] is the decoy's data key in a sealed box
 * to [owner]. The decoy vault can write a new [key] when its password changes but cannot read one.
 */
private class DecoyRecovery(val owner: ByteArray, var ownerSecret: ByteArray, var key: ByteArray)
/** The second, decoy vault: its own wrapped data key and file, opened by its own password (see [VaultEngine.createDecoy]). */
private class DecoySlot(var salt: ByteArray, var secret: ByteArray, var wrapped: ByteArray, var blob: String, var recovery: DecoyRecovery? = null)
/** [decoyChanges]: decoy password changes since the real password or biometrics last opened the vault (see [VaultEngine.changePassword]). */
private data class DeviceState(var attempts: Int, var erased: Boolean, var salt: ByteArray, var secret: ByteArray, var wrapped: ByteArray, var blob: String, var decoy: DecoySlot? = null, var decoyChanges: Int = 0) {
    fun encode(): ByteArray {
        fun b64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)
        return JSONObject().put("version", 1).put("attempts", attempts).put("erased", erased).put("salt", b64(salt)).put("secret", b64(secret)).put("wrapped", b64(wrapped)).put("blob", blob)
            .apply {
                decoy?.let { d -> put("decoy", JSONObject().put("salt", b64(d.salt)).put("secret", b64(d.secret)).put("wrapped", b64(d.wrapped)).put("blob", d.blob)
                    .apply { d.recovery?.let { r -> put("owner", b64(r.owner)).put("ownerSecret", b64(r.ownerSecret)).put("recovery", b64(r.key)) } }) }
                if (decoyChanges != 0) put("decoyChanges", decoyChanges)
            }
            .toString().toByteArray()
    }
    companion object {
        fun decode(bytes: ByteArray): DeviceState {
            val j = JSONObject(bytes.toString(Charsets.UTF_8)); require(j.getInt("version") == 1)
            fun data(o: JSONObject, name: String) = Base64.getDecoder().decode(o.getString(name))
            val decoy = j.optJSONObject("decoy")?.let { d ->
                val recovery = if (d.has("owner")) DecoyRecovery(data(d, "owner"), data(d, "ownerSecret"), data(d, "recovery")) else null
                DecoySlot(data(d, "salt"), data(d, "secret"), data(d, "wrapped"), d.getString("blob"), recovery)
            }
            return DeviceState(j.getInt("attempts"), j.getBoolean("erased"), data(j, "salt"), data(j, "secret"), data(j, "wrapped"), j.getString("blob"), decoy, j.optInt("decoyChanges", 0))
        }
    }
}
class VaultChangedException : IllegalStateException("The vault changed in another window. Unlock it again.")

class VaultEngine(private val storage: ProtectedStorage) {
    private var key: ByteArray? = null
    private var records = emptyList<VaultRecord>()
    /** Whether the open vault is the decoy one. Every operation acts on the open vault only. */
    private var activeDecoy = false
    private var loadedBlob: String? = null
    private val wrapAAD = "PassVault/key/v1".toByteArray()
    private val ownerAAD = "PassVault/decoy-owner/v1".toByteArray()
    private fun state(): DeviceState? {
        val value = storage.readState()?.let(DeviceState::decode) ?: run { lock(); return null }
        require(value.attempts in 0..10); UUID.fromString(value.blob)
        if (value.erased) { lock(); error("The local vault was erased after 10 failed attempts.") }
        if (value.attempts == 10) { erase(value); error("The local vault was erased after 10 failed attempts.") }
        require(value.salt.size == 16 && value.secret.size == 32 && value.wrapped.size == 72) { "Damaged protected state." }
        value.decoy?.let { d -> UUID.fromString(d.blob); require(d.salt.size == 16 && d.secret.size == 32 && d.wrapped.size == 72) { "Damaged protected state." }
            d.recovery?.let { r -> require(r.owner.size == 32 && r.ownerSecret.size == 72 && r.key.size == 80) { "Damaged protected state." } } }
        require(value.decoyChanges in 0..DECOY_CHANGES) { "Damaged protected state." }
        // An older window must not overwrite newer records, or write with a key that another engine has rotated away from.
        if (key != null && loadedBlob != (if (activeDecoy) value.decoy?.blob else value.blob)) {
            lock(); throw VaultChangedException()
        }
        return value
    }
    /** The vault files the state points at: the main one and, if set up, the decoy one. */
    private fun liveBlobs(value: DeviceState) = setOfNotNull(value.blob, value.decoy?.blob)
    fun exists() = VaultAccess.serialized { state() != null }
    fun isErased() = VaultAccess.serialized { storage.readState()?.let { DeviceState.decode(it).erased } ?: false }
    fun resetErasedVault(): Unit = VaultAccess.serialized {
        check(isErased()) { "Only an already-erased vault can be reset without a password." }
        lock(); storage.deleteBiometric(); storage.removeBlobs(emptySet()); storage.deleteState()
    }
    fun remainingAttempts() = VaultAccess.serialized { 10 - (state()?.attempts ?: 0) }
    fun lock(): Unit = VaultAccess.serialized { key?.fill(0); key = null; records = emptyList(); activeDecoy = false; loadedBlob = null }
    /** Wraps [dataKey] under [password] with a fresh salt and device secret. */
    private class Wrapped(val salt: ByteArray, val secret: ByteArray, val wrapped: ByteArray)
    private fun wrap(password: String, dataKey: ByteArray): Wrapped {
        val salt = VaultCrypto.random(16); val secret = VaultCrypto.random(32)
        val derived = VaultCrypto.passwordKey(password, salt); val wrapping = VaultCrypto.deviceKey(derived, secret); derived.fill(0)
        try { return Wrapped(salt, secret, VaultCrypto.seal(dataKey, wrapping, wrapAAD)) } finally { wrapping.fill(0) }
    }
    /** The data key [password] unwraps, or null. [legacy] keys from the text exactly as typed (vaults made before normalization). */
    private fun unwrap(password: String, salt: ByteArray, secret: ByteArray, wrapped: ByteArray, legacy: Boolean = false): ByteArray? {
        val derived = VaultCrypto.passwordKey(password, salt, legacyEncoding = legacy); val wrapping = VaultCrypto.deviceKey(derived, secret); derived.fill(0)
        return try { VaultCrypto.open(wrapped, wrapping, wrapAAD) } catch (_: AuthenticationFailure) { null } finally { wrapping.fill(0) }
    }
    fun create(password: String): List<VaultRecord> = VaultAccess.serialized {
        check(state() == null) { "A vault already exists." }; VaultCrypto.strongPassword(password)
        storage.initializeKey()
        val dataKey = VaultCrypto.random(32); val wrapped = wrap(password, dataKey)
        val blob = UUID.randomUUID().toString()
        val value = DeviceState(0, false, wrapped.salt, wrapped.secret, wrapped.wrapped, blob)
        storage.writeBlob(blob, VaultCrypto.seal(Records.encode(emptyList()), dataKey, blob.toByteArray()))
        storage.writeState(value.encode()); key = dataKey; records = emptyList(); activeDecoy = false; loadedBlob = blob; return@serialized records
    }
    private class Found(val key: ByteArray, val decoy: Boolean)
    /**
     * Checks [password] as one counted attempt and returns the data key it opens and whether that is the decoy vault's. Unlocking
     * ([unlocking]) accepts either vault's password and always derives two keys (the decoy's, or a throwaway one when there is no decoy),
     * so its timing does not reveal whether a decoy exists. Other checks accept only the open vault's password. The main password clears
     * the failure count and the decoy's password-change allowance; the decoy password leaves both as they were, so decoy sign-ins cannot
     * reset guesses at the main one.
     */
    private fun authenticate(password: String, unlocking: Boolean = false): Found {
        val value = state() ?: error("Create a vault first.")
        val before = value.attempts
        value.attempts++; storage.writeState(value.encode())
        val checkMain = unlocking || !activeDecoy; val checkDecoy = unlocking || activeDecoy
        // Vaults made before passwords were normalized are keyed from the text exactly as typed. Accept that form once and re-wrap in the
        // normalized form below. Both forms count as one attempt.
        var main: ByteArray? = null; var legacy = false
        if (checkMain) for (raw in if (PasswordText.differs(password)) listOf(false, true) else listOf(false)) {
            main = unwrap(password, value.salt, value.secret, value.wrapped, raw); if (main != null) { legacy = raw; break }
        }
        var decoy: ByteArray? = null
        if (checkDecoy) {
            val d = value.decoy
            if (d != null) decoy = unwrap(password, d.salt, d.secret, d.wrapped)
            else if (unlocking) VaultCrypto.passwordKey(password, VaultCrypto.random(16)).fill(0)
        }
        if (main != null) {
            decoy?.fill(0)
            value.attempts = 0; value.decoyChanges = 0
            try {
                if (legacy) wrap(password, main).let { value.salt = it.salt; value.secret = it.secret; value.wrapped = it.wrapped }
                // Clearing the counter never makes an old copy more useful to an attacker, so it does not need a new state key. A re-wrap does.
                storage.writeState(value.encode(), ratchet = legacy)
            } catch (e: Exception) { main.fill(0); throw e }
            return Found(main, false)
        }
        if (decoy != null) {
            value.attempts = before
            try { storage.writeState(value.encode(), ratchet = false) } catch (e: Exception) { decoy.fill(0); throw e }
            return Found(decoy, true)
        }
        if (value.attempts == 10) { erase(value); error("The local vault was erased after 10 failed attempts.") }
        throw AuthenticationFailure()
    }
    private fun load(candidate: ByteArray, decoy: Boolean): List<VaultRecord> {
        val value = state() ?: error("Vault is locked.")
        val blob = (if (decoy) value.decoy?.blob else value.blob) ?: error("Vault is locked.")
        val plain = VaultCrypto.open(storage.readBlob(blob), candidate, blob.toByteArray())
        // Key entries get their creation stamp as soon as they are loaded (in memory; stored with the next save), before an edit can bump
        // updatedAt. Loading never writes the vault.
        try { val loaded = FileKeys.stamp(Records.decode(plain)); key?.fill(0); key = candidate.copyOf(); records = loaded; activeDecoy = decoy; loadedBlob = blob; return records }
        finally { plain.fill(0); candidate.fill(0) }
    }
    fun unlock(password: String) = VaultAccess.serialized { lock(); authenticate(password, unlocking = true).let { load(it.key, it.decoy) } }
    fun biometricCipher(encrypt: Boolean): Cipher = VaultAccess.serialized { check(state() != null); return@serialized storage.biometricCipher(encrypt) }
    /** Biometrics hold the main vault's key, so they can only be set up from the main vault. */
    fun biometricKey(password: String): ByteArray = VaultAccess.serialized { check(key != null && !activeDecoy) { "Vault is locked." }; return@serialized authenticate(password).key }
    fun saveBiometric(cipher: Cipher, candidate: ByteArray): Unit = VaultAccess.serialized { check(state() != null && key != null && !activeDecoy) { "Vault is locked." }; storage.saveBiometric(cipher, candidate) }
    /**
     * A successful hardware-backed biometric unlock proves the owner is present, so like the main password it clears failed password attempts
     * and the decoy's password-change allowance. It opens the main vault.
     */
    fun unlockBiometric(cipher: Cipher): List<VaultRecord> = VaultAccess.serialized {
        lock()
        val value = state() ?: error("Create a vault first.")
        val loaded = load(storage.readBiometric(cipher), decoy = false)
        if (value.attempts != 0 || value.decoyChanges != 0) { value.attempts = 0; value.decoyChanges = 0; storage.writeState(value.encode(), ratchet = false) }
        return@serialized loaded
    }
    fun hasBiometric() = VaultAccess.serialized { state() != null && storage.hasBiometric() }
    fun disableBiometric(): Unit = VaultAccess.serialized { storage.deleteBiometric() }
    fun isUnlocked() = VaultAccess.serialized {
        if (key == null) false else try { state() != null } catch (_: Exception) { lock(); false }
    }
    /** Whether the open vault is the decoy one. */
    fun isDecoy() = VaultAccess.serialized { activeDecoy }
    /** Whether a decoy vault exists. Only the main vault can tell; from the decoy vault this is always false. */
    fun hasDecoy() = VaultAccess.serialized { key != null && !activeDecoy && state()?.decoy != null }
    /** Whether the real vault can give the decoy a new password ([resetDecoyPassword]); decoys set up by earlier test builds cannot. */
    fun canResetDecoy() = VaultAccess.serialized { key != null && !activeDecoy && state()?.decoy?.recovery != null }
    /** Saves [records] as the open vault's contents and returns what was stored: the same records, with key entries' creation stamps. */
    fun save(records: List<VaultRecord>): List<VaultRecord> = VaultAccess.serialized {
        val dataKey = key ?: error("Vault is locked."); val value = state() ?: error("Vault is locked.")
        val updated = FileKeys.stamp(records)
        val blob = UUID.randomUUID().toString(); val plain = Records.encode(updated)
        try { storage.writeBlob(blob, VaultCrypto.seal(plain, dataKey, blob.toByteArray())) } finally { plain.fill(0) }
        if (activeDecoy) (value.decoy ?: error("Vault is locked.")).blob = blob else value.blob = blob
        storage.writeState(value.encode()); this.records = updated; loadedBlob = blob
        storage.removeBlobs(liveBlobs(value))
        return@serialized updated
    }
    fun merge(imported: List<VaultRecord>): List<VaultRecord> = VaultAccess.serialized {
        check(key != null) { "Vault is locked." }
        // Matched by record id only: a record already in the vault is replaced in place (whole, fields included), the rest are added with their ids.
        val incoming = imported.associateBy { it.id }; val known = records.map { it.id }.toSet()
        return@serialized save(FileKeys.keepKeys(records, records.map { incoming[it.id] ?: it } + imported.filter { it.id !in known }))
    }
    /** Makes the imported records the whole vault: entries the file does not contain are deleted, except file keys ([FileKeys.keepKeys]). */
    fun replaceAll(imported: List<VaultRecord>): List<VaultRecord> = VaultAccess.serialized {
        check(key != null) { "Vault is locked." }
        return@serialized save(FileKeys.keepKeys(records, imported))
    }
    /**
     * Verifies the open vault's password (a counted attempt) and encrypts the backup with that same password. [instance]: the source
     * vault's [BackupStatus.instance] (the decoy's when it is open), read under the vault lock.
     */
    fun export(password: String, csv: Boolean, instance: (decoy: Boolean) -> Long = { 0L }): VaultExport {
        // Passwords set before the guessability rule still work; an encrypted backup is where a weak one is worth warning about. Worked out
        // before taking the vault lock: it needs no vault state, and its first use loads zxcvbn's dictionaries.
        val weak = !csv && PasswordPolicy.guesses(PasswordText.normalize(password)) < PasswordPolicy.MIN_GUESSES_LOG10
        return exportLocked(password, csv, weak, instance)
    }
    private fun exportLocked(password: String, csv: Boolean, weak: Boolean, instance: (Boolean) -> Long): VaultExport = VaultAccess.serialized {
        check(key != null) { "Vault is locked." }; authenticate(password).key.fill(0)
        return@serialized VaultExport.prepare(records, csv, activeDecoy, encode = { snapshot ->
            if (csv) VaultCSV.exportRecords(snapshot).toByteArray() else VaultCrypto.exportBackup(snapshot, password)
        }, weakPassword = weak, instance = instance)
    }
    /** Verifies the open vault's password (a counted attempt) and seals its records for another phone under a new one-time code. */
    fun exportTransfer(password: String): Pair<String, ByteArray> = VaultAccess.serialized {
        check(key != null) { "Vault is locked." }; authenticate(password).key.fill(0)
        val code = Transfer.newCode(); return@serialized code to Transfer.seal(records, code)
    }
    /**
     * Changes the open vault's password (the decoy's when the decoy is open). Also replaces the data key and re-encrypts the vault, so
     * nothing derived from the old password or old state can open future data.
     *
     * In the decoy vault the new password must not be the real one, and that check tests a guess at the real password: a refusal is counted
     * as a failed attempt, and since an accepted change also tells that the guess was wrong, only [DECOY_CHANGES] changes are allowed until
     * the real password or biometrics opens the vault. Past that the change is refused, never erased.
     */
    fun changePassword(current: String, new: String): Unit = VaultAccess.serialized {
        check(key != null) { "Vault is locked." }; VaultCrypto.strongPassword(new)
        authenticate(current).key.fill(0) // proves the current password; the vault is unlocked, so the old data key is not needed again
        val value = state() ?: error("Vault is locked.")
        if (activeDecoy) {
            check(value.decoyChanges < DECOY_CHANGES) { "The password was changed too many times. Try again later." }
            // Reserved before the check, as an attempt is: stopping the app mid-change must not give a free test.
            value.decoyChanges++; storage.writeState(value.encode())
            unwrap(new, value.salt, value.secret, value.wrapped)?.let {
                it.fill(0); value.decoyChanges--; value.attempts++; storage.writeState(value.encode())
                if (value.attempts >= 10) { erase(value); error("The local vault was erased after 10 failed attempts.") }
                throw IllegalArgumentException("Choose a different password.")
            }
        }
        value.decoy?.let { d -> if (!activeDecoy) unwrap(new, d.salt, d.secret, d.wrapped)?.let { it.fill(0); throw IllegalArgumentException("Choose a password different from your decoy vault's.") } }
        val previous = liveBlobs(value); val blob = UUID.randomUUID().toString()
        val dataKey = VaultCrypto.random(32); val plain = Records.encode(records)
        try {
            storage.writeBlob(blob, VaultCrypto.seal(plain, dataKey, blob.toByteArray()))
            val wrapped = wrap(new, dataKey)
            if (activeDecoy) {
                val recovery = value.decoy?.recovery?.also { it.key = VaultCrypto.sealTo(dataKey, it.owner) }
                value.decoy = DecoySlot(wrapped.salt, wrapped.secret, wrapped.wrapped, blob, recovery)
            } else {
                // The way back into the decoy is sealed under the data key, so it moves to the new one.
                value.decoy?.recovery?.let { r -> val owner = VaultCrypto.open(r.ownerSecret, key!!, ownerAAD); try { r.ownerSecret = VaultCrypto.seal(owner, dataKey, ownerAAD) } finally { owner.fill(0) } }
                // The biometric copy holds the old data key. Remove it before the commit so it cannot outlive the state that made it valid.
                storage.deleteBiometric()
                value.salt = wrapped.salt; value.secret = wrapped.secret; value.wrapped = wrapped.wrapped; value.blob = blob
            }
            storage.writeState(value.encode())
        } catch (e: Exception) { dataKey.fill(0); runCatching { storage.removeBlobs(previous) }; throw e }
        finally { plain.fill(0) }
        key?.fill(0); key = dataKey; loadedBlob = blob
        storage.removeBlobs(liveBlobs(value))
    }
    /** Sets up an empty decoy vault, opened from the unlock screen by [decoyPassword]. Only from the main vault, with its password. */
    fun createDecoy(password: String, decoyPassword: String): Unit = VaultAccess.serialized {
        check(key != null && !activeDecoy) { "Vault is locked." }; VaultCrypto.strongPassword(decoyPassword)
        authenticate(password).key.fill(0)
        val value = state() ?: error("Vault is locked.")
        require(value.decoy == null) { "A decoy vault already exists." }
        unwrap(decoyPassword, value.salt, value.secret, value.wrapped)?.let { it.fill(0); throw IllegalArgumentException("Choose a decoy password different from your app password.") }
        val dataKey = VaultCrypto.random(32); val (owner, ownerSecret) = VaultCrypto.boxKeyPair()
        try {
            val wrapped = wrap(decoyPassword, dataKey); val blob = UUID.randomUUID().toString()
            storage.writeBlob(blob, VaultCrypto.seal(Records.encode(emptyList()), dataKey, blob.toByteArray()))
            val recovery = DecoyRecovery(owner, VaultCrypto.seal(ownerSecret, key!!, ownerAAD), VaultCrypto.sealTo(dataKey, owner))
            value.decoy = DecoySlot(wrapped.salt, wrapped.secret, wrapped.wrapped, blob, recovery); value.decoyChanges = 0
            try { storage.writeState(value.encode()) } catch (e: Exception) { runCatching { storage.removeBlobs(setOf(value.blob)) }; throw e }
        } finally { dataKey.fill(0); ownerSecret.fill(0) }
    }
    /**
     * Gives the decoy vault a new password, keeping what is in it, for when its password is forgotten. Only from the main vault, with its
     * password. The decoy is re-encrypted under a new data key, as a password change from inside it would be.
     */
    fun resetDecoyPassword(password: String, decoyPassword: String): Unit = VaultAccess.serialized {
        check(key != null && !activeDecoy) { "Vault is locked." }; VaultCrypto.strongPassword(decoyPassword)
        authenticate(password).key.fill(0)
        val value = state() ?: error("Vault is locked.")
        val decoy = value.decoy ?: throw IllegalArgumentException("There is no decoy vault.")
        val recovery = decoy.recovery ?: throw IllegalArgumentException("This decoy vault was set up by an earlier test version. Remove it and set it up again.")
        unwrap(decoyPassword, value.salt, value.secret, value.wrapped)?.let { it.fill(0); throw IllegalArgumentException("Choose a decoy password different from your app password.") }
        val ownerSecret = VaultCrypto.open(recovery.ownerSecret, key!!, ownerAAD)
        val oldKey = try { VaultCrypto.openSealed(recovery.key, recovery.owner, ownerSecret) } finally { ownerSecret.fill(0) }
        val plain = try { VaultCrypto.open(storage.readBlob(decoy.blob), oldKey, decoy.blob.toByteArray()) } finally { oldKey.fill(0) }
        val previous = liveBlobs(value); val blob = UUID.randomUUID().toString(); val dataKey = VaultCrypto.random(32)
        try {
            storage.writeBlob(blob, VaultCrypto.seal(plain, dataKey, blob.toByteArray()))
            val wrapped = wrap(decoyPassword, dataKey)
            value.decoy = DecoySlot(wrapped.salt, wrapped.secret, wrapped.wrapped, blob, DecoyRecovery(recovery.owner, recovery.ownerSecret, VaultCrypto.sealTo(dataKey, recovery.owner)))
            value.decoyChanges = 0
            storage.writeState(value.encode())
        } catch (e: Exception) { runCatching { storage.removeBlobs(previous) }; throw e }
        finally { plain.fill(0); dataKey.fill(0) }
        storage.removeBlobs(liveBlobs(value))
    }
    /** Deletes the decoy vault and everything in it. Only from the main vault, with its password. */
    fun removeDecoy(password: String): Unit = VaultAccess.serialized {
        check(key != null && !activeDecoy) { "Vault is locked." }
        authenticate(password).key.fill(0)
        val value = state() ?: error("Vault is locked.")
        value.decoy = null; value.decoyChanges = 0; storage.writeState(value.encode())
        storage.removeBlobs(setOf(value.blob))
    }
    companion object {
        /** Decoy password changes allowed between openings by the real password or biometrics. */
        const val DECOY_CHANGES = 3
    }
    private fun erase(value: DeviceState) {
        lock(); value.erased = true; value.secret.fill(0); value.wrapped.fill(0); value.salt.fill(0)
        value.secret = byteArrayOf(); value.wrapped = byteArrayOf(); value.salt = byteArrayOf(); value.decoy = null; value.decoyChanges = 0
        storage.writeState(value.encode(), ratchet = false); storage.finishErasure()
    }
}
