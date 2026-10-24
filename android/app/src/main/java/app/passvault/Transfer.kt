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
 * The QR form of a transfer: `PVX1:<session>:<index>/<count>:<Base64url chunk>`, shown in a loop. The receiver keeps every distinct frame
 * of one session, in any order, until it has them all. Frames carry only ciphertext; the code is never in them.
 */
object TransferFrames {
    const val CHUNK = 500
    const val MAX_FRAMES = 4000
    private const val PREFIX = "PVX1:"
    fun frames(data: ByteArray, session: String = Transfer.newCode().take(4)): List<String> {
        val chunks = data.toList().chunked(CHUNK).map { it.toByteArray() }
        require(chunks.size <= MAX_FRAMES) { "The vault is too large to send by QR code. Save a transfer file instead." }
        return chunks.mapIndexed { i, c -> "$PREFIX$session:${i + 1}/${chunks.size}:" + Base64.getUrlEncoder().withoutPadding().encodeToString(c) }
    }
    fun isFrame(text: String) = text.startsWith(PREFIX)
    class Collector {
        private var session: String? = null
        private var parts: Array<ByteArray?> = emptyArray()
        val total get() = parts.size
        val received get() = parts.count { it != null }
        val complete get() = parts.isNotEmpty() && parts.all { it != null }
        /** True when [text] was a new frame of this transfer. A frame from another transfer (a new session) starts over. */
        fun add(text: String): Boolean {
            if (!isFrame(text)) return false
            val fields = text.removePrefix(PREFIX).split(':', limit = 3); if (fields.size != 3) return false
            val (index, count) = fields[1].split('/').mapNotNull { it.toIntOrNull() }.takeIf { it.size == 2 } ?: return false
            if (count !in 1..MAX_FRAMES || index !in 1..count) return false
            val chunk = runCatching { Base64.getUrlDecoder().decode(fields[2]) }.getOrNull()?.takeIf { it.isNotEmpty() && it.size <= CHUNK } ?: return false
            if (fields[0] != session || count != parts.size) { session = fields[0]; parts = arrayOfNulls(count) }
            if (parts[index - 1] != null) return false
            parts[index - 1] = chunk; return true
        }
        fun result(): ByteArray? = if (complete) parts.fold(ByteArray(0)) { acc, p -> acc + p!! } else null
    }
}
