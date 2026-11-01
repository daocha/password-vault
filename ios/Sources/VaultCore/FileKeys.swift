import Foundation

/// File keys travel through iOS as ordinary secure notes. Imports must keep their secrets even though iOS cannot encrypt files.
enum FileKeys {
    static let created = "fileKeyCreated"
    static func identity(_ record: VaultRecord) -> String? {
        guard record.isNote, let value = record.fields.first(where: { $0.kind == .password && $0.label == "age secret key" })?.value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.allSatisfy({ (33...126).contains($0) }), text == text.lowercased() || text == text.uppercased() else { return nil }
        let lower = text.lowercased()
        guard let split = lower.lastIndex(of: "1") else { return nil }
        let hrp = String(lower[..<split])
        guard hrp == "age-secret-key-" || hrp == "age-secret-key-pq-" else { return nil }
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
        let encoded = Array(lower[lower.index(after: split)...].utf8)
        guard encoded.count == 58 else { return nil } // 256 bits, four zero padding bits, six checksum characters.
        let values = encoded.compactMap { alphabet.firstIndex(of: $0).map(UInt32.init) }
        guard values.count == encoded.count, values[51] & 15 == 0 else { return nil }
        let bytes = Array(hrp.utf8)
        let expanded = bytes.map { UInt32($0 >> 5) } + [0] + bytes.map { UInt32($0 & 31) }
        let generator: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var checksum: UInt32 = 1
        for value in expanded + values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ value
            for i in 0..<5 where (top >> i) & 1 == 1 { checksum ^= generator[i] }
        }
        return checksum == 1 ? text.uppercased() : nil
    }
    static func stamp(_ records: [VaultRecord]) -> [VaultRecord] {
        records.map { record in
            guard identity(record) != nil, record.legacy[created] == nil else { return record }
            var stamped = record; stamped.legacy[created] = record.updatedAt; return stamped
        }
    }
    static func keeping(_ before: [VaultRecord], in imported: [VaultRecord]) -> [VaultRecord] {
        let secrets = Set(imported.compactMap(identity))
        var ids = Set(imported.map(\.id)), result = imported
        for record in before {
            guard let secret = identity(record), !secrets.contains(secret) else { continue }
            var kept = record
            while ids.contains(kept.id) { kept.id = UUID().uuidString }
            ids.insert(kept.id); result.append(kept)
        }
        return result
    }
}
