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
        val old = FileKeys.record("old", identity, "").copy(updatedAt = "2026-01-01T00:00:00Z")
        val new = FileKeys.record("new", Age.generateIdentity().encoded, "").copy(updatedAt = "2026-06-01T00:00:00.5Z")
        assertEquals(listOf("new", "old"), FileKeys.of(listOf(old, VaultRecord(name = "x"), new)).map { it.name })
    }

    @Test fun backupWarningUntilBackedUpAfterTheNewestKey() {
        val key = FileKeys.record("k", identity, "").copy(updatedAt = "2026-06-01T00:00:00Z")
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
