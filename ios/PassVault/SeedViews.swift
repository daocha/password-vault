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
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
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
        let width = proposal.width ?? 240
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
    /// One size for every word. The longest BIP-39 word has 8 letters and fits a third of the screen at this size, so no word is ever scaled down on its own.
    @ScaledMetric(relativeTo: .footnote) private var wordSize = 13.0
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(words.indices, id: \.self) { index in
                HStack(spacing: 0) {
                    Text("\(index + 1)").font(.system(size: 10)).foregroundStyle(Color.aOnSurfaceVariant).frame(width: 18, alignment: .leading)
                    Text(verbatim: words[index]).font(.system(size: wordSize, design: .monospaced)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 10)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }.textSelection(.disabled)
    }
}

/// The red "High risk" card shown above the seed editor.
struct SeedWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("High risk").font(.subheadline.weight(.bold))
                Text("Anyone with these words controls the wallet and all of its funds. A phone is not a hardware wallet. Don't store seed phrases here for wallets holding significant funds; keep those offline.").font(.subheadline)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.red, lineWidth: 1))
    }
}

/// Read-only view of a seed phrase or private key, like Android: wallet badge, name and a status chip, one card that reveals the words or key, the passphrase and notes, then the never-copied reminder.
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
                let problem = Bip39.problem(record.seedWords)
                let chip = record.privateKey.map { localizedFormat("Private key · %@", localized(WalletPrivateKey.format($0))) }
                    ?? (problem == nil ? localizedFormat("BIP-39 · %lld words", record.seedWords.count) : localized("Not a valid BIP-39 phrase"))
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(spacing: 0) {
                            IconBadge(symbol: "wallet.bifold", size: 72, tint: .purple)
                            Text(record.name).font(.title2).multilineTextAlignment(.center).padding(.top, 12)
                            Label(chip, systemImage: record.privateKey != nil || problem == nil ? "checkmark.shield" : "exclamationmark.triangle")
                                .font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
                                .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1)).padding(.top, 8)
                        }.frame(maxWidth: .infinity).padding(.top, 8)
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(LocalizedStringKey(record.privateKey == nil ? seedPhraseLabel : privateKeyLabel)).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Button { shown.toggle() } label: {
                                        Label(LocalizedStringKey(shown ? "Hide" : record.privateKey == nil ? "Show words" : "Show key"), systemImage: shown ? "eye.slash" : "eye").font(.subheadline)
                                    }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                                }
                                if shown {
                                    if let key = record.privateKey { Text(verbatim: key).font(.body.monospaced()).textSelection(.disabled) }
                                    else { SeedWordGrid(words: record.seedWords) }
                                } else {
                                    Text(LocalizedStringKey(record.privateKey == nil ? "Hidden. Make sure no one can see your screen before showing the words." : "Hidden. Make sure no one can see your screen before showing the key."))
                                        .font(.caption).foregroundStyle(Color.aOnSurfaceVariant)
                                }
                            }
                        }
                        if let passphrase = record.fields.first(where: { $0.label == seedPassphraseLabel })?.value, !passphrase.isEmpty {
                            SurfaceCard(padding: 0) {
                                HStack(spacing: 0) {
                                    IconBadge(symbol: "key.horizontal")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("BIP-39 passphrase").font(.caption).foregroundStyle(Color.aOnSurfaceVariant)
                                        Text(verbatim: passphraseShown ? passphrase : "••••••••••").font(passphraseShown ? .body.monospaced() : .body).textSelection(.disabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                                    Button { passphraseShown.toggle() } label: { Image(systemName: passphraseShown ? "eye.slash" : "eye").foregroundStyle(Color.aOnSurfaceVariant).frame(width: 44, height: 44).contentShape(Rectangle()) }
                                        .buttonStyle(.plain).accessibilityLabel(passphraseShown ? "Hide" : "Reveal")
                                }.padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 12)
                            }
                        }
                        if let notes = record.fields.first(where: { $0.kind == .note })?.value, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            SurfaceCard {
                                HStack(alignment: .top, spacing: 16) {
                                    IconBadge(symbol: "note.text")
                                    VStack(alignment: .leading, spacing: 2) { Text("Notes").font(.caption).foregroundStyle(Color.aOnSurfaceVariant); Text(verbatim: notes) }
                                }
                            }
                        }
                        Text("Seed phrases and private keys are never copied to the clipboard and are left out of CSV exports; only encrypted backups include them.")
                            .font(.caption).foregroundStyle(Color.aOnSurfaceVariant).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    }.padding(.horizontal, 16).padding(.bottom, 32)
                }
                .background(Color.aBackground)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back") }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            var updated = model.records
                            if let index = updated.firstIndex(where: { $0.id == recordID }) { updated[index].favorite.toggle() }
                            let snapshot = updated
                            model.run { try $0.save(snapshot); return snapshot }
                        } label: { Image(systemName: record.favorite ? "star.fill" : "star").foregroundStyle(record.favorite ? Color.favoriteStar : Color.primary) }
                            .accessibilityLabel(record.favorite ? "Remove from favorites" : "Add to favorites")
                        Button { shown = false; passphraseShown = false; editing = true } label: { Image(systemName: "pencil") }.accessibilityLabel("Edit")
                        Menu {
                            Button(role: .destructive) { deleting = true } label: { Label(LocalizedStringKey(record.privateKey == nil ? "Delete seed phrase" : "Delete private key"), systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More")
                    }
                }
                .sheet(isPresented: $editing) { SeedEditor(initial: record, isNew: false) }
                .alert(LocalizedStringKey(record.privateKey == nil ? "Delete this seed phrase?" : "Delete this private key?"), isPresented: $deleting) {
                    Button("Delete", role: .destructive) {
                        let updated = model.records.filter { $0.id != recordID }
                        model.run({ try $0.save(updated); return updated }, done: { dismiss() })
                    }
                    Button("Cancel", role: .cancel) {}
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
    /// The word being typed: the text after the last space, while the cursor is at the end.
    private var partial: String {
        guard mode == "enter", cursorAtEnd, let last = typed.last, !last.isWhitespace else { return "" }
        return Bip39.split(typed).last ?? ""
    }
    /// An outlined box as wide as the screen. The label sits above the text once there is some, and inside the box as a placeholder until then (the UIKit text view has none).
    private func outlined<Content: View>(_ label: String, icon: String? = nil, filled: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            if let icon { Image(systemName: icon).foregroundStyle(Color.aOnSurfaceVariant) }
            VStack(alignment: .leading, spacing: 0) {
                if filled { Text(label).font(.caption).foregroundStyle(Color.aOnSurfaceVariant) }
                content().frame(maxWidth: .infinity, alignment: .leading)
                    .background(alignment: .topLeading) {
                        if !filled { Text(label).font(.system(size: 14)).foregroundStyle(Color.aOnSurfaceVariant).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                    }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
    }
    private func eye(_ on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) { Image(systemName: on ? "eye.slash" : "eye").foregroundStyle(Color.aOnSurfaceVariant).frame(width: 36, height: 36).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(on ? "Hide" : "Reveal")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    SeedWarning()
                    outlined(localized("Wallet name"), icon: "wallet.bifold", filled: !name.isEmpty) { SeedInput(title: "Wallet name", text: $name) }
                    Picker("Mode", selection: $mode) {
                        Text("Generate").tag("generate"); Text("Enter words").tag("enter"); Text("Private key").tag("key")
                    }.pickerStyle(.segmented)
                    if mode == "key" {
                        VStack(alignment: .leading, spacing: 4) {
                            outlined(localized("Private key"), filled: !key.isEmpty) {
                                HStack { SeedInput(title: "Private key", text: $key, secure: !keyShown).frame(maxWidth: .infinity); eye(keyShown) { keyShown.toggle() } }
                            }
                            Text(LocalizedStringKey(key.isEmpty ? "Hex, WIF or another single-string key" : problem ?? WalletPrivateKey.format(key))).font(.caption)
                                .foregroundStyle(!key.isEmpty && problem != nil ? Color.red : Color.secondary).padding(.horizontal, 12)
                        }
                    } else if mode == "generate" {
                        SurfaceCard {
                            VStack(spacing: 12) {
                                HStack {
                                    Picker("Word count", selection: $count) { ForEach(Bip39.wordCounts, id: \.self) { Text("\($0) words").tag($0) } }.pickerStyle(.segmented)
                                    Button { generate() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44).contentShape(Rectangle()) }
                                        .buttonStyle(.plain).accessibilityLabel("Generate another phrase")
                                }
                                SeedWordGrid(words: generated)
                                Button { acknowledged.toggle() } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: acknowledged ? "checkmark.square.fill" : "square").foregroundStyle(acknowledged ? Color.accentColor : Color.secondary)
                                        Text("I wrote these words down offline, in order.").font(.subheadline).foregroundStyle(Color.aOnSurface).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if !generationError.isEmpty { Text(LocalizedStringKey(generationError)).font(.footnote).foregroundStyle(.red) }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            outlined(localized("Seed words, separated by spaces"), filled: !typed.isEmpty) {
                                SeedInput(title: "Seed words, separated by spaces", text: $typed, cursorChanged: { cursorAtEnd = $0 }).frame(minHeight: 72)
                            }
                            Text(words.isEmpty ? localized("12 or 24 words") : problem ?? localizedFormat("Valid BIP-39 phrase · %lld words", words.count)).font(.caption)
                                .foregroundStyle(words.isEmpty ? Color.secondary : problem == nil ? Color.green : words.count == 12 || words.count == 24 ? Color.red : Color.secondary).padding(.horizontal, 12)
                            if !suggestions.isEmpty, let prefix = Bip39.split(typed).last {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(suggestions, id: \.self) { word in
                                            Button { typed = String(typed.dropLast(prefix.count)) + word + " " } label: {
                                                Text(verbatim: word).font(.callout.monospaced()).padding(.horizontal, 12).frame(minHeight: 32)
                                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }
                            } else if !partial.isEmpty && !Bip39.unknownWords([partial]).isEmpty {
                                Text(localizedFormat("No BIP-39 word starts with “%@”.", partial)).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    if mode != "key" {
                        VStack(alignment: .leading, spacing: 4) {
                            outlined(localized("BIP-39 passphrase (optional)"), filled: !passphrase.isEmpty) {
                                HStack { SeedInput(title: "BIP-39 passphrase (optional)", text: $passphrase, secure: !passphraseShown).frame(maxWidth: .infinity); eye(passphraseShown) { passphraseShown.toggle() } }
                            }
                            Text("The optional “25th word”. Leave empty if your wallet doesn't use one.").font(.caption).foregroundStyle(Color.aOnSurfaceVariant).padding(.horizontal, 12)
                        }
                    }
                    outlined(localized("Notes (optional)"), filled: !notes.isEmpty) { SeedInput(title: "Notes (optional)", text: $notes).frame(minHeight: 44) }
                }.padding(.horizontal, 16).padding(.bottom, 32)
            }
            .background(Color.aBackground)
            .navigationTitle(LocalizedStringKey(mode == "key" ? (isNew ? "New private key" : "Edit private key") : isNew ? "New seed phrase" : "Edit seed phrase"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Discard changes") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { favorite.toggle() } label: { Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.favoriteStar : Color.primary) }
                        .accessibilityLabel(favorite ? "Remove from favorites" : "Add to favorites")
                    Button("Save") { save() }.buttonStyle(.borderedProminent).foregroundStyle(Color.aOnPrimary)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || problem != nil || !acknowledged || model.busy)
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
