import Foundation
import CryptoKit

public let seedPhraseLabel = "Seed phrase"
public let privateKeyLabel = "Private key"
public let seedPassphraseLabel = "BIP-39 passphrase"

/// English BIP-39 mnemonics. No wallet seed or address is derived here.
public enum Bip39 {
    public static let wordCounts = [12, 24]
    private static let wordlist: Result<[String], Error> = Result {
        guard let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt") else {
            throw VaultError.invalid("BIP-39 wordlist missing.")
        }
        return try checkedWordlist(Data(contentsOf: url))
    }
    static func checkedWordlist(_ data: Data) throws -> [String] {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda",
              let text = String(data: data, encoding: .utf8) else { throw VaultError.invalid("BIP-39 wordlist is corrupted.") }
        let words = text.split(whereSeparator: \.isNewline).map(String.init)
        guard words.count == 2048 else { throw VaultError.invalid("BIP-39 wordlist is corrupted.") }
        return words
    }
    public static func split(_ text: String) -> [String] { text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }
    public static func suggestions(_ prefix: String, limit: Int = 8) -> [String] {
        guard !prefix.isEmpty, limit > 0, let words = try? wordlist.get() else { return [] }
        return Array(words.filter { $0.hasPrefix(prefix) }.prefix(limit))
    }
    public static func unknownWords(_ phrase: [String]) -> [String] {
        guard let words = try? wordlist.get() else { return [] }
        let known = Set(words)
        return phrase.enumerated().filter { !known.contains($0.element) }.map { "#\($0.offset + 1) “\($0.element)”" }
    }
    public static func generate(_ count: Int) throws -> [String] {
        guard wordCounts.contains(count) else { throw VaultError.invalid("12 or 24 words") }
        var entropy = VaultCrypto.random(count / 3 * 4)
        defer { entropy.resetBytes(in: 0..<entropy.count) }
        return try fromEntropy(entropy)
    }
    public static func fromEntropy(_ entropy: Data) throws -> [String] {
        guard [16, 20, 24, 28, 32].contains(entropy.count) else { throw VaultError.invalid("Invalid BIP-39 entropy length.") }
        let words = try wordlist.get(), bytes = Array(entropy), hash = Array(SHA256.hash(data: entropy)), entropyBits = entropy.count * 8
        func bit(_ i: Int) -> Int {
            let offset = i < entropyBits ? i : i - entropyBits
            return Int((i < entropyBits ? bytes[offset / 8] : hash[offset / 8]) >> (7 - offset % 8) & 1)
        }
        return (0..<(entropyBits + entropyBits / 32) / 11).map { word in
            words[(0..<11).reduce(0) { $0 << 1 | bit(word * 11 + $1) }]
        }
    }
    public static func problem(_ phrase: [String]) -> String? {
        guard wordCounts.contains(phrase.count) else { return "12 or 24 words" }
        do {
            let words = try wordlist.get(), indices = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element, $0.offset) })
            guard phrase.allSatisfy({ indices[$0] != nil }) else { return "Not a valid BIP-39 phrase" }
            let bits = phrase.flatMap { word in (0..<11).reversed().map { (indices[word]! >> $0) & 1 } }
            var entropy = Data((0..<bits.count * 32 / 33 / 8).map { byte in
                UInt8((0..<8).reduce(0) { $0 << 1 | bits[byte * 8 + $1] })
            })
            defer { entropy.resetBytes(in: 0..<entropy.count) }
            return try fromEntropy(entropy).last == phrase.last ? nil : "Checksum mismatch — check the words and their order."
        } catch { return error.localizedDescription }
    }
}

/// Same light sanity checks as Android; unknown single-token key formats are preserved.
public enum WalletPrivateKey {
    public static func problem(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "Enter the private key." }
        if value.contains(where: \.isWhitespace) { return "A private key has no spaces or line breaks." }
        if value.utf16.count < 16 { return "Too short to be a private key." }
        return nil
    }
    public static func format(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: "^(0x)?[0-9a-fA-F]{64}$", options: .regularExpression) != nil { return "Hex · 32 bytes" }
        if value.range(of: "^[1-9A-HJ-NP-Za-km-z]{51,52}$", options: .regularExpression) != nil { return "WIF (Base58)" }
        return "Unrecognized format · saved as entered"
    }
}

extension VaultRecord {
    public var isSeed: Bool { type == "seed" }
    public var seedWords: [String] { Bip39.split(fields.first { $0.label == seedPhraseLabel }?.value ?? "") }
    public var privateKey: String? { fields.first { $0.label == privateKeyLabel }?.value }

    /// Keep unrecognized fields and all but the first notes field, as on Android.
    public func editingSeed(name: String, favorite: Bool, words: [String], privateKey: String?, passphrase: String, notes: String) throws -> VaultRecord {
        if let key = privateKey {
            if let problem = WalletPrivateKey.problem(key) { throw VaultError.invalid(problem) }
        } else if let problem = Bip39.problem(words) { throw VaultError.invalid(problem) }
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty else { throw VaultError.invalid("Wallet name") }
        result.favorite = favorite; result.type = "seed"; result.updatedAt = ISO8601DateFormatter().string(from: Date())
        result.fields = [.init(kind: .password, label: privateKey == nil ? seedPhraseLabel : privateKeyLabel,
                               value: privateKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? words.joined(separator: " "))]
        if privateKey == nil && !passphrase.isEmpty { result.fields.append(.init(kind: .password, label: seedPassphraseLabel, value: passphrase)) }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.fields.append(.init(kind: .note, label: "Notes", value: notes)) }
        let firstNote = fields.first { $0.kind == .note }?.id
        result.fields += fields.filter { ![seedPhraseLabel, privateKeyLabel, seedPassphraseLabel].contains($0.label) && $0.id != firstNote }
        return result
    }
}

public enum VaultTab: String, CaseIterable, Identifiable {
    case passwords, seed, totp
    public var id: String { rawValue }
    public var label: String {
        switch self { case .passwords: "Passwords"; case .seed: "Seed phrases"; case .totp: "2FA codes" }
    }
    public func contains(_ record: VaultRecord) -> Bool {
        switch self { case .passwords: !record.isSeed && !record.isTotp; case .seed: record.isSeed; case .totp: record.isTotp }
    }
}
