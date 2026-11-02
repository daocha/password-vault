import SwiftUI
import VaultCore

/// Android's colour roles from Theme.kt (light and dark), so Vault health looks the same on both phones.
extension Color {
    static func android(light: UInt32, dark: UInt32) -> Color {
        func rgb(_ value: UInt32) -> UIColor { UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1) }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
    }
    static let aBackground = android(light: 0xF8F9FF, dark: 0x111318)
    static let aCard = android(light: 0xF2F3FA, dark: 0x191C20)
    static let aTrack = android(light: 0xE1E2E9, dark: 0x33353A)
    static let aOnSurface = android(light: 0x191C20, dark: 0xE2E2E9)
    static let aOnSurfaceVariant = android(light: 0x44474E, dark: 0xC4C6D0)
    static let aOutlineVariant = android(light: 0xC4C6D0, dark: 0x44474E)
    static let aPrimary = android(light: 0x244E87, dark: 0xA9C7FF)
    static let aOnPrimary = android(light: 0xFFFFFF, dark: 0x0A305F)
    static let aError = android(light: 0xBA1A1A, dark: 0xFFB4AB)
    static let aSecondaryContainer = android(light: 0xD9E3F8, dark: 0x3E4759)
    static let aOnSecondaryContainer = android(light: 0x121C2B, dark: 0xD9E3F8)
    static let aErrorContainer = android(light: 0xFFDAD6, dark: 0x93000A)
    static let aOnErrorContainer = android(light: 0x410002, dark: 0xFFDAD6)
}

