package app.passvault

import org.bouncycastle.crypto.InvalidCipherTextException
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.digests.SHA3Digest
import org.bouncycastle.crypto.digests.SHAKEDigest
import org.bouncycastle.crypto.macs.HMac
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.math.ec.rfc7748.X25519
import org.bouncycastle.pqc.crypto.mlkem.MLKEMExtractor
import org.bouncycastle.pqc.crypto.mlkem.MLKEMGenerator
import org.bouncycastle.pqc.crypto.mlkem.MLKEMParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMPrivateKeyParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMPublicKeyParameters
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** Why an age file could not be decrypted. [Kind] follows the age test kit's outcomes (CCTV), so tests can check the exact failure. */
class AgeException(val kind: Kind, message: String) : Exception(message) {
    /** [passphrase]: a passphrase (scrypt) file, which PassVault does not open: it only encrypts to the vault's keys. */
    enum class Kind { header, noMatch, passphrase, hmac, payload, armor }
}

/**
 * age v1 file encryption (c2sp.org/age), so files PassVault encrypts open with the `age` command-line tool and vice versa. Supports the
 * X25519 and post-quantum hybrid (mlkem768x25519) recipient types and reads ASCII-armored files; passphrase (scrypt) stanzas cannot
 * be opened (but are rejected alongside other stanzas, as the spec requires) and hardware (tag) stanzas are ignored. Pure Kotlin on BouncyCastle's lightweight API, so the JVM unit tests check it against the age test kit.
 */
object Age {
    const val CHUNK = 64 * 1024
    private const val VERSION = "age-encryption.org/v1"
    private const val MAX_LINE = 16 * 1024; private const val MAX_HEADER = 1024 * 1024
    private const val BEGIN = "-----BEGIN AGE ENCRYPTED FILE-----"; private const val END = "-----END AGE ENCRYPTED FILE-----"
    private val rng = SecureRandom()

    class Stanza(val args: List<String>, val body: ByteArray)
    sealed class Recipient { abstract val encoded: String; internal abstract fun wrap(fileKey: ByteArray): Stanza }
    sealed class Identity {
        abstract val encoded: String; abstract val recipient: Recipient
        /** The file key, null when [stanza] is not for this identity; throws a header failure for a malformed stanza of its own type. */
        internal abstract fun unwrap(stanza: Stanza): ByteArray?
    }

    class X25519Recipient internal constructor(private val public: ByteArray) : Recipient() {
        override val encoded get() = Bech32.encode("age", public)
        override fun wrap(fileKey: ByteArray): Stanza {
            val ephemeral = random(32); val share = ByteArray(32).also { X25519.scalarMultBase(ephemeral, 0, it, 0) }; val shared = ByteArray(32)
            check(X25519.calculateAgreement(ephemeral, 0, public, 0, shared, 0)) { "Invalid recipient." }
            val key = hkdf(shared, share + public, "age-encryption.org/v1/X25519")
            try { return Stanza(listOf("X25519", b64(share)), aead(true, key, ByteArray(12), fileKey)) } finally { key.fill(0); shared.fill(0); ephemeral.fill(0) }
        }
    }
    class X25519Identity internal constructor(private val secret: ByteArray) : Identity() {
        private val public = ByteArray(32).also { X25519.scalarMultBase(secret, 0, it, 0) }
        override val encoded get() = Bech32.encode("AGE-SECRET-KEY-", secret)
        override val recipient get() = X25519Recipient(public)
        override fun unwrap(stanza: Stanza): ByteArray? {
            if (stanza.args.firstOrNull() != "X25519") return null
            if (stanza.args.size != 2) header("An X25519 stanza needs exactly two arguments.")
            val share = unb64(stanza.args[1]) ?: header("Invalid X25519 share.")
            if (share.size != 32 || stanza.body.size != 32) header("Invalid X25519 stanza.")
            val shared = ByteArray(32)
            if (!X25519.calculateAgreement(secret, 0, share, 0, shared, 0)) header("Invalid X25519 share.")
            val key = hkdf(shared, share + public, "age-encryption.org/v1/X25519")
            try { return openKey(key, ByteArray(12), stanza.body) } finally { key.fill(0); shared.fill(0) }
        }
    }

