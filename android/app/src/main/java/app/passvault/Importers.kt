package app.passvault

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId

/** Builds PassVault records from what other password managers export, the same way for every format. */
internal object ImportBuilder {
    fun name(title: String, website: String, fallback: String = "Imported entry") = title.trim().ifEmpty { hostOf(website)?.removePrefix("www.") ?: website.trim() }.ifEmpty { fallback }
    /**
     * An authenticator record for a TOTP value as other managers store it: an `otpauth://totp/` URI or a bare Base32 key. Null for
     * anything else (HOTP, Steam, damaged), which the caller keeps as an ordinary hidden field instead.
     */
    fun totp(value: String, name: String, account: String): VaultRecord? {
        val text = value.trim(); if (text.isEmpty()) return null
        val parsed = runCatching {
            if (text.startsWith("otpauth://", ignoreCase = true)) Totp.parseUri(text).let { if (it.issuer.isEmpty() && it.account.isEmpty()) it.copy(issuer = name, account = account) else it }
            else TotpAccount(Totp.decodeBase32(text), issuer = name, account = account)
        }.getOrNull() ?: return null
        return parsed.record(name)
    }
    /** A login, plus an authenticator record when [totp] holds a usable key (otherwise the value is kept as a hidden field). */
    fun login(name: String, website: String = "", username: String = "", password: String = "", notes: String = "", group: String = "", favorite: Boolean = false,
              updatedAt: Instant? = null, expires: String = "", history: List<PasswordChange> = emptyList(), extra: List<VaultField> = emptyList(),
              totp: String = "", legacy: Map<String, String> = emptyMap()): List<VaultRecord> {
        val code = totp(totp, name, username)
        val keep = if (code == null && totp.isNotBlank()) listOf(VaultField(kind = FieldKind.password, label = "One-time password", value = totp.trim())) else emptyList()
        val fields = listOf(VaultField(kind = FieldKind.username, label = "Username", value = username), VaultField(kind = FieldKind.password, label = "Password", value = password, history = history.sortedByDescending { it.changedAtEpochSeconds }.take(PASSWORD_HISTORY_LIMIT)),
            VaultField(kind = FieldKind.note, label = "Notes", value = notes)) + extra + keep
        val login = VaultRecord(name = name, website = website.trim(), group = group.trim(), favorite = favorite, updatedAt = (updatedAt ?: Instant.now()).toString(), fields = fields, legacy = legacy, expires = expires)
        return listOfNotNull(login, code?.copy(group = group.trim()))
    }
    fun note(name: String, notes: String, group: String = "", favorite: Boolean = false, updatedAt: Instant? = null, expires: String = "", extra: List<VaultField> = emptyList()) =
        VaultRecord(name = name, group = group.trim(), favorite = favorite, updatedAt = (updatedAt ?: Instant.now()).toString(), type = RecordType.note, expires = expires,
            fields = listOf(VaultField(kind = FieldKind.note, label = "Notes", value = notes)) + extra)
    fun card(name: String, holder: String, number: String, expiry: String, code: String, pin: String = "", notes: String = "", group: String = "", favorite: Boolean = false, updatedAt: Instant? = null, extra: List<VaultField> = emptyList()): VaultRecord {
        val values = mapOf(CARD_HOLDER_LABEL to holder, CARD_NUMBER_LABEL to (CardInput.number.digits(number) ?: number), CARD_EXPIRY_LABEL to (CardInput.expiry.digits(expiry) ?: expiry), CARD_CODE_LABEL to code, CARD_PIN_LABEL to pin, "Notes" to notes)
        return VaultRecord(name = name, group = group.trim(), favorite = favorite, updatedAt = (updatedAt ?: Instant.now()).toString(), type = RecordType.card,
            fields = defaultFields(RecordType.card).map { it.copy(value = values[it.label].orEmpty()) } + extra)
    }
    /** A field the importer has no place for: hidden when the source marked it secret. */
    fun extra(label: String, value: String, secret: Boolean) = VaultField(kind = if (secret) FieldKind.password else FieldKind.note, label = label.trim().ifEmpty { "Field" }, value = value)
    /** As `yyyy-MM-dd`, or "" outside years 1–9999 (e.g. KeePass's 9999-12-31 read east of UTC), which iOS would refuse in a transfer or backup. */
    fun localDate(instant: Instant): String =
        runCatching { instant.atZone(ZoneId.systemDefault()).toLocalDate() }.getOrNull()?.takeIf { it.year in 1..9999 }?.toString().orEmpty()
    /** `MM/YY`, as printed on cards, for years 2000–2099 (which is how two-digit years are read back); `MM/YYYY` for any other year. */
    fun cardExpiry(month: String, year: String): String {
        val m = month.trim().toIntOrNull() ?: return ""; val y = year.trim().toIntOrNull() ?: return ""
        return if (y < 100 || y in 2000..2099) "%02d/%02d".format(m, y % 100) else "%02d/%d".format(m, y)
    }
}

