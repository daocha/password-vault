import Foundation
import VaultCore
import Clibsodium

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

/// Backup reminders; mirrors Android's BackupReminderTest.
func backupChecks() throws {
    let now = Date(timeIntervalSince1970: 1_793_016_000), day = 86400.0
    func record(_ date: Date) -> VaultRecord { var r = VaultRecord(); r.updatedAt = ISO8601DateFormatter().string(from: date); return r }
    let records = [record(now - 40 * day), record(now - 2 * day)]
    try check(!BackupReminder.due([], lastBackup: nil, intervalDays: 30, snoozedUntil: nil, now: now), "no reminder for an empty vault")
    try check(BackupReminder.due(records, lastBackup: nil, intervalDays: 30, snoozedUntil: nil, now: now), "reminder before the first backup")
    try check(!BackupReminder.due(records, lastBackup: nil, intervalDays: 0, snoozedUntil: nil, now: now), "reminders off")
    try check(!BackupReminder.due(records, lastBackup: nil, intervalDays: 30, snoozedUntil: now + 60, now: now) && BackupReminder.due(records, lastBackup: nil, intervalDays: 30, snoozedUntil: now - 60, now: now), "snooze")
    try check(BackupReminder.due(records, lastBackup: now - 31 * day, intervalDays: 30, snoozedUntil: nil, now: now), "interval passed with changes")
    try check(!BackupReminder.due([record(now - 40 * day)], lastBackup: now - 31 * day, intervalDays: 30, snoozedUntil: nil, now: now), "interval passed without changes")
    try check(!BackupReminder.due(records, lastBackup: now - 10 * day, intervalDays: 30, snoozedUntil: nil, now: now) && BackupReminder.due(records, lastBackup: now - 8 * day, intervalDays: 7, snoozedUntil: nil, now: now), "interval length")
    var undated = VaultRecord(); undated.updatedAt = "not a date"
    let mixed = [record(now - 6 * day), record(now - day), undated]
    try check(BackupReminder.changedSince(mixed, lastBackup: now - 5 * day) == 2 && BackupReminder.changedSince(mixed, lastBackup: nil) == 3, "entries changed since the backup")
}

/// Argon2 against the RFC 9106 test vectors (§5) and libsodium's own Argon2id.
func argon2Checks() throws {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    let password = [UInt8](repeating: 1, count: 32), salt = [UInt8](repeating: 2, count: 16), secret = [UInt8](repeating: 3, count: 8), ad = [UInt8](repeating: 4, count: 12)
    for (variant, expected) in [(Argon2.Variant.d, "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb"),
                                (.i, "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8"),
                                (.id, "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")] {
        let tag = try Argon2.hash(password: password, salt: salt, secret: secret, associated: ad, iterations: 3, memoryKiB: 32, lanes: 4, variant: variant)
        try check(hex(tag) == expected, "Argon2\(variant) RFC 9106 vector")
    }
    // One lane, the only form libsodium offers: both must agree.
    let pw = Array("correct horse".utf8), s = [UInt8](repeating: 9, count: 16)
    var sodium = [UInt8](repeating: 0, count: 32)
    _ = crypto_pwhash(&sodium, 32, pw.map { CChar(bitPattern: $0) }, UInt64(pw.count), s, 3, 64 * 1024, crypto_pwhash_ALG_ARGON2ID13)
    try check(try Argon2.hash(password: pw, salt: s, iterations: 3, memoryKiB: 64, lanes: 1, variant: .id) == sodium, "Argon2id matches libsodium")
}