    /** ML-KEM-768 encapsulation key followed by an X25519 public key (X-Wing). */
    class HybridRecipient internal constructor(private val public: ByteArray) : Recipient() {
        private val mlkem = MLKEMPublicKeyParameters(MLKEMParameters.ml_kem_768, public.copyOfRange(0, MLKEM_PUBLIC))
        private val x25519 = public.copyOfRange(MLKEM_PUBLIC, HYBRID_PUBLIC)
        override val encoded get() = Bech32.encode("age1pq", public)
        override fun wrap(fileKey: ByteArray): Stanza {
            val pq = MLKEMGenerator(rng).generateEncapsulated(mlkem)
            val ephemeral = random(32); val ctT = ByteArray(32).also { X25519.scalarMultBase(ephemeral, 0, it, 0) }; val ssT = ByteArray(32)
            // getSecret() returns a copy, which destroy() does not reach: wipe it here too.
            var ssM: ByteArray? = null; val encapsulation = pq.encapsulation + ctT // read before destroy()
            val (key, nonce) = try {
                check(X25519.calculateAgreement(ephemeral, 0, x25519, 0, ssT, 0)) { "Invalid recipient." }
                ssM = pq.secret; hpke(combine(ssM, ssT, ctT, x25519))
            } finally { ssM?.fill(0); ssT.fill(0); ephemeral.fill(0); pq.destroy() }
            try { return Stanza(listOf("mlkem768x25519", b64(encapsulation)), aead(true, key, nonce, fileKey)) } finally { key.fill(0) }
        }
    }
    /** A 32-byte seed, expanded with SHAKE256 into the ML-KEM-768 seed (64 bytes) and the X25519 secret key (32 bytes). */
    class HybridIdentity internal constructor(private val seed: ByteArray) : Identity() {
        private val mlkem: MLKEMPrivateKeyParameters; private val x25519 = ByteArray(32); private val x25519Public = ByteArray(32)
        init {
            val expanded = ByteArray(96).also { SHAKEDigest(256).apply { update(seed, 0, seed.size); doFinal(it, 0, 96) } }
            mlkem = MLKEMPrivateKeyParameters(MLKEMParameters.ml_kem_768, expanded.copyOfRange(0, 64))
            expanded.copyInto(x25519, 0, 64, 96); expanded.fill(0)
            X25519.scalarMultBase(x25519, 0, x25519Public, 0)
        }
        override val encoded get() = Bech32.encode("AGE-SECRET-KEY-PQ-", seed)
        override val recipient get() = HybridRecipient(mlkem.publicKey + x25519Public)
        override fun unwrap(stanza: Stanza): ByteArray? {
            if (stanza.args.firstOrNull() != "mlkem768x25519") return null
            if (stanza.args.size != 2) header("An mlkem768x25519 stanza needs exactly two arguments.")
            val enc = unb64(stanza.args[1]) ?: header("Invalid mlkem768x25519 encapsulation.")
            if (enc.size != MLKEM_CIPHERTEXT + 32 || stanza.body.size != 32) header("Invalid mlkem768x25519 stanza.")
            val ctT = enc.copyOfRange(MLKEM_CIPHERTEXT, enc.size); val ssT = ByteArray(32); var ssM: ByteArray? = null
            val (key, nonce) = try {
                if (!X25519.calculateAgreement(x25519, 0, ctT, 0, ssT, 0)) header("Invalid mlkem768x25519 encapsulation.")
                // ML-KEM rejects implicitly: a corrupted ciphertext yields an unrelated secret, so the body simply fails to open.
                ssM = MLKEMExtractor(mlkem).extractSecret(enc.copyOfRange(0, MLKEM_CIPHERTEXT))
                hpke(combine(ssM, ssT, ctT, x25519Public))
            } finally { ssT.fill(0); ssM?.fill(0) }
            try { return openKey(key, nonce, stanza.body) } finally { key.fill(0) }
        }
    }
    private const val MLKEM_PUBLIC = 1184; private const val MLKEM_CIPHERTEXT = 1088; private const val HYBRID_PUBLIC = MLKEM_PUBLIC + 32

