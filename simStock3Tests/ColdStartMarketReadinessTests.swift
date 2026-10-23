import Foundation
import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class ColdStartMarketReadinessTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, [MarketDay]) {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let start = twDateTime.dateFromString("2025/01/01")!
        for index in 0..<260 {
            let date = twDateTime.calendar.date(byAdding: .day, value: index, to: start)!
            let close = 10_000 + Double(index)
            context.insert(MarketDay(dateTime: date, indexOpen: close,
                indexHigh: close + 10, indexLow: close - 10, indexClose: close))
        }
        try MarketDataStore(modelContext: context).rebuildPricePath()
        return (container, try MarketDay.fetchAll(in: context))
    }

    func testReadinessUsesCurrentSingleDayValuesWithoutBuildingHistoryLookup() throws {
        let (container, days) = try fixture()
        let technical = Technical(modelContext: container.mainContext)
        defer { technical.invalidateTimer(); withExtendedLifetime(container) {} }
        let reference = try MarketPricePathLookup(modelContext: container.mainContext)
        for index in [40, 249, 259] {
            XCTAssertEqual(technical.marketReadinessObservation(on: days[index].dateTime),
                reference.observation(on: days[index].dateTime))
        }
        let last = days[259]
        XCTAssertEqual(technical.marketReadinessObservation(on: last.dateTime)?.hasSimulationValues, true)
        let originalK = last.kdK
        last.kdK = nil
        XCTAssertNil(technical.marketReadinessObservation(on: last.dateTime),
            "Unsaved incomplete technical values must not reuse an earlier valid observation")
        last.kdK = originalK
        last.technicalStateVersion = 0
        XCTAssertNil(technical.marketReadinessObservation(on: last.dateTime))
        last.technicalStateVersion = MarketDataStore.technicalStateVersion
        last.priceObservationCount = 1
        last.pricePathPhase = .unavailable
        let warmup = try XCTUnwrap(technical.marketReadinessObservation(on: last.dateTime))
        XCTAssertFalse(warmup.hasSimulationValues, "A valid partial technical window is not mature S input")
        container.mainContext.delete(last)
        XCTAssertNil(technical.marketReadinessObservation(on: last.dateTime),
            "A pending deletion must not expose the stored observation through a limited fetch")
        XCTAssertEqual(technical.marketLookupReloadCount, 0)
        XCTAssertEqual(technical.marketLookupObservationCount, 0)
    }

    func testReadinessPreservesLiveFallbackFutureQuoteAndInjectedObservations() throws {
        let (container, days) = try fixture()
        let context = container.mainContext
        let technical = Technical(modelContext: context)
        defer { technical.invalidateTimer(); withExtendedLifetime(container) {} }
        let current = days[259], previous = days[258]
        let now = twDateTime.time0900(current.dateTime).addingTimeInterval(3_600)
        technical.liveMarketContext = .init(asOf: now, previousTradingDay: previous.dateTime)
        current.dataSource = "Yahoo"
        let quotes: [Date?] = [nil, now.addingTimeInterval(twDateTime.quoteFutureTolerance + 1), now]
        for quote in quotes {
            current.quoteTime = quote
            let reference = try MarketPricePathLookup(modelContext: context)
            XCTAssertEqual(technical.marketReadinessObservation(on: now),
                reference.liveObservation(on: now, asOf: now, previousTradingDay: previous.dateTime))
            XCTAssertEqual(technical.marketReadinessObservation(on: now)?.date,
                quote == now ? current.dateTime : previous.dateTime)
        }
        current.technicalStateVersion = 0
        XCTAssertEqual(technical.marketReadinessObservation(on: now)?.date, previous.dateTime)
        previous.dataSource = "Yahoo"
        XCTAssertNil(technical.marketReadinessObservation(on: now), "Fallback must be official")
        let missingHistorical = twDateTime.calendar.date(byAdding: .day, value: -1, to: days[0].dateTime)!
        XCTAssertNil(technical.marketReadinessObservation(on: missingHistorical), "Historical dates never borrow live fallback")

        previous.dataSource = "TWSE-MI_5MINS_HIST"
        let frozen = try MarketPricePathLookup(modelContext: context)
        let injected = Technical(modelContext: context, marketPricePathLookup: frozen)
        defer { injected.invalidateTimer() }
        injected.liveMarketContext = technical.liveMarketContext
        previous.technicalStateVersion = 0
        XCTAssertNil(technical.marketReadinessObservation(on: now))
        XCTAssertEqual(injected.marketReadinessObservation(on: now),
            frozen.liveObservation(on: now, asOf: now, previousTradingDay: previous.dateTime),
            "Injected research/test inputs keep their frozen lookup semantics")
        XCTAssertEqual(technical.marketLookupReloadCount, 0)
        XCTAssertEqual(injected.marketLookupReloadCount, 0)
    }

    func testPendingMarketEditsRefreshTheRequestedReplayRangeOnceAtItsBoundary() throws {
        let (container, days) = try fixture()
        let context = container.mainContext
        let technical = Technical(modelContext: context)
        defer { technical.invalidateTimer(); withExtendedLifetime(container) {} }
        technical.prepareMarketPricePathLookup(from: days[249].dateTime, through: days[249].dateTime)
        XCTAssertEqual(technical.marketLookupReloadCount, 1)
        let last = days[259]
        last.indexHighMax9 = try XCTUnwrap(last.indexHighMax9) + 1
        XCTAssertTrue(context.hasChanges)
        technical.prepareMarketPricePathLookup(from: days[245].dateTime, through: last.dateTime,
            checkPendingChanges: true)
        XCTAssertEqual(technical.marketLookupReloadCount, 2, "Refresh the requested range, not the old range first")
        let reference = try MarketPricePathLookup(modelContext: context)
        for index in 245...259 {
            XCTAssertEqual(technical.marketObservation(on: days[index].dateTime),
                reference.observation(on: days[index].dateTime))
        }
        XCTAssertEqual(technical.marketLookupReloadCount, 2, "One replay must not reload for every row while inputs remain pending")
        last.kdK = nil
        technical.prepareMarketPricePathLookup(from: days[245].dateTime, through: last.dateTime,
            checkPendingChanges: true)
        XCTAssertNil(technical.marketObservation(on: last.dateTime))
        XCTAssertEqual(technical.marketLookupReloadCount, 3, "The next calculation boundary rechecks unsaved changes")
    }
}
