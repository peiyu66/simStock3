import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class TradePresentationWindowTests: XCTestCase {
    private struct Fixture {
        let container: ModelContainer
        let stock: Stock
        let ui: uiObject
        var context: ModelContext { container.mainContext }
    }

    private func day(_ value: String) -> Date {
        twDateTime.startOfDay(twDateTime.dateFromString(value)!)
    }

    private func fixture(start: String = "2024/06/15", readOnly: Bool = false) throws -> Fixture {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let stock = Stock(sId: "VISIBLE", sName: "顯示窗口", group: "測試",
            dateFirst: day("2020/01/01"), dateStart: day(start), simMoneyBase: 100)
        // These UI-helper tests prepare completed state; replay validity itself
        // is covered by SimulationMarketDependencyTests, not bypassed here.
        stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
        stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
        container.mainContext.insert(stock)
        let ui = uiObject(modelContext: container.mainContext, isReadOnlySnapshot: readOnly)
        NotificationCenter.default.removeObserver(ui)
        return Fixture(container: container, stock: stock, ui: ui)
    }

    @discardableResult
    private func row(_ date: String, fixture: Fixture, close: Double = 100) -> Trade {
        let trade = Trade(stock: fixture.stock, dateTime: twDateTime.time1330(day(date)))
        trade.priceOpen = close; trade.priceHigh = close + 1; trade.priceLow = close - 1
        trade.priceClose = close; trade.volumeClose = 1_000; trade.dataSource = "TWSE"
        fixture.context.insert(trade)
        return trade
    }

    func testExactWindowCacheAndDateSelectionExcludeEarlierMonthRows() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let outside = row("2023/06/14", fixture: f)
        let first = row("2023/06/15", fixture: f)
        let later = row("2024/06/15", fixture: f)
        let invalid = row("2024/06/16", fixture: f, close: .infinity)
        try f.context.save()
        f.ui.storeOrderedTrades([outside, later, invalid, first], for: f.stock)
        XCTAssertEqual(f.ui.cachedOrderedTrades(for: f.stock)?.map(\.dateTime), [later.dateTime, first.dateTime])
        XCTAssertEqual(f.ui.latestVisibleTrade(for: f.stock)?.dateTime, later.dateTime)
        XCTAssertEqual(f.ui.resolvedTradeDate(for: outside.date, in: [outside, later, first], stock: f.stock), first.date)
        XCTAssertEqual(f.ui.resolvedTradeDate(for: day("2024/01/01"), in: [later, first], stock: f.stock), first.date)
        XCTAssertEqual(f.ui.resolvedTradeDate(for: nil, in: [first, later], stock: f.stock), later.date)
        XCTAssertNotNil(try Trade.fetch(in: f.context, for: f.stock).first { $0 === outside },
                        "The presentation window must not delete retained raw rows")
    }

    func testSettingChangeRejectsOldCacheAndResolvesSelectionInNewWindow() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let oldFirst = row("2023/06/15", fixture: f)
        let nextFirst = row("2023/07/15", fixture: f)
        let last = row("2024/07/15", fixture: f)
        let rows = [oldFirst, nextFirst, last]
        f.ui.storeOrderedTrades(rows, for: f.stock)
        let revision = f.ui.orderedTradeCacheRevision
        f.stock.dateStart = day("2024/07/15")
        XCTAssertNil(f.ui.cachedOrderedTrades(for: f.stock))
        XCTAssertGreaterThan(f.ui.orderedTradeCacheRevision, revision)
        XCTAssertEqual(f.ui.resolvedTradeDate(for: oldFirst.date, in: rows, stock: f.stock), nextFirst.date)
        f.ui.storeOrderedTrades(rows, for: f.stock)
        XCTAssertEqual(f.ui.cachedOrderedTrades(for: f.stock)?.map(\.dateTime), [last.dateTime, nextFirst.dateTime])
        f.stock.dateStart = day("2024/06/15")
        XCTAssertNil(f.ui.cachedOrderedTrades(for: f.stock), "Moving earlier must fetch newly visible retained rows")
        f.ui.storeOrderedTrades(rows, for: f.stock)
        XCTAssertEqual(f.ui.cachedOrderedTrades(for: f.stock)?.last?.dateTime, oldFirst.dateTime)
    }

    func testRawDateValidityAndInsertionInvalidatePresentationCache() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let outside = row("2023/06/14", fixture: f)
        let first = row("2023/06/15", fixture: f)
        let last = row("2024/06/15", fixture: f)
        try f.context.save()
        f.ui.storeOrderedTrades([outside, first, last], for: f.stock)
        outside.dateTime = twDateTime.time1330(day("2023/06/16"))
        XCTAssertNil(f.ui.cachedOrderedTrades(for: f.stock))
        f.ui.storeOrderedTrades([outside, first, last], for: f.stock)
        first.priceClose = 0
        XCTAssertNil(f.ui.cachedOrderedTrades(for: f.stock))
        f.ui.storeOrderedTrades([outside, first, last], for: f.stock)
        let inserted = row("2024/06/16", fixture: f)
        XCTAssertNil(f.ui.cachedOrderedTrades(for: f.stock))
        let reloaded = try Trade.fetchCalculationWindow(in: f.context, for: f.stock, ascending: false)
        f.ui.storeOrderedTrades(reloaded, for: f.stock)
        XCTAssertEqual(f.ui.cachedOrderedTrades(for: f.stock)?.first?.dateTime, inserted.dateTime)
        let revision = f.ui.orderedTradeCacheRevision
        XCTAssertEqual(f.ui.cachedOrderedTrades(for: f.stock)?.first?.dateTime, inserted.dateTime)
        XCTAssertEqual(f.ui.orderedTradeCacheRevision, revision,
                       "Unchanged pending membership must keep the refreshed cache usable")
    }

    func testInsertSavedBeforeNextCacheReadStillInvalidatesOldRows() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let first = row("2023/06/15", fixture: f)
        let last = row("2024/06/15", fixture: f)
        try f.context.save()
        f.ui.storeOrderedTrades([last, first], for: f.stock)
        let inserted = row("2024/06/16", fixture: f)
        try f.context.save()
        XCTAssertTrue(f.context.insertedModelsArray.isEmpty)
        XCTAssertNil(f.ui.cachedOrderedTrades(for: f.stock),
                     "Clearing the context's pending insert set must not revive stale cached rows")
        f.ui.storeOrderedTrades(try Trade.fetchCalculationWindow(in: f.context, for: f.stock), for: f.stock)
        XCTAssertEqual(f.ui.cachedOrderedTrades(for: f.stock)?.first?.dateTime, inserted.dateTime)
    }

    func testDeletedRowCannotSurviveCacheBeforeOrAfterSave() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let first = row("2023/06/15", fixture: f)
        let last = row("2024/06/15", fixture: f)
        try f.context.save()
        f.ui.storeOrderedTrades([last, first], for: f.stock)
        f.context.delete(last)
        XCTAssertNil(f.ui.cachedOrderedTrades(for: f.stock))
        f.ui.storeOrderedTrades([first], for: f.stock)
        try f.context.save()
        XCTAssertNil(f.ui.cachedOrderedTrades(for: f.stock))
        f.ui.storeOrderedTrades(try Trade.fetchCalculationWindow(in: f.context, for: f.stock), for: f.stock)
        XCTAssertEqual(f.ui.cachedOrderedTrades(for: f.stock)?.map(\.dateTime), [first.dateTime])
    }

    func testFiniteDirtyBlocksAffectedDaysWithoutBlockingValidEarlierDates() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        _ = row("2023/06/15", fixture: f)
        let completed = row("2024/06/15", fixture: f)
        let pending = row("2024/06/16", fixture: f)
        f.stock.simulationDirtyFrom = pending.dateTime
        XCTAssertFalse(completed.simUpdated, "This legacy flag must not become a new validity gate")
        XCTAssertFalse(f.stock.requiresHistoryRebuild, "This case is a finite boundary, not a full rebuild")
        XCTAssertTrue(f.ui.hasPendingResults(for: f.stock))
        XCTAssertEqual(f.ui.pendingResultsMessage(for: f.stock), "模擬待算")
        XCTAssertFalse(f.ui.isTradeResultPending(completed))
        XCTAssertTrue(f.ui.canEditTrade(completed))
        XCTAssertTrue(f.ui.isTradeResultPending(pending))
        XCTAssertFalse(f.ui.isTradeTechnicalResultPending(pending))
        XCTAssertFalse(f.ui.canEditTrade(pending))
        XCTAssertFalse(f.ui.canShowIntradaySuggestions(for: pending))
        f.stock.simulationDirtyFrom = nil
        f.stock.technicalDirtyFrom = pending.dateTime
        XCTAssertTrue(f.ui.isTradeTechnicalResultPending(pending))
        XCTAssertEqual(f.ui.pendingResultsMessage(for: f.stock), "模擬待算")
        XCTAssertFalse(f.ui.canEditTrade(pending))
        XCTAssertTrue(f.ui.canEditTrade(completed))
        f.stock.technicalDirtyFrom = nil
        XCTAssertNil(f.ui.pendingResultsMessage(for: f.stock))
        XCTAssertTrue(f.ui.canEditTrade(pending))
        XCTAssertFalse(f.ui.canShowIntradaySuggestions(for: pending), "A historical formal result is editable but is not an intraday scenario")
    }

    func testVersionMigrationUsesSharedVersionGateRegardlessOfCompletedFlags() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        _ = row("2023/06/15", fixture: f)
        let last = row("2024/06/15", fixture: f)
        last.tUpdated = true; last.simUpdated = true
        f.stock.technicalStateVersion -= 1
        XCTAssertTrue(f.ui.isTradeResultPending(last))
        XCTAssertFalse(f.ui.canEditTrade(last))
        f.stock.technicalStateVersion += 1
        f.stock.simulationStateVersion -= 1
        XCTAssertTrue(f.ui.isTradeResultPending(last))
        XCTAssertFalse(f.ui.canEditTrade(last))
    }

    func testNoUsableVisiblePriceDoesNotClaimTechnicalWasCalculated() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let outside = row("2023/06/14", fixture: f)
        let invalid = row("2024/06/15", fixture: f, close: 0)
        StockHistory.invalidate(f.stock)
        XCTAssertNil(f.stock.calculationWindow.firstPriceDate)
        XCTAssertNil(f.ui.latestVisibleTrade(for: f.stock))
        XCTAssertEqual(f.ui.pendingResultsMessage(for: f.stock),
                       "尚無股價")
        XCTAssertFalse(f.ui.canEditTrade(outside))
        XCTAssertFalse(f.ui.canEditTrade(invalid))
        let trace = try f.ui.sim.tech.recalculate(stock: f.stock, plan: .init(technical: .all, simulation: .all))
        XCTAssertTrue(trace.technicalDates.isEmpty); XCTAssertTrue(trace.simulationDates.isEmpty)
        XCTAssertNotNil(f.stock.technicalDirtyFrom); XCTAssertNotNil(f.stock.simulationDirtyFrom)
    }

    func testLessThanOneYearKeepsTechnicalRowsReadableButCannotEditSimulation() async throws {
        let f = try fixture(start: "2024/01/01")
        defer { withExtendedLifetime(f.container) {} }
        let first = row("2024/01/02", fixture: f)
        let latest = row("2024/07/02", fixture: f)
        f.stock.simulationDirtyFrom = latest.dateTime
        f.ui.storeOrderedTrades([first, latest], for: f.stock)
        XCTAssertFalse(f.stock.calculationWindow.hasSimulationDates)
        XCTAssertEqual(f.ui.cachedOrderedTrades(for: f.stock)?.count, 2)
        XCTAssertFalse(f.ui.canEditTrade(first))
        XCTAssertFalse(f.ui.canEditTrade(latest))
        XCTAssertEqual(f.ui.pendingResultsMessage(for: f.stock), "尚無模擬日期")
    }

    func testDirectManualEntryCannotMutatePendingOrOutsideRows() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let outside = row("2023/06/14", fixture: f)
        let first = row("2023/06/15", fixture: f)
        let pending = row("2024/06/15", fixture: f)
        pending.simReversed = "B+"; pending.simInvestByUser = 1
        outside.simReversed = "S+"; outside.simInvestByUser = -1
        f.stock.simulationDirtyFrom = pending.dateTime
        let before = [outside, first, pending].map { ($0.simReversed, $0.simInvestByUser) }
        for trade in [outside, first, pending] {
            f.ui.addInvestLocal(trade)
            f.ui.setReversedLocal(trade)
        }
        for (index, trade) in [outside, first, pending].enumerated() {
            XCTAssertEqual(trade.simReversed, before[index].0)
            XCTAssertEqual(trade.simInvestByUser, before[index].1)
        }
        XCTAssertFalse(f.ui.isChangingSimulation)
        XCTAssertFalse(f.ui.sim.tech.isRequestActive)
    }

    func testIncompleteStatusIsNotPresentedAsSuccessfulCompletion() {
        for message in ["已依現有資料計算技術值；大盤資料缺席，模擬待補", "近期尚待補", "模擬待計算"] {
            XCTAssertTrue(PriceUpdateStatusBar.indicatesIncompleteResult(message))
        }
        XCTAssertFalse(PriceUpdateStatusBar.indicatesIncompleteResult("示意資料已完成必要重算"))
        XCTAssertEqual(PriceUpdateStatusBar(isUpdating: false,
            message: "本盤段已查詢完成；最新正式行情10/22", hasIncompleteWork: false).statusSymbol,
            "checkmark.circle")
        XCTAssertEqual(PriceUpdateStatusBar(isUpdating: false,
            message: "個股下載完成；大盤查詢失敗", hasIncompleteWork: true).statusSymbol,
            "exclamationmark.triangle")
        XCTAssertEqual(PriceUpdateStatusBar(isUpdating: false,
            message: "交易日曆確認失敗", calendarConfirmation: .failed, hasIncompleteWork: false).statusSymbol,
            "exclamationmark.triangle")
        XCTAssertEqual(PriceUpdateStatusBar(isUpdating: false,
            message: "交易日曆確認中", calendarConfirmation: .pending, hasIncompleteWork: false).statusSymbol,
            "clock")
    }

    func testSharedSignalGateRejectsSameDayDirtyButRetainsRawAndStoredIntent() throws {
        let f = try fixture()
        _ = row("2023/06/15", fixture: f)
        let prior = row("2024/06/15", fixture: f)
        let t = row("2024/06/16", fixture: f)
        t.rollRounds = 4; t.rollDays = 200; t.rollAmtRoi = 20.5
        t.simQtyBuy = 99; t.simReversed = "B+"; t.simInvestByUser = 1
        t.tUpdated = true; t.simUpdated = true
        let warning = TrueAnnualReturnWarning.Snapshot(status: .caution, priorAnnual: -2,
            recoveryFloor: -1, priceRecovered: false, recentReturnRecovered: false, gradeSeekingPeak: false)
        AnnualWarningPersistence.write(warning, continuationFloor: nil, continuationPriceHigh: nil,
            locallyReleased: false, to: t)
        XCTAssertTrue(t.storedAnnualWarning.isWarning)
        let saved = t.simAnnualWarningData
        f.stock.simulationDirtyFrom = t.dateTime.addingTimeInterval(3600)
        XCTAssertTrue(t.simulationResultPending)
        XCTAssertTrue(t.explanationSimulationPending)
        XCTAssertTrue(f.ui.isTradeResultPending(t))
        XCTAssertFalse(t.technicalResultPending)
        XCTAssertFalse(prior.simulationResultPending)
        XCTAssertFalse(t.storedAnnualWarning.isWarning)
        XCTAssertTrue(t.gradeExplanation.values.isEmpty)
        XCTAssertEqual(t.priceClose, 100); XCTAssertEqual(t.simQtyBuy, 99)
        XCTAssertEqual(t.simReversed, "B+"); XCTAssertEqual(t.simInvestByUser, 1)
        XCTAssertEqual(t.simAnnualWarningData, saved, "Presentation must not delete obsolete stored evidence")
        f.stock.simulationDirtyFrom = nil
        XCTAssertFalse(t.simulationResultPending)
        XCTAssertTrue(t.storedAnnualWarning.isWarning)
        XCTAssertFalse(t.gradeExplanation.values.isEmpty)
    }

    func testReadOnlyAndBusyStateKeepBrowsingButDisableWrites() async throws {
        let f = try fixture(readOnly: true)
        defer { withExtendedLifetime(f.container) {} }
        _ = row("2023/06/15", fixture: f)
        let latest = row("2024/06/15", fixture: f)
        XCTAssertFalse(f.ui.canEditTrade(latest))
        XCTAssertEqual(f.ui.resolvedTradeDate(for: nil, in: [latest], stock: f.stock), latest.date)
        let writable = uiObject(modelContext: f.context)
        NotificationCenter.default.removeObserver(writable)
        XCTAssertTrue(writable.canEditTrade(latest))
        writable.isUpdatingPrices = true
        XCTAssertFalse(writable.canEditTrade(latest))
        writable.addInvestLocal(latest)
        writable.setReversedLocal(latest)
        XCTAssertEqual(latest.simInvestByUser, 0)
        XCTAssertEqual(latest.simReversed, "")
    }

    func testPendingSimulationIsNotPublishedAsCompleteGroupPerformance() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        _ = row("2023/06/15", fixture: f)
        let last = row("2024/06/15", fixture: f)
        last.rollAmtRoi = 90
        f.stock.simulationDirtyFrom = last.dateTime
        XCTAssertEqual(f.ui.stocksSummary([f.stock]), "部分模擬結果尚待補齊或計算")
        XCTAssertEqual(f.ui.stocksSummaryLocal([f.stock]).count, 0)
        XCTAssertEqual(f.ui.stocksSummaryLocal([f.stock]).roi, 0)
    }
}
