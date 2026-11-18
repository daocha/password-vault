import Foundation
import VaultCore

/// Automatic backups (see AutoBackupTests): no password after set-up, ordinary backup files, keys that expire, every backup kept.
func autoBackupChecks() throws {
    let boundary = Date(timeIntervalSince1970: 1_795_084_265)
    for frequency in AutoBackupFrequency.allCases {
        try check(frequency.remaining(since: nil, now: boundary) == 0, "no earlier backup is always due")
        if frequency == .instant {
            try check(frequency.remaining(since: boundary, now: boundary.addingTimeInterval(-60)) == 0, "instant is due even after the clock moves back")
        } else {
            try check(frequency.remaining(since: boundary, now: boundary) == frequency.seconds, "frequency uses the last successful backup")
            try check(frequency.remaining(since: boundary, now: boundary.addingTimeInterval(frequency.seconds - 1)) == 1, "not due before its boundary")
            try check(frequency.remaining(since: boundary, now: boundary.addingTimeInterval(frequency.seconds)) == 0, "due at its boundary")
            try check(frequency.remaining(since: boundary, now: boundary.addingTimeInterval(frequency.seconds + 1)) == 0, "overdue is due")
            try check(frequency.remaining(since: boundary, now: boundary.addingTimeInterval(-60)) == frequency.seconds + 60, "future timestamps do not back up early")
        }
    }
    let password = "A lengthy test passphrase 1!", engine = VaultEngine(storage: MemoryStorage())
    var record = VaultRecord(); record.name = "Bank"
    _ = try engine.create(password: password); try engine.save([record])
    try rejects("automatic backup set-up checks the password") { _ = try engine.sealAutoBackupKey(password: "wrong password") }
    try check(try engine.remainingAttempts() == 9 && engine.isUnlocked(), "automatic backup set-up is a counted attempt and keeps the vault open")
    let sealed = try engine.sealAutoBackupKey(password: password)
    guard case .ready(let export, let digest) = try engine.exportAutomatic(sealedKey: sealed, lastDigest: nil) else { throw VaultError.invalid("FAILED: automatic backup") }
    try check(try VaultCrypto.importBackup(export.data, password: password) == [record], "automatic backups open with the app password")
    guard case .unchanged = try engine.exportAutomatic(sealedKey: sealed, lastDigest: digest) else { throw VaultError.invalid("FAILED: unchanged records are not backed up again") }
    checks += 1
    try engine.changePassword(current: password, new: "Another lengthy passphrase 3!")
    guard case .keyGone = try engine.exportAutomatic(sealedKey: sealed, lastDigest: nil) else { throw VaultError.invalid("FAILED: a new password needs automatic backup set up again") }
    checks += 1
    engine.lock()
    try rejects("a locked vault makes no automatic backup") { _ = try engine.exportAutomatic(sealedKey: sealed, lastDigest: nil) }

    try check(AutoBackupFiles.name(at: Date(timeIntervalSince1970: 1_795_084_265), timeZone: TimeZone(identifier: "UTC")!) == "passvault_auto_2026-11-19_10_31_05.pvault", "automatic backup names match Android")
    var withLegacy = record; withLegacy.legacy = Dictionary(uniqueKeysWithValues: (0..<40).map { ("key\($0)", "value\($0)") })
    let digestKey = Data(repeating: 7, count: VaultCrypto.backupKeySize), digest0 = try VaultCrypto.backupDigest([withLegacy], backupKey: digestKey)
    for _ in 0..<20 {
        var copy = withLegacy; copy.legacy = Dictionary(uniqueKeysWithValues: withLegacy.legacy.shuffled().map { ($0.key, $0.value) })
        try check(try VaultCrypto.backupDigest([copy], backupKey: digestKey) == digest0, "the same records always give the same digest")
    }

    let suite = "PassVault.auto-backup-checks.\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let settings = AutoBackupSettings(defaults: defaults)
    try check(settings.frequency == .instant, "automatic backup defaults to instant")
    settings.frequency = .weekly
    try check(AutoBackupSettings(defaults: defaults).frequency == .weekly && AutoBackupSettings(defaults: defaults, decoy: true).frequency == .instant, "frequency persists per vault")
    settings.frequency = .instant
    settings.turnOn(folderBookmark: Data([1]), name: "Backups", sealedKey: sealed)
    for step in 0..<7 { try check(AutoBackupFiles.save(export, digest: Data([UInt8(step)]), to: folder, settings: settings, defaults: defaults, force: false, at: Date(timeIntervalSince1970: 1_795_084_265 + Double(step))), "automatic backup saved") }
    try check(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 7, "every automatic backup is kept")
    try check(BackupStatus(defaults: defaults).lastBackup != nil, "an automatic backup counts for the reminder")
    try check(!AutoBackupFiles.save(export, digest: Data([9]), to: nil, settings: settings, defaults: defaults, force: true) && settings.problem == .noAccess, "an unreachable folder pauses automatic backup")
    // Rapid writes use the exact same time, so this fails if filenames can collide.
    for step in 0..<3 { try AutoBackupFiles.write(Data([UInt8(step)]), to: folder, at: boundary) }
    try check(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 10, "multiple backups in the same second are all kept")
    let stem = AutoBackupFiles.name(at: boundary).dropLast(".pvault".count)
    // The first save above was at `boundary` too, so the three rapid ones end _2, _3 and _4.
    try check(try AutoBackupFiles.newest(in: folder, limit: 20).filter { $0.hasPrefix(String(stem)) } == ["\(stem)_4.pvault", "\(stem)_3.pvault", "\(stem)_2.pvault", "\(stem).pvault"],
              "backup names hold only the time, newest listed first")
    try check(AutoBackupFiles.newest(["a.txt"] + (0..<9).map { "passvault_auto_2026-11-1\($0)_00_00_00.pvault" }) == (4..<9).reversed().map { "passvault_auto_2026-11-1\($0)_00_00_00.pvault" }, "Settings lists the five newest backups")
    try rejects("an unreadable backup folder is an error") { _ = try AutoBackupFiles.newest(in: folder.appendingPathComponent("gone")) }
    let last = settings.lastAutomatic!
    settings.frequency = .daily
    try check(AutoBackupFiles.save(export, digest: Data([90]), to: folder, settings: settings, defaults: defaults, force: false, at: last.addingTimeInterval(86399)), "queued backup before the interval is skipped")
    try check(settings.lastAutomatic == last, "a skipped or failed backup does not move the interval")
    try check(AutoBackupFiles.save(export, digest: Data([91]), to: folder, settings: settings, defaults: defaults, force: false, at: last.addingTimeInterval(86400)), "queued backup at the boundary saves")
    try check(settings.lastAutomatic == last.addingTimeInterval(86400), "a success moves the interval")
    try check(AutoBackupFiles.save(export, digest: Data([92]), to: folder, settings: settings, defaults: defaults, force: true, at: last.addingTimeInterval(86401)), "Back up now bypasses the interval")
    try check(settings.lastAutomatic == last.addingTimeInterval(86401), "Back up now resets the interval")
    settings.clear()
    try check(settings.frequency == .instant, "turning off clears the frequency")
    try check(!settings.enabled && settings.sealedKey == nil, "turning automatic backup off forgets the key")
}
