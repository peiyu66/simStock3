import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class RecalculationTests: XCTestCase {
    private struct Fixture {
        let context: ModelContext
        let stock: Stock
        let technical: Technical
    }

    private struct ResultSnapshot {
        let technical: [Double]
        let simulation: [Double]
        let strings: [String]
        let tUpdated: Bool
    }

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ offset: Int) -> Date {
        let origin = calendar.date(
            from: DateComponents(year: 2024, month: 1, day: 1, hour: 13, minute: 30)
        )!
        return calendar.date(byAdding: .day, value: offset, to: origin)!
    }

    private func makeFixture(count: Int = 320, simulationStartIndex: Int = 260) throws -> Fixture {
        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let stock = Stock(
            sId: "TEST",
            sName: "測試股",
            group: "測試",
            dateFirst: date(0),
            dateStart: date(simulationStartIndex),
            simInvestAuto: 2,
            simMoneyBase: 100
        )
        context.insert(stock)

        for index in 0..<count {
            insertTrade(index: index, into: context, stock: stock)
        }
        try context.save()
        return Fixture(context: context, stock: stock, technical: Technical(modelContext: context))
    }

    @discardableResult
    private func insertTrade(index: Int, into context: ModelContext, stock: Stock) -> Trade {
        let wave = Double((index * 17) % 23) / 10
        let close = 70 + Double(index) * 0.08 + wave
        let trade = Trade(stock: stock, dateTime: twDateTime.time1330(date(index)))
        trade.priceOpen = close - 0.4
        trade.priceHigh = close + 1.1
        trade.priceLow = close - 1.3
        trade.priceClose = close
        trade.volumeClose = 800 + Double((index * 37) % 500)
        context.insert(trade)
        return trade
    }

    private func fullPlan() -> RecalculationPlan {
        RecalculationPlan(
            technical: .all,
            simulation: .all,
            resetDerivedSimulationState: true
        )
    }

    private func snapshot(_ trade: Trade) -> ResultSnapshot {
        ResultSnapshot(
            technical: [
                trade.tHighDiff, trade.tHighDiff125, trade.tHighDiff250,
                trade.tHighDiffZ125, trade.tHighDiffZ250, trade.tHighMax9,
                trade.tLowDiff, trade.tLowDiff125, trade.tLowDiff250,
                trade.tLowDiffZ125, trade.tLowDiffZ250, trade.tLowMin9,
                trade.tMa20, trade.tMa20Days, trade.tMa20Diff,
                trade.tMa20DiffMax9, trade.tMa20DiffMin9,
                trade.tMa20DiffZ125, trade.tMa20DiffZ250,
                trade.tMa60, trade.tMa60Days, trade.tMa60Diff,
                trade.tMa60DiffMax9, trade.tMa60DiffMin9,
                trade.tMa60DiffZ125, trade.tMa60DiffZ250,
                trade.tKdK, trade.tKdKMax9, trade.tKdKMin9,
                trade.tKdKZ125, trade.tKdKZ250,
                trade.tKdD, trade.tKdDZ125, trade.tKdDZ250,
                trade.tKdJ, trade.tKdJZ125, trade.tKdJZ250,
                trade.tOsc, trade.tOscEma12, trade.tOscEma26,
                trade.tOscMacd9, trade.tOscMax9, trade.tOscMin9,
                trade.tOscZ125, trade.tOscZ250,
                trade.vMa20, trade.vMa20Days, trade.vMa20Diff,
                trade.vMa20DiffMax9, trade.vMa20DiffMin9,
                trade.vMa20DiffZ125, trade.vMa20DiffZ250,
                trade.vMa60, trade.vMa60Days, trade.vMa60Diff,
                trade.vMa60DiffMax9, trade.vMa60DiffMin9,
                trade.vMa60DiffZ125, trade.vMa60DiffZ250,
                trade.vMax9, trade.vMin9, trade.vZ125, trade.vZ250
            ],
            simulation: [
                trade.rollAmtCost, trade.rollAmtProfit, trade.rollAmtRoi,
                trade.rollDays, trade.rollRounds,
                trade.simAmtBalance, trade.simAmtCost, trade.simAmtProfit,
                trade.simAmtRoi, trade.simDays, trade.simInvestAdded,
                trade.simInvestByUser, trade.simInvestTimes,
                trade.simQtyBuy, trade.simQtyInventory, trade.simQtySell,
                trade.simUnitCost, trade.simUnitRoi,
                trade.simInvestExceedCumulative,
                trade.simMoneyLackedCumulative ? 1 : 0
            ],
            strings: [trade.simReversed, trade.simRule, trade.simRuleBuy, trade.simRuleInvest],
            tUpdated: trade.tUpdated
        )
    }

    private func assertEqual(
        _ lhs: ResultSnapshot,
        _ rhs: ResultSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.technical.count, rhs.technical.count, file: file, line: line)
        for (left, right) in zip(lhs.technical, rhs.technical) {
            XCTAssertEqual(left, right, accuracy: 0.000_000_1, file: file, line: line)
        }
        for (left, right) in zip(lhs.simulation, rhs.simulation) {
            XCTAssertEqual(left, right, accuracy: 0.000_000_1, file: file, line: line)
        }
        XCTAssertEqual(lhs.strings, rhs.strings, file: file, line: line)
        XCTAssertEqual(lhs.tUpdated, rhs.tUpdated, file: file, line: line)
    }

    func testPlannerClassifiesNoOpAppendBackfillAndCorrection() {
        let first = date(10)
        let last = date(20)

        XCTAssertEqual(
            TradeChangeSet(previousFirstDate: first, previousLastDate: last)
                .plan(simulationStart: date(15), firstStableTechnicalDate: date(12)),
            .none
        )
        XCTAssertEqual(
            TradeChangeSet(previousFirstDate: first, previousLastDate: last, insertedDates: [date(21)])
                .plan(simulationStart: date(15), firstStableTechnicalDate: date(12)),
            RecalculationPlan(technical: .from(date(21)), simulation: .from(date(21)))
        )
        XCTAssertEqual(
            TradeChangeSet(previousFirstDate: first, previousLastDate: last, insertedDates: [date(9)])
                .plan(simulationStart: date(15), firstStableTechnicalDate: date(12)),
            RecalculationPlan(technical: .backfill(from: date(9)), simulation: .none)
        )
        XCTAssertEqual(
            TradeChangeSet(previousFirstDate: first, previousLastDate: last, modifiedDates: [date(18)])
                .plan(simulationStart: date(15), firstStableTechnicalDate: date(12)),
            RecalculationPlan(
                technical: .from(date(18)),
                simulation: .from(date(18))
            )
        )
    }

    func testFullPassSets250DayStabilityBoundary() throws {
        let fixture = try makeFixture()
        let trace = try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)

        XCTAssertEqual(trace.technicalDates.count, 320)
        XCTAssertEqual(trace.simulationDates.count, 320)
        XCTAssertTrue(trades.prefix(249).allSatisfy { !$0.tUpdated })
        XCTAssertTrue(trades.dropFirst(249).allSatisfy(\.tUpdated))
    }

    func testVolumeAveragesUsePriorClosedTradeAndIncludeInteriorZero() throws {
        let fixture = try makeFixture(count: 25, simulationStartIndex: 20)
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        for index in trades.indices {
            trades[index].volumeClose = 100 + Double(index)
        }
        trades[10].volumeClose = 0

        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())

        let expectedValues = trades[0...19].map(\.volumeClose)
        let expectedAverage = expectedValues.reduce(0, +) / Double(expectedValues.count)
        let expectedDiff = round(
            10000 * (trades[19].volumeClose - expectedAverage) / trades[19].volumeClose
        ) / 100
        XCTAssertEqual(trades[20].vMa20, expectedAverage, accuracy: 0.000_000_1)
        XCTAssertEqual(trades[20].vMa20Diff, expectedDiff, accuracy: 0.000_000_1)
        XCTAssertNotEqual(trades[20].vMa20, trades[21].vMa20)
    }

    func testVolumeStatisticsDoNotAdvancePastInvalidLatestEndpoint() throws {
        let fixture = try makeFixture(count: 25, simulationStartIndex: 20)
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        trades[19].volumeClose = 0

        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())

        XCTAssertEqual(trades[20].vMa20, trades[19].vMa20, accuracy: 0.000_000_1)
        XCTAssertEqual(trades[20].vMa20Days, trades[19].vMa20Days)
        XCTAssertEqual(trades[20].vMa20DiffMax9, trades[19].vMa20DiffMax9)
        XCTAssertEqual(trades[20].vMa20DiffZ125, trades[19].vMa20DiffZ125)
    }

    func testVolumeStatisticsRequireCloseAtOrAfter1330() throws {
        let fixture = try makeFixture(count: 25, simulationStartIndex: 20)
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        trades[19].dateTime = twDateTime.time1330(trades[19].date).addingTimeInterval(-60)

        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())

        XCTAssertEqual(trades[20].vMa60, trades[19].vMa60, accuracy: 0.000_000_1)
        XCTAssertEqual(trades[20].vMa60Days, trades[19].vMa60Days)
        XCTAssertEqual(trades[20].vMa60DiffZ250, trades[19].vMa60DiffZ250)
    }

    func testExistingTradesReceiveOneTimeVolumeStatisticsMigration() throws {
        let fixture = try makeFixture(count: 25, simulationStartIndex: 20)
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        XCTAssertTrue(trades.allSatisfy { $0.vMa20 == 0 && $0.vMa60 == 0 })

        try fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)

        XCTAssertGreaterThan(trades[20].vMa20, 0)
        XCTAssertGreaterThan(trades[20].vMa60, 0)
        let migrated20 = trades[20].vMa20
        try fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)
        XCTAssertEqual(trades[20].vMa20, migrated20)
    }

    func testAppendOnlyTouchesNewRowsAndMatchesFullOracle() throws {
        let incremental = try makeFixture()
        let oracle = try makeFixture()
        try incremental.technical.recalculate(stock: incremental.stock, plan: fullPlan())
        try oracle.technical.recalculate(stock: oracle.stock, plan: fullPlan())

        for index in 320..<323 {
            insertTrade(index: index, into: incremental.context, stock: incremental.stock)
            insertTrade(index: index, into: oracle.context, stock: oracle.stock)
        }
        let changes = TradeChangeSet(
            previousFirstDate: date(0),
            previousLastDate: date(319),
            insertedDates: Set((320..<323).map(date))
        )
        let trace = try incremental.technical.recalculate(stock: incremental.stock, changes: changes)
        try oracle.technical.recalculate(stock: oracle.stock, plan: fullPlan())

        XCTAssertEqual(trace.technicalDates, (320..<323).map(date))
        XCTAssertEqual(trace.simulationDates, (320..<323).map(date))
        let incrementalTrades = try Trade.fetch(in: incremental.context, for: incremental.stock, ascending: true)
        let oracleTrades = try Trade.fetch(in: oracle.context, for: oracle.stock, ascending: true)
        for index in 320..<323 {
            assertEqual(snapshot(incrementalTrades[index]), snapshot(oracleTrades[index]))
        }
    }

    func testCorrectionIncludingVolumeMatchesFullOracleAndUsesExpectedScope() throws {
        let incremental = try makeFixture()
        let oracle = try makeFixture()
        try incremental.technical.recalculate(stock: incremental.stock, plan: fullPlan())
        try oracle.technical.recalculate(stock: oracle.stock, plan: fullPlan())
        let incrementalTrades = try Trade.fetch(in: incremental.context, for: incremental.stock, ascending: true)
        let oracleTrades = try Trade.fetch(in: oracle.context, for: oracle.stock, ascending: true)
        incrementalTrades[300].volumeClose += 777
        oracleTrades[300].volumeClose += 777

        let changes = TradeChangeSet(
            previousFirstDate: date(0),
            previousLastDate: date(319),
            modifiedDates: [date(300)]
        )
        let trace = try incremental.technical.recalculate(stock: incremental.stock, changes: changes)
        try oracle.technical.recalculate(stock: oracle.stock, plan: fullPlan())

        XCTAssertEqual(trace.technicalDates.count, 20)
        XCTAssertEqual(trace.simulationDates.count, 20)
        for index in 300..<320 {
            assertEqual(snapshot(incrementalTrades[index]), snapshot(oracleTrades[index]))
        }
    }

    func testLatestTradeCorrectionOnlyRecalculatesTodayAndInheritsYesterdayState() throws {
        let fixture = try makeFixture()
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        trades[318].simMoneyLackedCumulative = true
        trades[318].simInvestExceedCumulative = 7
        trades[319].volumeClose += 1

        let trace = try fixture.technical.recalculate(
            stock: fixture.stock,
            changes: TradeChangeSet(
                previousFirstDate: date(0),
                previousLastDate: date(319),
                modifiedDates: [date(319)]
            )
        )

        XCTAssertEqual(trace.technicalDates, [date(319)])
        XCTAssertEqual(trace.simulationDates, [date(319)])
        XCTAssertTrue(trades[319].simMoneyLackedCumulative)
        XCTAssertEqual(trades[319].simInvestExceedCumulative, 7)
        XCTAssertTrue(fixture.stock.simMoneyLacked)
        XCTAssertEqual(fixture.stock.simInvestExceed, 7)
    }

    func testBackfillStopsAtFirstStableTradeAndDoesNotRecomputeSimulation() throws {
        let fixture = try makeFixture()
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let originalStable = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)[249]
        let originalSnapshot = snapshot(originalStable)

        for index in -10..<0 {
            insertTrade(index: index, into: fixture.context, stock: fixture.stock)
        }
        let changes = TradeChangeSet(
            previousFirstDate: date(0),
            previousLastDate: date(319),
            insertedDates: Set((-10..<0).map(date))
        )
        let trace = try fixture.technical.recalculate(stock: fixture.stock, changes: changes)

        XCTAssertEqual(trace.technicalDates.count, 260)
        XCTAssertTrue(trace.simulationDates.isEmpty)
        XCTAssertNotEqual(snapshot(originalStable).technical, originalSnapshot.technical)
    }

    func testNoOpAndSimulationOnlyScopesDoNotRunTechnicalUpdate() throws {
        let fixture = try makeFixture()
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let emptyTrace = try fixture.technical.recalculate(
            stock: fixture.stock,
            changes: TradeChangeSet(previousFirstDate: date(0), previousLastDate: date(319))
        )
        XCTAssertEqual(emptyTrace, RecalculationTrace())

        let simTrace = try fixture.technical.recalculate(
            stock: fixture.stock,
            plan: RecalculationPlan(technical: .none, simulation: .from(date(300)))
        )
        XCTAssertTrue(simTrace.technicalDates.isEmpty)
        XCTAssertEqual(simTrace.simulationDates.count, 20)
    }

    func testDirtyMarkersRecoverAndClearAfterSuccessfulRecalculation() throws {
        let fixture = try makeFixture()
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        fixture.stock.technicalDirtyFrom = date(300)
        fixture.stock.simulationDirtyFrom = date(300)
        try fixture.context.save()

        try fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)

        XCTAssertEqual(fixture.technical.lastRecalculationTrace.technicalDates.count, 20)
        XCTAssertEqual(fixture.technical.lastRecalculationTrace.simulationDates.count, 20)
        XCTAssertNil(fixture.stock.technicalDirtyFrom)
        XCTAssertNil(fixture.stock.simulationDirtyFrom)
    }

    func testExistingStorePerformsOneFullSimulationStateMigration() throws {
        let fixture = try makeFixture()
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        fixture.stock.simulationStateVersion = 0
        try fixture.context.save()

        try fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)

        XCTAssertEqual(fixture.technical.lastRecalculationTrace.simulationDates.count, 320)
        XCTAssertEqual(fixture.stock.simulationStateVersion, 1)
    }

    func testResetPolicyControlsUserActionsIndependentlyOfTechnicalWork() throws {
        let fixture = try makeFixture(count: 20, simulationStartIndex: 10)
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        trades[5].simReversed = "B+"
        trades[5].simInvestByUser = 1

        let trace = try fixture.technical.recalculate(
            stock: fixture.stock,
            plan: RecalculationPlan(
                technical: .none,
                simulation: .none,
                resetPolicy: .clearUserActions
            )
        )

        XCTAssertEqual(trace, RecalculationTrace())
        XCTAssertEqual(trades[5].simReversed, "")
        XCTAssertEqual(trades[5].simInvestByUser, 0)
    }

    func testSimulationEndPreservesThreeYearTestingBoundary() throws {
        let fixture = try makeFixture(count: 100, simulationStartIndex: 10)
        let trace = try fixture.technical.recalculate(
            stock: fixture.stock,
            plan: RecalculationPlan(
                technical: .none,
                simulation: .all,
                saveResults: false,
                simulationEnd: date(50)
            )
        )

        XCTAssertEqual(trace.simulationDates, (0...50).map(date))
    }
}
