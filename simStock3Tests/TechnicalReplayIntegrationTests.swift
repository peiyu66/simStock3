import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class TechnicalReplayIntegrationTests: XCTestCase {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let stock: Stock
        let technical: Technical
    }
    private enum SaveFailure: Error { case injected }
    private func date(_ index: Int) -> Date {
        let origin = twDateTime.dateFromString("2024/01/01")!
        let days = index < 260 ? index * 366 / 260 : 366 + index - 260
        return twDateTime.time1330(twDateTime.calendar.date(byAdding: .day, value: days, to: origin)!)
    }
    private func container(_ url: URL?) throws -> ModelContainer {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
    private func fixture(first: Int = 10, count: Int = 320, url: URL? = nil) throws -> Fixture {
        let container = try container(url)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let dates = (first..<count).map(date)
        if CalculationWindow(configuredStart: date(260),
            prices: dates.map { (date: $0, close: 100.0) }).hasSimulationDates {
            try RecalculationMarketFixture.seed(dates: dates, in: context)
        }
        let stock = Stock(sId: "P2", sName: "分段待辦", group: "測試", dateFirst: date(0),
                          dateStart: date(260), simInvestAuto: 2, simMoneyBase: 100)
        context.insert(stock)
        for index in first..<count { insert(index, stock: stock, context: context) }
        let technical = Technical(modelContext: context)
        _ = try technical.recalculate(stock: stock, plan: .init(technical: .all, simulation: .all))
        return Fixture(container: container, context: context, stock: stock, technical: technical)
    }
    private func reopen(_ url: URL) throws -> Fixture {
        let container = try container(url)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stock = try XCTUnwrap(Stock.fetch(in: context).first)
        return Fixture(container: container, context: context, stock: stock, technical: Technical(modelContext: context))
    }
    @discardableResult
    private func insert(_ index: Int, stock: Stock, context: ModelContext) -> Trade {
        let row = Trade(stock: stock, dateTime: date(index))
        let close = 70 + Double(index) * 0.08 + Double((index * 17) % 23) / 10
        row.priceClose = close; row.priceOpen = close - 0.4
        row.priceHigh = close + 1.1; row.priceLow = close - 1.3
        row.volumeClose = 800 + Double((index * 37) % 500); row.dataSource = "TWSE"
        context.insert(row)
        return row
    }

    /// Market writers save and read every grouped stock. Complete the whole
    /// test batch's market input before inserting any unsaved Trade relation,
    /// including backfill rows followed by an append in the same batch.
    private func prepareMarket(_ indices: [Int], for fixture: Fixture) throws {
        try RecalculationMarketFixture.seed(dates: indices.map(date), in: fixture.context)
    }
    private func rows(_ fixture: Fixture) throws -> [Trade] {
        try Trade.fetchCalculationWindow(in: fixture.context, for: fixture.stock)
    }
    private var ordinaryFields: [(String, KeyPath<Trade, Double>)] { [
            ("tHighDiff", \Trade.tHighDiff),
            ("tHighDiff125", \Trade.tHighDiff125),
            ("tHighDiff250", \Trade.tHighDiff250),
            ("tHighDiffZ125", \Trade.tHighDiffZ125),
            ("tHighDiffZ250", \Trade.tHighDiffZ250),
            ("tHighMax9", \Trade.tHighMax9),
            ("tLowDiff", \Trade.tLowDiff),
            ("tLowDiff125", \Trade.tLowDiff125),
            ("tLowDiff250", \Trade.tLowDiff250),
            ("tLowDiffZ125", \Trade.tLowDiffZ125),
            ("tLowDiffZ250", \Trade.tLowDiffZ250),
            ("tLowMin9", \Trade.tLowMin9),
            ("tMa20", \Trade.tMa20),
            ("tMa20Days", \Trade.tMa20Days),
            ("tMa20Diff", \Trade.tMa20Diff),
            ("tMa20DiffMax9", \Trade.tMa20DiffMax9),
            ("tMa20DiffMin9", \Trade.tMa20DiffMin9),
            ("tMa20DiffZ125", \Trade.tMa20DiffZ125),
            ("tMa20DiffZ250", \Trade.tMa20DiffZ250),
            ("tMa60", \Trade.tMa60),
            ("tMa60Days", \Trade.tMa60Days),
            ("tMa60Diff", \Trade.tMa60Diff),
            ("tMa60DiffMax9", \Trade.tMa60DiffMax9),
            ("tMa60DiffMin9", \Trade.tMa60DiffMin9),
            ("tMa60DiffZ125", \Trade.tMa60DiffZ125),
            ("tMa60DiffZ250", \Trade.tMa60DiffZ250),
            ("tZ125", \Trade.tZ125),
            ("tZ250", \Trade.tZ250),
            ("tKdK", \Trade.tKdK),
            ("tKdKMax9", \Trade.tKdKMax9),
            ("tKdKMin9", \Trade.tKdKMin9),
            ("tKdKZ125", \Trade.tKdKZ125),
            ("tKdKZ250", \Trade.tKdKZ250),
            ("tKdD", \Trade.tKdD),
            ("tKdDZ125", \Trade.tKdDZ125),
            ("tKdDZ250", \Trade.tKdDZ250),
            ("tKdJ", \Trade.tKdJ),
            ("tKdJZ125", \Trade.tKdJZ125),
            ("tKdJZ250", \Trade.tKdJZ250),
            ("tOsc", \Trade.tOsc),
            ("tOscEma12", \Trade.tOscEma12),
            ("tOscEma26", \Trade.tOscEma26),
            ("tOscMacd9", \Trade.tOscMacd9),
            ("tOscMax9", \Trade.tOscMax9),
            ("tOscMin9", \Trade.tOscMin9),
            ("tOscZ125", \Trade.tOscZ125),
            ("tOscZ250", \Trade.tOscZ250),
            ("vMa20", \Trade.vMa20),
            ("vMa20Days", \Trade.vMa20Days),
            ("vMa20Diff", \Trade.vMa20Diff),
            ("vMa20DiffMax9", \Trade.vMa20DiffMax9),
            ("vMa20DiffMin9", \Trade.vMa20DiffMin9),
            ("vMa20DiffZ125", \Trade.vMa20DiffZ125),
            ("vMa20DiffZ250", \Trade.vMa20DiffZ250),
            ("vMa60", \Trade.vMa60),
            ("vMa60Days", \Trade.vMa60Days),
            ("vMa60Diff", \Trade.vMa60Diff),
            ("vMa60DiffMax9", \Trade.vMa60DiffMax9),
            ("vMa60DiffMin9", \Trade.vMa60DiffMin9),
            ("vMa60DiffZ125", \Trade.vMa60DiffZ125),
            ("vMa60DiffZ250", \Trade.vMa60DiffZ250),
            ("vMax9", \Trade.vMax9),
            ("vMin9", \Trade.vMin9),
            ("vZ125", \Trade.vZ125),
            ("vZ250", \Trade.vZ250),
        ] }
    private func ordinary(_ row: Trade) -> [Double] {
        ordinaryFields.map { row[keyPath: $0.1] }
    }
    private func preservedOrdinary(_ row: Trade) -> [Double] {
        let derived = Set(OrdinaryTechnicalStatistic.derivedFields.map(\.rawValue))
        return ordinaryFields.filter { !derived.contains($0.0) }.map { row[keyPath: $0.1] }
    }

    private func assertStatisticsConsistent(_ values: [Trade], from first: Int,
                                            file: StaticString = #filePath, line: UInt = #line) {
        for index in first..<values.count {
            for field in OrdinaryTechnicalStatistic.derivedFields {
                let d = field.definition
                let indices = d.volume
                    ? Array((0...index).reversed().filter { OrdinaryTechnicalPreservation.eligibleVolume(values[$0]) }.prefix(d.count))
                    : Array(max(0, index - d.count + 1)...index)
                guard !indices.isEmpty else { continue }
                if d.volume && indices.first != index { continue }
                let input = indices.map { values[$0][keyPath: d.input] }
                let expected: Double
                switch d.operation {
                case .maximum: expected = input.max()!
                case .minimum: expected = input.min()!
                case .z:
                    let average = input.reduce(0, +) / Double(input.count)
                    let deviation = sqrt(input.reduce(0) { $0 + pow($1 - average, 2) } / Double(input.count))
                    expected = deviation == 0 ? 0 : (values[index][keyPath: d.input] - average) / deviation
                }
                XCTAssertEqual(values[index][keyPath: d.output], expected, "\(field) at \(index)", file: file, line: line)
            }
        }
    }

    private func pending(_ fixture: Fixture) throws -> TechnicalReplayWork {
        try XCTUnwrap(TechnicalReplayWork.decode(fixture.stock.technicalPendingWork,
            version: Int(Technical.technicalRuleVersion.dropFirst())!, configuredStart: fixture.stock.dateStart))
    }
    private func addBackfill(_ fixture: Fixture) throws -> RecalculationPlan {
        for index in 0..<10 { insert(index, stock: fixture.stock, context: fixture.context) }
        return try fixture.technical.recalculationPlan(stock: fixture.stock,
            changes: .init(insertedDates: Set((0..<10).map { twDateTime.startOfDay(date($0)) })))
    }
    private func storeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("P2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("fixture.store")
    }

    func testMidnightDownloadChangesRecognizeBackfillAndAppendAt1330() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        try prepareMarket(Array(0..<10) + [320], for: f)
        let backfill = try addBackfill(f)
        XCTAssertEqual(backfill.technical, .backfill(from: twDateTime.startOfDay(date(0))))
        let trace = try f.technical.recalculate(stock: f.stock, plan: backfill)
        XCTAssertEqual(trace.ordinaryTechnicalDates, (0..<260).map(date))
        XCTAssertEqual(trace.pricePathDates, (0..<259).map(date))
        insert(320, stock: f.stock, context: f.context)
        let plan = try f.technical.recalculationPlan(stock: f.stock,
            changes: .init(insertedDates: [twDateTime.startOfDay(date(320))]))
        XCTAssertEqual(plan.technical, .from(twDateTime.startOfDay(date(320))))
        let append = try f.technical.recalculate(stock: f.stock, plan: plan)
        XCTAssertEqual(append.ordinaryTechnicalDates, [date(320)])
        XCTAssertEqual(append.pricePathDates, [date(320)])
        XCTAssertEqual(append.simulationDates, [date(320)])
    }

    func testBackfillAppendCorrectionPendingSurvivesReopenWithoutRewritingMatureGap() async throws {
        let url = try storeURL()
        // SQLite releases file handles asynchronously; retain UUID fixture until process exit.
        var gap: [[Double]] = []
        func writePending() throws {
            let f = try fixture(url: url)
            defer { withExtendedLifetime(f.container) {} }
            try prepareMarket(Array(0..<10) + [320], for: f)
            let plan = try addBackfill(f)
            try f.technical.persistDirtyState(for: f.stock, plan: plan)
            insert(320, stock: f.stock, context: f.context)
            let append = try f.technical.recalculationPlan(stock: f.stock,
                changes: .init(insertedDates: [twDateTime.startOfDay(date(320))]))
            try f.technical.persistDirtyState(for: f.stock, plan: append)
            let values = try rows(f)
            values[300].priceClose += 2
            let correction = try f.technical.recalculationPlan(stock: f.stock,
                changes: .init(modifiedDates: [twDateTime.startOfDay(date(300))]))
            try f.technical.persistDirtyState(for: f.stock, plan: correction)
            let work = try pending(f)
            XCTAssertEqual(work.ordinaryDates(in: values.map(\.dateTime)), (Array(0..<260) + Array(300..<321)).map(date))
            XCTAssertEqual(work.pricePathDates(in: values.map(\.dateTime)), (Array(0..<259) + Array(300..<321)).map(date))
            gap = values[260..<300].map(preservedOrdinary)
        }
        try writePending()
        let f = try reopen(url)
        defer { withExtendedLifetime(f.container) {} }
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        let trace = f.technical.lastRecalculationTrace
        XCTAssertEqual(trace.ordinaryTechnicalDates, (Array(0..<260) + Array(300..<321)).map(date))
        XCTAssertEqual(trace.pricePathDates, (Array(0..<259) + Array(300..<321)).map(date))
        XCTAssertEqual(trace.simulationDates, (260..<321).map(date))
        XCTAssertEqual(try rows(f)[260..<300].map(preservedOrdinary), gap)
        assertStatisticsConsistent(try rows(f), from: 260)
        XCTAssertNil(f.stock.technicalPendingWork)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertNil(f.stock.simulationDirtyFrom)
    }

    func testCombinedBackfillAndAppendMatchesSplitPendingBatches() async throws {
        let combined = try fixture()
        let split = try fixture()
        defer { withExtendedLifetime(combined.container) {}; withExtendedLifetime(split.container) {} }
        try prepareMarket(Array(0..<10) + [320], for: combined)
        try prepareMarket(Array(0..<10) + [320], for: split)
        _ = try addBackfill(combined)
        insert(320, stock: combined.stock, context: combined.context)
        let allChanges = TradeChangeSet(insertedDates: Set((Array(0..<10) + [320]).map { twDateTime.startOfDay(date($0)) }))
        let together = try combined.technical.recalculate(stock: combined.stock, changes: allChanges)
        let backfill = try addBackfill(split)
        try split.technical.persistDirtyState(for: split.stock, plan: backfill)
        insert(320, stock: split.stock, context: split.context)
        let append = try split.technical.recalculationPlan(stock: split.stock,
            changes: .init(insertedDates: [twDateTime.startOfDay(date(320))]))
        try split.technical.persistDirtyState(for: split.stock, plan: append)
        _ = try await split.technical.recoverOrMigrateRecalculationState(for: split.stock)
        let separate = split.technical.lastRecalculationTrace
        XCTAssertEqual(together, separate)
        XCTAssertEqual(together.ordinaryTechnicalDates, (Array(0..<260) + [320]).map(date))
        XCTAssertEqual(together.pricePathDates, (Array(0..<259) + [320]).map(date))
        let left = try rows(combined), right = try rows(split)
        XCTAssertEqual(left.map(ordinary), right.map(ordinary))
        for (a, b) in zip(left, right) {
            XCTAssertEqual(a.storedPricePathState, b.storedPricePathState)
            XCTAssertEqual(a.simQtyBuy, b.simQtyBuy)
            XCTAssertEqual(a.simQtySell, b.simQtySell)
            XCTAssertEqual(a.simQtyInventory, b.simQtyInventory)
            XCTAssertEqual(a.rollAmtProfit, b.rollAmtProfit)
            XCTAssertEqual(a.grade, b.grade)
            XCTAssertEqual(a.simFitTrendPhaseRaw, b.simFitTrendPhaseRaw)
        }
    }

    func testFinalSaveFailureRetryKeepsOriginalMatureStopInMemoryAndOnDisk() async throws {
        let url = try storeURL()
        // SQLite releases file handles asynchronously; retain UUID fixture until process exit.
        let f = try fixture(url: url)
        defer { withExtendedLifetime(f.container) {} }
        let plan = try addBackfill(f)
        let expected = try XCTUnwrap(plan.technicalWork)
        var saves = 0
        f.technical.recalculationSave = {
            saves += 1
            if saves == 2 { throw SaveFailure.injected }
            try f.context.save()
        }
        XCTAssertThrowsError(try f.technical.recalculate(stock: f.stock, plan: plan))
        f.technical.recalculationSave = nil
        XCTAssertEqual(try pending(f), expected)
        func verifySavedWork() throws {
            let cold = try reopen(url)
            defer { withExtendedLifetime(cold.container) {} }
            XCTAssertEqual(try pending(cold), expected)
        }
        try verifySavedWork()
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertEqual(f.technical.lastRecalculationTrace.ordinaryTechnicalDates, (0..<260).map(date))
        XCTAssertEqual(f.technical.lastRecalculationTrace.pricePathDates, (0..<259).map(date))
        XCTAssertNil(f.stock.technicalPendingWork)
    }

    func testFirstValidPriceRemovalAndRestorationReinitializesTAndSimulation() async throws {
        let f = try fixture(first: 0)
        defer { withExtendedLifetime(f.container) {} }
        let original = try rows(f)
        let close = original[0].priceClose
        original[0].priceClose = 0
        let removed = try f.technical.recalculationPlan(stock: f.stock,
            changes: .init(modifiedDates: [twDateTime.startOfDay(date(0))]))
        XCTAssertEqual(removed.simulation, .all)
        let trace = try f.technical.recalculate(stock: f.stock, plan: removed)
        XCTAssertEqual(trace.ordinaryTechnicalDates, (1..<320).map(date))
        XCTAssertEqual(trace.pricePathDates, (1..<250).map(date))
        XCTAssertEqual(original[1].tKdK, 50)
        XCTAssertEqual(original[1].tKdD, 50)
        XCTAssertEqual(trace.simulationDates, (261..<320).map(date))
        original[0].priceClose = close
        let restored = try f.technical.recalculationPlan(stock: f.stock,
            changes: .init(modifiedDates: [twDateTime.startOfDay(date(0))]))
        XCTAssertEqual(restored.simulation, .all)
        let replay = try f.technical.recalculate(stock: f.stock, plan: restored)
        XCTAssertEqual(replay.ordinaryTechnicalDates, (0..<320).map(date))
        XCTAssertEqual(replay.pricePathDates, (0..<250).map(date))
        XCTAssertEqual(replay.simulationDates, (260..<320).map(date))
        XCTAssertEqual(original[0].tKdK, 50)
    }

    func testLaterSettingRebuildsWholeRollingWindowWhenOriginChanges() async throws {
        let f = try fixture(first: 0, count: 400)
        defer { withExtendedLifetime(f.container) {} }
        let original = try rows(f)
        let newStart = twDateTime.calendar.date(byAdding: .year, value: 1, to: date(30))!
        try StockHistory.changeStart(f.stock, to: newStart, in: f.context)
        try f.context.save()
        XCTAssertEqual(f.stock.technicalDirtyFrom, .distantPast)
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertEqual(f.technical.lastRecalculationTrace.ordinaryTechnicalDates, (30..<400).map(date))
        XCTAssertEqual(original[30].tKdK, 50)
        XCTAssertFalse(original[278].tUpdated)
        XCTAssertTrue(original[279].tUpdated)
        assertStatisticsConsistent(try rows(f), from: 250)
        XCTAssertNil(f.stock.technicalPendingWork)
    }

    func testLaterSettingDoesNotAddTWorkWhenFirstAvailablePriceStaysSame() async throws {
        let f = try fixture(first: 10)
        defer { withExtendedLifetime(f.container) {} }
        let later = twDateTime.calendar.date(byAdding: .day, value: 1, to: f.stock.dateStart)!
        try StockHistory.changeStart(f.stock, to: later, in: f.context)
        XCTAssertNil(f.stock.technicalPendingWork)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertTrue(f.technical.lastRecalculationTrace.technicalDates.isEmpty)
        XCTAssertFalse(f.technical.lastRecalculationTrace.simulationDates.isEmpty)
    }

    func testTOnlyResearchConsumesTechnicalWorkButKeepsSimulationPending() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        var plan = try addBackfill(f)
        plan.deferSimulation = true
        let trace = try f.technical.recalculate(stock: f.stock, plan: plan)
        XCTAssertEqual(trace.ordinaryTechnicalDates.count, 260)
        XCTAssertTrue(trace.simulationDates.isEmpty)
        XCTAssertNil(f.stock.technicalPendingWork)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertNotNil(f.stock.simulationDirtyFrom)
    }

    func testPreservationBoundaryUsesQualifiedVolumeAndIncludesTheBoundary() async throws {
        let f = try fixture(first: 0, count: 0)
        defer { withExtendedLifetime(f.container) {} }
        for index in 0..<300 { insert(index, stock: f.stock, context: f.context) }
        let values = try rows(f)
        values[0].tUpdated = true
        for count in [249, 250, 251] {
            XCTAssertEqual(OrdinaryTechnicalPreservation.stopIndex(in: Array(values.prefix(count))), min(count - 1, 249))
        }
        values[0].volumeClose = 0 // A genuine TWSE zero still advances maturity.
        XCTAssertEqual(OrdinaryTechnicalPreservation.stopIndex(in: values), 249)
        values[1].dataSource = "Yahoo"
        values[2].volumeClose = .nan
        values[3].volumeClose = -1
        XCTAssertEqual(OrdinaryTechnicalPreservation.stopIndex(in: values), 252)
        for row in values { row.tUpdated = false }
        XCTAssertEqual(OrdinaryTechnicalPreservation.stopIndex(in: values), 299)
        values[290].tUpdated = true
        XCTAssertEqual(OrdinaryTechnicalPreservation.stopIndex(in: values), 290)
        for row in values { row.dataSource = "Yahoo" }
        XCTAssertEqual(OrdinaryTechnicalPreservation.stopIndex(in: values), 299)
    }

    func testYahooOnlyVolumeDoesNotCauseRepeatedTechnicalRepair() async throws {
        let f = try fixture(first: 0, count: 20)
        defer { withExtendedLifetime(f.container) {} }
        let values = try rows(f)
        for row in values { row.dataSource = "Yahoo" }
        _ = try f.technical.recalculate(stock: f.stock, plan: .init(technical: .all, simulation: .all))
        XCTAssertTrue(values.allSatisfy { $0.vMa20 == 0 && $0.vMa60 == 0 })
        XCTAssertTrue(values.allSatisfy { $0.volumeClose > 0 })
        XCTAssertNil(f.stock.technicalDirtyFrom)
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertTrue(f.technical.lastRecalculationTrace.technicalDates.isEmpty,
            "Yahoo volume cannot certify an unfinished TWSE-volume migration")
    }

    func testQuantifyPreservedOrdinaryTailAgainstFullColdReplay() async throws {
        let incremental = try fixture()
        let cold = try fixture(first: 0)
        defer { withExtendedLifetime(incremental.container) {}; withExtendedLifetime(cold.container) {} }
        let before = try rows(incremental).suffix(60).map(preservedOrdinary)
        let plan = try addBackfill(incremental)
        _ = try incremental.technical.recalculate(stock: incremental.stock, plan: plan)
        let actual = try rows(incremental)
        let reference = try rows(cold)
        XCTAssertEqual(actual.suffix(60).map(preservedOrdinary), before)
        assertStatisticsConsistent(actual, from: 260)
        let fields = ordinaryFields
        XCTAssertEqual(fields.count, 65)
        XCTAssertEqual(Set(fields.map { $0.0 }).count, 65)
        var differences: [[String: Any]] = []
        for (name, key) in fields {
            let changed = actual.indices.filter { actual[$0][keyPath: key] != reference[$0][keyPath: key] }
            guard let first = changed.first else { continue }
            let maximum = changed.map { abs(actual[$0][keyPath: key] - reference[$0][keyPath: key]) }.max()!
            differences.append(["field": name, "count": changed.count, "firstIndex": first,
                                "maximumAbsoluteDifference": maximum])
        }
        var transactions: [Int] = []
        var grades: [Int] = []
        var warnings: [Int] = []
        var fits: [Int] = []
        for i in actual.indices {
            let a = actual[i], b = reference[i]
            XCTAssertEqual(a.tPricePathPhaseRaw, b.tPricePathPhaseRaw)
            XCTAssertEqual(a.tPricePathBarrier, b.tPricePathBarrier)
            XCTAssertEqual(a.tPricePathAnchorClose, b.tPricePathAnchorClose)
            XCTAssertEqual(a.tPricePathExtremeClose, b.tPricePathExtremeClose)
            XCTAssertEqual(a.tPricePathDaysSinceExtreme, b.tPricePathDaysSinceExtreme)
            if a.simQtyBuy != b.simQtyBuy || a.simQtySell != b.simQtySell || a.simQtyInventory != b.simQtyInventory
                || a.simRule != b.simRule || a.simRuleBuy != b.simRuleBuy || a.simRuleInvest != b.simRuleInvest {
                transactions.append(i)
            }
            if a.grade != b.grade { grades.append(i) }
            if a.simFitTrend != b.simFitTrend || a.simFitTrendPhaseRaw != b.simFitTrendPhaseRaw
                || a.simFitTrendPhaseExtreme != b.simFitTrendPhaseExtreme { fits.append(i) }
            func warning(_ data: Data?) throws -> Data? {
                guard let data else { return nil }
                return try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
            }
            if try warning(a.simAnnualWarningData) != warning(b.simAnnualWarningData) { warnings.append(i) }
        }
        let report: [String: Any] = ["fixture": "320 synthetic rows; initial rows10...319 then backfill0...9",
            "ordinaryFieldsCompared": fields.count, "ordinaryDifferences": differences,
            "transactionDifferenceIndices": transactions, "gradeDifferenceIndices": grades,
            "gradeTrendDifferenceIndices": fits, "warningDifferenceIndices": warnings,
            "pathDifferences": 0, "isPerformanceValidation": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("P2_MATURITY_DIAGNOSTIC " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "P2 maturity versus cold replay"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(differences.isEmpty, "Fixture should expose the maturity-preservation contract difference")
    }
    func testBackfillUpdatesOnlyDependentMatureStatisticsAndStopsAtExactBoundaries() throws {
        let f = try fixture(count: 600)
        defer { withExtendedLifetime(f.container) {} }
        let original = try rows(f)
        let before = Dictionary(uniqueKeysWithValues: original.map { ($0.dateTime, ordinary($0)) })
        let core = Dictionary(uniqueKeysWithValues: original.map { ($0.dateTime, preservedOrdinary($0)) })
        let plan = try addBackfill(f)
        let trace = try f.technical.recalculate(stock: f.stock, plan: plan)
        let values = try rows(f)
        XCTAssertEqual(trace.ordinaryTechnicalDates, (0..<260).map(date))
        XCTAssertEqual(trace.ordinaryStatisticWrites.keys.sorted(), (260...508).map(date))
        for index in 260..<600 {
            XCTAssertEqual(preservedOrdinary(values[index]), core[date(index)])
            if index >= 509 { XCTAssertEqual(ordinary(values[index]), before[date(index)]) }
        }
        XCTAssertEqual(trace.ordinaryStatisticWrites[date(267)]?.contains(.tOscMax9), true)
        XCTAssertNotEqual(trace.ordinaryStatisticWrites[date(268)]?.contains(.tOscMax9), true)
        XCTAssertEqual(trace.ordinaryStatisticWrites[date(383)]?.contains(.tOscZ125), true)
        XCTAssertNotEqual(trace.ordinaryStatisticWrites[date(384)]?.contains(.tOscZ125), true)
        XCTAssertNotEqual(values[300].tOscZ250, before[date(300)]![ordinaryFields.firstIndex { $0.0 == "tOscZ250" }!])
        assertStatisticsConsistent(values, from: 260)
        XCTAssertNil(f.stock.technicalPendingWork)
    }

    func testStatisticOnlyWriteAutomaticallyInvalidatesSimulationWithoutRewritingCoreT() throws {
        let f = try fixture(first: 0, count: 420)
        defer { withExtendedLifetime(f.container) {} }
        let values = try rows(f)
        let core = values.map(preservedOrdinary)
        values[300].tOscZ250 = 12345
        let work = TechnicalReplayWork(version: 4, configuredStart: f.stock.dateStart,
            ordinary: [], pricePath: [], allDates: values.map(\.dateTime), statistics: [.tOscZ250: [date(300)]])
        let trace = try f.technical.recalculate(stock: f.stock,
            plan: .init(technical: .from(date(300)), simulation: .none, technicalWork: work))
        XCTAssertTrue(trace.ordinaryTechnicalDates.isEmpty)
        XCTAssertTrue(trace.pricePathDates.isEmpty)
        XCTAssertEqual(trace.ordinaryStatisticWrites, [date(300): [.tOscZ250]])
        XCTAssertEqual(trace.simulationDates, (300..<420).map(date))
        XCTAssertEqual(values.map(preservedOrdinary), core)
        assertStatisticsConsistent(values, from: 300)
    }

    func testColdResumeAfterCoreWasSavedKeepsOnlyUnfinishedStatisticFields() async throws {
        let url = try storeURL()
        // Keep SQLite's UUID directory until the process releases its handles.
        func savePartial() throws -> [[Double]] {
            let f = try fixture(first: 0, count: 600, url: url)
            defer { withExtendedLifetime(f.container) {} }
            let values = try rows(f), dates = values.map(\.dateTime)
            // Model an already-saved T write followed by interruption before
            // downstream statistics; the source write is not pending again.
            values[250].tOsc += 0.25
            let work = TechnicalReplayWork(version: 4, configuredStart: f.stock.dateStart,
                ordinary: [date(250)], pricePath: [], allDates: dates).includingStatisticDependencies(trades: values)
            let remainder = work.remaining(ordinaryDone: [date(250)], pricePathDone: [], allDates: dates)
            f.stock.technicalPendingWork = try remainder.encoded()
            f.stock.technicalDirtyFrom = date(251)
            f.stock.simulationDirtyFrom = nil // common executor must restore S coverage itself
            try f.context.save()
            return values.map(preservedOrdinary)
        }
        let core = try savePartial()
        let f = try reopen(url)
        defer { withExtendedLifetime(f.container) {} }
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        let trace = f.technical.lastRecalculationTrace
        XCTAssertTrue(trace.ordinaryTechnicalDates.isEmpty)
        XCTAssertTrue(trace.pricePathDates.isEmpty)
        XCTAssertEqual(trace.ordinaryStatisticWrites.keys.sorted(), (251...499).map(date))
        XCTAssertEqual(trace.simulationDates, (260..<600).map(date))
        XCTAssertEqual(try rows(f).map(preservedOrdinary), core)
        assertStatisticsConsistent(try rows(f), from: 251)
        XCTAssertNil(f.stock.technicalPendingWork); XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertNil(f.stock.simulationDirtyFrom)
    }

    /// This fixture explicitly certifies its synthetic source months. Merely
    /// inserting a first/last price must never make that assertion for us.
    private func certify(_ f: Fixture) throws {
        let last = try XCTUnwrap(rows(f).last).dateTime
        for month in f.stock.unconfirmedHistoryMonths(through: last) {
            let next = twDateTime.calendar.date(byAdding: .month, value: 1, to: month)!
            try f.stock.confirmHistoryMonth(month, through: min(next.addingTimeInterval(-1), twDateTime.endOfDay(last)))
        }
    }

    func testConfirmedCompletionMakesColdAndBatchedAllTechnicalAndSimulationValuesIdentical() async throws {
        let cold = try fixture(first: 0, count: 600)
        let batch = try fixture(first: 10, count: 600)
        defer { withExtendedLifetime((cold.container, batch.container)) {} }
        try prepareMarket(Array(0..<10), for: batch)
        let partial = try addBackfill(batch)
        _ = try batch.technical.recalculate(stock: batch.stock, plan: partial)
        XCTAssertEqual(batch.technical.lastRecalculationTrace.ordinaryTechnicalDates.count, 260)
        XCTAssertNotEqual(try rows(cold).map(ordinary), try rows(batch).map(ordinary))
        try certify(batch)
        try batch.technical.persistDirtyState(for: batch.stock, plan: .none)
        _ = try await batch.technical.recoverOrMigrateRecalculationState(for: batch.stock)
        let a = try rows(cold), b = try rows(batch)
        XCTAssertEqual(batch.technical.lastRecalculationTrace.ordinaryTechnicalDates, b.map(\.dateTime))
        XCTAssertEqual(a.map(InternalMaturityProbe.technicalValues), b.map(InternalMaturityProbe.technicalValues))
        XCTAssertEqual(try a.filter { !$0.isBeforeSimulationStart }.map(InternalMaturityProbe.simulationValues),
            try b.filter { !$0.isBeforeSimulationStart }.map(InternalMaturityProbe.simulationValues))
        XCTAssertEqual(batch.stock.savedRollingOrigin?.firstPrice, twDateTime.startOfDay(date(0)))
        XCTAssertNil(batch.stock.technicalDirtyFrom); XCTAssertNil(batch.stock.simulationDirtyFrom)
        XCTAssertTrue(batch.technical.stocksRequiringRecalculation(in: [batch.stock]).isEmpty)
        let noChange = try batch.technical.recalculate(stock: batch.stock, plan: .none)
        XCTAssertTrue(noChange.technicalDates.isEmpty); XCTAssertTrue(noChange.simulationDates.isEmpty)
    }

    func testCompletedHistoryStillAppendsOnlyOneDayAndCorrectsOnlyAffectedSuffix() throws {
        let f = try fixture(first: 0, count: 600)
        defer { withExtendedLifetime(f.container) {} }
        try certify(f)
        try prepareMarket([600], for: f)
        let original = try rows(f).map(ordinary)
        insert(600, stock: f.stock, context: f.context)
        let appended = try f.technical.recalculate(stock: f.stock, changes: .init(insertedDates: [date(600)]))
        XCTAssertEqual(appended.ordinaryTechnicalDates, [date(600)])
        XCTAssertEqual(try rows(f).dropLast().map(ordinary), original)
        let values = try rows(f)
        values[580].priceClose += 1
        let corrected = try f.technical.recalculate(stock: f.stock, changes: .init(modifiedDates: [date(580)]))
        XCTAssertEqual(corrected.ordinaryTechnicalDates, (580...600).map(date))
        XCTAssertEqual(corrected.simulationDates, (580...600).map(date))
    }

    func testCompletionReceiptAndFullPendingWorkSurviveFailedFinalSaveAndReopen() async throws {
        let url = try storeURL()
        func failedReplay() throws {
            let f = try fixture(count: 600, url: url)
            defer { withExtendedLifetime(f.container) {} }
            try prepareMarket(Array(0..<10), for: f)
            _ = try f.technical.recalculate(stock: f.stock, plan: addBackfill(f))
            try certify(f)
            try f.technical.persistDirtyState(for: f.stock, plan: .none)
            let oldReceipt = f.stock.technicalRollingOrigin
            var saves = 0
            f.technical.recalculationSave = {
                saves += 1
                if saves == 2 { throw SaveFailure.injected }
                try f.context.save()
            }
            XCTAssertThrowsError(try f.technical.recalculate(stock: f.stock, plan: .none))
            XCTAssertEqual(f.stock.technicalRollingOrigin, oldReceipt)
            XCTAssertNotNil(f.stock.technicalDirtyFrom); XCTAssertNotNil(f.stock.simulationDirtyFrom)
        }
        try failedReplay()
        let f = try reopen(url)
        defer { withExtendedLifetime(f.container) {} }
        XCTAssertEqual(f.stock.savedRollingOrigin?.firstPrice, twDateTime.startOfDay(date(10)))
        XCTAssertNotNil(f.stock.technicalPendingWork)
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertEqual(f.technical.lastRecalculationTrace.ordinaryTechnicalDates.count, 600)
        XCTAssertEqual(f.stock.savedRollingOrigin?.firstPrice, twDateTime.startOfDay(date(0)))
        XCTAssertNil(f.stock.technicalDirtyFrom); XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertFalse(f.stock.needsCompletedHistoryReplay(trades: try rows(f), version: 4))
    }

    func testCompletedStockTReceiptCanSaveWhileMarketIsAbsent() throws {
        let f = try fixture(first: 10, count: 250)
        defer { withExtendedLifetime(f.container) {} }
        _ = try addBackfill(f)
        try certify(f)
        let trace = try f.technical.recalculate(stock: f.stock, plan: .none)
        XCTAssertEqual(trace.ordinaryTechnicalDates.count, 250)
        XCTAssertNotNil(f.stock.savedRollingOrigin)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertTrue(trace.simulationDates.isEmpty)
    }

    func testEarlierSettingRebuildsRetainedRawDespiteOldMatureFlagsWithoutDownloading() async throws {
        let f = try fixture(first: 0, count: 600)
        defer { withExtendedLifetime(f.container) {} }
        let original = try rows(f)
        let raw = original.map(InternalMaturityProbe.Raw.init)
        let oldT = original.map(InternalMaturityProbe.technicalValues)
        let later = twDateTime.calendar.date(byAdding: .year, value: 1, to: date(30))!
        try StockHistory.changeStart(f.stock, to: later, in: f.context)
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        original[0].tUpdated = true; original[0].tKdK = 999
        try StockHistory.changeStart(f.stock, to: date(260), in: f.context)
        XCTAssertEqual(f.stock.technicalDirtyFrom, .distantPast)
        _ = try await f.technical.recoverOrMigrateRecalculationState(for: f.stock)
        XCTAssertEqual(f.technical.lastRecalculationTrace.ordinaryTechnicalDates, (0..<600).map(date))
        XCTAssertEqual(try rows(f).map(InternalMaturityProbe.Raw.init), raw)
        XCTAssertEqual(try rows(f).map(InternalMaturityProbe.technicalValues), oldT)
        XCTAssertEqual(original[0].tKdK, 50)
    }

    func testVerifiedPrelistingBoundaryCompletesNewlyBackfilledRollingOrigin() throws {
        let cold = try fixture(first: 120, count: 600)
        let f = try fixture(first: 200, count: 600)
        defer { withExtendedLifetime((cold.container, f.container)) {} }
        try prepareMarket(Array(120..<200), for: f)
        for i in 120..<200 { insert(i, stock: f.stock, context: f.context) }
        _ = try f.technical.recalculate(stock: f.stock, changes: .init(insertedDates: Set((120..<200).map(date))))
        f.stock.twseListingDate = twDateTime.startOfDay(date(120))
        try certify(f)
        let trace = try f.technical.recalculate(stock: f.stock, plan: .none)
        XCTAssertEqual(trace.ordinaryTechnicalDates, (120..<600).map(date))
        XCTAssertEqual(try rows(f).map(InternalMaturityProbe.technicalValues), try rows(cold).map(InternalMaturityProbe.technicalValues))
        XCTAssertEqual(f.stock.savedRollingOrigin?.firstPrice, twDateTime.startOfDay(date(120)))
    }
}
