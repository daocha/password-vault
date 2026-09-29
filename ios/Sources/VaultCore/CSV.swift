import Foundation

public enum VaultCSV {
    private static let contentColumns: Set<String> = ["url", "username", "password", "extra", "name", "grouping", "fav", "customFields", "vaultFields"]
    public static func parse(_ text: String) throws -> [[String]] {
        guard text.utf8.count <= Records.maxBytes else { throw VaultError.invalid("CSV exceeds 16 MiB.") }
        let chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var rows = [[String]](), row = [String](), value = "", quoted = false, closed = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { value.append(c); i += 1 }
                    else { quoted = false; closed = true }
                } else { value.append(c) }
            } else if c == "," { row.append(value); value = ""; closed = false }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(value); rows.append(row); row = []; value = ""; closed = false
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
            } else if c == "\"" && value.isEmpty && !closed { quoted = true }
            else {
                guard !closed && c != "\"" else { throw VaultError.invalid("Malformed CSV quoting.") }
                value.append(c)
            }
            guard rows.count <= 10001, row.count <= 256 else { throw VaultError.invalid("CSV is too large.") }
            i += 1
        }
        guard !quoted else { throw VaultError.invalid("Unterminated CSV field.") }
        if !value.isEmpty || !row.isEmpty || closed { row.append(value); rows.append(row) }
        return rows
    }
    public static func importRecords(_ text: String) throws -> [VaultRecord] {
        let rows = try parse(text)
        guard let header = rows.first, Set(header).count == header.count,
              ["name", "username", "password"].allSatisfy(header.contains) else { throw VaultError.invalid("Expected BlackBerry Password Keeper CSV columns: name, username, password.") }
        return try Records.validate(rows.dropFirst().filter { $0 != [""] }.map { row in
            guard row.count == header.count else { throw VaultError.invalid("CSV row has the wrong number of columns.") }
            let cells = Dictionary(uniqueKeysWithValues: zip(header, row))
            if let native = cells["vaultFields"], !native.isEmpty {
                var record = VaultRecord()
                record.name = cells["name"] ?? ""; record.website = cells["url"] ?? ""
                record.group = cells["grouping"] ?? ""; record.favorite = cells["fav"] == "1"
                record.fields = try JSONDecoder().decode([VaultField].self, from: Data(native.utf8))
                record.legacy = cells.filter { !contentColumns.contains($0.key) }
                return record
            }
            var record = VaultRecord()
            record.name = cells["name"] ?? ""; record.website = cells["url"] ?? ""
            record.group = cells["grouping"] ?? ""; record.favorite = ["1", "true"].contains(cells["fav"]?.lowercased() ?? "")
            record.fields = [
                .init(kind: .username, label: cells["usernameLabel"].flatMap { $0.isEmpty ? nil : $0 } ?? "Username", value: cells["username"] ?? ""),
                .init(kind: .password, label: cells["passwordLabel"].flatMap { $0.isEmpty ? nil : $0 } ?? "Password", value: cells["password"] ?? ""),
                .init(kind: .note, label: cells["notesLabel"].flatMap { $0.isEmpty ? nil : $0 } ?? "Notes", value: cells["extra"] ?? "")
            ]
            // Never discard an unrecognized legacy representation or render it as public text.
            if let custom = cells["customFields"], !custom.isEmpty && custom != "[]" {
                record.fields.append(.init(kind: .password, label: "Imported custom fields (original)", value: custom))
            }
            record.legacy = cells.filter { !contentColumns.contains($0.key) }
            return record
        })
    }
    public static func exportRecords(_ records: [VaultRecord]) throws -> String {
        let columns = ["url", "username", "password", "extra", "name", "grouping", "fav", "customFields", "lastModifiedTime", "uid", "usernameLabel", "passwordLabel", "websiteLabel", "notesLabel", "passwordSetDate", "flags", "imageIndex", "dataVersion", "vaultFields"]
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = [columns.map(quote).joined(separator: ",")]
        for record in try Records.validate(records) where record.isLogin {
            var cells = record.legacy
            cells["name"] = record.name; cells["url"] = record.website; cells["grouping"] = record.group; cells["fav"] = record.favorite ? "1" : "0"
            cells["username"] = record.fields.first { $0.kind == .username }?.value ?? ""
            cells["password"] = record.fields.first { $0.kind == .password }?.value ?? ""
            cells["extra"] = record.fields.first { $0.kind == .note }?.value ?? ""
            cells["usernameLabel"] = record.fields.first { $0.kind == .username }?.label ?? "Username"
            cells["passwordLabel"] = record.fields.first { $0.kind == .password }?.label ?? "Password"
            cells["notesLabel"] = record.fields.first { $0.kind == .note }?.label ?? "Notes"
            cells["customFields"] = record.fields.first { $0.label == "Imported custom fields (original)" }?.value ?? ""
            cells["vaultFields"] = String(decoding: try JSONEncoder().encode(record.fields), as: UTF8.self)
            rows.append(columns.map { quote(cells[$0] ?? "") }.joined(separator: ","))
        }
        let result = rows.joined(separator: "\r\n") + "\r\n"
        guard result.utf8.count <= Records.maxBytes else { throw VaultError.invalid("CSV exceeds 16 MiB.") }
        return result
    }
}
