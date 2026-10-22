import CryptoKit
import SwiftData
import XCTest
@testable import simStock3

/// Reuse the preserved failing input; never open the source stores for writes.
@MainActor
final class RetainedHistoryCompletionTests: XCTestCase {
    func testHanxiangCompletionConvergesAllTAndTargetSimulationToColdReference() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("exports/update-cycle-statistic-repair")
        let inputs = root.appendingPathComponent("inputs")
        guard FileManager.default.fileExists(atPath: inputs.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Requires retained P5 diagnostic copies")
        }
        let output = root.appendingPathComponent("history-completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func hash(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        let market = inputs.appendingPathComponent("market-daily.csv")
        XCTAssertEqual(try hash(market), InternalMarketLow9Input.dailySHA)
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InternalBacktest/Research/Market/market-daily.csv")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: market, to: destination)
        }
        XCTAssertEqual(try hash(destination), InternalMarketLow9Input.dailySHA)
        let lookup = try InternalMarketLow9Input.loadCurrentMarketLookup()
        let end = twDateTime.time1330(twDateTime.dateFromString("2020/07/21")!)
        let target = twDateTime.time1330(twDateTime.dateFromString("2020/02/24")!)
        var rawReference: [InternalMaturityProbe.Raw] = []
        var tReference: [[String: [String: InternalMaturityProbe.Value]]] = []
        var sReference: [[String: [String: InternalMaturityProbe.Value]]] = []
        var summary: [String: Any] = [:]
        for arm in ["cold", "batched"] {
            try autoreleasepool {
                let source = inputs.appendingPathComponent(arm + ".store")
                let sourceHash = try hash(source)
                let copy = output.appendingPathComponent(arm + ".store")
                try FileManager.default.copyItem(at: source, to: copy)
                let schema = Schema([Stock.self, Trade.self])
                let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: copy))
                defer { withExtendedLifetime(container) {} }
                let context = ModelContext(container); context.autosaveEnabled = false
                let stockID = "2634"
                let stock = try XCTUnwrap(context.fetch(FetchDescriptor<Stock>(predicate: #Predicate { $0.sId == stockID })).first)
                let rows = try Trade.fetchCalculationWindow(in: context, for: stock)
                let simulated = rows.filter { !$0.isBeforeSimulationStart && $0.dateTime <= end }
                if arm == "cold" {
                    rawReference = rows.map(InternalMaturityProbe.Raw.init)
                    tReference = rows.map(InternalMaturityProbe.technicalValues)
                    sReference = try simulated.map(InternalMaturityProbe.simulationValues)
                } else {
                    XCTAssertEqual(rows.map(InternalMaturityProbe.Raw.init), rawReference)
                    let previousBuy = rows.first { $0.dateTime == target }!.simQtyBuy
                    XCTAssertEqual(previousBuy, 189)
                    let last = try XCTUnwrap(rows.last).dateTime
                    // Explicit completion event for the immutable, already
                    // audited input fixture; production must obtain receipts.
                    for month in stock.unconfirmedHistoryMonths(through: last) {
                        let next = twDateTime.calendar.date(byAdding: .month, value: 1, to: month)!
                        try stock.confirmHistoryMonth(month, through: min(next.addingTimeInterval(-1), twDateTime.endOfDay(last)))
                    }
                    let technical = Technical(modelContext: context, marketPricePathLookup: lookup)
                    let trace = try technical.recalculate(stock: stock,
                        plan: .init(technical: .none, simulation: .none, simulationEnd: end))
                    XCTAssertEqual(trace.ordinaryTechnicalDates, rows.map(\.dateTime))
                    XCTAssertEqual(trace.simulationDates, simulated.map(\.dateTime))
                    XCTAssertEqual(rows.map(InternalMaturityProbe.technicalValues), tReference)
                    XCTAssertEqual(try simulated.map(InternalMaturityProbe.simulationValues), sReference)
                    XCTAssertEqual(rows.map(InternalMaturityProbe.Raw.init), rawReference)
                    XCTAssertEqual(rows.first { $0.dateTime == target }?.simQtyBuy, 0)
                    XCTAssertNil(stock.technicalDirtyFrom)
                    XCTAssertNotNil(stock.savedRollingOrigin)
                    XCTAssertEqual(stock.simulationDirtyFrom, rows.first { $0.dateTime > end }?.dateTime)
                    summary = ["technicalRows": rows.count, "ordinaryFieldCount": InternalMaturityProbe.ordinaryFields.count,
                        "simulationRows": simulated.count, "ordinaryDifferences": 0, "simulationDifferences": 0,
                        "beforeBuy": previousBuy, "afterBuy": rows.first { $0.dateTime == target }!.simQtyBuy,
                        "completeScope": "T all visible rows; S retained first fixed window only; not full P5 or E1"]
                }
                XCTAssertEqual(try hash(source), sourceHash)
                summary[arm + "SourceSHA256"] = sourceHash
            }
        }
        try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("result.json"))
        print("RETAINED_HISTORY_COMPLETION \(output.path) \(summary)")
    }
}
