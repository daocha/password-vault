import SwiftUI
import VaultCore

/// The vault health report. Everything is computed from the unlocked records in memory; nothing is sent anywhere.
/// Every group starts collapsed, as a header with its count; `focus` opens one group and scrolls to it (the expiry banner opens "expiring").
struct HealthView: View {
    var focus: String? = nil
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State private var editing: VaultRecord?
    /// Open groups, and open "shared by" sets of reused passwords ("reused:<field id>").
    @State private var open: Set<String> = []
    var body: some View {
        let report = VaultHealth.check(model.records)
        NavigationStack { ScrollViewReader { proxy in
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
                    Section { if open.contains("reused") { ForEach(Array(report.reused.enumerated()), id: \.offset) { _, group in
                        // Each password shared by several entries is its own set, one line until opened.
                        let key = "reused:" + group[0].field.id
                        Button { toggle(key) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Shared by \(group.count) entries").font(.caption).foregroundStyle(.red)
                                    if !open.contains(key) { Text(group.map(\.record.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                Image(systemName: open.contains(key) ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityHint(open.contains(key) ? "Hide" : "Show")
                        if open.contains(key) { ForEach(group, id: \.field.id) { row($0.record, $0.field.label) } }
                    } } } header: { header("reused", "Reused passwords", report.reused.count, "The same password on several sites: one leak exposes them all.") }
                }
                if !report.weak.isEmpty {
                    Section { if open.contains("weak") { ForEach(report.weak, id: \.password.field.id) { row($0.password.record, "\($0.password.field.label) · \($0.score == 0 ? "Very weak" : "Weak")") } } }
                        header: { header("weak", "Weak passwords", report.weak.count, "Easy to guess. Replace them with generated ones.") }
                }
                if !report.old.isEmpty {
                    Section { if open.contains("old") { ForEach(report.old, id: \.password.field.id) { row($0.password.record, "\($0.password.field.label) · Unchanged since \(Self.format($0.since))") } } }
                        header: { header("old", "Old passwords", report.old.count, "Not changed for over a year.") }
                }
                if !report.expiring.isEmpty {
                    Section { if open.contains("expiring") { ForEach(report.expiring) { r in row(r, "\(r.expiryState() == .expired ? "Expired" : "Expires") \(r.expiryDate.map(Self.format) ?? "")") } } }
                        header: { header("expiring", "Expired or expiring soon", report.expiring.count, "Expired, or expiring within the next 30 days.") }
                }
                if !report.noTwoFactor.isEmpty {
                    Section { if open.contains("twoFactor") { ForEach(report.noTwoFactor) { row($0, $0.website) } } }
                        header: { header("twoFactor", "Consider two-factor codes", report.noTwoFactor.count, "Well-known services with no 2FA code saved in PassVault. If you already use another authenticator or text messages for them, ignore this.") }
                }
            }
            .navigationTitle("Vault health").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } }
            .sheet(item: $editing) { RecordEditor(record: $0) }
            .onAppear {
                guard let focus else { return }
                open = [focus]
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(focus, anchor: .top) } }
            }
        } }
    }
    private func toggle(_ key: String) { if !open.insert(key).inserted { open.remove(key) } }
    /// A group's header: tap it to open or close the group.
    private func header(_ key: String, _ title: String, _ count: Int, _ body: String) -> some View {
        Button { withAnimation { toggle(key) } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) { Text("\(title) (\(count))"); Text(body).font(.caption).textCase(nil) }
                Spacer()
                Image(systemName: open.contains(key) ? "chevron.up" : "chevron.down")
            }
        }.foregroundStyle(.secondary).accessibilityHint(open.contains(key) ? "Hide" : "Show").id(key)
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
