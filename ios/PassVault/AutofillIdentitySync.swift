import AuthenticationServices
import VaultCore

/// Keeps iOS's list of AutoFill logins (the suggestions above the keyboard) in step with the open vault while the user has turned on
/// "Show logins above the keyboard" (`AutofillIdentities`: site, username and record ID, never a password). Without that list iOS does
/// not offer PassVault in a login form. Turning the switch off, or the vault being erased, empties the list. Updates run one after
/// another, so an earlier one never lands after a later one.
@MainActor enum AutofillIdentitySync {
    static let settingKey = "autofillShowLogins"
    private static var last: Task<Void, Never>?

    static func update(_ records: [VaultRecord]) { apply(AutofillIdentities.entries(records)) }
    static func clear() { apply(nil) }

    private static func apply(_ entries: [AutofillIdentities.Entry]?) {
        let previous = last
        last = Task {
            await previous?.value
            let store = ASCredentialIdentityStore.shared
            do {
                if let entries {
                    // iOS keeps no list for a provider that is turned off; the next unlock fills it once it is on.
                    guard await store.state().isEnabled else { return }
                    try await store.replaceCredentialIdentities(entries.map {
                        ASPasswordCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: $0.domain, type: .domain), user: $0.user, recordIdentifier: $0.recordID)
                    })
                } else {
                    try await store.removeAllCredentialIdentities()
                }
            } catch {
                // Nothing to tell the user: the vault is unaffected, and the next change or unlock tries again.
            }
        }
    }
}
