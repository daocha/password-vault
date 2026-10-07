package app.passvault

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** The field of a `totp` record that holds its `otpauth://totp/...` URI (secret and parameters together). */
const val TOTP_LABEL = "Authenticator"

/**
 * One time-based one-time password account (RFC 6238), as found in an `otpauth://totp/` URI. [secret] is the raw key; [issuer] is the
 * service (e.g. "Binance") and [account] the user name shown beside it.
 */
data class TotpAccount(val secret: ByteArray, val issuer: String = "", val account: String = "", val algorithm: String = "SHA1", val digits: Int = 6, val period: Int = 30) {
    init {
        require(secret.isNotEmpty() && secret.size <= 256) { "Invalid authenticator key." }
        require(algorithm in Totp.ALGORITHMS && digits in 6..8 && period in 1..300) { "Unsupported authenticator settings." }
    }
    val secretBase32 get() = Totp.base32(secret)
    /** Canonical URI: the form stored in the vault and backups, and readable by other authenticator apps. */
    fun uri(): String {
        fun enc(s: String) = URLEncoder.encode(s, Charsets.UTF_8).replace("+", "%20")
        val label = if (issuer.isNotEmpty()) enc(issuer) + ":" + enc(account) else enc(account)
        return "otpauth://totp/$label?secret=$secretBase32" + (if (issuer.isNotEmpty()) "&issuer=${enc(issuer)}" else "") + "&algorithm=$algorithm&digits=$digits&period=$period"
    }
    fun code(epochSeconds: Long = System.currentTimeMillis() / 1000) = Totp.code(this, epochSeconds)
    /** Seconds until the current code changes. */
    fun remaining(epochSeconds: Long = System.currentTimeMillis() / 1000) = (period - Math.floorMod(epochSeconds, period.toLong())).toInt()
    /** The record stored for this account; [name] defaults to the issuer, then the account. */
    fun record(name: String = issuer.ifBlank { account }): VaultRecord = VaultRecord(name = name.trim().ifEmpty { "Authenticator" }, type = RecordType.totp, fields = listOf(VaultField(kind = FieldKind.password, label = TOTP_LABEL, value = uri())))
    override fun equals(other: Any?) = other is TotpAccount && secret.contentEquals(other.secret) && issuer == other.issuer && account == other.account && algorithm == other.algorithm && digits == other.digits && period == other.period
    override fun hashCode() = secret.contentHashCode() * 31 + uri().hashCode()
}

/** The authenticator account stored in a `totp` record, or null when its URI is missing or damaged. */
val VaultRecord.totp: TotpAccount? get() = fields.firstOrNull { it.label == TOTP_LABEL }?.value?.let { runCatching { Totp.parseUri(it) }.getOrNull() }

object Totp {
    val ALGORITHMS = listOf("SHA1", "SHA256", "SHA512")
    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    fun code(account: TotpAccount, epochSeconds: Long): String {
        val counter = Math.floorDiv(epochSeconds, account.period.toLong())
        val mac = Mac.getInstance("Hmac" + account.algorithm).apply { init(SecretKeySpec(account.secret, "RAW")) }
        val hash = mac.doFinal(ByteBuffer.allocate(8).putLong(counter).array())
        val offset = hash.last().toInt() and 0x0F
        val binary = ((hash[offset].toInt() and 0x7F) shl 24) or ((hash[offset + 1].toInt() and 0xFF) shl 16) or ((hash[offset + 2].toInt() and 0xFF) shl 8) or (hash[offset + 3].toInt() and 0xFF)
        var modulus = 1; repeat(account.digits) { modulus *= 10 }
        return (binary % modulus).toString().padStart(account.digits, '0')
    }

    fun base32(bytes: ByteArray): String {
        val out = StringBuilder(); var buffer = 0; var bits = 0
        for (b in bytes) { buffer = (buffer shl 8) or (b.toInt() and 0xFF); bits += 8; while (bits >= 5) { out.append(ALPHABET[(buffer shr (bits - 5)) and 31]); bits -= 5 } }
        if (bits > 0) out.append(ALPHABET[(buffer shl (5 - bits)) and 31])
        return out.toString()
    }
    /** Decodes a Base32 key as sites display it: case, spaces, hyphens and `=` padding are ignored. */
    fun decodeBase32(text: String): ByteArray {
        val clean = text.uppercase().filter { it != ' ' && it != '-' && it != '=' }
        require(clean.isNotEmpty() && clean.all { it in ALPHABET }) { "The key must be Base32 (letters A–Z and digits 2–7)." }
        val out = java.io.ByteArrayOutputStream(); var buffer = 0; var bits = 0
        for (c in clean) { buffer = (buffer shl 5) or ALPHABET.indexOf(c); bits += 5; if (bits >= 8) { out.write((buffer shr (bits - 8)) and 0xFF); bits -= 8 } }
        return out.toByteArray().also { require(it.isNotEmpty()) { "The key is too short." } }
    }

    private fun query(raw: String?): Map<String, String> = raw.orEmpty().split('&').filter { it.isNotEmpty() }.associate { part ->
        val i = part.indexOf('='); fun dec(s: String) = URLDecoder.decode(s.replace("+", "%2B"), Charsets.UTF_8)
        if (i < 0) dec(part).lowercase() to "" else dec(part.substring(0, i)).lowercase() to dec(part.substring(i + 1))
    }

