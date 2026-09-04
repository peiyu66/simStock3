import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class MarketDataTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    func testParserRequiresOfficialFieldsAndExcludesDatesAfterCompletedDay() throws {
        let payload: [String: Any] = [
            "stat": "OK",
            "fields": ["日期", "開盤指數", "最高指數", "最低指數", "收盤指數"],
            "data": [
                ["115/09/01", "24,000.10", "24,120.50", "23,980.00", "24,100.25"],
                ["115/09/02", "24,100.25", "24,200.00", "24,050.00", "24,180.00"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let records = try MarketDataStore.parseMonth(
            data,
            expectedMonth: date(2026, 9, 1),
            cutoff: date(2026, 9, 1)
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].close, 24_100.25)
        XCTAssertEqual(records[0].high, 24_120.50)
    }

    func testStrictPriorLookupNeverUsesSameDay() {
        let lookup = MarketPricePathLookup(observations: [
            .init(date: twDateTime.time1330(date(2026, 8, 31)), phase: .sideways),
            .init(date: twDateTime.time1330(date(2026, 9, 1)), phase: .seekingPeakLate),
            .init(date: twDateTime.time1330(date(2026, 9, 3)), phase: .seekingBottomLate),
        ])

        XCTAssertEqual(
            lookup.phase(before: twDateTime.time1330(date(2026, 9, 1))),
            .sideways
        )
        XCTAssertEqual(
            lookup.phase(before: twDateTime.time1330(date(2026, 9, 2))),
            .seekingPeakLate
        )
        XCTAssertNil(lookup.phase(before: twDateTime.time1330(date(2026, 8, 31))))
    }

    func testRequiredHistoryUsesEarliestGroupedStockPreparationMonth() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let later = Stock(
            sId: "LATE", sName: "晚", group: "A",
            dateFirst: date(2020, 2, 1), dateStart: date(2021, 2, 1)
        )
        let earlier = Stock(
            sId: "EARLY", sName: "早", group: "B",
            dateFirst: date(2017, 7, 1), dateStart: date(2018, 7, 1)
        )
        let ungrouped = Stock(
            sId: "NONE", sName: "未選", group: "",
            dateFirst: date(2012, 1, 1), dateStart: date(2013, 1, 1)
        )
        context.insert(later)
        context.insert(earlier)
        context.insert(ungrouped)

        XCTAssertEqual(
            MarketDataStore.requiredStartMonth(for: [later, earlier, ungrouped]),
            date(2017, 7, 1)
        )
    }

    func testRebuildPersistsMarketPricePathWithoutColdStartRecalculation() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarketDataTests-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
            }
        }
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let configuration = ModelConfiguration(
            "MarketDataPersistence",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )

        var expected: [(Int, Double?)] = []
        autoreleasepool {
            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = container.mainContext
                for offset in 0..<90 {
                    let close = 10_000 + Double(offset * offset)
                    context.insert(MarketDay(
                        dateTime: calendar.date(byAdding: .day, value: offset, to: date(2020, 1, 1))!,
                        indexOpen: close,
                        indexHigh: close + 10,
                        indexLow: close - 10,
                        indexClose: close
                    ))
                }
                try context.save()
                try MarketDataStore(modelContext: context).rebuildPricePath()
                expected = try MarketDay.fetchAll(in: context).map {
                    ($0.pricePathPhaseRaw, $0.pricePathBarrier)
                }
            } catch {
                XCTFail("建立大盤持久資料失敗：\(error)")
            }
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let persisted = try MarketDay.fetchAll(in: reopened.mainContext)
        XCTAssertEqual(persisted.count, 90)
        XCTAssertEqual(persisted.map(\.pricePathPhaseRaw), expected.map(\.0))
        XCTAssertEqual(persisted.map(\.pricePathBarrier), expected.map(\.1))
        XCTAssertTrue(persisted.allSatisfy {
            $0.technicalStateVersion == MarketDataStore.technicalStateVersion
        })
    }

    func testFormalSellVoteRequiresBothLatePeaksAndHighOrWowGrade() {
        XCTAssertEqual(
            MarketPricePathSellRule.contribution(
                priorMarketPhase: .seekingPeakLate,
                stockPhase: .seekingPeakLate,
                grade: .high
            ),
            1
        )
        XCTAssertEqual(
            MarketPricePathSellRule.contribution(
                priorMarketPhase: .seekingPeakLate,
                stockPhase: .seekingPeakLate,
                grade: .wow
            ),
            1
        )
        XCTAssertEqual(
            MarketPricePathSellRule.contribution(
                priorMarketPhase: .seekingPeakLate,
                stockPhase: .seekingPeakLate,
                grade: .fine
            ),
            0
        )
        XCTAssertEqual(
            MarketPricePathSellRule.contribution(
                priorMarketPhase: .seekingPeakEarly,
                stockPhase: .seekingPeakLate,
                grade: .wow
            ),
            0
        )
    }
}
