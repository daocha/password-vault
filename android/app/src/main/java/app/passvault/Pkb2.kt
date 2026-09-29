package app.passvault

import java.security.MessageDigest
import java.time.Instant
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** scrypt (RFC 7914) in plain Kotlin: PKB2 backups use N=65536, r=8, p=1, which libsodium's Java wrapper does not expose. */
object Scrypt {
    /** PBKDF2-HMAC-SHA256 with a single iteration (all scrypt needs), taking raw key bytes. */
    private fun pbkdf2One(password: ByteArray, salt: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256"); mac.init(SecretKeySpec(if (password.isEmpty()) ByteArray(64) else password, "HmacSHA256")) // an empty HMAC key equals a zero-padded one
        val out = ByteArray(length); var block = 1; var pos = 0
        while (pos < length) {
            mac.update(salt); mac.update(byteArrayOf((block ushr 24).toByte(), (block ushr 16).toByte(), (block ushr 8).toByte(), block.toByte()))
            val t = mac.doFinal(); val n = minOf(t.size, length - pos); System.arraycopy(t, 0, out, pos, n); pos += n; block++
        }
        return out
    }
    private fun salsa8(b: IntArray) {
        val x = b.copyOf()
        fun r(a: Int, n: Int) = (a shl n) or (a ushr (32 - n))
        repeat(4) {
            x[4] = x[4] xor r(x[0] + x[12], 7); x[8] = x[8] xor r(x[4] + x[0], 9); x[12] = x[12] xor r(x[8] + x[4], 13); x[0] = x[0] xor r(x[12] + x[8], 18)
            x[9] = x[9] xor r(x[5] + x[1], 7); x[13] = x[13] xor r(x[9] + x[5], 9); x[1] = x[1] xor r(x[13] + x[9], 13); x[5] = x[5] xor r(x[1] + x[13], 18)
            x[14] = x[14] xor r(x[10] + x[6], 7); x[2] = x[2] xor r(x[14] + x[10], 9); x[6] = x[6] xor r(x[2] + x[14], 13); x[10] = x[10] xor r(x[6] + x[2], 18)
            x[3] = x[3] xor r(x[15] + x[11], 7); x[7] = x[7] xor r(x[3] + x[15], 9); x[11] = x[11] xor r(x[7] + x[3], 13); x[15] = x[15] xor r(x[11] + x[7], 18)
            x[1] = x[1] xor r(x[0] + x[3], 7); x[2] = x[2] xor r(x[1] + x[0], 9); x[3] = x[3] xor r(x[2] + x[1], 13); x[0] = x[0] xor r(x[3] + x[2], 18)
            x[6] = x[6] xor r(x[5] + x[4], 7); x[7] = x[7] xor r(x[6] + x[5], 9); x[4] = x[4] xor r(x[7] + x[6], 13); x[5] = x[5] xor r(x[4] + x[7], 18)
            x[11] = x[11] xor r(x[10] + x[9], 7); x[8] = x[8] xor r(x[11] + x[10], 9); x[9] = x[9] xor r(x[8] + x[11], 13); x[10] = x[10] xor r(x[9] + x[8], 18)
            x[12] = x[12] xor r(x[15] + x[14], 7); x[13] = x[13] xor r(x[12] + x[15], 9); x[14] = x[14] xor r(x[13] + x[12], 13); x[15] = x[15] xor r(x[14] + x[13], 18)
        }
        for (i in 0 until 16) b[i] += x[i]
    }
    private fun blockMix(b: IntArray, y: IntArray, r: Int) {
        val x = IntArray(16); System.arraycopy(b, (2 * r - 1) * 16, x, 0, 16)
        for (i in 0 until 2 * r) {
            for (k in 0 until 16) x[k] = x[k] xor b[i * 16 + k]
            salsa8(x)
            System.arraycopy(x, 0, y, ((i and 1) * r + i / 2) * 16, 16)
        }
        System.arraycopy(y, 0, b, 0, 32 * r)
    }
    fun derive(password: ByteArray, salt: ByteArray, n: Int, r: Int, p: Int, length: Int): ByteArray {
        require(n > 1 && n and (n - 1) == 0 && r > 0 && p > 0)
        val blockInts = 32 * r
        val b = pbkdf2One(password, salt, p * 128 * r)
        val v = IntArray(blockInts * n); val y = IntArray(blockInts); val x = IntArray(blockInts)
        for (i in 0 until p) {
            for (k in 0 until blockInts) { val o = i * 128 * r + k * 4; x[k] = (b[o].toInt() and 255) or ((b[o + 1].toInt() and 255) shl 8) or ((b[o + 2].toInt() and 255) shl 16) or ((b[o + 3].toInt() and 255) shl 24) }
            for (j in 0 until n) { System.arraycopy(x, 0, v, j * blockInts, blockInts); blockMix(x, y, r) }
            for (j in 0 until n) { val idx = x[(2 * r - 1) * 16] and (n - 1); for (k in 0 until blockInts) x[k] = x[k] xor v[idx * blockInts + k]; blockMix(x, y, r) }
            for (k in 0 until blockInts) { val o = i * 128 * r + k * 4; b[o] = x[k].toByte(); b[o + 1] = (x[k] ushr 8).toByte(); b[o + 2] = (x[k] ushr 16).toByte(); b[o + 3] = (x[k] ushr 24).toByte() }
        }
        v.fill(0); x.fill(0); y.fill(0)
        return pbkdf2One(password, b, length).also { b.fill(0) }
    }
}

