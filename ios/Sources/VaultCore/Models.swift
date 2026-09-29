import Foundation

public enum VaultError: Error, LocalizedError {
    case invalid(String), authentication, locked, erased
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .authentication: return "Incorrect password or damaged encrypted data."
        case .locked: return "Your vault is locked."
        case .erased: return "The local vault was erased after 10 failed attempts. Restore an encrypted backup to a new vault."
        }
    }
}
public enum FieldKind: String, Codable, CaseIterable, Sendable { case username, password, note, question }
/// An earlier value of a password or security answer, with the time it was replaced. Created when a saved value changes and by Password Keeper (.pkb2) imports; separate from any field the user names "Previous password".
public struct PasswordChange: Codable, Equatable, Sendable {
    public var value: String
    public var changedAt: Int64
    public init(value: String, changedAt: Int64) { self.value = value; self.changedAt = changedAt }
}
public struct VaultField: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var kind: FieldKind
    public var label: String
    public var value: String
    public var question: String
    /// nil (omitted from the file) unless the field came from an import that carried history.
    public var history: [PasswordChange]? = nil
    public init(kind: FieldKind, label: String, value: String = "", question: String = "", history: [PasswordChange]? = nil) {
        self.kind = kind; self.label = label; self.value = value; self.question = question; self.history = history
    }
    /// Password history, most recently changed first.
    public var historyNewestFirst: [PasswordChange] { (history ?? []).sorted { $0.changedAt > $1.changedAt } }
    public var secret: Bool { kind == .password || kind == .question }
}
public struct VaultRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var name = ""
    public var website = ""
    public var group = ""
    public var favorite = false
    public var updatedAt = ISO8601DateFormatter().string(from: Date())
    public var fields: [VaultField] = [
        .init(kind: .username, label: "Username"),
        .init(kind: .password, label: "Password"),
        .init(kind: .note, label: "Notes")
    ]
    public var legacy: [String: String] = [:]
    /// nil or "login" for passwords; "seed" for BIP-39 seed phrases (created on Android), which never go into CSV.
    public var type: String? = nil
    public var isLogin: Bool { type == nil || type == "login" }
    public init() {}
    public func matches(_ query: String) -> Bool {
        let searchable = [name, website, group] + fields.filter { !$0.secret }.map(\.value)
        return query.isEmpty || searchable.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
/// A stable color for a group as (red, green, blue) in 0...1, derived from its name (trimmed, ignoring case) so it never has to be stored and
/// matches Android: FNV-1a hash of the UTF-8 bytes picks the hue, with fixed saturation and lightness that read on light and dark surfaces.
public func groupColorRGB(_ name: String) -> (r: Double, g: Double, b: Double) {
    var h: UInt64 = 0x811C9DC5
    for byte in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8 { h = ((h ^ UInt64(byte)) &* 16777619) & 0xFFFFFFFF }
    let hue = Double(h % 360), s = 0.65, l = 0.5
    let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
    let rgb: (Double, Double, Double)
    switch Int(hue / 60) { case 0: rgb = (c, x, 0); case 1: rgb = (x, c, 0); case 2: rgb = (0, c, x); case 3: rgb = (0, x, c); case 4: rgb = (x, 0, c); default: rgb = (c, 0, x) }
    return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
}
public let passwordHistoryLimit = 10
extension VaultRecord {
    /// Adds the replaced value of every password / security-answer field that differs from `previous` to that field's own history,
    /// stamped `date`. Fields are matched by id; a field that was empty before, or is unchanged, records nothing. Keeps the newest
    /// `passwordHistoryLimit` entries per field. Seed phrases are not tracked.
    public func recordingPasswordChanges(previous: VaultRecord?, at date: Date = Date()) -> VaultRecord {
        guard let previous, isLogin else { return self }
        let before = Dictionary(previous.fields.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var updated = self
        updated.fields = fields.map { field in
            guard let old = before[field.id], field.secret, !old.value.isEmpty, old.value != field.value else { return field }
            var changed = field
            let all = ((field.history ?? []) + [PasswordChange(value: old.value, changedAt: Int64(date.timeIntervalSince1970))]).sorted { $0.changedAt > $1.changedAt }
            changed.history = Array(all.prefix(passwordHistoryLimit))
            return changed
        }
        return updated
    }
}
public enum Records {
    public static let maxBytes = 16 * 1024 * 1024
    public static func validate(_ records: [VaultRecord]) throws -> [VaultRecord] {
        guard records.count <= 10000, Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ $0.fields.count <= 200 && Set($0.fields.map(\.id)).count == $0.fields.count }) else {
            throw VaultError.invalid("Too many records, fields, or duplicate identifiers.")
        }
        return records
    }
    public static func encode(_ records: [VaultRecord]) throws -> Data {
        let data = try JSONEncoder().encode(validate(records))
        guard data.count <= maxBytes else { throw VaultError.invalid("Vault exceeds the 16 MiB limit.") }
        return data
    }
    public static func decode(_ data: Data) throws -> [VaultRecord] {
        guard data.count <= maxBytes else { throw VaultError.invalid("File exceeds the 16 MiB limit.") }
        return try validate(JSONDecoder().decode([VaultRecord].self, from: data))
    }
}
