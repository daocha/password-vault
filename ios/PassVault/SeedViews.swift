import SwiftUI
import UIKit
import VaultCore

/// Paste is allowed, but seed material must never be written to the clipboard.
final class SeedTextView: UITextView {
    override func copy(_ sender: Any?) {}
    override func cut(_ sender: Any?) {}
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        [#selector(paste(_:)), #selector(select(_:)), #selector(selectAll(_:))].contains(action)
            && super.canPerformAction(action, withSender: sender)
    }
}

private struct SeedInput: UIViewRepresentable {
    let title: String
    @Binding var text: String
    var secure = false
    var cursorChanged: ((Bool) -> Void)? = nil
    func makeUIView(context: Context) -> SeedTextView {
        let view = SeedTextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        view.backgroundColor = .clear
        view.autocorrectionType = .no; view.spellCheckingType = .no
        view.autocapitalizationType = .none; view.smartQuotesType = .no; view.smartDashesType = .no
        view.keyboardType = .asciiCapable; view.isScrollEnabled = false
        if #available(iOS 18.0, *) { view.writingToolsBehavior = .none }
        return view
    }
    func updateUIView(_ view: SeedTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if view.isSecureTextEntry != secure { view.isSecureTextEntry = secure }
        view.textColor = .label
        view.accessibilityLabel = localized(title)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SeedTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SeedInput
        init(_ parent: SeedInput) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text }
        func textViewDidChangeSelection(_ view: UITextView) {
            let atEnd = view.selectedRange.upperBound == view.text.utf16.count
            DispatchQueue.main.async { self.parent.cursorChanged?(atEnd) }
        }
    }
}

struct SeedWordGrid: View {
    let words: [String]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(words.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                    Text(verbatim: words[index]).font(.system(.callout, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }.textSelection(.disabled)
    }
}

struct SeedDetail: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss
    let recordID: String
    @State private var shown = false
    @State private var passphraseShown = false
    @State private var editing = false
    @State private var deleting = false
    private var record: VaultRecord? { model.records.first { $0.id == recordID } }
    var body: some View {
        NavigationStack {
            if let record {
                Form {
                    Section {
                        Label(record.name, systemImage: "wallet.bifold").font(.title2)
                        Text(record.privateKey.map { localized(WalletPrivateKey.format($0)) } ?? (Bip39.problem(record.seedWords).map(localized) ?? localizedFormat("BIP-39 · %lld words", record.seedWords.count))).font(.caption)
                    }
                    Section(LocalizedStringKey(record.privateKey == nil ? seedPhraseLabel : privateKeyLabel)) {
                        Button(LocalizedStringKey(shown ? "Hide" : record.privateKey == nil ? "Show words" : "Show key")) { shown.toggle() }
                        if shown {
                            if let key = record.privateKey { Text(verbatim: key).font(.body.monospaced()).textSelection(.disabled) }
                            else { SeedWordGrid(words: record.seedWords) }
                        } else {
                            Text(LocalizedStringKey(record.privateKey == nil ? "Hidden. Make sure no one can see your screen before showing the words." : "Hidden. Make sure no one can see your screen before showing the key."))
                        }
                    }
                    if let passphrase = record.fields.first(where: { $0.label == seedPassphraseLabel })?.value, !passphrase.isEmpty {
                        Section("BIP-39 passphrase") {
                            Text(verbatim: passphraseShown ? passphrase : "••••••••••").font(.body.monospaced()).textSelection(.disabled)
                            Button(LocalizedStringKey(passphraseShown ? "Hide" : "Reveal")) { passphraseShown.toggle() }
                        }
                    }
                    if let notes = record.fields.first(where: { $0.kind == .note })?.value, !notes.isEmpty { Section("Notes") { Text(verbatim: notes) } }
                    Section { Text("Seed phrases and private keys are never copied to the clipboard and are left out of CSV exports; only encrypted backups include them.").font(.footnote).foregroundStyle(.secondary) }
                }
                .navigationTitle(record.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            var updated = model.records
                            if let index = updated.firstIndex(where: { $0.id == recordID }) { updated[index].favorite.toggle() }
                            let snapshot = updated
                            model.run { try $0.save(snapshot); return snapshot }
                        } label: { Label("Favorites", systemImage: record.favorite ? "star.fill" : "star") }
                        Button("Edit", systemImage: "pencil") { shown = false; passphraseShown = false; editing = true }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
                    }
                }
                .sheet(isPresented: $editing) { SeedEditor(initial: record, isNew: false) }
                .confirmationDialog(LocalizedStringKey(record.privateKey == nil ? "Delete this seed phrase?" : "Delete this private key?"), isPresented: $deleting, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        let updated = model.records.filter { $0.id != recordID }
                        model.run({ try $0.save(updated); return updated }, done: { dismiss() })
                    }
                } message: { Text("Without another backup, this wallet cannot be recovered.") }
            }
        }
    }
}

