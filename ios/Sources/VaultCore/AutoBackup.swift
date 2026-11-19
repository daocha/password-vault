import Foundation

/// What `VaultEngine.exportAutomatic` found.
public enum AutomaticBackup: Sendable {
    /// The records are the ones the last automatic backup held.
    case unchanged
    /// The key was sealed under an earlier data key (the password changed) or another vault's: set automatic backup up again.
    case keyGone
    case ready(VaultExport, digest: Data)
}

/// The minimum time between successful automatic backups. Monthly is 30 days on both platforms.
public enum AutoBackupFrequency: String, CaseIterable, Sendable {
    case instant, daily, weekly, monthly
    public var seconds: TimeInterval {
        switch self { case .instant: 0; case .daily: 86400; case .weekly: 7 * 86400; case .monthly: 30 * 86400 }
    }
    public func remaining(since last: Date?, now: Date = Date()) -> TimeInterval {
        guard self != .instant, let last else { return 0 }
        return max(0, seconds - now.timeIntervalSince(last))
    }
}

/**
 Automatic backups: save changes instantly by default, or after the chosen interval since the last successful backup, to a chosen folder. The app never goes online: the folder's own app (iCloud Drive, Google Drive, OneDrive…) copies the file elsewhere.
 Each backup is a new dated file and none is ever deleted, so an entry deleted by mistake can still be found in an older backup; the user
 removes old ones when they like. Same rules on Android.
 Kept in ordinary preferences: the folder bookmark and the backup key sealed under the vault's data key, nothing readable.
 */
public struct AutoBackupSettings {
    public enum Problem: String { case keyGone, noAccess, writeFailed }
    private static let mutex = NSRecursiveLock()
    static let keys = ["autoBackupFolder", "autoBackupName", "autoBackupKey", "autoBackupDigest", "autoBackupAt", "autoBackupProblem", "autoBackupFrequency"]
    private let defaults: UserDefaults
    private let prefix: String
    public init(defaults: UserDefaults = .standard, decoy: Bool = false) { self.defaults = defaults; prefix = decoy ? "decoy." : "" }
    private func serialized<T>(_ action: () -> T) -> T { Self.mutex.lock(); defer { Self.mutex.unlock() }; return action() }

    public var enabled: Bool { folderBookmark != nil && sealedKey != nil }
    /// A bookmark to the folder the user picked, which keeps access to it across launches.
    public var folderBookmark: Data? { serialized { defaults.data(forKey: prefix + "autoBackupFolder") } }
    /// The folder name shown in Settings.
    public var name: String { serialized { defaults.string(forKey: prefix + "autoBackupName") ?? "" } }
    /// `VaultEngine.sealAutoBackupKey`: only this vault's data key opens it.
    public var sealedKey: Data? { serialized { defaults.data(forKey: prefix + "autoBackupKey") } }
    /// `VaultCrypto.backupDigest` of what the last automatic backup held.
    public var lastDigest: Data? { serialized { defaults.data(forKey: prefix + "autoBackupDigest") } }
    public var lastAutomatic: Date? { serialized { defaults.object(forKey: prefix + "autoBackupAt") as? Date } }
    public var frequency: AutoBackupFrequency {
        get { serialized { defaults.string(forKey: prefix + "autoBackupFrequency").flatMap(AutoBackupFrequency.init(rawValue:)) ?? .instant } }
        nonmutating set { serialized { defaults.set(newValue.rawValue, forKey: prefix + "autoBackupFrequency") } }
    }
    public func remaining(now: Date = Date()) -> TimeInterval { frequency.remaining(since: lastAutomatic, now: now) }
    public var problem: Problem? { serialized { defaults.string(forKey: prefix + "autoBackupProblem").flatMap(Problem.init(rawValue:)) } }

    public func turnOn(folderBookmark: Data, name: String, sealedKey: Data) {
        serialized {
            defaults.set(folderBookmark, forKey: prefix + "autoBackupFolder"); defaults.set(name, forKey: prefix + "autoBackupName")
            defaults.set(sealedKey, forKey: prefix + "autoBackupKey")
            defaults.removeObject(forKey: prefix + "autoBackupDigest"); defaults.removeObject(forKey: prefix + "autoBackupAt"); defaults.removeObject(forKey: prefix + "autoBackupProblem")
        }
    }
    /// A bookmark iOS reported as stale, made again while the folder was still reachable.
    public func refresh(folderBookmark: Data) { serialized { defaults.set(folderBookmark, forKey: prefix + "autoBackupFolder") } }
    public func succeeded(digest: Data, at: Date) {
        serialized {
            defaults.set(digest, forKey: prefix + "autoBackupDigest"); defaults.set(at, forKey: prefix + "autoBackupAt")
            defaults.removeObject(forKey: prefix + "autoBackupProblem")
        }
    }
    public func failed(_ problem: Problem) { serialized { defaults.set(problem.rawValue, forKey: prefix + "autoBackupProblem") } }
    /// Turns automatic backups off and forgets the folder, key and history (also when the vault is removed or replaced).
    public func clear() { serialized { for key in Self.keys { defaults.removeObject(forKey: prefix + key) } } }
}

