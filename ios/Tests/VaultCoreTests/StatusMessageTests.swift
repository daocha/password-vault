import XCTest
@testable import VaultCore

final class StatusMessageTests: XCTestCase {
    func testShowsUntilDismissed() {
        var status = StatusMessage()
        XCTAssertFalse(status.isShowing)
        status.show("Decoy vault removed.", error: false)
        XCTAssertTrue(status.isShowing)
        XCTAssertEqual(status.text, "Decoy vault removed.")
        XCTAssertFalse(status.isError)
        status.dismiss()
        XCTAssertFalse(status.isShowing)
        XCTAssertFalse(status.isError)
    }

    func testExpiryHidesOnlyTheMessageItWasStartedFor() {
        var status = StatusMessage()
        let first = status.show("Unlock took 300 ms", error: false)
        let second = status.show("Unlock took 300 ms", error: false)
        XCTAssertNotEqual(first, second, "showing the same text again restarts its time")
        status.expire(first)
        XCTAssertTrue(status.isShowing, "the first timer must not hide the message shown again")
        status.expire(second)
        XCTAssertFalse(status.isShowing)
    }

    func testExpiryAfterDismissOrNewMessageChangesNothing() {
        var status = StatusMessage()
        let old = status.show("Wrong password", error: true)
        status.dismiss()
        let newer = status.show("Camera access is needed", error: true)
        status.expire(old)
        XCTAssertEqual(status.text, "Camera access is needed")
        XCTAssertTrue(status.isError)
        XCTAssertNotEqual(old, newer)
    }

    func testErrorsAreMarkedAndEmptyTextClosesTheMessage() {
        var status = StatusMessage()
        status.show("Wrong password", error: true)
        XCTAssertTrue(status.isError)
        status.show("", error: true)
        XCTAssertFalse(status.isShowing)
        XCTAssertFalse(status.isError)
    }

    func testDisplayTimeMatchesAndroid() {
        XCTAssertEqual(StatusMessage.displaySeconds, 6)
    }

    func testScreenReadersKeepMessagesUntilOK() {
        XCTAssertNil(StatusMessage.displayTime(assistiveTechnology: true))
        XCTAssertEqual(StatusMessage.displayTime(assistiveTechnology: false), 6)
    }
}
