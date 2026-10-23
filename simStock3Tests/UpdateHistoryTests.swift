import SwiftData
import XCTest
@testable import simStock3

/// The update planner must distinguish saved input edits without fetching the
/// historical Trade collection. Exercise the store's change journal itself.
@MainActor
final class UpdateHistoryTests: XCTestCase {
    private func date(_ value: String) -> Date {
        twDateTime.dateFromString(value, format: "yyyy/MM/dd HH:mm")!
    }

    func testLedgerScopesSourceWorkAndMarketInvalidationAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let url = directory.appendingPathComponent("ledger.store")
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        var rows: [Trade] = []
        let stocks = ["A", "B"].map { id in
            let stock = Stock(sId: id, sName: id, group: "A", dateFirst: date("2025/10/01 00:00"),
                dateStart: date("2026/10/01 00:00"))
            context.insert(stock)
            let row = Trade(stock: stock, dateTime: date("2025/10/02 13:30"), dataSource: "TWSE")
            row.priceClose = 100
            context.insert(row)
            rows.append(row)
            return stock
        }
        try context.save()
        let ledger = UpdateWorkLedger(context: context)
        ledger.refresh()
        XCTAssertTrue(ledger.isReliable)
        func certify() throws {
            for (stock, row) in zip(stocks, rows) {
                ledger.rememberSource(stock, trades: [row], through: nil)
                ledger.rememberCompletedWork(stock)
            }
            try ledger.persist()
        }
        try certify()
        XCTAssertTrue(ledger.hasCompletedWork(stocks[0]))
        stocks[0].yahooCheckedAt = Date()
        stocks[0].sName = "名稱更新"
        try context.save(); ledger.refresh()
        XCTAssertTrue(ledger.hasCompletedWork(stocks[0]), "Display/check timestamps do not invalidate calculations")
        rows[0].simInvestByUser = 1
        try context.save(); ledger.refresh()
        XCTAssertNotNil(ledger.proof(for: stocks[0]), "Manual S input must preserve source evidence")
        XCTAssertFalse(ledger.hasCompletedWork(stocks[0]))
        XCTAssertTrue(ledger.hasCompletedWork(stocks[1]))
        try certify()
        rows[0].priceClose = 101
        try context.save(); ledger.refresh()
        XCTAssertNil(ledger.proof(for: stocks[0]))
        XCTAssertTrue(ledger.hasCompletedWork(stocks[1]), "One stock's quote does not invalidate another")
        try certify()
        let market = MarketDay(dateTime: date("2025/10/02 13:30"), indexOpen: 100,
            indexHigh: 101, indexLow: 99, indexClose: 100)
        context.insert(market)
        try context.save(); ledger.refresh()
        XCTAssertNotNil(ledger.proof(for: stocks[0]), "Market input does not invalidate stock source/T")
        XCTAssertFalse(ledger.hasCompletedWork(stocks[0]))
        XCTAssertFalse(ledger.hasCompletedWork(stocks[1]))
        try certify()
        let reopened = UpdateWorkLedger(context: context)
        reopened.refresh()
        XCTAssertTrue(reopened.hasCompletedWork(stocks[0]), "Successful completion survives a new ledger")
        XCTAssertEqual(reopened.changedTransactions, 0)
        stocks[0].dateStart = date("2026/09/01 00:00")
        XCTAssertFalse(reopened.hasCompletedWork(stocks[0]), "Unsaved settings cannot use a certificate")
        try context.save(); reopened.refresh()
        XCTAssertNil(reopened.proof(for: stocks[0]))
        XCTAssertTrue(reopened.hasCompletedWork(stocks[1]))
        context.delete(rows[1]); try context.save(); reopened.refresh()
        XCTAssertNil(reopened.proof(for: stocks[1]), "Removing the earliest quote invalidates its window")
    }

    func testSavedInputEventMatrixInvalidatesOnlyTheAffectedProof() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema,
            url: directory.appendingPathComponent("events.store")))
        let context = container.mainContext
        context.autosaveEnabled = false
        let stock = Stock(sId: "MATRIX", sName: "MATRIX", group: "A",
            dateFirst: date("2025/01/01 00:00"), dateStart: date("2026/01/01 00:00"))
        context.insert(stock)
        let row = Trade(stock: stock, dateTime: date("2026/01/02 13:30"), dataSource: "TWSE")
        row.priceClose = 100
        context.insert(row); try context.save()
        let ledger = UpdateWorkLedger(context: context)
        ledger.refresh()
        let events: [(String, Bool, () -> Void)] = [
            ("date correction", true, { row.dateTime = self.date("2026/01/03 13:30") }),
            ("source replacement", true, { row.dataSource = "yahoo" }),
            ("volume correction", true, { row.volumeClose = 200 }),
            ("coverage", true, { stock.twseHistoryCoverage = Data("{}".utf8) }),
            ("listing evidence", true, { stock.twseListingDate = self.date("2025/01/02 00:00") }),
            ("group exit", true, { stock.group = "" }),
            ("group reentry", true, { stock.group = "B" }),
            ("capital", false, { stock.simMoneyBase = 200_000 }),
            ("automatic investment", false, { stock.simInvestAuto = 50_000 }),
            ("manual reversal", false, { row.simReversed = "B-" }),
            ("technical version", false, { stock.technicalStateVersion += 1 }),
            ("simulation version", false, { stock.simulationStateVersion += 1 }),
            ("persistent pending work", false, { stock.simulationDirtyFrom = row.dateTime })
        ]
        for (name, invalidatesSource, edit) in events {
            ledger.rememberSource(stock, trades: [row], through: nil)
            ledger.rememberCompletedWork(stock)
            ledger.rememberP10(stock, quote: row)
            XCTAssertTrue(ledger.hasCompletedWork(stock), name)
            edit(); try context.save(); ledger.refresh()
            XCTAssertEqual(ledger.proof(for: stock) == nil, invalidatesSource, name)
            XCTAssertFalse(ledger.hasCompletedWork(stock), name)
            XCTAssertFalse(ledger.hasP10(stock, quote: row), name)
        }
        ledger.rememberSource(stock, trades: [row], through: nil)
        ledger.rememberCompletedWork(stock)
        let earlier = Trade(stock: stock, dateTime: date("2025/01/02 13:30"), dataSource: "TWSE")
        earlier.priceClose = 90
        context.insert(earlier); try context.save(); ledger.refresh()
        XCTAssertNil(ledger.proof(for: stock), "Backfill insertion invalidates the cached start")
        ledger.rememberSource(stock, trades: [earlier, row], through: nil)
        ledger.rememberCompletedWork(stock)
        context.delete(earlier); try context.save(); ledger.refresh()
        XCTAssertNil(ledger.proof(for: stock), "Deleting that start invalidates it again")
        withExtendedLifetime(container) {}
    }

    func testIntradayEligibilityExcludesOldOfficialAndPostCloseQuotes() async throws {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let stock = Stock(sId: "TIME", sName: "TIME", group: "A", dateFirst: .distantPast, dateStart: .distantPast)
        container.mainContext.insert(stock)
        let trade = Trade(stock: stock, dateTime: date("2026/10/23 10:00"), dataSource: "yahoo")
        trade.priceClose = 100
        container.mainContext.insert(trade)
        XCTAssertTrue(IntradayScenarioPolicy.permits(trade, asOf: date("2026/10/23 10:01")))
        for now in ["2026/10/23 08:59", "2026/10/23 13:30", "2026/10/23 15:30", "2026/10/24 10:00"] {
            XCTAssertFalse(IntradayScenarioPolicy.permits(trade, asOf: date(now)), now)
        }
        trade.dataSource = "TWSE"
        XCTAssertFalse(IntradayScenarioPolicy.permits(trade, asOf: date("2026/10/23 10:01")))
        trade.dataSource = "yahoo"; trade.dateTime = date("2026/10/22 10:00")
        XCTAssertFalse(IntradayScenarioPolicy.permits(trade, asOf: date("2026/10/23 10:01")))
        trade.dateTime = date("2026/10/23 13:30")
        XCTAssertFalse(IntradayScenarioPolicy.permits(trade, asOf: date("2026/10/23 13:31")))
    }

    func testUnsavedChangesFailedReceiptAndForeignStoreCannotCertifyCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let url = directory.appendingPathComponent("ledger.store")
        let receipt = url.appendingPathExtension("update-check.json")
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        context.autosaveEnabled = false
        let stock = Stock(sId: "SAVED", sName: "SAVED", group: "A", dateFirst: .distantPast, dateStart: Date())
        context.insert(stock)
        let row = Trade(stock: stock, dateTime: Date(), dataSource: "TWSE")
        row.priceClose = 100
        context.insert(row); try context.save()
        let ledger = UpdateWorkLedger(context: context)
        ledger.refresh()
        ledger.rememberSource(stock, trades: [row], through: nil)
        ledger.rememberCompletedWork(stock)
        ledger.rememberP10(stock, quote: row)
        try ledger.persist()
        let savedReceipt = try Data(contentsOf: receipt)
        let reopened = UpdateWorkLedger(context: context)
        reopened.refresh()
        XCTAssertTrue(reopened.hasP10(stock, quote: row))
        row.priceClose = 200 // No successful save; never overwrite the saved proof.
        ledger.refresh()
        ledger.rememberSource(stock, trades: [row], through: nil)
        ledger.rememberCompletedWork(stock)
        try ledger.persist()
        XCTAssertFalse(ledger.hasCompletedWork(stock))
        XCTAssertEqual(try Data(contentsOf: receipt), savedReceipt)
        context.rollback()
        let afterRollback = UpdateWorkLedger(context: context)
        afterRollback.refresh()
        XCTAssertTrue(afterRollback.hasCompletedWork(stock), "Rollback restored the certified saved inputs")

        // A restored database can have older history even if the file identity
        // is unchanged. A receipt ahead of the store must not certify it.
        var futureReceipt = try XCTUnwrap(JSONSerialization.jsonObject(with: savedReceipt) as? [String: Any])
        var token = try XCTUnwrap(futureReceipt["token"] as? [String: Any])
        let storeTokens = try XCTUnwrap(token["storeTokens"] as? [String: Int64])
        token["storeTokens"] = storeTokens.mapValues { $0 + 1000 }
        futureReceipt["token"] = token
        try JSONSerialization.data(withJSONObject: futureReceipt).write(to: receipt)
        let afterStoreRestore = UpdateWorkLedger(context: context)
        afterStoreRestore.refresh()
        XCTAssertFalse(afterStoreRestore.hasCompletedWork(stock))
        try savedReceipt.write(to: receipt)

        let otherURL = directory.appendingPathComponent("replacement.store")
        let other = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: otherURL))
        try savedReceipt.write(to: otherURL.appendingPathExtension("update-check.json"))
        let foreign = UpdateWorkLedger(context: other.mainContext)
        foreign.refresh()
        XCTAssertNil(foreign.proof(for: stock), "A copied/imported store cannot inherit another store's receipt")

        stock.technicalStateVersion = 0
        stock.technicalDirtyFrom = .distantPast
        try context.save(); ledger.refresh()
        XCTAssertFalse(ledger.hasCompletedWork(stock))
        try FileManager.default.removeItem(at: receipt)
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ledger.persist())
        let afterFailedReceipt = UpdateWorkLedger(context: context)
        afterFailedReceipt.refresh()
        XCTAssertNil(afterFailedReceipt.proof(for: stock))
        XCTAssertEqual(stock.technicalDirtyFrom, .distantPast, "Cache failure cannot clear durable work")
        withExtendedLifetime((container, other)) {}
    }

    func testPersistentHistoryReportsFieldsAndRelationshipDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let url = directory.appendingPathComponent("history.store")
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let stock = Stock(sId: "JOURNAL", sName: "紀錄", group: "A",
                          dateFirst: .distantPast, dateStart: Date())
        context.insert(stock)
        let trade = Trade(stock: stock, dateTime: Date())
        trade.priceClose = 100
        context.insert(trade)
        try context.save()
        var latest = HistoryDescriptor<DefaultHistoryTransaction>(sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)])
        latest.fetchLimit = 1
        let first = try XCTUnwrap(context.fetchHistory(latest).first)
        let token = first.token
        trade.priceClose = 101
        try context.save()
        let changes = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: #Predicate { $0.token > token }))
        XCTAssertEqual(changes.count, 1)
        let fields = changes.flatMap(\.changes).compactMap { change -> DefaultHistoryUpdate<Trade>? in
            guard case .update(let update) = change else { return nil }
            return update as? DefaultHistoryUpdate<Trade>
        }.flatMap(\.updatedAttributes)
        XCTAssertTrue(fields.contains(\Trade.priceClose))
        let beforeDelete = try XCTUnwrap(context.fetchHistory(latest).first).token
        context.delete(trade)
        try context.save()
        let deletion = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: #Predicate { $0.token > beforeDelete }))
        let stockRelationships = deletion.flatMap(\.changes).compactMap { change -> DefaultHistoryUpdate<Stock>? in
            guard case .update(let update) = change else { return nil }
            return update as? DefaultHistoryUpdate<Stock>
        }.flatMap(\.updatedAttributes)
        XCTAssertTrue(stockRelationships.contains(\Stock.trades), "Deleting a row must identify its owning stock through the inverse relationship")
        let encoded = try JSONEncoder().encode(try XCTUnwrap(context.fetchHistory(latest).first).token)
        let decoded = try JSONDecoder().decode(DefaultHistoryToken.self, from: encoded)
        let reader = ModelContext(container)
        XCTAssertTrue(try reader.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: #Predicate { $0.token > decoded })).isEmpty)
    }
}