/// Automatic backup files: a new dated file each time in the chosen folder. Nothing is deleted. Same names as Android's `AutoBackupFiles`.
public enum AutoBackupFiles {
    private static let prefix = "passvault_auto_", fileExtension = ".pvault"
    /// How many backups Settings lists.
    public static let recent = 5
    /// e.g. passvault_auto_2026-11-19_10_31_05.pvault, in local time: names sort by age.
    public static func name(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd_HH_mm_ss"
        return prefix + formatter.string(from: date) + fileExtension
    }
    /// `name(at:)`, or, when that is `taken` (a second backup within the same second), the same name ending _2, _3… before the extension.
    /// These still sort after the first one.
    public static func uniqueName(at date: Date, timeZone: TimeZone = .current, taken: (String) -> Bool) throws -> String {
        let first = name(at: date, timeZone: timeZone)
        if !taken(first) { return first }
        let stem = first.dropLast(fileExtension.count)
        for count in 2...10_000 where !taken("\(stem)_\(count)\(fileExtension)") { return "\(stem)_\(count)\(fileExtension)" }
        throw VaultError.invalid("Too many backups in one second.")
    }
    /// Whether `name` is an automatic backup's file name (also the longer names earlier test builds gave them).
    public static func isAutomatic(_ name: String) -> Bool { name.hasPrefix(prefix) && name.hasSuffix(fileExtension) }
    /// The newest `limit` automatic backups among `names` (a folder's files), newest first: by the time in the name, then by the number
    /// a second backup within the same second ends with (so _10 comes after _9).
    public static func newest(_ names: [String], limit: Int = recent) -> [String] {
        Array(Set(names.filter(isAutomatic)).sorted { a, b in
            let x = age(a), y = age(b)
            return x.time != y.time ? x.time > y.time : x.count != y.count ? x.count > y.count : a > b
        }.prefix(limit))
    }
    /// The time written in an automatic backup's name and its number within that second: 1 for none, N for "_N", N+1 for " (N)" (a
    /// copy a folder's app renamed). Longer names from earlier test builds count as 1.
    private static func age(_ name: String) -> (time: Substring, count: Int) {
        let rest = name.dropFirst(prefix.count).dropLast(fileExtension.count)
        let time = rest.prefix(19), tail = rest.dropFirst(time.count)
        if tail.hasPrefix("_"), let number = Int(tail.dropFirst()), number > 0 { return (time, number) }
        if tail.hasPrefix(" ("), tail.hasSuffix(")"), let number = Int(tail.dropFirst(2).dropLast()), number >= 0 { return (time, number + 1) }
        return (time, 1)
    }
    /// The newest automatic backups in `folder` (whose security-scoped access the caller holds). Throws when it cannot be read.
    public static func newest(in folder: URL, limit: Int = recent) throws -> [String] {
        var coordination: NSError?, result: Result<[String], Error> = .success([])
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordination) { url in
            result = Result { try FileManager.default.contentsOfDirectory(atPath: url.path) }
        }
        if let coordination { throw coordination }
        return newest(try result.get().map(downloadedName), limit: limit)
    }
    /// iCloud Drive can list a file that is not downloaded yet as a hidden placeholder, ".name.icloud": the backup's own name.
    static func downloadedName(_ name: String) -> String {
        name.hasPrefix(".") && name.hasSuffix(".icloud") && name.count > 8 ? String(name.dropFirst().dropLast(7)) : name
    }
    /// Writes `data` as a new file in `folder` (coordinated, so a cloud folder's app sees a whole file). Returns the new file's name.
    /// The caller holds the folder's security-scoped access and writes one backup at a time (`save`).
    @discardableResult public static func write(_ data: Data, to folder: URL, at date: Date = Date()) throws -> String {
        let name = try uniqueName(at: date) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let file = folder.appendingPathComponent(name)
        var coordination: NSError?, failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordination) { url in
            do {
                // Never replaces a file: one made between the check above and here fails this backup instead.
                #if os(iOS)
                try data.write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: url, options: .withoutOverwriting)
                #endif
            } catch {
                // A partial file must not look like a complete backup (as on Android). A file that already existed is not ours to delete.
                failure = error
                if (error as? CocoaError)?.code != .fileWriteFileExists { try? FileManager.default.removeItem(at: url) }
            }
        }
        if let error = coordination ?? failure { throw error }
        return name
    }
}

extension AutoBackupFiles {
    private static let lock = NSLock()
    /// Writes one automatic backup to `folder` (whose security-scoped access the caller holds) and records it: the settings' digest and
    /// time, and the source vault's backup history. One at a time; a second request for the same records is skipped, unless `force`.
    /// Returns false, with the settings' problem set, when the file could not be written.
    @discardableResult public static func save(_ export: VaultExport, digest: Data, to folder: URL?, settings: AutoBackupSettings, defaults: UserDefaults,
                                               force: Bool, at date: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !force, settings.lastDigest == digest { return true }
        // Recheck inside the writer lock: a preceding queued backup may have just reset the interval.
        if !force && settings.remaining(now: date) > 0 { return true }
        guard settings.enabled else { return true }
        guard let folder else { settings.failed(.noAccess); return false }
        do {
            try write(export.data, to: folder, at: date)
            settings.succeeded(digest: digest, at: date)
            export.recordBackup(defaults: defaults, savedAt: date)
            return true
        } catch {
            settings.failed(FileManager.default.fileExists(atPath: folder.path) ? .writeFailed : .noAccess)
            return false
        }
    }
}
