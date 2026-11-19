package app.passvault

import androidx.annotation.StringRes
import java.security.MessageDigest

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

    /** A new phrase from [SeedEntropy.system]. Throws [EntropyFailure] rather than return a phrase whose randomness failed a check. */
    fun generate(wordCount: Int): List<String> = generate(wordCount, SeedEntropy.system)

    /**
     * A phrase from the SHA-256 mix of one block from each of [sources] (see [SeedEntropy.mix]). Before the phrase is returned, the blocks
     * must differ from each other, the entropy must differ from every raw block, and the phrase must decode back to the entropy with a
     * valid checksum. The buffers this code fills with entropy are wiped whether or not a check fails (the hash's own state and the
     * returned words cannot be). [mix] is replaced only by tests, to show that a faulty mixer is caught.
     */
    @Synchronized internal fun generate(
        wordCount: Int, sources: List<SeedEntropy.Source>, mix: (List<ByteArray>, Int) -> ByteArray = SeedEntropy::mix,
    ): List<String> {
        require(wordCount in WORD_COUNTS)
        require(sources.size >= 2) { "A seed phrase mixes at least two random sources." }
        val blocks = ArrayList<ByteArray>(sources.size)
        try {
            for (source in sources) blocks += source.read()
            for (i in blocks.indices) for (j in i + 1 until blocks.size) {
                if (MessageDigest.isEqual(blocks[i], blocks[j])) throw EntropyFailure("${sources[i].name} and ${sources[j].name} returned the same block.")
            }
            val entropy = mix(blocks, wordCount / 3 * 4)
            try {
                if (SeedEntropy.unmixed(blocks, entropy)) throw EntropyFailure("A random source reached the phrase without being mixed.")
                val words = fromEntropy(entropy)
                if (!encodes(words, entropy)) throw EntropyFailure("The new phrase does not decode to its entropy.")
                return words
            } finally { entropy.fill(0) }
        } finally { blocks.forEach { it.fill(0) } }
    }

    /** True when [words] is a valid phrase that decodes to exactly [entropy]. */
    internal fun encodes(words: List<String>, entropy: ByteArray): Boolean {
        val decoded = toEntropy(words) ?: return false
        try { return MessageDigest.isEqual(decoded, entropy) && problem(words) == null } finally { decoded.fill(0) }
    }

    fun fromEntropy(entropy: ByteArray): List<String> {
        require(entropy.size in listOf(16, 20, 24, 28, 32))
        val hash = MessageDigest.getInstance("SHA-256").digest(entropy)
        try {
            val entropyBits = entropy.size * 8
            fun bit(i: Int) = if (i < entropyBits) (entropy[i / 8].toInt() shr (7 - i % 8)) and 1 else (hash[(i - entropyBits) / 8].toInt() shr (7 - (i - entropyBits) % 8)) and 1
            return (0 until (entropyBits + entropyBits / 32) / 11).map { w -> words[(0 until 11).fold(0) { v, b -> (v shl 1) or bit(w * 11 + b) }] }
        } finally { hash.fill(0) }
    }

    /**
     * The entropy a phrase of 12, 15, 18, 21 or 24 known words encodes, without checking its checksum; null for any other phrase.
     * Built straight into the returned array (the caller wipes it), with no boxed bit list left behind.
     */
    internal fun toEntropy(phrase: List<String>): ByteArray? {
        if (phrase.size !in 12..24 || phrase.size % 3 != 0) return null
        val entropyBits = phrase.size * 11 * 32 / 33
        val entropy = ByteArray(entropyBits / 8)
        var bit = 0
        for (word in phrase) {
            val value = index[word] ?: run { entropy.fill(0); return null }
            for (shift in 10 downTo 0) {
                if (bit < entropyBits && (value shr shift) and 1 == 1) entropy[bit / 8] = (entropy[bit / 8].toInt() or (0x80 ushr (bit % 8))).toByte()
                bit++
            }
        }
        return entropy
    }
    fun split(text: String): List<String> = text.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
    fun isWord(word: String) = word in index
    fun suggestions(prefix: String, limit: Int = 8): List<String> = if (prefix.isEmpty()) emptyList() else words.filter { it.startsWith(prefix) }.take(limit)

    /** Null when [phrase] is a valid 12- or 24-word English BIP-39 mnemonic, otherwise the reason. */
    fun problem(phrase: List<String>): UiText? {
        if (phrase.size !in WORD_COUNTS) return UiText(R.string.seed_err_word_count, listOf(phrase.size))
        val unknown = phrase.withIndex().filter { !isWord(it.value) }
        if (unknown.isNotEmpty()) return UiText(R.string.seed_err_unknown, listOf(unknown.joinToString { "#${it.index + 1} “${it.value}”" }))
        val entropy = toEntropy(phrase) ?: return UiText(R.string.seed_err_checksum)
        // Every word but the last is fixed by the entropy alone, so the last word decides whether the checksum matches.
        val expected = try { fromEntropy(entropy) } finally { entropy.fill(0) }
        return if (expected.last() == phrase.last()) null else UiText(R.string.seed_err_checksum)
    }
}
