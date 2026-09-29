import Foundation
import Clibsodium

public enum VaultCrypto {
    public static let magic = Data("QVAULT01".utf8)
    static let initialized: Bool = sodium_init() >= 0
    public static func random(_ count: Int) -> Data {
        precondition(initialized && count > 0)
        var bytes = [UInt8](repeating: 0, count: count)
        randombytes_buf(&bytes, count)
        return Data(bytes)
    }
    public static func passwordKey(_ password: String, salt: Data) throws -> Data {
        guard initialized, salt.count == 16, password.utf8.count <= 4096 else { throw VaultError.invalid("Invalid password or salt.") }
        var key = [UInt8](repeating: 0, count: 32)
        defer { sodium_memzero(&key, key.count) }
        let result = password.withCString { pointer in
            crypto_pwhash(&key, 32, pointer, UInt64(password.utf8.count), Array(salt), 3, 64 * 1024 * 1024, crypto_pwhash_ALG_ARGON2ID13)
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
    public static let passwordRule = "At least 12 characters with uppercase and lowercase letters, a number and a symbol."
    public static func passwordProblem(_ password: String) -> String? {
        if password.count < 12 { return "Use at least 12 characters." }
        if password.utf8.count > 4096 { return "Use at most 4096 UTF-8 bytes." }
        if !password.contains(where: \.isUppercase) { return "Add an uppercase letter." }
        if !password.contains(where: \.isLowercase) { return "Add a lowercase letter." }
        if !password.contains(where: \.isNumber) { return "Add a number." }
        if !password.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) { return "Add a symbol." }
        return nil
    }
    public static func requireStrongPassword(_ password: String) throws {
        if let problem = passwordProblem(password) { throw VaultError.invalid(problem) }
    }
    public static func exportBackup(_ records: [VaultRecord], password: String) throws -> Data {
        try requireStrongPassword(password)
        let salt = random(16), header = magic + salt
        var key = try passwordKey(password, salt: salt)
        defer { key.resetBytes(in: 0..<key.count) }
        return try header + seal(Records.encode(records), key: key, aad: header)
    }
    public static func importBackup(_ data: Data, password: String) throws -> [VaultRecord] {
        guard data.count >= 64, data.count <= Records.maxBytes + 64, data.prefix(8) == magic else { throw VaultError.invalid("Unsupported or oversized encrypted backup.") }
        let header = Data(data.prefix(24))
        var key = try passwordKey(password, salt: Data(header.suffix(16)))
        defer { key.resetBytes(in: 0..<key.count) }
        var plaintext = try open(Data(data.dropFirst(24)), key: key, aad: header)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        return try Records.decode(plaintext)
    }
    public static func generatePassword(length: Int = 24, symbols: Bool = true) throws -> String {
        guard (12...128).contains(length) else { throw VaultError.invalid("Choose 12–128 characters.") }
        let sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnopqrstuvwxyz", "23456789"] + (symbols ? ["!@#$%^&*()-_=+[]{}:,.?"] : [])
        let alphabet = Array(sets.joined())
        while true {
            let chars = (0..<length).map { _ in alphabet[Int(randombytes_uniform(UInt32(alphabet.count)))] }
            if sets.allSatisfy({ set in chars.contains { set.contains($0) } }) { return String(chars) }
        }
    }
}
