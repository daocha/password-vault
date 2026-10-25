package app.passvault

import org.bouncycastle.crypto.StreamCipher
import org.bouncycastle.crypto.engines.ChaCha7539Engine
import org.bouncycastle.crypto.engines.Salsa20Engine
import org.bouncycastle.crypto.generators.Argon2BytesGenerator
import org.bouncycastle.crypto.params.Argon2Parameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Reads KeePass databases (`.kdbx`, versions 3.1 and 4.x) for import: AES-KDF, Argon2d and Argon2id key derivation; AES-256 and
 * ChaCha20 encryption; Salsa20 and ChaCha20 protected values; password, key file, or both. Twofish databases are refused with advice.
 * Every MAC and hash the format carries is checked before anything is used. BouncyCastle supplies Argon2, ChaCha20 and Salsa20.
 */
object Kdbx {
    private const val SIG1 = 0x9AA2D903.toInt(); private const val SIG2 = 0xB54BFB67.toInt()
    private val AES = uuid("31c1f2e6bf714350be5805216afc5aff"); private val CHACHA = uuid("d6038a2b8b6f4cb5a524339a31dbb59a"); private val TWOFISH = uuid("ad68f29f576f4bb9a36ad47af965346c")
    private val AES_KDF = uuid("c9d9f39a628a4460bf740d08c18a4fea"); private val AES_KDF_KDBX4 = uuid("7c02bb8279a74ac0927d114a00648238")
    private val ARGON2D = uuid("ef636ddf8c29444b91f7a9a403e30a0c"); private val ARGON2ID = uuid("9e298b1956db4773b23dfc3ec6f0a1e6")
    private fun uuid(hex: String) = ByteArray(16) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    /** Argon2 memory above this would not fit an app's memory on most phones. */
    private const val MAX_ARGON2_BYTES = 512L * 1024 * 1024
    /**
     * Key settings that would keep a phone busy for more than about a minute are refused: the import cannot be cancelled, and while it runs
     * the app cannot be unlocked again. KeePass and KeePassXC defaults (tens of thousands to a few million AES rounds, or Argon2 at 64 MiB
     * and a few dozen passes) stay well below these.
     */
    private const val MAX_AES_ROUNDS = 100_000_000L
    private const val MAX_ARGON2_WORK_BYTES = 8L * 1024 * 1024 * 1024 // memory times iterations
    private const val TOO_COSTLY = "This database's key settings need more memory or time than a phone can provide. Lower them in KeePass (Database settings, Security) and export again."

    fun isKdbx(data: ByteArray) = data.size >= 12 && le(data).getInt(0) == SIG1 && le(data).getInt(4) == SIG2
    private fun le(data: ByteArray) = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
    private fun sha256(vararg parts: ByteArray) = MessageDigest.getInstance("SHA-256").run { parts.forEach(::update); digest() }
    private fun sha512(vararg parts: ByteArray) = MessageDigest.getInstance("SHA-512").run { parts.forEach(::update); digest() }
    private fun damaged(): Nothing = throw IllegalArgumentException("The KeePass file is damaged or not supported.")

    /** Imports a database. [password] null means "no password" (key file only), which differs from an empty password. */
    fun import(data: ByteArray, password: String?, keyFile: ByteArray?): List<VaultRecord> {
        val composite = compositeKey(password, keyFile)
        // A truncated or malformed file can fail in a read past its end or in the cipher setup; report it as damaged, not with the raw error.
        val (xml, stream) = try { decrypt(data, composite) }
            catch (_: IndexOutOfBoundsException) { damaged() } catch (_: java.nio.BufferUnderflowException) { damaged() }
            catch (_: java.security.GeneralSecurityException) { damaged() } catch (_: java.io.IOException) { damaged() }
            finally { composite.fill(0) }
        return KeePassXml.records(MiniXml.parse(xml), stream)
    }
    /** Tries the password as given, and with a key file and an empty password also "no password", as KeePass allows both. */
    fun importTyped(data: ByteArray, password: String, keyFile: ByteArray?): List<VaultRecord> {
        if (keyFile == null || password.isNotEmpty()) return import(data, password, keyFile)
        return try { import(data, null, keyFile) } catch (_: AuthenticationFailure) { import(data, "", keyFile) }
    }

