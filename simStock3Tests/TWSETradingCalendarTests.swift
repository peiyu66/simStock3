import XCTest
@testable import simStock3

final class TWSETradingCalendarTests: XCTestCase {
    func testMigrationWarningSessionStaysAcknowledgedAcrossBoundedBatches() {
        var session = MigrationWarningSession()

        session.acknowledge()
        session.finishBatch(hasPendingMigration: true)
        XCTAssertTrue(session.isAcknowledged)

        session.finishBatch(hasPendingMigration: false)
        XCTAssertFalse(session.isAcknowledged)
    }

    func testPriceUpdateLifecycleWaitsUntilSceneAndStocksAreReady() {
        var gate = PriceUpdateLifecycleGate()

        XCTAssertEqual(
            gate.actionWhenReady(isSceneActive: false, hasStocks: false),
            .none
        )
        XCTAssertEqual(
            gate.actionWhenReady(isSceneActive: false, hasStocks: true),
            .none
        )
        XCTAssertEqual(
            gate.actionWhenReady(isSceneActive: true, hasStocks: true),
            .initial
        )
        XCTAssertEqual(
            gate.actionWhenReady(isSceneActive: true, hasStocks: true),
            .none
        )
    }

    func testPriceUpdateLifecycleResumesOnceAfterReturningToForeground() {
        var gate = PriceUpdateLifecycleGate()
        XCTAssertEqual(
            gate.actionWhenReady(isSceneActive: true, hasStocks: true),
            .initial
        )

        gate.markBackground()
        XCTAssertEqual(
            gate.actionWhenReady(isSceneActive: false, hasStocks: true),
            .none
        )
        XCTAssertEqual(
            gate.actionWhenReady(isSceneActive: true, hasStocks: true),
            .resume
        )
        XCTAssertEqual(
            gate.actionWhenReady(isSceneActive: true, hasStocks: true),
            .none
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func entry(_ name: String, _ rocDate: String) -> TWSEHolidayEntry {
        TWSEHolidayEntry(name: name, date: rocDate, weekday: "", description: "")
    }

    private func snapshot(_ entries: [TWSEHolidayEntry]) -> TWSETradingCalendarSnapshot {
        TWSETradingCalendarSnapshot(
            version: TWSETradingCalendarSnapshot.currentVersion,
            sourceURL: TWSETradingCalendar.sourceURL.absoluteString,
            fetchedAt: Date(),
            year: 2026,
            entries: entries
        )
    }

    func testOfficialHolidayIsClosed() {
        let schedule = snapshot([entry("端午節", "1150619")])
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 6, 19), snapshot: schedule, calendar: calendar),
            .closed
        )
    }

    func testExplicitTradingMarkersRemainTradingDays() {
        let schedule = snapshot([
            entry("農曆春節前最後交易日", "1150211"),
            entry("農曆春節後開始交易日", "1150223")
        ])
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 2, 11), snapshot: schedule, calendar: calendar),
            .tradingDay
        )
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 2, 23), snapshot: schedule, calendar: calendar),
            .tradingDay
        )
    }

    func testNoTradingSettlementDayIsClosed() {
        let schedule = snapshot([entry("市場無交易，僅辦理結算交割作業", "1150212")])
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 2, 12), snapshot: schedule, calendar: calendar),
            .closed
        )
    }

    func testWeekendIsClosedUnlessTWSEMarksMakeUpTradingDay() {
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 7, 18), snapshot: snapshot([]), calendar: calendar),
            .closed
        )
        let makeUp = snapshot([entry("補行交易日", "1150718")])
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 7, 18), snapshot: makeUp, calendar: calendar),
            .tradingDay
        )
    }

    func testWeekdayWithoutCurrentCalendarIsUnknown() {
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 7, 17), snapshot: nil, calendar: calendar),
            .unknown
        )
    }

    func testROCDateKeyUsesTaiwanYear() {
        XCTAssertEqual(
            TWSETradingCalendar.rocDateKey(for: date(2026, 7, 17), calendar: calendar),
            "1150717"
        )
    }

    func testLatestCompletedTradingDayBeforeOpenIsPreviousTradingDay() {
        XCTAssertEqual(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 22, 8, 30),
                snapshot: snapshot([]),
                calendar: calendar
            ),
            date(2026, 7, 21)
        )
    }

    func testLatestCompletedTradingDayDuringMarketIsPreviousTradingDay() {
        XCTAssertEqual(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 22, 10, 0),
                snapshot: snapshot([]),
                calendar: calendar
            ),
            date(2026, 7, 21)
        )
    }

    func testLatestCompletedTradingDayAfterPublicationIsToday() {
        XCTAssertEqual(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 22, 15, 35),
                snapshot: snapshot([]),
                calendar: calendar
            ),
            date(2026, 7, 22)
        )
    }

    func testLatestCompletedTradingDayBeforeOfficialPublicationIsPreviousTradingDay() {
        XCTAssertEqual(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 22, 15, 34),
                snapshot: snapshot([]),
                calendar: calendar
            ),
            date(2026, 7, 21)
        )
    }

    func testLatestCompletedTradingDayOnClosedDaySkipsWeekend() {
        XCTAssertEqual(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 19, 10, 0),
                snapshot: snapshot([]),
                calendar: calendar
            ),
            date(2026, 7, 17)
        )
    }

    func testLatestCompletedTradingDayWithoutCalendarIsUnknown() {
        XCTAssertNil(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 22, 10, 0),
                snapshot: nil,
                calendar: calendar
            )
        )
    }

    func testYahooPolicyRequestsOnlyWhenUseful() {
        XCTAssertFalse(DailyPriceUpdatePolicy.shouldRequestYahoo(
            marketStatus: .tradingDay,
            asOf: date(2026, 7, 22, 8, 30),
            hasOfficialDataForToday: false,
            lastSuccessfulCloseRefresh: nil,
            calendar: calendar
        ))
        XCTAssertTrue(DailyPriceUpdatePolicy.shouldRequestYahoo(
            marketStatus: .tradingDay,
            asOf: date(2026, 7, 22, 10, 0),
            hasOfficialDataForToday: false,
            lastSuccessfulCloseRefresh: nil,
            calendar: calendar
        ))
        XCTAssertFalse(DailyPriceUpdatePolicy.shouldRequestYahoo(
            marketStatus: .tradingDay,
            asOf: date(2026, 7, 22, 14, 0),
            hasOfficialDataForToday: true,
            lastSuccessfulCloseRefresh: nil,
            calendar: calendar
        ))
        XCTAssertTrue(DailyPriceUpdatePolicy.shouldRequestYahoo(
            marketStatus: .tradingDay,
            asOf: date(2026, 7, 22, 14, 0),
            hasOfficialDataForToday: false,
            lastSuccessfulCloseRefresh: nil,
            calendar: calendar
        ))
        XCTAssertTrue(DailyPriceUpdatePolicy.shouldRequestYahoo(
            marketStatus: .tradingDay,
            asOf: date(2026, 7, 22, 14, 0),
            hasOfficialDataForToday: false,
            lastSuccessfulCloseRefresh: date(2026, 7, 22, 13, 29),
            calendar: calendar
        ))
        XCTAssertFalse(DailyPriceUpdatePolicy.shouldRequestYahoo(
            marketStatus: .tradingDay,
            asOf: date(2026, 7, 22, 14, 0),
            hasOfficialDataForToday: false,
            lastSuccessfulCloseRefresh: date(2026, 7, 22, 13, 31),
            calendar: calendar
        ))
        XCTAssertTrue(DailyPriceUpdatePolicy.shouldRequestYahoo(
            marketStatus: .tradingDay,
            asOf: date(2026, 7, 22, 14, 0),
            hasOfficialDataForToday: false,
            lastSuccessfulCloseRefresh: date(2026, 7, 21, 13, 31),
            calendar: calendar
        ))
        XCTAssertFalse(DailyPriceUpdatePolicy.shouldRequestYahoo(
            marketStatus: .closed,
            asOf: date(2026, 7, 19, 10, 0),
            hasOfficialDataForToday: false,
            lastSuccessfulCloseRefresh: nil,
            calendar: calendar
        ))
    }
}
