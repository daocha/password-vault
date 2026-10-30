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
        assertFalse(FileKeys.needsBackup(listOf(regrouped, new), Instant.parse("2026-07-01T00:00:00Z")))
    }

    @Test fun backupWarningUntilBackedUpAfterTheNewestKey() {
        val key = FileKeys.record("k", identity, "", Instant.parse("2026-06-01T00:00:00Z"))
        assertFalse(FileKeys.needsBackup(emptyList(), null))
        assertTrue(FileKeys.needsBackup(listOf(key), null))
        assertTrue(FileKeys.needsBackup(listOf(key), Instant.parse("2026-05-31T00:00:00Z")))
        assertFalse(FileKeys.needsBackup(listOf(key), Instant.parse("2026-06-02T00:00:00Z")))
    }

    @Test fun fileNames() {
        assertEquals("report.pdf.age", FileKeys.encryptedName("report.pdf")); assertEquals("file.age", FileKeys.encryptedName(null))
        assertEquals("report.pdf", FileKeys.decryptedName("report.pdf.age")); assertEquals("photo.jpg", FileKeys.decryptedName("photo.jpg.AGE"))
        assertEquals("notes.txt.decrypted", FileKeys.decryptedName("notes.txt")); assertEquals(".age.decrypted", FileKeys.decryptedName(".age"))
        assertEquals("file.decrypted", FileKeys.decryptedName(null))
    }
}