    /** A new post-quantum hybrid identity (`AGE-SECRET-KEY-PQ-1…`), the type `age-keygen -pq` makes. */
    fun generateIdentity(): Identity = HybridIdentity(random(32))
    /** An `AGE-SECRET-KEY-1…` or `AGE-SECRET-KEY-PQ-1…` string; throws [IllegalArgumentException] for anything else. */
    fun parseIdentity(text: String): Identity {
        val (hrp, data) = Bech32.decode(text.trim())
        require(data.size == 32) { "Not an age secret key." }
        return when (hrp) { "age-secret-key-" -> X25519Identity(data); "age-secret-key-pq-" -> HybridIdentity(data); else -> throw IllegalArgumentException("Not an age secret key.") }
    }
    /** Whether [text] is an identity [parseIdentity] accepts, without expanding the key (cheap enough for list filtering). */
    fun isIdentity(text: String) = runCatching { Bech32.decode(text.trim()) }.getOrNull()?.let { (hrp, data) -> data.size == 32 && hrp in setOf("age-secret-key-", "age-secret-key-pq-") } == true
    /** Whether [identity] is the post-quantum hybrid type. */
    fun isPostQuantum(identity: String) = identity.trim().startsWith("AGE-SECRET-KEY-PQ-1", ignoreCase = true)
    /** An `age1…` or `age1pq1…` public key. */
    fun parseRecipient(text: String): Recipient {
        val (hrp, data) = Bech32.decode(text.trim())
        return when {
            hrp == "age" && data.size == 32 -> X25519Recipient(data)
            hrp == "age1pq" && data.size == HYBRID_PUBLIC -> HybridRecipient(data)
            else -> throw IllegalArgumentException("Not an age public key.")
        }
    }

    /** Encrypts [input] to [recipients], streaming in 64 KiB chunks. Neither stream is closed. */
    fun encrypt(input: InputStream, output: OutputStream, recipients: List<Recipient>) {
        require(recipients.isNotEmpty())
        val fileKey = random(16)
        try {
            val header = ByteArrayOutputStream()
            header.write("$VERSION\n".toByteArray())
            for (stanza in recipients.map { it.wrap(fileKey) }) header.write(encode(stanza))
            header.write("---".toByteArray())
            val macKey = hkdf(fileKey, ByteArray(0), "header"); val mac = hmac(macKey, header.toByteArray()); macKey.fill(0)
            header.write(" ${b64(mac)}\n".toByteArray())
            output.write(header.toByteArray())
            val nonce = random(16); output.write(nonce)
            val key = hkdf(fileKey, nonce, "payload")
            // The plaintext buffers are wiped even when reading or writing fails part way.
            var current = ByteArray(CHUNK); var next = ByteArray(CHUNK)
            try {
                var counter = 0L
                var n = readFully(input, current, 0, CHUNK)
                while (true) {
                    // A full chunk is the last only when nothing follows it; an empty file is one empty final chunk.
                    val m = if (n < CHUNK) 0 else readFully(input, next, 0, CHUNK)
                    output.write(aead(true, key, chunkNonce(counter, m == 0), current, n))
                    if (m == 0) break
                    current.fill(0); val t = current; current = next; next = t; n = m; counter++
                }
            } finally { current.fill(0); next.fill(0); key.fill(0) }
        } finally { fileKey.fill(0) }
    }

