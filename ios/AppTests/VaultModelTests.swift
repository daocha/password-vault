import XCTest
import VaultCore
@testable import PassVault

final class ModelTestStorage: VaultStorage {
    var state: Data?
    var blobs = [String: Data]()
    var biometric: Data?
    func readState() throws -> Data? { state }
    func writeState(_ data: Data) throws { state = data }
    func deleteState() throws { state = nil }
    func readBlob(_ id: String) throws -> Data { try XCTUnwrap(blobs[id]) }
    func writeBlob(_ data: Data, id: String) throws { blobs[id] = data }
    func removeBlobs(keeping ids: Set<String>) throws { blobs = blobs.filter { ids.contains($0.key) } }
    func hasBlobs() throws -> Bool { !blobs.isEmpty }
    func saveBiometricKey(_ data: Data) throws { biometric = data }
    func readBiometricKey() throws -> Data { guard let biometric else { throw VaultError.locked }; return biometric }
    func hasBiometricKey() throws -> Bool { biometric != nil }
    func deleteBiometricKey() throws { biometric = nil }
}

@MainActor final class VaultModelTests: XCTestCase {
    private let password = "A lengthy test passphrase 1!"

    func testDeviceLockOverridesEveryBackgroundDelayAndDiscardsTransfer() throws {
        let original = AppSettings.shared.autoLock
        defer { AppSettings.shared.autoLock = original }
        for option in AutoLock.allCases {
            let engine = VaultEngine(storage: ModelTestStorage())
            let records = try engine.create(password: password)
            let model = VaultModel(engine: engine)
            model.records = records + [VaultRecord()]; model.unlocked = true
            model.sending = TransferPayload(code: "test", data: Data(), decoy: false)
            AppSettings.shared.autoLock = option
            model.didEnterBackground()
            model.deviceDidLock()
            model.didBecomeActive()
            XCTAssertFalse(model.unlocked, option.rawValue)
            XCTAssertTrue(model.records.isEmpty, option.rawValue)
            XCTAssertNil(model.sending, option.rawValue)
        }
    }

    func testResetClearsBothVaultsBackupHistoriesBeforeCreatingANewVault() throws {
        let suite = "PassVault.model-tests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for decoy in [false, true] {
            let history = BackupStatus(defaults: defaults, decoy: decoy)
            history.record(savedAt: Date(), snapshotAt: Date(), instance: history.instance)
            history.intervalDays = 7; history.snoozedUntil = Date().addingTimeInterval(86400)
        }
        let storage = ModelTestStorage(), engine = VaultEngine(storage: storage)
        _ = try engine.create(password: password)
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(storage.state)) as? [String: Any])
        state["erased"] = true
        storage.state = try JSONSerialization.data(withJSONObject: state)
        let model = VaultModel(engine: engine, defaults: defaults)
        XCTAssertTrue(model.erased)
        model.resetErased()
        XCTAssertFalse(model.erased); XCTAssertFalse(model.exists)
        XCTAssertNil(model.lastBackup); XCTAssertNil(model.backupSnapshotAt); XCTAssertNil(model.backupSnoozedUntil)
        XCTAssertEqual(model.backupIntervalDays, 30)
        for decoy in [false, true] { XCTAssertNil(BackupStatus(defaults: defaults, decoy: decoy).lastBackup) }
        _ = try engine.create(password: password)
        model.records = [VaultRecord()]
        XCTAssertTrue(model.backupDue)
    }

    func testDisablingBiometricsUpdatesSettingsAndRemovesTheUnlockKey() async throws {
        let storage = ModelTestStorage(), engine = VaultEngine(storage: storage)
        _ = try engine.create(password: password)
        try engine.enableBiometrics(password: password)
        let model = VaultModel(engine: engine)
        model.unlocked = true
        XCTAssertTrue(model.biometricEnabled)
        let done = expectation(description: "disable biometrics")
        model.run({ try $0.disableBiometrics(); return nil }, done: { done.fulfill() })
        await fulfillment(of: [done], timeout: 15)
        XCTAssertFalse(model.biometricEnabled)
        XCTAssertNil(storage.biometric)
        XCTAssertTrue(model.unlocked)
        engine.lock()
        XCTAssertThrowsError(try engine.unlockBiometric())
    }
}
