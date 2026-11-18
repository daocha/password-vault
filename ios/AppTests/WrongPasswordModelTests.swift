import XCTest
import VaultCore
@testable import PassVault

/// As on Android: a wrong app password in Settings shows the error and keeps the vault open; the attempt is counted.
@MainActor final class WrongPasswordModelTests: XCTestCase {
    private let password = "A lengthy test passphrase 1!"

    func testAWrongExportPasswordShowsTheErrorAndKeepsTheVaultOpen() async throws {
        let suite = "PassVault.wrong-password.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = VaultEngine(storage: ModelTestStorage())
        _ = try engine.create(password: password); engine.lock()
        let model = VaultModel(engine: engine, defaults: defaults)
        let pass = password
        model.run { try $0.unlock(password: pass) }
        try await waitUntil { !model.busy }
        XCTAssertTrue(model.unlocked)
        model.run { _ = try $0.prepareExport(password: "wrong password", csv: false); return nil }
        try await waitUntil { !model.busy }
        XCTAssertTrue(model.unlocked, "the vault stays open")
        XCTAssertTrue(engine.isUnlocked())
        XCTAssertTrue(model.status.isShowing && model.status.isError)
        XCTAssertEqual(model.attempts, 9, "the attempt is counted")
        // A failed unlock still shows the lock screen.
        model.lock()
        model.run { try $0.unlock(password: "wrong password") }
        try await waitUntil { !model.busy }
        XCTAssertFalse(model.unlocked)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
