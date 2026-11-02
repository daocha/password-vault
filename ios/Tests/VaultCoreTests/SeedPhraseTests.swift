import XCTest
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
    func testIncorrectChecksumAndUnsupportedWordCountsCannotBeSaved() throws {
        for count in [0, 12, 15, 18, 21, 24] {
            XCTAssertThrowsError(try VaultRecord().editingSeed(name: "Bad phrase", favorite: false, words: Array(repeating: "abandon", count: count), privateKey: nil, passphrase: "", notes: ""))
        }
    }
}
