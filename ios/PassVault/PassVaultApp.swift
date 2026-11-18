import SwiftUI
import UIKit
import VaultCore
import UniformTypeIdentifiers
import AuthenticationServices
import AVFoundation

@MainActor final class VaultModel: ObservableObject {
    @Published var records = [VaultRecord]()
    @Published var unlocked = false
    @Published var exists = true
    @Published var busy = false
    /// The message over the vault: closes with OK or by itself, like Android's snackbar (see `StatusMessage`).
    @Published private(set) var status = StatusMessage()
    var message: String { status.text }
    /// How long a message stays up; tests shorten it.
    var messageSeconds = StatusMessage.displaySeconds
    /// Debug builds: the last unlock's timing, kept in Settings.
    @Published var unlockSummary = ""
    @Published var attempts = 10
    @Published var erased = false
    /// When the last encrypted backup was saved, and the reminder settings. Ordinary preferences: only times and a choice, no secrets.
    @Published var lastBackup: Date?
    @Published var backupIntervalDays = 30
    @Published var backupSnoozedUntil: Date?
    @Published var backupSnapshotAt: Date?
    let backupPreferences: UserDefaults
    private var backups: BackupStatus { BackupStatus(defaults: backupPreferences, decoy: decoy) }
    @Published var biometricEnabled = false
    /// Whether the vault is where the AutoFill extension can open it (`KeychainStorage.shared`).
    private(set) var autofillReady = false
    /// The decoy vault is open: settings that would reveal or touch the real vault are not shown.
    @Published var decoy = false
    @Published var hasDecoy = false
    /// Whether the real vault can give the decoy a new password (decoys from earlier test builds cannot).
    @Published var canResetDecoy = false
    /// The transfer being sent, if any; it survives a lock for a while so its code is still there after sharing the file from another app.
    @Published var sending: TransferPayload?
    private var backgroundedAt: Date?
    private(set) var engine: VaultEngine? = nil
    private var generation = 0
    private var pendingLock: Task<Bool, Never>?
    private var biometricAutoPrompted = false
    private var protectedDataAvailable = true
    private var deviceLockHandled = false
    init(engine suppliedEngine: VaultEngine? = nil, defaults: UserDefaults = .standard) {
        backupPreferences = defaults
        var initialized: VaultEngine?
        do {
            let storage = suppliedEngine == nil ? try KeychainStorage(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                                                                     keepAlive: BackgroundHold.hold, reason: BackgroundHold.unlockReason) : nil
            let engine = try suppliedEngine ?? VaultEngine(storage: storage!)
            initialized = engine; autofillReady = storage?.shared ?? false
            exists = try engine.exists(); attempts = try engine.remainingAttempts()
            biometricEnabled = (try? engine.biometricsEnabled()) ?? false
        } catch { show(error.localizedDescription) }
        engine = initialized
        erased = (try? initialized?.isErased()) ?? false
        loadBackupStatus()
        // A backup copy left from sending one before the app was closed.
        BackupShare.sweep(in: FileManager.default.temporaryDirectory)
    }
    func loadBackupStatus() {
        lastBackup = backups.lastBackup; backupSnapshotAt = backups.snapshotAt
        backupIntervalDays = backups.intervalDays; backupSnoozedUntil = backups.snoozedUntil
    }
    /// Only a saved encrypted backup counts: CSV leaves out 2FA keys, cards and notes.
    func recordBackup(_ exported: VaultExport) {
        exported.recordBackup(defaults: backupPreferences); loadBackupStatus()
    }
    /// The removed decoy's backup history and reminder choice.
    func forgetDecoyBackups() { BackupStatus(defaults: backupPreferences, decoy: true).clear(); AutoBackupSettings(defaults: backupPreferences, decoy: true).clear(); autoBackupRevision += 1 }
    /// The open vault's automatic backup settings (the decoy has its own).
    var autoBackups: AutoBackupSettings { AutoBackupSettings(defaults: backupPreferences, decoy: decoy) }
    /// Bumped whenever automatic backup settings or results change, so Settings shows them.
    @Published var autoBackupRevision = 0
    private var autoBackupTimer: Task<Void, Never>?
    /// The result of a backup the user asked for (Back up now, or the first one after choosing the folder), shown as an alert.
    struct AutoBackupNotice: Identifiable { let id = UUID(); let saved: Bool; let text: String }
    @Published var autoBackupNotice: AutoBackupNotice?
    /// Settings → Last encrypted backup with automatic backup on: the newest backups in its folder (`AutoBackupFiles.newest`).
    struct RecentBackups: Identifiable { let id = UUID(); let folder: String; let names: [String] }
    @Published var recentBackups: RecentBackups?
    /// Lists the newest automatic backups in the folder, or says PassVault cannot open it (access lost, folder gone). `done` runs when it is shown.
    func showRecentBackups(done: (() -> Void)? = nil) {
        let settings = autoBackups
        guard unlocked, settings.enabled, let bookmark = settings.folderBookmark else { return }
        let current = generation, name = settings.name
        Task {
            let names = await Task.detached { () -> [String]? in
                var stale = false
                guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                return try? AutoBackupFiles.newest(in: folder)
            }.value
            guard generation == current, unlocked else { return }
            if let names { recentBackups = RecentBackups(folder: name, names: names) }
            else { show(localizedFormat("PassVault cannot open the folder %@. Choose it again in Automatic backup.", name)) }
            done?()
        }
    }
    func autoBackupProblem(_ settings: AutoBackupSettings) -> String {
        switch settings.problem {
        case .keyGone?: localized("Paused: your app password changed. Choose the folder again to resume.")
        case .noAccess?: localizedFormat("Paused: PassVault can no longer open %@. Choose the folder again.", settings.name)
        default: localized("The last automatic backup could not be saved. PassVault tries again next time.")
        }
    }
    /// Saves an automatic backup of the open vault if it changed since the last one (`force`: even if not). Encrypts here (milliseconds:
    /// the key was derived when it was set up), so a lock right after still finds the vault open; the file is written in the background.
    func autoBackup(force: Bool = false, announce: Bool = false) {
        autoBackupTimer?.cancel(); autoBackupTimer = nil
        guard unlocked, let engine else { return }
        let settings = autoBackups
        guard settings.enabled, let sealed = settings.sealedKey, let bookmark = settings.folderBookmark else { return }
        if !force && (busy || settings.problem == .keyGone) { return }
        if !force && scheduleAutoBackup(settings) { return }
        let defaults = backupPreferences
        guard let result = try? engine.exportAutomatic(sealedKey: sealed, lastDigest: settings.lastDigest, force: force, instance: { BackupStatus(defaults: defaults, decoy: $0).instance }) else { return }
        switch result {
        case .unchanged: break
        case .keyGone:
            settings.failed(.keyGone); autoBackupRevision += 1
            if announce { autoBackupNotice = AutoBackupNotice(saved: false, text: autoBackupProblem(settings)) }
        case .ready(let export, let digest):
            let current = generation
            AutoBackupWriter.write(export, digest: digest, bookmark: bookmark, settings: settings, defaults: defaults, force: force) { [weak self] saved in
                guard let self else { return }
                self.loadBackupStatus(); self.autoBackupRevision += 1
                guard current == self.generation, self.unlocked else { return }
                self.scheduleAutoBackup(settings)
                if announce {
                    // Asked for: confirm in an alert, saved or not.
                    let at = settings.lastAutomatic?.formatted(date: .abbreviated, time: .standard) ?? ""
                    self.autoBackupNotice = AutoBackupNotice(saved: saved, text: saved ? localizedFormat("Saved to %@ at %@.", settings.name, at) : self.autoBackupProblem(settings))
                } else if !saved {
                    // On its own (locking, leaving): only a failure is mentioned.
                    self.show(self.autoBackupProblem(settings))
                }
            }
        }
    }
    /// Recheck at the interval boundary while unlocked. A locked or suspended app catches up on its next unlock or foreground visit.
    @discardableResult private func scheduleAutoBackup(_ settings: AutoBackupSettings) -> Bool {
        autoBackupTimer?.cancel(); autoBackupTimer = nil
        let wait = settings.remaining()
        guard unlocked, settings.enabled, settings.problem != .keyGone, wait > 0 else { return false }
        autoBackupTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } catch { return }
            self?.autoBackup()
        }
        return true
    }
    func setAutoBackupFrequency(_ frequency: AutoBackupFrequency) {
        autoBackups.frequency = frequency; autoBackupRevision += 1
        autoBackup()
    }
    func turnOffAutoBackup() {
        autoBackups.clear(); autoBackupRevision += 1
        autoBackupTimer?.cancel(); autoBackupTimer = nil
    }
    func snoozeBackup() { backups.snoozedUntil = Date().addingTimeInterval(Double(BackupReminder.snoozeDays) * 86400); loadBackupStatus() }
    func setBackupInterval(_ days: Int) { backups.intervalDays = days; loadBackupStatus() }
    var backupDue: Bool { BackupReminder.due(records, lastBackup: lastBackup, intervalDays: backupIntervalDays, snoozedUntil: backupSnoozedUntil, snapshotAt: backupSnapshotAt) }
    func lock() {
        autoBackup()
        autoBackupTimer?.cancel(); autoBackupTimer = nil
        SecretClipboard.clearOnLock(); backgroundedAt = nil
        generation += 1; unlocked = false; records = []; decoy = false; hasDecoy = false; canResetDecoy = false; recentBackups = nil
        if let sending, Date() >= sending.expiresAt { self.sending = nil }
        loadBackupStatus()
        let engine = engine
        let current = generation, previousLock = pendingLock
        let locking = Task.detached {
            _ = await previousLock?.value
            engine?.lock()
            return (try? engine?.biometricsEnabled()) ?? false
        }
        pendingLock = locking
        Task {
            let enabled = await locking.value
            if generation == current && !unlocked { biometricEnabled = enabled }
        }
    }
    func run(_ work: @escaping @Sendable (VaultEngine) throws -> [VaultRecord]?, done: (() -> Void)? = nil) {
        guard !busy, let engine else { return }
        busy = true; dismissMessage(); let current = generation, locking = pendingLock
        Task {
            var completed = false
            do {
                let result = try await Task.detached { _ = await locking?.value; return try work(engine) }.value
                guard generation == current else {
                    engine.lock()
                    // Creation may have committed while we left the app. Keep its result off screen,
                    // but refresh the locked screen so it does not offer to create a second vault.
                    exists = (try? engine.exists()) ?? exists
                    attempts = (try? engine.remainingAttempts()) ?? attempts
                    erased = (try? engine.isErased()) ?? erased
                    busy = false; return
                }
                if let result {
                    records = result; unlocked = true; exists = true
                    // Each vault keeps its own backup history, so the decoy shows only its own.
                    decoy = engine.isDecoy(); hasDecoy = (try? engine.hasDecoy()) ?? false; canResetDecoy = (try? engine.canResetDecoy()) ?? false; loadBackupStatus()
                    // Only the vault that made a pending transfer may see it again.
                    if let sending, sending.decoy != decoy || Date() >= sending.expiresAt { self.sending = nil }
                }
                biometricEnabled = (try? engine.biometricsEnabled()) ?? false
                attempts = try engine.remainingAttempts(); done?(); completed = true
            } catch { failed(error) }
            busy = false
            if completed { autoBackup() }
        }
    }
    /// A failed action: its message, and the attempts left. As on Android, a wrong password in an open vault leaves it open (the attempt
    /// is still counted); only an unlock that failed, or the erasure after the tenth wrong password, shows the lock screen.
    func failed(_ error: Error) {
        let closed = !unlocked || !(engine?.isUnlocked() ?? false)
        if closed { lock() }
        attempts = (try? engine?.remainingAttempts()) ?? 0
        erased = (try? engine?.isErased()) ?? false
        show(Self.failureMessage(error, attempts: attempts, erased: erased))
    }
    /// The message for a failed action, in the app's language. A wrong app password says how many attempts are left, as on Android.
    static func failureMessage(_ error: Error, attempts: Int, erased: Bool) -> String {
        if case VaultError.authentication? = error as? VaultError, !erased { return localizedFormat("Incorrect password. %lld attempts left before this vault is erased.", attempts) }
        return localizedError(error)
    }
    /// The app left the screen: lock now, or note the time so a later return can lock once the chosen delay has passed.
    func didEnterBackground() {
        biometricAutoPrompted = false
        // A password or biometric unlock can still be running. Invalidate it even though
        // there is no visible session yet, as Android does when its activity stops.
        guard unlocked else { if busy { lock() }; return }
        // Leaving the app saves changes to the automatic backup folder now, in case the app is closed before it locks.
        autoBackup()
        switch AppSettings.shared.autoLock.delay {
        case 0?: lock()
        case nil: break // Only locking the device does it.
        default: backgroundedAt = Date()
        }
    }
    func didBecomeActive(protectedDataAvailable: Bool = true) {
        guard protectedDataAvailable else { deviceDidLock(); return }
        self.protectedDataAvailable = true
        deviceLockHandled = false
        if unlocked, let since = backgroundedAt, let delay = AppSettings.shared.autoLock.delay, Date().timeIntervalSince(since) >= delay { lock() }
        backgroundedAt = nil
        autoUnlockWithBiometrics()
        autoBackup()
    }
    /// Whether VoiceOver or Switch Control is on: messages then stay until OK. Tests replace it.
    var assistiveTechnology: () -> Bool = { UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning }
    /// Shows `text` (a localization key or an error's own text) until OK or `messageSeconds` pass. VoiceOver reads it out.
    func show(_ text: String, error: Bool = true) {
        let serial = status.show(text, error: error)
        guard !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: localized(text))
        guard StatusMessage.displayTime(assistiveTechnology: assistiveTechnology()) != nil else { return }
        let seconds = messageSeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.status.expire(serial)
        }
    }
    func dismissMessage() { status.dismiss() }
    /// Debug builds: keep how long the unlock took and where in Settings → Last unlock. Release builds record nothing.
    /// The engine's own timing, plus everything until the vault is on screen (the status checks that follow the unlock).
    func recordUnlockTiming(since started: UInt64) {
        #if DEBUG
        guard let timing = engine?.lastUnlockTiming else { return }
        unlockSummary = "\(timing); vault shown after \((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) ms"
        print("PassVault: \(unlockSummary)")
        #endif
    }
    func autoUnlockWithBiometrics() {
        // Face ID can make the scene inactive and active again. Attempt only once per foreground visit,
        // so cancelling (or falling back to the app password) never immediately opens another prompt.
        guard protectedDataAvailable, exists, !erased, !unlocked, !busy, biometricEnabled, !biometricAutoPrompted else { return }
        biometricAutoPrompted = true
        let started = DispatchTime.now().uptimeNanoseconds
        run({ try $0.unlockBiometric() }, done: { [weak self] in self?.recordUnlockTiming(since: started) })
    }
    /// A device lock always overrides the background delay, as screen-off does on Android.
    func deviceDidLock() {
        protectedDataAvailable = false
        guard !deviceLockHandled else { return }
        deviceLockHandled = true
        biometricAutoPrompted = false
        sending = nil; lock()
    }
    /// A suspended app may miss the unavailable event. Availability returning is also evidence of a
    /// device-lock cycle: discard the retained session before resuming, regardless of the timeout.
    func deviceDidUnlock() {
        if !deviceLockHandled { deviceDidLock() }
        protectedDataAvailable = true
        deviceLockHandled = false
    }
    func resetErased() {
        guard let engine else { return }
        do {
            try engine.resetErasedVault()
            BackupStatus(defaults: backupPreferences).clear(); AutoBackupSettings(defaults: backupPreferences).clear(); forgetDecoyBackups(); loadBackupStatus()
            BackupShare.sweep(in: FileManager.default.temporaryDirectory)
            biometricEnabled = false; erased = false; exists = false; attempts = 10; show("Create a new vault, then import your backup.", error: false)
        }
        catch { show(error.localizedDescription) }
    }
}

