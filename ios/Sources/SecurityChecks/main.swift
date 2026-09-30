import Foundation
import VaultCore

final class MemoryStorage: VaultStorage {
    var state: Data?
    var blobs = [String: Data]()
    var biometric: Data?
    var failWrite = false
    func readState() throws -> Data? { state }
    func deleteState() throws { state = nil }
    func writeState(_ data: Data) throws { if failWrite { throw VaultError.invalid("Simulated write failure") }; state = data }
    func readBlob(_ id: String) throws -> Data { guard let data = blobs[id] else { throw VaultError.invalid("Missing blob") }; return data }
    func writeBlob(_ data: Data, id: String) throws { blobs[id] = data }
    func removeBlobs(except id: String?) throws { blobs = blobs.filter { $0.key == id } }
    func hasBlobs() throws -> Bool { !blobs.isEmpty }
    func saveBiometricKey(_ data: Data) throws { biometric = data }
    func readBiometricKey() throws -> Data { guard let biometric else { throw VaultError.locked }; return biometric }
    func deleteBiometricKey() throws { biometric = nil }
}
var checks = 0
func XCTUnwrapData(_ data: Data?) throws -> Data { guard let data else { throw VaultError.invalid("FAILED: missing state") }; return data }
func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try condition() else { throw VaultError.invalid("FAILED: \(label)") }; checks += 1
}
func rejects(_ label: String, _ action: () throws -> Void) throws {
    do { try action() } catch { checks += 1; return }
    throw VaultError.invalid("FAILED to reject: \(label)")
}
do {
    let password = "A lengthy test passphrase 1!"
    var record = VaultRecord(); record.name = "Example, Inc."; record.fields[1].value = "test-only-secret"
    record.fields[2].value = "one\r\ntwo \"quoted\""; record.fields.append(.init(kind: .question, label: "Recovery", value: "test answer", question: "Which city?"))
    let encrypted = try VaultCrypto.exportBackup([record], password: password)
    try check(VaultCrypto.importBackup(encrypted, password: password) == [record], "encrypted roundtrip")
    try rejects("wrong backup password") { _ = try VaultCrypto.importBackup(encrypted, password: "wrong") }
    var damaged = encrypted; damaged[damaged.count - 1] ^= 1
    try rejects("tampered ciphertext") { _ = try VaultCrypto.importBackup(damaged, password: password) }
    try rejects("truncated ciphertext") { _ = try VaultCrypto.importBackup(encrypted.dropLast(), password: password) }
    try check(encrypted != VaultCrypto.exportBackup([record], password: password), "fresh randomness")
    try check(encrypted.range(of: Data("test-only-secret".utf8)) == nil, "no plaintext in backup")
    let csv = try VaultCSV.exportRecords([record]), imported = try VaultCSV.importRecords(csv)
    try check(imported.count == 1 && imported[0].fields == record.fields && imported[0].name == record.name, "CSV multiline, quoting, ordered custom fields")
    try rejects("unterminated CSV") { _ = try VaultCSV.parse("a,\"unterminated") }
    try rejects("CSV trailing garbage") { _ = try VaultCSV.parse("\"a\"garbage") }
    try rejects("CSV wrong column count") { _ = try VaultCSV.importRecords("name,username,password\na,b") }
    let store = MemoryStorage(), engine = VaultEngine(storage: store)
    do { // Import matches by record id; full replacement makes the file the whole vault.
        let e = VaultEngine(storage: MemoryStorage()); _ = try e.create(password: password)
        var a = VaultRecord(), b = VaultRecord(); a.name = "a"; b.name = "b"; try e.save([a, b])
        var a2 = a; a2.name = "a2"; a2.fields.removeFirst(); var d = VaultRecord(); d.name = "d"
        let merged = try e.merge([a2, d])
        try check(merged.map(\.name) == ["a2", "b", "d"] && merged[0].id == a.id && merged[0].fields.count == a.fields.count - 1, "import replaces same-id records and keeps the rest")
        try check(try e.replaceAll([a2]) == [a2], "full replacement deletes entries the file lacks")
    }
    _ = try engine.create(password: password); try engine.save([record]); try engine.enableBiometrics(password: password); engine.lock()
    for attempt in 1...9 {
        try rejects("wrong app password") { _ = try engine.unlock(password: "wrong") }
        try check(VaultEngine(storage: store).remainingAttempts() == 10 - attempt, "durable counter")
    }
    _ = try engine.unlockBiometric()
    try check(engine.remainingAttempts() == 1, "biometrics cannot reset password counter")
    try rejects("tenth failure") { _ = try engine.unlock(password: "wrong") }
    try check(store.blobs.isEmpty && store.biometric == nil, "cryptographic erasure cleanup")
    try rejects("biometric after erasure") { _ = try engine.unlockBiometric() }
    try rejects("password after erasure") { _ = try VaultEngine(storage: store).unlock(password: password) }
    try engine.resetErasedVault()
    try check(!engine.exists(), "new vault allowed only after explicit erased-state reset")
    _ = try engine.create(password: password)
    try rejects("reset live vault without password") { try engine.resetErasedVault() }
    try engine.save([record]); try engine.changePassword(current: password, new: "A different passphrase 2?"); engine.lock()
    try rejects("old master password") { _ = try engine.unlock(password: password) }
    try check(engine.unlock(password: "A different passphrase 2?") == [record], "changed master password preserves records")
    // Backups: QVAULT02 carries its own authenticated Argon2id cost; QVAULT01 files still open.
    try check(encrypted.prefix(8) == Data("QVAULT02".utf8) && encrypted[8..<12] == Data([0, 4, 0, 0]) && encrypted[12..<16] == Data([0, 0, 0, 4]), "new backups use QVAULT02 with 256 MiB and 4 passes")
    var weaker = encrypted; weaker[9] = 0
    try rejects("backup cost below the minimum") { _ = try VaultCrypto.importBackup(weaker, password: password) }
    var costlier = encrypted; costlier[8] = 0xFF
    try rejects("backup cost above the maximum") { _ = try VaultCrypto.importBackup(costlier, password: password) }
    var retuned = encrypted; retuned[15] = 5
    try rejects("authenticated cost fields are bound to the ciphertext") { _ = try VaultCrypto.importBackup(retuned, password: password) }
    try rejects("unknown backup version") { _ = try VaultCrypto.importBackup(Data("QVAULT03".utf8) + encrypted.dropFirst(8), password: password) }
    func versionOne(_ pw: String, legacy: Bool) throws -> Data {
        let salt = VaultCrypto.random(16), header = Data("QVAULT01".utf8) + salt
        var key = try VaultCrypto.passwordKey(pw, salt: salt, legacyEncoding: legacy); defer { key.resetBytes(in: 0..<key.count) }
        return try header + VaultCrypto.seal(Records.encode([record]), key: key, aad: header)
    }
    try check(VaultCrypto.importBackup(versionOne(password, legacy: false), password: password) == [record], "QVAULT01 backups still import")
    // Passwords are NFKC-normalized. Built from scalars so the two spellings stay distinct in this source file.
    let acute = String(Unicode.Scalar(UInt8(0xE9))), combining = String(Unicode.Scalar(UInt32(0x301))!)
    let composed = "Caf" + acute + " pass phrase 1!", decomposed = "Cafe" + combining + " pass phrase 1!"
    try check(Array(composed.utf8) != Array(decomposed.utf8) && PasswordText.differs(decomposed) && !PasswordText.differs(composed), "composed and decomposed spellings are different bytes")
    try check(!PasswordText.differs(password), "ASCII passwords are unchanged, so existing vaults keep working")
    let salt16 = VaultCrypto.random(16)
    try check(VaultCrypto.passwordKey(composed, salt: salt16) == VaultCrypto.passwordKey(decomposed, salt: salt16), "both spellings derive the same key")
    try check(VaultCrypto.passwordKey(decomposed, salt: salt16) != VaultCrypto.passwordKey(decomposed, salt: salt16, legacyEncoding: true), "legacy encoding keys from the text as typed")
    try check(VaultCrypto.passwordProblem(composed) == VaultCrypto.passwordProblem(decomposed), "password policy judges the normalized text")
    try check(VaultCrypto.importBackup(versionOne(decomposed, legacy: true), password: decomposed) == [record], "QVAULT01 keyed from raw typed text still imports")
    try check(VaultCrypto.importBackup(versionOne(decomposed, legacy: false), password: composed) == [record], "QVAULT01 keyed from normalized text imports with either spelling")
    let store3 = MemoryStorage(), engine3 = VaultEngine(storage: store3)
    _ = try engine3.create(password: decomposed); engine3.lock()
    try check(engine3.unlock(password: composed).isEmpty, "either spelling of the password opens the vault")
    // A vault keyed the old way (raw typed text) opens once, costs one attempt, and is re-wrapped in normalized form.
    let store4 = MemoryStorage(), engine4 = VaultEngine(storage: store4)
    _ = try engine4.create(password: password); try engine4.save([record]); engine4.lock()
    var json = try JSONSerialization.jsonObject(with: XCTUnwrapData(store4.state)) as! [String: Any]
    let oldSalt = Data(base64Encoded: json["salt"] as! String)!, oldSecret = Data(base64Encoded: json["secret"] as! String)!, oldWrapped = Data(base64Encoded: json["wrappedKey"] as! String)!
    let aadKey = Data("PassVault/key/v1".utf8)
    let dataKey = try VaultCrypto.open(oldWrapped, key: VaultCrypto.deviceKey(VaultCrypto.passwordKey(password, salt: oldSalt), secret: oldSecret), aad: aadKey)
    let legacyWrapping = try VaultCrypto.deviceKey(VaultCrypto.passwordKey(decomposed, salt: oldSalt, legacyEncoding: true), secret: oldSecret)
    json["wrappedKey"] = try VaultCrypto.seal(dataKey, key: legacyWrapping, aad: aadKey).base64EncodedString()
    store4.state = try JSONSerialization.data(withJSONObject: json)
    try rejects("password that matches neither spelling") { _ = try engine4.unlock(password: "Cafe pass phrase 1!") }
    try check(engine4.remainingAttempts() == 9, "a failed attempt is charged once even when two spellings are tried")
    try check(engine4.unlock(password: decomposed) == [record] && engine4.remainingAttempts() == 10, "legacy-keyed vault opens and clears the counter")
    let rewrapped = try JSONSerialization.jsonObject(with: XCTUnwrapData(store4.state)) as! [String: Any]
    try check(rewrapped["salt"] as! String != json["salt"] as! String, "legacy-keyed vault is re-wrapped with a fresh salt")
    engine4.lock(); try check(engine4.unlock(password: composed) == [record], "re-wrapped vault opens with the normalized spelling")
    // Changing the password replaces the data key and the vault ciphertext, and drops the biometric copy of the old key.
    let store5 = MemoryStorage(), engine5 = VaultEngine(storage: store5)
    _ = try engine5.create(password: password); try engine5.save([record]); try engine5.enableBiometrics(password: password)
    let oldBlobs = store5.blobs, oldBiometricKey = store5.biometric!
    try engine5.changePassword(current: password, new: "A different passphrase 2?")
    try check(store5.biometric == nil, "changing the password removes the biometric copy of the old data key")
    try check(store5.blobs.count == 1 && oldBlobs.keys.first != store5.blobs.keys.first && oldBlobs.values.first != store5.blobs.values.first, "vault is re-encrypted into a new file")
    let newBlobId = store5.blobs.keys.first!
    try rejects("old data key cannot open the rotated vault") { _ = try VaultCrypto.open(store5.blobs[newBlobId]!, key: oldBiometricKey, aad: Data(newBlobId.utf8)) }
    try rejects("biometric unlock after password change") { _ = try engine5.unlockBiometric() }
    try rejects("wrong current password changes nothing") { try engine5.changePassword(current: "wrong", new: "Yet another passphrase 3!") }
    engine5.lock(); try check(VaultEngine(storage: store5).unlock(password: "A different passphrase 2?") == [record], "records survive key rotation")
    try rejects("old password after rotation") { _ = try VaultEngine(storage: store5).unlock(password: password) }
    let store6 = MemoryStorage(), engine6 = VaultEngine(storage: store6)
    _ = try engine6.create(password: password); try engine6.save([record]); let before6 = store6.blobs; store6.failWrite = true
    try rejects("failed state write during password change") { try engine6.changePassword(current: password, new: "A different passphrase 2?") }
    store6.failWrite = false
    try check(store6.blobs == before6 || store6.blobs.count == 1, "failed password change leaves one vault file")
    engine6.lock(); try check(VaultEngine(storage: store6).unlock(password: password) == [record], "failed password change keeps the old password working")
    // Data from a newer PassVault gets an "update the app" error, not a generic or misleading one.
    func isError(_ expected: VaultError, _ action: () throws -> Void) -> Bool {
        do { try action(); return false } catch let error as VaultError { return String(describing: error) == String(describing: expected) } catch { return false }
    }
    try check(isError(.newerBackup) { _ = try VaultCrypto.importBackup(Data("QVAULT03".utf8) + Data(repeating: 0, count: 80), password: password) }, "newer backup version is reported as newer")
    try check(isError(.newerBackup) { _ = try VaultCrypto.importBackup(Data("QVAULT10".utf8), password: password) }, "even a truncated newer backup is reported as newer")
    try check(!isError(.newerBackup) { _ = try VaultCrypto.importBackup(Data("QVAULTxx".utf8) + Data(repeating: 0, count: 80), password: password) }, "unknown non-version marker is not called newer")
    try check(!isError(.newerBackup) { _ = try VaultCrypto.importBackup(encrypted, password: "wrong") }, "wrong password is not called newer")
    let store7 = MemoryStorage(), engine7 = VaultEngine(storage: store7)
    _ = try engine7.create(password: password); engine7.lock()
    var future = try JSONSerialization.jsonObject(with: XCTUnwrapData(store7.state)) as! [String: Any]
    future["version"] = 2; future["somethingNew"] = "x"; future.removeValue(forKey: "wrappedKey")
    store7.state = try JSONSerialization.data(withJSONObject: future)
    try check(isError(.newerVault) { _ = try engine7.exists() } && isError(.newerVault) { _ = try engine7.unlock(password: password) }, "state from a newer version is reported as newer")
    try check(isError(.newerVault) { _ = try engine7.isErased() }, "newer state is reported as newer when checking erasure")
    let store2 = MemoryStorage(), engine2 = VaultEngine(storage: store2)
    _ = try engine2.create(password: password); engine2.lock(); store2.failWrite = true
    try rejects("failed state commit") { _ = try engine2.unlock(password: password) }
    store2.failWrite = false
    try rejects("bad password") { _ = try engine2.unlock(password: "wrong") }
    _ = try engine2.unlock(password: password)
    try check(engine2.remainingAttempts() == 10, "correct password resets counter")
    store2.state = nil
    try rejects("deleted protected state") { _ = try engine2.exists() }
    try rejects("recreate over orphaned vault") { _ = try engine2.create(password: password) }
    for _ in 0..<50 {
        let value = try VaultCrypto.generatePassword()
        try check(value.count == 24 && value.contains(where: { $0.isUppercase }) && value.contains(where: { $0.isLowercase }) && value.contains(where: { $0.isNumber }), "generator policy")
    }
    try rejects("invalid generator length") { _ = try VaultCrypto.generatePassword(length: 0) }
    func brandId(_ website: String, _ name: String = "") -> String? { findBrand(website: website, name: name)?.id }
    try check(brandId("Spotify") == "spotify" && brandId("spotify.com") == "spotify" && brandId("https://open.spotify.com/track/1?x=y") == "spotify" && brandId("", "SPOTIFY") == "spotify", "brand by name or domain")
    try check(brandId("www.github.com") == "github" && brandId("mail.google.com") == "google" && brandId("Gmail") == "google" && brandId("twitter.com") == "x", "brand subdomains and aliases")
    try check(brandId("github.com", "Spotify") == "github", "brand: website wins over name")
    try check(brandId("Spotify family plan") == nil && brandId("notspotify.com") == nil && brandId("spotify.com.evil.example") == nil && brandId("Apple pie recipes") == nil && brandId("") == nil, "brand does not over-match")
    try check(brandId("Synology") == "synology" && brandId("Charles Schwab") == "schwab" && brandId("client.schwab.com") == "schwab" && brandId("online.citibank.com.hk") == "citi" && brandId("中國信託") == "ctbc" && brandId("招商银行") == "cmb" && brandId("www.hsbc.com.hk") == "hsbc", "brand banks and Synology")
    try check(brandId("schwab.com") == "schwab" && brandId("", "Charles Schwab Bank") == "schwab" && brandId("abchina.com") == "abc" && brandId("中國農業銀行") == "abc" && brandId("", "中国农业银行信用卡") == "abc" && brandId("Amazon.com") == "amazon" && brandId("Microsoft") == "microsoft" && brandId("https://www.linkedin.com/login") == "linkedin", "brand reported cases")
    try check(brandId("binance.com") == "binance" && brandId("Bitget") == "bitget" && brandId("gate.io") == "gateio" && brandId("Huobi") == "htx" && brandId("Crypto.com") == "cryptocom" && brandId("Trust Wallet") == "trustwallet" && brandId("phantom.app") == "phantom" && brandId("MetaMask") == "metamask" && brandId("wallet.coinbase.com") == "coinbasewallet" && brandId("Max") == nil, "brand crypto exchanges and wallets")
    try check(brandId("Metamask Wallet") == "metamask" && brandId("MetaMask") == "metamask" && brandId("Phantom") == "phantom" && brandId("Phantom Wallet") == "phantom" && brandId("HTTPS://WWW.Phantom.APP/x") == "phantom" && brandId("國泰世華銀行") == "cathaybk" && brandId("Bybit Exchange") == "bybit", "brand: wallet/exchange suffix, case and scheme")
    try check(brandId("ABC") == nil && brandId("Post") == nil && brandId("Key") == nil, "generic marks match by domain only")
    try check(groupColorRGB("Work") == groupColorRGB(" work "), "group color ignores case and spaces")
    // Password Keeper .pkb2 import: sanitized fixture (fake data), same file the Android tests use.
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("android/app/src/test/resources/sample.pkb2")
    let pkb2 = try Data(contentsOf: fixture)
    let keeper = try Pkb2.importRecords(pkb2, password: "correct horse")
    try check(keeper.count == 3 && Pkb2.isPkb2(pkb2) && !Pkb2.isPkb2(Data("QVAULT01".utf8)), "pkb2 records")
    let login = keeper[0]
    try check(login.name == "Sample login" && login.website == "example.com" && login.favorite && login.legacy["uid"] == "11111111111111111111111111111111", "pkb2 record metadata")
    try check(login.fields.map(\.value) == ["alice", "Pw-one-1!", "first note", "alice2", "Pw-two-2!", "second note", "Rex", "Paris", "second.example.com", "bob", "Pw-three-3!", "typed-by-hand"], "pkb2 fields keep original order")
    try check(login.fields.map(\.kind) == [.username, .password, .note, .username, .password, .note, .question, .question, .note, .username, .password, .password], "pkb2 field kinds")
    try check(login.fields.filter { $0.kind == .question }.map(\.question) == ["First pet?", "Birth city?"] && login.fields[9].label == "Work login" && login.fields[8].label == "Website", "pkb2 labels")
    try check(login.fields[4].historyNewestFirst.map(\.value) == ["Old-pw-0!", "Older-pw-9!"] && login.fields[4].historyNewestFirst.map(\.changedAt) == [1690000000, 1680000000], "pkb2 password history newest first")
    try check(login.fields.enumerated().allSatisfy { $0.offset == 4 || $0.element.history == nil } && login.fields[11].label == "Previous password" && login.fields[11].history == nil, "manual 'Previous password' field is not history")
    let roundTrip = try Records.decode(Records.encode(keeper))
    try check(roundTrip[0].fields == login.fields, "history survives vault encoding")
    try check(try VaultCSV.importRecords(VaultCSV.exportRecords(keeper))[0].fields == login.fields, "history survives CSV roundtrip")
    let oldJSON = Data(#"[{"id":"a","name":"x","website":"","group":"","favorite":false,"updatedAt":"2020-01-01T00:00:00Z","fields":[{"id":"f","kind":"password","label":"Password","value":"v","question":""}],"legacy":{}}]"#.utf8)
    try check(try Records.decode(oldJSON)[0].fields[0].history == nil, "records without history still load")
    try check(keeper[1].fields.first?.value == "line1\nline2 é" && keeper[2].fields.map(\.value) == ["[ ] eggs", "[x] milk"], "pkb2 notes and lists")
    try rejects("pkb2 wrong password") { _ = try Pkb2.importRecords(pkb2, password: "wrong password") }
    var tampered = pkb2; tampered[tampered.count - 40] ^= 1
    try rejects("pkb2 tampering") { _ = try Pkb2.importRecords(tampered, password: "correct horse") }
    try rejects("pkb2 truncation") { _ = try Pkb2.importRecords(pkb2.prefix(100), password: "correct horse") }
    if let path = ProcessInfo.processInfo.environment["PASSVAULT_TEST_PKB2"] {
        let real = try Pkb2.importRecords(Data(contentsOf: URL(fileURLWithPath: path)), password: ProcessInfo.processInfo.environment["PASSVAULT_TEST_PKB2_PASSWORD"] ?? "")
        try check(!real.isEmpty, "local pkb2 fixture has records")
        print("Local PKB2 import verified (\(real.count) records); no record contents logged.")
    }
    // Password history recorded natively when a saved value changes.
    var before = VaultRecord(); before.fields = [.init(kind: .username, label: "Username", value: "alice"), .init(kind: .password, label: "Password", value: "old-1"), .init(kind: .question, label: "Security question", value: "answer-1", question: "Pet?"), .init(kind: .note, label: "Notes", value: "n1"), .init(kind: .password, label: "Previous password", value: "typed")]
    var after = before; after.fields[0].value = "alice2"; after.fields[1].value = "new-2"; after.fields[2].value = "answer-2"; after.fields[3].value = "n2"
    let stamp = Date(timeIntervalSince1970: 1_800_000_000)
    let tracked = after.recordingPasswordChanges(previous: before, at: stamp)
    try check(tracked.fields[1].history == [PasswordChange(value: "old-1", changedAt: 1_800_000_000)] && tracked.fields[2].history == [PasswordChange(value: "answer-1", changedAt: 1_800_000_000)], "password and answer changes recorded with a timestamp")
    try check(tracked.fields[0].history == nil && tracked.fields[3].history == nil && tracked.fields[4].history == nil, "usernames, notes and unchanged fields record nothing")
    try check(before.recordingPasswordChanges(previous: before, at: stamp) == before && after.recordingPasswordChanges(previous: nil, at: stamp) == after, "no change or new record records nothing")
    var seed = before; seed.type = "seed"; var seedAfter = seed; seedAfter.fields[1].value = "changed"
    try check(seedAfter.recordingPasswordChanges(previous: seed, at: stamp) == seedAfter, "seed phrases are not tracked")
    var chain = before
    for n in 1...12 { var next = chain; next.fields[1].value = "pw-\(n)"; chain = next.recordingPasswordChanges(previous: chain, at: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + n))) }
    try check(chain.fields[1].history?.count == passwordHistoryLimit && chain.fields[1].historyNewestFirst.first?.value == "pw-11" && chain.fields[1].historyNewestFirst.last?.value == "pw-2", "history keeps the newest \(passwordHistoryLimit) entries")
    if let path = ProcessInfo.processInfo.environment["PASSVAULT_TEST_CSV"] {
        let migrated = try VaultCSV.importRecords(String(contentsOfFile: path, encoding: .utf8))
        try check(!migrated.isEmpty, "local migration fixture has records")
        let back = try VaultCSV.importRecords(VaultCSV.exportRecords(migrated))
        try check(back.map(\.fields) == migrated.map(\.fields), "local migration roundtrip")
        print("Local CSV migration verified; no record contents logged.")
    }
    print("PASS: \(checks) security and migration checks.")
} catch {
    // Error messages contain no input values or decrypted records.
    fputs("Security check failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
