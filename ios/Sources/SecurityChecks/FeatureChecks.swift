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
    var firstSpotify = login("Spotify", strong, website: "https://spotify.com"), secondSpotify = login("Spotify", strong, website: "https://spotify.com")
    firstSpotify.fields[0].value = "me@example.com"; secondSpotify.fields[0].value = "other@example.com"
    let matchingCode = try TotpAccount(secret: Totp.decodeBase32("JBSWY3DPEHPK3PXP"), issuer: "Spotify", account: " ME@example.com ").record()
    try check(VaultHealth.check([firstSpotify, secondSpotify, matchingCode]).noTwoFactor.map(\.id) == [secondSpotify.id], "2FA covers only the matching account")
    let unnamedCode = try TotpAccount(secret: Totp.decodeBase32("JBSWY3DPEHPK3PXP"), issuer: "Spotify").record()
    try check(VaultHealth.check([firstSpotify, secondSpotify, unnamedCode]).noTwoFactor.count == 2, "2FA without an account does not cover every login")
    // Typed in steps: as one expression the literals made older Swift compilers give up type-checking it.
    let expectedRatio: Double = (7.0 - 3.0 - 0.5) / 7.0
    let expectedScore: Int = Int((100.0 * expectedRatio).rounded())
    try check(report.checked == 7 && report.score == expectedScore, "health score")
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
    try check(Expiry.imported(Date(timeIntervalSince1970: 1_793_016_000)).count == 10 && Expiry.imported(Date(timeIntervalSince1970: 253_402_400_000)).isEmpty,
              "imported dates outside four-digit years are dropped")
    let damagedTime = "<KeePassFile><Root><Group><Entry><Times><LastModificationTime>AAAAAAAAAIA=</LastModificationTime></Times><String><Key>Title</Key><Value>Mail</Value></String></Entry></Group></Root></KeePassFile>"
    try check(try Importers.importPlain(Data(damagedTime.utf8)).count == 1, "a damaged KDBX 4 time (near Int64.min) does not overflow")
    // Key settings too slow for a phone are refused before any work: AES-KDF rounds (KDBX 3.1 header field 6) and Argon2 passes ("I").
    func refusedAsTooCostly(_ data: Data, _ label: String) throws {
        do { _ = try Kdbx.importRecords(data, password: "demo", keyFile: file("demo.key")); throw VaultError.invalid("\(label) was accepted") }
        catch VaultError.invalid(let message) where message.contains("key settings") { checks += 1 }
    }
    func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    var demo = Array(try file("demo.kdbx")), pos = 12
    while demo[pos] != 6 { pos += 3 + Int(demo[pos + 1]) | Int(demo[pos + 2]) << 8 }
    demo.replaceSubrange(pos + 3..<pos + 11, with: le64(200_000_000))
    try refusedAsTooCostly(Data(demo), "200 million AES rounds")
    var argon = Array(try file("Argon2.kdbx")); let marker: [UInt8] = [5, 1, 0, 0, 0, UInt8(ascii: "I"), 8, 0, 0, 0]
    guard let at = (0...argon.count - marker.count).first(where: { Array(argon[$0..<$0 + marker.count]) == marker }) else { throw VaultError.invalid("no Argon2 passes entry") }
    argon.replaceSubrange(at + marker.count..<at + marker.count + 8, with: le64(1_000_000))
    try refusedAsTooCostly(Data(argon), "a million Argon2 passes")
    try checkDemo(try Importers.importPlain(file("demo.xml")), "KeePass XML export")
    let unsupportedOTP = """
    <KeePassFile><Root><Group><Entry>
    <String><Key>Title</Key><Value>Mail</Value></String>
    <String><Key>UserName</Key><Value>me</Value></String>
    <String><Key>TimeOtp-Secret-Base32</Key><Value>JBSWY3DPEHPK3PXP</Value></String>
    <String><Key>TimeOtp-Algorithm</Key><Value>HMAC-SHA3</Value></String>
    </Entry></Group></Root></KeePassFile>
    """
    let keptOTP = try Importers.importPlain(Data(unsupportedOTP.utf8))
    try check(keptOTP.count == 1 && value(keptOTP[0], "TimeOtp-Secret-Base32") == "JBSWY3DPEHPK3PXP"
              && keptOTP[0].fields.first { $0.label == "TimeOtp-Secret-Base32" }?.secret == true
              && value(keptOTP[0], "TimeOtp-Algorithm") == "HMAC-SHA3", "unsupported KeePass TOTP settings kept")
    let supportedOTP = unsupportedOTP.replacingOccurrences(of: "HMAC-SHA3", with: "HMAC-SHA256")
    let convertedOTP = try Importers.importPlain(Data(supportedOTP.utf8))
    try check(convertedOTP.count == 2 && convertedOTP.first(where: \.isTotp)?.totp?.algorithm == "SHA256"
              && convertedOTP.first(where: \.isLogin)?.fields.contains(where: { $0.label.hasPrefix("TimeOtp-") }) == false, "supported KeePass TOTP converted")
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
    let oldCard = #"{"encrypted":false,"items":[{"id":"9","type":3,"name":"Old card","card":{"number":"4111111111111111","expMonth":"12","expYear":"1999"}}]}"#
    try check(value(try Importers.importPlain(Data(oldCard.utf8)).first(where: \.isCard)!, cardExpiryLabel) == "12/1999", "a card year outside 2000-2099 keeps four digits")
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

