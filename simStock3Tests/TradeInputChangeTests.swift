import Foundation
import Observation
import SwiftData
import XCTest
@testable import simStock3

/// These exercise the real @Model-generated accessors, including objects
/// materialized by SwiftData rather than constructed by Trade.init.
@MainActor
final class TradeInputChangeTests: XCTestCase {
    private func day(_ text: String) -> Date {
        twDateTime.startOfDay(twDateTime.dateFromString(text)!)
    }

    private func makeContainer(at url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func insertStock(_ identifier: String, in context: ModelContext) -> Stock {
        let stock = Stock(sId: identifier, sName: identifier, group: "測試",
            dateFirst: day("2020/01/01"), dateStart: day("2024/06/15"))
        context.insert(stock)
        return stock
    }

    @discardableResult
    private func insertRow(_ date: String, stock: Stock, in context: ModelContext) -> Trade {
        let trade = Trade(stock: stock, dateTime: twDateTime.time1330(day(date)))
        trade.priceClose = 100
        context.insert(trade)
        return trade
    }

    private func fetchedStock(_ identifier: String, in context: ModelContext) throws -> Stock {
        try XCTUnwrap(context.fetch(FetchDescriptor<Stock>(
            predicate: #Predicate { $0.sId == identifier })).first)
    }

    func testSuccessiveUnsavedRawChangesRefreshEndpointsIncludingOutsideRowMovingInside() throws {
        let container = try makeContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let stock = insertStock("RAW", in: context)
        let first = insertRow("2023/07/01", stock: stock, in: context)
        let last = insertRow("2024/07/01", stock: stock, in: context)
        let outside = insertRow("2023/06/14", stock: stock, in: context)
        try context.save()
        XCTAssertEqual(stock.effectiveSimulationStart, day("2024/07/01"))

        let initialRevision = stock.tradeInputChanges.revision
        first.priceClose = 0
        XCTAssertGreaterThan(stock.tradeInputChanges.revision, initialRevision)
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2024/07/01"))
        first.priceClose = 100
        XCTAssertEqual(stock.effectiveSimulationStart, day("2024/07/01"))
        first.dateTime = twDateTime.time1330(day("2023/06/20"))
        XCTAssertEqual(stock.effectiveSimulationStart, day("2024/06/20"))

        // This row was not a cached endpoint or an input to the prior window.
        let changed = ObservationCount()
        withObservationTracking { _ = stock.calculationWindow } onChange: {
            MainActor.assumeIsolated { changed.value += 1 }
        }
        outside.dateTime = twDateTime.time1330(day("2023/06/15"))
        XCTAssertEqual(changed.value, 1, "The per-stock signal must notify summary observers")
        XCTAssertEqual(stock.effectiveSimulationStart, day("2024/06/15"))
        last.dateTime = twDateTime.time1330(day("2024/08/01"))
        XCTAssertEqual(stock.calculationWindow.lastPriceDate, day("2024/08/01"))
        let beforeSourceChange = stock.tradeInputChanges.revision
        last.dataSource = "Yahoo"
        XCTAssertGreaterThan(stock.tradeInputChanges.revision, beforeSourceChange)
        XCTAssertEqual(stock.calculationWindow.lastPriceDate, day("2024/08/01"))
        XCTAssertTrue(context.hasChanges, "These reads must work before saving")
    }

    func testInsertedRowInvalidatesAnAlreadyCachedEmptyWindow() throws {
        let container = try makeContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let stock = insertStock("INSERT", in: context)
        try context.save()
        XCTAssertNil(stock.calculationWindow.firstPriceDate)
        let revision = stock.tradeInputChanges.revision
        insertRow("2023/06/15", stock: stock, in: context)
        XCTAssertGreaterThan(stock.tradeInputChanges.revision, revision)
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2023/06/15"))
        XCTAssertTrue(context.hasChanges)
    }

    func testNewlyFetchedContextInstanceInvalidatesWithoutInitializerTrackingFlag() throws {
        let container = try makeContainer()
        defer { withExtendedLifetime(container) {} }
        let original = insertStock("FETCHED", in: container.mainContext)
        let originalFirst = insertRow("2023/06/15", stock: original, in: container.mainContext)
        insertRow("2024/07/01", stock: original, in: container.mainContext)
        try container.mainContext.save()

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let fetched = try fetchedStock("FETCHED", in: context)
        let first = try XCTUnwrap(Trade.windowEndpoint(in: context, for: fetched, ascending: true))
        XCTAssertFalse(first === originalFirst)
        XCTAssertFalse(first.rawInputTrackingReady, "Exercise the materialized-model branch")
        XCTAssertNotNil(first.modelContext)
        XCTAssertEqual(fetched.calculationWindow.firstPriceDate, day("2023/06/15"))

        let revision = fetched.tradeInputChanges.revision
        first.priceClose = 0
        XCTAssertGreaterThan(fetched.tradeInputChanges.revision, revision)
        XCTAssertEqual(fetched.calculationWindow.firstPriceDate, day("2024/07/01"))
        first.priceClose = 101
        first.dateTime = twDateTime.time1330(day("2023/06/20"))
        XCTAssertEqual(fetched.effectiveSimulationStart, day("2024/06/20"))
        try context.save()

        let verification = ModelContext(container)
        let savedStock = try fetchedStock("FETCHED", in: verification)
        let savedFirst = try XCTUnwrap(Trade.windowEndpoint(in: verification, for: savedStock, ascending: true))
        XCTAssertEqual(savedFirst.priceClose, 101)
        XCTAssertEqual(savedStock.calculationWindow.firstPriceDate, day("2023/06/20"))
    }

    func testRawWritesSaveAndReopenWithoutPersistingRevisionOrLosingFutureInvalidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TradeInputChanges-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")

        try autoreleasepool {
            let container = try makeContainer(at: url)
            let context = container.mainContext
            let stock = insertStock("REOPEN", in: context)
            let first = insertRow("2023/06/15", stock: stock, in: context)
            insertRow("2024/07/01", stock: stock, in: context)
            try context.save()
            _ = stock.calculationWindow
            first.priceClose = 123
            first.dateTime = twDateTime.time1330(day("2023/06/20"))
            first.dataSource = "Yahoo"
            XCTAssertEqual(stock.effectiveSimulationStart, day("2024/06/20"))
            try context.save()
            withExtendedLifetime(container) {}
        }

        try autoreleasepool {
            let reopened = try makeContainer(at: url)
            let context = reopened.mainContext
            let stock = try fetchedStock("REOPEN", in: context)
            XCTAssertEqual(stock.tradeInputChanges.revision, 0)
            XCTAssertNil(stock.cachedCalculationWindow)
            let first = try XCTUnwrap(Trade.windowEndpoint(in: context, for: stock, ascending: true))
            XCTAssertEqual(first.priceClose, 123)
            XCTAssertEqual(first.dataSource, "Yahoo")
            XCTAssertEqual(stock.effectiveSimulationStart, day("2024/06/20"))
            let revision = stock.tradeInputChanges.revision
            first.priceClose = 0
            XCTAssertGreaterThan(stock.tradeInputChanges.revision, revision)
            XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2024/07/01"))
            try context.save()
            withExtendedLifetime(reopened) {}
        }

        let verified = try makeContainer(at: url)
        defer { withExtendedLifetime(verified) {} }
        let stock = try fetchedStock("REOPEN", in: verified.mainContext)
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2024/07/01"))
        XCTAssertEqual(try verified.mainContext.fetchCount(FetchDescriptor<Trade>()), 2,
                       "Invalid prices remain stored; endpoint queries only exclude them")
    }

    func testChangingOwnerInvalidatesBothOldAndNewStockBeforeSave() throws {
        let container = try makeContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let oldOwner = insertStock("OWNER-A", in: context)
        let newOwner = insertStock("OWNER-B", in: context)
        let moved = insertRow("2023/06/15", stock: oldOwner, in: context)
        insertRow("2024/06/15", stock: oldOwner, in: context)
        insertRow("2023/07/01", stock: newOwner, in: context)
        insertRow("2024/07/01", stock: newOwner, in: context)
        try context.save()
        XCTAssertEqual(oldOwner.calculationWindow.firstPriceDate, day("2023/06/15"))
        XCTAssertEqual(newOwner.calculationWindow.firstPriceDate, day("2023/07/01"))
        let oldRevision = oldOwner.tradeInputChanges.revision
        let newRevision = newOwner.tradeInputChanges.revision

        moved.stock = newOwner
        XCTAssertGreaterThan(oldOwner.tradeInputChanges.revision, oldRevision)
        XCTAssertGreaterThan(newOwner.tradeInputChanges.revision, newRevision)
        XCTAssertEqual(oldOwner.calculationWindow.firstPriceDate, day("2024/06/15"))
        XCTAssertEqual(newOwner.calculationWindow.firstPriceDate, day("2023/06/15"))
        XCTAssertTrue(context.hasChanges)
        try context.save()

        let verification = ModelContext(container)
        let savedOwner = try fetchedStock("OWNER-B", in: verification)
        let savedFirst = try XCTUnwrap(Trade.windowEndpoint(in: verification, for: savedOwner, ascending: true))
        XCTAssertEqual(savedFirst.stock.sId, "OWNER-B")
        XCTAssertEqual(savedOwner.calculationWindow.firstPriceDate, day("2023/06/15"))
    }

    func testDeletingCachedEndpointsRefreshesGetterBeforeSave() throws {
        let container = try makeContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let stock = insertStock("DELETE", in: context)
        let first = insertRow("2023/06/15", stock: stock, in: context)
        let middle = insertRow("2023/07/01", stock: stock, in: context)
        let last = insertRow("2024/07/01", stock: stock, in: context)
        try context.save()
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2023/06/15"))
        XCTAssertEqual(stock.calculationWindow.lastPriceDate, day("2024/07/01"))

        context.delete(first)
        XCTAssertTrue(first.isDeleted)
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2023/07/01"))
        context.delete(last)
        XCTAssertEqual(stock.calculationWindow.lastPriceDate, day("2023/07/01"))
        context.delete(middle)
        XCTAssertNil(stock.calculationWindow.firstPriceDate)
        XCTAssertNil(stock.calculationWindow.lastPriceDate)
        XCTAssertTrue(context.hasChanges)
    }

    func testTechnicalSimulationAndManualResultWritesDoNotInvalidateRawWindow() throws {
        let container = try makeContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let stock = insertStock("DERIVED", in: context)
        let trade = insertRow("2023/06/15", stock: stock, in: context)
        insertRow("2024/07/01", stock: stock, in: context)
        try context.save()
        let window = stock.calculationWindow
        let revision = stock.tradeInputChanges.revision

        trade.tKdK = 55
        trade.tMa60 = 101
        trade.tUpdated = true
        trade.simAmtBalance = 99
        trade.simFitTrend = 0.4
        trade.simUpdated = true
        trade.simInvestByUser = 2
        trade.simReversed = "Buy"
        XCTAssertEqual(stock.tradeInputChanges.revision, revision)
        XCTAssertEqual(stock.calculationWindow, window)
        try context.save()
        XCTAssertEqual(stock.tradeInputChanges.revision, revision)
        XCTAssertEqual(stock.calculationWindow, window)
    }

    func testRollbackRestoresEditedEndpointsAndOutsideRowsAcrossRepeatedEdits() throws {
        let container = try makeContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let stock = insertStock("ROLLBACK-RAW", in: context)
        let first = insertRow("2023/06/20", stock: stock, in: context)
        insertRow("2023/07/01", stock: stock, in: context)
        let last = insertRow("2024/07/01", stock: stock, in: context)
        let outside = insertRow("2023/06/14", stock: stock, in: context)
        try context.save()
        let original = stock.calculationWindow

        first.priceClose = 0
        outside.dateTime = twDateTime.time1330(day("2023/06/15"))
        last.dateTime = twDateTime.time1330(day("2024/08/01"))
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2023/06/15"))
        XCTAssertEqual(stock.calculationWindow.lastPriceDate, day("2024/08/01"))
        try ModelRollback.restore(in: context)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(first.priceClose, 100)
        XCTAssertEqual(outside.dateTime, twDateTime.time1330(day("2023/06/14")))
        XCTAssertEqual(stock.calculationWindow, original)

        // A second cycle exercises the rearmed observation, not only its first
        // callback. The moved row is inside the date range but has no valid price.
        first.dateTime = twDateTime.time1330(day("2023/06/14"))
        outside.priceClose = 0
        outside.dateTime = twDateTime.time1330(day("2023/06/15"))
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2023/07/01"))
        try ModelRollback.restore(in: context)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(first.dateTime, twDateTime.time1330(day("2023/06/20")))
        XCTAssertEqual(outside.priceClose, 100)
        XCTAssertEqual(stock.calculationWindow, original)
    }

    func testRawRollbackBeforeAnyWindowQueryPreservesOriginalValues() throws {
        let container = try makeContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let stock = insertStock("ROLLBACK-UNREAD", in: context)
        let row = insertRow("2023/06/20", stock: stock, in: context)
        try context.save()
        row.priceClose = 0
        row.dateTime = twDateTime.time1330(day("2023/07/01"))
        XCTAssertTrue(context.hasChanges)
        try ModelRollback.restore(in: context)
        XCTAssertEqual(row.priceClose, 100)
        XCTAssertEqual(row.dateTime, twDateTime.time1330(day("2023/06/20")))
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2023/06/20"))
    }

    func testRollbackRestoresDeletedEndpointsAfterReadingPendingSummary() throws {
        let container = try makeContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let stock = insertStock("ROLLBACK-DELETE", in: context)
        let first = insertRow("2023/06/20", stock: stock, in: context)
        insertRow("2023/07/01", stock: stock, in: context)
        let last = insertRow("2024/07/01", stock: stock, in: context)
        try context.save()
        let original = stock.calculationWindow

        context.delete(first)
        context.delete(last)
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2023/07/01"))
        XCTAssertEqual(stock.calculationWindow.lastPriceDate, day("2023/07/01"))
        try ModelRollback.restore(in: context)
        XCTAssertFalse(context.hasChanges)
        XCTAssertFalse(first.isDeleted)
        XCTAssertFalse(last.isDeleted)
        XCTAssertEqual(stock.calculationWindow, original)

        context.delete(last)
        XCTAssertEqual(stock.calculationWindow.lastPriceDate, day("2023/07/01"))
        try ModelRollback.restore(in: context)
        XCTAssertEqual(stock.calculationWindow, original)
    }

    func testRollbackDiscardsInsertedEndpointsAfterReadingPendingSummary() throws {
        let container = try makeContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let stock = insertStock("ROLLBACK-INSERT", in: context)
        insertRow("2023/06/20", stock: stock, in: context)
        insertRow("2024/07/01", stock: stock, in: context)
        try context.save()
        let original = stock.calculationWindow

        insertRow("2023/06/15", stock: stock, in: context)
        insertRow("2024/08/01", stock: stock, in: context)
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2023/06/15"))
        XCTAssertEqual(stock.calculationWindow.lastPriceDate, day("2024/08/01"))
        try ModelRollback.restore(in: context)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(stock.calculationWindow, original)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Trade>()), 2)

        insertRow("2023/06/16", stock: stock, in: context)
        XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2023/06/16"))
        try ModelRollback.restore(in: context)
        XCTAssertEqual(stock.calculationWindow, original)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Trade>()), 2)
    }

    func testReadOnlyStoreSaveFailurePreservesPendingSummaryAndRollbackRestoresStoredInputs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TradeInputReadOnly-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")

        try autoreleasepool {
            let container = try makeContainer(at: url)
            let context = container.mainContext
            let stock = insertStock("READ-ONLY", in: context)
            insertRow("2023/06/20", stock: stock, in: context)
            insertRow("2023/07/01", stock: stock, in: context)
            insertRow("2024/07/01", stock: stock, in: context)
            insertRow("2020/01/01", stock: stock, in: context)
            try context.save()
            withExtendedLifetime(container) {}
        }
        let storedBytes = try databaseBytes(at: url)

        try autoreleasepool {
            let schema = Schema([Stock.self, Trade.self, MarketDay.self])
            let configuration = ModelConfiguration(schema: schema, url: url,
                allowsSave: false, cloudKitDatabase: .none)
            let readOnly = try ModelContainer(for: schema, configurations: configuration)
            let context = readOnly.mainContext
            context.autosaveEnabled = false
            let stock = try fetchedStock("READ-ONLY", in: context)
            let original = stock.calculationWindow
            let rows = try context.fetch(FetchDescriptor<Trade>(sortBy: [SortDescriptor(\.dateTime)]))
            XCTAssertEqual(rows.count, 4)
            let outside = try XCTUnwrap(rows.first)
            let first = try XCTUnwrap(Trade.windowEndpoint(in: context, for: stock, ascending: true))
            let last = try XCTUnwrap(Trade.windowEndpoint(in: context, for: stock, ascending: false))

            first.priceClose = 0
            outside.dateTime = twDateTime.time1330(day("2023/06/15"))
            context.delete(last)
            insertRow("2024/08/01", stock: stock, in: context)
            let pending = stock.calculationWindow
            XCTAssertEqual(pending.firstPriceDate, day("2023/06/15"))
            XCTAssertEqual(pending.lastPriceDate, day("2024/08/01"))

            // The failure must come from the real read-only store, not a mock
            // error or a precondition that skips the actual ModelContext.save.
            var saveFailure: Error?
            do { try context.save() } catch { saveFailure = error }
            guard let saveFailure else {
                XCTFail("allowsSave:false did not reject ModelContext.save; save-failure behavior was not exercised")
                return
            }
            let error = saveFailure as NSError
            print("TRADE_INPUT_READ_ONLY_SAVE_FAILURE domain=\(error.domain) code=\(error.code)")
            XCTAssertTrue(context.hasChanges)
            XCTAssertEqual(stock.calculationWindow, pending)

            try ModelRollback.restore(in: context)
            XCTAssertFalse(context.hasChanges)
            XCTAssertEqual(first.priceClose, 100)
            XCTAssertEqual(outside.dateTime, twDateTime.time1330(day("2020/01/01")))
            XCTAssertEqual(stock.calculationWindow, original)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Trade>()), 4)
            withExtendedLifetime(readOnly) {}
        }

        XCTAssertEqual(try databaseBytes(at: url), storedBytes,
                       "Rejected writes and rollback must not change the isolated database or its WAL")
        try autoreleasepool {
            let schema = Schema([Stock.self, Trade.self, MarketDay.self])
            let verified = try ModelContainer(for: schema, configurations:
                ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none))
            let context = verified.mainContext
            context.autosaveEnabled = false
            let stock = try fetchedStock("READ-ONLY", in: context)
            let rows = try context.fetch(FetchDescriptor<Trade>(sortBy: [SortDescriptor(\.dateTime)]))
            XCTAssertEqual(rows.map { twDateTime.startOfDay($0.dateTime) },
                [day("2020/01/01"), day("2023/06/20"), day("2023/07/01"), day("2024/07/01")])
            XCTAssertTrue(rows.allSatisfy { $0.priceClose == 100 && $0.dataSource == "TWSE" })
            XCTAssertEqual(stock.calculationWindow.firstPriceDate, day("2023/06/20"))
            XCTAssertEqual(stock.calculationWindow.lastPriceDate, day("2024/07/01"))
            withExtendedLifetime(verified) {}
        }
    }

    func testReadOnlySaveFailureRecoveryIsIndependentOfPendingIdentifierOrder() throws {
        // A single successful run used to depend on which edited/deleted ID
        // happened to be fetched first. Exercise independent stores/identities.
        for _ in 0..<5 {
            try testReadOnlyStoreSaveFailurePreservesPendingSummaryAndRollbackRestoresStoredInputs()
        }
    }

    /// SHM contains connection locks, not persistent contents. Compare the
    /// actual SQLite and WAL bytes of this test's freshly created tiny store.
    private func databaseBytes(at url: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for suffix in ["", "-wal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                files[suffix] = try Data(contentsOf: file)
            }
        }
        return files
    }

    @MainActor
    private final class ObservationCount {
        var value = 0
    }
}
