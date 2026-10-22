import SwiftData
import XCTest
@testable import simStock3

private final class HistoryReceiptURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload: [String: Any] = [:]
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = try! JSONSerialization.data(withJSONObject: Self.payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class TWSEHistoryReceiptTests: XCTestCase {
    private func date(_ text: String) -> Date { twDateTime.dateFromString(text)! }
    private let goodRow = ["112/01/03", "1000000", "0", "100", "101", "99", "100", "0", "1"]

    private func fixture() throws -> (ModelContainer, Stock, Technical, URLSession) {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let stock = Stock(sId: "RECEIPT", sName: "來源確認", group: "A",
            dateFirst: date("2023/01/01"), dateStart: date("2024/01/01"), simMoneyBase: 100)
        container.mainContext.insert(stock)
        try container.mainContext.save()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HistoryReceiptURLProtocol.self]
        let session = URLSession(configuration: config)
        let technical = Technical(modelContext: container.mainContext, priceSession: session)
        HistoryReceiptURLProtocol.status = 200
        return (container, stock, technical, session)
    }

    func testSuccessfulUnchangedMonthConfirmsSourceWithoutRepeatingCompletedT() async throws {
        let (container, stock, technical, session) = try fixture()
        defer { session.invalidateAndCancel(); withExtendedLifetime(container) {} }
        HistoryReceiptURLProtocol.payload = ["stat": "OK", "data": [goodRow]]
        let result1 = await technical.twseRequestAsync(stock: stock, dateStart: date("2023/01/01"), recalculate: false)
        XCTAssertTrue(result1)
        XCTAssertTrue(stock.unconfirmedHistoryMonths(through: date("2023/01/31")).isEmpty)
        XCTAssertNil(stock.savedRollingOrigin)
        XCTAssertNotNil(stock.technicalDirtyFrom)
        _ = try await technical.recoverOrMigrateRecalculationState(for: stock)
        XCTAssertEqual(technical.lastRecalculationTrace.ordinaryTechnicalDates.count, 1)
        let receipt = stock.technicalRollingOrigin
        let result2 = await technical.twseRequestAsync(stock: stock, dateStart: date("2023/01/01"), recalculate: false)
        XCTAssertTrue(result2)
        XCTAssertEqual(stock.technicalRollingOrigin, receipt)
        XCTAssertNil(stock.technicalDirtyFrom)
        XCTAssertFalse(stock.needsCompletedHistoryReplay(
            trades: try Trade.fetchCalculationWindow(in: container.mainContext, for: stock), version: 4))
        // There is no simulation date yet; a future S obligation is distinct
        // from repeating an already completed technical calculation.
        let noChange = try technical.recalculate(stock: stock, plan: .none)
        XCTAssertTrue(noChange.technicalDates.isEmpty)
    }

    func testEmptyFailedMalformedOrWrongMonthResponseDoesNotCertifyAbsence() async throws {
        let (container, stock, technical, session) = try fixture()
        defer { session.invalidateAndCancel(); withExtendedLifetime(container) {} }
        var wrongMonth = goodRow; wrongMonth[0] = "112/02/03"
        var invalidVolume = goodRow; invalidVolume[1] = "nan"
        var invalidHigh = goodRow; invalidHigh[4] = "--"
        for payload: [String: Any] in [
            ["stat": "OK"], ["stat": "OK", "data": []], ["stat": "很抱歉，沒有符合條件的資料!"],
            ["stat": "OK", "data": [invalidVolume]], ["stat": "OK", "data": [invalidHigh]],
            ["stat": "OK", "data": [goodRow, goodRow]],
            ["stat": "OK", "data": [goodRow, ["invalid"]]],
            ["stat": "OK", "data": [wrongMonth]]
        ] {
            HistoryReceiptURLProtocol.payload = payload
            let result3 = await technical.twseRequestAsync(stock: stock, dateStart: date("2023/01/01"), recalculate: false)
            XCTAssertFalse(result3)
            XCTAssertTrue(stock.confirmedHistory.months.isEmpty)
            XCTAssertNil(stock.confirmedHistory.legacyIntervals)
            XCTAssertNil(stock.twseListingDate)
            XCTAssertNil(stock.savedRollingOrigin)
        }
        HistoryReceiptURLProtocol.status = 503
        HistoryReceiptURLProtocol.payload = ["stat": "OK", "data": [goodRow]]
        let result4 = await technical.twseRequestAsync(stock: stock, dateStart: date("2023/01/01"), recalculate: false)
        XCTAssertFalse(result4)
        XCTAssertTrue(stock.confirmedHistory.months.isEmpty)
        XCTAssertNil(stock.confirmedHistory.legacyIntervals)
    }

    func testFailedSourceSaveCannotLeaveSuccessfulCoverageReceipt() async throws {
        enum Failure: Error { case injected }
        let (container, stock, technical, session) = try fixture()
        defer { session.invalidateAndCancel(); withExtendedLifetime(container) {} }
        HistoryReceiptURLProtocol.payload = ["stat": "OK", "data": [goodRow]]
        technical.recalculationSave = { throw Failure.injected }
        let result5 = await technical.twseRequestAsync(stock: stock, dateStart: date("2023/01/01"), recalculate: false)
        XCTAssertFalse(result5)
        XCTAssertTrue(stock.confirmedHistory.months.isEmpty)
        XCTAssertNil(stock.confirmedHistory.legacyIntervals)
        XCTAssertNil(stock.savedRollingOrigin)
        XCTAssertNotNil(stock.technicalDirtyFrom)
    }
    func testSavedSourceReceiptSurvivesSubsequentTechnicalSaveFailure() async throws {
        enum Failure: Error { case injected }
        let (container, stock, technical, session) = try fixture()
        defer { session.invalidateAndCancel(); withExtendedLifetime(container) {} }
        HistoryReceiptURLProtocol.payload = ["stat": "OK", "data": [goodRow]]
        var saves = 0
        technical.recalculationSave = {
            saves += 1
            if saves == 3 { throw Failure.injected }
            try container.mainContext.save()
        }
        let result = await technical.twseRequestAsync(stock: stock, dateStart: date("2023/01/01"))
        XCTAssertFalse(result)
        XCTAssertFalse(stock.confirmedHistory.months.isEmpty)
        XCTAssertNil(stock.savedRollingOrigin)
        XCTAssertNotNil(stock.technicalDirtyFrom)
        let freshContext = ModelContext(container)
        let reopened = try XCTUnwrap(Stock.fetchAll(in: freshContext).first)
        XCTAssertFalse(reopened.confirmedHistory.months.isEmpty)
        XCTAssertNil(reopened.savedRollingOrigin)
        let retry = Technical(modelContext: freshContext, priceSession: session)
        _ = try await retry.recoverOrMigrateRecalculationState(for: reopened)
        XCTAssertEqual(retry.lastRecalculationTrace.ordinaryTechnicalDates.count, 1)
        XCTAssertNotNil(reopened.savedRollingOrigin)
    }
    func testAbsentOHLCReceiptPersistsStatsWithoutTradeOrRewritingExistingPrice() async throws {
        let (container, stock, technical, session) = try fixture()
        defer { technical.invalidateTimer(); session.invalidateAndCancel(); withExtendedLifetime(container) {} }
        var absent = goodRow
        absent[1] = "139"; absent[2] = "17,570"; absent[8] = "8"
        for i in 3...6 { absent[i] = "--" }
        HistoryReceiptURLProtocol.payload = ["stat": "OK", "data": [absent]]
        let first = await technical.twseRequestAsync(stock: stock, dateStart: date("2023/01/01"), recalculate: false)
        XCTAssertTrue(first)
        XCTAssertTrue(try Trade.fetchCalculationWindow(in: container.mainContext, for: stock).isEmpty)
        XCTAssertNil(stock.twseListingDate, "No OHLC is not evidence of pre-listing")
        XCTAssertNil(stock.savedRollingOrigin)
        let reopened = try XCTUnwrap(Stock.fetchAll(in: ModelContext(container)).first)
        XCTAssertEqual(reopened.confirmedHistory.noPriceDays?["202301"]?.first?.amount, 17570)
        XCTAssertTrue(reopened.unconfirmedHistoryMonths(through: date("2023/01/31")).isEmpty)
        let trade = Trade(stock: stock, dateTime: twDateTime.time1330(date("2023/01/03")), dataSource: "TWSE")
        trade.priceOpen = 100; trade.priceHigh = 101; trade.priceLow = 99; trade.priceClose = 100; trade.volumeClose = 1000
        trade.tUpdated = true
        container.mainContext.insert(trade)
        try container.mainContext.save()
        let second = await technical.twseRequestAsync(stock: stock, dateStart: date("2023/01/01"), recalculate: false)
        XCTAssertTrue(second)
        XCTAssertEqual(trade.priceClose, 100)
        XCTAssertEqual(trade.volumeClose, 1000)
        XCTAssertEqual(trade.dataSource, "TWSE")
        XCTAssertTrue(trade.tUpdated)
        try stock.forgetHistoryMonths(containing: [trade.dateTime])
        XCTAssertNil(stock.confirmedHistory.noPriceDays?["202301"])
    }

    func testAbsentSourceSaveFailureRestoresBothReceiptAndRawStatistics() async throws {
        enum Failure: Error { case injected }
        let (container, stock, technical, session) = try fixture()
        defer { technical.invalidateTimer(); session.invalidateAndCancel(); withExtendedLifetime(container) {} }
        var absent = goodRow; for i in 3...6 { absent[i] = "--" }
        absent[1] = "0"; absent[2] = "0"; absent[8] = "0"
        HistoryReceiptURLProtocol.payload = ["stat": "OK", "data": [absent]]
        let before = stock.twseHistoryCoverage
        technical.recalculationSave = { throw Failure.injected }
        let failed = await technical.twseRequestAsync(stock: stock, dateStart: date("2023/01/01"), recalculate: false)
        XCTAssertFalse(failed)
        XCTAssertEqual(stock.twseHistoryCoverage, before)
        XCTAssertEqual(try Stock.fetchAll(in: ModelContext(container)).first?.twseHistoryCoverage, before)
        technical.recalculationSave = nil
        let retry = await technical.twseRequestAsync(stock: stock, dateStart: date("2023/01/01"), recalculate: false)
        XCTAssertTrue(retry)
        XCTAssertTrue(stock.unconfirmedHistoryMonths(through: date("2023/01/31")).isEmpty)
        XCTAssertEqual(stock.confirmedHistory.noPriceDays?["202301"]?.count, 1)
    }

    func testCurrentMonthNoPriceTailConfirmsOnlyThroughReportedDate() async throws {
        let (container, stock, technical, session) = try fixture()
        defer { technical.invalidateTimer(); session.invalidateAndCancel(); withExtendedLifetime(container) {} }
        let month = twDateTime.startOfMonth(Date())
        let year = twDateTime.calendar.component(.year, from: month) - 1911
        let mm = twDateTime.stringFromDate(month, format: "MM")
        var absent = goodRow
        absent[0] = "\(year)/\(mm)/01"; absent[1] = "0"; absent[2] = "0"; absent[8] = "0"
        for i in 3...6 { absent[i] = "--" }
        HistoryReceiptURLProtocol.payload = ["stat": "OK", "data": [absent]]
        let result = await technical.twseRequestAsync(stock: stock, dateStart: month, recalculate: false)
        XCTAssertTrue(result)
        XCTAssertEqual(stock.confirmedHistory.months[TWSEHistoryCoverage.key(month)], twDateTime.endOfDay(month))
        XCTAssertFalse(stock.confirmedHistory.contains(month: month,
            through: twDateTime.calendar.date(byAdding: .day, value: 1, to: month)!))
        XCTAssertTrue(try Trade.fetchCalculationWindow(in: container.mainContext, for: stock).isEmpty)
    }

}
