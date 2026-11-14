package app.passvault

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ParallelKeysTest {
    @Test fun bothDerivationsRunAtTheSameTime() {
        // Each side waits for the other: run one after the other, they would time out instead.
        val barrier = CyclicBarrier(2)
        val (a, b) = bothKeys({ barrier.await(5, TimeUnit.SECONDS); byteArrayOf(1) }, { barrier.await(5, TimeUnit.SECONDS); null })
        assertArrayEquals(byteArrayOf(1), a); assertNull(b)
    }

    @Test fun aDerivationThatRanShortOfMemoryRunsAgainAlone() {
        val mainRuns = AtomicInteger(); val sideRuns = AtomicInteger()
        val (a, b) = bothKeys({ if (mainRuns.incrementAndGet() == 1) error("Not enough memory to derive the vault key.") else byteArrayOf(1) },
            { if (sideRuns.incrementAndGet() == 1) error("Not enough memory to derive the vault key.") else byteArrayOf(2) })
        assertArrayEquals(byteArrayOf(1), a); assertArrayEquals(byteArrayOf(2), b)
        assertEquals(2, mainRuns.get()); assertEquals(2, sideRuns.get())
    }

    @Test fun whenOneKeepsFailingTheOtherKeyIsZeroed() {
        val sideKey = byteArrayOf(7, 7, 7)
        assertThrows(IllegalStateException::class.java) { bothKeys({ error("still failing") }, { sideKey }) }
        assertTrue(sideKey.all { it == 0.toByte() })
        val mainKey = byteArrayOf(9, 9)
        assertThrows(IllegalStateException::class.java) { bothKeys({ mainKey }, { error("still failing") }) }
        assertTrue(mainKey.all { it == 0.toByte() })
    }

    @Test fun timingSaysWhereTheTimeWent() {
        assertEquals("Unlock took 1500 ms: password hashing 1200 ms, Keystore and files 300 ms", UnlockTiming(1500, 1200).toString())
    }
}
