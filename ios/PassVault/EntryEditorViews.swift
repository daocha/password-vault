import SwiftUI
import VaultCore

/// An outlined text field with an optional leading icon, a label that shrinks above the text once there is some, and optional supporting text, like Android's OutlinedTextField.
struct OutlinedField<Trailing: View>: View {
    let label: String
    var icon: String?
    @Binding var text: String
    var secure = false
    var monospaced = false
    var multiline = false
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never
    var supporting: String?
    var supportingIsError = false
    var error = false
    var focusChanged: ((Bool) -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                if let icon { Image(systemName: icon).foregroundStyle(Color.aOnSurfaceVariant) }
                VStack(alignment: .leading, spacing: 0) {
                    if !text.isEmpty || focused { Text(label).font(.caption).foregroundStyle(error ? Color.red : focused ? Color.accentColor : Color.secondary) }
                    field.focused($focused).font(monospaced ? .system(size: 14, design: .monospaced) : .system(size: 15))
                        .keyboardType(keyboard).textInputAutocapitalization(capitalization).autocorrectionDisabled()
                }
                trailing
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 56)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(error ? Color.red : focused ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: focused || error ? 2 : 1))
            .contentShape(Rectangle()).onTapGesture { focused = true }
            .onChange(of: focused) { _, now in focusChanged?(now) }
            if let supporting { Text(supporting).font(.caption).foregroundStyle(supportingIsError ? Color.red : Color.secondary).padding(.horizontal, 12) }
        }
    }
    @ViewBuilder private var field: some View {
        if secure { SecureField(label, text: $text) }
        else if multiline { TextField(label, text: $text, axis: .vertical).lineLimit(2...6) }
        else { TextField(label, text: $text) }
    }
}

extension OutlinedField where Trailing == EmptyView {
    init(label: String, icon: String? = nil, text: Binding<String>, secure: Bool = false, monospaced: Bool = false, multiline: Bool = false, keyboard: UIKeyboardType = .default,
         capitalization: TextInputAutocapitalization = .never, supporting: String? = nil, supportingIsError: Bool = false, error: Bool = false, focusChanged: ((Bool) -> Void)? = nil) {
        self.init(label: label, icon: icon, text: text, secure: secure, monospaced: monospaced, multiline: multiline, keyboard: keyboard, capitalization: capitalization,
                  supporting: supporting, supportingIsError: supportingIsError, error: error, focusChanged: focusChanged) { EmptyView() }
    }
}

/// A rounded card on the grouped background, used for every block on the entry screens.
struct SurfaceCard<Content: View>: View {
    var radius: CGFloat = 20
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.aCard, in: RoundedRectangle(cornerRadius: radius))
    }
}

/// Reminder date for a record: an outlined row showing the day (or None); tapping opens a calendar.
struct ExpiryField: View {
    @Binding var value: String?
    @State private var picking = false
    private var date: Date? { value.flatMap(Expiry.parseDate).flatMap(Expiry.localDate) }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar").foregroundStyle(Color.aOnSurfaceVariant)
            VStack(alignment: .leading, spacing: 0) {
                Text("Expiry reminder").font(.caption).foregroundStyle(Color.aOnSurfaceVariant)
                Text(date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? localized("None")).font(.body)
            }
            Spacer()
            if date != nil {
                Button { value = nil } label: { Image(systemName: "xmark").foregroundStyle(Color.aOnSurfaceVariant).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Remove reminder")
            }
        }
        .padding(.leading, 12).padding(.trailing, date == nil ? 12 : 0).padding(.vertical, 6).frame(minHeight: 56)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
        .contentShape(Rectangle()).onTapGesture { picking = true }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
        .sheet(isPresented: $picking) { ExpiryPickerSheet(initial: date ?? Date()) { value = Expiry.format(Expiry.components($0)) } }
    }
}

private struct ExpiryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var selection: Date
    let pick: (Date) -> Void
    init(initial: Date, pick: @escaping (Date) -> Void) { _selection = State(initialValue: initial); self.pick = pick }
    var body: some View {
        NavigationStack {
            DatePicker("Expiry reminder", selection: $selection, displayedComponents: .date).datePickerStyle(.graphical).padding()
                .navigationTitle("Expiry reminder").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("OK") { pick(selection); dismiss() } }
                }
        }.presentationDetents([.medium, .large])
    }
}

