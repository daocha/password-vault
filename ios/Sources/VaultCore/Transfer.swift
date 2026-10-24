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

/// The QR form of a transfer: `PVX1:<session>:<index>/<count>:<Base64url chunk>`, shown in a loop; the same as Android's `TransferFrames`.
/// Frames carry only ciphertext; the code is never in them.
public enum TransferFrames {
    public static let chunk = 500, maxFrames = 4000
    static let prefix = "PVX1:"
    public static func frames(_ data: Data, session: String = String(Transfer.newCode().prefix(4))) throws -> [String] {
        let bytes = Array(data), count = (bytes.count + chunk - 1) / chunk
        guard count <= maxFrames else { throw VaultError.invalid("The vault is too large to send by QR code. Save a transfer file instead.") }
        return (0..<count).map { i in
            let part = Data(bytes[(i * chunk)..<min(bytes.count, (i + 1) * chunk)])
            let b64 = part.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "\(prefix)\(session):\(i + 1)/\(count):\(b64)"
        }
    }
    public static func isFrame(_ text: String) -> Bool { text.hasPrefix(prefix) }
    public final class Collector {
        private var session: String?
        private var parts = [Data?]()
        public init() {}
        public var total: Int { parts.count }
        public var received: Int { parts.filter { $0 != nil }.count }
        public var complete: Bool { !parts.isEmpty && parts.allSatisfy { $0 != nil } }
        /// True when `text` was a new frame of this transfer. A frame from another transfer (a new session) starts over.
        @discardableResult public func add(_ text: String) -> Bool {
            guard isFrame(text) else { return false }
            let fields = text.dropFirst(prefix.count).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return false }
            let numbers = fields[1].split(separator: "/").compactMap { Int($0) }
            guard numbers.count == 2, (1...maxFrames).contains(numbers[1]), (1...numbers[1]).contains(numbers[0]) else { return false }
            var b64 = fields[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let part = Data(base64Encoded: b64), !part.isEmpty, part.count <= chunk else { return false }
            if String(fields[0]) != session || numbers[1] != parts.count { session = String(fields[0]); parts = Array(repeating: nil, count: numbers[1]) }
            guard parts[numbers[0] - 1] == nil else { return false }
            parts[numbers[0] - 1] = part; return true
        }
        public func result() -> Data? { complete ? parts.reduce(Data()) { $0 + $1! } : nil }
    }
}
