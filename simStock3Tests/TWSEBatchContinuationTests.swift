import SwiftData
import XCTest
@testable import simStock3

private final class BatchMonthURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestedMonths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let month = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "date" }!.value!
        Self.requestedMonths.append(month)
        let year = Int(month.prefix(4))! - 1911
        let mm = month.dropFirst(4).prefix(2)
        let payload: [String: Any] = ["stat": "OK",
            "fields": ["日期", "開盤指數", "最高指數", "最低指數", "收盤指數"],
            "data": [["\(year)/\(mm)/01", "100", "101", "99", "100"]]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class TWSEBatchContinuationTests: XCTestCase {
    private func date(_ value: String) -> Date { twDateTime.dateFromString(value)! }

    private func fixture() throws -> (ModelContainer, Stock) {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let stock = Stock(sId: "TEST", sName: "測試", group: "測試",
            dateFirst: date("2010/01/01"), dateStart: date("2024/01/01"))
        container.mainContext.insert(stock)
        try container.mainContext.save()
        return (container, stock)
    }

    func testPromptReportsRemainingAndStopsOnFailureCompletionOrNoWork() async {
        let progress = TWSEBatchProgress.make(stockHistoryMonths: 12, stockRecentMonths: 3,
            marketMonths: 7, requestedMonths: 12, failedMonths: 0, reachedBatchLimit: true)!
        XCTAssertEqual(progress.remainingMonths, 22)
        XCTAssertEqual(progress.nextBatchMonths, 6)
        XCTAssertTrue(progress.message.contains("合計 22 個月份"))
        XCTAssertEqual(TWSEBatchProgress(stockHistoryMonths: 2, stockRecentMonths: 0,
                                       marketMonths: 0).nextBatchMonths, 2)
        XCTAssertNil(TWSEBatchProgress.make(stockHistoryMonths: 12, stockRecentMonths: 0,
            marketMonths: 0, requestedMonths: 6, failedMonths: 1, reachedBatchLimit: true))
        XCTAssertNil(TWSEBatchProgress.make(stockHistoryMonths: 0, stockRecentMonths: 0,
            marketMonths: 0, requestedMonths: 6, failedMonths: 0, reachedBatchLimit: true))
        XCTAssertNil(TWSEBatchProgress.make(stockHistoryMonths: 12, stockRecentMonths: 0,
            marketMonths: 0, requestedMonths: 0, failedMonths: 0, reachedBatchLimit: true))
        XCTAssertNil(TWSEBatchProgress.make(stockHistoryMonths: 12, stockRecentMonths: 0,
            marketMonths: 0, requestedMonths: 1, failedMonths: 0, reachedBatchLimit: false))
    }

    func testMarketOnlyAndRecentOnlyWorkOfferContinuationButFailuresDoNot() async {
        var summary = simObject.TWSEUpdateSummary()
        summary.market.requestedMonths = 6
        summary.market.remainingHistoryMonths = 7
        summary.market.reachedBatchLimit = true
        XCTAssertEqual(summary.continuationProgress?.remainingMonths, 7)
        summary.market.failedMonths = 1
        XCTAssertNil(summary.continuationProgress)
        summary.market = MarketDataStore.UpdateSummary()
        summary.requestedMonths = 6
        summary.remainingRecentMonths = 8
        summary.reachedBatchLimit = true
        XCTAssertEqual(summary.continuationProgress?.remainingMonths, 8)
        XCTAssertTrue(summary.statusText.contains("近期尚待補 8"))
        summary.failedMonths = 1
        XCTAssertNil(summary.continuationProgress)
    }

    func testContinueThenCancelAndDuplicateResolution() async throws {
        let (container, stock) = try fixture()
        let ui = uiObject(modelContext: container.mainContext)
        for choice: Int? in [6, 6, nil] {
            let task = Task { @MainActor in
                await ui.requestTWSEBatchContinuation(
                    TWSEBatchProgress(stockHistoryMonths: 12, stockRecentMonths: 0, marketMonths: 0),
                    stocks: [stock])
            }
            for _ in 0..<100 where ui.twseBatchPrompt == nil { await Task.yield() }
            XCTAssertNotNil(ui.twseBatchPrompt)
            let visibleID = ui.twseBatchPrompt?.id
            ui.startDailyPriceUpdate(stocks: [stock], ensureFollowUpIfBusy: true)
            XCTAssertEqual(ui.twseBatchPrompt?.id, visibleID)
            XCTAssertNil(ui.simulationMigrationAlert)
            // SwiftUI may clear its presentation binding before the action.
            ui.twseBatchPrompt = nil
            ui.resolveTWSEBatchContinuation(months: choice)
            ui.resolveTWSEBatchContinuation(months: nil)
            let result = await task.value
            XCTAssertEqual(result, choice)
            XCTAssertNil(ui.twseBatchPrompt)
        }
    }

    func testTaskCancellationReleasesPrompt() async throws {
        let (container, stock) = try fixture()
        let ui = uiObject(modelContext: container.mainContext)
        let task = Task { @MainActor in
            await ui.requestTWSEBatchContinuation(
                TWSEBatchProgress(stockHistoryMonths: 12, stockRecentMonths: 0, marketMonths: 0),
                stocks: [stock])
        }
        for _ in 0..<100 where ui.twseBatchPrompt == nil { await Task.yield() }
        XCTAssertNotNil(ui.twseBatchPrompt)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(ui.twseBatchPrompt)
    }

    func testRecentMarketBatchesContinueWithoutRepeatingSuccessfulMonths() async throws {
        let (container, stock) = try fixture()
        let context = container.mainContext
        context.insert(MarketDay(dateTime: date("2023/01/01"), indexOpen: 100, indexHigh: 101, indexLow: 99, indexClose: 100))
        try context.save()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BatchMonthURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        BatchMonthURLProtocol.requestedMonths = []
        let store = MarketDataStore(modelContext: context, session: session)
        var cursor: Date?
        var remaining: [Int] = []
        var counts: [Int] = []
        for _ in 0..<3 {
            let summary = await store.update(stocks: [stock], through: date("2024/02/01"),
                maximumHistoryMonths: 6, forwardStartMonth: cursor)
            XCTAssertEqual(summary.failedMonths, 0)
            counts.append(summary.requestedMonths)
            remaining.append(summary.remainingRecentMonths)
            cursor = summary.nextForwardMonth
            XCTAssertEqual(summary.isInputComplete, summary.remainingRecentMonths == 0)
        }
        XCTAssertEqual(counts, [6, 6, 2])
        XCTAssertEqual(remaining, [8, 2, 0])
        XCTAssertEqual(Set(BatchMonthURLProtocol.requestedMonths).count, 14)
        XCTAssertEqual(BatchMonthURLProtocol.requestedMonths.count, 14)
    }
    func testHistoryOnlyMarketBatchesContinueUntilCoverageIsComplete() async throws {
        let (container, stock) = try fixture()
        let context = container.mainContext
        context.insert(MarketDay(dateTime: date("2024/02/01"), indexOpen: 100,
                                indexHigh: 101, indexLow: 99, indexClose: 100))
        try context.save()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BatchMonthURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        BatchMonthURLProtocol.requestedMonths = []
        let store = MarketDataStore(modelContext: context, session: session)
        var remaining: [Int] = []
        var limits: [Bool] = []
        for _ in 0..<3 {
            let summary = await store.update(stocks: [stock], through: date("2024/02/01"))
            XCTAssertEqual(summary.failedMonths, 0)
            remaining.append(summary.remainingHistoryMonths)
            limits.append(summary.reachedBatchLimit)
        }
        XCTAssertEqual(remaining, [7, 1, 0])
        XCTAssertEqual(limits, [true, true, false])
        XCTAssertEqual(Set(BatchMonthURLProtocol.requestedMonths).count, 13)
        XCTAssertEqual(BatchMonthURLProtocol.requestedMonths.count, 13)
    }

}