/// KeePass databases from kdbxweb (fixtures/kdbxweb) and other managers' exports; mirrors Android's KeePassTest and ImportersTest.
func importChecks() throws {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../fixtures/kdbxweb").standardized
    func file(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
    func value(_ r: VaultRecord, _ label: String) -> String { r.fields.first { $0.label == label }?.value ?? "" }
    func checkDemo(_ records: [VaultRecord], _ label: String) throws {
        guard let entry = records.first(where: { $0.name == "my entry" }) else { throw VaultError.invalid("FAILED: \(label) has no demo entry") }
        try check(entry.group == "General" && entry.website == "http://me.me" && entry.fields.prefix(3).map(\.value) == ["me", "mypass", "some notes"], "\(label) basic fields")
        try check(value(entry, "my field") == "my val" && value(entry, "my field protected") == "protected val" && entry.fields.first { $0.label == "my field protected" }?.secret == true, "\(label) custom fields")
        try check(entry.fields[1].history?.map(\.value) == ["pass"] && ["2015-08-29", "2015-08-30"].contains(entry.expires ?? ""), "\(label) history and expiry")
        try check(!records.contains { $0.group.contains("Recycle Bin") }, "\(label) skips the recycle bin")
    }
    for name in ["demo.kdbx", "Argon2.kdbx", "Argon2id.kdbx", "Argon2ChaCha.kdbx", "AesChaCha.kdbx"] {
        try check(Kdbx.isKdbx(try file(name)), "\(name) recognised")
        try checkDemo(try Kdbx.importRecords(file(name), password: "demo", keyFile: file("demo.key")), name)
    }
    try rejects("wrong KeePass password") { _ = try Kdbx.importRecords(file("demo.kdbx"), password: "wrong", keyFile: file("demo.key")) }
    try rejects("missing key file") { _ = try Kdbx.importRecords(file("Argon2.kdbx"), password: "demo", keyFile: nil) }
    try check(!(try Kdbx.importRecords(file("cyrillic.kdbx"), password: "пароль", keyFile: nil)).isEmpty && !(try Kdbx.importRecords(file("AesKdfKdbx4.kdbx"), password: "demo", keyFile: nil)).isEmpty
              && !(try Kdbx.importRecords(file("KDBX4.1.kdbx"), password: "test", keyFile: nil)).isEmpty, "other KeePass databases")
    _ = try Kdbx.importRecords(file("EmptyPass.kdbx"), password: "", keyFile: nil)
    for (db, key) in [("Key32", "Key32.key"), ("Key64", "Key64.key"), ("KeyWithBom", "KeyWithBom.key"), ("binkey", "binkey.key")] { _ = try Kdbx.importRecords(file("\(db).kdbx"), password: "test", keyFile: file(key)) }
    _ = try Kdbx.importRecords(file("KeyV2.kdbx"), password: nil, keyFile: file("KeyV2.keyx"))
    _ = try Kdbx.importTyped(file("NoPassWithKeyFile.kdbx"), password: "", keyFile: file("NoPassWithKeyFile.key"))
    checks += 1
    try checkDemo(try Importers.importPlain(file("demo.xml")), "KeePass XML export")
    try rejects("XML DOCTYPE") { _ = try MiniXml.parse(Data("<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]><KeePassFile>&e;</KeePassFile>".utf8)) }
    for bad in ["<a><b></a>", "<a>", "<a x=1/>", "text", "<a>&unknown;</a>", "<a/><b/>"] { try rejects("bad XML \(bad)") { _ = try MiniXml.parse(Data(bad.utf8)) } }
    let ok = try MiniXml.parse(Data("<?xml version=\"1.0\"?><!-- c --><a k='v &amp; w'><b>x &lt;y&gt; &#65;&#x42;</b><c><![CDATA[<raw>]]></c><d/></a>".utf8))
    try check(ok.attributes["k"] == "v & w" && ok.child("b")?.text == "x <y> AB" && ok.child("c")?.text == "<raw>" && ok.child("d") != nil, "XML reader")

    func csv(_ text: String) throws -> [VaultRecord] { try Importers.importPlain(Data(text.utf8)) }
    let totpUri = "otpauth://totp/Example:me?secret=JBSWY3DPEHPK3PXP&issuer=Example"
    let chrome = try csv("name,url,username,password,note\r\nexample.com,https://example.com/login,me@example.com,test-only-1,hello\r\n")
    try check(chrome.count == 1 && chrome[0].name == "example.com" && chrome[0].fields.prefix(3).map(\.value) == ["me@example.com", "test-only-1", "hello"], "Chrome CSV")
    let firefox = try csv("\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\",\"guid\",\"timeCreated\",\"timeLastUsed\",\"timePasswordChanged\"\n\"https://www.example.org\",\"me\",\"test-only-2\",,\"https://www.example.org\",\"{abc}\",\"1600000000000\",\"1600000000000\",\"1500000000000\"\n")
    try check(firefox[0].name == "example.org" && firefox[0].legacy["passwordSetDate"] == "1500000000" && firefox[0].legacy["guid"] == "{abc}", "Firefox CSV")
    let bw = try csv("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\nWork,1,login,Mail,n1,\"PIN: 1234\nRecovery: abc\",0,\"https://mail.example\nhttps://alt.example\",me,test-only-3,\(totpUri)\n,,note,Wi-Fi,the code is 42,,0,,,,\n")
    let mail = bw.first { $0.name == "Mail" && $0.isLogin }!
    try check(mail.favorite && mail.group == "Work" && mail.website == "https://mail.example" && value(mail, "PIN") == "1234" && value(mail, "Website") == "https://alt.example"
              && bw.contains { $0.isTotp } && bw.first { $0.name == "Wi-Fi" }?.isNote == true, "Bitwarden CSV")
    let one = try csv("Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nBank,https://bank.example,me,test-only-4,,true,false,\"Finance,Money\",n\n")
    try check(one.count == 1 && one[0].group == "Finance" && one[0].favorite, "1Password CSV")
    try check(try csv("Title,URL,Username,Password,Notes,OTPAuth\nShop,https://shop.example,me,test-only-5,,\(totpUri)\n").map(\.isTotp) == [false, true], "Safari CSV")
    let xc = try csv("\"Group\",\"Title\",\"Username\",\"Password\",\"URL\",\"Notes\",\"TOTP\",\"Icon\",\"Last Modified\",\"Created\"\n\"Root/Email\",\"Mail\",\"me\",\"test-only-6\",\"https://mail.example\",\"\",\"\",\"0\",\"2026-01-01T00:00:00Z\",\"2026-01-01T00:00:00Z\"\n\"Root\",\"Top\",\"me\",\"test-only-7\",\"\",\"\",\"\",\"0\",\"\",\"\"\n")
    try check(xc.map(\.group) == ["Email", ""], "KeePassXC CSV groups")
    let kp = try csv("\"Account\",\"Login Name\",\"Password\",\"Web Site\",\"Comments\"\n\"Forum\",\"me\",\"test-only-8\",\"https://forum.example\",\"c\"\n")
    try check(kp[0].name == "Forum" && kp[0].website == "https://forum.example" && value(kp[0], "Notes") == "c", "KeePass CSV")
    try check(try csv("url,username,password,extra,name,grouping,fav,customFields\r\nhttps://example.test,user,test-only,notes,Example,Work,1,opaque\r\n")[0].fields.last?.value == "opaque", "Password Keeper CSV keeps its importer")
    try rejects("unrecognised CSV") { _ = try csv("a,b,c\n1,2,3\n") }
    try check(value(try csv("name,url,username,password,totp\nGame,,me,test-only-11,steam://ABCDEF\n")[0], "One-time password") == "steam://ABCDEF", "non-TOTP one-time values kept")

    let json = """
    {"encrypted":false,"folders":[{"id":"f1","name":"Personal"}],"items":[
     {"id":"1","folderId":"f1","type":1,"name":"Mail","notes":"n","favorite":true,"fields":[{"name":"PIN","value":"1234","type":1},{"name":"Plan","value":"pro","type":0}],
      "login":{"uris":[{"match":null,"uri":"https://mail.example"}],"username":"me","password":"test-only-9","totp":"JBSWY3DPEHPK3PXP"},
      "passwordHistory":[{"lastUsedDate":"2025-01-01T00:00:00.000Z","password":"older"}],"revisionDate":"2026-01-01T00:00:00.000Z","deletedDate":null},
     {"id":"2","folderId":null,"type":3,"name":"Visa","notes":null,"favorite":false,"card":{"cardholderName":"Me","brand":"Visa","number":"4111111111111111","expMonth":"3","expYear":"2027","code":"123"}},
     {"id":"3","type":2,"name":"Door code","notes":"4321","secureNote":{"type":0}},
     {"id":"4","type":4,"name":"Me","identity":{"firstName":"Ann","lastName":"Lee","passportNumber":"X1","email":null}},
     {"id":"5","type":1,"name":"Gone","login":{"password":"x"},"deletedDate":"2026-02-01T00:00:00.000Z"}]}
    """
    let records = try Importers.importPlain(Data(json.utf8))
    let bwMail = records.first { $0.name == "Mail" && $0.isLogin }!
    try check(bwMail.group == "Personal" && bwMail.favorite && bwMail.fields[1].history?.map(\.value) == ["older"] && bwMail.fields.first { $0.label == "PIN" }?.secret == true
              && bwMail.fields.first { $0.label == "Plan" }?.secret == false && records.contains { $0.isTotp && $0.name == "Mail" }, "Bitwarden JSON login")
    let card = records.first(where: \.isCard)!
    try check(card.cardSummary == "Visa •••• 1111" && value(card, cardExpiryLabel) == "03/27" && value(card, cardCodeLabel) == "123", "Bitwarden JSON card")
    let identity = records.first { $0.name == "Me" }!
    try check(value(records.first { $0.name == "Door code" }!, "Notes") == "4321" && identity.isNote && value(identity, "First name") == "Ann"
              && identity.fields.first { $0.label == "Passport number" }?.secret == true && !records.contains { $0.name == "Gone" }, "Bitwarden JSON notes, identities and trash")
    try rejects("encrypted Bitwarden export") { _ = try Importers.importPlain(Data(#"{"encrypted":true,"passwordProtected":true,"data":"..."}"#.utf8)) }
}

/// 1Password `.1pux` (fixtures/exports/sample.1pux, shared with Android's ImportersTest).
func onePuxChecks() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../fixtures/exports/sample.1pux").standardized
    let records = try Importers.importPlain(Data(contentsOf: url))
    func value(_ r: VaultRecord, _ label: String) -> String { r.fields.first { $0.label == label }?.value ?? "" }
    let mail = records.first { $0.name == "Mail" && $0.isLogin }!
    try check(mail.group == "Work" && mail.favorite && mail.fields.prefix(3).map(\.value) == ["me", "test-only-10", "n"] && mail.fields[1].history?.map(\.value) == ["older"]
              && mail.fields.first { $0.label == "recovery" }?.secret == true && records.contains(where: \.isTotp), "1PUX login")
    let card = records.first(where: \.isCard)!
    try check(card.cardSummary == "Mastercard •••• 0004" && value(card, cardExpiryLabel) == "12/27" && value(card, cardCodeLabel) == "999" && value(card, "bank") == "Big Bank"
              && card.fields.filter { $0.value == "999" }.count == 1, "1PUX card")
    try check(!records.contains { $0.name == "Old" } && value(records.first { $0.name == "Note" }!, "Notes") == "keep me", "1PUX trashed and archived items")
}
