import Foundation
import CryptoKit
import Security
import Clibsodium

/// A random source failed a safety check, so no seed phrase was made. Every failure shows the same localized message;
/// `detail` says which check failed, for tests and diagnostics.
public struct EntropyFailure: Error, LocalizedError, Equatable {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
    public var errorDescription: String? { SeedEntropy.failureMessage }
}

/// Where seed-phrase randomness comes from, and the checks it passes before a phrase is shown. Android's `SeedEntropy` does the same.
///
/// Two separate paths to the system's random generator are read and hashed together, so a fault in one path (libsodium's generator
/// swapped out, a call routed to a generator that is not cryptographic, a source that returns a constant) cannot weaken a phrase while
/// the other path works. Both paths end in the kernel's generator: this guards against faults in the code above the kernel, not in the
/// kernel itself.
public enum SeedEntropy {
    /// Bytes read from each source for every phrase.
    public static let blockSize = 32
    /// A block in which one byte value appears this often is rejected. A working source does that about once in 7 billion blocks
    /// (256 · P[Binomial(32, 1/256) ≥ 8] ≈ 1.3e-10); a stuck, all-zero or heavily biased source does it at once.
    public static let maxRepeats = 8
    static let domain = Array("PassVault/bip39-entropy/v1".utf8)
    public static let failureMessage = "This device's random number generator failed a safety check, so no phrase was made. Try again. If this keeps happening, don't create seed phrases on this device."

    /// One random source. It keeps a digest of its last block, so a source that returns the same block twice is caught.
    public final class Source: @unchecked Sendable {
        public let name: String
        private let fill: (inout [UInt8]) throws -> Void
        private var last: SHA256.Digest?
        private let lock = NSLock()
        public init(name: String, fill: @escaping (inout [UInt8]) throws -> Void) { self.name = name; self.fill = fill }

        /// A fresh `blockSize`-byte block that passed the checks. The caller wipes it.
        public func read() throws -> [UInt8] {
            lock.lock(); defer { lock.unlock() }
            var block = [UInt8](repeating: 0, count: SeedEntropy.blockSize)
            do {
                do { try fill(&block) } catch let failure as EntropyFailure { throw failure } catch { throw EntropyFailure("\(name) could not be read (\(error)).") }
                guard block.count == SeedEntropy.blockSize else { throw EntropyFailure("\(name) returned \(block.count) bytes.") }
                guard SeedEntropy.healthy(block) else { throw EntropyFailure("\(name) returned a block that fails the health check.") }
                let digest = SHA256.hash(data: block)
                if digest == last { throw EntropyFailure("\(name) returned its previous block again.") }
                last = digest
                return block
            } catch {
                SeedEntropy.wipe(&block)
                throw error
            }
        }
    }

    /// False when one byte value appears `maxRepeats` or more times in `block`.
    public static func healthy(_ block: [UInt8]) -> Bool {
        var counts = [Int](repeating: 0, count: 256)
        defer { sodium_memzero(&counts, counts.count * MemoryLayout<Int>.stride) }
        for byte in block {
            counts[Int(byte)] += 1
            if counts[Int(byte)] >= maxRepeats { return false }
        }
        return true
    }

    /// SHA-256 over the domain tag, the output `length` and every block preceded by its length (32-bit big-endian), cut to `length`
    /// bytes. The lengths make the encoding unambiguous: no two different lists of blocks hash the same input.
    public static func mix(_ blocks: [[UInt8]], length: Int) -> [UInt8] {
        precondition((1...32).contains(length))
        var hasher = SHA256()
        hasher.update(data: domain); hasher.update(data: be32(length))
        for block in blocks { hasher.update(data: be32(block.count)); hasher.update(data: block) }
        return Array(hasher.finalize().prefix(length))
    }

    /// True when `entropy` equals the start of a raw block: the phrase would not have gone through `mix`.
    public static func unmixed(_ blocks: [[UInt8]], _ entropy: [UInt8]) -> Bool {
        blocks.contains { $0.count >= entropy.count && $0.prefix(entropy.count).elementsEqual(entropy) }
    }

    /// Overwrites `bytes` in place (libsodium's memzero, which the compiler cannot remove). `bytes` must be the only reference to its
    /// storage, or Swift copies it first and wipes the copy.
    static func wipe(_ bytes: inout [UInt8]) { sodium_memzero(&bytes, bytes.count) }

    private static func be32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 255), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)] }

    /// libsodium's generator, refused unless it is `expected`. `sysrandom` is libsodium's default; on Apple platforms it is
    /// `arc4random_buf`, seeded by the kernel. Another name means something replaced it (`randombytes_set_implementation`).
    public static func sodiumSource(expected: String = "sysrandom") -> Source {
        Source(name: "libsodium") { block in
            guard VaultCrypto.initialized else { throw EntropyFailure("libsodium is not initialized.") }
            let implementation = String(cString: randombytes_implementation_name())
            guard implementation == expected else { throw EntropyFailure("libsodium uses \(implementation), not \(expected).") }
            randombytes_buf(&block, block.count)
        }
    }

    /// The Security framework's generator, which does not go through libsodium.
    public static func secRandomSource() -> Source {
        Source(name: "SecRandomCopyBytes") { block in
            let status = SecRandomCopyBytes(kSecRandomDefault, block.count, &block)
            guard status == errSecSuccess else { throw EntropyFailure("SecRandomCopyBytes failed (\(status)).") }
        }
    }

    /// The two sources every generated phrase mixes.
    public static let system: [Source] = [sodiumSource(), secRandomSource()]
}
