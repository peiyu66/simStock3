import XCTest
@testable import simStock3

final class DiagnosticMessageTests: XCTestCase {
    func testNormalTimerInvalidationIsBenign() {
        XCTAssertTrue(simLog.isBenignTimerLifecycleMessage("timer invalidated."))
        XCTAssertTrue(simLog.isBenignTimerLifecycleMessage(" TIMER INVALIDATED.\n"))
    }

    func testUnexpectedTimerInvalidationMessageIsNotHidden() {
        XCTAssertFalse(
            simLog.isBenignTimerLifecycleMessage("timer invalidated unexpectedly.")
        )
    }
}
