package app.passvault

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import kotlin.math.abs
import kotlin.math.sqrt

/** Seed-phrase randomness: the official BIP-39 vectors, the mixing of two sources, and the checks that refuse a bad source. */
class SeedEntropyTest {
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun ramp(start: Int) = ByteArray(32) { (start + it).toByte() }
    /** A source that returns [block] once (copied in), and remembers the buffer it filled so tests can check that it was wiped. */
    private class Recording(name: String, private val next: () -> ByteArray) {
        val filled = mutableListOf<ByteArray>()
        val source = SeedEntropy.Source(name) { block -> next().copyInto(block); filled += block }
    }
    /** A different block on every read: SHA-256 of the name and a counter. */
    private fun counter(name: String): Recording {
        var n = 0
        return Recording(name) { MessageDigest.getInstance("SHA-256").digest("$name/${n++}".toByteArray()) }
    }

    // The same golden values are checked on iOS (SeedChecks.swift, SeedPhraseTests.swift); they were computed with an independent Python
    // implementation of the construction in SeedEntropy.mix.
    private val goldenA = ramp(0); private val goldenB = ramp(32)
    private val golden12 = "trash detect abuse mouse teach august loud milk width any city school"
    private val golden24 = "gown twenty shock orchard isolate female liar script various bounce stairs swarm never resist title entire square phrase wage bind clog equal aerobic eye"

    @Test fun everyOfficialEnglishVectorEncodesDecodesAndValidates() {
        val vectors = File("../../fixtures/bip39/english-vectors.tsv").readLines().filter { it.isNotBlank() }.map { it.split('\t') }
        assertEquals(24, vectors.size)
        for ((entropyHex, phrase) in vectors) {
            val entropy = hex(entropyHex); val words = phrase.split(' ')
            assertEquals(entropyHex, phrase, Bip39.fromEntropy(entropy).joinToString(" "))
            assertArrayEquals(entropyHex, entropy, Bip39.toEntropy(words))
            // The editor accepts 12 and 24 words only; 18-word vectors still check the encoding above.
            if (words.size in Bip39.WORD_COUNTS) { assertNull(phrase, Bip39.problem(words)); assertTrue(Bip39.encodes(words, entropy)) }
        }
    }

    @Test fun toEntropyRejectsUnknownWordsAndOddLengths() {
        val about = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".split(' ')
        assertNull(Bip39.toEntropy(about.dropLast(1) + "notaword"))
        assertNull(Bip39.toEntropy(about + "abandon"))
        assertNull(Bip39.toEntropy(about.take(9)))
        assertNull(Bip39.toEntropy(emptyList()))
        assertNull(Bip39.toEntropy(List(27) { "abandon" }))
        // Valid words with a wrong checksum still decode: the checksum is problem()'s job.
        assertArrayEquals(ByteArray(16), Bip39.toEntropy(List(12) { "abandon" }))
        assertEquals(UiText(R.string.seed_err_checksum), Bip39.problem(List(12) { "abandon" }))
        assertFalse(Bip39.encodes(List(12) { "abandon" }, ByteArray(16)))
        assertFalse(Bip39.encodes(about, ByteArray(16) { 1 }))
        assertTrue(Bip39.encodes(about, ByteArray(16)))
    }

    @Test fun mixMatchesTheCrossPlatformGoldenValues() {
        assertArrayEquals(hex("e7678c04c85de81e610c64fac144a5e0"), SeedEntropy.mix(listOf(goldenA, goldenB), 16))
        assertArrayEquals(hex("653d67194e0768a9e0360df1834f516db9516ef8ba5cd3747bd88b22b898010a"), SeedEntropy.mix(listOf(goldenA, goldenB), 32))
        assertEquals(golden12, Bip39.generate(12, listOf(Recording("a") { goldenA }.source, Recording("b") { goldenB }.source)).joinToString(" "))
        assertEquals(golden24, Bip39.generate(24, listOf(Recording("a") { goldenA }.source, Recording("b") { goldenB }.source)).joinToString(" "))
    }

