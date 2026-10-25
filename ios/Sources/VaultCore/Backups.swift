import Foundation

/// Backup reminder rules; the same as Android's `BackupReminder`.
public enum BackupReminder {
    public static let snoozeDays = 3
    /// The reminder choices, in days; 0 turns reminders off.
    public static let intervals = [0, 7, 14, 30]
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }
    /// Entries added or edited after `lastBackup` (all of them before any backup). Deleted entries cannot be counted.
    public static func changedSince(_ records: [VaultRecord], lastBackup: Date?) -> Int {
        guard let lastBackup else { return records.count }
        return records.filter { parse($0.updatedAt).map { $0 > lastBackup } ?? true }.count
    }
    /// Due when reminders are on, the vault has entries, it is not snoozed, and either there has never been a backup or the last one is at
    /// least an interval old and something changed since.
    public static func due(_ records: [VaultRecord], lastBackup: Date?, intervalDays: Int, snoozedUntil: Date?, now: Date = Date()) -> Bool {
        guard intervalDays > 0, !records.isEmpty, snoozedUntil.map({ now >= $0 }) ?? true else { return false }
        guard let lastBackup else { return true }
        return now.timeIntervalSince(lastBackup) >= Double(intervalDays) * 86400 && changedSince(records, lastBackup: lastBackup) > 0
    }
}
