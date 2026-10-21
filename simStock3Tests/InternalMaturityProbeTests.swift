import Foundation
import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class InternalMaturityProbeTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let base: URL
        let cold: URL
        let marketContainer: ModelContainer
        let lookup: MarketPricePathLookup
        let trace: RecalculationTrace
    }
    private func date(_ index: Int) -> Date {
        let first = twDateTime.dateFromString("2024/01/02")!
        let days = index < 260 ? index * 366 / 260 : 366 + index - 260
        return twDateTime.time1330(twDateTime.calendar.date(byAdding: .day, value: days, to: first)!)
    }
    private func container(_ url: URL) throws -> ModelContainer {
        let schema = Schema([Stock.self, Trade.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            url: url, allowsSave: true, cloudKitDatabase: .none)])
    }
    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent("base.store")
        let cold = directory.appendingPathComponent("cold.store")
        let marketContainer = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try RecalculationMarketFixture.seed(dates: (0..<600).map(date), in: marketContainer.mainContext)
        let lookup = try MarketPricePathLookup(modelContext: marketContainer.mainContext)
        do {
            let store = try container(base)
            let context = ModelContext(store); context.autosaveEnabled = false
            let stock = Stock(sId: "MATURITY", sName: "分批", group: "測試", dateFirst: date(0),
                dateStart: date(260), simInvestAuto: 2, simMoneyBase: 100)
            context.insert(stock)
            for index in -1..<600 {
                let day = index == -1
                    ? twDateTime.calendar.date(byAdding: .month, value: -1, to: date(0))! : date(index)
                let row = Trade(stock: stock, dateTime: day)
                let close = 90 + sin(Double(index) / 12) * 16 + Double(index) * 0.025
                row.priceOpen = close; row.priceHigh = close + 1; row.priceLow = close - 1
                row.priceClose = close; row.volumeClose = 1_000 + Double((index + 1) % 83)
                row.dataSource = "TWSE"; context.insert(row)
            }
            try context.save()
            let technical = Technical(modelContext: context, marketPricePathLookup: lookup)
            let trace = try technical.recalculate(stock: stock,
                plan: .init(technical: .all, simulation: .none, deferSimulation: true))
            XCTAssertEqual(trace.ordinaryTechnicalDates, (0..<600).map(date))
            XCTAssertTrue(trace.simulationDates.isEmpty)
            XCTAssertNotNil(stock.simulationDirtyFrom)
            try context.save()
            withExtendedLifetime(store) {}
        }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: base.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: cold.path + suffix))
            }
        }
        let trace: RecalculationTrace
        do {
            let store = try container(cold)
            let context = ModelContext(store); context.autosaveEnabled = false
            let stock = try XCTUnwrap(Stock.fetchAll(in: context).first)
            let technical = Technical(modelContext: context, marketPricePathLookup: lookup)
            let result = try InternalPeriodReplay.replay(stock: stock, start: date(260), end: date(450),
                money: 100, investments: 2, technical: technical, in: context)
            trace = result.trace
            XCTAssertTrue(trace.technicalDates.isEmpty)
            XCTAssertEqual(trace.simulationDates, (260...450).map(date))
            XCTAssertEqual(stock.simulationDirtyFrom, date(451))
            XCTAssertEqual(stock.simulationStateVersion, 0)
            withExtendedLifetime(store) {}
        }
        return .init(directory: directory, base: base, cold: cold, marketContainer: marketContainer, lookup: lookup, trace: trace)
    }
    private func run(_ fixture: Fixture, traces: [String: RecalculationTrace]? = nil) throws -> InternalMaturityProbe.Report {
        try InternalMaturityProbe.run(technicalBaseURL: fixture.base, coldStoreURL: fixture.cold,
            outputURL: fixture.directory.appendingPathComponent("MaturityProbe"), start: date(260), end: date(450),
            money: 100, investments: 2, marketLookup: fixture.lookup,
            ruleCommit: String(repeating: "a", count: 40), expectedStockIDs: ["MATURITY"],
            coldTraces: traces ?? ["MATURITY": fixture.trace])
    }

    func testActivationRequiresExplicitDiagnosticAFirstFixedWindowAndDedicatedID() throws {
        try InternalMaturityProbe.validateActivation(diagnostic: true, sample: "A", fullWindow: false, identifier: "p5-maturity-01")
        for (diagnostic, sample, full, id) in [(false, "A", false, "p5-maturity-01"),
            (true, "B", false, "p5-maturity-01"), (true, "A", true, "p5-maturity-01"),
            (true, "A", false, "ordinary-p5"), (true, "A", false, "p5-maturity-../x")] {
            XCTAssertThrowsError(try InternalMaturityProbe.validateActivation(diagnostic: diagnostic,
                sample: sample, fullWindow: full, identifier: id))
        }
        XCTAssertThrowsError(try InternalMaturityProbe.validateActivation(diagnostic: true,
            sample: "A", fullWindow: false, identifier: nil))
    }

    func testSixCalendarMonthBatchesPartitionOnlyWindowRawWithoutUsingToday() throws {
        let stock = Stock(sId: "PARTITION", sName: "切批", group: "測試", dateFirst: date(0), dateStart: date(260))
        let dates = ["2023/12/31", "2024/01/02", "2024/03/31", "2024/04/01", "2024/09/30"]
            .map { twDateTime.time1330(twDateTime.dateFromString($0)!) }
        let raw = dates.map { day in
            let trade = Trade(stock: stock, dateTime: day); trade.priceClose = 100
            return InternalMaturityProbe.Raw(trade)
        }
        let lower = twDateTime.dateFromString("2024/01/02")!
        let invalidFuture = Trade(stock: stock, dateTime: twDateTime.dateFromString("2028/01/01")!)
        invalidFuture.priceClose = 0
        let batches = InternalMaturityProbe.batches(raw: raw + [InternalMaturityProbe.Raw(invalidFuture)], requestStart: lower)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].lower, twDateTime.startOfDay(twDateTime.dateFromString("2024/04/01")!))
        XCTAssertEqual(batches[0].upperExclusive, twDateTime.startOfDay(twDateTime.dateFromString("2024/10/01")!))
        XCTAssertEqual(batches[0].raw.map(\.date), Array(dates.suffix(2)))
        XCTAssertEqual(batches.flatMap(\.raw).map(\.date).sorted(), Array(dates.dropFirst()))
        XCTAssertEqual(Set(batches.flatMap(\.raw).map(\.date)).count, 4)
        XCTAssertEqual(batches.last?.lower, lower)
    }

    func testRawOnlyBatchedReplayPreservesSourcesFutureDirtyAndComparesAllRequiredFields() async throws {
        let f = try fixture()
        // SwiftData closes SQLite asynchronously. Keep the UUID fixture until the test process exits.
        defer { withExtendedLifetime(f.marketContainer) {} }
        let baseSHA = try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: f.base)
        let coldSHA = try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: f.cold)
        let report = try run(f)
        XCTAssertTrue(report.comparisonCompleted)
        XCTAssertTrue(report.boundedPathIdentical)
        XCTAssertFalse(report.formalStrategy)
        XCTAssertFalse(report.formalBaseline)
        XCTAssertEqual(report.ordinaryFieldNames.count, 65)
        XCTAssertEqual(Set(report.ordinaryFieldNames).count, 65)
        XCTAssertEqual(report.pathFieldNames.count, 5)
        let stock = try XCTUnwrap(report.stocks.first)
        XCTAssertEqual(stock.allRawCount, 601)
        XCTAssertEqual(stock.retainedOutsideWindowCount, 1)
        XCTAssertEqual(stock.technicalComparisonCount, 600)
        XCTAssertEqual(stock.simulationComparisonCount, 191)
        XCTAssertEqual(stock.pathChangedRows, 0)
        XCTAssertGreaterThan(stock.ordinaryChangedRows, 0,
            "This oscillator fixture must expose maturity formation differences rather than accidentally comparing two cold replays")
        XCTAssertEqual(stock.remainingSimulationDirtyFrom, date(451))
        XCTAssertEqual(stock.wholeStockSimulationVersion, 0)
        XCTAssertEqual(try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: f.base), baseSHA)
        XCTAssertEqual(try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: f.cold), coldSHA)
        let probe = f.directory.appendingPathComponent("MaturityProbe")
        let traces = try JSONDecoder().decode([InternalMaturityProbe.BatchTrace].self,
            from: Data(contentsOf: probe.appendingPathComponent("MATURITY/batches.json")))
        XCTAssertGreaterThan(traces.count, 2)
        XCTAssertTrue(traces.allSatisfy { $0.simulationDates.isEmpty && $0.technicalDirtyFrom == nil && $0.simulationDirtyFrom != nil })
        XCTAssertEqual(traces.flatMap(\.insertedDates).sorted(), (0..<600).map(date))
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.appendingPathComponent(".complete").path))
        // Reopening the saved arm must retain raw beyond the period and its S
        // pending boundary. Completion is scoped to the target, never the store.
        let reopened = try container(probe.appendingPathComponent("batched.store"))
        let context = ModelContext(reopened)
        let persisted = try XCTUnwrap(Stock.fetchAll(in: context).first)
        XCTAssertEqual(persisted.simulationDirtyFrom, date(451))
        XCTAssertEqual(try Trade.fetch(in: context, for: persisted).count, 601)
        XCTAssertEqual(try Trade.last(in: context, for: persisted)?.dateTime, date(599))
        let firstVisible = try XCTUnwrap(Trade.fetchCalculationWindow(in: context, for: persisted).first)
        XCTAssertEqual(firstVisible.dateTime, date(0))
        XCTAssertEqual(firstVisible.tKdK, 50, "Retained outside-W raw must not seed initialization")
        withExtendedLifetime(reopened) {}
    }

    func testMissingColdTraceCannotMasqueradeAsCompletedComparison() async throws {
        let f = try fixture()
        // SwiftData closes SQLite asynchronously. Keep the UUID fixture until the test process exits.
        defer { withExtendedLifetime(f.marketContainer) {} }
        var incomplete = f.trace
        incomplete.simulationDates.removeLast()
        XCTAssertThrowsError(try run(f, traces: ["MATURITY": incomplete])) { error in
            XCTAssertTrue(error.localizedDescription.contains("未完整寫入 S"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("MaturityProbe/.complete").path))
    }

    func testTargetWarningPayloadAndDecisionDifferencesBypassOnlyWholeStockDisplayGate() async throws {
        let f = try fixture()
        // SwiftData closes SQLite asynchronously. Keep the UUID fixture until the test process exits.
        defer { withExtendedLifetime(f.marketContainer) {} }
        let store = try container(f.cold)
        let context = ModelContext(store); context.autosaveEnabled = false
        let stock = try XCTUnwrap(Stock.fetchAll(in: context).first)
        let row = try XCTUnwrap(Trade.fetch(in: context, for: stock).first { $0.dateTime == date(450) })
        XCTAssertEqual(stock.simulationStateVersion, 0)
        XCTAssertNotNil(AnnualWarningPersistence.decode(row), "Target payload is valid despite future S dirty")
        let before = try InternalMaturityProbe.simulationValues(row)
        row.simQtyBuy += 1
        row.rollAmtProfit += 123
        row.simFitTrendPhaseRaw += 1
        let after = try InternalMaturityProbe.simulationValues(row)
        let differences = InternalMaturityProbe.compare(date: row.dateTime, cold: before, batched: after)
        XCTAssertTrue(differences.contains { $0.group == "transaction" && $0.field == "simQtyBuy" })
        XCTAssertTrue(differences.contains { $0.group == "account" && $0.field == "rollAmtProfit" })
        XCTAssertTrue(differences.contains { $0.group == "grade" && $0.field == "simFitTrendPhaseRaw" })
        row.simAnnualWarningData = nil
        XCTAssertThrowsError(try InternalMaturityProbe.simulationValues(row), "Missing warning must not become two unavailable values that falsely compare equal")
        withExtendedLifetime(store) {}
    }
}