/// Decoy vault: a second password opens a separate vault; neither can see or reset the other.
func decoyChecks() throws {
    let main = "A lengthy test passphrase 1!", decoyPassword = "Another decoy phrase 2?"
    let store = MemoryStorage(), engine = VaultEngine(storage: store)
    _ = try engine.create(password: main)
    var secret = VaultRecord(); secret.name = "Real bank"
    try engine.save([secret]); try engine.enableBiometrics(password: main)
    try check(!(try engine.hasDecoy()), "no decoy at first")
    try rejects("decoy equal to the app password") { try engine.createDecoy(password: main, decoyPassword: main) }
    try rejects("weak decoy password") { try engine.createDecoy(password: main, decoyPassword: "short") }
    try rejects("decoy needs the app password") { try engine.createDecoy(password: "Wrong passphrase 9!", decoyPassword: decoyPassword) }
    _ = try engine.unlock(password: main) // a failed password check locks the vault
    try engine.createDecoy(password: main, decoyPassword: decoyPassword)
    try check(try engine.hasDecoy() && store.blobs.count == 2, "decoy created with its own file")
    try rejects("second decoy") { try engine.createDecoy(password: main, decoyPassword: "Yet another phrase 3#") }
    engine.lock()

    try check(try engine.unlock(password: decoyPassword).isEmpty && engine.isDecoy(), "decoy password opens the empty decoy vault")
    try check(!(try engine.hasDecoy()), "the decoy vault cannot see that it is a decoy")
    var harmless = VaultRecord(); harmless.name = "Shopping"
    try engine.save([harmless])
    try rejects("decoy cannot enable biometrics") { try engine.enableBiometrics(password: decoyPassword) }
    try rejects("decoy cannot remove itself") { try engine.removeDecoy(password: decoyPassword) }
    try rejects("main password is not accepted inside the decoy vault") { _ = try engine.export(password: main, backupPassword: nil, csv: true) }
    try check(!(try engine.unlock(password: decoyPassword)).isEmpty && engine.isDecoy(), "decoy reopens after the failed check")
    let exported = try engine.export(password: decoyPassword, backupPassword: nil, csv: true)
    try check(String(decoding: exported, as: UTF8.self).contains("Shopping") && !String(decoding: exported, as: UTF8.self).contains("Real bank"), "decoy export holds only decoy entries")
    engine.lock()

    try check(try engine.unlock(password: main).map(\.name) == ["Real bank"] && !engine.isDecoy(), "main password still opens the real vault")
    engine.lock()
    try check(try engine.unlockBiometric().map(\.name) == ["Real bank"], "biometrics open the real vault")
    engine.lock()
    try check(try engine.unlock(password: decoyPassword).map(\.name) == ["Shopping"], "decoy entries were saved to the decoy file")
    engine.lock()

    // Failed guesses are not cleared by decoy sign-ins, only by the real password.
    for _ in 1...3 { try rejects("wrong password") { _ = try engine.unlock(password: "Wrong passphrase 9!") } }
    try check(try engine.remainingAttempts() == 7, "three failures counted")
    _ = try engine.unlock(password: decoyPassword); engine.lock()
    try check(try engine.remainingAttempts() == 7, "decoy sign-in leaves the failure count")
    _ = try engine.unlock(password: main)
    try check(try engine.remainingAttempts() == 10, "real password clears the failure count")

    // Changing the decoy's password from inside it keeps both vaults; the real one cannot take the decoy's password.
    try rejects("app password equal to the decoy's") { try engine.changePassword(current: main, new: decoyPassword) }
    engine.lock(); _ = try engine.unlock(password: decoyPassword)
    try rejects("decoy password equal to the app's") { try engine.changePassword(current: decoyPassword, new: main) }
    engine.lock(); _ = try engine.unlock(password: decoyPassword)
    try engine.changePassword(current: decoyPassword, new: "Fresh decoy phrase 4$"); engine.lock()
    try check(try engine.unlock(password: "Fresh decoy phrase 4$").map(\.name) == ["Shopping"], "decoy password changed"); engine.lock()
    try check(try engine.unlock(password: main).map(\.name) == ["Real bank"] && store.blobs.count == 2, "real vault untouched by the decoy's password change")

    try engine.removeDecoy(password: main)
    try check(!(try engine.hasDecoy()) && store.blobs.count == 1, "decoy removed with its file"); engine.lock()
    try rejects("removed decoy no longer opens") { _ = try engine.unlock(password: "Fresh decoy phrase 4$") }
    try decoyCounterChecks(); try decoyResetChecks()

    // Erasure after 10 failures destroys both vaults.
    let wiped = MemoryStorage(), e = VaultEngine(storage: wiped)
    _ = try e.create(password: main); try e.createDecoy(password: main, decoyPassword: decoyPassword); e.lock()
    for _ in 1...10 { try rejects("failure toward erasure") { _ = try e.unlock(password: "Wrong passphrase 9!") } }
    try check(wiped.blobs.isEmpty, "erasure removes the decoy vault too")
    try rejects("decoy after erasure") { _ = try VaultEngine(storage: wiped).unlock(password: decoyPassword) }
    // State written before decoys existed still reads.
    let legacy = MemoryStorage(); _ = try VaultEngine(storage: legacy).create(password: main)
    try check(!String(decoding: legacy.state!, as: UTF8.self).contains("decoy"), "no decoy key stored without a decoy")
}

