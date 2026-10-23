import XCTest
@testable import simStock3

final class YahooTradingDayFallbackTests: XCTestCase {
    private func date(_ value: String) -> Date {
        twDateTime.dateFromString(value, format: "yyyy/MM/dd HH:mm")!
    }

    func testOnlyCompleteValidatedRoundAfterOpeningGracePauses() {
        let now = date("2026/10/23 09:06"), previous = date("2026/10/22 13:30")
        func evaluate(_ stocks: [Date], market: Date? = nil, count: Int = 2,
                      time: Date? = nil, interrupted: Bool = false) -> YahooTradingDayFallback? {
            .evaluate(asOf: time ?? now, expectedStockCount: count, stockQuoteDates: stocks,
                      marketQuoteDate: market, previousTradingDay: previous, interrupted: interrupted)
        }
        XCTAssertNotNil(evaluate([previous, previous], market: previous))
        XCTAssertNil(evaluate([previous], market: previous)) // One request failed or was skipped.
        XCTAssertNil(evaluate([previous, now], market: previous))
        XCTAssertNil(evaluate([now, previous], market: previous)) // Later stale quote cannot override today's evidence.
        XCTAssertNil(evaluate([previous, previous], market: now)) // Individual halt is not closure.
        XCTAssertNil(evaluate([previous, previous])) // Index failure is not closure.
        XCTAssertNil(evaluate([], market: previous, count: 0))
        XCTAssertNil(evaluate([previous, previous], market: date("2026/10/21 13:30")))
        XCTAssertNil(evaluate([previous, previous], market: previous, time: date("2026/10/23 09:05")))
        XCTAssertNil(evaluate([previous, previous], market: previous, interrupted: true))
    }

    func testPauseIsOnlyForTaipeiObservationDay() {
        let pause = YahooTradingDayFallback(day: date("2026/10/23 00:00"))
        XCTAssertTrue(pause.applies(to: date("2026/10/23 23:59")))
        XCTAssertFalse(pause.applies(to: date("2026/10/24 00:00")))
        XCTAssertFalse(pause.applies(to: date("2026/10/22 23:59")))
    }

    func testPersistenceRestartManualClearAndOfficialCalendarRemainIndependent() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file.appendingPathExtension("yahoo-pause.json")) }
        let now = date("2026/10/23 10:00")
        let first = TWSETradingCalendar(fileURL: file)
        try await first.setYahooPause(.init(day: date("2026/10/23 00:00")))
        let reopened = TWSETradingCalendar(fileURL: file)
        let paused = await reopened.isYahooPaused(asOf: now)
        XCTAssertTrue(paused)
        let snapshot = TWSETradingCalendarSnapshot(version: 1, sourceURL: "mock", fetchedAt: now, year: 2026, entries: [])
        XCTAssertEqual(TWSETradingCalendar.status(for: now, snapshot: snapshot), .tradingDay)
        try await reopened.clearYahooPause()
        let cleared = await TWSETradingCalendar(fileURL: file).isYahooPaused(asOf: now)
        XCTAssertFalse(cleared)
    }

    func testFailedSaveCannotEnablePause() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("calendar.json")
        let calendar = TWSETradingCalendar(fileURL: missing)
        let now = date("2026/10/23 10:00")
        do {
            try await calendar.setYahooPause(.init(day: date("2026/10/23 00:00")))
            XCTFail("Missing parent must not save")
        } catch { }
        let paused = await calendar.isYahooPaused(asOf: now)
        XCTAssertFalse(paused)
    }
    func testGraceAndPauseUseTaipeiSecondsAcrossYearBoundary() {
        let previous = date("2026/12/31 13:30")
        let grace = date("2027/01/01 09:05")
        func evaluate(_ now: Date) -> YahooTradingDayFallback? {
            .evaluate(asOf: now, expectedStockCount: 1, stockQuoteDates: [previous],
                marketQuoteDate: previous, previousTradingDay: previous, interrupted: false)
        }
        XCTAssertNil(evaluate(grace))
        let pause = evaluate(grace.addingTimeInterval(0.001))
        XCTAssertNotNil(pause)
        let midnight = date("2027/01/02 00:00")
        XCTAssertEqual(pause?.applies(to: midnight.addingTimeInterval(-0.001)), true)
        XCTAssertEqual(pause?.applies(to: midnight), false)
    }

}
