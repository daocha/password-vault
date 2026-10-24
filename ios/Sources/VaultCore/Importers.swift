import Foundation

/// Builds PassVault records from what other password managers export, the same way for every format (like Android's `ImportBuilder`).
enum ImportBuilder {
    /// The host of a URL or bare domain, without `www.`; nil when it does not look like one. Same rules as Android's `hostOf`.
    static func host(_ value: String) -> String? {
        var s = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        for stop in ["/", "?", "#"] { if let r = s.range(of: stop) { s = String(s[..<r.lowerBound]) } }
        if let r = s.range(of: "@", options: .backwards) { s = String(s[r.upperBound...]) }
        if let r = s.range(of: ":") { s = String(s[..<r.lowerBound]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        while s.hasSuffix(".") { s.removeLast() }
        return s.contains(".") ? s : nil
    }
    static func name(_ title: String, website: String, fallback: String = "Imported entry") -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let h = host(website) ?? website.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? fallback : h
    }
    /// An authenticator record for an `otpauth://totp/` URI or a bare Base32 key; nil for anything else (HOTP, Steam, damaged).
    static func totp(_ value: String, name: String, account: String) -> VaultRecord? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var parsed: TotpAccount?
        if text.lowercased().hasPrefix("otpauth://") {
            parsed = try? Totp.parseURI(text)
            if var p = parsed, p.issuer.isEmpty && p.account.isEmpty { p.issuer = name; p.account = account; parsed = p }
        } else if let secret = try? Totp.decodeBase32(text) { parsed = try? TotpAccount(secret: secret, issuer: name, account: account) }
        return parsed?.record(name: name)
    }
    /// A login, plus an authenticator record when `totp` holds a usable key (otherwise the value is kept as a hidden field).
    static func login(_ name: String, website: String = "", username: String = "", password: String = "", notes: String = "", group: String = "", favorite: Bool = false,
                      updatedAt: Date? = nil, expires: String = "", history: [PasswordChange] = [], extra: [VaultField] = [], totp: String = "", legacy: [String: String] = [:]) -> [VaultRecord] {
        let code = self.totp(totp, name: name, account: username)
        let keep = code == nil && !totp.trimmingCharacters(in: .whitespaces).isEmpty ? [VaultField(kind: .password, label: "One-time password", value: totp.trimmingCharacters(in: .whitespacesAndNewlines))] : []
        let sortedHistory = Array(history.sorted { $0.changedAt > $1.changedAt }.prefix(passwordHistoryLimit))
        var record = VaultRecord()
        record.name = name; record.website = website.trimmingCharacters(in: .whitespacesAndNewlines); record.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        record.favorite = favorite; record.updatedAt = ISO8601DateFormatter().string(from: updatedAt ?? Date()); record.legacy = legacy; record.expires = expires.isEmpty ? nil : expires
        record.fields = [.init(kind: .username, label: "Username", value: username), .init(kind: .password, label: "Password", value: password, history: sortedHistory.isEmpty ? nil : sortedHistory),
                         .init(kind: .note, label: "Notes", value: notes)] + extra + keep
        guard var code else { return [record] }
        code.group = record.group
        return [record, code]
    }
    static func note(_ name: String, notes: String, group: String = "", favorite: Bool = false, updatedAt: Date? = nil, extra: [VaultField] = []) -> VaultRecord {
        var record = VaultRecord.new(type: "note")
        record.name = name; record.group = group.trimmingCharacters(in: .whitespacesAndNewlines); record.favorite = favorite
        record.updatedAt = ISO8601DateFormatter().string(from: updatedAt ?? Date()); record.fields[0].value = notes; record.fields += extra
        return record
    }
    static func card(_ name: String, holder: String, number: String, expiry: String, code: String, pin: String = "", notes: String = "", group: String = "", favorite: Bool = false, updatedAt: Date? = nil, extra: [VaultField] = []) -> VaultRecord {
        var record = VaultRecord.new(type: "card")
        let values = [cardHolderLabel: holder, cardNumberLabel: number, cardExpiryLabel: expiry, cardCodeLabel: code, cardPinLabel: pin, "Notes": notes]
        record.name = name; record.group = group.trimmingCharacters(in: .whitespacesAndNewlines); record.favorite = favorite
        record.updatedAt = ISO8601DateFormatter().string(from: updatedAt ?? Date())
        record.fields = record.fields.map { var f = $0; f.value = values[f.label] ?? ""; return f } + extra
        return record
    }
    /// A field the importer has no place for: hidden when the source marked it secret.
    static func extra(_ label: String, _ value: String, secret: Bool) -> VaultField {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return VaultField(kind: secret ? .password : .note, label: l.isEmpty ? "Field" : l, value: value)
    }
    static func cardExpiry(month: String, year: String) -> String {
        guard let m = Int(month.trimmingCharacters(in: .whitespaces)), let y = Int(year.trimmingCharacters(in: .whitespaces)) else { return "" }
        return String(format: "%02d/%02d", m, y % 100)
    }
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: text) ?? fractional.date(from: text)
    }
}

