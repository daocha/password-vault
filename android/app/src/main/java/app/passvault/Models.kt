package app.passvault

import androidx.annotation.StringRes
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

enum class FieldKind { username, password, note, question }
/** `login` records are passwords; `seed` records hold a BIP-39 mnemonic and never leave the app in plaintext CSV. */
enum class RecordType { login, seed }
const val SEED_LABEL = "Seed phrase"
const val PRIVATE_KEY_LABEL = "Private key"
const val SEED_PASSPHRASE_LABEL = "BIP-39 passphrase"
/** An earlier value of a password or security answer, with the time it was replaced. Created when a saved value changes and by Password Keeper (.pkb2) imports; separate from any field the user names "Previous password". */
data class PasswordChange(val value: String, val changedAtEpochSeconds: Long) {
    fun json() = JSONObject().put("value", value).put("changedAt", changedAtEpochSeconds)
    companion object { fun from(j: JSONObject) = PasswordChange(j.getString("value"), j.getLong("changedAt")) }
}
data class VaultField(val id: String = UUID.randomUUID().toString(), val kind: FieldKind, val label: String, val value: String = "", val question: String = "", val history: List<PasswordChange> = emptyList()) {
    val secret get() = kind == FieldKind.password || kind == FieldKind.question
    /** Password history, most recently changed first. */
    val historyNewestFirst get() = history.sortedByDescending { it.changedAtEpochSeconds }
    fun json() = JSONObject().put("id", id).put("kind", kind.name).put("label", label).put("value", value).put("question", question).apply { if (history.isNotEmpty()) put("history", JSONArray(history.map { it.json() })) }
    companion object {
        fun from(j: JSONObject) = VaultField(j.getString("id"), FieldKind.valueOf(j.getString("kind")), j.getString("label"), j.getString("value"), j.getString("question"),
            j.optJSONArray("history")?.let { a -> (0 until a.length()).map { PasswordChange.from(a.getJSONObject(it)) } }.orEmpty())
    }
}
data class VaultRecord(
    val id: String = UUID.randomUUID().toString(), val name: String = "", val website: String = "", val group: String = "", val favorite: Boolean = false,
    val updatedAt: String = Instant.now().toString(),
    val fields: List<VaultField> = listOf(VaultField(kind = FieldKind.username, label = "Username"), VaultField(kind = FieldKind.password, label = "Password"), VaultField(kind = FieldKind.note, label = "Notes")),
    val legacy: Map<String, String> = emptyMap(),
    val type: RecordType = RecordType.login,
) {
    val seedWords: List<String> get() = fields.firstOrNull { it.label == SEED_LABEL }?.value?.let(Bip39::split).orEmpty()
    /** A seed-type record that holds a bare private key instead of a mnemonic. */
    val privateKey: String? get() = fields.firstOrNull { it.label == PRIVATE_KEY_LABEL }?.value
    fun matches(query: String) = (listOf(name, website, group) + fields.filter { !it.secret }.map { it.value }).any { it.contains(query, ignoreCase = true) }
    fun json() = JSONObject().put("id", id).put("name", name).put("website", website).put("group", group).put("favorite", favorite).put("updatedAt", updatedAt).put("fields", JSONArray(fields.map { it.json() })).put("legacy", JSONObject(legacy)).apply { if (type != RecordType.login) put("type", type.name) }
    companion object {
        fun from(j: JSONObject): VaultRecord {
            val fields = j.getJSONArray("fields"); val legacy = j.getJSONObject("legacy")
            return VaultRecord(j.getString("id"), j.getString("name"), j.getString("website"), j.getString("group"), j.getBoolean("favorite"), j.getString("updatedAt"), (0 until fields.length()).map { VaultField.from(fields.getJSONObject(it)) }, legacy.keys().asSequence().associateWith { legacy.getString(it) }, RecordType.valueOf(j.optString("type", RecordType.login.name)))
        }
    }
}
/** How many of [groups] (one group per record) equal [name], ignoring case: true = all, null = some, false = none. */
fun groupMembership(groups: Collection<String>, name: String): Boolean? {
    val count = groups.count { it.trim().equals(name, ignoreCase = true) }
    return if (count == 0) false else if (count == groups.size) true else null
}
/**
 * A stable color for a group as opaque ARGB, derived from its name (trimmed, ignoring case) so it never has to be stored and matches
 * on iOS: FNV-1a hash of the UTF-8 bytes picks the hue, with fixed saturation and lightness that read on light and dark surfaces.
 */
