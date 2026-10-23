import Foundation
import SwiftData
import XCTest
@testable import simStock3

/// Exercises the app's rollback boundary after a real rejected disk-store save.
/// The original model references must be restored before any verification fetch.
@MainActor
final class ModelRollbackTests: XCTestCase {
    private let stockIDs = ["ROLLBACK-A", "ROLLBACK-B"]
    private let tradeDays = ["2020/01/02", "2023/06/20", "2024/07/01"]
    private let marketDays = ["2024/07/01", "2024/07/02"]

    private func day(_ text: String) -> Date {
        twDateTime.startOfDay(twDateTime.dateFromString(text)!)
    }

    private func makeContainer(at url: URL, allowsSave: Bool) throws -> ModelContainer {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(
            schema: schema, url: url, allowsSave: allowsSave, cloudKitDatabase: .none))
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func seed(in context: ModelContext) throws {
        for index in stockIDs.indices {
            let stock = Stock(sId: stockIDs[index], sName: stockIDs[index],
                group: index == 0 ? "A" : "B", dateFirst: day("2020/01/01"),
                dateStart: day("2024/06/15"), simInvestAuto: 2, simMoneyBase: 100_000)
            context.insert(stock)
            stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
            stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
            stock.technicalDirtyFrom = day("2024/07/02")
            stock.simulationDirtyFrom = day("2024/07/03")
            stock.simInvestExceed = 2
            stock.simMoneyLacked = true
            var rows: [Trade] = []
            for (offset, date) in tradeDays.enumerated() {
                let row = Trade(stock: stock, dateTime: twDateTime.time1330(day(date)))
                context.insert(row)
                let price = Double(100 + index * 10 + offset)
                row.priceOpen = price - 1
                row.priceHigh = price + 2
                row.priceLow = price - 2
                row.priceClose = price
                row.volumeClose = Double(1_000 + offset)
                if offset == tradeDays.count - 1 {
                    row.simReversed = index == 0 ? "S+" : "B+"
                    row.simInvestByUser = index == 0 ? 1 : -1
                }
                rows.append(row)
            }
            stock.rebuildUserActionSummary(from: rows)
        }
        for index in marketDays.indices {
            let price = Double(20_000 + index * 100)
            let market = MarketDay(dateTime: day(marketDays[index]),
                indexOpen: price - 1, indexHigh: price + 2,
                indexLow: price - 2, indexClose: price)
            context.insert(market)
            // Persistence sentinels only; this fixture does not claim a fully
            // calculated market row or run any market/strategy calculation.
            market.technicalStateVersion = MarketDataStore.technicalStateVersion
            market.kdK = Double(40 + index)
            market.indexHighMax9 = price + 10
        }
        try context.save()
    }

    private func load(in context: ModelContext) throws -> ([Stock], [[Trade]], [MarketDay]) {
        let stocks = try context.fetch(FetchDescriptor<Stock>(sortBy: [SortDescriptor(\.sId)]))
        let rows = try stocks.map { try Trade.fetch(in: context, for: $0, ascending: true) }
        let markets = try context.fetch(FetchDescriptor<MarketDay>(sortBy: [SortDescriptor(\.dateTime)]))
        return (stocks, rows, markets)
    }

