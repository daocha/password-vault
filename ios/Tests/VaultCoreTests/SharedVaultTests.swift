import Foundation
import XCTest
@testable import VaultCore

/// One vault opened by two engines, as the iOS app and its AutoFill extension open it from two processes. `exclusive` is one lock for
/// both (the app's storage uses a file lock), and every storage call records whether it was made while holding it.
final class SharedStorage: VaultStorage {
    private let inner = MemoryStorage()
    private let lock = NSRecursiveLock(), books = NSLock()
    private var owner: Thread?, depth = 0
    private(set) var callsOutsideLock = 0
    func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        books.lock(); owner = Thread.current; depth += 1; books.unlock()
        defer { books.lock(); depth -= 1; if depth == 0 { owner = nil }; books.unlock(); lock.unlock() }
        return try body()
    }
    private func checked<T>(_ body: () throws -> T) rethrows -> T {
        books.lock(); if owner !== Thread.current { callsOutsideLock += 1 }; books.unlock()
        return try body()
    }
    func readState() throws -> Data? { try checked { try inner.readState() } }
    func writeState(_ data: Data) throws { try checked { try inner.writeState(data) } }
    func deleteState() throws { try checked { try inner.deleteState() } }
    func readBlob(_ id: String) throws -> Data { try checked { try inner.readBlob(id) } }
    func writeBlob(_ data: Data, id: String) throws { try checked { try inner.writeBlob(data, id: id) } }
    func removeBlobs(keeping ids: Set<String>) throws { try checked { try inner.removeBlobs(keeping: ids) } }
    func hasBlobs() throws -> Bool { try checked { try inner.hasBlobs() } }
    func saveBiometricKey(_ data: Data) throws { try checked { try inner.saveBiometricKey(data) } }
    func readBiometricKey() throws -> Data { try checked { try inner.readBiometricKey() } }
    func hasBiometricKey() throws -> Bool { try checked { try inner.hasBiometricKey() } }
    func deleteBiometricKey() throws { try checked { try inner.deleteBiometricKey() } }
}

final class SharedVaultTests: XCTestCase {
    private let password = "A lengthy test passphrase 1!"

    /// The app saves while the extension unlocks. Without the shared lock the extension could write back the state it read before the
    /// app's save, pointing at a vault file the save had just deleted, and the vault would never open again.
    func testTheAppAndTheExtensionNeverInterleaveStorage() throws {
        let storage = SharedStorage()
        let app = VaultEngine(storage: storage), autofill = VaultEngine(storage: storage, sequentialKeys: true)
        _ = try app.create(password: password)
        let group = DispatchGroup(), saves = 12
        var failures = [Error](), failuresLock = NSLock()
        func record(_ error: Error) { failuresLock.lock(); failures.append(error); failuresLock.unlock() }
        DispatchQueue.global().async(group: group) {
            var saved = [VaultRecord]()
            for step in 0..<saves {
                var entry = VaultRecord(); entry.name = "Entry \(step)"; saved.append(entry)
                do { try app.save(saved) } catch { record(error) }
            }
        }
        DispatchQueue.global().async(group: group) {
            for _ in 0..<3 {
                do { _ = try autofill.unlock(password: self.password); autofill.lock() } catch { record(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(storage.callsOutsideLock, 0, "every storage call is inside the shared lock")
        let reopened = try VaultEngine(storage: storage).unlock(password: password)
        XCTAssertEqual(reopened.count, saves, "every save is kept and the vault still opens")
        XCTAssertEqual(try app.remainingAttempts(), 10)
    }

    /// Questions about the open vault only read memory: they never wait for the other process.
    func testInMemoryQuestionsDoNotWaitForTheOtherProcess() throws {
        let storage = SharedStorage(), app = VaultEngine(storage: storage)
        _ = try app.create(password: password)
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { storage.exclusive { held.signal(); _ = release.wait(timeout: .now() + 10) }; done.signal() }
        held.wait()
        let started = Date()
        XCTAssertTrue(app.isUnlocked()); XCTAssertFalse(app.isDecoy())
        if case .keyGone = try app.exportAutomatic(sealedKey: Data(repeating: 1, count: 72), lastDigest: nil) {} else { XCTFail("an unrelated key does not open") }
        app.lock()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        release.signal(); done.wait()
    }

    /// The extension derives its two keys one after the other (iOS stops an extension that uses much memory), with the same results.
    func testOneAfterAnotherOpensBothVaultsAndCountsFailures() throws {
        let storage = MemoryStorage(), app = VaultEngine(storage: storage)
        _ = try app.create(password: password)
        var record = VaultRecord(); record.name = "Real"
        try app.save([record])
        try app.createDecoy(password: password, decoyPassword: "Another lengthy decoy phrase 2!")
        app.lock()
        let autofill = VaultEngine(storage: storage, sequentialKeys: true)
        XCTAssertEqual(try autofill.unlock(password: password).map(\.name), ["Real"])
        XCTAssertFalse(autofill.isDecoy())
        autofill.lock()
        XCTAssertEqual(try autofill.unlock(password: "Another lengthy decoy phrase 2!"), [])
        XCTAssertTrue(autofill.isDecoy())
        autofill.lock()
        XCTAssertThrowsError(try autofill.unlock(password: "wrong password"))
        XCTAssertFalse(autofill.isUnlocked())
        XCTAssertEqual(try autofill.remainingAttempts(), 9)
        XCTAssertEqual(try app.remainingAttempts(), 9, "both engines see one attempt count")
        _ = try autofill.unlock(password: password)
        XCTAssertEqual(try app.remainingAttempts(), 10)
    }
}

/// The file lock the app and AutoFill share (`KeychainStorage` uses it around every vault transaction).
final class FileLockTests: XCTestCase {
    private func temporaryPath() -> String { FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)").path }

    /// Two locks on one file stand for the app and the extension: the second waits until the first is given up.
    func testASecondHolderWaitsForTheFirst() {
        let path = temporaryPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let app = FileLock(path: path), autofill = FileLock(path: path)
        let held = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        var order = [String](), orderLock = NSLock()
        func note(_ step: String) { orderLock.lock(); order.append(step); orderLock.unlock() }
        DispatchQueue.global().async {
            app.run { note("app in"); held.signal(); Thread.sleep(forTimeInterval: 0.3); note("app out") }
            done.signal()
        }
        held.wait()
        autofill.run { note("autofill in") }
        done.wait()
        XCTAssertEqual(order, ["app in", "app out", "autofill in"])
    }

    func testItIsReentrantAndKeepsTheAppAliveOncePerHold() {
        let path = temporaryPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        var calls = [Bool]()
        let lock = FileLock(path: path) { calls.append($0) }
        let value = lock.run { lock.run { lock.run { 42 } } }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(calls, [true, false], "kept alive while held, released after the outermost")
        XCTAssertThrowsError(try lock.run { throw VaultError.locked })
        XCTAssertEqual(calls, [true, false, true, false], "released after an error too")
        // Released: another holder gets it at once.
        let other = FileLock(path: path), started = Date()
        other.run {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    /// Before the first unlock the file cannot be opened; the vault work still runs (nothing in it can be read then anyway).
    func testWorkRunsWhenTheFileCannotBeOpened() {
        let lock = FileLock(path: "/nonexistent-folder-\(UUID().uuidString)/lock")
        XCTAssertEqual(lock.run { 7 }, 7)
    }
}
