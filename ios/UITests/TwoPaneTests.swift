import XCTest

/// On a wide screen (an iPad, an unfolded foldable iPhone, an iPhone in landscape) entries and editors open in a pane beside
/// the list; on a narrow one (an upright iPhone, a folded phone) they open over the list, as before. CI runs this on an
/// iPhone and on an iPad simulator.
final class TwoPaneTests: XCTestCase {
    private let password = "Simulator test password 1!"
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    /// Turning an iPhone sideways moves the open entry, and an unsaved edit, into the pane beside the list; turning it
    /// back moves them over the list again.
    func testTurningAPhoneMovesTheOpenEntryBetweenThePaneAndFullScreen() throws {
        let app = XCUIApplication()
        app.launch()
        createOrUnlock(app)
        let settings = app.buttons["vault.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        if app.windows.firstMatch.horizontalSizeClass == .regular { throw XCTSkip("an iPad shows the pane whichever way it is turned") }
        XCTAssertFalse(app.staticTexts["No entry selected"].exists, "an upright iPhone has no side pane")
        // Added upright, where the editor has room for the confirmation checkbox above the keyboard.
        app.buttons["tab.seed"].tap()
        let name = "Sideways \(UUID().uuidString.prefix(4))"
        addSeed(name, in: app)
        XCTAssertTrue(waitUntilHittable(settings), app.debugDescription)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["No entry selected"].waitForExistence(timeout: 10), "an iPhone in landscape splits like an iPad: \(app.debugDescription)")
        row(name, in: app).tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "the entry opens beside the list: \(app.debugDescription)")
        XCTAssertTrue(settings.isHittable, "the list stays usable beside the pane")

        app.buttons["Edit"].tap()
        let field = app.textViews["Wallet name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText(" kept")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the editor moves over the list: \(app.debugDescription)")
        XCTAssertTrue((field.value as? String)?.contains("kept") == true, "turning the phone keeps unsaved edits")
        XCTAssertFalse(app.staticTexts["No entry selected"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((field.value as? String)?.contains("kept") == true, "and turning it back keeps them too")
        app.buttons["Discard changes"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), app.debugDescription)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10), "upright, the details are full screen again: \(app.debugDescription)")
        app.buttons["Back"].tap()
        XCTAssertTrue(waitUntilHittable(settings), app.debugDescription)
    }

    func testEntriesOpenBesideTheListOnWideScreensAndOverItOnNarrowOnes() {
        let app = XCUIApplication()
        app.launch()
        createOrUnlock(app)
        let settings = app.buttons["vault.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        let window = app.windows.firstMatch
        let wide = window.horizontalSizeClass == .regular || window.verticalSizeClass == .compact
        XCTAssertEqual(app.staticTexts["No entry selected"].exists, wide, "only a wide screen has the side pane")

        app.buttons["tab.seed"].tap()
        let suffix = UUID().uuidString.prefix(4)
        let first = "Pane A \(suffix)", second = "Pane B \(suffix)"
        addSeed(first, in: app)
        if wide {
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "a saved new entry opens beside the list: \(app.debugDescription)")
            XCTAssertTrue(settings.isHittable, "the list stays usable beside the pane")
        } else {
            XCTAssertTrue(waitUntilHittable(settings), "a narrow screen returns to the list: \(app.debugDescription)")
            XCTAssertFalse(app.buttons["Close"].exists)
        }
        addSeed(second, in: app)

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
            XCTAssertTrue(app.textViews["Wallet name"].waitForExistence(timeout: 10), app.debugDescription)
            app.buttons["Discard changes"].tap()
            XCTAssertTrue(waitUntilHittable(app.buttons["Back"]), app.debugDescription)
            app.buttons["Back"].tap()
            XCTAssertTrue(waitUntilHittable(settings), app.debugDescription)
        }
    }

    /// Editing in the pane: tapping another entry with unsaved changes asks first, and Keep editing keeps what was typed.
    private func editBesideTheList(first: String, second: String, in app: XCUIApplication) {
        app.buttons["Edit"].tap()
        let name = app.textViews["Wallet name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["vault.settings"].isHittable, "the editor opens beside the list")
        name.tap()
        name.typeText(" edited")
        row(second, in: app).tap()
        let alert = app.alerts["Discard unsaved changes?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        alert.buttons["Keep editing"].tap()
        XCTAssertTrue((name.value as? String)?.contains("edited") == true, "Keep editing keeps the typed text")

        row(second, in: app).tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        alert.buttons["Discard"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(name.exists, "the other entry's details replace the editor")
        XCTAssertFalse(app.staticTexts["\(first) edited"].exists, "the discarded name was not saved")
    }

    /// Adds a generated seed phrase. The seed tab's add button is a plain button; the passwords tab's is a menu, which
    /// XCUITest could not open on the CI simulator.
    private func addSeed(_ name: String, in app: XCUIApplication) {
        let add = app.buttons["New seed phrase"]
        XCTAssertTrue(waitUntilHittable(add), app.debugDescription)
        add.tap()
        let field = app.textViews["Wallet name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        // Confirm the generated words before typing, while the keyboard cannot cover the checkbox.
        let written = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "I wrote these words down")).firstMatch
        XCTAssertTrue(written.waitForExistence(timeout: 10), app.debugDescription)
        written.tap()
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
