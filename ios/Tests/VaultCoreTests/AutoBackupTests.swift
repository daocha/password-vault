import Foundation
import XCTest
@testable import VaultCore

final class AutoBackupTests: XCTestCase {
    private let password = "A lengthy test passphrase 1!"
    private let decoyPassword = "A separate decoy passphrase 2!"
    private func ready(_ result: AutomaticBackup, file: StaticString = #filePath, line: UInt = #line) throws -> (VaultExport, Data) {
        guard case .ready(let export, let digest) = result else { XCTFail("expected a backup, got \(result)", file: file, line: line); throw VaultError.invalid("no backup") }
        return (export, digest)
    }
    private func named(_ name: String) -> VaultRecord { var record = VaultRecord(); record.name = name; return record }

    func testFrequencyDefaultsPersistenceAndIntervalBoundaries() throws {
        let suite = "PassVault.frequency.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AutoBackupSettings(defaults: defaults), decoy = AutoBackupSettings(defaults: defaults, decoy: true)
        XCTAssertEqual(settings.frequency, .instant)
        settings.frequency = .weekly
        XCTAssertEqual(AutoBackupSettings(defaults: defaults).frequency, .weekly)
        XCTAssertEqual(decoy.frequency, .instant)
        settings.turnOn(folderBookmark: Data([1]), name: "Backups", sealedKey: Data([2]))
        XCTAssertEqual(settings.frequency, .weekly)
        settings.clear()
        XCTAssertEqual(settings.frequency, .instant)
        defaults.set("invalid", forKey: "autoBackupFrequency")
        XCTAssertEqual(settings.frequency, .instant)
        let last = Date(timeIntervalSince1970: 1_795_084_265)
        for frequency in AutoBackupFrequency.allCases {
            XCTAssertEqual(frequency.remaining(since: nil, now: last), 0)
            if frequency == .instant {
                XCTAssertEqual(frequency.remaining(since: last, now: last.addingTimeInterval(-60)), 0)
                continue
            }
            XCTAssertEqual(frequency.remaining(since: last, now: last), frequency.seconds)
            XCTAssertEqual(frequency.remaining(since: last, now: last.addingTimeInterval(frequency.seconds - 1)), 1)
            XCTAssertEqual(frequency.remaining(since: last, now: last.addingTimeInterval(frequency.seconds)), 0)
            XCTAssertEqual(frequency.remaining(since: last, now: last.addingTimeInterval(frequency.seconds + 1)), 0)
            XCTAssertEqual(frequency.remaining(since: last, now: last.addingTimeInterval(-60)), frequency.seconds + 60)
        }
        settings.succeeded(digest: Data([1]), at: last)
        settings.failed(.writeFailed)
        XCTAssertEqual(settings.lastAutomatic, last)
    }

