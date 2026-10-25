import Foundation
import Compression

/// Moving the vault to another phone without any network; the same format as Android's `Transfer`:
///
///     PVXFER01: magic 8 | u32be memKiB | u32be passes | salt 16 | XChaCha20-Poly1305 box (header as AAD)
///
/// The plaintext is raw DEFLATE of the same JSON as a backup. The key is Argon2id of the one-time code's 12 characters (59 bits, chosen at
/// random by the sender), at the local vault's cost.
public enum Transfer {
    static let magic = Data("PVXFER01".utf8)
    static let header = 32
    /// No 0/O, 1/I/L, so a code read off a screen is typed back correctly.
    public static let codeAlphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
    public static let codeLength = 12
    public static func newCode() -> String {
        String((0..<codeLength).map { _ in codeAlphabet[Int(VaultCrypto.random(4).reduce(0) { $0 << 8 | UInt32($1) } % UInt32(codeAlphabet.count))] })
    }
    /// "7K4P-92XM-QD3F".
    public static func display(_ code: String) -> String { stride(from: 0, to: code.count, by: 4).map { String(Array(code)[$0..<min(code.count, $0 + 4)]) }.joined(separator: "-") }
    /// The code as typed (any case, with or without dashes or spaces).
    public static func canonical(_ typed: String) throws -> String {
        let code = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard code.count == codeLength, code.allSatisfy(codeAlphabet.contains) else { throw VaultError.invalid("Check the transfer code: it is 12 letters and digits, shown on the other phone.") }
        return code
    }
    public static func isTransfer(_ data: Data) -> Bool { data.prefix(8) == magic }
    public static func seal(_ records: [VaultRecord], code: String) throws -> Data {
        let profile = KdfProfile.vault, salt = VaultCrypto.random(16)
        func be32(_ v: Int) -> Data { Data([UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]) }
        let head = magic + be32(profile.memKiB) + be32(Int(profile.opsLimit)) + salt
        var key = try VaultCrypto.passwordKey(canonical(code), salt: salt, profile: profile)
        defer { key.resetBytes(in: 0..<key.count) }
        return head + (try VaultCrypto.seal(Data(try deflate(Array(Records.encode(records)))), key: key, aad: head))
    }
    public static func open(_ data: Data, code typed: String) throws -> [VaultRecord] {
        let bytes = Array(data)
        guard isTransfer(data), bytes.count >= header + 40 else { throw VaultError.invalid("Not a PassVault transfer.") }
        func u32(_ o: Int) -> Int { Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3]) }
        let mem = u32(8), passes = u32(12)
        guard BackupFormat.memKiBRange.contains(mem), BackupFormat.passesRange.contains(passes) else { throw VaultError.invalid("Unsupported transfer settings.") }
        var key = try VaultCrypto.passwordKey(canonical(typed), salt: Data(bytes[16..<32]), profile: KdfProfile(opsLimit: UInt64(passes), memKiB: mem))
        defer { key.resetBytes(in: 0..<key.count) }
        let packed = try VaultCrypto.open(Data(bytes[header...]), key: key, aad: Data(bytes[..<header]))
        return try Records.decode(Data(try Inflate.raw(Array(packed), limit: Records.maxBytes)))
    }
    static func deflate(_ input: [UInt8]) throws -> [UInt8] {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1); defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw VaultError.invalid("Cannot compress.") }
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
                if status == COMPRESSION_STATUS_END { return out }
                guard status == COMPRESSION_STATUS_OK else { throw VaultError.invalid("Cannot compress.") }
            }
        }
    }
}

/// The QR form of a transfer, an endless stream: `PVX2:<session>:<count>:<size>:<seed>:<Base64url chunk>`; the same as Android's
/// `TransferFrames`. The `size` bytes are cut into `count` chunks of `chunk` bytes, the last padded with zeros. A frame with a seed below
/// `count` is that chunk; every later seed is the XOR of a pseudo-random half of the chunks (a random linear fountain code), so the receiver
/// can rebuild the transfer from any `count` or so frames it reads, instead of waiting for a loop to come round to the few it missed. Frames
/// carry only ciphertext; the code is never in them. Receivers also read the first version's loop, `PVX1:<session>:<index>/<count>:<chunk>`.
public enum TransferFrames {
    public static let chunk = 500, maxFrames = 4000
    static let prefix = "PVX2:", v1Prefix = "PVX1:"
    static let words = (chunk + 7) / 8
    public static func isFrame(_ text: String) -> Bool { text.hasPrefix(prefix) || text.hasPrefix(v1Prefix) }

    /// The frames of one transfer, by seed: the first `count` are the chunks in order, then mixes for as long as the screen is shown.
    public struct Sender: Sendable {
        let data: [UInt8], session: String
        public let count: Int
        public init(_ data: Data, session: String = String(Transfer.newCode().prefix(4))) throws {
            self.data = Array(data); self.session = session; count = (data.count + chunk - 1) / chunk
            guard (1...maxFrames).contains(count) else { throw VaultError.invalid("The vault is too large to send by QR code. Save a transfer file instead.") }
        }
        public func frame(_ seed: Int) -> String {
            var out = [UInt64](repeating: 0, count: words)
            if seed < count { xorChunk(&out, seed) } else { let m = mix(seed, count); for i in 0..<count where bit(m, i) { xorChunk(&out, i) } }
            return "\(prefix)\(session):\(count):\(data.count):\(seed):" + base64url(bytes(out))
        }
        private func xorChunk(_ into: inout [UInt64], _ index: Int) {
            for j in (index * chunk)..<min(data.count, (index + 1) * chunk) { let k = j - index * chunk; into[k / 8] ^= UInt64(data[j]) << (8 * UInt64(k % 8)) }
        }
    }