struct SeedEditor: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss
    let initial: VaultRecord
    let isNew: Bool
    @State private var name: String
    @State private var favorite: Bool
    @State private var mode: String
    @State private var typed: String
    @State private var key: String
    @State private var passphrase: String
    @State private var notes: String
    @State private var generated = [String]()
    @State private var count = 12
    @State private var acknowledged: Bool
    @State private var keyShown = false
    @State private var passphraseShown = false
    @State private var generationError = ""
    @State private var cursorAtEnd = true
    init(initial: VaultRecord, isNew: Bool) {
        self.initial = initial; self.isNew = isNew
        _name = State(initialValue: initial.name); _favorite = State(initialValue: initial.favorite)
        _mode = State(initialValue: initial.privateKey != nil ? "key" : isNew ? "generate" : "enter")
        _typed = State(initialValue: initial.seedWords.joined(separator: " ")); _key = State(initialValue: initial.privateKey ?? "")
        _count = State(initialValue: Bip39.wordCounts.contains(initial.seedWords.count) ? initial.seedWords.count : 12)
        _passphrase = State(initialValue: initial.fields.first { $0.label == seedPassphraseLabel }?.value ?? "")
        _notes = State(initialValue: initial.fields.first { $0.kind == .note }?.value ?? "")
        _acknowledged = State(initialValue: !isNew)
    }
    private var words: [String] { mode == "generate" ? generated : Bip39.split(typed) }
    private var suggestions: [String] {
        guard cursorAtEnd, let last = typed.last, !last.isWhitespace, let prefix = Bip39.split(typed).last else { return [] }
        let candidates = Bip39.suggestions(prefix)
        return candidates == [prefix] ? [] : candidates
    }
    private var problem: String? {
        if mode == "key" { return WalletPrivateKey.problem(key).map(localized) }
        if !Bip39.wordCounts.contains(words.count) { return localizedFormat("Enter 12 or 24 words (%lld so far).", words.count) }
        let unknown = Bip39.unknownWords(words)
        if !unknown.isEmpty { return localizedFormat("Not BIP-39 words: %@", unknown.joined(separator: ", ")) }
        return Bip39.problem(words).map(localized)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("High risk", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Text("Anyone with these words controls the wallet and all of its funds. A phone is not a hardware wallet. Don't store seed phrases here for wallets holding significant funds; keep those offline.").font(.footnote)
                }
                Section("Wallet name") { SeedInput(title: "Wallet name", text: $name).frame(minHeight: 44) }
                Section {
                    Picker("Mode", selection: $mode) {
                        Text("Generate").tag("generate"); Text("Enter words").tag("enter"); Text("Private key").tag("key")
                    }.pickerStyle(.segmented)
                }
                if mode == "key" {
                    Section("Private key") {
                        SeedInput(title: "Private key", text: $key, secure: !keyShown).frame(minHeight: 44)
                        Button(LocalizedStringKey(keyShown ? "Hide" : "Reveal")) { keyShown.toggle() }
                        Text(LocalizedStringKey(key.isEmpty ? "Hex, WIF or another single-string key" : problem ?? WalletPrivateKey.format(key))).font(.footnote)
                    }
                } else if mode == "generate" {
                    Section {
                        Picker("Word count", selection: $count) { ForEach(Bip39.wordCounts, id: \.self) { Text("\($0) words").tag($0) } }.pickerStyle(.segmented)
                        Button("Generate another phrase", systemImage: "arrow.clockwise") { generate() }
                        SeedWordGrid(words: generated)
                        Toggle("I wrote these words down offline, in order.", isOn: $acknowledged)
                        if !generationError.isEmpty { Text(LocalizedStringKey(generationError)).foregroundStyle(.red) }
                    }
                } else {
                    Section("Seed words, separated by spaces") {
                        SeedInput(title: "Seed words, separated by spaces", text: $typed, cursorChanged: { cursorAtEnd = $0 }).frame(minHeight: 100)
                        if let problem { Text(LocalizedStringKey(problem)).font(.footnote).foregroundStyle(.red) }
                        if !suggestions.isEmpty, let prefix = Bip39.split(typed).last {
                            ScrollView(.horizontal) {
                                HStack {
                                    ForEach(suggestions, id: \.self) { word in
                                        Button(word) {
                                            let preceding = typed.dropLast(prefix.count)
                                            typed = String(preceding) + word + " "
                                        }.buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }
                }
                if mode != "key" {
                    Section("BIP-39 passphrase (optional)") {
                        SeedInput(title: "BIP-39 passphrase (optional)", text: $passphrase, secure: !passphraseShown).frame(minHeight: 44)
                        Button(LocalizedStringKey(passphraseShown ? "Hide" : "Reveal")) { passphraseShown.toggle() }
                        Text("The optional “25th word”. Leave empty if your wallet doesn't use one.").font(.footnote)
                    }
                }
                Section("Notes (optional)") { SeedInput(title: "Notes (optional)", text: $notes).frame(minHeight: 60) }
                Toggle("Favorite", isOn: $favorite)
            }
            .navigationTitle(LocalizedStringKey(mode == "key" ? (isNew ? "New private key" : "Edit private key") : isNew ? "New seed phrase" : "Edit seed phrase"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || problem != nil || !acknowledged || model.busy)
                }
            }
            .onAppear { if mode == "generate" && generated.isEmpty { generate() } }
            .onChange(of: count) { _, _ in generate() }
            .onChange(of: typed) { _, text in if text != text.lowercased() { typed = text.lowercased() } }
            .onChange(of: mode) { _, mode in
                keyShown = false; passphraseShown = false
                if mode == "generate" { if generated.count != count { generate() }; acknowledged = false }
                else { acknowledged = true }
            }
        }
    }
    private func generate() {
        acknowledged = false
        do { generated = try Bip39.generate(count); generationError = "" }
        catch { generated = []; generationError = error.localizedDescription }
    }
    private func save() {
        do {
            let record = try initial.editingSeed(name: name, favorite: favorite, words: words, privateKey: mode == "key" ? key : nil, passphrase: passphrase, notes: notes)
            var updated = model.records
            if let index = updated.firstIndex(where: { $0.id == record.id }) { updated[index] = record } else { updated.append(record) }
            let snapshot = updated
            model.run({ try $0.save(snapshot); return snapshot }, done: { dismiss() })
        } catch { generationError = error.localizedDescription }
    }
}
