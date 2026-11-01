import Foundation
import XCTest
@testable import VaultCore

final class AppearancePreferencesTests: XCTestCase {
    private var appResources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PassVault")
    }

    func testDefaultsAndUnknownSavedValuesFollowSystem() throws {
        let name = "PassVault.appearance-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppearancePreferences(defaults: defaults)
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertEqual(preferences.language, .system)
        defaults.set("retired-theme", forKey: "theme")
        defaults.set("unsupported-language", forKey: "language")
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertEqual(preferences.language, .system)
    }

    func testChoicesSurviveReloadWithoutChangingOtherPreferences() throws {
        let name = "PassVault.appearance-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(300, forKey: "autoLockDelay")
        let preferences = AppearancePreferences(defaults: defaults)
        for theme in AppTheme.allCases {
            for language in AppLanguage.allCases {
                preferences.theme = theme
                preferences.language = language
                let reloaded = AppearancePreferences(defaults: defaults)
                XCTAssertEqual(reloaded.theme, theme)
                XCTAssertEqual(reloaded.language, language)
                XCTAssertEqual(defaults.integer(forKey: "autoLockDelay"), 300)
            }
        }
    }

    func testTranslationsHaveMatchingKeysAndFormatArguments() throws {
        func table(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: appResources.appendingPathComponent("\(language).lproj/Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try table("en")
        let placeholders = try NSRegularExpression(pattern: "%([0-9]+\\$)?(lld|ld|d|@|s)")
        func arguments(_ text: String) -> [String] {
            placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }.sorted()
        }
        for language in ["zh-Hans", "zh-Hant"] {
            let translated = try table(language)
            XCTAssertEqual(Set(english.keys), Set(translated.keys))
            for (key, value) in translated {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
                XCTAssertEqual(arguments(key), arguments(value), "\(language): \(key)")
            }
            XCTAssertNotEqual(translated["Settings"], english["Settings"])
            XCTAssertNotEqual(translated["Theme"], english["Theme"])
            XCTAssertNotEqual(translated["Language"], english["Language"])
        }
    }

    func testExplicitLanguageLoadsItsResourceBundleAndSystemUsesTheOriginalBundle() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = ["CFBundleIdentifier": "app.passvault.localization-tests", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appendingPathComponent("Info.plist"))
        for language in ["en", "zh-Hans", "zh-Hant"] {
            try FileManager.default.copyItem(at: appResources.appendingPathComponent("\(language).lproj"), to: folder.appendingPathComponent("\(language).lproj"))
        }
        let bundle = try XCTUnwrap(Bundle(url: folder))
        XCTAssertEqual(AppLanguage.english.bundle(in: bundle).localizedString(forKey: "Settings", value: nil, table: nil), "Settings")
        XCTAssertEqual(AppLanguage.simplifiedChinese.bundle(in: bundle).localizedString(forKey: "Settings", value: nil, table: nil), "设置")
        XCTAssertEqual(AppLanguage.traditionalChinese.bundle(in: bundle).localizedString(forKey: "Settings", value: nil, table: nil), "設定")
        XCTAssertEqual(AppLanguage.system.bundle(in: bundle), bundle)
    }
}
