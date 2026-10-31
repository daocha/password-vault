package app.passvault

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class FileOperationStateTest {
    @Test(timeout = 10000) fun cancellingKeepsTheOutputOwnedUntilCleanupFinishes() = runBlocking {
        val jobs = FileJobs(); val ticket = jobs.start()!!
        val writing = CompletableDeferred<Unit>(); val finishWriting = CompletableDeferred<Unit>()
        val cleaning = CompletableDeferred<Unit>(); val finishCleaning = CompletableDeferred<Unit>()
        var accepted = false
        val old = launch {
            try {
                FileCrypt.guarded(Dispatchers.IO, { ticket.cancelled }, {
                    cleaning.complete(Unit); runBlocking { finishCleaning.await() }; true
                }, { writing.complete(Unit); runBlocking { finishWriting.await() } }, { accepted = true })
                fail("The cancelled job must not succeed")
            } catch (_: FileCrypt.Cancelled) {
                // The output was removed before ownership is released.
            } finally { jobs.finish(ticket) }
        }
        writing.await()
        ticket.cancel() // A lock hides progress; a different session or activity may now try to start a job.
        assertTrue(jobs.running.value); assertNull(jobs.start())
        finishWriting.complete(Unit); cleaning.await()
        assertNull("A new output must not be opened while the old cleanup can still delete it", jobs.start())
        finishCleaning.complete(Unit); old.join()
        assertFalse(accepted); assertFalse(jobs.running.value)
        val next = jobs.start()!!
        // A stale completion cannot release the new job's ownership.
        jobs.finish(ticket); assertTrue(jobs.running.value); assertNull(jobs.start())
        jobs.finish(next); assertFalse(jobs.running.value)
    }

    @Test fun cleanupWarningsAccumulateAndStayUntilAcknowledgedInTheirVault() {
        val notices = FileNotices(); val real = FileVault(false, 0); val decoy = FileVault(true, 0)
        notices.add(real, "first plaintext file"); notices.add(decoy, "decoy file"); notices.add(real, "second plaintext file")
        // Opening the decoy neither consumes nor reveals either real-vault warning.
        val decoyWarning = notices.pending.value.single { it.source == decoy }
        notices.acknowledge(decoyWarning)
        assertEquals(listOf("first plaintext file", "second plaintext file"), notices.pending.value.filter { it.source == real }.map { it.text })
        // Re-reading (including after a lock or another save) does not consume a warning.
        val first = notices.pending.value.first { it.source == real }
        assertSame(first, notices.pending.value.first { it.source == real })
        notices.acknowledge(first)
        assertEquals("second plaintext file", notices.pending.value.single().text)
    }

    @Test(timeout = 10000) fun backupWritesAndUnwrittenCleanupWaitForTheCurrentOutputOwner() = runBlocking {
        val jobs = FileJobs(); val ticket = jobs.start()!!; val order = mutableListOf<String>()
        val backup = async(start = CoroutineStart.UNDISPATCHED) { jobs.withOutput { order += "backup" } }
        val cleanup = async(start = CoroutineStart.UNDISPATCHED) { jobs.withOutput { order += "unwritten cleanup" } }
        ticket.cancel()
        assertTrue(order.isEmpty()); assertFalse(backup.isCompleted); assertFalse(cleanup.isCompleted)
        order += "old cleanup"; jobs.finish(ticket)
        backup.await(); cleanup.await()
        assertEquals("old cleanup", order.first())
        assertEquals(setOf("old cleanup", "backup", "unwritten cleanup"), order.toSet())
        assertFalse(jobs.running.value)
    }

    @Test(timeout = 10000) fun cancellingAWaitingWriterDoesNotTakeOwnershipOrWrite() = runBlocking {
        val jobs = FileJobs(); val ticket = jobs.start()!!; var wrote = false
        val waiting = launch(start = CoroutineStart.UNDISPATCHED) { jobs.withOutput { wrote = true } }
        waiting.cancel(); jobs.finish(ticket); waiting.join()
        assertFalse(wrote); assertFalse(jobs.running.value)
        jobs.finish(jobs.start()!!)
    }

    @Test fun aRecreatedVaultNeverSeesWarningsFromItsPredecessor() {
        val notices = FileNotices(); val old = FileVault(true, 0); val fresh = FileVault(true, 1)
        notices.add(old, "old decoy file"); notices.add(FileVault(false, 0), "real file")
        notices.forgetBefore(fresh)
        // A provider can finish cleanup long after the source decoy has been removed.
        notices.add(old, "late old decoy file"); notices.add(fresh, "new decoy file")
        assertEquals(listOf("real file", "new decoy file"), notices.pending.value.map { it.text })
        notices.forgetBefore(old) // A stale caller cannot move the accepted instance backwards.
        notices.add(old, "another stale file")
        assertEquals(2, notices.pending.value.size)
    }
}
