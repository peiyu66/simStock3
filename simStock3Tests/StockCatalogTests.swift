import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class StockCatalogTests: XCTestCase {
    func testParserReadsOfficialChineseKeysAndNormalizesWhitespace() throws {
        let data = """
        [
          {"公司代號":" 2330 ","公司簡稱":" 台積電 "},
          {"公司代號":"2317","公司簡稱":"鴻海"}
        ]
        """.data(using: .utf8)!

        XCTAssertEqual(
            try TWSEStockCatalogParser.decode(data, minimumCount: 2),
            [
                TWSEStockCatalogEntry(code: "2317", shortName: "鴻海"),
                TWSEStockCatalogEntry(code: "2330", shortName: "台積電")
            ]
        )
    }

    func testParserRejectsIncompleteCatalog() {
        let data = """
        [{"公司代號":"2330","公司簡稱":"台積電"}]
        """.data(using: .utf8)!

        XCTAssertThrowsError(try TWSEStockCatalogParser.decode(data, minimumCount: 2))
    }

    func testApplyPreservesTrackedStockAndMarksMissingStockUnlisted() async throws {
        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let tracked = Stock(
            sId: "2330",
            sName: "舊名稱",
            group: "股群_1",
            dateFirst: Date(timeIntervalSince1970: 1),
            dateStart: Date(timeIntervalSince1970: 2),
            simInvestAuto: 2,
            simMoneyBase: 600
        )
        let missing = Stock(
            sId: "9999",
            sName: "已下市",
            group: "股群_2",
            dateFirst: Date(timeIntervalSince1970: 3),
            dateStart: Date(timeIntervalSince1970: 4),
            simInvestAuto: 1,
            simMoneyBase: 70
        )
        context.insert(tracked)
        context.insert(missing)
        try context.save()

        let updater = StockCatalogUpdater(modelContext: context)
        let summary = try updater.apply([
            TWSEStockCatalogEntry(code: "2330", shortName: "台積電"),
            TWSEStockCatalogEntry(code: "2317", shortName: "鴻海")
        ])

        XCTAssertEqual(summary.inserted, 1)
        XCTAssertEqual(summary.renamed, 1)
        XCTAssertEqual(tracked.sName, "台積電")
        XCTAssertEqual(tracked.group, "股群_1")
        XCTAssertEqual(tracked.simMoneyBase, 600)
        XCTAssertTrue(tracked.isListed)
        XCTAssertFalse(missing.isListed)

        let catalogOnly = try XCTUnwrap(Stock.fetch(in: context, sId: ["2317"]).first)
        XCTAssertEqual(catalogOnly.group, "")
        XCTAssertEqual(catalogOnly.simMoneyBase, 0)
        XCTAssertTrue(catalogOnly.isListed)
        XCTAssertEqual(
            try Stock.fetchGrouped(in: context).map(\.sId),
            ["2330", "9999"]
        )
    }

    func testMissingLastSuccessRequiresImmediateRefresh() {
        XCTAssertTrue(StockCatalogUpdater.needsRefresh(lastSuccess: nil))
        XCTAssertFalse(StockCatalogUpdater.needsRefresh(
            lastSuccess: Date(),
            now: Date(),
            refreshInterval: 60
        ))
    }

    func testSearchTreatsSpacesAndCommasAsEquivalentSeparators() {
        XCTAssertEqual(StockCatalogSearch.keywords(from: "2 台"), ["2", "台"])
        XCTAssertEqual(StockCatalogSearch.keywords(from: "2,台"), ["2", "台"])
        XCTAssertEqual(StockCatalogSearch.keywords(from: "2，台"), ["2", "台"])
    }

    func testSearchRequiresEveryKeywordAcrossCodeOrName() {
        let keywords = StockCatalogSearch.keywords(from: "2 台")

        XCTAssertTrue(StockCatalogSearch.matches(
            code: "2330",
            name: "台積電",
            keywords: keywords
        ))
        XCTAssertFalse(StockCatalogSearch.matches(
            code: "2330",
            name: "鴻海",
            keywords: keywords
        ))
        XCTAssertFalse(StockCatalogSearch.matches(
            code: "1101",
            name: "台泥",
            keywords: keywords
        ))
    }
}
