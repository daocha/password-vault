package app.passvault

import org.json.JSONObject
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher

/** The second, decoy vault: its own wrapped data key and file, opened by its own password (see [VaultEngine.createDecoy]). */
private class DecoySlot(var salt: ByteArray, var secret: ByteArray, var wrapped: ByteArray, var blob: String)
private data class DeviceState(var attempts: Int, var erased: Boolean, var salt: ByteArray, var secret: ByteArray, var wrapped: ByteArray, var blob: String, var decoy: DecoySlot? = null) {
    fun encode(): ByteArray {
        fun b64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)
        return JSONObject().put("version", 1).put("attempts", attempts).put("erased", erased).put("salt", b64(salt)).put("secret", b64(secret)).put("wrapped", b64(wrapped)).put("blob", blob)
            .apply { decoy?.let { d -> put("decoy", JSONObject().put("salt", b64(d.salt)).put("secret", b64(d.secret)).put("wrapped", b64(d.wrapped)).put("blob", d.blob)) } }
            .toString().toByteArray()
    }
    companion object {
        fun decode(bytes: ByteArray): DeviceState {
            val j = JSONObject(bytes.toString(Charsets.UTF_8)); require(j.getInt("version") == 1)
            fun data(o: JSONObject, name: String) = Base64.getDecoder().decode(o.getString(name))
            val decoy = j.optJSONObject("decoy")?.let { d -> DecoySlot(data(d, "salt"), data(d, "secret"), data(d, "wrapped"), d.getString("blob")) }
            return DeviceState(j.getInt("attempts"), j.getBoolean("erased"), data(j, "salt"), data(j, "secret"), data(j, "wrapped"), j.getString("blob"), decoy)
        }
    }
}
class VaultEngine(private val storage: ProtectedStorage) {
    private var key: ByteArray? = null
    private var records = emptyList<VaultRecord>()
    /** Whether the open vault is the decoy one. Every operation acts on the open vault only. */
    private var activeDecoy = false
    private val wrapAAD = "PassVault/key/v1".toByteArray()
    private fun state(): DeviceState? {
        val value = storage.readState()?.let(DeviceState::decode) ?: return null
        require(value.attempts in 0..10); UUID.fromString(value.blob)
        check(!value.erased) { "The local vault was erased after 10 failed attempts." }
        if (value.attempts == 10) { erase(value); error("The local vault was erased after 10 failed attempts.") }
        require(value.salt.size == 16 && value.secret.size == 32 && value.wrapped.size == 72) { "Damaged protected state." }
        value.decoy?.let { d -> UUID.fromString(d.blob); require(d.salt.size == 16 && d.secret.size == 32 && d.wrapped.size == 72) { "Damaged protected state." } }
        return value
    }
    /** The vault files the state points at: the main one and, if set up, the decoy one. */
    private fun liveBlobs(value: DeviceState) = setOfNotNull(value.blob, value.decoy?.blob)
    @Synchronized fun exists() = state() != null
    @Synchronized fun isErased() = storage.readState()?.let { DeviceState.decode(it).erased } ?: false
    @Synchronized fun resetErasedVault() {
        check(isErased()) { "Only an already-erased vault can be reset without a password." }
        lock(); storage.deleteBiometric(); storage.removeBlobs(emptySet()); storage.deleteState()
    }
    @Synchronized fun remainingAttempts() = 10 - (state()?.attempts ?: 0)
    @Synchronized fun lock() { key?.fill(0); key = null; records = emptyList(); activeDecoy = false }
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
    @Synchronized fun create(password: String): List<VaultRecord> {
        check(state() == null) { "A vault already exists." }; VaultCrypto.strongPassword(password)
        storage.initializeKey()
        val dataKey = VaultCrypto.random(32); val wrapped = wrap(password, dataKey)
        val blob = UUID.randomUUID().toString()
        val value = DeviceState(0, false, wrapped.salt, wrapped.secret, wrapped.wrapped, blob)
        storage.writeBlob(blob, VaultCrypto.seal(Records.encode(emptyList()), dataKey, blob.toByteArray()))
        storage.writeState(value.encode()); key = dataKey; records = emptyList(); activeDecoy = false; return records
    }
    private class Found(val key: ByteArray, val decoy: Boolean)
    /**
     * Checks [password] as one counted attempt and returns the data key it opens and whether that is the decoy vault's. Unlocking
     * ([unlocking]) accepts either vault's password and always derives two keys (the decoy's, or a throwaway one when there is no decoy),
     * so its timing does not reveal whether a decoy exists. Other checks accept only the open vault's password. The main password clears
     * the failure count; the decoy password leaves it as it was, so decoy sign-ins cannot reset guesses at the main one.
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
            value.attempts = 0
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
        try { val loaded = Records.decode(plain); key?.fill(0); key = candidate.copyOf(); records = loaded; activeDecoy = decoy; return records }
        finally { plain.fill(0); candidate.fill(0) }
    }
    @Synchronized fun unlock(password: String) = authenticate(password, unlocking = true).let { load(it.key, it.decoy) }
    @Synchronized fun biometricCipher(encrypt: Boolean): Cipher { check(state() != null); return storage.biometricCipher(encrypt) }
    /** Biometrics hold the main vault's key, so they can only be set up from the main vault. */
    @Synchronized fun biometricKey(password: String): ByteArray { check(key != null && !activeDecoy) { "Vault is locked." }; return authenticate(password).key }
    @Synchronized fun saveBiometric(cipher: Cipher, candidate: ByteArray) { check(state() != null && key != null && !activeDecoy) { "Vault is locked." }; storage.saveBiometric(cipher, candidate) }
    /** A successful hardware-backed biometric unlock proves the owner is present, so it clears failed password attempts. It opens the main vault. */
    @Synchronized fun unlockBiometric(cipher: Cipher): List<VaultRecord> {
        val value = state() ?: error("Create a vault first.")
        val loaded = load(storage.readBiometric(cipher), decoy = false)
        if (value.attempts != 0) { value.attempts = 0; storage.writeState(value.encode(), ratchet = false) }
        return loaded
    }
    @Synchronized fun hasBiometric() = state() != null && storage.hasBiometric()
    @Synchronized fun disableBiometric() = storage.deleteBiometric()
    @Synchronized fun isUnlocked() = key != null
    /** Whether the open vault is the decoy one. */
    @Synchronized fun isDecoy() = activeDecoy
    /** Whether a decoy vault exists. Only the main vault can tell; from the decoy vault this is always false. */
    @Synchronized fun hasDecoy() = key != null && !activeDecoy && state()?.decoy != null
    @Synchronized fun save(updated: List<VaultRecord>) {
        val dataKey = key ?: error("Vault is locked."); val value = state() ?: error("Vault is locked.")
        val blob = UUID.randomUUID().toString(); val plain = Records.encode(updated)
        try { storage.writeBlob(blob, VaultCrypto.seal(plain, dataKey, blob.toByteArray())) } finally { plain.fill(0) }
        if (activeDecoy) (value.decoy ?: error("Vault is locked.")).blob = blob else value.blob = blob
        storage.writeState(value.encode()); records = updated
        storage.removeBlobs(liveBlobs(value))
    }
    @Synchronized fun merge(imported: List<VaultRecord>): List<VaultRecord> {
        check(key != null) { "Vault is locked." }
        // Matched by record id only: a record already in the vault is replaced in place (whole, fields included), the rest are added with their ids.
        val incoming = imported.associateBy { it.id }; val known = records.map { it.id }.toSet()
        val updated = records.map { incoming[it.id] ?: it } + imported.filter { it.id !in known }; save(updated); return updated
    }
    /** Makes the imported records the whole vault: entries the file does not contain are deleted. */
    @Synchronized fun replaceAll(imported: List<VaultRecord>): List<VaultRecord> {
        check(key != null) { "Vault is locked." }
        save(imported); return imported
    }
    /** Verifies the open vault's password (a counted attempt) and encrypts the backup with that same password. */
    @Synchronized fun export(password: String, csv: Boolean): ByteArray {
        check(key != null) { "Vault is locked." }; authenticate(password).key.fill(0)
        return if (csv) VaultCSV.exportRecords(records).toByteArray() else VaultCrypto.exportBackup(records, password)
    }
    /** Verifies the open vault's password (a counted attempt) and seals its records for another phone under a new one-time code. */
    @Synchronized fun exportTransfer(password: String): Pair<String, ByteArray> {
        check(key != null) { "Vault is locked." }; authenticate(password).key.fill(0)
        val code = Transfer.newCode(); return code to Transfer.seal(records, code)
    }
    /**
     * Changes the open vault's password (the decoy's when the decoy is open). Also replaces the data key and re-encrypts the vault, so
     * nothing derived from the old password or old state can open future data.
     */
    @Synchronized fun changePassword(current: String, new: String) {
        check(key != null) { "Vault is locked." }; VaultCrypto.strongPassword(new)
        authenticate(current).key.fill(0) // proves the current password; the vault is unlocked, so the old data key is not needed again
        val value = state() ?: error("Vault is locked.")
        value.decoy?.let { d -> if (!activeDecoy) unwrap(new, d.salt, d.secret, d.wrapped)?.let { it.fill(0); throw IllegalArgumentException("Choose a password different from your decoy vault's.") } }
        val previous = liveBlobs(value); val blob = UUID.randomUUID().toString()
        val dataKey = VaultCrypto.random(32); val plain = Records.encode(records)
        try {
            storage.writeBlob(blob, VaultCrypto.seal(plain, dataKey, blob.toByteArray()))
            val wrapped = wrap(new, dataKey)
            if (activeDecoy) value.decoy = DecoySlot(wrapped.salt, wrapped.secret, wrapped.wrapped, blob)
            else {
                // The biometric copy holds the old data key. Remove it before the commit so it cannot outlive the state that made it valid.
                storage.deleteBiometric()
                value.salt = wrapped.salt; value.secret = wrapped.secret; value.wrapped = wrapped.wrapped; value.blob = blob
            }
            storage.writeState(value.encode())
        } catch (e: Exception) { dataKey.fill(0); runCatching { storage.removeBlobs(previous) }; throw e }
        finally { plain.fill(0) }
        key?.fill(0); key = dataKey
        storage.removeBlobs(liveBlobs(value))
    }
    /** Sets up an empty decoy vault, opened from the unlock screen by [decoyPassword]. Only from the main vault, with its password. */
    @Synchronized fun createDecoy(password: String, decoyPassword: String) {
        check(key != null && !activeDecoy) { "Vault is locked." }; VaultCrypto.strongPassword(decoyPassword)
        authenticate(password).key.fill(0)
        val value = state() ?: error("Vault is locked.")
        require(value.decoy == null) { "A decoy vault already exists." }
        unwrap(decoyPassword, value.salt, value.secret, value.wrapped)?.let { it.fill(0); throw IllegalArgumentException("Choose a decoy password different from your app password.") }
        val dataKey = VaultCrypto.random(32)
        try {
            val wrapped = wrap(decoyPassword, dataKey); val blob = UUID.randomUUID().toString()
            storage.writeBlob(blob, VaultCrypto.seal(Records.encode(emptyList()), dataKey, blob.toByteArray()))
            value.decoy = DecoySlot(wrapped.salt, wrapped.secret, wrapped.wrapped, blob)
            try { storage.writeState(value.encode()) } catch (e: Exception) { runCatching { storage.removeBlobs(setOf(value.blob)) }; throw e }
        } finally { dataKey.fill(0) }
    }
    /** Deletes the decoy vault and everything in it. Only from the main vault, with its password. */
    @Synchronized fun removeDecoy(password: String) {
        check(key != null && !activeDecoy) { "Vault is locked." }
        authenticate(password).key.fill(0)
        val value = state() ?: error("Vault is locked.")
        value.decoy = null; storage.writeState(value.encode())
        storage.removeBlobs(setOf(value.blob))
    }
    private fun erase(value: DeviceState) {
        lock(); value.erased = true; value.secret.fill(0); value.wrapped.fill(0); value.salt.fill(0)
        value.secret = byteArrayOf(); value.wrapped = byteArrayOf(); value.salt = byteArrayOf(); value.decoy = null
        storage.writeState(value.encode(), ratchet = false); storage.finishErasure()
    }
}
