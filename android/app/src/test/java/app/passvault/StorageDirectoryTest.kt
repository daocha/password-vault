package app.passvault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class StorageDirectoryTest {
    /**
     * On first launch MainActivity opens the engine and file recovery on two threads, and both create the storage directory. The one that
     * loses the race used to fail, which showed "An interrupted file could not be checked" on a device with no interrupted file.
     */
    @Test fun creatingTheDirectoryFromManyThreadsAtOnceAlwaysSucceeds() {
        val root = Files.createTempDirectory("pv-dir").toFile()
        val pool = Executors.newFixedThreadPool(8)
        try {
            repeat(50) { round ->
                val target = File(root, "round-$round/passvault")
                val start = CountDownLatch(1)
                val results = (1..8).map { pool.submit<Result<File>> { start.await(); runCatching { ensureDirectory(target) } } }
                start.countDown()
                results.forEach { val result = it.get(10, TimeUnit.SECONDS); assertTrue(result.exceptionOrNull()?.toString(), result.isSuccess) }
                assertTrue(target.isDirectory)
            }
        } finally { pool.shutdownNow(); root.deleteRecursively() }
    }

    @Test fun anExistingDirectoryIsKeptAndAFileInTheWayIsRefused() {
        val root = Files.createTempDirectory("pv-dir").toFile()
        try {
            val existing = File(root, "passvault").apply { mkdirs() }
            File(existing, "state").writeText("kept")
            assertEquals(existing, ensureDirectory(existing))
            assertEquals("kept", File(existing, "state").readText())
            val blocked = File(root, "blocked").apply { writeText("not a directory") }
            assertThrows(IllegalStateException::class.java) { ensureDirectory(blocked) }
        } finally { root.deleteRecursively() }
    }
}
