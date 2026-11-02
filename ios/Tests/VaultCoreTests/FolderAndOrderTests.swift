import XCTest
@testable import VaultCore

final class FolderAndOrderTests: XCTestCase {
    private func imported() throws -> [VaultRecord] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Records.decode(Data(contentsOf: root.appendingPathComponent("fixtures/list-parity/records.json")))
    }
    func testImportedFoldersAreAvailableAndCombineWithOtherFilters() throws {
        let records = try imported()
        XCTAssertEqual(VaultListFilter.folders(in: records), ["Personal", "Work"])
        XCTAssertEqual(VaultListFilter(folder: "Work").apply(to: records).map(\.name), ["Work login", "Work card", "Work note"])
        XCTAssertEqual(VaultListFilter(query: "alice", favorites: true, folder: "Work").apply(to: records).map(\.name), ["Work login"])
        XCTAssertEqual(VaultListFilter(folder: "Work", kind: "card").apply(to: records).map(\.name), ["Work card"])
        XCTAssertTrue(VaultListFilter(query: "never-search-this").apply(to: records).isEmpty)
        XCTAssertEqual(VaultListFilter(tab: .seed, folder: "Work", kind: "card").apply(to: records).map(\.name), ["Seed"])
        XCTAssertEqual(VaultListFilter.folders(in: records.filter { $0.group.trimmingCharacters(in: .whitespacesAndNewlines) != "Work" }), ["Personal"])
    }
    func testImportedAndroidOrderSurvivesRecordEncodingAndFallbacks() throws {
        let records = try Records.decode(Records.encode(imported()))
        XCTAssertEqual(VaultListFilter(tab: .totp).apply(to: records).map(\.name), ["Gamma", "Alpha", "Beta", "Aardvark"])
        var codes = records.filter(\.isTotp)
        for index in codes.indices { codes[index].legacy.removeValue(forKey: TotpOrder.key) }
        XCTAssertEqual(codes.sorted(by: TotpOrder.less).map(\.name), ["Beta", "Aardvark", "Alpha", "Gamma"])
        for value in ["oops", "2147483648", " 1"] {
            codes[0].legacy[TotpOrder.key] = value
            XCTAssertNil(TotpOrder.position(codes[0]))
        }
    }
    func testReorderingOnlyChangesMovedCodesAndPreservesOtherMetadata() throws {
        let records = try imported(), codes = records.filter(\.isTotp).sorted(by: TotpOrder.less)
        let first = TotpOrder.apply(records, ordered: codes.map(\.id), now: "2026-01-01T00:00:00Z")
        let moved = TotpOrder.apply(first, ordered: [codes[0].id, codes[2].id, codes[1].id, codes[3].id], now: "2027-01-01T00:00:00Z")
        XCTAssertEqual(moved.filter(\.isTotp).sorted(by: TotpOrder.less).map(\.name), ["Gamma", "Beta", "Alpha", "Aardvark"])
        XCTAssertEqual(moved.first { $0.name == "Gamma" }?.updatedAt, "2020-01-01T00:00:00Z")
        XCTAssertEqual(moved.first { $0.name == "Alpha" }?.updatedAt, "2027-01-01T00:00:00Z")
        XCTAssertEqual(moved.filter { !$0.isTotp }, records.filter { !$0.isTotp })
        XCTAssertTrue(moved.allSatisfy { $0.legacy["vendor"] == "preserved" })
        XCTAssertEqual(TotpOrder.apply(records, ordered: [], now: "unused"), records)
        let login = try XCTUnwrap(records.first { !$0.isTotp })
        let withNonCodes = TotpOrder.apply(records, ordered: [login.id, "not-in-vault", codes[0].id], now: "now")
        XCTAssertEqual(withNonCodes.first { $0.id == login.id }, login)
        XCTAssertEqual(TotpOrder.position(try XCTUnwrap(withNonCodes.first { $0.id == codes[0].id })), 2)
    }
}