/// Reads exports from other password managers, like Android's `Importers`. Encrypted formats (`.pvault`, `.pkb2`, `.kdbx`) need a password.
public enum Importers {
    public static func needsPassword(_ data: Data) -> Bool { data.prefix(6) == Data("QVAULT".utf8) || Pkb2.isPkb2(data) || Kdbx.isKdbx(data) || Transfer.isTransfer(data) }
    /// Unencrypted exports, recognised by content: 1Password `.1pux`, Bitwarden JSON, KeePass XML, and CSV from Password Keeper, LastPass,
    /// browsers, Bitwarden, 1Password, KeePass, KeePassXC, Dashlane, Proton Pass and others.
    public static func importPlain(_ data: Data) throws -> [VaultRecord] {
        if data.prefix(4) == Data([0x50, 0x4B, 3, 4]) { return try OnePux.importRecords(data) }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let start = text.drop(while: \.isWhitespace)
        if start.hasPrefix("{") { return try BitwardenJson.importRecords(text) }
        if start.hasPrefix("<") {
            guard start.prefix(4096).contains("<KeePassFile") else { throw VaultError.invalid("Unrecognised XML file. PassVault reads KeePass XML exports.") }
            return try KeePassXml.records(MiniXml.parse(data), stream: nil)
        }
        return try GenericCsv.importRecords(text)
    }
}

