import XCTest

/// Steps the UI tests share. The tests run one after another on the same simulator, in any order, so a vault may already exist.
extension XCUIApplication {
    static let testPassword = "Simulator test password 1!"

    /// Creates the vault on a fresh simulator, or unlocks the one an earlier test made.
    func createOrUnlockVault(password: String = XCUIApplication.testPassword) {
        let create = buttons["Create vault"]
        XCTAssertTrue(secureTextFields.firstMatch.waitForExistence(timeout: 15), debugDescription)
        if create.exists {
            secureTextFields["Master passphrase"].tap()
            secureTextFields["Master passphrase"].typeText(password)
            secureTextFields["Repeat passphrase"].tap()
            secureTextFields["Repeat passphrase"].typeText(password)
            let consent = switches.firstMatch
            consent.tap()
            // SwiftUI exposes both the labelled container and its native switch. On runtimes where tapping the label only scrolls it
            // into view, hit the control.
            if consent.value as? String != "1" { consent.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
            XCTAssertEqual(consent.value as? String, "1")
            create.tap()
        } else {
            let field = secureTextFields.firstMatch
            field.tap(); field.typeText(password)
            buttons.matching(NSPredicate(format: "label IN %@", ["Unlock vault", "解锁保险库", "解鎖保險庫"])).firstMatch.tap()
        }
    }

    /// Swipes the frontmost list up until `element` is on screen. A list makes its rows only as they scroll into view, so a row
    /// further down does not exist until then: waiting for it first fails.
    @discardableResult func scrollUntilHittable(_ element: XCUIElement, swipes: Int = 10) -> Bool {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return true }
            swipeUp()
        }
        return element.exists && element.isHittable
    }
}
