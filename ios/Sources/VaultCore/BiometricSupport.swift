import Foundation
import LocalAuthentication

/// Whether biometric unlock can be turned on, from what LocalAuthentication reports. Mirrors Android's `BiometricSupport`.
public enum BiometricAvailability: Equatable, Sendable {
    case available, notEnrolled, unsupported, unavailable

    /// `code` is the LAError code `canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` reported (nil when it succeeded);
    /// `hasSensor` is whether the device has Face ID or Touch ID at all (`biometryType != .none`).
    public init(laErrorCode code: Int?, hasSensor: Bool) {
        switch code {
        case nil: self = .available
        case LAError.Code.biometryNotEnrolled.rawValue: self = .notEnrolled
        // biometryNotAvailable also means Face ID was denied to the app, which Settings can undo; only a missing sensor is permanent.
        case LAError.Code.biometryNotAvailable.rawValue where !hasSensor: self = .unsupported
        default: self = .unavailable
        }
    }

    /// The device's current answer.
    public static func current() -> BiometricAvailability {
        let context = LAContext(); var error: NSError?
        let ok = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return BiometricAvailability(laErrorCode: ok ? nil : (error?.code ?? LAError.Code.biometryNotAvailable.rawValue), hasSensor: context.biometryType != .none)
    }

    /// The switch can always turn biometric unlock off; turning it on needs Face ID or Touch ID ready to use.
    public func canToggle(enabled: Bool) -> Bool { enabled || self == .available }

    /// The settings row's status line while biometric unlock is off.
    public var offSummary: String {
        switch self {
        case .available: "Off"
        case .notEnrolled: "Enroll Face ID or Touch ID in Settings first."
        case .unsupported: "Not available: this device has no Face ID or Touch ID"
        case .unavailable: "Face ID or Touch ID is unavailable right now. Check Settings."
        }
    }
}
