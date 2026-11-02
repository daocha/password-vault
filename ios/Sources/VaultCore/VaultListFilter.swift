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