/** Reads exports from other password managers. Encrypted formats (`.pvault`, `.pkb2`, `.kdbx`) need a password and are opened elsewhere. */
object Importers {
    fun needsPassword(data: ByteArray) = VaultCrypto.isBackup(data) || Pkb2.isPkb2(data) || Kdbx.isKdbx(data) || Transfer.isTransfer(data)
    /**
     * Unencrypted exports, recognised by content rather than file name: 1Password `.1pux`, Bitwarden JSON, KeePass XML and CSV from
     * Password Keeper, LastPass, Chrome, Edge, Firefox, Safari, Bitwarden, 1Password, KeePass, KeePassXC, Dashlane, Proton Pass and others.
     */
    fun importPlain(data: ByteArray): List<VaultRecord> {
        if (data.size >= 4 && data[0] == 'P'.code.toByte() && data[1] == 'K'.code.toByte() && data[2] == 3.toByte() && data[3] == 4.toByte()) return OnePux.import(data)
        val text = data.toString(Charsets.UTF_8).removePrefix("\uFEFF")
        val start = text.trimStart()
        return when {
            start.startsWith("{") -> BitwardenJson.import(text)
            start.startsWith("<") -> { require("<KeePassFile" in start.take(4096)) { "Unrecognised XML file. PassVault reads KeePass XML exports." }; KeePassXml.records(MiniXml.parse(text), null) }
            else -> GenericCsv.import(text)
        }
    }
}

