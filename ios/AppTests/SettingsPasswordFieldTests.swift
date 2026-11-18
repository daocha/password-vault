import XCTest
import SwiftUI
import UIKit
@testable import PassVault

@MainActor final class SettingsPasswordFieldTests: XCTestCase {
    func testEyeShowsAndHidesWithoutLosingTheText() {
        var password = "Simulator test password 1!"
        let controller = SettingsPasswordField.Controller(text: Binding(get: { password }, set: { password = $0 }))
        controller.loadViewIfNeeded()
        let field = controller.field
        XCTAssertTrue(field.isSecureTextEntry, "starts hidden")
        XCTAssertTrue(field.rightView === controller.eye)
        XCTAssertEqual(field.rightViewMode, .always)
        XCTAssertEqual(controller.eye.accessibilityLabel, "Show password")

        controller.eye.sendActions(for: .touchUpInside)
        XCTAssertFalse(field.isSecureTextEntry)
        XCTAssertEqual(field.text, "Simulator test password 1!")
        XCTAssertEqual(controller.eye.accessibilityLabel, "Hide password")

        controller.eye.sendActions(for: .touchUpInside)
        XCTAssertTrue(field.isSecureTextEntry)
        XCTAssertEqual(field.text, "Simulator test password 1!")
        XCTAssertEqual(password, "Simulator test password 1!")
        XCTAssertEqual(controller.eye.accessibilityLabel, "Show password")
    }
}