    /** Parses `otpauth://totp/Issuer:account?secret=...`. HOTP (counter-based) accounts are rejected. */
    fun parseUri(text: String): TotpAccount {
        val uri = runCatching { URI(text.trim()) }.getOrNull()
        require(uri != null && uri.scheme.equals("otpauth", ignoreCase = true)) { "Not an authenticator QR code." }
        require(uri.host.equals("totp", ignoreCase = true)) { "Only time-based (TOTP) codes are supported." }
        val params = query(uri.rawQuery)
        val label = URLDecoder.decode(uri.rawPath.orEmpty().removePrefix("/").replace("+", "%2B"), Charsets.UTF_8)
        val colon = label.indexOf(':')
        val labelIssuer = if (colon >= 0) label.substring(0, colon).trim() else ""
        val account = (if (colon >= 0) label.substring(colon + 1) else label).trim()
        val algorithm = params["algorithm"]?.uppercase()?.ifEmpty { null } ?: "SHA1"
        val digits = params["digits"]?.toIntOrNull() ?: if (params["digits"].isNullOrEmpty()) 6 else 0
        val period = params["period"]?.toIntOrNull() ?: if (params["period"].isNullOrEmpty()) 30 else 0
        return TotpAccount(decodeBase32(params["secret"] ?: throw IllegalArgumentException("The QR code has no key.")), params["issuer"]?.trim()?.ifEmpty { null } ?: labelIssuer, account, algorithm, digits, period)
    }

    class Migration(val accounts: List<TotpAccount>, val skipped: Int)
    fun isMigration(text: String) = text.trim().startsWith("otpauth-migration://", ignoreCase = true)
    /**
     * Google Authenticator's "Transfer accounts" QR: `otpauth-migration://offline?data=<base64 protobuf>`. Large exports are split over
     * several QR codes; each holds whole accounts, so each one is imported on its own. HOTP accounts are counted in [Migration.skipped].
     */
    fun parseMigration(text: String): Migration {
        require(isMigration(text)) { "Not a Google Authenticator export." }
        val data = query(URI(text.trim()).rawQuery)["data"] ?: throw IllegalArgumentException("The export QR code has no data.")
        val bytes = runCatching { Base64.getDecoder().decode(data.replace('-', '+').replace('_', '/').filter { !it.isWhitespace() }) }.getOrElse { throw IllegalArgumentException("Damaged export QR code.") }
        val accounts = mutableListOf<TotpAccount>(); var skipped = 0
        for ((field, value) in Protobuf(bytes).fields()) if (field == 1 && value is ByteArray) {
            var secret = ByteArray(0); var name = ""; var issuer = ""; var algorithm = 1; var digits = 1; var type = 2
            for ((f, v) in Protobuf(value).fields()) when (f) {
                1 -> secret = v as ByteArray
                2 -> name = (v as ByteArray).toString(Charsets.UTF_8)
                3 -> issuer = (v as ByteArray).toString(Charsets.UTF_8)
                4 -> algorithm = (v as Long).toInt()
                5 -> digits = (v as Long).toInt()
                6 -> type = (v as Long).toInt()
            }
            val algo = when (algorithm) { 0, 1 -> "SHA1"; 2 -> "SHA256"; 3 -> "SHA512"; else -> null }
            if (type == 1 || algo == null || secret.isEmpty()) { skipped++; continue }
            // Exports often repeat the issuer as a prefix of the name ("Binance: me@example.com").
            val account = if (issuer.isNotEmpty() && name.startsWith("$issuer:")) name.substring(issuer.length + 1).trim() else name
            accounts += TotpAccount(secret, issuer.trim(), account, algo, if (digits == 2) 8 else 6, 30)
        }
        require(accounts.isNotEmpty() || skipped > 0) { "The export QR code has no accounts." }
        return Migration(accounts, skipped)
    }

    /** Minimal protobuf reader: varint (as Long) and length-delimited (as ByteArray) fields; others are skipped. */
    private class Protobuf(private val b: ByteArray) {
        private var i = 0
        private fun varint(): Long { var shift = 0; var result = 0L; while (true) { require(i < b.size && shift < 64) { "Damaged export QR code." }; val x = b[i++].toInt(); result = result or ((x and 0x7F).toLong() shl shift); if (x and 0x80 == 0) return result; shift += 7 } }
        fun fields(): List<Pair<Int, Any>> {
            val out = mutableListOf<Pair<Int, Any>>()
            while (i < b.size) {
                val key = varint(); val field = (key ushr 3).toInt()
                when ((key and 7).toInt()) {
                    0 -> out += field to varint()
                    1 -> { require(i + 8 <= b.size) { "Damaged export QR code." }; i += 8 }
                    2 -> { val len = varint(); require(len >= 0 && i + len <= b.size) { "Damaged export QR code." }; out += field to b.copyOfRange(i, i + len.toInt()); i += len.toInt() }
                    5 -> { require(i + 4 <= b.size) { "Damaged export QR code." }; i += 4 }
                    else -> throw IllegalArgumentException("Damaged export QR code.")
                }
            }
            return out
        }
    }
}
