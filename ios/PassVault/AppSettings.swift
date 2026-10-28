import SwiftUI
import UIKit
import VaultCore

/// How soon the vault locks after the app leaves the screen; the same choices as Android.
enum AutoLock: String, CaseIterable, Identifiable {
    case immediately, oneMinute, fiveMinutes, deviceLock
    var id: String { rawValue }
    var label: String {
        switch self {
        case .immediately: "Immediately"
        case .oneMinute: "After 1 minute"
        case .fiveMinutes: "After 5 minutes"
        case .deviceLock: "When the device locks"
        }
    }
    /// Seconds in the background before locking; nil when only locking the device does it.
    var delay: TimeInterval? {
        switch self {
        case .immediately: 0
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .deviceLock: nil
        }
    }
}

/// How long a copied secret stays on the clipboard; the same choices as Android.
enum ClipboardClear: String, CaseIterable, Identifiable {
    case s30, m1, m2, m5, m10, m15, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .s30: "30 seconds"
        case .m1: "1 minute"
        case .m2: "2 minutes"
        case .m5: "5 minutes"
        case .m10: "10 minutes"
        case .m15: "15 minutes"
        case .never: "Never"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .s30: 30
        case .m1: 60
        case .m2: 120
        case .m5: 300
        case .m10: 600
        case .m15: 900
        case .never: nil
        }
    }
}

/// Preferences that hold no secrets, so they live in ordinary UserDefaults. Defaults match Android's.
@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard
    @Published var autoLock: AutoLock { didSet { defaults.set(autoLock.rawValue, forKey: "autoLock") } }
    @Published var allowCopy: Bool { didSet { defaults.set(allowCopy, forKey: "allowCopy"); if !allowCopy { SecretClipboard.clear() } } }
    @Published var clipboardClear: ClipboardClear { didSet { defaults.set(clipboardClear.rawValue, forKey: "clipboardClear") } }
    @Published var clearClipboardOnLock: Bool { didSet { defaults.set(clearClipboardOnLock, forKey: "clearClipOnLock") } }
    @Published var generator: GeneratorOptions { didSet {
        defaults.set(generator.length, forKey: "genLength"); defaults.set(generator.letters, forKey: "genLetters")
        defaults.set(generator.numbers, forKey: "genNumbers"); defaults.set(generator.symbols, forKey: "genSymbols")
    } }
    private init() {
        autoLock = defaults.string(forKey: "autoLock").flatMap(AutoLock.init) ?? .immediately
        allowCopy = defaults.object(forKey: "allowCopy") as? Bool ?? true
        clipboardClear = defaults.string(forKey: "clipboardClear").flatMap(ClipboardClear.init) ?? .m1
        clearClipboardOnLock = defaults.object(forKey: "clearClipOnLock") as? Bool ?? true
        var options = GeneratorOptions(length: (defaults.object(forKey: "genLength") as? Int ?? 10).clamped(GeneratorOptions.minLength, GeneratorOptions.maxLength),
                                       letters: defaults.object(forKey: "genLetters") as? Bool ?? true, numbers: defaults.object(forKey: "genNumbers") as? Bool ?? true,
                                       symbols: defaults.object(forKey: "genSymbols") as? Bool ?? true)
        if !options.letters && !options.numbers && !options.symbols { options = GeneratorOptions() }
        generator = options
    }
}

private extension Int { func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) } }

/// The one place a secret is put on the pasteboard: this device only (never Universal Clipboard), and removed after the chosen delay.
@MainActor enum SecretClipboard {
    private static var lastChange: Int?
    static func copy(_ value: String) {
        let settings = AppSettings.shared
        guard settings.allowCopy else { return }
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if let seconds = settings.clipboardClear.seconds { options[.expirationDate] = Date().addingTimeInterval(seconds) }
        UIPasteboard.general.setItems([["public.utf8-plain-text": value]], options: options)
        lastChange = UIPasteboard.general.changeCount
    }
    /// Empties the pasteboard only if it still holds what this app copied.
    static func clear() {
        guard let lastChange, UIPasteboard.general.changeCount == lastChange else { return }
        UIPasteboard.general.setItems([], options: [:]); Self.lastChange = nil
    }
    static func clearOnLock() { if AppSettings.shared.clearClipboardOnLock { clear() } }
}
