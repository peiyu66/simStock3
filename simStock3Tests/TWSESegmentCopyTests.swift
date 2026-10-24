import Foundation
import SwiftData
import XCTest
@testable import simStock3

nonisolated private final class SegmentRecordedResponses: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    static func configure(_ values: [String: Data]) { lock.lock(); defer { lock.unlock() }; bodies = values; requests = [] }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let stock = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "stockNo" }?.value
        let key = stock ?? (url.path == "/indicesReport/MI_5MINS_HIST" ? "MARKET" : "UNEXPECTED")
        Self.lock.lock(); Self.requests.append(url.absoluteString); let body = Self.bodies[key]; Self.lock.unlock()
        guard let body else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class TWSESegmentCopyTests: XCTestCase {
    func testRecordedSaturdayResponsesStopRepeatChecksWithoutChangingSavedValues() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("exports/twse-segment-20261024")
        let input = root.appendingPathComponent("fixture/input.store")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("Requires explicitly isolated device copy") }
        let run = root.appendingPathComponent("copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let output = run.appendingPathComponent("copy.store")
        try FileManager.default.copyItem(at: input, to: output)
        let objects = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture/responses.json"))) as! [String: Any]
        let bodies = try objects.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        SegmentRecordedResponses.configure(bodies)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SegmentRecordedResponses.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let now = twDateTime.dateFromString("2026/10/24 06:42", format: "yyyy/MM/dd HH:mm")!
        let file = run.appendingPathComponent("calendar.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TWSETradingCalendarSnapshot(version: 1, sourceURL: "recorded-test", fetchedAt: now,
            year: 2026, entries: [])).write(to: file)
        let calendar = TWSETradingCalendar(fileURL: file, session: session, clock: { now })
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: output))
        container.mainContext.autosaveEnabled = false
        let sim = simObject(modelContext: container.mainContext, tradingCalendar: calendar, marketSession: session, marketRetryDelays: [])
        let stocks = try Stock.fetchGrouped(in: container.mainContext)
        XCTAssertEqual(stocks.count, 18)
        var evidence: [[String: Any]] = []
        for pass in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            let before = SegmentRecordedResponses.count
            let result = await sim.updateDailyPrices(stocks: stocks, clock: { now })
            let requests = SegmentRecordedResponses.count - before
            XCTAssertEqual(requests, pass == 0 ? 19 : 0)
            XCTAssertEqual(result.twse.requestedMonths, pass == 0 ? 18 : 0)
            XCTAssertEqual(result.twse.market.requestedMonths, pass == 0 ? 1 : 0)
            XCTAssertEqual(result.yahoo.requestedStocks, 0)
            XCTAssertFalse(result.hasIncompleteWork, result.statusText)
            XCTAssertEqual(result.twse.remainingHistoryMonths, 0)
            XCTAssertTrue(result.twse.calculatedStockIDs.isEmpty)
            XCTAssertEqual(result.twse.timings.p10Executions, 0)
            XCTAssertEqual(result.twse.checkedWithoutNewPriceStockIDs.count, 18)
            if pass > 0 {
                XCTAssertEqual(result.twse.timings.stockHistoryReads, 0)
                XCTAssertEqual(result.twse.timings.windowInputScans, 0)
            }
            evidence.append(["pass": pass, "requests": requests, "seconds": ProcessInfo.processInfo.systemUptime - start,
                "status": result.statusText, "timings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.twse.timings))])
        }
        let reopened = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: output))
        let resumed = simObject(modelContext: reopened.mainContext, tradingCalendar: calendar, marketSession: session, marketRetryDelays: [])
        let before = SegmentRecordedResponses.count
        let result = await resumed.updateDailyPrices(clock: { now })
        XCTAssertEqual(SegmentRecordedResponses.count, before)
        XCTAssertFalse(result.hasIncompleteWork)
        XCTAssertEqual(result.twse.timings.stockHistoryReads, 0)
        XCTAssertEqual(result.twse.timings.windowInputScans, 0)
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: run.appendingPathComponent("results.json"))
        print("SEGMENT_COPY_OUTPUT \(run.path)")
        withExtendedLifetime((container, reopened)) {}
    }
}
