import SwiftUI
import UIKit
import VaultCore
import UniformTypeIdentifiers
import AVFoundation

@MainActor final class VaultModel: ObservableObject {
    @Published var records = [VaultRecord]()
    @Published var unlocked = false
    @Published var exists = true
    @Published var busy = false
    @Published var message = ""
    @Published var attempts = 10
    @Published var erased = false
    /// When the last encrypted backup was saved, and the reminder settings. Ordinary preferences: only times and a choice, no secrets.
    @Published var lastBackup: Date?
    @Published var backupIntervalDays = 30
    @Published var backupSnoozedUntil: Date?
    private var backupPrefix = ""
    /// The decoy vault is open: settings that would reveal or touch the real vault are not shown.
    @Published var decoy = false
    @Published var hasDecoy = false
    /// Whether the real vault can give the decoy a new password (decoys from earlier test builds cannot).
    @Published var canResetDecoy = false
    /// The transfer being sent, if any; it survives a lock for a while so its code is still there after sharing the file from another app.
    @Published var sending: TransferPayload?
    private var unlockedAt = Date.distantPast
    private(set) var engine: VaultEngine? = nil
    private var generation = 0
    init() {
        var initialized: VaultEngine?
        do {
            let engine = VaultEngine(storage: try KeychainStorage()); initialized = engine
            exists = try engine.exists(); attempts = try engine.remainingAttempts()
        } catch { message = error.localizedDescription }
        engine = initialized
        erased = (try? initialized?.isErased()) ?? false
        loadBackupStatus()
    }
    func loadBackupStatus() {
        let defaults = UserDefaults.standard
        lastBackup = defaults.object(forKey: backupPrefix + "lastBackupAt") as? Date
        backupIntervalDays = defaults.object(forKey: backupPrefix + "backupReminderDays") as? Int ?? 30
        backupSnoozedUntil = defaults.object(forKey: backupPrefix + "backupSnoozeUntil") as? Date
    }
    /// Only a saved encrypted backup counts: CSV leaves out 2FA keys, cards and notes.
    func recordBackup() {
        UserDefaults.standard.set(Date(), forKey: backupPrefix + "lastBackupAt"); UserDefaults.standard.removeObject(forKey: backupPrefix + "backupSnoozeUntil"); loadBackupStatus()
    }
    /// The removed decoy's backup history and reminder choice.
    func forgetDecoyBackups() { for key in ["lastBackupAt", "backupReminderDays", "backupSnoozeUntil"] { UserDefaults.standard.removeObject(forKey: "decoy." + key) } }
    func snoozeBackup() { UserDefaults.standard.set(Date().addingTimeInterval(Double(BackupReminder.snoozeDays) * 86400), forKey: backupPrefix + "backupSnoozeUntil"); loadBackupStatus() }
    func setBackupInterval(_ days: Int) { UserDefaults.standard.set(days, forKey: backupPrefix + "backupReminderDays"); loadBackupStatus() }
    var backupDue: Bool { BackupReminder.due(records, lastBackup: lastBackup, intervalDays: backupIntervalDays, snoozedUntil: backupSnoozedUntil) }
    func lock() {
        generation += 1; unlocked = false; records = []; decoy = false; hasDecoy = false; canResetDecoy = false
        if let sending, Date() >= sending.expiresAt { self.sending = nil }
        if !backupPrefix.isEmpty { backupPrefix = ""; loadBackupStatus() }
        let engine = engine
        Task.detached { engine?.lock() }
    }
    func run(_ work: @escaping @Sendable (VaultEngine) throws -> [VaultRecord]?, done: (() -> Void)? = nil) {
        guard !busy, let engine else { return }
        busy = true; message = ""; let current = generation
        Task {
            do {
                let result = try await Task.detached { try work(engine) }.value
                guard generation == current else { engine.lock(); busy = false; return }
                if let result {
                    records = result; unlocked = true; exists = true; unlockedAt = Date()
                    // Each vault keeps its own backup history, so the decoy shows only its own.
                    decoy = engine.isDecoy(); hasDecoy = (try? engine.hasDecoy()) ?? false; canResetDecoy = (try? engine.canResetDecoy()) ?? false; backupPrefix = decoy ? "decoy." : ""; loadBackupStatus()
                    // Only the vault that made a pending transfer may see it again.
                    if let sending, sending.decoy != decoy || Date() >= sending.expiresAt { self.sending = nil }
                }
                attempts = try engine.remainingAttempts(); done?()
            } catch {
                message = error.localizedDescription
                // Failed export/password verification also closes visible secret views.
                lock(); attempts = (try? engine.remainingAttempts()) ?? 0
                erased = (try? engine.isErased()) ?? false
            }
            busy = false
        }
    }
    func checkTimeout() { if unlocked && Date().timeIntervalSince(unlockedAt) >= 300 { lock() } }
    func resetErased() {
        guard let engine else { return }
        do { try engine.resetErasedVault(); erased = false; exists = false; attempts = 10; message = "Create a new vault, then import your backup." }
        catch { message = error.localizedDescription }
    }
}

