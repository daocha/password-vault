import Foundation
import VaultCore

func listParityChecks() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let records = try Records.decode(Data(contentsOf: root.appendingPathComponent("fixtures/list-parity/records.json")))
    try check(VaultListFilter.folders(in: records) == ["Personal", "Work"], "imported folders appear as filters")
    try check(VaultListFilter(folder: "Work").apply(to: records).map(\.name) == ["Work login", "Work card", "Work note"], "folder filter trims imported groups")
    try check(VaultListFilter(query: "alice", favorites: true, folder: "Work").apply(to: records).map(\.name) == ["Work login"], "folder, favorites and search intersect")
    try check(VaultListFilter(folder: "Work", kind: "card").apply(to: records).map(\.name) == ["Work card"], "card and folder filters intersect")
    try check(VaultListFilter(query: "never-search-this").apply(to: records).isEmpty, "folder filters never search secret fields")
    try check(VaultListFilter(tab: .seed, folder: "Work", kind: "card").apply(to: records).map(\.name) == ["Seed"], "password filters do not leak into other tabs")
    let expected = ["Gamma", "Alpha", "Beta", "Aardvark"]
    try check(VaultListFilter(tab: .totp).apply(to: records).map(\.name) == expected, "Android imported 2FA order is honored")
    let backup = try VaultCrypto.exportBackup(records, password: "A lengthy backup password 1!")
    let restored = try VaultCrypto.importBackup(backup, password: "A lengthy backup password 1!")
    try check(VaultListFilter(tab: .totp).apply(to: restored).map(\.name) == expected, "2FA order survives encrypted backup import")
    let codes = records.filter(\.isTotp).sorted(by: TotpOrder.less)
    let first = TotpOrder.apply(records, ordered: codes.map(\.id), now: "2026-01-01T00:00:00Z")
    let moved = TotpOrder.apply(first, ordered: [codes[0].id, codes[2].id, codes[1].id, codes[3].id], now: "2027-01-01T00:00:00Z")
    try check(moved.filter(\.isTotp).sorted(by: TotpOrder.less).map(\.name) == ["Gamma", "Beta", "Alpha", "Aardvark"], "reorder writes the Android positions")
    try check(moved.first { $0.name == "Gamma" }?.updatedAt == "2020-01-01T00:00:00Z", "unmoved code is not stamped")
    try check(moved.first { $0.name == "Alpha" }?.updatedAt == "2027-01-01T00:00:00Z", "moved code is stamped for backup reminders")
    try check(moved.filter { !$0.isTotp } == records.filter { !$0.isTotp }, "reorder leaves other record types untouched")
    try check(moved.allSatisfy { $0.legacy["vendor"] == "preserved" }, "reorder preserves unrelated metadata")
    try check(TotpOrder.apply(records, ordered: [], now: "unused") == records, "cancel/no-op leaves order untouched")
    var fallback = records.filter(\.isTotp)
    for index in fallback.indices { fallback[index].legacy.removeValue(forKey: TotpOrder.key) }
    try check(fallback.sorted(by: TotpOrder.less).map(\.name) == ["Beta", "Aardvark", "Alpha", "Gamma"], "unordered codes use Android favorite/name fallback")
    for value in ["oops", "2147483648", "-2147483649", " 1"] {
        fallback[0].legacy[TotpOrder.key] = value
        try check(TotpOrder.position(fallback[0]) == nil, "damaged/overflowed 2FA position is ignored")
    }
    let login = records.first { !$0.isTotp }!
    let mixed = TotpOrder.apply(records, ordered: [login.id, "missing", codes[0].id], now: "now")
    try check(mixed.first { $0.id == login.id } == login && TotpOrder.position(mixed.first { $0.id == codes[0].id }!) == 2, "non-code ids do not get positions")
}
