package app.passvault

import android.app.KeyguardManager
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.KeyInfo
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

class ProtectedStorage(private val context: Context) {
    private val directory = File(context.noBackupFilesDir, "passvault").apply { check(exists() || mkdirs()) }
    private val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val stateAlias = "passvault-state-v1"
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
    private fun stateKey(create: Boolean = false): SecretKey {
        val existing = keystore.getKey(stateAlias, null) as? SecretKey
        return existing ?: if (create && !File(directory, "state").exists() && !hasBlobs()) generate(stateAlias, false)
        else error("Protected device key is missing. Access is refused.")
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
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, stateKey(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD("PassVault/state/v1".toByteArray())
        return cipher.doFinal(bytes.copyOfRange(12, bytes.size))
    }
    fun writeState(bytes: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, stateKey(create = true))
        cipher.updateAAD("PassVault/state/v1".toByteArray())
        write(File(directory, "state"), cipher.iv + cipher.doFinal(bytes))
    }
    // Initialize the OS key before writing the first encrypted vault blob.
    fun initializeKey() { stateKey(create = true) }
    fun deleteState() { AtomicFile(File(directory, "state")).delete(); AtomicFile(File(directory, "erased")).delete() }
    fun finishErasure() {
        // A nonsecret tombstone only denies access. It is never an authorization token.
        // Persist it before removing the Keystore key so interrupted cleanup resumes safely.
        write(File(directory, "erased"), byteArrayOf(1))
        deleteBiometric()
        if (keystore.containsAlias(stateAlias)) keystore.deleteEntry(stateAlias)
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
