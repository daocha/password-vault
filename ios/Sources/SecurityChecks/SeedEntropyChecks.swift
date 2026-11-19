import Foundation
import CryptoKit
import VaultCore

/// Seed-phrase randomness: the official BIP-39 vectors, the mixing of two sources, and the checks that refuse a bad source.
/// Mirrors Android's SeedEntropyTest; the golden values were computed with an independent Python implementation of `SeedEntropy.mix`.
func seedEntropyChecks() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized
    func hex(_ text: Substring) -> [UInt8] { stride(from: 0, to: text.count, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! } }
    func ramp(_ start: Int) -> [UInt8] { (0..<32).map { UInt8((start + $0) & 255) } }
    func fixed(_ name: String, _ block: [UInt8]) -> SeedEntropy.Source { SeedEntropy.Source(name: name) { $0 = block } }
    func counter(_ name: String) -> SeedEntropy.Source {
        var n = 0
        return SeedEntropy.Source(name: name) { block in
            block = Array(SHA256.hash(data: Data("\(name)/\(n)".utf8))); n += 1
        }
    }
    func failure(_ action: () throws -> Void) -> String? {
        do { try action() } catch let error as EntropyFailure { return error.detail } catch { return nil }
        return nil
    }

    // Every English vector from the BIP-39 reference implementation (fixtures/bip39).
    let lines = try String(contentsOf: root.appendingPathComponent("fixtures/bip39/english-vectors.tsv"), encoding: .utf8).split(separator: "\n")
    try check(lines.count == 24, "all 24 official English BIP-39 vectors are present")
    for line in lines {
        let parts = line.split(separator: "\t"), words = parts[1].split(separator: " ").map(String.init)
        try check(Bip39.fromEntropy(Data(hex(parts[0]))) == words, "official BIP-39 vector \(parts[0]) encodes")
        if Bip39.wordCounts.contains(words.count) { try check(Bip39.problem(words) == nil, "official BIP-39 vector \(parts[0]) validates") }
    }

    let a = ramp(0), b = ramp(32)
    try check(SeedEntropy.mix([a, b], length: 16) == hex("e7678c04c85de81e610c64fac144a5e0"), "seed mixing golden value (16 bytes), as Android")
    try check(SeedEntropy.mix([a, b], length: 32) == hex("653d67194e0768a9e0360df1834f516db9516ef8ba5cd3747bd88b22b898010a"), "seed mixing golden value (32 bytes), as Android")
    try check(Bip39.generate(12, sources: [fixed("a", a), fixed("b", b)]).joined(separator: " ") == "trash detect abuse mouse teach august loud milk width any city school", "12-word golden phrase, as Android")
    try check(Bip39.generate(24, sources: [fixed("a", a), fixed("b", b)]).joined(separator: " ") == "gown twenty shock orchard isolate female liar script various bounce stairs swarm never resist title entire square phrase wage bind clog equal aerobic eye", "24-word golden phrase, as Android")

    let base = SeedEntropy.mix([a, b], length: 32)
    for which in 0..<2 { for bit in 0..<256 {
        var blocks = [a, b]; blocks[which][bit / 8] ^= UInt8(1 << (bit % 8))
        guard SeedEntropy.mix(blocks, length: 32) != base else { throw VaultError.invalid("FAILED: source \(which) bit \(bit) does not change the mix") }
    } }
    checks += 1
    try check(SeedEntropy.mix([b, a], length: 32) != base, "source order changes the mix")
    try check(SeedEntropy.mix([Array((a + b)[0..<31]), Array((a + b)[31...])], length: 32) != base && SeedEntropy.mix([a + b], length: 32) != base, "block lengths are part of the mix")
    try check(SeedEntropy.mix([a, b], length: 16) != Array(base.prefix(16)), "output length is part of the mix")

    try check(SeedEntropy.healthy(a) && !SeedEntropy.healthy([UInt8](repeating: 0, count: 32)) && !SeedEntropy.healthy([UInt8](repeating: 255, count: 32)), "health check rejects constant blocks")
    try check(SeedEntropy.healthy((0..<32).map { $0 < SeedEntropy.maxRepeats - 1 ? 7 : UInt8(100 + $0) }), "seven repeats pass the health check")
    try check(!SeedEntropy.healthy((0..<32).map { $0 < SeedEntropy.maxRepeats ? 7 : UInt8(100 + $0) }), "eight repeats fail the health check")
    try check(!SeedEntropy.healthy((0..<32).map { $0 % 4 == 0 ? 0x55 : UInt8(100 + $0) }), "spread-out repeats fail the health check")
    try check(SeedEntropy.unmixed([a, b], Array(b.prefix(16))) && !SeedEntropy.unmixed([a, b], SeedEntropy.mix([a, b], length: 16)), "raw blocks are recognized")

    try check(failure { _ = try Bip39.generate(12, sources: [fixed("stuck", [UInt8](repeating: 0x41, count: 32)), counter("b")]) }?.contains("health") == true, "a stuck source is refused")
    try check(failure { _ = try Bip39.generate(12, sources: [counter("a"), SeedEntropy.Source(name: "broken") { _ in throw CocoaError(.fileReadUnknown) }]) }?.contains("broken") == true, "an unreadable source is refused")
    try check(failure { _ = try Bip39.generate(12, sources: [counter("a"), SeedEntropy.Source(name: "short") { $0 = [1, 2, 3] }]) }?.contains("3 bytes") == true, "a short block is refused")
    try check(failure { _ = try Bip39.generate(12, sources: [fixed("x", a), fixed("y", a)]) }?.contains("same block") == true, "two sources returning the same block are refused")
    let repeating = fixed("repeating", a)
    _ = try Bip39.generate(12, sources: [repeating, counter("b")])
    try check(failure { _ = try Bip39.generate(12, sources: [repeating, counter("c")]) }?.contains("previous block") == true, "a source that repeats its block is refused")
    try rejects("one source is not enough") { _ = try Bip39.generate(12, sources: [counter("only")]) }
    try rejects("15 words are not offered") { _ = try Bip39.generate(15, sources: [counter("a"), counter("b")]) }
    try check(EntropyFailure("detail").localizedDescription == SeedEntropy.failureMessage, "every randomness failure shows the same message")
    // The editor shows these through LocalizedStringKey, so each language needs both keys (Android's lint checks its own strings).
    let recommendation = "Recommended for a new wallet: a passphrase (the “25th word”) keeps the funds safe even if these words leak. Enter the same passphrase in your wallet app and write it down separately: without it, the funds can't be recovered."
    for language in ["en", "zh-Hans", "zh-Hant"] {
        let table = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("ios/PassVault/\(language).lproj/Localizable.strings")), format: nil) as! [String: String]
        try check(table[SeedEntropy.failureMessage] != nil && table[recommendation] != nil, "\(language) translates the randomness failure and the passphrase recommendation")
    }

    try check(SeedEntropy.sodiumSource().read().count == SeedEntropy.blockSize && SeedEntropy.secRandomSource().read().count == SeedEntropy.blockSize, "system sources read")
    try check(failure { _ = try SeedEntropy.sodiumSource(expected: "internal").read() }?.contains("sysrandom") == true, "libsodium must use its sysrandom generator")
    try check(SeedEntropy.system.map(\.name) == ["libsodium", "SecRandomCopyBytes"], "phrases mix libsodium and the Security framework")

    // A grossly broken generator (stuck bits, a short cycle, a counter) shows up as unbalanced bits or words. The bounds are 6 (each of
    // 128 bits) and 8 (chi-square) standard deviations, so a working generator fails less than once in a million runs.
    let wordlist = try String(contentsOf: root.appendingPathComponent("ios/Sources/VaultCore/Resources/bip39-english.txt"), encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    let position = Dictionary(uniqueKeysWithValues: wordlist.enumerated().map { ($0.element, $0.offset) })
    try check(wordlist.count == 2048, "word list read for the uniformity check")
    let runs = 2000
    var ones = [Int](repeating: 0, count: 128), wordCounts = [String: Int](), seen = Set<String>()
    for _ in 0..<runs {
        let words = try Bip39.generate(12)
        try check(Bip39.problem(words) == nil && seen.insert(words.joined(separator: " ")).inserted, "generated phrase is valid and new")
        checks -= 1
        for word in words { wordCounts[word, default: 0] += 1 }
        // The first 128 of the 132 bits the 12 words carry are the entropy; the last 4 are the checksum.
        let bits = words.flatMap { word in (0..<11).reversed().map { (position[word]! >> $0) & 1 == 1 } }
        for bit in 0..<128 where bits[bit] { ones[bit] += 1 }
    }
    checks += 1
    let sigma = (Double(runs) * 0.25).squareRoot()
    try check(ones.allSatisfy { abs(Double($0) - Double(runs) / 2) <= 6 * sigma }, "every entropy bit is balanced")
    let expected = Double(runs * 12) / 2048, chiSquare = wordlist.reduce(0.0) { sum, word in
        let observed = Double(wordCounts[word] ?? 0); return sum + (observed - expected) * (observed - expected) / expected
    }
    try check(abs(chiSquare - 2047) <= 8 * (2.0 * 2047).squareRoot(), "words are spread evenly (chi-square \(chiSquare))")

    // Only libsodium and SecRandomCopyBytes may supply randomness: no generator that is not cryptographic, and nothing that could
    // replace libsodium's. Coldcard's 2021 regression routed seeds to such a generator without any test noticing.
    let banned = [
        // The C library's generators: rand(), random() and the *rand48 family take no argument; the seeding ones take one.
        // (VaultCrypto.random(n), which is libsodium, takes a count and is not matched.)
        #"\barc4random"#, #"(?<![.\w])(rand|random|drand48|lrand48|mrand48)\s*\(\s*\)"#,
        #"(?<![.\w])(srand|srandom|srand48|seed48|erand48|nrand48|jrand48)\s*\("#,
        #"SystemRandomNumberGenerator"#, #"\.random\(in:"#, #"\bBool\.random\("#, #"\.randomElement\("#, #"\.shuffled\("#, #"\.shuffle\("#,
        #"\bGK(ARC4|Mersenne|LinearCongruential|Random)"#, #"randombytes_set_implementation"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    var hits = [String](), scanned = 0
    for folder in ["ios/Sources/VaultCore", "ios/PassVault", "ios/AutoFill"] {
        let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            scanned += 1
            // Comments may name these generators (to explain why they are not used); only code counts.
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").map { line in
                line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
            }.joined(separator: "\n")
            let text = code, range = NSRange(text.startIndex..., in: text)
            for pattern in banned where pattern.firstMatch(in: text, range: range) != nil { hits.append("\(file.lastPathComponent): \(pattern.pattern)") }
        }
    }
    try check(scanned > 40, "app sources found for the randomness scan")
    try check(hits.isEmpty, "app code uses no weak randomness: \(hits)")
}