    /**
     * Decrypts an age file, binary or ASCII-armored, with whichever of [identities] it was encrypted to. Plaintext is written chunk by
     * chunk as each is authenticated, so on a [AgeException] of kind `payload` [output] already holds a truncated prefix: discard it.
     */
    fun decrypt(input: InputStream, output: OutputStream, identities: List<Identity>) = decryptBinary(binary(input), output, identities)
    /** Reads only the header: throws as [decrypt] would when the file is not age, is for other keys, or its header was changed. */
    fun checkHeader(input: InputStream, identities: List<Identity>) { openHeader(binary(input), identities).fill(0) }
    /** [input] itself, or the decoded bytes when it is ASCII-armored. */
    private fun binary(input: InputStream): InputStream {
        val buffered = BufferedInputStream(input, CHUNK)
        buffered.mark(1024)
        val peek = ByteArray(1024).let { it.copyOf(readFully(buffered, it, 0, it.size)) }
        buffered.reset()
        val start = peek.indexOfFirst { it.toInt().toChar() !in " \t\r\n" }
        if (start < 0 || String(peek, start, minOf(10, peek.size - start), Charsets.ISO_8859_1) != "-----BEGIN") return buffered
        return Dearmor(buffered)
    }
    /** The file key, after checking the header MAC. */
    private fun openHeader(input: InputStream, identities: List<Identity>): ByteArray {
        val header = readHeader(input)
        // The spec requires an scrypt (passphrase) stanza to be alone, so a passphrase file cannot be silently re-addressed to a key.
        if (header.stanzas.size > 1 && header.stanzas.any { it.args.firstOrNull() == "scrypt" }) header("A passphrase stanza must be the only one.")
        var fileKey: ByteArray? = null
        loop@ for (stanza in header.stanzas) for (identity in identities) { fileKey = identity.unwrap(stanza); if (fileKey != null) break@loop }
        fileKey ?: if (header.stanzas.any { it.args.firstOrNull() == "scrypt" }) throw AgeException(AgeException.Kind.passphrase, "This file is protected with a passphrase.")
            else throw AgeException(AgeException.Kind.noMatch, "This file was not encrypted to any of your keys.")
        try {
            if (fileKey.size != 16) header("Invalid file key.")
            val macKey = hkdf(fileKey, ByteArray(0), "header"); val mac = hmac(macKey, header.macInput); macKey.fill(0)
            if (!MessageDigest.isEqual(mac, header.mac)) throw AgeException(AgeException.Kind.hmac, "The file header was changed.")
            return fileKey
        } catch (e: Exception) { fileKey.fill(0); throw e }
    }
    internal fun decryptBinary(input: InputStream, output: OutputStream, identities: List<Identity>) {
        val fileKey = openHeader(input, identities)
        try {
            val nonce = ByteArray(16)
            if (readFully(input, nonce, 0, 16) < 16) header("The file is truncated.")
            val key = hkdf(fileKey, nonce, "payload")
            try {
                val buffer = ByteArray(CHUNK + 16); var counter = 0L
                var n = readFully(input, buffer, 0, buffer.size)
                while (true) {
                    if (n < 16) payload("The file is truncated.")
                    // A short chunk must be the last; a full one is the last only when nothing follows it.
                    val following = if (n < buffer.size) -1 else input.read()
                    val last = following < 0
                    if (last && n == 16 && counter > 0) payload("The file ends with an empty chunk.")
                    val plain = try { aead(false, key, chunkNonce(counter, last), buffer, n) } catch (e: InvalidCipherTextException) { payload("The file is damaged or was changed.") }
                    try { output.write(plain) } finally { plain.fill(0) }
                    if (last) break
                    buffer[0] = following.toByte(); n = 1 + readFully(input, buffer, 1, buffer.size - 1); counter++
                }
                buffer.fill(0)
            } finally { key.fill(0) }
        } finally { fileKey.fill(0) }
    }

