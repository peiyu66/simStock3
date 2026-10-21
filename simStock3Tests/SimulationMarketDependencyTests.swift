import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class SimulationMarketDependencyTests: XCTestCase {
    private enum Failure: Error { case save }
    private struct Fixture {
        let container: ModelContainer
        let stock: Stock
        let trades: [Trade]
        let technical: Technical
        var context: ModelContext { container.mainContext }
    }
    private func date(_ index: Int) -> Date {
        let origin = twDateTime.dateFromString("2024/01/01")!
        let days = index < 260 ? index * 366 / 260 : 366 + index - 260
        return twDateTime.time1330(twDateTime.calendar.date(byAdding: .day, value: days, to: origin)!)
    }
    private func record(_ index: Int, delta: Double = 0) -> MarketDataStore.Record {
        .init(date: date(index), open: 10_000, high: 20_000 - Double(index) + delta,
              low: 100 + Double(index), close: 10_000)
    }
    private func fixture(marketIndices: [Int] = []) throws -> Fixture {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let market = MarketDataStore(modelContext: context)
        _ = try market.applyOfficialRecords(marketIndices.map { record($0) })
        try market.rebuildPricePath()
        let stock = Stock(sId: "DEPENDENCY", sName: "市場依賴", group: "測試",
                          dateFirst: date(0), dateStart: date(260), simMoneyBase: 100)
        context.insert(stock)
        let trades = (0..<330).map { index in
            let trade = Trade(stock: stock, dateTime: date(index))
            let close = 100 + sin(Double(index) / 15) * 10
            trade.dataSource = "TWSE"; trade.volumeClose = 1000
            trade.priceOpen = close; trade.priceHigh = close + 1; trade.priceLow = close - 1; trade.priceClose = close
            context.insert(trade)
            return trade
        }
        try context.save()
        return Fixture(container: container, stock: stock, trades: trades,
                       technical: Technical(modelContext: context))
    }

    func testNoMarketCompletesStockTechnicalButPreservesSimulationAndIntent() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        // A retained legacy true flag cannot bypass missing dependencies.
        for trade in f.trades { trade.simUpdated = true }
        f.trades[300].simReversed = "Buy"; f.trades[300].simInvestByUser = 1
        f.trades[300].rollAmtProfit = 1234
        f.stock.simMoneyLacked = true
        let trace = try f.technical.recalculate(stock: f.stock,
            plan: .init(technical: .all, simulation: .all, resetDerivedSimulationState: true))
        XCTAssertEqual(trace.technicalDates, f.trades.map(\.dateTime))
        XCTAssertTrue(trace.simulationDates.isEmpty)
        XCTAssertEqual(trace.blockedSimulationDate, date(260))
        XCTAssertEqual(trace.simulationDependencyIssue, .marketMissing)
        XCTAssertEqual(f.stock.technicalStateVersion, Int(Technical.technicalRuleVersion.dropFirst())!)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertNotNil(f.stock.simulationDirtyFrom)
        XCTAssertNotEqual(f.stock.simulationStateVersion, Int(Technical.simulationRuleVersion.dropFirst())!)
        XCTAssertEqual(f.trades[300].rollAmtProfit, 1234)
        XCTAssertEqual(f.trades[300].simReversed, "Buy")
        XCTAssertEqual(f.trades[300].simInvestByUser, 1)
        XCTAssertTrue(f.stock.simMoneyLacked)
        let market = MarketDataStore(modelContext: f.context)
        _ = try market.applyOfficialRecords((0..<330).map { record($0) })
        try market.rebuildPricePath()
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertTrue(f.technical.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertEqual(f.technical.lastRecalculationTrace.simulationDates, (260..<330).map(date))
        XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertEqual(f.stock.simulationStateVersion, Int(Technical.simulationRuleVersion.dropFirst())!)
    }

    func testMissingHistoricalDayStopsAtPrefixAndCompletesAfterRepair() async throws {
        let f = try fixture(marketIndices: Array(0..<300) + Array(301..<330))
        defer { withExtendedLifetime(f.container) {} }
        f.trades[310].simReversed = "Buy"; f.trades[310].rollAmtProfit = 3456
        let trace = try f.technical.recalculate(stock: f.stock, plan: .init(technical: .all, simulation: .all))
        XCTAssertEqual(trace.simulationDates, (260..<300).map(date))
        XCTAssertEqual(trace.simulationDependencyIssue, .marketMissing)
        XCTAssertEqual(f.stock.simulationDirtyFrom, date(300))
        XCTAssertEqual(f.trades[310].rollAmtProfit, 3456)
        XCTAssertEqual(f.trades[310].simReversed, "Buy")
        let market = MarketDataStore(modelContext: f.context)
        _ = try market.applyOfficialRecords([record(300)])
        try market.rebuildPricePath()
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        // Migration remains pending until the entire S period is complete, so
        // recovery may replay all S; it must never rerun valid stock T.
        XCTAssertTrue(f.technical.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertEqual(f.technical.lastRecalculationTrace.simulationDates, (260..<330).map(date))
        XCTAssertEqual(f.stock.simulationStateVersion, Int(Technical.simulationRuleVersion.dropFirst())!)
        XCTAssertTrue(f.trades[260...].allSatisfy { $0.simMarketSourceDate == $0.dateTime })
    }

    func testFullRecoveryWithoutMarketPreservesUncomputedTailAndManualIntent() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        StockHistory.invalidate(f.stock)
        f.trades[310].simReversed = "Buy"; f.trades[310].simInvestByUser = 1
        f.trades[310].rollAmtProfit = 3456; f.trades[310].tKdK = 999
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertEqual(f.technical.lastRecalculationTrace.technicalDates.count, 330)
        XCTAssertTrue(f.technical.lastRecalculationTrace.simulationDates.isEmpty)
        XCTAssertNotEqual(f.trades[310].tKdK, 999)
        XCTAssertEqual(f.trades[310].rollAmtProfit, 3456)
        XCTAssertEqual(f.trades[310].simReversed, "Buy")
        XCTAssertEqual(f.trades[310].simInvestByUser, 1)
        XCTAssertNil(f.stock.technicalDirtyFrom); XCTAssertNotNil(f.stock.simulationDirtyFrom)
    }

    func testCancellationAtRecoveryYieldDoesNotClearStoredDerivedValues() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        StockHistory.invalidate(f.stock)
        f.trades[310].rollAmtProfit = 3456; f.trades[310].tKdK = 999
        f.trades[310].simReversed = "Buy"
        let task = Task { @MainActor in
            try await f.technical.recoverOrMigrateRecalculationState(for: f.stock) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        _ = try await task.value
        XCTAssertTrue(f.technical.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertTrue(f.technical.lastRecalculationTrace.simulationDates.isEmpty)
        XCTAssertEqual(f.trades[310].rollAmtProfit, 3456)
        XCTAssertEqual(f.trades[310].tKdK, 999)
        XCTAssertEqual(f.trades[310].simReversed, "Buy")
        XCTAssertNotNil(f.stock.technicalDirtyFrom); XCTAssertNotNil(f.stock.simulationDirtyFrom)
    }

    func testFirstSimulationDayCannotConsumeUnofficialPreviousStockRow() async throws {
        let f = try fixture(marketIndices: Array(0..<330))
        defer { withExtendedLifetime(f.container) {} }
        f.trades[259].dataSource = "yahoo"
        let trace = try f.technical.recalculate(stock: f.stock, plan: .init(technical: .all, simulation: .all))
        XCTAssertTrue(trace.simulationDates.isEmpty)
        XCTAssertEqual(trace.blockedSimulationDate, date(260))
        XCTAssertEqual(trace.simulationDependencyIssue, .stockOfficialPriceMissing)
        XCTAssertNil(f.stock.technicalDirtyFrom); XCTAssertNotNil(f.stock.simulationDirtyFrom)
        f.trades[259].dataSource = "TWSE"
        let repaired = try f.technical.recalculate(stock: f.stock, changes: .init(
            previousFirstDate: date(0), previousLastDate: date(329), modifiedDates: [date(259)]))
        XCTAssertEqual(repaired.simulationDates, (260..<330).map(date))
        XCTAssertNil(f.stock.simulationDirtyFrom)
    }

    func testMarketSaveFailureCannotBeSettledBySimulationOnlyReplay() async throws {
        let f = try fixture(marketIndices: Array(0..<330))
        defer { withExtendedLifetime(f.container) {} }
        _ = try f.technical.recalculate(stock: f.stock, plan: .init(technical: .all, simulation: .all))
        let market = MarketDataStore(modelContext: f.context)
        _ = try market.applyOfficialRecords([record(300, delta: 20)])
        var saves = 0
        market.technicalSave = { saves += 1; if saves == 2 { throw Failure.save }; try f.context.save() }
        XCTAssertThrowsError(try market.rebuildPricePath())
        let trace = try f.technical.recalculate(stock: f.stock, plan: .init(technical: .none, simulation: .from(date(300))))
        XCTAssertTrue(trace.simulationDates.isEmpty)
        XCTAssertEqual(trace.simulationDependencyIssue, .marketMissing)
        XCTAssertEqual(f.stock.simulationDirtyFrom, date(300))
        let price = f.trades[329].priceClose
        let profit = f.trades[329].rollAmtProfit
        f.technical.runP10ForTesting([f.stock])
        XCTAssertEqual(f.trades[329].priceClose, price)
        XCTAssertEqual(f.trades[329].rollAmtProfit, profit)
        market.technicalSave = nil
        try market.rebuildPricePath()
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertEqual(f.technical.lastRecalculationTrace.simulationDates, (300..<330).map(date))
        XCTAssertNil(f.stock.simulationDirtyFrom)
    }

    func testMatureCurrentNeedsPreviousStockDayButKnownPartialKeepsOriginalGates() async throws {
        let f = try fixture(marketIndices: Array(0..<330))
        defer { withExtendedLifetime(f.container) {} }
        var lookup = try MarketPricePathLookup(modelContext: f.context).observations
        lookup.removeAll { $0.date == date(299) }
        let missing = Technical(modelContext: f.context, marketPricePathLookup: .init(observations: lookup))
        XCTAssertEqual(missing.simulationDependencyIssue(trades: f.trades, index: 300), .previousMarketMissing)
        let partial = try fixture(marketIndices: Array(200..<330))
        defer { withExtendedLifetime(partial.container) {} }
        XCTAssertNil(partial.technical.simulationDependencyIssue(trades: partial.trades, index: 260))
        XCTAssertEqual(partial.technical.marketObservation(on: date(260))?.priceObservationCount, 61)
        XCTAssertEqual(partial.technical.simulationDependencyIssue(trades: partial.trades, index: 239), .marketMissing)
    }

    func testLivePreviousOfficialFallbackRemainsAvailableOnlyForExplicitLiveDay() async throws {
        let f = try fixture(marketIndices: Array(0..<329))
        defer { withExtendedLifetime(f.container) {} }
        f.trades[329].dataSource = "yahoo"
        XCTAssertEqual(f.technical.simulationDependencyIssue(trades: f.trades, index: 329), .stockOfficialPriceMissing)
        f.technical.liveMarketContext = .init(asOf: date(329), previousTradingDay: date(328))
        XCTAssertNil(f.technical.simulationDependencyIssue(trades: f.trades, index: 329))
        XCTAssertEqual(f.technical.marketObservation(on: date(329))?.date, date(328))
        f.technical.liveMarketContext = .init(asOf: date(330), previousTradingDay: date(329))
        XCTAssertEqual(f.technical.simulationDependencyIssue(trades: f.trades, index: 329), .stockOfficialPriceMissing)
    }
}
