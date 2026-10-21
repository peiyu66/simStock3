import Foundation
import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class RecalculationCoverageTests: XCTestCase {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let stock: Stock
        let technical: Technical
    }

    private struct SimulationSnapshot: Equatable {
        let values: [Double]
        let optionalValues: [Double?]
        let strings: [String]
        let flags: [Bool]
        let counts: [Int]
        let warning: Data?
    }

    private enum SaveFailure: Error { case injected }

    private func date(_ offset: Int) -> Date {
        let first = twDateTime.dateFromString("2024/01/02")!
        return twDateTime.time1330(twDateTime.calendar.date(byAdding: .day, value: offset, to: first)!)
    }

    private func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let configuration = url.map {
            ModelConfiguration(schema: schema, url: $0, allowsSave: true, cloudKitDatabase: .none)
        } ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeFixture(count: Int = 60, start: Int = 10, url: URL? = nil) throws -> Fixture {
        let container = try makeContainer(url: url)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stock = Stock(sId: "COVERAGE", sName: "範圍測試", group: "測試",
                          dateFirst: date(0), dateStart: date(start), simInvestAuto: 2, simMoneyBase: 100)
        context.insert(stock)
        for index in 0..<count {
            let close = 70 + Double(index) * 0.08 + Double((index * 17) % 23) / 10
            let trade = Trade(stock: stock, dateTime: date(index))
            trade.priceOpen = close - 0.4
            trade.priceHigh = close + 1.1
            trade.priceLow = close - 1.3
            trade.priceClose = close
            trade.volumeClose = 800 + Double((index * 37) % 500)
            trade.dataSource = "TWSE"
            context.insert(trade)
        }
        try context.save()
        return Fixture(container: container, context: context, stock: stock,
                       technical: Technical(modelContext: context))
    }

    private func reopen(_ url: URL) throws -> Fixture {
        let container = try makeContainer(url: url)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stock = try XCTUnwrap(Stock.fetchAll(in: context).first)
        return Fixture(container: container, context: context, stock: stock,
                       technical: Technical(modelContext: context))
    }

    private func rows(_ fixture: Fixture) throws -> [Trade] {
        try Trade.fetch(in: fixture.context, for: fixture.stock, ascending: true)
    }

    private func fullPlan() -> RecalculationPlan {
        RecalculationPlan(technical: .all, simulation: .all, resetDerivedSimulationState: true)
    }

    private func technicalSnapshot(_ trade: Trade) -> [Double?] {
        [trade.tMa20, trade.tMa60, trade.tKdK, trade.tKdD, trade.tOsc,
         trade.vMa20, trade.vMa60, trade.vZ125, trade.tOscZ125,
         Double(trade.tPricePathPhaseRaw), trade.tPricePathBarrier,
         trade.tPricePathAnchorClose, trade.tPricePathExtremeClose,
         Double(trade.tPricePathDaysSinceExtreme)]
    }

    private func simulationSnapshot(_ trade: Trade) -> SimulationSnapshot {
        // JSON key order is not a semantic difference in a persisted warning.
        let warning = trade.simAnnualWarningData.flatMap { data -> Data? in
            guard let object = try? JSONSerialization.jsonObject(with: data) else { return data }
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        return SimulationSnapshot(
            values: [trade.simAmtBalance, trade.simAmtCost, trade.simAmtProfit, trade.simAmtRoi,
                     trade.simQtyBuy, trade.simQtySell, trade.simQtyInventory, trade.simDays,
                     trade.rollAmtCost, trade.rollAmtProfit, trade.rollAmtRoi, trade.rollDays,
                     trade.rollRounds, trade.simInvestTimes, trade.simInvestByUser],
            optionalValues: [trade.simFitFast, trade.simFitSlow, trade.simFitTrend,
                             trade.simFitTrendPhaseExtreme],
            strings: [trade.simRule, trade.simRuleBuy, trade.simRuleInvest, trade.simReversed],
            flags: [trade.simUpdated, trade.simMoneyLackedCumulative],
            counts: [trade.simFitObservationCount, trade.simFitTrendPhaseRaw], warning: warning)
    }

    private func temporaryStore() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecalculationCoverage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("fixture.store")
    }

    func testDependencyUsesActualWritesAndIncludesPrecedingRowOnlyWhenConsumed() async {
        let dates = (0..<20).map(date)
        XCTAssertEqual(RecalculationCoverage.dependentSimulationStart(
            technicalDates: [date(12)], tradeDates: dates, simulationStart: date(10)), date(12))
        XCTAssertEqual(RecalculationCoverage.dependentSimulationStart(
            technicalDates: [date(9)], tradeDates: dates, simulationStart: date(10)), date(10))
        XCTAssertNil(RecalculationCoverage.dependentSimulationStart(
            technicalDates: [date(8)], tradeDates: dates, simulationStart: date(10)))
        XCTAssertNil(RecalculationCoverage.dependentSimulationStart(
            technicalDates: [], tradeDates: dates, simulationStart: date(10)),
            "Reading the same preceding history without writes does not invalidate S")
    }

    func testDirtyCompletionConsumesOnlyAContiguousPendingPrefix() async {
        let dates = (0..<8).map(date)
        XCTAssertEqual(RecalculationCoverage.remainingDirty(date(2),
            completed: [date(2), date(3), date(5)], requiredDates: dates), date(4))
        XCTAssertEqual(RecalculationCoverage.remainingDirty(date(2),
            completed: Array(dates[3...]), requiredDates: dates), date(2))
        XCTAssertNil(RecalculationCoverage.remainingDirty(date(2),
            completed: Array(dates[2...]), requiredDates: dates))
        XCTAssertEqual(RecalculationCoverage.remainingDirty(date(9),
            completed: dates, requiredDates: dates), date(9), "Future pending work is not completed")
    }

    func testNewTechnicalOnlyEntryReplaysSimulationEvenWhenTechnicalValuesAreIdentical() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        _ = try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let trades = try rows(fixture)
        let expectedTechnical = trades.map(technicalSnapshot)
        let expectedSimulation = trades.map(simulationSnapshot)
        // Poison S alone: the T request must repair it without an explicit S scope.
        trades[40].simAmtBalance = -123_456
        trades[40].simFitTrendPhaseRaw = 999
        let trace = try fixture.technical.recalculate(stock: fixture.stock,
            plan: RecalculationPlan(technical: .from(date(40)), simulation: .none))
        XCTAssertEqual(trace.technicalDates, (40..<60).map(date))
        XCTAssertEqual(trace.simulationDates, (40..<60).map(date))
        XCTAssertEqual(trades.map(technicalSnapshot), expectedTechnical)
        XCTAssertEqual(trades.map(simulationSnapshot), expectedSimulation)
        XCTAssertNil(fixture.stock.technicalDirtyFrom)
        XCTAssertNil(fixture.stock.simulationDirtyFrom)
    }

    func testPersistingTechnicalOnlyRequestAutomaticallyPersistsDependentSimulationWork() async throws {
        let url = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func saveRequest() throws {
            let fixture = try makeFixture(url: url)
            defer { withExtendedLifetime(fixture.container) {} }
            _ = try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
            try fixture.technical.persistDirtyState(for: fixture.stock,
                plan: RecalculationPlan(technical: .from(date(40)), simulation: .none))
        }
        try saveRequest()
        let fixture = try reopen(url)
        defer { withExtendedLifetime(fixture.container) {} }
        XCTAssertEqual(fixture.stock.technicalDirtyFrom, date(40))
        XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(40))
        _ = try await fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)
        XCTAssertEqual(fixture.technical.lastRecalculationTrace.technicalDates, (40..<60).map(date))
        XCTAssertEqual(fixture.technical.lastRecalculationTrace.simulationDates, (40..<60).map(date))
        XCTAssertNil(fixture.stock.technicalDirtyFrom)
        XCTAssertNil(fixture.stock.simulationDirtyFrom)
    }

    func testSavedSimulationEndRetainsNextDateAndResumesAfterReopening() async throws {
        let url = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let oracle = try makeFixture()
        defer { withExtendedLifetime(oracle.container) {} }
        _ = try oracle.technical.recalculate(stock: oracle.stock, plan: fullPlan())
        let expected = try rows(oracle).map(simulationSnapshot)
        func savePrefix() throws {
            let fixture = try makeFixture(url: url)
            defer { withExtendedLifetime(fixture.container) {} }
            let trace = try fixture.technical.recalculate(stock: fixture.stock,
                plan: RecalculationPlan(technical: .all, simulation: .all,
                                        resetDerivedSimulationState: true, simulationEnd: date(39)))
            XCTAssertEqual(trace.technicalDates, (0..<60).map(date))
            XCTAssertEqual(trace.simulationDates, (0...39).map(date))
            XCTAssertNil(fixture.stock.technicalDirtyFrom)
            XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(40))
            XCTAssertEqual(fixture.stock.technicalStateVersion, Int(Technical.technicalRuleVersion.dropFirst())!)
            XCTAssertEqual(fixture.stock.simulationStateVersion, 0, "A prefix cannot complete migration")
        }
        try savePrefix()
        let fixture = try reopen(url)
        defer { withExtendedLifetime(fixture.container) {} }
        XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(40))
        XCTAssertEqual(fixture.stock.simulationStateVersion, 0)
        _ = try await fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)
        XCTAssertTrue(fixture.technical.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertNil(fixture.stock.simulationDirtyFrom)
        XCTAssertEqual(fixture.stock.simulationStateVersion, Int(Technical.simulationRuleVersion.dropFirst())!)
        XCTAssertEqual(try rows(fixture).map(simulationSnapshot), expected)
    }

    func testFinalSaveFailureRetainsRegisteredPendingWorkAndOldVersions() async throws {
        let url = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func failAfterWork() throws {
            let fixture = try makeFixture(url: url)
            defer { withExtendedLifetime(fixture.container) {} }
            let context = fixture.context
            var saves = 0
            fixture.technical.recalculationSave = {
                saves += 1
                if saves == 2 { throw SaveFailure.injected }
                try context.save()
            }
            defer { fixture.technical.recalculationSave = nil }
            XCTAssertThrowsError(try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())) {
                XCTAssertTrue($0 is SaveFailure)
            }
            XCTAssertEqual(saves, 2)
            XCTAssertEqual(fixture.stock.technicalDirtyFrom, date(0))
            XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(0))
            XCTAssertEqual(fixture.stock.technicalStateVersion, 0)
            XCTAssertEqual(fixture.stock.simulationStateVersion, 0)
        }
        try failAfterWork()
        let fixture = try reopen(url)
        defer { withExtendedLifetime(fixture.container) {} }
        XCTAssertEqual(fixture.stock.technicalDirtyFrom, date(0))
        XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(0))
        XCTAssertEqual(fixture.stock.technicalStateVersion, 0)
        XCTAssertEqual(fixture.stock.simulationStateVersion, 0)
        _ = try await fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)
        XCTAssertEqual(fixture.technical.lastRecalculationTrace.technicalDates, (0..<60).map(date))
        XCTAssertEqual(fixture.technical.lastRecalculationTrace.simulationDates, (0..<60).map(date))
        XCTAssertNil(fixture.stock.technicalDirtyFrom)
        XCTAssertNil(fixture.stock.simulationDirtyFrom)
    }

    func testFinalSaveFailureRestoresManualIntentUntilSuccessfulRetry() async throws {
        let url = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        func verifySavedOriginalIntent() throws {
            let reopened = try reopen(url)
            defer { withExtendedLifetime(reopened.container) {} }
            let trade = try rows(reopened)[10]
            XCTAssertEqual(trade.simReversed, "S-")
            XCTAssertEqual(trade.simInvestByUser, 1)
            XCTAssertTrue(reopened.stock.simReversed)
            XCTAssertEqual(reopened.stock.simInvestUser, 1)
            XCTAssertNil(reopened.stock.technicalDirtyFrom)
            XCTAssertEqual(reopened.stock.simulationDirtyFrom, date(10))
        }

        func failThenRetryInSameProcess() throws {
            let fixture = try makeFixture(url: url)
            defer { withExtendedLifetime(fixture.container) {} }
            _ = try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
            let trades = try rows(fixture)
            let trade = trades[10]
            XCTAssertFalse(trade.isBeforeSimulationStart)
            XCTAssertEqual(trades[9].simQtyInventory, 0)
            trade.simReversed = "S-"
            trade.simInvestByUser = 1
            fixture.stock.rebuildUserActionSummary(from: trades)
            try fixture.context.save()

            let context = fixture.context
            let stock = fixture.stock
            var saves = 0
            fixture.technical.recalculationSave = {
                saves += 1
                if saves == 2 {
                    // Prove replay really removed both invalid actions before
                    // the failed commit, rather than leaving them untouched.
                    XCTAssertEqual(trade.simReversed, "")
                    XCTAssertEqual(trade.simInvestByUser, 0)
                    XCTAssertFalse(stock.simReversed)
                    XCTAssertEqual(stock.simInvestUser, 0)
                    throw SaveFailure.injected
                }
                try context.save()
            }
            defer { fixture.technical.recalculationSave = nil }
            let plan = RecalculationPlan(technical: .none, simulation: .from(date(10)))
            XCTAssertThrowsError(try fixture.technical.recalculate(stock: stock, plan: plan)) {
                XCTAssertTrue($0 is SaveFailure)
            }
            XCTAssertEqual(saves, 2)
            XCTAssertEqual(trade.simReversed, "S-")
            XCTAssertEqual(trade.simInvestByUser, 1)
            XCTAssertTrue(stock.simReversed)
            XCTAssertEqual(stock.simInvestUser, 1)
            XCTAssertNil(stock.technicalDirtyFrom)
            XCTAssertEqual(stock.simulationDirtyFrom, date(10))
            try verifySavedOriginalIntent()

            fixture.technical.recalculationSave = nil
            let trace = try fixture.technical.recalculate(stock: stock, plan: plan)
            XCTAssertTrue(trace.technicalDates.isEmpty)
            XCTAssertEqual(trace.simulationDates, (10..<60).map(date))
            XCTAssertEqual(trace.userActions.clearedInvalid, 2)
            XCTAssertEqual(trace.userActions.retained, 0)
            XCTAssertEqual(trade.simReversed, "")
            XCTAssertEqual(trade.simInvestByUser, 0)
            XCTAssertFalse(stock.simReversed)
            XCTAssertEqual(stock.simInvestUser, 0)
            XCTAssertNil(stock.simulationDirtyFrom)
        }

        try failThenRetryInSameProcess()
        let reopened = try reopen(url)
        defer { withExtendedLifetime(reopened.container) {} }
        let trade = try rows(reopened)[10]
        XCTAssertEqual(trade.simReversed, "")
        XCTAssertEqual(trade.simInvestByUser, 0)
        XCTAssertFalse(reopened.stock.simReversed)
        XCTAssertEqual(reopened.stock.simInvestUser, 0)
        XCTAssertNil(reopened.stock.simulationDirtyFrom)
    }

    func testCurrentVersionTruncatedReplayResumesOnlyItsUnfinishedSuffix() async throws {
        let url = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let oracle = try makeFixture()
        defer { withExtendedLifetime(oracle.container) {} }
        _ = try oracle.technical.recalculate(stock: oracle.stock, plan: fullPlan())
        let expected = try rows(oracle).map(simulationSnapshot)
        func savePrefix() throws {
            let fixture = try makeFixture(url: url)
            defer { withExtendedLifetime(fixture.container) {} }
            _ = try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
            let trades = try rows(fixture)
            trades[40].simAmtBalance = -123_456
            trades[40].simFitTrendPhaseRaw = 999
            let trace = try fixture.technical.recalculate(stock: fixture.stock,
                plan: RecalculationPlan(technical: .from(date(30)), simulation: .none,
                                        simulationEnd: date(39)))
            XCTAssertEqual(trace.technicalDates, (30..<60).map(date))
            XCTAssertEqual(trace.simulationDates, (30...39).map(date))
            XCTAssertNil(fixture.stock.technicalDirtyFrom)
            XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(40))
        }
        try savePrefix()
        let fixture = try reopen(url)
        defer { withExtendedLifetime(fixture.container) {} }
        XCTAssertEqual(fixture.stock.simulationStateVersion, Int(Technical.simulationRuleVersion.dropFirst())!)
        XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(40))
        _ = try await fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)
        XCTAssertTrue(fixture.technical.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertEqual(fixture.technical.lastRecalculationTrace.simulationDates, (40..<60).map(date))
        XCTAssertNil(fixture.stock.simulationDirtyFrom)
        XCTAssertEqual(try rows(fixture).map(simulationSnapshot), expected)
    }

    func testDeferredResearchSimulationStaysDirtyAfterTechnicalCompletionAndReopen() async throws {
        let url = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func saveTechnicalOnly() throws {
            let fixture = try makeFixture(url: url)
            defer { withExtendedLifetime(fixture.container) {} }
            let trace = try fixture.technical.recalculate(stock: fixture.stock,
                plan: RecalculationPlan(technical: .all, simulation: .none, deferSimulation: true))
            XCTAssertEqual(trace.technicalDates, (0..<60).map(date))
            XCTAssertTrue(trace.simulationDates.isEmpty)
            XCTAssertNil(fixture.stock.technicalDirtyFrom)
            XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(10))
            XCTAssertEqual(fixture.stock.technicalStateVersion, Int(Technical.technicalRuleVersion.dropFirst())!)
            XCTAssertEqual(fixture.stock.simulationStateVersion, 0)
        }
        try saveTechnicalOnly()
        let fixture = try reopen(url)
        defer { withExtendedLifetime(fixture.container) {} }
        XCTAssertNil(fixture.stock.technicalDirtyFrom)
        XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(10))
        XCTAssertTrue(fixture.technical.hasPendingDataRecalculation(in: [fixture.stock]))
        _ = try await fixture.technical.recoverOrMigrateRecalculationState(for: fixture.stock)
        XCTAssertTrue(fixture.technical.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertNil(fixture.stock.simulationDirtyFrom)
    }

    func testNoOpAndSimulationOnlyCannotClearUnprocessedTechnicalDirty() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        _ = try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let trades = try rows(fixture)
        let expectedTechnical = trades.map(technicalSnapshot)
        fixture.stock.technicalDirtyFrom = date(30)
        fixture.stock.simulationDirtyFrom = date(30)
        try fixture.context.save()
        let noOp = try fixture.technical.recalculate(stock: fixture.stock, plan: .none)
        XCTAssertTrue(noOp.technicalDates.isEmpty)
        XCTAssertTrue(noOp.simulationDates.isEmpty)
        XCTAssertEqual(fixture.stock.technicalDirtyFrom, date(30))
        XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(30))
        let simulationOnly = try fixture.technical.recalculate(stock: fixture.stock,
            plan: RecalculationPlan(technical: .none, simulation: .from(date(40))))
        XCTAssertTrue(simulationOnly.technicalDates.isEmpty)
        XCTAssertEqual(fixture.stock.technicalDirtyFrom, date(30))
        XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(30))
        XCTAssertEqual(trades.map(technicalSnapshot), expectedTechnical)
    }

    func testSaveResultsFalseDoesNotOptOutOfTechnicalToSimulationCoverage() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        _ = try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let trace = try fixture.technical.recalculate(stock: fixture.stock,
            plan: RecalculationPlan(technical: .from(date(40)), simulation: .none, saveResults: false))
        XCTAssertEqual(trace.technicalDates, (40..<60).map(date))
        XCTAssertEqual(trace.simulationDates, (40..<60).map(date))
        XCTAssertEqual(fixture.stock.technicalDirtyFrom, date(40), "Unsaved completion is not durable")
        XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(40))
    }

    func testMarketRebuildWithoutRawChangesInvalidatesSimulationButNotStockTechnical() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        for index in 0..<60 {
            let close = 10_000 + Double(index) * 3
            fixture.context.insert(MarketDay(dateTime: date(index), indexOpen: close,
                indexHigh: close + 20, indexLow: close - 20, indexClose: close))
        }
        let market = MarketDataStore(modelContext: fixture.context)
        try market.rebuildPricePath()
        fixture.technical.reloadMarketPricePathLookup()
        _ = try fixture.technical.recalculate(stock: fixture.stock, plan: fullPlan())
        let trades = try rows(fixture)
        let technicalBefore = trades.map(technicalSnapshot)
        let marketBefore = try MarketDay.fetchAll(in: fixture.context).map {
            [$0.indexHighMax9, $0.indexLowMin9, $0.kdK, $0.kdD, $0.kdJZ250,
             $0.indexHighDiff250, $0.indexHighDiffZ250, $0.oscZ125]
        }
        try market.rebuildPricePath()
        XCTAssertNil(fixture.stock.technicalDirtyFrom)
        XCTAssertEqual(fixture.stock.simulationDirtyFrom, date(10))
        XCTAssertEqual(trades.map(technicalSnapshot), technicalBefore)
        XCTAssertEqual(try MarketDay.fetchAll(in: fixture.context).map {
            [$0.indexHighMax9, $0.indexLowMin9, $0.kdK, $0.kdD, $0.kdJZ250,
             $0.indexHighDiff250, $0.indexHighDiffZ250, $0.oscZ125]
        }, marketBefore, "Equal market values still count as actual technical writes")
    }

    func testMarketWriteIncludesBorrowedSourceAbsentFromStockDates() async throws {
        let fixture = try makeFixture(count: 20)
        defer { withExtendedLifetime(fixture.container) {} }
        let borrowed = Stock(sId: "BORROWED", sName: "暫算", group: "測試",
                             dateFirst: date(0), dateStart: date(10))
        fixture.context.insert(borrowed)
        let live = Trade(stock: borrowed, dateTime: date(10))
        live.simMarketSourceDate = date(4)
        live.simMarketIsProvisional = true
        fixture.context.insert(live)
        fixture.stock.technicalDirtyFrom = date(2)
        try RecalculationInvalidation.marketTechnical(writes: [date(4)], in: fixture.context)
        XCTAssertEqual(borrowed.simulationDirtyFrom, date(10))
        XCTAssertNil(borrowed.technicalDirtyFrom)
        XCTAssertNil(fixture.stock.simulationDirtyFrom,
            "A much earlier market write with no effective-date dependency is unrelated")
        XCTAssertEqual(fixture.stock.technicalDirtyFrom, date(2))
    }
}
