package app.passvault

import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** age encryption through ContentResolver streams on Android's runtime (BouncyCastle's ML-KEM and ChaCha20 on ART, not the JVM). */
class FileCryptInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val directory = File(context.cacheDir, "filecrypt-test").apply { mkdirs() }
    @After fun clean() { directory.deleteRecursively() }

    @Test fun recognisesTheSameDocumentUnderDifferentUris() {
        val authority = "com.android.externalstorage.documents"
        val doc = android.provider.DocumentsContract.buildDocumentUri(authority, "primary:Download/report.pdf")
        // The same document reached through a tree grant has a different URI.
        val viaTree = android.provider.DocumentsContract.buildDocumentUriUsingTree(android.provider.DocumentsContract.buildTreeDocumentUri(authority, "primary:Download"), "primary:Download/report.pdf")
        assertTrue(FileCrypt.sameDocument(doc, doc)); assertTrue(FileCrypt.sameDocument(doc, viaTree))
        assertFalse(FileCrypt.sameDocument(doc, android.provider.DocumentsContract.buildDocumentUri(authority, "primary:Download/report.pdf.age")))
        assertFalse(FileCrypt.sameDocument(doc, android.provider.DocumentsContract.buildDocumentUri("other.provider", "primary:Download/report.pdf")))
        assertFalse(FileCrypt.sameDocument(Uri.fromFile(File("/a")), Uri.fromFile(File("/b"))))
    }

    @Test fun anUnwrittenSaveTargetIsKeptWhenItHasContent() {
        // The user picked an existing file to replace, then the job never started: the file must survive.
        val existing = File(directory, "backup.pvault").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        FileCrypt.discardUnwritten(context.contentResolver, Uri.fromFile(existing))
        assertArrayEquals(byteArrayOf(1, 2, 3), existing.readBytes())
    }

    @Test fun encryptsAndDecryptsLargeFiles() {
        val identity = Age.parseIdentity(Age.generateIdentity().encoded)
        val plain = File(directory, "plain.bin").apply { writeBytes(ByteArray(5 * Age.CHUNK + 123) { (it * 13).toByte() }) }
        val sealed = File(directory, "plain.bin.age"); val opened = File(directory, "opened.bin")
        var read = 0L
        FileCrypt.encrypt(context.contentResolver, Uri.fromFile(plain), Uri.fromFile(sealed), identity.recipient, { false }) { read = it }
        assertEquals(plain.length(), read)
        assertTrue(String(sealed.readBytes().copyOf(21)) == "age-encryption.org/v1")
        FileCrypt.check(context.contentResolver, Uri.fromFile(sealed), listOf(identity))
        FileCrypt.decrypt(context.contentResolver, Uri.fromFile(sealed), Uri.fromFile(opened), listOf(identity), { false }) {}
        assertArrayEquals(plain.readBytes(), opened.readBytes())
    }

    @Test fun failedOrCancelledOutputIsEmptied() {
        val identity = Age.generateIdentity()
        val plain = File(directory, "plain.bin").apply { writeBytes(ByteArray(3 * Age.CHUNK) { it.toByte() }) }
        val sealed = File(directory, "sealed.age")
        FileCrypt.encrypt(context.contentResolver, Uri.fromFile(plain), Uri.fromFile(sealed), identity.recipient, { false }) {}
        // Damage the last chunk: the first chunks decrypt and are written before the damage is found.
        val damaged = File(directory, "damaged.age").apply { writeBytes(sealed.readBytes().also { it[it.size - 5] = (it[it.size - 5].toInt() xor 1).toByte() }) }
        val out = File(directory, "out.bin")
        val e = assertThrows(AgeException::class.java) { FileCrypt.decrypt(context.contentResolver, Uri.fromFile(damaged), Uri.fromFile(out), listOf(identity), { false }) {} }
        assertEquals(AgeException.Kind.payload, e.kind)
        assertTrue("no plaintext left behind", !out.exists() || out.length() == 0L)
        val cancelled = File(directory, "cancelled.bin")
        assertThrows(FileCrypt.Cancelled::class.java) { FileCrypt.decrypt(context.contentResolver, Uri.fromFile(sealed), Uri.fromFile(cancelled), listOf(identity), { true }) {} }
        assertTrue(!cancelled.exists() || cancelled.length() == 0L)
        // A small file is read in full before any plaintext is written, so a stop that lands after the last read must still discard the output.
        val small = File(directory, "small.age"); File(directory, "small.bin").writeBytes(ByteArray(1000) { 7 })
        FileCrypt.encrypt(context.contentResolver, Uri.fromFile(File(directory, "small.bin")), Uri.fromFile(small), identity.recipient, { false }) {}
        val late = File(directory, "late.bin"); var stop = false
        assertThrows(FileCrypt.Cancelled::class.java) { FileCrypt.decrypt(context.contentResolver, Uri.fromFile(small), Uri.fromFile(late), listOf(identity), { stop }) { if (it >= small.length()) stop = true } }
        assertTrue("late stop leaves nothing", !late.exists() || late.length() == 0L)
        assertEquals(AgeException.Kind.noMatch, assertThrows(AgeException::class.java) { FileCrypt.check(context.contentResolver, Uri.fromFile(sealed), listOf(Age.generateIdentity())) }.kind)
    }
}