/** CSV from other managers, matched by column names. Password Keeper / LastPass layouts keep their own lossless importer. */
internal object GenericCsv {
    private fun key(header: String) = header.lowercase().filter { it.isLetterOrDigit() }
    private val columns = mapOf(
        "name" to listOf("name", "title", "account", "itemname", "entry", "entryname"),
        "url" to listOf("url", "website", "loginuri", "uri", "weburl", "webaddress", "loginurl", "urls"),
        "username" to listOf("username", "loginusername", "loginname", "user", "login", "userid"),
        "email" to listOf("email", "emailaddress", "username2"),
        "password" to listOf("password", "loginpassword", "pass", "pwd"),
        "notes" to listOf("notes", "note", "extra", "comments", "comment", "notesplain"),
        "group" to listOf("group", "folder", "grouping", "category", "groupname", "vault"),
        "tags" to listOf("tags", "tag", "labels"),
        "totp" to listOf("totp", "otpauth", "logintotp", "otp", "onetimepassword", "otpsecret", "otpurl", "twofactorsecret"),
        "favorite" to listOf("favorite", "fav", "favourite", "starred"),
        "type" to listOf("type", "itemtype"),
        "fields" to listOf("fields", "customfields"),
        "changed" to listOf("timepasswordchanged", "passwordchanged", "passwordsetdate"),
    )
    fun import(text: String): List<VaultRecord> {
        val rows = VaultCSV.parse(text); val header = rows.firstOrNull() ?: throw IllegalArgumentException("The file is empty.")
        val keys = header.map(::key)
        // Password Keeper and LastPass exports: the existing importer reads their custom fields losslessly.
        if (header.containsAll(listOf("name", "username", "password")) && (header.contains("extra") || header.contains("grouping") || header.contains("vaultFields"))) return VaultCSV.importRecords(text)
        require(header.toSet().size == header.size) { "The CSV has duplicate column names." }
        val index = columns.mapValues { (_, names) -> names.firstNotNullOfOrNull { n -> keys.indexOf(n).takeIf { it >= 0 } } }
        require((index["password"] != null || index["username"] != null || index["notes"] != null) && (index["name"] != null || index["url"] != null)) {
            "Unrecognised CSV. PassVault reads exports with name or URL columns and username, password or notes columns."
        }
        val used = index.values.filterNotNull().toSet()
        val data = rows.drop(1).filter { it != listOf("") }
        data.forEach { require(it.size == header.size) { "A CSV row has the wrong number of columns." } }
        // KeePassXC writes every group path from the database's root group ("Root/Email"); only its exports lose that first segment.
        val groupColumn = index["group"]
        val groups = data.map { row -> groupColumn?.let { row[it].trim() }.orEmpty() }
        val keePassXc = keys.containsAll(listOf("group", "title", "icon", "lastmodified", "created"))
        val firstSegment = if (keePassXc) groups.filter { it.isNotEmpty() }.map { it.substringBefore('/') }.distinct().singleOrNull() else null
        return Records.validate(data.flatMapIndexed { r, row ->
            fun cell(name: String) = index[name]?.let { row[it] }.orEmpty()
            val website = cell("url").lineSequence().firstOrNull().orEmpty().trim()
            val name = ImportBuilder.name(cell("name"), website)
            var group = groups[r]
            if (firstSegment != null) group = if (group == firstSegment) "" else group.removePrefix("$firstSegment/")
            if (group.isEmpty()) group = cell("tags").split(',', ';').firstOrNull()?.trim().orEmpty()
            val favorite = cell("favorite").trim().lowercase() in setOf("1", "true", "yes", "y", "x", "*")
            val extra = cell("fields").lines().filter { it.isNotBlank() }.map { line -> line.substringBefore(": ", "").let { label -> ImportBuilder.extra(label.ifEmpty { "Field" }, line.substringAfter(": "), false) } } +
                cell("url").lineSequence().drop(1).filter { it.isNotBlank() }.map { ImportBuilder.extra("Website", it.trim(), false) }.toList()
            val legacy = header.indices.filter { it !in used && row[it].isNotEmpty() }.associate { header[it] to row[it] }.toMutableMap()
            cell("changed").trim().toLongOrNull()?.let { legacy["passwordSetDate"] = (if (it > 100_000_000_000L) it / 1000 else it).toString() }
            val username = cell("username").ifEmpty { cell("email") }
            when (cell("type").trim().lowercase()) {
                "note", "securenote", "secure note" -> listOf(ImportBuilder.note(name, cell("notes"), group, favorite, extra = extra))
                else -> ImportBuilder.login(name, website, username, cell("password"), cell("notes"), group, favorite, extra = extra, totp = cell("totp"), legacy = legacy)
            }
        })
    }
}

