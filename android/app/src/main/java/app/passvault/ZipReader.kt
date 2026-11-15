package app.passvault

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipInputStream

/**
 * Selects a ZIP entry through its central directory, without inflating unrelated attachments. Checks and messages match
 * iOS's `ZipReader`: the end record's comment length, every offset against the directory, a local header (or data
 * descriptor) that agrees with the directory, the size limit, a DEFLATE stream that fills exactly its compressed size,
 * the decompressed size and the CRC.
 */
internal object ZipReader {
    const val DAMAGED = "The zip file is damaged."
    const val TOO_LARGE = "The export is too large."
    const val UNSUPPORTED = "The zip file uses a compression PassVault does not support."
    fun entry(zip: ByteArray, name: String): ByteArray? {
        fun u16(offset: Int) = (zip[offset].toInt() and 255) or ((zip[offset + 1].toInt() and 255) shl 8)
        fun u32(offset: Int) = u16(offset).toLong() or (u16(offset + 2).toLong() shl 16)
        fun valid(condition: Boolean) = require(condition) { DAMAGED }
        valid(zip.size >= 22)
        // The end record may be followed by a comment. Validate its length so a signature
        // inside that comment cannot be mistaken for the record itself.
        val end = (zip.size - 22 downTo maxOf(0, zip.size - 22 - 65535)).firstOrNull {
            u32(it) == 0x06054b50L && it + 22 + u16(it + 20) == zip.size
        } ?: throw IllegalArgumentException(DAMAGED)
        valid(u16(end + 4) == 0 && u16(end + 6) == 0 && u16(end + 8) == u16(end + 10))
        val directory = u32(end + 16)
        val directoryEnd = directory + u32(end + 12)
        valid(directory <= end && directoryEnd <= end)
        var position = directory.toInt()
        repeat(u16(end + 10)) {
            valid(position.toLong() + 46 <= directoryEnd)
            valid(u32(position) == 0x02014b50L)
            val nameLength = u16(position + 28)
            val next = position.toLong() + 46 + nameLength + u16(position + 30) + u16(position + 32)
            valid(next <= directoryEnd)
            val entryName = String(zip, position + 46, nameLength, Charsets.UTF_8)
            if (entryName == name) {
                val flags = u16(position + 8); val method = u16(position + 10); val crc = u32(position + 16)
                val size = u32(position + 24)
                val compressed = u32(position + 20)
                val local = u32(position + 42)
                valid(u16(position + 34) == 0 && local + 30 <= directory)
                require((flags and 1) == 0 && (method == 0 || method == 8)) { UNSUPPORTED }
                require(size <= Records.MAX_BYTES) { TOO_LARGE }
                val offset = local.toInt()
                valid(u32(offset) == 0x04034b50L)
                val localNameLength = u16(offset + 26)
                val body = local + 30 + localNameLength + u16(offset + 28)
                valid(body + compressed <= directory)
                // The local header must describe the same entry as the directory, so a reader trusting either copy sees the
                // same file. Its CRC and sizes, or with flag 8 the data descriptor after the data, must match the directory's.
                // Checked here, as on iOS, rather than left to ZipInputStream, which compares them only with the data.
                valid((u16(offset + 6) and 9) == (flags and 9) && u16(offset + 8) == method &&
                    zip.copyOfRange(offset + 30, offset + 30 + localNameLength).contentEquals(zip.copyOfRange(position + 46, position + 46 + nameLength)))
                valid(method == 8 || ((flags and 8) == 0 && compressed == size))
                if ((flags and 8) == 0) valid(u32(offset + 14) == crc && u32(offset + 18) == compressed && u32(offset + 22) == size)
                else {
                    var descriptor = body + compressed
                    if (descriptor + 4 <= directory && u32(descriptor.toInt()) == 0x08074b50L) descriptor += 4 // the signature is optional
                    valid(descriptor + 12 <= directory && u32(descriptor.toInt()) == crc && u32(descriptor.toInt() + 4) == compressed && u32(descriptor.toInt() + 8) == size)
                }
                // The standard reader inflates the selected entry and checks that its stream ends at the compressed size.
                // Never advance it to a second entry: nextEntry would inflate skipped contents without our output limit.
                val out = ByteArrayOutputStream()
                try {
                    ZipInputStream(ByteArrayInputStream(zip, offset, directory.toInt() - offset)).use { input ->
                        valid(input.nextEntry?.name == name)
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            require(out.size() + count <= Records.MAX_BYTES) { TOO_LARGE }
                            out.write(buffer, 0, count)
                        }
                    }
                } catch (e: java.io.IOException) { throw IllegalArgumentException(DAMAGED, e) } // a bad DEFLATE stream or local CRC
                val data = out.toByteArray()
                valid(data.size.toLong() == size && java.util.zip.CRC32().apply { update(data) }.value == crc)
                return data
            }
            position = next.toInt()
        }
        return null
    }
}