/// Keeps the app running in the background while it holds the lock it shares with AutoFill: iOS stops an app that is suspended while
/// holding a lock on a file in a shared container. Called on the vault's queue while the engine is busy, so it never waits for the main
/// thread (which may be waiting for the engine): it asks the main queue, which runs the requests in order.
enum BackgroundHold {
    @MainActor private static var task = UIBackgroundTaskIdentifier.invalid
    static func hold(_ on: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if on { if task == .invalid { task = UIApplication.shared.beginBackgroundTask(withName: "PassVault vault") { end() } } } else { end() }
            }
        }
    }
    @MainActor private static func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task); task = .invalid
    }
    /// What Face ID or Touch ID shows when it unlocks the vault, in the language chosen in PassVault (read off the main thread).
    static func unlockReason() -> String {
        AppearancePreferences().language.bundle().localizedString(forKey: "Unlock your password vault", value: nil, table: nil)
    }
}

/// Third-party keyboards could log revealed passwords and notes typed into ordinary text fields; only the system keyboard is allowed.
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var model: VaultModel?

    func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
        model?.deviceDidLock()
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        model?.deviceDidUnlock()
        if application.applicationState == .active {
            model?.didBecomeActive(protectedDataAvailable: application.isProtectedDataAvailable)
        }
    }

    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}