/// Third-party keyboards could log revealed passwords and notes typed into ordinary text fields; only the system keyboard is allowed.
final class AppDelegate: NSObject, UIApplicationDelegate {
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
            VaultRoot().environmentObject(model)
                .tint(Color(red: 0.12, green: 0.32, blue: 0.66))
                .overlay { if phase != .active { Color(red: 0.025, green: 0.07, blue: 0.18).ignoresSafeArea().overlay { Image(systemName: "lock.fill").font(.system(size: 56)).foregroundStyle(.white) } } }
                .onChange(of: phase) { _, phase in
                    if phase == .active { PrivacyCover.hide() } else { PrivacyCover.show() }
                    if phase == .background { model.lock() }
                }
                // Locking the phone (not just leaving the app to share the file) ends a pending transfer.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in model.sending = nil }
                .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in model.checkTimeout() }
        }
    }
}

struct VaultRoot: View {
    @EnvironmentObject var model: VaultModel
    var body: some View {
        Group { if model.unlocked { RecordList() } else { UnlockView() } }
            .safeAreaInset(edge: .bottom) {
                if !model.message.isEmpty { Text(model.message).font(.footnote).foregroundStyle(.red).padding().frame(maxWidth: .infinity).background(.regularMaterial) }
            }
            .overlay { if model.busy { ZStack { Color.black.opacity(0.15).ignoresSafeArea(); ProgressView("Securing your vault…").padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } } }
            .disabled(model.busy)
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
                        Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(.tint)
                        WordMark().font(.largeTitle.bold())
                        Text("Your passwords. Only on your device.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                }.listRowBackground(Color.clear)
                Section(model.exists ? "Welcome back" : "Create your private vault") {
                    if model.erased {
                        Text("The local vault has been erased. You can create a new one and restore an exported backup.")
                        Button("Start a new vault") { resetConfirmation = true }
                    }
                    SecureField("Master passphrase", text: $password).textContentType(.password)
                    if !model.exists {
                        SecureField("Repeat passphrase", text: $confirmation)
                        Text("\(VaultCrypto.passwordProblem(password) ?? VaultCrypto.passwordRule) There is no password reset or cloud recovery.").font(.footnote)
                        Toggle("I understand: 10 failed password attempts erase the local vault", isOn: $acknowledge)
                    }
                    Button(model.exists ? "Unlock vault" : "Create vault") {
                        let value = password; password = ""; confirmation = ""
                        let exists = model.exists
                        model.run { engine in try exists ? engine.unlock(password: value) : engine.create(password: value) }
                    }.disabled(password.isEmpty || (!model.exists && (password != confirmation || !acknowledge)))
                    if model.exists {
                        Button("Unlock with Face ID / Touch ID", systemImage: "faceid") { model.run { try $0.unlockBiometric() } }
                        Text("\(model.attempts) password attempts remaining").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .confirmationDialog("Start a new empty vault? Your erased records cannot be recovered without a backup.", isPresented: $resetConfirmation) { Button("Create new vault") { model.resetErased() } }
        }
    }
}

/// "Expired" or "Expires soon" beside a list row; nothing for records without a date or with one further away.
struct ExpiryBadge: View {
    let record: VaultRecord
    var body: some View {
        switch record.expiryState() {
        case .expired: Label("Expired", systemImage: "calendar.badge.exclamationmark").font(.caption2).foregroundStyle(.red)
        case .soon: Label("Expires soon", systemImage: "calendar.badge.clock").font(.caption2).foregroundStyle(.orange)
        default: EmptyView()
        }
    }
}

func groupColor(_ name: String) -> Color { let c = groupColorRGB(name); return Color(red: c.r, green: c.g, blue: c.b) }

/// A group's name in its own color: colored border, a light tint behind the text, and the normal text color so contrast holds in light and dark mode.
struct GroupTag: View {
    let name: String
    var body: some View {
        let tint = groupColor(name)
        Text(name.trimmingCharacters(in: .whitespaces)).font(.caption2).foregroundStyle(.primary).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint, lineWidth: 1))
    }
}

