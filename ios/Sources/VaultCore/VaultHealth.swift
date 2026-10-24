import Foundation

/// Offline password-strength estimate: no breach lookup and no network. Common passwords (and the same with leetspeak, or digits and
/// symbols tacked on) score 0. Otherwise the estimate is length × log2(character pool), where a character that only repeats the previous
/// one or continues an alphabetical, numerical or keyboard-row run counts half, and each further one in the same run a tenth. Android
/// implements the same rules and word list.
public enum PasswordStrength {
    /// 0 very weak, 1 weak, 2 fair, 3 strong, 4 very strong.
    public static func score(_ password: String) -> Int {
        if password.isEmpty || isCommon(password) { return 0 }
        let value = bits(password)
        let score = value < 28 ? 0 : value < 36 ? 1 : value < 60 ? 2 : value < 80 ? 3 : 4
        return password.unicodeScalars.count < 8 ? min(score, 1) : score
    }
    public static func bits(_ password: String) -> Double {
        let chars = password.unicodeScalars.map(\.value)
        var pool = 0
        if chars.contains(where: { (0x61...0x7A).contains($0) }) { pool += 26 }
        if chars.contains(where: { (0x41...0x5A).contains($0) }) { pool += 26 }
        if chars.contains(where: { (0x30...0x39).contains($0) }) { pool += 10 }
        if chars.contains(where: { (0x20...0x7E).contains($0) && !isAsciiAlnum($0) }) { pool += 33 }
        if chars.contains(where: { $0 > 0x7E }) { pool += 100 }
        var length = 0.0, run = 0
        for i in chars.indices {
            run = i > 0 && continues(chars[i - 1], chars[i]) ? run + 1 : 0
            length += run == 0 ? 1 : run == 1 ? 0.5 : 0.1
        }
        return length * log2(Double(pool))
    }
    private static func isAsciiAlnum(_ c: UInt32) -> Bool { (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) }
    private static func lower(_ c: UInt32) -> UInt32 {
        guard let scalar = Unicode.Scalar(c) else { return c }
        let mapped = scalar.properties.lowercaseMapping.unicodeScalars
        return mapped.count == 1 ? mapped.first!.value : c
    }
    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890"].map { Array($0.unicodeScalars.map(\.value)) }
    private static func continues(_ previous: UInt32, _ current: UInt32) -> Bool {
        let a = lower(previous), b = lower(current)
        if a == b { return true }
        if isAsciiAlnum(a) && isAsciiAlnum(b) && (a == b + 1 || b == a + 1) { return true }
        return rows.contains { row in
            guard let i = row.firstIndex(of: a) else { return false }
            return (i + 1 < row.count && row[i + 1] == b) || (i > 0 && row[i - 1] == b)
        }
    }
    public static let common: Set<String> = Set(commonPasswordList.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    private static let leet: [Character: Character] = ["@": "a", "4": "a", "0": "o", "1": "i", "!": "i", "3": "e", "5": "s", "$": "s", "7": "t", "+": "t"]
    public static func isCommon(_ password: String) -> Bool {
        let lower = password.lowercased()
        // Digits and symbols around a word ("Password123!", "!monkey") do not make it a new password.
        let core = String(lower.drop { !$0.isLetter }.reversed().drop { !$0.isLetter }.reversed())
        func unleet(_ s: String) -> String { String(s.map { leet[$0] ?? $0 }) }
        return [lower, core, unleet(lower), unleet(core)].contains { $0.unicodeScalars.count >= 3 && common.contains($0) }
    }
}

/// One password field of one login record, the unit every check reports on.
public struct CheckedPassword: Sendable {
    public let record: VaultRecord, field: VaultField
    public init(record: VaultRecord, field: VaultField) { self.record = record; self.field = field }
}
public struct HealthReport: Sendable {
    /// Passwords used by more than one entry, one list per shared value.
    public let reused: [[CheckedPassword]]
    public let weak: [(password: CheckedPassword, score: Int)]
    /// Passwords not changed for over `VaultHealth.oldDays` days, with the day they were set.
    public let old: [(password: CheckedPassword, since: DateComponents)]
    public let expiring: [VaultRecord]
    /// Logins for well-known services that have no authenticator record here. Advice only: the service may use another 2FA method.
    public let noTwoFactor: [VaultRecord]
    public let checked: Int
    /// 0–100: each checked password counts fully when fine, half when only old, nothing when reused or weak. Nil with nothing to check.
    public var score: Int? {
        guard checked > 0 else { return nil }
        func key(_ p: CheckedPassword) -> String { p.record.id + "/" + p.field.id }
        let bad = Set(reused.flatMap { $0 }.map(key) + weak.map { key($0.password) })
        let aged = Set(old.map { key($0.password) }).subtracting(bad)
        return Int((100.0 * (Double(checked - bad.count) - Double(aged.count) * 0.5) / Double(checked)).rounded())
    }
    public var problemCount: Int { reused.reduce(0) { $0 + $1.count } + weak.count + old.count + expiring.count }
}

public enum VaultHealth {
    public static let oldDays = 365
    public static func check(_ records: [VaultRecord], today: DateComponents = Expiry.today()) -> HealthReport {
        let passwords = records.filter(\.isLogin).flatMap { r in r.fields.filter { $0.kind == .password && !$0.value.isEmpty }.map { CheckedPassword(record: r, field: $0) } }
        var groups = [String: [CheckedPassword]](), order = [String]()
        for p in passwords { if groups[p.field.value] == nil { order.append(p.field.value) }; groups[p.field.value, default: []].append(p) }
        let reused = order.compactMap { groups[$0] }.filter { Set($0.map(\.record.id)).count > 1 }.enumerated().sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }.map(\.element)
        let weak = passwords.map { (password: $0, score: PasswordStrength.score($0.field.value)) }.filter { $0.score <= 1 }.enumerated().sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }.map(\.element)
        let cutoff = Expiry.dayNumber(today) - oldDays
        let old = passwords.compactMap { p -> (password: CheckedPassword, since: DateComponents)? in
            guard let since = passwordSetOn(p), Expiry.dayNumber(since) < cutoff else { return nil }
            return (p, since)
        }.enumerated().sorted { (Expiry.dayNumber($0.element.since), $0.offset) < (Expiry.dayNumber($1.element.since), $1.offset) }.map(\.element)
        let expiring = records.filter { [.expired, .soon].contains($0.expiryState(today: today)) }.enumerated()
            .sorted { (Expiry.dayNumber($0.element.expiryDate!), $0.offset) < (Expiry.dayNumber($1.element.expiryDate!), $1.offset) }.map(\.element)
        let covered = Set(records.filter(\.isTotp).compactMap { findBrand(website: $0.totp?.issuer ?? "", name: $0.name)?.id })
        let noTwoFactor = records.filter { r in r.isLogin && r.fields.contains { $0.kind == .password && !$0.value.isEmpty } && (findBrand(website: r.website, name: r.name).map { !covered.contains($0.id) } ?? false) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return HealthReport(reused: reused, weak: weak, old: old, expiring: expiring, noTwoFactor: noTwoFactor, checked: passwords.count)
    }
    /// When the current value was set: the newest history entry (the moment the previous value was replaced), else Password Keeper's
    /// `passwordSetDate`, else the record's last change, which is only an upper bound for records edited without changing the password.
    public static func passwordSetOn(_ p: CheckedPassword) -> DateComponents? {
        var epoch = (p.field.history ?? []).map(\.changedAt).max().flatMap { $0 > 0 ? $0 : nil }
        if epoch == nil, let legacy = p.record.legacy["passwordSetDate"].flatMap({ Int64($0) }), legacy > 0 { epoch = legacy > 100_000_000_000 ? legacy / 1000 : legacy }
        let date: Date
        if let epoch { date = Date(timeIntervalSince1970: TimeInterval(epoch)) }
        else {
            let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let parsed = plain.date(from: p.record.updatedAt) ?? fractional.date(from: p.record.updatedAt) else { return nil }
            date = parsed
        }
        return Expiry.components(date)
    }
}
