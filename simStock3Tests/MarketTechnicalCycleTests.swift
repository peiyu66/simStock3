import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class MarketTechnicalCycleTests: XCTestCase {
    private enum SaveFailure: Error { case injected }
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let stock: Stock
        let market: MarketDataStore
    }
    private func date(_ index: Int) -> Date {
        let origin = twDateTime.dateFromString("2024/01/01")!
        let days = index < 260 ? index * 366 / 260 : 366 + index - 260
        return twDateTime.time1330(twDateTime.calendar.date(byAdding: .day, value: days, to: origin)!)
    }
    private func record(_ index: Int, delta: Double = 0) -> MarketDataStore.Record {
        let close = 10_000 + Double(index) * 3 + sin(Double(index) / 9) * 200 + delta
        return .init(date: date(index), open: close - 2, high: close + 30, low: close - 40, close: close)
    }
    private func makeContainer(_ url: URL?) throws -> ModelContainer {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
    private func fixture(first: Int = 0, count: Int = 600, url: URL? = nil) throws -> Fixture {
        let container = try makeContainer(url)
        let context = ModelContext(container); context.autosaveEnabled = false
        let stock = Stock(sId: "MARKET-CYCLE", sName: "市場依賴", group: "測試",
                          dateFirst: date(0), dateStart: date(260))
        context.insert(stock)
        for index in 0...count {
            let row = Trade(stock: stock, dateTime: date(index))
            row.priceClose = 100; row.tKdK = 999; row.tUpdated = index >= 249; row.simUpdated = true
            context.insert(row)
        }
        let market = MarketDataStore(modelContext: context)
        _ = try market.applyOfficialRecords((first..<count).map { record($0) })
        try market.rebuildPricePath()
        stock.technicalDirtyFrom = nil; stock.simulationDirtyFrom = nil
        try context.save()
        return Fixture(container: container, context: context, stock: stock, market: market)
    }
    private func rows(_ fixture: Fixture) throws -> [MarketDay] {
        try MarketDay.fetchAll(in: fixture.context)
    }
    private func values(_ day: MarketDay) -> [Double?] {
        [day.indexHighMax9, day.indexLowMin9, day.indexHighDiff250, day.indexHighDiffZ125,
         day.oscZ125, day.oscEMA12, day.oscEMA26, day.oscMACD9, day.kdK, day.kdD, day.kdJZ250,
         day.indexLowDiffZ125, day.ma20DiffMax9, day.priceObservationCount.map(Double.init),
         Double(day.pricePathPhaseRaw), day.pricePathBarrier, day.pricePathAnchorClose,
         day.pricePathExtremeClose, Double(day.pricePathDaysSinceExtreme)]
    }
    private func storeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MarketCycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("fixture.store")
    }

    func testCleanColdRebuildDoesNoWorkAndAppendWritesOnlyNewDay() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let before = try rows(f).map(values)
        try f.market.rebuildPricePath()
        XCTAssertTrue(f.market.lastTechnicalWriteDates.isEmpty)
        XCTAssertNil(f.stock.simulationDirtyFrom)
        XCTAssertEqual(try f.market.applyOfficialRecords([record(600)]), 1)
        XCTAssertEqual(f.stock.simulationDirtyFrom, date(600))
        try f.market.rebuildPricePath()
        XCTAssertEqual(f.market.lastTechnicalWriteDates, [date(600)])
        XCTAssertEqual(try rows(f).dropLast().map(values), before)
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertTrue(try Trade.fetchCalculationWindow(in: f.context, for: f.stock).allSatisfy { $0.tKdK == 999 })
    }

    func testPureEarlyBackfillLeavesMatureMarketAndUnrelatedStockSimulationValid() async throws {
        let f = try fixture(first: 10)
        defer { withExtendedLifetime(f.container) {} }
        let tail = try rows(f).filter { $0.dateTime >= date(259) }.map(values)
        _ = try f.market.applyOfficialRecords((0..<10).map { record($0) })
        XCTAssertNil(f.stock.technicalDirtyFrom)
        XCTAssertNil(f.stock.simulationDirtyFrom)
        try f.market.rebuildPricePath()
        XCTAssertEqual(f.market.lastTechnicalWriteDates, (0..<259).map(date))
        XCTAssertEqual(try rows(f)[259...].map(values), tail)
        XCTAssertNil(f.stock.simulationDirtyFrom)
    }

    func testMiddleCorrectionIsBoundedButSimulationReplaysItsDependentTail() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let original = try rows(f).map(values)
        _ = try f.market.applyOfficialRecords([record(300, delta: 200)])
        XCTAssertEqual(f.stock.simulationDirtyFrom, date(300))
        XCTAssertNil(f.stock.technicalDirtyFrom)
        try f.market.rebuildPricePath()
        XCTAssertEqual(f.market.lastTechnicalWriteDates, (300..<550).map(date))
        let after = try rows(f).map(values)
        XCTAssertEqual(Array(after[..<300]), Array(original[..<300]))
        XCTAssertEqual(Array(after[550...]), Array(original[550...]))
        XCTAssertNotEqual(after[300], original[300])
        XCTAssertEqual(f.stock.simulationDirtyFrom, date(300))
    }

    func testSourceReplacementUsesOfficialRawSequenceWithoutReusingYahooState() async throws {
        let f = try fixture(count: 300)
        defer { withExtendedLifetime(f.container) {} }
        let yahoo = record(300)
        XCTAssertTrue(try f.market.applyYahooQuote(yahoo, asOf: yahoo.date))
        let day = try XCTUnwrap(MarketDay.fetchSameDay(as: yahoo.date, in: f.context))
        let value = values(day)
        _ = try f.market.applyOfficialRecords([yahoo])
        XCTAssertTrue(day.isOfficial)
        XCTAssertFalse(day.hasCurrentTechnicalValues)
        try f.market.rebuildPricePath()
        XCTAssertEqual(f.market.lastTechnicalWriteDates, [date(300)])
        XCTAssertEqual(values(day), value)
        XCTAssertTrue(day.hasCurrentTechnicalValues)
    }

    func testKnownPendingSurvivesColdReopenWithoutExpandingItAgain() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func write() throws {
            let f = try fixture(url: url)
            defer { withExtendedLifetime(f.container) {} }
            _ = try f.market.applyOfficialRecords([record(100, delta: 200)])
            XCTAssertEqual(try rows(f).filter { $0.technicalStateVersion == MarketDataStore.pendingTechnicalStateVersion }.map(\.dateTime), (100..<350).map(date))
        }
        try write()
        let container = try makeContainer(url)
        defer { withExtendedLifetime(container) {} }
        let market = MarketDataStore(modelContext: container.mainContext)
        try market.rebuildPricePath()
        XCTAssertEqual(market.lastTechnicalWriteDates, (100..<350).map(date))
        try market.rebuildPricePath()
        XCTAssertTrue(market.lastTechnicalWriteDates.isEmpty)
    }

    func testFinalSaveFailureKeepsPendingVersionAndDependentSimulation() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        _ = try f.market.applyOfficialRecords([record(300, delta: 200)])
        var saves = 0
        f.market.technicalSave = {
            saves += 1
            if saves == 2 { throw SaveFailure.injected }
            try f.context.save()
        }
        XCTAssertThrowsError(try f.market.rebuildPricePath())
        f.market.technicalSave = nil
        XCTAssertTrue(try rows(f)[300..<550].allSatisfy { !$0.hasCurrentTechnicalValues })
        XCTAssertEqual(f.stock.simulationDirtyFrom, date(300))
        try f.market.rebuildPricePath()
        XCTAssertEqual(f.market.lastTechnicalWriteDates, (300..<550).map(date))
        XCTAssertTrue(try rows(f).allSatisfy(\.hasCurrentTechnicalValues))
    }

    func testLaterBatchCannotHideAnOverlappingUnknownOriginAfterColdReopen() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func write() throws {
            let f = try fixture(url: url)
            defer { withExtendedLifetime(f.container) {} }
            let unknown = try rows(f)[300]
            unknown.indexHigh += 500
            unknown.technicalStateVersion = 0
            try f.context.save()
            // This batch reaches row 349. The unknown origin at 300 must still
            // extend its own dependencies to row 549 before becoming -7.
            _ = try f.market.applyOfficialRecords([record(100, delta: 200)])
            XCTAssertEqual(try rows(f).filter {
                $0.technicalStateVersion == MarketDataStore.pendingTechnicalStateVersion
            }.map(\.dateTime), (100..<550).map(date))
        }
        try write()
        let container = try makeContainer(url)
        defer { withExtendedLifetime(container) {} }
        let market = MarketDataStore(modelContext: container.mainContext)
        try market.rebuildPricePath()
        XCTAssertEqual(market.lastTechnicalWriteDates, (100..<550).map(date))
        let days = try MarketDay.fetchAll(in: container.mainContext)
        let control = try XCTUnwrap(BoundedMarketTechnicalContext.referenceValue(
            points: days[300..<550].map(\.boundedRawPoint)))
        XCTAssertEqual(days[549].indexHighDiff250, control.highDiff250)
        XCTAssertTrue(days.allSatisfy(\.hasCurrentTechnicalValues))
    }

    func testMarketWorkWithoutEffectiveStockDatesDoesNotInventSimulationWork() async throws {
        let container = try makeContainer(nil)
        defer { withExtendedLifetime(container) {} }
        let stock = Stock(sId: "EMPTY", sName: "尚無行情", group: "測試",
                          dateFirst: date(0), dateStart: date(260))
        container.mainContext.insert(stock)
        let market = MarketDataStore(modelContext: container.mainContext)
        _ = try market.applyOfficialRecords([record(300)])
        try market.rebuildPricePath()
        XCTAssertEqual(market.lastTechnicalWriteDates, [date(300)])
        XCTAssertNil(stock.technicalDirtyFrom)
        XCTAssertNil(stock.simulationDirtyFrom)
    }

    func testUnknownDirtyAndVersionMigrationHaveConservativeCoverage() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let days = try rows(f)
        days[300].technicalStateVersion = 0
        try f.context.save()
        try f.market.rebuildPricePath()
        XCTAssertEqual(f.market.lastTechnicalWriteDates, (300..<550).map(date))
        for day in days { day.technicalStateVersion = 6 }
        try f.context.save()
        try f.market.rebuildPricePath()
        XCTAssertEqual(f.market.lastTechnicalWriteDates, (0..<600).map(date))
        XCTAssertNil(f.stock.technicalDirtyFrom)
    }

    func testIdenticalOfficialInputsDoNotCreateWork() async throws {
        let f = try fixture(count: 40)
        defer { withExtendedLifetime(f.container) {} }
        XCTAssertEqual(try f.market.applyOfficialRecords((0..<40).map { record($0) }), 0)
        try f.market.rebuildPricePath()
        XCTAssertTrue(f.market.lastTechnicalWriteDates.isEmpty)
        XCTAssertNil(f.stock.simulationDirtyFrom)
    }

    func testCoverageCountsOfficialSessionsAndNotYahooTrials() async {
        let official = (0..<300).map(date)
        XCTAssertEqual(MarketTechnicalCoverage.affected(targetDates: official, officialDates: official, changedDates: [date(0)]), Set((0..<250).map(date)))
        let removed = Array(official.dropFirst())
        XCTAssertEqual(MarketTechnicalCoverage.affected(targetDates: removed, officialDates: removed, changedDates: [date(0)]), Set((1..<250).map(date)))
        let trial = date(249).addingTimeInterval(-86400 / 2)
        XCTAssertTrue(MarketTechnicalCoverage.affected(targetDates: [trial], officialDates: official, changedDates: [date(0)]).contains(trial))
    }
}