/// Shown when the sparkle button of a password field is tapped; the same content as Android's dialog: key icon, title, the candidate with a refresh button, the length and character options, then Cancel and Use password.
struct GeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var options: GeneratorOptions
    @State private var candidate = ""
    @State private var failure = ""
    let use: (String) -> Void
    init(defaults: GeneratorOptions, use: @escaping (String) -> Void) { _options = State(initialValue: defaults); self.use = use }
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal").font(.title2).foregroundStyle(.tint)
            Text("Generate password").font(.title3)
            HStack {
                Text(verbatim: candidate).font(.body.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                Button { regenerate() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Generate another")
            }
            .padding(.leading, 16).padding(.trailing, 4)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            if !failure.isEmpty { Text(failure).font(.footnote).foregroundStyle(.red) }
            VStack(spacing: 8) { GeneratorOptionsEditor(options: $options) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Use password") { use(candidate); dismiss() }.disabled(candidate.isEmpty).padding(.leading, 8)
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.aCard)
        .presentationDetents([.height(460), .large])
        .onAppear { regenerate() }
        .onChange(of: options) { _, _ in regenerate() }
    }
    private func regenerate() {
        do { candidate = try VaultCrypto.generatePassword(options); failure = "" } catch { candidate = ""; failure = error.localizedDescription }
    }
}

