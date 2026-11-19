import Foundation
import VaultCore

/// A wrong app password in an open vault is counted but leaves it open, as on Android; the tenth still erases (see WrongPasswordTests).
func wrongPasswordChecks() throws {
    let password = "A lengthy test passphrase 1!", engine = VaultEngine(storage: MemoryStorage())
    _ = try engine.create(password: password)
    try rejects("wrong export password") { _ = try engine.prepareExport(password: "wrong password", csv: false) }
    try check(engine.isUnlocked() && (try engine.remainingAttempts()) == 9, "a wrong export password is counted and keeps the vault open")
    for _ in 1...8 { try rejects("wrong export password") { _ = try engine.prepareExport(password: "wrong password", csv: false) } }
    try rejects("tenth wrong export password") { _ = try engine.prepareExport(password: "wrong password", csv: false) }
    try check(!engine.isUnlocked() && (try engine.isErased()), "the tenth wrong password erases and closes the vault")

    // Closing the Face ID / Touch ID prompt is not a failed attempt, and reaches the app and AutoFill as `cancelled`, which they do not show.
    let storage = MemoryStorage(), biometric = VaultEngine(storage: storage)
    _ = try biometric.create(password: password); try biometric.enableBiometrics(password: password); biometric.lock()
    storage.cancelBiometric = true
    do { _ = try biometric.unlockBiometric(); try check(false, "a cancelled biometric unlock opened the vault") }
    catch VaultError.cancelled {}
    try check(!biometric.isUnlocked() && (try biometric.remainingAttempts()) == 10, "a cancelled biometric prompt is not counted")
    let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let keychain = try String(contentsOf: ios.appendingPathComponent("PassVault/KeychainStorage.swift"), encoding: .utf8)
    try check(keychain.contains("if biometric && status == errSecUserCanceled { throw VaultError.cancelled }"), "KeychainStorage reports a cancelled prompt as cancelled")
    for path in ["PassVault/PassVaultApp.swift", "AutoFill/AutofillModel.swift"] {
        let source = try String(contentsOf: ios.appendingPathComponent(path), encoding: .utf8)
        try check(source.contains("if case VaultError.cancelled? = error as? VaultError { return }"), "\(path) shows nothing for a cancelled prompt")
    }
}
