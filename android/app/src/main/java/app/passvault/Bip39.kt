package app.passvault

import androidx.annotation.StringRes
import java.security.MessageDigest
import java.security.SecureRandom

/** A localizable message: a string resource plus format arguments, resolved in the UI with [text]. */
data class UiText(@StringRes val res: Int, val args: List<Any> = emptyList())

/** BIP-39 mnemonics (English wordlist). Only the phrase is stored; seeds are never derived here. */
object Bip39 {
    val WORD_COUNTS = listOf(12, 24)
    private const val WORDLIST_SHA256 = "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"
    val words: List<String> by lazy {
        val bytes = Bip39::class.java.getResourceAsStream("/bip39-english.txt")?.use { it.readBytes() } ?: error("BIP-39 wordlist missing.")
        // Fail closed if the bundled list was altered: a wrong list silently produces unrecoverable phrases.
        check(MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) } == WORDLIST_SHA256) { "BIP-39 wordlist is corrupted." }
        bytes.toString(Charsets.UTF_8).lines().filter { it.isNotEmpty() }.also { check(it.size == 2048) }
    }
    private val index by lazy { words.withIndex().associate { it.value to it.index } }
    private val random = SecureRandom()

    fun generate(wordCount: Int): List<String> {
        require(wordCount in WORD_COUNTS)
        val entropy = ByteArray(wordCount / 3 * 4).also(random::nextBytes)
        try { return fromEntropy(entropy) } finally { entropy.fill(0) }
    }
    fun fromEntropy(entropy: ByteArray): List<String> {
        require(entropy.size in listOf(16, 20, 24, 28, 32))
        val hash = MessageDigest.getInstance("SHA-256").digest(entropy)
        val entropyBits = entropy.size * 8
        fun bit(i: Int) = if (i < entropyBits) (entropy[i / 8].toInt() shr (7 - i % 8)) and 1 else (hash[(i - entropyBits) / 8].toInt() shr (7 - (i - entropyBits) % 8)) and 1
        return (0 until (entropyBits + entropyBits / 32) / 11).map { w -> words[(0 until 11).fold(0) { v, b -> (v shl 1) or bit(w * 11 + b) }] }
    }
    fun split(text: String): List<String> = text.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
    fun isWord(word: String) = word in index
    fun suggestions(prefix: String, limit: Int = 8): List<String> = if (prefix.isEmpty()) emptyList() else words.filter { it.startsWith(prefix) }.take(limit)

    /** Null when [phrase] is a valid 12- or 24-word English BIP-39 mnemonic, otherwise the reason. */
    fun problem(phrase: List<String>): UiText? {
        if (phrase.size !in WORD_COUNTS) return UiText(R.string.seed_err_word_count, listOf(phrase.size))
        val unknown = phrase.withIndex().filter { !isWord(it.value) }
        if (unknown.isNotEmpty()) return UiText(R.string.seed_err_unknown, listOf(unknown.joinToString { "#${it.index + 1} “${it.value}”" }))
        val bits = phrase.flatMap { word -> val v = index.getValue(word); (10 downTo 0).map { (v shr it) and 1 } }
        val entropyBits = bits.size * 32 / 33
        val entropy = ByteArray(entropyBits / 8) { i -> (0 until 8).fold(0) { v, b -> (v shl 1) or bits[i * 8 + b] }.toByte() }
        val expected = fromEntropy(entropy); entropy.fill(0)
        return if (expected.last() == phrase.last()) null else UiText(R.string.seed_err_checksum)
    }
}