/// Add or edit a login, card or secure note. Same layout as Android: a details card, then one card per field.
struct RecordEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State var record: VaultRecord
    @State private var revealed = Set<String>()
    @State private var generatingFor: String?
    @State private var groupFocused = false

    private var isNew: Bool { !model.records.contains { $0.id == record.id } }
    private var title: String {
        if record.isCard { return isNew ? "New card" : "Edit card" }
        if record.isNote { return isNew ? "New secure note" : "Edit secure note" }
        return isNew ? "New entry" : "Edit entry"
    }
    private var groups: [String] { VaultListFilter.folders(in: model.records) }

    var body: some View {
        NavigationStack {
            List {
                detailsCard.rowStyle(top: 0)
                HStack {
                    Text("Fields").font(.headline).foregroundStyle(Color.aOnSurfaceVariant)
                    Spacer()
                    if record.fields.count > 1 { Text("Drag ⋮⋮ to reorder").font(.caption2).foregroundStyle(Color.aOnSurfaceVariant) }
                }.rowStyle(top: 6).moveDisabled(true)
                ForEach($record.fields) { $field in
                    fieldCard($field).rowStyle()
                        .accessibilityAction(named: Text("Move up")) { move(field.id, by: -1) }
                        .accessibilityAction(named: Text("Move down")) { move(field.id, by: 1) }
                }.onMove { record.fields.move(fromOffsets: $0, toOffset: $1) }
                addFieldMenu.rowStyle().moveDisabled(true)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(Color.aBackground)
            .environment(\.editMode, .constant(record.fields.count > 1 ? .active : .inactive))
            .navigationTitle(LocalizedStringKey(title)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Discard changes") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { record.favorite.toggle() } label: { Image(systemName: record.favorite ? "star.fill" : "star").foregroundStyle(record.favorite ? Color.favoriteStar : Color.primary) }
                        .accessibilityLabel(record.favorite ? "Remove from favorites" : "Add to favorites")
                    Button("Save") { save() }.buttonStyle(.borderedProminent).foregroundStyle(Color.aOnPrimary).disabled(record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                }
            }
            .sheet(item: Binding(get: { generatingFor.map(GeneratingField.init) }, set: { generatingFor = $0?.id })) { target in
                GeneratorSheet(defaults: settings.generator) { value in
                    guard let index = record.fields.firstIndex(where: { $0.id == target.id }) else { return }
                    record.fields[index].value = value; revealed.insert(target.id)
                }
            }
        }
    }

    private struct GeneratingField: Identifiable { let id: String }

    private var detailsCard: some View {
        SurfaceCard {
            VStack(spacing: 10) {
                OutlinedField(label: localized("Name"), icon: "person.text.rectangle", text: $record.name)
                if !record.isNote { OutlinedField(label: localized("Website/App name"), icon: "globe", text: $record.website, keyboard: .URL) }
                groupField
                // A card's own expiry date is its reminder.
                if !record.isCard { ExpiryField(value: $record.expires) }
            }
        }
    }

    /// Typing narrows the suggestions below the field to matching groups; the arrow always lists every group, and picking one replaces the current group.
    private var groupField: some View {
        let typed = record.group.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = typed.isEmpty ? [] : groups.filter { $0.localizedCaseInsensitiveContains(typed) && $0.caseInsensitiveCompare(typed) != .orderedSame }
        let isNew = !groups.isEmpty && !typed.isEmpty && !groups.contains { $0.caseInsensitiveCompare(typed) == .orderedSame }
        return VStack(spacing: 4) {
            OutlinedField(label: localized("Group"), icon: "folder", text: $record.group, supporting: isNew ? localized("New group") : nil, focusChanged: { groupFocused = $0 }) {
                if !groups.isEmpty {
                    Menu {
                        ForEach(groups, id: \.self) { name in Button { record.group = name } label: { Label(name, systemImage: "folder") } }
                    } label: { Image(systemName: "chevron.down").foregroundStyle(Color.aOnSurfaceVariant).frame(width: 36, height: 36).contentShape(Rectangle()) }
                        .accessibilityLabel("Group")
                }
            }
            if groupFocused && !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches, id: \.self) { name in
                        Button { record.group = name } label: {
                            Label(name, systemImage: "folder").foregroundStyle(Color.aOnSurface).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func fieldCard(_ field: Binding<VaultField>) -> some View {
        let f = field.wrappedValue
        let hidden = f.secret && !revealed.contains(f.id)
        let name = displayFieldLabel(f.label)
        let cardInput = CardInput.of(f.label).flatMap { input in input.digits(f.value).map { _ in input } }
        return SurfaceCard(radius: 16, padding: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: fieldSymbol(f), size: 36).padding(.top, 8)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(name).font(.subheadline.weight(.medium)).foregroundStyle(Color.aOnSurfaceVariant)
                        Spacer()
                        Button { record.fields.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle").foregroundStyle(.red).frame(width: 36, height: 36).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel(localizedFormat("Remove %@", name))
                    }
                    if f.kind == .question { OutlinedField(label: localized("Question"), text: field.question) }
                    OutlinedField(label: f.kind == .question ? localized("Answer") : f.label == cardExpiryLabel ? localized("MM/YY") : name, text: valueBinding(field, cardInput: cardInput, hidden: hidden),
                                  secure: hidden, monospaced: f.kind == .password && !hidden, multiline: f.kind == .note,
                                  keyboard: cardNumericLabels.contains(f.label) || cardInput == .expiry ? .numberPad : .default) {
                        if f.secret {
                            HStack(spacing: 0) {
                                if f.kind == .password && !cardNumericLabels.contains(f.label) {
                                    Button { generatingFor = f.id } label: { Image(systemName: "sparkles").foregroundStyle(Color.aOnSurfaceVariant).frame(width: 36, height: 36).contentShape(Rectangle()) }
                                        .buttonStyle(.plain).accessibilityLabel("Generate password")
                                }
                                Button { if !revealed.insert(f.id).inserted { revealed.remove(f.id) } } label: { Image(systemName: hidden ? "eye" : "eye.slash").foregroundStyle(Color.aOnSurfaceVariant).frame(width: 36, height: 36).contentShape(Rectangle()) }
                                    .buttonStyle(.plain).accessibilityLabel(hidden ? "Reveal" : "Hide")
                            }
                        }
                    }
                }
            }
        }
    }

    /// A card number or expiry is stored as digits only and shown grouped; legacy values like "03/27" are edited as their digits.
    private func valueBinding(_ field: Binding<VaultField>, cardInput: CardInput?, hidden: Bool) -> Binding<String> {
        guard let input = cardInput else { return field.value }
        if hidden { return Binding(get: { field.wrappedValue.value }, set: { field.wrappedValue.value = input.clean($0) }) }
        return Binding(get: { input.formatted(input.digits(field.wrappedValue.value) ?? "") }, set: { field.wrappedValue.value = input.edited($0, from: input.digits(field.wrappedValue.value) ?? "") })
    }

    private var addFieldMenu: some View {
        Menu {
            ForEach(FieldKind.allCases, id: \.self) { kind in
                Button { record.fields.append(VaultField(kind: kind, label: Self.defaultLabel(kind))) } label: { Label(LocalizedStringKey(Self.defaultLabel(kind)), systemImage: fieldSymbol(VaultField(kind: kind, label: Self.defaultLabel(kind)))) }
            }
        } label: {
            Label("Add field", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
        }
    }
    private static func defaultLabel(_ kind: FieldKind) -> String {
        switch kind { case .username: "Username"; case .password: "Password"; case .note: "Notes"; case .question: "Security question" }
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = record.fields.firstIndex(where: { $0.id == id }), record.fields.indices.contains(index + offset) else { return }
        record.fields.swapAt(index, index + offset)
    }

    private func save() {
        record.name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        record.updatedAt = ISO8601DateFormatter().string(from: Date())
        record = record.recordingPasswordChanges(previous: model.records.first { $0.id == record.id })
        var updated = model.records
        if let index = updated.firstIndex(where: { $0.id == record.id }) { updated[index] = record } else { updated.append(record) }
        let snapshot = updated
        model.run({ try $0.save(snapshot); return snapshot }, done: { dismiss() })
    }
}

private extension View {
    /// A list row that looks like a plain block on the grouped background.
    func rowStyle(top: CGFloat = 5) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 16, bottom: 5, trailing: 16)).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}
