package app.passvault

import android.app.KeyguardManager
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.KeyInfo
import android.util.AtomicFile
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

/**
 * Protected state file: `"PVS2" | u32be generation | iv 12 | AES-GCM ciphertext`, authenticated with the header.
 * Each generation has its own Keystore key and older keys are deleted, so a copied older state file cannot be decrypted (rolled back).
 */
internal object StateFormat {
    private val magic = "PVS2".toByteArray()
    const val HEADER = 8; const val IV = 12; const val MIN_SIZE = HEADER + IV + 16
    fun header(generation: Int): ByteArray = ByteBuffer.allocate(HEADER).put(magic).putInt(generation).array()
    /** `PVS` followed by a digit above the layout this build reads: state saved by a newer PassVault. */
    fun isNewer(bytes: ByteArray): Boolean = bytes.size >= 4 && bytes.copyOfRange(0, 3).contentEquals("PVS".toByteArray()) && bytes[3].toInt() > '2'.code && bytes[3].toInt() <= '9'.code
    /** The stored generation, or 0 for a file in the earlier layout (`iv | ciphertext`, one fixed key) or anything else unrecognised. */
    fun generation(bytes: ByteArray): Int =
        if (bytes.size >= MIN_SIZE && bytes.copyOfRange(0, 4).contentEquals(magic)) ByteBuffer.wrap(bytes, 4, 4).int.coerceAtLeast(0) else 0
    fun aad(header: ByteArray): ByteArray = "PassVault/state/v2".toByteArray() + header
}

