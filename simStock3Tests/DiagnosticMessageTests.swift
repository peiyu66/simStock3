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

    func testLaterYahooSuccessCanRecoverMatchingConnectivityFailure() {
        let failedAt = Date(timeIntervalSince1970: 1_000)
        let recoveredAt = Date(timeIntervalSince1970: 2_000)
        let event = DiagnosticEvent(
            id: UUID(),
            date: failedAt,
            source: .yahoo,
            severity: .error,
            category: .connectivity,
            stockID: "2317",
            message: "2317 yahoo：The request timed out.",
            recoveredAt: nil
        )

        XCTAssertTrue(
            simLog.shouldMarkRecovered(
                event,
                source: .yahoo,
                stockID: "2317",
                at: recoveredAt
            )
        )
    }

    func testRecoveryDoesNotCrossStocksOrResolveParsingFailures() {
        let failedAt = Date(timeIntervalSince1970: 1_000)
        let recoveredAt = Date(timeIntervalSince1970: 2_000)
        let parsingEvent = DiagnosticEvent(
            id: UUID(),
            date: failedAt,
            source: .yahoo,
            severity: .error,
            category: .parsing,
            stockID: "2317",
            message: "2317 yahoo：解析無交易資料。",
            recoveredAt: nil
        )

        XCTAssertFalse(
            simLog.shouldMarkRecovered(
                parsingEvent,
                source: .yahoo,
                stockID: "2317",
                at: recoveredAt
            )
        )

        let connectivityEvent = DiagnosticEvent(
            id: UUID(),
            date: failedAt,
            source: .yahoo,
            severity: .error,
            category: .connectivity,
            stockID: "2308",
            message: "2308 yahoo：The request timed out.",
            recoveredAt: nil
        )
        XCTAssertFalse(
            simLog.shouldMarkRecovered(
                connectivityEvent,
                source: .yahoo,
                stockID: "2317",
                at: recoveredAt
            )
        )
    }

    func testStoredEventWithoutRecoveryFieldStillDecodes() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","date":1000,"source":"Yahoo","severity":"error","category":"連線","stockID":"2317","message":"timed out"}"#
        let event = try JSONDecoder().decode(DiagnosticEvent.self, from: Data(json.utf8))

        XCTAssertEqual(event.stockID, "2317")
        XCTAssertNil(event.recoveredAt)
    }
}