    fun compositeKey(password: String?, keyFile: ByteArray?): ByteArray {
        require(password != null || keyFile != null) { "Enter the database password or choose its key file." }
        val parts = listOfNotNull(password?.let { sha256(it.toByteArray(Charsets.UTF_8)) }, keyFile?.let(KeyFile::key))
        return sha256(*parts.toTypedArray())
    }

    private class Header(val major: Int, val fields: Map<Int, ByteArray>, val end: Int)
    private fun header(data: ByteArray): Header {
        require(isKdbx(data)) { "Not a KeePass database." }
        val version = le(data).getInt(8); val major = version ushr 16
        require(major == 3 || major == 4) { "This KeePass database version is not supported. Save it with KeePass 2 or KeePassXC (KDBX 3.1 or 4) first." }
        val fields = mutableMapOf<Int, ByteArray>(); var pos = 12
        while (true) {
            if (pos + (if (major >= 4) 5 else 3) > data.size) damaged()
            val id = data[pos].toInt() and 0xFF
            val size = if (major >= 4) le(data).getInt(pos + 1) else le(data).getShort(pos + 1).toInt() and 0xFFFF
            pos += if (major >= 4) 5 else 3
            if (size < 0 || pos + size > data.size) damaged()
            fields[id] = data.copyOfRange(pos, pos + size); pos += size
            if (id == 0) break
        }
        return Header(major, fields, pos)
    }

    /** Key derivation from the header (KDBX 3: fields 5/6, AES-KDF; KDBX 4: the VariantDictionary in field 11). */
    private fun transform(h: Header, composite: ByteArray): ByteArray {
        if (h.major < 4) return aesKdf(composite, h.fields[5] ?: damaged(), le(h.fields[6]?.takeIf { it.size == 8 } ?: damaged()).getLong(0))
        val params = variantDictionary(h.fields[11] ?: damaged())
        val kdf = params["\$UUID"] as? ByteArray ?: damaged()
        return when {
            kdf.contentEquals(AES_KDF) || kdf.contentEquals(AES_KDF_KDBX4) -> aesKdf(composite, params["S"] as? ByteArray ?: damaged(), (params["R"] as? Long) ?: damaged())
            kdf.contentEquals(ARGON2D) || kdf.contentEquals(ARGON2ID) -> {
                val memory = (params["M"] as? Long) ?: damaged(); val iterations = (params["I"] as? Long) ?: damaged()
                val parallelism = ((params["P"] as? Int) ?: (params["P"] as? Long)?.toInt()) ?: damaged(); val version = (params["V"] as? Int) ?: 0x13
                require(version == 0x10 || version == 0x13) { "The KeePass file is damaged or not supported." }
                require(memory in 8L * 1024..MAX_ARGON2_BYTES && iterations in 1..MAX_ARGON2_WORK_BYTES / memory && parallelism in 1..256) { TOO_COSTLY }
                val builder = Argon2Parameters.Builder(if (kdf.contentEquals(ARGON2D)) Argon2Parameters.ARGON2_d else Argon2Parameters.ARGON2_id)
                    .withVersion(if (version == 0x10) Argon2Parameters.ARGON2_VERSION_10 else Argon2Parameters.ARGON2_VERSION_13)
                    .withIterations(iterations.toInt()).withMemoryAsKB((memory / 1024).toInt()).withParallelism(parallelism).withSalt(params["S"] as? ByteArray ?: damaged())
                (params["K"] as? ByteArray)?.let(builder::withSecret); (params["A"] as? ByteArray)?.let(builder::withAdditional)
                val out = ByteArray(32)
                try { Argon2BytesGenerator().apply { init(builder.build()) }.generateBytes(composite, out) }
                catch (_: OutOfMemoryError) { throw IllegalArgumentException("Not enough memory to open this database on this phone.") }
                out
            }
            else -> throw IllegalArgumentException("This database uses a key derivation PassVault does not support.")
        }
    }
    /** KeePass's AES-KDF is defined as repeated AES-ECB encryption of the key; ECB is not used to encrypt data. */
    @android.annotation.SuppressLint("GetInstance")
    private fun aesKdf(composite: ByteArray, seed: ByteArray, rounds: Long): ByteArray {
        require(seed.size == 32 && rounds >= 0) { "The KeePass file is damaged or not supported." }
        require(rounds <= MAX_AES_ROUNDS) { TOO_COSTLY }
        val cipher = Cipher.getInstance("AES/ECB/NoPadding").apply { init(Cipher.ENCRYPT_MODE, SecretKeySpec(seed, "AES")) }
        var a = composite.copyOf(); var b = ByteArray(32)
        for (i in 0 until rounds) { cipher.update(a, 0, 32, b, 0); val t = a; a = b; b = t }
        return sha256(a)
    }
    /** KDBX 4 VariantDictionary: u16 version, then entries of type, i32 name length, name, i32 value length, value. */
    internal fun variantDictionary(bytes: ByteArray): Map<String, Any> {
        val buffer = le(bytes); if (bytes.size < 2 || (buffer.getShort(0).toInt() and 0xFF00) != 0x0100) damaged()
        val out = mutableMapOf<String, Any>(); var pos = 2
        while (pos < bytes.size) {
            val type = bytes[pos].toInt() and 0xFF; pos++
            if (type == 0) break
            if (pos + 4 > bytes.size) damaged(); val nameLength = buffer.getInt(pos); pos += 4
            if (nameLength < 0 || pos + nameLength + 4 > bytes.size) damaged()
            val name = String(bytes, pos, nameLength, Charsets.UTF_8); pos += nameLength
            val length = buffer.getInt(pos); pos += 4; if (length < 0 || pos + length > bytes.size) damaged()
            if (type in setOf(0x04, 0x0C) && length != 4 || type in setOf(0x05, 0x0D) && length != 8 || type == 0x08 && length != 1) damaged()
            out[name] = when (type) {
                0x04 -> buffer.getInt(pos); 0x05 -> buffer.getLong(pos); 0x08 -> bytes[pos].toInt() != 0; 0x0C -> buffer.getInt(pos); 0x0D -> buffer.getLong(pos)
                0x18 -> String(bytes, pos, length, Charsets.UTF_8); else -> bytes.copyOfRange(pos, pos + length)
            }
            pos += length
        }
        return out
    }