/** Bitwarden's unencrypted JSON export (`"encrypted": false`). Items in the trash are skipped. */
internal object BitwardenJson {
    private fun JSONObject.str(name: String) = if (isNull(name)) "" else optString(name, "")
    private fun time(value: String) = runCatching { Instant.parse(value) }.getOrNull()
    fun import(text: String): List<VaultRecord> {
        val root = runCatching { JSONObject(text) }.getOrElse { throw IllegalArgumentException("Unrecognised JSON file. PassVault reads Bitwarden JSON exports.") }
        require(!root.optBoolean("encrypted", false)) { "This Bitwarden export is encrypted. Export again choosing \"JSON\" (not \"JSON (Encrypted)\")." }
        val items = root.optJSONArray("items") ?: throw IllegalArgumentException("Unrecognised JSON file. PassVault reads Bitwarden JSON exports.")
        val folders = root.optJSONArray("folders")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) }.associate { it.str("id") to it.str("name") } }.orEmpty()
        val out = mutableListOf<VaultRecord>()
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            if (item.str("deletedDate").isNotEmpty()) continue
            val group = folders[item.str("folderId")].orEmpty(); val favorite = item.optBoolean("favorite"); val notes = item.str("notes")
            val updated = time(item.str("revisionDate"))
            val custom = item.optJSONArray("fields")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) }.filter { it.optInt("type") != 3 }.map { ImportBuilder.extra(it.str("name"), it.str("value"), it.optInt("type") == 1) } }.orEmpty()
            when (item.optInt("type", 1)) {
                1 -> {
                    val login = item.optJSONObject("login") ?: JSONObject()
                    val uris = login.optJSONArray("uris")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).str("uri") }.filter { it.isNotBlank() } }.orEmpty()
                    val history = item.optJSONArray("passwordHistory")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) }.map { PasswordChange(it.str("password"), time(it.str("lastUsedDate"))?.epochSecond ?: 0) } }.orEmpty()
                    val website = uris.firstOrNull().orEmpty()
                    out += ImportBuilder.login(ImportBuilder.name(item.str("name"), website), website, login.str("username"), login.str("password"), notes, group, favorite, updated, history = history,
                        extra = uris.drop(1).map { ImportBuilder.extra("Website", it, false) } + custom, totp = login.str("totp"))
                }
                3 -> {
                    val c = item.optJSONObject("card") ?: JSONObject()
                    out += ImportBuilder.card(ImportBuilder.name(item.str("name"), "", "Card"), c.str("cardholderName"), c.str("number"), ImportBuilder.cardExpiry(c.str("expMonth"), c.str("expYear")), c.str("code"), notes = notes, group = group, favorite = favorite, updatedAt = updated, extra = custom)
                }
                else -> {
                    // Secure notes, identities and SSH keys: every detail becomes a field of a secure note.
                    val details = (item.optJSONObject("identity") ?: item.optJSONObject("sshKey"))?.let { d -> d.keys().asSequence().sorted().filter { d.str(it).isNotBlank() }.map { k -> ImportBuilder.extra(label(k), d.str(k), k in setOf("ssn", "passportNumber", "licenseNumber", "privateKey")) }.toList() }.orEmpty()
                    out += ImportBuilder.note(ImportBuilder.name(item.str("name"), "", "Note"), notes, group, favorite, updated, extra = details + custom)
                }
            }
        }
        return Records.validate(out)
    }
    /** "firstName" → "First name". */
    private fun label(key: String) = key.replace(Regex("([a-z])([A-Z0-9])"), "$1 $2").lowercase().replaceFirstChar { it.uppercase() }
}

