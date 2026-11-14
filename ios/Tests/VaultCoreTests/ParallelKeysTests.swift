import Foundation
import XCTest
@testable import VaultCore

final class ParallelKeysTests: XCTestCase {
    private struct OutOfMemory: Error {}

    func testBothDerivationsRunAtTheSameTime() throws {
        // Each side waits for the other: run one after the other, they would time out instead.
        let mainStarted = DispatchSemaphore(value: 0), sideStarted = DispatchSemaphore(value: 0)
        let (a, b) = try bothKeys({
            mainStarted.signal(); guard sideStarted.wait(timeout: .now() + 5) == .success else { throw OutOfMemory() }; return Data([1])
        }, {
            sideStarted.signal(); guard mainStarted.wait(timeout: .now() + 5) == .success else { throw OutOfMemory() }; return nil
        })
        XCTAssertEqual(a, Data([1])); XCTAssertNil(b)
    }

    func testADerivationThatRanShortOfMemoryRunsAgainAlone() throws {
        var mainRuns = 0, sideRuns = 0
        let (a, b) = try bothKeys({ mainRuns += 1; if mainRuns == 1 { throw OutOfMemory() }; return Data([1]) },
                                  { sideRuns += 1; if sideRuns == 1 { throw OutOfMemory() }; return Data([2]) })
        XCTAssertEqual(a, Data([1])); XCTAssertEqual(b, Data([2])); XCTAssertEqual(mainRuns, 2); XCTAssertEqual(sideRuns, 2)
    }

    func testWhenOneKeepsFailingThePairFails() {
        XCTAssertThrowsError(try bothKeys({ throw OutOfMemory() }, { Data([7]) }))
        XCTAssertThrowsError(try bothKeys({ Data([9]) }, { throw OutOfMemory() }))
    }

    /// The key that was derived is wiped in place, not a copy of it, when the other derivation keeps failing.
    func testWhenThePairFailsTheOtherKeysOwnBytesAreWiped() {
        for mainFails in [true, false] {
            // The key's bytes live in a buffer the test owns, so the test can see whether they were zeroed.
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 1); defer { buffer.deallocate() }
            memset(buffer, 0xAB, 32)
            let key: () throws -> Data? = { Data(bytesNoCopy: buffer, count: 32, deallocator: .none) }
            let failing: () throws -> Data? = { throw OutOfMemory() }
            XCTAssertThrowsError(try mainFails ? bothKeys(failing, key) : bothKeys(key, failing))
            XCTAssertTrue((0..<32).allSatisfy { buffer.load(fromByteOffset: $0, as: UInt8.self) == 0 }, "key bytes wiped (main fails: \(mainFails))")
        }
    }

    func testWipeZeroesTheKeyItselfAndDropsIt() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 1); defer { buffer.deallocate() }
        memset(buffer, 0xCD, 32)
        var key: Data? = Data(bytesNoCopy: buffer, count: 32, deallocator: .none)
        wipe(&key)
        XCTAssertNil(key)
        XCTAssertTrue((0..<32).allSatisfy { buffer.load(fromByteOffset: $0, as: UInt8.self) == 0 })
    }

    func testUnlockRecordsWhereTheTimeWent() throws {
        XCTAssertEqual(UnlockTiming(totalMilliseconds: 1500, hashingMilliseconds: 1100, stateMilliseconds: 300, stateReads: 3, stateWrites: 2).description,
                       "Password unlock 1500 ms: password hashing 1100 ms, protected state 300 ms (3 reads, 2 writes, key in Keychain), vault file 100 ms")
        XCTAssertEqual(UnlockTiming(biometric: true, totalMilliseconds: 400, biometricMilliseconds: 150, stateMilliseconds: 200, stateReads: 2).description,
                       "Biometric unlock 400 ms: biometric key 150 ms, protected state 200 ms (2 reads, 0 writes, key in Keychain), vault file 50 ms")
    }
}
