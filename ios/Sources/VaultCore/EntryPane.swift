import Foundation

/// The entry the vault list has open: its details, an editor for it, or an editor for a new entry.
/// On a wide screen (an unfolded foldable iPhone, an iPad) it is shown in a pane beside the list. On a narrow screen the same
/// state is presented over the list as before: details full screen, an editor as a sheet. The state is kept when the
/// screen changes width, so folding or unfolding the phone keeps the open entry and any unsaved edits.
/// `Editor` is whatever the app keeps an editor's draft in.
public struct EntryPane<Editor> {
    /// What a narrow screen presents over the list. A wide screen shows the editor if there is one, otherwise the details.
    public enum Presentation: Equatable {
        case none
        case detail(String)
        /// Narrow screens show the editor as a sheet over the entry's details.
        case detailAndEditor(String)
        case newEditor
    }
    public enum Request {
        case open(String)
        case create(Editor)
    }

    /// The id of the entry whose details are open.
    public private(set) var viewing: String?
    public private(set) var editor: Editor?
    /// The editor is for an entry not yet in the vault.
    public private(set) var editingNew = false
    /// A row or New entry tapped while the editor had unsaved changes, waiting for the person to discard them or keep editing.
    public private(set) var pending: Request?

    public init() {}

    public var presentation: Presentation {
        if editor != nil && editingNew { return .newEditor }
        guard let viewing else { return .none }
        return editor == nil ? .detail(viewing) : .detailAndEditor(viewing)
    }

    /// Opens an entry or a new editor. Unsaved changes are never thrown away silently: with `unsavedChanges` the request
    /// waits in `pending` for `discardChanges()` or `keepEditing()`. Returns whether it was carried out.
    @discardableResult public mutating func request(_ request: Request, unsavedChanges: Bool) -> Bool {
        // Tapping the entry already open (even while editing it) changes nothing.
        if case .open(let id) = request, id == viewing, !editingNew { return true }
        if editor != nil && unsavedChanges { pending = request; return false }
        apply(request)
        return true
    }
    public mutating func discardChanges() {
        guard let request = pending else { return }
        pending = nil
        apply(request)
    }
    public mutating func keepEditing() { pending = nil }

    /// Edits the entry whose details are open.
    public mutating func edit(_ editor: Editor) {
        guard viewing != nil else { return }
        self.editor = editor; editingNew = false; pending = nil
    }
    /// Discard, or a finished save: back to the entry's details, or to nothing for a new entry.
    public mutating func closeEditor() { editor = nil; editingNew = false; pending = nil }
    /// After a save. A wide screen then shows the saved entry's details; a narrow one goes back to where it was.
    public mutating func saved(_ id: String, showDetails: Bool) {
        let wasNew = editingNew
        closeEditor()
        if wasNew && showDetails { viewing = id }
    }
    /// Closes the details (Back, Close, or the entry was deleted).
    public mutating func close() { viewing = nil; closeEditor() }
    /// Closes the details of an entry no longer in the vault (deleted from the list, or by another screen).
    public mutating func keepOnly(_ ids: Set<String>) {
        if let viewing, !ids.contains(viewing) { close() }
    }

    private mutating func apply(_ request: Request) {
        switch request {
        case .open(let id): viewing = id; editor = nil; editingNew = false
        case .create(let editor): viewing = nil; self.editor = editor; editingNew = true
        }
        pending = nil
    }
}

/// An editor's fields, kept outside the editor so they survive the screen changing width.
public protocol EditorForm: Equatable {
    /// Whether saving would change anything, so closing the editor would lose work.
    func hasChanges(from original: Self) -> Bool
}
public extension EditorForm {
    func hasChanges(from original: Self) -> Bool { self != original }
}
extension VaultRecord: EditorForm {}

/// The 2FA editor's fields. Which parts are revealed or expanded is not kept: a setup key is hidden again after a fold.
public struct TotpForm: EditorForm, Sendable {
    public var name: String
    public var issuer: String
    public var account: String
    public var key: String
    public var algorithm: String
    public var digits: Int
    public var period: Int
    public var notes: String
    public var favorite: Bool
    public init(record: VaultRecord) {
        let start = record.totp
        name = record.name; issuer = start?.issuer ?? ""; account = start?.account ?? ""
        key = start?.secretBase32 ?? ""; algorithm = start?.algorithm ?? "SHA1"
        digits = start?.digits ?? 6; period = start?.period ?? 30
        notes = record.fields.first { $0.kind == .note }?.value ?? ""; favorite = record.favorite
    }
    /// Algorithm, digits or period differ from what most sites use.
    public var usesAdvancedSettings: Bool { algorithm != "SHA1" || digits != 6 || period != 30 }
}

/// The seed phrase editor's fields, including a freshly generated phrase, so a fold does not replace the words someone is writing down.
public struct SeedForm: EditorForm, Sendable {
    public var name: String
    public var favorite: Bool
    /// "generate", "enter" or "key".
    public var mode: String
    public var typed: String
    public var key: String
    public var passphrase: String
    public var notes: String
    public var generated: [String] = []
    public var count: Int
    /// The person confirmed writing the generated words down.
    public var acknowledged: Bool
    public init(record: VaultRecord, isNew: Bool) {
        name = record.name; favorite = record.favorite
        mode = record.privateKey != nil ? "key" : isNew ? "generate" : "enter"
        typed = record.seedWords.joined(separator: " "); key = record.privateKey ?? ""
        count = Bip39.wordCounts.contains(record.seedWords.count) ? record.seedWords.count : 12
        passphrase = record.fields.first { $0.label == seedPassphraseLabel }?.value ?? ""
        notes = record.fields.first { $0.kind == .note }?.value ?? ""
        acknowledged = !isNew
    }
    /// The words or key that saving would store. Generated words count only once confirmed as written down; until then
    /// they are a suggestion, and a new phrase that was only generated has nothing to lose.
    private var secret: [String]? {
        switch mode {
        case "key": key.isEmpty ? [] : [key]
        case "generate": acknowledged ? generated : nil
        default: Bip39.split(typed)
        }
    }
    public func hasChanges(from original: SeedForm) -> Bool {
        if name != original.name || favorite != original.favorite || passphrase != original.passphrase || notes != original.notes { return true }
        guard let secret else { return false }
        return secret != (original.secret ?? [])
    }
}
