import XCTest
import VaultCore
@testable import PassVault

/// The real storage on the simulator. Once the vault is in the app group, AutoFill's storage finds the same protected state, files and
/// biometric key; before that (or without the app group) AutoFill is refused instead of opening an empty vault.
final class SharedVaultStorageTests: XCTestCase {
    func testAutofillOpensTheVaultTheAppShares() throws {
        XCTAssertEqual(SharedVault.group, "group." + (Bundle.main.bundleIdentifier ?? ""))
        let app = try KeychainStorage()
        guard app.shared else {
            XCTAssertThrowsError(try KeychainStorage(role: .autofill)) { XCTAssertTrue($0 is KeychainStorage.NotShared) }
            return
        }
        let autofill = try KeychainStorage(role: .autofill)
        XCTAssertTrue(autofill.shared)
        XCTAssertEqual(try app.readState(), try autofill.readState())
        XCTAssertEqual(try app.hasBlobs(), try autofill.hasBlobs())
        XCTAssertEqual(try app.hasBiometricKey(), try autofill.hasBiometricKey())
        // A second launch of the app finds the vault already moved.
        XCTAssertTrue(try KeychainStorage().shared)
    }
}
