import AuthenticationServices
import SwiftUI
import UIKit

/// PassVault's AutoFill. iOS opens it from the Passwords (key) button above the keyboard once PassVault is turned on in Settings →
/// General → AutoFill & Passwords. PassVault puts nothing in the QuickType bar, so no username or website leaves the encrypted vault: the
/// vault is unlocked here, with the app password or Face ID / Touch ID (counted attempts, as in the app), and the login the user confirms
/// is handed to the app or web page asking. The vault locks again when it fills, is cancelled, closes or the device locks.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let model = AutofillModel()
    private var deviceLock: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] credential in self?.finish(credential) }
        let host = UIHostingController(rootView: AutofillRoot(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        deviceLock = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.cancel() }
        }
    }
    deinit { if let deviceLock { NotificationCenter.default.removeObserver(deviceLock) } }

    /// The Passwords button: the page's address, or the domains the app is associated with.
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.start(serviceIdentifiers.map(\.identifier))
    }
    /// Only for logins offered in the QuickType bar, which PassVault never fills in: always ask.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.Code.userInteractionRequired.rawValue))
    }
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        model.start([credentialRequest.credentialIdentity.serviceIdentifier.identifier])
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.close()
    }

    private func finish(_ credential: ASPasswordCredential?) {
        if let credential { extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: nil) }
        else { extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.Code.userCanceled.rawValue)) }
    }
}
