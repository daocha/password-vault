import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import CoreImage
import VaultCore

/// "123 456", "1234 5678": codes are easier to read and type in two halves.
func formatTotpCode(_ code: String) -> String { code.count < 6 ? code : String(code.prefix(code.count / 2)) + " " + String(code.dropFirst(code.count / 2)) }

/// Same clipboard policy as passwords: see `SecretClipboard`.
@MainActor func copyLocally(_ value: String) { SecretClipboard.copy(value) }

/// Ring that empties as the current code ages, with the seconds left inside; red for the last five seconds.
struct TotpCountdown: View {
    let account: TotpAccount
    let date: Date
    var size: CGFloat = 32
    var body: some View {
        let remaining = account.remaining(at: date), urgent = remaining <= 5
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
            Circle().trim(from: 0, to: Double(remaining) / Double(account.period)).stroke(urgent ? Color.red : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(remaining)").font((size >= 48 ? Font.subheadline : Font.caption2).monospacedDigit()).foregroundStyle(urgent ? Color.red : Color.secondary)
        }.frame(width: size, height: size).accessibilityLabel("\(remaining) seconds left")
    }
}

/// A list row with the live code; tapping the code copies it.
struct TotpRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let record: VaultRecord
    var selection: RowSelection?
    @ScaledMetric(relativeTo: .body) private var titleSize = 15.0
    @ScaledMetric(relativeTo: .subheadline) private var subtitleSize = 13.0
    @ScaledMetric(relativeTo: .body) private var titleHeight = 22.0
    @ScaledMetric(relativeTo: .subheadline) private var subtitleHeight = 18.0
    @ScaledMetric(relativeTo: .title3) private var codeSize = 22.0
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 16) {
                RowLeading(record: record, selection: selection)
                VStack(alignment: .leading, spacing: 0) {
                    Text(record.name.isEmpty ? localized("Untitled") : record.name).font(.system(size: titleSize, weight: .medium)).foregroundStyle(Color.aOnSurface).lineLimit(1).frame(minHeight: titleHeight, alignment: .leading)
                    if let account = record.totp?.account, !account.isEmpty { Text(account).font(.system(size: subtitleSize)).foregroundStyle(Color.aOnSurfaceVariant).lineLimit(1).frame(minHeight: subtitleHeight, alignment: .leading) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if record.favorite { Image(systemName: "star.fill").font(.system(size: 18)).foregroundStyle(Color.favoriteStar).accessibilityLabel("Favorites") }
                if selection?.selecting == true { EmptyView() }
                else if let totp = record.totp {
                    let code = totp.code(at: context.date)
                    HStack(spacing: 0) {
                    Button { copyLocally(code) } label: {
                        Text(formatTotpCode(code)).font(.system(size: codeSize, weight: .semibold, design: .monospaced)).foregroundStyle(totp.remaining(at: context.date) <= 5 ? Color.red : Color.accentColor).lineLimit(1).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 8).padding(.vertical, 4)
                    }.buttonStyle(.borderless).layoutPriority(1).disabled(!settings.allowCopy).accessibilityLabel("Copy code")
                    TotpCountdown(account: totp, date: context.date)
                    }
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).accessibilityLabel("This 2FA entry is damaged and cannot make codes.")
                }
            }
        }
    }
}

