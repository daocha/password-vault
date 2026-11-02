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
    public static func due(_ records: [VaultRecord], lastBackup: Date?, intervalDays: Int, snoozedUntil: Date?, now: Date = Date(), snapshotAt: Date? = nil) -> Bool {
        guard intervalDays > 0, !records.isEmpty, snoozedUntil.map({ now >= $0 }) ?? true else { return false }
        guard let lastBackup else { return true }
        return now.timeIntervalSince(lastBackup) >= Double(intervalDays) * 86400 && changedSince(records, lastBackup: snapshotAt ?? lastBackup) > 0
    }
}

/// Nonsecret history belongs to a particular vault instance, independently of which vault is currently open.
public struct BackupStatus {
    private static let mutex = NSRecursiveLock()
    private let defaults: UserDefaults
    private let prefix: String
    public init(defaults: UserDefaults = .standard, decoy: Bool = false) {
        self.defaults = defaults; prefix = decoy ? "decoy." : ""
    }
    private func serialized<T>(_ action: () -> T) -> T {
        Self.mutex.lock(); defer { Self.mutex.unlock() }; return action()
    }
    public var lastBackup: Date? { serialized { defaults.object(forKey: prefix + "lastBackupAt") as? Date } }
    public var snapshotAt: Date? { serialized { defaults.object(forKey: prefix + "backupSnapshotAt") as? Date ?? lastBackup } }
    public var instance: Int { serialized { defaults.integer(forKey: prefix + "backupInstance") } }
    public var intervalDays: Int {
        get { serialized { defaults.object(forKey: prefix + "backupReminderDays") as? Int ?? 30 } }
        nonmutating set { serialized { defaults.set(newValue, forKey: prefix + "backupReminderDays") } }
    }
    public var snoozedUntil: Date? {
        get { serialized { defaults.object(forKey: prefix + "backupSnoozeUntil") as? Date } }
        nonmutating set { serialized { defaults.set(newValue, forKey: prefix + "backupSnoozeUntil") } }
    }
    public func record(savedAt: Date, snapshotAt: Date, instance: Int) {
        serialized {
            guard instance == self.instance else { return }
            defaults.set(savedAt, forKey: prefix + "lastBackupAt")
            defaults.set(snapshotAt, forKey: prefix + "backupSnapshotAt")
            defaults.removeObject(forKey: prefix + "backupSnoozeUntil")
        }
    }
    public func clear() {
        serialized {
            defaults.set(instance &+ 1, forKey: prefix + "backupInstance")
            for key in ["lastBackupAt", "backupSnapshotAt", "backupReminderDays", "backupSnoozeUntil"] { defaults.removeObject(forKey: prefix + key) }
        }
    }
}

/// The bytes, source vault and cutoff of one export travel together through the file picker.
public struct VaultExport: Sendable {
    public let data: Data
    public let csv: Bool
    public let decoy: Bool
    public let instance: Int
    public let snapshotAt: Date
    public func recordBackup(defaults: UserDefaults = .standard, savedAt: Date = Date()) {
        guard !csv else { return }
        BackupStatus(defaults: defaults, decoy: decoy).record(savedAt: savedAt, snapshotAt: snapshotAt, instance: instance)
    }
}
