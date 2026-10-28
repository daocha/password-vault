import Foundation
import CryptoKit
import CommonCrypto
import Compression
import Clibsodium

/// Reads KeePass databases (`.kdbx`, versions 3.1 and 4.x) for import, like Android's `Kdbx`: AES-KDF, Argon2d and Argon2id; AES-256 and
/// ChaCha20; Salsa20 and ChaCha20 protected values; password, key file, or both. Twofish databases are refused with advice. Every MAC and
/// hash the format carries is checked before anything is used.
public enum Kdbx {
    static let aes = hex("31c1f2e6bf714350be5805216afc5aff"), chacha = hex("d6038a2b8b6f4cb5a524339a31dbb59a"), twofish = hex("ad68f29f576f4bb9a36ad47af965346c")
    static let aesKdf = hex("c9d9f39a628a4460bf740d08c18a4fea"), aesKdfKdbx4 = hex("7c02bb8279a74ac0927d114a00648238")
    static let argon2d = hex("ef636ddf8c29444b91f7a9a403e30a0c"), argon2id = hex("9e298b1956db4773b23dfc3ec6f0a1e6")
    static let maxArgon2Bytes: UInt64 = 512 * 1024 * 1024
    /// Key settings that would keep a phone busy for more than about a minute are refused: the import cannot be cancelled. KeePass and
    /// KeePassXC defaults (tens of thousands to a few million AES rounds, or Argon2 at 64 MiB and a few dozen passes) stay well below these.
    static let maxAesRounds: UInt64 = 100_000_000, maxArgon2WorkBytes: UInt64 = 8 * 1024 * 1024 * 1024 // Argon2: memory times iterations
    static var tooCostly: VaultError { .invalid("This database's key settings need more memory or time than a phone can provide. Lower them in KeePass (Database settings, Security) and export again.") }
    static func hex(_ s: String) -> [UInt8] { stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! } }
    static func u32(_ d: [UInt8], _ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 }
    static func u64(_ d: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    static func sha256(_ parts: [UInt8]...) -> [UInt8] { var h = SHA256(); parts.forEach { h.update(data: $0) }; return Array(h.finalize()) }
    static func sha512(_ parts: [UInt8]...) -> [UInt8] { var h = SHA512(); parts.forEach { h.update(data: $0) }; return Array(h.finalize()) }
    static var damaged: VaultError { .invalid("The KeePass file is damaged or not supported.") }

    public static func isKdbx(_ data: Data) -> Bool { data.count >= 12 && u32(Array(data.prefix(8)), 0) == 0x9AA2D903 && u32(Array(data.prefix(8)), 4) == 0xB54BFB67 }
    /// Imports a database. `password` nil means "no password" (key file only), which differs from an empty password.
    public static func importRecords(_ data: Data, password: String?, keyFile: Data?) throws -> [VaultRecord] {
        let (xml, stream) = try decrypt(Array(data), composite: compositeKey(password: password, keyFile: keyFile))
        return try KeePassXml.records(MiniXml.parse(xml), stream: stream)
    }
    /// Tries the password as given, and with a key file and an empty password also "no password", as KeePass allows both.
    public static func importTyped(_ data: Data, password: String, keyFile: Data?) throws -> [VaultRecord] {
        guard keyFile != nil, password.isEmpty else { return try importRecords(data, password: password, keyFile: keyFile) }
        do { return try importRecords(data, password: nil, keyFile: keyFile) } catch VaultError.authentication { return try importRecords(data, password: "", keyFile: keyFile) }
    }
    public static func compositeKey(password: String?, keyFile: Data?) throws -> [UInt8] {
        guard password != nil || keyFile != nil else { throw VaultError.invalid("Enter the database password or choose its key file.") }
        var parts = [UInt8]()
        if let password { parts += sha256(Array(password.utf8)) }
        if let keyFile { parts += try KeyFile.key(Array(keyFile)) }
        return sha256(parts)
    }

    struct Header { let major: Int; let fields: [Int: [UInt8]]; let end: Int }
    static func header(_ d: [UInt8]) throws -> Header {
        guard d.count >= 12, u32(d, 0) == 0x9AA2D903, u32(d, 4) == 0xB54BFB67 else { throw VaultError.invalid("Not a KeePass database.") }
        let major = Int(u32(d, 8) >> 16)
        guard major == 3 || major == 4 else { throw VaultError.invalid("This KeePass database version is not supported. Save it with KeePass 2 or KeePassXC (KDBX 3.1 or 4) first.") }
        var fields = [Int: [UInt8]](), pos = 12
        while true {
            guard pos + (major >= 4 ? 5 : 3) <= d.count else { throw damaged }
            let id = Int(d[pos]), size = major >= 4 ? Int(Int32(bitPattern: u32(d, pos + 1))) : Int(d[pos + 1]) | Int(d[pos + 2]) << 8
            pos += major >= 4 ? 5 : 3
            guard size >= 0, pos + size <= d.count else { throw damaged }
            fields[id] = Array(d[pos..<pos + size]); pos += size
            if id == 0 { break }
        }
        return Header(major: major, fields: fields, end: pos)
    }
    /// KDBX 4 VariantDictionary: u16 version, then entries of type, i32 name length, name, i32 value length, value.
    static func variantDictionary(_ b: [UInt8]) throws -> [String: Any] {
        guard b.count >= 2, b[1] == 1 else { throw damaged }
        var out = [String: Any](), pos = 2
        while pos < b.count {
            let type = b[pos]; pos += 1
            if type == 0 { break }
            guard pos + 4 <= b.count else { throw damaged }
            let nameLength = Int(Int32(bitPattern: u32(b, pos))); pos += 4
            guard nameLength >= 0, pos + nameLength + 4 <= b.count else { throw damaged }
            let name = String(decoding: b[pos..<pos + nameLength], as: UTF8.self); pos += nameLength
            let length = Int(Int32(bitPattern: u32(b, pos))); pos += 4
            guard length >= 0, pos + length <= b.count else { throw damaged }
            switch type {
            case 0x04, 0x0C: guard length >= 4 else { throw damaged }; out[name] = UInt64(u32(b, pos))
            case 0x05, 0x0D: guard length >= 8 else { throw damaged }; out[name] = u64(b, pos)
            case 0x08: out[name] = UInt64(b[pos])
            default: out[name] = Array(b[pos..<pos + length])
            }
            pos += length
        }
        return out
    }
    static func transform(_ h: Header, _ composite: [UInt8]) throws -> [UInt8] {
        if h.major < 4 {
            guard let seed = h.fields[5], let rounds = h.fields[6], rounds.count == 8 else { throw damaged }
            return try aesKdf(composite, seed: seed, rounds: u64(rounds, 0))
        }
        guard let raw = h.fields[11] else { throw damaged }
        let params = try variantDictionary(raw)
        guard let kdf = params["$UUID"] as? [UInt8] else { throw damaged }
        if kdf == aesKdf || kdf == aesKdfKdbx4 {
            guard let seed = params["S"] as? [UInt8], let rounds = params["R"] as? UInt64 else { throw damaged }
            return try aesKdf(composite, seed: seed, rounds: rounds)
        }
        guard kdf == argon2d || kdf == argon2id else { throw VaultError.invalid("This database uses a key derivation PassVault does not support.") }
        guard let memory = params["M"] as? UInt64, let iterations = params["I"] as? UInt64, let lanes = params["P"] as? UInt64, let salt = params["S"] as? [UInt8] else { throw damaged }
        let version = params["V"] as? UInt64 ?? 0x13
        guard version == 0x10 || version == 0x13 else { throw damaged }
        guard (8 * 1024...maxArgon2Bytes).contains(memory), (1...maxArgon2WorkBytes / memory).contains(iterations), (1...256).contains(lanes) else { throw tooCostly }
        return try Argon2.hash(password: composite, salt: salt, secret: params["K"] as? [UInt8] ?? [], associated: params["A"] as? [UInt8] ?? [], iterations: Int(iterations),
                               memoryKiB: Int(memory / 1024), lanes: Int(lanes), variant: kdf == argon2d ? .d : .id, version: UInt32(version))
    }
    static func aesKdf(_ composite: [UInt8], seed: [UInt8], rounds: UInt64) throws -> [UInt8] {
        guard seed.count == 32 else { throw damaged }
        guard rounds <= maxAesRounds else { throw tooCostly }
        var cryptor: CCCryptorRef?
        guard CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), seed, seed.count, nil, &cryptor) == kCCSuccess, let cryptor else { throw damaged }
        defer { CCCryptorRelease(cryptor) }
        var a = composite, b = [UInt8](repeating: 0, count: 32), moved = 0
        for _ in 0..<rounds { _ = CCCryptorUpdate(cryptor, a, 32, &b, 32, &moved); swap(&a, &b) }
        return sha256(a)
    }

    /// The database XML and the protected-value stream. Throws `VaultError.authentication` for wrong credentials.
    static func decrypt(_ d: [UInt8], composite: [UInt8]) throws -> (Data, InnerStream?) {
        let h = try header(d)
        guard let cipherId = h.fields[2] else { throw damaged }
        if cipherId == twofish { throw VaultError.invalid("This database is encrypted with Twofish. In KeePass, change the encryption to AES or ChaCha20 (Database settings, Security), save, and import again.") }
        guard cipherId == aes || cipherId == chacha else { throw VaultError.invalid("This database uses an encryption PassVault does not support.") }
        guard let masterSeed = h.fields[4], let iv = h.fields[7] else { throw damaged }
        let transformed = try transform(h, composite), key = sha256(masterSeed, transformed)
        let compressed = (h.fields[3].map { $0.count >= 4 ? u32($0, 0) : 0 } ?? 0) == 1
        if h.major < 4 {
            guard let plain = try cipher(cipherId, key: key, iv: iv, Array(d[h.end...])) else { throw VaultError.authentication }
            guard let start = h.fields[9], plain.count >= 32, Array(plain.prefix(32)) == start else { throw VaultError.authentication }
            let payload = try hashedBlocks(plain, start: 32)
            let xml = compressed ? try Inflate.gunzip(payload) : payload
            let streamId = h.fields[10].map { $0.count >= 4 ? u32($0, 0) : 0 } ?? 0
            return (Data(xml), try InnerStream.make(id: streamId, key: h.fields[8] ?? []))
        }
        guard d.count >= h.end + 64, sha256(Array(d[..<h.end])) == Array(d[h.end..<h.end + 32]) else { throw damaged }
        let hmacBase = sha512(masterSeed, transformed, [1])
        func blockKey(_ index: UInt64) -> SymmetricKey { SymmetricKey(data: sha512(le64(index), hmacBase)) }
        func mac(_ key: SymmetricKey, _ parts: [UInt8]...) -> [UInt8] { var m = HMAC<SHA256>(key: key); parts.forEach { m.update(data: $0) }; return Array(m.finalize()) }
        guard mac(blockKey(UInt64.max), Array(d[..<h.end])) == Array(d[h.end + 32..<h.end + 64]) else { throw VaultError.authentication }
        var encrypted = [UInt8](), pos = h.end + 64, index: UInt64 = 0
        while true {
            guard pos + 36 <= d.count else { throw damaged }
            let size = Int(Int32(bitPattern: u32(d, pos + 32)))
            guard size >= 0, pos + 36 + size <= d.count else { throw damaged }
            let block = Array(d[pos + 36..<pos + 36 + size]), sizeBytes = Array(d[pos + 32..<pos + 36])
            guard mac(blockKey(index), le64(index), sizeBytes, block) == Array(d[pos..<pos + 32]) else { throw damaged }
            pos += 36 + size; index += 1
            if size == 0 { break }
            encrypted += block; guard encrypted.count <= Records.maxBytes * 2 else { throw VaultError.invalid("The database is too large.") }
        }
        guard let plain = try cipher(cipherId, key: key, iv: iv, encrypted) else { throw damaged }
        let payload = compressed ? try Inflate.gunzip(plain) : plain
        // Inner header: id u8, size i32, data. 1 = stream id, 2 = stream key, 3 = attachment (not imported), 0 = end.
        var streamId: UInt32 = 0, streamKey = [UInt8](), p = 0
        while true {
            guard p + 5 <= payload.count else { throw damaged }
            let id = payload[p], size = Int(Int32(bitPattern: u32(payload, p + 1))); p += 5
            guard size >= 0, p + size <= payload.count else { throw damaged }
            if id == 1, size >= 4 { streamId = u32(payload, p) } else if id == 2 { streamKey = Array(payload[p..<p + size]) }
            p += size
            if id == 0 { break }
        }
        return (Data(payload[p...]), try InnerStream.make(id: streamId, key: streamKey))
    }
    /// nil when AES padding is wrong, which for KDBX 3 means wrong credentials.
    static func cipher(_ id: [UInt8], key: [UInt8], iv: [UInt8], _ input: [UInt8]) throws -> [UInt8]? {
        if id == aes {
            guard iv.count == 16 else { throw damaged }
            var out = [UInt8](repeating: 0, count: input.count + 16), produced = 0
            let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv, input, input.count, &out, out.count, &produced)
            return status == kCCSuccess ? Array(out.prefix(produced)) : nil
        }
        guard iv.count == 12 else { throw damaged }
        var out = [UInt8](repeating: 0, count: input.count)
        _ = crypto_stream_chacha20_ietf_xor(&out, input, UInt64(input.count), iv, key)
        return out
    }
    /// KDBX 3 hashed block stream: u32 index, 32-byte SHA-256, u32 size, data; a zero-size block ends it.
    static func hashedBlocks(_ d: [UInt8], start: Int) throws -> [UInt8] {
        var out = [UInt8](), pos = start, expected: UInt32 = 0
        while true {
            guard pos + 40 <= d.count else { throw damaged }
            let index = u32(d, pos), hash = Array(d[pos + 4..<pos + 36]), size = Int(u32(d, pos + 36)); pos += 40
            guard index == expected, pos + size <= d.count else { throw damaged }
            expected += 1
            if size == 0 { break }
            let block = Array(d[pos..<pos + size]); pos += size
            guard sha256(block) == hash else { throw damaged }
            out += block; guard out.count <= Records.maxBytes * 2 else { throw VaultError.invalid("The database is too large.") }
        }
        return out
    }
}