/// App-switcher privacy cover in its own window above everything, so it also hides sheets (which SwiftUI presents above any overlay).
@MainActor enum PrivacyCover {
    private static var windows = [UIWindow]()
    static func show() {
        guard windows.isEmpty else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: Color(red: 0.025, green: 0.07, blue: 0.18).ignoresSafeArea().overlay { Image(systemName: "lock.fill").font(.system(size: 56)).foregroundStyle(.white) })
            window.isHidden = false
            windows.append(window)
        }
    }
    static func hide() { windows.forEach { $0.isHidden = true }; windows.removeAll() }
}

@main struct PassVaultApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = VaultModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            LocalizedVaultRoot().environmentObject(model)
                .tint(Color.aPrimary)
                .onAppear {
                    appDelegate.model = model
                    if phase == .active { model.didBecomeActive(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable) }
                }
                .onChange(of: model.biometricEnabled) { _, _ in if phase == .active { model.autoUnlockWithBiometrics() } }
                .onChange(of: model.busy) { _, busy in if phase == .active && !busy { model.autoUnlockWithBiometrics() } }
                .overlay { if phase != .active { Color(red: 0.025, green: 0.07, blue: 0.18).ignoresSafeArea().overlay { Image(systemName: "lock.fill").font(.system(size: 56)).foregroundStyle(.white) } } }
                .onChange(of: phase) { _, phase in
                    if phase == .active { PrivacyCover.hide() } else { PrivacyCover.show() }
                    if phase == .background { model.didEnterBackground() }
                    if phase == .active { model.didBecomeActive(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable); AppSettings.shared.applyInterfaceStyle() }
                }
        }
    }
}

/// Changing language recreates presented screens as Android's activity recreation does.
/// The model remains outside this identity so the open vault and its records are retained.
struct LocalizedVaultRoot: View {
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        VaultRoot()
            .id(settings.language)
            .environment(\.locale, settings.language.locale)
            .preferredColorScheme(settings.colorScheme)
            .onAppear { settings.applyInterfaceStyle() }
    }
}

struct VaultRoot: View {
    @EnvironmentObject var model: VaultModel
    var body: some View {
        Group { if model.unlocked { RecordList() } else { UnlockView() } }
            .safeAreaInset(edge: .bottom) {
                if model.status.isShowing { StatusBanner(status: model.status) { model.dismissMessage() } }
            }
            .overlay { if model.busy { ZStack { Color.black.opacity(0.15).ignoresSafeArea(); ProgressView("Securing your vault…").padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } } }
            .disabled(model.busy)
    }
}

extension View {
    /// The message bar inside a sheet. The vault list's own bar is behind any sheet, so messages from Settings and its panels (a wrong
    /// password, "Encrypted backup exported.") were never seen there.
    func statusBar(_ model: VaultModel) -> some View {
        safeAreaInset(edge: .bottom) { if model.status.isShowing { StatusBanner(status: model.status) { model.dismissMessage() } } }
    }
}

/// The message bar: errors in red with a warning sign, other messages in the normal text color, and OK to close it.
struct StatusBanner: View {
    let status: StatusMessage
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if status.isError { Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true) }
            Text(LocalizedStringKey(status.text)).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Button("OK", action: dismiss).font(.footnote.weight(.semibold)).accessibilityIdentifier("status-dismiss")
        }
        .foregroundStyle(status.isError ? Color.red : Color.primary)
        .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity).background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }
}

struct UnlockView: View {
    @EnvironmentObject var model: VaultModel
    @State private var password = ""
    @State private var confirmation = ""
    @State private var acknowledge = false
    @State private var resetConfirmation = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image("vault_icon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 112, height: 112)
                            .accessibilityLabel("PassVault lock")
                        WordMark().font(.largeTitle.bold())
                        Text("Your passwords. Only on your device.").foregroundStyle(Color.aOnSurfaceVariant)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                }.listRowBackground(Color.clear)
                Section(LocalizedStringKey(model.exists ? "Welcome back" : "Create your private vault")) {
                    if model.erased {
                        Text("The local vault has been erased. You can create a new one and restore an exported backup.")
                        Button("Start a new vault") { resetConfirmation = true }
                    }
                    PasswordInput(label: "Master passphrase", text: $password, contentType: .password)
                    if !model.exists {
                        PasswordInput(label: "Repeat passphrase", text: $confirmation)
                        PasswordMismatch(password: password, repeated: confirmation)
                        Text(localized(VaultCrypto.passwordProblem(password) ?? VaultCrypto.passwordRule) + " " + localized("There is no password reset or cloud recovery.")).font(.footnote)
                        Toggle("I understand: 10 failed password attempts erase the local vault", isOn: $acknowledge)
                    }
                    Button(LocalizedStringKey(model.exists ? "Unlock vault" : "Create vault")) {
                        let value = password; password = ""; confirmation = ""
                        let exists = model.exists
                        let started = DispatchTime.now().uptimeNanoseconds
                        model.run({ engine in try exists ? engine.unlock(password: value) : engine.create(password: value) }, done: { if exists { model.recordUnlockTiming(since: started) } })
                    }.disabled(password.isEmpty || (!model.exists && (!samePassword(password, confirmation) || !acknowledge)))
                    if model.exists {
                        if model.biometricEnabled { Button("Unlock with Face ID / Touch ID", systemImage: "faceid") { let started = DispatchTime.now().uptimeNanoseconds; model.run({ try $0.unlockBiometric() }, done: { model.recordUnlockTiming(since: started) }) } }
                        Text("\(model.attempts) password attempts remaining").font(.footnote).foregroundStyle(Color.aOnSurfaceVariant)
                    }
                }
            }
            .confirmationDialog("Start a new empty vault? Your erased records cannot be recovered without a backup.", isPresented: $resetConfirmation) { Button("Create new vault") { model.resetErased() } }
        }
    }
}

