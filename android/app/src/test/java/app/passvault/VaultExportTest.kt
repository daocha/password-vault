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

class VaultExportTest {
    private val key = FileKeys.record("key", "AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX", "")
    private val savedAt = Instant.parse("2026-10-31T00:00:00Z")
    private fun prepare(records: List<VaultRecord>, csv: Boolean = false, decoy: Boolean = false) = VaultExport.prepare(records, csv, decoy, Records::encode)

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

    @Test fun csvDoesNotRecordBackupCoverage() {
        val prefs = preferences(); val status = BackupStatus(prefs)
        val before = savedAt.minusSeconds(60)
        status.record(before, setOf("previous"))
        val csv = prepare(listOf(key), csv = true)
        try { csv.recordBackup(prefs, savedAt) } finally { csv.clear() }
        assertEquals(before, status.lastBackup); assertEquals(setOf("previous"), status.fileKeys)
    }

    @Test fun outOfOrderCompletionsTrackTheBytesOfTheLastSavedBackup() {
        val prefs = preferences(); val status = BackupStatus(prefs)
        val laterKey = FileKeys.record("later", Age.generateIdentity().encoded, "")
        val old = prepare(listOf(key)); val new = prepare(listOf(key, laterKey))
        try {
            new.recordBackup(prefs, savedAt)
            assertFalse(FileKeys.needsBackup(listOf(key, laterKey), status.lastBackup, status.fileKeys))
            old.recordBackup(prefs, savedAt.plusSeconds(1))
            val savedKeys = FileKeys.of(Records.decode(old.bytes)).map { FileKeys.fingerprint(it.ageIdentity!!) }.toSet()
            assertEquals(savedKeys, status.fileKeys)
            assertTrue(FileKeys.needsBackup(listOf(key, laterKey), status.lastBackup, status.fileKeys))
        } finally { old.clear(); new.clear() }
    }

    /** Minimal SharedPreferences double: each editor applies its staged changes together, as the Android API does. */
    private fun preferences(): SharedPreferences {
        val values = mutableMapOf<String, Any?>()
        return Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
            when (method.name) {
                "getLong", "getStringSet" -> values[args!![0]] ?: args[1]
                "edit" -> {
                    val staged = mutableMapOf<String, Any?>()
                    Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { editor, operation, input ->
                        when (operation.name) {
                            "putLong", "putStringSet" -> { staged[input!![0] as String] = input[1]; editor }
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
