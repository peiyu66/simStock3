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
                         lastStockDay: String = "2026/10/02 13:30", storeURL: URL? = nil) throws -> (ModelContainer, simObject, Stock) {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let configuration = storeURL.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
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
        return (container, simObject(modelContext: context, tradingCalendar: calendar, marketSession: session, marketRetryDelays: []), stock)
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
        XCTAssertTrue(ui.priceUpdateMessage.contains("Yahoo 無需查詢"))
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


    private func quote(_ timestamp: String, market: Bool = false, close: Int = 100) -> String {
        (market ? "<title>加權指數(^TWII)</title>" : "<title>測試</title>")
            + "<time datetime=\"\(timestamp)\">"
            + [("開盤", 100), ("最高", 120), ("最低", 90), ("成交", close), ("總量", 1000)]
                .map { "<span>\($0.0)</span><span>\($0.1)</span>" }.joined()
    }

    func testIndexFailureDoesNotRepeatCompletedStocksAndUsesPreviousTradingDay() async throws {
        let now = date("2026/10/05 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        UpdateURLProtocol.configure(["/quote/TEST": (200, quote("2026/10/05 10:00"))])
        let first = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        let latest = try XCTUnwrap(Trade.last(in: container.mainContext, for: stock))
        XCTAssertEqual(first.twse.requestedMonths, 0)
        XCTAssertEqual(first.yahoo.updatedStocks, 1)
        XCTAssertTrue(first.yahoo.marketFailed)
        XCTAssertTrue(latest.simMarketIsProvisional)
        XCTAssertEqual(latest.simMarketSourceDate, date("2026/10/02 13:30"))
        XCTAssertNil(try MarketDay.fetchSameDay(as: now, in: container.mainContext))
        XCTAssertEqual(UpdateURLProtocol.requestedPaths.first, "/quote/TEST")
        UpdateURLProtocol.configure([:])
        let second = await sim.updateDailyPrices(stocks: [stock], clock: { now.addingTimeInterval(30) })
        XCTAssertEqual(second.twse.requestedMonths, 0)
        XCTAssertEqual(second.yahoo.requestedStocks, 0)
        XCTAssertFalse(UpdateURLProtocol.requestedPaths.contains("/exchangeReport/STOCK_DAY"))
        XCTAssertFalse(UpdateURLProtocol.requestedPaths.contains("/quote/TEST"))
        XCTAssertTrue(latest.simMarketIsProvisional)
        sim.tech.invalidateTimer()
    }

    func testColdResumeKeepsStockAndYahooCheckpointsAfterIndexFailure() async throws {
        let now = date("2026/10/05 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: folder); session.invalidateAndCancel() }
        let store = folder.appendingPathComponent("fixture.store")
        do {
            let (container, sim, stock) = try fixture(calendar: calendar, session: session, storeURL: store)
            UpdateURLProtocol.configure(["/quote/TEST": (200, quote("2026/10/05 10:00"))])
            let first = await sim.updateDailyPrices(stocks: [stock], clock: { now })
            XCTAssertEqual(first.yahoo.updatedStocks, 1)
            sim.tech.invalidateTimer()
            withExtendedLifetime(container) {}
        }
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let reopened = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: store))
        let stock = try XCTUnwrap(Stock.fetchGrouped(in: reopened.mainContext).first)
        let sim = simObject(modelContext: reopened.mainContext, tradingCalendar: calendar, marketSession: session, marketRetryDelays: [])
        UpdateURLProtocol.configure([:])
        let second = await sim.updateDailyPrices(stocks: [stock], clock: { now.addingTimeInterval(30) })
        XCTAssertEqual(second.twse.requestedMonths, 0)
        XCTAssertEqual(second.yahoo.requestedStocks, 0)
        XCTAssertEqual(stock.yahooCheckedAt, now)
        XCTAssertFalse(UpdateURLProtocol.requestedPaths.contains("/exchangeReport/STOCK_DAY"))
        XCTAssertTrue(try XCTUnwrap(Trade.last(in: reopened.mainContext, for: stock)).simMarketIsProvisional)
        sim.tech.invalidateTimer()
    }

    func testBothYahooFailuresKeepCompletedTWSEAndDoNotInventToday() async throws {
        let now = date("2026/10/05 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        for _ in 0..<2 {
            UpdateURLProtocol.configure([:])
            let result = await sim.updateDailyPrices(stocks: [stock], clock: { now })
            XCTAssertEqual(result.twse.requestedMonths, 0)
            XCTAssertEqual(result.yahoo.requestedStocks, 1)
            XCTAssertTrue(result.yahoo.successfulStockIDs.isEmpty)
            XCTAssertFalse(UpdateURLProtocol.requestedPaths.contains("/exchangeReport/STOCK_DAY"))
            XCTAssertEqual(try Trade.last(in: container.mainContext, for: stock)?.dateTime, date("2026/10/02 13:30"))
        }
        sim.tech.invalidateTimer()
    }

    func testTodayOfficialStockDoesNotRefetchWhenOfficialMarketAndYahooMarketFail() async throws {
        let now = date("2026/10/05 16:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session, lastStockDay: "2026/10/05 13:30")
        for _ in 0..<2 {
            UpdateURLProtocol.configure([:])
            let result = await sim.updateDailyPrices(stocks: [stock], clock: { now })
            XCTAssertEqual(result.twse.requestedMonths, 0)
            XCTAssertEqual(result.twse.market.failedMonths, 1)
            XCTAssertFalse(UpdateURLProtocol.requestedPaths.contains("/exchangeReport/STOCK_DAY"))
            XCTAssertFalse(UpdateURLProtocol.requestedPaths.contains("/quote/TEST"))
            XCTAssertTrue(try XCTUnwrap(Trade.last(in: container.mainContext, for: stock)).simMarketIsProvisional)
        }
        XCTAssertNil(try MarketDay.fetchSameDay(as: now, in: container.mainContext))
    }

    func testStockTWSEAndYahooSaveBeforeFailedMarketHistory() async throws {
        let now = date("2026/10/05 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session, lastStockDay: "2026/10/01 13:30")
        let context = container.mainContext
        let market = try XCTUnwrap(MarketDay.fetchSameDay(as: date("2026/10/02 13:30"), in: context))
        context.delete(market); try context.save()
        UpdateURLProtocol.configure([
            "/exchangeReport/STOCK_DAY": (200, "{\"stat\":\"OK\",\"data\":[[\"115/10/02\",\"1000000\",\"0\",\"100\",\"101\",\"99\",\"100\",\"0\",\"1\"]]}"),
            "/quote/TEST": (200, quote("2026/10/05 10:00"))])
        let first = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        XCTAssertEqual(first.twse.requestedMonths, 1)
        XCTAssertEqual(first.yahoo.updatedStocks, 1)
        XCTAssertEqual(Array(UpdateURLProtocol.requestedPaths.prefix(3)),
                       ["/exchangeReport/STOCK_DAY", "/quote/TEST", "/indicesReport/MI_5MINS_HIST"])
        XCTAssertTrue(first.twse.realtimeBlockedStockIDs.contains(stock.sId))
        UpdateURLProtocol.configure([:])
        let second = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        XCTAssertEqual(second.twse.requestedMonths, 0)
        XCTAssertFalse(UpdateURLProtocol.requestedPaths.contains("/exchangeReport/STOCK_DAY"))
        sim.tech.invalidateTimer()
    }

    func testLateMarketQuoteRecalculatesUnchangedStockAndPreservesOriginalSourceDate() async throws {
        let now = date("2026/10/05 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        UpdateURLProtocol.configure(["/quote/TEST": (200, quote("2026/10/05 10:00"))])
        _ = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        let latest = try XCTUnwrap(Trade.last(in: container.mainContext, for: stock))
        XCTAssertEqual(latest.simMarketSourceDate, date("2026/10/02 13:30"))
        UpdateURLProtocol.configure(["/quote/^TWII": (200, quote("2026/10/05 10:01", market: true, close: 110))])
        let result = await sim.updateDailyPrices(stocks: [stock], clock: { now.addingTimeInterval(60) })
        XCTAssertTrue(result.yahoo.marketUpdated)
        XCTAssertEqual(result.yahoo.requestedStocks, 0)
        XCTAssertEqual(latest.simMarketSourceDate, date("2026/10/05 13:30"))
        XCTAssertEqual(latest.simMarketQuoteTime, date("2026/10/05 10:01"))
        XCTAssertNil(stock.simulationDirtyFrom)
        XCTAssertTrue(sim.tech.lastRecalculationTrace.simulationDates.contains(latest.dateTime))
        let expected = [latest.rollAmtProfit, latest.simAmtBalance, latest.simQtyInventory, latest.tKdJ]
        _ = try sim.tech.recalculate(stock: stock, plan: RecalculationPlan(technical: .all, simulation: .all, resetDerivedSimulationState: true))
        XCTAssertEqual(expected, [latest.rollAmtProfit, latest.simAmtBalance, latest.simQtyInventory, latest.tKdJ])
        sim.tech.invalidateTimer()
    }

    func testSingleStockUpdateRecalculatesOtherStocksWhenSharedMarketArrives() async throws {
        let now = date("2026/10/05 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, first) = try fixture(calendar: calendar, session: session)
        let context = container.mainContext
        let second = Stock(sId: "SECOND", sName: "第二檔", group: "A", dateFirst: first.dateFirst, dateStart: first.dateStart)
        context.insert(second)
        second.technicalStateVersion = first.technicalStateVersion
        second.simulationStateVersion = first.simulationStateVersion
        for original in try Trade.fetch(in: context, for: first, ascending: true) {
            let trade = Trade(stock: second, dateTime: original.dateTime)
            trade.priceOpen = 100; trade.priceHigh = 101; trade.priceLow = 99; trade.priceClose = 100
            context.insert(trade)
        }
        try context.save()
        UpdateURLProtocol.configure([
            "/quote/TEST": (200, quote("2026/10/05 10:00")),
            "/quote/SECOND": (200, quote("2026/10/05 10:00"))])
        _ = await sim.updateDailyPrices(stocks: [first, second], clock: { now })
        let secondTrade = try XCTUnwrap(Trade.last(in: context, for: second))
        XCTAssertEqual(secondTrade.simMarketSourceDate, date("2026/10/02 13:30"))
        UpdateURLProtocol.configure(["/quote/^TWII": (200, quote("2026/10/05 10:01", market: true, close: 110))])
        let result = await sim.updateDailyPrices(stocks: [first], clock: { now.addingTimeInterval(60) })
        XCTAssertTrue(result.yahoo.marketUpdated)
        XCTAssertEqual(result.twse.requestedMonths, 0)
        XCTAssertEqual(result.yahoo.requestedStocks, 0)
        XCTAssertEqual(secondTrade.simMarketSourceDate, date("2026/10/05 13:30"))
        XCTAssertEqual(secondTrade.simMarketQuoteTime, date("2026/10/05 10:01"))
        XCTAssertNil(second.simulationDirtyFrom)
        XCTAssertFalse(UpdateURLProtocol.requestedPaths.contains("/exchangeReport/STOCK_DAY"))
        sim.tech.invalidateTimer()
    }

    func testUnpublishedTodayOfficialCloseStillAllowsProvisionalUsingCompletePriorInputs() async throws {
        let now = date("2026/10/05 16:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        UpdateURLProtocol.configure(["/quote/TEST": (200, quote("2026/10/05 13:30", close: 110))])
        let result = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        XCTAssertEqual(result.twse.requestedMonths, 1)
        XCTAssertEqual(result.twse.failedMonths, 1)
        XCTAssertTrue(result.twse.forwardFailedStockIDs.contains(stock.sId))
        XCTAssertTrue(result.twse.realtimeBlockedStockIDs.isEmpty)
        let latest = try XCTUnwrap(Trade.last(in: container.mainContext, for: stock))
        XCTAssertTrue(latest.simMarketIsProvisional)
        XCTAssertEqual(latest.simMarketSourceDate, date("2026/10/02 13:30"))
        XCTAssertEqual(latest.priceClose, 110)
        XCTAssertNil(stock.simulationDirtyFrom)
        XCTAssertNil(try MarketDay.fetchSameDay(as: now, in: container.mainContext))
        sim.tech.invalidateTimer()
    }

    func testOldQuoteCannotMarkCloseCompleteOrOverwriteNewerPrice() async throws {
        let now = date("2026/10/05 13:40"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        UpdateURLProtocol.configure(["/quote/TEST": (200, quote("2026/10/05 13:20"))])
        _ = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        let latest = try XCTUnwrap(Trade.last(in: container.mainContext, for: stock))
        XCTAssertFalse(latest.isYahooClosePrice)
        UpdateURLProtocol.configure(["/quote/TEST": (200, quote("2026/10/05 13:30", close: 110))])
        let second = await sim.updateDailyPrices(stocks: [stock], clock: { now.addingTimeInterval(30) })
        XCTAssertEqual(second.yahoo.requestedStocks, 1)
        XCTAssertTrue(latest.isYahooClosePrice)
        UpdateURLProtocol.configure(["/quote/TEST": (200, quote("2026/10/05 13:20", close: 95))])
        let stale = await sim.tech.fetchYahooPrice(stock, asOf: now)
        XCTAssertFalse(stale.succeeded)
        XCTAssertEqual(latest.priceClose, 110)
        sim.tech.invalidateTimer()
    }

    func testProvisionalManualIntentIsPreservedWithoutAddingToAccounting() async throws {
        let now = date("2026/10/05 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        UpdateURLProtocol.configure(["/quote/TEST": (200, quote("2026/10/05 10:00"))])
        _ = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        let latest = try XCTUnwrap(Trade.last(in: container.mainContext, for: stock))
        latest.simInvestByUser = 1
        latest.simReversed = "S+"
        stock.simulationDirtyFrom = twDateTime.startOfDay(now)
        _ = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        XCTAssertEqual(latest.simInvestByUser, 1)
        XCTAssertEqual(latest.simReversed, "S+")
        XCTAssertNotNil(latest.simProvisionalEffectiveInvestment)
        XCTAssertEqual(latest.invested, (latest.simProvisionalEffectiveInvestment ?? 0) + latest.simInvestAdded)
        sim.tech.invalidateTimer()
    }


    func testInterruptedYahooListResumesOnlyUnfinishedStock() async throws {
        let now = date("2026/10/05 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, first) = try fixture(calendar: calendar, session: session)
        let context = container.mainContext
        let second = Stock(sId: "SECOND", sName: "第二檔", group: "A", dateFirst: first.dateFirst, dateStart: first.dateStart)
        context.insert(second)
        second.technicalStateVersion = first.technicalStateVersion
        second.simulationStateVersion = first.simulationStateVersion
        for original in try Trade.fetch(in: context, for: first, ascending: true) {
            let trade = Trade(stock: second, dateTime: original.dateTime)
            trade.priceOpen = 100; trade.priceHigh = 101; trade.priceLow = 99; trade.priceClose = 100
            context.insert(trade)
        }
        try context.save()
        UpdateURLProtocol.configure(["/quote/TEST": (200, quote("2026/10/05 10:00"))])
        let saved = await sim.tech.fetchYahooPrice(first, asOf: now)
        XCTAssertTrue(saved.succeeded) // Simulate interruption before the next source.
        let freshContext = ModelContext(container)
        let reopened = simObject(modelContext: freshContext, tradingCalendar: calendar, marketSession: session, marketRetryDelays: [])
        let stocks = try Stock.fetchGrouped(in: freshContext)
        UpdateURLProtocol.configure(["/quote/SECOND": (200, quote("2026/10/05 10:00"))])
        let result = await reopened.updateDailyPrices(stocks: stocks, clock: { now.addingTimeInterval(30) })
        XCTAssertEqual(result.twse.requestedMonths, 0)
        XCTAssertEqual(result.yahoo.requestedStocks, 1)
        XCTAssertEqual(result.yahoo.successfulStockIDs, ["SECOND"])
        XCTAssertFalse(UpdateURLProtocol.requestedPaths.contains("/exchangeReport/STOCK_DAY"))
        XCTAssertFalse(UpdateURLProtocol.requestedPaths.contains("/quote/TEST"))
        reopened.tech.invalidateTimer()
        withExtendedLifetime(container) {}
    }

    func testInvalidOrWrongDayYahooQuoteDoesNotCreateToday() async throws {
        let now = date("2026/10/05 10:00"), session = session()
        let (calendar, file) = try calendar(now: now, session: session)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let (container, sim, stock) = try fixture(calendar: calendar, session: session)
        for html in [quote("2026/10/02 13:30"), quote("2026/10/05 10:06"), quote("2026/10/05 10:00", close: 130)] {
            UpdateURLProtocol.configure(["/quote/TEST": (200, html)])
            let result = await sim.tech.fetchYahooPrice(stock, asOf: now)
            XCTAssertFalse(result.succeeded)
            XCTAssertNil(stock.yahooCheckedAt)
            XCTAssertEqual(try Trade.fetch(in: container.mainContext, for: stock, ascending: true).count, 2)
        }
    }
}
