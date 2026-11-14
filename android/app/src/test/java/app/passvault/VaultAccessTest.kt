package app.passvault

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class VaultAccessTest {
    @Test fun theDecryptedStateLastsOnlyUntilTheOutermostTransactionEnds() {
        val plain = byteArrayOf(1, 2, 3)
        VaultAccess.serialized {
            VaultAccess.serialized { VaultAccess.cachedState = plain }
            // A nested block ending does not end the transaction.
            assertArrayEquals(byteArrayOf(1, 2, 3), VaultAccess.serialized { VaultAccess.cachedState })
        }
        assertNull(VaultAccess.serialized { VaultAccess.cachedState })
        assertTrue("zeroed when the transaction ended", plain.all { it == 0.toByte() })
    }

    @Test fun aFailingTransactionAlsoForgetsAndZeroesIt() {
        val plain = byteArrayOf(4, 5)
        assertThrows(IllegalStateException::class.java) { VaultAccess.serialized { VaultAccess.cachedState = plain; error("failed") } }
        assertNull(VaultAccess.serialized { VaultAccess.cachedState })
        assertTrue(plain.all { it == 0.toByte() })
    }

    @Test fun replacingItZeroesTheOldCopy() {
        val old = byteArrayOf(7, 7); val new = byteArrayOf(8)
        VaultAccess.serialized {
            VaultAccess.cachedState = old; VaultAccess.cachedState = new
            assertTrue(old.all { it == 0.toByte() }); assertArrayEquals(byteArrayOf(8), VaultAccess.cachedState)
        }
    }
}
