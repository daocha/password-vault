package app.passvault

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.security.SecureRandom

/** On a real Android runtime: SecureRandom comes from Conscrypt, /dev/urandom is readable, and phrases are generated from both. */
@RunWith(AndroidJUnit4::class)
class SeedEntropyInstrumentedTest {
    @Test fun phrasesComeFromConscryptAndTheKernel() {
        assertEquals("AndroidOpenSSL", SeedEntropy.expectedProvider)
        assertEquals("AndroidOpenSSL", SecureRandom().provider.name)
        assertEquals(SeedEntropy.BLOCK, SeedEntropy.secureRandomSource().read().size)
        assertEquals(SeedEntropy.BLOCK, SeedEntropy.deviceSource().read().size)
        val seen = HashSet<String>()
        for (count in Bip39.WORD_COUNTS) repeat(100) {
            val words = Bip39.generate(count)
            assertEquals(count, words.size)
            assertNull(Bip39.problem(words))
            assertTrue(seen.add(words.joinToString(" ")))
        }
    }
}