    /// Which chunks the frame with `seed` mixes: a bit per chunk, from SplitMix64 (the same on Android); never none.
    public static func mix(_ seed: Int, _ count: Int) -> [UInt64] {
        var state = UInt64(seed)
        var out = (0..<((count + 63) / 64)).map { _ -> UInt64 in
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state; z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9; z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB; return z ^ (z >> 31)
        }
        if count % 64 != 0 { out[out.count - 1] &= (1 << UInt64(count % 64)) - 1 }
        if out.allSatisfy({ $0 == 0 }) { setBit(&out, seed % count) }
        return out
    }
    static func bit(_ w: [UInt64], _ i: Int) -> Bool { (w[i / 64] >> UInt64(i % 64)) & 1 != 0 }
    static func setBit(_ w: inout [UInt64], _ i: Int) { w[i / 64] |= 1 << UInt64(i % 64) }
    static func xorWith(_ w: inout [UInt64], _ other: [UInt64]) { for i in w.indices { w[i] ^= other[i] } }
    static func words(_ bytes: [UInt8]) -> [UInt64] {
        var w = [UInt64](repeating: 0, count: words)
        for (k, b) in bytes.enumerated() { w[k / 8] |= UInt64(b) << (8 * UInt64(k % 8)) }
        return w
    }
    static func bytes(_ w: [UInt64]) -> [UInt8] { (0..<chunk).map { k in UInt8(truncatingIfNeeded: w[k / 8] >> (8 * UInt64(k % 8))) } }
    public static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Gauss–Jordan elimination over GF(2), one frame at a time: `rows[p]` is the only kept frame with chunk `p` in its mix, so a new frame
    /// costs one pass over the kept ones. Once every chunk has a row, each row is exactly its chunk.
    public final class Collector {
        private struct Row { var mix: [UInt64]; var data: [UInt64] }
        private var session: String?
        private var rows = [Row?]()
        /// Bytes in the transfer; -1 until known (a first-version loop says it only in its last frame).
        private var size = -1
        public init() {}
        public var total: Int { rows.count }
        public private(set) var received = 0
        public var complete: Bool { !rows.isEmpty && received == rows.count && size >= 0 }
        /// True when `text` was a frame of this transfer that brought something new. A frame from another transfer (a new session) starts over.
        @discardableResult public func add(_ text: String) -> Bool {
            guard let frame = parse(text) else { return false }
            if frame.session != session || frame.count != rows.count || (frame.size >= 0 && size >= 0 && frame.size != size) {
                session = frame.session; rows = Array(repeating: nil, count: frame.count); size = -1; received = 0
            }
            var mix: [UInt64]
            if frame.seed < frame.count { mix = [UInt64](repeating: 0, count: (frame.count + 63) / 64); setBit(&mix, frame.seed) } else { mix = TransferFrames.mix(frame.seed, frame.count) }
            var data = words(frame.chunk)
            for p in rows.indices { if let row = rows[p], bit(mix, p) { xorWith(&mix, row.mix); xorWith(&data, row.data) } }
            guard let pivot = (0..<frame.count).first(where: { bit(mix, $0) }) else { return false }
            for p in rows.indices { if let row = rows[p], bit(row.mix, pivot) { xorWith(&rows[p]!.mix, mix); xorWith(&rows[p]!.data, data) } }
            rows[pivot] = Row(mix: mix, data: data); received += 1
            if frame.size >= 0 { size = frame.size }
            return true
        }
        public func result() -> Data? {
            guard complete else { return nil }
            var out = [UInt8](); out.reserveCapacity(size)
            for row in rows { out.append(contentsOf: bytes(row!.data).prefix(size - out.count)) }
            return Data(out)
        }
    }

    struct Frame { let session: String, count: Int, size: Int, seed: Int, chunk: [UInt8] }
    static func parse(_ text: String) -> Frame? {
        func decode(_ s: Substring) -> [UInt8]? {
            var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            return Data(base64Encoded: b64).map(Array.init)
        }
        if text.hasPrefix(prefix) {
            let f = text.dropFirst(prefix.count).split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard f.count == 5, let count = Int(f[1]), let size = Int(f[2]), let seed = Int(f[3]), (1...maxFrames).contains(count),
                  ((count - 1) * chunk + 1...count * chunk).contains(size), seed >= 0, let part = decode(f[4]), part.count == chunk else { return nil }
            return Frame(session: String(f[0]), count: count, size: size, seed: seed, chunk: part)
        }
        guard text.hasPrefix(v1Prefix) else { return nil }
        let f = text.dropFirst(v1Prefix.count).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard f.count == 3 else { return nil }
        let numbers = f[1].split(separator: "/").compactMap { Int($0) }
        guard numbers.count == 2, (1...maxFrames).contains(numbers[1]), (1...numbers[1]).contains(numbers[0]), let part = decode(f[2]) else { return nil }
        let (index, count) = (numbers[0], numbers[1])
        // Every chunk but the last is full; the last one gives the size.
        guard !part.isEmpty, part.count <= chunk, index == count || part.count == chunk else { return nil }
        return Frame(session: String(f[0]), count: count, size: index == count ? (count - 1) * chunk + part.count : -1, seed: index - 1, chunk: part)
    }
}