fun groupColorArgb(name: String): Int {
    var h = 0x811C9DC5L
    for (b in name.trim().lowercase().toByteArray(Charsets.UTF_8)) h = ((h xor (b.toLong() and 0xFF)) * 16777619L) and 0xFFFFFFFFL
    val hue = (h % 360).toDouble(); val s = 0.65; val l = 0.5
    val c = (1 - Math.abs(2 * l - 1)) * s; val x = c * (1 - Math.abs((hue / 60) % 2 - 1)); val m = l - c / 2
    val (r, g, b) = when ((hue / 60).toInt()) { 0 -> Triple(c, x, 0.0); 1 -> Triple(x, c, 0.0); 2 -> Triple(0.0, c, x); 3 -> Triple(0.0, x, c); 4 -> Triple(x, 0.0, c); else -> Triple(c, 0.0, x) }
    fun ch(v: Double) = Math.round((v + m) * 255).toInt()
    return (0xFF shl 24) or (ch(r) shl 16) or (ch(g) shl 8) or ch(b)
}
const val PASSWORD_HISTORY_LIMIT = 10
/**
 * Adds the replaced value of every password / security-answer field that differs from [previous] to that field's own history,
 * stamped [changedAt]. Fields are matched by id; a field that was empty before, or is unchanged, records nothing. Keeps the newest
 * [PASSWORD_HISTORY_LIMIT] entries per field. Seed phrases are not tracked.
 */
fun VaultRecord.recordingPasswordChanges(previous: VaultRecord?, changedAt: Instant = Instant.now()): VaultRecord {
    if (previous == null || type != RecordType.login) return this
    val before = previous.fields.associateBy { it.id }
    return copy(fields = fields.map { field ->
        val old = before[field.id]
        if (old != null && field.secret && old.value.isNotEmpty() && old.value != field.value)
            field.copy(history = (field.history + PasswordChange(old.value, changedAt.epochSecond)).sortedByDescending { it.changedAtEpochSeconds }.take(PASSWORD_HISTORY_LIMIT))
        else field
    })
}
object Records {
    const val MAX_BYTES = 16 * 1024 * 1024
    fun validate(records: List<VaultRecord>): List<VaultRecord> {
        require(records.size <= 10000 && records.map { it.id }.toSet().size == records.size) { "Too many records or duplicate identifiers." }
        require(records.all { it.fields.size <= 200 && it.fields.map { f -> f.id }.toSet().size == it.fields.size }) { "Invalid field identifiers." }
        return records
    }
    fun encode(records: List<VaultRecord>) = JSONArray(validate(records).map { it.json() }).toString().toByteArray(Charsets.UTF_8).also { require(it.size <= MAX_BYTES) { "Vault exceeds 16 MiB." } }
    fun decode(bytes: ByteArray): List<VaultRecord> {
        require(bytes.size <= MAX_BYTES) { "File exceeds 16 MiB." }
        val array = JSONArray(bytes.toString(Charsets.UTF_8))
        require(array.length() <= 10000)
        return validate((0 until array.length()).map { VaultRecord.from(array.getJSONObject(it)) })
    }
}
enum class AutoLock(val label: String, val millis: Long?, @StringRes val labelRes: Int) {
    immediately("Immediately", 0, R.string.app_autolock_immediately), oneMinute("After 1 minute", 60_000, R.string.app_autolock_1m), fiveMinutes("After 5 minutes", 300_000, R.string.app_autolock_5m), deviceLock("When the device locks", null, R.string.app_autolock_device)
}
