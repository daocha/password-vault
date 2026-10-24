import Foundation
import VaultCore

/// Cards, secure notes and expiry reminders; mirrors Android's CardsTest.
func cardChecks() throws {
    try check(Cards.brand("4111 1111 1111 1111") == "Visa" && Cards.brand("2221000000000009") == "Mastercard" && Cards.brand("378282246310005") == "American Express"
              && Cards.brand("6011111111111117") == "Discover" && Cards.brand("3530111333300000") == "JCB" && Cards.brand("6200000000000005") == "UnionPay" && Cards.brand("9999") == nil, "card networks")
    try check(Cards.formatted("4111111111111111") == "4111 1111 1111 1111" && Cards.formatted("378282246310005") == "3782 822463 10005" && Cards.formatted("not a number") == "not a number", "card number grouping")
    for (text, year, month) in [("03/27", 2027, 3), ("3/2027", 2027, 3), ("2027-03", 2027, 3), ("0327", 2027, 3), (" 12 / 27 ", 2027, 12)] {
        try check(Cards.parseExpiry(text).map { $0.year == year && $0.month == month } == true, "card expiry \(text)")
    }
    try check(Cards.parseExpiry("13/27") == nil && Cards.parseExpiry("soon") == nil, "invalid card expiry")
    let today = DateComponents(year: 2026, month: 10, day: 25)
    func reminder(_ date: String) -> VaultRecord { var r = VaultRecord(); r.expires = date; return r }
    try check(VaultRecord().expiryState(today: today) == .none && reminder("2026-10-24").expiryState(today: today) == .expired && reminder("2026-10-25").expiryState(today: today) == .soon
              && reminder("2026-11-24").expiryState(today: today) == .soon && reminder("2026-11-25").expiryState(today: today) == .ok, "reminder expiry states")
    func card(_ expiry: String) -> VaultRecord {
        var r = VaultRecord.new(type: "card")
        r.fields = r.fields.map { var f = $0; if f.label == cardExpiryLabel { f.value = expiry }; if f.label == cardNumberLabel { f.value = "4111 1111 1111 1234" }; return f }
        return r
    }
    try check(card("10/26").expiryDate == DateComponents(year: 2026, month: 10, day: 31) && card("10/26").expiryState(today: today) == .soon
              && card("09/26").expiryState(today: today) == .expired && card("01/28").expiryState(today: today) == .ok, "card valid through end of expiry month")
    try check(card("01/28").cardSummary == "Visa •••• 1234" && VaultRecord.new(type: "card").cardSummary.isEmpty, "card summary")
    var login = VaultRecord(); login.name = "Site"
    var note = VaultRecord.new(type: "note"); note.name = "Wi-Fi"
    var withDate = card("01/28"); withDate.expires = "2027-01-31"
    let restored = try Records.decode(Records.encode([withDate, note, login]))
    try check(restored == [withDate, note, login] && !String(decoding: try Records.encode([login]), as: UTF8.self).contains("expires"), "card and note round trip; no empty expiry stored")
    try check(try VaultCSV.importRecords(VaultCSV.exportRecords(restored)).map(\.name) == ["Site"], "cards and notes stay out of CSV")
    try rejects("invalid expiry date") { _ = try Records.validate([reminder("next year")]) }
    try rejects("impossible expiry date") { _ = try Records.validate([reminder("2026-02-30")]) }
    let before = card("01/28")
    var after = before; after.fields = after.fields.map { var f = $0; if f.label == cardNumberLabel { f.value = "4000056655665556" }; return f }
    try check(after.recordingPasswordChanges(previous: before).fields.first { $0.label == cardNumberLabel }?.history?.map(\.value) == ["4111 1111 1111 1234"], "card number changes kept in history")
    // Android's JSON writes the same keys, so the two apps read each other's records.
    let android = #"[{"id":"c","name":"Bank","website":"","group":"","favorite":false,"updatedAt":"2026-10-25T00:00:00Z","fields":[],"legacy":{},"type":"card","expires":"2027-01-31"}]"#
    try check(try Records.decode(Data(android.utf8)).first.map { $0.isCard && $0.expires == "2027-01-31" } == true, "reads Android card JSON")
}