/// Read-only view of a 2FA entry, the screen it opens to: avatar and name, the live code with countdown and copy, the setup key (hidden until shown) with its settings, notes, then the backup reminder. The pencil edits.
struct TotpDetail: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss
    let recordID: String
    @State private var keyShown = false
    @State private var editing: VaultRecord?
    @State private var deleting = false
    private var record: VaultRecord? { model.records.first { $0.id == recordID } }

    var body: some View {
        NavigationStack {
            if let record {
                let account = record.totp
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(spacing: 0) {
                            RecordAvatar(record: record, size: 72)
                            Text(record.name).font(.title2).multilineTextAlignment(.center).padding(.top, 12)
                            if let account, !account.account.isEmpty { Text(verbatim: account.account).font(.subheadline).foregroundStyle(Color.aOnSurfaceVariant) }
                        }.frame(maxWidth: .infinity).padding(.top, 8)
                        codeCard(account)
                        if let account { keyCard(account) }
                        if let notes = record.fields.first(where: { $0.kind == .note })?.value, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            SurfaceCard {
                                HStack(alignment: .top, spacing: 16) {
                                    IconBadge(symbol: "note.text")
                                    VStack(alignment: .leading, spacing: 2) { Text("Notes").font(.caption).foregroundStyle(Color.aOnSurfaceVariant); Text(verbatim: notes) }
                                }
                            }
                        }
                        Text("Setup keys are left out of CSV exports; only encrypted backups include them. Keep a backup: losing this phone without one means losing these codes.")
                            .font(.caption).foregroundStyle(Color.aOnSurfaceVariant).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    }.padding(.horizontal, 16).padding(.bottom, 32)
                }
                .background(Color.aBackground)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back") }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { toggleFavorite() } label: { Image(systemName: record.favorite ? "star.fill" : "star").foregroundStyle(record.favorite ? Color.favoriteStar : Color.primary) }
                            .accessibilityLabel(record.favorite ? "Remove from favorites" : "Add to favorites")
                        Button { keyShown = false; editing = record } label: { Image(systemName: "pencil") }.accessibilityLabel("Edit")
                        Menu {
                            Button(role: .destructive) { deleting = true } label: { Label("Delete 2FA code", systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More")
                    }
                }
                .sheet(item: $editing) { TotpEditor(record: $0) }
                .alert("Delete this 2FA code?", isPresented: $deleting) {
                    Button("Delete", role: .destructive) {
                        let updated = model.records.filter { $0.id != recordID }
                        model.run({ try $0.save(updated); return updated }, done: { dismiss() })
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("If two-factor authentication is still on for “\(record.name)”, you will need another backup of this key or the site's recovery codes to sign in.") }
            }
        }
    }

    @ViewBuilder private func codeCard(_ account: TotpAccount?) -> some View {
        SurfaceCard {
            if let account {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let code = account.code(at: context.date)
                    HStack(spacing: 8) {
                        Text(formatTotpCode(code)).font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .foregroundStyle(account.remaining(at: context.date) <= 5 ? Color.red : Color.accentColor)
                            .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity, alignment: .leading)
                        TotpCountdown(account: account, date: context.date, size: 48)
                        if settings.allowCopy {
                            Button { copyLocally(code) } label: { Image(systemName: "doc.on.doc").frame(width: 44, height: 44).contentShape(Rectangle()) }
                                .buttonStyle(.plain).accessibilityLabel("Copy code")
                        }
                    }
                }
            } else {
                Text("This 2FA entry is damaged and cannot make codes.").foregroundStyle(.red)
            }
        }
    }

    private func keyCard(_ account: TotpAccount) -> some View {
        let key = stride(from: 0, to: account.secretBase32.count, by: 4).map { start -> String in
            let chars = Array(account.secretBase32)
            return String(chars[start..<min(start + 4, chars.count)])
        }.joined(separator: " ")
        return SurfaceCard(padding: 0) {
            HStack(spacing: 0) {
                IconBadge(symbol: "key")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup key").font(.caption).foregroundStyle(Color.aOnSurfaceVariant)
                    Text(verbatim: keyShown ? key : "••••••••••").font(keyShown ? .body.monospaced() : .body)
                    Text(localizedFormat("%@ · %lld digits · %lld s", account.algorithm, account.digits, account.period)).font(.caption2).foregroundStyle(Color.aOnSurfaceVariant)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                Button { keyShown.toggle() } label: { Image(systemName: keyShown ? "eye.slash" : "eye").foregroundStyle(Color.aOnSurfaceVariant).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(keyShown ? "Hide setup key" : "Show setup key")))
            }.padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 12)
        }
    }

    private func toggleFavorite() {
        var updated = model.records
        guard let index = updated.firstIndex(where: { $0.id == recordID }) else { return }
        updated[index].favorite.toggle()
        let snapshot = updated
        model.run { try $0.save(snapshot); return snapshot }
    }
}