/// Decoy password changes cost an attempt only when they fail, are limited until the real password or biometrics opens the vault, and never erase.
func decoyCounterChecks() throws {
    let main = "A lengthy test passphrase 1!", decoyPassword = "Another decoy phrase 2?"
    let store = MemoryStorage(), engine = VaultEngine(storage: store)
    _ = try engine.create(password: main); try engine.enableBiometrics(password: main); try engine.createDecoy(password: main, decoyPassword: decoyPassword); engine.lock()
    try rejects("wrong password") { _ = try engine.unlock(password: "Wrong passphrase 9!") }
    _ = try engine.unlock(password: decoyPassword)
    try check(try engine.remainingAttempts() == 9, "decoy sign-in leaves the failure count")
    try rejects("wrong current decoy password") { try engine.changePassword(current: "Wrong passphrase 9!", new: "Fresh decoy phrase 4$") }
    try check(try engine.remainingAttempts() == 8, "a wrong current password is counted")
    _ = try engine.unlock(password: decoyPassword) // a failed password check locks the vault
    try rejects("the real password as the decoy's") { try engine.changePassword(current: decoyPassword, new: main) }
    try check(try engine.remainingAttempts() == 7, "taking the real password is refused and counted")
    var current = decoyPassword
    for i in 1...VaultEngine.decoyChanges { let next = "Fresh decoy phrase \(i)$"; try engine.changePassword(current: current, new: next); current = next }
    try check(try engine.remainingAttempts() == 7, "successful decoy password changes cost no attempt")
    try rejects("a fourth change") { try engine.changePassword(current: current, new: "Fresh decoy phrase 9$") }
    try rejects("the real password once the allowance is used") { try engine.changePassword(current: current, new: main) }
    try check(try engine.remainingAttempts() == 7 && store.blobs.count == 2, "refused changes are not counted and erase nothing")
    engine.lock(); _ = try engine.unlock(password: current)
    try rejects("a decoy sign-in does not renew the allowance") { try engine.changePassword(current: current, new: "Fresh decoy phrase 9$") }
    engine.lock(); _ = try engine.unlockBiometric()
    try check(try engine.remainingAttempts() == 10, "biometrics clear the failure count")
    engine.lock(); _ = try engine.unlock(password: current)
    try engine.changePassword(current: current, new: "Fresh decoy phrase 9$") // and renew the allowance
    current = "Fresh decoy phrase 9$"
    // A change that stops after the real-password check (here: the new vault file cannot be written) still uses the allowance.
    store.failBlobWrite = true
    for _ in 1..<VaultEngine.decoyChanges { try rejects("interrupted change") { try engine.changePassword(current: current, new: "Fresh decoy phrase 8$") } }
    store.failBlobWrite = false
    try rejects("allowance used by interrupted changes") { try engine.changePassword(current: current, new: "Fresh decoy phrase 8$") }
    try check(try engine.remainingAttempts() == 10, "interrupted changes cost no attempt")
}

