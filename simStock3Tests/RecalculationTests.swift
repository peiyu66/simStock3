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

    private func prepareHeldPosition(
        in fixture: Fixture,
        unitCost: Double
    ) throws -> [Trade] {
        let trades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        )
        let previous = trades[0]
        previous.simRule = "H"
        previous.simRuleBuy = "H"
        previous.simQtyInventory = 1
        previous.simAmtCost = unitCost * 1_000
        previous.simUnitCost = unitCost
        previous.simAmtBalance = fixture.stock.moneyBase - previous.simAmtCost
        previous.simInvestTimes = 1
        previous.simDays = 10
        previous.rollDays = 10
        previous.rollRounds = 1
        previous.rollAmtCost = previous.simAmtCost
        return trades
    }

    private func prepareNormalBuy(in fixture: Fixture) throws -> [Trade] {
        let trades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        )
        let previous = trades[0]
        let trade = trades[1]
        previous.simRule = "_"
        previous.simQtyInventory = 0
        previous.simQtySell = 0
        previous.simInvestTimes = 0
        trade.tMa60DiffZ125 = 1
        trade.tMa20Diff = 2
        trade.tMa60Diff = 0.5
        trade.tMa20Days = 1
        trade.tMa20DiffMin9 = -10
        trade.tMa60DiffMin9 = -10
        trade.tKdKMin9 = -10
        trade.tOscMin9 = -10
        return trades
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
                trade.tZ125, trade.tZ250,
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

    func testStrategyFitEMAUsesTwentyAndOneHundredTwentyFiveDayRates() {
        var state = InternalBacktestDecisionRecorder.StrategyFitEMA()
        XCTAssertFalse(state.isValid)
        XCTAssertNil(state.fitTrend)

        state.update(fitLevel: 10, roi: 4, days: 30)
        XCTAssertEqual(state.observationCount, 1)
        XCTAssertEqual(state.fitFast, 10)
        XCTAssertEqual(state.fitSlow, 10)
        XCTAssertEqual(state.fitTrend, 0)
        XCTAssertTrue(state.isValid)

        state.update(fitLevel: 20, roi: 14, days: 40)
        XCTAssertEqual(state.observationCount, 2)
        XCTAssertEqual(state.fitFast!, 10 + 20.0 / 21.0, accuracy: 0.000_000_1)
        XCTAssertEqual(state.fitSlow!, 10 + 20.0 / 126.0, accuracy: 0.000_000_1)
        XCTAssertEqual(
            state.fitTrend!,
            (10 + 20.0 / 21.0) - (10 + 20.0 / 126.0),
            accuracy: 0.000_000_1
        )

        state.update(fitLevel: .infinity, roi: 0, days: 0)
        XCTAssertEqual(state.observationCount, 2)
    }

    func testStrategyFitRecorderDoesNotChangeSimulationOutputs() throws {
        let control = try makeFixture()
        let recorded = try makeFixture()
        try control.technical.recalculate(stock: control.stock, plan: fullPlan())

        InternalBacktestDecisionRecorder.begin(.init(
            sampleID: "TEST",
            inputSnapshotID: "TEST",
            decisionBaseID: "TEST-v5",
            dataRuleVersion: "T2/S19",
            ruleVersion: "S17",
            ruleCommit: "test",
            through: "2024/12/31",
            moneyBaseWan: 100,
            automaticInvestments: 2
        ))
        defer { InternalBacktestDecisionRecorder.reset() }
        InternalBacktestDecisionRecorder.beginWindow(end: date(319))
        try recorded.technical.recalculate(stock: recorded.stock, plan: fullPlan())

        let controlTrades = try Trade.fetch(
            in: control.context,
            for: control.stock,
            ascending: true
        )
        let recordedTrades = try Trade.fetch(
            in: recorded.context,
            for: recorded.stock,
            ascending: true
        )
        XCTAssertEqual(controlTrades.count, recordedTrades.count)
        for (lhs, rhs) in zip(controlTrades, recordedTrades) {
            assertEqual(snapshot(lhs), snapshot(rhs))
        }
        XCTAssertFalse(InternalBacktestDecisionRecorder.events.isEmpty)
        let gradeEvents = InternalBacktestDecisionRecorder.events.filter {
            $0.pending.phase == .grade
        }
        XCTAssertFalse(gradeEvents.isEmpty)
        XCTAssertTrue(gradeEvents.allSatisfy { $0.pending.strategyFitObservation != nil })
        let gradeEventsByDate = Dictionary(uniqueKeysWithValues: gradeEvents.map {
            ($0.pending.date, $0)
        })
        var expectedPriorObservationCount = 0
        for trade in recordedTrades where !trade.isBeforeSimulationStart {
            let dateText = twDateTime.stringFromDate(trade.dateTime)
            let observation = try XCTUnwrap(
                gradeEventsByDate[dateText]?.pending.strategyFitObservation,
                "Missing Grade strategy-fit observation for \(dateText)"
            )
            XCTAssertEqual(observation.fitObservationCount, expectedPriorObservationCount)
            if trade.days > 0 {
                expectedPriorObservationCount += 1
            }
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        try InternalBacktestDecisionRecorder.write(to: output, outcomes: [])
        let manifestData = try Data(contentsOf: output.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        XCTAssertEqual((manifest["formatVersion"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual(
            (manifest["strategyFitObservationCount"] as? NSNumber)?.intValue,
            gradeEvents.count
        )
        XCTAssertEqual(
            (manifest["strategyFitObservationLinkCount"] as? NSNumber)?.intValue,
            InternalBacktestDecisionRecorder.events.count
        )
    }

    func testEnsureStockUsesRequestedAutomaticInvestmentDefault() throws {
        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let stock = try Stock.ensureStock(
            in: context,
            sId: "NEW",
            sName: "新股",
            group: "測試",
            dateFirst: date(0),
            dateStart: date(10),
            simMoneyBase: 70,
            simInvestAuto: 2
        )

        XCTAssertEqual(stock.simInvestAuto, 2)
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

        let priceWindow = trades.suffix(125).map(\.priceClose)
        let priceAverage = priceWindow.reduce(0, +) / Double(priceWindow.count)
        let priceVariance = priceWindow.reduce(0) {
            $0 + pow($1 - priceAverage, 2)
        } / Double(priceWindow.count)
        let expectedPriceZ = (trades.last!.priceClose - priceAverage) / sqrt(priceVariance)
        XCTAssertEqual(trades.last!.tZ125, expectedPriceZ, accuracy: 0.000_000_1)
    }

    func testNewTradeImmediatelyMarksPreparationPeriod() throws {
        let fixture = try makeFixture(count: 3, simulationStartIndex: 2)
        let trades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        )

        XCTAssertEqual(trades[0].simRule, "_")
        XCTAssertEqual(trades[1].simRule, "_")
        XCTAssertEqual(trades[2].simRule, "")
    }

    func testVolumeStatisticsIncludeCurrentTWSETradeAndSkipYahooRows() throws {
        let fixture = try makeFixture(count: 25, simulationStartIndex: 20)
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        for index in trades.indices {
            trades[index].volumeClose = 100 + Double(index)
        }
        trades[10].dataSource = "yahoo"
        trades[10].volumeClose = 10_000

        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())

        let expectedValues = trades[0...20]
            .filter { $0.dataSource == "TWSE" }
            .map(\.volumeClose)
        let expectedAverage = expectedValues.reduce(0, +) / Double(expectedValues.count)
        let expectedDiff = round(
            10000 * (trades[20].volumeClose - expectedAverage) / trades[20].volumeClose
        ) / 100
        let volumeVariance = expectedValues.reduce(0) {
            $0 + pow($1 - expectedAverage, 2)
        } / Double(expectedValues.count)
        let expectedVolumeZ = (trades[20].volumeClose - expectedAverage) / sqrt(volumeVariance)
        XCTAssertEqual(trades[20].vMa20, expectedAverage, accuracy: 0.000_000_1)
        XCTAssertEqual(trades[20].vMa20Diff, expectedDiff, accuracy: 0.000_000_1)
        XCTAssertEqual(trades[20].vZ125, expectedVolumeZ, accuracy: 0.000_000_1)
        XCTAssertEqual(trades[20].vZ250, expectedVolumeZ, accuracy: 0.000_000_1)
        XCTAssertEqual(trades[20].vMax9, 120)
        XCTAssertEqual(trades[20].vMin9, 112)
        XCTAssertNotEqual(trades[20].vMa20, trades[21].vMa20)
    }

    func testYahooIntradayTradeRetainsLatestTWSEVolumeStatistics() throws {
        let fixture = try makeFixture(count: 25, simulationStartIndex: 20)
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        trades[20].dataSource = "yahoo"
        trades[20].volumeClose = 50_000

        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())

        XCTAssertEqual(trades[20].vMa20, trades[19].vMa20, accuracy: 0.000_000_1)
        XCTAssertEqual(trades[20].vMa20Days, trades[19].vMa20Days)
        XCTAssertEqual(trades[20].vMa20DiffMax9, trades[19].vMa20DiffMax9)
        XCTAssertEqual(trades[20].vMa20DiffZ125, trades[19].vMa20DiffZ125)
        XCTAssertEqual(trades[20].vMax9, trades[19].vMax9)
        XCTAssertEqual(trades[20].vMin9, trades[19].vMin9)
        XCTAssertEqual(trades[20].vZ125, trades[19].vZ125)
        XCTAssertEqual(trades[20].vZ250, trades[19].vZ250)
    }

    func testTWSESourceIsAuthoritativeRegardlessOfStoredTime() throws {
        let fixture = try makeFixture(count: 25, simulationStartIndex: 20)
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        trades[20].dateTime = twDateTime.time1330(trades[20].date).addingTimeInterval(-60)
        trades[20].volumeClose = 50_000

        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())

        XCTAssertNotEqual(trades[20].vMa60, trades[19].vMa60)
        XCTAssertEqual(trades[20].vMax9, 50_000)
    }

    func testOfficialTWSEZeroVolumeRemainsAnObservation() throws {
        let fixture = try makeFixture(count: 25, simulationStartIndex: 20)
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        trades[20].volumeClose = 0

        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())

        let expectedAverage = trades[1...20].map(\.volumeClose).reduce(0, +) / 20
        XCTAssertEqual(trades[20].vMa20, expectedAverage, accuracy: 0.000_000_1)
        XCTAssertEqual(trades[20].vMin9, 0)
        XCTAssertEqual(trades[20].vMa20Diff, 0)
    }

    func testExistingTradesReceiveOneTimeVolumeStatisticsMigration() async throws {
        let fixture = try makeFixture(count: 25, simulationStartIndex: 20)
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        XCTAssertTrue(trades.allSatisfy { $0.vMa20 == 0 && $0.vMa60 == 0 })

        try await fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)

        XCTAssertGreaterThan(trades[20].vMa20, 0)
        XCTAssertGreaterThan(trades[20].vMa60, 0)
        let migrated20 = trades[20].vMa20
        try await fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)
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
            let trade = insertTrade(
                index: index,
                into: fixture.context,
                stock: fixture.stock
            )
            // Reproduce rows inserted by the older backfill path before the
            // preparation-period marker was initialized at creation time.
            trade.simRule = ""
        }
        let changes = TradeChangeSet(
            previousFirstDate: date(0),
            previousLastDate: date(319),
            insertedDates: Set((-10..<0).map(date))
        )
        let trace = try fixture.technical.recalculate(stock: fixture.stock, changes: changes)

        XCTAssertEqual(trace.technicalDates.count, 260)
        XCTAssertTrue(trace.simulationDates.isEmpty)
        let backfilledTrades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        ).prefix(10)
        XCTAssertTrue(backfilledTrades.allSatisfy(\.isBeforeSimulationStart))
        XCTAssertTrue(backfilledTrades.allSatisfy { $0.simRule == "_" })
        XCTAssertNotEqual(snapshot(originalStable).technical, originalSnapshot.technical)
    }

    func testBackfillContinuesUntilTWSEVolumeWindowIsStable() throws {
        let fixture = try makeFixture()
        let initialTrades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        )
        for index in 0..<20 {
            initialTrades[index].dataSource = "yahoo"
        }
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())

        for index in -10..<0 {
            insertTrade(index: index, into: fixture.context, stock: fixture.stock)
        }
        let trace = try fixture.technical.recalculate(
            stock: fixture.stock,
            changes: TradeChangeSet(
                previousFirstDate: date(0),
                previousLastDate: date(319),
                insertedDates: Set((-10..<0).map(date))
            )
        )

        // The price window is stable at row 259 after insertion, but the first
        // 250-observation TWSE volume window is not stable until row 269.
        XCTAssertEqual(trace.technicalDates.count, 270)
        XCTAssertTrue(trace.simulationDates.isEmpty)
    }

    func testSimulationStartDateReactivatesFormerPreparationRows() throws {
        let fixture = try makeFixture(count: 30, simulationStartIndex: 20)
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let trades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        )
        XCTAssertTrue(trades[15].isBeforeSimulationStart)
        XCTAssertEqual(trades[15].simRule, "_")

        fixture.stock.dateStart = date(10)
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())

        XCTAssertFalse(trades[15].isBeforeSimulationStart)
        XCTAssertNotEqual(trades[15].simRule, "_")
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

    func testDirtyMarkersRecoverAndClearAfterSuccessfulRecalculation() async throws {
        let fixture = try makeFixture()
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        fixture.stock.technicalDirtyFrom = date(300)
        fixture.stock.simulationDirtyFrom = date(300)
        try fixture.context.save()

        try await fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)

        XCTAssertEqual(fixture.technical.lastRecalculationTrace.technicalDates.count, 20)
        XCTAssertEqual(fixture.technical.lastRecalculationTrace.simulationDates.count, 20)
        XCTAssertNil(fixture.stock.technicalDirtyFrom)
        XCTAssertNil(fixture.stock.simulationDirtyFrom)
    }

    func testManualPlusOneClearsWhenAutomaticAdditionActuallyExecutes() throws {
        let fixture = try makeFixture(count: 2, simulationStartIndex: 0)
        let trades = try prepareHeldPosition(in: fixture, unitCost: 120)
        let trade = trades[1]
        trade.tMa20Diff = -25
        trade.tMa60Diff = -25
        trade.simInvestByUser = 1
        fixture.stock.simInvestUser = 99

        let trace = try fixture.technical.recalculate(
            stock: fixture.stock,
            plan: RecalculationPlan(
                technical: .none,
                simulation: .from(trade.dateTime)
            )
        )

        XCTAssertEqual(trade.simInvestAdded, 1)
        XCTAssertEqual(trade.simInvestByUser, 0)
        XCTAssertEqual(trace.userActions.clearedRedundant, 1)
        XCTAssertEqual(fixture.stock.simInvestUser, 0)
    }

    func testManualMinusOneClearsWhenThereIsNoAutomaticAddition() throws {
        let fixture = try makeFixture(count: 2, simulationStartIndex: 0)
        let trades = try prepareHeldPosition(in: fixture, unitCost: 75)
        let trade = trades[1]
        trade.simInvestByUser = -1

        let trace = try fixture.technical.recalculate(
            stock: fixture.stock,
            plan: RecalculationPlan(
                technical: .none,
                simulation: .from(trade.dateTime)
            )
        )

        XCTAssertEqual(trade.simInvestAdded, 0)
        XCTAssertEqual(trade.simInvestByUser, 0)
        XCTAssertEqual(trace.userActions.clearedRedundant, 1)
    }

    func testSellReversalIsRetainedOnlyWhenItChangesTheNormalResult() throws {
        let retainedFixture = try makeFixture(count: 2, simulationStartIndex: 0)
        let retainedTrades = try prepareHeldPosition(in: retainedFixture, unitCost: 120)
        retainedTrades[1].simReversed = "S+"
        let retainedTrace = try retainedFixture.technical.recalculate(
            stock: retainedFixture.stock,
            plan: RecalculationPlan(
                technical: .none,
                simulation: .from(retainedTrades[1].dateTime)
            )
        )
        XCTAssertEqual(retainedTrades[1].simReversed, "S+")
        XCTAssertGreaterThan(retainedTrades[1].simQtySell, 0)
        XCTAssertEqual(retainedTrace.userActions.retained, 1)
        XCTAssertTrue(retainedFixture.stock.simReversed)

        let redundantFixture = try makeFixture(count: 2, simulationStartIndex: 0)
        let redundantTrades = try prepareHeldPosition(in: redundantFixture, unitCost: 50)
        let redundant = redundantTrades[1]
        redundant.tKdJ = 110
        redundant.tKdJZ125 = 2
        redundant.tKdJZ250 = 2
        redundant.tKdKZ125 = 2
        redundant.tKdDZ125 = 2
        redundant.tOscZ125 = 2
        redundant.tOscZ250 = 2
        redundant.simReversed = "S+"
        redundantFixture.stock.simReversed = true
        let redundantTrace = try redundantFixture.technical.recalculate(
            stock: redundantFixture.stock,
            plan: RecalculationPlan(
                technical: .none,
                simulation: .from(redundant.dateTime)
            )
        )
        XCTAssertEqual(redundant.simReversed, "")
        XCTAssertGreaterThan(redundant.simQtySell, 0)
        XCTAssertEqual(redundantTrace.userActions.clearedRedundant, 1)
        XCTAssertFalse(redundantFixture.stock.simReversed)
    }

    func testSellReversalAfterAddedCapitalRestoresOneBaseBeforeRepurchase() throws {
        let fixture = try makeFixture(count: 3, simulationStartIndex: 0)
        let trades = try prepareHeldPosition(in: fixture, unitCost: 120)
        let held = trades[0]
        let reversedSell = trades[1]
        let repurchase = trades[2]
        held.simInvestTimes = 2
        held.simAmtBalance = (2 * fixture.stock.moneyBase) - held.simAmtCost
        reversedSell.simReversed = "S+"
        repurchase.tMa60DiffZ125 = 1
        repurchase.tMa20Diff = 2
        repurchase.tMa60Diff = 0.5
        repurchase.tMa20Days = 1
        repurchase.tMa20DiffMin9 = -10
        repurchase.tMa60DiffMin9 = -10
        repurchase.tKdKMin9 = -10
        repurchase.tOscMin9 = -10

        let trace = try fixture.technical.recalculate(
            stock: fixture.stock,
            plan: RecalculationPlan(
                technical: .none,
                simulation: .from(reversedSell.dateTime)
            )
        )

        XCTAssertEqual(reversedSell.simReversed, "S+")
        XCTAssertGreaterThan(reversedSell.simQtySell, 0)
        XCTAssertEqual(repurchase.simInvestAdded, -1)
        XCTAssertEqual(repurchase.simInvestTimes, 1)
        XCTAssertGreaterThan(repurchase.simQtyBuy, 0)
        XCTAssertFalse(repurchase.simMoneyLackedCumulative)
        XCTAssertFalse(fixture.stock.simMoneyLacked)
        XCTAssertEqual(trace.userActions.retained, 1)
    }

    func testBuyReversalIsRetainedOrClearedAgainstNormalBuy() throws {
        let retainedFixture = try makeFixture(count: 2, simulationStartIndex: 0)
        let retainedTrades = try prepareNormalBuy(in: retainedFixture)
        retainedTrades[1].simReversed = "B-"
        let retainedTrace = try retainedFixture.technical.recalculate(
            stock: retainedFixture.stock,
            plan: RecalculationPlan(
                technical: .none,
                simulation: .from(retainedTrades[1].dateTime)
            )
        )
        XCTAssertEqual(retainedTrades[1].simReversed, "B-")
        XCTAssertEqual(retainedTrades[1].simQtyBuy, 0)
        XCTAssertEqual(retainedTrace.userActions.retained, 1)

        let redundantFixture = try makeFixture(count: 2, simulationStartIndex: 0)
        let redundantTrades = try prepareNormalBuy(in: redundantFixture)
        redundantTrades[1].simReversed = "B+"
        let redundantTrace = try redundantFixture.technical.recalculate(
            stock: redundantFixture.stock,
            plan: RecalculationPlan(
                technical: .none,
                simulation: .from(redundantTrades[1].dateTime)
            )
        )
        XCTAssertEqual(redundantTrades[1].simReversed, "")
        XCTAssertGreaterThan(redundantTrades[1].simQtyBuy, 0)
        XCTAssertEqual(redundantTrace.userActions.clearedRedundant, 1)
    }

    func testNoInventoryClearsSellAndManualActionsAsInvalid() throws {
        let fixture = try makeFixture(count: 2, simulationStartIndex: 0)
        let trades = try prepareNormalBuy(in: fixture)
        let trade = trades[1]
        trade.simReversed = "S-"
        trade.simInvestByUser = 1

        let trace = try fixture.technical.recalculate(
            stock: fixture.stock,
            plan: RecalculationPlan(
                technical: .none,
                simulation: .from(trade.dateTime)
            )
        )

        XCTAssertEqual(trade.simReversed, "")
        XCTAssertEqual(trade.simInvestByUser, 0)
        XCTAssertEqual(trace.userActions.clearedInvalid, 2)
        XCTAssertFalse(fixture.stock.simReversed)
        XCTAssertEqual(fixture.stock.simInvestUser, 0)
    }

    func testP10WhatIfPricesRestoreTheSameActualStateAsOneRealPriceReplay() throws {
        let p10Fixture = try makeFixture()
        let oracleFixture = try makeFixture()
        try p10Fixture.technical.recalculate(stock: p10Fixture.stock, plan: fullPlan())
        try oracleFixture.technical.recalculate(stock: oracleFixture.stock, plan: fullPlan())
        let p10Trades = try Trade.fetch(
            in: p10Fixture.context,
            for: p10Fixture.stock,
            ascending: true
        )
        let oracleTrades = try Trade.fetch(
            in: oracleFixture.context,
            for: oracleFixture.stock,
            ascending: true
        )
        let p10Trade = p10Trades.last!
        let oracleTrade = oracleTrades.last!
        let reversal: String
        if p10Trade.simQtySell > 0 {
            reversal = "S-"
        } else if p10Trade.simQtyBuy > 0 {
            reversal = "B-"
        } else if p10Trade.simQtyInventory > 0 {
            reversal = "S+"
        } else {
            reversal = "B+"
        }
        p10Trade.simReversed = reversal
        oracleTrade.simReversed = reversal

        p10Fixture.technical.runP10ForTesting([p10Fixture.stock])
        _ = try oracleFixture.technical.recalculate(
            stock: oracleFixture.stock,
            plan: RecalculationPlan(
                technical: .from(oracleTrade.dateTime),
                simulation: .from(oracleTrade.dateTime)
            )
        )

        assertEqual(snapshot(p10Trade), snapshot(oracleTrade))
        XCTAssertEqual(p10Fixture.stock.simReversed, oracleFixture.stock.simReversed)
        XCTAssertEqual(p10Fixture.stock.simInvestUser, oracleFixture.stock.simInvestUser)
    }

    func testExistingStorePerformsFullS27MigrationAndRevalidatesUserActions() async throws {
        let fixture = try makeFixture()
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        fixture.stock.simulationStateVersion = 13
        // Model a legacy row containing both reversal and manual-investment
        // inputs. Migration must retain only the intent that still applies.
        trades[261].simReversed = "B+"
        trades[261].simInvestByUser = 1
        try fixture.context.save()

        var progressMessages: [String] = []
        let actions = try await fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock) {
            progressMessages.append($0)
        }

        XCTAssertEqual(fixture.technical.lastRecalculationTrace.simulationDates.count, 320)
        XCTAssertEqual(fixture.stock.simulationStateVersion, 27)
        XCTAssertEqual(trades[261].simReversed, "")
        XCTAssertEqual(trades[261].simInvestByUser, 1)
        XCTAssertEqual(actions.retained, 1)
        XCTAssertEqual(actions.clearedInvalid, 1)
        XCTAssertEqual(progressMessages, ["正在套用新版模擬規則（S13 → S27）"])
    }

    func testPendingMigrationWarningCountsEachStoredUserIntent() throws {
        let fixture = try makeFixture(count: 20, simulationStartIndex: 10)
        let trades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        )
        fixture.stock.technicalStateVersion = 2
        fixture.stock.simulationStateVersion = 9
        trades[12].simReversed = "S+"
        trades[12].simInvestByUser = 1

        let pending = fixture.technical.pendingMigrationUserActions(in: [fixture.stock])

        XCTAssertEqual(pending.stocks, 1)
        XCTAssertEqual(pending.actions, 2)
    }

    func testYahooAndP10CannotRunBeforeRequiredDataRuleMigration() async throws {
        let fixture = try makeFixture()
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        fixture.stock.simulationStateVersion = 9
        let trades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        )
        let lastTrade = trades.last!
        let before = snapshot(lastTrade)
        var migrationRequests = 0
        fixture.technical.requiredDataRuleMigrationRequest = { stocks in
            migrationRequests += stocks.count
        }

        let yahoo = await fixture.technical.updateYahooPrices(stocks: [fixture.stock])
        fixture.technical.runP10ForTesting([fixture.stock])

        XCTAssertEqual(yahoo.requestedStocks, 0)
        XCTAssertEqual(migrationRequests, 2)
        XCTAssertEqual(fixture.stock.simulationStateVersion, 9)
        assertEqual(snapshot(lastTrade), before)
    }

    func testMigrationWarningPreemptsAnExistingLegacyOperation() throws {
        let fixture = try makeFixture(count: 20, simulationStartIndex: 10)
        fixture.stock.technicalStateVersion = 2
        fixture.stock.simulationStateVersion = 9
        let trades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        )
        trades[12].simReversed = "S+"
        let ui = uiObject(modelContext: fixture.context)
        ui.runningMsg = "舊即時作業仍在執行"

        ui.startDailyPriceUpdate(stocks: [fixture.stock])

        guard let alert = ui.simulationMigrationAlert else {
            return XCTFail("S9 人工操作必須先顯示不可取消的遷移警告")
        }
        switch alert.kind {
        case .warning:
            break
        case .result:
            XCTFail("遷移尚未執行，不應先顯示完成結果")
        }
        XCTAssertEqual(fixture.stock.simulationStateVersion, 9)
    }

    func testMigrationWarningPreemptsCatalogSearchDeferral() throws {
        let fixture = try makeFixture(count: 20, simulationStartIndex: 10)
        fixture.stock.technicalStateVersion = 2
        fixture.stock.simulationStateVersion = 9
        let trades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        )
        trades[12].simReversed = "S+"
        let ui = uiObject(modelContext: fixture.context)
        ui.catalogSearchDidBegin()

        ui.startDailyPriceUpdate(
            stocks: [fixture.stock],
            deferWhileSearching: true
        )

        guard let alert = ui.simulationMigrationAlert else {
            return XCTFail("搜尋狀態不得延後或隱藏必要的遷移警告")
        }
        switch alert.kind {
        case .warning:
            break
        case .result:
            XCTFail("遷移尚未執行，不應先顯示完成結果")
        }
        XCTAssertEqual(fixture.stock.simulationStateVersion, 9)
    }

    func testRootMigrationEntryFetchesGroupedStocksWithoutListLifecycle() throws {
        let fixture = try makeFixture(count: 20, simulationStartIndex: 10)
        fixture.stock.technicalStateVersion = 2
        fixture.stock.simulationStateVersion = 9
        let trades = try Trade.fetch(
            in: fixture.context,
            for: fixture.stock,
            ascending: true
        )
        trades[12].simInvestByUser = 1
        let ui = uiObject(modelContext: fixture.context)

        XCTAssertTrue(ui.startRequiredDataRuleMigrationIfNeeded())
        XCTAssertNotNil(ui.simulationMigrationAlert)
        XCTAssertEqual(fixture.stock.simulationStateVersion, 9)
    }

    func testExistingStorePerformsFullT2VolumeMigrationAndPreservesUserActions() async throws {
        let fixture = try makeFixture()
        try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let trades = try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
        fixture.stock.technicalStateVersion = 1
        fixture.stock.simulationStateVersion = 9
        trades[261].simReversed = "B+"
        trades[261].simInvestByUser = 1
        trades.last!.vMax9 = 0
        trades.last!.vZ125 = 0
        try fixture.context.save()

        var progressMessages: [String] = []
        try await fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock) {
            progressMessages.append($0)
        }

        XCTAssertEqual(fixture.technical.lastRecalculationTrace.technicalDates.count, 320)
        XCTAssertEqual(fixture.technical.lastRecalculationTrace.simulationDates.count, 320)
        XCTAssertEqual(fixture.stock.technicalStateVersion, 2)
        XCTAssertEqual(fixture.stock.simulationStateVersion, 27)
        XCTAssertNotEqual(trades.last!.vMax9, 0)
        XCTAssertNotEqual(trades.last!.vZ125, 0)
        XCTAssertEqual(trades[261].simReversed, "")
        XCTAssertEqual(trades[261].simInvestByUser, 1)
        XCTAssertEqual(
            progressMessages,
            ["正在更新新版技術與模擬資料（T1/S9 → T2/S27）"]
        )
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