/// The key stream that protects KeePass field values, consumed in document order (Salsa20 for KDBX 3, ChaCha20 for KDBX 4).
final class InnerStream {
    private let id: UInt32, key: [UInt8], nonce: [UInt8]
    private init(id: UInt32, key: [UInt8], nonce: [UInt8]) { self.id = id; self.key = key; self.nonce = nonce }
    static func make(id: UInt32, key: [UInt8]) throws -> InnerStream? {
        switch id {
        case 0: return nil
        case 2: return InnerStream(id: 2, key: Kdbx.sha256(key), nonce: [0xE8, 0x30, 0x09, 0x4B, 0x97, 0x20, 0x5D, 0x2A])
        case 3: let h = Kdbx.sha512(key); return InnerStream(id: 3, key: Array(h[0..<32]), nonce: Array(h[32..<44]))
        default: throw VaultError.invalid("This database protects its fields with a method PassVault does not support.")
        }
    }
    /// The first `count` key-stream bytes.
    func keystream(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(count, 1))
        if id == 2 { _ = crypto_stream_salsa20(&out, UInt64(count), nonce, key) } else { _ = crypto_stream_chacha20_ietf(&out, UInt64(count), nonce, key) }
        return Array(out.prefix(count))
    }
}

/// KeePass key files: XML version 1.0 (Base64) or 2.0 (hex with a check hash), 32 raw bytes, 64 hex digits, or any other file (hashed).
public enum KeyFile {
    public static func key(_ file: [UInt8]) throws -> [UInt8] {
        if file.count == 32 { return file }
        let text = String(bytes: file, encoding: .utf8)
        let isHex = { (s: String) in s.allSatisfy { $0.isHexDigit && $0.isASCII } }
        if file.count == 64, let text, isHex(text) { return Kdbx.hex(text.lowercased()) }
        if let text, text.drop(while: { $0 == "\u{FEFF}" || $0.isWhitespace }).hasPrefix("<"), let root = try? MiniXml.parse(Data(file)), root.name == "KeyFile" {
            let damaged = VaultError.invalid("The key file is damaged.")
            guard let data = root.child("Key")?.child("Data") else { throw damaged }
            if (root.child("Meta")?.child("Version")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").hasPrefix("2") {
                let hex = data.text.filter { !$0.isWhitespace }
                guard hex.count == 64, isHex(hex) else { throw damaged }
                let bytes = Kdbx.hex(hex.lowercased())
                if let check = data.attributes["Hash"], Kdbx.sha256(bytes).prefix(4).map({ String(format: "%02x", $0) }).joined() != check.trimmingCharacters(in: .whitespaces).lowercased() { throw damaged }
                return bytes
            }
            guard let bytes = Data(base64Encoded: data.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw damaged }
            return Array(bytes)
        }
        return Kdbx.sha256(file)
    }
}

