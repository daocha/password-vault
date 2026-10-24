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

/// Vault health; mirrors Android's VaultHealthTest, including the same strength vectors.
func healthChecks() throws {
    let strengthVectors: [(String, Int)] = [
        ("", 0), ("123456", 0), ("password", 0), ("Password123!", 0), ("P@ssw0rd", 0), ("!monkey", 0), ("qwertyuiop", 0), ("woaini1314", 0),
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0), ("abcdefgh", 0), ("Ab1!", 0), ("zebra", 0),
        ("correcthorse", 2), ("k#9Lq!2v", 2), ("k#9Lq!2vX@", 3), ("Tr0ub4dor&3", 3),
        ("correct horse battery staple", 4), ("x7#Qm2!vLp9@Zr4^", 4), ("密码安全很重要", 1), ("我的密码很长而且很安全哦", 3),
    ]
    for (password, expected) in strengthVectors { try check(PasswordStrength.score(password) == expected, "strength of vector \(expected)") }
    func login(_ name: String, _ password: String, website: String = "", updatedAt: String = ISO8601DateFormatter().string(from: Date()), history: [PasswordChange]? = nil) -> VaultRecord {
        var r = VaultRecord(); r.name = name; r.website = website; r.updatedAt = updatedAt
        r.fields = [.init(kind: .username, label: "Username", value: "me"), .init(kind: .password, label: "Password", value: password, history: history)]
        return r
    }
    let today = DateComponents(year: 2026, month: 10, day: 25), strong = "x7#Qm2!vLp9@Zr4^"
    let a = login("Mail", strong), b = login("Shop", strong), c = login("Forum", "123456")
    let old = login("Old site", "Kf8#pW2!zQ7mVx", updatedAt: "2024-01-01T00:00:00Z")
    let changed = login("Changed", "Hn5$tR9@kL2wQe", updatedAt: "2024-01-01T00:00:00Z", history: [PasswordChange(value: "before", changedAt: 1_780_272_000)])
    let github = login("GitHub", "Zp4!mQ8#rT2vWy", website: "https://github.com/login"), spotify = login("Spotify", "Yc3@nB7!kD5xLs")
    let spotifyCode = try TotpAccount(secret: Totp.decodeBase32("JBSWY3DPEHPK3PXP"), issuer: "Spotify", account: "me").record()
    var passport = VaultRecord.new(type: "note"); passport.name = "Passport"; passport.expires = "2026-11-01"
    var seed = VaultRecord(); seed.name = "Wallet"; seed.type = "seed"; seed.fields = [.init(kind: .password, label: "Seed phrase", value: "123456")]
    let report = VaultHealth.check([a, b, c, old, changed, github, spotify, spotifyCode, passport, seed], today: today)
    try check(report.reused.map { Set($0.map(\.record.name)) } == [["Mail", "Shop"]], "reused passwords")
    try check(report.weak.map(\.password.record.name) == ["Forum"], "weak passwords")
    try check(report.old.map(\.password.record.name) == ["Old site"], "old passwords")
    try check(report.expiring.map(\.name) == ["Passport"], "expiring records")
    try check(report.noTwoFactor.map(\.name) == ["GitHub"], "logins without 2FA")
    try check(report.checked == 7 && report.score == Int((100.0 * (7 - 3 - 0.5) / 7).rounded()), "health score")
    var twice = VaultRecord(); twice.fields = [.init(kind: .password, label: "Password", value: "Kf8#pW2!zQ7mVx"), .init(kind: .password, label: "PIN", value: "Kf8#pW2!zQ7mVx")]
    try check(VaultHealth.check([twice]).reused.isEmpty && VaultHealth.check([twice]).score == 100 && VaultHealth.check([]).score == nil, "one record twice is not reuse; empty vault has no score")
    var keeper = login("Keeper", "Kf8#pW2!zQ7mVx"); keeper.legacy = ["passwordSetDate": "1500000000"]
    try check(VaultHealth.passwordSetOn(CheckedPassword(record: keeper, field: keeper.fields[1])).map { $0.year == 2017 && $0.month == 7 } == true, "Password Keeper set date")
    try check(PasswordStrength.common.count > 250, "common password list loaded")
}