/** Minimal order-preserving JSON reader. PKB2 subfields can repeat a key ("t"), which org.json rejects or silently collapses. */
private class Json(private val s: String) {
    private var i = 0
    class Obj(val entries: List<Pair<String, Any?>>) {
        fun all(key: String) = entries.filter { it.first == key }.map { it.second }
        fun get(key: String) = entries.firstOrNull { it.first == key }?.second
        fun str(key: String) = get(key) as? String
    }
    fun parse(): Any? = value().also { ws(); require(i == s.length) { "Unexpected data after the records." } }
    private fun ws() { while (i < s.length && s[i].isWhitespace()) i++ }
    private fun value(): Any? {
        ws(); require(i < s.length) { "Truncated records." }
        return when (s[i]) {
            '{' -> { i++; val list = mutableListOf<Pair<String, Any?>>(); ws(); if (s[i] == '}') i++ else while (true) { ws(); val k = string(); ws(); require(s[i++] == ':'); list.add(k to value()); ws(); if (s[i] == ',') i++ else { require(s[i++] == '}'); break } }; Obj(list) }
            '[' -> { i++; val list = mutableListOf<Any?>(); ws(); if (s[i] == ']') i++ else while (true) { list.add(value()); ws(); if (s[i] == ',') i++ else { require(s[i++] == ']'); break } }; list }
            '"' -> string()
            else -> { val start = i; while (i < s.length && s[i] !in ",]} \n\r\t") i++; when (val t = s.substring(start, i)) { "true" -> true; "false" -> false; "null" -> null; else -> t.toDoubleOrNull()?.let { if (it % 1.0 == 0.0 && Math.abs(it) < 9e15) it.toLong() else it } ?: error("Invalid JSON value.") } }
        }
    }
    private fun string(): String {
        require(s[i++] == '"'); val sb = StringBuilder()
        while (true) {
            require(i < s.length) { "Unterminated string." }
            val c = s[i++]
            when (c) {
                '"' -> return sb.toString()
                '\\' -> when (val e = s[i++]) { 'n' -> sb.append('\n'); 't' -> sb.append('\t'); 'r' -> sb.append('\r'); 'b' -> sb.append('\b'); 'f' -> sb.append('\u000c'); 'u' -> { sb.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4 }; else -> sb.append(e) }
                else -> sb.append(c)
            }
        }
    }
}

/**
 * Reader for BlackBerry Password Keeper `.pkb2` backups (format taken from the app's own exporter).
 *
 *     "PKB2" | u32be version (1 or 2) | salt 32 | iv 16
 *            | u32be n1 | keys (AES-CBC, n1 bytes) | HMAC-SHA256(macKey, keys) 32
 *            | u32be n2 | records (AES-CBC, n2 bytes) | HMAC-SHA256(recordsMacKey, records) 32
 *
 * Version 2 derives 64 bytes with scrypt(N=65536, r=8, p=1); version 1 used PBKDF2-HMAC-SHA256 (10000). The first half is the
 * AES key for `keys`, the second the HMAC key. `keys` = recordsKey 32 | recordsMacKey 32 | recordsIv 16. Records are JSON.
 */
