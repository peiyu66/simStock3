import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class StockHistoryTests: XCTestCase {
    private func date(_ value: String) -> Date { twDateTime.dateFromString(value)! }

    private func fixture() throws -> (ModelContainer, Stock, [Trade]) {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let stock = Stock(sId: "TEST", sName: "測試", group: "A",
                          dateFirst: date("2020/01/01"), dateStart: date("2024/07/15"))
        container.mainContext.insert(stock)
        let rows = ["2020/01/01", "2023/06/30", "2023/07/01", "2024/07/14", "2024/07/15", "2025/01/01"].map { value in
            let trade = Trade(stock: stock, dateTime: twDateTime.time1330(date(value)))
            trade.priceClose = 100
            container.mainContext.insert(trade)
            return trade
        }
        stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
        stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
        try container.mainContext.save()
        return (container, stock, rows)
    }

    func testCleanupStartsHistoryUpdateAfterDismissalWithoutAnotherConfirmation() async throws {
        let (container, stock, rows) = try fixture()
        rows[5].simInvestByUser = 1
        try container.mainContext.save()
        let ui = uiObject(modelContext: container.mainContext)
        NotificationCenter.default.removeObserver(ui)
        ui.previewsHistorySettings = true // No networking after cleanup.
        ui.historyCleanupWillPresent()
        try ui.requestHistoryCleanup(StockHistory.candidates(in: container.mainContext))
        XCTAssertEqual(try Trade.fetch(in: container.mainContext, for: stock).count, 6)
        XCTAssertFalse(stock.requiresHistoryRebuild)
        // Returning from the deletion alert can foreground the app while the
        // cleanup sheet is still visible. Start only after it has closed.
        ui.startDailyPriceUpdate(stocks: [stock], ensureFollowUpIfBusy: true)
        XCTAssertNil(ui.simulationMigrationAlert)
        XCTAssertFalse(ui.isUpdatingPrices)
        ui.historyCleanupDidDismiss()
        XCTAssertTrue(ui.isChangingSimulation)
        XCTAssertTrue(ui.simulationStatusMessage.contains("正在清理"))
        XCTAssertEqual(try Trade.fetch(in: container.mainContext, for: stock).count, 6)
        await ui.historyCleanupTask?.value
        XCTAssertEqual(try Trade.fetch(in: container.mainContext, for: stock).count, 4)
        XCTAssertTrue(stock.requiresHistoryRebuild)
        XCTAssertNil(ui.simulationMigrationAlert)
        XCTAssertTrue(ui.isUpdatingPrices)
        XCTAssertFalse(ui.isMigratingSimulationData)
        XCTAssertTrue(ui.priceUpdateMessage.contains("已清除 1 檔、2 筆歷史資料"))
        XCTAssertTrue(ui.priceUpdateMessage.contains("檢查及補齊歷史股價"))
        XCTAssertEqual(try Trade.fetch(in: container.mainContext, for: stock, ascending: true).last?.simInvestByUser, 1)
    }

    func testSingleStockCleanupOmitsCounter() async throws {
        let (container, _, _) = try fixture()
        var messages: [String] = []
        _ = try await StockHistory.clean(StockHistory.candidates(in: container.mainContext),
            in: container.mainContext) { messages.append($0) }
        XCTAssertTrue(messages.contains { $0.hasPrefix("TEST 測試 正在清理") })
        XCTAssertFalse(messages.contains { $0.contains("1/1") })
    }

    func testPendingHistoryRejectsManualWritesWithoutLockingReadOnlyNavigation() async throws {
        let (container, stock, rows) = try fixture()
        let ui = uiObject(modelContext: container.mainContext)
        NotificationCenter.default.removeObserver(ui)
        StockHistory.invalidate(stock)
        let trade = rows[5]
        XCTAssertFalse(ui.isTradeOperationLocked)
        ui.addInvest(trade)
        ui.setReversed(trade)
        XCTAssertEqual(trade.simInvestByUser, 0)
        XCTAssertEqual(trade.simReversed, "")
        XCTAssertFalse(ui.isChangingSimulation)
    }

    func testRebuildBoundarySurvivesReopeningStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.store")
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        func writeStore() throws {
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, url: url))
            let stock = Stock(sId: "REOPEN", sName: "重開", group: "A",
                dateFirst: date("2020/01/01"), dateStart: date("2024/01/01"))
            container.mainContext.insert(stock)
            StockHistory.invalidate(stock)
            try container.mainContext.save()
        }
        try writeStore()
        let reopened = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, url: url))
        let stock = try XCTUnwrap(Stock.fetch(in: reopened.mainContext).first)
        XCTAssertTrue(stock.requiresHistoryRebuild)
        XCTAssertEqual(stock.technicalDirtyFrom, Date.distantPast)
        XCTAssertEqual(stock.simulationDirtyFrom, Date.distantPast)
    }

    func testCleanupKeepsWholePreparationMonthAndCurrentManualActions() async throws {
        let (container, stock, rows) = try fixture()
        rows[0].simReversed = "S+"
        rows[5].simInvestByUser = 1
        try container.mainContext.save()
        let selection = try StockHistory.candidates(in: container.mainContext)
        XCTAssertEqual(selection.count, 1)
        XCTAssertEqual(selection[0].count, 2)
        XCTAssertEqual(selection[0].userActions, 1)
        let result = try await StockHistory.clean(selection, in: container.mainContext)
        XCTAssertEqual(result.rows, 2)
        let retained = try Trade.fetch(in: container.mainContext, for: stock, ascending: true)
        XCTAssertEqual(retained.count, 4)
        XCTAssertEqual(retained[0].date, date("2023/07/01"))
        XCTAssertEqual(retained.last?.simInvestByUser, 1)
        XCTAssertEqual(stock.simInvestUser, 1)
        XCTAssertTrue(stock.requiresHistoryRebuild)
        XCTAssertTrue(try StockHistory.candidates(in: container.mainContext).isEmpty)
    }

    func testUngroupedCleanupKeepsCatalogAndDoesNotDeleteOtherStocksOrMarket() async throws {
        let (container, stock, _) = try fixture()
        let context = container.mainContext
        stock.group = ""
        let other = Stock(sId: "KEEP", sName: "保留", group: "A",
                          dateFirst: date("2020/01/01"), dateStart: date("2024/07/15"))
        context.insert(other)
        context.insert(Trade(stock: other, dateTime: date("2020/01/01")))
        context.insert(MarketDay(dateTime: date("2020/01/01"), indexOpen: 100, indexHigh: 101,
                                indexLow: 99, indexClose: 100))
        try context.save()
        let selection = try StockHistory.candidates(in: context).filter { $0.id == stock.sId }
        let result = try await StockHistory.clean(selection, in: context)
        XCTAssertEqual(result.rows, 6)
        XCTAssertTrue(result.rebuildStocks.isEmpty)
        XCTAssertEqual(try Stock.fetch(in: context).count, 2)
        XCTAssertEqual(try Trade.fetch(in: context, for: other).count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MarketDay>()), 1)
        XCTAssertTrue(try Trade.fetch(in: context, for: stock).isEmpty)
    }

    func testLegacyGroupEntryUsesTheSameLifecycle() async throws {
        let (container, stock, rows) = try fixture()
        rows[5].simInvestByUser = 1
        let sim = simObject(modelContext: container.mainContext)
        sim.moveStocksToGroup([stock], group: "", downloadNewStocks: false)
        XCTAssertEqual(stock.group, "")
        XCTAssertEqual(rows[5].simInvestByUser, 0)
        XCTAssertTrue(stock.requiresHistoryRebuild)
        sim.moveStocksToGroup([stock], group: "再加入", downloadNewStocks: false)
        XCTAssertEqual(stock.dateStart, defaults.start)
        XCTAssertEqual(stock.simMoneyBase, defaults.money)
        XCTAssertEqual(stock.group, "再加入")
    }

    func testChangedSelectionFailsBeforeDeletingAnyRows() async throws {
        let (container, stock, _) = try fixture()
        let selection = try StockHistory.candidates(in: container.mainContext)
        stock.group = ""
        try container.mainContext.save()
        do {
            _ = try await StockHistory.clean(selection, in: container.mainContext)
            XCTFail("Changed selection must fail before deletion")
        } catch { XCTAssertTrue(error is StockHistory.CleanupError) }
        XCTAssertEqual(try Trade.fetch(in: container.mainContext, for: stock).count, 6)
        let empty = try await StockHistory.clean([], in: container.mainContext)
        XCTAssertEqual(empty.rows, 0)
    }

    func testForwardThenBackwardStartDoesNotRestoreExitedActions() async throws {
        let (container, stock, rows) = try fixture()
        rows[4].simReversed = "S+"
        rows[5].simInvestByUser = 1
        try StockHistory.changeStart(stock, to: date("2024/12/01"), in: container.mainContext)
        XCTAssertEqual(rows[4].simReversed, "")
        XCTAssertEqual(rows[5].simInvestByUser, 1)
        try StockHistory.changeStart(stock, to: date("2024/01/01"), in: container.mainContext)
        XCTAssertEqual(rows[4].simReversed, "")
        XCTAssertEqual(rows[5].simInvestByUser, 1)
        XCTAssertTrue(stock.requiresHistoryRebuild)
        XCTAssertTrue(rows.allSatisfy { $0.priceClose == 100 })
    }

    func testGroupMovePreservesButRemoveAndRejoinClearActionsAndApplyDefaults() async throws {
        let (container, stock, rows) = try fixture()
        rows[5].simInvestByUser = 1
        rows[4].simReversed = "S+"
        stock.simMoneyBase = 400
        try StockHistory.changeGroup(stock, to: "B", start: date("2025/01/01"), money: 600,
                                     investments: 2, in: container.mainContext)
        XCTAssertEqual(rows[5].simInvestByUser, 1)
        XCTAssertEqual(stock.simMoneyBase, 400)
        XCTAssertFalse(stock.requiresHistoryRebuild)
        try StockHistory.changeGroup(stock, to: "", start: date("2025/01/01"), money: 600,
                                     investments: 2, in: container.mainContext)
        XCTAssertTrue(rows.allSatisfy { $0.simInvestByUser == 0 && $0.simReversed.isEmpty })
        // Legacy ungrouped records may still carry old actions.
        rows[5].simInvestByUser = 1
        try StockHistory.changeGroup(stock, to: "C", start: date("2025/01/01"), money: 600,
                                     investments: 2, in: container.mainContext)
        XCTAssertEqual(stock.dateStart, date("2025/01/01"))
        XCTAssertEqual(stock.simMoneyBase, 600)
        XCTAssertEqual(rows[5].simInvestByUser, 0)
        XCTAssertTrue(stock.requiresHistoryRebuild)
        XCTAssertTrue(rows.allSatisfy { $0.priceClose == 100 })
    }
}
