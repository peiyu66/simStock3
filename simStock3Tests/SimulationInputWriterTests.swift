import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class SimulationInputWriterTests: XCTestCase {
    private enum Failure: Error { case save }
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let stock: Stock
        let trades: [Trade]
        let simulation: simObject
        let ui: uiObject
    }

    private func date(_ index: Int) -> Date {
        let first = twDateTime.dateFromString("2024/01/02")!
        let days = index < 10 ? index * 366 / 10 : 366 + index - 10
        return twDateTime.time1330(twDateTime.calendar.date(byAdding: .day, value: days, to: first)!)
    }

    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let configuration = url.map {
            ModelConfiguration(schema: schema, url: $0, allowsSave: true, cloudKitDatabase: .none)
        } ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func fixture(url: URL? = nil) throws -> Fixture {
        let container = try container(url: url)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try RecalculationMarketFixture.seed(dates: (0..<30).map(date), in: context)
        let stock = Stock(sId: "SINPUT", sName: "輸入保存", group: "測試",
            dateFirst: date(0), dateStart: date(10), simInvestAuto: 2, simMoneyBase: 100)
        context.insert(stock)
        let trades = (0..<30).map { index in
            let trade = Trade(stock: stock, dateTime: date(index))
            let close = 100 + Double(index) * 0.2
            trade.priceOpen = close; trade.priceHigh = close + 1; trade.priceLow = close - 1
            trade.priceClose = close; trade.volumeClose = 1_000; trade.dataSource = "TWSE"
            context.insert(trade)
            return trade
        }
        try context.save()
        let simulation = simObject(modelContext: context)
        let trace = try simulation.tech.recalculate(stock: stock,
            plan: .init(technical: .all, simulation: .all, resetDerivedSimulationState: true))
        XCTAssertEqual(trace.simulationDates, (10..<30).map(date))
        XCTAssertNil(stock.technicalDirtyFrom); XCTAssertNil(stock.simulationDirtyFrom)
        let ui = uiObject(modelContext: context, priceCheckSimulation: simulation)
        NotificationCenter.default.removeObserver(ui)
        // Tests intercept only dispatch after the real writer commits. All T,
        // S, maturity and market dependencies above use the production pipeline.
        simulation.tech.requiredDataRuleMigrationRequest = { _ in }
        return Fixture(container: container, context: context, stock: stock, trades: trades,
                       simulation: simulation, ui: ui)
    }

    private func storeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulationInputWriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("test.store")
    }

    func testManualInvestmentPersistsEarlierDirtyBeforeDispatchAndColdRecovery() async throws {
        let url = try storeURL()
        let f = try fixture(url: url)
        defer { withExtendedLifetime(f.container) {} }
        f.stock.simulationDirtyFrom = date(25)
        f.trades[15].simInvestAdded = 0
        try f.context.save()
        var requests = 0
        f.simulation.tech.requiredDataRuleMigrationRequest = { stocks in
            requests += 1
            XCTAssertEqual(stocks.map(\.sId), [f.stock.sId])
            XCTAssertFalse(f.context.hasChanges, "Inputs and invalidation must already be committed")
            XCTAssertEqual(f.stock.simulationDirtyFrom, self.date(15))
        }
        f.ui.addInvest(f.trades[15])
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(f.trades[15].simInvestByUser, 1)
        XCTAssertEqual(f.stock.simInvestUser, 1)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertFalse(f.ui.isTradeTechnicalResultPending(f.trades[15]))
        XCTAssertTrue(f.ui.isTradeResultPending(f.trades[15]))
        XCTAssertFalse(f.ui.isTradeOperationLocked)

        let coldContainer = try container(url: url)
        defer { withExtendedLifetime(coldContainer) {} }
        let cold = ModelContext(coldContainer)
        cold.autosaveEnabled = false
        let stock = try XCTUnwrap(Stock.fetchAll(in: cold).first)
        let rows = try Trade.fetchCalculationWindow(in: cold, for: stock)
        XCTAssertEqual(rows[15].simInvestByUser, 1)
        XCTAssertEqual(stock.simulationDirtyFrom, date(15))
        let technical = Technical(modelContext: cold)
        _ = try await technical.recoverOrMigrateRecalculationState(for: stock)
        XCTAssertEqual(technical.lastRecalculationTrace.simulationDates, (15..<30).map(date))
        XCTAssertTrue(technical.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertNil(stock.simulationDirtyFrom)
    }

    func testLegacyReversalUsesSameAtomicWriterAndClearsConflictingInvestment() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        f.stock.simulationDirtyFrom = date(25)
        f.trades[15].simInvestByUser = 1
        f.stock.rebuildUserActionSummary(from: f.trades)
        try f.context.save()
        var requests = 0
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in
            requests += 1
            XCTAssertFalse(f.context.hasChanges)
            XCTAssertEqual(f.stock.simulationDirtyFrom, self.date(15))
            XCTAssertFalse(f.trades[15].simReversed.isEmpty)
            XCTAssertEqual(f.trades[15].simInvestByUser, 0)
        }
        f.simulation.setReversed(f.trades[15])
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(f.stock.simInvestUser, 0)
        XCTAssertTrue(f.stock.simReversed)
        XCTAssertNil(f.stock.technicalDirtyFrom)
    }

    func testCapitalAndAutomaticInvestmentChangesPersistSOnlyBeforeDispatch() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let technicalValues = f.trades.map { [$0.tMa20, $0.tKdK, $0.tKdD] }
        var saves = 0
        f.simulation.simulationInputs.save = { saves += 1; try f.context.save() }
        var requests = 0
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in
            requests += 1
            XCTAssertFalse(f.context.hasChanges)
            XCTAssertEqual(f.stock.simulationDirtyFrom, .distantPast)
            XCTAssertNil(f.stock.technicalDirtyFrom)
        }
        f.ui.settingStocks([f.stock], dateStart: f.stock.dateStart, moneyBase: 120, autoInvest: 3)
        XCTAssertEqual(saves, 1); XCTAssertEqual(requests, 1)
        XCTAssertEqual(f.stock.simMoneyBase, 120); XCTAssertEqual(f.stock.simInvestAuto, 3)
        XCTAssertEqual(f.trades.map { [$0.tMa20, $0.tKdK, $0.tKdD] }, technicalValues)
        _ = try await f.simulation.tech.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertTrue(f.simulation.tech.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertEqual(f.simulation.tech.lastRecalculationTrace.simulationDates, (10..<30).map(date))
        XCTAssertNil(f.stock.simulationDirtyFrom)
        f.simulation.settingStocks([f.stock], dateStart: f.stock.dateStart, moneyBase: 130, autoInvest: 4)
        XCTAssertEqual(saves, 2); XCTAssertEqual(requests, 2)
        XCTAssertEqual(f.stock.simMoneyBase, 130); XCTAssertEqual(f.stock.simInvestAuto, 4)
        XCTAssertNil(f.stock.technicalDirtyFrom)
    }

    func testIdenticalSettingsInBothEntryPointsDoNotSaveOrRequestReplay() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        var saves = 0
        var requests = 0
        f.simulation.simulationInputs.save = { saves += 1; try f.context.save() }
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in requests += 1 }
        let midnight = twDateTime.startOfDay(f.stock.dateStart)
        f.ui.settingStocks([f.stock], dateStart: midnight, moneyBase: 100, autoInvest: 2)
        f.simulation.settingStocks([f.stock], dateStart: midnight, moneyBase: 100, autoInvest: 2)
        XCTAssertEqual(saves, 0); XCTAssertEqual(requests, 0)
        XCTAssertNil(f.stock.technicalDirtyFrom); XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertEqual(f.stock.dateStart, date(10), "Same-day settings must not rewrite the configured timestamp")
        XCTAssertEqual(f.ui.simulationStatusMessage, "模擬設定未變更")
    }

    func testManualSaveFailureDoesNotDispatchAndKeepsInputPairedWithDirty() async throws {
        let url = try storeURL()
        let f = try fixture(url: url)
        defer { withExtendedLifetime(f.container) {} }
        f.trades[15].simInvestAdded = 0
        try f.context.save()
        var requests = 0
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in requests += 1 }
        f.simulation.simulationInputs.save = { throw Failure.save }
        f.ui.addInvest(f.trades[15])
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(f.trades[15].simInvestByUser, 1)
        XCTAssertEqual(f.stock.simulationDirtyFrom, date(15))
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertTrue(f.ui.simulationStatusMessage.contains("保存失敗"))
        XCTAssertFalse(f.ui.isTradeOperationLocked)
        XCTAssertFalse(f.ui.canEditTrade(f.trades[15]))

        let coldContainer = try container(url: url)
        defer { withExtendedLifetime(coldContainer) {} }
        let cold = ModelContext(coldContainer)
        cold.autosaveEnabled = false
        let stock = try XCTUnwrap(Stock.fetchAll(in: cold).first)
        let rows = try Trade.fetchCalculationWindow(in: cold, for: stock)
        XCTAssertEqual(rows[15].simInvestByUser, 0)
        XCTAssertNil(stock.simulationDirtyFrom, "A failed transaction must not partially persist the intent")

        // A later successful save retains the necessary replay, never new input
        // with a clean S boundary. No second toggle is needed to recover.
        f.simulation.simulationInputs.save = nil
        try f.context.save()
        _ = try await f.simulation.tech.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertEqual(f.simulation.tech.lastRecalculationTrace.simulationDates, (15..<30).map(date))
        XCTAssertTrue(f.simulation.tech.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertNil(f.stock.simulationDirtyFrom)
    }

    func testLegacySettingSaveFailureDoesNotDispatchOrLeaveCleanChangedInputs() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        var requests = 0
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in requests += 1 }
        f.simulation.simulationInputs.save = { throw Failure.save }
        f.simulation.settingStocks([f.stock], dateStart: f.stock.dateStart, moneyBase: 120, autoInvest: 3)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(f.stock.simMoneyBase, 120); XCTAssertEqual(f.stock.simInvestAuto, 3)
        XCTAssertEqual(f.stock.simulationDirtyFrom, .distantPast)
        XCTAssertNil(f.stock.technicalDirtyFrom)
    }

    func testExplicitReloadSurvivesExistingDirtyAndDoesNotRequireInputChange() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        f.stock.simulationDirtyFrom = date(25)
        try f.context.save()
        var requests = 0
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in
            requests += 1
            XCTAssertFalse(f.context.hasChanges)
            XCTAssertEqual(f.stock.simulationDirtyFrom, .distantPast)
        }
        XCTAssertTrue(f.ui.reloadNow([f.stock], action: .simUpdateAll))
        XCTAssertEqual(requests, 1)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertEqual(f.stock.simInvestAuto, 2)
        f.simulation.reloadNow([f.stock], action: .tUpdateAll)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(f.stock.technicalDirtyFrom, .distantPast,
                       "An existing S boundary must not discard an explicit full T request")
    }

    func testReloadNormalizationSavesDefaultAndInvalidationTogetherAndFailureDoesNotDispatch() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        f.stock.simInvestAuto = 0
        try f.context.save()
        var requests = 0
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in
            requests += 1
            XCTAssertFalse(f.context.hasChanges)
            XCTAssertEqual(f.stock.simInvestAuto, 2)
            XCTAssertEqual(f.stock.simulationDirtyFrom, .distantPast)
        }
        f.simulation.reloadNow([f.stock], action: .TWSE)
        XCTAssertEqual(requests, 1)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        f.simulation.simulationInputs.save = { throw Failure.save }
        XCTAssertTrue(f.ui.reloadNow([f.stock], action: .simUpdateAll))
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(f.ui.simulationStatusMessage.contains("保存失敗"))
        XCTAssertFalse(f.ui.isTradeOperationLocked)
    }

    func testUnchangedInvestmentAndInvalidDatesCannotMutateOrRequestReplay() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        var saves = 0
        var requests = 0
        f.simulation.simulationInputs.save = { saves += 1; try f.context.save() }
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in requests += 1 }
        f.trades[15].simInvestAdded = -1
        f.ui.addInvest(f.trades[15])
        f.simulation.addInvest(f.trades[0])
        f.simulation.setReversed(f.trades[0])
        XCTAssertEqual(saves, 0); XCTAssertEqual(requests, 0)
        XCTAssertNil(f.stock.simulationDirtyFrom); XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertEqual(f.trades[15].simInvestByUser, 0)
        XCTAssertEqual(f.stock.simInvestUser, 0)
        XCTAssertFalse(f.ui.isTradeOperationLocked)
    }
}