/// Reordering always includes every code, even while the main list is filtered.
struct TotpReorderView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss
    @State private var codes: [VaultRecord]
    private let originalIDs: [String]
    init(codes: [VaultRecord]) { _codes = State(initialValue: codes); originalIDs = codes.map(\.id) }
    var body: some View {
        NavigationStack {
            List {
                Text("Drag a code by its handle to move it.").font(.callout).foregroundStyle(Color.aOnSurfaceVariant)
                ForEach(codes) { record in
                    VaultEntryRow(record: record)
                    .accessibilityAction(named: Text("Move up")) { move(record.id, by: -1) }
                    .accessibilityAction(named: Text("Move down")) { move(record.id, by: 1) }
                }.onMove { codes.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder 2FA codes").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let updated = TotpOrder.apply(model.records, ordered: codes.map(\.id), now: ISO8601DateFormatter().string(from: Date()))
                        model.run({ try $0.save(updated); return updated }, done: { dismiss() })
                    }.disabled(model.busy || codes.map(\.id) == originalIDs)
                }
            }
            .disabled(model.busy)
        }.interactiveDismissDisabled(model.busy)
    }
    private func move(_ id: String, by offset: Int) {
        guard let index = codes.firstIndex(where: { $0.id == id }), codes.indices.contains(index + offset) else { return }
        codes.swapAt(index, index + offset)
    }
}

