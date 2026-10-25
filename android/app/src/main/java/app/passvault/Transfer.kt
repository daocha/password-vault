package app.passvault

import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.Base64
import java.util.zip.Deflater
import java.util.zip.Inflater

/**
 * Moving the vault to another phone without any network: the records are compressed and encrypted under a one-time transfer code
 * that is shown on screen only, then either streamed as a loop of QR codes (see [TransferFrames]) or saved as a file.
 *
 *     PVXFER01: magic 8 | u32be memKiB | u32be passes | salt 16 | XChaCha20-Poly1305 box (header as AAD)
 *
 * The plaintext is raw DEFLATE of the same JSON as a backup. The key is Argon2id of the code's 12 characters (59 bits, chosen at
 * random by the sender), at the local vault's cost.
 */
object Transfer {
    private val magic = "PVXFER01".toByteArray()
    const val HEADER = 32
    /** No 0/O, 1/I/L, so a code read off a screen is typed back correctly. */
    const val CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    const val CODE_LENGTH = 12
    private val rng = SecureRandom()

    fun newCode(): String = String(CharArray(CODE_LENGTH) { CODE_ALPHABET[rng.nextInt(CODE_ALPHABET.length)] })
    /** "7K4P-92XM-QD3F". */
    fun display(code: String) = code.chunked(4).joinToString("-")
    /** What to keep of a code being typed: its letters and digits, upper case, at most 12; the dashes are only shown (see [typingBreaks]). */
    fun typing(text: String) = text.uppercase().filter { it in 'A'..'Z' || it in '0'..'9' }.take(CODE_LENGTH)
    /** Where a code being typed shows a dash: after each group of four as soon as it is typed ("FM96" reads "FM96-"), not after the last. */
    fun typingBreaks(typed: String) = listOf(4, 8).filter { it <= typed.length }
    /** The code as typed (any case, with or without dashes or spaces), or an error naming the problem. */
    fun canonical(typed: String): String {
        val code = typed.uppercase().filter { !it.isWhitespace() && it != '-' }
        require(code.length == CODE_LENGTH && code.all { it in CODE_ALPHABET }) { "Check the transfer code: it is 12 letters and digits, shown on the other phone." }
        return code
    }
    fun isTransfer(data: ByteArray) = data.size >= 8 && data.copyOfRange(0, 8).contentEquals(magic)

    fun seal(records: List<VaultRecord>, code: String): ByteArray {
        val profile = KdfProfile.VAULT; val salt = VaultCrypto.random(16)
        val header = ByteBuffer.allocate(HEADER).put(magic).putInt(profile.memKiB).putInt(profile.opsLimit.toInt()).put(salt).array()
        val json = Records.encode(records); val packed = deflate(json); json.fill(0)
        val key = VaultCrypto.passwordKey(canonical(code), salt, profile)
        try { return header + VaultCrypto.seal(packed, key, header) } finally { key.fill(0); packed.fill(0) }
    }
    fun open(data: ByteArray, typedCode: String): List<VaultRecord> {
        require(isTransfer(data) && data.size >= HEADER + 40) { "Not a PassVault transfer." }
        val buffer = ByteBuffer.wrap(data, 8, 8); val mem = buffer.int; val passes = buffer.int
        require(mem in BackupFormat.MIN_MEM_KIB..BackupFormat.MAX_MEM_KIB && passes in BackupFormat.MIN_PASSES..BackupFormat.MAX_PASSES) { "Unsupported transfer settings." }
        val header = data.copyOfRange(0, HEADER)
        val key = VaultCrypto.passwordKey(canonical(typedCode), data.copyOfRange(16, 32), KdfProfile(passes.toLong(), mem))
        val packed = try { VaultCrypto.open(data.copyOfRange(HEADER, data.size), key, header) } finally { key.fill(0) }
        val json = try { inflate(packed, Records.MAX_BYTES) } finally { packed.fill(0) }
        try { return Records.decode(json) } finally { json.fill(0) }
    }
    internal fun deflate(input: ByteArray): ByteArray {
        val deflater = Deflater(Deflater.BEST_COMPRESSION, true).apply { setInput(input); finish() }
        val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(65536)
        try { while (!deflater.finished()) out.write(buffer, 0, deflater.deflate(buffer)) } finally { deflater.end() }
        return out.toByteArray()
    }
    internal fun inflate(input: ByteArray, limit: Int): ByteArray {
        val inflater = Inflater(true).apply { setInput(input) }
        val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(65536)
        try {
            while (!inflater.finished()) {
                val n = inflater.inflate(buffer)
                if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) throw IllegalArgumentException("The transfer is damaged.")
                require(out.size() + n <= limit) { "The transfer is too large." }; out.write(buffer, 0, n)
            }
        } catch (e: java.util.zip.DataFormatException) { throw IllegalArgumentException("The transfer is damaged.") } finally { inflater.end() }
        return out.toByteArray()
    }
}