/// The real vault can give the decoy a new password, keeping its entries; the decoy cannot.
func decoyResetChecks() throws {
    let main = "A lengthy test passphrase 1!", newMain = "Another long passphrase 2@"
    let store = MemoryStorage(), engine = VaultEngine(storage: store)
    _ = try engine.create(password: main); var real = VaultRecord(); real.name = "Real bank"; try engine.save([real])
    try engine.createDecoy(password: main, decoyPassword: "Another decoy phrase 2?"); engine.lock()
    _ = try engine.unlock(password: "Another decoy phrase 2?"); var harmless = VaultRecord(); harmless.name = "Shopping"; try engine.save([harmless])
    try engine.changePassword(current: "Another decoy phrase 2?", new: "Forgotten decoy 3#"); engine.lock()
    _ = try engine.unlock(password: main)
    try check(try engine.canResetDecoy(), "the real vault can reset the decoy's password")
    try engine.changePassword(current: main, new: newMain); engine.lock()
    _ = try engine.unlock(password: newMain)
    try rejects("reset needs the app password") { try engine.resetDecoyPassword(password: "Wrong passphrase 9!", decoyPassword: "Remembered decoy 5%") }
    _ = try engine.unlock(password: newMain)
    try rejects("reset to the app password") { try engine.resetDecoyPassword(password: newMain, decoyPassword: newMain) }
    let before = Set(store.blobs.keys)
    try engine.resetDecoyPassword(password: newMain, decoyPassword: "Remembered decoy 5%")
    try check(store.blobs.count == 2 && Set(store.blobs.keys) != before, "the decoy is re-encrypted into a new file"); engine.lock()
    try rejects("the forgotten decoy password") { _ = try engine.unlock(password: "Forgotten decoy 3#") }
    try check(try engine.unlock(password: "Remembered decoy 5%").map(\.name) == ["Shopping"] && engine.isDecoy(), "the decoy keeps its entries under the new password")
    try check(!(try engine.canResetDecoy()), "only the real vault can reset the decoy")
    try rejects("reset from inside the decoy") { try engine.resetDecoyPassword(password: "Remembered decoy 5%", decoyPassword: "Another decoy 6&") }
    engine.lock(); try check(try engine.unlock(password: newMain).map(\.name) == ["Real bank"], "the real vault is untouched")
}

