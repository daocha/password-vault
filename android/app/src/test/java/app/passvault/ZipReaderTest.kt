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
        assertThrows(java.util.zip.ZipException::class.java) { ZipReader.entry(damaged, "export.data") }
        assertThrows(IllegalArgumentException::class.java) { ZipReader.entry(zip.copyOf(20), "export.data") }
        val invalidOffset = zip.copyOf()
        val end = zip.size - 22 - "A ZIP comment containing PK\u0005\u0006".toByteArray().size
        repeat(4) { invalidOffset[end + 16 + it] = 0x7f }
        assertThrows(IllegalArgumentException::class.java) { ZipReader.entry(invalidOffset, "export.data") }
    }
}
