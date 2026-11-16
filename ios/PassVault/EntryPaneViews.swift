import SwiftUI
import VaultCore

/// An editor's fields, owned by the vault list rather than the editor, so they outlive the sheet or pane showing them.
/// Folding or unfolding the phone moves the editor between a sheet and the side pane; both show the same draft.
@MainActor final class EditorDraft<Form: EditorForm>: ObservableObject {
    /// A fresh id per editor. An object's address cannot be used: a freed draft's address can be reused by the next one,
    /// and the next editor would then inherit the last one's view state, such as a revealed setup key.
    let id = UUID()
    let original: Form
    @Published var form: Form
    init(_ form: Form) { original = form; self.form = form }
    var hasChanges: Bool { form.hasChanges(from: original) }
}

/// The editor the vault list has open, with what its save needs besides the fields.
@MainActor enum OpenEditor {
    case record(EditorDraft<VaultRecord>)
    case totp(EditorDraft<TotpForm>, original: VaultRecord)
    case seed(EditorDraft<SeedForm>, initial: VaultRecord, isNew: Bool)

    static func editing(_ record: VaultRecord, isNew: Bool) -> OpenEditor {
        if record.isTotp { return .totp(EditorDraft(TotpForm(record: record)), original: record) }
        if record.isSeed { return .seed(EditorDraft(SeedForm(record: record, isNew: isNew)), initial: record, isNew: isNew) }
        return .record(EditorDraft(record))
    }
    var hasChanges: Bool {
        switch self {
        case .record(let draft): draft.hasChanges
        case .totp(let draft, _): draft.hasChanges
        case .seed(let draft, _, _): draft.hasChanges
        }
    }
    /// Identifies the draft, so a new editor starts fresh instead of reusing the last one's view state.
    nonisolated var id: UUID {
        switch self {
        case .record(let draft): draft.id
        case .totp(let draft, _): draft.id
        case .seed(let draft, _, _): draft.id
        }
    }

    /// The editor view; `done` gets the saved entry's id, or nil when discarded.
    @ViewBuilder func view(done: @escaping (String?) -> Void) -> some View {
        switch self {
        case .record(let draft): RecordEditorForm(draft: draft, done: done)
        case .totp(let draft, let original): TotpEditorForm(draft: draft, original: original, done: done)
        case .seed(let draft, let initial, let isNew): SeedEditorForm(draft: draft, initial: initial, isNew: isNew, done: done)
        }
    }
}

/// The list's open entry. `wide` is updated as the list is drawn, before any sheet reacts to the new width, so the
/// sheets' bindings can tell a width change (keep the entry) from the person closing a sheet (close it).
@MainActor final class EntryPaneModel: ObservableObject {
    @Published var state = EntryPane<OpenEditor>()
    var wide = false
    /// Vault health is open over the list (upright), so the entry it opens shows over the report, narrow-style, even
    /// where the list has a side pane (an iPad or an unfolded foldable held upright). Updated with `wide`.
    var healthSheet = false
    /// The open entry and its editor show in the pane beside the list (or the report), not over it.
    var besideList: Bool { wide && !healthSheet }
    /// The entry Vault health's report opened. Only that one shows over the report: an entry the list had open in its
    /// side pane (an iPad or an unfolded foldable held upright) stays there, behind the report.
    var fromHealth: String?
    /// Opens an entry from Vault health's report.
    func openFromHealth(_ id: String) { fromHealth = id; open(id) }
    /// The entry to show over Vault health's report, upright: one the report opened, never the list's.
    var entryOverReport: OpenEntryItem? {
        guard healthSheet else { return nil }
        switch state.presentation {
        case .detail(let id), .detailAndEditor(let id): return id == fromHealth ? OpenEntryItem(id: id) : nil
        case .none, .newEditor: return nil
        }
    }
    init(healthSheet: Bool = false) { self.healthSheet = healthSheet }

    var hasUnsavedChanges: Bool { state.editor?.hasChanges ?? false }
    func open(_ id: String) { state.request(.open(id), unsavedChanges: hasUnsavedChanges) }
    func create(_ record: VaultRecord) { state.request(.create(.editing(record, isNew: true)), unsavedChanges: hasUnsavedChanges) }
    func edit(_ record: VaultRecord) { state.edit(.editing(record, isNew: false)) }
    func editorDone(_ saved: String?) {
        if let saved { state.saved(saved, showDetails: wide) } else { state.closeEditor() }
    }

