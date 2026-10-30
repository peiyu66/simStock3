import Foundation
import SwiftData
import XCTest
@testable import simStock3

nonisolated private final class ManualInputURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManualInputURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let calendarFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: calendarFile) }
        let calendar = TWSETradingCalendar(fileURL: calendarFile, session: session)
        let simulation = simObject(modelContext: context, tradingCalendar: calendar, marketSession: session, marketRetryDelays: [])
        let trace = try simulation.tech.recalculate(stock: stock,
            plan: .init(technical: .all, simulation: .all, resetDerivedSimulationState: true))
        XCTAssertEqual(trace.simulationDates, (10..<30).map(date))
        XCTAssertNil(stock.technicalDirtyFrom); XCTAssertNil(stock.simulationDirtyFrom)
        XCTAssertNil(stock.manualIntentValidationFrom)
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
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(f.trades[15].simInvestByUser, 1)
        XCTAssertEqual(f.stock.simInvestUser, 1)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertFalse(f.ui.isTradeTechnicalResultPending(f.trades[15]))
        XCTAssertTrue(f.ui.isTradeResultPending(f.trades[15]))
        XCTAssertTrue(f.ui.isTradeOperationLocked)
        f.simulation.tech.manualRecalculationTask?.cancel()
        await f.simulation.tech.manualRecalculationTask?.value
        XCTAssertFalse(f.ui.isTradeOperationLocked)
        XCTAssertTrue(f.ui.simulationStatusMessage.contains("中斷"))

        let coldContainer = try container(url: url)
        defer { withExtendedLifetime(coldContainer) {} }
        let cold = ModelContext(coldContainer)
        cold.autosaveEnabled = false
        let stock = try XCTUnwrap(Stock.fetchAll(in: cold).first)
        let rows = try Trade.fetchCalculationWindow(in: cold, for: stock)
        XCTAssertEqual(rows[15].simInvestByUser, 1)
        XCTAssertEqual(stock.simulationDirtyFrom, date(15))
        XCTAssertEqual(stock.manualIntentValidationFrom, date(15))
        let technical = Technical(modelContext: cold)
        _ = try await technical.recoverOrMigrateRecalculationState(for: stock)
        XCTAssertEqual(technical.lastRecalculationTrace.simulationDates, (15..<30).map(date))
        XCTAssertTrue(technical.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertNil(stock.simulationDirtyFrom)
        XCTAssertNil(stock.manualIntentValidationFrom)
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
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(f.stock.simInvestUser, 0)
        XCTAssertTrue(f.stock.simReversed)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        await f.simulation.tech.manualRecalculationTask?.value
        XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertTrue(f.simulation.tech.lastRecalculationTrace.technicalDates.isEmpty)
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
    func testAllManualEntrypointsStayLocalAndSilentWithAnotherDirtyStock() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let other = Stock(sId: "OTHER", sName: "另一股", group: "測試",
            dateFirst: date(0), dateStart: date(10), simInvestAuto: 2, simMoneyBase: 100)
        f.context.insert(other)
        other.simulationDirtyFrom = date(10)
        let row = Trade(stock: other, dateTime: date(15))
        row.priceClose = 777; row.simReversed = "B+"
        f.context.insert(row)
        try f.context.save()
        f.simulation.stocks = f.simulation.getStocks()
        let httpBefore = ManualInputURLProtocol.requests
        var recoveryRequests = 0
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in recoveryRequests += 1 }
        for entry in 0..<8 {
            let trade = f.trades[15]
            if [2, 3, 6, 7].contains(entry) { trade.simInvestAdded = 0 }
            switch entry {
            case 0, 1: f.ui.setReversed(trade)
            case 2, 3: f.ui.addInvest(trade)
            case 4, 5: f.simulation.setReversed(trade)
            default: f.simulation.addInvest(trade)
            }
            XCTAssertEqual(f.stock.simulationDirtyFrom, date(15), "Each entry must actually save an operation")
            XCTAssertEqual(f.stock.manualIntentValidationFrom, date(15))
            await f.simulation.tech.manualRecalculationTask?.value
            XCTAssertNil(f.stock.simulationDirtyFrom)
            XCTAssertTrue(f.simulation.tech.lastRecalculationTrace.technicalDates.isEmpty)
            XCTAssertEqual(f.simulation.tech.lastRecalculationTrace.simulationDates, (15..<30).map(date))
            XCTAssertEqual(other.simulationDirtyFrom, date(10))
            XCTAssertEqual(row.priceClose, 777); XCTAssertEqual(row.simReversed, "B+")
            XCTAssertNil(f.ui.simulationMigrationAlert)
            XCTAssertTrue(f.ui.simulationStatusMessage.isEmpty)
            XCTAssertTrue(f.ui.priceUpdateMessage.isEmpty)
            XCTAssertFalse(f.ui.isTradeOperationLocked)
        }
        XCTAssertEqual(recoveryRequests, 0)
        XCTAssertEqual(ManualInputURLProtocol.requests, httpBefore, "Even an empty calendar must not be fetched")
    }

    func testLocalReplayFailureKeepsSavedIntentAndNeverDispatchesRecovery() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let httpBefore = ManualInputURLProtocol.requests
        var requests = 0
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in requests += 1 }
        f.simulation.tech.recalculationSave = { throw Failure.save }
        f.ui.setReversed(f.trades[15])
        let intent = f.trades[15].simReversed
        await f.simulation.tech.manualRecalculationTask?.value
        XCTAssertEqual(f.trades[15].simReversed, intent)
        XCTAssertEqual(f.stock.simulationDirtyFrom, date(15))
        XCTAssertTrue(f.ui.simulationStatusMessage.contains("重算失敗"))
        XCTAssertNil(f.ui.simulationMigrationAlert)
        XCTAssertFalse(f.ui.isTradeOperationLocked)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(ManualInputURLProtocol.requests, httpBefore)
    }

    func testMissingMarketKeepsLocalPendingWorkWithoutFetchingOrMigrationAlert() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let missing = try XCTUnwrap(MarketDay.fetchSameDay(as: date(20), in: f.context))
        f.context.delete(missing)
        try f.context.save()
        f.simulation.tech.invalidateMarketPricePathLookup()
        let httpBefore = ManualInputURLProtocol.requests
        var requests = 0
        f.simulation.tech.requiredDataRuleMigrationRequest = { _ in requests += 1 }
        f.ui.setReversed(f.trades[15])
        await f.simulation.tech.manualRecalculationTask?.value
        XCTAssertNotNil(f.stock.simulationDirtyFrom)
        XCTAssertFalse(f.ui.simulationStatusMessage.isEmpty)
        XCTAssertNil(f.ui.simulationMigrationAlert)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(ManualInputURLProtocol.requests, httpBefore)
        XCTAssertTrue(f.simulation.tech.lastRecalculationTrace.technicalDates.isEmpty)
    }

    func testQueuedLocalReplaysDoNotDispatchNetworkOrLoseSavedWork() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let httpBefore = ManualInputURLProtocol.requests
        f.simulation.setReversed(f.trades[15])
        f.simulation.addInvest(f.trades[12])
        await f.simulation.tech.manualRecalculationTask?.value
        XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertEqual(ManualInputURLProtocol.requests, httpBefore)
        XCTAssertFalse(f.simulation.tech.isRequestActive)
    }

    private func anotherDirtyStock(_ f: Fixture) throws -> (Stock, Trade) {
        let other = Stock(sId: "OTHER", sName: "另一股", group: "測試",
            dateFirst: date(0), dateStart: date(10), simInvestAuto: 2, simMoneyBase: 100)
        f.context.insert(other)
        other.technicalStateVersion = f.stock.technicalStateVersion
        other.simulationStateVersion = f.stock.simulationStateVersion
        other.simulationDirtyFrom = date(20)
        let row = Trade(stock: other, dateTime: date(20))
        row.priceClose = 777; row.simReversed = "B+"
        f.context.insert(row)
        try f.context.save()
        f.simulation.stocks = f.simulation.getStocks()
        return (other, row)
    }

    func testSingleStockCapitalAndInvestmentSettingsStayLocalAndSilent() async throws {
        for values in [(120.0, 2.0), (100.0, 3.0), (120.0, 3.0)] {
            let f = try fixture()
            defer { withExtendedLifetime(f.container) {} }
            let (other, row) = try anotherDirtyStock(f)
            let before = ManualInputURLProtocol.requests
            var recovery = 0
            f.simulation.tech.requiredDataRuleMigrationRequest = { _ in recovery += 1 }
            f.ui.applySetting(f.stock, dateStart: f.stock.dateStart,
                moneyBase: values.0, autoInvest: values.1, applyToAll: false)
            XCTAssertEqual(f.stock.simulationDirtyFrom, .distantPast)
            await f.simulation.tech.manualRecalculationTask?.value
            XCTAssertNil(f.stock.simulationDirtyFrom)
            XCTAssertTrue(f.simulation.tech.lastRecalculationTrace.technicalDates.isEmpty)
            XCTAssertEqual(f.simulation.tech.lastRecalculationTrace.simulationDates, (10..<30).map(date))
            XCTAssertEqual(other.simulationDirtyFrom, date(20))
            XCTAssertEqual(other.simMoneyBase, 100); XCTAssertEqual(other.simInvestAuto, 2)
            XCTAssertEqual(row.priceClose, 777); XCTAssertEqual(row.simReversed, "B+")
            XCTAssertEqual(recovery, 0); XCTAssertEqual(ManualInputURLProtocol.requests, before)
            XCTAssertNil(f.ui.simulationMigrationAlert)
            XCTAssertTrue(f.ui.simulationStatusMessage.isEmpty)
            XCTAssertTrue(f.ui.priceUpdateMessage.isEmpty)
            XCTAssertFalse(f.ui.isTradeOperationLocked)
        }
    }

    func testSingleStockStartChangesMatchExistingNecessaryReplayWithoutNetwork() async throws {
        for start in [date(9), date(11)] {
            let f = try fixture(), reference = try fixture()
            defer { withExtendedLifetime((f.container, reference.container)) {} }
            let (other, row) = try anotherDirtyStock(f)
            let before = ManualInputURLProtocol.requests
            var recovery = 0
            f.simulation.tech.requiredDataRuleMigrationRequest = { _ in recovery += 1 }
            _ = try reference.simulation.simulationInputs.applySettings([reference.stock], start: start,
                money: 100, investments: 2)
            _ = try await reference.simulation.tech.recoverOrMigrateRecalculationState(for: reference.stock)
            f.ui.applySetting(f.stock, dateStart: start, moneyBase: 100, autoInvest: 2, applyToAll: false)
            await f.simulation.tech.manualRecalculationTask?.value
            let trace = f.simulation.tech.lastRecalculationTrace
            let expected = reference.simulation.tech.lastRecalculationTrace
            XCTAssertEqual(trace.technicalDates, expected.technicalDates)
            XCTAssertEqual(trace.simulationDates, expected.simulationDates)
            XCTAssertFalse(trace.technicalDates.isEmpty, "Earlier start or changed first raw row needs T replay")
            XCTAssertEqual(f.stock.technicalDirtyFrom, reference.stock.technicalDirtyFrom)
            XCTAssertEqual(f.stock.simulationDirtyFrom, reference.stock.simulationDirtyFrom)
            XCTAssertEqual(other.simulationDirtyFrom, date(20)); XCTAssertEqual(row.simReversed, "B+")
            XCTAssertEqual(recovery, 0); XCTAssertEqual(ManualInputURLProtocol.requests, before)
            XCTAssertNil(f.ui.simulationMigrationAlert)
            XCTAssertFalse(f.ui.isTradeOperationLocked)
        }
    }

    func testSingleStockSettingsSheetCancelNoChangeAndDeferredApply() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let before = ManualInputURLProtocol.requests
        var saves = 0
        f.simulation.simulationInputs.save = { saves += 1; try f.context.save() }
        f.ui.simulationSettingsWillPresent()
        f.ui.simulationSettingsDidDismiss()
        XCTAssertEqual(saves, 0)
        f.ui.applySetting(f.stock, dateStart: f.stock.dateStart, moneyBase: 100, autoInvest: 2, applyToAll: false)
        XCTAssertEqual(saves, 0); XCTAssertNil(f.simulation.tech.manualRecalculationTask)
        XCTAssertTrue(f.ui.simulationStatusMessage.isEmpty)
        f.ui.simulationSettingsWillPresent()
        f.ui.applySetting(f.stock, dateStart: f.stock.dateStart, moneyBase: 120, autoInvest: 2, applyToAll: false)
        XCTAssertEqual(saves, 0); XCTAssertEqual(f.stock.simMoneyBase, 100)
        f.ui.simulationSettingsDidDismiss()
        XCTAssertEqual(saves, 1)
        await f.simulation.tech.manualRecalculationTask?.value
        XCTAssertEqual(f.stock.simMoneyBase, 120); XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertTrue(f.ui.simulationStatusMessage.isEmpty)
        XCTAssertEqual(ManualInputURLProtocol.requests, before)
    }

    func testSingleStockSettingCancellationKeepsPersistentFullReplayForColdRecovery() async throws {
        let url = try storeURL(), f = try fixture(url: url)
        defer { withExtendedLifetime(f.container) {} }
        let before = ManualInputURLProtocol.requests
        f.ui.applySetting(f.stock, dateStart: f.stock.dateStart, moneyBase: 120, autoInvest: 3, applyToAll: false)
        f.simulation.tech.manualRecalculationTask?.cancel()
        await f.simulation.tech.manualRecalculationTask?.value
        XCTAssertTrue(f.ui.simulationStatusMessage.contains("中斷"))
        let coldContainer = try container(url: url)
        defer { withExtendedLifetime(coldContainer) {} }
        let context = ModelContext(coldContainer)
        let stock = try XCTUnwrap(Stock.fetchAll(in: context).first)
        XCTAssertEqual(stock.simMoneyBase, 120); XCTAssertEqual(stock.simInvestAuto, 3)
        XCTAssertEqual(stock.simulationDirtyFrom, .distantPast)
        XCTAssertEqual(stock.manualIntentValidationFrom, .distantPast)
        let technical = Technical(modelContext: context)
        _ = try await technical.recoverOrMigrateRecalculationState(for: stock)
        XCTAssertNil(stock.simulationDirtyFrom)
        XCTAssertNil(stock.manualIntentValidationFrom)
        XCTAssertEqual(technical.lastRecalculationTrace.simulationDates, (10..<30).map(date))
        XCTAssertEqual(ManualInputURLProtocol.requests, before)
    }

    func testSingleStockSettingSaveAndReplayFailureKeepPendingWithoutDispatch() async throws {
        for failSave in [true, false] {
            let f = try fixture()
            defer { withExtendedLifetime(f.container) {} }
            let before = ManualInputURLProtocol.requests
            var recovery = 0
            f.simulation.tech.requiredDataRuleMigrationRequest = { _ in recovery += 1 }
            if failSave { f.simulation.simulationInputs.save = { throw Failure.save } }
            else { f.simulation.tech.recalculationSave = { throw Failure.save } }
            f.ui.applySetting(f.stock, dateStart: f.stock.dateStart, moneyBase: 120, autoInvest: 3, applyToAll: false)
            await f.simulation.tech.manualRecalculationTask?.value
            XCTAssertEqual(f.stock.simMoneyBase, 120)
            XCTAssertEqual(f.stock.simulationDirtyFrom, .distantPast)
            XCTAssertTrue(f.ui.simulationStatusMessage.contains("失敗"))
            XCTAssertNotNil(f.stock.manualIntentValidationFrom)
            XCTAssertNil(f.ui.simulationMigrationAlert)
            XCTAssertEqual(recovery, 0); XCTAssertEqual(ManualInputURLProtocol.requests, before)
            XCTAssertFalse(f.ui.isTradeOperationLocked)
        }
    }

    func testExplicitAllStockSettingsStillApplyToBothStocksAndUseGlobalRecovery() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let (other, _) = try anotherDirtyStock(f)
        var requested: [String] = []
        f.simulation.tech.requiredDataRuleMigrationRequest = { requested = $0.map(\.sId) }
        f.ui.applySetting(f.stock, dateStart: f.stock.dateStart, moneyBase: 120, autoInvest: 3, applyToAll: true)
        XCTAssertEqual(Set(requested), Set([f.stock.sId, other.sId]))
        XCTAssertEqual(other.simMoneyBase, 120); XCTAssertEqual(other.simInvestAuto, 3)
        XCTAssertEqual(f.stock.simulationDirtyFrom, .distantPast)
        XCTAssertEqual(other.simulationDirtyFrom, .distantPast)
        XCTAssertNil(f.simulation.tech.manualRecalculationTask)
    }

}
