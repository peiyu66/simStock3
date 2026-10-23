import XCTest
@testable import simStock3

nonisolated private final class CalendarDateTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

nonisolated private final class CalendarDateTestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payload = ""
    nonisolated(unsafe) private static var status = 500
    static func configure(status: Int, payload: String = "") {
        lock.lock(); defer { lock.unlock() }
        self.status = status; self.payload = payload
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let status = Self.status, payload = Self.payload
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

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
            TWSETradingCalendar.status(for: date(2026, 6, 19), snapshot: schedule),
            .closed
        )
    }

    func testExplicitTradingMarkersRemainTradingDays() {
        let schedule = snapshot([
            entry("農曆春節前最後交易日", "1150211"),
            entry("農曆春節後開始交易日", "1150223")
        ])
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 2, 11), snapshot: schedule),
            .tradingDay
        )
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 2, 23), snapshot: schedule),
            .tradingDay
        )
    }

    func testNoTradingSettlementDayIsClosed() {
        let schedule = snapshot([entry("市場無交易，僅辦理結算交割作業", "1150212")])
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 2, 12), snapshot: schedule),
            .closed
        )
    }

    func testWeekendIsClosedUnlessTWSEMarksMakeUpTradingDay() {
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 7, 18), snapshot: snapshot([])),
            .closed
        )
        let makeUp = snapshot([entry("補行交易日", "1150718")])
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 7, 18), snapshot: makeUp),
            .tradingDay
        )
    }

    func testWeekdayWithoutCurrentCalendarIsUnknown() {
        XCTAssertEqual(
            TWSETradingCalendar.status(for: date(2026, 7, 17), snapshot: nil),
            .unknown
        )
    }

    func testROCDateKeyUsesTaiwanYear() {
        XCTAssertEqual(
            TWSETradingCalendar.rocDateKey(for: date(2026, 7, 17)),
            "1150717"
        )
    }

    func testLatestCompletedTradingDayBeforeOpenIsPreviousTradingDay() {
        XCTAssertEqual(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 22, 8, 30),
                snapshot: snapshot([])
            ),
            date(2026, 7, 21)
        )
    }

    func testLatestCompletedTradingDayDuringMarketIsPreviousTradingDay() {
        XCTAssertEqual(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 22, 10, 0),
                snapshot: snapshot([])
            ),
            date(2026, 7, 21)
        )
    }

    func testLatestCompletedTradingDayAfterPublicationIsToday() {
        XCTAssertEqual(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 22, 15, 35),
                snapshot: snapshot([])
            ),
            date(2026, 7, 22)
        )
    }

    func testLatestCompletedTradingDayBeforeOfficialPublicationIsPreviousTradingDay() {
        XCTAssertEqual(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 22, 15, 34),
                snapshot: snapshot([])
            ),
            date(2026, 7, 21)
        )
    }

    func testLatestCompletedTradingDayOnClosedDaySkipsWeekend() {
        XCTAssertEqual(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 19, 10, 0),
                snapshot: snapshot([])
            ),
            date(2026, 7, 17)
        )
    }

    func testLatestCompletedTradingDayWithoutCalendarIsUnknown() {
        XCTAssertNil(
            TWSETradingCalendar.latestCompletedTradingDay(
                asOf: date(2026, 7, 22, 10, 0),
                snapshot: nil
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
    func testPublicationUsesExactTaipeiBoundaryAndMissingPreviousYearStaysUnknown() {
        let cutoff = date(2026, 7, 22, 15, 35)
        XCTAssertEqual(TWSETradingCalendar.latestCompletedTradingDay(
            asOf: cutoff.addingTimeInterval(-0.001), snapshot: snapshot([])), date(2026, 7, 21))
        XCTAssertEqual(TWSETradingCalendar.latestCompletedTradingDay(
            asOf: cutoff, snapshot: snapshot([])), date(2026, 7, 22))
        let newYear = TWSETradingCalendarSnapshot(version: 1, sourceURL: "fixture",
            fetchedAt: date(2027, 1, 1), year: 2027, entries: [entry("元旦", "1160101")])
        XCTAssertNil(TWSETradingCalendar.latestCompletedTradingDay(asOf: date(2027, 1, 1, 16), snapshot: newYear))
        XCTAssertNil(TWSETradingCalendar.latestCompletedTradingDay(asOf: date(2027, 1, 4, 8), snapshot: newYear))
        XCTAssertEqual(TWSETradingCalendar.latestCompletedTradingDay(
            asOf: date(2027, 1, 4, 15, 35), snapshot: newYear), date(2027, 1, 4))
    }

    func testCalendarDefaultDateUsesInjectedClockAndRejectsInvalidROCSourceDate() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarDateTestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        CalendarDateTestProtocol.configure(status: 200,
            payload: #"[{"Name":"元旦","Date":"1150101","Weekday":"","Description":""}]"#)
        let now = date(2026, 7, 22, 15, 35)
        let clock = CalendarDateTestClock(now)
        let service = TWSETradingCalendar(fileURL: file, session: session, clock: { clock.now() })
        let first = await service.decision()
        XCTAssertEqual(first.status, .tradingDay)
        XCTAssertEqual(first.requestCount, 1)
        let latest = await service.latestCompletedTradingDay()
        XCTAssertEqual(latest, date(2026, 7, 22))
        let saved = await service.cachedSnapshot()
        XCTAssertEqual(saved?.fetchedAt, now, "Event time is the supplied absolute instant")

        clock.set(now.addingTimeInterval(24 * 60 * 60))
        CalendarDateTestProtocol.configure(status: 200,
            payload: #"[{"Name":"壞日期","Date":"1150230","Weekday":"","Description":""}]"#)
        let invalid = await service.decision()
        XCTAssertEqual(invalid.status, .unknown)
        XCTAssertNotNil(invalid.refreshError)
        let afterInvalid = await service.cachedSnapshot()
        XCTAssertEqual(afterInvalid, saved)
    }

    func testClockRollbackDoesNotExtendRefreshBackoffOrTrustFutureSnapshot() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarDateTestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        CalendarDateTestProtocol.configure(status: 500)
        let initial = date(2026, 7, 22, 16)
        let clock = CalendarDateTestClock(initial)
        let service = TWSETradingCalendar(fileURL: file, session: session, clock: { clock.now() })
        let first = await service.decision()
        let backedOff = await service.decision()
        XCTAssertEqual(first.requestCount, 1)
        XCTAssertEqual(backedOff.requestCount, 0)
        clock.set(initial.addingTimeInterval(-1))
        let rollback = await service.decision()
        XCTAssertEqual(rollback.requestCount, 1)
        clock.set(initial.addingTimeInterval(3599))
        let boundary = await service.decision()
        XCTAssertEqual(boundary.requestCount, 1)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TWSETradingCalendarSnapshot(version: 1, sourceURL: "fixture",
            fetchedAt: initial.addingTimeInterval(60), year: 2026, entries: [])).write(to: file)
        let future = TWSETradingCalendar(fileURL: file, session: session, clock: { initial })
        let latest = await future.latestCompletedTradingDay()
        let provisional = await future.provisionalSnapshot(for: initial)
        let needsRefresh = await future.needsRefreshWait(for: initial)
        XCTAssertNil(latest)
        XCTAssertNil(provisional)
        XCTAssertTrue(needsRefresh)
    }

}
