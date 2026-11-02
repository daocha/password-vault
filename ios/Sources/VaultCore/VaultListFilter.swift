import Foundation

/// List filters operate on the preserved imported group, never on secret field values.
public struct VaultListFilter {
    public var tab: VaultTab
    public var query: String
    public var favorites: Bool
    public var folder: String?
    public var kind: String?
    public init(tab: VaultTab = .passwords, query: String = "", favorites: Bool = false, folder: String? = nil, kind: String? = nil) {
        self.tab = tab; self.query = query; self.favorites = favorites; self.folder = folder; self.kind = kind
    }
    public static func folderName(_ record: VaultRecord) -> String { record.group.trimmingCharacters(in: .whitespacesAndNewlines) }
    public static func folders(in records: [VaultRecord]) -> [String] {
        var seen = Set<String>()
        return records.filter { VaultTab.passwords.contains($0) }.map(folderName)
            .filter { !$0.isEmpty && seen.insert($0).inserted }.sorted { $0.lowercased() < $1.lowercased() }
    }
    /// Android's editor/group dialog coalesces case variants; list filters keep the original folder names.
    public static func editableFolders(in records: [VaultRecord]) -> [String] {
        var seen = Set<String>()
        return records.filter { VaultTab.passwords.contains($0) }.map(folderName)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.sorted { $0.lowercased() < $1.lowercased() }
    }
    public static func visibleSelection(_ selected: Set<String>, in records: [VaultRecord]) -> Set<String> {
        selected.intersection(records.map(\.id))
    }
    public func apply(to records: [VaultRecord]) -> [VaultRecord] {
        records.filter {
            tab.contains($0) && $0.matches(query) && (!favorites || $0.favorite)
                && (tab != .passwords || folder == nil || Self.folderName($0) == folder)
                && (tab != .passwords || kind == nil || $0.type == kind)
        }.sorted {
            if tab == .totp { return TotpOrder.less($0, $1) }
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }
}

/// Group edits are staged until Apply, exactly as in Android's group dialog.
public struct VaultGroupAssignment {
    private let original: [String: String]
    public private(set) var pending: [String: String]
    public private(set) var names: [String]
    public init(records: [VaultRecord], ids: Set<String>) {
        original = Dictionary(uniqueKeysWithValues: records.filter { ids.contains($0.id) && VaultTab.passwords.contains($0) }.map { ($0.id, VaultListFilter.folderName($0)) })
        pending = original
        names = VaultListFilter.editableFolders(in: records)
    }
    public var count: Int { pending.count }
    public var hasChanges: Bool { pending != original }
    /// nil means some selected entries belong to this group; false means none.
    public func membership(_ name: String) -> Bool? {
        let count = pending.values.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name.lowercased() }.count
        return count == 0 ? false : count == pending.count ? true : nil
    }
    public mutating func assign(_ group: String) { pending = pending.mapValues { _ in group } }
    public mutating func add(_ text: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let existing = names.first { $0.lowercased() == name.lowercased() }
        if existing == nil { names.append(name); names.sort { $0.lowercased() < $1.lowercased() } }
        assign(existing ?? name)
    }
    public func applying(to records: [VaultRecord], now: String) -> [VaultRecord] {
        records.map { record in
            guard let next = pending[record.id], next != original[record.id] else { return record }
            var changed = record; changed.group = next; changed.updatedAt = now; return changed
        }
    }
}