/// The vault keys on the normalized password, so two spellings that normalize alike are the same password.
func samePassword(_ a: String, _ b: String) -> Bool { PasswordText.normalize(a) == PasswordText.normalize(b) }

/// "Passwords don't match." under a repeat field once something is typed in it.
struct PasswordMismatch: View {
    let password: String
    let repeated: String
    var body: some View {
        if !repeated.isEmpty && !samePassword(password, repeated) { Text("Passwords don't match.").font(.footnote).foregroundStyle(.red) }
    }
}

/// "Expired" or "Expires soon" beside a list row; nothing for records without a date or with one further away.
struct ExpiryBadge: View {
    let record: VaultRecord
    var body: some View {
        let state = record.expiryState()
        if state == .expired || state == .soon {
            HStack(spacing: 3) {
                Image(systemName: "calendar").font(.system(size: 11))
                Text(LocalizedStringKey(state == .expired ? "Expired" : "Expires soon")).font(.caption2.weight(.medium))
            }
            .foregroundStyle(.red).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

func groupColor(_ name: String) -> Color { let c = groupColorRGB(name); return Color(red: c.r, green: c.g, blue: c.b) }

/// A group's name in its own color: colored border, a light tint behind the text, and the normal text color so contrast holds in light and dark mode.
struct GroupTag: View {
    let name: String
    var large = false
    @ScaledMetric(relativeTo: .caption2) private var fontSize = 11.0
    @ScaledMetric(relativeTo: .footnote) private var largeFontSize = 14.0
    var body: some View {
        let tint = groupColor(name), radius: CGFloat = large ? 8 : 6
        Text(name.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: large ? largeFontSize : fontSize, weight: .medium)).foregroundStyle(Color.aOnSurface).lineLimit(1)
            .padding(.horizontal, large ? 10 : 6).padding(.vertical, large ? 4 : 1)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(tint, lineWidth: 1))
    }
}

/// "Pass" in the normal text color and "Vault" in the brand blue, a shade deeper in light mode so it keeps its contrast.
struct WordMark: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text("Pass") + Text("Vault").foregroundColor(scheme == .dark ? Color(red: 0.30, green: 0.70, blue: 1.0) : Color(red: 0.12, green: 0.47, blue: 0.80))
    }
}

/// Earlier values of a password, newest change first. Imported from Password Keeper; unrelated to fields the user names "Previous password".
struct PasswordHistoryView: View {
    @ObservedObject private var settings = AppSettings.shared
    let field: VaultField
    @Environment(\.dismiss) var dismiss
    @State private var shown = Set<Int>()
    var body: some View {
        NavigationStack {
            List(Array(field.historyNewestFirst.enumerated()), id: \.offset) { index, change in
                HStack {
                    VStack(alignment: .leading) {
                        Text(change.changedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(change.changedAt)).formatted(date: .abbreviated, time: .shortened) : "Unknown date").font(.caption).foregroundStyle(Color.aOnSurfaceVariant)
                        Text(shown.contains(index) ? change.value : "••••••••••").font(.body.monospaced())
                    }
                    Spacer()
                    Button { if !shown.insert(index).inserted { shown.remove(index) } } label: { Image(systemName: shown.contains(index) ? "eye.slash" : "eye") }.buttonStyle(.borderless).accessibilityLabel(Text(LocalizedStringKey(shown.contains(index) ? "Hide" : "Reveal")))
                    if settings.allowCopy { Button { SecretClipboard.copy(change.value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).accessibilityLabel("Copy earlier password") }
                }
            }.navigationTitle("Password history \(field.label)").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .commaSeparatedText] }
    var data: Data
    var exported: VaultExport?
    init(data: Data, exported: VaultExport? = nil) { self.data = data; self.exported = exported }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data(); exported = nil }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
/// One focused settings dialog at a time; passwords are cleared whenever it closes.
private enum VaultSettingsPanel: String, Identifiable {
    case language, autoLock, biometrics, decoy, changePassword, generator, clipboard, backupReminder, send, exportEncrypted, exportCSV, autoBackupSetup, autoBackup, autofill
    var id: String { rawValue }
    var requiresPassword: Bool {
        switch self {
        case .biometrics, .decoy, .changePassword, .send, .exportEncrypted, .exportCSV, .autoBackupSetup: true
        default: false
        }
    }
    var title: String {
        switch self {
        case .language: "Language"
        case .autoLock: "Auto-lock"
        case .biometrics: "Biometric unlock"
        case .decoy: "Decoy vault"
        case .changePassword: "Change app password"
        case .generator: "Password generator"
        case .clipboard: "Clear copied text"
        case .backupReminder: "Backup reminder"
        case .send: "Send to another phone"
        case .exportEncrypted: "Export encrypted backup"
        case .exportCSV: "Export plaintext CSV"
        case .autoBackupSetup, .autoBackup: "Automatic backup"
        case .autofill: "AutoFill"
        }
    }
}

