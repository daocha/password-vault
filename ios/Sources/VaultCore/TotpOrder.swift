import Foundation

/// Android stores the order in this existing metadata key, preserved by backups and transfers.
public enum TotpOrder {
    public static let key = "totpOrder"
    public static func position(_ record: VaultRecord) -> Int32? { record.legacy[key].flatMap(Int32.init) }
    public static func less(_ lhs: VaultRecord, _ rhs: VaultRecord) -> Bool {
        let a = position(lhs) ?? .max, b = position(rhs) ?? .max
        if a != b { return a < b }
        if lhs.favorite != rhs.favorite { return lhs.favorite }
        return lhs.name.lowercased() < rhs.name.lowercased()
    }
    /// As on Android, only moved codes are stamped; unrelated records and metadata stay intact.
    public static func apply(_ records: [VaultRecord], ordered: [String], now: String) -> [VaultRecord] {
        let positions = ordered.enumerated().reduce(into: [String: Int32]()) { $0[$1.element] = Int32($1.offset) }
        return records.map { record in
            guard record.isTotp, let next = positions[record.id], position(record) != next else { return record }
            var changed = record; changed.legacy[key] = String(next); changed.updatedAt = now
            return changed
        }
    }
}
