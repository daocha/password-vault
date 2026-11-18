import XCTest
import UIKit
import VaultCore
@testable import PassVault

@MainActor final class BackupShareSheetTests: XCTestCase {
    func testTheSheetKeepsAirDropAndDropsMailMessagesAndCopy() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("share-test.pvault")
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        var result: Bool?
        let sheet = BackupShareSheet.controller(for: file) { result = $0 }
        let excluded = Set(sheet.excludedActivityTypes ?? [])
        // The raw strings in VaultCore are Apple's real constants.
        for kind in [UIActivity.ActivityType.mail, .message, .copyToPasteboard, .print, .assignToContact, .saveToCameraRoll, .addToReadingList, .markupAsPDF, .openInIBooks] {
            XCTAssertTrue(excluded.contains(kind), kind.rawValue)
        }
        XCTAssertFalse(excluded.contains(.airDrop))
        XCTAssertEqual(UIActivity.ActivityType.airDrop.rawValue, BackupShare.airDrop)
        sheet.completionWithItemsHandler?(.airDrop, true, nil, nil)
        XCTAssertEqual(result, true)
    }
}