    /** The database XML and the protected-value stream. Throws [AuthenticationFailure] for wrong credentials. */
    private fun decrypt(data: ByteArray, composite: ByteArray): Pair<String, StreamCipher?> {
        val h = header(data)
        val cipherId = h.fields[2] ?: damaged()
        require(!cipherId.contentEquals(TWOFISH)) { "This database is encrypted with Twofish. In KeePass, change the encryption to AES or ChaCha20 (Database settings, Security), save, and import again." }
        require(cipherId.contentEquals(AES) || cipherId.contentEquals(CHACHA)) { "This database uses an encryption PassVault does not support." }
        val masterSeed = h.fields[4] ?: damaged(); val iv = h.fields[7] ?: damaged()
        val transformed = transform(h, composite)
        val key = sha256(masterSeed, transformed)
        val compressed = (h.fields[3]?.let { le(it).getInt(0) } ?: 0) == 1
        if (h.major < 4) {
            val plain = try { cipher(cipherId, key, iv, data.copyOfRange(h.end, data.size)) } catch (_: javax.crypto.BadPaddingException) { throw AuthenticationFailure() }
            val start = h.fields[9] ?: damaged()
            if (plain.size < 32 || !MessageDigest.isEqual(plain.copyOfRange(0, 32), start)) throw AuthenticationFailure()
            val payload = hashedBlocks(plain, 32)
            val xml = if (compressed) gunzip(payload) else payload
            val streamId = h.fields[10]?.let { le(it).getInt(0) } ?: 0
            return xml.toString(Charsets.UTF_8) to innerStream(streamId, h.fields[8] ?: ByteArray(0))
        }
        if (data.size < h.end + 64) damaged()
        if (!MessageDigest.isEqual(sha256(data.copyOfRange(0, h.end)), data.copyOfRange(h.end, h.end + 32))) damaged()
        val hmacBase = sha512(masterSeed, transformed, byteArrayOf(1))
        fun blockKey(index: Long) = sha512(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(index).array(), hmacBase)
        fun hmac(key: ByteArray, vararg parts: ByteArray) = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(key, "HmacSHA256")); parts.forEach(::update); doFinal() }
        if (!MessageDigest.isEqual(hmac(blockKey(-1L), data.copyOfRange(0, h.end)), data.copyOfRange(h.end + 32, h.end + 64))) throw AuthenticationFailure()
        val encrypted = java.io.ByteArrayOutputStream(); var pos = h.end + 64; var index = 0L
        while (true) {
            if (pos + 36 > data.size) damaged()
            val mac = data.copyOfRange(pos, pos + 32); val size = le(data).getInt(pos + 32); if (size < 0 || pos + 36 + size > data.size) damaged()
            val block = data.copyOfRange(pos + 36, pos + 36 + size)
            val header = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putLong(index).putInt(size).array()
            if (!MessageDigest.isEqual(hmac(blockKey(index), header, block), mac)) damaged()
            pos += 36 + size; index++
            if (size == 0) break
            encrypted.write(block); require(encrypted.size() <= Records.MAX_BYTES * 2) { "The database is too large." }
        }
        val plain = cipher(cipherId, key, iv, encrypted.toByteArray())
        val payload = if (compressed) gunzip(plain) else plain
        // Inner header: id u8, size i32, data. 1 = stream id, 2 = stream key, 3 = attachment (not imported), 0 = end.
        var streamId = 0; var streamKey = ByteArray(0); var p = 0
        while (true) {
            if (p + 5 > payload.size) damaged()
            val id = payload[p].toInt() and 0xFF; val size = le(payload).getInt(p + 1); p += 5
            if (size < 0 || p + size > payload.size) damaged()
            when (id) { 1 -> streamId = le(payload.copyOfRange(p, p + size)).getInt(0); 2 -> streamKey = payload.copyOfRange(p, p + size) }
            p += size
            if (id == 0) break
        }
        return String(payload, p, payload.size - p, Charsets.UTF_8) to innerStream(streamId, streamKey)
    }
    // KeePass specifies AES-CBC for these existing files. This importer only decrypts; KDBX 4 verifies block HMACs before this call,
    // and KDBX 3 checks its stream-start bytes and block hashes afterward. AES-GCM would not read KeePass AES databases.
    private fun cipher(id: ByteArray, key: ByteArray, iv: ByteArray, input: ByteArray): ByteArray =
        if (id.contentEquals(AES)) Cipher.getInstance("AES/CBC/PKCS5Padding").run { if (iv.size != 16) damaged(); init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv)); doFinal(input) }
        else { require(iv.size == 12) { "The KeePass file is damaged or not supported." }; ChaCha7539Engine().run { init(false, ParametersWithIV(KeyParameter(key), iv)); ByteArray(input.size).also { processBytes(input, 0, input.size, it, 0) } } }
    /** KDBX 3 hashed block stream: u32 index, 32-byte SHA-256, u32 size, data; a zero-size block ends it. */
    private fun hashedBlocks(data: ByteArray, start: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(); var pos = start; var expected = 0
        while (true) {
            if (pos + 40 > data.size) damaged()
            val index = le(data).getInt(pos); val hash = data.copyOfRange(pos + 4, pos + 36); val size = le(data).getInt(pos + 36); pos += 40
            if (index != expected++ || size < 0 || pos + size > data.size) damaged()
            if (size == 0) break
            val block = data.copyOfRange(pos, pos + size); pos += size
            if (!MessageDigest.isEqual(sha256(block), hash)) damaged()
            out.write(block); require(out.size() <= Records.MAX_BYTES * 2) { "The database is too large." }
        }
        return out.toByteArray()
    }
    private fun gunzip(data: ByteArray): ByteArray = java.util.zip.GZIPInputStream(data.inputStream()).use { input ->
        val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
        while (true) { val n = input.read(buffer); if (n < 0) break; require(out.size() + n <= Records.MAX_BYTES * 4) { "The database is too large." }; out.write(buffer, 0, n) }
        out.toByteArray()
    }
    private fun innerStream(id: Int, key: ByteArray): StreamCipher? = when (id) {
        0 -> null
        2 -> Salsa20Engine().apply { init(false, ParametersWithIV(KeyParameter(sha256(key)), byteArrayOf(0xE8.toByte(), 0x30, 0x09, 0x4B, 0x97.toByte(), 0x20, 0x5D, 0x2A))) }
        3 -> sha512(key).let { h -> ChaCha7539Engine().apply { init(false, ParametersWithIV(KeyParameter(h.copyOfRange(0, 32)), h.copyOfRange(32, 44))) } }
        else -> throw IllegalArgumentException("This database protects its fields with a method PassVault does not support.")
    }
}

