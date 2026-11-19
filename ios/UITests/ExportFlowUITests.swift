import XCTest

/// Exporting an encrypted backup on the simulator: a wrong password shows the error and keeps the vault open; the right one offers
/// Save to Files and Send to a nearby device as buttons, and Send opens the share sheet.
final class ExportFlowUITests: XCTestCase {
    private let password = "Simulator test password 1!"
    override func setUpWithError() throws { continueAfterFailure = false }

    func testExportOffersSaveAndSendAndAWrongPasswordKeepsTheVaultOpen() {
        let app = XCUIApplication()
        app.launch()
        app.createOrUnlockVault(password: password)
        let settings = app.buttons["vault.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.buttons["settings.language"].waitForExistence(timeout: 10), app.debugDescription)
        // Further down the list, so it exists only once scrolled into view.
        let export = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Export encrypted backup")).firstMatch
        XCTAssertTrue(app.scrollUntilHittable(export), app.debugDescription)
        export.tap()

        let field = app.secureTextFields["Current app password"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("Wrong passphrase 9!")
        app.buttons["Export"].tap()
        let errors = app.staticTexts.matching(NSPredicate(format: "label == %@", "Incorrect password or damaged encrypted data."))
        XCTAssertTrue(errors.firstMatch.waitForExistence(timeout: 60), "the error shows: \(app.debugDescription)")
        XCTAssertTrue(errors.allElementsBoundByIndex.contains { $0.isHittable }, "the message is on top, not behind the sheet: \(app.debugDescription)")
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
        // The share sheet's elements differ between iOS versions; any of these means it is open.
        let marks = [app.otherElements["ActivityListView"], app.navigationBars["UIActivityContentView"], app.buttons["AirDrop"], app.cells["AirDrop"], app.buttons["Close"]]
        let deadline = Date().addingTimeInterval(20)
        while !marks.contains(where: \.exists) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(marks.contains(where: \.exists), "the share sheet opens: \(app.debugDescription)")
        if app.buttons["Close"].exists { app.buttons["Close"].tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertFalse(app.buttons["Unlock vault"].exists)
    }
}
