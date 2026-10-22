import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import simStock3

private final class LegacyHistoryURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request.url!.absoluteString)
        // No network and no manufactured successful monthly response.
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }
    override func stopLoading() {}
}

@MainActor
final class LegacyHistoryAdoptionTests: XCTestCase {
    private func day(_ value: String) -> Date { twDateTime.dateFromString(value)! }
    private func dates(_ values: String...) -> Set<Date> { Set(values.map(day)) }

    func testOldJSONAndExactWindowAdoptionDoNotCertifyEarlierOrFutureDates() throws {
        let old = try JSONEncoder().encode(["months": [String: Date]()])
        var coverage = try JSONDecoder().decode(TWSEHistoryCoverage.self, from: old)
        XCTAssertNil(coverage.legacyAdoptionCompleted)
        let prices = dates("2023/01/23", "2023/01/24", "2023/02/01")
        coverage.adoptLegacy(stockDates: prices, marketDates: prices,
            requestStart: day("2023/01/22"), through: day("2023/02/01"))
        XCTAssertEqual(coverage.legacyIntervals?.count, 2)
        XCTAssertTrue(coverage.months.isEmpty)
        XCTAssertTrue(coverage.contains(month: day("2023/01/01"), from: day("2023/01/22"), through: day("2023/01/31")))
        XCTAssertFalse(coverage.contains(month: day("2023/01/01"), from: day("2023/01/21"), through: day("2023/01/31")))
        XCTAssertFalse(coverage.contains(month: day("2023/02/01"), through: day("2023/02/02")))
        XCTAssertEqual(try JSONDecoder().decode(TWSEHistoryCoverage.self, from: JSONEncoder().encode(coverage)), coverage)
    }

    func testMissingDayMissingReferenceAndExistingSuccessfulMonthRemainDistinct() {
        var coverage = TWSEHistoryCoverage()
        coverage.confirm(month: day("2023/03/01"), through: day("2023/03/31"))
        coverage.adoptLegacy(stockDates: dates("2023/01/03", "2023/02/01", "2023/04/03"),
            marketDates: dates("2023/01/03", "2023/01/04", "2023/04/03"),
            requestStart: day("2023/01/01"), through: day("2023/04/03"))
        XCTAssertFalse(coverage.contains(month: day("2023/01/01"), through: day("2023/01/31")))
        XCTAssertFalse(coverage.contains(month: day("2023/02/01"), through: day("2023/02/28")))
        XCTAssertTrue(coverage.contains(month: day("2023/03/01"), through: day("2023/03/31")))
        XCTAssertTrue(coverage.contains(month: day("2023/04/01"), through: day("2023/04/03")))
        let before = coverage
        coverage.adoptLegacy(stockDates: dates("2023/01/03"), marketDates: dates("2023/01/03"),
            requestStart: day("2023/01/01"), through: day("2023/01/03"))
        XCTAssertEqual(before, coverage, "No repeated inference after the legacy transition")
    }

    private func fixture() throws -> (ModelContainer, Stock, [Trade], [MarketDay]) {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let stock = Stock(sId: "LEGACY", sName: "舊資料", group: "A", dateFirst: day("2023/01/01"), dateStart: day("2024/01/01"))
        container.mainContext.insert(stock)
        var rows: [Trade] = []; var market: [MarketDay] = []
        for date in [day("2023/01/03"), day("2023/01/04")] {
            let trade = Trade(stock: stock, dateTime: twDateTime.time1330(date), dataSource: "TWSE")
            trade.priceClose = 100; trade.priceOpen = 100; trade.priceHigh = 101; trade.priceLow = 99; trade.volumeClose = 1000
            container.mainContext.insert(trade); rows.append(trade)
            let index = MarketDay(dateTime: date, indexOpen: 100, indexHigh: 101, indexLow: 99, indexClose: 100)
            container.mainContext.insert(index); market.append(index)
        }
        try container.mainContext.save()
        return (container, stock, rows, market)
    }

    func testNewStockNeverUsesLegacyInferenceAndDeletionDoesNotReenableIt() throws {
        let (container, stock, rows, market) = try fixture()
        let technical = Technical(modelContext: container.mainContext)
        defer { technical.invalidateTimer() }
        try technical.adoptLegacyHistoryCoverage(for: stock, trades: rows, marketDays: market)
        XCTAssertEqual(stock.unconfirmedHistoryMonths(through: day("2023/01/04")).count, 1)
        stock.twseHistoryCoverage = nil // Simulate an on-disk pre-receipt stock.
        try technical.adoptLegacyHistoryCoverage(for: stock, trades: rows, marketDays: market)
        XCTAssertTrue(stock.unconfirmedHistoryMonths(through: day("2023/01/04")).isEmpty)
        try stock.forgetHistoryMonths(containing: [rows[0].dateTime])
        try technical.adoptLegacyHistoryCoverage(for: stock, trades: rows, marketDays: market)
        XCTAssertEqual(stock.unconfirmedHistoryMonths(through: day("2023/01/04")).count, 1)
    }