struct TransferView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State private var password = ""
    @State private var csv = false
    @State private var csvConsent = false
    @State private var importing = false
    @State private var exporting = false
    @State private var document: ExportDocument?
    /// An encrypted backup is ready: save it to Files or send it to a nearby device.
    @State private var choosingDestination = false
    /// Automatic backup set up with the app password, waiting for the user to pick the folder.
    @State private var choosingFolder = false
    @State private var pendingAutoKey: Data?
    @State private var pendingImport: [VaultRecord]?
    @State private var receiving = false
    @State private var decoyPassword = ""
    @State private var confirmDecoy = ""
    @State private var removingDecoy = false
    /// An encrypted file (PassVault backup, Password Keeper .pkb2 or KeePass .kdbx) waiting for its password.
    @State private var encryptedImport: EncryptedImport?
    @State private var newPassword = ""
    @State private var confirmNew = ""
    @State private var panel: VaultSettingsPanel?
    @State private var health = false
    /// Vault health opened from Settings keeps to its sheet: its entries open over the report, whatever the width.
    @StateObject private var healthPane = EntryPaneModel(healthSheet: true)
    @State private var healthFlipped: Set<String> = []
    @State private var biometrics = BiometricAvailability.current()
    /// Whether PassVault is turned on in iOS Settings → General → AutoFill & Passwords.
    @State private var autofillOn = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Appearance").font(.footnote.weight(.semibold)).foregroundStyle(Color.aPrimary).textCase(nil)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Theme")
                        Picker("Theme", selection: $settings.theme) {
                            ForEach(AppTheme.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                    settingsRow("Language", icon: "globe", summary: settings.language.label) { open(.language) }
                        .accessibilityIdentifier("settings.language")
                }
                Section(header: Text("Security").font(.footnote.weight(.semibold)).foregroundStyle(Color.aPrimary).textCase(nil)) {
                    settingsRow("Vault health", icon: "checkmark.shield") { health = true }
                    settingsRow("Auto-lock", icon: "timer", summary: settings.autoLock.label) { open(.autoLock) }
                    #if DEBUG
                    // Debug builds only, not translated: where the last unlock's time went, to compare devices.
                    if !model.unlockSummary.isEmpty { settingsRow("Last unlock (debug)", icon: "timer", summary: model.unlockSummary) { model.show(model.unlockSummary, error: false) } }
                    #endif
                    // Without Face ID or Touch ID ready the switch is off and greyed out, saying why, instead of asking for the password first.
                    if !model.decoy {
                        Toggle(isOn: Binding(get: { model.biometricEnabled }, set: { enabled in
                            if enabled { open(.biometrics) }
                            else { model.run { try $0.disableBiometrics(); return nil } }
                        })) {
                            HStack(spacing: 14) {
                                IconBadge(symbol: "faceid", size: 36, tint: .aOnSecondaryContainer, container: .aSecondaryContainer)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Biometric unlock").font(.callout)
                                    Text(LocalizedStringKey(model.biometricEnabled ? "On" : biometrics.offSummary)).font(.caption).foregroundStyle(Color.aOnSurfaceVariant)
                                }
                            }
                        }.disabled(model.busy || !biometrics.canToggle(enabled: model.biometricEnabled)).accessibilityIdentifier("settings.biometrics")
                        .onChange(of: phase) { _, now in if now == .active { biometrics = .current() } }
                    }
                    settingsRow("AutoFill", icon: "rectangle.and.pencil.and.ellipsis", summary: autofillOn ? "PassVault fills logins in other apps and Safari" : "Off. Turn on in iOS Settings to fill logins in other apps and Safari") { open(.autofill) }
                        .accessibilityIdentifier("settings.autofill")
                    settingsRow("Change app password", icon: "key") { open(.changePassword) }
                    if !model.decoy {
                        settingsRow("Decoy vault", icon: "theatermasks", summary: model.hasDecoy ? "On" : "Off") { open(.decoy) }
                    }
                }
                Section(header: Text("Random password").font(.footnote.weight(.semibold)).foregroundStyle(Color.aPrimary).textCase(nil)) {
                    settingsRow("Password generator", icon: "sparkles", summary: localizedFormat("%lld characters", settings.generator.length)) { open(.generator) }
                }
                Section(header: Text("Clipboard").font(.footnote.weight(.semibold)).foregroundStyle(Color.aPrimary).textCase(nil)) {
                    Toggle(isOn: $settings.allowCopy) { Label("Allow copying", systemImage: "doc.on.doc") }
                    if settings.allowCopy {
                        settingsRow("Clear copied text", icon: "timer", summary: settings.clipboardClear.label) { open(.clipboard) }
                        Toggle(isOn: $settings.clearClipboardOnLock) { Label("Clear copied text when the vault locks", systemImage: "lock") }
                    }
                }
                Section {
                    settingsRow("Last encrypted backup", icon: "clock.arrow.circlepath", summary: model.lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never") {
                        // With automatic backup on, the newest backups in its folder; otherwise straight to exporting one.
                        if model.autoBackups.enabled { model.showRecentBackups() } else { open(.exportEncrypted) }
                    }.accessibilityIdentifier("settings.lastBackup")
                    let auto = model.autoBackups
                    settingsRow("Automatic backup", icon: "arrow.triangle.2.circlepath.icloud", summary: !auto.enabled ? "Off" : auto.problem != nil ? model.autoBackupProblem(auto) : localizedFormat("On · %@", auto.name)) {
                        open(auto.enabled ? .autoBackup : .autoBackupSetup)
                    }.id(model.autoBackupRevision)
                    settingsRow("Backup reminder", icon: "bell.badge", summary: backupIntervalLabel(model.backupIntervalDays)) { open(.backupReminder) }
                    settingsRow("Import file", icon: "folder", summary: "Backups and exports from other password managers") { importing = true }
                    settingsRow("Send to another phone", icon: "iphone.and.arrow.forward") { open(.send) }
                    settingsRow("Receive from another phone", icon: "qrcode.viewfinder") { receive() }
                    settingsRow("Export encrypted backup", icon: "lock.doc") { open(.exportEncrypted) }
                    settingsRow("Export plaintext CSV", icon: "doc.text") { open(.exportCSV) }
                } header: { Text("Backup & migration") } footer: {
                    Text("PassVault keeps no cloud copy. Only your own encrypted backups can restore your vault if this phone is lost or reset. CSV leaves out 2FA keys, cards and notes.")
                }
                Section {
                    Text("Local vault erasure follows 10 failed app-password attempts. Copied encrypted backups cannot enforce an attempt limit. Unlocking with the app password or biometrics clears failed attempts.").font(.footnote).foregroundStyle(Color.aOnSurfaceVariant)
                }
            }.scrollContentBackground(.hidden).background(Color.aBackground).navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .task { await refreshAutofill() }
                .onChange(of: phase) { _, now in if now == .active { Task { await refreshAutofill() } } }
                .toolbar { Button("Done") { dismiss() } }
                .statusBar(model)
                .sheet(item: $panel, onDismiss: clearPasswords) { panel in
                    settingsDialog(panel)
                }
                .alert("Recent automatic backups", isPresented: Binding(get: { model.recentBackups != nil }, set: { if !$0 { model.recentBackups = nil } }), presenting: model.recentBackups) { _ in
                    Button("OK") { model.recentBackups = nil }
                } message: { recent in
                    Text(recent.names.isEmpty ? localizedFormat("No automatic backups in %@ yet.", recent.folder)
                         : ([localizedFormat("Newest first, in %@:", recent.folder)] + recent.names).joined(separator: "\n"))
                }
                .sheet(isPresented: $health, onDismiss: { healthPane.state.close(); healthPane.fromHealth = nil; healthFlipped = [] }) { HealthView(focus: nil, pane: healthPane, close: { health = false }, flipped: $healthFlipped) }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                    do {
                        let data = try readPicked(result.get())
                        if Importers.needsPassword(data) { encryptedImport = EncryptedImport(data: data); return }
                        Task {
                            do {
                                let imported = try await Task.detached { try Importers.importPlain(data) }.value
                                if model.unlocked { if imported.isEmpty { model.show("The file contains no records.") } else { pendingImport = imported } }
                            } catch { model.show(error.localizedDescription) }
                        }
                    } catch { model.show(error.localizedDescription) }
                }
                .fullScreenCover(isPresented: $receiving) { TransferReceiveView { data in
                    // Present the code prompt once the scanner has finished closing; SwiftUI drops a sheet shown mid-dismissal.
                    receiving = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { encryptedImport = EncryptedImport(data: data) }
                } }
                .sheet(item: $encryptedImport) { file in DecryptImportView(file: file) { records in encryptedImport = nil; if model.unlocked { pendingImport = records } } }
                .confirmationDialog("Import \(pendingImport?.count ?? 0) records?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
                    Button("Import") { if let records = pendingImport { model.run { try $0.merge(records) } }; pendingImport = nil }
                    Button("Full replacement", role: .destructive) { if let records = pendingImport { model.run { try $0.replaceAll(records) } }; pendingImport = nil }
                    Button("Cancel", role: .cancel) { pendingImport = nil }
                } message: {
                    Text(importMessage)
                }

        }
    }
    private var importMessage: String {
        let explanation = localized("Import: adds new entries and replaces existing entries with the same ID. Entries missing from the file are kept.\n\nFull replacement: the file is the golden source. Entries it does not contain are deleted.")
        return (pendingImport?.contains(where: \.isFileKey) == true ? localized(fileKeyUnsupportedMessage) + "\n\n" : "") + explanation
    }
    private func clearPasswords() {
        password = ""; newPassword = ""; confirmNew = ""; decoyPassword = ""; confirmDecoy = ""; csvConsent = false
        choosingDestination = false; if !exporting { document = nil }
    }

    private func open(_ next: VaultSettingsPanel) {
        clearPasswords()
        csv = next == .exportCSV
        panel = next
    }

    private func backupIntervalLabel(_ days: Int) -> String {
        days == 0 ? "Off" : days == 7 ? "Every week" : days == 14 ? "Every 2 weeks" : "Every month"
    }

    /// A settings row as on Android: the icon in a tinted circle, the title in the normal text colour, the current value under it in the secondary colour.
    /// A plain button style keeps Form from painting the whole row in the tint colour.
    private func settingsRow(_ title: String, icon: String, summary: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Color.aOnSecondaryContainer)
                    .frame(width: 36, height: 36).background(Color.aSecondaryContainer, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title)).font(.callout).foregroundStyle(Color.aOnSurface)
                    if let summary { Text(LocalizedStringKey(summary)).font(.caption).foregroundStyle(Color.aOnSurfaceVariant) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.aOnSurfaceVariant)
            }.padding(.vertical, 2).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func settingsDialog(_ panel: VaultSettingsPanel) -> some View {
        NavigationStack {
            Form {
                if panel.requiresPassword && !choosingDestination {
                    Section("App password") { SettingsPasswordField(text: $password) }
                }
                switch panel {
                case .language:
                    Section {
                        ForEach(AppLanguage.allCases) { language in
                            choice(language.label, selected: settings.language == language) { settings.language = language; self.panel = nil }
                                .accessibilityIdentifier("language.\(language.rawValue)")
                        }
                    }
                case .autoLock:
                    Section {
                        ForEach(AutoLock.allCases) { option in
                            choice(option.label, selected: settings.autoLock == option) { settings.autoLock = option; self.panel = nil }
                        }
                    } footer: { Text("PassVault locks after leaving the app for the selected time, or when the device locks.") }
                case .clipboard:
                    Section {
                        ForEach(ClipboardClear.allCases) { option in
                            choice(option.label, selected: settings.clipboardClear == option) { settings.clipboardClear = option; self.panel = nil }
                        }
                    } footer: { Text("Copied values stay on this device only and are never shared through Universal Clipboard.") }
                case .autoBackupSetup:
                    Section {
                        Button("Choose a folder") { setUpAutoBackup() }.disabled(password.isEmpty)
                    } header: { Text("Automatic backup") } footer: {
                        Text("PassVault saves an encrypted backup after every change by default, to a folder you choose once. You can also choose daily, weekly or monthly backups. Each backup is a new file and opens with your app password. Choose a folder that another app copies off this phone, such as a folder in a trusted cloud drive (iCloud Drive, Google Drive or OneDrive) or on your NAS. PassVault itself never goes online.")
                    }
                case .autoBackup:
                    let auto = model.autoBackups
                    Section {
                        Text(localizedFormat("Saving to the folder %@. Each backup is a new file; older ones stay until you delete them.", auto.name)).font(.footnote)
                        Text(auto.lastAutomatic.map { localizedFormat("Last automatic backup: %@", $0.formatted(date: .abbreviated, time: .shortened)) } ?? localized("No automatic backup saved yet.")).font(.footnote)
                        Picker("Frequency", selection: Binding(get: { auto.frequency }, set: { model.setAutoBackupFrequency($0) })) {
                            Text("Instant").tag(AutoBackupFrequency.instant)
                            Text("Daily").tag(AutoBackupFrequency.daily)
                            Text("Weekly").tag(AutoBackupFrequency.weekly)
                            Text("Monthly").tag(AutoBackupFrequency.monthly)
                        }
                        Text("Instant saves after every change. Daily, weekly and monthly wait 1, 7 or 30 days after the last successful automatic backup. Only changed contents are saved. Backups run while the vault is unlocked; overdue changes are backed up on your next unlock.").font(.footnote)
                        if auto.problem != nil { Text(model.autoBackupProblem(auto)).font(.footnote).foregroundStyle(.red) }
                        if auto.problem != .keyGone { Button("Back up now") { model.autoBackup(force: true, announce: true) } }
                        Button("Choose another folder") { self.panel = .autoBackupSetup }
                        Button("Turn off", role: .destructive) { model.turnOffAutoBackup(); model.show("Automatic backup turned off. Backups already saved are kept.", error: false); self.panel = nil }
                    }.id(model.autoBackupRevision)
                case .autofill:
                    Section {
                        Text("1. Open Settings → General → AutoFill & Passwords and turn on PassVault.")
                        Text("2. In a login form, tap Passwords above the keyboard, then PassVault.")
                        Text("3. Unlock with your app password or Face ID / Touch ID, choose the login and confirm where it goes.")
                        Button("Open AutoFill settings") { Task { try? await ASSettingsHelper.openCredentialProviderAppSettings() } }
                        if !model.autofillReady { Text("AutoFill cannot open your vault yet. Close PassVault and open it again.").font(.footnote).foregroundStyle(.red) }
                    } header: { Text(LocalizedStringKey(autofillOn ? "On" : "Off")) } footer: {
                        Text("PassVault never shows your logins above the keyboard, so usernames and websites stay in the encrypted vault. AutoFill uses the same app password and attempt count as the app, and the vault locks again as soon as a login is filled.")
                    }
                case .backupReminder:
                    Section {
                        ForEach(BackupReminder.intervals, id: \.self) { days in
                            choice(backupIntervalLabel(days), selected: model.backupIntervalDays == days) { model.setBackupInterval(days); self.panel = nil }
                        }
                    } footer: { Text("A reminder appears in the app when a backup is due and something has changed. CSV exports do not count.") }
                case .generator:
                    Section { GeneratorOptionsEditor(options: $settings.generator) } footer: { Text("Defaults for newly generated passwords.") }
                case .biometrics:
                    Section("Biometric unlock") {
                        Button("Enable Face ID / Touch ID") { let value = password; password = ""; model.run({ try $0.enableBiometrics(password: value); return nil }, done: { self.panel = nil }) }.disabled(password.isEmpty)
                    }
                case .decoy:
                    Section {
                        if model.hasDecoy {
                            // A new password for the decoy, for when it is forgotten; what is in the decoy is kept.
                            if model.canResetDecoy {
                                PasswordInput(label: "New decoy password", text: $decoyPassword)
                                PasswordInput(label: "Repeat decoy password", text: $confirmDecoy)
                                PasswordMismatch(password: decoyPassword, repeated: confirmDecoy)
                                if !decoyPassword.isEmpty { Text(LocalizedStringKey(VaultCrypto.passwordProblem(decoyPassword) ?? "Meets the password rules.")).font(.footnote) }
                                Button("Change decoy password") {
                                    let current = password, next = decoyPassword; password = ""; decoyPassword = ""; confirmDecoy = ""
                                    model.run({ try $0.resetDecoyPassword(password: current, decoyPassword: next); return nil }, done: {
                                        // The decoy keeps its data key, so its automatic backups would still use the old decoy password: set them up again.
                                        let decoyBackups = AutoBackupSettings(defaults: model.backupPreferences, decoy: true)
                                        if decoyBackups.enabled { decoyBackups.failed(.keyGone) }
                                        model.show("Decoy password changed.", error: false)
                                    })
                                }.disabled(password.isEmpty || VaultCrypto.passwordProblem(decoyPassword) != nil || !samePassword(decoyPassword, confirmDecoy))
                            } else {
                                Text("This decoy vault was set up by an earlier test version, so its password cannot be changed here. Remove it and set it up again.").font(.footnote)
                            }
                            Button("Remove decoy vault", role: .destructive) { removingDecoy = true }.disabled(password.isEmpty)
                        } else {
                            PasswordInput(label: "Decoy password", text: $decoyPassword)
                            PasswordInput(label: "Repeat decoy password", text: $confirmDecoy)
                            PasswordMismatch(password: decoyPassword, repeated: confirmDecoy)
                            if !decoyPassword.isEmpty { Text(LocalizedStringKey(VaultCrypto.passwordProblem(decoyPassword) ?? "Meets the password rules.")).font(.footnote) }
                            Button("Set up decoy vault") {
                                let current = password, next = decoyPassword; password = ""; decoyPassword = ""; confirmDecoy = ""
                                model.run({ try $0.createDecoy(password: current, decoyPassword: next); return nil }, done: { model.hasDecoy = true; model.canResetDecoy = true; model.show("Decoy vault set up. Lock PassVault and unlock with the decoy password to fill it.", error: false) })
                            }.disabled(password.isEmpty || VaultCrypto.passwordProblem(decoyPassword) != nil || !samePassword(decoyPassword, confirmDecoy))
                        }
                    } header: { Text("Decoy vault") } footer: {
                        Text("A second app password that opens a separate, harmless vault. If someone forces you to unlock PassVault, enter the decoy password: they see only what you put in the decoy vault, and your real entries stay hidden. To fill it, lock PassVault and unlock with the decoy password. This section is not shown inside the decoy vault. Face ID / Touch ID always opens your real vault, so turn it off if you might be made to use it. Someone who knows PassVault well and examines the phone could still tell that a second vault exists.")
                    }
                case .changePassword:
                    Section("Change app password") {
                        PasswordInput(label: "New app password", text: $newPassword)
                        PasswordInput(label: "Repeat new app password", text: $confirmNew)
                        PasswordMismatch(password: newPassword, repeated: confirmNew)
                        Button("Change password") {
                            let current = password, next = newPassword; password = ""; newPassword = ""; confirmNew = ""
                            model.run({ try $0.changePassword(current: current, new: next); return nil }, done: { if model.autoBackups.enabled { model.autoBackups.failed(.keyGone); model.autoBackupRevision += 1 } })
                        }.disabled(password.isEmpty || VaultCrypto.passwordProblem(newPassword) != nil || !samePassword(newPassword, confirmNew))
                        Text(LocalizedStringKey(model.decoy ? "Existing exported backups keep their original password." : "Existing exported backups keep their original password. Changing it turns off Face ID / Touch ID; enable it again in Settings.")).font(.footnote)
                    }
                case .send:
                    Section {
                        Button("Continue") { send() }.disabled(password.isEmpty)
                    } footer: { Text("No network needed. The old phone shows a moving QR code encrypted with a one-time transfer code. A transfer file works too.") }
                case .exportEncrypted, .exportCSV:
                    if choosingDestination {
                        // Buttons in the panel itself: a confirmation dialog over this sheet showed its title without any buttons.
                        Section {
                            Button("Save to Files", systemImage: "folder") { choosingDestination = false; exporting = true }
                            Button("Send to a nearby device", systemImage: "square.and.arrow.up") { choosingDestination = false; sendBackup() }
                        } header: { Text("Save or send this backup?") } footer: {
                            Text("Send it only to a device you own or trust, with AirDrop. Anyone who gets this file can keep trying to guess your app password.")
                        }
                    } else {
                    Section("Export") {
                        if csv {
                            Text("CSV files expose every password. Keep them out of spreadsheets: cells may contain formulas. Delete your migration copy after checking the import.").font(.footnote).foregroundStyle(.orange)
                            Toggle("I understand the plaintext export risk", isOn: $csvConsent)
                        } else {
                            Text("Encrypted exports use your app password. Keep it safe; there is no recovery service.").font(.footnote)
                        }
                        Button("Export") { export() }.disabled(password.isEmpty || (csv && !csvConsent))
                    }
                    }
                }
            }
            .disabled(model.busy)
            .overlay { if model.busy { ProgressView("Securing your vault…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .navigationTitle(LocalizedStringKey(panel.title)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { self.panel = nil }.disabled(model.busy).accessibilityIdentifier("settings.panel.done") } }
                .confirmationDialog("Remove the decoy vault and everything in it? Your real vault is not affected.", isPresented: $removingDecoy, titleVisibility: .visible) {
                    Button("Remove decoy vault", role: .destructive) { let current = password; password = ""; model.run({ try $0.removeDecoy(password: current); return nil }, done: { model.hasDecoy = false; model.canResetDecoy = false; model.forgetDecoyBackups(); model.show("Decoy vault removed.", error: false) }) }
                }
                .fileExporter(isPresented: $exporting, document: document, contentType: csv ? .commaSeparatedText : .data, defaultFilename: exportFileName(csv ? "csv" : "pvault")) { [exported = document?.exported] result in
                    document = nil
                    switch result {
                    case .failure(let error): model.show(localizedError(error))
                    case .success:
                        if let exported { model.recordBackup(exported); self.panel = nil; model.show(exported.csv ? "Plaintext CSV exported. Protect or delete this file after migration." : "Encrypted backup exported.", error: false) }
                    }
                }
        }
        .statusBar(model)
        // On the navigation stack, not on the form that carries the export's file exporter: one view with both can present only one.
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in finishAutoSetup(result) }
        .alert(model.autoBackupNotice?.saved == false ? "Backup not saved" : "Backup saved",
               isPresented: Binding(get: { model.autoBackupNotice != nil }, set: { if !$0 { model.autoBackupNotice = nil } }), presenting: model.autoBackupNotice) { _ in
            Button("OK") { model.autoBackupNotice = nil }
        } message: { notice in Text(notice.text) }
        .interactiveDismissDisabled(model.busy)
        .presentationDetents(panel.requiresPassword ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func refreshAutofill() async { autofillOn = await ASCredentialIdentityStore.shared.state().isEnabled }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(LocalizedStringKey(title)).foregroundStyle(Color.aOnSurface)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func send() {
        guard !model.busy, let engine = model.engine else { return }
        let pass = password; password = ""; model.busy = true
        Task {
            do {
                let sealed = try await Task.detached { try engine.exportTransfer(password: pass) }.value
                // Shown from the vault list, so it can come back after a lock; this sheet closes.
                if model.unlocked { model.sending = TransferPayload(code: sealed.code, data: sealed.data, decoy: model.decoy); dismiss() }
            } catch { model.failed(error) }
            model.busy = false
        }
    }
    private func receive() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: receiving = true
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { granted in Task { @MainActor in if granted { receiving = true } else { model.show("Camera access is needed to scan. Allow it in Settings, or use a transfer file.") } } }
        default: model.show("Camera access is needed to scan. Allow it in Settings, or use a transfer file.")
        }
    }
    /// Hands a copy of the prepared backup to the trimmed share sheet. It counts as a backup when iOS reports the share completed.
    private func sendBackup() {
        guard let exported = document?.exported else { return }
        document = nil
        let temporary = FileManager.default.temporaryDirectory
        do {
            let file = try BackupShare.write(exported.data, name: exportFileName("pvault"), in: temporary)
            DispatchQueue.main.async {
                BackupShareSheet.present(file) { completed in
                    BackupShare.sweep(in: temporary)
                    if completed { model.recordBackup(exported); self.panel = nil; model.show("Encrypted backup sent.", error: false) }
                }
            }
        } catch { model.show(error.localizedDescription) }
    }
    /// Checks the app password (a counted attempt), derives the backup key once, then lets the user pick the folder.
    private func setUpAutoBackup() {
        guard !model.busy, let engine = model.engine else { return }
        let pass = password; password = ""; model.busy = true
        Task {
            do {
                let sealed = try await Task.detached { try engine.sealAutoBackupKey(password: pass) }.value
                if model.unlocked {
                    pendingAutoKey = sealed
                    if let folder = uiTestBackupFolder() { finishAutoSetup(.success(folder)) } else { choosingFolder = true }
                }
            } catch { model.failed(error) }
            model.busy = false
        }
    }
    /// UI tests cannot drive the system folder picker, so a debug build launched by one names a folder in its own temporary directory.
    /// Release builds never read it.
    private func uiTestBackupFolder() -> URL? {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["PASSVAULT_UI_TEST_BACKUP_FOLDER"], !name.isEmpty, !name.contains("/") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        #endif
        return nil
    }
    private func finishAutoSetup(_ result: Result<URL, Error>) {
        guard let key = pendingAutoKey else { return }
        pendingAutoKey = nil
        guard model.unlocked, case .success(let folder) = result else { model.show("Automatic backup not set up.", error: false); return }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? folder.bookmarkData() else { model.show("This folder cannot be used for automatic backups. Choose another one."); return }
        model.autoBackups.turnOn(folderBookmark: bookmark, name: folder.lastPathComponent, sealedKey: key)
        model.autoBackupRevision += 1
        // Straight to the automatic backup panel, with Back up now, as on Android.
        panel = .autoBackup
        model.autoBackup(force: true, announce: true)
    }
    private func export() {
        guard !model.busy, let engine = model.engine else { return }
        let pass = password, isCSV = csv, defaults = model.backupPreferences
        password = ""; model.busy = true
        Task {
            do {
                let exported = try await Task.detached { try engine.prepareExport(password: pass, csv: isCSV, instance: { BackupStatus(defaults: defaults, decoy: $0).instance }) }.value
                if model.unlocked {
                    document = ExportDocument(data: exported.data, exported: exported)
                    if isCSV { exporting = true } else { choosingDestination = true }
                }
            } catch { model.failed(error) }
            model.busy = false
        }
    }
}

/// Reads a file chosen in a document picker, refusing anything larger than a vault can hold.
func readPicked(_ url: URL, limit: Int = Records.maxBytes + 64) throws -> Data {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else { throw VaultError.invalid("The file is too large.") }
    return try Data(contentsOf: url)
}

struct EncryptedImport: Identifiable { let id = UUID(); let data: Data }

/// Asks for the password of an encrypted import file, and for KeePass optionally its key file.
struct DecryptImportView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    let file: EncryptedImport
    let done: ([VaultRecord]) -> Void
    @State private var password = ""
    @State private var keyFile: Data?
    @State private var choosingKey = false
    @State private var working = false
    @State private var error = ""
    var keepass: Bool { Kdbx.isKdbx(file.data) }
    var transfer: Bool { Transfer.isTransfer(file.data) }
    var keeper: Bool { Pkb2.isPkb2(file.data) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // The transfer code is read off another screen, so it is typed in the clear.
                    if transfer { TransferCodeField(code: $password) }
                    else { PasswordInput(label: keepass ? "Database password" : "File password", text: $password) }
                    if keepass {
                        if keyFile == nil { Button("Choose key file", systemImage: "key") { choosingKey = true } }
                        else { HStack { Label("Key file chosen", systemImage: "key.fill"); Spacer(); Button("Remove") { keyFile = nil } } }
                    }
                } footer: {
                    Text(LocalizedStringKey(transfer ? "Enter the transfer code shown on the other phone." : keepass ? "Enter the database password. If it also uses a key file, choose it too. Opening it can take a few seconds."
                         : keeper ? "Enter the password you chose when exporting this .pkb2 file from Password Keeper." : "Enter the password this backup was exported with."))
                }
                if !error.isEmpty { Text(LocalizedStringKey(error)).foregroundStyle(.red).font(.footnote) }
                if working { ProgressView("Decrypting…") }
            }
            .navigationTitle(LocalizedStringKey(transfer ? "Transfer from another phone" : keepass ? "KeePass database" : keeper ? "Password Keeper backup" : "Encrypted backup")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Decrypt") { decrypt() }.disabled(working || (password.isEmpty && !keepass)) }
            }
            .fileImporter(isPresented: $choosingKey, allowedContentTypes: [.item]) { result in
                do { keyFile = try readPicked(result.get(), limit: 1024 * 1024) } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func decrypt() {
        let data = file.data, pass = password, key = keyFile
        password = ""; working = true; error = ""
        Task {
            do {
                let records = try await Task.detached { () throws -> [VaultRecord] in
                    if Transfer.isTransfer(data) { return try Transfer.open(data, code: pass) }
                    if Kdbx.isKdbx(data) { return try Kdbx.importTyped(data, password: pass, keyFile: key) }
                    if Pkb2.isPkb2(data) { return try Pkb2.importRecords(data, password: pass) }
                    return try VaultCrypto.importBackup(data, password: pass)
                }.value
                working = false
                if records.isEmpty { error = "The file contains no records." } else { done(records) }
            } catch {
                working = false
                // A wrong password and a damaged file look the same to the decryption, as on Android.
                if case VaultError.authentication? = error as? VaultError { self.error = localized("Incorrect password or damaged backup file.") } else { self.error = localizedError(error) }
            }
        }
    }
}

/// e.g. passvault_2026-09-29_10_31.pvault, in local time.
func exportFileName(_ fileExtension: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HH_mm"
    return "passvault_\(formatter.string(from: Date())).\(fileExtension)"
}

/// Length and character types for generated passwords; at least one type always stays on.
struct GeneratorOptionsEditor: View {
    @Binding var options: GeneratorOptions
    var body: some View {
        Stepper("Length: \(options.length)", value: $options.length, in: GeneratorOptions.minLength...GeneratorOptions.maxLength)
        Toggle("Letters", isOn: toggle(\.letters))
        Toggle("Numbers", isOn: toggle(\.numbers))
        Toggle("Symbols", isOn: toggle(\.symbols))
    }
    private func toggle(_ key: WritableKeyPath<GeneratorOptions, Bool>) -> Binding<Bool> {
        Binding(get: { options[keyPath: key] }, set: { on in
            var next = options; next[keyPath: key] = on
            if next.letters || next.numbers || next.symbols { options = next }
        })
    }
}
