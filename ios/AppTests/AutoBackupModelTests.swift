import XCTest
import UIKit
import VaultCore
@testable import PassVault

/// Automatic backup through the app model: locking saves changes to the bookmarked folder without a password.
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
        model.autoBackup(force: true, announce: true)
        try await waitUntil { model.autoBackupNotice != nil }
        XCTAssertEqual(model.autoBackupNotice?.saved, true)
        XCTAssertTrue(model.autoBackupNotice?.text.contains("Backups") == true)
        XCTAssertEqual(files(), 1)
        model.autoBackupNotice = nil
        try await Task.sleep(for: .milliseconds(1100)) // a new second, so a new name
        model.autoBackup(force: true, announce: true)
        try await waitUntil { model.autoBackupNotice != nil }
        XCTAssertEqual(model.autoBackupNotice?.saved, true)
        XCTAssertEqual(files(), 2, "every backup stays")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