    internal class Header(val stanzas: List<Stanza>, val macInput: ByteArray, val mac: ByteArray)
    internal fun readHeader(input: InputStream): Header {
        val raw = ByteArrayOutputStream()
        fun line(): String {
            val start = raw.size()
            while (true) {
                val b = input.read()
                if (b < 0) header("The file header is incomplete.")
                if (b == '\n'.code) break
                // Header lines are printable ASCII; a CR (CRLF line endings) is not allowed.
                if (b !in 0x20..0x7E) header("Invalid character in the file header.")
                raw.write(b)
                if (raw.size() - start > MAX_LINE || raw.size() > MAX_HEADER) header("The file header is too long.")
            }
            val text = String(raw.toByteArray(), start, raw.size() - start, Charsets.US_ASCII); raw.write('\n'.code); return text
        }
        val version = line()
        if (version != VERSION) header(if (version.startsWith("age-encryption.org/")) "Unsupported age version." else "Not an age file.")
        val stanzas = ArrayList<Stanza>()
        while (true) {
            val text = line()
            when {
                text.startsWith("-> ") -> {
                    val args = text.substring(3).split(' ')
                    if (args.any { a -> a.isEmpty() || a.any { it.code !in 0x21..0x7E } }) header("Invalid stanza arguments.")
                    val body = StringBuilder()
                    while (true) {
                        val b = line()
                        if (b.length > 64) header("A stanza line is too long.")
                        body.append(b)
                        if (b.length < 64) break
                    }
                    stanzas += Stanza(args, unb64(body.toString()) ?: header("Invalid stanza body."))
                    if (stanzas.size > 256) header("Too many stanzas.")
                }
                text.startsWith("---") -> {
                    if (stanzas.isEmpty() || !text.startsWith("--- ")) header("Invalid header MAC line.")
                    val mac = unb64(text.substring(4))?.takeIf { it.size == 32 } ?: header("Invalid header MAC.")
                    val all = raw.toByteArray()
                    return Header(stanzas, all.copyOf(all.size - text.length - 1 + 3), mac)
                }
                else -> header("Invalid line in the file header.")
            }
        }
    }
    private fun encode(stanza: Stanza): ByteArray {
        val text = StringBuilder("-> ").append(stanza.args.joinToString(" ")).append('\n')
        // Body lines are 64 columns; the last is shorter, and empty when the body fills its lines exactly.
        val body = b64(stanza.body); var i = 0
        while (body.length - i >= 64) { text.append(body, i, i + 64).append('\n'); i += 64 }
        return text.append(body, i, body.length).append('\n').toString().toByteArray(Charsets.US_ASCII)
    }

    internal fun dearmor(data: ByteArray): ByteArray = Dearmor(ByteArrayInputStream(data)).readBytes()

