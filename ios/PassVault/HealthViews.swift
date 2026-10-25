import SwiftUI
import VaultCore

/// The vault health report. Everything is computed from the unlocked records in memory; nothing is sent anywhere.
struct HealthView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State private var editing: VaultRecord?
    var body: some View {
        let report = VaultHealth.check(model.records)
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Checked on this phone only").font(.headline)
                            Text("Your passwords are never uploaded or sent anywhere. PassVault checks them here, on this device, and nothing leaves it. Because it works offline, it cannot look passwords up in online lists of leaked passwords.").font(.footnote)
                        }
                    } icon: { Image(systemName: "lock.iphone") }
                }
                Section {
                    HStack(spacing: 20) {
                        ZStack {
                            Circle().stroke(.quaternary, lineWidth: 6)
                            Circle().trim(from: 0, to: Double(report.score ?? 0) / 100).stroke((report.score ?? 100) >= 70 ? Color.accentColor : .red, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                            Text(report.score.map(String.init) ?? "—").font(.title2.bold())
                        }.frame(width: 72, height: 72)
                        VStack(alignment: .leading) {
                            Text("Health score").font(.caption).foregroundStyle(.secondary)
                            Text(report.score.map(Self.label) ?? "No passwords to check yet").font(.headline)
                            if report.checked > 0 { Text("\(report.checked) passwords checked").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 6)
                    if report.checked > 0 && report.problemCount == 0 && report.noTwoFactor.isEmpty { Label("No problems found.", systemImage: "checkmark.circle") }
                }
                if !report.reused.isEmpty {
                    Section { ForEach(Array(report.reused.enumerated()), id: \.offset) { _, group in
                        Text("Shared by \(group.count) entries").font(.caption).foregroundStyle(.red)
                        ForEach(group, id: \.field.id) { row($0.record, $0.field.label) }
                    } } header: { header("Reused passwords", "The same password on several sites: one leak exposes them all.") }
                }
                if !report.weak.isEmpty {
                    Section { ForEach(report.weak, id: \.password.field.id) { row($0.password.record, "\($0.password.field.label) · \($0.score == 0 ? "Very weak" : "Weak")") } }
                        header: { header("Weak passwords", "Easy to guess. Replace them with generated ones.") }
                }
                if !report.old.isEmpty {
                    Section { ForEach(report.old, id: \.password.field.id) { row($0.password.record, "\($0.password.field.label) · Unchanged since \(Self.format($0.since))") } }
                        header: { header("Old passwords", "Not changed for over a year.") }
                }
                if !report.expiring.isEmpty {
                    Section { ForEach(report.expiring) { r in row(r, "\(r.expiryState() == .expired ? "Expired" : "Expires") \(r.expiryDate.map(Self.format) ?? "")") } }
                        header: { header("Expired or expiring soon", "Expired, or expiring within the next 30 days.") }
                }
                if !report.noTwoFactor.isEmpty {
                    Section { ForEach(report.noTwoFactor) { row($0, $0.website) } }
                        header: { header("Consider two-factor codes", "Well-known services with no 2FA code saved in PassVault. If you already use another authenticator or text messages for them, ignore this.") }
                }
            }
            .navigationTitle("Vault health").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } }
            .sheet(item: $editing) { RecordEditor(record: $0) }
        }
    }
    private func header(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(title); Text(body).font(.caption).textCase(nil) }
    }
    private func row(_ record: VaultRecord, _ detail: String) -> some View {
        Button { editing = record } label: {
            HStack(spacing: 12) {
                RecordIcon(record: record)
                VStack(alignment: .leading) {
                    Text(record.name).foregroundStyle(.primary)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
    }
    static func label(_ score: Int) -> String { score >= 90 ? "Excellent" : score >= 70 ? "Good" : score >= 50 ? "Fair" : "Needs attention" }
    static func format(_ date: DateComponents) -> String { Expiry.localDate(date)?.formatted(date: .abbreviated, time: .omitted) ?? "" }
}
