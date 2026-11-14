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

    func testUnlockRecordsWhereTheTimeWent() throws {
        XCTAssertEqual(UnlockTiming(totalMilliseconds: 1500, hashingMilliseconds: 1200).description,
                       "Unlock took 1500 ms: password hashing 1200 ms, Keychain and files 300 ms")
    }
}
