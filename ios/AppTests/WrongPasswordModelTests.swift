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
        XCTAssertEqual(model.status.text, localizedFormat("Incorrect password. %lld attempts left before this vault is erased.", 9), "says how many attempts are left, as on Android")
        // A failed unlock still shows the lock screen.
        model.lock()
        model.run { try $0.unlock(password: "wrong password") }
        try await waitUntil { !model.busy }
        XCTAssertFalse(model.unlocked)
    }

    /// The wrong-password message follows the app's language (it was always English).
    func testTheWrongPasswordMessageIsTranslated() {
        let settings = AppSettings.shared, before = settings.language
        defer { settings.language = before }
        let cases: [(AppLanguage, String)] = [(.english, "Incorrect password. 9 attempts left before this vault is erased."),
                                              (.simplifiedChinese, "密码错误。此保险库被清除前还剩 9 次尝试机会。"),
                                              (.traditionalChinese, "密碼錯誤。此保險庫被清除前還剩 9 次嘗試機會。")]
        for (language, expected) in cases {
            settings.language = language
            XCTAssertEqual(VaultModel.failureMessage(VaultError.authentication, attempts: 9, erased: false), expected)
        }
        settings.language = .simplifiedChinese
        XCTAssertEqual(VaultModel.failureMessage(VaultError.erased, attempts: 0, erased: true), "本地保险库因密码连续输错 10 次已被清除。请创建新保险库并恢复加密备份。")
        XCTAssertEqual(localizedError(VaultError.locked), "你的保险库已锁定。")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
