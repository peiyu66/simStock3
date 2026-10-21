import CryptoKit
import SwiftData
import XCTest
@testable import simStock3

/// Opt-in local evidence check. Retained diagnostic stores are never committed
/// or opened for writing; each run creates new isolated copies. Ordinary CI
/// skips this one test when the preserved P5 evidence is not installed.
@MainActor
final class RetainedStatisticCounterexampleTests: XCTestCase {
    func testHanxiangStoredStatisticsRepairAndDependentSimulationReplay() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("exports/update-cycle-statistic-repair")
        let inputs = root.appendingPathComponent("inputs")
        guard FileManager.default.fileExists(atPath: inputs.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Requires explicitly prepared, retained P5 diagnostic copies")
        }
        let output = root.appendingPathComponent("hanxiang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func hash(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        let market = inputs.appendingPathComponent("market-daily.csv")
        XCTAssertEqual(try hash(market), InternalMarketLow9Input.dailySHA)
        let marketDestination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InternalBacktest/Research/Market/market-daily.csv")
        if FileManager.default.fileExists(atPath: marketDestination.path) {
            XCTAssertEqual(try hash(marketDestination), InternalMarketLow9Input.dailySHA)
        } else {
            try FileManager.default.createDirectory(at: marketDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: market, to: marketDestination)
        }
        let lookup = try InternalMarketLow9Input.loadCurrentMarketLookup()
        let targetDate = twDateTime.time1330(twDateTime.dateFromString("2020/02/24")!)
        let end = twDateTime.time1330(twDateTime.dateFromString("2020/07/21")!)
        let fields = Set(OrdinaryTechnicalStatistic.derivedFields.map(\.rawValue))
        var summaries: [String: Any] = [:]
        var simulations: [String: [Date: [String: [String: InternalMaturityProbe.Value]]]] = [:]
        for arm in ["cold", "batched"] {
            try autoreleasepool {
                let source = inputs.appendingPathComponent(arm + ".store")
                let sourceHash = try hash(source)
                let copy = output.appendingPathComponent(arm + ".store")
                try FileManager.default.copyItem(at: source, to: copy)
                let schema = Schema([Stock.self, Trade.self])
                let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
                    url: copy, allowsSave: true, cloudKitDatabase: .none)])
                defer { withExtendedLifetime(container) {} }
                let context = ModelContext(container); context.autosaveEnabled = false
                let stockID = "2634"
                let stock = try XCTUnwrap(context.fetch(FetchDescriptor<Stock>(predicate: #Predicate { $0.sId == stockID })).first)
                let technical = Technical(modelContext: context, marketPricePathLookup: lookup)
                let rows = try Trade.fetchCalculationWindow(in: context, for: stock)
                let raw = rows.map(InternalMaturityProbe.Raw.init)
                let before = rows.map(InternalMaturityProbe.technicalValues)
                let first = try XCTUnwrap(rows.first)
                let target = try XCTUnwrap(rows.first { $0.dateTime == targetDate })
                let oldZ = target.tOscZ250, oldBuy = target.simQtyBuy
                XCTAssertEqual(oldBuy, arm == "cold" ? 0 : 189)
                let statistics = Dictionary(uniqueKeysWithValues: OrdinaryTechnicalStatistic.derivedFields.map {
                    ($0, rows.dropFirst().map(\.dateTime))
                })
                let work = TechnicalReplayWork(version: 4, configuredStart: stock.dateStart,
                    ordinary: [], pricePath: [], allDates: rows.map(\.dateTime), statistics: statistics)
                let trace = try technical.recalculate(stock: stock,
                    plan: .init(technical: .from(first.dateTime), simulation: .none,
                                simulationEnd: end, technicalWork: work))
                XCTAssertTrue(trace.ordinaryTechnicalDates.isEmpty)
                XCTAssertTrue(trace.pricePathDates.isEmpty)
                XCTAssertNil(trace.simulationDependencyIssue)
                XCTAssertNil(trace.blockedSimulationDate)
                XCTAssertEqual(rows.map(InternalMaturityProbe.Raw.init), raw)
                var changed: [String: Int] = [:]
                for (index, row) in rows.enumerated() {
                    let after = InternalMaturityProbe.technicalValues(row)
                    XCTAssertEqual(after["path"], before[index]["path"])
                    for (name, _) in InternalMaturityProbe.ordinaryFields {
                        if after["ordinary"]?[name] != before[index]["ordinary"]?[name] {
                            changed[name, default: 0] += 1
                            XCTAssertTrue(fields.contains(name), "Unexpected core write: \(name)")
                        }
                    }
                    if index > 0 {
                        let inputs = Array(rows[max(0, index - 249)...index]).map(\.tOsc)
                        let avg = inputs.reduce(0, +) / Double(inputs.count)
                        let sd = sqrt(inputs.reduce(0) { $0 + pow($1 - avg, 2) } / Double(inputs.count))
                        XCTAssertEqual(row.tOscZ250, sd == 0 ? 0 : (row.tOsc - avg) / sd)
                    }
                }
                if arm == "cold" { XCTAssertTrue(changed.isEmpty, "Shared formulas must preserve every cold-arm T value") }
                let simulated = rows.filter { !$0.isBeforeSimulationStart && $0.dateTime <= end }
                XCTAssertEqual(trace.simulationDates, simulated.map(\.dateTime))
                XCTAssertEqual(simulated.count, 733)
                XCTAssertNil(stock.technicalDirtyFrom); XCTAssertNil(stock.technicalPendingWork)
                XCTAssertEqual(stock.simulationDirtyFrom, rows.first { $0.dateTime > end }?.dateTime)
                simulations[arm] = try Dictionary(uniqueKeysWithValues: simulated.map { row in
                    try autoreleasepool { (row.dateTime, try InternalMaturityProbe.simulationValues(row)) }
                })
                summaries[arm] = ["beforeZ250": oldZ, "afterZ250": target.tOscZ250,
                    "beforeBuy": oldBuy, "afterBuy": target.simQtyBuy, "afterInventory": target.simQtyInventory,
                    "coreTWritten": trace.ordinaryTechnicalDates.count, "pathWritten": trace.pricePathDates.count,
                    "statisticDatesWritten": trace.ordinaryStatisticWrites.count,
                    "simulationDatesWritten": trace.simulationDates.count, "changedTFields": changed,
                    "remainingSDirty": stock.simulationDirtyFrom?.timeIntervalSinceReferenceDate as Any,
                    "sourceSHA256": sourceHash]
                XCTAssertEqual(try hash(source), sourceHash)
            }
        }
        let cold = try XCTUnwrap(simulations["cold"]), batched = try XCTUnwrap(simulations["batched"])
        let differences = cold.keys.sorted().flatMap { date in
            InternalMaturityProbe.compare(date: date, cold: cold[date]!, batched: batched[date]!)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(differences).write(to: output.appendingPathComponent("simulation-differences.json"))
        summaries["simulationDifferentDates"] = Set(differences.map(\.date)).count
        summaries["scope"] = "2634 retained first fixed window only; unchanged formulas and core T; no strategy validation"
        try JSONSerialization.data(withJSONObject: summaries, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("result.json"))
        print("RETAINED_STATISTIC_REPAIR \(output.path) \(summaries)")
        XCTAssertEqual(cold[targetDate]?["transaction"]?["simQtyBuy"], batched[targetDate]?["transaction"]?["simQtyBuy"])
    }
}
