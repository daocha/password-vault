import Foundation
import XCTest
@testable import VaultCore

/// A wrong app password in an open vault (export, transfer, password change) is counted but leaves the vault open, as on Android.
final class WrongPasswordTests: XCTestCase {
    private let password = "A lengthy test passphrase 1!"

    func testAWrongPasswordInAnOpenVaultIsCountedButKeepsItOpen() throws {
        let engine = VaultEngine(storage: MemoryStorage())
        _ = try engine.create(password: password)
        var record = VaultRecord(); record.name = "Bank"
        try engine.save([record])
        XCTAssertThrowsError(try engine.prepareExport(password: "wrong password", csv: false))
        XCTAssertTrue(engine.isUnlocked(), "the vault stays open")
        XCTAssertEqual(try engine.remainingAttempts(), 9, "the attempt is counted")
        XCTAssertThrowsError(try engine.exportTransfer(password: "wrong password"))
        XCTAssertEqual(try engine.remainingAttempts(), 8)
        let export = try engine.prepareExport(password: password, csv: false)
        XCTAssertEqual(try VaultCrypto.importBackup(export.data, password: password), [record])
        XCTAssertEqual(try engine.remainingAttempts(), 10, "the right password resets the count")
    }

    func testTheTenthWrongPasswordStillErasesAndCloses() throws {
        let engine = VaultEngine(storage: MemoryStorage())
        _ = try engine.create(password: password)
        for _ in 1...9 { XCTAssertThrowsError(try engine.prepareExport(password: "wrong password", csv: false)) }
        XCTAssertTrue(engine.isUnlocked())
        XCTAssertThrowsError(try engine.prepareExport(password: "wrong password", csv: false)) { guard case VaultError.erased? = $0 as? VaultError else { return XCTFail("expected erasure, got \($0)") } }
        XCTAssertFalse(engine.isUnlocked())
        XCTAssertTrue(try engine.isErased())
    }

    func testAFailedUnlockStaysLocked() throws {
        let engine = VaultEngine(storage: MemoryStorage())
        _ = try engine.create(password: password)
        engine.lock()
        XCTAssertThrowsError(try engine.unlock(password: "wrong password"))
        XCTAssertFalse(engine.isUnlocked())
    }

    func testTheAppKeepsTheVaultOpenAndShowsMessagesInsideSettings() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PassVault")
        let source = try String(contentsOf: app.appendingPathComponent("PassVaultApp.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("model.lock(); model.attempts"), "a failed check no longer locks the app")
        XCTAssertTrue(source.contains("let closed = !unlocked || !(engine?.isUnlocked() ?? false)"))
        // Settings and its panels are sheets over the vault list, whose message bar they hide.
        XCTAssertEqual(source.components(separatedBy: ".statusBar(model)").count - 1, 2, "Settings and its panels show messages")
        // Save and Send are buttons in the panel; the confirmation dialog over the sheet showed no buttons.
        XCTAssertFalse(source.contains(".confirmationDialog(\"Save or send this backup?\""))
        XCTAssertTrue(source.contains("Button(\"Save to Files\", systemImage: \"folder\")") && source.contains("Button(\"Send to a nearby device\", systemImage: \"square.and.arrow.up\")"))
    }
}
