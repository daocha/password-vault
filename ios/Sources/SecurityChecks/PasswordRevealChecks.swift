import Foundation

/// Every password box in the app has an eye that shows what was typed, as on Android (see PasswordRevealTests).
func passwordRevealChecks() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let app = root.appendingPathComponent("PassVault")
    for file in try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil) where file.pathExtension == "swift"
        && !["PasswordInput.swift", "EntryEditorViews.swift"].contains(file.lastPathComponent) {
        try check(!(try String(contentsOf: file, encoding: .utf8)).contains("SecureField("), "\(file.lastPathComponent): password boxes use PasswordInput, which has an eye")
    }
    let input = try String(contentsOf: app.appendingPathComponent("PasswordInput.swift"), encoding: .utf8)
    // One field switched in place: swapping a SecureField for a TextField lost the keyboard and made the form jump.
    try check(input.contains("field.isSecureTextEntry = !shown") && input.contains("setShown(false)") && !input.contains("TextField(label"), "PasswordBox starts hidden and toggles one field in place")
    try check((try String(contentsOf: app.appendingPathComponent("SettingsPasswordField.swift"), encoding: .utf8)).contains("PasswordBox(field: Field())"), "the Settings and Export password box has an eye")
    for language in ["en", "zh-Hans", "zh-Hant"] {
        let table = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("\(language).lproj/Localizable.strings")), format: nil) as! [String: String]
        try check(table["Show password"] != nil && table["Hide password"] != nil, "\(language) translates the eye's labels")
    }
}
