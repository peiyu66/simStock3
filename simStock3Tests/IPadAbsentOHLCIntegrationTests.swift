import Foundation
import SwiftData
import XCTest
@testable import simStock3

private final class AbsentOHLCCapturedProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var directory: URL!
    nonisolated(unsafe) static var requests: [String] = []
    nonisolated(unsafe) static var unexpected: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.append(url.absoluteString)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let stock = query.first { $0.name == "stockNo" }?.value ?? ""
        let date = query.first { $0.name == "date" }?.value ?? ""
        let file = Self.directory.appendingPathComponent("\(stock)-\(date.prefix(6)).json")
        guard url.path.hasSuffix("STOCK_DAY"), let body = try? Data(contentsOf: file) else {
            Self.unexpected.append(url.absoluteString)
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class IPadAbsentOHLCIntegrationTests: XCTestCase {
    func testTwoFullUpdatesAndColdReopenClearFivePendingMonthsWithoutPriceFabrication() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("exports/ohlc-absence-fix")
        let input = root.appendingPathComponent("inputs/ipad.store")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("Requires preserved iPad copy") }
        let run = root.appendingPathComponent("ipad-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let output = run.appendingPathComponent("replay.store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try FileManager.default.copyItem(at: input, to: output)
        AbsentOHLCCapturedProtocol.directory = project.appendingPathComponent("simStock3Tests/Fixtures/TWSEAbsentOHLC")
        let day = twDateTime.dateFromString("2026/10/22")!
        let now = day.addingTimeInterval(17 * 3600 + 37 * 60 + 15)
        let expected = ["2201": ["202003"], "2317": ["202507"],
                        "2449": ["202404"], "8467": ["202302", "202606"]]
        var reports: [[String: Any]] = []
        for round in 1...2 {
            AbsentOHLCCapturedProtocol.requests = []
            AbsentOHLCCapturedProtocol.unexpected = []
            let schema = Schema([Stock.self, Trade.self, MarketDay.self])
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, url: output))
            container.mainContext.autosaveEnabled = false
            let stocks = try Stock.fetchGrouped(in: container.mainContext)
            let before = Dictionary(uniqueKeysWithValues: stocks.map { ($0.sId, $0.twseHistoryCoverage) })
            func pending() -> [String: [String]] {
                Dictionary(uniqueKeysWithValues: stocks.compactMap { stock in
                    let months = stock.unconfirmedHistoryMonths(through: day).map(TWSEHistoryCoverage.key)
                    return months.isEmpty ? nil : (stock.sId, months)
                })
            }
            XCTAssertEqual(pending(), round == 1 ? expected : [:])
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AbsentOHLCCapturedProtocol.self]
            let session = URLSession(configuration: config)
            let calendarURL = run.appendingPathComponent("calendar-\(round).json")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(TWSETradingCalendarSnapshot(version: 1, sourceURL: "captured-diagnosis-no-network",
                fetchedAt: now, year: 2026, entries: [])).write(to: calendarURL)
            let calendar = TWSETradingCalendar(fileURL: calendarURL, session: session, clock: { now })
            let sim = simObject(modelContext: container.mainContext, tradingCalendar: calendar,
                                marketSession: session, marketRetryDelays: [])
            defer { sim.tech.invalidateTimer(); session.invalidateAndCancel() }
            let firstLog = simLog.Log.count
            let result = await sim.updateDailyPrices(stocks: stocks, clock: { now },
                onProgress: { print("IPAD DIAG ROUND \(round): \($0)") }, onBatchCompletion: { _ in nil })
            XCTAssertEqual(result.twse.requestedMonths, round == 1 ? 5 : 0)
            XCTAssertEqual(result.twse.failedMonths, 0)
            XCTAssertEqual(result.twse.remainingHistoryMonths, 0)
            XCTAssertEqual(result.twse.market.requestedMonths, 0)
            XCTAssertTrue(pending().isEmpty)
            XCTAssertTrue(AbsentOHLCCapturedProtocol.unexpected.isEmpty)
            XCTAssertEqual(AbsentOHLCCapturedProtocol.requests.count, round == 1 ? 5 : 0)
            XCTAssertEqual(AbsentOHLCCapturedProtocol.requests.contains { $0.contains("date=20230201") }, round == 1)
            for stock in stocks {
                if round == 2 || expected[stock.sId] == nil { XCTAssertEqual(stock.twseHistoryCoverage, before[stock.sId]!) }
                for month in expected[stock.sId] ?? [] {
                    XCTAssertNotNil(stock.confirmedHistory.months[month])
                    let absent = try XCTUnwrap(stock.confirmedHistory.noPriceDays?[month])
                    XCTAssertEqual(absent.count, 1)
                    XCTAssertNil(try Trade.fetch(in: container.mainContext, for: stock, on: absent[0].date))
                }
            }
            let logs = Array(simLog.Log.dropFirst(firstLog)).map(\.text)
            XCTAssertFalse(logs.contains { $0.contains("解析失敗") })
            XCTAssertEqual(logs.filter { $0.contains("RAW SAVE OK") }.count, round == 1 ? 5 : 0)
            try container.mainContext.save()
            reports.append(["round": round, "stocks": stocks.count, "requestedMonths": result.twse.requestedMonths,
                "failedMonths": result.twse.failedMonths, "pending": pending(), "statusText": result.statusText,
                "requests": AbsentOHLCCapturedProtocol.requests, "logs": logs])
            print("IPAD FIX ROUND \(round) COMPLETE: requests=\(result.twse.requestedMonths) failures=0 pending=0")
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: run.appendingPathComponent("two-rounds.json"))
        print("IPAD_FIX_OUTPUT \(run.path)")
    }
}
