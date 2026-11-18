import Foundation
import SwiftData
import XCTest
@testable import simStock3

/// Responses are released explicitly by the test, not by sleep/timing guesses.
nonisolated private final class HeldYahooProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [String: HeldYahooProtocol] = [:]
    nonisolated(unsafe) private static var started: [String] = []
    nonisolated(unsafe) private static var peak = 0
    nonisolated(unsafe) private static var stopped = 0
    nonisolated(unsafe) private static var stopWaiters: [(Int, XCTestExpectation)] = []
    nonisolated(unsafe) private static var waiters: [(Int, XCTestExpectation)] = []
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = [:]; started = []; peak = 0; waiters = []; stopped = 0; stopWaiters = []
    }
    static var starts: [String] { lock.lock(); defer { lock.unlock() }; return started }
    static var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
    static var active: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(pending.keys) }
    static func startedExpectation(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "HTTP starts >= \(count)")
        lock.lock()
        if started.count >= count { expectation.fulfill() } else { waiters.append((count, expectation)) }
        lock.unlock()
        return expectation
    }
    static func stoppedExpectation(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "HTTP cancellations >= \(count)")
        lock.lock()
        if stopped >= count { expectation.fulfill() } else { stopWaiters.append((count, expectation)) }
        lock.unlock()
        return expectation
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url!.lastPathComponent
        Self.lock.lock()
        Self.pending[key] = self; Self.started.append(key)
        Self.peak = max(Self.peak, Self.pending.count)
        let fulfilled = Self.waiters.filter { Self.started.count >= $0.0 }
        Self.waiters.removeAll { Self.started.count >= $0.0 }
        Self.lock.unlock()
        fulfilled.forEach { $0.1.fulfill() }
    }
    override func stopLoading() {
        Self.lock.lock()
        let key = request.url!.lastPathComponent
        if Self.pending[key] === self {
            Self.pending.removeValue(forKey: key); Self.stopped += 1
        }
        let fulfilled = Self.stopWaiters.filter { Self.stopped >= $0.0 }
        Self.stopWaiters.removeAll { Self.stopped >= $0.0 }
        Self.lock.unlock()
        fulfilled.forEach { $0.1.fulfill() }
    }
    @discardableResult static func respond(_ id: String, html: String, status: Int = 200) -> Bool {
        lock.lock(); let task = pending.removeValue(forKey: id); lock.unlock()
        guard let task else { return false }
        task.client?.urlProtocol(task, didReceive: HTTPURLResponse(url: task.request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        task.client?.urlProtocol(task, didLoad: Data(html.utf8))
        task.client?.urlProtocolDidFinishLoading(task)
        return true
    }
}

@MainActor final class YahooConcurrentRequestTests: XCTestCase {
    private func date(_ s: String) -> Date { twDateTime.strictDateFromString(s, format: "yyyy/MM/dd HH:mm")! }
    private var now: Date { date("2026/11/18 10:00") }
    private func html(_ time: String = "2026/11/18 10:00", close: Double = 105) -> String {
        "<time datetime=\"\(time)\"></time>" + [("開盤",100.0),("最高",120.0),("最低",90.0),("成交",close),("總量",10.0)]
            .map { "<span>\($0.0)</span><span>\($0.1)</span>" }.joined()
    }
    private func fixture(_ count: Int) throws -> (ModelContainer, Technical, [Stock], URLSession, URL) {
        HeldYahooProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HeldYahooProtocol.self]
        let session = URLSession(configuration: config)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = now
        let calendar = TWSETradingCalendar(fileURL: file, session: session, clock: { clock })
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let stocks = (0..<count).map { index in
            let stock = Stock(sId: "S\(index)", sName: "測試\(index)", group: "A",
                dateFirst: date("2025/01/01 00:00"), dateStart: date("2026/01/01 00:00"))
            context.insert(stock)
            let row = Trade(stock: stock, dateTime: date("2026/11/17 13:30"))
            row.priceClose = 100; row.dataSource = "TWSE"; row.simReversed = "S+"; row.simInvestByUser = 1
            context.insert(row)
            return stock
        }
        try context.save()
        return (container, Technical(modelContext: context, tradingCalendar: calendar, priceSession: session), stocks, session, file)
    }
    private func waitFor(_ count: Int) async {
        await fulfillment(of: [HeldYahooProtocol.startedExpectation(count)], timeout: 3)
    }
    private func rows(_ stock: Stock, in context: ModelContext) throws -> [Trade] {
        try Trade.fetch(in: context, for: stock, ascending: true)
    }
    private func snapshot(_ stocks: [Stock], in context: ModelContext) throws -> [String] {
        try stocks.flatMap { stock in
            var values = ["\(stock.sId)|\(stock.yahooCheckedAt?.timeIntervalSince1970 ?? -1)|\(stock.technicalDirtyFrom?.timeIntervalSince1970 ?? -1)|\(stock.simulationDirtyFrom?.timeIntervalSince1970 ?? -1)"]
            values += try rows(stock, in: context).map { t in
                "\(stock.sId)|\(t.dateTime.timeIntervalSince1970)|\(t.priceOpen)|\(t.priceHigh)|\(t.priceLow)|\(t.priceClose)|\(t.volumeClose)|\(t.dataSource)|\(t.simReversed)|\(t.simInvestByUser)"
            }
            return values
        }
    }
    func testSlowFirstResponseDoesNotBlockFollowingStocksAndNeverExceedsThree() async throws {
        let (container, tech, stocks, session, file) = try fixture(6)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file); withExtendedLifetime(container) {} }
        let now = now
        var progress: [String] = []
        let task = Task { await tech.updateYahooPrices(stocks: stocks, updateMarket: false, asOf: now,
            rawPricesOnly: true, onProgress: { progress.append($0) }) }
        await waitFor(3)
        XCTAssertEqual(Set(HeldYahooProtocol.starts), ["S0", "S1", "S2"])
        XCTAssertEqual(HeldYahooProtocol.active.count, 3)
        XCTAssertTrue(HeldYahooProtocol.respond("S1", html: html(close: 106)))
        await waitFor(4)
        XCTAssertTrue(HeldYahooProtocol.active.contains("S0"))
        XCTAssertEqual(try rows(stocks[1], in: container.mainContext).last?.priceClose, 106)
        XCTAssertEqual(try rows(stocks[0], in: container.mainContext).count, 1)
        XCTAssertTrue(HeldYahooProtocol.respond("S3", html: html()))
        await waitFor(5)
        XCTAssertTrue(HeldYahooProtocol.respond("S2", html: html()))
        await waitFor(6)
        for id in ["S5", "S4", "S0"] { XCTAssertTrue(HeldYahooProtocol.respond(id, html: html())) }
        let summary = await task.value
        XCTAssertEqual(summary.requestedStocks, 6); XCTAssertEqual(summary.updatedStocks, 6)
        XCTAssertEqual(summary.successfulStockIDs, Set(stocks.map(\.sId)))
        XCTAssertEqual(HeldYahooProtocol.maximum, 3)
        XCTAssertEqual(progress.count, 6)
        for index in 0..<6 { XCTAssertTrue(progress[index].hasPrefix("\(index + 1)/6 S\(index)")) }
        for stock in stocks {
            let saved = try rows(stock, in: container.mainContext)
            XCTAssertEqual(saved.count, 2); XCTAssertEqual(saved[0].simReversed, "S+")
            XCTAssertEqual(saved[0].simInvestByUser, 1)
            XCTAssertEqual(stock.yahooCheckedAt, now); XCTAssertNotNil(stock.technicalDirtyFrom)
        }
    }
    func testCancellationCancelsOutstandingRequestsWithoutStartingRestOrWritingLateReplies() async throws {
        let (container, tech, stocks, session, file) = try fixture(6)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file); withExtendedLifetime(container) {} }
        let now = now
        let task = Task { await tech.updateYahooPrices(stocks: stocks, updateMarket: false, asOf: now, rawPricesOnly: true) }
        await waitFor(3)
        XCTAssertTrue(HeldYahooProtocol.respond("S1", html: html()))
        await waitFor(4) // A committed success remains, outstanding work is cancelled.
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.updatedStocks, 1); XCTAssertEqual(result.successfulStockIDs, ["S1"])
        XCTAssertEqual(HeldYahooProtocol.starts.count, 4)
        await fulfillment(of: [HeldYahooProtocol.stoppedExpectation(3)], timeout: 3)
        XCTAssertTrue(HeldYahooProtocol.active.isEmpty)
        for index in [0, 2, 3, 4, 5] {
            XCTAssertEqual(try rows(stocks[index], in: container.mainContext).count, 1)
            XCTAssertNil(stocks[index].yahooCheckedAt)
        }
        XCTAssertFalse(HeldYahooProtocol.respond("S0", html: html(close: 110)))
    }
    func testAdmissionClosingStopsRefillButPreservesAlreadySentValidReplies() async throws {
        let (container, tech, stocks, session, file) = try fixture(5)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file); withExtendedLifetime(container) {} }
        let now = now
        var allowed = true
        let task = Task { await tech.updateYahooPrices(stocks: stocks, updateMarket: false, asOf: now,
            rawPricesOnly: true, permitsNextRequest: { allowed }) }
        await waitFor(3); allowed = false
        for id in ["S2", "S1", "S0"] { XCTAssertTrue(HeldYahooProtocol.respond(id, html: html())) }
        let result = await task.value
        XCTAssertEqual(result.requestedStocks, 3); XCTAssertEqual(result.updatedStocks, 3)
        XCTAssertEqual(HeldYahooProtocol.starts.count, 3); XCTAssertTrue(HeldYahooProtocol.active.isEmpty)
        for (index, stock) in stocks.enumerated() {
            XCTAssertEqual(try rows(stock, in: container.mainContext).count, index < 3 ? 2 : 1)
        }
    }
    func testCancelledOrDisallowedBatchStartsNoHTTP() async throws {
        for cancel in [false, true] {
            let (container, tech, stocks, session, file) = try fixture(4)
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file); withExtendedLifetime(container) {} }
            let now = now
            let task = Task { await tech.updateYahooPrices(stocks: stocks, updateMarket: false, asOf: now,
                rawPricesOnly: true, permitsNextRequest: { cancel }) }
            if cancel { task.cancel() }
            let result = await task.value
            XCTAssertEqual(result.requestedStocks, 0); XCTAssertEqual(result.updatedStocks, 0)
            XCTAssertTrue(HeldYahooProtocol.starts.isEmpty)
            for stock in stocks { XCTAssertEqual(try rows(stock, in: container.mainContext).count, 1) }
        }
    }
    func testFailedStockDoesNotBlockRefillAndSummaryDatesRetainInputOrder() async throws {
        let (container, tech, stocks, session, file) = try fixture(4)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file); withExtendedLifetime(container) {} }
        let now = now
        let task = Task { await tech.updateYahooPrices(stocks: stocks, updateMarket: false, asOf: now, rawPricesOnly: true) }
        await waitFor(3)
        XCTAssertTrue(HeldYahooProtocol.respond("S1", html: "unavailable", status: 503))
        await waitFor(4)
        XCTAssertTrue(HeldYahooProtocol.respond("S3", html: html("2026/11/17 13:30")))
        XCTAssertTrue(HeldYahooProtocol.respond("S2", html: html("2026/11/18 09:59")))
        XCTAssertTrue(HeldYahooProtocol.respond("S0", html: html()))
        let result = await task.value
        XCTAssertEqual(result.successfulStockIDs, ["S0", "S2"])
        XCTAssertEqual(result.quoteDates, [now, date("2026/11/18 09:59"), date("2026/11/17 13:30")])
        XCTAssertEqual(result.updatedStocks, 2); XCTAssertEqual(result.requestedStocks, 4)
        XCTAssertNil(stocks[1].yahooCheckedAt); XCTAssertNil(stocks[3].yahooCheckedAt)
    }
    func testWritesRecheckCurrentTWSEAndNewerYahooRowsAfterNetworkSuspension() async throws {
        let (container, tech, stocks, session, file) = try fixture(3)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file); withExtendedLifetime(container) {} }
        let now = now, context = container.mainContext
        let task = Task { await tech.updateYahooPrices(stocks: stocks, updateMarket: false, asOf: now, rawPricesOnly: true) }
        await waitFor(3)
        let official = try Trade.ensureTrade(in: context, for: stocks[0], on: now)
        official.dataSource = "TWSE"; official.priceClose = 112
        let newer = try Trade.ensureTrade(in: context, for: stocks[1], on: now)
        newer.dataSource = "yahoo"; newer.priceClose = 113
        context.delete(stocks[2]); try context.save()
        for id in ["S2", "S1", "S0"] { XCTAssertTrue(HeldYahooProtocol.respond(id, html: html("2026/11/18 09:59"))) }
        let result = await task.value
        XCTAssertEqual(official.priceClose, 112); XCTAssertEqual(newer.priceClose, 113)
        XCTAssertEqual(result.updatedStocks, 0); XCTAssertEqual(result.successfulStockIDs, ["S0"])
    }
    func testOutOfOrderOlderStockCannotRewindSharedQuoteTimeAcrossClose() async throws {
        let (container, tech, stocks, session, file) = try fixture(4)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file); withExtendedLifetime(container) {} }
        let closeNow = date("2026/11/18 13:34")
        let task = Task { await tech.updateYahooPrices(stocks: stocks, updateMarket: false, asOf: closeNow, rawPricesOnly: true) }
        await waitFor(3)
        XCTAssertTrue(HeldYahooProtocol.respond("S1", html: html("2026/11/18 13:33")))
        await waitFor(4) // S0 is still held; S1 has already saved and refilled the slot.
        XCTAssertTrue(HeldYahooProtocol.active.contains("S0"))
        XCTAssertEqual(tech.timeLastTrade, date("2026/11/18 13:33"))
        for id in ["S3", "S2", "S0"] {
            XCTAssertTrue(HeldYahooProtocol.respond(id, html: html("2026/11/18 13:20")))
        }
        let result = await task.value
        XCTAssertEqual(result.updatedStocks, 4)
        XCTAssertEqual(tech.timeLastTrade, date("2026/11/18 13:33"))
        // isMarketingTime uses this same session predicate; older responses must
        // not turn a post-close observation back into a pre-close observation.
        XCTAssertFalse(twDateTime.inMarketingTime(tech.timeLastTrade, forToday: true, asOf: closeNow))
        XCTAssertEqual(result.quoteDates, [date("2026/11/18 13:20"), date("2026/11/18 13:33"),
                                          date("2026/11/18 13:20"), date("2026/11/18 13:20")])
    }
    func testMarketAndFinalSummaryWaitForAllStockReplies() async throws {
        let (container, tech, stocks, session, file) = try fixture(4)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file); withExtendedLifetime(container) {} }
        let now = now
        var completed = false
        let task = Task {
            let result = await tech.updateYahooPrices(stocks: stocks, updateMarket: true, asOf: now, rawPricesOnly: true)
            completed = true
            return result
        }
        await waitFor(3)
        XCTAssertTrue(HeldYahooProtocol.respond("S1", html: html()))
        await waitFor(4)
        XCTAssertTrue(HeldYahooProtocol.respond("S2", html: html()))
        XCTAssertTrue(HeldYahooProtocol.respond("S3", html: html()))
        XCTAssertTrue(HeldYahooProtocol.active.contains("S0"))
        XCTAssertFalse(HeldYahooProtocol.starts.contains("^TWII")); XCTAssertFalse(completed)
        XCTAssertTrue(HeldYahooProtocol.respond("S0", html: html()))
        await waitFor(5)
        XCTAssertEqual(HeldYahooProtocol.starts.last, "^TWII")
        for stock in stocks { XCTAssertEqual(try rows(stock, in: container.mainContext).count, 2) }
        XCTAssertFalse(completed)
        XCTAssertTrue(HeldYahooProtocol.respond("^TWII", html: "unavailable", status: 503))
        let result = await task.value
        XCTAssertTrue(completed); XCTAssertTrue(result.marketFailed)
        XCTAssertEqual(result.updatedStocks, 4); XCTAssertEqual(result.successfulStockIDs.count, 4)
    }
    func testParallelPersistedValuesMatchSequentialReferenceWithSameResponses() async throws {
        var reference: [String] = []
        for parallel in [false, true] {
            let (container, tech, stocks, session, file) = try fixture(6)
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file); withExtendedLifetime(container) {} }
            let now = now
            let task = Task {
                if parallel { _ = await tech.updateYahooPrices(stocks: stocks, updateMarket: false, asOf: now, rawPricesOnly: true) }
                else { for stock in stocks { _ = await tech.fetchYahooPrice(stock, asOf: now) } }
            }
            if parallel {
                await waitFor(3)
                for (id, count) in [("S2",4),("S3",5),("S4",6)] {
                    XCTAssertTrue(HeldYahooProtocol.respond(id, html: html(close: Double(id.dropFirst())! + 100)))
                    await waitFor(count)
                }
                for id in ["S5","S1","S0"] { XCTAssertTrue(HeldYahooProtocol.respond(id, html: html(close: Double(id.dropFirst())! + 100))) }
            } else {
                for index in 0..<6 {
                    await waitFor(index + 1)
                    XCTAssertEqual(HeldYahooProtocol.active.count, 1)
                    XCTAssertTrue(HeldYahooProtocol.respond("S\(index)", html: html(close: Double(index) + 100)))
                }
            }
            await task.value
            // A new context reads saved rows, not the original model objects.
            let reopened = ModelContext(container)
            let saved = try Stock.fetchGrouped(in: reopened).sorted { $0.sId < $1.sId }
            let values = try snapshot(saved, in: reopened)
            if parallel { XCTAssertEqual(values, reference); XCTAssertEqual(HeldYahooProtocol.maximum, 3) }
            else { reference = values; XCTAssertEqual(HeldYahooProtocol.maximum, 1) }
        }
    }
}
