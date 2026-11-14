import Foundation

/// The one-line message the app shows over the vault (errors, confirmations, the debug unlock timing). Mirrors Android's
/// snackbar: it closes with OK or by itself after `displaySeconds`, and errors are marked as errors.
/// Each `show` gets a new `serial`, so a timer started for an earlier message never hides a newer one, even one with the same text.
public struct StatusMessage: Equatable, Sendable {
    /// Android hides its snackbar after 6 seconds.
    public static let displaySeconds: Double = 6
    public private(set) var text = ""
    public private(set) var isError = false
    public private(set) var serial = 0
    public init() {}
    public var isShowing: Bool { !text.isEmpty }

    /// Shows `text` and returns the serial to pass to `expire` when its time is up. Empty text just closes the message.
    @discardableResult public mutating func show(_ text: String, error: Bool) -> Int {
        serial &+= 1
        self.text = text; isError = error && !text.isEmpty
        return serial
    }
    /// OK, or a new action that starts with a clean slate.
    public mutating func dismiss() { serial &+= 1; text = ""; isError = false }
    /// The display time of the message shown as `serial` is up: hide it, unless something newer has replaced it.
    public mutating func expire(_ serial: Int) { if serial == self.serial { dismiss() } }
}