    @Test fun everyInputBitChangesTheMix() {
        val base = SeedEntropy.mix(listOf(goldenA, goldenB), 32)
        for (which in 0..1) for (bit in 0 until 256) {
            val blocks = listOf(goldenA.copyOf(), goldenB.copyOf())
            blocks[which][bit / 8] = (blocks[which][bit / 8].toInt() xor (1 shl (bit % 8))).toByte()
            assertFalse("source $which bit $bit", SeedEntropy.mix(blocks, 32).contentEquals(base))
        }
        assertFalse("order matters", SeedEntropy.mix(listOf(goldenB, goldenA), 32).contentEquals(base))
        // Length prefixes: the same bytes split differently are different inputs.
        val joined = goldenA + goldenB
        assertFalse(SeedEntropy.mix(listOf(joined.copyOfRange(0, 31), joined.copyOfRange(31, 64)), 32).contentEquals(base))
        assertFalse(SeedEntropy.mix(listOf(joined), 32).contentEquals(base))
        // The output length is hashed too, so a 12-word phrase is not the start of the 24-word one from the same blocks.
        assertFalse(SeedEntropy.mix(listOf(goldenA, goldenB), 16).contentEquals(base.copyOf(16)))
        assertThrows(IllegalArgumentException::class.java) { SeedEntropy.mix(listOf(goldenA, goldenB), 33) }
        assertThrows(IllegalArgumentException::class.java) { SeedEntropy.mix(listOf(goldenA, goldenB), 0) }
    }

    @Test fun healthCheckRejectsRepeatedBytes() {
        assertTrue(SeedEntropy.healthy(ramp(0)))
        assertFalse(SeedEntropy.healthy(ByteArray(32)))
        assertFalse(SeedEntropy.healthy(ByteArray(32) { -1 }))
        assertTrue(SeedEntropy.healthy(ByteArray(32) { if (it < SeedEntropy.MAX_REPEATS - 1) 7 else (100 + it).toByte() }))
        assertFalse(SeedEntropy.healthy(ByteArray(32) { if (it < SeedEntropy.MAX_REPEATS) 7 else (100 + it).toByte() }))
        // Spread out, not only in a run.
        assertFalse(SeedEntropy.healthy(ByteArray(32) { if (it % 4 == 0) 0x55 else (100 + it).toByte() }))
    }

    @Test fun badSourcesAreRefusedAndTheirBuffersWiped() {
        val stuck = Recording("stuck") { ByteArray(32) { 0x41 } }
        assertThrows(EntropyFailure::class.java) { Bip39.generate(12, listOf(stuck.source, counter("b").source)) }
        assertTrue(stuck.filled.all { b -> b.all { it == 0.toByte() } })

        val broken = SeedEntropy.Source("broken") { throw IOException("unreadable") }
        val good = counter("good")
        val failure = assertThrows(EntropyFailure::class.java) { Bip39.generate(12, listOf(good.source, broken)) }
        assertTrue(failure.message!!.contains("broken"))
        assertTrue("the first source's block is wiped when the second fails", good.filled.single().all { it == 0.toByte() })

        assertThrows(EntropyFailure::class.java) { Bip39.generate(12, listOf(Recording("x") { goldenA }.source, Recording("y") { goldenA }.source)) }

        val repeating = Recording("repeating") { goldenA }
        Bip39.generate(12, listOf(repeating.source, counter("b").source))
        val again = assertThrows(EntropyFailure::class.java) { Bip39.generate(12, listOf(repeating.source, counter("c").source)) }
        assertTrue(again.message!!.contains("previous block"))

        assertThrows(IllegalArgumentException::class.java) { Bip39.generate(12, listOf(counter("only").source)) }
        assertThrows(IllegalArgumentException::class.java) { Bip39.generate(15, listOf(counter("a").source, counter("b").source)) }
    }

    @Test fun generatedPhrasesWipeEveryBlock() {
        val a = counter("a"); val b = counter("b")
        repeat(5) { assertNull(Bip39.problem(Bip39.generate(24, listOf(a.source, b.source)))) }
        assertEquals(5, a.filled.size)
        assertTrue((a.filled + b.filled).all { block -> block.all { it == 0.toByte() } })
    }

    @Test fun unmixedEntropyIsDetected() {
        assertTrue(SeedEntropy.unmixed(listOf(goldenA, goldenB), goldenB.copyOf(16)))
        assertTrue(SeedEntropy.unmixed(listOf(goldenA, goldenB), goldenA.copyOf(32)))
        assertFalse(SeedEntropy.unmixed(listOf(goldenA, goldenB), SeedEntropy.mix(listOf(goldenA, goldenB), 16)))
        // A mixer that passes either source straight through must not produce a phrase.
        for (bypass in listOf<(List<ByteArray>, Int) -> ByteArray>({ blocks, n -> blocks[0].copyOf(n) }, { blocks, n -> blocks[1].copyOf(n) })) {
            val a = counter("a"); val b = counter("b")
            assertThrows(EntropyFailure::class.java) { Bip39.generate(12, listOf(a.source, b.source), bypass) }
            assertTrue((a.filled + b.filled).all { block -> block.all { it == 0.toByte() } })
        }
    }

