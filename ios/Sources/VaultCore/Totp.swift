import Foundation
import CryptoKit

/// The field of a `totp` record that holds its `otpauth://totp/...` URI (secret and parameters together).
public let totpLabel = "Authenticator"

/// One time-based one-time password account (RFC 6238), as found in an `otpauth://totp/` URI. `issuer` is the service (e.g. "Binance")
/// and `account` the user name shown beside it.
public struct TotpAccount: Equatable, Sendable {
    public static let algorithms = ["SHA1", "SHA256", "SHA512"]
    public var secret: Data
    public var issuer: String
    public var account: String
    public var algorithm: String
    public var digits: Int
    public var period: Int
    public init(secret: Data, issuer: String = "", account: String = "", algorithm: String = "SHA1", digits: Int = 6, period: Int = 30) throws {
        guard !secret.isEmpty, secret.count <= 256 else { throw VaultError.invalid("Invalid authenticator key.") }
        guard Self.algorithms.contains(algorithm), (6...8).contains(digits), (1...300).contains(period) else { throw VaultError.invalid("Unsupported authenticator settings.") }
        self.secret = secret; self.issuer = issuer; self.account = account; self.algorithm = algorithm; self.digits = digits; self.period = period
    }
    public var secretBase32: String { Totp.base32(secret) }
    /// Canonical URI: the form stored in the vault and backups, and readable by other authenticator apps. Same encoding as Android.
    public var uri: String {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: Totp.unreserved) ?? s }
        let label = issuer.isEmpty ? enc(account) : enc(issuer) + ":" + enc(account)
        return "otpauth://totp/\(label)?secret=\(secretBase32)" + (issuer.isEmpty ? "" : "&issuer=\(enc(issuer))") + "&algorithm=\(algorithm)&digits=\(digits)&period=\(period)"
    }
    public func code(at date: Date = Date()) -> String { Totp.code(self, at: Int64(date.timeIntervalSince1970.rounded(.down))) }
    /// Seconds until the current code changes.
    public func remaining(at date: Date = Date()) -> Int { let t = Int64(date.timeIntervalSince1970.rounded(.down)), p = Int64(period); return Int(p - ((t % p) + p) % p) }
    /// The record stored for this account; the name defaults to the issuer, then the account.
    public func record(name: String? = nil) -> VaultRecord {
        var record = VaultRecord()
        let fallback = issuer.trimmingCharacters(in: .whitespaces).isEmpty ? account : issuer
        record.name = (name ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        if record.name.isEmpty { record.name = "Authenticator" }
        record.type = "totp"
        record.fields = [VaultField(kind: .password, label: totpLabel, value: uri)]
        return record
    }
}

extension VaultRecord {
    public var isTotp: Bool { type == "totp" }
    /// The authenticator account stored in a `totp` record, or nil when its URI is missing or damaged.
    public var totp: TotpAccount? { fields.first { $0.label == totpLabel }.flatMap { try? Totp.parseURI($0.value) } }
}

public enum Totp {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    /// Matches Java's URLEncoder output after "+" is turned into "%20", so both platforms write identical URIs.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.*")

    public static func code(_ account: TotpAccount, at epochSeconds: Int64) -> String {
        let p = Int64(account.period)
        var counter = UInt64(bitPattern: (epochSeconds >= 0 ? epochSeconds : epochSeconds - p + 1) / p).bigEndian
        let message = Data(bytes: &counter, count: 8), key = SymmetricKey(data: account.secret)
        let hash: [UInt8]
        switch account.algorithm {
        case "SHA256": hash = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case "SHA512": hash = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        default: hash = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        }
        let offset = Int(hash[hash.count - 1] & 0x0F)
        let binary = (UInt32(hash[offset] & 0x7F) << 24) | (UInt32(hash[offset + 1]) << 16) | (UInt32(hash[offset + 2]) << 8) | UInt32(hash[offset + 3])
        var modulus: UInt32 = 1; for _ in 0..<account.digits { modulus *= 10 }
        let value = String(binary % modulus)
        return String(repeating: "0", count: account.digits - value.count) + value
    }