/// Adds or edits an authenticator account: scan its QR code, read it from a screenshot, or type the setup key.
/// A Google Authenticator export QR holds several accounts and is offered for import instead of filling the form.
struct TotpEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    let original: VaultRecord
    @State private var name: String
    @State private var issuer: String
    @State private var account: String
    @State private var key: String
    @State private var algorithm: String
    @State private var digits: Int
    @State private var period: Int
    @State private var notes: String
    @State private var favorite: Bool
    @State private var keyShown: Bool
    @State private var scanning = false
    @State private var photo: PhotosPickerItem?
    @State private var notice: String?
    @State private var noticeError = false
    @State private var pendingImport: [VaultRecord]?
    @State private var importNote = ""
    @State private var advanced: Bool

    init(record: VaultRecord) {
        original = record
        let start = record.totp
        _name = State(initialValue: record.name); _issuer = State(initialValue: start?.issuer ?? ""); _account = State(initialValue: start?.account ?? "")
        _key = State(initialValue: start?.secretBase32 ?? ""); _algorithm = State(initialValue: start?.algorithm ?? "SHA1")
        _digits = State(initialValue: start?.digits ?? 6); _period = State(initialValue: start?.period ?? 30)
        _notes = State(initialValue: record.fields.first { $0.kind == .note }?.value ?? ""); _favorite = State(initialValue: record.favorite)
        _keyShown = State(initialValue: start == nil)
        _advanced = State(initialValue: start.map { $0.algorithm != "SHA1" || $0.digits != 6 || $0.period != 30 } ?? false)
    }
    private var isNew: Bool { !model.records.contains { $0.id == original.id } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var secret: Data? { try? Totp.decodeBase32(key) }
    private var candidate: TotpAccount? {
        guard let secret else { return nil }
        return try? TotpAccount(secret: secret, issuer: issuer.isEmpty ? trimmedName : issuer, account: account.trimmingCharacters(in: .whitespaces), algorithm: algorithm, digits: digits, period: period)
    }
    private var duplicate: VaultRecord? {
        guard let secret else { return nil }
        return model.records.first { $0.id != original.id && $0.isTotp && $0.totp?.secret == secret }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Button { requestCamera() } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity, minHeight: 52) }
                            .buttonStyle(.borderedProminent).foregroundStyle(Color.aOnPrimary)
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("From image", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 52)
                                .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                        }
                    }
                    if let notice { Text(LocalizedStringKey(notice)).font(.subheadline).foregroundStyle(noticeError ? Color.red : Color.green).frame(maxWidth: .infinity, alignment: .leading) }
                    if let duplicate { Text("This 2FA code is already in your vault as “\(duplicate.name)”.").font(.subheadline).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
                    OutlinedField(label: localized("Service"), icon: "person.text.rectangle", text: $name)
                    OutlinedField(label: localized("Account (optional)"), icon: "person", text: $account, keyboard: .emailAddress)
                    OutlinedField(label: localized("Setup key"), icon: "key", text: $key, secure: !keyShown, monospaced: true, capitalization: .characters,
                                  supporting: localized(!key.isEmpty && secret == nil ? "The key must be Base32: letters A–Z and digits 2–7." : "The Base32 key shown with the QR code"),
                                  supportingIsError: !key.isEmpty && secret == nil, error: !key.isEmpty && secret == nil) {
                        Button { keyShown.toggle() } label: { Image(systemName: keyShown ? "eye.slash" : "eye").foregroundStyle(Color.aOnSurfaceVariant).frame(width: 36, height: 36).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(keyShown ? "Hide setup key" : "Show setup key")))
                    }
                    advancedCard
                    if let candidate {
                        SurfaceCard(radius: 16) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Current code").font(.caption).foregroundStyle(Color.aOnSurfaceVariant)
                                        Text(formatTotpCode(candidate.code(at: context.date))).font(.title2.monospaced()).foregroundStyle(.tint).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                    }
                                    Spacer()
                                    TotpCountdown(account: candidate, date: context.date)
                                }
                            }
                        }
                    }
                    OutlinedField(label: localized("Notes (optional)"), text: $notes, multiline: true, capitalization: .sentences)
                    Text("Setup keys are left out of CSV exports; only encrypted backups include them. Keep a backup: losing this phone without one means losing these codes.")
                        .font(.caption).foregroundStyle(Color.aOnSurfaceVariant).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }.padding(.horizontal, 16).padding(.bottom, 32)
            }
            .background(Color.aBackground)
            .navigationTitle(LocalizedStringKey(isNew ? "New 2FA code" : "Edit 2FA code")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Discard changes") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { favorite.toggle() } label: { Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.favoriteStar : Color.primary) }
                        .accessibilityLabel(favorite ? "Remove from favorites" : "Add to favorites")
                    Button("Save") { save() }.buttonStyle(.borderedProminent).foregroundStyle(Color.aOnPrimary).disabled(trimmedName.isEmpty || candidate == nil || model.busy)
                }
            }
            .sheet(isPresented: $scanning) { QRScannerSheet { text in scanning = false; handle(text) } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task { let data = try? await item.loadTransferable(type: Data.self); handle(data.flatMap(decodeQRCode)) }
            }
            .confirmationDialog(pendingImport?.isEmpty == false ? localizedFormat("Add %lld 2FA codes?", pendingImport?.count ?? 0) : localized("Nothing new to add from this QR code."), isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
                if let records = pendingImport, !records.isEmpty {
                    Button("Add") { pendingImport = nil; model.run({ try $0.merge(records) }, done: { dismiss() }) }
                }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            } message: { Text(importNote) }
        }
    }

    /// Collapsed by default, like Android: algorithm, digits and period for the few sites that need them.
    private var advancedCard: some View {
        SurfaceCard(radius: 16, padding: 0) {
            VStack(spacing: 0) {
                Button { withAnimation { advanced.toggle() } } label: {
                    HStack { Text("Advanced").font(.subheadline.weight(.semibold)); Spacer(); Image(systemName: advanced ? "chevron.up" : "chevron.down") }
                        .padding(16).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if advanced {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Most sites use SHA1, 6 digits and 30 seconds. Change these only if the site says so.").font(.caption).foregroundStyle(Color.aOnSurfaceVariant)
                        Text("Algorithm").font(.subheadline.weight(.medium))
                        Picker("Algorithm", selection: $algorithm) { ForEach(TotpAccount.algorithms, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                        Text("Digits").font(.subheadline.weight(.medium))
                        Picker("Digits", selection: $digits) { ForEach([6, 7, 8], id: \.self) { Text("\($0)").tag($0) } }.pickerStyle(.segmented)
                        OutlinedField(label: localized("Period (seconds)"), text: Binding(get: { String(period) }, set: { period = Int($0.filter(\.isNumber).prefix(3)) ?? 0 }), keyboard: .numberPad,
                                      error: !(1...300).contains(period))
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
        }
    }

    private func requestCamera() {
        notice = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: scanning = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in if granted { scanning = true } else { cameraDenied() } }
            }
        default: cameraDenied()
        }
    }
    private func cameraDenied() { noticeError = true; notice = "Camera access is needed to scan. Allow it in Settings, choose a screenshot, or enter the setup key instead." }

    private func handle(_ text: String?) {
        noticeError = true
        guard let text else { notice = "No QR code found in that image."; return }
        if Totp.isMigration(text) {
            guard let migration = try? Totp.parseMigration(text) else { notice = "That QR code is not a 2FA setup code."; return }
            let known = model.records.compactMap { $0.totp?.secret }
            var seen = Set<Data>(), fresh = [TotpAccount]()
            for account in migration.accounts where !known.contains(account.secret) && seen.insert(account.secret).inserted { fresh.append(account) }
            var lines = ["From a Google Authenticator export. They are added to your vault; nothing is replaced."]
            if migration.accounts.count > fresh.count { lines.append("\(migration.accounts.count - fresh.count) accounts already in your vault were skipped.") }
            if migration.skipped > 0 { lines.append("\(migration.skipped) counter-based (HOTP) accounts are not supported and were skipped.") }
            lines.append("If the export showed several QR codes, scan each one.")
            importNote = lines.joined(separator: "\n")
            pendingImport = fresh.map { $0.record() }
            notice = nil
            return
        }
        if text.lowercased().hasPrefix("otpauth://hotp") { notice = "Counter-based (HOTP) codes are not supported."; return }
        guard let scanned = try? Totp.parseURI(text) else { notice = "That QR code is not a 2FA setup code."; return }
        issuer = scanned.issuer; account = scanned.account; key = scanned.secretBase32
        algorithm = scanned.algorithm; digits = scanned.digits; period = scanned.period
        if trimmedName.isEmpty || isNew { name = scanned.issuer.isEmpty ? scanned.account : scanned.issuer }
        noticeError = false; notice = "QR code read. Check the details, then save."
    }

    private func save() {
        guard let candidate else { return }
        var record = original
        var fields = [VaultField]()
        var totpField = original.fields.first { $0.label == totpLabel } ?? VaultField(kind: .password, label: totpLabel)
        totpField.value = candidate.uri
        fields.append(totpField)
        let note = original.fields.first { $0.kind == .note }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var field = note ?? VaultField(kind: .note, label: "Notes"); field.value = notes; fields.append(field)
        }
        // Keep any other fields (e.g. from a backup made elsewhere) instead of silently dropping them.
        fields += original.fields.filter { $0.label != totpLabel && $0.id != note?.id }
        record.name = trimmedName; record.favorite = favorite; record.type = "totp"; record.fields = fields
        record.updatedAt = ISO8601DateFormatter().string(from: Date())
        var updated = model.records
        if let index = updated.firstIndex(where: { $0.id == record.id }) { updated[index] = record } else { updated.append(record) }
        let snapshot = updated
        model.run({ try $0.save(snapshot); return snapshot }, done: { dismiss() })
    }
}