/// "Pass" in the normal text color and "Vault" in the brand blue, a shade deeper in light mode so it keeps its contrast.
struct WordMark: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text("Pass") + Text("Vault").foregroundColor(scheme == .dark ? Color(red: 0.30, green: 0.70, blue: 1.0) : Color(red: 0.12, green: 0.47, blue: 0.80))
    }
}

/// The brand's icon when the record is a well-known site or app; otherwise the key (or star for favorites).
struct RecordIcon: View {
    let record: VaultRecord
    var body: some View {
        if record.isLogin || record.isTotp, let brand = findBrand(website: record.website, name: record.name) {
            Image(brand.assetName).resizable().scaledToFit().accessibilityLabel(brand.title).frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) { if record.favorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow).offset(x: 4, y: -4) } }
                .frame(width: 38)
        } else {
            Image(systemName: record.favorite ? "star.fill" : record.isCard ? "creditcard.fill" : record.isNote ? "note.text" : "key.fill").foregroundStyle(.tint).frame(width: 30)
        }
    }
}

struct RecordList: View {
    @EnvironmentObject var model: VaultModel
    @State private var query = ""
    @State private var favorites = false
    @State private var editing: VaultRecord?
    @State private var editingTotp: VaultRecord?
    @State private var showTotp = false
    @State private var transfer = false
    @State private var health = false
    var filtered: [VaultRecord] { model.records.filter { $0.isTotp == showTotp && $0.matches(query) && (!favorites || $0.favorite) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $showTotp) { Text("Passwords").tag(false); Text("2FA codes").tag(true) }.pickerStyle(.segmented)
                    Toggle("Favorites only", isOn: $favorites)
                }
                if model.backupDue {
                    Section {
                        Label(model.lastBackup.map { "Last backup \($0.formatted(.relative(presentation: .named))) · \(BackupReminder.changedSince(model.records, lastBackup: $0)) entries changed since" }
                              ?? "No backup yet. If this phone is lost or reset, these entries are gone.", systemImage: "externaldrive.badge.exclamationmark")
                        HStack { Button("Back up") { transfer = true }; Spacer(); Button("Later") { model.snoozeBackup() }.foregroundStyle(.secondary) }.buttonStyle(.borderless)
                    }
                }
                let expiring = model.records.filter { [.expired, .soon].contains($0.expiryState()) }.count
                if expiring > 0 {
                    Section { Button { health = true } label: { Label("Expired or expiring soon: \(expiring)", systemImage: "calendar.badge.exclamationmark") } }
                }
                Section(showTotp ? "\(filtered.count) codes" : "\(filtered.count) records") {
                    ForEach(filtered) { record in
                        if record.isTotp { Button { editingTotp = record } label: { TotpRow(record: record) } } else {
                        Button { editing = record } label: {
                            HStack(spacing: 14) {
                                RecordIcon(record: record)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.name.isEmpty ? "Untitled record" : record.name).font(.headline).foregroundStyle(.primary)
                                    if record.isCard, !record.cardSummary.isEmpty { Text(record.cardSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    else if !record.website.isEmpty { Text(record.website).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    if !record.group.trimmingCharacters(in: .whitespaces).isEmpty { GroupTag(name: record.group) }
                                }
                                Spacer()
                                ExpiryBadge(record: record)
                            }.padding(.vertical, 5)
                        }
                        }
                    }.onDelete { offsets in
                        let ids = Set(offsets.map { filtered[$0].id }), updated = model.records.filter { !ids.contains($0.id) }
                        model.run { try $0.save(updated); return updated }
                    }
                }
            }
            .overlay {
                if showTotp && !model.records.contains(where: \.isTotp) { ContentUnavailableView("No 2FA codes", systemImage: "qrcode.viewfinder", description: Text("Tap + and scan the QR code a site shows when you turn on two-factor authentication, or enter its setup key. Codes are generated offline on this device. To move from Google Authenticator, export there and scan its QR code here.")) }
                else if !showTotp && model.records.isEmpty { ContentUnavailableView("A little peace of mind", systemImage: "lock.shield", description: Text("Add your first password or import your Password Keeper CSV.")) }
            }
            .navigationTitle("PassVault").navigationBarTitleDisplayMode(.inline).searchable(text: $query, prompt: "Search names, usernames, notes")
            .toolbar {
                ToolbarItem(placement: .principal) { WordMark().font(.headline) }
                ToolbarItem(placement: .topBarLeading) { Button("Lock", systemImage: "lock") { model.lock() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Vault health", systemImage: "heart.text.square") { health = true }
                    Button("Import, export & security", systemImage: "gearshape") { transfer = true }
                    if showTotp {
                        Button("Add 2FA code", systemImage: "plus") { var record = VaultRecord(); record.type = "totp"; record.fields = []; editingTotp = record }
                    } else {
                        Menu("Add record", systemImage: "plus") {
                            Button("Login", systemImage: "key") { editing = VaultRecord() }
                            Button("Payment card", systemImage: "creditcard") { editing = VaultRecord.new(type: "card") }
                            Button("Secure note", systemImage: "note.text") { editing = VaultRecord.new(type: "note") }
                        }
                    }
                }
            }
            .sheet(item: $editing) { RecordEditor(record: $0) }
            .sheet(item: $editingTotp) { TotpEditor(record: $0) }
            .sheet(isPresented: $transfer) { TransferView() }
            .sheet(isPresented: $health) { HealthView() }
            .fullScreenCover(item: $model.sending) { TransferSendView(payload: $0) }
        }
    }
}

