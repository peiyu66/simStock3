import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import simStock3

/// Opt-in integration check. Stage only a disposable, frozen normal-store copy
/// in the isolated test host's Documents/ReleaseMigration directory.
@MainActor
final class NormalStoreMigrationTests: XCTestCase {
    func testFrozenNormalStoreCopyMigratesAndReopensWithoutLosingUserIntent() async throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReleaseMigration", isDirectory: true)
        let input = directory.appendingPathComponent("s63-normal.store")
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw XCTSkip("No opt-in frozen normal-store copy staged in this isolated test host")
        }
        let output = directory.appendingPathComponent("s64-migrated.store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "Preserve prior results; use a fresh staging directory")
        try FileManager.default.copyItem(at: input, to: output)
        let inputHash = SHA256.hash(data: try Data(contentsOf: input))
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        var stockCount = 0
        var intentCount = 0
        var simulationRows = 0
        var retained = 0
        do {
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, url: output))
            let context = container.mainContext
            let stocks = try Stock.fetchGrouped(in: context).sorted { $0.sId < $1.sId }
            stockCount = stocks.count
            XCTAssertGreaterThan(stockCount, 0)
            XCTAssertTrue(stocks.allSatisfy { $0.technicalStateVersion == 3 && $0.simulationStateVersion == 63 })
            let technical = Technical(modelContext: context)
            for stock in stocks {
                let rows = try Trade.fetch(in: context, for: stock, ascending: true)
                let intentions = rows.filter { !$0.simReversed.isEmpty || $0.simInvestByUser != 0 }
                    .map { ($0.dateTime, $0.simReversed, $0.simInvestByUser) }
                intentCount += intentions.count
                let actions = try await technical.recoverOrMigrateRecalculationState(for: stock)
                simulationRows += technical.lastRecalculationTrace.simulationDates.count
                retained += actions.retained
                XCTAssertTrue(technical.lastRecalculationTrace.technicalDates.isEmpty)
                XCTAssertEqual("S\(stock.simulationStateVersion)", Technical.simulationRuleVersion)
                XCTAssertNil(stock.technicalDirtyFrom)
                XCTAssertNil(stock.simulationDirtyFrom)
                XCTAssertEqual(actions.clearedInvalid, 0)
                XCTAssertEqual(actions.clearedRedundant, 0)
                for (date, reversal, amount) in intentions {
                    let trade = try XCTUnwrap(rows.first { $0.dateTime == date })
                    XCTAssertEqual(trade.simReversed, reversal)
                    XCTAssertEqual(trade.simInvestByUser, amount)
                }
            }
            technical.invalidateTimer()
            try context.save()
            withExtendedLifetime(container) {}
        }
        do {
            let reopened = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, url: output))
            let stocks = try Stock.fetchGrouped(in: reopened.mainContext)
            XCTAssertEqual(stocks.count, stockCount)
            XCTAssertTrue(stocks.allSatisfy {
                $0.technicalStateVersion == 3 && "S\($0.simulationStateVersion)" == Technical.simulationRuleVersion
                    && $0.technicalDirtyFrom == nil && $0.simulationDirtyFrom == nil
            })
            let savedIntentCount = try stocks.reduce(0) { total, stock in
                total + (try Trade.fetch(in: reopened.mainContext, for: stock))
                    .filter { !$0.simReversed.isEmpty || $0.simInvestByUser != 0 }.count
            }
            XCTAssertEqual(savedIntentCount, intentCount)
            withExtendedLifetime(reopened) {}
        }
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: input)), inputHash)
        let summary: [String: Any] = ["stocks": stockCount, "manualIntentRows": intentCount,
            "retainedActions": retained, "simulationRows": simulationRows,
            "technicalRowsReplayed": 0, "dataRules": Technical.dataRuleVersion,
            "inputUnchanged": true, "reopenedSuccessfully": true]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("migration-summary.json"))
    }
}
