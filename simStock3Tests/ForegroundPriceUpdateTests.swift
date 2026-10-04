import Foundation
import SwiftData
import XCTest
@testable import simStock3

nonisolated private final class UpdateURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var delay: TimeInterval = 0

    static func configure(_ values: [String: (Int, String)], delay: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        responses = values.mapValues { ($0.0, Data($0.1.utf8)) }
        paths = []; self.delay = delay
    }
    static var requestedPaths: [String] {
        lock.lock(); defer { lock.unlock() }; return paths
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let path = request.url!.path
        Self.paths.append(path)
        let reply = Self.responses[path]
        let delay = Self.delay
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard let reply else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.1)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class ForegroundPriceUpdateTests: XCTestCase {
    private let calendarPath = "/v1/holidaySchedule/holidaySchedule"
    private let ordinaryCalendar = "[{\"Name\":\"元旦\",\"Date\":\"1150101\",\"Weekday\":\"\",\"Description\":\"\"}]"
    private func date(_ value: String) -> Date {
        twDateTime.dateFromString(value, format: "yyyy/MM/dd HH:mm")!
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateURLProtocol.self]
        return URLSession(configuration: config)
    }
    private func calendar(now: Date, age: TimeInterval = 0, year: Int = 2026,
                          session: URLSession) throws -> (TWSETradingCalendar, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TWSETradingCalendarSnapshot(version: 1, sourceURL: "mock", fetchedAt: now.addingTimeInterval(-age),
            year: year, entries: [])).write(to: file)
        return (TWSETradingCalendar(fileURL: file, session: session, clock: { now }), file)
    }
    private func fixture(calendar: TWSETradingCalendar, session: URLSession,
                         lastStockDay: String = "2026/10/02 13:30") throws -> (ModelContainer, simObject, Stock) {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let stock = Stock(sId: "TEST", sName: "測試", group: "A",
            dateFirst: date("2025/10/01 00:00"), dateStart: date("2026/10/01 00:00"))
        context.insert(stock)
        for value in ["2025/10/01 13:30", lastStockDay] {
            let trade = Trade(stock: stock, dateTime: date(value))
            trade.priceClose = 100; trade.priceOpen = 100; trade.priceHigh = 101; trade.priceLow = 99
            trade.dataSource = "TWSE"
            context.insert(trade)
        }
        stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
        stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
        for value in ["2025/10/01 13:30", "2026/10/02 13:30"] {
            context.insert(MarketDay(dateTime: date(value), indexOpen: 100, indexHigh: 101, indexLow: 99, indexClose: 100))
        }
        try context.save()
        try MarketDataStore(modelContext: context).rebuildPricePath()
        return (container, simObject(modelContext: context, tradingCalendar: calendar, marketSession: session), stock)
    }

    func testKnownWeekendCompleteInputsUseOneReadPerSourceAndNoNetworkOrLookupRebuild() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([:])
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        for _ in 0..<2 { // Foreground resume gets a new session; no persistent no-work shortcut.
            var messages: [String] = []
            let result = await sim.updateTWSEPrices(stocks: [stock], asOf: now, onProgress: { messages.append($0) })
            XCTAssertFalse(messages.contains { $0.contains("確認交易日曆") })
            XCTAssertEqual(result.marketDayStatus, .closed)
            XCTAssertEqual(result.expectedCompletedTradingDay, date("2026/10/02 00:00"))
            XCTAssertEqual(result.requestedMonths, 0)
            XCTAssertEqual(result.market.requestedMonths, 0)
            XCTAssertTrue(result.market.isReadyForSimulation)
            XCTAssertTrue(result.realtimeBlockedStockIDs.isEmpty)
            XCTAssertEqual(result.timings.stockHistoryReads, 1)
            XCTAssertEqual(result.timings.marketHistoryReads, 1)
            XCTAssertEqual(result.timings.marketLookupReloads, 0)
        }
        XCTAssertTrue(UpdateURLProtocol.requestedPaths.isEmpty)
        XCTAssertEqual(try Trade.fetch(in: container.mainContext, for: stock).count, 2)
    }

    func testMissingOfficialStockStillRequestsAndFailureCannotBecomeComplete() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure(["/exchangeReport/STOCK_DAY": (200, "{\"stat\":\"not ready\"}")])
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session, lastStockDay: "2026/10/01 13:30")
        let yahoo = Trade(stock: stock, dateTime: date("2026/10/02 13:30"))
        yahoo.dataSource = "Yahoo"; yahoo.priceClose = 100
        container.mainContext.insert(yahoo); try container.mainContext.save()
        let result = await sim.updateTWSEPrices(stocks: [stock], asOf: now)
        XCTAssertEqual(result.requestedMonths, 1)
        XCTAssertEqual(result.failedMonths, 1)
        XCTAssertTrue(result.realtimeBlockedStockIDs.contains(stock.sId))
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, ["/exchangeReport/STOCK_DAY"])
    }

    func testExpiredCalendarIsRefreshedBeforePlanningNewTradingDay() async throws {
        let now = date("2026/10/04 16:00"), session = session()
        let special = "[{\"Name\":\"補行交易\",\"Date\":\"1151004\",\"Weekday\":\"\",\"Description\":\"\"}]"
        UpdateURLProtocol.configure([calendarPath: (200, special)])
        let (calendar, file) = try calendar(now: now, age: 86_401, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let decision = await calendar.decision(for: now)
        let completed = await calendar.latestCompletedTradingDay(asOf: now)
        XCTAssertEqual(decision.status, .tradingDay)
        XCTAssertEqual(decision.requestCount, 1)
        XCTAssertEqual(completed, date("2026/10/04 00:00"))
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
    }

    func testExpiredCalendarFailureAndRetryThrottleRemainUnknown() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([calendarPath: (503, "unavailable")])
        let (calendar, file) = try calendar(now: now, age: 86_401, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let failed = await calendar.decision(for: now)
        let retried = await calendar.decision(for: now)
        let completed = await calendar.latestCompletedTradingDay(asOf: now)
        XCTAssertNotNil(failed.refreshError)
        XCTAssertEqual(failed.status, .unknown)
        XCTAssertEqual(retried.status, .unknown)
        XCTAssertNil(completed)
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
    }

    func testConcurrentCalendarCallersAwaitSameRefresh() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([calendarPath: (200, ordinaryCalendar)], delay: 0.1)
        let (calendar, file) = try calendar(now: now, age: 86_401, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        async let first = calendar.decision(for: now)
        async let second = calendar.decision(for: now)
        let values = await [first, second]
        XCTAssertTrue(values.allSatisfy { $0.refreshed && $0.status == .closed })
        XCTAssertEqual(values.reduce(0) { $0 + $1.requestCount }, 1)
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
    }

    func testCrossYearRefreshRejectsPreviousYearResponse() async throws {
        let now = date("2027/01/01 08:59"), session = session()
        UpdateURLProtocol.configure([calendarPath: (200, ordinaryCalendar)])
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let result = await calendar.decision(for: now)
        XCTAssertEqual(result.status, .unknown)
        XCTAssertNotNil(result.refreshError)
        let completed = await calendar.latestCompletedTradingDay(asOf: now)
        XCTAssertNil(completed)
    }

    func testReadSessionSeesDirtyAndVersionChangesAndInvalidatesInsertedRows() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let reads = OfficialPriceReadSession(context: container.mainContext)
        XCTAssertTrue(sim.tech.stocksRequiringRecalculation(in: [stock], readSession: reads).isEmpty)
        stock.simulationDirtyFrom = date("2026/10/01 00:00")
        XCTAssertEqual(sim.tech.stocksRequiringRecalculation(in: [stock], readSession: reads).count, 1)
        stock.simulationDirtyFrom = nil; stock.simulationStateVersion = 0
        XCTAssertEqual(sim.tech.stocksRequiringRecalculation(in: [stock], readSession: reads).count, 1)
        XCTAssertEqual(reads.stockHistoryReads, 1)
        let trade = Trade(stock: stock, dateTime: now)
        container.mainContext.insert(trade)
        reads.invalidateStock(stock)
        XCTAssertEqual(try reads.stockTrades(stock).count, 3)
        XCTAssertEqual(reads.stockHistoryReads, 2)
        reads.invalidateAll()
        XCTAssertEqual(try reads.stockTrades(stock).count, 3)
        XCTAssertEqual(reads.stockHistoryReads, 3)
    }

    func testMarketRevisionInvalidatesCoverageAndDirtyFlagsWithoutStockRefetch() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let reads = OfficialPriceReadSession(context: container.mainContext)
        let store = MarketDataStore(modelContext: container.mainContext, session: session)
        XCTAssertTrue(sim.tech.stocksRequiringRecalculation(in: [stock], readSession: reads).isEmpty)
        _ = try reads.marketDays()
        let record = MarketDataStore.Record(date: date("2026/10/02 13:30"), open: 100, high: 102, low: 99, close: 101)
        XCTAssertEqual(try store.applyOfficialRecords([record], readSession: reads), 1)
        let plan = try XCTUnwrap(store.inputPlan(stocks: [stock], through: date("2026/10/02 00:00"), readSession: reads))
        XCTAssertTrue(plan.requiresTechnicalRebuild)
        XCTAssertEqual(sim.tech.stocksRequiringRecalculation(in: [stock], readSession: reads).count, 1)
        XCTAssertEqual(reads.stockHistoryReads, 1)
        XCTAssertEqual(reads.marketHistoryReads, 2)
        XCTAssertEqual(try store.applyOfficialRecords([record], readSession: reads), 0)
        _ = try reads.marketDays()
        XCTAssertEqual(reads.marketHistoryReads, 2)
    }
    func testTaipeiCutoffsAndPreopenUseAbsoluteInstantsAcrossTimezones() async throws {
        let session = session()
        let now = date("2026/10/05 08:59")
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        // UTC 00:59 is Taipei 08:59, independently of the device timezone.
        let formatter = ISO8601DateFormatter()
        let utc = try XCTUnwrap(formatter.date(from: "2026-10-05T00:59:00Z"))
        XCTAssertEqual(utc, now)
        for (time, expected) in [("2026/10/05 08:59", "2026/10/02 00:00"),
                                 ("2026/10/05 09:00", "2026/10/02 00:00"),
                                 ("2026/10/05 15:34", "2026/10/02 00:00"),
                                 ("2026/10/05 15:35", "2026/10/05 00:00")] {
            let completed = await calendar.latestCompletedTradingDay(asOf: date(time))
            XCTAssertEqual(completed, date(expected))
        }
        XCTAssertFalse(DailyPriceUpdatePolicy.shouldRequestYahoo(marketStatus: .tradingDay,
            asOf: utc, hasOfficialDataForToday: false, lastSuccessfulCloseRefresh: nil,
            calendar: twDateTime.calendar))
        XCTAssertTrue(DailyPriceUpdatePolicy.shouldRequestYahoo(marketStatus: .tradingDay,
            asOf: utc.addingTimeInterval(60), hasOfficialDataForToday: false, lastSuccessfulCloseRefresh: nil,
            calendar: twDateTime.calendar))
    }

    func testLongHolidayAndMissingCalendarStayConservative() async throws {
        let snapshot = TWSETradingCalendarSnapshot(version: 1, sourceURL: "mock", fetchedAt: Date(), year: 2026,
            entries: ["1151005", "1151006"].map {
                TWSEHolidayEntry(name: "休市", date: $0, weekday: "", description: "")
            })
        XCTAssertEqual(TWSETradingCalendar.latestCompletedTradingDay(asOf: date("2026/10/06 16:00"),
            snapshot: snapshot), date("2026/10/02 00:00"))
        XCTAssertNil(TWSETradingCalendar.latestCompletedTradingDay(asOf: date("2026/10/06 16:00"), snapshot: nil))
    }

    func testExpiredCalendarReplansPipelineAfterHolidayCorrection() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        let holiday = "[{\"Name\":\"休市\",\"Date\":\"1151002\",\"Weekday\":\"\",\"Description\":\"\"}]"
        UpdateURLProtocol.configure([calendarPath: (200, holiday)])
        let (calendar, file) = try calendar(now: now, age: 86_401, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session, lastStockDay: "2026/10/01 13:30")
        let result = await sim.updateTWSEPrices(stocks: [stock], asOf: now)
        XCTAssertEqual(result.expectedCompletedTradingDay, date("2026/10/01 00:00"))
        XCTAssertEqual(result.requestedMonths, 0)
        XCTAssertEqual(result.timings.calendarRequests, 1)
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
        _ = container
    }

    func testNewStockIsNotHiddenByCompleteExistingStock() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure(["/exchangeReport/STOCK_DAY": (200, "{\"stat\":\"not ready\"}")])
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let newStock = Stock(sId: "NEW", sName: "新股", group: "A", dateFirst: now, dateStart: now)
        container.mainContext.insert(newStock); try container.mainContext.save()
        let result = await sim.updateTWSEPrices(stocks: [stock, newStock], asOf: now)
        XCTAssertEqual(result.requestedMonths, 1)
        XCTAssertEqual(result.failedMonths, 1)
        XCTAssertTrue(result.realtimeBlockedStockIDs.contains("NEW"))
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, ["/exchangeReport/STOCK_DAY"])
    }

    func testSuccessfulStockAppendInvalidatesReadSessionBeforeRecalculation() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        let body = "{\"stat\":\"OK\",\"data\":[[\"115/10/02\",\"0\",\"0\",\"100\",\"101\",\"99\",\"100\"]]}"
        UpdateURLProtocol.configure(["/exchangeReport/STOCK_DAY": (200, body)])
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session, lastStockDay: "2026/10/01 13:30")
        let result = await sim.updateTWSEPrices(stocks: [stock], asOf: now)
        XCTAssertEqual(result.requestedMonths, 1)
        XCTAssertEqual(result.failedMonths, 0)
        XCTAssertEqual(result.timings.stockHistoryReads, 2)
        XCTAssertEqual(sim.tech.officialPriceRevision, 1)
        let latest = try XCTUnwrap(Trade.fetch(in: container.mainContext, for: stock, TWSE: true, ascending: false).first)
        XCTAssertEqual(latest.dateTime, date("2026/10/02 13:30"))
        XCTAssertNil(stock.technicalDirtyFrom)
        XCTAssertNil(stock.simulationDirtyFrom)
        let next = await sim.updateTWSEPrices(stocks: [stock], asOf: now)
        XCTAssertEqual(next.requestedMonths, 0)
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, ["/exchangeReport/STOCK_DAY"])
    }

    func testPendingMarketRebuildRefreshesLookupOnceThenReusesIt() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([:])
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let day = try XCTUnwrap(MarketDay.fetchAll(in: container.mainContext).last)
        day.technicalStateVersion = 0
        let first = await sim.updateTWSEPrices(stocks: [stock], asOf: now)
        XCTAssertTrue(first.market.isReadyForSimulation)
        XCTAssertEqual(first.timings.marketLookupReloads, 1)
        let second = await sim.updateTWSEPrices(stocks: [stock], asOf: now)
        XCTAssertEqual(second.timings.marketLookupReloads, 0)
        XCTAssertTrue(UpdateURLProtocol.requestedPaths.isEmpty)
    }

    func testDailyWeekendPipelineSkipsYahooAndProducesDiagnostics() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([:])
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let result = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        XCTAssertEqual(result.yahoo.requestedStocks, 0)
        XCTAssertFalse(result.yahoo.marketUpdated)
        XCTAssertEqual(result.twse.timings.calendarRequests, 0)
        XCTAssertEqual(result.twse.timings.stockHistoryReads, 1)
        XCTAssertGreaterThanOrEqual(result.twse.timings.totalSeconds, result.twse.timings.officialSeconds)
        XCTAssertTrue(UpdateURLProtocol.requestedPaths.isEmpty)
        _ = container
    }

    func testDiagnosticSnapshotRemainsCompatibleWithOlderSavedData() async throws {
        let snapshot = PriceUpdateDiagnosticSnapshot(completedAt: date("2026/10/04 10:00"), statusText: "test",
            expectedTradingDate: nil, marketStatus: "休市", twseRequestedMonths: 0, twseFailedMonths: 0, twsePendingHistoryMonths: nil,
            yahooRequestedStocks: 0, yahooUpdatedStocks: 0, yahooSuccessfulStocks: 0, yahooSkippedStocks: 0)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertNil(try JSONDecoder().decode(PriceUpdateDiagnosticSnapshot.self, from: data).timings)
        var updated = snapshot
        updated.timings = PriceUpdateTimings(calendarSeconds: 0.25, calendarRequests: 1, stockHistoryReads: 10)
        let roundTrip = try JSONDecoder().decode(PriceUpdateDiagnosticSnapshot.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(roundTrip.timings?.calendarRequests, 1)
        XCTAssertTrue(roundTrip.timings!.diagnosticText.contains("0.250s"))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for isolated state transition")
    }

    func testExpiredWeekendPreflightUsesNoNetworkAndRejectsMissingOrDirtyInputs() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([:])
        let (calendar, file) = try calendar(now: now, age: 90_000, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let provisional = await sim.provisionalNoPriceWork(asOf: now)
        XCTAssertEqual(provisional?.expectedCompletedTradingDay, date("2026/10/02 00:00"))
        XCTAssertEqual(provisional?.stockHistoryReads, 1)
        XCTAssertEqual(provisional?.marketHistoryReads, 1)
        XCTAssertTrue(UpdateURLProtocol.requestedPaths.isEmpty)
        stock.simulationDirtyFrom = now
        let dirty = await sim.provisionalNoPriceWork(asOf: now)
        XCTAssertNil(dirty)
        stock.simulationDirtyFrom = nil
        let last = try XCTUnwrap(Trade.fetch(in: container.mainContext, for: stock, ascending: true).last)
        last.dataSource = "Yahoo"
        let missing = await sim.provisionalNoPriceWork(asOf: now)
        XCTAssertNil(missing)
        XCTAssertTrue(UpdateURLProtocol.requestedPaths.isEmpty)
    }

    func testProvisionalRejectsMarketHoursCrossYearAndFutureCache() async throws {
        let now = date("2026/10/05 08:59"), session = session()
        UpdateURLProtocol.configure([:])
        let (calendar, file) = try calendar(now: now, age: 90_000, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, _) = try fixture(calendar: calendar, session: session)
        defer { withExtendedLifetime(container) {} }
        let preopen = await sim.provisionalNoPriceWork(asOf: now)
        XCTAssertNotNil(preopen)
        for value in ["2026/10/05 09:00", "2026/10/05 15:34", "2026/10/05 15:35", "2027/01/01 08:00"] {
            let result = await sim.provisionalNoPriceWork(asOf: date(value))
            XCTAssertNil(result, value) // 15:35 now requires Monday official data.
        }
        let (future, futureFile) = try self.calendar(now: now, age: -60, session: session)
        defer { try? FileManager.default.removeItem(at: futureFile) }
        let futureResult = await future.provisionalSnapshot(for: now)
        XCTAssertNil(futureResult)
        let empty = TWSETradingCalendar(fileURL: file.appendingPathExtension("absent"), session: session, clock: { now })
        let emptyResult = await empty.provisionalSnapshot(for: now)
        XCTAssertNil(emptyResult)
        XCTAssertTrue(UpdateURLProtocol.requestedPaths.isEmpty)
    }

    func testBackgroundCalendarReleasesUIBeforeResponseThenConfirmsWithoutPrices() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([calendarPath: (200, ordinaryCalendar)], delay: 0.3)
        let (calendar, file) = try calendar(now: now, age: 90_000, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let ui = uiObject(modelContext: container.mainContext, priceCheckSimulation: sim,
                          priceCheckClock: { now }, companyInfoRefresh: { _ in })
        ui.startDailyPriceUpdate(stocks: [stock], allowProvisionalCalendar: true)
        try await waitUntil { ui.calendarConfirmation == .pending }
        XCTAssertFalse(ui.isUpdatingPrices)
        XCTAssertFalse(ui.isTradeOperationLocked)
        XCTAssertTrue(ui.priceUpdateMessage.contains("暫無更新"))
        XCTAssertFalse(ui.priceUpdateMessage.contains("已是最新"))
        try await waitUntil { ui.calendarConfirmation == .none && !ui.isUpdatingPrices }
        XCTAssertTrue(ui.priceUpdateMessage.contains("已是最新"))
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
    }

    func testBackgroundFailureKeepsProvisionalUIAndDoesNotClaimCompletion() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([calendarPath: (503, "unavailable")], delay: 0.2)
        let (calendar, file) = try calendar(now: now, age: 90_000, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let ui = uiObject(modelContext: container.mainContext, priceCheckSimulation: sim,
                          priceCheckClock: { now }, companyInfoRefresh: { _ in })
        ui.startDailyPriceUpdate(stocks: [stock], allowProvisionalCalendar: true)
        try await waitUntil { ui.calendarConfirmation == .pending }
        XCTAssertFalse(ui.isUpdatingPrices)
        try await waitUntil { ui.calendarConfirmation == .failed }
        XCTAssertTrue(ui.priceUpdateMessage.contains("尚未確認"))
        XCTAssertFalse(ui.priceUpdateMessage.contains("已是最新"))
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
    }

    func testManualCheckJoinsBackgroundRequestAndWaitsForConfirmation() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([calendarPath: (200, ordinaryCalendar)], delay: 0.3)
        let (calendar, file) = try calendar(now: now, age: 90_000, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let ui = uiObject(modelContext: container.mainContext, priceCheckSimulation: sim,
                          priceCheckClock: { now }, companyInfoRefresh: { _ in })
        ui.startDailyPriceUpdate(stocks: [stock], allowProvisionalCalendar: true)
        try await waitUntil { ui.calendarConfirmation == .pending && !UpdateURLProtocol.requestedPaths.isEmpty }
        ui.startDailyPriceUpdate(stocks: [stock])
        XCTAssertTrue(ui.isUpdatingPrices)
        try await waitUntil { !ui.isUpdatingPrices }
        XCTAssertTrue(ui.priceUpdateMessage.contains("已是最新"))
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
    }

    func testBackgroundChangedCalendarReplansMissingOfficialData() async throws {
        let now = date("2026/10/04 16:00"), session = session()
        let special = "[{\"Name\":\"補行交易\",\"Date\":\"1151004\",\"Weekday\":\"\",\"Description\":\"\"}]"
        UpdateURLProtocol.configure([calendarPath: (200, special),
            "/exchangeReport/STOCK_DAY": (200, "{\"stat\":\"not ready\"}")], delay: 0.1)
        let (calendar, file) = try calendar(now: now, age: 90_000, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, _) = try fixture(calendar: calendar, session: session)
        defer { withExtendedLifetime(container) {} }
        let provisional = await sim.provisionalNoPriceWork(asOf: now)
        XCTAssertNotNil(provisional)
        let decision = await sim.tech.refreshTradingCalendar(for: now)
        XCTAssertEqual(decision.status, .tradingDay)
        let newCutoff = await sim.tech.latestCompletedTWSETradingDay(asOf: now)
        XCTAssertEqual(newCutoff, date("2026/10/04 00:00"))
        let stillProvisional = await sim.provisionalNoPriceWork(asOf: now)
        XCTAssertNil(stillProvisional)
        // The existing expired-calendar pipeline test covers the ensuing
        // official download. Here verify the changed cutoff creates real work.
        let progress = sim.officialUpdateProgress(stocks: sim.getStocks(), allGroupedStocks: sim.getStocks(), through: newCutoff)
        XCTAssertFalse(progress.subjects.isEmpty)
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
    }

    func testDataChangedDuringBackgroundConfirmationIsRechecked() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([calendarPath: (200, ordinaryCalendar),
            "/exchangeReport/STOCK_DAY": (200, "{\"stat\":\"not ready\"}")], delay: 0.2)
        let (calendar, file) = try calendar(now: now, age: 90_000, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let ui = uiObject(modelContext: container.mainContext, priceCheckSimulation: sim,
                          priceCheckClock: { now }, companyInfoRefresh: { _ in })
        ui.startDailyPriceUpdate(stocks: [stock], allowProvisionalCalendar: true)
        try await waitUntil { ui.calendarConfirmation == .pending }
        let trades = try Trade.fetch(in: container.mainContext, for: stock, ascending: true)
        try XCTUnwrap(trades.last).dataSource = "Yahoo"
        try await waitUntil { UpdateURLProtocol.requestedPaths.contains("/exchangeReport/STOCK_DAY") }
        try await waitUntil { !ui.isUpdatingPrices }
        XCTAssertEqual(UpdateURLProtocol.requestedPaths.filter { $0 == calendarPath }.count, 1)
        XCTAssertTrue(ui.priceUpdateMessage.contains("部分更新完成"))
        XCTAssertTrue(ui.priceUpdateMessage.contains("Yahoo 略過"))
    }

    func testRepeatedForegroundSharesBackgroundRequest() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([calendarPath: (200, ordinaryCalendar)], delay: 0.3)
        let (calendar, file) = try calendar(now: now, age: 90_000, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        let ui = uiObject(modelContext: container.mainContext, priceCheckSimulation: sim,
                          priceCheckClock: { now }, companyInfoRefresh: { _ in })
        ui.startDailyPriceUpdate(stocks: [stock], allowProvisionalCalendar: true)
        try await waitUntil { ui.calendarConfirmation == .pending && !UpdateURLProtocol.requestedPaths.isEmpty }
        ui.startDailyPriceUpdate(stocks: [stock], allowProvisionalCalendar: true)
        try await waitUntil { ui.calendarConfirmation == .pending && !ui.isUpdatingPrices }
        try await waitUntil { ui.calendarConfirmation == .none && !ui.isUpdatingPrices }
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
    }

    func testCalendarSuccessPersistsAndNextForegroundAndColdInstanceDoNotQueryOrShowRefresh() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([calendarPath: (200, ordinaryCalendar)])
        let (calendar, file) = try calendar(now: now, age: 90_000, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        defer { withExtendedLifetime(container) {} }
        var firstMessages: [String] = []
        let first = await sim.updateTWSEPrices(stocks: [stock], asOf: now, onProgress: { firstMessages.append($0) })
        XCTAssertEqual(first.timings.calendarRequests, 1)
        XCTAssertTrue(firstMessages.contains { $0.contains("確認交易日曆") })
        let pending = await sim.provisionalNoPriceWork(asOf: now)
        XCTAssertNil(pending)
        var nextMessages: [String] = []
        let second = await sim.updateTWSEPrices(stocks: [stock], asOf: now, onProgress: { nextMessages.append($0) })
        XCTAssertEqual(second.timings.calendarRequests, 0)
        XCTAssertFalse(nextMessages.contains { $0.contains("確認交易日曆") })
        let reloaded = TWSETradingCalendar(fileURL: file, session: session, clock: { now })
        let needsWait = await reloaded.needsRefreshWait(for: now)
        XCTAssertFalse(needsWait)
        let cold = await reloaded.decision(for: now)
        XCTAssertEqual(cold.requestCount, 0)
        XCTAssertEqual(cold.status, .closed)
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
    }

    func testFailedCalendarBackoffDoesNotPretendAnotherRefreshIsRunning() async throws {
        let now = date("2026/10/04 10:00"), session = session()
        UpdateURLProtocol.configure([calendarPath: (503, "unavailable")])
        let (calendar, file) = try calendar(now: now, age: 90_000, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let before = await calendar.needsRefreshWait(for: now)
        XCTAssertTrue(before)
        let first = await calendar.decision(for: now)
        XCTAssertEqual(first.status, .unknown)
        let throttled = await calendar.needsRefreshWait(for: now)
        XCTAssertFalse(throttled)
        let second = await calendar.decision(for: now)
        XCTAssertEqual(second.status, .unknown)
        XCTAssertEqual(second.requestCount, 0)
        XCTAssertEqual(UpdateURLProtocol.requestedPaths, [calendarPath])
    }

}