    /// Hooks for a detail view the list shows, beside it (`inPane`) or over it.
    func hooks(inPane: Bool) -> EntryPaneHooks {
        EntryPaneHooks(
            inPane: inPane,
            close: { [weak self] in self?.state.close() },
            edit: { [weak self] in self?.edit($0) },
            // Narrow screens only: the editor opens as a sheet over the details. A wide screen shows it in the pane instead.
            editorItem: Binding(get: { [weak self] in
                // Details in the pane never present the editor themselves: beside the list it shows in the pane, and
                // behind Vault health's sheet the details over the report present it.
                guard let self, !inPane, !self.besideList, case .detailAndEditor = self.state.presentation, let editor = self.state.editor else { return nil }
                return EditorItem(editor: editor)
            }, set: { [weak self] item in
                guard let self, !inPane, item == nil, !self.besideList else { return }
                self.state.closeEditor()
            }),
            editorDone: { [weak self] in self?.editorDone($0) })
    }
    /// A new entry's editor, as a sheet over a narrow list. Swiping it away discards it, as before.
    var narrowNewEditor: Binding<EditorItem?> {
        Binding(get: { [weak self] in
            guard let self, !self.wide, self.state.presentation == .newEditor, let editor = self.state.editor else { return nil }
            return EditorItem(editor: editor)
        }, set: { [weak self] item in
            guard let self, item == nil, !self.wide else { return }
            self.state.closeEditor()
        })
    }
}

/// How a detail view opened from the vault list closes and edits: through the list's open-entry state rather than by
/// dismissing itself, so the entry stays open when the screen changes width. Detail views opened elsewhere get none.
struct EntryPaneHooks {
    let inPane: Bool
    let close: () -> Void
    let edit: (VaultRecord) -> Void
    /// Narrow screens only: the editor opens as a sheet over the details. A wide screen shows it in the pane instead.
    let editorItem: Binding<EditorItem?>
    let editorDone: (String?) -> Void
    /// The editor sheet a detail view presents: none without hooks, or until the view is `ready` to present.
    static func editorItem(_ hooks: EntryPaneHooks?, ready: Bool) -> Binding<EditorItem?> {
        guard ready, let hooks else { return .constant(nil) }
        return hooks.editorItem
    }
}

/// An open editor for `sheet(item:)`, which keeps showing it while the sheet animates away.
struct EditorItem: Identifiable {
    let editor: OpenEditor
    var id: UUID { editor.id }
    @MainActor func view(done: @escaping (String?) -> Void) -> some View { editor.view(done: done).id(id) }
}

/// The detail view for an entry the vault list has open. Keyed by the entry, so nothing revealed carries over to the next one.
struct OpenEntryDetail: View {
    @ObservedObject var pane: EntryPaneModel
    let record: VaultRecord
    let inPane: Bool
    var body: some View {
        let hooks = pane.hooks(inPane: inPane)
        Group {
            if record.isTotp { TotpDetail(recordID: record.id, hooks: hooks) }
            else if record.isSeed { SeedDetail(recordID: record.id, hooks: hooks) }
            else { RecordDetail(recordID: record.id, hooks: hooks) }
        }.id(record.id)
    }
}

/// The right-hand side of a wide screen: the open editor, the open entry, or a hint to pick one.
struct EntryPaneView: View {
    @EnvironmentObject var model: VaultModel
    @ObservedObject var pane: EntryPaneModel
    /// Where to pick an entry: the vault list, or Vault health's report.
    var hint: LocalizedStringKey = "Choose an entry from the list, or add a new one."
    var body: some View {
        Group {
            // Behind Vault health's sheet the editor is shown over the report instead; one editor per draft.
            if let editor = pane.state.editor, !pane.healthSheet {
                editor.view(done: { pane.editorDone($0) }).id(editor.id)
            } else if let id = pane.state.viewing, let record = model.records.first(where: { $0.id == id }) {
                OpenEntryDetail(pane: pane, record: record, inPane: true)
            } else {
                ContentUnavailableView("No entry selected", systemImage: "sidebar.right", description: Text(hint))
                    .background(Color.aBackground)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("entry-pane")
    }
}

/// Lets a narrow screen present the open entry with `item:` presenters, which keep their content while animating away.
struct OpenEntryItem: Identifiable, Equatable {
    let id: String
}
