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
}
