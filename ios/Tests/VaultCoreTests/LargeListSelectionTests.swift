import XCTest
@testable import VaultCore

final class LargeListSelectionTests: XCTestCase {
    private func records() -> [VaultRecord] {
        (0..<501).map { index in
            var record = VaultRecord()
            record.id = "entry-\(index)"; record.name = String(format: "Entry %03d", index)
            record.group = index < 25 ? "Small folder" : "Other"
            record.favorite = index % 10 == 0
            record.fields[0].value = "person-\(index)"
            record.fields[1].value = "never-search-this-secret"
            return record
        }
    }
    func testSelectAllAndDeselectAllAcross501Entries() {
        let records = records(), snapshot = VaultListSnapshot(records: records, filter: VaultListFilter())
        let one: Set<String> = [records[0].id]
        XCTAssertEqual(snapshot.visible.count, 501)
        XCTAssertEqual(snapshot.total, 501)
        let all = snapshot.togglingAll(one)
        XCTAssertEqual(all, Set(records.map(\.id)))
        XCTAssertEqual(snapshot.selection(from: all), all)
        XCTAssertTrue(snapshot.togglingAll(all).isEmpty)
        XCTAssertTrue(snapshot.visible.allSatisfy { all.contains($0.id) })
    }
    func testFilteringPrunesSelectionWithoutReselectingHiddenEntries() {
        let records = records(), all = Set(records.map(\.id))
        let folder = VaultListSnapshot(records: records, filter: VaultListFilter(folder: "Small folder"))
        let narrowed = folder.selection(from: all)
        XCTAssertEqual(narrowed, Set(records.prefix(25).map(\.id)))
        XCTAssertEqual(folder.total, 501)
        XCTAssertTrue(folder.togglingAll(narrowed).isEmpty)
        let full = VaultListSnapshot(records: records, filter: VaultListFilter())
        XCTAssertEqual(full.selection(from: narrowed), narrowed)
        XCTAssertEqual(full.togglingAll(narrowed).count, 501)
        let search = VaultListSnapshot(records: records, filter: VaultListFilter(query: "person-500"))
        XCTAssertEqual(search.togglingAll([]), [records[500].id])
        let none = VaultListSnapshot(records: records, filter: VaultListFilter(query: "never-search-this-secret"))
        XCTAssertTrue(none.togglingAll(all).isEmpty)
        XCTAssertTrue(none.selection(from: all).isEmpty)
    }
    func testPreparedRowsRemainStableWhenTheVaultChanges() {
        var records = records()
        let snapshot = VaultListSnapshot(records: records, filter: VaultListFilter())
        records.removeAll()
        XCTAssertEqual(snapshot.togglingAll([]).count, 501)
        XCTAssertEqual(snapshot.visible.count, 501)
        XCTAssertTrue(VaultListSnapshot(records: records, filter: VaultListFilter()).selection(from: snapshot.ids).isEmpty)
    }
}
