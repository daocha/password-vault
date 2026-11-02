import Foundation

public enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "", english = "en", simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: "System default"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }
    public var locale: Locale { self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue) }
    public func bundle(in bundle: Bundle = .main) -> Bundle {
        guard self != .system, let path = bundle.path(forResource: rawValue, ofType: "lproj"),
              let localized = Bundle(path: path) else { return bundle }
        return localized
    }
}

/// Nonsecret preferences, with the same keys, choices and defaults as Android.
public struct AppearancePreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var theme: AppTheme {
        get { defaults.string(forKey: "theme").flatMap(AppTheme.init(rawValue:)) ?? .system }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "theme") }
    }
    public var language: AppLanguage {
        get { defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "language") }
    }
}