    /**
     * Strict PEM (RFC 7468), decoded line by line as it is read, so a large armored file never sits in memory: whitespace is allowed
     * only around the block, lines are 64 columns (the last 1–64), LF or CRLF, canonical padded base64 with padding only on the last
     * line. An error surfaces when the reader reaches it, as [AgeException] of kind `armor`, so like any failure part way through
     * decryption it can leave a truncated output prefix behind.
     */
    private class Dearmor(private val input: InputStream) : InputStream() {
        private var started = false; private var done = false
        private var pending: String? = null
        private var decoded = ByteArray(0); private var position = 0
        private fun armor(message: String): Nothing = throw AgeException(AgeException.Kind.armor, message)
        private fun whitespace(b: Int) = b == ' '.code || b == '\t'.code || b == '\r'.code || b == '\n'.code
        /** The line starting with byte [first] (already read), without its LF or CRLF; null when [first] is the end of input. */
        private fun line(first: Int = input.read()): String? {
            if (first < 0) return null
            val text = StringBuilder(); var b = first
            while (b >= 0 && b != '\n'.code) {
                if (b > 0x7E) armor("Invalid character in armored file.")
                text.append(b.toChar())
                if (text.length > 80) armor("Invalid line length in armored file.")
                b = input.read()
            }
            val line = text.removeSuffix("\r").toString()
            if ('\r' in line) armor("Invalid line ending in armored file.")
            return line
        }
        private fun isEnd(line: String?) = line != null && line.trimEnd(' ', '\t') == END
        /** Decodes the next body line; false at the end of the block. */
        private fun fill(): Boolean {
            if (done) return false
            if (!started) {
                started = true
                var first = input.read(); while (first >= 0 && whitespace(first)) first = input.read()
                if (line(first) != BEGIN) armor("Not an armored age file.")
                pending = line()
            }
            val current = pending ?: armor("Not an armored age file.")
            if (isEnd(current)) {
                // Only whitespace may follow the block.
                while (true) { val b = input.read(); if (b < 0) break; if (!whitespace(b)) armor("Not an armored age file.") }
                done = true; return false
            }
            val next = line(); val last = next == null || isEnd(next)
            if (if (last) current.length !in 1..64 else current.length != 64) armor("Invalid line length in armored file.")
            if (!last && '=' in current) armor("Invalid base64 in armored file.")
            val bytes = try { Base64.getDecoder().decode(current) } catch (e: IllegalArgumentException) { armor("Invalid base64 in armored file.") }
            if (Base64.getEncoder().encodeToString(bytes) != current) armor("Non-canonical base64 in armored file.")
            pending = next; decoded = bytes; position = 0
            return true
        }
        override fun read(): Int { while (position >= decoded.size) if (!fill()) return -1; return decoded[position++].toInt() and 0xFF }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            while (position >= decoded.size) if (!fill()) return -1
            val n = minOf(len, decoded.size - position); System.arraycopy(decoded, position, b, off, n); position += n; return n
        }
    }

    private fun header(message: String): Nothing = throw AgeException(AgeException.Kind.header, message)
    private fun payload(message: String): Nothing = throw AgeException(AgeException.Kind.payload, message)
    private fun random(size: Int) = ByteArray(size).also(rng::nextBytes)
    private fun b64(data: ByteArray): String = Base64.getEncoder().withoutPadding().encodeToString(data)
    /** Canonical unpadded base64, or null. */
    private fun unb64(text: String): ByteArray? {
        if ('=' in text) return null
        val data = try { Base64.getDecoder().decode(text) } catch (e: IllegalArgumentException) { return null }
        return data.takeIf { b64(it) == text }
    }
    private fun readFully(input: InputStream, into: ByteArray, offset: Int, length: Int): Int {
        var total = 0
        while (total < length) { val n = input.read(into, offset + total, length - total); if (n < 0) break; total += n }
        return total
    }
    private fun chunkNonce(counter: Long, last: Boolean) = ByteArray(12).also { n -> for (i in 0 until 8) n[10 - i] = (counter ushr (8 * i)).toByte(); if (last) n[11] = 1 }
    /** The file key from a stanza body, or null when it does not authenticate (the stanza is for someone else). */
    private fun openKey(key: ByteArray, nonce: ByteArray, body: ByteArray): ByteArray? = try { aead(false, key, nonce, body) } catch (e: InvalidCipherTextException) { null }
    private fun aead(encrypt: Boolean, key: ByteArray, nonce: ByteArray, input: ByteArray, length: Int = input.size): ByteArray {
        val cipher = ChaCha20Poly1305(); cipher.init(encrypt, AEADParameters(KeyParameter(key), 128, nonce))
        val out = ByteArray(cipher.getOutputSize(length))
        // Decrypting, processBytes writes plaintext before doFinal checks the tag: wipe it when the tag is rejected.
        val n = try { cipher.processBytes(input, 0, length, out, 0).let { it + cipher.doFinal(out, it) } } catch (e: Exception) { out.fill(0); throw e }
        return if (n == out.size) out else out.copyOf(n).also { out.fill(0) }
    }
    private fun hmac(key: ByteArray, data: ByteArray): ByteArray = HMac(SHA256Digest()).run { init(KeyParameter(key)); update(data, 0, data.size); ByteArray(32).also { doFinal(it, 0) } }
    /**
     * HKDF-SHA-256 (RFC 5869), BouncyCastle's: extract and expand separately, as HPKE's labeled steps need. An empty salt is HashLen zero
     * bytes, which HMAC treats the same as an empty key.
     */
    private fun extract(salt: ByteArray, ikm: ByteArray): ByteArray = HKDFBytesGenerator(SHA256Digest()).extractPRK(salt, ikm)
    private fun expand(prk: ByteArray, info: ByteArray, length: Int): ByteArray =
        ByteArray(length).also { HKDFBytesGenerator(SHA256Digest()).apply { init(HKDFParameters.skipExtractParameters(prk, info)) }.generateBytes(it, 0, length) }
    private fun hkdf(ikm: ByteArray, salt: ByteArray, info: String): ByteArray { val prk = extract(salt, ikm); try { return expand(prk, info.toByteArray(), 32) } finally { prk.fill(0) } }
    /** X-Wing's combiner: SHA3-256(ss_M ‖ ss_X ‖ ct_X ‖ pk_X ‖ label). */
    private fun combine(ssM: ByteArray, ssT: ByteArray, ctT: ByteArray, pkT: ByteArray): ByteArray = SHA3Digest(256).run {
        for (part in listOf(ssM, ssT, ctT, pkT, "\\.//^\\".toByteArray())) update(part, 0, part.size)
        ByteArray(32).also { doFinal(it, 0) }
    }
    /** HPKE base-mode key schedule (RFC 9180) for MLKEM768-X25519 / HKDF-SHA256 / ChaCha20Poly1305 with age's info string: key and nonce. */
    private fun hpke(sharedSecret: ByteArray): Pair<ByteArray, ByteArray> {
        val suite = "HPKE".toByteArray() + byteArrayOf(0x64, 0x7a, 0, 1, 0, 3); val v1 = "HPKE-v1".toByteArray()
        fun labeledExtract(salt: ByteArray, label: String, ikm: ByteArray) = extract(salt, v1 + suite + label.toByteArray() + ikm)
        fun labeledExpand(prk: ByteArray, label: String, info: ByteArray, length: Int) = expand(prk, byteArrayOf(0, length.toByte()) + v1 + suite + label.toByteArray() + info, length)
        val context = byteArrayOf(0) + labeledExtract(ByteArray(0), "psk_id_hash", ByteArray(0)) + labeledExtract(ByteArray(0), "info_hash", "age-encryption.org/mlkem768x25519".toByteArray())
        val secret = labeledExtract(sharedSecret, "secret", ByteArray(0)); sharedSecret.fill(0)
        try { return labeledExpand(secret, "key", context, 32) to labeledExpand(secret, "base_nonce", context, 12) } finally { secret.fill(0) }
    }
}

