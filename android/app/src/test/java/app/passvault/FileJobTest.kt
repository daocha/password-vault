package app.passvault

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** [FileCrypt.guarded]: a complete output survives only if it is accepted. Each interleaving of a stop with the job's end. */
class FileJobTest {
    private class Probe(val removable: Boolean = true) { var discarded = 0; var accepted = 0; fun discard() = removable.also { discarded++ } }

    @Test fun successIsAcceptedAndKept() = runBlocking {
        val p = Probe()
        FileCrypt.guarded(Dispatchers.IO, { false }, p::discard, {}, { p.accepted++ })
        assertEquals(1, p.accepted); assertEquals(0, p.discarded)
    }

    @Test fun stopAfterTheJobsLastCheckDiscards() = runBlocking {
        val p = Probe(); var stopped = false
        // The job finishes writing, then the vault locks before the result is accepted.
        assertThrows(FileCrypt.Cancelled::class.java) { runBlocking { FileCrypt.guarded(Dispatchers.IO, { stopped }, p::discard, { stopped = true }, { p.accepted++ }) } }
        assertEquals(0, p.accepted); assertEquals(1, p.discarded)
    }

    @Test fun coroutineCancelledOnTheWayBackDiscards() = runBlocking {
        val p = Probe(); val inJob = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        // The activity is destroyed while the worker finishes: withContext then throws CancellationException on its way back.
        val run = async(Dispatchers.Default) { FileCrypt.guarded(Dispatchers.IO, { false }, p::discard, { inJob.complete(Unit); runBlocking { release.await() } }, { p.accepted++ }) }
        inJob.await(); run.cancel(); release.complete(Unit)
        assertThrows(CancellationException::class.java) { runBlocking { run.await() } }
        assertEquals(0, p.accepted); assertEquals(1, p.discarded)
    }

    @Test fun failedRemovalIsReported() = runBlocking {
        val p = Probe(removable = false); var stopped = false
        val e = assertThrows(FileCrypt.LeftBehind::class.java) { runBlocking { FileCrypt.guarded(Dispatchers.IO, { stopped }, p::discard, { stopped = true }, { p.accepted++ }) } }
        assertTrue(e.cause is FileCrypt.Cancelled); assertEquals(0, p.accepted)
    }

    @Test fun aFailedCleanupStillQueuesItsWarningWhenTheActivityIsDestroyed() = runBlocking {
        val notices = FileNotices(); val source = FileVault(false, 0)
        val inJob = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val run = async(Dispatchers.Default) {
            FileCrypt.guarded(Dispatchers.IO, { false }, {
                notices.add(source, "plaintext file could not be removed"); false
            }, { inJob.complete(Unit); runBlocking { release.await() } }, { fail("Destroyed activity cannot accept output") })
        }
        inJob.await(); run.cancel(); release.complete(Unit)
        assertThrows(CancellationException::class.java) { runBlocking { run.await() } }
        assertEquals(source, notices.pending.value.single().source)
        assertEquals("plaintext file could not be removed", notices.pending.value.single().text)
    }

    @Test fun jobFailuresAreLeftToTheJob() = runBlocking {
        // The job cleans up its own partial output (FileCrypt.write); nothing complete was written, so nothing more to discard.
        val p = Probe()
        assertThrows(IllegalStateException::class.java) { runBlocking { FileCrypt.guarded(Dispatchers.IO, { false }, p::discard, { error("damaged") }, { p.accepted++ }) } }
        assertEquals(0, p.discarded); assertEquals(0, p.accepted)
    }
}
