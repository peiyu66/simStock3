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
}