struct RecordEditor: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State var record: VaultRecord
    @State private var revealed = Set<String>()
    @State private var generatorLength = 24
    @State private var generatorSymbols = true
    @State private var historyField: VaultField?
    var body: some View {
        NavigationStack {
            Form {
                Section("Password generator") {
                    Stepper("Length: \(generatorLength)", value: $generatorLength, in: 12...128)
                    Toggle("Include symbols", isOn: $generatorSymbols)
                }
                Section(record.isCard ? "Card" : record.isNote ? "Secure note" : "Website or app") {
                    TextField("Name", text: $record.name)
                    if !record.isNote { TextField("Website/App name", text: $record.website).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    TextField("Group", text: $record.group)
                    Toggle("Favorite", isOn: $record.favorite)
                    // A card's own expiry date is its reminder.
                    if !record.isCard {
                        Toggle("Expiry reminder", isOn: Binding(get: { record.expires != nil }, set: { record.expires = $0 ? Expiry.format(Expiry.components(Date().addingTimeInterval(86400 * 365))) : nil }))
                        if let expires = record.expires, let date = Expiry.parseDate(expires).flatMap(Expiry.localDate) {
                            DatePicker("Remind on", selection: Binding(get: { date }, set: { record.expires = Expiry.format(Expiry.components($0)) }), displayedComponents: .date)
                        }
                    } else if let date = record.expiryDate.flatMap(Expiry.localDate) {
                        Text("Card expires \(date.formatted(date: .abbreviated, time: .omitted))").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Fields · drag the handles to reorder") {
                    ForEach($record.fields) { $field in
                        VStack(alignment: .leading) {
                            TextField("Field label", text: $field.label).font(.caption).foregroundStyle(.secondary)
                            if field.kind == .question { TextField("Security question", text: $field.question) }
                            HStack {
                                let cardInput = CardInput.of(field.label).flatMap { input in input.digits(field.value).map { _ in input } }
                                if field.secret && !revealed.contains(field.id) { SecureField(field.kind == .question ? "Answer" : cardNumericLabels.contains(field.label) ? field.label : "Password", text: cardInput.map { input in Binding(get: { field.value }, set: { field.value = input.clean($0) }) } ?? $field.value).keyboardType(cardNumericLabels.contains(field.label) ? .numberPad : .default) }
                                // A card number or expiry is stored as digits only and shown grouped; legacy values like "03/27" are edited as their digits.
                                else if let cardInput { TextField(field.label == cardExpiryLabel ? "MM/YY" : "Value", text: Binding(get: { cardInput.formatted(cardInput.digits(field.value) ?? "") }, set: { field.value = cardInput.edited($0, from: cardInput.digits(field.value) ?? "") })).keyboardType(.numberPad) }
                                else { TextField(field.label == cardExpiryLabel ? "MM/YY" : "Value", text: $field.value, axis: .vertical).keyboardType(cardNumericLabels.contains(field.label) ? .numberPad : .default) }
                                if field.secret {
                                    Button { if !revealed.insert(field.id).inserted { revealed.remove(field.id) } } label: { Image(systemName: revealed.contains(field.id) ? "eye.slash" : "eye") }.buttonStyle(.borderless).accessibilityLabel(revealed.contains(field.id) ? "Hide secret" : "Reveal secret")
                                }
                            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                            HStack {
                                if field.kind == .password && !cardNumericLabels.contains(field.label) { Button("Generate strong password") { do { field.value = try VaultCrypto.generatePassword(length: generatorLength, symbols: generatorSymbols) } catch { model.message = error.localizedDescription } }.font(.caption).buttonStyle(.borderless) }
                                Spacer()
                                if !field.historyNewestFirst.isEmpty { Button("History", systemImage: "clock.arrow.circlepath") { historyField = field }.font(.caption).buttonStyle(.borderless) }
                                Button("Copy", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.setItems([["public.utf8-plain-text": field.label == cardExpiryLabel ? Cards.formattedExpiry(field.value) : field.value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)])
                                }.font(.caption).buttonStyle(.borderless)
                            }
                        }.padding(.vertical, 4)
                    }.onMove { record.fields.move(fromOffsets: $0, toOffset: $1) }.onDelete { record.fields.remove(atOffsets: $0) }
                }
                Section {
                    Menu("Add field", systemImage: "plus.circle") {
                        ForEach(FieldKind.allCases, id: \.self) { kind in Button(kind == .question ? "Security question & answer" : kind.rawValue.capitalized) { record.fields.append(.init(kind: kind, label: kind.rawValue.capitalized)) } }
                    }
                }
            }.environment(\.editMode, .constant(.active))
                .sheet(item: $historyField) { PasswordHistoryView(field: $0) }
                .navigationTitle(record.name.isEmpty ? (record.isCard ? "New card" : record.isNote ? "New secure note" : "New record") : record.name)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        record.updatedAt = ISO8601DateFormatter().string(from: Date())
                        record = record.recordingPasswordChanges(previous: model.records.first { $0.id == record.id })
                        var updated = model.records
                        if let index = updated.firstIndex(where: { $0.id == record.id }) { updated[index] = record } else { updated.append(record) }
                        let snapshot = updated
                        model.run({ try $0.save(snapshot); return snapshot }, done: { dismiss() })
                    }.disabled(record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

/// Earlier values of a password, newest change first. Imported from Password Keeper; unrelated to fields the user names "Previous password".
struct PasswordHistoryView: View {
    let field: VaultField
    @Environment(\.dismiss) var dismiss
    @State private var shown = Set<Int>()
    var body: some View {
        NavigationStack {
            List(Array(field.historyNewestFirst.enumerated()), id: \.offset) { index, change in
                HStack {
                    VStack(alignment: .leading) {
                        Text(change.changedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(change.changedAt)).formatted(date: .abbreviated, time: .shortened) : "Unknown date").font(.caption).foregroundStyle(.secondary)
                        Text(shown.contains(index) ? change.value : "••••••••••").font(.body.monospaced())
                    }
                    Spacer()
                    Button { if !shown.insert(index).inserted { shown.remove(index) } } label: { Image(systemName: shown.contains(index) ? "eye.slash" : "eye") }.buttonStyle(.borderless).accessibilityLabel(shown.contains(index) ? "Hide" : "Reveal")
                    Button { UIPasteboard.general.setItems([["public.utf8-plain-text": change.value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)]) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).accessibilityLabel("Copy earlier password")
                }
            }.navigationTitle("Password history \(field.label)").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct TransferView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State private var password = ""
    @State private var backupPassword = ""
    @State private var confirmBackup = ""
    @State private var csv = false
    @State private var csvConsent = false
    @State private var importing = false
    @State private var exporting = false
    @State private var document: ExportDocument?
    @State private var pendingImport: [VaultRecord]?
    @State private var receiving = false
    @State private var decoyPassword = ""
    @State private var confirmDecoy = ""
    @State private var removingDecoy = false
    /// An encrypted file (PassVault backup, Password Keeper .pkb2 or KeePass .kdbx) waiting for its password.
    @State private var encryptedImport: EncryptedImport?
    @State private var newPassword = ""
    @State private var confirmNew = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("App password") { SecureField("Current app password", text: $password) }
                // Biometrics always open the real vault, so the decoy vault neither shows nor changes them.
                if !model.decoy {
                    Section("Biometric unlock") {
                        Button("Enable Face ID / Touch ID") { let value = password; password = ""; model.run { try $0.enableBiometrics(password: value); return nil } }.disabled(password.isEmpty)
                    }
                    Section {
                        if model.hasDecoy {
                            // A new password for the decoy, for when it is forgotten; what is in the decoy is kept.
                            if model.canResetDecoy {
                                SecureField("New decoy password", text: $decoyPassword)
                                SecureField("Repeat decoy password", text: $confirmDecoy)
                                if !decoyPassword.isEmpty { Text(VaultCrypto.passwordProblem(decoyPassword) ?? "Meets the password rules.").font(.footnote) }
                                Button("Change decoy password") {
                                    let current = password, next = decoyPassword; password = ""; decoyPassword = ""; confirmDecoy = ""
                                    model.run({ try $0.resetDecoyPassword(password: current, decoyPassword: next); return nil }, done: { model.message = "Decoy password changed." })
                                }.disabled(password.isEmpty || VaultCrypto.passwordProblem(decoyPassword) != nil || decoyPassword != confirmDecoy)
                            } else {
                                Text("This decoy vault was set up by an earlier test version, so its password cannot be changed here. Remove it and set it up again.").font(.footnote)
                            }
                            Button("Remove decoy vault", role: .destructive) { removingDecoy = true }.disabled(password.isEmpty)
                        } else {
                            SecureField("Decoy password", text: $decoyPassword)
                            SecureField("Repeat decoy password", text: $confirmDecoy)
                            if !decoyPassword.isEmpty { Text(VaultCrypto.passwordProblem(decoyPassword) ?? "Meets the password rules.").font(.footnote) }
                            Button("Set up decoy vault") {
                                let current = password, next = decoyPassword; password = ""; decoyPassword = ""; confirmDecoy = ""
                                model.run({ try $0.createDecoy(password: current, decoyPassword: next); return nil }, done: { model.hasDecoy = true; model.canResetDecoy = true; model.message = "Decoy vault set up. Lock PassVault and unlock with the decoy password to fill it." })
                            }.disabled(password.isEmpty || VaultCrypto.passwordProblem(decoyPassword) != nil || decoyPassword != confirmDecoy)
                        }
                    } header: { Text("Decoy vault") } footer: {
                        Text("A second app password that opens a separate, harmless vault. If someone forces you to unlock PassVault, enter the decoy password: they see only what you put in the decoy vault, and your real entries stay hidden. To fill it, lock PassVault and unlock with the decoy password. This section is not shown inside the decoy vault. Face ID / Touch ID always opens your real vault, so turn it off if you might be made to use it. Someone who knows PassVault well and examines the phone could still tell that a second vault exists.")
                    }
                }
                Section("Change master password") {
                    SecureField("New passphrase", text: $newPassword)
                    SecureField("Repeat new passphrase", text: $confirmNew)
                    Button("Change password") {
                        let current = password, next = newPassword; password = ""; newPassword = ""; confirmNew = ""
                        model.run { try $0.changePassword(current: current, new: next); return nil }
                    }.disabled(password.isEmpty || VaultCrypto.passwordProblem(newPassword) != nil || newPassword != confirmNew)
                    Text(model.decoy ? "Existing exported backups keep their original password." : "Existing exported backups keep their original password. Changing it turns off Face ID / Touch ID; enable it again above.").font(.footnote)
                }
                Section {
                    LabeledContent("Last encrypted backup", value: model.lastBackup.map { "\($0.formatted(date: .abbreviated, time: .shortened)) (\($0.formatted(.relative(presentation: .named))))" } ?? "Never")
                    Picker("Backup reminder", selection: Binding(get: { model.backupIntervalDays }, set: { model.setBackupInterval($0) })) {
                        ForEach(BackupReminder.intervals, id: \.self) { days in Text(days == 0 ? "Off" : days == 7 ? "Every week" : days == 14 ? "Every 2 weeks" : "Every month").tag(days) }
                    }
                } header: { Text("Backups") } footer: {
                    Text("PassVault keeps no cloud copy: if this phone is lost or reset, only your own backups bring your entries back. A reminder appears in the app when a backup is due and something has changed. CSV exports do not count, because they leave out 2FA keys, cards and notes.")
                }
                Section {
                    Button("Import file") { importing = true }
                } header: { Text("Import") } footer: {
                    Text("PassVault backups, KeePass (.kdbx or XML), Bitwarden (JSON or CSV), 1Password (.1pux or CSV), Password Keeper (.pkb2 or CSV), and CSV from browsers and other managers. The format is recognised from the file.")
                }
                Section {
                    Button("Send to another phone", systemImage: "iphone.and.arrow.forward") { send() }.disabled(password.isEmpty)
                    Button("Receive from another phone", systemImage: "qrcode.viewfinder") { receive() }
                } header: { Text("Move to another phone") } footer: {
                    Text("No network needed: the old phone shows a moving QR code, encrypted with a one-time code shown only on its screen, for the new phone to scan. A transfer file works too. Sending asks for the app password above.")
                }
                Section("Export") {
                    Toggle("Plaintext CSV", isOn: $csv)
                    if csv {
                        Text("CSV files expose every password. Keep them out of spreadsheets: cells may contain formulas. Delete your migration copy after checking the import.").font(.footnote).foregroundStyle(.orange)
                        Toggle("I understand the plaintext export risk", isOn: $csvConsent)
                    } else {
                        SecureField("Encrypted export password", text: $backupPassword)
                        SecureField("Repeat password for export", text: $confirmBackup)
                        Text("Encrypted exports use their own password. Keep it safe; there is no recovery service.").font(.footnote)
                    }
                    Button("Export all passwords") { export() }.disabled(password.isEmpty || (csv ? !csvConsent : backupPassword != confirmBackup || VaultCrypto.passwordProblem(backupPassword) != nil))
                }
                Section("Security") { Text("The vault locks in the background and after five minutes per session. Copied values expire after 30 seconds. Local vault erasure follows 10 failed app-password attempts. Copied encrypted backups cannot enforce an attempt limit. Unlocking with the app password or biometrics clears failed attempts.").font(.footnote) }
            }.navigationTitle("Vault settings").toolbar { Button("Done") { dismiss() } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                    do {
                        let data = try readPicked(result.get())
                        if Importers.needsPassword(data) { encryptedImport = EncryptedImport(data: data); return }
                        Task {
                            do {
                                let imported = try await Task.detached { try Importers.importPlain(data) }.value
                                if model.unlocked { if imported.isEmpty { model.message = "The file contains no records." } else { pendingImport = imported } }
                            } catch { model.message = error.localizedDescription }
                        }
                    } catch { model.message = error.localizedDescription }
                }
                .fullScreenCover(isPresented: $receiving) { TransferReceiveView { data in
                    // Present the code prompt once the scanner has finished closing; SwiftUI drops a sheet shown mid-dismissal.
                    receiving = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { encryptedImport = EncryptedImport(data: data) }
                } }
                .sheet(item: $encryptedImport) { file in DecryptImportView(file: file) { records in encryptedImport = nil; if model.unlocked { pendingImport = records } } }
                .confirmationDialog("Remove the decoy vault and everything in it? Your real vault is not affected.", isPresented: $removingDecoy, titleVisibility: .visible) {
                    Button("Remove decoy vault", role: .destructive) { let current = password; password = ""; model.run({ try $0.removeDecoy(password: current); return nil }, done: { model.hasDecoy = false; model.canResetDecoy = false; model.forgetDecoyBackups(); model.message = "Decoy vault removed." }) }
                }
                .confirmationDialog("Import \(pendingImport?.count ?? 0) records?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
                    Button("Import") { if let records = pendingImport { model.run { try $0.merge(records) } }; pendingImport = nil }
                    Button("Full replacement", role: .destructive) { if let records = pendingImport { model.run { try $0.replaceAll(records) } }; pendingImport = nil }
                    Button("Cancel", role: .cancel) { pendingImport = nil }
                } message: {
                    Text("Import: adds new entries and replaces existing entries with the same ID. Entries missing from the file are kept.\n\nFull replacement: the file is the golden source. Entries it does not contain are deleted.")
                }
                .fileExporter(isPresented: $exporting, document: document, contentType: csv ? .commaSeparatedText : .data, defaultFilename: exportFileName(csv ? "csv" : "pvault")) { result in
                    document = nil
                    switch result {
                    case .failure(let error): model.message = error.localizedDescription
                    case .success: if !csv { model.recordBackup() }
                    }
                }
        }
    }
    private func send() {
        guard !model.busy, let engine = model.engine else { return }
        let pass = password; password = ""; model.busy = true
        Task {
            do {
                let sealed = try await Task.detached { try engine.exportTransfer(password: pass) }.value
                // Shown from the vault list, so it can come back after a lock; this sheet closes.
                if model.unlocked { model.sending = TransferPayload(code: sealed.code, data: sealed.data, decoy: model.decoy); dismiss() }
            } catch { model.message = error.localizedDescription; model.lock(); model.attempts = (try? engine.remainingAttempts()) ?? 0; model.erased = (try? engine.isErased()) ?? false }
            model.busy = false
        }
    }
    private func receive() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: receiving = true
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { granted in Task { @MainActor in if granted { receiving = true } else { model.message = "Camera access is needed to scan. Allow it in Settings, or use a transfer file." } } }
        default: model.message = "Camera access is needed to scan. Allow it in Settings, or use a transfer file."
        }
    }
    private func export() {
        guard !model.busy, let engine = model.engine else { return }
        let pass = password, backup = backupPassword, isCSV = csv
        password = ""; backupPassword = ""; confirmBackup = ""; model.busy = true
        Task {
            do {
                let data = try await Task.detached { try engine.export(password: pass, backupPassword: backup, csv: isCSV) }.value
                if model.unlocked { document = ExportDocument(data: data); exporting = true }
            } catch { model.message = error.localizedDescription; model.lock(); model.attempts = (try? engine.remainingAttempts()) ?? 0; model.erased = (try? engine.isErased()) ?? false }
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
                    if transfer { TextField("Transfer code", text: $password).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.body.monospaced()) }
                    else { SecureField(keepass ? "Database password" : "File password", text: $password) }
                    if keepass {
                        if keyFile == nil { Button("Choose key file", systemImage: "key") { choosingKey = true } }
                        else { HStack { Label("Key file chosen", systemImage: "key.fill"); Spacer(); Button("Remove") { keyFile = nil } } }
                    }
                } footer: {
                    Text(transfer ? "Enter the transfer code shown on the other phone." : keepass ? "Enter the database password. If it also uses a key file, choose it too. Opening it can take a few seconds."
                         : keeper ? "Enter the password you chose when exporting this .pkb2 file from Password Keeper." : "Enter the password this backup was exported with.")
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.footnote) }
                if working { ProgressView("Decrypting…") }
            }
            .navigationTitle(transfer ? "Transfer from another phone" : keepass ? "KeePass database" : keeper ? "Password Keeper backup" : "Encrypted backup").navigationBarTitleDisplayMode(.inline)
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
            } catch { working = false; self.error = error.localizedDescription }
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
