package app.passvault

import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File

class FileRecoveryInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val output = File(context.cacheDir, "private-recovery-test-name.txt")
    private val source = FileVault(false, 42)
    private val journal = File(context.noBackupFilesDir, "passvault/file-recovery")
    @Before fun prepare() { FileRecovery(context).pending().forEach { FileRecovery(context).finish(it.id) }; output.writeBytes(byteArrayOf()) }
    @After fun clean() { FileRecovery(context).pending().forEach { FileRecovery(context).finish(it.id) }; output.delete() }

    @Test fun interruptedPlaintextIsRecoveredByANewInstance() {
        val first = FileRecovery(context)
        val id = first.begin(Uri.fromFile(output), source, true)
        output.writeText("synthetic partial plaintext")
        val disk = journal.readBytes().toString(Charsets.ISO_8859_1)
        assertFalse(disk.contains(output.name)); assertFalse(disk.contains("synthetic partial plaintext"))
        val restarted = FileRecovery(context)
        assertEquals(id, restarted.pending().single().id)
        assertEquals(source, restarted.pending().single().source)
        assertTrue(restarted.recover().isEmpty())
        assertTrue(!output.exists() || output.length() == 0L)
    }
    @Test fun completedOutputIsKeptAndFailedCleanupStaysDurableUntilAcknowledged() {
        val first = FileRecovery(context)
        val id = first.begin(Uri.fromFile(output), source, true)
        output.writeText("synthetic plaintext")
        val failed = FileRecovery(context).recover { false }.single()
        assertEquals(id, failed.id); assertTrue(failed.plaintext)
        assertEquals(id, FileRecovery(context).pending().single().id)
        FileRecovery(context).finish(id)
        assertTrue(FileRecovery(context).recover().isEmpty())
        assertEquals("synthetic plaintext", output.readText())
    }
    @Test fun malformedJournalRefusesNewOutputInsteadOfForgettingPendingCleanup() {
        val recovery = FileRecovery(context)
        recovery.begin(Uri.fromFile(output), source, true)
        val original = journal.readBytes()
        try {
            journal.writeBytes(original.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() })
            assertThrows(Exception::class.java) { FileRecovery(context).begin(Uri.fromFile(File(context.cacheDir, "another-output")), source, false) }
        } finally { journal.writeBytes(original) }
    }
}