    public static func base32(_ data: Data) -> String {
        var out = "", buffer = 0, bits = 0
        for byte in data { buffer = (buffer << 8) | Int(byte); bits += 8; while bits >= 5 { out.append(alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5 }; buffer &= (1 << bits) - 1 }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }
    /// Decodes a Base32 key as sites display it: case, spaces, hyphens and `=` padding are ignored.
    public static func decodeBase32(_ text: String) throws -> Data {
        let clean = text.uppercased().filter { $0 != " " && $0 != "-" && $0 != "=" }
        guard !clean.isEmpty else { throw VaultError.invalid("The key must be Base32 (letters A–Z and digits 2–7).") }
        var out = Data(), buffer = 0, bits = 0
        for c in clean {
            guard let index = alphabet.firstIndex(of: c) else { throw VaultError.invalid("The key must be Base32 (letters A–Z and digits 2–7).") }
            buffer = (buffer << 5) | index; bits += 5
            if bits >= 8 { out.append(UInt8((buffer >> (bits - 8)) & 0xFF)); bits -= 8; buffer &= (1 << bits) - 1 }
        }
        guard !out.isEmpty else { throw VaultError.invalid("The key is too short.") }
        return out
    }

    private static func query(_ components: URLComponents) -> [String: String] {
        var result = [String: String]()
        for item in components.queryItems ?? [] where result[item.name.lowercased()] == nil { result[item.name.lowercased()] = item.value ?? "" }
        return result
    }

    /// Parses `otpauth://totp/Issuer:account?secret=...`. HOTP (counter-based) accounts are rejected.
    public static func parseURI(_ text: String) throws -> TotpAccount {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), components.scheme?.lowercased() == "otpauth" else { throw VaultError.invalid("Not an authenticator QR code.") }
        guard components.host?.lowercased() == "totp" else { throw VaultError.invalid("Only time-based (TOTP) codes are supported.") }
        let params = query(components)
        let label = String(components.path.drop { $0 == "/" })
        let colon = label.firstIndex(of: ":")
        let labelIssuer = colon.map { String(label[..<$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        let account = (colon.map { String(label[label.index(after: $0)...]) } ?? label).trimmingCharacters(in: .whitespaces)
        guard let secret = params["secret"] else { throw VaultError.invalid("The QR code has no key.") }
        func number(_ name: String, _ fallback: Int) -> Int { guard let value = params[name], !value.isEmpty else { return fallback }; return Int(value) ?? 0 }
        let issuer = params["issuer"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let algorithm = params["algorithm"]?.uppercased() ?? ""
        return try TotpAccount(secret: decodeBase32(secret), issuer: issuer.isEmpty ? labelIssuer : issuer, account: account,
                               algorithm: algorithm.isEmpty ? "SHA1" : algorithm, digits: number("digits", 6), period: number("period", 30))
    }

    public struct Migration: Sendable { public var accounts: [TotpAccount]; public var skipped: Int }
    public static func isMigration(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("otpauth-migration://") }
    /// Google Authenticator's "Transfer accounts" QR: `otpauth-migration://offline?data=<base64 protobuf>`. Large exports are split over
    /// several QR codes; each holds whole accounts, so each one is imported on its own. HOTP accounts are counted in `skipped`.
    public static func parseMigration(_ text: String) throws -> Migration {
        guard isMigration(text), let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VaultError.invalid("Not a Google Authenticator export.") }
        guard let raw = query(components)["data"] else { throw VaultError.invalid("The export QR code has no data.") }
        var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").filter { !$0.isWhitespace }
        while b64.count % 4 != 0 { b64.append("=") }
        guard let bytes = Data(base64Encoded: b64) else { throw VaultError.invalid("Damaged export QR code.") }
        var accounts = [TotpAccount](), skipped = 0
        for (field, value) in try Protobuf.fields(bytes) {
            guard field == 1, case .bytes(let entry) = value else { continue }
            var secret = Data(), name = "", issuer = "", algorithm = 1, digits = 1, type = 2
            for (f, v) in try Protobuf.fields(entry) {
                switch (f, v) {
                case (1, .bytes(let d)): secret = d
                case (2, .bytes(let d)): name = String(decoding: d, as: UTF8.self)
                case (3, .bytes(let d)): issuer = String(decoding: d, as: UTF8.self)
                case (4, .varint(let n)): algorithm = Int(truncatingIfNeeded: n)
                case (5, .varint(let n)): digits = Int(truncatingIfNeeded: n)
                case (6, .varint(let n)): type = Int(truncatingIfNeeded: n)
                default: break
                }
            }
            let algo: String? = [0: "SHA1", 1: "SHA1", 2: "SHA256", 3: "SHA512"][algorithm]
            guard type != 1, let algo, !secret.isEmpty else { skipped += 1; continue }
            // Exports often repeat the issuer as a prefix of the name ("Binance: me@example.com").
            let account = !issuer.isEmpty && name.hasPrefix(issuer + ":") ? String(name.dropFirst(issuer.count + 1)).trimmingCharacters(in: .whitespaces) : name
            accounts.append(try TotpAccount(secret: secret, issuer: issuer.trimmingCharacters(in: .whitespaces), account: account, algorithm: algo, digits: digits == 2 ? 8 : 6, period: 30))
        }
        guard !accounts.isEmpty || skipped > 0 else { throw VaultError.invalid("The export QR code has no accounts.") }
        return Migration(accounts: accounts, skipped: skipped)
    }

    /// Minimal protobuf reader: varint and length-delimited fields; fixed-width fields are skipped.
    private enum Protobuf {
        enum Value { case varint(UInt64), bytes(Data) }
        static func fields(_ data: Data) throws -> [(Int, Value)] {
            let b = [UInt8](data); var i = 0, out = [(Int, Value)]()
            func varint() throws -> UInt64 {
                var result: UInt64 = 0, shift: UInt64 = 0
                while true {
                    guard i < b.count, shift < 64 else { throw VaultError.invalid("Damaged export QR code.") }
                    let x = b[i]; i += 1; result |= UInt64(x & 0x7F) << shift
                    if x & 0x80 == 0 { return result }; shift += 7
                }
            }
            while i < b.count {
                let key = try varint(), field = Int(truncatingIfNeeded: key >> 3)
                switch key & 7 {
                case 0: out.append((field, .varint(try varint())))
                case 1: guard i + 8 <= b.count else { throw VaultError.invalid("Damaged export QR code.") }; i += 8
                case 2:
                    let length = try varint()
                    guard length <= UInt64(b.count - i) else { throw VaultError.invalid("Damaged export QR code.") }
                    out.append((field, .bytes(Data(b[i..<(i + Int(length))])))); i += Int(length)
                case 5: guard i + 4 <= b.count else { throw VaultError.invalid("Damaged export QR code.") }; i += 4
                default: throw VaultError.invalid("Damaged export QR code.")
                }
            }
            return out
        }
    }
}
