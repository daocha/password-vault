import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import VaultCore

/// A transfer being sent: kept through a lock for `TransferPayload.keep` (leaving the app to share the file locks it), and shown again only
/// after unlocking the same vault it was made from.
struct TransferPayload: Identifiable {
    static let keep: TimeInterval = 600
    let id = UUID(); let code: String; let data: Data; let decoy: Bool; let expiresAt = Date().addingTimeInterval(keep)
    /// Built once: the receiver starts over whenever the session id changes, so every frame must come from the same split.
    let frames: TransferFrames.Sender?
    init(code: String, data: Data, decoy: Bool) { self.code = code; self.data = data; self.decoy = decoy; frames = try? TransferFrames.Sender(data) }
}

/// A QR code, one point per module scaled without smoothing.
func qrImage(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8); filter.correctionLevel = "L"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cg)
}

/// The old phone: an animated QR code of the encrypted transfer, every chunk once and then fresh mixes of them (see `TransferFrames`).
/// The one-time code is shown only on request, and the QR code is hidden while it is, so one photo never holds both.
struct TransferSendView: View {
    let payload: TransferPayload
    @Environment(\.dismiss) var dismiss
    @State private var index = 0
    @State private var showCode = false
    @State private var saving = false
    @State private var saved = false
    var body: some View {
        let frames = payload.frames
        NavigationStack {
            VStack(spacing: 16) {
                Text("On the new phone, open PassVault, go to Import, export & security, Receive from another phone, and point its camera at this screen. Keep this screen open until it is done.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if showCode {
                    VStack(spacing: 12) {
                        Text("Transfer code").font(.headline)
                        Text(Transfer.display(payload.code)).font(.system(size: 30, weight: .bold, design: .monospaced))
                        Text("Type this code on the new phone when it asks. The QR codes hold only encrypted data; without this code they are useless, so don't let anyone photograph it.").font(.footnote).multilineTextAlignment(.center)
                    }.padding(24).frame(maxWidth: .infinity).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                } else if let frames, let image = qrImage(frames.frame(index)) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    Text("Code \(index % frames.count + 1) of \(frames.count)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This vault is too large for QR codes. Save a transfer file instead.").multilineTextAlignment(.center)
                }
                Button(showCode ? "Show QR code again" : "Show transfer code") { showCode.toggle() }.buttonStyle(.borderedProminent)
                Button("Save as file instead") { saving = true }
                Text("Leaving PassVault to send the file locks it. Unlock again within 10 minutes and this screen comes back with the same code.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if saved { Text("Transfer file saved. On the new phone, import it and type the transfer code.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                Spacer()
            }
            .padding()
            .navigationTitle("Send to another phone").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            // As on Android: any frame helps the receiver, so one it skips costs nothing, and a fast camera reads more.
            .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in if !showCode && frames != nil { index += 1 } }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            // A transfer file is not a backup: its code is shown once and not kept, so it does not count toward the backup reminder.
            .fileExporter(isPresented: $saving, document: ExportDocument(data: payload.data), contentType: .data, defaultFilename: exportFileName("pvtransfer").replacingOccurrences(of: "passvault_", with: "passvault_transfer_")) { result in
                if case .success = result { saved = true }
            }
        }
    }
}

/// The new phone: scans the old phone's looping QR code, frames in any order, until the whole encrypted transfer has arrived.
struct TransferReceiveView: View {
    let done: (Data) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var collector = TransferFrames.Collector()
    @State private var received = 0
    @State private var total = 0
    @State private var finished = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Point the camera at the moving QR code on the old phone. It does not need every code: ones it misses are made up by later ones.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                QRScannerView(onCode: { text in
                    guard !finished, collector.add(text) else { return }
                    received = collector.received; total = collector.total
                    if let data = collector.result() { finished = true; done(data) }
                }, continuous: true).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Hold this phone about 20–30 cm (8–12 in) away, so the code fills about half of the square. Up close, many cameras cannot focus.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if total == 0 { Text("Waiting for the first code…") } else {
                    ProgressView(value: Double(received), total: Double(total))
                    Text("Received \(received) of \(total)")
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Receive from another phone").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
}