    /// Only scalar/owner getters: no query, calculationWindow, or relationship
    /// collection is read here, so this cannot hide a failed model refresh.
    private func assertOriginalScalars(stocks: [Stock], rows: [[Trade]], markets: [MarketDay],
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(stocks.count, 2, file: file, line: line)
        XCTAssertEqual(rows.count, 2, file: file, line: line)
        XCTAssertEqual(markets.count, 2, file: file, line: line)
        guard stocks.count == 2, rows.count == 2, markets.count == 2 else { return }
        for index in stocks.indices {
            let stock = stocks[index]
            XCTAssertEqual(stock.sId, stockIDs[index], file: file, line: line)
            XCTAssertEqual(stock.group, index == 0 ? "A" : "B", file: file, line: line)
            XCTAssertEqual(stock.dateStart, day("2024/06/15"), file: file, line: line)
            XCTAssertEqual(stock.dateFirst, day("2020/01/01"), file: file, line: line)
            XCTAssertEqual(stock.simMoneyBase, 100_000, file: file, line: line)
            XCTAssertEqual(stock.simInvestAuto, 2, file: file, line: line)
            XCTAssertTrue(stock.simReversed, file: file, line: line)
            XCTAssertEqual(stock.simInvestUser, 1, file: file, line: line)
            XCTAssertEqual(stock.simInvestExceed, 2, file: file, line: line)
            XCTAssertTrue(stock.simMoneyLacked, file: file, line: line)
            XCTAssertEqual(stock.technicalDirtyFrom, day("2024/07/02"), file: file, line: line)
            XCTAssertEqual(stock.simulationDirtyFrom, day("2024/07/03"), file: file, line: line)
            XCTAssertNil(stock.technicalPendingWork, file: file, line: line)
            XCTAssertEqual(stock.technicalStateVersion,
                Int(Technical.technicalRuleVersion.dropFirst())!, file: file, line: line)
            XCTAssertEqual(stock.simulationStateVersion,
                Int(Technical.simulationRuleVersion.dropFirst())!, file: file, line: line)
            XCTAssertEqual(rows[index].count, tradeDays.count, file: file, line: line)
            guard rows[index].count == tradeDays.count else { continue }
            for (offset, row) in rows[index].enumerated() {
                let price = Double(100 + index * 10 + offset)
                XCTAssertTrue(row.stock === stock, file: file, line: line)
                XCTAssertFalse(row.isDeleted, file: file, line: line)
                XCTAssertEqual(row.dateTime, twDateTime.time1330(day(tradeDays[offset])), file: file, line: line)
                XCTAssertEqual(row.dataSource, "TWSE", file: file, line: line)
                XCTAssertEqual(row.priceOpen, price - 1, file: file, line: line)
                XCTAssertEqual(row.priceHigh, price + 2, file: file, line: line)
                XCTAssertEqual(row.priceLow, price - 2, file: file, line: line)
                XCTAssertEqual(row.priceClose, price, file: file, line: line)
                XCTAssertEqual(row.volumeClose, Double(1_000 + offset), file: file, line: line)
                let hasAction = offset == tradeDays.count - 1
                XCTAssertEqual(row.simReversed, hasAction ? (index == 0 ? "S+" : "B+") : "",
                    file: file, line: line)
                let investment: Double = hasAction ? (index == 0 ? 1 : -1) : 0
                XCTAssertEqual(row.simInvestByUser, investment, file: file, line: line)
            }
        }
        for (index, market) in markets.enumerated() {
            let price = Double(20_000 + index * 100)
            XCTAssertEqual(market.dateTime, twDateTime.time1330(day(marketDays[index])), file: file, line: line)
            XCTAssertEqual(market.dataSource, "TWSE-MI_5MINS_HIST", file: file, line: line)
            XCTAssertNil(market.quoteTime, file: file, line: line)
            XCTAssertEqual(market.indexOpen, price - 1, file: file, line: line)
            XCTAssertEqual(market.indexHigh, price + 2, file: file, line: line)
            XCTAssertEqual(market.indexLow, price - 2, file: file, line: line)
            XCTAssertEqual(market.indexClose, price, file: file, line: line)
            XCTAssertEqual(market.technicalStateVersion, MarketDataStore.technicalStateVersion, file: file, line: line)
            XCTAssertEqual(market.kdK, Double(40 + index), file: file, line: line)
            XCTAssertEqual(market.indexHighMax9, price + 10, file: file, line: line)
        }
    }

    func testRejectedMixedSaveRestoresOriginalStocksManualIntentAndMarketModels() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixedRollback-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        try autoreleasepool {
            let writable = try makeContainer(at: url, allowsSave: true)
            try seed(in: writable.mainContext)
            withExtendedLifetime(writable) {}
        }
        let storedBytes = try databaseBytes(at: url)

