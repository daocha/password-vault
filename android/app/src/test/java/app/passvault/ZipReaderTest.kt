package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class ZipReaderTest {
    private val text = "test-only export".toByteArray()
    private fun archive(stored: Boolean = false, ignored: Boolean = false, payload: ByteArray = text): ByteArray =
        ByteArrayOutputStream().also { out -> ZipOutputStream(out).use { zip ->
            if (ignored) {
                zip.putNextEntry(ZipEntry("files/unused"))
                val block = ByteArray(65536)
                repeat(512) { zip.write(block) } // 32 MiB, larger than the record limit; must never be inflated.
                zip.closeEntry()
            }
            val entry = ZipEntry("export.data")
            if (stored) {
                entry.method = ZipEntry.STORED; entry.size = payload.size.toLong()
                entry.crc = CRC32().apply { update(payload) }.value
            }
            zip.putNextEntry(entry); zip.write(payload); zip.closeEntry()
            zip.setComment("A ZIP comment containing PK\u0005\u0006")
        } }.toByteArray()

    @Test fun storedAndDeflatedExportsStillReadWithCommentsAndDataDescriptors() {
        for (stored in listOf(false, true)) assertArrayEquals(text, ZipReader.entry(archive(stored), "export.data"))
    }

    @Test fun unrelatedLargeEntriesAreNeverInflated() {
        val zip = archive(ignored = true)
        assertArrayEquals(text, ZipReader.entry(zip, "export.data"))
        // A reserved DEFLATE block in the ignored entry proves the reader does not try to decompress it.
        val body = 30 + "files/unused".toByteArray().size
        zip[body] = 7
        assertArrayEquals(text, ZipReader.entry(zip, "export.data"))
        assertNull(ZipReader.entry(zip, "missing"))
    }

    @Test fun oversizedSelectedEntryIsRejectedEvenWhenItsDirectorySizeLies() {
        val zip = archive(payload = ByteArray(Records.MAX_BYTES + 1))
        assertThrows(IllegalArgumentException::class.java) { ZipReader.entry(zip, "export.data") }
        val central = (0..zip.size - 4).first { zip[it] == 0x50.toByte() && zip[it + 1] == 0x4b.toByte() && zip[it + 2] == 1.toByte() && zip[it + 3] == 2.toByte() }
        repeat(4) { zip[central + 24 + it] = 0 }
        assertThrows(IllegalArgumentException::class.java) { ZipReader.entry(zip, "export.data") }
    }

    @Test fun damagedSelectedEntryAndMalformedDirectoryAreRejected() {
        val zip = archive()
        val damaged = zip.copyOf().also { it[30 + "export.data".length] = 7 }
        assertEquals(ZipReader.DAMAGED, assertThrows(IllegalArgumentException::class.java) { ZipReader.entry(damaged, "export.data") }.message)
        assertThrows(IllegalArgumentException::class.java) { ZipReader.entry(zip.copyOf(20), "export.data") }
        val invalidOffset = zip.copyOf()
        val end = zip.size - 22 - "A ZIP comment containing PK\u0005\u0006".toByteArray().size
        repeat(4) { invalidOffset[end + 16 + it] = 0x7f }
        assertThrows(IllegalArgumentException::class.java) { ZipReader.entry(invalidOffset, "export.data") }
    }

    // The same damaged archives as iOS's ZipReaderTests, made from fixtures/exports/sample.1pux: both readers must
    // accept or refuse each one with the same message.
    private fun fixture(name: String) = java.io.File("../../fixtures/exports/$name").readBytes()
    private fun u16(z: ByteArray, o: Int) = (z[o].toInt() and 255) or ((z[o + 1].toInt() and 255) shl 8)
    private fun u32(z: ByteArray, o: Int) = u16(z, o) or (u16(z, o + 2) shl 16)
    private fun put32(z: ByteArray, o: Int, v: Int) { for (i in 0 until 4) z[o + i] = (v shr (8 * i)).toByte() }
    private fun end(z: ByteArray) = z.size - 22 // sample.1pux has no comment
    /** Offset of export.data's central directory record. */
    private fun central(z: ByteArray): Int {
        var pos = u32(z, end(z) + 16)
        while (String(z, pos + 46, u16(z, pos + 28), Charsets.UTF_8) != "export.data") pos += 46 + u16(z, pos + 28) + u16(z, pos + 30) + u16(z, pos + 32)
        return pos
    }
    private fun refused(z: ByteArray, message: String) =
        assertEquals(message, assertThrows(IllegalArgumentException::class.java) { ZipReader.entry(z, "export.data") }.message)

    @Test fun readsTheSharedFixtureAndChecksItsCrc() {
        val zip = fixture("sample.1pux")
        val data = ZipReader.entry(zip, "export.data")!!
        assertEquals(1475, data.size)
        assertEquals(u32(zip, central(zip) + 16).toLong() and 0xFFFFFFFFL, CRC32().apply { update(data) }.value)
        assertNull(ZipReader.entry(zip, "missing"))
        assertNotNull(ZipReader.entry(fixture("skipped-attachment.1pux"), "export.data"))
    }

    @Test fun aSignatureInsideTheCommentIsNotTheEndRecord() {
        val comment = "PK\u0005\u0006".toByteArray() + ByteArray(30) { 'x'.code.toByte() }
        val original = fixture("sample.1pux"); val at = end(original)
        val zip = original + comment; zip[at + 20] = comment.size.toByte()
        assertEquals(1475, ZipReader.entry(zip, "export.data")!!.size)
        // A comment length that does not reach the end of the file leaves no valid end record.
        zip[at + 20] = (comment.size - 1).toByte()
        refused(zip, ZipReader.DAMAGED)
    }

    @Test fun wrongCrcOrSizeIsDamaged() {
        val zip = fixture("sample.1pux"); val c = central(zip)
        refused(zip.copyOf().also { it[c + 16] = (it[c + 16].toInt() xor 1).toByte() }, ZipReader.DAMAGED)
        refused(zip.copyOf().also { put32(it, c + 24, 1474) }, ZipReader.DAMAGED)
    }

    @Test fun declaredSizeOverTheLimitIsTooLarge() {
        val zip = fixture("sample.1pux"); put32(zip, central(zip) + 24, Records.MAX_BYTES + 1)
        refused(zip, ZipReader.TOO_LARGE)
    }

    @Test fun encryptedEntriesAndOtherMethodsAreUnsupported() {
        val zip = fixture("sample.1pux"); val c = central(zip)
        refused(zip.copyOf().also { it[c + 8] = (it[c + 8].toInt() or 1).toByte() }, ZipReader.UNSUPPORTED)
        refused(zip.copyOf().also { it[c + 10] = 12 }, ZipReader.UNSUPPORTED)
    }

    @Test fun damagedDeflateStreamAndDirectoryAreDamaged() {
        val zip = fixture("sample.1pux"); val c = central(zip); val local = u32(zip, c + 42)
        refused(zip.copyOf().also { it[local + 30 + u16(zip, local + 26) + u16(zip, local + 28)] = 7 }, ZipReader.DAMAGED) // reserved block type
        refused(zip.copyOf().also { put32(it, end(zip) + 16, end(zip) + 1) }, ZipReader.DAMAGED)
        refused(zip.copyOf(20), ZipReader.DAMAGED)
        refused(zip.copyOf().also { it[end(zip) + 4] = 1 }, ZipReader.DAMAGED)
    }

    // The local header (and data descriptor) must agree with the central directory, as in iOS's ZipReaderTests.
    private fun local(z: ByteArray) = u32(z, central(z) + 42)
    private fun dataStart(z: ByteArray) = local(z) + 30 + u16(z, local(z) + 26) + u16(z, local(z) + 28)
    private fun ByteArray.xor(o: Int, bits: Int) = copyOf().also { it[o] = (it[o].toInt() xor bits).toByte() }

    @Test fun aLocalHeaderThatDisagreesWithTheDirectoryIsDamaged() {
        val zip = fixture("sample.1pux"); val l = local(zip)
        refused(zip.xor(l + 6, 1), ZipReader.DAMAGED) // encrypted
        refused(zip.copyOf().also { it[l + 30] = 'E'.code.toByte() }, ZipReader.DAMAGED) // renamed
        refused(zip.xor(l + 14, 1), ZipReader.DAMAGED) // CRC
        refused(zip.copyOf().also { it[l + 8] = 0; it[l + 9] = 0 }, ZipReader.DAMAGED) // stored
        refused(zip.copyOf().also { put32(it, l + 18, u32(zip, l + 18) + 1) }, ZipReader.DAMAGED) // compressed size
        refused(zip.xor(l + 6, 8), ZipReader.DAMAGED) // a descriptor the directory does not have
    }

    @Test fun aStreamEndingBeforeItsCompressedSizeIsDamaged() {
        val zip = fixture("sample.1pux"); val c = central(zip); val l = local(zip)
        // Both headers claim one more byte than the DEFLATE stream uses: the next header's first byte.
        put32(zip, c + 20, u32(zip, c + 20) + 1); put32(zip, l + 18, u32(zip, l + 18) + 1)
        refused(zip, ZipReader.DAMAGED)
    }

    @Test fun dataDescriptorsAreReadAndMustAgreeWithTheDirectory() {
        val zip = fixture("data-descriptor.1pux"); val c = central(zip); val l = local(zip)
        assertEquals(8, u16(zip, c + 8) and 8)
        assertArrayEquals(ZipReader.entry(fixture("sample.1pux"), "export.data"), ZipReader.entry(zip, "export.data"))
        val descriptor = dataStart(zip) + u32(zip, c + 20)
        assertEquals(0x08074b50, u32(zip, descriptor))
        for (field in listOf(4, 8, 12)) refused(zip.xor(descriptor + field, 1), ZipReader.DAMAGED) // CRC, compressed size, size
        refused(zip.xor(l + 6, 8), ZipReader.DAMAGED) // the local header no longer announces the descriptor
    }
}
