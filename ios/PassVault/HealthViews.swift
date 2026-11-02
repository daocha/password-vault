import SwiftUI
import VaultCore

/// The vault health report. Everything is computed from the unlocked records in memory; nothing is sent anywhere.
/// Every group starts collapsed, as a header with its count; `focus` opens one group and scrolls to it (the expiry banner opens "expiring").
struct HealthView: View {
    var focus: String? = nil
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State private var viewing: VaultRecord?
    /// Groups (and "shared by" sets of reused passwords, "reused:<field id>") the person has flipped from their starting state.
    /// A group is open when it is the focused one XOR flipped, so the focused group is open from the first frame with no state to set up.
    @State private var flipped: Set<String> = []
    private func isOpen(_ key: String) -> Bool { (key == focus) != flipped.contains(key) }
    var body: some View {
        let report = VaultHealth.check(model.records)
        NavigationStack { ScrollViewReader { proxy in
            List {
                // Top cards, laid out like Android's: a tinted privacy note, then the score card, then the all-clear line.
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.iphone")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Checked on this phone only").font(.subheadline.weight(.bold))
                        Text("Your passwords are never uploaded or sent anywhere. PassVault checks them here, on this device, and nothing leaves it. Because it works offline, it cannot look passwords up in online lists of leaked passwords.").font(.footnote).font(.subheadline)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                .topCardRow(top: 0)
                HStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                        Circle().trim(from: 0, to: Double(report.score ?? 0) / 100).stroke((report.score ?? 100) >= 70 ? Color.accentColor : .red, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text(report.score.map(String.init) ?? "—").font(.title2.bold())
                    }.frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Health score").font(.caption).foregroundStyle(.secondary)
                        Text(LocalizedStringKey(report.score.map(Self.label) ?? "No passwords to check yet")).font(.headline)
                        if report.checked > 0 { Text("\(report.checked) passwords checked").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                .topCardRow()
                if report.checked > 0 && report.problemCount == 0 && report.noTwoFactor.isEmpty {
                    Label("No problems found.", systemImage: "checkmark.circle").padding(16).topCardRow()
                }
                if !report.reused.isEmpty {
                    Section { if isOpen("reused") { ForEach(Array(report.reused.enumerated()), id: \.offset) { _, group in
                        // Each password shared by several entries is its own set, one line until opened.
                        let key = "reused:" + group[0].field.id
                        Button { toggle(key) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Shared by \(group.count) entries").font(.caption).foregroundStyle(.red)
                                    if !isOpen(key) { Text(group.map(\.record.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                Image(systemName: isOpen(key) ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityHint(isOpen(key) ? "Hide" : "Show")
                        if isOpen(key) { ForEach(group, id: \.field.id) { row($0.record, $0.field.label) } }
                    } } } header: { header("reused", "Reused passwords", report.reused.count, "The same password on several sites: one leak exposes them all.") }
                }
                if !report.weak.isEmpty {
                    Section { if isOpen("weak") { ForEach(report.weak, id: \.password.field.id) { row($0.password.record, "\($0.password.field.label) · \($0.score == 0 ? "Very weak" : "Weak")") } } }
                        header: { header("weak", "Weak passwords", report.weak.count, "Easy to guess. Replace them with generated ones.") }
                }
                if !report.old.isEmpty {
                    Section { if isOpen("old") { ForEach(report.old, id: \.password.field.id) { row($0.password.record, "\($0.password.field.label) · Unchanged since \(Self.format($0.since))") } } }
                        header: { header("old", "Old passwords", report.old.count, "Not changed for over a year.") }
                }
                if !report.expiring.isEmpty {
                    Section { if isOpen("expiring") { ForEach(report.expiring) { r in row(r, "\(r.expiryState() == .expired ? "Expired" : "Expires") \(r.expiryDate.map(Self.format) ?? "")") } } }
                        header: { header("expiring", "Expired or expiring soon", report.expiring.count, "Expired, or expiring within the next 30 days.") }
                }
                if !report.noTwoFactor.isEmpty {
                    Section { if isOpen("twoFactor") { ForEach(report.noTwoFactor) { row($0, $0.website) } } }
                        header: { header("twoFactor", "Consider two-factor codes", report.noTwoFactor.count, "Well-known services with no 2FA code saved in PassVault. If you already use another authenticator or text messages for them, ignore this.") }
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .navigationTitle("Vault health").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } }
            .fullScreenCover(item: $viewing) { record in
                if record.isTotp { TotpDetail(recordID: record.id) }
                else if record.isSeed { SeedDetail(recordID: record.id) }
                else { RecordDetail(recordID: record.id) }
            }
            .onAppear {
                guard let focus else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo(focus, anchor: .top) } }
            }
        } }
    }
    private func toggle(_ key: String) { if !flipped.insert(key).inserted { flipped.remove(key) } }
    /// A group's header: tap it to open or close the group.
    /// The icon Android shows for each group; the "consider two-factor" group is advice, the rest are problems and get the red badge.
    private static let groupIcons: [String: String] = [
        "reused": "doc.on.doc", "weak": "exclamationmark.shield", "old": "clock.arrow.circlepath", "expiring": "calendar", "twoFactor": "number",
    ]
    private func header(_ key: String, _ title: String, _ count: Int, _ body: String) -> some View {
        Button { withAnimation { toggle(key) } } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: Self.groupIcons[key] ?? "exclamationmark.triangle", tint: key == "twoFactor" ? .accentColor : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(localized(title)) (\(count))").font(.headline).foregroundStyle(.primary)
                    Text(LocalizedStringKey(body)).font(.caption).foregroundStyle(.secondary).textCase(nil)
                }
                Spacer()
                Image(systemName: isOpen(key) ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }.buttonStyle(.plain).accessibilityHint(isOpen(key) ? "Hide" : "Show").id(key)
    }
    private func row(_ record: VaultRecord, _ detail: String) -> some View {
        Button { viewing = record } label: {
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

private extension View {
    /// A plain block on the grouped background instead of a grouped-list row.
    func topCardRow(top: CGFloat = 6) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 16, bottom: 6, trailing: 16)).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}
