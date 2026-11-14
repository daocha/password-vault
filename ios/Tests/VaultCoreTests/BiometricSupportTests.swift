import Foundation
import LocalAuthentication
import XCTest
@testable import VaultCore

final class BiometricSupportTests: XCTestCase {
    private var appResources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PassVault")
    }

    func testLocalAuthenticationAnswersMapToAvailability() {
        XCTAssertEqual(BiometricAvailability(laErrorCode: nil, hasSensor: true), .available)
        XCTAssertEqual(BiometricAvailability(laErrorCode: LAError.Code.biometryNotEnrolled.rawValue, hasSensor: true), .notEnrolled)
        // No Face ID or Touch ID at all: biometric unlock can never be turned on.
        XCTAssertEqual(BiometricAvailability(laErrorCode: LAError.Code.biometryNotAvailable.rawValue, hasSensor: false), .unsupported)
        // A sensor the app was denied, or one locked out, can come back from Settings.
        XCTAssertEqual(BiometricAvailability(laErrorCode: LAError.Code.biometryNotAvailable.rawValue, hasSensor: true), .unavailable)
        XCTAssertEqual(BiometricAvailability(laErrorCode: LAError.Code.biometryLockout.rawValue, hasSensor: true), .unavailable)
        XCTAssertEqual(BiometricAvailability(laErrorCode: LAError.Code.passcodeNotSet.rawValue, hasSensor: true), .unavailable)
    }

    func testTheSwitchCanAlwaysTurnBiometricsOffButOnlyOnWhenReady() {
        XCTAssertTrue(BiometricAvailability.available.canToggle(enabled: false))
        for availability in [BiometricAvailability.notEnrolled, .unsupported, .unavailable] {
            XCTAssertFalse(availability.canToggle(enabled: false), "\(availability) cannot turn biometrics on")
            XCTAssertTrue(availability.canToggle(enabled: true), "\(availability) can still turn biometrics off")
        }
    }

    func testEveryStatusLineIsTranslated() throws {
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let data = try Data(contentsOf: appResources.appendingPathComponent("\(language).lproj/Localizable.strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for availability in [BiometricAvailability.available, .notEnrolled, .unsupported, .unavailable] {
                XCTAssertNotNil(table[availability.offSummary], "\(language) lacks \(availability.offSummary)")
            }
        }
    }
}
