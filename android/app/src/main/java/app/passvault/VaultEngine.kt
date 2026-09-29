package app.passvault

import org.json.JSONObject
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher

private data class DeviceState(var attempts: Int, var erased: Boolean, var salt: ByteArray, var secret: ByteArray, var wrapped: ByteArray, var blob: String) {
    fun encode(): ByteArray {
        fun b64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)
        return JSONObject().put("version", 1).put("attempts", attempts).put("erased", erased).put("salt", b64(salt)).put("secret", b64(secret)).put("wrapped", b64(wrapped)).put("blob", blob).toString().toByteArray()
    }
    companion object {
        fun decode(bytes: ByteArray): DeviceState {
            val j = JSONObject(bytes.toString(Charsets.UTF_8)); require(j.getInt("version") == 1)
            fun data(name: String) = Base64.getDecoder().decode(j.getString(name))
            return DeviceState(j.getInt("attempts"), j.getBoolean("erased"), data("salt"), data("secret"), data("wrapped"), j.getString("blob"))
        }
    }
}
class VaultEngine(private val storage: ProtectedStorage) {
    private var key: ByteArray? = null
    private var records = emptyList<VaultRecord>()
    private val wrapAAD = "PassVault/key/v1".toByteArray()
    private fun state(): DeviceState? {
        val value = storage.readState()?.let(DeviceState::decode) ?: return null
        require(value.attempts in 0..10); UUID.fromString(value.blob)
        check(!value.erased) { "The local vault was erased after 10 failed attempts." }
        if (value.attempts == 10) { erase(value); error("The local vault was erased after 10 failed attempts.") }
        require(value.salt.size == 16 && value.secret.size == 32 && value.wrapped.size == 72) { "Damaged protected state." }
        return value
    }
    @Synchronized fun exists() = state() != null
    @Synchronized fun isErased() = storage.readState()?.let { DeviceState.decode(it).erased } ?: false
    @Synchronized fun resetErasedVault() {
        check(isErased()) { "Only an already-erased vault can be reset without a password." }
        lock(); storage.deleteBiometric(); storage.removeBlobs(null); storage.deleteState()
    }
    @Synchronized fun remainingAttempts() = 10 - (state()?.attempts ?: 0)
    @Synchronized fun lock() { key?.fill(0); key = null; records = emptyList() }
    @Synchronized fun create(password: String): List<VaultRecord> {
        check(state() == null) { "A vault already exists." }; VaultCrypto.strongPassword(password)
        storage.initializeKey()
        val salt = VaultCrypto.random(16); val secret = VaultCrypto.random(32); val dataKey = VaultCrypto.random(32)
        val derived = VaultCrypto.passwordKey(password, salt); val wrapping = VaultCrypto.deviceKey(derived, secret); derived.fill(0)
        val blob = UUID.randomUUID().toString()
        try {
            val value = DeviceState(0, false, salt, secret, VaultCrypto.seal(dataKey, wrapping, wrapAAD), blob)
            storage.writeBlob(blob, VaultCrypto.seal(Records.encode(emptyList()), dataKey, blob.toByteArray()))
            storage.writeState(value.encode()); key = dataKey; records = emptyList(); return records
        } finally { wrapping.fill(0) }
    }
    private fun authenticate(password: String): ByteArray {
        val value = state() ?: error("Create a vault first.")
        value.attempts++; storage.writeState(value.encode())
        val derived = VaultCrypto.passwordKey(password, value.salt); val wrapping = VaultCrypto.deviceKey(derived, value.secret); derived.fill(0)
        val candidate: ByteArray
        try { candidate = VaultCrypto.open(value.wrapped, wrapping, wrapAAD) }
        catch (e: AuthenticationFailure) { if (value.attempts == 10) { erase(value); error("The local vault was erased after 10 failed attempts.") }; throw e }
        finally { wrapping.fill(0) }
        value.attempts = 0
        try { storage.writeState(value.encode()) } catch (e: Exception) { candidate.fill(0); throw e }
        return candidate
    }
    private fun load(candidate: ByteArray): List<VaultRecord> {
        val value = state() ?: error("Vault is locked.")
        val plain = VaultCrypto.open(storage.readBlob(value.blob), candidate, value.blob.toByteArray())
        try { val loaded = Records.decode(plain); key?.fill(0); key = candidate.copyOf(); records = loaded; return records }
        finally { plain.fill(0); candidate.fill(0) }
    }
    @Synchronized fun unlock(password: String) = load(authenticate(password))
    @Synchronized fun biometricCipher(encrypt: Boolean): Cipher { check(state() != null); return storage.biometricCipher(encrypt) }
    @Synchronized fun biometricKey(password: String): ByteArray { check(key != null) { "Vault is locked." }; return authenticate(password) }
    @Synchronized fun saveBiometric(cipher: Cipher, candidate: ByteArray) { check(state() != null && key != null) { "Vault is locked." }; storage.saveBiometric(cipher, candidate) }
    /** A successful hardware-backed biometric unlock proves the owner is present, so it clears failed password attempts. */
    @Synchronized fun unlockBiometric(cipher: Cipher): List<VaultRecord> {
        val value = state() ?: error("Create a vault first.")
        val loaded = load(storage.readBiometric(cipher))
        if (value.attempts != 0) { value.attempts = 0; storage.writeState(value.encode()) }
        return loaded
    }
    @Synchronized fun hasBiometric() = state() != null && storage.hasBiometric()
    @Synchronized fun disableBiometric() = storage.deleteBiometric()
    @Synchronized fun isUnlocked() = key != null
    @Synchronized fun save(updated: List<VaultRecord>) {
        val dataKey = key ?: error("Vault is locked."); val value = state() ?: error("Vault is locked.")
        val blob = UUID.randomUUID().toString(); val plain = Records.encode(updated)
        try { storage.writeBlob(blob, VaultCrypto.seal(plain, dataKey, blob.toByteArray())) } finally { plain.fill(0) }
        value.blob = blob; storage.writeState(value.encode()); records = updated
        storage.removeBlobs(blob)
    }
    @Synchronized fun merge(imported: List<VaultRecord>): List<VaultRecord> {
        check(key != null) { "Vault is locked." }
        val updated = records + imported.map { it.copy(id = UUID.randomUUID().toString()) }; save(updated); return updated
    }
    /** Verifies the app password (a counted attempt) and encrypts the backup with that same password. */
    @Synchronized fun export(password: String, csv: Boolean): ByteArray {
        check(key != null) { "Vault is locked." }; authenticate(password).fill(0)
        return if (csv) VaultCSV.exportRecords(records).toByteArray() else VaultCrypto.exportBackup(records, password)
    }
    @Synchronized fun changePassword(current: String, new: String) {
        check(key != null) { "Vault is locked." }; VaultCrypto.strongPassword(new)
        val candidate = authenticate(current)
        try {
            val value = state() ?: error("Vault is locked.")
            val salt = VaultCrypto.random(16); val secret = VaultCrypto.random(32)
            val derived = VaultCrypto.passwordKey(new, salt); val wrapping = VaultCrypto.deviceKey(derived, secret); derived.fill(0)
            try { value.salt = salt; value.secret = secret; value.wrapped = VaultCrypto.seal(candidate, wrapping, wrapAAD); storage.writeState(value.encode()) }
            finally { wrapping.fill(0) }
        } finally { candidate.fill(0) }
    }
    private fun erase(value: DeviceState) {
        lock(); value.erased = true; value.secret.fill(0); value.wrapped.fill(0); value.salt.fill(0)
        value.secret = byteArrayOf(); value.wrapped = byteArrayOf(); value.salt = byteArrayOf()
        storage.writeState(value.encode()); storage.finishErasure()
    }
}