class ProtectedStorage(private val context: Context) {
    private val directory = File(context.noBackupFilesDir, "passvault").apply { check(exists() || mkdirs()) }
    private val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val legacyStateAlias = "passvault-state-v1"
    private val stateAliasPrefix = "passvault-state-g"
    private fun stateAlias(generation: Int) = "$stateAliasPrefix$generation"
    private val bioAlias = "passvault-biometric-v1"
    private fun generate(alias: String, biometric: Boolean): SecretKey {
        check(context.getSystemService(KeyguardManager::class.java).isDeviceSecure) { "Set a device screen lock first." }
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).setUnlockedDeviceRequired(true).setIsStrongBoxBacked(strongBox)
            .apply { if (biometric) { setUserAuthenticationRequired(true); setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG); setInvalidatedByBiometricEnrollment(true) } }.build()
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val key = try { generator.init(spec(true)); generator.generateKey() }
        catch (_: java.security.ProviderException) { generator.init(spec(false)); generator.generateKey() } // includes StrongBoxUnavailableException
        val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
        @Suppress("DEPRECATION")
        if (!info.isInsideSecureHardware && !BuildConfig.ALLOW_SOFTWARE_KEYSTORE) { keystore.deleteEntry(alias); error("This device does not provide hardware-backed key storage.") }
        return key
    }
    private fun missingKey(): Nothing = error("Protected device key is missing. Access is refused.")
    private fun stateFileExists() = File(directory, "state").exists() || File(directory, "state.bak").exists()
    private fun secretKey(alias: String) = keystore.getKey(alias, null) as? SecretKey
    /** Deletes every state key (all generations and the pre-ratchet one) except [keep]. */
    private fun deleteStateKeys(keep: Int? = null) {
        val kept = keep?.let(::stateAlias)
        java.util.Collections.list(keystore.aliases()).filter { (it == legacyStateAlias || it.startsWith(stateAliasPrefix)) && it != kept }.forEach { keystore.deleteEntry(it) }
    }
    private fun write(file: File, bytes: ByteArray) {
        val atomic = AtomicFile(file); val stream = atomic.startWrite()
        try { stream.write(bytes); atomic.finishWrite(stream) } catch (e: Exception) { atomic.failWrite(stream); throw e }
    }
    private fun read(file: File, max: Int): ByteArray {
        val atomic = AtomicFile(file)
        return atomic.openRead().use { input ->
            val output = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
            while (true) { val n = input.read(buffer); if (n < 0) break; require(output.size() + n <= max) { "File is too large." }; output.write(buffer, 0, n) }
            output.toByteArray()
        }
    }
    fun readState(): ByteArray? {
        if (File(directory, "erased").exists()) {
            finishErasure()
            return "{\"version\":1,\"attempts\":10,\"erased\":true,\"salt\":\"\",\"secret\":\"\",\"wrapped\":\"\",\"blob\":\"00000000-0000-0000-0000-000000000000\"}".toByteArray()
        }
        val file = File(directory, "state")
        if (!file.exists() && !File(directory, "state.bak").exists()) { check(!hasBlobs()) { "Protected state is missing." }; return null }
        val bytes = read(file, 16384); require(bytes.size >= 28)
        // An earlier-layout file that happens to start with these bytes still has its old key; a newer layout does not.
        if (StateFormat.isNewer(bytes) && secretKey(legacyStateAlias) == null) throw NewerVersionException(backup = false)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val generation = StateFormat.generation(bytes)
        val key = if (generation > 0) secretKey(stateAlias(generation)) else null
        if (key != null) {
            val header = bytes.copyOfRange(0, StateFormat.HEADER)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(StateFormat.HEADER, StateFormat.HEADER + StateFormat.IV)))
            cipher.updateAAD(StateFormat.aad(header))
            return cipher.doFinal(bytes.copyOfRange(StateFormat.HEADER + StateFormat.IV, bytes.size))
        }
        // A file from before generations. A newer file whose key is gone (a restored old copy) has no legacy key to fall back on and is refused.
        cipher.init(Cipher.DECRYPT_MODE, secretKey(legacyStateAlias) ?: missingKey(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD("PassVault/state/v1".toByteArray())
        return cipher.doFinal(bytes.copyOfRange(12, bytes.size))
    }
    /**
     * With [ratchet] (the default) the state moves to a new Keystore key and every older key is deleted once the file is committed,
     * so copies of earlier state (with fewer failed attempts recorded) can no longer be decrypted. Skip it only for writes that never
     * make an old copy more useful to an attacker, such as clearing the counter after the password was proven.
     */
    fun writeState(bytes: ByteArray, ratchet: Boolean = true) {
        val existing = if (stateFileExists()) read(File(directory, "state"), 16384) else null
        if (existing != null && StateFormat.isNewer(existing) && secretKey(legacyStateAlias) == null) throw NewerVersionException(backup = false)
        val held = existing?.let(StateFormat::generation)?.takeIf { it > 0 && keystore.containsAlias(stateAlias(it)) }
        val generation: Int; val key: SecretKey
        if (existing == null) { generation = 1; key = secretKey(stateAlias(1)) ?: missingKey() } // created by initializeKey() before the first blob
        else if (held != null && !ratchet) { generation = held; key = secretKey(stateAlias(held)) ?: missingKey() }
        else {
            // Never mint a key over state that could not be read: the current key must still exist (this also migrates the earlier layout).
            if (!keystore.containsAlias(held?.let(::stateAlias) ?: legacyStateAlias)) missingKey()
            generation = (held ?: 0) + 1
            if (keystore.containsAlias(stateAlias(generation))) keystore.deleteEntry(stateAlias(generation))
            key = generate(stateAlias(generation), false)
        }
        val header = StateFormat.header(generation)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(StateFormat.aad(header))
        check(cipher.iv.size == StateFormat.IV)
        write(File(directory, "state"), header + cipher.iv + cipher.doFinal(bytes))
        deleteStateKeys(keep = generation)
    }
    // Initialize the OS key before writing the first encrypted vault blob.
    fun initializeKey() {
        check(!stateFileExists() && !hasBlobs()) { "Protected device key is missing. Access is refused." }
        deleteStateKeys(); generate(stateAlias(1), false)
    }
    fun deleteState() { AtomicFile(File(directory, "state")).delete(); AtomicFile(File(directory, "erased")).delete(); deleteStateKeys() }
    fun finishErasure() {
        // A nonsecret tombstone only denies access. It is never an authorization token.
        // Persist it before removing the Keystore key so interrupted cleanup resumes safely.
        write(File(directory, "erased"), byteArrayOf(1))
        deleteBiometric()
        deleteStateKeys()
        AtomicFile(File(directory, "state")).delete()
        removeBlobs(null)
    }
    private fun blob(id: String): File { require(java.util.UUID.fromString(id).toString().equals(id, true)); return File(directory, "$id.vault") }
    fun readBlob(id: String) = read(blob(id), Records.MAX_BYTES + 40)
    fun writeBlob(id: String, bytes: ByteArray) = write(blob(id), bytes)
    fun hasBlobs() = directory.listFiles()?.any { it.name.endsWith(".vault") || it.name.endsWith(".vault.bak") } ?: false
    // Also removes AtomicFile leftovers (<id>.vault.new from an interrupted write, legacy <id>.vault.bak).
    fun removeBlobs(except: String?) {
        directory.listFiles()?.filter { f -> listOf(".vault", ".vault.new", ".vault.bak").any { f.name.endsWith(it) } && f.name.substringBefore('.') != except }
            ?.forEach { check(it.delete() || !it.exists()) { "Could not remove old ciphertext." } }
    }
    fun biometricCipher(encrypt: Boolean): Cipher {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        if (encrypt) {
            if (keystore.containsAlias(bioAlias)) keystore.deleteEntry(bioAlias)
            cipher.init(Cipher.ENCRYPT_MODE, generate(bioAlias, true))
        } else {
            val key = keystore.getKey(bioAlias, null) as? SecretKey ?: error("Unlock with your password and enable biometrics first.")
            val bytes = read(File(directory, "biometric"), 256)
            require(bytes.size == 60)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        }
        return cipher
    }
    // The biometric key is auth-per-operation: AAD must be supplied only after BiometricPrompt authorizes the cipher.
    private val bioAAD = "PassVault/biometric/v1".toByteArray()
    fun saveBiometric(cipher: Cipher, key: ByteArray) { cipher.updateAAD(bioAAD); val iv = cipher.iv; write(File(directory, "biometric"), iv + cipher.doFinal(key)) }
    fun readBiometric(cipher: Cipher): ByteArray { val bytes = read(File(directory, "biometric"), 256); cipher.updateAAD(bioAAD); return cipher.doFinal(bytes.copyOfRange(12, bytes.size)) }
    fun hasBiometric() = keystore.containsAlias(bioAlias) && File(directory, "biometric").exists()
    fun deleteBiometric() {
        if (keystore.containsAlias(bioAlias)) keystore.deleteEntry(bioAlias)
        AtomicFile(File(directory, "biometric")).delete()
    }
}
