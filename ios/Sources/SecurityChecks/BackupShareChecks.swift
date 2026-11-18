import Foundation
import VaultCore

/// Sending a backup to a nearby device (see BackupShareTests).
func backupShareChecks() throws {
    let excluded = Set(BackupShare.excludedActivityTypes)
    try check(!excluded.contains(BackupShare.airDrop) && excluded.contains("com.apple.UIKit.activity.Mail") && excluded.contains("com.apple.UIKit.activity.Message")
              && excluded.contains("com.apple.UIKit.activity.CopyToPasteboard"), "share sheet keeps AirDrop and drops mail, messages and copy")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let first = try BackupShare.write(Data([1]), name: "a.pvault", in: temporary)
    let second = try BackupShare.write(Data([2]), name: "../b.pvault", in: temporary)
    try check(!FileManager.default.fileExists(atPath: first.path) && second.deletingLastPathComponent().lastPathComponent == BackupShare.folderName, "one shared copy at a time, inside its folder")
    try check(BackupShare.sweep(in: temporary) && !FileManager.default.fileExists(atPath: second.path), "shared copies are swept")
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PassVault")
    let source = try String(contentsOf: app.appendingPathComponent("PassVaultApp.swift"), encoding: .utf8)
    try check(source.contains("if isCSV { exporting = true } else { choosingDestination = true }"), "CSV exports are never sent")
    let sheet = try String(contentsOf: app.appendingPathComponent("BackupShareSheet.swift"), encoding: .utf8)
    try check(sheet.contains("sheet.excludedActivityTypes = BackupShare.excludedActivityTypes"), "the share sheet is trimmed")
}
