import SwiftUI
import VaultCore

/// Stored labels the app and importers create; shown translated, never rewritten in the data. A label the user typed is shown as is.
private let builtInFieldLabels: Set<String> = [
    "Username", "Password", "Notes", "Security question", cardHolderLabel, cardNumberLabel, cardExpiryLabel, cardCodeLabel, cardPinLabel,
]
@MainActor func displayFieldLabel(_ label: String) -> String { builtInFieldLabels.contains(label) ? localized(label) : label }

func fieldSymbol(_ field: VaultField) -> String {
    switch field.label {
    case cardNumberLabel: return "creditcard"
    case cardExpiryLabel: return "calendar"
    case cardCodeLabel, cardPinLabel: return "number"
    default:
        switch field.kind { case .username: return "person"; case .password: return "key.horizontal"; case .note: return "note.text"; case .question: return "questionmark.bubble" }
    }
}

/// Tinted circle behind a field's icon, like Android's IconBadge.
struct IconBadge: View {
    let symbol: String
    var size: CGFloat = 40
    var tint: Color = .accentColor
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.45)).foregroundStyle(tint)
            .frame(width: size, height: size).background(tint.opacity(0.18), in: Circle())
    }
}

/// The brand's logo for a well-known site, a card or note badge, or a letter on a color picked from the name, as on Android.
struct RecordAvatar: View {
    let record: VaultRecord
    var size: CGFloat = 72
    /// Android's hashCode of the lower-cased name picks the color, so a name has the same one on both phones.
    private var paletteIndex: Int {
        var hash: Int32 = 0
        for unit in record.name.lowercased().utf16 { hash = hash &* 31 &+ Int32(unit) }
        return Int(((Int(hash) % 3) + 3) % 3)
    }
    var body: some View {
        if record.isCard { IconBadge(symbol: "creditcard", size: size) }
        else if record.isNote { IconBadge(symbol: "note.text", size: size, tint: .purple) }
        else if !record.isSeed, let brand = findBrand(website: record.website, name: record.name) {
            Image(brand.assetName).resizable().scaledToFit().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.23)).accessibilityLabel(brand.title)
        } else {
            let tint = [Color.accentColor, Color.teal, Color.purple][paletteIndex]
            let letter = record.name.trimmingCharacters(in: .whitespacesAndNewlines).first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "•"
            Text(letter).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(tint)
                .frame(width: size, height: size).background(tint.opacity(0.18), in: Circle())
        }
    }
}

/// Read-only view of a login, card or note, the screen an entry opens to: header, one card of fields with reveal / history / copy, then Edit.
struct RecordDetail: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss
    let recordID: String
    @State private var revealed = Set<String>()
    @State private var editing: VaultRecord?
    @State private var historyField: VaultField?
    @State private var deleting = false
    private var record: VaultRecord? { model.records.first { $0.id == recordID } }

    var body: some View {
        NavigationStack {
            if let record {
                ScrollView {
                    VStack(spacing: 16) {
                        header(record)
                        fieldsCard(record)
                        if let updated = formatUpdated(record.updatedAt) {
                            Text(localizedFormat("Updated %@", updated)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 32)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { toggleFavorite(record) } label: { Image(systemName: record.favorite ? "star.fill" : "star").foregroundStyle(record.favorite ? Color.favoriteStar : Color.primary) }
                            .accessibilityLabel(record.favorite ? "Remove from favorites" : "Add to favorites")
                        Button { revealed = []; editing = record } label: { Image(systemName: "pencil") }.accessibilityLabel("Edit")
                        Menu {
                            Button(role: .destructive) { deleting = true } label: { Label("Delete entry", systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More")
                    }
                }
                .sheet(item: $editing) { RecordEditor(record: $0) }
                .sheet(item: $historyField) { PasswordHistoryView(field: $0) }
                .alert("Delete this entry?", isPresented: $deleting) {
                    Button("Delete", role: .destructive) {
                        let updated = model.records.filter { $0.id != recordID }
                        model.run({ try $0.save(updated); return updated }, done: { dismiss() })
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { Text(localizedFormat("“%@” will be permanently removed from this vault.", record.name)) }
            }
        }
    }

    private func header(_ record: VaultRecord) -> some View {
        VStack(spacing: 0) {
            RecordAvatar(record: record, size: 72)
            Text(record.name).font(.title2).multilineTextAlignment(.center).padding(.top, 12)
            if !record.website.isEmpty { Text(verbatim: record.website).font(.subheadline).foregroundStyle(.secondary) }
            if record.isCard && !record.cardSummary.isEmpty { Text(verbatim: record.cardSummary).font(.subheadline).foregroundStyle(.secondary) }
            if !VaultListFilter.folderName(record).isEmpty { GroupTag(name: VaultListFilter.folderName(record), large: true).padding(.top, 8) }
            if let date = record.expiryDate.flatMap(Expiry.localDate) {
                let state = record.expiryState()
                Text(localizedFormat(state == .expired ? "Expired %@" : "Expires %@", date.formatted(date: .abbreviated, time: .omitted)))
                    .font(.subheadline).foregroundStyle(state == .expired || state == .soon ? Color.red : Color.secondary).padding(.top, 8)
            }
        }.frame(maxWidth: .infinity).padding(.top, 8)
    }

    private func fieldsCard(_ record: VaultRecord) -> some View {
        VStack(spacing: 0) {
            if record.fields.isEmpty {
                Text("No fields. Tap edit to add a username or password.").foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(record.fields.enumerated()), id: \.element.id) { index, field in
                if index > 0 { Divider().padding(.leading, 72) }
                fieldRow(field)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func fieldRow(_ field: VaultField) -> some View {
        let shown = !field.secret || revealed.contains(field.id)
        let name = displayFieldLabel(field.label)
        return HStack(spacing: 0) {
            IconBadge(symbol: fieldSymbol(field))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption).foregroundStyle(.secondary)
                if field.kind == .question && !field.question.isEmpty { Text(field.question).font(.subheadline) }
                if field.value.isEmpty { Text("—").foregroundStyle(.tertiary) }
                else if shown { Text(verbatim: shownValue(field)).font(field.kind == .password ? .body.monospaced() : .body).textSelection(.disabled) }
                else { Text(verbatim: "••••••••••") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            if field.secret && !field.value.isEmpty {
                iconButton(revealed.contains(field.id) ? "eye.slash" : "eye", label: revealed.contains(field.id) ? "Hide" : "Reveal") {
                    if !revealed.insert(field.id).inserted { revealed.remove(field.id) }
                }
            }
            if !field.historyNewestFirst.isEmpty {
                iconButton("clock.arrow.circlepath", label: localizedFormat("Password history %@", name)) { historyField = field }
            }
            if settings.allowCopy && !field.value.isEmpty {
                iconButton("doc.on.doc", label: localizedFormat("Copy %@", name)) { SecretClipboard.copy(field.label == cardExpiryLabel ? Cards.formattedExpiry(field.value) : field.value) }
            }
        }
        .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 12)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func shownValue(_ field: VaultField) -> String {
        switch field.label { case cardNumberLabel: Cards.formatted(field.value); case cardExpiryLabel: Cards.formattedExpiry(field.value); default: field.value }
    }

    private func formatUpdated(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) ?? { formatter.formatOptions.insert(.withFractionalSeconds); return formatter.date(from: iso) }() else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func toggleFavorite(_ record: VaultRecord) {
        var updated = model.records
        guard let index = updated.firstIndex(where: { $0.id == record.id }) else { return }
        updated[index].favorite.toggle()
        let snapshot = updated
        model.run { try $0.save(snapshot); return snapshot }
    }
}
