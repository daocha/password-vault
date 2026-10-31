package app.passvault

import android.content.SharedPreferences
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class VaultExportTest {
    private val key = FileKeys.record("key", "AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX", "")
    private val savedAt = Instant.parse("2026-10-31T00:00:00Z")
    private fun prepare(records: List<VaultRecord>, csv: Boolean = false, decoy: Boolean = false, snapshotAt: Instant = savedAt.minusSeconds(60)) =
        VaultExport.prepare(records, csv, decoy, Records::encode, snapshotAt = snapshotAt)

    @Test fun slowBackupKeepsItsSnapshotWhenAnotherExportIsCancelled() = runBlocking {
        val prefs = preferences()
        val first = prepare(listOf(key), decoy = true)
        val started = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>()
        var written = byteArrayOf()
        val saving = launch {
            try {
                withContext(Dispatchers.IO) { started.complete(Unit); finish.await(); written = first.bytes.copyOf() }
                first.recordBackup(prefs, savedAt)
            } finally { first.clear() }
        }
        started.await()
        val newerKey = FileKeys.record("newer", Age.generateIdentity().encoded, "")
        val current = listOf(key, newerKey)
        // Another backup is prepared with an extra key, then its picker is cancelled.
        prepare(current).clear()
        // A CSV export for the other vault must not change the first export's format or destination either.
        prepare(current, csv = true).clear()
        finish.complete(Unit); saving.join()

        assertEquals(listOf(key), Records.decode(written))
        val decoy = BackupStatus(prefs, "decoy.")
        assertEquals(savedAt, decoy.lastBackup)
        assertEquals(setOf(FileKeys.fingerprint(key.ageIdentity!!)), decoy.fileKeys)
        assertTrue("the key missing from the saved bytes still needs a backup", FileKeys.needsBackup(current, decoy.lastBackup, decoy.fileKeys))
        assertNull("the other vault's history is untouched", BackupStatus(prefs).lastBackup)
        assertTrue(first.bytes.all { it == 0.toByte() })
    }

    @Test fun weakPasswordWarningBelongsToItsOwnEncryptedExport() {
        val weak = VaultExport.prepare(listOf(key), csv = false, decoy = false, encode = Records::encode, weakPassword = true)
        val strong = prepare(listOf(key))
        // CSV has no password, so it never carries the warning.
        val csv = VaultExport.prepare(listOf(key), csv = true, decoy = false, encode = Records::encode, weakPassword = true)
        try { assertTrue(weak.weakPassword); assertFalse(strong.weakPassword); assertFalse(csv.weakPassword) } finally { weak.clear(); strong.clear(); csv.clear() }
    }

    @Test fun editsDuringSavingRemainUnbackedAfterTheBackupCompletes() {
        val prefs = preferences(); val status = BackupStatus(prefs)
        val cutoff = savedAt.minusSeconds(60)
        val before = VaultRecord(name = "login", updatedAt = cutoff.minusSeconds(1).toString(),
            fields = listOf(VaultField(kind = FieldKind.password, label = "Password", value = "old password")))
        val backup = prepare(listOf(before), snapshotAt = cutoff)
        val edited = before.copy(updatedAt = cutoff.plusSeconds(10).toString(), fields = before.fields.map { it.copy(value = "new password") })
        val added = VaultRecord(name = "added while saving", updatedAt = cutoff.plusSeconds(30).toString())
        try {
            backup.recordBackup(prefs, savedAt)
            assertEquals(listOf(before), Records.decode(backup.bytes))
            assertEquals(savedAt, status.lastBackup); assertEquals(cutoff, status.snapshotAt)
            assertEquals(2, BackupReminder.changedSince(listOf(edited, added), status.snapshotAt))
            assertTrue(BackupReminder.due(listOf(edited, added), status.lastBackup, BackupInterval.month, null,
                savedAt.plus(java.time.Duration.ofDays(40)), snapshotAt = status.snapshotAt))
        } finally { backup.clear() }
    }

    @Test fun aLegacyBackupWithoutACutoffCountsFromItsCompletion() {
        val prefs = preferences(); val status = BackupStatus(prefs)
        prefs.edit().putLong("lastBackupAt", savedAt.toEpochMilli()).apply()
        assertEquals(savedAt, status.snapshotAt)
        // Unchanged since that backup: no reminder after upgrading. Changed since: counted.
        val unchanged = listOf(VaultRecord(name = "backed up", updatedAt = savedAt.minusSeconds(1).toString()))
        assertEquals(0, BackupReminder.changedSince(unchanged, status.snapshotAt))
        assertFalse(BackupReminder.due(unchanged, status.lastBackup, BackupInterval.month, null, savedAt.plus(java.time.Duration.ofDays(40)), snapshotAt = status.snapshotAt))
        assertEquals(1, BackupReminder.changedSince(unchanged + VaultRecord(name = "new", updatedAt = savedAt.plusSeconds(1).toString()), status.snapshotAt))
    }

    @Test fun removingTheDecoyForgetsAllOfItsBackupHistory() {
        val prefs = preferences(); val decoy = BackupStatus(prefs, "decoy."); val main = BackupStatus(prefs)
        decoy.record(savedAt, setOf("decoy key")); decoy.interval = BackupInterval.week; decoy.snooze(savedAt)
        main.record(savedAt, setOf("main key"))
        decoy.clear()
        assertNull(decoy.lastBackup); assertNull(decoy.snapshotAt); assertNull(decoy.fileKeys); assertNull(decoy.snoozedUntil); assertEquals(BackupInterval.month, decoy.interval)
        assertEquals(savedAt, main.lastBackup); assertEquals(savedAt, main.snapshotAt); assertEquals(setOf("main key"), main.fileKeys)
    }

    @Test fun aBackupFinishingAfterItsVaultWasRemovedIsNotCredited() {
        val prefs = preferences(); val decoy = BackupStatus(prefs, "decoy.")
        val old = VaultExport.prepare(listOf(key), csv = false, decoy = true, encode = { ByteArray(1) }, instance = { BackupStatus(prefs, if (it) "decoy." else "").instance })
        // The decoy is removed (and perhaps created again) while that backup is still being written.
        decoy.clear()
        try { old.recordBackup(prefs, savedAt) } finally { old.clear() }
        assertNull(decoy.lastBackup); assertNull(decoy.snapshotAt); assertNull(decoy.fileKeys)
        // A backup of the new vault counts.
        val fresh = VaultExport.prepare(emptyList(), csv = false, decoy = true, encode = { ByteArray(1) }, instance = { BackupStatus(prefs, if (it) "decoy." else "").instance })
        try { fresh.recordBackup(prefs, savedAt) } finally { fresh.clear() }
        assertEquals(savedAt, decoy.lastBackup)
    }

    @Test fun csvDoesNotRecordBackupCoverage() {
        val prefs = preferences(); val status = BackupStatus(prefs)
        val before = savedAt.minusSeconds(60)
        status.record(before, setOf("previous"))
        val csv = prepare(listOf(key), csv = true)
        try { csv.recordBackup(prefs, savedAt) } finally { csv.clear() }
        assertEquals(before, status.lastBackup); assertEquals(before, status.snapshotAt); assertEquals(setOf("previous"), status.fileKeys)
    }

    @Test(timeout = 15000) fun backupCompletionCannotRaceVaultRemoval() {
        val readInstance = CountDownLatch(1); val finishRead = CountDownLatch(1); val cleared = CountDownLatch(1)
        val intercept = AtomicBoolean(true)
        val prefs = preferences { name ->
            if (name == "backupInstance" && intercept.compareAndSet(true, false)) {
                readInstance.countDown(); check(finishRead.await(5, TimeUnit.SECONDS))
            }
        }
        val status = BackupStatus(prefs)
        val failure = AtomicReference<Throwable?>()
        val writing = thread { try { status.record(savedAt, setOf("old key"), instance = 0L) } catch (e: Throwable) { failure.set(e) } }
        assertTrue(readInstance.await(5, TimeUnit.SECONDS))
        val removing = thread { try { status.clear(); cleared.countDown() } catch (e: Throwable) { failure.set(e) } }
        // Without a common lock, removal completes between the old backup's instance check and its metadata write.
        cleared.await(200, TimeUnit.MILLISECONDS)
        finishRead.countDown(); writing.join(5000); removing.join(5000)
        assertFalse(writing.isAlive); assertFalse(removing.isAlive)
        assertNull(failure.get())
        assertEquals(1L, status.instance)
        assertNull(status.lastBackup); assertNull(status.snapshotAt); assertNull(status.fileKeys)
    }

    @Test fun outOfOrderCompletionsTrackTheBytesOfTheLastSavedBackup() {
        val prefs = preferences(); val status = BackupStatus(prefs)
        val laterKey = FileKeys.record("later", Age.generateIdentity().encoded, "")
        val oldCutoff = savedAt.minusSeconds(120); val newCutoff = savedAt.minusSeconds(60)
        val old = prepare(listOf(key), snapshotAt = oldCutoff); val new = prepare(listOf(key, laterKey), snapshotAt = newCutoff)
        try {
            new.recordBackup(prefs, savedAt)
            assertEquals(newCutoff, status.snapshotAt)
            assertFalse(FileKeys.needsBackup(listOf(key, laterKey), status.lastBackup, status.fileKeys))
            old.recordBackup(prefs, savedAt.plusSeconds(1))
            assertEquals(oldCutoff, status.snapshotAt)
            val savedKeys = FileKeys.of(Records.decode(old.bytes)).map { FileKeys.fingerprint(it.ageIdentity!!) }.toSet()
            assertEquals(savedKeys, status.fileKeys)
            assertTrue(FileKeys.needsBackup(listOf(key, laterKey), status.lastBackup, status.fileKeys))
        } finally { old.clear(); new.clear() }
    }

    /** Minimal SharedPreferences double: each editor applies its staged changes together, as the Android API does. */
    private fun preferences(afterRead: (String) -> Unit = {}): SharedPreferences {
        val values = java.util.Collections.synchronizedMap(mutableMapOf<String, Any?>())
        return Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
            when (method.name) {
                "getLong", "getString", "getStringSet" -> (values[args!![0]] ?: args[1]).also { afterRead(args[0] as String) }
                "edit" -> {
                    val staged = mutableMapOf<String, Any?>()
                    Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { editor, operation, input ->
                        when (operation.name) {
                            "putLong", "putString", "putStringSet" -> { staged[input!![0] as String] = input[1]; editor }
                            "remove" -> { staged[input!![0] as String] = null; editor }
                            "apply" -> { values.putAll(staged); null }
                            else -> error("Unexpected preference edit: ${operation.name}")
                        }
                    }
                }
                else -> error("Unexpected preference read: ${method.name}")
            }
        } as SharedPreferences
    }
}