/// Raw DEFLATE (as in gzip and zip) through Apple's Compression framework, refusing output past a bound.
enum Inflate {
    static func raw(_ input: [UInt8], limit: Int) throws -> [UInt8] {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1); defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw VaultError.invalid("Cannot decompress.") }
        defer { compression_stream_destroy(stream) }
        var out = [UInt8](), buffer = [UInt8](repeating: 0, count: 65536)
        return try input.withUnsafeBufferPointer { source in
            stream.pointee.src_ptr = source.baseAddress ?? UnsafePointer(bitPattern: 1)!; stream.pointee.src_size = input.count
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { dst -> compression_status in
                    stream.pointee.dst_ptr = dst.baseAddress!; stream.pointee.dst_size = dst.count
                    return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                out += buffer.prefix(buffer.count - stream.pointee.dst_size)
                guard out.count <= limit else { throw VaultError.invalid("The file is too large.") }
                if status == COMPRESSION_STATUS_END { return out }
                guard status == COMPRESSION_STATUS_OK else { throw VaultError.invalid("The file is damaged.") }
            }
        }
    }
    static func gunzip(_ d: [UInt8]) throws -> [UInt8] {
        guard d.count >= 18, d[0] == 0x1F, d[1] == 0x8B, d[2] == 8 else { throw Kdbx.damaged }
        let flags = d[3]; var pos = 10
        if flags & 4 != 0 { guard pos + 2 <= d.count else { throw Kdbx.damaged }; pos += 2 + Int(d[pos]) | Int(d[pos + 1]) << 8 }
        if flags & 8 != 0 { while pos < d.count && d[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 16 != 0 { while pos < d.count && d[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 2 != 0 { pos += 2 }
        guard pos < d.count else { throw Kdbx.damaged }
        return try raw(Array(d[pos...]), limit: Records.maxBytes * 4)
    }
}

/// KeePass XML (from a `.kdbx` or KeePass's XML export) to PassVault records, like Android's. Entries in the recycle bin are skipped.
enum KeePassXml {
    static let standard: Set<String> = ["Title", "UserName", "Password", "URL", "Notes"]
    static let otpKeys: Set<String> = ["otp", "TOTP Seed", "TOTP Settings", "TimeOtp-Secret", "TimeOtp-Secret-Hex", "TimeOtp-Secret-Base32", "TimeOtp-Secret-Base64", "TimeOtp-Length", "TimeOtp-Period", "TimeOtp-Algorithm"]
    /// KDBX 3.1 writes ISO times; KDBX 4 writes Base64 of int64 seconds since 0001-01-01.
    static func time(_ text: String?) -> Date? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.contains("-") {
            // Fractional seconds are accepted too, like Android's `Instant.parse`.
            let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
            return plain.date(from: t) ?? fractional.date(from: t)
        }
        guard let b = Data(base64Encoded: t), b.count == 8 else { return nil }
        // In floating point: a damaged value near Int64.min would overflow (and crash) as integer arithmetic.
        return Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: Kdbx.u64(Array(b), 0))) - 62_135_596_800)
    }
    static func records(_ root: XmlElement, stream: InnerStream?) throws -> [VaultRecord] {
        guard root.name == "KeePassFile" else { throw VaultError.invalid("Unrecognised XML file. PassVault reads KeePass XML exports.") }
        // Protected values are XORed with one key stream, consumed in document order across the whole file.
        var protected = [(XmlElement, [UInt8])]()
        try root.walk { e in
            guard e.attributes["Protected"]?.lowercased() == "true" else { return }
            guard let bytes = Data(base64Encoded: e.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw Kdbx.damaged }
            protected.append((e, Array(bytes)))
        }
        if !protected.isEmpty {
            guard let stream else { throw Kdbx.damaged }
            let keys = stream.keystream(protected.reduce(0) { $0 + $1.1.count }); var offset = 0
            for (element, bytes) in protected {
                element.text = String(decoding: zip(bytes, keys[offset..<offset + bytes.count]).map { $0 ^ $1 }, as: UTF8.self); offset += bytes.count
            }
        }
        let meta = root.child("Meta")
        let recycleBin = meta?.child("RecycleBinEnabled")?.text.trimmingCharacters(in: .whitespaces).lowercased() == "true" ? meta?.child("RecycleBinUUID")?.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        guard let top = root.child("Root")?.child("Group") else { return [] }
        var out = [VaultRecord]()
        func visit(_ group: XmlElement, _ path: String) {
            for entry in group.all("Entry") { out += self.entry(entry, group: path) }
            for child in group.all("Group") {
                if let recycleBin, child.child("UUID")?.text.trimmingCharacters(in: .whitespacesAndNewlines) == recycleBin { continue }
                let name = child.child("Name")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                visit(child, path.isEmpty ? name : path + "/" + name)
            }
        }
        visit(top, "")
        return try Records.validate(out)
    }
    struct Strings {
        var values = [(String, String)](), secret = Set<String>()
        init(_ entry: XmlElement) {
            for s in entry.all("String") {
                guard let key = s.child("Key")?.text, let value = s.child("Value") else { continue }
                if let index = values.firstIndex(where: { $0.0 == key }) { values[index].1 = value.text } else { values.append((key, value.text)) }
                if value.attributes["Protected"]?.lowercased() == "true" || value.attributes["ProtectInMemory"]?.lowercased() == "true" { secret.insert(key) }
            }
        }
        subscript(_ key: String) -> String { values.first { $0.0 == key }?.1 ?? "" }
    }
    static func entry(_ entry: XmlElement, group: String) -> [VaultRecord] {
        let s = Strings(entry)
        guard s.values.contains(where: { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return [] }
        let times = entry.child("Times"), updated = time(times?.child("LastModificationTime")?.text)
        var expires = ""
        if times?.child("Expires")?.text.trimmingCharacters(in: .whitespaces).lowercased() == "true", let date = time(times?.child("ExpiryTime")?.text) { expires = Expiry.imported(date) }
        // History versions (oldest first) then the entry itself: each password that was replaced is kept with the time it was replaced.
        let versions = (entry.child("History")?.all("Entry") ?? []).map { (Strings($0)["Password"], time($0.child("Times")?.child("LastModificationTime")?.text)) } + [(s["Password"], updated)]
        let history = zip(versions, versions.dropFirst()).filter { !$0.0.0.isEmpty && $0.0.0 != $0.1.0 }
            .map { PasswordChange(value: $0.0.0, changedAt: Int64(($0.1.1 ?? $0.0.1)?.timeIntervalSince1970 ?? 0)) }
        let name = ImportBuilder.name(s["Title"], website: s["URL"])
        let totp = totpURI(s, name: name)
        let usableTotp = ImportBuilder.totp(totp, name: name, account: s["UserName"]) != nil
        // Keep the original KeePass fields if conversion fails; otherwise an unsupported key or setting disappears on import.
        let extra = s.values.filter { !standard.contains($0.0) && (!usableTotp || !otpKeys.contains($0.0)) }
            .map { ImportBuilder.extra($0.0, $0.1, secret: otpKeys.contains($0.0) || s.secret.contains($0.0)) }
        return ImportBuilder.login(name, website: s["URL"], username: s["UserName"], password: s["Password"], notes: s["Notes"], group: group, updatedAt: updated,
                                   expires: expires, history: history, extra: extra, totp: usableTotp ? totp : "")
    }
    /// KeePassXC's `otp` URI, KeePass 2.47+ `TimeOtp-*` fields, or the older `TOTP Seed` / `TOTP Settings` pair, as an otpauth URI.
    static func totpURI(_ s: Strings, name: String) -> String {
        if !s["otp"].trimmingCharacters(in: .whitespaces).isEmpty { return s["otp"] }
        func uri(_ secret: Data, _ digits: Int, _ period: Int, _ algorithm: String) -> String { (try? TotpAccount(secret: secret, issuer: name, account: s["UserName"], algorithm: algorithm, digits: digits, period: period).uri) ?? "" }
        func setting(_ value: String, _ fallback: Int) -> Int? { let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.isEmpty ? fallback : Int(trimmed) }
        var secret: Data?
        if !s["TimeOtp-Secret-Base32"].isEmpty { secret = try? Totp.decodeBase32(s["TimeOtp-Secret-Base32"]) }
        else if !s["TimeOtp-Secret-Hex"].isEmpty { let h = s["TimeOtp-Secret-Hex"].filter { !$0.isWhitespace }; if h.count % 2 == 0, h.allSatisfy(\.isHexDigit) { secret = Data(Kdbx.hex(h.lowercased())) } }
        else if !s["TimeOtp-Secret-Base64"].isEmpty { secret = Data(base64Encoded: s["TimeOtp-Secret-Base64"].trimmingCharacters(in: .whitespaces)) }
        else if !s["TimeOtp-Secret"].isEmpty { secret = Data(s["TimeOtp-Secret"].utf8) }
        if let secret {
            let algorithm: String
            switch s["TimeOtp-Algorithm"].trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "-", with: "") {
            case "", "HMACSHA1", "SHA1": algorithm = "SHA1"
            case "HMACSHA256", "SHA256": algorithm = "SHA256"
            case "HMACSHA512", "SHA512": algorithm = "SHA512"
            default: return ""
            }
            guard let digits = setting(s["TimeOtp-Length"], 6), let period = setting(s["TimeOtp-Period"], 30) else { return "" }
            return uri(secret, digits, period, algorithm)
        }
        if !s["TOTP Seed"].trimmingCharacters(in: .whitespaces).isEmpty {
            let settings = s["TOTP Settings"].split(separator: ";", omittingEmptySubsequences: false)
            guard let seed = try? Totp.decodeBase32(s["TOTP Seed"]) else { return s["TOTP Seed"] }
            guard let digits = setting(settings.count > 1 ? String(settings[1]) : "", 6), let period = setting(settings.first.map(String.init) ?? "", 30) else { return "" }
            return uri(seed, digits, period, "SHA1")
        }
        return ""
    }
}
