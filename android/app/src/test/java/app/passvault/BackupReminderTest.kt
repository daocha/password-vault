package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.time.Duration
import java.time.Instant

class BackupReminderTest {
    private val now = Instant.parse("2026-10-25T12:00:00Z")
    private fun record(updated: Instant) = VaultRecord(updatedAt = updated.toString())
    @Test fun dueRules() {
        val old = now.minus(Duration.ofDays(40)); val recent = now.minus(Duration.ofDays(2))
        val records = listOf(record(old), record(recent))
        assertFalse("empty vault", BackupReminder.due(emptyList(), null, BackupInterval.month, null, now))
        assertTrue("never backed up", BackupReminder.due(records, null, BackupInterval.month, null, now))
        assertFalse("reminders off", BackupReminder.due(records, null, BackupInterval.off, null, now))
        assertFalse("snoozed", BackupReminder.due(records, null, BackupInterval.month, now.plusSeconds(60), now))
        assertTrue("snooze over", BackupReminder.due(records, null, BackupInterval.month, now.minusSeconds(60), now))
        val backup = now.minus(Duration.ofDays(31))
        assertTrue("month passed, changes since", BackupReminder.due(records, backup, BackupInterval.month, null, now))
        assertFalse("month passed, nothing changed", BackupReminder.due(listOf(record(old)), backup, BackupInterval.month, null, now))
        assertFalse("interval not reached", BackupReminder.due(records, now.minus(Duration.ofDays(10)), BackupInterval.month, null, now))
        assertTrue("weekly", BackupReminder.due(records, now.minus(Duration.ofDays(8)), BackupInterval.week, null, now))
    }
    @Test fun changedSinceCountsEditsAfterTheBackup() {
        val backup = now.minus(Duration.ofDays(5))
        val records = listOf(record(now.minus(Duration.ofDays(6))), record(now.minus(Duration.ofDays(1))), VaultRecord(updatedAt = "not a date"))
        assertEquals(2, BackupReminder.changedSince(records, backup))
        assertEquals(3, BackupReminder.changedSince(records, null))
    }

    @Test fun theSnapshotFindsChangesButCompletionTimeSetsTheReminderInterval() {
        val completed = now.minus(Duration.ofDays(31))
        val cutoff = completed.minusSeconds(60)
        val editedDuringSaving = listOf(record(completed.minusSeconds(30)))
        assertTrue(BackupReminder.due(editedDuringSaving, completed, BackupInterval.month, null, now, snapshotAt = cutoff))
        assertFalse(BackupReminder.due(editedDuringSaving, now.minus(Duration.ofDays(2)), BackupInterval.month, null, now, snapshotAt = cutoff))
        assertFalse(BackupReminder.due(listOf(record(cutoff.minusSeconds(1))), completed, BackupInterval.month, null, now, snapshotAt = cutoff))
    }
}
