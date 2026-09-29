import Foundation
import Clibsodium
import CommonCrypto

/// Reader for BlackBerry Password Keeper `.pkb2` backups (format taken from the app's own exporter).
///
///     "PKB2" | u32be version (1 or 2) | salt 32 | iv 16
///            | u32be n1 | keys (AES-CBC) | HMAC-SHA256(macKey, keys) 32
///            | u32be n2 | records (AES-CBC) | HMAC-SHA256(recordsMacKey, records) 32
///
/// Version 2 derives 64 bytes with scrypt(N=65536, r=8, p=1); version 1 used PBKDF2-HMAC-SHA256 (10000 iterations).
/// The first half is the AES key that opens `keys`, the second half its HMAC key. `keys` = recordsKey 32 | recordsMacKey 32 | recordsIv 16.
public enum Pkb2 {
    private static let magic = Data("PKB2".utf8)
    public static func isPkb2(_ data: Data) -> Bool { data.prefix(4) == magic }

    private static func int(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
    private static func damaged() -> VaultError { .invalid("Damaged Password Keeper backup.") }

    private static func hmacMatches(key: ArraySlice<UInt8>, data: [UInt8], tag: [UInt8]) -> Bool {
        var mac = [UInt8](repeating: 0, count: 32)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), Array(key), key.count, data, data.count, &mac)
        return mac.count == tag.count && sodium_memcmp(mac, tag, 32) == 0
    }
    private static func cbcDecrypt(key: ArraySlice<UInt8>, iv: [UInt8], data: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128); var produced = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), Array(key), key.count, iv, data, data.count, &out, out.count, &produced)
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(produced))
    }
    private static func derive(_ password: [UInt8], salt: [UInt8], version: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64)
        if version == 2 {
            guard VaultCrypto.initialized, crypto_pwhash_scryptsalsa208sha256_ll(password, password.count, salt, salt.count, 65536, 8, 1, &out, out.count) == 0 else { throw VaultError.invalid("Not enough memory to open this backup.") }
        } else {
            guard CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.map { Int8(bitPattern: $0) }, password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 10000, &out, out.count) == kCCSuccess else { throw damaged() }
        }
        return out
    }

    public static func importRecords(_ file: Data, password: String) throws -> [VaultRecord] {
        let d = [UInt8](file)
        guard isPkb2(file), d.count >= 8 + 48 + 4 else { throw VaultError.invalid("Not a Password Keeper backup.") }
        let version = int(d, 4)
        guard version == 1 || version == 2 else { throw VaultError.invalid("Unsupported Password Keeper backup version \(version).") }
        let salt = Array(d[8..<40]), iv = Array(d[40..<56])
        let n1 = int(d, 56)
        guard n1 >= 16, n1 <= d.count, 60 + n1 + 32 + 4 <= d.count else { throw damaged() }
        let keys = Array(d[60..<(60 + n1)]), mac1 = Array(d[(60 + n1)..<(92 + n1)])
        let n2 = int(d, 92 + n1)
        guard n2 >= 16, n2 <= d.count, 96 + n1 + n2 + 32 == d.count else { throw damaged() }
        let records = Array(d[(96 + n1)..<(96 + n1 + n2)]), mac2 = Array(d[(96 + n1 + n2)...])
        var derived = try derive(Array(password.utf8), salt: salt, version: version)
        defer { sodium_memzero(&derived, derived.count) }
        guard hmacMatches(key: derived[32..<64], data: keys, tag: mac1) else { throw VaultError.authentication }
        guard var inner = cbcDecrypt(key: derived[0..<32], iv: iv, data: keys), inner.count >= 80 else { throw VaultError.authentication }
        defer { sodium_memzero(&inner, inner.count) }
        guard hmacMatches(key: inner[32..<64], data: records, tag: mac2) else { throw VaultError.invalid("The backup is damaged (integrity check failed).") }
        guard var plain = cbcDecrypt(key: inner[0..<32], iv: Array(inner[64..<80]), data: records) else { throw damaged() }
        defer { sodium_memzero(&plain, plain.count) }
        return try parse(String(decoding: plain, as: UTF8.self))
    }

    // MARK: JSON (order-preserving; a subfield can repeat the key "t", which JSONSerialization would collapse)

    final class Obj {
        let entries: [(String, Any?)]
        init(_ entries: [(String, Any?)]) { self.entries = entries }
        func get(_ key: String) -> Any? { entries.first { $0.0 == key }?.1 }
        func all(_ key: String) -> [Any?] { entries.filter { $0.0 == key }.map { $0.1 } }
        func str(_ key: String) -> String? { get(key) as? String }
    }
    private struct Reader {
        let s: [Character]; var i = 0
        init(_ text: String) { s = Array(text) }
        mutating func ws() { while i < s.count, s[i].isWhitespace { i += 1 } }
        mutating func need(_ c: Character) throws { guard i < s.count, s[i] == c else { throw VaultError.invalid("Unrecognised Password Keeper data.") }; i += 1 }
        mutating func value() throws -> Any? {
            ws(); guard i < s.count else { throw VaultError.invalid("Truncated Password Keeper records.") }
            switch s[i] {
            case "{":
                i += 1; var list: [(String, Any?)] = []; ws()
                if s[i] == "}" { i += 1; return Obj(list) }
                while true { ws(); let k = try string(); ws(); try need(":"); list.append((k, try value())); ws(); if s[i] == "," { i += 1 } else { try need("}"); break } }
                return Obj(list)
            case "[":
                i += 1; var list: [Any?] = []; ws()
                if s[i] == "]" { i += 1; return list }
                while true { list.append(try value()); ws(); if s[i] == "," { i += 1 } else { try need("]"); break } }
                return list
            case "\"": return try string()
            default:
                let start = i; while i < s.count, !",]} \n\r\t".contains(s[i]) { i += 1 }
                switch String(s[start..<i]) {
                case "true": return true
                case "false": return false
                case "null": return nil
                case let t: if let n = Int64(t) { return n }; if let x = Double(t) { return x }; throw VaultError.invalid("Unrecognised Password Keeper data.")
                }
            }
        }
        mutating func string() throws -> String {
            try need("\""); var out = ""
            while i < s.count {
                let c = s[i]; i += 1
                if c == "\"" { return out }
                guard c == "\\" else { out.append(c); continue }
                guard i < s.count else { break }
                let e = s[i]; i += 1
                switch e {
                case "n": out.append("\n"); case "t": out.append("\t"); case "r": out.append("\r"); case "b": out.append("\u{8}"); case "f": out.append("\u{c}")
                case "u":
                    guard i + 4 <= s.count, var code = UInt32(String(s[i..<(i + 4)]), radix: 16) else { throw VaultError.invalid("Unrecognised Password Keeper data.") }
                    i += 4
                    if (0xD800..<0xDC00).contains(code), i + 6 <= s.count, s[i] == "\\", s[i + 1] == "u", let low = UInt32(String(s[(i + 2)..<(i + 6)]), radix: 16), (0xDC00..<0xE000).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00); i += 6
                    }
                    out.unicodeScalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: out.append(e)
                }
            }
            throw VaultError.invalid("Unterminated string in Password Keeper data.")
        }
    }

    /// Password Keeper records to PassVault records. Fields keep their original order; password history is attached to its password field.
    static func parse(_ text: String) throws -> [VaultRecord] {
        var reader = Reader(text)
        guard let root = try reader.value() as? Obj else { throw VaultError.invalid("Unrecognised Password Keeper data.") }
        guard let list = root.get("records") as? [Any?] else { return [] }
        return try Records.validate(try list.map { item in
            guard let r = item as? Obj else { throw VaultError.invalid("Unrecognised Password Keeper record.") }
            return record(r)
        })
    }
    private static func label(_ kind: FieldKind) -> String {
        switch kind { case .username: return "Username"; case .password: return "Password"; case .note: return "Notes"; case .question: return "Security question" }
    }
    private static func record(_ r: Obj) -> VaultRecord {
        var out = VaultRecord(); out.fields = []
        var name = ""
        func add(_ kind: FieldKind, _ text: String?, _ value: String, question: String = "", history: [PasswordChange]? = nil) {
            out.fields.append(VaultField(kind: kind, label: (text?.isEmpty == false ? text : nil) ?? label(kind), value: value, question: question, history: history))
        }
        for case let f as Obj in (r.get("f") as? [Any?]) ?? [] {
            let text = f.str("n"), value = f.str("v") ?? ""
            switch f.str("t") {
            case "t": if name.isEmpty { name = value } else if !value.isEmpty { add(.note, text ?? "Title", value) }
            case "w": if out.website.isEmpty { out.website = value } else if !value.isEmpty { add(.note, text ?? "Website", value) }
            case "u": add(.username, text, value)
            case "p":
                // Earlier passwords go into the field's own history (a subfield writes "t" twice: the type, then the change time).
                var history: [PasswordChange] = []
                for case let sf as Obj in (f.get("sf") as? [Any?]) ?? [] where (sf.all("t").first as? String) == "hp" {
                    if let old = sf.str("pw"), !old.isEmpty { history.append(PasswordChange(value: old, changedAt: (sf.all("t").dropFirst().first as? Int64) ?? 0)) }
                }
                add(.password, text, value, history: history.isEmpty ? nil : history)
            case "n": add(.note, text, value)
            case "sq": add(.question, nil, value, question: text ?? "")
            case "c": add(.note, text ?? "Custom", value)
            case "lst":
                let items = ((f.get("sf") as? [Any?]) ?? []).compactMap { $0 as? Obj }.filter { $0.str("t") == "chk" }
                    .sorted { (($0.get("lst_ord") as? Int64) ?? 0) < (($1.get("lst_ord") as? Int64) ?? 0) }
                if !value.isEmpty { add(.note, text ?? "List", value) }
                for item in items { add(.note, text ?? "List item", ((item.get("lst_chk") as? Bool) == true ? "[x] " : "[ ] ") + (item.str("lst_lbl") ?? "")) }
            default: break // Icons, trusted-application lists and bare timestamps are Password Keeper internals.
            }
        }
        out.name = name.isEmpty ? "Untitled" : name
        out.favorite = (r.get("fav") as? Bool) == true
        if let lm = r.get("lm") as? Int64 { out.updatedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(lm))) }
        if let uid = r.str("u") { out.legacy = ["uid": uid] }
        return out
    }
}
