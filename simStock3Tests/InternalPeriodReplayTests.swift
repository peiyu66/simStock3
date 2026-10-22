import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class InternalPeriodReplayTests: XCTestCase {
    private enum Failure: Error { case save }
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let stock: Stock
        let trades: [Trade]
        let technical: Technical
    }
    private func date(_ index: Int) -> Date {
        let first = twDateTime.dateFromString("2024/01/02")!
        let days = index < 260 ? index * 366 / 260 : 366 + index - 260
        return twDateTime.time1330(twDateTime.calendar.date(byAdding: .day, value: days, to: first)!)
    }
    private func fixture(count: Int = 330, market: Bool = true) throws -> Fixture {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        if market { try RecalculationMarketFixture.seed(dates: (0..<count).map(date), in: context) }
        let stock = Stock(sId: "PERIOD", sName: "期間診斷", group: "測試",
            dateFirst: date(0), dateStart: date(260), simInvestAuto: 2, simMoneyBase: 100)
        context.insert(stock)
        let trades = (0..<count).map { index in
            let trade = Trade(stock: stock, dateTime: date(index))
            let close = 100 + sin(Double(index) / 9) * 10 + Double(index) * 0.03
            trade.priceOpen = close; trade.priceHigh = close + 1; trade.priceLow = close - 1
            trade.priceClose = close; trade.volumeClose = 1_000 + Double(index)
            trade.dataSource = "TWSE"
            context.insert(trade)
            return trade
        }
        try context.save()
        let technical = Technical(modelContext: context)
        RecalculationInvalidation.simulation(stock, from: stock.effectiveSimulationStart)
        let trace = try technical.recalculate(stock: stock,
            plan: .init(technical: .all, simulation: .none, deferSimulation: true))
        XCTAssertEqual(trace.technicalDates, trades.map(\.dateTime))
        XCTAssertTrue(trace.simulationDates.isEmpty)
        XCTAssertNotNil(stock.simulationDirtyFrom, "T-only research base must retain invalid S")
        return Fixture(container: container, context: context, stock: stock, trades: trades, technical: technical)
    }

    private func ordinary(_ trade: Trade) -> [Double] {
        [trade.tMa20, trade.tMa60, trade.tKdK, trade.tKdD, trade.tOsc, trade.vMa20, trade.vZ250]
    }
    private func path(_ trade: Trade) -> [Double?] {
        [Double(trade.tPricePathPhaseRaw), trade.tPricePathBarrier,
         trade.tPricePathAnchorClose, trade.tPricePathExtremeClose, Double(trade.tPricePathDaysSinceExtreme)]
    }

    func testLaterWindowWithDifferentRawOriginRebuildsRollingTOnce() async throws {
        let f = try fixture()
        let cold = try fixture()
        defer { withExtendedLifetime((f.container, cold.container)) {} }
        let start = date(280)
        let end = date(310)
        let result = try InternalPeriodReplay.replay(stock: f.stock, start: start, end: end,
            money: 100, investments: 2, technical: f.technical, in: f.context)
        let visible = try Trade.fetchCalculationWindow(in: f.context, for: f.stock)
        XCTAssertEqual(result.trace.ordinaryTechnicalDates, visible.map(\.dateTime))
        XCTAssertEqual(result.trace.pricePathDates, visible.map(\.dateTime))
        XCTAssertEqual(result.trace.simulationDates,
            visible.filter { !$0.isBeforeSimulationStart && $0.dateTime <= end }.map(\.dateTime))
        XCTAssertEqual(result.status, .targetPeriodValid)
        XCTAssertEqual(visible.first?.tKdK, 50)
        XCTAssertEqual(visible.first?.tKdD, 50)
        // Original formulas retain recursive state. A different raw origin must
        // match a cold whole-window pass, even where the old rows were mature.
        cold.stock.dateStart = start
        cold.stock.invalidateCalculationWindow()
        _ = try cold.technical.recalculate(stock: cold.stock,
            plan: .init(technical: .all, simulation: .none, deferSimulation: true))
        let coldVisible = try Trade.fetchCalculationWindow(in: cold.context, for: cold.stock)
        XCTAssertEqual(visible.map(ordinary), coldVisible.map(ordinary))
        XCTAssertEqual(visible.map(path), coldVisible.map(path))
        let reference = try InternalPeriodReplay.replay(stock: cold.stock, start: start, end: end,
            money: 100, investments: 2, technical: cold.technical, in: cold.context)
        XCTAssertTrue(reference.trace.technicalDates.isEmpty)
        func simulation(_ trade: Trade) -> [Double?] {
            [trade.simQtyBuy, trade.simQtySell, trade.simQtyInventory, trade.simAmtBalance,
             trade.simAmtCost, trade.rollAmtProfit, trade.rollAmtRoi, trade.simFitTrend]
        }
        XCTAssertEqual(result.targetTrades.map(simulation), reference.targetTrades.map(simulation))
        let repeated = try InternalPeriodReplay.replay(stock: f.stock, start: start, end: end,
            money: 100, investments: 2, technical: f.technical, in: f.context)
        XCTAssertTrue(repeated.trace.technicalDates.isEmpty, "The same completed origin must not rebuild T again")
        XCTAssertEqual(repeated.targetTrades.map(simulation), reference.targetTrades.map(simulation))
        XCTAssertEqual(try Trade.fetch(in: f.context, for: f.stock).count, 330,
                       "Research must retain raw rows outside the target period")
    }

    func testMissingMarketRejectsReportEvenWhenOldTailContainsFiniteProfits() async throws {
        let f = try fixture(market: false)
        defer { withExtendedLifetime(f.container) {} }
        f.trades[310].rollAmtProfit = 999
        f.trades[310].rollRounds = 5
        f.trades[310].rollDays = 100
        XCTAssertThrowsError(try InternalPeriodReplay.replay(stock: f.stock,
            start: date(260), end: date(310), money: 100, investments: 2,
            technical: f.technical, in: f.context)) { error in
                XCTAssertTrue(error is InternalPeriodReplay.ReplayError)
            }
        XCTAssertTrue(f.technical.lastRecalculationTrace.simulationDates.isEmpty)
        XCTAssertEqual(f.technical.lastRecalculationTrace.simulationDependencyIssue, .marketMissing)
        XCTAssertNotNil(f.stock.simulationDirtyFrom)
        XCTAssertEqual(f.trades[310].rollAmtProfit, 999,
                       "Finite retained values are not evidence that S ran")
    }

    func testCompletedTargetRetainsFutureRawDirtyAndOldWholeStockVersion() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let oldVersion = f.stock.simulationStateVersion
        let result = try InternalPeriodReplay.replay(stock: f.stock,
            start: date(260), end: date(300), money: 100, investments: 2,
            technical: f.technical, in: f.context)
        XCTAssertEqual(result.status, .targetPeriodValid)
        XCTAssertEqual(result.trace.simulationDates, (260...300).map(date))
        XCTAssertTrue(result.trace.technicalDates.isEmpty)
        XCTAssertEqual(result.finalTrade?.dateTime, date(300))
        XCTAssertEqual(f.stock.simulationDirtyFrom, date(301))
        XCTAssertEqual(f.stock.simulationStateVersion, oldVersion)
        XCTAssertNotEqual(oldVersion, Int(Technical.simulationRuleVersion.dropFirst())!)
        XCTAssertEqual(try Trade.fetch(in: f.context, for: f.stock).last?.dateTime, date(329))
        XCTAssertFalse(f.context.hasChanges, "Scoring is allowed only after a successful save")
    }

    func testNoSimulationDatesIsExplicitAndDoesNotScorePreparationOrRequireMarket() async throws {
        let f = try fixture(count: 100, market: false)
        defer { withExtendedLifetime(f.container) {} }
        f.trades[99].rollRounds = 9
        f.trades[99].rollAmtProfit = 999
        let result = try InternalPeriodReplay.replay(stock: f.stock,
            start: date(260), end: date(99), money: 100, investments: 2,
            technical: f.technical, in: f.context)
        XCTAssertEqual(result.status, .noSimulationDates)
        XCTAssertNil(result.finalTrade)
        XCTAssertTrue(result.targetTrades.isEmpty)
        XCTAssertTrue(result.trace.simulationDates.isEmpty)
        XCTAssertNotNil(f.stock.simulationDirtyFrom)
        XCTAssertNil(f.stock.technicalDirtyFrom)
    }

    func testFinalSaveFailureCannotReturnValidPeriod() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        var saves = 0
        f.technical.recalculationSave = {
            saves += 1
            if saves == 2 { throw Failure.save }
            try f.context.save()
        }
        XCTAssertThrowsError(try InternalPeriodReplay.replay(stock: f.stock,
            start: date(260), end: date(300), money: 100, investments: 2,
            technical: f.technical, in: f.context)) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(f.stock.simulationDirtyFrom, .distantPast)
    }

    func testDiagnosticCacheRejectsLegacyMarkerAndChangesWithFullCommitOrInput() throws {
        let commit = String(repeating: "a", count: 40)
        let first = try UpdateCycleDiagnosticIdentity(sample: "A", profile: "abcd9-v3",
            ruleCommit: commit, inputSHA256: String(repeating: "1", count: 64),
            technicalVersion: "T4", marketVersion: 7)
        XCTAssertFalse(first.matches(marker: Data("T3".utf8)))
        XCTAssertTrue(first.matches(marker: try JSONEncoder().encode(first)))
        let differentCommit = try UpdateCycleDiagnosticIdentity(sample: "A", profile: "abcd9-v3",
            ruleCommit: String(repeating: "a", count: 39) + "b", inputSHA256: first.inputSHA256,
            technicalVersion: "T4", marketVersion: 7)
        let differentInput = try UpdateCycleDiagnosticIdentity(sample: "A", profile: "abcd9-v3",
            ruleCommit: commit, inputSHA256: String(repeating: "2", count: 64),
            technicalVersion: "T4", marketVersion: 7)
        XCTAssertNotEqual(first.cacheName, differentCommit.cacheName)
        XCTAssertNotEqual(first.cacheName, differentInput.cacheName)
        XCTAssertFalse(first.matches(marker: try JSONEncoder().encode(differentCommit)))
        XCTAssertFalse(first.matches(marker: try JSONEncoder().encode(differentInput)))
    }

    func testDiagnosticRunIdentityIsUniqueSafeAndCannotRecordFormalDecisionBase() throws {
        let commit = String(repeating: "a", count: 40)
        let first = try UpdateCycleDiagnosticIdentity.runID(sample: "A", fullWindow: false,
            ruleCommit: commit, requestedID: nil)
        let next = try UpdateCycleDiagnosticIdentity.runID(sample: "A", fullWindow: false,
            ruleCommit: commit, requestedID: nil)
        XCTAssertNotEqual(first, next)
        XCTAssertTrue(first.hasPrefix("update-cycle-"))
        XCTAssertFalse(first.contains("baseline"))
        XCTAssertThrowsError(try UpdateCycleDiagnosticIdentity.runID(sample: "A", fullWindow: false,
            ruleCommit: commit, requestedID: "../formal"))
        XCTAssertThrowsError(try UpdateCycleDiagnosticIdentity.validate(
            arguments: ["app", "--update-cycle-diagnostic", "--record-decision-base"], ruleCommit: commit))
        XCTAssertThrowsError(try UpdateCycleDiagnosticIdentity.validate(
            arguments: ["app", "--update-cycle-diagnostic", "--formal-resumable-update-baseline-v40"], ruleCommit: commit))
        XCTAssertThrowsError(try UpdateCycleDiagnosticIdentity.validate(
            arguments: ["app"], ruleCommit: "aaaaaaa"))
    }

    func testInputIdentityIncludesWALContentAndDoesNotModifySource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("fixture.store")
        let raw = Data("small isolated input".utf8)
        try raw.write(to: store)
        let original = try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: store)
        try Data("new raw observations".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        let appended = try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: store)
        XCTAssertNotEqual(original, appended)
        XCTAssertEqual(try Data(contentsOf: store), raw)
    }
}