/// CSV from other managers, matched by column names. Password Keeper / LastPass layouts keep their own lossless importer.
enum GenericCsv {
    static func key(_ header: String) -> String { String(header.lowercased().filter { $0.isLetter || $0.isNumber }) }
    static let columns: [(String, [String])] = [
        ("name", ["name", "title", "account", "itemname", "entry", "entryname"]),
        ("url", ["url", "website", "loginuri", "uri", "weburl", "webaddress", "loginurl", "urls"]),
        ("username", ["username", "loginusername", "loginname", "user", "login", "userid"]),
        ("email", ["email", "emailaddress", "username2"]),
        ("password", ["password", "loginpassword", "pass", "pwd"]),
        ("notes", ["notes", "note", "extra", "comments", "comment", "notesplain"]),
        ("group", ["group", "folder", "grouping", "category", "groupname", "vault"]),
        ("tags", ["tags", "tag", "labels"]),
        ("totp", ["totp", "otpauth", "logintotp", "otp", "onetimepassword", "otpsecret", "otpurl", "twofactorsecret"]),
        ("favorite", ["favorite", "fav", "favourite", "starred"]),
        ("type", ["type", "itemtype"]),
        ("fields", ["fields", "customfields"]),
        ("changed", ["timepasswordchanged", "passwordchanged", "passwordsetdate"]),
    ]
    static func importRecords(_ text: String) throws -> [VaultRecord] {
        let rows = try VaultCSV.parse(text)
        guard let header = rows.first else { throw VaultError.invalid("The file is empty.") }
        let keys = header.map(key)
        if ["name", "username", "password"].allSatisfy(header.contains) && (header.contains("extra") || header.contains("grouping") || header.contains("vaultFields")) { return try VaultCSV.importRecords(text) }
        guard Set(header).count == header.count else { throw VaultError.invalid("The CSV has duplicate column names.") }
        var index = [String: Int]()
        for (name, synonyms) in columns { if let i = synonyms.lazy.compactMap({ keys.firstIndex(of: $0) }).first { index[name] = i } }
        guard index["password"] != nil || index["username"] != nil || index["notes"] != nil, index["name"] != nil || index["url"] != nil else {
            throw VaultError.invalid("Unrecognised CSV. PassVault reads exports with name or URL columns and username, password or notes columns.")
        }
        let used = Set(index.values)
        let data = rows.dropFirst().filter { $0 != [""] }
        guard data.allSatisfy({ $0.count == header.count }) else { throw VaultError.invalid("A CSV row has the wrong number of columns.") }
        // KeePassXC writes every group path from its root ("Root/Email"); a prefix shared by all rows is dropped.
        let groups = data.map { row in index["group"].map { row[$0].trimmingCharacters(in: .whitespaces) } ?? "" }
        let nonEmpty = groups.filter { !$0.isEmpty }, firsts = Set(nonEmpty.map { String($0.split(separator: "/", omittingEmptySubsequences: false)[0]) })
        let firstSegment = firsts.count == 1 && (nonEmpty.contains { $0.contains("/") } || firsts.first!.lowercased() == "root") ? firsts.first : nil
        var out = [VaultRecord]()
        for (r, row) in data.enumerated() {
            func cell(_ name: String) -> String { index[name].map { row[$0] } ?? "" }
            let urlLines = cell("url").split(whereSeparator: \.isNewline).map(String.init)
            let website = urlLines.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = ImportBuilder.name(cell("name"), website: website)
            var group = groups[r]
            if let firstSegment { group = group == firstSegment ? "" : (group.hasPrefix(firstSegment + "/") ? String(group.dropFirst(firstSegment.count + 1)) : group) }
            if group.isEmpty { group = cell("tags").split(whereSeparator: { $0 == "," || $0 == ";" }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
            let favorite = ["1", "true", "yes", "y", "x", "*"].contains(cell("favorite").trimmingCharacters(in: .whitespaces).lowercased())
            let extra = cell("fields").split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { line -> VaultField in
                let l = String(line)
                guard let r = l.range(of: ": ") else { return ImportBuilder.extra("Field", l, secret: false) }
                return ImportBuilder.extra(String(l[..<r.lowerBound]), String(l[r.upperBound...]), secret: false)
            } + urlLines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { ImportBuilder.extra("Website", $0.trimmingCharacters(in: .whitespaces), secret: false) }
            var legacy = [String: String]()
            for i in header.indices where !used.contains(i) && !row[i].isEmpty { legacy[header[i]] = row[i] }
            if let changed = Int64(cell("changed").trimmingCharacters(in: .whitespaces)) { legacy["passwordSetDate"] = String(changed > 100_000_000_000 ? changed / 1000 : changed) }
            let username = cell("username").isEmpty ? cell("email") : cell("username")
            switch cell("type").trimmingCharacters(in: .whitespaces).lowercased() {
            case "note", "securenote", "secure note": out.append(ImportBuilder.note(name, notes: cell("notes"), group: group, favorite: favorite, extra: extra))
            default: out += ImportBuilder.login(name, website: website, username: username, password: cell("password"), notes: cell("notes"), group: group, favorite: favorite, extra: extra, totp: cell("totp"), legacy: legacy)
            }
        }
        return try Records.validate(out)
    }
}

/// Bitwarden's unencrypted JSON export (`"encrypted": false`). Items in the trash are skipped.
enum BitwardenJson {
    static func str(_ o: [String: Any], _ k: String) -> String {
        switch o[k] { case let s as String: return s; case let n as NSNumber: return n.stringValue; default: return "" }
    }
    static func importRecords(_ text: String) throws -> [VaultRecord] {
        let unrecognised = VaultError.invalid("Unrecognised JSON file. PassVault reads Bitwarden JSON exports.")
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { throw unrecognised }
        if root["encrypted"] as? Bool == true { throw VaultError.invalid("This Bitwarden export is encrypted. Export again choosing \"JSON\" (not \"JSON (Encrypted)\").") }
        guard let items = root["items"] as? [[String: Any]] else { throw unrecognised }
        var folders = [String: String]()
        for f in root["folders"] as? [[String: Any]] ?? [] { folders[str(f, "id")] = str(f, "name") }
        var out = [VaultRecord]()
        for item in items {
            if !str(item, "deletedDate").isEmpty { continue }
            let group = folders[str(item, "folderId")] ?? "", favorite = item["favorite"] as? Bool ?? false, notes = str(item, "notes")
            let updated = ImportBuilder.date(str(item, "revisionDate"))
            let custom = (item["fields"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) != 3 }.map { ImportBuilder.extra(str($0, "name"), str($0, "value"), secret: ($0["type"] as? Int) == 1) }
            switch item["type"] as? Int ?? 1 {
            case 1:
                let login = item["login"] as? [String: Any] ?? [:]
                let uris = (login["uris"] as? [[String: Any]] ?? []).map { str($0, "uri") }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let history = (item["passwordHistory"] as? [[String: Any]] ?? []).map { PasswordChange(value: str($0, "password"), changedAt: Int64(ImportBuilder.date(str($0, "lastUsedDate"))?.timeIntervalSince1970 ?? 0)) }
                let website = uris.first ?? ""
                out += ImportBuilder.login(ImportBuilder.name(str(item, "name"), website: website), website: website, username: str(login, "username"), password: str(login, "password"), notes: notes,
                                           group: group, favorite: favorite, updatedAt: updated, history: history, extra: uris.dropFirst().map { ImportBuilder.extra("Website", $0, secret: false) } + custom, totp: str(login, "totp"))
            case 3:
                let c = item["card"] as? [String: Any] ?? [:]
                out.append(ImportBuilder.card(ImportBuilder.name(str(item, "name"), website: "", fallback: "Card"), holder: str(c, "cardholderName"), number: str(c, "number"),
                                              expiry: ImportBuilder.cardExpiry(month: str(c, "expMonth"), year: str(c, "expYear")), code: str(c, "code"), notes: notes, group: group, favorite: favorite, updatedAt: updated, extra: custom))
            default:
                // Secure notes, identities and SSH keys: every detail becomes a field of a secure note.
                let d = item["identity"] as? [String: Any] ?? item["sshKey"] as? [String: Any] ?? [:]
                let secretKeys: Set<String> = ["ssn", "passportNumber", "licenseNumber", "privateKey"]
                let details = d.keys.sorted().filter { !str(d, $0).trimmingCharacters(in: .whitespaces).isEmpty }.map { ImportBuilder.extra(label($0), str(d, $0), secret: secretKeys.contains($0)) }
                out.append(ImportBuilder.note(ImportBuilder.name(str(item, "name"), website: "", fallback: "Note"), notes: notes, group: group, favorite: favorite, updatedAt: updated, extra: details + custom))
            }
        }
        return try Records.validate(out)
    }
    /// "firstName" → "First name".
    static func label(_ key: String) -> String {
        var out = ""
        for c in key { if let last = out.last, last.isLowercase, c.isUppercase || c.isNumber { out += " " }; out.append(c) }
        let lower = out.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}

/// 1Password's `.1pux` export: a zip whose `export.data` is JSON. Archived items are imported too; trashed ones are not.
enum OnePux {
    static func importRecords(_ zip: Data) throws -> [VaultRecord] {
        guard let data = try ZipReader.entry(Array(zip), name: "export.data"), let root = (try? JSONSerialization.jsonObject(with: Data(data))) as? [String: Any] else {
            throw VaultError.invalid("Unrecognised zip file. PassVault reads 1Password .1pux exports.")
        }
        let vaults = (root["accounts"] as? [[String: Any]] ?? []).flatMap { $0["vaults"] as? [[String: Any]] ?? [] }
        var out = [VaultRecord]()
        for vault in vaults {
            let vaultName = (vault["attrs"] as? [String: Any]).map { BitwardenJson.str($0, "name") } ?? ""
            for item in vault["items"] as? [[String: Any]] ?? [] {
                if BitwardenJson.str(item, "state") == "trashed" { continue }
                let overview = item["overview"] as? [String: Any] ?? [:], details = item["details"] as? [String: Any] ?? [:]
                let tags = overview["tags"] as? [String] ?? []
                let group = tags.first ?? (vaults.count > 1 ? vaultName : "")
                let favorite = (item["favIndex"] as? Int ?? 0) > 0
                let updated = (item["updatedAt"] as? Int).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
                var website = BitwardenJson.str(overview, "url")
                if website.isEmpty, let first = (overview["urls"] as? [[String: Any]])?.first { website = BitwardenJson.str(first, "url") }
                let name = ImportBuilder.name(BitwardenJson.str(overview, "title"), website: website)
                let notes = BitwardenJson.str(details, "notesPlain"), category = BitwardenJson.str(item, "categoryUuid")
                // A card's own fields fill the card; any others stay as extra fields.
                let cardFields: Set<String> = category == "002" ? ["cardholder", "ccnum", "cvv", "expiry", "pin"] : []
                var username = "", password = BitwardenJson.str(details, "password"), totp = "", extra = [VaultField](), byId = [String: String]()
                for f in details["loginFields"] as? [[String: Any]] ?? [] {
                    switch BitwardenJson.str(f, "designation") {
                    case "username": username = BitwardenJson.str(f, "value")
                    case "password": password = BitwardenJson.str(f, "value")
                    default: if !BitwardenJson.str(f, "value").isEmpty { extra.append(ImportBuilder.extra(BitwardenJson.str(f, "name"), BitwardenJson.str(f, "value"), secret: BitwardenJson.str(f, "fieldType") == "P")) }
                    }
                }
                for section in details["sections"] as? [[String: Any]] ?? [] {
                    for f in section["fields"] as? [[String: Any]] ?? [] {
                        guard let value = f["value"] as? [String: Any], let kind = value.keys.first else { continue }
                        var text = ""
                        switch kind {
                        case "monthYear": if let v = value[kind] as? Int, v > 0 { text = String(format: "%02d/%02d", v % 100, (v / 100) % 100) }
                        case "date": if let v = value[kind] as? Int, v > 0 { text = Expiry.format(Expiry.components(Date(timeIntervalSince1970: TimeInterval(v)))) }
                        case "email": text = (value[kind] as? [String: Any]).map { BitwardenJson.str($0, "email_address") } ?? BitwardenJson.str(value, kind)
                        case "address": if let a = value[kind] as? [String: Any] { text = ["street", "city", "state", "zip", "country"].map { BitwardenJson.str(a, $0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", ") }
                        case "sshKey": text = (value[kind] as? [String: Any]).map { BitwardenJson.str($0, "privateKey") } ?? ""
                        default: text = BitwardenJson.str(value, kind)
                        }
                        if text.isEmpty { continue }
                        let id = BitwardenJson.str(f, "id")
                        if kind == "totp" && totp.isEmpty { totp = text; continue }
                        byId[id] = text
                        if cardFields.contains(id) { continue }
                        let title = BitwardenJson.str(f, "title")
                        extra.append(ImportBuilder.extra(title.isEmpty ? id : title, text, secret: ["concealed", "creditCardNumber", "sshKey"].contains(kind)))
                    }
                }
                let history = (details["passwordHistory"] as? [[String: Any]] ?? []).map { PasswordChange(value: BitwardenJson.str($0, "value"), changedAt: Int64($0["time"] as? Int ?? 0)) }
                switch category {
                case "001", "005": out += ImportBuilder.login(name, website: website, username: username, password: password, notes: notes, group: group, favorite: favorite, updatedAt: updated, history: history, extra: extra, totp: totp)
                case "002": out.append(ImportBuilder.card(name, holder: byId["cardholder"] ?? "", number: byId["ccnum"] ?? "", expiry: byId["expiry"] ?? "", code: byId["cvv"] ?? "", pin: byId["pin"] ?? "", notes: notes, group: group, favorite: favorite, updatedAt: updated, extra: extra))
                default: out.append(ImportBuilder.note(name, notes: notes, group: group, favorite: favorite, updatedAt: updated, extra: (password.isEmpty ? [] : [ImportBuilder.extra("Password", password, secret: true)]) + extra))
                }
            }
        }
        return try Records.validate(out)
    }
}

/// Reads one stored or deflated file from a zip archive (via its central directory), refusing anything past the vault size limit.
enum ZipReader {
    static func entry(_ z: [UInt8], name: String) throws -> [UInt8]? {
        func u16(_ o: Int) -> Int { Int(z[o]) | Int(z[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let damaged = VaultError.invalid("The zip file is damaged.")
        // End of central directory: the last "PK\5\6" record (it may be followed by a comment of up to 64 KiB).
        guard z.count >= 22, let end = stride(from: z.count - 22, through: max(0, z.count - 22 - 65535), by: -1).first(where: { z[$0] == 0x50 && z[$0 + 1] == 0x4B && z[$0 + 2] == 5 && z[$0 + 3] == 6 }) else { throw damaged }
        var pos = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            guard pos + 46 <= z.count, u32(pos) == 0x02014B50 else { throw damaged }
            let method = u16(pos + 10), compressed = u32(pos + 20), size = u32(pos + 24), nameLength = u16(pos + 28), extraLength = u16(pos + 30), commentLength = u16(pos + 32), local = u32(pos + 42)
            guard pos + 46 + nameLength <= z.count else { throw damaged }
            let entryName = String(decoding: z[pos + 46..<pos + 46 + nameLength], as: UTF8.self)
            pos += 46 + nameLength + extraLength + commentLength
            guard entryName == name else { continue }
            guard size <= Records.maxBytes, local + 30 <= z.count, u32(local) == 0x04034B50 else { throw damaged }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= z.count else { throw damaged }
            let body = Array(z[start..<start + compressed])
            switch method {
            case 0: return body
            case 8: return try Inflate.raw(body, limit: Records.maxBytes)
            default: throw VaultError.invalid("The zip file uses a compression PassVault does not support.")
            }
        }
        return nil
    }
}
