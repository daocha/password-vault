package app.passvault

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.FileNotFoundException

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

    @Test fun recognisesTheSameFileReachedThroughDifferentAuthorities() {
        val source = File(directory, "report.pdf").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val firstAuthority = "app.passvault.test.first"; val otherAuthority = "app.passvault.test.other"
        val from = DocumentsContract.buildDocumentUri(firstAuthority, "source")
        val to = DocumentsContract.buildDocumentUri(otherAuthority, "existing")
        // Two authorities and document ids open the same underlying file. No hard links (which Android's app policy can prohibit).
        val provider = WriteRefusingProvider(source, source, false)
        provider.attachInfo(context, ProviderInfo().apply { authority = "$firstAuthority;$otherAuthority" })
        val resolver = ContentResolver.wrap(provider)
        assertFalse(FileCrypt.sameDocument(from, to)); assertTrue(FileCrypt.sameFile(resolver, from, to))
        val distinct = WriteRefusingProvider(source, File(directory, "other.pdf").apply { writeBytes(byteArrayOf(1)) }, false)
        distinct.attachInfo(context, ProviderInfo().apply { authority = "$firstAuthority;$otherAuthority" })
        assertFalse(FileCrypt.sameFile(ContentResolver.wrap(distinct), from, to))
        // Encrypting onto it refuses before truncating: the source is untouched.
        assertThrows(FileCrypt.SameFile::class.java) {
            FileCrypt.encrypt(resolver, from, to, Age.generateIdentity().recipient, { false }) {}
        }
        assertEquals(0, provider.writeAttempts)
        assertArrayEquals(byteArrayOf(1, 2, 3), source.readBytes())
    }

    @Test fun anUnwrittenSaveTargetIsKeptWhenItHasContent() {
        // The user picked an existing file to replace, then the job never started: the file must survive.
        val existing = File(directory, "backup.pvault").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        FileCrypt.discardUnwritten(context.contentResolver, Uri.fromFile(existing))
        assertArrayEquals(byteArrayOf(1, 2, 3), existing.readBytes())
    }

    @Test fun failingToOpenAnExistingTargetDoesNotDeleteIt() {
        val source = File(directory, "source.bin").apply { writeBytes(byteArrayOf(4, 5, 6)) }
        val identity = Age.generateIdentity()
        // Providers can fail by throwing or by returning null. Neither encryption nor decryption owns the destination yet.
        for (nullOnWrite in listOf(false, true)) for (decrypting in listOf(false, true)) {
            val original = byteArrayOf(1, 2, 3)
            val target = File(directory, "existing.bin").apply { writeBytes(original) }
            val provider = WriteRefusingProvider(source, target, nullOnWrite)
            val authority = "app.passvault.test.documents"
            provider.attachInfo(context, ProviderInfo().apply { this.authority = authority })
            val resolver = ContentResolver.wrap(provider)
            val uri = DocumentsContract.buildDocumentUri(authority, "existing")
            val sourceUri = DocumentsContract.buildDocumentUri(authority, "source")
            val process = {
                if (decrypting) FileCrypt.decrypt(resolver, sourceUri, uri, listOf(identity), { false }) {}
                else FileCrypt.encrypt(resolver, sourceUri, uri, identity.recipient, { false }) {}
            }
            assertThrows(FileCrypt.UnsafeTarget::class.java) { process() }
            assertEquals(0, provider.writeAttempts)
            assertEquals(0, provider.deletions)
            assertArrayEquals(original, target.readBytes())
            // Deletion is supported even though opening for writing is refused: the old cleanup would have destroyed this file.
            assertTrue(FileCrypt.delete(resolver, uri))
            assertEquals(1, provider.deletions)
            assertFalse(target.exists())
            // A new, empty document created by the save picker still gets cleaned up when opening fails.
            target.writeBytes(byteArrayOf())
            assertThrows(FileNotFoundException::class.java) { process() }
            assertEquals(1, provider.writeAttempts)
            assertEquals(2, provider.deletions)
            assertFalse(target.exists())
        }
    }

    @Test fun cancellingBeforeOpeningKeepsAnExistingTarget() {
        val target = File(directory, "existing.bin").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        assertThrows(FileCrypt.Cancelled::class.java) {
            FileCrypt.encrypt(context.contentResolver, Uri.fromFile(File(directory, "unused.bin")), Uri.fromFile(target), Age.generateIdentity().recipient, { true }) {}
        }
        assertArrayEquals(byteArrayOf(1, 2, 3), target.readBytes())
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

    @Test fun recoveryMustBeRecordedBeforeAnyPlaintextIsWritten() {
        val identity = Age.generateIdentity()
        val plain = File(directory, "before-journal.bin").apply { writeText("synthetic secret") }
        val sealed = File(directory, "before-journal.age")
        FileCrypt.encrypt(context.contentResolver, Uri.fromFile(plain), Uri.fromFile(sealed), identity.recipient, { false }) {}
        val out = File(directory, "journal-refused.bin")
        assertThrows(java.io.IOException::class.java) {
            FileCrypt.decrypt(context.contentResolver, Uri.fromFile(sealed), Uri.fromFile(out), listOf(identity), { false },
                { throw java.io.IOException("Recovery journal unavailable") }) {}
        }
        assertTrue(!out.exists() || out.length() == 0L)
    }

    @Test fun aProviderIgnoringTruncationIsNotReportedAsCleaned() {
        val file = File(directory, "provider-kept-plaintext.bin").apply { writeText("synthetic plaintext") }
        val authority = "app.passvault.test.ignore-truncation"
        val provider = WriteRefusingProvider(file, file, false, ignoreTruncation = true)
        provider.attachInfo(context, ProviderInfo().apply { this.authority = authority })
        val uri = DocumentsContract.buildDocumentUri(authority, "existing")
        assertFalse(FileCrypt.discard(ContentResolver.wrap(provider), uri))
        assertEquals("synthetic plaintext", file.readText())
    }

    @Test fun aStreamedAliasCannotDestroyTheSource() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.cacheDir, "encryption-review-alias.bin")
        val original = ByteArray(4096) { (it % 251 + 1).toByte() }
        file.writeBytes(original)
        try {
            val provider = object : ContentProvider() {
                override fun onCreate() = true
                override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
                    if (DocumentsContract.getDocumentId(uri) == "streamed-source") {
                        check(mode == "r")
                        val snapshot = file.readBytes()
                        val pipe = ParcelFileDescriptor.createPipe()
                        Thread {
                            try { ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { it.write(snapshot) } }
                            catch (_: java.io.IOException) { }
                        }.start()
                        return pipe[0]
                    }
                    return ParcelFileDescriptor.open(file, ParcelFileDescriptor.parseMode(mode))
                }
                override fun getType(uri: Uri) = "application/octet-stream"
                override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
                override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
                override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
                override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
            }
            val first = "app.passvault.review.stream"
            val second = "app.passvault.review.local"
            provider.attachInfo(context, ProviderInfo().apply { authority = "$first;$second" })
            val resolver = ContentResolver.wrap(provider)
            val source = DocumentsContract.buildDocumentUri(first, "streamed-source")
            val target = DocumentsContract.buildDocumentUri(second, "local-target")
            assertFalse(FileCrypt.sameDocument(source, target))
            assertFalse(FileCrypt.sameFile(resolver, source, target))
            val identity = Age.generateIdentity()
            assertThrows(FileCrypt.UnsafeTarget::class.java) {
                FileCrypt.encrypt(resolver, source, target, identity.recipient, { false }) {}
            }
            assertArrayEquals(original, file.readBytes())
            assertThrows(FileCrypt.UnsafeTarget::class.java) {
                FileCrypt.decrypt(resolver, source, target, listOf(identity), { false }) {}
            }
            assertArrayEquals(original, file.readBytes())
        } finally { file.delete() }
    }

    /** A provider that can read and delete its document, but cannot open it for writing (permissions, quota or a transient failure). */
    private class WriteRefusingProvider(private val source: File, private val file: File, private val nullOnWrite: Boolean, private val ignoreTruncation: Boolean = false) : ContentProvider() {
        var writeAttempts = 0
        var deletions = 0
        override fun onCreate() = true
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
            if (DocumentsContract.getDocumentId(uri) == "source") {
                check(mode == "r")
                return ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
            }
            if (mode != "r") {
                writeAttempts++
                if (ignoreTruncation) return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_WRITE_ONLY)
                if (nullOnWrite) return null
                throw FileNotFoundException("Cannot open destination for writing.")
            }
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
            check(method == "android:deleteDocument")
            if (ignoreTruncation) throw UnsupportedOperationException("Deletion is not supported")
            deletions++; check(file.delete())
            return Bundle()
        }
        override fun getType(uri: Uri) = "application/octet-stream"
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
    }
}
