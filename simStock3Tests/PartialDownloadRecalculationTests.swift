import Foundation
import SwiftData
import XCTest
@testable import simStock3

/// Synthetic monthly responses only. No request can reach the network.
private final class PartialMonthURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var firstDayHasNoOHLC = false
    nonisolated(unsafe) static var requestedMonths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path == "/exchangeReport/STOCK_DAY",
              let stamp = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "date" })?.value,
              let start = twDateTime.dateFromString(stamp, format: "yyyyMMdd") else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        Self.requestedMonths.append(stamp)
        let range = twDateTime.calendar.range(of: .day, in: .month, for: start)!
        let rows = range.map { offset -> [String] in
            let day = twDateTime.calendar.date(byAdding: .day, value: offset - 1, to: start)!
            let year = twDateTime.calendar.component(.year, from: day) - 1911
            let mmdd = twDateTime.stringFromDate(day, format: "MM/dd")
            if Self.firstDayHasNoOHLC && offset == 1 {
                return ["\(year)/\(mmdd)", "139", "17,570", "--", "--", "--", "--", "0", "8"]
            }
            return ["\(year)/\(mmdd)", "1000000", "0", "100", "101", "99", "100", "0", "1"]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["stat": "OK", "data": rows])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class PartialDownloadRecalculationTests: XCTestCase {
    private func date(_ value: String) -> Date { twDateTime.dateFromString(value)! }
    private func days(_ first: Date, _ last: Date) -> [Date] {
        let count = twDateTime.calendar.dateComponents([.day], from: first, to: last).day!
        return (0...count).map { twDateTime.time1330(twDateTime.calendar.date(byAdding: .day, value: $0, to: first)!) }
    }
    private struct Fixture {
        let container: ModelContainer
        let sim: simObject
        let stock: Stock
        let session: URLSession
        let calendarURL: URL
    }
    private func fixture(first: String, last: String, market: Bool = true) throws -> Fixture {
        PartialMonthURLProtocol.firstDayHasNoOHLC = false
        PartialMonthURLProtocol.requestedMonths = []
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        if market {
            let writer = MarketDataStore(modelContext: context)
            _ = try writer.applyOfficialRecords(days(date("2023/01/01"), date("2026/10/02")).map {
                .init(date: $0, open: 100, high: 101, low: 99, close: 100)
            })
            try writer.rebuildPricePath()
        }
        let stock = Stock(sId: "PARTIAL", sName: "暫算", group: "A",
            dateFirst: date("2023/01/01"), dateStart: date("2024/01/01"))
        context.insert(stock)
        for day in days(date(first), date(last)) {
            let row = Trade(stock: stock, dateTime: day)
            row.dataSource = "TWSE"; row.volumeClose = 1000
            row.priceOpen = 100; row.priceHigh = 101; row.priceLow = 99; row.priceClose = 100
            context.insert(row)
        }
        // Synthetic preloaded months are known complete source fixtures.
        var month = twDateTime.startOfMonth(date(first))
        while month <= date(last) {
            let next = twDateTime.calendar.date(byAdding: .month, value: 1, to: month)!
            try stock.confirmHistoryMonth(month, through: min(next.addingTimeInterval(-1), twDateTime.endOfDay(date(last))))
            month = next
        }
        try context.save()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PartialMonthURLProtocol.self]
        let session = URLSession(configuration: config)
        let now = date("2026/10/04")
        let calendarURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TWSETradingCalendarSnapshot(version: 1, sourceURL: "synthetic", fetchedAt: now,
            year: 2026, entries: [])).write(to: calendarURL)
        let calendar = TWSETradingCalendar(fileURL: calendarURL, session: session, clock: { now })
        return Fixture(container: container,
            sim: simObject(modelContext: context, tradingCalendar: calendar, marketSession: session, marketRetryDelays: []),
            stock: stock, session: session, calendarURL: calendarURL)
    }
    private func close(_ f: Fixture) {
        f.sim.tech.invalidateTimer(); f.session.invalidateAndCancel()
        PartialMonthURLProtocol.firstDayHasNoOHLC = false
        try? FileManager.default.removeItem(at: f.calendarURL)
    }

    func testCancelContinuationComputesExistingRangeWithoutCompletingHistory() async throws {
        let f = try fixture(first: "2024/07/01", last: "2026/10/02")
        defer { close(f) }
        var prompts = 0
        let result = await f.sim.updateTWSEPrices(stocks: [f.stock], asOf: date("2026/10/04"),
            onBatchCompletion: { _ in prompts += 1; return nil })
        let trace = f.sim.tech.lastRecalculationTrace
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(result.requestedMonths, 6)
        XCTAssertEqual(result.remainingHistoryMonths, 12)
        XCTAssertEqual(f.stock.effectiveSimulationStart, date("2025/01/01"))
        XCTAssertEqual(trace.technicalDates.first, twDateTime.time1330(date("2024/01/01")))
        XCTAssertEqual(trace.simulationDates.first, twDateTime.time1330(date("2025/01/01")))
        XCTAssertEqual(trace.simulationDates.last, twDateTime.time1330(date("2026/10/02")))
        XCTAssertNil(f.stock.technicalDirtyFrom); XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertEqual(result.calculatedStockIDs, [f.stock.sId])
        XCTAssertFalse(result.statusText.contains("歷史資料也已補齊"))
        XCTAssertEqual(f.stock.dateStart, date("2024/01/01"))
    }

    func testNoPriceReceiptsSurviveBatchCancellationAndResumeWithoutRepeatingMonths() async throws {
        let f = try fixture(first: "2024/07/01", last: "2026/10/02")
        defer { close(f) }
        PartialMonthURLProtocol.firstDayHasNoOHLC = true
        let first = await f.sim.updateTWSEPrices(stocks: [f.stock], asOf: date("2026/10/04"),
            onBatchCompletion: { _ in nil })
        XCTAssertEqual(first.requestedMonths, 6)
        XCTAssertEqual(first.failedMonths, 0)
        XCTAssertEqual(first.remainingHistoryMonths, 12)
        let firstRequests = Set(PartialMonthURLProtocol.requestedMonths)
        XCTAssertEqual(firstRequests.count, 6)
        let reopened = try XCTUnwrap(Stock.fetchAll(in: ModelContext(f.container)).first)
        XCTAssertEqual(reopened.confirmedHistory.noPriceDays?.count, 6)
        for rows in reopened.confirmedHistory.noPriceDays?.values ?? Dictionary<String, [TWSEHistoryCoverage.NoPriceDay]>().values {
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].shares, 139)
            XCTAssertNil(try Trade.fetch(in: f.container.mainContext, for: f.stock, on: rows[0].date))
        }
        PartialMonthURLProtocol.requestedMonths = []
        let second = await f.sim.updateTWSEPrices(stocks: [f.stock], asOf: date("2026/10/04"),
            onBatchCompletion: { _ in nil })
        XCTAssertEqual(second.requestedMonths, 6)
        XCTAssertEqual(second.failedMonths, 0)
        XCTAssertEqual(second.remainingHistoryMonths, 6)
        XCTAssertTrue(firstRequests.isDisjoint(with: PartialMonthURLProtocol.requestedMonths))
        XCTAssertEqual(f.stock.confirmedHistory.noPriceDays?.count, 12)
    }

    func testLegacySuccessfulMonthsSurviveCancelAndColdContext() async throws {
        let f = try fixture(first: "2024/07/01", last: "2026/10/02")
        defer { close(f) }
        var legacy = f.stock.confirmedHistory
        legacy.legacyAdoptionCompleted = nil // Existing 3.7.0 successful receipts.
        f.stock.twseHistoryCoverage = try JSONEncoder().encode(legacy)
        try f.container.mainContext.save()
        let result = await f.sim.updateTWSEPrices(stocks: [f.stock], asOf: date("2026/10/04"),
            onBatchCompletion: { _ in nil })
        XCTAssertEqual(result.requestedMonths, 6)
        XCTAssertEqual(result.remainingHistoryMonths, 12)
        let reopened = ModelContext(f.container)
        let stock = try XCTUnwrap(Stock.fetchAll(in: reopened).first)
        XCTAssertEqual(stock.confirmedHistory.legacyAdoptionCompleted, true)
        XCTAssertEqual(stock.confirmedHistory.months.count, legacy.months.count + 6)
        let missing = stock.unconfirmedHistoryMonths(through: date("2026/10/02"))
        XCTAssertEqual(missing.count, 12)
        XCTAssertFalse(missing.contains { $0 >= date("2024/01/01") })
        XCTAssertEqual(stock.technicalStateVersion, 4)
        XCTAssertNil(stock.technicalDirtyFrom); XCTAssertNil(stock.simulationDirtyFrom)
    }

    func testRecentBatchCancellationStillCalculatesThroughSavedLatestDate() async throws {
        let f = try fixture(first: "2024/01/01", last: "2025/02/01")
        defer { close(f) }
        var prompts = 0
        let result = await f.sim.updateTWSEPrices(stocks: [f.stock], asOf: date("2026/10/04"),
            onBatchCompletion: { _ in prompts += 1; return nil })
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(result.requestedMonths, 6)
        XCTAssertGreaterThan(result.remainingRecentMonths, 0)
        XCTAssertEqual(f.sim.tech.lastRecalculationTrace.simulationDates.last, twDateTime.time1330(date("2025/07/31")))
        XCTAssertNil(f.stock.technicalDirtyFrom); XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertTrue(result.realtimeBlockedStockIDs.contains(f.stock.sId))
        XCTAssertTrue(result.statusText.contains("近期尚待補"))
        XCTAssertFalse(result.statusText.contains("股價已是最新"))
    }

    func testAbsentMarketDoesNotBlockTechnicalAndCannotSettleSimulation() async throws {
        let f = try fixture(first: "2024/01/01", last: "2025/02/01", market: false)
        defer { close(f) }
        var legacy = f.stock.confirmedHistory
        legacy.legacyAdoptionCompleted = nil
        f.stock.twseHistoryCoverage = try JSONEncoder().encode(legacy)
        try f.container.mainContext.save()
        let result = await f.sim.updateTWSEPrices(stocks: [f.stock], asOf: date("2026/10/04"))
        XCTAssertFalse(f.sim.tech.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertTrue(f.sim.tech.lastRecalculationTrace.simulationDates.isEmpty)
        XCTAssertEqual(f.sim.tech.lastRecalculationTrace.simulationDependencyIssue, .marketMissing)
        XCTAssertNil(f.stock.technicalDirtyFrom); XCTAssertNotNil(f.stock.simulationDirtyFrom)
        XCTAssertTrue(result.realtimeBlockedStockIDs.contains(f.stock.sId))
        XCTAssertEqual(try MarketDay.fetchAll(in: f.container.mainContext).count, 0)
        XCTAssertEqual(result.calculatedStockIDs, [f.stock.sId])
    }

    func testWholeTaskCancellationPreservesDirtyAndResumeDoesNotDownloadAgain() async throws {
        let f = try fixture(first: "2024/07/01", last: "2026/10/02")
        defer { close(f) }
        let task = Task { @MainActor in
            await f.sim.updateTWSEPrices(stocks: [f.stock], asOf: date("2026/10/04"),
                onBatchCompletion: { _ in withUnsafeCurrentTask { $0?.cancel() }; return nil })
        }
        let result = await task.value
        XCTAssertTrue(result.wasInterrupted)
        XCTAssertTrue(f.sim.tech.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertNotNil(f.stock.technicalDirtyFrom); XCTAssertNotNil(f.stock.simulationDirtyFrom)
        // Same saved raw prices resume via the common executor, no request path.
        _ = try await f.sim.tech.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertNil(f.stock.technicalDirtyFrom); XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertEqual(f.sim.tech.lastRecalculationTrace.simulationDates.last, twDateTime.time1330(date("2026/10/02")))
    }
}
