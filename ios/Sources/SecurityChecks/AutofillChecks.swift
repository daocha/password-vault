import Foundation
import VaultCore

/// One vault opened by two engines, as the app and AutoFill open it from two processes, with one lock for both (as `FileLock`).
private final class LockedStorage: VaultStorage {
    let inner = MemoryStorage()
    private let lock = NSRecursiveLock()
    func exclusive<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    func readState() throws -> Data? { try inner.readState() }
    func writeState(_ data: Data) throws { try inner.writeState(data) }
    func deleteState() throws { try inner.deleteState() }
    func readBlob(_ id: String) throws -> Data { try inner.readBlob(id) }
    func writeBlob(_ data: Data, id: String) throws { try inner.writeBlob(data, id: id) }
    func removeBlobs(keeping ids: Set<String>) throws { try inner.removeBlobs(keeping: ids) }
    func hasBlobs() throws -> Bool { try inner.hasBlobs() }
    func saveBiometricKey(_ data: Data) throws { try inner.saveBiometricKey(data) }
    func readBiometricKey() throws -> Data { try inner.readBiometricKey() }
    func hasBiometricKey() throws -> Bool { try inner.hasBiometricKey() }
    func deleteBiometricKey() throws { try inner.deleteBiometricKey() }
}

/// iOS AutoFill: website matching (the same cases as Android's AutofillDomainsTest), the shared vault and its lock (see AutofillTests and
/// SharedVaultTests).
func autofillChecks() throws {
    try check(AutofillDomains.listLoaded, "the Public Suffix List loads")
    func base(_ host: String) -> String? { AutofillDomains.host(host).flatMap(AutofillDomains.registrable) }
    for suffix in ["github.io", "pages.dev", "appspot.com", "s3.amazonaws.com"] {
        try check(!AutofillDomains.sameSite("https://victim.\(suffix)", "attacker.\(suffix)"), "hosting tenants are different sites: \(suffix)")
        try check(AutofillDomains.sameSite("https://login.victim.\(suffix)", "victim.\(suffix)"), "a tenant's own subdomain matches: \(suffix)")
    }
    try check(base("www.bbc.co.uk") == "bbc.co.uk" && base("co.uk") == nil && base("foo.ck") == nil && base("login.www.ck") == "www.ck"
              && base("www.city.kawasaki.jp") == "city.kawasaki.jp" && base("ward.kawasaki.jp") == nil, "public suffix wildcard and exception rules")
    try check(AutofillDomains.sameSite("https://10.0.0.1:443/login", "10.0.0.1") && !AutofillDomains.sameSite("https://10.0.0.1", "192.168.0.1")
              && !AutofillDomains.sameSite("https://[2001:db8::1]/", "2001:db8::2"), "IP addresses compared as complete literals")
    for ambiguous in ["127.1", "0177.0.0.1", "2130706433", "0x7f000001", "1.2.3.0x4"] { try check(AutofillDomains.host(ambiguous) == nil, "ambiguous address refused: \(ambiguous)") }
    try check(AutofillDomains.sameSite("https://bücher.de/login", "xn--bcher-kva.de") && !AutofillDomains.sameSite("https://faß.de", "fass.de")
              && !AutofillDomains.sameSite("https://apple.com", "аpple.com"), "international names: same site only when the same")
    for bad in ["https://bank.com@evil.com", "https://evil.com\\@bank.com", "javascript://bank.com", "https://bank.com:99999", "https://bank.com:", "https://bank..com",
                "https://bank.com%2eevil.com", "https://bank.com\nevil.com"] { try check(AutofillDomains.host(bad) == nil, "malformed origin refused: \(bad)") }

    var bank = VaultRecord(); bank.name = "Bank"; bank.website = "https://www.bank.com"; bank.fields[0].value = "me"; bank.fields[1].value = "secret"
    var mail = VaultRecord(); mail.name = "Mail"; mail.website = "mail.example"; mail.fields[1].value = "other"
    var card = VaultRecord(); card.name = "Card"; card.type = "card"; card.website = "bank.com"; card.fields[1].value = "1234"
    let logins = AutofillMatch.candidates([bank, mail, card])
    try check(logins.map(\.name) == ["Bank", "Mail"], "only logins are offered")
    let shown = AutofillMatch.shown(logins, sites: AutofillMatch.sites(["https://login.bank.com/"]), query: "")
    try check(shown.suggested && shown.records.map(\.name) == ["Bank"], "the site's logins are suggested")
    try check(AutofillMatch.shown(logins, sites: AutofillMatch.sites(["https://other.example"]), query: "").records.count == 2, "no match lists every login")

    // The app and AutoFill on one vault: saves and unlocks never interleave, so the vault always opens.
    let password = "A lengthy test passphrase 1!", storage = LockedStorage()
    let app = VaultEngine(storage: storage), autofill = VaultEngine(storage: storage, sequentialKeys: true)
    _ = try app.create(password: password)
    let group = DispatchGroup()
    var failed = false
    DispatchQueue.global().async(group: group) {
        var saved = [VaultRecord]()
        for step in 0..<8 { var entry = VaultRecord(); entry.name = "Entry \(step)"; saved.append(entry); if (try? app.save(saved)) == nil { failed = true } }
    }
    DispatchQueue.global().async(group: group) {
        for _ in 0..<2 { if (try? autofill.unlock(password: password)) == nil { failed = true }; autofill.lock() }
    }
    group.wait()
    try check(!failed, "saving in the app while AutoFill unlocks")
    try check(try VaultEngine(storage: storage).unlock(password: password).count == 8, "every save kept and the vault still opens")
    try rejects("a wrong password in AutoFill") { _ = try autofill.unlock(password: "wrong password") }
    try check(try app.remainingAttempts() == 9, "AutoFill's failed attempts count for the app too")

    let path = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var holds = [Bool]()
    let lock = FileLock(path: path) { holds.append($0) }, other = FileLock(path: path)
    try check(lock.run { lock.run { 5 } } == 5 && holds == [true, false], "the file lock is reentrant and keeps the app alive once per hold")
    let held = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    var order = [String]()
    DispatchQueue.global().async { lock.run { order.append("app"); held.signal(); Thread.sleep(forTimeInterval: 0.2); order.append("app done") }; done.signal() }
    held.wait(); other.run { order.append("autofill") }; done.wait()
    try check(order == ["app", "app done", "autofill"], "AutoFill waits for the app's transaction")
}
