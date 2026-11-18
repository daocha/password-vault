import XCTest

/// The eye beside a password box shows what was typed and hides it again, as on Android.
final class PasswordRevealUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testEyeRevealsTheUnlockPasswordAndHidesItAgain() {
        let app = XCUIApplication()
        app.launch()
        let field = app.secureTextFields["Master passphrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.tap()
        field.typeText("abc")
        let place = field.frame
        app.buttons["Show password"].firstMatch.tap()
        let shown = app.textFields["Master passphrase"]
        XCTAssertTrue(shown.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(shown.frame, place, "the form must not jump when the eye is tapped")
        XCTAssertEqual(shown.value as? String, "abc")
        // The keyboard stays with the box: typing goes on where it left off.
        shown.typeText("d")
        XCTAssertEqual(shown.value as? String, "abcd")
        app.buttons["Hide password"].firstMatch.tap()
        XCTAssertTrue(app.secureTextFields["Master passphrase"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.textFields["Master passphrase"].exists)
        XCTAssertEqual((app.secureTextFields["Master passphrase"].value as? String)?.count, 4)
        XCTAssertEqual(app.secureTextFields["Master passphrase"].frame, place)
    }
}