/** 1Password's `.1pux` export: a zip whose `export.data` is JSON. Archived items are imported too; trashed ones are not. */
internal object OnePux {
    fun import(zip: ByteArray): List<VaultRecord> {
        val data = ZipReader.entry(zip, "export.data") ?: throw IllegalArgumentException("Unrecognised zip file. PassVault reads 1Password .1pux exports.")
        val root = JSONObject(data.toString(Charsets.UTF_8))
        val out = mutableListOf<VaultRecord>()
        val accounts = root.optJSONArray("accounts") ?: JSONArray()
        val vaults = (0 until accounts.length()).flatMap { a -> accounts.getJSONObject(a).optJSONArray("vaults")?.let { v -> (0 until v.length()).map { v.getJSONObject(it) } }.orEmpty() }
        for (vault in vaults) {
            val vaultName = vault.optJSONObject("attrs")?.optString("name").orEmpty()
            val items = vault.optJSONArray("items") ?: continue
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                if (item.optString("state") == "trashed") continue
                val overview = item.optJSONObject("overview") ?: JSONObject(); val details = item.optJSONObject("details") ?: JSONObject()
                val tags = overview.optJSONArray("tags")?.let { t -> (0 until t.length()).map { t.optString(it) } }.orEmpty()
                val group = tags.firstOrNull() ?: if (vaults.size > 1) vaultName else ""
                val favorite = item.optInt("favIndex", 0) > 0
                val updated = item.optLong("updatedAt", 0).takeIf { it > 0 }?.let(Instant::ofEpochSecond)
                // The main URL, then any others the item lists; the others are kept as extra Website fields.
                val urls = (listOf(overview.optString("url")) + overview.optJSONArray("urls")?.let { a -> (0 until a.length()).map { a.optJSONObject(it)?.optString("url").orEmpty() } }.orEmpty())
                    .map(String::trim).filter { it.isNotEmpty() }.distinct()
                val website = urls.firstOrNull().orEmpty()
                val name = ImportBuilder.name(overview.optString("title"), website)
                val notes = details.optString("notesPlain"); val category = item.optString("categoryUuid")
                // A card's own fields fill the card; any others stay as extra fields.
                val cardFields = if (category == "002") setOf("cardholder", "ccnum", "cvv", "expiry", "pin") else emptySet()
                var username = ""; var password = details.optString("password"); var totp = ""
                val extra = urls.drop(1).map { ImportBuilder.extra("Website", it, false) }.toMutableList(); val byId = mutableMapOf<String, String>()
                details.optJSONArray("loginFields")?.let { a -> for (j in 0 until a.length()) { val f = a.getJSONObject(j)
                    when (f.optString("designation")) { "username" -> username = f.optString("value"); "password" -> password = f.optString("value")
                        else -> if (f.optString("value").isNotEmpty()) extra += ImportBuilder.extra(f.optString("name"), f.optString("value"), f.optString("fieldType") == "P") }
                } }
                details.optJSONArray("sections")?.let { sections -> for (s in 0 until sections.length()) {
                    val fields = sections.getJSONObject(s).optJSONArray("fields") ?: continue
                    for (j in 0 until fields.length()) {
                        val f = fields.getJSONObject(j); val value = f.optJSONObject("value") ?: continue; val kind = value.keys().asSequence().firstOrNull() ?: continue
                        val text = when (kind) {
                            "monthYear" -> value.optInt(kind).takeIf { it > 0 }?.let { ImportBuilder.cardExpiry((it % 100).toString(), (it / 100).toString()) }.orEmpty()
                            "date" -> value.optLong(kind).takeIf { it > 0 }?.let { runCatching { Instant.ofEpochSecond(it) }.getOrNull() }?.let(ImportBuilder::localDate).orEmpty()
                            "email" -> value.optJSONObject(kind)?.optString("email_address") ?: value.optString(kind)
                            "address" -> value.optJSONObject(kind)?.let { a -> listOf("street", "city", "state", "zip", "country").map { a.optString(it) }.filter { it.isNotBlank() }.joinToString(", ") }.orEmpty()
                            "sshKey" -> value.optJSONObject(kind)?.optString("privateKey").orEmpty()
                            else -> value.opt(kind)?.takeIf { it !is JSONObject && it !is JSONArray && it != JSONObject.NULL }?.toString().orEmpty()
                        }
                        if (text.isEmpty()) continue
                        val id = f.optString("id")
                        if (kind == "totp" && totp.isEmpty()) { totp = text; continue }
                        byId[id] = text
                        if (id in cardFields) continue
                        extra += ImportBuilder.extra(f.optString("title").ifEmpty { id }, text, kind == "concealed" || kind == "creditCardNumber" || kind == "sshKey")
                    }
                } }
                val history = details.optJSONArray("passwordHistory")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) }.map { PasswordChange(it.optString("value"), it.optLong("time")) } }.orEmpty()
                when (category) {
                    "001", "005" -> out += ImportBuilder.login(name, website, username, password, notes, group, favorite, updated, history = history, extra = extra, totp = totp)
                    "002" -> out += ImportBuilder.card(name, byId["cardholder"].orEmpty(), byId["ccnum"].orEmpty(), byId["expiry"].orEmpty(), byId["cvv"].orEmpty(), byId["pin"].orEmpty(), notes, group, favorite, updated, extra = extra)
                    else -> out += ImportBuilder.note(name, notes, group, favorite, updated, extra = (if (password.isNotEmpty()) listOf(ImportBuilder.extra("Password", password, true)) else emptyList()) + extra)
                }
            }
        }
        return Records.validate(out)
    }
}

/** Reads one stored or deflated file from a zip archive, refusing anything that would inflate past the vault size limit. */
internal object ZipReader {
    fun entry(zip: ByteArray, name: String): ByteArray? {
        java.util.zip.ZipInputStream(zip.inputStream()).use { input ->
            while (true) {
                val entry = input.nextEntry ?: return null
                if (entry.name != name) continue
                val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
                while (true) { val n = input.read(buffer); if (n < 0) break; require(out.size() + n <= Records.MAX_BYTES) { "The export is too large." }; out.write(buffer, 0, n) }
                return out.toByteArray()
            }
        }
    }
}
