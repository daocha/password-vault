import XCTest

/// On a wide screen (an iPad, an unfolded foldable iPhone) entries and editors open in a pane beside the list; on a narrow
/// one (an iPhone, a folded phone) they open over the list, as before. CI runs this on an iPhone and on an iPad simulator.
final class TwoPaneTests: XCTestCase {
    private let password = "Simulator test password 1!"
    override func setUpWithError() throws { continueAfterFailure = false }

    func testEntriesOpenBesideTheListOnWideScreensAndOverItOnNarrowOnes() {
        let app = XCUIApplication()
        app.launch()
        createOrUnlock(app)
        let settings = app.buttons["vault.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        let wide = app.windows.firstMatch.horizontalSizeClass == .regular
        XCTAssertEqual(app.staticTexts["No entry selected"].exists, wide, "only a wide screen has the side pane")

        let suffix = UUID().uuidString.prefix(4)
        let first = "Pane A \(suffix)", second = "Pane B \(suffix)"
        addLogin(first, in: app)
        if wide {
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "a saved new entry opens beside the list: \(app.debugDescription)")
            XCTAssertTrue(settings.isHittable, "the list stays usable beside the pane")
        } else {
            XCTAssertTrue(waitUntilHittable(settings), "a narrow screen returns to the list: \(app.debugDescription)")
            XCTAssertFalse(app.buttons["Close"].exists)
        }
        addLogin(second, in: app)

        row(first, in: app).tap()
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), app.debugDescription)
        if wide {
            XCTAssertTrue(app.buttons["Close"].exists)
            XCTAssertTrue(settings.isHittable, "the details open beside the list")
            editBesideTheList(first: first, second: second, in: app)
            app.buttons["Close"].tap()
            XCTAssertTrue(app.staticTexts["No entry selected"].waitForExistence(timeout: 10), app.debugDescription)
        } else {
            XCTAssertTrue(app.buttons["Back"].exists, "the details open full screen, as before")
            XCTAssertFalse(settings.isHittable)
            // Edit still opens as a sheet over the details, and discarding returns to them.
            edit.tap()
            XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 10), app.debugDescription)
            app.buttons["Discard changes"].tap()
            XCTAssertTrue(waitUntilHittable(app.buttons["Back"]), app.debugDescription)
            app.buttons["Back"].tap()
            XCTAssertTrue(waitUntilHittable(settings), app.debugDescription)
        }
    }

    /// Editing in the pane: tapping another entry with unsaved changes asks first, and Keep editing keeps what was typed.
    private func editBesideTheList(first: String, second: String, in app: XCUIApplication) {
        app.buttons["Edit"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["vault.settings"].isHittable, "the editor opens beside the list")
        name.tap()
        name.typeText(" edited")
        row(second, in: app).tap()
        let alert = app.alerts["Discard unsaved changes?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        alert.buttons["Keep editing"].tap()
        XCTAssertTrue((name.value as? String)?.hasSuffix(" edited") == true, "Keep editing keeps the typed text")

        row(second, in: app).tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        alert.buttons["Discard"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(name.exists, "the other entry's details replace the editor")
        XCTAssertFalse(app.staticTexts["\(first) edited"].exists, "the discarded name was not saved")
    }

    private func addLogin(_ name: String, in app: XCUIApplication) {
        let add = app.buttons["New entry"]
        XCTAssertTrue(waitUntilHittable(add), app.debugDescription)
        // SwiftUI exposes the menu as a labelled button around the unlabelled control that opens it, and a tap on the
        // outer element does not always reach it. Try the inner control, a tap at its centre, then a long press.
        let login = app.buttons["Login"]
        let attempts: [() -> Void] = [
            { add.buttons.firstMatch.exists ? add.buttons.firstMatch.tap() : add.tap() },
            { add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() },
            { add.press(forDuration: 0.8) },
            { add.tap() },
        ]
        for attempt in attempts {
            attempt()
            if login.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(login.exists, app.debugDescription)
        login.tap()
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText(name)
        app.buttons["Save"].tap()
        XCTAssertTrue(row(name, in: app).waitForExistence(timeout: 15), app.debugDescription)
    }

    /// The entry's row in the list (the detail pane has no cells).
    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.containing(.staticText, identifier: name).firstMatch
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// The localization test may already have created the vault on this simulator.
    private func createOrUnlock(_ app: XCUIApplication) {
        let create = app.buttons["Create vault"]
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        if create.exists {
            app.secureTextFields["Master passphrase"].tap()
            app.secureTextFields["Master passphrase"].typeText(password)
            app.secureTextFields["Repeat passphrase"].tap()
            app.secureTextFields["Repeat passphrase"].typeText(password)
            let consent = app.switches.firstMatch
            consent.tap()
            if consent.value as? String != "1" { consent.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
            XCTAssertEqual(consent.value as? String, "1")
            create.tap()
        } else {
            field.tap()
            field.typeText(password)
            app.buttons.matching(NSPredicate(format: "label IN %@", ["Unlock vault", "解锁保险库", "解鎖保險庫"])).firstMatch.tap()
        }
    }
}
