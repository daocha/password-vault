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
        app.createOrUnlockVault(password: password)
        let settings = app.buttons["vault.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.buttons["settings.language"].waitForExistence(timeout: 10), app.debugDescription)
        // Further down the list, so it exists only once scrolled into view.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Automatic backup")).firstMatch
        XCTAssertTrue(app.scrollUntilHittable(row), app.debugDescription)
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
}
