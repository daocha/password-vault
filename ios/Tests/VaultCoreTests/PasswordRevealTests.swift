import Foundation
import XCTest

/// Every box where the user types a password has an eye that shows what was typed, as on Android.
final class PasswordRevealTests: XCTestCase {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PassVault")
    }

    func testEverySecureFieldHasAnEye() throws {
        let files = try FileManager.default.contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        // PasswordInput carries its own eye; OutlinedField's secure mode is driven by an eye beside it (entry editor, 2FA key).
        for file in files where !["PasswordInput.swift", "EntryEditorViews.swift"].contains(file.lastPathComponent) {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("SecureField("), "\(file.lastPathComponent) has a password box without an eye: use PasswordInput")
        }
        let unlock = try String(contentsOf: appSources.appendingPathComponent("PassVaultApp.swift"), encoding: .utf8)
        for label in ["Master passphrase", "Repeat passphrase", "New app password", "Repeat new app password", "Decoy password", "New decoy password", "Repeat decoy password"] {
            XCTAssertTrue(unlock.contains("PasswordInput(label: \"\(label)\""), "\(label) has an eye")
        }
        XCTAssertTrue(unlock.contains("PasswordInput(label: keepass ? \"Database password\" : \"File password\""), "import password has an eye")
        let settings = try String(contentsOf: appSources.appendingPathComponent("SettingsPasswordField.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("field.rightView = eye"), "the app password box in Settings and Export has an eye")
    }

    func testEyeLabelsAreTranslated() throws {
        for (language, show, hide) in [("en", "Show password", "Hide password"), ("zh-Hans", "显示密码", "隐藏密码"), ("zh-Hant", "顯示密碼", "隱藏密碼")] {
            let data = try Data(contentsOf: appSources.appendingPathComponent("\(language).lproj/Localizable.strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            XCTAssertEqual(table["Show password"], show, language)
            XCTAssertEqual(table["Hide password"], hide, language)
        }
    }
}