    @Test fun systemSourcesAreCheckedWhereTheyComeFrom() {
        // Unit tests run on the desktop JVM, whose SecureRandom comes from the JDK's "SUN" provider; on a phone it must be Conscrypt.
        assertEquals("SUN", SeedEntropy.expectedProvider)
        assertEquals(32, SeedEntropy.secureRandomSource().read().size)
        assertTrue(assertThrows(EntropyFailure::class.java) { SeedEntropy.secureRandomSource("AndroidOpenSSL").read() }.message!!.contains("SUN"))
        assertEquals(32, SeedEntropy.deviceSource().read().size)
        assertThrows(EntropyFailure::class.java) { SeedEntropy.deviceSource("/nonexistent/urandom").read() }
        val short = File.createTempFile("short", ".bin").apply { writeBytes(ramp(0).copyOf(10)); deleteOnExit() }
        assertThrows(EntropyFailure::class.java) { SeedEntropy.deviceSource(short.path).read() }
        val zeros = File.createTempFile("zeros", ".bin").apply { writeBytes(ByteArray(64)); deleteOnExit() }
        assertThrows(EntropyFailure::class.java) { SeedEntropy.deviceSource(zeros.path).read() }
        assertEquals(listOf("SecureRandom", "/dev/urandom"), SeedEntropy.system.map { it.name })
    }

    /**
     * Catches a grossly broken generator (stuck bits, a short cycle, a counter): every bit position of the entropy is balanced and the
     * words are spread over the whole list. Bounds are 6 (each of 128 bits) and 8 (chi-square) standard deviations, so a working generator
     * fails less than once in a million runs.
     */
    @Test fun generatedPhrasesLookUniform() {
        val runs = 2000
        val ones = IntArray(128); val wordCounts = IntArray(2048); val seen = HashSet<String>()
        val index = Bip39.words.withIndex().associate { it.value to it.index }
        repeat(runs) {
            val words = Bip39.generate(12)
            assertTrue(seen.add(words.joinToString(" ")))
            val entropy = Bip39.toEntropy(words)!!
            for (bit in 0 until 128) if ((entropy[bit / 8].toInt() shr (7 - bit % 8)) and 1 == 1) ones[bit]++
            for (word in words) wordCounts[index.getValue(word)]++
        }
        val sigma = sqrt(runs * 0.25)
        for (bit in 0 until 128) assertTrue("bit $bit set ${ones[bit]} of $runs", abs(ones[bit] - runs / 2.0) <= 6 * sigma)
        val expected = runs * 12 / 2048.0
        val chiSquare = wordCounts.sumOf { (it - expected) * (it - expected) / expected }
        val df = 2047.0
        assertTrue("word chi-square $chiSquare", abs(chiSquare - df) <= 8 * sqrt(2 * df))
    }

    /**
     * Only SecureRandom and /dev/urandom may supply randomness. Coldcard's 2021 regression routed seeds to a non-cryptographic generator
     * without any test noticing; this fails the build if app code picks up one of those generators, seeds a SecureRandom, or installs a
     * security provider that could take over `SecureRandom()`.
     */
    @Test fun appCodeUsesNoWeakRandomness() {
        val banned = listOf(
            "java.util.Random", "kotlin.random", "Math.random", "ThreadLocalRandom", "SplittableRandom", "SHA1PRNG", "setSeed(",
            "SecureRandom.getInstance", "insertProviderAt", "addProvider(",
        )
        val sources = File("src").walkTopDown().filter { it.isFile && it.extension in setOf("kt", "java") && "/test/" !in it.path && "/androidTest/" !in it.path }.toList()
        assertTrue("found app sources", sources.any { it.name == "SeedEntropy.kt" })
        val hits = sources.flatMap { file -> file.readLines().withIndex().flatMap { (n, line) -> banned.filter { it in line }.map { "${file.path}:${n + 1}: $it" } } } +
            sources.flatMap { file -> Regex("""\bRandom\s*[(.]""").findAll(file.readText()).map { "${file.path}: ${it.value}" }.toList() } +
            // Kotlin's collection shuffle() and random() without an argument use kotlin.random's default generator.
            sources.flatMap { file -> Regex("""\.(random|shuffled|shuffle)\(\s*\)""").findAll(file.readText()).map { "${file.path}: ${it.value}" }.toList() } +
            sources.flatMap { file -> Regex("""SecureRandom\(\s*[^)\s]""").findAll(file.readText()).map { "${file.path}: seeded ${it.value}" }.toList() }
        assertEquals(emptyList<String>(), hits)
    }

    @Test fun generationStillValidatesAfterManyCalls() {
        for (count in Bip39.WORD_COUNTS) repeat(50) { val words = Bip39.generate(count); assertEquals(count, words.size); assertNull(Bip39.problem(words)) }
        assertNotNull(Bip39.problem(Bip39.split("abandon abandon abandon")))
    }
}