/** KeePass key files: XML version 1.0 (Base64) or 2.0 (hex with a check hash), 32 raw bytes, 64 hex digits, or any other file (hashed). */
object KeyFile {
    fun key(file: ByteArray): ByteArray {
        if (file.size == 32) return file.copyOf()
        val text = runCatching { Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(file)).toString() }.getOrNull()
        if (file.size == 64 && text != null && text.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return ByteArray(32) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        if (text != null && text.trimStart('\uFEFF', ' ', '\t', '\r', '\n').startsWith("<")) {
            val root = runCatching { MiniXml.parse(text) }.getOrNull()
            if (root?.name == "KeyFile") {
                val version = root.child("Meta")?.child("Version")?.text?.trim().orEmpty()
                val data = root.child("Key")?.child("Data") ?: throw IllegalArgumentException("The key file is damaged.")
                if (version.startsWith("2")) {
                    val hex = data.text.filter { !it.isWhitespace() }
                    require(hex.length == 64 && hex.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) { "The key file is damaged." }
                    val bytes = ByteArray(32) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
                    data.attributes["Hash"]?.let { check -> require(MessageDigest.getInstance("SHA-256").digest(bytes).copyOfRange(0, 4).joinToString("") { "%02x".format(it) }.equals(check.trim(), true)) { "The key file is damaged." } }
                    return bytes
                }
                return runCatching { Base64.getDecoder().decode(data.text.trim()) }.getOrElse { throw IllegalArgumentException("The key file is damaged.") }
            }
        }
        return MessageDigest.getInstance("SHA-256").digest(file)
    }
}