/// Decodes a QR code from a picture on the device (Core Image); nothing leaves the phone.
func decodeQRCode(_ data: Data) -> String? {
    guard let image = CIImage(data: data) else { return nil }
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    return detector?.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
}

struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            QRScannerView(onCode: onCode).ignoresSafeArea()
                .overlay(alignment: .top) { Text("Point the camera at the 2FA QR code").font(.callout).padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule()).padding() }
                .overlay { RoundedRectangle(cornerRadius: 24).stroke(.white, lineWidth: 3).frame(width: 240, height: 240) }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    /// Report every code read (a transfer's loop of frames) instead of only the first.
    var continuous = false
    func makeUIViewController(context: Context) -> QRScannerController { let controller = QRScannerController(); controller.onCode = onCode; controller.continuous = continuous; return controller }
    func updateUIViewController(_ controller: QRScannerController, context: Context) { controller.onCode = onCode }
}

/// Live camera preview that reports the first QR code it reads, once, or with `continuous` every one. Detection is done by AVFoundation on the device.
final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var continuous = false
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        // Every scan starts at 2x (see QRScanZoom), a transfer's stream of codes and a 2FA setup code alike.
        if (try? device.lockForConfiguration()) != nil { device.videoZoomFactor = CGFloat(QRScanZoom.factor(maxZoom: Double(device.activeFormat.videoMaxZoomFactor))); device.unlockForConfiguration() }
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.addSublayer(layer)
        preview = layer
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.layer.bounds }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { if !session.isRunning { session.startRunning() } }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { if session.isRunning { session.stopRunning() } }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let text = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        if continuous { onCode?(text); return }
        delivered = true
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        onCode?(text)
    }
}
