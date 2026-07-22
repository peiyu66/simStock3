import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class HistoryCoverageTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeFixture(dateStart: Date) throws -> (ModelContext, Stock) {
        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let stock = Stock(
            sId: "TEST",
            sName: "測試股",
            group: "測試",
            dateFirst: date(2010, 1, 1),
            dateStart: dateStart,
            simInvestAuto: 2,
            simMoneyBase: 100
        )
        context.insert(stock)
        try context.save()
        return (context, stock)
    }

    private func insertTrade(
        source: String,
        date: Date,
        context: ModelContext,
        stock: Stock
    ) throws {
        let trade = Trade(stock: stock, dateTime: date, dataSource: source)
        trade.priceClose = 100
        context.insert(trade)
        try context.save()
    }

    func testNoTWSEHistoryNeedsBackfill() throws {
        let (context, stock) = try makeFixture(dateStart: date(2024, 7, 15))
        XCTAssertTrue(stock.needsTWSEHistoryBackfill(in: context))
    }

    func testYahooHistoryDoesNotCountAsAuthoritativeCoverage() throws {
        let (context, stock) = try makeFixture(dateStart: date(2024, 7, 15))
        try insertTrade(source: "yahoo", date: date(2023, 6, 30), context: context, stock: stock)
        XCTAssertTrue(stock.needsTWSEHistoryBackfill(in: context))
    }

    func testTWSETradeInRequiredMonthCompletesCoverage() throws {
        let (context, stock) = try makeFixture(dateStart: date(2024, 7, 15))
        try insertTrade(source: "TWSE", date: date(2023, 7, 3), context: context, stock: stock)
        XCTAssertFalse(stock.needsTWSEHistoryBackfill(in: context))
    }

    func testTWSETradeAfterRequiredMonthStillNeedsBackfill() throws {
        let (context, stock) = try makeFixture(dateStart: date(2024, 7, 15))
        try insertTrade(source: "TWSE", date: date(2023, 8, 1), context: context, stock: stock)
        XCTAssertTrue(stock.needsTWSEHistoryBackfill(in: context))
    }

    func testRequiredHistoryNeverPredatesTWSE2010Boundary() throws {
        let (_, stock) = try makeFixture(dateStart: date(2010, 3, 1))
        XCTAssertEqual(stock.requiredTWSEHistoryStartMonth, date(2010, 1, 1))
    }

    func testYahooEligibilityIsBlockedOnlyForStockWithForwardTWSEFailure() {
        var summary = simObject.TWSEUpdateSummary()
        summary.forwardFailedStockIDs.insert("FAILED")

        XCTAssertFalse(summary.permitsYahooUpdate(for: "FAILED"))
        XCTAssertTrue(summary.permitsYahooUpdate(for: "COMPLETED"))
    }
}