/** Bech32 (BIP 173) without the 90-character limit, as age uses it. Strings are all upper or all lower case; [decode] returns the lower-case HRP. */
internal object Bech32 {
    private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    private val GENERATOR = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
    private fun polymod(values: IntArray): Int {
        var chk = 1
        for (v in values) { val top = chk ushr 25; chk = ((chk and 0x1ffffff) shl 5) xor v; for (i in 0 until 5) if ((top ushr i) and 1 == 1) chk = chk xor GENERATOR[i] }
        return chk
    }
    private fun expandHrp(hrp: String) = IntArray(hrp.length * 2 + 1).also { out -> hrp.forEachIndexed { i, c -> out[i] = c.code ushr 5; out[i + hrp.length + 1] = c.code and 31 } }
    private fun convert(data: IntArray, from: Int, to: Int, pad: Boolean): IntArray {
        var acc = 0; var bits = 0; val out = ArrayList<Int>(); val max = (1 shl to) - 1; val maxAcc = (1 shl (from + to - 1)) - 1
        for (v in data) { require(v ushr from == 0); acc = ((acc shl from) or v) and maxAcc; bits += from; while (bits >= to) { bits -= to; out += (acc ushr bits) and max } }
        if (pad) { if (bits > 0) out += (acc shl (to - bits)) and max } else require(bits < from && ((acc shl (to - bits)) and max) == 0) { "Invalid padding." }
        return out.toIntArray()
    }
    fun encode(hrp: String, data: ByteArray): String {
        val lower = hrp.lowercase(); val values = convert(IntArray(data.size) { data[it].toInt() and 0xFF }, 8, 5, true)
        val check = polymod(expandHrp(lower) + values + IntArray(6)) xor 1
        val text = lower + "1" + (values + IntArray(6) { (check ushr (5 * (5 - it))) and 31 }).joinToString("") { CHARSET[it].toString() }
        return if (hrp == hrp.uppercase()) text.uppercase() else text
    }
    fun decode(text: String): Pair<String, ByteArray> {
        require(text == text.lowercase() || text == text.uppercase()) { "Mixed case." }
        val s = text.lowercase(); val split = s.lastIndexOf('1')
        require(split >= 1 && s.length - split - 1 >= 6 && s.all { it.code in 33..126 }) { "Invalid Bech32." }
        val hrp = s.substring(0, split)
        val values = s.substring(split + 1).map { c -> CHARSET.indexOf(c).also { require(it >= 0) { "Invalid Bech32 character." } } }.toIntArray()
        require(polymod(expandHrp(hrp) + values) == 1) { "Invalid Bech32 checksum." }
        return hrp to convert(values.copyOf(values.size - 6), 5, 8, false).let { b -> ByteArray(b.size) { b[it].toByte() } }
    }
}
