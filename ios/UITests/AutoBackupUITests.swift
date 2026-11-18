import XCTest

/// Automatic backup on the simulator, from Settings: set up with the app password, a folder (the system picker is replaced by a folder in
/// the app's temporary directory; see uiTestBackupFolder), then Back up now, each confirmed by an alert.
final class AutoBackupUITests: XCTestCase {
    private let password = "Simulator test password 1!"
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSetUpAndBackUpNowAreConfirmed() {
        let app = XCUIApplication()
        app.launchEnvironment["PASSVAULT_UI_TEST_BACKUP_FOLDER"] = "ui-test-backups-\(UUID().uuidString)"
        app.launch()
        createOrUnlock(app)
        let settings = app.buttons["vault.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        settings.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Automatic backup")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        row.tap()
        // Turned on by an earlier run on this simulator: choose the folder again.
        let another = app.buttons["Choose another folder"]
        if another.waitForExistence(timeout: 3) { another.tap() }

        XCTAssertTrue(app.secureTextFields["Current app password"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeText(password)
        app.buttons["Choose a folder"].tap()
        let saved = app.alerts["Backup saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 90), "the first backup is confirmed: \(app.debugDescription)")
        saved.buttons["OK"].tap()

        let now = app.buttons["Back up now"]
        XCTAssertTrue(now.waitForExistence(timeout: 10), "the panel with Back up now opens after choosing the folder: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Last automatic backup:")).firstMatch.waitForExistence(timeout: 10))
        now.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 30), "Back up now is confirmed: \(app.debugDescription)")
        saved.buttons["OK"].tap()
        XCTAssertFalse(app.alerts["Backup not saved"].exists)
    }

    /// The other UI tests may already have created the vault on this simulator.
    private func createOrUnlock(_ app: XCUIApplication) {
        let create = app.buttons["Create vault"]
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        if create.exists {
            app.secureTextFields["Master passphrase"].tap()
            app.secureTextFields["Master passphrase"].typeText(password)
            app.secureTextFields["Repeat passphrase"].tap()
            app.secureTextFields["Repeat passphrase"].typeText(password)
            let consent = app.switches.firstMatch
            consent.tap()
            if consent.value as? String != "1" { consent.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
            create.tap()
        } else {
            let field = app.secureTextFields.firstMatch
            field.tap(); field.typeText(password)
            app.buttons.matching(NSPredicate(format: "label IN %@", ["Unlock vault", "解锁保险库", "解鎖保險庫"])).firstMatch.tap()
        }
    }
}
