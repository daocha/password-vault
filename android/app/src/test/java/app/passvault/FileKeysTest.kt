package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class FileKeysTest {
    private val identity = "AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX"

    @Test fun keyIsASecureNoteThatSurvivesBackups() {
        val key = FileKeys.record("File encryption key", identity, "note")
        assertEquals(RecordType.note, key.type); assertEquals(identity, key.ageIdentity)
        // Backups, transfers and other apps see an ordinary secure note.
        val decoded = Records.decode(Records.encode(listOf(key, VaultRecord(name = "Login"))))
        assertEquals(identity, decoded[0].ageIdentity); assertNull(decoded[1].ageIdentity)
        // Only a valid identity in the labelled password field of a note counts.
        assertNull(key.copy(type = RecordType.login).ageIdentity)
        assertNull(key.copy(fields = key.fields.map { if (it.label == AGE_KEY_LABEL) it.copy(value = "not a key") else it }).ageIdentity)
        assertNull(key.copy(fields = key.fields.map { if (it.label == AGE_KEY_LABEL) it.copy(kind = FieldKind.note) else it }).ageIdentity)
    }

    @Test fun newestKeyComesFirst() {
        val old = FileKeys.record("old", identity, "", Instant.parse("2026-01-01T00:00:00Z"))
        val new = FileKeys.record("new", Age.generateIdentity().encoded, "", Instant.parse("2026-06-01T00:00:00.5Z"))
        // An entry without the stamp (made by hand on another app) falls back to updatedAt.
        val unstamped = FileKeys.record("unstamped", Age.generateIdentity().encoded, "").copy(legacy = emptyMap(), updatedAt = "2026-03-01T00:00:00Z")
        assertEquals(listOf("new", "unstamped", "old"), FileKeys.of(listOf(old, VaultRecord(name = "x"), new, unstamped)).map { it.name })
    }

    @Test fun editingAnOldKeyDoesNotMakeItActive() {
        val old = FileKeys.record("old", identity, "", Instant.parse("2026-01-01T00:00:00Z"))
        val new = FileKeys.record("new", Age.generateIdentity().encoded, "", Instant.parse("2026-06-01T00:00:00Z"))
        // Moving the old key to a group (or any other edit) bumps updatedAt; the key added last stays active.
        val regrouped = old.copy(group = "Archive", updatedAt = "2026-09-01T00:00:00Z")
        assertEquals(listOf("new", "old"), FileKeys.of(listOf(regrouped, new)).map { it.name })
        // The stamp survives backups.
        assertEquals(listOf("new", "old"), FileKeys.of(Records.decode(Records.encode(listOf(regrouped, new)))).map { it.name })
        val backedUp = setOf(FileKeys.fingerprint(identity), FileKeys.fingerprint(new.ageIdentity!!))
        assertFalse(FileKeys.needsBackup(listOf(regrouped, new), Instant.parse("2026-07-01T00:00:00Z"), backedUp))
    }

    @Test fun unstampedKeysAreStampedBeforeAnEdit() {
        // Entries from the first build, or made by hand on iOS, have no stamp until the vault next loads them.
        val old = FileKeys.record("old", identity, "").copy(legacy = emptyMap(), updatedAt = "2026-01-01T00:00:00Z")
        val new = FileKeys.record("new", Age.generateIdentity().encoded, "", Instant.parse("2026-06-01T00:00:00Z"))
        val other = VaultRecord(name = "login")
        val stamped = FileKeys.stamp(listOf(old, new, other))
        assertEquals("2026-01-01T00:00:00Z", stamped[0].legacy[FileKeys.CREATED]); assertEquals("2026-01-01T00:00:00Z", stamped[0].updatedAt)
        assertSame(new, stamped[1]); assertSame(other, stamped[2])
        // Already stamped: the same list comes back, so nothing is saved.
        assertSame(stamped, FileKeys.stamp(stamped))
        val regrouped = stamped.map { if (it.name == "old") it.copy(group = "Archive", updatedAt = "2026-09-01T00:00:00Z") else it }
        assertEquals("new", FileKeys.of(regrouped).first().name)
    }

    @Test fun backupWarningFollowsTheSecretItself() {
        val key = FileKeys.record("k", identity, "", Instant.parse("2026-01-01T00:00:00Z"))
        val inBackup = setOf(FileKeys.fingerprint(identity))
        assertFalse(FileKeys.needsBackup(listOf(key), Instant.parse("2026-02-01T00:00:00Z"), inBackup))
        // The secret replaced in another app's editor: same entry, same creation stamp, not in the backup.
        val replaced = key.copy(fields = key.fields.map { if (it.label == AGE_KEY_LABEL) it.copy(value = Age.generateIdentity().encoded) else it })
        assertTrue(FileKeys.needsBackup(listOf(replaced), Instant.parse("2026-02-01T00:00:00Z"), inBackup))
        // Case and spacing do not change the fingerprint; it does not contain the key.
        assertEquals(FileKeys.fingerprint(identity), FileKeys.fingerprint(" " + identity.lowercase() + "\n"))
        assertEquals(32, FileKeys.fingerprint(identity).length); assertFalse(identity.contains(FileKeys.fingerprint(identity), ignoreCase = true))
    }

    @Test fun backupWarningUntilTheBackupHasKnownKeyCoverage() {
        val key = FileKeys.record("k", identity, "", Instant.parse("2026-06-01T00:00:00Z"))
        // A legacy backup's timestamp cannot prove that it held the current secret, even when the entry is older.
        assertFalse(FileKeys.needsBackup(emptyList(), null, null))
        assertTrue(FileKeys.needsBackup(listOf(key), null, null))
        assertTrue(FileKeys.needsBackup(listOf(key), Instant.parse("2026-05-31T00:00:00Z"), null))
        val lastBackup = Instant.parse("2026-06-02T00:00:00Z")
        assertTrue(FileKeys.needsBackup(listOf(key), lastBackup, null))
        val replaced = key.copy(updatedAt = "2026-09-01T00:00:00Z", fields = key.fields.map {
            if (it.label == AGE_KEY_LABEL) it.copy(value = Age.generateIdentity().encoded) else it
        })
        assertTrue(FileKeys.needsBackup(listOf(replaced), lastBackup, null))
        val tracked = setOf(FileKeys.fingerprint(replaced.ageIdentity!!))
        assertFalse(FileKeys.needsBackup(listOf(replaced), Instant.parse("2026-10-01T00:00:00Z"), tracked))
        assertTrue("fingerprints without a completed backup do not count", FileKeys.needsBackup(listOf(replaced), null, tracked))
    }

    @Test fun fileNames() {
        assertEquals("report.pdf.age", FileKeys.encryptedName("report.pdf")); assertEquals("file.age", FileKeys.encryptedName(null))
        assertEquals("report.pdf", FileKeys.decryptedName("report.pdf.age")); assertEquals("photo.jpg", FileKeys.decryptedName("photo.jpg.AGE"))
        assertEquals("notes.txt.decrypted", FileKeys.decryptedName("notes.txt")); assertEquals(".age.decrypted", FileKeys.decryptedName(".age"))
        assertEquals("file.decrypted", FileKeys.decryptedName(null))
    }
}