    func testRapidBackupsKeepEveryVersionEvenWithinOneSecond() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let at = Date()
        for step in 0..<20 { try AutoBackupFiles.write(Data([UInt8(step)]), to: folder, at: at) }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 20)
        let bytes = try files.map { try Data(contentsOf: folder.appendingPathComponent($0)).first! }
        XCTAssertEqual(Set(bytes), Set((0..<20).map { UInt8($0) }))
    }

    func testNamesMatchAndroidAndSortByAge() {
        let at = Date(timeIntervalSince1970: 1_795_084_265) // 2026-11-19 10:31:05 UTC
        XCTAssertEqual(AutoBackupFiles.name(at: at, timeZone: TimeZone(identifier: "UTC")!), "passvault_auto_2026-11-19_10_31_05.pvault")
        let names = (1...8).map { AutoBackupFiles.name(at: at.addingTimeInterval(Double($0) * 3600), timeZone: TimeZone(identifier: "UTC")!) }
        XCTAssertEqual(names.shuffled().sorted(), names)
    }

    /// The "changed since the last backup" digest must not depend on dictionary order: JSONEncoder writes `legacy` in whatever order the
    /// dictionary has, which made identical records look changed (a new backup on every lock).
    func testTheDigestOfTheSameRecordsNeverChanges() throws {
        var record = VaultRecord(); record.name = "Bank"
        record.legacy = Dictionary(uniqueKeysWithValues: (0..<40).map { ("key\($0)", "value\($0)") })
        let key = Data(repeating: 7, count: VaultCrypto.backupKeySize)
        let first = try VaultCrypto.backupDigest([record], backupKey: key)
        for _ in 0..<50 {
            var copy = record
            copy.legacy = Dictionary(uniqueKeysWithValues: record.legacy.shuffled().map { ($0.key, $0.value) })
            XCTAssertEqual(try VaultCrypto.backupDigest([copy], backupKey: key), first)
            XCTAssertEqual(try Records.canonical([copy]), try Records.canonical([record]))
        }
        record.legacy["key0"] = "changed"
        XCTAssertNotEqual(try VaultCrypto.backupDigest([record], backupKey: key), first)
    }

    func testBackupsNeedNoPasswordAfterSetUpAndOpenWithTheAppPassword() throws {
        let engine = VaultEngine(storage: MemoryStorage())
        _ = try engine.create(password: password); try engine.save([named("Bank")])
        XCTAssertThrowsError(try engine.sealAutoBackupKey(password: "wrong password"))
        XCTAssertEqual(try engine.remainingAttempts(), 9, "setting up is a counted attempt")
        XCTAssertTrue(engine.isUnlocked(), "a wrong password leaves the vault open, as on Android")
        let sealed = try engine.sealAutoBackupKey(password: password)
        XCTAssertEqual(try engine.remainingAttempts(), 10)
        let (first, digest) = try ready(engine.exportAutomatic(sealedKey: sealed, lastDigest: nil))
        XCTAssertFalse(first.csv); XCTAssertFalse(first.decoy)
        XCTAssertEqual(try VaultCrypto.importBackup(first.data, password: password).map(\.name), ["Bank"])
        XCTAssertThrowsError(try VaultCrypto.importBackup(first.data, password: "wrong password"))
        guard case .unchanged = try engine.exportAutomatic(sealedKey: sealed, lastDigest: digest) else { return XCTFail("nothing changed") }
        let (forced, sameDigest) = try ready(engine.exportAutomatic(sealedKey: sealed, lastDigest: digest, force: true))
        XCTAssertNotEqual(forced.data, first.data, "each file has its own nonce")
        XCTAssertEqual(sameDigest, digest)
        try engine.save([named("Bank"), named("Mail")])
        let (second, changed) = try ready(engine.exportAutomatic(sealedKey: sealed, lastDigest: digest))
        XCTAssertNotEqual(changed, digest)
        XCTAssertEqual(try VaultCrypto.importBackup(second.data, password: password).map(\.name).sorted(), ["Bank", "Mail"])
        engine.lock()
        XCTAssertThrowsError(try engine.exportAutomatic(sealedKey: sealed, lastDigest: nil))
    }

    func testANewPasswordOrAnotherVaultCannotUseTheKey() throws {
        let engine = VaultEngine(storage: MemoryStorage())
        _ = try engine.create(password: password); try engine.save([named("Bank")])
        let sealed = try engine.sealAutoBackupKey(password: password)
        try engine.createDecoy(password: password, decoyPassword: decoyPassword)
        engine.lock(); _ = try engine.unlock(password: decoyPassword); try engine.save([named("Shopping")])
        guard case .keyGone = try engine.exportAutomatic(sealedKey: sealed, lastDigest: nil) else { return XCTFail("the decoy cannot use the real vault's key") }
        let decoySealed = try engine.sealAutoBackupKey(password: decoyPassword)
        let (decoy, _) = try ready(engine.exportAutomatic(sealedKey: decoySealed, lastDigest: nil))
        XCTAssertTrue(decoy.decoy)
        XCTAssertEqual(try VaultCrypto.importBackup(decoy.data, password: decoyPassword).map(\.name), ["Shopping"])
        engine.lock(); _ = try engine.unlock(password: password)
        guard case .keyGone = try engine.exportAutomatic(sealedKey: decoySealed, lastDigest: nil) else { return XCTFail("the real vault cannot use the decoy's key") }
        let next = "Another lengthy passphrase 3!"
        try engine.changePassword(current: password, new: next)
        guard case .keyGone = try engine.exportAutomatic(sealedKey: sealed, lastDigest: nil) else { return XCTFail("a new password needs a new key") }
        let (renewed, _) = try ready(engine.exportAutomatic(sealedKey: try engine.sealAutoBackupKey(password: next), lastDigest: nil))
        XCTAssertEqual(try VaultCrypto.importBackup(renewed.data, password: next).map(\.name), ["Bank"])
    }

    func testEachBackupIsANewFileNoneIsDeletedAndItCountsForTheReminder() throws {
        let suite = "PassVault.auto-backup-tests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([9]).write(to: folder.appendingPathComponent("holiday.jpg"))
        let settings = AutoBackupSettings(defaults: defaults), decoySettings = AutoBackupSettings(defaults: defaults, decoy: true)
        settings.turnOn(folderBookmark: Data([1]), name: "Backups", sealedKey: Data([2]))
        XCTAssertTrue(settings.enabled); XCTAssertFalse(decoySettings.enabled)
        let engine = VaultEngine(storage: MemoryStorage())
        _ = try engine.create(password: password); try engine.save([named("Bank")])
        let sealed = try engine.sealAutoBackupKey(password: password)
        let start = Date(timeIntervalSince1970: 1_795_084_265)
        var digest = Data()
        for step in 0..<7 {
            try engine.save((0...step).map { named("Entry \($0)") })
            let (export, next) = try ready(engine.exportAutomatic(sealedKey: sealed, lastDigest: settings.lastDigest))
            XCTAssertTrue(AutoBackupFiles.save(export, digest: next, to: folder, settings: settings, defaults: defaults, force: false, at: start.addingTimeInterval(Double(step) * 60)))
            digest = next
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files.count, 8, "every backup stays, with the user's own file")
        XCTAssertTrue(files.contains("holiday.jpg"))
        XCTAssertEqual(settings.lastDigest, digest); XCTAssertEqual(settings.lastAutomatic, start.addingTimeInterval(360))
        XCTAssertEqual(BackupStatus(defaults: defaults).lastBackup, start.addingTimeInterval(360), "an automatic backup counts for the reminder")
        let newest = try XCTUnwrap(files.filter { $0.hasPrefix("passvault_auto_") }.max())
        XCTAssertEqual(try VaultCrypto.importBackup(Data(contentsOf: folder.appendingPathComponent(newest)), password: password).count, 7)
        // The same records again are skipped; a missing folder pauses with a reason, and a success clears it.
        let (again, same) = try ready(engine.exportAutomatic(sealedKey: sealed, lastDigest: nil))
        XCTAssertTrue(AutoBackupFiles.save(again, digest: same, to: folder, settings: settings, defaults: defaults, force: false))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 8, "unchanged records are not saved again")
        XCTAssertFalse(AutoBackupFiles.save(again, digest: same, to: nil, settings: settings, defaults: defaults, force: true))
        XCTAssertEqual(settings.problem, .noAccess)
        XCTAssertFalse(AutoBackupFiles.save(again, digest: same, to: folder.appendingPathComponent("gone"), settings: settings, defaults: defaults, force: true))
        XCTAssertEqual(settings.problem, .noAccess)
        XCTAssertTrue(AutoBackupFiles.save(again, digest: same, to: folder, settings: settings, defaults: defaults, force: true, at: start.addingTimeInterval(600)))
        XCTAssertNil(settings.problem)
        settings.clear()
        XCTAssertFalse(settings.enabled); XCTAssertNil(settings.lastDigest); XCTAssertNil(settings.lastAutomatic)
    }

    func testTheAppBacksUpBeforeLockingAndOnLeavingAndIsTranslated() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PassVault")
        let source = try String(contentsOf: app.appendingPathComponent("PassVaultApp.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("    func lock() {\n        autoBackup()\n"), "locking saves changes first")
        XCTAssertTrue(source.contains("        autoBackup()\n        switch AppSettings.shared.autoLock.delay {"), "leaving the app saves changes")
        XCTAssertTrue(source.contains("model.autoBackups.failed(.keyGone)"), "a password change pauses automatic backups")
        XCTAssertTrue(source.contains("panel = .autoBackup\n        model.autoBackup(force: true, announce: true)"), "choosing the folder shows the panel with Back up now")
        let english = try String(contentsOf: app.appendingPathComponent("en.lproj/Localizable.strings"), encoding: .utf8)
        let keys = ["Frequency", "Instant", "Daily", "Weekly", "Monthly", "Automatic backup", "On · %@", "Choose a folder", "Back up now", "Choose another folder", "Saved to %@ at %@.", "Backup saved", "Backup not saved",
                    "No automatic backup saved yet.", "Paused: your app password changed. Choose the folder again to resume.", "Paused: PassVault can no longer open %@. Choose the folder again.",
                    "The last automatic backup could not be saved. PassVault tries again next time.", "Saving to the folder %@. Each backup is a new file; older ones stay until you delete them."]
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let data = try Data(contentsOf: app.appendingPathComponent("\(language).lproj/Localizable.strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for key in keys { XCTAssertNotNil(table[key], "\(language) lacks \(key)") }
        }
        XCTAssertTrue(english.contains("\"Automatic backup\""))
        XCTAssertFalse(english.contains("newest 5"), "nothing is deleted any more")
        XCTAssertTrue(source.contains("self.autoBackupNotice = AutoBackupNotice(saved: saved"), "Back up now is confirmed in an alert")
    }
}
