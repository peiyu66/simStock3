import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class CalculationWindowIntegrationTests: XCTestCase {
    private func day(_ value: String) -> Date { twDateTime.startOfDay(twDateTime.dateFromString(value)!) }
    private func fixture(start: String = "2024/06/15") throws -> (ModelContainer, Stock, Technical) {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let stock = Stock(sId: "WINDOW", sName: "窗口", group: "測試",
            dateFirst: day("2020/01/01"), dateStart: day(start), simInvestAuto: 2, simMoneyBase: 100)
        container.mainContext.insert(stock)
        return (container, stock, Technical(modelContext: container.mainContext))
    }
    private func row(_ value: String, stock: Stock, context: ModelContext, close: Double = 100) -> Trade {
        let row = Trade(stock: stock, dateTime: twDateTime.time1330(day(value)))
        row.priceClose = close; row.priceOpen = close; row.priceHigh = close + 1; row.priceLow = close - 1
        row.volumeClose = 1_000; row.dataSource = "TWSE"
        context.insert(row)
        return row
    }

    func testFullReplayStartsInsideExactDayWindowAndLeavesRetainedRowUntouched() async throws {
        let (container, stock, technical) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let outside = row("2023/06/14", stock: stock, context: context)
        outside.tKdK = 999; outside.rollAmtProfit = 12345; outside.simReversed = "Buy"
        let first = row("2023/06/15", stock: stock, context: context)
        first.tMa60 = 888; first.tKdK = 999; first.simAmtBalance = 999; first.simQtyInventory = 100
        let preparation = row("2024/06/14", stock: stock, context: context)
        let simulated = row("2024/06/15", stock: stock, context: context)
        let trace = try technical.recalculate(stock: stock, plan: .init(technical: .all, simulation: .all))
        XCTAssertEqual(trace.technicalDates, [first, preparation, simulated].map(\.dateTime))
        XCTAssertEqual(trace.simulationDates, [simulated.dateTime])
        XCTAssertEqual(first.tKdK, 50)
        XCTAssertNotEqual(first.tMa60, 888)
        XCTAssertEqual(first.simQtyInventory, 0)
        XCTAssertEqual(outside.tKdK, 999)
        XCTAssertEqual(outside.rollAmtProfit, 12345)
        XCTAssertEqual(outside.simReversed, "Buy")
        XCTAssertEqual(stock.dateStart, day("2024/06/15"))
    }

    func testHalfYearCalculatesTButDefersSimulationAndPreservesConfiguredIntent() async throws {
        let (container, stock, technical) = try fixture(start: "2024/01/01")
        defer { withExtendedLifetime(container) {} }
        let first = row("2024/01/02", stock: stock, context: container.mainContext)
        let latest = row("2024/07/02", stock: stock, context: container.mainContext)
        latest.simReversed = "Buy"; latest.simInvestByUser = 1; latest.rollAmtProfit = 1000
        let trace = try technical.recalculate(stock: stock, plan: .init(technical: .all, simulation: .all))
        XCTAssertEqual(trace.technicalDates, [first.dateTime, latest.dateTime])
        XCTAssertTrue(trace.simulationDates.isEmpty)
        XCTAssertEqual(latest.simRule, "_")
        XCTAssertEqual(latest.rollAmtProfit, 0)
        XCTAssertEqual(latest.simReversed, "Buy")
        XCTAssertEqual(latest.simInvestByUser, 1)
        XCTAssertEqual(trace.userActions.clearedInvalid, 0)
        XCTAssertNil(stock.technicalDirtyFrom)
        XCTAssertNotNil(stock.simulationDirtyFrom)
        XCTAssertFalse(stock.calculationWindow.hasSimulationDates)
        XCTAssertEqual(stock.dateStart, day("2024/01/01"))
    }

    func testWindowSnapshotInvalidatesForDateValidityAndInsertedPrices() async throws {
        let (container, stock, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let first = row("2023/07/01", stock: stock, context: container.mainContext)
        let last = row("2024/07/01", stock: stock, context: container.mainContext)
        XCTAssertEqual(stock.effectiveSimulationStart, day("2024/07/01"))
        first.priceClose = 0
        XCTAssertEqual(stock.effectiveSimulationStart, day("2025/07/01"))
        _ = try Trade.fetchCalculationWindow(in: container.mainContext, for: stock)
        first.priceClose = 100
        XCTAssertEqual(stock.effectiveSimulationStart, day("2024/07/01"))
        first.dateTime = twDateTime.time1330(day("2023/06/20"))
        XCTAssertEqual(stock.effectiveSimulationStart, day("2024/06/20"))
        let inserted = row("2023/06/15", stock: stock, context: container.mainContext)
        XCTAssertEqual(stock.effectiveSimulationStart, day("2024/06/15"))
        container.mainContext.delete(inserted)
        try container.mainContext.save()
        XCTAssertEqual(stock.effectiveSimulationStart, day("2024/06/20"))
        last.priceClose = 101
        XCTAssertEqual(stock.calculationWindow.lastPriceDate, day("2024/07/01"))
    }

    func testOutsideBackfillDoesNotRequestTechnicalOrSimulationReplay() async throws {
        let (container, stock, technical) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let first = row("2023/06/15", stock: stock, context: container.mainContext)
        let last = row("2024/06/15", stock: stock, context: container.mainContext)
        _ = try technical.recalculate(stock: stock, plan: .init(technical: .all, simulation: .all))
        let outside = row("2020/01/01", stock: stock, context: container.mainContext)
        let changes = TradeChangeSet(previousFirstDate: first.dateTime, previousLastDate: last.dateTime,
            insertedDates: [outside.dateTime])
        XCTAssertEqual(try technical.recalculationPlan(stock: stock, changes: changes), .none)
        let trace = try technical.recalculate(stock: stock, changes: changes)
        XCTAssertTrue(trace.technicalDates.isEmpty)
        XCTAssertTrue(trace.simulationDates.isEmpty)
        XCTAssertNil(stock.technicalDirtyFrom)
        XCTAssertNil(stock.simulationDirtyFrom)
    }

    func testEarlierSettingOverridesCompletedFlagsAndReplaysOnlyNewWindow() async throws {
        let (container, stock, technical) = try fixture(start: "2025/06/15")
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let outside = row("2020/01/01", stock: stock, context: context)
        let reentered = row("2023/06/15", stock: stock, context: context)
        let oldFirst = row("2024/06/15", stock: stock, context: context)
        let latest = row("2025/06/15", stock: stock, context: context)
        _ = try technical.recalculate(stock: stock, plan: .init(technical: .all, simulation: .all))
        for trade in [outside, reentered, oldFirst, latest] { trade.tUpdated = true; trade.simUpdated = true; trade.tKdK = 999 }
        try StockHistory.changeStart(stock, to: day("2024/06/15"), in: context)
        try context.save()
        XCTAssertEqual(stock.technicalDirtyFrom, .distantPast)
        XCTAssertEqual(stock.simulationDirtyFrom, .distantPast)
        _ = try await technical.recoverOrMigrateRecalculationState(for: stock)
        XCTAssertEqual(technical.lastRecalculationTrace.technicalDates, [reentered, oldFirst, latest].map(\.dateTime))
        XCTAssertEqual(technical.lastRecalculationTrace.simulationDates, [oldFirst, latest].map(\.dateTime))
        XCTAssertEqual(reentered.tKdK, 50)
        XCTAssertNotEqual(latest.tKdK, 999)
        XCTAssertEqual(outside.tKdK, 999)
        XCTAssertNil(stock.technicalDirtyFrom)
        XCTAssertNil(stock.simulationDirtyFrom)
    }

    func testYearsUsesTheSameEffectiveStartAsReplay() async throws {
        let originalTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        defer { NSTimeZone.default = originalTimeZone }
        let (container, stock, _) = try fixture(start: "2024/01/01")
        defer { withExtendedLifetime(container) {} }
        _ = row("2023/07/01", stock: stock, context: container.mainContext)
        let last = row("2026/07/01", stock: stock, context: container.mainContext)
        XCTAssertEqual(stock.effectiveSimulationStart, day("2024/07/01"))
        XCTAssertEqual(stock.years, 2, accuracy: 1e-12)
        XCTAssertEqual(last.years, stock.years, accuracy: 1e-12)
        XCTAssertEqual(stock.dateStart, day("2024/01/01"))
    }

    func testDatabaseSeedsExcludeInvalidPricesBeforeApplyingFetchLimits() async throws {
        let (container, stock, _) = try fixture(start: "2024/01/01")
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let preparation = row("2023/01/01", stock: stock, context: context)
        let prior = row("2024/01/02", stock: stock, context: context)
        prior.simQtySell = 1; prior.simAmtRoi = -5; prior.simFitTrendPhaseRaw = 10
        let invalid = row("2024/01/03", stock: stock, context: context, close: .infinity)
        invalid.simQtySell = 1; invalid.simAmtRoi = 10; invalid.simFitTrendPhaseRaw = 3
        let target = row("2024/01/04", stock: stock, context: context)
        try context.save()
        let valid = try Trade.fetchCalculationWindow(in: context, for: stock)
        XCTAssertEqual(valid.map(\.dateTime), [preparation, prior, target].map(\.dateTime))
        var database = try SimulationRollingContext.seeded(before: target.dateTime, for: stock, in: context)
        var loaded = SimulationRollingContext.seeded(before: 2, in: valid)
        XCTAssertEqual(database.gradeLossCutPenaltyLevel, 1)
        XCTAssertEqual(database.gradeLossCutPenaltyLevel, loaded.gradeLossCutPenaltyLevel)
        if case .confirmed = database.lastWorseningBoundary {} else { XCTFail("Invalid row became the boundary") }
        database.update(after: target)
        let databaseWarning = target.simAnnualWarningData
        loaded.update(after: target)
        XCTAssertEqual(databaseWarning, target.simAnnualWarningData)
    }

}
