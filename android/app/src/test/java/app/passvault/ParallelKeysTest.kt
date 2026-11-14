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

    @Test fun anInterruptStillWaitsForTheOtherKeyAndIsKeptForTheCaller() {
        val release = java.util.concurrent.CountDownLatch(1)
        val (a, b) = bothKeys({ Thread.currentThread().interrupt(); release.countDown(); byteArrayOf(1) },
            { release.await(5, TimeUnit.SECONDS); Thread.sleep(50); byteArrayOf(2) })
        assertArrayEquals(byteArrayOf(1), a); assertArrayEquals(byteArrayOf(2), b)
        assertTrue("the interrupt is restored", Thread.interrupted())
    }

    @Test fun timingSaysWhereTheTimeWent() {
        assertEquals("Password unlock 1500 ms: password hashing 1100 ms, protected state 300 ms (3 reads, 2 writes, key in StrongBox), vault file 100 ms",
            UnlockTiming(false, 1500, 1100, 0, 300, 3, 2, "StrongBox").toString())
        assertEquals("Biometric unlock 400 ms: biometric key 150 ms, protected state 200 ms (2 reads, 0 writes, key in TEE), vault file 50 ms",
            UnlockTiming(true, 400, 0, 150, 200, 2, 0, "TEE").toString())
    }
}
