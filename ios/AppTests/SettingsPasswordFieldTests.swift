import XCTest
import SwiftUI
import UIKit
@testable import PassVault

@MainActor final class SettingsPasswordFieldTests: XCTestCase {
    func testEyeShowsAndHidesWithoutLosingTheText() {
        var password = "Simulator test password 1!"
        let controller = SettingsPasswordField.Controller(text: Binding(get: { password }, set: { password = $0 }))
        controller.loadViewIfNeeded()
        let field = controller.field, eye = controller.box.eye
        XCTAssertTrue(controller.view === controller.box)
        XCTAssertTrue(field.isSecureTextEntry, "starts hidden")
        XCTAssertEqual(eye.accessibilityLabel, "Show password")

        eye.sendActions(for: .touchUpInside)
        XCTAssertFalse(field.isSecureTextEntry)
        XCTAssertEqual(field.text, "Simulator test password 1!")
        XCTAssertEqual(eye.accessibilityLabel, "Hide password")

        eye.sendActions(for: .touchUpInside)
        XCTAssertTrue(field.isSecureTextEntry)
        XCTAssertEqual(field.text, "Simulator test password 1!")
        XCTAssertEqual(password, "Simulator test password 1!")
        XCTAssertEqual(eye.accessibilityLabel, "Show password")
    }

    /// The eye changes the same field in place: it keeps the keyboard, its text and its place, so the form does not jump.
    func testTheEyeKeepsTheSameFieldFocusedAndInPlace() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
        let box = PasswordBox()
        box.frame = CGRect(x: 16, y: 300, width: 358, height: 44)
        host.view.addSubview(box); box.layoutIfNeeded()
        let field = box.field
        XCTAssertTrue(field.becomeFirstResponder())
        field.insertText("abc")
        let frame = field.convert(field.bounds, to: window)
        box.eye.sendActions(for: .touchUpInside)
        XCTAssertTrue(box.field === field && field.isFirstResponder && !field.isSecureTextEntry)
        XCTAssertEqual(field.convert(field.bounds, to: window), frame)
        field.insertText("d")
        box.eye.sendActions(for: .touchUpInside)
        XCTAssertTrue(field.isFirstResponder && field.isSecureTextEntry)
        // Typing on after hiding again adds to the text instead of replacing it.
        field.insertText("e")
        XCTAssertEqual(field.text, "abcde")
        window.isHidden = true
    }
}
