import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import CoreImage
import VaultCore

/// "123 456", "1234 5678": codes are easier to read and type in two halves.
func formatTotpCode(_ code: String) -> String { code.count < 6 ? code : String(code.prefix(code.count / 2)) + " " + String(code.dropFirst(code.count / 2)) }

/// Same clipboard policy as passwords: this device only, expiring after 30 seconds.
func copyLocally(_ value: String) {
    UIPasteboard.general.setItems([["public.utf8-plain-text": value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)])
}

/// Ring that empties as the current code ages, with the seconds left inside; red for the last five seconds.
struct TotpCountdown: View {
    let account: TotpAccount
    let date: Date
    var body: some View {
        let remaining = account.remaining(at: date), urgent = remaining <= 5
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
            Circle().trim(from: 0, to: Double(remaining) / Double(account.period)).stroke(urgent ? Color.red : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(remaining)").font(.caption2.monospacedDigit()).foregroundStyle(urgent ? Color.red : Color.secondary)
        }.frame(width: 28, height: 28).accessibilityLabel("\(remaining) seconds left")
    }
}

/// A list row with the live code; tapping the code copies it.
struct TotpRow: View {
    let record: VaultRecord
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 14) {
                RecordIcon(record: record)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name.isEmpty ? "Untitled" : record.name).font(.headline).foregroundStyle(.primary)
                    if let account = record.totp?.account, !account.isEmpty { Text(account).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if let totp = record.totp {
                    let code = totp.code(at: context.date)
                    Button { copyLocally(code) } label: {
                        Text(formatTotpCode(code)).font(.title3.monospaced().weight(.semibold)).foregroundStyle(totp.remaining(at: context.date) <= 5 ? Color.red : Color.accentColor)
                    }.buttonStyle(.borderless).accessibilityLabel("Copy code")
                    TotpCountdown(account: totp, date: context.date)
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).accessibilityLabel("This 2FA entry is damaged and cannot make codes.")
                }
            }.padding(.vertical, 5)
        }
    }
}

/// Adds or edits an authenticator account: scan its QR code, read it from a screenshot, or type the setup key.
/// A Google Authenticator export QR holds several accounts and is offered for import instead of filling the form.
struct TotpEditor: View {
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
    @State private var confirmDelete = false

    init(record: VaultRecord) {
        original = record
        let start = record.totp
        _name = State(initialValue: record.name); _issuer = State(initialValue: start?.issuer ?? ""); _account = State(initialValue: start?.account ?? "")
        _key = State(initialValue: start?.secretBase32 ?? ""); _algorithm = State(initialValue: start?.algorithm ?? "SHA1")
        _digits = State(initialValue: start?.digits ?? 6); _period = State(initialValue: start?.period ?? 30)
        _notes = State(initialValue: record.fields.first { $0.kind == .note }?.value ?? ""); _favorite = State(initialValue: record.favorite)
        _keyShown = State(initialValue: start == nil)
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
            Form {
                Section {
                    Button("Scan QR code", systemImage: "qrcode.viewfinder") { requestCamera() }
                    PhotosPicker(selection: $photo, matching: .images) { Label("Read QR code from a screenshot", systemImage: "photo") }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(noticeError ? Color.red : Color.green) }
                    if let duplicate { Text("This 2FA code is already in your vault as “\(duplicate.name)”.").font(.footnote).foregroundStyle(.red) }
                }
                Section("Account") {
                    TextField("Service", text: $name)
                    TextField("Account (optional)", text: $account).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        if keyShown { TextField("Setup key", text: $key).font(.body.monospaced()) } else { SecureField("Setup key", text: $key) }
                        Button { keyShown.toggle() } label: { Image(systemName: keyShown ? "eye.slash" : "eye") }.buttonStyle(.borderless).accessibilityLabel(keyShown ? "Hide setup key" : "Show setup key")
                    }.textInputAutocapitalization(.characters).autocorrectionDisabled()
                    if !key.isEmpty && secret == nil { Text("The key must be Base32: letters A–Z and digits 2–7.").font(.footnote).foregroundStyle(.red) }
                    Toggle("Favorite", isOn: $favorite)
                }
                Section {
                    Picker("Algorithm", selection: $algorithm) { ForEach(TotpAccount.algorithms, id: \.self) { Text($0).tag($0) } }
                    Picker("Digits", selection: $digits) { ForEach([6, 7, 8], id: \.self) { Text("\($0)").tag($0) } }
                    HStack { Text("Period (seconds)"); TextField("30", value: $period, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                } header: { Text("Advanced") } footer: { Text("Most sites use SHA1, 6 digits and 30 seconds. Change these only if the site says so.") }
                if let candidate {
                    Section("Current code") {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack {
                                Text(formatTotpCode(candidate.code(at: context.date))).font(.title2.monospaced().weight(.semibold)).foregroundStyle(.tint)
                                Spacer()
                                TotpCountdown(account: candidate, date: context.date)
                                Button("Copy", systemImage: "doc.on.doc") { copyLocally(candidate.code()) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("Notes") { TextField("Notes (optional)", text: $notes, axis: .vertical) }
                Section { Text("Setup keys are left out of CSV exports; only encrypted backups include them. Keep a backup: losing this phone without one means losing these codes.").font(.footnote).foregroundStyle(.secondary) }
                if !isNew { Section { Button("Delete 2FA code", role: .destructive) { confirmDelete = true } } }
            }
            .navigationTitle(isNew ? "New 2FA code" : "Edit 2FA code").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(trimmedName.isEmpty || candidate == nil) }
            }
            .sheet(isPresented: $scanning) { QRScannerSheet { text in scanning = false; handle(text) } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task { let data = try? await item.loadTransferable(type: Data.self); handle(data.flatMap(decodeQRCode)) }
            }
            .confirmationDialog(pendingImport?.isEmpty == false ? "Add \(pendingImport?.count ?? 0) 2FA codes?" : "Nothing new to add from this QR code.", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
                if let records = pendingImport, !records.isEmpty {
                    Button("Add") { pendingImport = nil; model.run({ try $0.merge(records) }, done: { dismiss() }) }
                }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            } message: { Text(importNote) }
            .confirmationDialog("Delete this 2FA code?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let updated = model.records.filter { $0.id != original.id }
                    model.run({ try $0.save(updated); return updated }, done: { dismiss() })
                }
            } message: { Text("If two-factor authentication is still on for “\(original.name)”, you will need another backup of this key or the site's recovery codes to sign in.") }
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
    func makeUIViewController(context: Context) -> QRScannerController { let controller = QRScannerController(); controller.onCode = onCode; return controller }
    func updateUIViewController(_ controller: QRScannerController, context: Context) { controller.onCode = onCode }
}

/// Live camera preview that reports the first QR code it reads, once. Detection is done by AVFoundation on the device.
final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
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
        delivered = true
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        onCode?(text)
    }
}
