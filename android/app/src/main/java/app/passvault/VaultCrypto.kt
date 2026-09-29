package app.passvault

import androidx.annotation.StringRes
import com.goterl.lazysodium.SodiumAndroid
import com.sun.jna.NativeLong
import java.security.SecureRandom

object PasswordPolicy {
    @StringRes const val RULE = R.string.app_pw_rule
    /** Resource id of the first unmet rule, or null when [password] is acceptable. */
    @StringRes fun problem(password: String): Int? = when {
        password.codePointCount(0, password.length) < 12 -> R.string.app_pw_min_length
        password.toByteArray().size > 4096 -> R.string.app_pw_max_bytes
        password.none { it.isUpperCase() } -> R.string.app_pw_upper
        password.none { it.isLowerCase() } -> R.string.app_pw_lower
        password.none { it.isDigit() } -> R.string.app_pw_digit
        password.none { !it.isLetterOrDigit() && !it.isWhitespace() } -> R.string.app_pw_symbol
        else -> null
    }
}
data class GeneratorOptions(val length: Int = 10, val letters: Boolean = true, val numbers: Boolean = true, val symbols: Boolean = true) {
    val sets get() = (if (letters) listOf(UPPER, LOWER) else emptyList()) + (if (numbers) listOf(DIGITS) else emptyList()) + (if (symbols) listOf(SYMBOLS) else emptyList())
    companion object {
        const val MIN_LENGTH = 6; const val MAX_LENGTH = 64
        // Look-alike characters (O/0, l/1/I) are left out.
        const val UPPER = "ABCDEFGHJKLMNPQRSTUVWXYZ"; const val LOWER = "abcdefghijkmnopqrstuvwxyz"; const val DIGITS = "23456789"; const val SYMBOLS = "!@#$%^&*()-_=+[]{}:,.?"
    }
}
object PasswordGenerator {
    private val rng = SecureRandom()
    /** Uniform over the enabled alphabet, resampling until every enabled class appears at least once. */
    fun generate(options: GeneratorOptions): String {
        val sets = options.sets
        require(sets.isNotEmpty()) { "Choose at least one character type." }
        require(options.length in GeneratorOptions.MIN_LENGTH..GeneratorOptions.MAX_LENGTH && options.length >= sets.size)
        val alphabet = sets.joinToString("")
        while (true) {
            val value = CharArray(options.length) { alphabet[rng.nextInt(alphabet.length)] }.concatToString()
            if (sets.all { set -> value.any { it in set } }) return value
        }
    }
}
class AuthenticationFailure : Exception("Incorrect password or damaged encrypted data.")
object VaultCrypto {
    private val sodium = SodiumAndroid()
    private val rng = SecureRandom()
    private val magic = "QVAULT01".toByteArray()
    fun random(size: Int) = ByteArray(size).also(rng::nextBytes)
    fun passwordKey(password: String, salt: ByteArray): ByteArray {
        val input = password.toByteArray(Charsets.UTF_8)
        require(input.size <= 4096 && salt.size == 16)
        val result = ByteArray(32)
        try { check(sodium.crypto_pwhash(result, 32, input, input.size.toLong(), salt, 3, NativeLong(64L * 1024 * 1024), 2) == 0) { "Not enough memory to derive the vault key." } }
        finally { input.fill(0) }
        return result
    }
    fun deviceKey(passwordKey: ByteArray, secret: ByteArray): ByteArray {
        require(passwordKey.size == 32 && secret.size == 32)
        val input = "PassVault/device-wrap/v1".toByteArray() + passwordKey
        return ByteArray(32).also { check(sodium.crypto_generichash(it, 32, input, input.size.toLong(), secret, 32) == 0); input.fill(0) }
    }
    fun seal(plain: ByteArray, key: ByteArray, aad: ByteArray): ByteArray {
        require(key.size == 32 && plain.size <= Records.MAX_BYTES)
        val nonce = random(24); val output = ByteArray(plain.size + 16)
        check(sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(output, LongArray(1), plain, plain.size.toLong(), aad, aad.size.toLong(), null, nonce, key) == 0)
        return nonce + output
    }
    fun open(box: ByteArray, key: ByteArray, aad: ByteArray): ByteArray {
        require(key.size == 32 && box.size in 40..Records.MAX_BYTES + 40) { "Invalid encrypted file." }
        val nonce = box.copyOfRange(0, 24); val cipher = box.copyOfRange(24, box.size); val plain = ByteArray(cipher.size - 16)
        if (sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(plain, LongArray(1), null, cipher, cipher.size.toLong(), aad, aad.size.toLong(), nonce, key) != 0) { plain.fill(0); throw AuthenticationFailure() }
        return plain
    }
    fun strongPassword(password: String) { if (PasswordPolicy.problem(password) != null) throw IllegalArgumentException("Password does not meet the strength rules.") }
    // The caller has already verified this is the app password; it met the policy in force when it was set.
    fun exportBackup(records: List<VaultRecord>, password: String): ByteArray {
        require(password.isNotEmpty() && password.toByteArray().size <= 4096)
        val salt = random(16); val header = magic + salt; val key = passwordKey(password, salt); val plain = Records.encode(records)
        try { return header + seal(plain, key, header) } finally { key.fill(0); plain.fill(0) }
    }
    fun isBackup(data: ByteArray) = data.size >= magic.size && data.copyOfRange(0, magic.size).contentEquals(magic)
    fun importBackup(data: ByteArray, password: String): List<VaultRecord> {
        require(data.size in 64..Records.MAX_BYTES + 64 && data.copyOfRange(0, 8).contentEquals(magic)) { "Unsupported or oversized encrypted backup." }
        val header = data.copyOfRange(0, 24); val key = passwordKey(password, data.copyOfRange(8, 24))
        try {
            val plain = open(data.copyOfRange(24, data.size), key, header)
            try { return Records.decode(plain) } finally { plain.fill(0) }
        } finally { key.fill(0) }
    }
}
