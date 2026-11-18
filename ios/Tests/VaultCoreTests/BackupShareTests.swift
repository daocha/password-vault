import Foundation
import XCTest
@testable import VaultCore

final class BackupShareTests: XCTestCase {
    func testTheShareSheetKeepsAirDropAndDropsMailChatAndCopy() {
        let excluded = Set(BackupShare.excludedActivityTypes)
        XCTAssertEqual(excluded.count, BackupShare.excludedActivityTypes.count, "no duplicates")
        XCTAssertFalse(excluded.contains(BackupShare.airDrop))
        for kind in ["Mail", "Message", "CopyToPasteboard", "Print", "SaveToCameraRoll", "AssignToContact"] {
            XCTAssertTrue(excluded.contains("com.apple.UIKit.activity.\(kind)"), kind)
        }
        XCTAssertTrue(excluded.contains("com.apple.mobilenotes.SharingExtension"))
        XCTAssertTrue(excluded.contains("com.apple.DocumentManagerUICore.SaveToFiles"), "Save is its own choice")
    }

    func testTheSharedCopyIsReplacedAndSweptAway() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let first = try BackupShare.write(Data([1, 2, 3]), name: "passvault_2026-11-19_10_00.pvault", in: temporary)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, BackupShare.folderName)
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        // Each send replaces the earlier copy, and a name cannot climb out of the shared folder.
        let second = try BackupShare.write(Data([4]), name: "../escape.pvault", in: temporary)
        XCTAssertEqual(second.lastPathComponent, "escape.pvault")
        XCTAssertEqual(second.deletingLastPathComponent().lastPathComponent, BackupShare.folderName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("escape.pvault").path))
        XCTAssertTrue(BackupShare.sweep(in: temporary))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(BackupShare.sweep(in: temporary.appendingPathComponent("missing")))
    }

    func testTheChoiceIsTranslatedAndOfferedForEncryptedBackupsOnly() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PassVault")
        let source = try String(contentsOf: app.appendingPathComponent("PassVaultApp.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if isCSV { exporting = true } else { choosingDestination = true }"), "CSV is never sent")
        XCTAssertTrue(source.contains("if completed { model.recordBackup(exported)"), "only a completed send counts as a backup")
        let keys = ["Save or send this backup?", "Save to Files", "Send to a nearby device", "Encrypted backup sent.",
                    "Send it only to a device you own or trust, with AirDrop. Anyone who gets this file can keep trying to guess your app password."]
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let data = try Data(contentsOf: app.appendingPathComponent("\(language).lproj/Localizable.strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for key in keys { XCTAssertNotNil(table[key], "\(language) lacks \(key)") }
        }
    }
}
