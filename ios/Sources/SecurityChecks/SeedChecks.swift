import Foundation
import VaultCore

func seedChecks() throws {
    let vectors = [
        (String(repeating: "00", count: 16), String(repeating: "abandon ", count: 11) + "about"),
        (String(repeating: "ff", count: 16), String(repeating: "zoo ", count: 11) + "wrong"),
        (String(repeating: "00", count: 32), String(repeating: "abandon ", count: 23) + "art"),
        (String(repeating: "ff", count: 32), String(repeating: "zoo ", count: 23) + "vote"),
        ("9e885d952ad362caeb4efe34a8e91bd2", "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic")
    ]
    for (entropy, phrase) in vectors {
        let bytes = stride(from: 0, to: entropy.count, by: 2).map { i -> UInt8 in
            let a = entropy.index(entropy.startIndex, offsetBy: i), b = entropy.index(a, offsetBy: 2)
            return UInt8(entropy[a..<b], radix: 16)!
        }
        try check(Bip39.fromEntropy(Data(bytes)).joined(separator: " ") == phrase, "BIP-39 cross-platform golden vector")
        try check(Bip39.problem(Bip39.split(phrase)) == nil, "BIP-39 vector checksum")
    }
    try check(Bip39.problem(Array(repeating: "abandon", count: 12)) != nil, "invalid BIP-39 checksum")
    try check(Bip39.problem(Array(repeating: "unknownword", count: 12)) != nil, "unknown BIP-39 word")
    try check(Bip39.problem(Array(repeating: "abandon", count: 15)) != nil, "UI supports only 12 and 24 words, as Android")
    try check(Bip39.suggestions("ab") == ["abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract"], "BIP-39 suggestions match Android")
    try check(Bip39.split(" ABANDON\r\nabout ") == ["abandon", "about"] && Bip39.split("abandon\u{00A0}about").count == 1, "seed whitespace parsing matches Android")
    for count in Bip39.wordCounts {
        var generated = Set<[String]>()
        for _ in 0..<20 {
            let words = try Bip39.generate(count)
            try check(words.count == count && Bip39.problem(words) == nil, "generated seed validates")
            generated.insert(words)
        }
        try check(generated.count == 20, "generated phrases use fresh randomness")
    }
    let phrase = Bip39.split(vectors[0].1)
    var initial = VaultRecord(); initial.fields = [.init(kind: .password, label: "Custom secret", value: "preserve"), .init(kind: .note, label: "Notes", value: "old"), .init(kind: .note, label: "Extra notes", value: "preserve too")]
    let seed = try initial.editingSeed(name: " Wallet ", favorite: true, words: phrase, privateKey: nil, passphrase: " Exact passphrase ", notes: "new notes")
    try check(seed.type == "seed" && seed.name == "Wallet" && seed.favorite && seed.seedWords == phrase, "seed record matches Android fields")
    try check(seed.fields.contains { $0.label == seedPassphraseLabel && $0.value == " Exact passphrase " }, "seed passphrase kept exactly")
    try check(seed.fields.contains { $0.value == "preserve" } && seed.fields.contains { $0.value == "preserve too" }, "seed edits preserve unknown and extra note fields")
    var key = try seed.editingSeed(name: "Key", favorite: false, words: [], privateKey: "  " + String(repeating: "ab", count: 32) + "  ", passphrase: "omitted", notes: "")
    key.id = UUID().uuidString
    try check(key.privateKey == String(repeating: "ab", count: 32) && key.seedWords.isEmpty && !key.fields.contains { $0.label == seedPassphraseLabel }, "private-key mode drops phrase/passphrase as Android")
    try check(WalletPrivateKey.problem("short") != nil && WalletPrivateKey.problem("a key with spaces") != nil && WalletPrivateKey.problem(String(repeating: "k", count: 20)) == nil, "same light private key validation")
    try check(WalletPrivateKey.format(String(repeating: "ab", count: 32)) == "Hex · 32 bytes", "private key format guess")
    try check(VaultCSV.exportRecords([seed, key]).isEmpty || !VaultCSV.exportRecords([seed, key]).contains("abandon"), "seed phrases excluded from CSV")
    try check(!VaultCSV.exportRecords([seed, key]).contains(String(repeating: "ab", count: 32)), "private keys excluded from CSV")
    let roundtrip = try Records.decode(Records.encode([seed, key]))
    try check(roundtrip == [seed, key], "seed and private-key fields survive record encoding")
    try check(VaultTab.seed.contains(seed) && !VaultTab.passwords.contains(seed) && !VaultTab.totp.contains(seed), "seeds cannot leak into password or 2FA tabs")
    let backup = try VaultCrypto.exportBackup([seed, key], password: "A lengthy backup password 1!")
    try check(VaultCrypto.importBackup(backup, password: "A lengthy backup password 1!") == [seed, key], "encrypted backup preserves seed material")
}