/**
 * The QR form of a transfer, an endless stream: `PVX2:<session>:<count>:<size>:<seed>:<Base64url chunk>`. The `size` bytes are cut into
 * `count` chunks of [CHUNK] bytes, the last padded with zeros. A frame with a seed below `count` is that chunk; every later seed is the XOR
 * of a pseudo-random half of the chunks (a random linear fountain code). The receiver can then rebuild the transfer from any `count` or so
 * frames it reads, instead of waiting for a loop to come round to the few it missed. Frames carry only ciphertext; the code is never in them.
 * Receivers also read the first version's loop, `PVX1:<session>:<index>/<count>:<chunk>`.
 */
object TransferFrames {
    const val CHUNK = 500
    const val MAX_FRAMES = 4000
    private const val PREFIX = "PVX2:"
    private const val V1_PREFIX = "PVX1:"
    private const val WORDS = (CHUNK + 7) / 8
    fun isFrame(text: String) = text.startsWith(PREFIX) || text.startsWith(V1_PREFIX)

    /** The frames of one transfer, by seed: the first [count] are the chunks in order, then mixes for as long as the screen is shown. */
    class Sender(private val data: ByteArray, private val session: String = Transfer.newCode().take(4)) {
        val count = (data.size + CHUNK - 1) / CHUNK
        init { require(count in 1..MAX_FRAMES) { "The vault is too large to send by QR code. Save a transfer file instead." } }
        fun frame(seed: Int): String {
            require(seed >= 0)
            val words = LongArray(WORDS)
            if (seed < count) xorChunk(words, seed) else { val mix = mix(seed, count); for (i in 0 until count) if (mix.bit(i)) xorChunk(words, i) }
            return "$PREFIX$session:$count:${data.size}:$seed:" + Base64.getUrlEncoder().withoutPadding().encodeToString(bytes(words))
        }
        private fun xorChunk(into: LongArray, index: Int) {
            for (j in index * CHUNK until minOf(data.size, (index + 1) * CHUNK)) { val k = j - index * CHUNK; into[k / 8] = into[k / 8] xor ((data[j].toLong() and 0xFF) shl (8 * (k % 8))) }
        }
    }

    /** Which chunks the frame with [seed] mixes: a bit per chunk, from SplitMix64 (the same on iOS); never none. */
    internal fun mix(seed: Int, count: Int): LongArray {
        var state = seed.toLong()
        val out = LongArray((count + 63) / 64) {
            state += -0x61c8864680b583ebL
            var z = state; z = (z xor (z ushr 30)) * -0x40a7b892e31b1a47L; z = (z xor (z ushr 27)) * -0x6b2fb644ecceee15L; z xor (z ushr 31)
        }
        if (count % 64 != 0) out[out.size - 1] = out[out.size - 1] and ((1L shl (count % 64)) - 1)
        if (out.all { it == 0L }) out.setBit(seed % count)
        return out
    }
    private fun LongArray.bit(i: Int) = (this[i / 64] ushr (i % 64)) and 1L != 0L
    private fun LongArray.setBit(i: Int) { this[i / 64] = this[i / 64] or (1L shl (i % 64)) }
    private fun LongArray.xorWith(other: LongArray) { for (i in indices) this[i] = this[i] xor other[i] }
    private fun words(bytes: ByteArray) = LongArray(WORDS).also { w -> bytes.forEachIndexed { k, b -> w[k / 8] = w[k / 8] or ((b.toLong() and 0xFF) shl (8 * (k % 8))) } }
    private fun bytes(words: LongArray) = ByteArray(CHUNK) { k -> (words[k / 8] ushr (8 * (k % 8))).toByte() }

