import Foundation
import SwiftData
import XCTest
@testable import simStock3

nonisolated private final class TaiwanDateRequestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private let responseTime: Date
    private var count = 0

    init(requestTime: Date, responseTime: Date) {
        current = requestTime
        self.responseTime = responseTime
    }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return current
    }
    func beginResponse() {
        lock.lock(); defer { lock.unlock() }
        current = responseTime
    }
    var samples: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private final class TaiwanDateURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestClock: TaiwanDateRequestClock?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Advance only the injected clock once the request is actually sent;
        // no real wait or machine clock/timezone change is needed.
        Self.requestClock?.beginResponse()
        let requestedMonth = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "date" })?.value
        let sourceDate = requestedMonth?.hasPrefix("202402") == true ? "113/02/28" : "115/10/23"
        let payload: [String: Any] = ["stat": "OK", "data": [
            [sourceDate, "1000000", "100000000", "100", "101", "99", "100", "0", "1"]
        ]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The process default is changed only inside this serial MainActor suite and
/// always restored. No device setting, real feed, or user store is involved.
@MainActor
final class TradeTaiwanDateTests: XCTestCase {
    private let zones = ["Asia/Taipei", "UTC", "America/Los_Angeles", "Asia/Tokyo"]
    private func date(_ value: String) -> Date {
        twDateTime.dateFromString(value, format: "yyyy/MM/dd HH:mm:ss")!
    }
    private func fixture() throws -> (ModelContainer, Stock) {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let stock = Stock(sId: "TZTEST", sName: "日期隔離測試", group: "A",
            dateFirst: date("2025/10/01 00:00:00"), dateStart: date("2026/10/01 13:30:00"))
        context.insert(stock)
        try context.save()
        return (container, stock)
    }

    func testRealTWSEImportFindsSameTaiwanDayAndRetainsManualIntentAcrossTimezones() async throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let (container, stock) = try fixture()
        let context = container.mainContext
        let previous = Trade(stock: stock, dateTime: date("2026/10/22 13:30:00"), dataSource: "TWSE")
        previous.priceClose = 75
        previous.simReversed = "B"
        previous.simInvestByUser = 2
        context.insert(previous)
        try context.save()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TaiwanDateURLProtocol.self]
        let session = URLSession(configuration: config)
        let technical = Technical(modelContext: context, priceSession: session)
        defer { technical.invalidateTimer(); session.invalidateAndCancel(); withExtendedLifetime(container) {} }
        var targetID: PersistentIdentifier?
        for zone in zones {
            NSTimeZone.default = TimeZone(identifier: zone)!
            XCTAssertEqual(Calendar.current.timeZone.secondsFromGMT(for: date("2026/10/23 00:00:00")),
                TimeZone(identifier: zone)!.secondsFromGMT(for: date("2026/10/23 00:00:00")))
            let first = await technical.twseRequestAsync(stock: stock,
                dateStart: date("2026/10/01 00:00:00"), recalculate: false)
            XCTAssertTrue(first, zone)
            let row = try XCTUnwrap(Trade.fetch(in: context, for: stock, on: date("2026/10/23 00:00:00")), zone)
            if let targetID { XCTAssertEqual(row.persistentModelID, targetID, zone) }
            targetID = row.persistentModelID
            row.simReversed = "S"
            row.simInvestByUser = 3
            stock.p10Date = row.date
            try context.save()
            let second = await technical.twseRequestAsync(stock: stock,
                dateStart: date("2026/10/01 00:00:00"), recalculate: false)
            XCTAssertTrue(second, zone)
            XCTAssertEqual(try Trade.fetch(in: context, for: stock).count, 2, zone)
            XCTAssertEqual(row.dateTime, date("2026/10/23 13:30:00"), zone)
            XCTAssertEqual(row.date, date("2026/10/23 00:00:00"), zone)
            XCTAssertEqual(stock.p10Date, row.date, zone)
            XCTAssertEqual(row.simReversed, "S", zone)
            XCTAssertEqual(row.simInvestByUser, 3, zone)
            XCTAssertEqual(previous.priceClose, 75, zone)
            XCTAssertEqual(previous.simReversed, "B", zone)
            XCTAssertEqual(previous.simInvestByUser, 2, zone)
        }
    }


    func testMonthlyReceiptUsesRequestClockWhenResponseCrossesLeapMonthBoundary() async throws {
        let (container, stock) = try fixture()
        let context = container.mainContext
        stock.dateFirst = date("2024/02/01 00:00:00")
        stock.dateStart = date("2025/02/01 00:00:00")
        try context.save()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TaiwanDateURLProtocol.self]
        let session = URLSession(configuration: config)
        let technical = Technical(modelContext: context, priceSession: session)
        defer { technical.invalidateTimer(); session.invalidateAndCancel(); withExtendedLifetime(container) {} }
        let month = date("2024/02/01 00:00:00")
        let beforeBoundary = date("2024/02/29 23:59:59").addingTimeInterval(0.5)
        let afterBoundary = date("2024/03/01 00:00:00")
        let crossingClock = TaiwanDateRequestClock(requestTime: beforeBoundary, responseTime: afterBoundary)
        TaiwanDateURLProtocol.requestClock = crossingClock
        defer { TaiwanDateURLProtocol.requestClock = nil }
        let first = await technical.twseRequestAsync(stock: stock, dateStart: month, recalculate: false,
            clock: crossingClock.now)
        XCTAssertTrue(first)
        XCTAssertEqual(crossingClock.samples, 1, "Capture the request timestamp exactly once before sending")
        XCTAssertEqual(stock.confirmedHistory.months["202402"], date("2024/02/28 23:59:59"),
            "A response arriving in March cannot certify missing February dates for a request sent in February")
        let newMonthClock = TaiwanDateRequestClock(requestTime: afterBoundary, responseTime: afterBoundary)
        TaiwanDateURLProtocol.requestClock = newMonthClock
        let second = await technical.twseRequestAsync(stock: stock, dateStart: month, recalculate: false,
            clock: newMonthClock.now)
        XCTAssertTrue(second)
        XCTAssertEqual(newMonthClock.samples, 1, "A new request after month end can certify the whole source month")
        XCTAssertEqual(stock.confirmedHistory.months["202402"], date("2024/02/29 23:59:59"))
        XCTAssertEqual(try Trade.fetch(in: context, for: stock).count, 1)
        XCTAssertEqual(stock.dateStart, date("2025/02/01 00:00:00"))
    }

    func testTradeInitialMarkerUsesTaiwanDayRatherThanDeviceMidnight() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let (container, stock) = try fixture()
        defer { withExtendedLifetime(container) {} }
        stock.dateStart = date("2026/10/23 13:30:00")
        for zone in zones {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let sameDay = Trade(stock: stock, dateTime: date("2026/10/23 00:00:00"))
            let before = Trade(stock: stock, dateTime: date("2026/10/22 23:59:59").addingTimeInterval(0.5))
            XCTAssertEqual(sameDay.simRule, "", zone)
            XCTAssertEqual(before.simRule, "_", zone)
        }
    }

    func testDailyFetchAndEnsureIncludeFractionalLastSecondAndExcludeNextMidnight() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let (container, stock) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let before = Trade(stock: stock, dateTime: date("2026/10/22 23:59:59").addingTimeInterval(0.75))
        let tail = Trade(stock: stock, dateTime: date("2026/10/23 23:59:59").addingTimeInterval(0.75))
        tail.simReversed = "B"; tail.simInvestByUser = 2
        let next = Trade(stock: stock, dateTime: date("2026/10/24 00:00:00"))
        for row in [before, tail, next] { context.insert(row) }
        try context.save()
        for zone in zones {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let found = try Trade.fetch(in: context, for: stock, on: date("2026/10/23 00:00:00"))
            XCTAssertEqual(found?.persistentModelID, tail.persistentModelID, zone)
            let ensured = try Trade.ensureTrade(in: context, for: stock, on: date("2026/10/23 12:00:00"))
            XCTAssertEqual(ensured.persistentModelID, tail.persistentModelID, zone)
            XCTAssertEqual(ensured.simReversed, "B", zone)
            XCTAssertEqual(ensured.simInvestByUser, 2, zone)
            XCTAssertEqual(try Trade.fetch(in: context, for: stock).count, 3, zone)
        }
    }

    func testEnsureCreatesExactlyTaiwanCloseOnceAcrossDefaultTimezones() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let (container, stock) = try fixture()
        defer { withExtendedLifetime(container) {} }
        var firstID: PersistentIdentifier?
        for zone in zones {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let row = try Trade.ensureTrade(in: container.mainContext, for: stock, on: date("2026/10/23 00:00:00"))
            try container.mainContext.save()
            if let firstID { XCTAssertEqual(row.persistentModelID, firstID, zone) }
            firstID = row.persistentModelID
            XCTAssertEqual(row.dateTime, date("2026/10/23 13:30:00"), zone)
            XCTAssertEqual(try Trade.fetch(in: container.mainContext, for: stock).count, 1, zone)
        }
    }

    func testExplicitDuplicateCleanupUsesHalfOpenTaiwanDayOnly() throws {
        let original = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = original }
        let (container, stock) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let before = Trade(stock: stock, dateTime: date("2026/10/22 23:59:59"))
        let keep = Trade(stock: stock, dateTime: date("2026/10/23 13:30:00"))
        keep.simReversed = "B"; keep.simInvestByUser = 1
        let tail = Trade(stock: stock, dateTime: date("2026/10/23 23:59:59").addingTimeInterval(0.5))
        let next = Trade(stock: stock, dateTime: date("2026/10/24 00:00:00"))
        for row in [before, keep, tail, next] { context.insert(row) }
        try context.save()
        try Trade.deleteDuplicates(in: context, for: stock, on: date("2026/10/23 00:00:00"))
        let remaining = try Trade.fetch(in: context, for: stock, ascending: true)
        XCTAssertEqual(remaining.map(\.dateTime), [before.dateTime, keep.dateTime, next.dateTime])
        XCTAssertEqual(keep.simReversed, "B")
        XCTAssertEqual(keep.simInvestByUser, 1)
    }

    func testP10DayAndLedgerKeySurviveColdReopenInDifferentTimezones() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("dates.store"))
        var key: Data!
        NSTimeZone.default = TimeZone(identifier: "Asia/Taipei")!
        do {
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = container.mainContext
            context.autosaveEnabled = false
            let stock = Stock(sId: "COLD", sName: "冷重開", group: "A",
                dateFirst: date("2025/10/01 00:00:00"), dateStart: date("2026/10/01 00:00:00"))
            context.insert(stock)
            let quote = Trade(stock: stock, dateTime: date("2026/10/23 09:20:00"), dataSource: "yahoo")
            quote.priceClose = 100; quote.simReversed = "B"; quote.simInvestByUser = 2
            context.insert(quote)
            stock.p10Date = quote.date
            try context.save()
            let ledger = UpdateWorkLedger(context: context)
            ledger.refresh()
            XCTAssertTrue(ledger.isReliable)
            ledger.rememberP10(stock, quote: quote)
            key = ledger.p10Key(for: stock, quote: quote)
            try ledger.persist()
        }
        for zone in zones.dropFirst() {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = container.mainContext
            context.autosaveEnabled = false
            let stock = try XCTUnwrap(Stock.fetchAll(in: context).first)
            let quote = try XCTUnwrap(Trade.fetch(in: context, for: stock, on: date("2026/10/23 00:00:00")))
            let ledger = UpdateWorkLedger(context: context)
            ledger.refresh()
            XCTAssertEqual(stock.p10Date, quote.date, zone)
            XCTAssertEqual(quote.date, date("2026/10/23 00:00:00"), zone)
            XCTAssertEqual(ledger.p10Key(for: stock, quote: quote), key, zone)
            XCTAssertTrue(ledger.hasP10(stock, quote: quote), zone)
            XCTAssertEqual(quote.simReversed, "B", zone)
            XCTAssertEqual(quote.simInvestByUser, 2, zone)
            XCTAssertFalse(context.hasChanges, zone)
        }
    }

    func testStockAndCalculationWindowShareNormalizedLeapYearPreparationDate() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let (container, stock) = try fixture()
        defer { withExtendedLifetime(container) {} }
        for zone in zones {
            NSTimeZone.default = TimeZone(identifier: zone)!
            stock.dateStart = date("2024/02/29 23:59:59")
            let window = CalculationWindow(configuredStart: stock.dateStart, prices: [
                (date("2023/02/28 00:00:00"), 100), (date("2024/02/29 13:30:00"), 100)
            ])
            XCTAssertEqual(stock.dateRequestStart, date("2023/02/28 00:00:00"), zone)
            XCTAssertEqual(stock.dateRequestStart, window.requestStart, zone)
            XCTAssertEqual(window.simulationStart, date("2024/02/29 00:00:00"), zone)
        }
    }

    func testStockAndTradeAnnualizationRetainOriginal365DayFormula() throws {
        let (container, stock) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        stock.dateStart = date("2024/01/02 00:00:00")
        let first = Trade(stock: stock, dateTime: date("2023/01/02 13:30:00"), dataSource: "TWSE")
        first.priceClose = 100
        let last = Trade(stock: stock, dateTime: date("2026/10/23 13:30:00"), dataSource: "TWSE")
        last.priceClose = 100
        context.insert(first); context.insert(last)
        try context.save()
        let start = try XCTUnwrap(stock.effectiveSimulationStart)
        let expected = max(1, twDateTime.startOfDay(last.dateTime).timeIntervalSince(start) / 86400 / 365)
        XCTAssertEqual(stock.years, expected)
        XCTAssertEqual(last.years, expected)
        XCTAssertEqual(first.years, 1)
    }

    func testLegacyMonthReceiptsKeepTheirInclusiveValuesAcrossLeapMonthAndYear() {
        for (month, next) in [("2024/02/01 00:00:00", "2024/03/01 00:00:00"),
                              ("2025/12/01 00:00:00", "2026/01/01 00:00:00")] {
            let start = date(month)
            let end = date(next)
            var coverage = TWSEHistoryCoverage()
            coverage.adoptLegacy(stockDates: [start, end], marketDates: [start, end],
                requestStart: start, through: end)
            let interval = coverage.legacyIntervals?[TWSEHistoryCoverage.key(start)]
            XCTAssertEqual(interval?.from, start)
            XCTAssertEqual(interval?.through, end.addingTimeInterval(-1))
            XCTAssertTrue(coverage.contains(month: start, through: end.addingTimeInterval(-1)))
            XCTAssertFalse(coverage.contains(month: start, through: end))
        }
    }
}
