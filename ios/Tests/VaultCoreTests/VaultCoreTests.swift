import XCTest
@testable import VaultCore

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
final class VaultCoreTests: XCTestCase {
    let password = "A lengthy test passphrase 1!"
    func fixture() -> VaultRecord {
        var r = VaultRecord(); r.name = "Example, Inc."; r.fields[1].value = "test-only-secret"
        r.fields[2].value = "one\r\ntwo \"quoted\""; r.fields.append(.init(kind: .question, label: "Recovery", value: "test answer", question: "Which city?"))
        return r
    }
    func testBackupAuthenticatesPasswordAndAllBytes() throws {
        let records = [fixture()], encrypted = try VaultCrypto.exportBackup(records, password: password)
        XCTAssertEqual(try VaultCrypto.importBackup(encrypted, password: password), records)
        XCTAssertThrowsError(try VaultCrypto.importBackup(encrypted, password: "wrong"))
        var damaged = encrypted; damaged[damaged.count - 1] ^= 1
        XCTAssertThrowsError(try VaultCrypto.importBackup(damaged, password: password))
        XCTAssertThrowsError(try VaultCrypto.importBackup(encrypted.dropLast(), password: password))
        XCTAssertNotEqual(encrypted, try VaultCrypto.exportBackup(records, password: password))
        XCTAssertNil(encrypted.range(of: Data("test-only-secret".utf8)))
    }
    func testCSVPreservesOrderedFieldsAndQuotedMultilineValues() throws {
        let original = fixture(), csv = try VaultCSV.exportRecords([original]), imported = try VaultCSV.importRecords(csv)
        XCTAssertEqual(imported.count, 1); XCTAssertEqual(imported[0].name, original.name)
        XCTAssertEqual(imported[0].fields, original.fields)
        XCTAssertThrowsError(try VaultCSV.parse("a,\"unterminated"))
        XCTAssertThrowsError(try VaultCSV.parse("\"a\"garbage"))
        XCTAssertThrowsError(try VaultCSV.importRecords("name,username,password\na,b"))
    }
    func testErasureAndBiometricBypassPrevention() throws {
        let store = MemoryStorage(), engine = VaultEngine(storage: store)
        _ = try engine.create(password: password)
        try engine.save([fixture()]); try engine.enableBiometrics(password: password); engine.lock()
        for attempt in 1...9 {
            XCTAssertThrowsError(try engine.unlock(password: "wrong"))
            XCTAssertEqual(try engine.remainingAttempts(), 10 - attempt)
        }
        _ = try engine.unlockBiometric()
        XCTAssertEqual(try engine.remainingAttempts(), 1)
        XCTAssertThrowsError(try engine.unlock(password: "wrong"))
        XCTAssertTrue(store.blobs.isEmpty); XCTAssertNil(store.biometric)
        XCTAssertThrowsError(try engine.unlockBiometric())
        XCTAssertThrowsError(try engine.unlock(password: password))
        XCTAssertThrowsError(try VaultEngine(storage: store).exists())
    }
    func testStateWriteFailurePreventsPasswordCheckAndMissingStateFailsClosed() throws {
        let store = MemoryStorage(), engine = VaultEngine(storage: store)
        _ = try engine.create(password: password); engine.lock(); store.failWrite = true
        XCTAssertThrowsError(try engine.unlock(password: password))
        store.failWrite = false; store.state = nil
        XCTAssertThrowsError(try engine.exists())
        XCTAssertThrowsError(try engine.create(password: password))
    }
    func testAttemptSurvivesNewEngineAndCorrectPasswordResets() throws {
        let store = MemoryStorage(), engine = VaultEngine(storage: store)
        _ = try engine.create(password: password); engine.lock()
        XCTAssertThrowsError(try engine.unlock(password: "wrong"))
        let restarted = VaultEngine(storage: store)
        XCTAssertEqual(try restarted.remainingAttempts(), 9)
        _ = try restarted.unlock(password: password)
        XCTAssertEqual(try restarted.remainingAttempts(), 10)
    }
    func testInterruptedTenthAttemptErasesOnNextAccess() throws {
        let store = MemoryStorage(), engine = VaultEngine(storage: store)
        _ = try engine.create(password: password)
        var state = try JSONDecoder().decode(DeviceState.self, from: XCTUnwrap(store.state))
        state.attempts = 10; store.state = try JSONEncoder().encode(state)
        XCTAssertThrowsError(try VaultEngine(storage: store).unlock(password: password))
        XCTAssertTrue(store.blobs.isEmpty)
    }
    func testGeneratorPolicy() throws {
        for _ in 0..<50 {
            let value = try VaultCrypto.generatePassword()
            XCTAssertEqual(value.count, 24)
            XCTAssertTrue(value.contains { $0.isUppercase }); XCTAssertTrue(value.contains { $0.isLowercase }); XCTAssertTrue(value.contains { $0.isNumber })
        }
        XCTAssertThrowsError(try VaultCrypto.generatePassword(length: 0))
    }
    func testLocalMigrationFileWithoutExposingSecrets() throws {
        guard let path = ProcessInfo.processInfo.environment["PASSVAULT_TEST_CSV"] else { throw XCTSkip("Optional local migration fixture not configured") }
        let records = try VaultCSV.importRecords(String(contentsOfFile: path, encoding: .utf8))
        XCTAssertFalse(records.isEmpty)
        let roundtrip = try VaultCSV.importRecords(VaultCSV.exportRecords(records))
        XCTAssertEqual(roundtrip.map(\.fields), records.map(\.fields))
    }
}
