import UIKit
import VaultCore

/// Writes automatic backups off the main thread, one at a time, and keeps running for a while after the app leaves the screen.
enum AutoBackupWriter {
    private static let queue = DispatchQueue(label: "PassVault.auto-backup", qos: .utility)

    /// Writes `export` to the bookmarked folder (see `AutoBackupFiles.save`); `done` runs on the main thread with whether it was saved.
    @MainActor static func write(_ export: VaultExport, digest: Data, bookmark: Data, settings: AutoBackupSettings, defaults: UserDefaults, force: Bool,
                                 done: @escaping @MainActor (Bool) -> Void) {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "PassVault automatic backup") {
            UIApplication.shared.endBackgroundTask(task); task = .invalid
        }
        queue.async {
            var stale = false
            let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let access = folder?.startAccessingSecurityScopedResource() ?? false
            defer { if access { folder?.stopAccessingSecurityScopedResource() } }
            if stale, let fresh = try? folder?.bookmarkData() { settings.refresh(folderBookmark: fresh) }
            let saved = AutoBackupFiles.save(export, digest: digest, to: folder, settings: settings, defaults: defaults, force: force)
            Task { @MainActor in
                done(saved)
                if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
            }
        }
    }
}
