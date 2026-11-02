import XCTest

final class LocalizationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLanguageSwitchUpdatesPresentedSettingsAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Create vault"].waitForExistence(timeout: 15), app.debugDescription)
        do {
            let password = "Simulator test password 1!"
            app.secureTextFields["Master passphrase"].tap()
            app.secureTextFields["Master passphrase"].typeText(password)
            app.secureTextFields["Repeat passphrase"].tap()
            app.secureTextFields["Repeat passphrase"].typeText(password)
            let consent = app.switches.firstMatch
            consent.tap()
            // SwiftUI exposes both the labelled container and its native switch.
            // On runtimes where tapping the label only scrolls it into view, hit the control.
            if consent.value as? String != "1" { consent.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
            XCTAssertEqual(consent.value as? String, "1")
            XCTAssertTrue(app.buttons["Create vault"].isEnabled)
            app.buttons["Create vault"].tap()
        }
        openSettings(app)
        selectLanguage("zh-Hans", in: app)
        openSettings(app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["外观"].exists)

        app.terminate()
        app.launch()
        unlock(app)
        openSettings(app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))

        selectLanguage("zh-Hant", in: app)
        openSettings(app)
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 10))
        selectLanguage("en", in: app)
        openSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    private func unlock(_ app: XCUIApplication) {
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Simulator test password 1!")
        // The first form button is the localized Unlock vault action.
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Unlock vault", "解锁保险库", "解鎖保險庫"])).firstMatch.tap()
    }

    private func openSettings(_ app: XCUIApplication) {
        let button = app.buttons["vault.settings"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), app.debugDescription)
        button.tap()
        XCTAssertTrue(app.buttons["settings.language"].waitForExistence(timeout: 10))
    }

    private func selectLanguage(_ language: String, in app: XCUIApplication) {
        app.buttons["settings.language"].tap()
        let option = app.buttons["language.\(language)"]
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        option.tap()
    }
}
