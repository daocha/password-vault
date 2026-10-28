import Foundation
import Clibsodium

/// Argon2id cost. `memKiB` is stored in backup headers, so it is kept in KiB.
public struct KdfProfile: Equatable {
    public let opsLimit: UInt64
    public let memKiB: Int
    var memBytes: Int { memKiB * 1024 }
    /// Local vault (also guarded by the device secret and attempt limit) and QVAULT01 backups.
    public static let vault = KdfProfile(opsLimit: 3, memKiB: 64 * 1024)
    /// QVAULT02 backups: portable and attackable offline with no attempt limit, so each guess is made costlier.
    public static let backup = KdfProfile(opsLimit: 4, memKiB: 256 * 1024)
}
/// Passwords are used as NFKC-normalized UTF-8, so the same typed text derives the same key on every keyboard and platform.
public enum PasswordText {
    public static let maxBytes = 4096
    public static func normalize(_ password: String) -> String { password.precomposedStringWithCompatibilityMapping }
    /// Compares UTF-8 bytes: Swift's `==` treats canonically equivalent strings (composed and decomposed forms) as equal.
    public static func differs(_ password: String) -> Bool { Array(normalize(password).utf8) != Array(password.utf8) }
}
/// Portable encrypted backup header (the whole header is authenticated as AAD).
///
///     QVAULT01: magic 8 | salt 16                                   (Argon2id 3 passes, 64 MiB)
///     QVAULT02: magic 8 | u32be memKiB | u32be passes | salt 16
enum BackupFormat {
    static let magicV1 = Data("QVAULT01".utf8), magicV2 = Data("QVAULT02".utf8)
    static let v1Header = 24, v2Header = 32
    /// A header cannot pick weaker or absurdly expensive parameters than these.
    static let memKiBRange = 64 * 1024...1024 * 1024, passesRange = 3...10
    struct Header { let version: Int; let profile: KdfProfile; let salt: Data; let size: Int }
    private static func be32(_ value: Int) -> Data { Data([UInt8(value >> 24 & 255), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)]) }
    private static func u32(_ data: Data, _ offset: Int) -> Int { data.dropFirst(offset).prefix(4).reduce(0) { $0 << 8 | Int($1) } }
    /// `QVAULT` followed by two digits above the versions this build reads: a backup from a newer PassVault.
    static func isNewer(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(8))
        guard bytes.count == 8, Array(bytes[0..<6]) == Array("QVAULT".utf8), bytes[6] >= 0x30, bytes[6] <= 0x39, bytes[7] >= 0x30, bytes[7] <= 0x39 else { return false }
        return Int(bytes[6] - 0x30) * 10 + Int(bytes[7] - 0x30) > 2
    }
    static func header(profile: KdfProfile, salt: Data) -> Data { magicV2 + be32(profile.memKiB) + be32(Int(profile.opsLimit)) + salt }
    static func parse(_ data: Data) throws -> Header {
        if isNewer(data) { throw VaultError.newerBackup }
        let unsupported = VaultError.invalid("Unsupported or oversized encrypted backup.")
        guard data.count >= v1Header else { throw unsupported }
        let magic = Data(data.prefix(8))
        if magic == magicV1 { return Header(version: 1, profile: .vault, salt: Data(data.dropFirst(8).prefix(16)), size: v1Header) }
        guard magic == magicV2, data.count >= v2Header else { throw unsupported }
        let mem = u32(data, 8), passes = u32(data, 12)
        guard memKiBRange.contains(mem), passesRange.contains(passes) else { throw VaultError.invalid("Unsupported encrypted backup settings.") }
        return Header(version: 2, profile: KdfProfile(opsLimit: UInt64(passes), memKiB: mem), salt: Data(data.dropFirst(16).prefix(16)), size: v2Header)
    }
}
public enum VaultCrypto {
    static let initialized: Bool = sodium_init() >= 0
    public static func random(_ count: Int) -> Data {
        precondition(initialized && count > 0)
        var bytes = [UInt8](repeating: 0, count: count)
        randombytes_buf(&bytes, count)
        return Data(bytes)
    }
    /// `legacyEncoding` keys from the text exactly as typed, only to open data made before passwords were normalized.
    public static func passwordKey(_ password: String, salt: Data, profile: KdfProfile = .vault, legacyEncoding: Bool = false) throws -> Data {
        let text = legacyEncoding ? password : PasswordText.normalize(password)
        guard initialized, salt.count == 16, text.utf8.count <= PasswordText.maxBytes else { throw VaultError.invalid("Invalid password or salt.") }
        var key = [UInt8](repeating: 0, count: 32)
        defer { sodium_memzero(&key, key.count) }
        let result = text.withCString { pointer in
            crypto_pwhash(&key, 32, pointer, UInt64(text.utf8.count), Array(salt), profile.opsLimit, profile.memBytes, crypto_pwhash_ALG_ARGON2ID13)
        }
        guard result == 0 else { throw VaultError.invalid("Not enough memory to derive the vault key.") }
        return Data(key)
    }
    public static func deviceKey(_ passwordKey: Data, secret: Data) throws -> Data {
        guard passwordKey.count == 32, secret.count == 32 else { throw VaultError.invalid("Invalid device key.") }
        var output = [UInt8](repeating: 0, count: 32)
        let input = Data("PassVault/device-wrap/v1".utf8) + passwordKey
        guard crypto_generichash(&output, 32, Array(input), UInt64(input.count), Array(secret), 32) == 0 else { throw VaultError.invalid("Key derivation failed.") }
        defer { sodium_memzero(&output, output.count) }
        return Data(output)
    }
    // Encoded box: 24-byte nonce || ciphertext || 16-byte authentication tag.
    public static func seal(_ plaintext: Data, key: Data, aad: Data) throws -> Data {
        guard key.count == 32, plaintext.count <= Records.maxBytes else { throw VaultError.invalid("Invalid encryption input.") }
        let nonce = random(24)
        var output = [UInt8](repeating: 0, count: plaintext.count + 16)
        var length: UInt64 = 0
        guard crypto_aead_xchacha20poly1305_ietf_encrypt(&output, &length, Array(plaintext), UInt64(plaintext.count), Array(aad), UInt64(aad.count), nil, Array(nonce), Array(key)) == 0 else { throw VaultError.invalid("Encryption failed.") }
        return nonce + Data(output)
    }
    public static func open(_ box: Data, key: Data, aad: Data) throws -> Data {
        guard key.count == 32, box.count >= 40, box.count <= Records.maxBytes + 40 else { throw VaultError.invalid("Invalid encrypted data.") }
        let nonce = Array(box.prefix(24)), cipher = Array(box.dropFirst(24))
        var output = [UInt8](repeating: 0, count: max(1, cipher.count - 16))
        defer { sodium_memzero(&output, output.count) }
        var length: UInt64 = 0
        guard crypto_aead_xchacha20poly1305_ietf_decrypt(&output, &length, nil, cipher, UInt64(cipher.count), Array(aad), UInt64(aad.count), nonce, Array(key)) == 0 else { throw VaultError.authentication }
        return Data(output.prefix(Int(length)))
    }
    /// An X25519 key pair for `seal(_:to:)`: public 32 bytes, secret 32 bytes.
    static func boxKeyPair() throws -> (public: Data, secret: Data) {
        var publicKey = [UInt8](repeating: 0, count: 32), secretKey = [UInt8](repeating: 0, count: 32)
        defer { sodium_memzero(&secretKey, secretKey.count) }
        guard initialized, crypto_box_keypair(&publicKey, &secretKey) == 0 else { throw VaultError.invalid("Key generation failed.") }
        return (Data(publicKey), Data(secretKey))
    }
    /// A libsodium sealed box: only the holder of the secret key matching `publicKey` can open it, not the sender. 48 bytes longer than `plaintext`.
    static func seal(_ plaintext: Data, to publicKey: Data) throws -> Data {
        guard initialized, publicKey.count == 32, plaintext.count <= 1024 else { throw VaultError.invalid("Invalid encryption input.") }
        var output = [UInt8](repeating: 0, count: plaintext.count + 48)
        guard crypto_box_seal(&output, Array(plaintext), UInt64(plaintext.count), Array(publicKey)) == 0 else { throw VaultError.invalid("Encryption failed.") }
        return Data(output)
    }
    static func openSealed(_ box: Data, publicKey: Data, secretKey: Data) throws -> Data {
        guard initialized, publicKey.count == 32, secretKey.count == 32, (48...1024 + 48).contains(box.count) else { throw VaultError.invalid("Invalid encrypted data.") }
        var output = [UInt8](repeating: 0, count: max(1, box.count - 48))
        defer { sodium_memzero(&output, output.count) }
        guard crypto_box_seal_open(&output, Array(box), UInt64(box.count), Array(publicKey), Array(secretKey)) == 0 else { throw VaultError.authentication }
        return Data(output.prefix(box.count - 48))
    }
    public static let passwordRule = "At least 12 characters with uppercase and lowercase letters, a number and a symbol."
    public static func passwordProblem(_ typed: String) -> String? {
        let password = PasswordText.normalize(typed)
        if password.unicodeScalars.count < 12 { return "Use at least 12 characters." }
        if password.utf8.count > PasswordText.maxBytes { return "Use at most 4096 UTF-8 bytes." }
        if !password.contains(where: \.isUppercase) { return "Add an uppercase letter." }
        if !password.contains(where: \.isLowercase) { return "Add a lowercase letter." }
        if !password.contains(where: \.isDecimalDigit) { return "Add a number." }
        if !password.contains(where: { !$0.isLetter && !$0.isDecimalDigit && !$0.isWhitespace }) { return "Add a symbol." }
        return nil
    }
    public static func requireStrongPassword(_ password: String) throws {
        if let problem = passwordProblem(password) { throw VaultError.invalid(problem) }
    }
    /// `password` is the verified app password, which met the policy in force when it was set, so it is not re-checked here.
    public static func exportBackup(_ records: [VaultRecord], password: String) throws -> Data {
        guard !password.isEmpty, PasswordText.normalize(password).utf8.count <= PasswordText.maxBytes else { throw VaultError.invalid("Unsupported password.") }
        let profile = KdfProfile.backup
        let salt = random(16), header = BackupFormat.header(profile: profile, salt: salt)
        var key = try passwordKey(password, salt: salt, profile: profile)
        defer { key.resetBytes(in: 0..<key.count) }
        return try header + seal(Records.encode(records), key: key, aad: header)
    }
    public static func importBackup(_ data: Data, password: String) throws -> [VaultRecord] {
        let parsed = try BackupFormat.parse(data)
        guard data.count >= parsed.size + 40, data.count <= Records.maxBytes + parsed.size + 40 else { throw VaultError.invalid("Unsupported or oversized encrypted backup.") }
        let header = Data(data.prefix(parsed.size)), box = Data(data.dropFirst(parsed.size))
        // QVAULT01 files were keyed from the password exactly as typed; try that too when normalization would change it.
        for legacy in parsed.version == 1 && PasswordText.differs(password) ? [false, true] : [false] {
            var key = try passwordKey(password, salt: parsed.salt, profile: parsed.profile, legacyEncoding: legacy)
            defer { key.resetBytes(in: 0..<key.count) }
            do {
                var plaintext = try open(box, key: key, aad: header)
                defer { plaintext.resetBytes(in: 0..<plaintext.count) }
                return try Records.decode(plaintext)
            } catch VaultError.authentication { continue }
        }
        throw VaultError.authentication
    }
    public static func generatePassword(_ options: GeneratorOptions = GeneratorOptions()) throws -> String {
        let sets = options.sets
        guard !sets.isEmpty else { throw VaultError.invalid("Choose at least one character type.") }
        guard (GeneratorOptions.minLength...GeneratorOptions.maxLength).contains(options.length), options.length >= sets.count else { throw VaultError.invalid("Choose \(GeneratorOptions.minLength)–\(GeneratorOptions.maxLength) characters.") }
        let alphabet = Array(sets.joined())
        while true {
            let chars = (0..<options.length).map { _ in alphabet[Int(randombytes_uniform(UInt32(alphabet.count)))] }
            if sets.allSatisfy({ set in chars.contains { set.contains($0) } }) { return String(chars) }
        }
    }
}

/// What the password generator may use; the same defaults and limits as Android's `GeneratorOptions`.
public struct GeneratorOptions: Equatable, Sendable {
    public static let minLength = 6, maxLength = 64
    public var length = 10, letters = true, numbers = true, symbols = true
    public init(length: Int = 10, letters: Bool = true, numbers: Bool = true, symbols: Bool = true) { self.length = length; self.letters = letters; self.numbers = numbers; self.symbols = symbols }
    // Look-alike characters (O/0, l/1/I) are left out.
    var sets: [String] {
        (letters ? ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnopqrstuvwxyz"] : []) + (numbers ? ["23456789"] : []) + (symbols ? ["!@#$%^&*()-_=+[]{}:,.?"] : [])
    }
}
