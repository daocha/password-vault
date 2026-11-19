import Foundation
import CryptoKit
import Clibsodium

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
    /// Word to its position in the list; empty when the list is missing or corrupted (callers check `wordlist` first).
    private static let wordIndex: [String: Int] = (try? wordlist.get()).map { Dictionary(uniqueKeysWithValues: $0.enumerated().map { ($0.element, $0.offset) }) } ?? [:]
    private static let generationLock = NSLock()
    static func checkedWordlist(_ data: Data) throws -> [String] {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda",
              let text = String(data: data, encoding: .utf8) else { throw VaultError.invalid("BIP-39 wordlist is corrupted.") }
        let words = text.split(whereSeparator: \.isNewline).map(String.init)
        guard words.count == 2048 else { throw VaultError.invalid("BIP-39 wordlist is corrupted.") }
        return words
    }
    public static func split(_ text: String) -> [String] {
        // Java's default \s separates ASCII whitespace; keep nonbreaking spaces inside a word,
        // so pasted invalid phrases receive the same validation result on both platforms.
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .components(separatedBy: CharacterSet(charactersIn: " \t\n\r\u{000B}\u{000C}")).filter { !$0.isEmpty }
    }
    public static func suggestions(_ prefix: String, limit: Int = 8) -> [String] {
        guard !prefix.isEmpty, limit > 0, let words = try? wordlist.get() else { return [] }
        return Array(words.filter { $0.hasPrefix(prefix) }.prefix(limit))
    }
    public static func unknownWords(_ phrase: [String]) -> [String] {
        guard let words = try? wordlist.get() else { return [] }
        let known = Set(words)
        return phrase.enumerated().filter { !known.contains($0.element) }.map { "#\($0.offset + 1) “\($0.element)”" }
    }
    /// A new phrase from `SeedEntropy.system`. Throws `EntropyFailure` rather than return a phrase whose randomness failed a check.
    public static func generate(_ count: Int) throws -> [String] { try generate(count, sources: SeedEntropy.system) }

    /// A phrase from the SHA-256 mix of one block from each of `sources` (see `SeedEntropy.mix`). Before the phrase is returned, the
    /// blocks must differ from each other, the entropy must differ from every raw block, and the phrase must decode back to the entropy
    /// with a valid checksum. The buffers this code fills with entropy are wiped whether or not a check fails (CryptoKit's hash state
    /// and the returned words cannot be).
    public static func generate(_ count: Int, sources: [SeedEntropy.Source]) throws -> [String] {
        try generate(count, sources: sources, mix: SeedEntropy.mix(_:length:))
    }

    /// `mix` is replaced only by tests, to show that a faulty mixer is caught.
    static func generate(_ count: Int, sources: [SeedEntropy.Source], mix: ([[UInt8]], Int) -> [UInt8]) throws -> [String] {
        guard wordCounts.contains(count) else { throw VaultError.invalid("12 or 24 words") }
        guard sources.count >= 2 else { throw VaultError.invalid("A seed phrase mixes at least two random sources.") }
        generationLock.lock(); defer { generationLock.unlock() }
        var blocks = [[UInt8]]()
        defer { for index in blocks.indices { SeedEntropy.wipe(&blocks[index]) } }
        for source in sources { blocks.append(try source.read()) }
        for i in blocks.indices { for j in blocks.indices where j > i && blocks[i] == blocks[j] {
            throw EntropyFailure("\(sources[i].name) and \(sources[j].name) returned the same block.")
        } }
        var entropy = mix(blocks, count / 3 * 4)
        defer { SeedEntropy.wipe(&entropy) }
        if SeedEntropy.unmixed(blocks, entropy) { throw EntropyFailure("A random source reached the phrase without being mixed.") }
        var data = Data(entropy)
        defer { data.resetBytes(in: 0..<data.count) }
        let words = try fromEntropy(data)
        guard encodes(words, entropy) else { throw EntropyFailure("The new phrase does not decode to its entropy.") }
        return words
    }

    /// True when `words` is a valid phrase that decodes to exactly `entropy`.
    static func encodes(_ words: [String], _ entropy: [UInt8]) -> Bool {
        guard var decoded = toEntropy(words) else { return false }
        defer { SeedEntropy.wipe(&decoded) }
        return decoded == entropy && problem(words) == nil
    }

    /// The entropy a phrase of 12, 15, 18, 21 or 24 known words encodes, without checking its checksum; nil for any other phrase.
    /// Built straight into the returned array (the caller wipes it), with no bit list left behind.
    static func toEntropy(_ phrase: [String]) -> [UInt8]? {
        guard (12...24).contains(phrase.count), phrase.count % 3 == 0 else { return nil }
        let entropyBits = phrase.count * 11 * 32 / 33
        var entropy = [UInt8](repeating: 0, count: entropyBits / 8)
        var bit = 0
        for word in phrase {
            guard let value = wordIndex[word] else { SeedEntropy.wipe(&entropy); return nil }
            for shift in stride(from: 10, through: 0, by: -1) {
                if bit < entropyBits && (value >> shift) & 1 == 1 { entropy[bit / 8] |= UInt8(0x80 >> (bit % 8)) }
                bit += 1
            }
        }
        return entropy
    }

    public static func fromEntropy(_ entropy: Data) throws -> [String] {
        guard [16, 20, 24, 28, 32].contains(entropy.count) else { throw VaultError.invalid("Invalid BIP-39 entropy length.") }
        let words = try wordlist.get(), entropyBits = entropy.count * 8
        var bytes = Array(entropy), hash = Array(SHA256.hash(data: entropy))
        defer { SeedEntropy.wipe(&bytes); SeedEntropy.wipe(&hash) }
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
            _ = try wordlist.get()
            guard var entropy = toEntropy(phrase) else { return "Not a valid BIP-39 phrase" }
            defer { SeedEntropy.wipe(&entropy) }
            var data = Data(entropy)
            defer { data.resetBytes(in: 0..<data.count) }
            // Every word but the last is fixed by the entropy alone, so the last word decides whether the checksum matches.
            return try fromEntropy(data).last == phrase.last ? nil : "Checksum mismatch — check the words and their order."
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
        result.favorite = favorite; result.type = "seed"; result.updatedAt = VaultTimestamp.format()
        let firstNote = fields.first { $0.kind == .note }?.id
        // Reuse the existing field (same id, history and label) where there is one, so an unchanged value stays the same
        // field and a save that merges onto newer changes (applyingEdits) can tell what this edit really changed.
        func field(_ existing: VaultField?, kind: FieldKind, label: String, value: String) -> VaultField {
            guard var field = existing else { return .init(kind: kind, label: label, value: value) }
            if field.value != value { field.value = value }
            return field
        }
        let secretLabel = privateKey == nil ? seedPhraseLabel : privateKeyLabel
        result.fields = [field(fields.first { $0.label == secretLabel }, kind: .password, label: secretLabel,
                               value: privateKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? words.joined(separator: " "))]
        if privateKey == nil && !passphrase.isEmpty { result.fields.append(field(fields.first { $0.label == seedPassphraseLabel }, kind: .password, label: seedPassphraseLabel, value: passphrase)) }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.fields.append(field(fields.first { $0.id == firstNote }, kind: .note, label: "Notes", value: notes)) }
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