    func testSourceAdoptionDoesNotRequireMarketTAndIgnoresIntradayAsProof() throws {
        let (container, stock, rows, market) = try fixture()
        stock.twseHistoryCoverage = nil
        rows[1].dataSource = "yahoo"
        let technical = Technical(modelContext: container.mainContext)
        defer { technical.invalidateTimer() }
        try technical.adoptLegacyHistoryCoverage(for: stock, trades: rows, marketDays: market)
        XCTAssertTrue(stock.unconfirmedHistoryMonths(through: day("2023/01/03")).isEmpty)
        XCTAssertEqual(stock.unconfirmedHistoryMonths(through: day("2023/01/04")).count, 1)
        XCTAssertTrue(market.allSatisfy { $0.technicalStateVersion == 0 })
        XCTAssertEqual(stock.technicalStateVersion, 0)
        XCTAssertEqual(stock.simulationStateVersion, 0)
        XCTAssertNil(stock.technicalDirtyFrom)
        XCTAssertNil(stock.simulationDirtyFrom)
    }

    func testFailedAdoptionSaveRestoresEvidenceAndRetryPersists() throws {
        enum Failure: Error { case injected }
        let (container, stock, rows, market) = try fixture()
        stock.twseHistoryCoverage = nil
        try stock.confirmHistoryMonth(day("2022/12/01"), through: day("2022/12/31"))
        try container.mainContext.save()
        let before = stock.twseHistoryCoverage
        let technical = Technical(modelContext: container.mainContext)
        defer { technical.invalidateTimer() }
        technical.recalculationSave = { throw Failure.injected }
        XCTAssertThrowsError(try technical.adoptLegacyHistoryCoverage(for: stock, trades: rows, marketDays: market))
        XCTAssertEqual(stock.twseHistoryCoverage, before)
        XCTAssertEqual(try Stock.fetchAll(in: ModelContext(container)).first?.twseHistoryCoverage, before)
        technical.recalculationSave = nil
        try technical.adoptLegacyHistoryCoverage(for: stock, trades: rows, marketDays: market)
        let reopened = try XCTUnwrap(Stock.fetchAll(in: ModelContext(container)).first)
        XCTAssertTrue(reopened.unconfirmedHistoryMonths(through: day("2023/01/04")).isEmpty)
        XCTAssertEqual(reopened.confirmedHistory.months.count, 1)
    }

