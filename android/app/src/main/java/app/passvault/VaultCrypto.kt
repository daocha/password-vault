package app.passvault

import androidx.annotation.StringRes
import com.goterl.lazysodium.SodiumAndroid
import com.sun.jna.NativeLong
import java.security.SecureRandom

object PasswordPolicy {
    @StringRes val RULE = R.string.app_pw_rule
    /** Resource id of the first unmet rule, or null when [password] is acceptable. */
    @StringRes fun problem(typed: String): Int? = PasswordText.normalize(typed).let { password -> when {
        password.codePointCount(0, password.length) < 12 -> R.string.app_pw_min_length
        password.toByteArray().size > PasswordText.MAX_BYTES -> R.string.app_pw_max_bytes
        password.none { it.isUpperCase() } -> R.string.app_pw_upper
        password.none { it.isLowerCase() } -> R.string.app_pw_lower
        password.none { it.isDigit() } -> R.string.app_pw_digit
        password.none { !it.isLetterOrDigit() && !it.isWhitespace() } -> R.string.app_pw_symbol
        guesses(password) < MIN_GUESSES_LOG10 -> R.string.app_pw_guessable
        else -> null
    } }
    /**
     * A stolen backup can be guessed at offline, without the phone's ten-attempt limit, so the password must also be hard to guess, not
     * only mixed in character types: "Summer2026!!" passes those but is in every cracking wordlist. 10^10 guesses (zxcvbn's top score) is
     * years for one GPU against the backup's Argon2id. Only the first [ESTIMATE_LENGTH] characters are estimated: zxcvbn slows down
     * sharply on long input, and a longer password only gets stronger.
     */
    const val MIN_GUESSES_LOG10 = 10.0
    private const val ESTIMATE_LENGTH = 64
    /**
     * log10 of zxcvbn's estimated guesses, entirely offline (its dictionaries are in the jar). If the estimator cannot run on a phone, the
     * character rules alone decide, rather than no vault being creatable; the device tests check that it does run on Android.
     */
    fun guesses(password: String): Double = runCatching {
        val end = if (password.codePointCount(0, password.length) > ESTIMATE_LENGTH) password.offsetByCodePoints(0, ESTIMATE_LENGTH) else password.length
        val estimator = zxcvbn
        synchronized(estimator) { estimator.measure(password.substring(0, end), listOf("passvault", "vault", "password")).guessesLog10 }
    }.getOrDefault(Double.MAX_VALUE)
    /** Built once: each `Zxcvbn()` reads all its dictionaries from the jar again. Used under its own lock, as its thread safety is not documented. */
    private val zxcvbn by lazy { com.nulabinc.zxcvbn.Zxcvbn() }
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
    fun random(size: Int) = ByteArray(size).also(rng::nextBytes)
    /** [legacyEncoding] keys from the text exactly as typed, only to open data made before passwords were normalized. */
    fun passwordKey(password: String, salt: ByteArray, profile: KdfProfile = KdfProfile.VAULT, legacyEncoding: Boolean = false): ByteArray {
        val input = if (legacyEncoding) PasswordText.legacyBytes(password) else PasswordText.bytes(password)
        try {
            require(input.size <= PasswordText.MAX_BYTES && salt.size == 16)
            val result = ByteArray(32)
            check(sodium.crypto_pwhash(result, 32, input, input.size.toLong(), salt, profile.opsLimit, NativeLong(profile.memBytes), 2) == 0) { "Not enough memory to derive the vault key." }
            return result
        } finally { input.fill(0) }
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
    /** An X25519 key pair for [sealTo]: public 32 bytes, secret 32 bytes. */
    fun boxKeyPair(): Pair<ByteArray, ByteArray> {
        val public = ByteArray(32); val secret = ByteArray(32)
        check(sodium.crypto_box_keypair(public, secret) == 0); return public to secret
    }
    /** A libsodium sealed box: only the holder of the secret key matching [publicKey] can open it, not the sender. 48 bytes longer than [plain]. */
    fun sealTo(plain: ByteArray, publicKey: ByteArray): ByteArray {
        require(publicKey.size == 32 && plain.size <= 1024)
        return ByteArray(plain.size + 48).also { check(sodium.crypto_box_seal(it, plain, plain.size.toLong(), publicKey) == 0) }
    }
    fun openSealed(box: ByteArray, publicKey: ByteArray, secretKey: ByteArray): ByteArray {
        require(publicKey.size == 32 && secretKey.size == 32 && box.size in 48..1024 + 48) { "Invalid encrypted data." }
        val plain = ByteArray(box.size - 48)
        if (sodium.crypto_box_seal_open(plain, box, box.size.toLong(), publicKey, secretKey) != 0) { plain.fill(0); throw AuthenticationFailure() }
        return plain
    }
    fun strongPassword(password: String) { if (PasswordPolicy.problem(password) != null) throw IllegalArgumentException("Password does not meet the strength rules.") }
    // The caller has already verified this is the app password; it met the policy in force when it was set.
    fun exportBackup(records: List<VaultRecord>, password: String): ByteArray {
        require(password.isNotEmpty() && PasswordText.bytes(password).size <= PasswordText.MAX_BYTES)
        val profile = KdfProfile.BACKUP
        val salt = random(16); val header = BackupFormat.header(profile, salt); val key = passwordKey(password, salt, profile); val plain = Records.encode(records)
        try { return header + seal(plain, key, header) } finally { key.fill(0); plain.fill(0) }
    }
    fun isBackup(data: ByteArray) = BackupFormat.isBackup(data)
    fun importBackup(data: ByteArray, password: String): List<VaultRecord> {
        val parsed = BackupFormat.parse(data)
        require(data.size in parsed.size + 40..Records.MAX_BYTES + parsed.size + 40) { "Unsupported or oversized encrypted backup." }
        val header = data.copyOfRange(0, parsed.size); val box = data.copyOfRange(parsed.size, data.size)
        // QVAULT01 files were keyed from the password exactly as typed; try that too when normalization would change it.
        var failure: AuthenticationFailure? = null
        for (legacy in if (parsed.version == 1 && PasswordText.differs(password)) listOf(false, true) else listOf(false)) {
            val key = passwordKey(password, parsed.salt, parsed.profile, legacy)
            try {
                val plain = open(box, key, header)
                try { return Records.decode(plain) } finally { plain.fill(0) }
            } catch (e: AuthenticationFailure) { failure = e } finally { key.fill(0) }
        }
        throw failure!!
    }
}
