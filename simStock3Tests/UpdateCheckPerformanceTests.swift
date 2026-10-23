import Foundation
import SwiftData
import XCTest
@testable import simStock3

nonisolated private final class UpdateCheckNoNetwork: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.paths.append(request.url!.absoluteString); Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }
    override func stopLoading() {}
}

/// Optional local evidence. Never reads the user's live store and never makes
/// requests; the runner explicitly supplies a previously isolated source copy.
@MainActor final class UpdateCheckPerformanceTests: XCTestCase {
    func testCompletedPausedForegroundCopyHasZeroRepeatedHistoryWork() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("exports/update-check-20261023")
        let input = root.appendingPathComponent("input.store")
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw XCTSkip("Requires the explicitly prepared isolated input copy")
        }
        let run = root.appendingPathComponent("run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let output = run.appendingPathComponent("copy.store")
        try FileManager.default.copyItem(at: input, to: output)
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: output))
        container.mainContext.autosaveEnabled = false
        let stocks = try Stock.fetchGrouped(in: container.mainContext)
        let now = twDateTime.dateFromString("2026/10/23 10:00", format: "yyyy/MM/dd HH:mm")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateCheckNoNetwork.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let calendarURL = run.appendingPathComponent("calendar.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TWSETradingCalendarSnapshot(version: 1, sourceURL: "isolated-no-network", fetchedAt: now,
            year: 2026, entries: [])).write(to: calendarURL)
        let calendar = TWSETradingCalendar(fileURL: calendarURL, session: session, clock: { now })
        try await calendar.setYahooPause(.init(day: twDateTime.startOfDay(now)))
        let sim = simObject(modelContext: container.mainContext, tradingCalendar: calendar,
            marketSession: session, marketRetryDelays: [])
        defer { sim.tech.invalidateTimer() }
        var reports: [[String: Any]] = []
        for pass in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            let result = await sim.updateDailyPrices(stocks: stocks, clock: { now }, onBatchCompletion: { _ in nil })
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            reports.append(["pass": pass, "elapsed": elapsed, "status": result.statusText,
                "timings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.twse.timings))])
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
                .write(to: run.appendingPathComponent("timings.json"))
            XCTAssertEqual(result.twse.timings.p10Executions, 0)
            XCTAssertTrue(result.twse.calculatedStockIDs.isEmpty)
            XCTAssertEqual(result.twse.remainingHistoryMonths, 0)
            XCTAssertTrue(UpdateCheckNoNetwork.requests.isEmpty)
            XCTAssertFalse(result.twse.historyCoverageSaveFailed)
            if pass > 0 {
                XCTAssertEqual(result.twse.timings.stockHistoryReads, 0)
                XCTAssertEqual(result.twse.timings.marketHistoryReads, 0)
                XCTAssertEqual(result.twse.timings.windowObservedRows, 0)
                XCTAssertEqual(result.twse.timings.windowInputScans, 0)
            }
            print("EVENT_CHECK_PASS \(pass): \(elapsed)s, \(result.twse.timings)")
        }
        print("EVENT_CHECK_OUTPUT \(run.path)")
        withExtendedLifetime(container) {}
    }
}
