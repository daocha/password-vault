package app.passvault

import java.io.DataInputStream
import java.io.FileInputStream
import java.security.MessageDigest
import java.security.SecureRandom

/** A random source failed a safety check, so no seed phrase was made. The editor shows [R.string.seed_err_randomness]. */
class EntropyFailure(message: String) : Exception(message)

/**
 * Where seed-phrase randomness comes from, and the checks it passes before a phrase is shown. iOS's `SeedEntropy` does the same.
 *
 * Two separate paths to the system's random generator are read and hashed together, so a fault in one path (a provider swapped in, a
 * call routed to a generator that is not cryptographic, a source that returns a constant) cannot weaken a phrase while the other path
 * works. Both paths end in the kernel's generator: this guards against faults in the code above the kernel, not in the kernel itself.
 */
object SeedEntropy {
    /** Bytes read from each source for every phrase. */
    const val BLOCK = 32
    /**
     * A block in which one byte value appears this often is rejected. A working source does that about once in 7 billion blocks
     * (256 · P[Binomial(32, 1/256) ≥ 8] ≈ 1.3e-10); a stuck, all-zero or heavily biased source does it at once.
     */
    const val MAX_REPEATS = 8
    private val DOMAIN = "PassVault/bip39-entropy/v1".toByteArray(Charsets.US_ASCII)

    /** One random source. It keeps a digest of its last block, so a source that returns the same block twice is caught. */
    class Source(val name: String, private val fill: (ByteArray) -> Unit) {
        private var last: ByteArray? = null

        /** A fresh [BLOCK]-byte block that passed the checks. The caller wipes it. */
        @Synchronized fun read(): ByteArray {
            val block = ByteArray(BLOCK)
            var passed = false
            try {
                try { fill(block) } catch (e: EntropyFailure) { throw e } catch (e: Exception) { throw EntropyFailure("$name could not be read (${e.javaClass.simpleName}).") }
                if (!healthy(block)) throw EntropyFailure("$name returned a block that fails the health check.")
                val digest = MessageDigest.getInstance("SHA-256").digest(block)
                if (last?.let { MessageDigest.isEqual(it, digest) } == true) throw EntropyFailure("$name returned its previous block again.")
                last = digest
                passed = true
                return block
            } finally { if (!passed) block.fill(0) }
        }
    }

    /** False when one byte value appears [MAX_REPEATS] or more times in [block]. */
    fun healthy(block: ByteArray): Boolean {
        val counts = IntArray(256)
        try {
            for (b in block) if (++counts[b.toInt() and 0xff] >= MAX_REPEATS) return false
            return true
        } finally { counts.fill(0) }
    }

    /**
     * SHA-256 over the domain tag, the output [length] and every block preceded by its length (32-bit big-endian), cut to [length] bytes.
     * The lengths make the encoding unambiguous: no two different lists of blocks hash the same input.
     */
    fun mix(blocks: List<ByteArray>, length: Int): ByteArray {
        require(length in 1..32)
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(DOMAIN); digest.update(be32(length))
        for (block in blocks) { digest.update(be32(block.size)); digest.update(block) }
        val full = digest.digest()
        try { return full.copyOf(length) } finally { full.fill(0) }
    }

    /** True when [entropy] equals the start of a raw block: the phrase would not have gone through [mix]. */
    fun unmixed(blocks: List<ByteArray>, entropy: ByteArray): Boolean =
        blocks.any { block -> block.size >= entropy.size && entropy.indices.all { block[it] == entropy[it] } }

    private fun be32(value: Int) = byteArrayOf((value ushr 24).toByte(), (value ushr 16).toByte(), (value ushr 8).toByte(), value.toByte())

    /** ART reports "Dalvik" as its VM name; the desktop JVM that runs unit tests does not. */
    private val onAndroid = System.getProperty("java.vm.name") == "Dalvik"
    /** Where `SecureRandom()` must come from: Conscrypt on Android (BoringSSL, seeded by the kernel), the JDK's own provider in unit tests. */
    val expectedProvider = if (onAndroid) "AndroidOpenSSL" else "SUN"

    /** `SecureRandom()`, refused if any provider other than [expected] supplies it. A new instance each time catches a provider added later. */
    fun secureRandomSource(expected: String = expectedProvider) = Source("SecureRandom") { block ->
        val random = SecureRandom()
        val provider = random.provider.name
        if (provider != expected) throw EntropyFailure("SecureRandom comes from $provider, not $expected.")
        random.nextBytes(block)
    }

    /** The kernel's generator read directly, not through any Java provider. */
    fun deviceSource(path: String = "/dev/urandom") = Source(path) { block -> DataInputStream(FileInputStream(path)).use { it.readFully(block) } }

    /** The two sources every generated phrase mixes. */
    val system: List<Source> = listOf(secureRandomSource(), deviceSource())
}
