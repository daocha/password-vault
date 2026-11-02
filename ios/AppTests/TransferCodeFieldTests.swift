import XCTest
import SwiftUI
import UIKit
import VaultCore
@testable import PassVault

@MainActor final class TransferCodeFieldTests: XCTestCase {
    func testTypingWithoutDashesUpdatesNativeTextAndDecrypts() throws {
        var code = ""
        let coordinator = TransferCodeField.Coordinator(code: Binding(get: { code }, set: { code = $0 }))
        let field = UITextField()
        let input = "7k4p92xmqd3f"
        for (index, character) in input.enumerated() {
            XCTAssertFalse(coordinator.textField(field, shouldChangeCharactersIn: NSRange(location: (field.text ?? "").utf16.count, length: 0), replacementString: String(character)))
            XCTAssertEqual(field.text, Transfer.typingShown(String(input.prefix(index + 1)).uppercased()))
        }
        XCTAssertEqual(code, "7K4P92XMQD3F")
        let records = [VaultRecord()]
        let data = try Transfer.seal(records, code: code)
        XCTAssertEqual(try Transfer.open(data, code: code), records)
        XCTAssertEqual(try Transfer.open(data, code: XCTUnwrap(field.text)), records)
    }

    func testPasteBackspaceAndMiddleReplacement() {
        var code = ""
        let coordinator = TransferCodeField.Coordinator(code: Binding(get: { code }, set: { code = $0 }))
        let field = UITextField()
        func edit(_ range: NSRange, _ replacement: String) {
            XCTAssertFalse(coordinator.textField(field, shouldChangeCharactersIn: range, replacementString: replacement))
        }
        edit(NSRange(location: 0, length: 0), "7k4p-92xm qd3f")
        XCTAssertEqual(field.text, "7K4P-92XM-QD3F")
        XCTAssertEqual(code, "7K4P92XMQD3F")
        edit(NSRange(location: 4, length: 1), "")
        XCTAssertEqual(field.text, "7K49-2XMQ-D3F")
        XCTAssertEqual(code, "7K492XMQD3F")
        edit(NSRange(location: 0, length: (field.text ?? "").utf16.count), "fm96")
        XCTAssertEqual(field.text, "FM96-")
        edit(NSRange(location: 4, length: 1), "")
        XCTAssertEqual(field.text, "FM9")
        edit(NSRange(location: 1, length: 1), "k")
        XCTAssertEqual(field.text, "FK9")
    }
}
