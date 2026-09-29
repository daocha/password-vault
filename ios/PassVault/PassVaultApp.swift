import SwiftUI
import UIKit
import VaultCore
import UniformTypeIdentifiers

@MainActor final class VaultModel: ObservableObject {
    @Published var records = [VaultRecord]()
    @Published var unlocked = false
    @Published var exists = true
    @Published var busy = false
    @Published var message = ""
    @Published var attempts = 10
    @Published var erased = false
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
    }
    func lock() {
        generation += 1; unlocked = false; records = []
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
                if let result { records = result; unlocked = true; exists = true; unlockedAt = Date() }
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
                        Text("PassVault").font(.largeTitle.bold())
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

struct RecordList: View {
    @EnvironmentObject var model: VaultModel
    @State private var query = ""
    @State private var favorites = false
    @State private var editing: VaultRecord?
    @State private var transfer = false
    var filtered: [VaultRecord] { model.records.filter { $0.matches(query) && (!favorites || $0.favorite) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var body: some View {
        NavigationStack {
            List {
                Section { Toggle("Favorites only", isOn: $favorites) }
                Section("\(filtered.count) records") {
                    ForEach(filtered) { record in
                        Button { editing = record } label: {
                            HStack(spacing: 14) {
                                Image(systemName: record.favorite ? "star.fill" : "key.fill").foregroundStyle(.tint).frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.name.isEmpty ? "Untitled record" : record.name).font(.headline).foregroundStyle(.primary)
                                    Text(record.group.isEmpty ? record.website : record.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(.vertical, 5)
                        }
                    }.onDelete { offsets in
                        let ids = Set(offsets.map { filtered[$0].id }), updated = model.records.filter { !ids.contains($0.id) }
                        model.run { try $0.save(updated); return updated }
                    }
                }
            }
            .overlay { if model.records.isEmpty { ContentUnavailableView("A little peace of mind", systemImage: "lock.shield", description: Text("Add your first password or import your Password Keeper CSV.")) } }
            .navigationTitle("Your vault").searchable(text: $query, prompt: "Search names, usernames, notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Lock", systemImage: "lock") { model.lock() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Import, export & security", systemImage: "gearshape") { transfer = true }
                    Button("Add record", systemImage: "plus") { editing = VaultRecord() }
                }
            }
            .sheet(item: $editing) { RecordEditor(record: $0) }
            .sheet(isPresented: $transfer) { TransferView() }
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
                Section("Website or app") {
                    TextField("Name", text: $record.name)
                    TextField("Website", text: $record.website).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Group", text: $record.group)
                    Toggle("Favorite", isOn: $record.favorite)
                }
                Section("Fields · drag the handles to reorder") {
                    ForEach($record.fields) { $field in
                        VStack(alignment: .leading) {
                            TextField("Field label", text: $field.label).font(.caption).foregroundStyle(.secondary)
                            if field.kind == .question { TextField("Security question", text: $field.question) }
                            HStack {
                                if field.secret && !revealed.contains(field.id) { SecureField(field.kind == .question ? "Answer" : "Password", text: $field.value) }
                                else { TextField("Value", text: $field.value, axis: .vertical) }
                                if field.secret {
                                    Button { if !revealed.insert(field.id).inserted { revealed.remove(field.id) } } label: { Image(systemName: revealed.contains(field.id) ? "eye.slash" : "eye") }.buttonStyle(.borderless).accessibilityLabel(revealed.contains(field.id) ? "Hide secret" : "Reveal secret")
                                }
                            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                            HStack {
                                if field.kind == .password { Button("Generate strong password") { do { field.value = try VaultCrypto.generatePassword(length: generatorLength, symbols: generatorSymbols) } catch { model.message = error.localizedDescription } }.font(.caption).buttonStyle(.borderless) }
                                Spacer()
                                if !field.historyNewestFirst.isEmpty { Button("History", systemImage: "clock.arrow.circlepath") { historyField = field }.font(.caption).buttonStyle(.borderless) }
                                Button("Copy", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.setItems([["public.utf8-plain-text": field.value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)])
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
                .navigationTitle(record.name.isEmpty ? "New record" : record.name)
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
    @State private var newPassword = ""
    @State private var confirmNew = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Biometric unlock") {
                    SecureField("Current app password", text: $password)
                    Button("Enable Face ID / Touch ID") { let value = password; password = ""; model.run { try $0.enableBiometrics(password: value); return nil } }
                }
                Section("Change master password") {
                    SecureField("New passphrase", text: $newPassword)
                    SecureField("Repeat new passphrase", text: $confirmNew)
                    Button("Change password") {
                        let current = password, next = newPassword; password = ""; newPassword = ""; confirmNew = ""
                        model.run { try $0.changePassword(current: current, new: next); return nil }
                    }.disabled(password.isEmpty || VaultCrypto.passwordProblem(newPassword) != nil || newPassword != confirmNew)
                    Text("Existing exported backups keep their original password.").font(.footnote)
                }
                Section("Import & export") {
                    Toggle("Plaintext CSV", isOn: $csv)
                    if csv {
                        Text("CSV files expose every password. Keep them out of spreadsheets: cells may contain formulas. Delete your migration copy after checking the import.").font(.footnote).foregroundStyle(.orange)
                        Toggle("I understand the plaintext export risk", isOn: $csvConsent)
                    } else {
                        SecureField("Encrypted file password (also for Password Keeper .pkb2)", text: $backupPassword)
                        SecureField("Repeat password for export", text: $confirmBackup)
                        Text("Encrypted exports use their own password. Keep it safe; there is no recovery service.").font(.footnote)
                    }
                    Button("Import file") { importing = true }
                    Button("Export all passwords") { export() }.disabled(password.isEmpty || (csv ? !csvConsent : backupPassword != confirmBackup || VaultCrypto.passwordProblem(backupPassword) != nil))
                }
                Section("Security") { Text("The vault locks in the background and after five minutes per session. Copied values expire after 30 seconds. Local vault erasure follows 10 failed app-password attempts. Copied encrypted backups cannot enforce an attempt limit. Biometrics do not reset the password counter.").font(.footnote) }
            }.navigationTitle("Vault settings").toolbar { Button("Done") { dismiss() } }
                .fileImporter(isPresented: $importing, allowedContentTypes: csv ? [.commaSeparatedText, .plainText, .data] : [.data]) { result in
                    do {
                        let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= Records.maxBytes + 64 else { throw VaultError.invalid("File exceeds 16 MiB.") }
                        let data = try Data(contentsOf: url), isCSV = csv, pass = backupPassword
                        backupPassword = ""; confirmBackup = ""
                        Task {
                            do {
                                let imported = try await Task.detached { try isCSV ? VaultCSV.importRecords(String(decoding: data, as: UTF8.self)) : (Pkb2.isPkb2(data) ? Pkb2.importRecords(data, password: pass) : VaultCrypto.importBackup(data, password: pass)) }.value
                                if model.unlocked { pendingImport = imported }
                            } catch { model.message = error.localizedDescription }
                        }
                    } catch { model.message = error.localizedDescription }
                }
                .confirmationDialog("Import \(pendingImport?.count ?? 0) records? Existing records will be kept.", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
                    Button("Import records") { if let records = pendingImport { model.run { try $0.merge(records) } }; pendingImport = nil }
                }
                .fileExporter(isPresented: $exporting, document: document, contentType: csv ? .commaSeparatedText : .data, defaultFilename: exportFileName(csv ? "csv" : "pvault")) { result in
                    document = nil
                    if case .failure(let error) = result { model.message = error.localizedDescription }
                }
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

/// e.g. passvault_2026-09-29_10_31.pvault, in local time.
func exportFileName(_ fileExtension: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HH_mm"
    return "passvault_\(formatter.string(from: Date())).\(fileExtension)"
}
