import XCTest
import CryptoKit
@testable import VaultCore

final class SeedPhraseTests: XCTestCase {
    func testWordlistTamperingFailsClosed() throws {
        XCTAssertThrowsError(try Bip39.checkedWordlist(Data("abandon\nability\n".utf8)))
    }
    func testSeedEditsPreserveForeignFieldsWithoutPuttingSecretsInPasswordSearchOrCSV() throws {
        let words = try Bip39.fromEntropy(Data(repeating: 0, count: 16))
        var record = VaultRecord()
        record.fields = [.init(kind: .password, label: "Foreign", value: "hidden extra"), .init(kind: .note, label: "Notes", value: "old notes")]
        let seed = try record.editingSeed(name: "Wallet", favorite: false, words: words, privateKey: nil, passphrase: " untouched ", notes: "notes")
        XCTAssertEqual(seed.fields.first { $0.label == "Foreign" }?.value, "hidden extra")
        XCTAssertFalse(seed.matches("abandon"))
        XCTAssertFalse(seed.matches("untouched"))
        XCTAssertFalse(VaultTab.passwords.contains(seed))
        XCTAssertFalse(try VaultCSV.exportRecords([seed]).contains("Wallet"))
        XCTAssertEqual(try Records.decode(Records.encode([seed])), [seed])
    }
    private func ramp(_ start: Int) -> [UInt8] { (0..<32).map { UInt8((start + $0) & 255) } }
    private func fixed(_ name: String, _ block: [UInt8]) -> SeedEntropy.Source { SeedEntropy.Source(name: name) { $0 = block } }
    private func counter(_ name: String) -> SeedEntropy.Source {
        var n = 0
        return SeedEntropy.Source(name: name) { block in block = Array(SHA256.hash(data: Data("\(name)/\(n)".utf8))); n += 1 }
    }

    func testEveryOfficialVectorDecodesBackToItsEntropy() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../fixtures/bip39/english-vectors.tsv").standardized
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 24)
        for line in lines {
            let parts = line.split(separator: "\t"), words = parts[1].split(separator: " ").map(String.init)
            let entropy = stride(from: 0, to: parts[0].count, by: 2).map { UInt8(parts[0].dropFirst($0).prefix(2), radix: 16)! }
            XCTAssertEqual(try Bip39.fromEntropy(Data(entropy)), words)
            XCTAssertEqual(Bip39.toEntropy(words), entropy)
            if Bip39.wordCounts.contains(words.count) { XCTAssertTrue(Bip39.encodes(words, entropy)) }
        }
    }

    func testToEntropyRejectsUnknownWordsAndOddLengths() {
        let about = Array(repeating: "abandon", count: 11) + ["about"]
        XCTAssertNil(Bip39.toEntropy(Array(about.dropLast()) + ["notaword"]))
        XCTAssertNil(Bip39.toEntropy(about + ["abandon"]))
        XCTAssertNil(Bip39.toEntropy(Array(about.prefix(9))))
        XCTAssertNil(Bip39.toEntropy([]))
        XCTAssertNil(Bip39.toEntropy(Array(repeating: "abandon", count: 27)))
        // Valid words with a wrong checksum still decode: the checksum is problem()'s job.
        XCTAssertEqual(Bip39.toEntropy(Array(repeating: "abandon", count: 12)), [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(Bip39.problem(Array(repeating: "abandon", count: 12)), "Checksum mismatch — check the words and their order.")
        XCTAssertFalse(Bip39.encodes(Array(repeating: "abandon", count: 12), [UInt8](repeating: 0, count: 16)))
        XCTAssertFalse(Bip39.encodes(about, [UInt8](repeating: 1, count: 16)))
        XCTAssertTrue(Bip39.encodes(about, [UInt8](repeating: 0, count: 16)))
    }

    func testGoldenPhrasesMatchAndroid() throws {
        XCTAssertEqual(try Bip39.generate(12, sources: [fixed("a", ramp(0)), fixed("b", ramp(32))]).joined(separator: " "),
                       "trash detect abuse mouse teach august loud milk width any city school")
        XCTAssertEqual(SeedEntropy.mix([ramp(0), ramp(32)], length: 16).map { String(format: "%02x", $0) }.joined(), "e7678c04c85de81e610c64fac144a5e0")
    }

    func testAMixerThatPassesASourceThroughIsCaught() {
        for bypass in [{ (blocks: [[UInt8]], n: Int) in Array(blocks[0].prefix(n)) }, { (blocks: [[UInt8]], n: Int) in Array(blocks[1].prefix(n)) }] {
            XCTAssertThrowsError(try Bip39.generate(12, sources: [counter("a"), counter("b")], mix: bypass)) { XCTAssertTrue($0 is EntropyFailure) }
        }
        XCTAssertNoThrow(try Bip39.generate(12, sources: [counter("a"), counter("b")], mix: SeedEntropy.mix(_:length:)))
    }

    func testBadSourcesAreRefused() throws {
        func detail(_ action: () throws -> Void) -> String? {
            do { try action() } catch let error as EntropyFailure { return error.detail } catch { return nil }
            return nil
        }
        XCTAssertEqual(detail { _ = try Bip39.generate(12, sources: [self.fixed("stuck", [UInt8](repeating: 0x41, count: 32)), self.counter("b")]) },
                       "stuck returned a block that fails the health check.")
        XCTAssertEqual(detail { _ = try Bip39.generate(12, sources: [self.fixed("x", self.ramp(0)), self.fixed("y", self.ramp(0))]) }, "x and y returned the same block.")
        let repeating = fixed("repeating", ramp(0))
        _ = try Bip39.generate(24, sources: [repeating, counter("b")])
        XCTAssertEqual(detail { _ = try Bip39.generate(24, sources: [repeating, self.counter("c")]) }, "repeating returned its previous block again.")
        XCTAssertEqual(detail { _ = try SeedEntropy.sodiumSource(expected: "internal").read() }, "libsodium uses sysrandom, not internal.")
        XCTAssertThrowsError(try Bip39.generate(12, sources: [counter("only")]))
        XCTAssertEqual(EntropyFailure("x").localizedDescription, SeedEntropy.failureMessage)
    }

    func testWipeOverwritesTheBufferInPlace() {
        var bytes = ramp(1)
        let address = bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        SeedEntropy.wipe(&bytes)
        XCTAssertEqual(bytes, [UInt8](repeating: 0, count: 32))
        XCTAssertEqual(bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }, address)
    }

    func testIncorrectChecksumAndUnsupportedWordCountsCannotBeSaved() throws {
        for count in [0, 12, 15, 18, 21, 24] {
            XCTAssertThrowsError(try VaultRecord().editingSeed(name: "Bad phrase", favorite: false, words: Array(repeating: "abandon", count: count), privateKey: nil, passphrase: "", notes: ""))
        }
    }
}