    private func simulator(context: ModelContext, now: Date) throws -> (simObject, URLSession, URL) {
        LegacyHistoryURLProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LegacyHistoryURLProtocol.self]
        let session = URLSession(configuration: config)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TWSETradingCalendarSnapshot(version: 1, sourceURL: "isolated", fetchedAt: now,
            year: twDateTime.calendar.component(.year, from: now), entries: [])).write(to: url)
        let calendar = TWSETradingCalendar(fileURL: url, session: session, clock: { now })
        return (simObject(modelContext: context, tradingCalendar: calendar, marketSession: session, marketRetryDelays: []), session, url)
    }

    func testUpdateEntrySaveFailureCannotDownloadOrClaimCompletion() async throws {
        enum Failure: Error { case injected }
        let (container, stock, _, _) = try fixture()
        stock.twseHistoryCoverage = nil; try container.mainContext.save()
        let now = day("2023/01/05")
        let (sim, session, url) = try simulator(context: container.mainContext, now: now)
        defer { sim.tech.invalidateTimer(); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: url) }
        sim.tech.recalculationSave = { throw Failure.injected }
        let result = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        XCTAssertTrue(result.twse.historyCoverageSaveFailed)
        XCTAssertEqual(result.twse.remainingHistoryMonths, 1)
        XCTAssertTrue(LegacyHistoryURLProtocol.requests.isEmpty)
        XCTAssertFalse(result.twse.permitsRealtimeSimulation(for: stock.sId))
        XCTAssertNil(stock.twseHistoryCoverage)
        XCTAssertTrue(result.statusText.contains("保存失敗"))
    }

    func testIntradayQuoteAtUpdateEntryDoesNotRestartConfirmedHistory() async throws {
        let (container, stock, _, market) = try fixture()
        stock.twseHistoryCoverage = nil
        let now = day("2023/01/05").addingTimeInterval(12 * 3600)
        let quote = Trade(stock: stock, dateTime: now, dataSource: "yahoo")
        quote.priceClose = 100; quote.priceOpen = 100; quote.priceHigh = 101; quote.priceLow = 99
        container.mainContext.insert(quote)
        stock.yahooCheckedAt = now
        try container.mainContext.save()
        let (sim, session, url) = try simulator(context: container.mainContext, now: now)
        defer { sim.tech.invalidateTimer(); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(market.allSatisfy { $0.technicalStateVersion == 0 })
        let result = await sim.updateDailyPrices(stocks: [stock], clock: { now })
        XCTAssertEqual(result.twse.requestedMonths, 0)
        XCTAssertEqual(result.twse.remainingHistoryMonths, 0)
        XCTAssertFalse(LegacyHistoryURLProtocol.requests.contains { $0.contains("STOCK_DAY") })
        XCTAssertFalse(stock.confirmedHistory.contains(month: day("2023/01/01"), through: day("2023/01/05")))
        XCTAssertEqual(stock.technicalStateVersion, 4)
        XCTAssertFalse(sim.tech.lastRecalculationTrace.technicalDates.isEmpty)
    }

    /// Explicit opt-in, disposable copies only. Exercises the same full update
    /// entry as launch, including source planning, counts, T/S and cold reopen.
    func testFrozenLegacyStoresUseUpdateEntryWithoutBlanketSixMonthRedownload() async throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HistoryAdoption")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("t3-s64-normal.store").path) else {
            throw XCTSkip("Stage frozen copies in the isolated test host")
        }
        let runDirectory = directory.appendingPathComponent("run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        var reports: [[String: Any]] = []
        for name in ["t4-s65-migrated", "t3-s64-normal"] {
            let input = directory.appendingPathComponent(name + ".store")
            let output = runDirectory.appendingPathComponent(name + "-adopted.store")
            let inputHash = SHA256.hash(data: try Data(contentsOf: input))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "Use fresh evidence directory; never overwrite")
            try FileManager.default.copyItem(at: input, to: output)
            var after: [String: [String]] = [:]
            do {
                let schema = Schema([Stock.self, Trade.self, MarketDay.self])
                let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: output))
                container.mainContext.autosaveEnabled = false
                let stocks = try Stock.fetchGrouped(in: container.mainContext)
                XCTAssertEqual(stocks.count, 14)
                XCTAssertEqual(stocks.reduce(0) { $0 + $1.unconfirmedHistoryMonths(through: day("2026/10/08")).count }, 1282)
                // A saved, same-day Yahoo quote is not a historical receipt.
                let now = twDateTime.time1330(day("2026/10/08")).addingTimeInterval(3600)
                let (sim, session, url) = try simulator(context: container.mainContext, now: now)
                defer { sim.tech.invalidateTimer(); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: url) }
                let result = await sim.updateDailyPrices(stocks: stocks, clock: { now },
                    onProgress: { print("LEGACY \(name) \($0)") }, onBatchCompletion: { _ in nil })
                XCTAssertFalse(result.twse.historyCoverageSaveFailed)
                XCTAssertEqual(result.twse.remainingHistoryMonths, 5)
                XCTAssertEqual(result.twse.requestedMonths, 4, "First unresolved month per stock fails; one stock has two missing months")
                XCTAssertEqual(result.twse.failedMonths, 4)
                XCTAssertEqual(stocks.reduce(0) { $0 + ($1.confirmedHistory.legacyIntervals?.count ?? 0) }, 1277)
                XCTAssertTrue(result.statusText.contains("歷史尚待補 5 個月份"))
                XCTAssertEqual(result.twse.migratedDataRuleStocks, name == "t3-s64-normal" ? 14 : 0)
                let requests = LegacyHistoryURLProtocol.requests
                XCTAssertEqual(requests.count, 4)
                for stock in stocks {
                    let months = stock.unconfirmedHistoryMonths(through: day("2026/10/08")).map(TWSEHistoryCoverage.key)
                    if !months.isEmpty { after[stock.sId] = months }
                    XCTAssertEqual(stock.technicalStateVersion, 4)
                    XCTAssertEqual(stock.simulationStateVersion, 65)
                    XCTAssertNil(stock.technicalDirtyFrom); XCTAssertNil(stock.simulationDirtyFrom)
                }
                XCTAssertEqual(after, ["2368": ["201607", "202209"], "2449": ["202404"], "8454": ["201607"], "8467": ["202606"]])
                try container.mainContext.save()
                reports.append(["source": name, "adopted": 1277, "remaining": after, "requested": requests,
                    "migrated": result.twse.migratedDataRuleStocks])
                print("LEGACY COMPLETE \(name) adopted=1277 remaining=5 migrated=\(result.twse.migratedDataRuleStocks)")
            }
            do {
                let schema = Schema([Stock.self, Trade.self, MarketDay.self])
                let reopened = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: output))
                let stocks = try Stock.fetchGrouped(in: reopened.mainContext)
                XCTAssertEqual(stocks.reduce(0) { $0 + $1.unconfirmedHistoryMonths(through: day("2026/10/08")).count }, 5)
                let reads = OfficialPriceReadSession(context: reopened.mainContext)
                let technical = Technical(modelContext: reopened.mainContext)
                defer { technical.invalidateTimer() }
                for stock in stocks {
                    let before = stock.twseHistoryCoverage
                    try technical.adoptLegacyHistoryCoverage(for: stock, trades: reads.stockTrades(stock), marketDays: reads.marketDays())
                    XCTAssertEqual(before, stock.twseHistoryCoverage)
                }
            }
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: input)), inputHash)
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: runDirectory.appendingPathComponent("summary.json"))
        print("LEGACY_OUTPUT \(runDirectory.path)")
    }
}
