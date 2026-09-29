package app.passvault

import org.json.JSONArray

object VaultCSV {
    private val contentColumns = setOf("url", "username", "password", "extra", "name", "grouping", "fav", "customFields", "vaultFields")
    fun parse(text: String): List<List<String>> {
        require(text.toByteArray().size <= Records.MAX_BYTES) { "CSV exceeds 16 MiB." }
        val input = text.removePrefix("\uFEFF"); val rows = mutableListOf<List<String>>(); var row = mutableListOf<String>(); val value = StringBuilder()
        var quoted = false; var closed = false; var i = 0
        while (i < input.length) {
            val c = input[i]
            if (quoted) {
                if (c == '"') { if (i + 1 < input.length && input[i + 1] == '"') { value.append(c); i++ } else { quoted = false; closed = true } }
                else value.append(c)
            } else when {
                c == ',' -> { row.add(value.toString()); value.clear(); closed = false }
                c == '\r' || c == '\n' -> { row.add(value.toString()); rows.add(row); row = mutableListOf(); value.clear(); closed = false; if (c == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++ }
                c == '"' && value.isEmpty() && !closed -> quoted = true
                else -> { require(!closed && c != '"') { "Malformed CSV quoting." }; value.append(c) }
            }
            require(rows.size <= 10001 && row.size <= 256) { "CSV is too large." }; i++
        }
        require(!quoted) { "Unterminated CSV field." }
        if (value.isNotEmpty() || row.isNotEmpty() || closed) { row.add(value.toString()); rows.add(row) }
        return rows
    }
    fun importRecords(text: String): List<VaultRecord> {
        val rows = parse(text); val header = rows.firstOrNull() ?: error("CSV is empty.")
        require(header.toSet().size == header.size && header.containsAll(listOf("name", "username", "password"))) { "Expected Password Keeper CSV columns: name, username, password." }
        return Records.validate(rows.drop(1).filter { it != listOf("") }.map { row ->
            require(row.size == header.size) { "CSV row has the wrong number of columns." }
            val cells = header.zip(row).toMap()
            fun cell(name: String) = cells[name].orEmpty()
            fun label(name: String, fallback: String) = cell(name).ifEmpty { fallback }
            val native = cell("vaultFields")
            val fields = if (native.isNotEmpty()) {
                val array = JSONArray(native); (0 until array.length()).map { VaultField.from(array.getJSONObject(it)) }
            } else {
                val basic = listOf(VaultField(kind = FieldKind.username, label = label("usernameLabel", "Username"), value = cell("username")), VaultField(kind = FieldKind.password, label = label("passwordLabel", "Password"), value = cell("password")), VaultField(kind = FieldKind.note, label = label("notesLabel", "Notes"), value = cell("extra")))
                val custom = cell("customFields")
                basic + if (custom.isNotEmpty() && custom != "[]") listOf(VaultField(kind = FieldKind.password, label = "Imported custom fields (original)", value = custom)) else emptyList()
            }
            VaultRecord(name = cell("name"), website = cell("url"), group = cell("grouping"), favorite = cell("fav").lowercase() in listOf("1", "true"), fields = fields, legacy = cells.filterKeys { it !in contentColumns })
        })
    }
    fun exportRecords(records: List<VaultRecord>): String {
        val columns = listOf("url", "username", "password", "extra", "name", "grouping", "fav", "customFields", "lastModifiedTime", "uid", "usernameLabel", "passwordLabel", "websiteLabel", "notesLabel", "passwordSetDate", "flags", "imageIndex", "dataVersion", "vaultFields")
        fun quote(value: String) = "\"" + value.replace("\"", "\"\"") + "\""
        val lines = mutableListOf(columns.joinToString(",", transform = ::quote))
        // Seed phrases are only ever exported inside the encrypted backup.
        for (record in Records.validate(records).filter { it.type == RecordType.login }) {
            val cells = record.legacy.toMutableMap()
            cells["name"] = record.name; cells["url"] = record.website; cells["grouping"] = record.group; cells["fav"] = if (record.favorite) "1" else "0"
            cells["username"] = record.fields.firstOrNull { it.kind == FieldKind.username }?.value.orEmpty()
            cells["password"] = record.fields.firstOrNull { it.kind == FieldKind.password }?.value.orEmpty()
            cells["extra"] = record.fields.firstOrNull { it.kind == FieldKind.note }?.value.orEmpty()
            cells["usernameLabel"] = record.fields.firstOrNull { it.kind == FieldKind.username }?.label ?: "Username"
            cells["passwordLabel"] = record.fields.firstOrNull { it.kind == FieldKind.password }?.label ?: "Password"
            cells["notesLabel"] = record.fields.firstOrNull { it.kind == FieldKind.note }?.label ?: "Notes"
            cells["customFields"] = record.fields.firstOrNull { it.label == "Imported custom fields (original)" }?.value.orEmpty()
            cells["vaultFields"] = JSONArray(record.fields.map { it.json() }).toString()
            lines.add(columns.joinToString(",") { quote(cells[it].orEmpty()) })
        }
        return (lines.joinToString("\r\n") + "\r\n").also { require(it.toByteArray().size <= Records.MAX_BYTES) { "CSV exceeds 16 MiB." } }
    }
}