        try autoreleasepool {
            let readOnly = try makeContainer(at: url, allowsSave: false)
            let context = readOnly.mainContext
            let (stocks, rows, markets) = try load(in: context)
            assertOriginalScalars(stocks: stocks, rows: rows, markets: markets)
            let leaving = try XCTUnwrap(stocks.first)
            let moving = try XCTUnwrap(stocks.last)
            let originalWindows = stocks.map(\.calculationWindow)
            let originalTradeIDs = rows.flatMap { $0.map(\.persistentModelID) }

            try StockHistory.changeGroup(leaving, to: "", start: day("2025/06/15"),
                money: 200_000, investments: 3, in: context)
            try StockHistory.changeGroup(moving, to: "C", start: day("2025/06/15"),
                money: 200_000, investments: 3, in: context)
            XCTAssertEqual(leaving.group, "")
            XCTAssertFalse(leaving.simReversed)
            XCTAssertEqual(leaving.simInvestUser, 0)
            XCTAssertTrue(rows[0].allSatisfy { $0.simReversed.isEmpty && $0.simInvestByUser == 0 })
            XCTAssertEqual(leaving.technicalDirtyFrom, .distantPast)
            XCTAssertEqual(leaving.simulationDirtyFrom, .distantPast)
            XCTAssertEqual(moving.group, "C")
            XCTAssertEqual(moving.dateStart, day("2024/06/15"), "A direct group move preserves settings")
            XCTAssertTrue(moving.simReversed)
            XCTAssertEqual(moving.simInvestUser, 1)
            XCTAssertEqual(rows[1].last?.simReversed, "B+")
            XCTAssertEqual(rows[1].last?.simInvestByUser, -1)

            // A separate pending date edit in the same rejected transaction
            // exercises restoration of Stock's date and cached window too.
            moving.dateStart = day("2025/06/15")
            moving.invalidateCalculationWindow()
            XCTAssertNotEqual(moving.calculationWindow, originalWindows[1])
            for (index, market) in markets.enumerated() {
                market.indexClose = Double(21_000 + index)
                market.technicalStateVersion = -1
                market.kdK = Double(80 + index)
                market.indexHighMax9 = Double(22_000 + index)
            }
            XCTAssertTrue(context.hasChanges)
            var saveFailure: Error?
            do { try context.save() } catch { saveFailure = error }
            guard let saveFailure else {
                XCTFail("The real read-only store did not reject this mixed save")
                return
            }
            let failure = saveFailure as NSError
            print("MIXED_ROLLBACK_SAVE_FAILURE domain=\(failure.domain) code=\(failure.code)")
            XCTAssertTrue(context.hasChanges)

            try ModelRollback.restore(in: context)
            XCTAssertFalse(context.hasChanges)
            // Keep these original-reference assertions before any fetch or
            // window read; a verification fetch must not repair a failing test.
            assertOriginalScalars(stocks: stocks, rows: rows, markets: markets)
            XCTAssertEqual(stocks.map(\.calculationWindow), originalWindows)
            XCTAssertEqual(rows.flatMap { $0.map(\.persistentModelID) }, originalTradeIDs)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Trade>()), 6)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Stock>()), 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MarketDay>()), 2)

            let verification = ModelContext(readOnly)
            verification.autosaveEnabled = false
            let reopened = try load(in: verification)
            assertOriginalScalars(stocks: reopened.0, rows: reopened.1, markets: reopened.2)
            XCTAssertEqual(reopened.0.map(\.calculationWindow), originalWindows)
            XCTAssertFalse(verification.hasChanges)
            withExtendedLifetime(readOnly) {}
        }
        XCTAssertEqual(try databaseBytes(at: url), storedBytes,
            "The rejected save and rollback must preserve this fixture's SQLite and WAL bytes")
    }

    /// SHM is connection-lock state; compare only persistent SQLite/WAL bytes.
    private func databaseBytes(at url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for suffix in ["", "-wal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                result[suffix] = try Data(contentsOf: file)
            }
        }
        return result
    }
}
