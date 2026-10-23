import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class ColdStartSourceMarketTests: XCTestCase {
    private func date(_ text: String) -> Date { twDateTime.dateFromString(text)! }

    private func storedFixture() throws -> (URL, ModelContainer, Stock) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema,
            url: directory.appendingPathComponent("source.store")))
        container.mainContext.autosaveEnabled = false
        let stock = Stock(sId: "SOURCE", sName: "來源", group: "A",
            dateFirst: date("2010/01/01"), dateStart: date("2024/01/01"))
        stock.twseListingDate = date("2023/06/20")
        container.mainContext.insert(stock)
        try container.mainContext.save()
        return (directory, container, stock)
    }

    func testListingEvidenceIsExplicitReusedAndInvalidatedByEarlierPrice() throws {
        let (directory, container, stock) = try storedFixture()
        defer { try? FileManager.default.removeItem(at: directory); withExtendedLifetime(container) {} }
        let context = container.mainContext
        let reads = OfficialPriceReadSession(context: context)
        let end = date("2023/07/03")
        XCTAssertEqual(stock.unconfirmedHistoryMonths(through: end).first, date("2023/01/01"),
            "Unknown listing applicability must retain source responsibility")
        XCTAssertEqual(reads.ledger.listingEvidenceReads, 0, "Rendering a badge never queries old prices")
        try reads.prepareSourceEvidence(for: [stock])
        XCTAssertEqual(stock.unconfirmedHistoryMonths(through: end), [date("2023/06/01"), date("2023/07/01")])
        XCTAssertEqual(reads.ledger.listingEvidenceReads, 1)
        try reads.prepareSourceEvidence(for: [stock])
        XCTAssertEqual(reads.ledger.listingEvidenceReads, 1, "No input event means no repeated scan")
        try reads.ledger.persist()

        let reopenedContext = ModelContext(container)
        let reopened = try XCTUnwrap(Stock.fetch(in: reopenedContext).first)
        let reopenedLedger = UpdateWorkLedger.shared(in: reopenedContext)
        reopenedLedger.refresh()
        XCTAssertEqual(reopenedLedger.listingProof(for: reopened)?.hasEarlierOfficialPrice, false)
        XCTAssertEqual(reopened.unconfirmedHistoryMonths(through: end).first, date("2023/06/01"))
        XCTAssertEqual(reopenedLedger.listingEvidenceReads, 0)

        let older = Trade(stock: stock, dateTime: date("2022/01/03"), dataSource: "TWSE")
        older.priceClose = 100
        context.insert(older)
        XCTAssertNil(reads.ledger.listingProof(for: stock), "Unsaved input cannot use old evidence")
        try context.save()
        reads.refreshChanges()
        XCTAssertNil(reads.ledger.listingProof(for: stock))
        try reads.prepareSourceEvidence(for: [stock])
        XCTAssertEqual(reads.ledger.listingProof(for: stock)?.hasEarlierOfficialPrice, true,
            "A relisting cannot hide retained earlier official history")
        XCTAssertEqual(stock.unconfirmedHistoryMonths(through: end).first, date("2023/01/01"))
    }

    func testListingEvidenceDoesNotTrustYahooInvalidPricesOrUnsavedChanges() throws {
        let (directory, container, stock) = try storedFixture()
        defer { try? FileManager.default.removeItem(at: directory); withExtendedLifetime(container) {} }
        let context = container.mainContext
        let ledger = UpdateWorkLedger.shared(in: context)
        let yahoo = Trade(stock: stock, dateTime: date("2022/01/03"), dataSource: "yahoo")
        yahoo.priceClose = 100
        context.insert(yahoo)
        let invalid = Trade(stock: stock, dateTime: date("2022/01/04"), dataSource: "TWSE")
        invalid.priceClose = 0
        context.insert(invalid)
        try ledger.confirmListingEvidence(for: stock)
        XCTAssertNil(ledger.listingProof(for: stock))
        XCTAssertEqual(ledger.listingEvidenceReads, 0)
        try context.save()
        try ledger.confirmListingEvidence(for: stock)
        XCTAssertEqual(ledger.listingProof(for: stock)?.hasEarlierOfficialPrice, false)
        invalid.priceClose = 100
        try context.save(); ledger.refresh()
        XCTAssertNil(ledger.listingProof(for: stock))
        try ledger.confirmListingEvidence(for: stock)
        XCTAssertEqual(ledger.listingProof(for: stock)?.hasEarlierOfficialPrice, true)
        stock.group = ""
        try context.save(); ledger.refresh()
        let before = ledger.listingEvidenceReads
        try ledger.confirmListingEvidence(for: stock)
        XCTAssertEqual(ledger.listingEvidenceReads, before, "Ungrouped history is not startup source work")
    }

    func testMultiStockSourceBatchReadsJournalOnceAndRefreshesAfterSave() throws {
        let (directory, container, first) = try storedFixture()
        defer { try? FileManager.default.removeItem(at: directory); withExtendedLifetime(container) {} }
        let context = container.mainContext
        var stocks = [first]
        for id in ["SECOND", "THIRD"] {
            let stock = Stock(sId: id, sName: id, group: "A",
                dateFirst: date("2010/01/01"), dateStart: date("2024/01/01"))
            stock.twseListingDate = date("2023/06/20")
            context.insert(stock)
            stocks.append(stock)
        }
        try context.save()
        let reads = OfficialPriceReadSession(context: context)
        let ledger = reads.ledger
        var before = ledger.journalReads
        try reads.prepareSourceEvidence(for: stocks)
        XCTAssertEqual(ledger.journalReads - before, 1, "One refreshed boundary serves the entire batch")
        XCTAssertEqual(ledger.listingEvidenceReads, 3)
        before = ledger.journalReads
        for stock in stocks { _ = try reads.stockTrades(stock) }
        for stock in stocks { _ = try reads.stockTrades(stock) }
        XCTAssertEqual(ledger.journalReads - before, 0, "Reads and cache hits reuse the verified boundary")
        before = ledger.journalReads
        try reads.prepareSourceEvidence(for: stocks)
        XCTAssertEqual(ledger.journalReads - before, 1)
        XCTAssertEqual(ledger.listingEvidenceReads, 3, "A repeated unchanged batch reuses source evidence")

        let older = Trade(stock: first, dateTime: date("2023/02/03"), dataSource: "TWSE")
        older.priceClose = 100
        context.insert(older)
        try context.save()
        before = ledger.journalReads
        let refreshed = try reads.stockTrades(first)
        XCTAssertEqual(ledger.journalReads - before, 1, "A save must refresh before trusting cached source state")
        XCTAssertEqual(refreshed.map(\.dateTime), [older.dateTime], "Saved insertion invalidates the cached empty window")
        XCTAssertEqual(ledger.listingProof(for: first)?.hasEarlierOfficialPrice, true)
        XCTAssertEqual(ledger.listingEvidenceReads, 4)
        before = ledger.journalReads
        _ = try reads.stockTrades(first)
        XCTAssertEqual(ledger.journalReads - before, 0)

        before = ledger.journalReads
        try ledger.confirmListingEvidence(for: first)
        XCTAssertEqual(ledger.journalReads - before, 1, "Standalone callers still validate the journal")
    }

    func testHistoryBadgeUsesOnlyUsableOfficialPricesInsideRequestedWindow() throws {
        let (directory, container, stock) = try storedFixture()
        defer { try? FileManager.default.removeItem(at: directory); withExtendedLifetime(container) {} }
        let context = container.mainContext
        stock.twseListingDate = nil
        let retained = Trade(stock: stock, dateTime: date("2022/12/30"))
        retained.priceClose = 100
        context.insert(retained)
        try context.save()
        XCTAssertNil(try Trade.windowEndpoint(in: context, for: stock, ascending: false, officialOnly: true))
        XCTAssertTrue(stock.needsTWSEHistoryBackfill(in: context), "Retained old prices cannot satisfy the active window")

        let valid = Trade(stock: stock, dateTime: date("2023/01/03"))
        valid.priceClose = 100
        let invalid = Trade(stock: stock, dateTime: date("2023/02/01"))
        invalid.priceClose = 0
        let yahoo = Trade(stock: stock, dateTime: date("2023/03/01"), dataSource: "Yahoo")
        yahoo.priceClose = 100
        for row in [valid, invalid, yahoo] { context.insert(row) }
        try stock.confirmHistoryMonth(date("2023/01/01"), through: date("2023/02/01"))
        try context.save()
        XCTAssertEqual(try Trade.windowEndpoint(in: context, for: stock, ascending: false, officialOnly: true)?.dateTime, valid.dateTime)
        XCTAssertFalse(stock.needsTWSEHistoryBackfill(in: context), "Invalid and Yahoo rows cannot extend the official receipt requirement")
        invalid.priceClose = 100
        XCTAssertTrue(stock.needsTWSEHistoryBackfill(in: context), "Pending valid official corrections participate before save")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Trade>()), 4, "No retained raw price is deleted")
    }

    func testManualSummaryKeepsAllSurvivingIntentWithoutDateOrder() throws {
        let (directory, container, stock) = try storedFixture()
        defer { try? FileManager.default.removeItem(at: directory); withExtendedLifetime(container) {} }
        let context = container.mainContext
        let older = Trade(stock: stock, dateTime: date("2020/01/01"), dataSource: "TWSE")
        older.simInvestByUser = -1
        let newer = Trade(stock: stock, dateTime: date("2023/07/03"), dataSource: "TWSE")
        newer.simInvestByUser = 1; newer.simReversed = "B-"
        context.insert(newer); context.insert(older)
        try context.save()
        XCTAssertEqual(try Stock.repairUserActionSummaries(for: [stock], in: context), 1)
        XCTAssertEqual(stock.simInvestUser, 2)
        XCTAssertTrue(stock.simReversed)
        XCTAssertEqual(older.simInvestByUser, -1)
        XCTAssertEqual(newer.simReversed, "B-")
        XCTAssertEqual(try Stock.repairUserActionSummaries(for: [stock], in: context), 0)
    }

    func testMarketLookupIsLazyAndLoadsRequestedDatesWithoutArbitraryLimit() throws {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let origin = date("2023/01/01")
        let dates = (0..<360).map { twDateTime.calendar.date(byAdding: .day, value: $0, to: origin)! }
        for (index, date) in dates.enumerated() {
            let close = 10_000 + Double(index)
            context.insert(MarketDay(dateTime: date, indexOpen: close,
                indexHigh: close + 10, indexLow: close - 10, indexClose: close))
        }
        try MarketDataStore(modelContext: context).rebuildPricePath()
        let predecessors = try MarketDay.fetchOfficialRawPredecessors(before: twDateTime.startOfDay(dates[350]), in: context)
        XCTAssertEqual(predecessors.map(\.dateTime), dates[101..<350].map { twDateTime.time1330($0) })
        let reference = try MarketPricePathLookup(modelContext: context)
        let technical = Technical(modelContext: context)
        defer { technical.invalidateTimer(); withExtendedLifetime(container) {} }
        XCTAssertEqual(technical.marketLookupReloadCount, 0)
        XCTAssertEqual(technical.marketLookupObservationCount, 0)
        technical.prepareMarketPricePathLookup(from: dates[40], through: dates[350])
        XCTAssertEqual(technical.marketLookupObservationCount, 311, "A real replay range may exceed 251 dates")
        for index in [40, 249, 350] {
            XCTAssertEqual(technical.marketObservation(on: dates[index]), reference.observation(on: dates[index]))
        }
        XCTAssertEqual(technical.marketLookupReloadCount, 1)
        technical.liveMarketContext = .init(asOf: dates[359], previousTradingDay: dates[357])
        context.delete(try XCTUnwrap(MarketDay.fetchSameDay(as: dates[359], in: context)))
        try context.save()
        XCTAssertEqual(technical.marketObservation(on: dates[359]), reference.observation(on: dates[357]))

        let reads = OfficialPriceReadSession(context: context)
        XCTAssertEqual(try reads.marketDays(from: dates[300], through: twDateTime.time1330(dates[305])).count, 6)
        XCTAssertEqual(try reads.marketDays(from: dates[302], through: twDateTime.time1330(dates[304])).count, 3)
        XCTAssertEqual(reads.marketHistoryReads, 1)
    }

    func testBoundedMarketReadSessionRetainsDemandAcrossSavedChanges() throws {
        let (directory, container, _) = try storedFixture()
        defer { try? FileManager.default.removeItem(at: directory); withExtendedLifetime(container) {} }
        let context = container.mainContext
        let january = twDateTime.time1330(date("2023/01/03"))
        let february = twDateTime.time1330(date("2023/02/03"))
        let march = twDateTime.time1330(date("2023/03/03"))
        for day in [twDateTime.time1330(date("2020/01/03")), january, february, march] {
            context.insert(MarketDay(dateTime: day, indexOpen: 100,
                indexHigh: 101, indexLow: 99, indexClose: 100))
        }
        try context.save()
        let reads = OfficialPriceReadSession(context: context)
        XCTAssertEqual(try reads.marketDays(from: january, through: february).map(\.dateTime), [january, february])
        let insertedDate = twDateTime.time1330(date("2023/01/16"))
        context.insert(MarketDay(dateTime: insertedDate, indexOpen: 110,
            indexHigh: 111, indexLow: 109, indexClose: 110))
        try context.save()
        XCTAssertEqual(try reads.marketDays(from: january, through: insertedDate).map(\.dateTime), [january, insertedDate],
            "A narrow read after save must include new inputs and return only its requested dates")
        XCTAssertEqual(reads.marketHistoryReads, 2)
        XCTAssertEqual(try reads.marketDays(from: january, through: february).map(\.dateTime), [january, insertedDate, february])
        XCTAssertEqual(reads.marketHistoryReads, 2, "Invalidation retains this pass's already requested bounds")
        XCTAssertEqual(try reads.marketDays(from: january, through: march).map(\.dateTime), [january, insertedDate, february, march])
        XCTAssertEqual(reads.marketHistoryReads, 3)
        XCTAssertEqual(try reads.marketDays(from: february, through: february).map(\.dateTime), [february])
        XCTAssertEqual(reads.marketHistoryReads, 3)
    }
}
