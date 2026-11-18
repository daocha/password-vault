import XCTest
import UIKit
import VaultCore
@testable import PassVault

/// Automatic backups through the app model: saved changes, intervals, locking and explicit backups.
@MainActor final class AutoBackupModelTests: XCTestCase {
    private let password = "A lengthy test passphrase 1!"

    func testLockingSavesChangesToTheChosenFolderOnce() async throws {
        let suite = "PassVault.auto-backup-model.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = VaultEngine(storage: ModelTestStorage())
        _ = try engine.create(password: password)
        var record = VaultRecord(); record.name = "Bank"
        try engine.save([record])
        let sealed = try engine.sealAutoBackupKey(password: password)
        engine.lock()
        AutoBackupSettings(defaults: defaults).turnOn(folderBookmark: try folder.bookmarkData(), name: "Backups", sealedKey: sealed)

        let model = VaultModel(engine: engine, defaults: defaults)
        let pass = password
        model.run { try $0.unlock(password: pass) }
        try await waitUntil { !model.busy }
        XCTAssertTrue(model.unlocked)
        model.lock()
        func backups() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("passvault_auto_") } }
        try await waitUntil { backups().count == 1 && AutoBackupSettings(defaults: defaults).lastAutomatic != nil }
        let saved = try Data(contentsOf: folder.appendingPathComponent(try XCTUnwrap(backups().first)))
        XCTAssertEqual(try VaultCrypto.importBackup(saved, password: password).map(\.name), ["Bank"])
        XCTAssertNotNil(BackupStatus(defaults: defaults).lastBackup, "it counts for the backup reminder")

        // Nothing changed: unlocking and locking again writes nothing new.
        model.run { try $0.unlock(password: pass) }
        try await waitUntil { !model.busy }
        model.lock()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(backups().count, 1)
    }

    /// Back up now: a new file even when nothing changed, confirmed in an alert (the message bar was hidden behind Settings).
    func testBackUpNowSavesANewFileAndConfirmsIt() async throws {
        let suite = "PassVault.auto-backup-now.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = VaultEngine(storage: ModelTestStorage())
        _ = try engine.create(password: password)
        let sealed = try engine.sealAutoBackupKey(password: password)
        engine.lock()
        AutoBackupSettings(defaults: defaults).turnOn(folderBookmark: try folder.bookmarkData(), name: "Backups", sealedKey: sealed)
        let model = VaultModel(engine: engine, defaults: defaults)
        let pass = password
        model.run { try $0.unlock(password: pass) }
        try await waitUntil { !model.busy }
        func files() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count }
        try await waitUntil { files() == 1 && AutoBackupSettings(defaults: defaults).lastAutomatic != nil }
        model.autoBackup(force: true, announce: true)
        try await waitUntil { model.autoBackupNotice != nil }
        XCTAssertEqual(model.autoBackupNotice?.saved, true)
        XCTAssertTrue(model.autoBackupNotice?.text.contains("Backups") == true)
        XCTAssertEqual(files(), 2)
        model.autoBackupNotice = nil
        model.autoBackup(force: true, announce: true)
        try await waitUntil { model.autoBackupNotice != nil }
        XCTAssertEqual(model.autoBackupNotice?.saved, true)
        XCTAssertEqual(files(), 3, "every backup stays, even within one second")
    }

    func testInstantSavesAfterChangesAndDailyDefersUntilTheIntervalExpires() async throws {
        let suite = "PassVault.auto-backup-frequency-model.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = VaultEngine(storage: ModelTestStorage())
        _ = try engine.create(password: password)
        let sealed = try engine.sealAutoBackupKey(password: password)
        engine.lock()
        let settings = AutoBackupSettings(defaults: defaults)
        settings.turnOn(folderBookmark: try folder.bookmarkData(), name: "Backups", sealedKey: sealed)
        let model = VaultModel(engine: engine, defaults: defaults)
        let pass = password
        model.run { try $0.unlock(password: pass) }
        func files() -> [URL] { (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] }
        try await waitUntil { files().count == 1 && settings.lastAutomatic != nil && !model.busy }
        XCTAssertEqual(settings.frequency, .instant)

        var record = VaultRecord(); record.name = "Bank"
        let first = record
        let initialDigest = settings.lastDigest
        model.run { try $0.save([first]); return [first] }
        try await waitUntil { files().count == 2 && !model.busy && settings.lastDigest != initialDigest }
        XCTAssertTrue(model.unlocked, "instant backs up without locking or leaving")
        model.setAutoBackupFrequency(.daily)
        record.name = "Updated Bank"
        let updated = record
        let last = try XCTUnwrap(settings.lastAutomatic)
        model.run { try $0.save([updated]); return [updated] }
        try await waitUntil { !model.busy }
        XCTAssertEqual(files().count, 2, "daily defers changes until the interval")
        XCTAssertEqual(settings.lastAutomatic, last)

        // Make the real daily boundary arrive shortly, then verify the timer saves without another edit or lock.
        settings.succeeded(digest: try XCTUnwrap(settings.lastDigest), at: Date().addingTimeInterval(-86400 + 0.3))
        model.setAutoBackupFrequency(.daily)
        try await waitUntil { files().count == 3 && settings.lastAutomatic.map { $0 > last } == true }
        let contents = try files().map { try VaultCrypto.importBackup(Data(contentsOf: $0), password: password).map(\.name) }
        XCTAssertTrue(contents.contains(["Updated Bank"]))
        model.autoBackup(force: true, announce: true)
        try await waitUntil { model.autoBackupNotice != nil }
        XCTAssertEqual(model.autoBackupNotice?.saved, true)
        XCTAssertEqual(files().count, 4, "Back up now bypasses daily even without changes")
        model.lock()
    }

    /// Settings → Last encrypted backup with automatic backup on: the five newest backups in its folder, newest first; an error when the
    /// folder cannot be opened.
    func testLastBackupListsTheNewestBackupsInTheFolder() async throws {
        let suite = "PassVault.auto-backup-recent.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = VaultEngine(storage: ModelTestStorage())
        _ = try engine.create(password: password)
        let sealed = try engine.sealAutoBackupKey(password: password)
        engine.lock()
        let model = VaultModel(engine: engine, defaults: defaults)
        let pass = password
        model.run { try $0.unlock(password: pass) }
        try await waitUntil { !model.busy }
        model.showRecentBackups()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(model.recentBackups, "automatic backup off: nothing to list (Settings opens the export instead)")

        AutoBackupSettings(defaults: defaults).turnOn(folderBookmark: try folder.bookmarkData(), name: "Backups", sealedKey: sealed)
        try Data([9]).write(to: folder.appendingPathComponent("holiday.jpg"))
        let start = Date(timeIntervalSince1970: 1_795_084_265)
        let written = try (0..<7).map { try AutoBackupFiles.write(Data([UInt8($0)]), to: folder, at: start.addingTimeInterval(Double($0) * 60)) }
        var shown = false
        model.showRecentBackups { shown = true }
        try await waitUntil { shown }
        XCTAssertEqual(model.recentBackups?.folder, "Backups")
        XCTAssertEqual(model.recentBackups?.names, Array(written.reversed().prefix(5)))
        model.recentBackups = nil

        // The folder is gone (or access was lost): an error, not a list.
        try FileManager.default.removeItem(at: folder)
        shown = false
        model.showRecentBackups { shown = true }
        try await waitUntil { shown }
        XCTAssertNil(model.recentBackups)
        XCTAssertTrue(model.status.isError)
        XCTAssertEqual(model.status.text, localizedFormat("PassVault cannot open the folder %@. Choose it again in Automatic backup.", "Backups"))
        model.lock()
        XCTAssertNil(model.recentBackups)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
