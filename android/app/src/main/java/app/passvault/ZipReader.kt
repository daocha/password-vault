package app.passvault

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipInputStream

/** Selects a ZIP entry through its central directory, without inflating unrelated attachments (as on iOS). */
internal object ZipReader {
    fun entry(zip: ByteArray, name: String): ByteArray? {
        fun u16(offset: Int) = (zip[offset].toInt() and 255) or ((zip[offset + 1].toInt() and 255) shl 8)
        fun u32(offset: Int) = u16(offset).toLong() or (u16(offset + 2).toLong() shl 16)
        fun valid(condition: Boolean) = require(condition) { "The zip file is damaged or unsupported." }
        valid(zip.size >= 22)
        // The end record may be followed by a comment. Validate its length so a signature
        // inside that comment cannot be mistaken for the record itself.
        val end = (zip.size - 22 downTo maxOf(0, zip.size - 22 - 65535)).firstOrNull {
            u32(it) == 0x06054b50L && it + 22 + u16(it + 20) == zip.size
        } ?: throw IllegalArgumentException("The zip file is damaged.")
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
                val size = u32(position + 24)
                val compressed = u32(position + 20)
                val local = u32(position + 42)
                valid(u16(position + 34) == 0 && local + 30 <= directory)
                require(size <= Records.MAX_BYTES) { "The export is too large." }
                val offset = local.toInt()
                valid(u32(offset) == 0x04034b50L)
                val body = local + 30 + u16(offset + 26) + u16(offset + 28)
                valid(body + compressed <= directory)
                // Let the standard reader validate the selected local header, DEFLATE stream,
                // data descriptor and CRC. Never advance it to a second entry: nextEntry
                // would inflate skipped contents without applying our output limit.
                ZipInputStream(ByteArrayInputStream(zip, offset, directory.toInt() - offset)).use { input ->
                    valid(input.nextEntry?.name == name)
                    val out = ByteArrayOutputStream(); val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(out.size() + count <= Records.MAX_BYTES) { "The export is too large." }
                        out.write(buffer, 0, count)
                    }
                    valid(out.size().toLong() == size)
                    return out.toByteArray()
                }
            }
            position = next.toInt()
        }
        return null
    }
}
