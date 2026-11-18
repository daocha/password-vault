import XCTest

/// Exporting an encrypted backup on the simulator: a wrong password shows the error and keeps the vault open; the right one offers
/// Save to Files and Send to a nearby device as buttons, and Send opens the share sheet.
final class ExportFlowUITests: XCTestCase {
    private let password = "Simulator test password 1!"
    override func setUpWithError() throws { continueAfterFailure = false }

    func testExportOffersSaveAndSendAndAWrongPasswordKeepsTheVaultOpen() {
        let app = XCUIApplication()
        app.launch()
        createOrUnlock(app)
        let settings = app.buttons["vault.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        settings.tap()
        let export = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Export encrypted backup")).firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<8 where !export.isHittable { app.swipeUp() }
        export.tap()

        let field = app.secureTextFields["Current app password"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("Wrong passphrase 9!")
        app.buttons["Export"].tap()
        let error = app.staticTexts["Incorrect password or damaged encrypted data."].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 60), "the error shows inside the panel: \(app.debugDescription)")
        XCTAssertTrue(error.isHittable, "the message is on top, not behind the sheet")
        XCTAssertFalse(app.buttons["Unlock vault"].exists, "a wrong password no longer locks the vault")
        XCTAssertTrue(field.exists)

        field.tap()
        field.typeText(password)
        app.buttons["Export"].tap()
        let save = app.buttons["Save to Files"], send = app.buttons["Send to a nearby device"]
        XCTAssertTrue(send.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertTrue(save.isHittable && send.isHittable)
        XCTAssertTrue(app.staticTexts["Save or send this backup?"].exists || app.staticTexts["SAVE OR SEND THIS BACKUP?"].exists)
        send.tap()
        let sheet = app.otherElements["ActivityListView"], close = app.buttons["Close"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20) || close.waitForExistence(timeout: 1), "the share sheet opens: \(app.debugDescription)")
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertFalse(app.buttons["Unlock vault"].exists)
    }

    /// The localization and side-pane tests may already have created the vault on this simulator.
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
