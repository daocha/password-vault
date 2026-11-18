import Foundation

/**
 Sending an encrypted backup straight to a nearby device. iOS has no AirDrop-only share sheet, so the sheet is trimmed instead: Apple's
 mail, message, note, print, copy and social choices are removed (``excludedActivityTypes``). Other apps' share extensions cannot all be
 removed, so the screen warns to send only to a trusted device. Android offers only Quick Share and the phone makers' nearby-sharing apps.
 */
public enum BackupShare {
    /** Raw `UIActivity.ActivityType` values left out of the share sheet: everything Apple offers except AirDrop. */
    public static let excludedActivityTypes: [String] = [
        "com.apple.UIKit.activity.Mail", "com.apple.UIKit.activity.Message", "com.apple.UIKit.activity.Print",
        "com.apple.UIKit.activity.CopyToPasteboard", "com.apple.UIKit.activity.AssignToContact", "com.apple.UIKit.activity.SaveToCameraRoll",
        "com.apple.UIKit.activity.AddToReadingList", "com.apple.UIKit.activity.OpenInIBooks", "com.apple.UIKit.activity.MarkupAsPDF",
        "com.apple.UIKit.activity.SharePlay", "com.apple.UIKit.activity.CollaborationInviteWithLink", "com.apple.UIKit.activity.CollaborationCopyLink",
        "com.apple.UIKit.activity.PostToFacebook", "com.apple.UIKit.activity.PostToTwitter", "com.apple.UIKit.activity.PostToWeibo",
        "com.apple.UIKit.activity.TencentWeibo", "com.apple.UIKit.activity.PostToFlickr", "com.apple.UIKit.activity.PostToVimeo",
        // Apple's own share extensions: Notes, Reminders, Freeform, shared albums and Save to Files (the dialog already offers Save).
        "com.apple.mobilenotes.SharingExtension", "com.apple.reminders.sharingextension", "com.apple.freeform.sharingextension",
        "com.apple.mobileslideshow.StreamShareService", "com.apple.DocumentManagerUICore.SaveToFiles",
    ]
    public static let airDrop = "com.apple.UIKit.activity.AirDrop"

    public static let folderName = "backup-share"
    public static func folder(in temporary: URL) -> URL { temporary.appendingPathComponent(folderName, isDirectory: true) }

    /** Removes earlier copies and writes `data` as `name` (no folders), readable only while the phone is unlocked. */
    public static func write(_ data: Data, name: String, in temporary: URL) throws -> URL {
        sweep(in: temporary)
        let folder = folder(in: temporary)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent((name as NSString).lastPathComponent)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        return file
    }
    /** Deletes every copy; true when none is left. */
    @discardableResult public static func sweep(in temporary: URL) -> Bool {
        let folder = folder(in: temporary)
        try? FileManager.default.removeItem(at: folder)
        return !FileManager.default.fileExists(atPath: folder.path)
    }
}
