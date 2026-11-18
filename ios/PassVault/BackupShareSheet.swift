import SwiftUI
import UIKit
import VaultCore

/// Presents the trimmed share sheet for one backup copy (see ``BackupShare``). `done(true)` when the user completed a share.
@MainActor enum BackupShareSheet {
    static func controller(for file: URL, done: @escaping (Bool) -> Void) -> UIActivityViewController {
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.excludedActivityTypes = BackupShare.excludedActivityTypes.map(UIActivity.ActivityType.init(rawValue:))
        sheet.completionWithItemsHandler = { _, completed, _, _ in done(completed) }
        return sheet
    }

    /// Shown over whatever is on screen (the export settings sheet); on iPad it points at the middle of that screen.
    static func present(_ file: URL, done: @escaping (Bool) -> Void) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { done(false); return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let sheet = controller(for: file, done: done)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
}