/// Phone-to-phone transfer; Android opens fixtures/transfer/ios.pvtransfer and iOS opens Android's android.pvtransfer.
func transferChecks() throws {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../fixtures/transfer").standardized
    for _ in 0..<100 { let c = Transfer.newCode(); try check(c.count == 12 && c.allSatisfy(Transfer.codeAlphabet.contains), "transfer code alphabet") }
    try check(Transfer.display("7K4P92XMQD3F") == "7K4P-92XM-QD3F" && (try Transfer.canonical(" 7k4p-92xm qd3f ")) == "7K4P92XMQD3F", "transfer code formats")
    for bad in ["7K4P92XMQD3", "7K4P92XMQD30", "OK4P92XMQD3F"] { try rejects("bad code \(bad)") { _ = try Transfer.canonical(bad) } }
    var a = VaultRecord(); a.name = "Mail"; var b = VaultRecord.new(type: "card"); b.name = "Visa"
    let code = Transfer.newCode(), sealed = try Transfer.seal([a, b], code: code)
    try check(try Transfer.open(sealed, code: Transfer.display(code).lowercased()) == [a, b], "transfer round trip")
    try rejects("wrong transfer code") { _ = try Transfer.open(sealed, code: code == "222222222222" ? "333333333333" : "222222222222") }
    var tampered = sealed; tampered[tampered.count - 1] ^= 1
    try rejects("tampered transfer") { _ = try Transfer.open(tampered, code: code) }
    // QR frames in any order, with repeats, rebuild the same bytes.
    let frames = try TransferFrames.frames(sealed, session: "AB12"), collector = TransferFrames.Collector()
    for f in frames.reversed() + frames { collector.add(f) }
    try check(collector.result() == sealed && frames.allSatisfy { $0.count < 700 }, "transfer frames reassemble")
    let android = Array(try TransferFrames.frames(Data(repeating: 7, count: 2345), session: "AB12").prefix(1))
    try check(android[0].hasPrefix("PVX1:AB12:1/5:"), "frame layout matches Android")
    if ProcessInfo.processInfo.environment["PASSVAULT_WRITE_TRANSFER_FIXTURE"] != nil {
        var x = VaultRecord(); x.name = "From iOS"; var y = VaultRecord.new(type: "note"); y.name = "iOS note"
        try Transfer.seal([x, y], code: "PHNE2C3DE4FG").write(to: fixtures.appendingPathComponent("ios.pvtransfer"))
    }
    // Interoperability: Android's fixture (code in the README) must open here.
    if let data = try? Data(contentsOf: fixtures.appendingPathComponent("android.pvtransfer")) {
        try check(try Transfer.open(data, code: "ANDRD2CDE3FG").map(\.name) == ["From Android", "Android card"], "opens Android's transfer")
    } else { throw VaultError.invalid("FAILED: missing fixtures/transfer/android.pvtransfer") }
}

/// Fixes from the branch review: health checks only real passwords, nested CSV folders are kept, a large transfer joins linearly.
func reviewFixChecks() throws {
    var r = VaultRecord(); r.name = "Imported"
    r.fields = [.init(kind: .password, label: "Password", value: "x7#Qm2!vLp9@Zr4^"), .init(kind: .password, label: "PIN", value: "1234"), .init(kind: .password, label: "One-time password", value: "steam://AB"),
                .init(kind: .password, label: "Old password", value: "123456"), .init(kind: .question, label: "Security question", value: "Paris")]
    try check(VaultHealth.passwordFields(r).map(\.label) == ["Password", "Old password"] && VaultHealth.check([r]).weak.map(\.password.field.label) == ["Old password"], "health checks only real passwords")
    let nested = try Importers.importPlain(Data("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\nWork/Email,,login,A,,,0,,me,p1,\nWork/Bank,,login,B,,,0,,me,p2,\nWork,,login,C,,,0,,me,p3,\n".utf8))
    try check(nested.map(\.group) == ["Work/Email", "Work/Bank", "Work"], "nested folders outside KeePassXC kept")
    let data = Data((0..<(TransferFrames.chunk * 400)).map { UInt8(truncatingIfNeeded: $0) }), collector = TransferFrames.Collector()
    for f in try TransferFrames.frames(data) { collector.add(f) }
    let started = Date(); let joined = collector.result()
    try check(joined == data && Date().timeIntervalSince(started) < 2, "transfer joins linearly")
}