object Pkb2 {
    private val magic = "PKB2".toByteArray()
    fun isPkb2(data: ByteArray) = data.size >= 4 && data.copyOfRange(0, 4).contentEquals(magic)
    private fun int(d: ByteArray, o: Int) = ((d[o].toInt() and 255) shl 24) or ((d[o + 1].toInt() and 255) shl 16) or ((d[o + 2].toInt() and 255) shl 8) or (d[o + 3].toInt() and 255)
    private fun hmac(key: ByteArray, data: ByteArray) = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(key, "HmacSHA256")); doFinal(data) }
    private fun cbc(key: ByteArray, iv: ByteArray, data: ByteArray) = Cipher.getInstance("AES/CBC/PKCS5Padding").run { init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv)); doFinal(data) }

    fun import(data: ByteArray, password: String): List<VaultRecord> {
        require(isPkb2(data) && data.size >= 8 + 48 + 4) { "Not a Password Keeper backup." }
        val version = int(data, 4); require(version == 1 || version == 2) { "Unsupported Password Keeper backup version $version." }
        val salt = data.copyOfRange(8, 40); val iv = data.copyOfRange(40, 56)
        val n1 = int(data, 56); require(n1 in 16..data.size && 60 + n1 + 32 + 4 <= data.size) { "Damaged Password Keeper backup." }
        val keys = data.copyOfRange(60, 60 + n1); val mac1 = data.copyOfRange(60 + n1, 92 + n1)
        val n2 = int(data, 92 + n1); require(n2 in 16..data.size && 96 + n1 + n2 + 32 == data.size) { "Damaged Password Keeper backup." }
        val records = data.copyOfRange(96 + n1, 96 + n1 + n2); val mac2 = data.copyOfRange(96 + n1 + n2, data.size)
        val pw = password.toByteArray(Charsets.UTF_8)
        val derived = try { if (version == 2) Scrypt.derive(pw, salt, 65536, 8, 1, 64) else pbkdf2(pw, salt) } finally { pw.fill(0) }
        try {
            if (!MessageDigest.isEqual(hmac(derived.copyOfRange(32, 64), keys), mac1)) throw AuthenticationFailure()
            val inner = try { cbc(derived.copyOfRange(0, 32), iv, keys) } catch (e: Exception) { throw AuthenticationFailure() }
            try {
                require(inner.size >= 80) { "Damaged Password Keeper backup." }
                if (!MessageDigest.isEqual(hmac(inner.copyOfRange(32, 64), records), mac2)) throw IllegalArgumentException("The backup is damaged (integrity check failed).")
                val plain = cbc(inner.copyOfRange(0, 32), inner.copyOfRange(64, 80), records)
                try { return parse(plain.toString(Charsets.UTF_8)) } finally { plain.fill(0) }
            } finally { inner.fill(0) }
        } finally { derived.fill(0) }
    }
    private fun pbkdf2(password: ByteArray, salt: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256"); mac.init(SecretKeySpec(password, "HmacSHA256"))
        val out = ByteArray(64)
        for (block in 1..2) {
            mac.update(salt); mac.update(byteArrayOf(0, 0, 0, block.toByte()))
            var u = mac.doFinal(); val t = u.copyOf()
            repeat(9999) { u = mac.doFinal(u); for (k in t.indices) t[k] = (t[k].toInt() xor u[k].toInt()).toByte() }
            System.arraycopy(t, 0, out, (block - 1) * 32, 32)
        }
        return out
    }

    /** Password Keeper records to PassVault records. Fields keep their original order; password history is attached to its password field. */
    internal fun parse(text: String): List<VaultRecord> {
        val root = Json(text).parse() as? Json.Obj ?: error("Unrecognised Password Keeper data.")
        val list = root.get("records") as? List<*> ?: return emptyList()
        return Records.validate(list.map { toRecord(it as? Json.Obj ?: error("Unrecognised Password Keeper record.")) })
    }
    private fun toRecord(r: Json.Obj): VaultRecord {
        var name = ""; var website = ""; val fields = mutableListOf<VaultField>()
        fun add(kind: FieldKind, label: String?, value: String, question: String = "", history: List<PasswordChange> = emptyList()) { fields.add(VaultField(kind = kind, label = label?.takeIf { it.isNotEmpty() } ?: kind.defaultLabel, value = value, question = question, history = history)) }
        for (f in (r.get("f") as? List<*>).orEmpty()) {
            f as? Json.Obj ?: continue
            val label = f.str("n"); val value = f.str("v").orEmpty()
            when (f.str("t")) {
                "t" -> if (name.isEmpty()) name = value else if (value.isNotEmpty()) add(FieldKind.note, label ?: "Title", value)
                "w" -> if (website.isEmpty()) website = value else if (value.isNotEmpty()) add(FieldKind.note, label ?: "Website", value)
                "u" -> add(FieldKind.username, label, value)
                "p" -> {
                    // Earlier passwords go into the field's own history (a subfield writes "t" twice: the type, then the change time).
                    val history = (f.get("sf") as? List<*>).orEmpty().filterIsInstance<Json.Obj>().filter { it.all("t").firstOrNull() == "hp" }.mapNotNull { sf ->
                        val old = sf.str("pw")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                        PasswordChange(old, (sf.all("t").getOrNull(1) as? Long) ?: 0L)
                    }
                    add(FieldKind.password, label, value, history = history)
                }
                "n" -> add(FieldKind.note, label, value)
                "sq" -> add(FieldKind.question, null, value, question = label.orEmpty())
                "c" -> add(FieldKind.note, label ?: "Custom", value)
                "lst" -> {
                    val items = (f.get("sf") as? List<*>).orEmpty().filterIsInstance<Json.Obj>().filter { it.str("t") == "chk" }.sortedBy { (it.get("lst_ord") as? Long) ?: 0L }
                    if (value.isNotEmpty()) add(FieldKind.note, label ?: "List", value)
                    items.forEach { add(FieldKind.note, label ?: "List item", (if (it.get("lst_chk") == true) "[x] " else "[ ] ") + it.str("lst_lbl").orEmpty()) }
                }
                // Icons, trusted-application lists and bare timestamps are Password Keeper internals.
            }
        }
        val modified = (r.get("lm") as? Long)?.let { runCatching { Instant.ofEpochSecond(it).toString() }.getOrNull() } ?: Instant.now().toString()
        return VaultRecord(name = name.ifEmpty { "Untitled" }, website = website, favorite = r.get("fav") == true, updatedAt = modified, fields = fields, legacy = r.str("u")?.let { mapOf("uid" to it) } ?: emptyMap())
    }
}