/// The vault health report, laid out like Android: a privacy note, the score, then one rounded card per group with its icon, count and a
/// short explanation, left-aligned. Everything is computed from the unlocked records in memory; nothing is sent anywhere.
/// Every group starts collapsed; `focus` opens one group and scrolls to it (the expiry banner opens "expiring").
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
            ScrollView {
                LazyVStack(spacing: 12) {
                    privacyNote
                    scoreCard(report)
                    if report.checked > 0 && report.problemCount == 0 && report.noTwoFactor.isEmpty {
                        Label("No problems found.", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(Color.aOnSurface)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !report.reused.isEmpty {
                        group("reused", "Reused passwords", report.reused.count, "The same password on several sites: one leak exposes them all.") {
                            ForEach(Array(report.reused.enumerated()), id: \.offset) { index, set in
                                if index > 0 { Divider().overlay(Color.aOutlineVariant) }
                                reusedSet(set)
                            }
                        }
                    }
                    if !report.weak.isEmpty {
                        group("weak", "Weak passwords", report.weak.count, "Easy to guess. Replace them with generated ones.") {
                            ForEach(report.weak, id: \.password.field.id) { issue($0.password.record, "\(displayFieldLabel($0.password.field.label)) · \(localized($0.score == 0 ? "Very weak" : "Weak"))") }
                        }
                    }
                    if !report.old.isEmpty {
                        group("old", "Old passwords", report.old.count, "Not changed for over a year.") {
                            ForEach(report.old, id: \.password.field.id) { issue($0.password.record, "\(displayFieldLabel($0.password.field.label)) · \(localizedFormat("Unchanged since %@", Self.format($0.since)))") }
                        }
                    }
                    if !report.expiring.isEmpty {
                        group("expiring", "Expired or expiring soon", report.expiring.count, "Expired, or expiring within the next 30 days.") {
                            ForEach(report.expiring) { r in issue(r, localizedFormat(r.expiryState() == .expired ? "Expired %@" : "Expires %@", r.expiryDate.map(Self.format) ?? "")) }
                        }
                    }
                    if !report.noTwoFactor.isEmpty {
                        group("twoFactor", "Consider two-factor codes", report.noTwoFactor.count, "Well-known services with no 2FA code saved in PassVault. If you already use another authenticator or text messages, you can ignore this.", advice: true) {
                            ForEach(report.noTwoFactor) { issue($0, $0.website) }
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 32)
            }
            .background(Color.aBackground)
            .navigationTitle("Vault health").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back") } }
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

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.iphone")
            VStack(alignment: .leading, spacing: 4) {
                Text("Checked on this phone only").font(.footnote.weight(.bold))
                Text("Your passwords are never uploaded or sent anywhere. PassVault checks them here, on this device, and nothing leaves it. Because it works offline, it cannot look passwords up in online lists of leaked passwords.")
                    .font(.footnote).multilineTextAlignment(.leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color.aOnSecondaryContainer)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.aSecondaryContainer, in: RoundedRectangle(cornerRadius: 16))
    }

    private func scoreCard(_ report: HealthReport) -> some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.aTrack, lineWidth: 6)
                Circle().trim(from: 0, to: Double(report.score ?? 0) / 100).stroke((report.score ?? 100) >= 70 ? Color.aPrimary : Color.aError, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(report.score.map(String.init) ?? "—").font(.title3.bold()).foregroundStyle(Color.aOnSurface)
            }.frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text("Health score").font(.caption.weight(.medium)).foregroundStyle(Color.aOnSurfaceVariant)
                Text(LocalizedStringKey(report.score.map(Self.label) ?? "No passwords to check yet")).font(.callout.weight(.medium)).foregroundStyle(Color.aOnSurface)
                if report.checked > 0 { Text("\(report.checked) passwords checked").font(.caption).foregroundStyle(Color.aOnSurfaceVariant) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.aCard, in: RoundedRectangle(cornerRadius: 20))
    }

    private func toggle(_ key: String) { if !flipped.insert(key).inserted { flipped.remove(key) } }

    /// The icon Android shows for each group; the "consider two-factor" group is advice, the rest are problems and get the red badge.
    private static let groupIcons: [String: String] = [
        "reused": "doc.on.doc", "weak": "exclamationmark.shield", "old": "clock.arrow.circlepath", "expiring": "calendar", "twoFactor": "number",
    ]

    /// One rounded card per group: its header (tap to open or close it) and, when open, its entries.
    private func group<Content: View>(_ key: String, _ title: String, _ count: Int, _ body: String, advice: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Button { withAnimation { toggle(key) } } label: {
                HStack(spacing: 12) {
                    Image(systemName: Self.groupIcons[key] ?? "exclamationmark.triangle").font(.system(size: 18))
                        .foregroundStyle(advice ? Color.aOnSecondaryContainer : Color.aOnErrorContainer)
                        .frame(width: 40, height: 40).background(advice ? Color.aSecondaryContainer : Color.aErrorContainer, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(localized(title))  (\(count))").font(.callout.weight(.medium)).foregroundStyle(Color.aOnSurface)
                        Text(LocalizedStringKey(body)).font(.caption).foregroundStyle(Color.aOnSurfaceVariant).multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isOpen(key) ? "chevron.up" : "chevron.down").font(.footnote).foregroundStyle(Color.aOnSurfaceVariant)
                }
                .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint(isOpen(key) ? "Hide" : "Show")
            if isOpen(key) { content() }
        }
        .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.aCard, in: RoundedRectangle(cornerRadius: 20))
        .id(key)
    }

    /// Each password shared by several entries is its own set, one line until opened.
    private func reusedSet(_ set: [CheckedPassword]) -> some View {
        let key = "reused:" + set[0].field.id, open = isOpen(key)
        return VStack(spacing: 0) {
            Button { withAnimation { toggle(key) } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(localizedFormat("Shared by %lld entries", set.count)).font(.caption.weight(.medium)).foregroundStyle(Color.aError)
                        if !open { Text(set.map(\.record.name).joined(separator: ", ")).font(.caption).foregroundStyle(Color.aOnSurfaceVariant).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.footnote).foregroundStyle(Color.aOnSurfaceVariant)
                }
                .padding(.leading, 16).padding(.trailing, 12).padding(.top, 12).padding(.bottom, open ? 4 : 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint(open ? "Hide" : "Show")
            if open { ForEach(set, id: \.field.id) { issue($0.record, displayFieldLabel($0.field.label)) } }
        }
    }

    private func issue(_ record: VaultRecord, _ detail: String) -> some View {
        Button { viewing = record } label: {
            HStack(spacing: 12) {
                RecordAvatar(record: record, size: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text(record.name).font(.callout).foregroundStyle(Color.aOnSurface).lineLimit(1)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Color.aOnSurfaceVariant).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.aOnSurfaceVariant)
            }
            .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    static func label(_ score: Int) -> String { score >= 90 ? "Excellent" : score >= 70 ? "Good" : score >= 50 ? "Fair" : "Needs attention" }
    static func format(_ date: DateComponents) -> String { Expiry.localDate(date)?.formatted(date: .abbreviated, time: .omitted) ?? "" }
}