    /**
     * Gauss–Jordan elimination over GF(2), one frame at a time: `rows[p]` is the only kept frame with chunk `p` in its mix, so a new frame
     * costs one pass over the kept ones. Once every chunk has a row, each row is exactly its chunk.
     */
    class Collector {
        private class Row(val mix: LongArray, val data: LongArray)
        private var session: String? = null
        private var rows: Array<Row?> = emptyArray()
        /** Bytes in the transfer; -1 until known (a first-version loop says it only in its last frame). */
        private var size = -1
        val total get() = rows.size
        var received = 0; private set
        val complete get() = rows.isNotEmpty() && received == rows.size && size >= 0
        /** True when [text] was a frame of this transfer that brought something new. A frame from another transfer (a new session) starts over. */
        fun add(text: String): Boolean {
            val frame = parse(text) ?: return false
            if (frame.session != session || frame.count != rows.size || (frame.size >= 0 && size >= 0 && frame.size != size)) {
                session = frame.session; rows = arrayOfNulls(frame.count); size = -1; received = 0
            }
            val mix = if (frame.seed < frame.count) LongArray((frame.count + 63) / 64).also { it.setBit(frame.seed) } else mix(frame.seed, frame.count)
            val data = words(frame.chunk)
            for (p in rows.indices) { val row = rows[p] ?: continue; if (mix.bit(p)) { mix.xorWith(row.mix); data.xorWith(row.data) } }
            val pivot = (0 until frame.count).firstOrNull { mix.bit(it) } ?: return false
            for (row in rows) if (row != null && row.mix.bit(pivot)) { row.mix.xorWith(mix); row.data.xorWith(data) }
            rows[pivot] = Row(mix, data); received++
            if (frame.size >= 0) size = frame.size
            return true
        }
        fun result(): ByteArray? {
            if (!complete) return null
            val out = ByteArray(size)
            rows.forEachIndexed { p, row -> bytes(row!!.data).copyInto(out, p * CHUNK, 0, minOf(CHUNK, size - p * CHUNK)) }
            return out
        }
    }

    private class Frame(val session: String, val count: Int, val size: Int, val seed: Int, val chunk: ByteArray)
    private fun parse(text: String): Frame? {
        fun chunk(b64: String) = runCatching { Base64.getUrlDecoder().decode(b64) }.getOrNull()
        if (text.startsWith(PREFIX)) {
            val f = text.removePrefix(PREFIX).split(':', limit = 5); if (f.size != 5) return null
            val count = f[1].toIntOrNull() ?: return null; val size = f[2].toIntOrNull() ?: return null; val seed = f[3].toIntOrNull() ?: return null
            if (count !in 1..MAX_FRAMES || size !in (count - 1) * CHUNK + 1..count * CHUNK || seed < 0) return null
            return chunk(f[4])?.takeIf { it.size == CHUNK }?.let { Frame(f[0], count, size, seed, it) }
        }
        if (!text.startsWith(V1_PREFIX)) return null
        val f = text.removePrefix(V1_PREFIX).split(':', limit = 3); if (f.size != 3) return null
        val (index, count) = f[1].split('/').mapNotNull { it.toIntOrNull() }.takeIf { it.size == 2 } ?: return null
        if (count !in 1..MAX_FRAMES || index !in 1..count) return null
        // Every chunk but the last is full; the last one gives the size.
        val chunk = chunk(f[2])?.takeIf { it.isNotEmpty() && it.size <= CHUNK && (index == count || it.size == CHUNK) } ?: return null
        return Frame(f[0], count, if (index == count) (count - 1) * CHUNK + chunk.size else -1, index - 1, chunk)
    }
}
