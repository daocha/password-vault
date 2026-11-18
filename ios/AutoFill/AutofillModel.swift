import AuthenticationServices
import SwiftUI
import VaultCore

/// The language and appearance chosen in PassVault, which the app copies to the app group (`AppSettings.shareWithAutofill`).
enum AutofillSettings {
    static var preferences: AppearancePreferences { AppearancePreferences(defaults: SharedVault.preferences ?? .standard) }
}
/// The extension's text in the language chosen in PassVault. `PasswordInput` uses it too.
@MainActor func localized(_ key: String) -> String {
    AutofillSettings.preferences.language.bundle().localizedString(forKey: key, value: nil, table: nil)
}
@MainActor func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: AutofillSettings.preferences.language.locale, arguments: arguments)
}

/// One AutoFill request: open the shared vault, unlock it, list the logins for the site first, fill the one the user confirms.
@MainActor final class AutofillModel: ObservableObject {
    enum Stage: Equatable { case loading, unavailable(String), locked, open }
    @Published private(set) var stage = Stage.loading
    /// The open vault's logins (with a username or password); empty while locked.
    @Published private(set) var logins = [VaultRecord]()
    /// Which of them are for the site asking (`AutofillMatch.suggestedIDs`).
    private(set) var suggested = Set<String>()
    @Published private(set) var busy = false
    @Published var message = ""
    @Published private(set) var attempts = 10
    @Published private(set) var biometricEnabled = false
    /// The login waiting for the user to confirm where it goes.
    @Published var confirming: VaultRecord?
    /// The sites iOS named for this request, as hosts.
    private(set) var sites = [String]()
    /// The site shown to the user: the first one iOS named.
    var target: String { sites.first ?? localized("this app") }
    var finish: (ASPasswordCredential?) -> Void = { _ in }
    private var engine: VaultEngine?
    /// Bumped by every new request and every close, so work that finishes afterwards is dropped (and its vault locked).
    private var generation = 0
    private var biometricPrompted = false
    private let queue = DispatchQueue(label: "PassVault.autofill", qos: .userInitiated)

    /// Vault work runs off the main thread, one piece at a time.
    private func work<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async { continuation.resume(with: Result { try body() }) } }
    }

    func start(_ identifiers: [String]) {
        close()
        let current = generation
        sites = AutofillMatch.sites(identifiers); message = ""; stage = .loading; biometricPrompted = false
        Task {
            do {
                let reason = { AutofillSettings.preferences.language.bundle().localizedString(forKey: "Unlock your password vault", value: nil, table: nil) }
                let opened = try await work { () -> (VaultEngine, erased: Bool, exists: Bool, attempts: Int, biometric: Bool) in
                    // Half the memory of the app's unlock: iOS stops an extension that uses much more.
                    let engine = VaultEngine(storage: try KeychainStorage(role: .autofill, reason: reason), sequentialKeys: true)
                    if try engine.isErased() { return (engine, true, true, 0, false) }
                    return (engine, false, try engine.exists(), try engine.remainingAttempts(), (try? engine.biometricsEnabled()) ?? false)
                }
                guard current == generation else { return }
                engine = opened.0
                if opened.erased { stage = .unavailable(localized(VaultError.erased.localizedDescription)) }
                else if !opened.exists { stage = .unavailable(localized("Create your vault in PassVault first.")) }
                else {
                    attempts = opened.attempts; biometricEnabled = opened.biometric; stage = .locked
                    if biometricEnabled { biometricPrompted = true; unlockWithBiometrics() }
                }
            } catch {
                if current == generation { stage = .unavailable(localized(error.localizedDescription)) }
            }
        }
    }

    func unlock(password: String) { run { try $0.unlock(password: password) } }
    func unlockWithBiometrics() { run { try $0.unlockBiometric() } }
    private func run(_ action: @escaping (VaultEngine) throws -> [VaultRecord]) {
        guard !busy, stage == .locked, let engine else { return }
        busy = true; message = ""
        let current = generation
        Task {
            defer { if current == generation { busy = false } }
            do {
                let sites = self.sites
                let opened = try await work { () -> ([VaultRecord], Set<String>) in
                    let logins = AutofillMatch.candidates(try action(engine))
                    return (logins, AutofillMatch.suggestedIDs(logins, sites: sites))
                }
                guard current == generation else { queue.async { engine.lock() }; return }
                logins = opened.0; suggested = opened.1; stage = .open
            } catch {
                let status = try? await work { () -> (Int, Bool) in engine.lock(); return ((try? engine.remainingAttempts()) ?? 0, (try? engine.isErased()) ?? false) }
                guard current == generation else { return }
                let (left, erased) = status ?? (0, false)
                attempts = left
                if erased { stage = .unavailable(localized(VaultError.erased.localizedDescription)); return }
                // As in the app: a wrong password says how many attempts are left before the vault is erased.
                if case VaultError.authentication? = error as? VaultError { message = localizedFormat("Incorrect password. %lld attempts left before this vault is erased.", left) }
                else { message = localized(error.localizedDescription) }
            }
        }
    }

    /// Hands the confirmed login to the app or page asking, and locks the vault.
    func fill(_ record: VaultRecord) {
        guard stage == .open, let engine, engine.isUnlocked(), logins.contains(where: { $0.id == record.id }) else { return }
        let credential = ASPasswordCredential(user: AutofillMatch.username(record) ?? "", password: AutofillMatch.password(record) ?? "")
        close()
        finish(credential)
    }
    func cancel() { close(); finish(nil) }
    /// Locks the vault and forgets its logins. Work still running is dropped when it finishes.
    func close() {
        generation += 1
        logins = []; suggested = []; confirming = nil; busy = false
        if stage == .open { stage = .locked }
        if let engine { queue.async { engine.lock() } }
    }
}