/** KeePass XML (from a `.kdbx` or KeePass's XML export) to PassVault records. Entries in the recycle bin are skipped. */
internal object KeePassXml {
    private val standard = setOf("Title", "UserName", "Password", "URL", "Notes")
    private val otpKeys = setOf("otp", "TOTP Seed", "TOTP Settings", "TimeOtp-Secret", "TimeOtp-Secret-Hex", "TimeOtp-Secret-Base32", "TimeOtp-Secret-Base64", "TimeOtp-Length", "TimeOtp-Period", "TimeOtp-Algorithm")
    /** KDBX 3.1 writes ISO times; KDBX 4 writes Base64 of int64 seconds since 0001-01-01. */
    fun time(text: String?): Instant? {
        val t = text?.trim().orEmpty(); if (t.isEmpty()) return null
        if ('-' in t) return runCatching { Instant.parse(t) }.getOrNull()
        val bytes = runCatching { Base64.getDecoder().decode(t) }.getOrNull()?.takeIf { it.size == 8 } ?: return null
        return runCatching { Instant.ofEpochSecond(ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).long - 62_135_596_800L) }.getOrNull()
    }
    fun records(root: XmlElement, stream: StreamCipher?): List<VaultRecord> {
        require(root.name == "KeePassFile") { "Unrecognised XML file. PassVault reads KeePass XML exports." }
        // Protected values are XORed with one key stream, consumed in document order across the whole file.
        root.walk { e ->
            if (e.attributes["Protected"].equals("True", ignoreCase = true)) {
                val cipher = stream ?: throw IllegalArgumentException("The KeePass file is damaged or not supported.")
                val bytes = runCatching { Base64.getDecoder().decode(e.text.trim()) }.getOrElse { throw IllegalArgumentException("The KeePass file is damaged or not supported.") }
                val plain = ByteArray(bytes.size); cipher.processBytes(bytes, 0, bytes.size, plain, 0)
                e.text = plain.toString(Charsets.UTF_8); plain.fill(0)
            }
        }
        val meta = root.child("Meta")
        val recycleBin = meta?.child("RecycleBinUUID")?.text?.trim()?.takeIf { meta.child("RecycleBinEnabled")?.text?.trim().equals("True", true) }
        val top = root.child("Root")?.child("Group") ?: return emptyList()
        val out = mutableListOf<VaultRecord>()
        fun visit(group: XmlElement, path: String) {
            for (entry in group.all("Entry")) out += entry(entry, path)
            for (child in group.all("Group")) {
                if (recycleBin != null && child.child("UUID")?.text?.trim() == recycleBin) continue
                val name = child.child("Name")?.text?.trim().orEmpty()
                visit(child, if (path.isEmpty()) name else "$path/$name")
            }
        }
        visit(top, "")
        return Records.validate(out)
    }
    private class Strings(entry: XmlElement) {
        val values = LinkedHashMap<String, String>(); val secret = mutableSetOf<String>()
        init { for (s in entry.all("String")) { val key = s.child("Key")?.text ?: continue; val value = s.child("Value") ?: continue
            values[key] = value.text; if (value.attributes["Protected"].equals("True", true) || value.attributes["ProtectInMemory"].equals("True", true)) secret += key } }
        operator fun get(key: String) = values[key].orEmpty()
    }
    private fun entry(entry: XmlElement, group: String): List<VaultRecord> {
        val s = Strings(entry)
        if (s.values.values.all { it.isBlank() }) return emptyList()
        val times = entry.child("Times")
        val updated = time(times?.child("LastModificationTime")?.text)
        val expires = if (times?.child("Expires")?.text?.trim().equals("True", true)) time(times?.child("ExpiryTime")?.text)?.let(ImportBuilder::localDate).orEmpty() else ""
        // History versions (oldest first) then the entry itself: each password that was replaced is kept with the time it was replaced.
        val versions = entry.child("History")?.all("Entry").orEmpty().map { Strings(it)["Password"] to time(it.child("Times")?.child("LastModificationTime")?.text) } + (s["Password"] to updated)
        val history = versions.zipWithNext().filter { (old, next) -> old.first.isNotEmpty() && old.first != next.first }.map { (old, next) -> PasswordChange(old.first, (next.second ?: old.second)?.epochSecond ?: 0) }
        val name = ImportBuilder.name(s["Title"], s["URL"])
        val totp = totpUri(s, name)
        val usableTotp = ImportBuilder.totp(totp, name, s["UserName"]) != null
        // Keep the original KeePass fields if conversion fails; otherwise an unsupported key or setting disappears on import.
        val extra = s.values.filterKeys { it !in standard && (!usableTotp || it !in otpKeys) }
            .map { (key, value) -> ImportBuilder.extra(key, value, key in otpKeys || key in s.secret) }
        return ImportBuilder.login(name, s["URL"], s["UserName"], s["Password"], s["Notes"], group, updatedAt = updated, expires = expires, history = history, extra = extra, totp = if (usableTotp) totp else "")
    }
    /** KeePassXC's `otp` URI, KeePass 2.47+ `TimeOtp-*` fields, or the older `TOTP Seed` / `TOTP Settings` pair, as an otpauth URI. */
    private fun totpUri(s: Strings, name: String): String {
        if (s["otp"].isNotBlank()) return s["otp"]
        fun account(secret: ByteArray, digits: Int, period: Int, algorithm: String) = runCatching { TotpAccount(secret, issuer = name, account = s["UserName"], algorithm = algorithm, digits = digits, period = period).uri() }.getOrNull()
        fun setting(value: String, default: Int) = if (value.isBlank()) default else value.trim().toIntOrNull()
        val secret = when {
            s["TimeOtp-Secret-Base32"].isNotBlank() -> runCatching { Totp.decodeBase32(s["TimeOtp-Secret-Base32"]) }.getOrNull()
            s["TimeOtp-Secret-Hex"].isNotBlank() -> s["TimeOtp-Secret-Hex"].filter { !it.isWhitespace() }.takeIf { it.length % 2 == 0 }?.let { h -> runCatching { ByteArray(h.length / 2) { h.substring(it * 2, it * 2 + 2).toInt(16).toByte() } }.getOrNull() }
            s["TimeOtp-Secret-Base64"].isNotBlank() -> runCatching { Base64.getDecoder().decode(s["TimeOtp-Secret-Base64"].trim()) }.getOrNull()
            s["TimeOtp-Secret"].isNotEmpty() -> s["TimeOtp-Secret"].toByteArray(Charsets.UTF_8)
            else -> null
        }
        if (secret != null) {
            val algorithm = when (s["TimeOtp-Algorithm"].trim().uppercase().replace("-", "")) {
                "", "HMACSHA1", "SHA1" -> "SHA1"; "HMACSHA256", "SHA256" -> "SHA256"; "HMACSHA512", "SHA512" -> "SHA512"; else -> return ""
            }
            return account(secret, setting(s["TimeOtp-Length"], 6) ?: return "", setting(s["TimeOtp-Period"], 30) ?: return "", algorithm) ?: ""
        }
        if (s["TOTP Seed"].isNotBlank()) {
            val settings = s["TOTP Settings"].split(';')
            val seed = runCatching { Totp.decodeBase32(s["TOTP Seed"]) }.getOrNull() ?: return s["TOTP Seed"]
            return account(seed, setting(settings.getOrNull(1).orEmpty(), 6) ?: return "", setting(settings.firstOrNull().orEmpty(), 30) ?: return "", "SHA1") ?: ""
        }
        return ""
    }
}
