import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class MarketDataTests: XCTestCase {
    func testYahooIndexQuoteUsesTodayTimestampAndValidatedOHLC() throws {
        let html = """
        <title>加權指數(^TWII) 走勢圖 - Yahoo股市</title>
        <time datatime="2026/09/15 11:55">資料時間</time>
        <li><span>成交</span><span>45,746.97</span></li>
        <li><span>開盤</span><span>45,847.27</span></li>
        <li><span>最高</span><span>46,009.85</span></li>
        <li><span>最低</span><span>45,673.37</span></li>
        """
        let now = twDateTime.dateFromString("2026/09/15 11:56", format: "yyyy/MM/dd HH:mm")!
        let record = try MarketDataStore.parseYahooQuote(html, asOf: now)
        XCTAssertEqual(record.close, 45_746.97)
        XCTAssertEqual(record.open, 45_847.27)
        XCTAssertEqual(record.high, 46_009.85)
        XCTAssertEqual(record.low, 45_673.37)
        XCTAssertEqual(record.date, now.addingTimeInterval(-60))
        for invalid in [
            html.replacingOccurrences(of: "2026/09/15", with: "2026/09/14"),
            html.replacingOccurrences(of: "11:55", with: "12:02"),
            html.replacingOccurrences(of: "46,009.85", with: "45,000"),
            html.replacingOccurrences(of: "45,673.37", with: "46,000"),
            html.replacingOccurrences(of: "45,746.97", with: "--"),
            html.replacingOccurrences(of: "45,746.97", with: "nan"),
            html.replacingOccurrences(of: "加權指數(^TWII)", with: "台積電(2330.TW)")
        ] {
            XCTAssertThrowsError(try MarketDataStore.parseYahooQuote(invalid, asOf: now))
        }
    }

    func testYahooIndexRepeatsFromYesterdayAndCannotReplaceOfficialOrNewerQuote() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = twDateTime.dateFromString("2026/09/15 11:56", format: "yyyy/MM/dd HH:mm")!
        for offset in -100..<0 {
            let day = twDateTime.calendar.date(byAdding: .day, value: offset, to: now)!
            let close = 40_000 + Double(offset + 100) * 10
            context.insert(MarketDay(dateTime: day, indexOpen: close,
                indexHigh: close + 100, indexLow: close - 100, indexClose: close))
        }
        let store = MarketDataStore(modelContext: context)
        try store.rebuildPricePath()
        let prior = try MarketDay.fetchAll(in: context)
        let priorStates = prior.map(\.storedPricePathState)
        let first = MarketDataStore.Record(date: now, open: 41_000, high: 41_100, low: 40_900, close: 40_950)
        XCTAssertTrue(try store.applyYahooQuote(first, asOf: now))
        let today = try XCTUnwrap(MarketDay.fetchSameDay(as: now, in: context))
        XCTAssertFalse(today.isOfficial)
        XCTAssertEqual(today.quoteTime, now)
        XCTAssertEqual(try MarketIndexExtremaLookup(modelContext: context).observations.count, prior.count)
        XCTAssertEqual(try MarketPricePathLookup(modelContext: context).observation(on: now)?.date, today.dateTime)
        XCTAssertFalse(try store.applyYahooQuote(first, asOf: now))
        let second = MarketDataStore.Record(date: now.addingTimeInterval(60), open: 41_000,
            high: 41_150, low: 40_800, close: 40_850)
        XCTAssertTrue(try store.applyYahooQuote(second, asOf: second.date))
        var reference = PricePathRollingContext()
        for day in prior { _ = reference.update(date: day.dateTime, close: day.indexClose) }
        XCTAssertEqual(today.storedPricePathState,
            reference.update(date: today.dateTime, close: second.close))
        XCTAssertEqual(today.indexHighMax9, 41_150)
        XCTAssertEqual(today.indexLowMin9, min(40_800, prior.suffix(8).map(\.indexLow).min()!))
        XCTAssertEqual(prior.map(\.storedPricePathState), priorStates)
        XCTAssertFalse(try store.applyYahooQuote(first, asOf: second.date))
        XCTAssertEqual(today.indexClose, second.close)
        XCTAssertEqual(try store.applyOfficialRecords([.init(date: now, open: 41_000,
            high: 41_200, low: 40_700, close: 41_000)]), 1)
        XCTAssertTrue(today.isOfficial)
        XCTAssertNil(today.quoteTime)
        XCTAssertFalse(today.hasCurrentTechnicalValues)
        try store.rebuildPricePath()
        XCTAssertTrue(today.hasCurrentTechnicalValues)
        XCTAssertFalse(try store.applyYahooQuote(second, asOf: second.date))
        XCTAssertEqual(today.indexClose, 41_000)
    }

    func testYahooDayDoesNotCompleteOfficialHistoryPlan() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let stock = Stock(sId: "2330", sName: "台積電", group: "測試",
            dateFirst: date(2026, 1, 1), dateStart: date(2026, 9, 1))
        context.insert(stock)
        context.insert(MarketDay(dateTime: date(2026, 9, 14), indexOpen: 100,
            indexHigh: 101, indexLow: 99, indexClose: 100))
        context.insert(MarketDay(dateTime: date(2026, 9, 15), dataSource: "Yahoo", indexOpen: 100,
            indexHigh: 102, indexLow: 99, indexClose: 101))
        try context.save()
        let plan = try XCTUnwrap(MarketDataStore(modelContext: context).inputPlan(
            stocks: [stock], through: date(2026, 9, 15)))
        XCTAssertTrue(plan.months.contains(twDateTime.startOfMonth(date(2026, 9, 15))))
    }

    func testSameDayLookupIncludesRollingValuesAndNeverSubstitutesAnotherDay() {
        let yesterday = MarketPricePathLookup.Observation(date: twDateTime.time1330(date(2026, 9, 14)),
            phase: .seekingBottomLate, indexLow: 90, indexLowMin9: 90, indexHigh: 100, indexHighMax9: 110)
        let today = MarketPricePathLookup.Observation(date: twDateTime.time1330(date(2026, 9, 15)),
            phase: .seekingPeakLate, indexLow: 100, indexLowMin9: 90, indexHigh: 120, indexHighMax9: 120)
        let lookup = MarketPricePathLookup(observations: [today, yesterday])
        for time in ["2026/09/15 09:00", "2026/09/15 13:30", "2026/09/15 23:59"] {
            let decision = twDateTime.dateFromString(time, format: "yyyy/MM/dd HH:mm")!
            XCTAssertEqual(lookup.observation(on: decision), today)
            XCTAssertEqual(lookup.phase(on: decision), .seekingPeakLate)
        }
        XCTAssertNil(lookup.observation(on: date(2026, 9, 13)))
        XCTAssertNil(lookup.observation(on: date(2026, 9, 16)))
        XCTAssertEqual(MarketPricePathSellRule.contribution(marketPhase: lookup.phase(on: today.date),
            stockPhase: .seekingPeakLate, grade: .high), 1)
        XCTAssertEqual(MarketLow9SellRule.contribution(originalMatched: false,
            market: lookup.observation(on: today.date), stockPhase: .sideways, grade: .weak), 0)
        XCTAssertTrue(MarketHigh9BuyRule.suppressesVote(market: lookup.observation(on: today.date),
            grade: .fine, decisionPhase: .improvingWarning))
        XCTAssertTrue(RecoveryLowBuyRule.applies(grade: .low, inventory: 1, pricePhase: .seekingBottomEarly,
            marketHigh: today.indexHigh, marketHighMax9: today.indexHighMax9))
    }

    func testOfficialMarketChangesPersistEarliestSimulationBoundaryAcrossAllGroupedStocks() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let first = Stock(sId: "A", sName: "A", group: "A", dateFirst: date(2020, 1, 1), dateStart: date(2021, 1, 1))
        let second = Stock(sId: "B", sName: "B", group: "B", dateFirst: date(2020, 1, 1), dateStart: date(2021, 1, 1))
        let excluded = Stock(sId: "C", sName: "C", group: "", dateFirst: date(2020, 1, 1), dateStart: date(2021, 1, 1))
        [first, second, excluded].forEach { context.insert($0) }
        second.simulationDirtyFrom = date(2026, 8, 1)
        let store = MarketDataStore(modelContext: context)
        let record = MarketDataStore.Record(date: date(2026, 9, 15), open: 100, high: 110, low: 90, close: 105)
        XCTAssertEqual(try store.applyOfficialRecords([record]), 1)
        XCTAssertEqual(first.simulationDirtyFrom, date(2026, 9, 15))
        XCTAssertEqual(second.simulationDirtyFrom, date(2026, 8, 1))
        XCTAssertNil(excluded.simulationDirtyFrom)
        first.simulationDirtyFrom = nil
        XCTAssertEqual(try store.applyOfficialRecords([record]), 0)
        XCTAssertNil(first.simulationDirtyFrom)
        XCTAssertNil(first.technicalDirtyFrom)
    }

    func testFormalHigh9RuleMatchesAdoptedCandidateBoundaries() async {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        for raw in 0...11 {
            guard let phase = StrategyFitTrendPhase(rawValue: raw) else { continue }
            for grade: Trade.Grade in [.damn, .low, .weak, .none, .fine, .high, .wow] {
                for marketRaw in 1...9 {
                    let market = PricePathPhase(rawValue: marketRaw)!
                    let prior = MarketPricePathLookup.Observation(date: day, phase: market,
                        indexHigh: 110, indexHighMax9: 110)
                    XCTAssertEqual(MarketHigh9BuyRule.suppressesVote(market: prior, grade: grade, decisionPhase: phase),
                        grade >= .fine && market != .seekingPeakEarly && phase != .neutral)
                }
            }
        }
        XCTAssertFalse(MarketHigh9BuyRule.suppressesVote(market: nil, grade: .wow, decisionPhase: .improvingWarning))
        for high: Double? in [nil, 0, .nan, .infinity, 109] {
            let prior = MarketPricePathLookup.Observation(date: day, phase: .seekingPeakLate,
                indexHigh: high, indexHighMax9: 110)
            XCTAssertFalse(MarketHigh9BuyRule.suppressesVote(market: prior, grade: .wow, decisionPhase: .improvingWarning))
        }
        let lookup = MarketPricePathLookup(observations: [
            .init(date: twDateTime.startOfDay(day), phase: .seekingPeakLate, indexHigh: 110, indexHighMax9: 110)
        ])
        XCTAssertNil(lookup.observation(before: day))
        XCTAssertEqual(lookup.observation(before: day.addingTimeInterval(86400))?.indexHighMax9, 110)
    }

    func testHP04High9NeutralExclusionPreservesOtherPhases() async {
        for raw in 0...11 {
            guard let phase = StrategyFitTrendPhase(rawValue: raw) else { continue }
            XCTAssertTrue(InternalHP04High9Candidate.allowsGradePhase(phase, excludeNeutral: false))
            XCTAssertEqual(InternalHP04High9Candidate.allowsGradePhase(phase, excludeNeutral: true),
                           phase != .neutral)
        }
    }

    func testHP04High9MarketPhaseExclusionPreservesEarlierCandidates() async {
        XCTAssertTrue(InternalHP04High9Candidate.allowsMarketPhase(nil, excludeEarlyPeak: false))
        XCTAssertTrue(InternalHP04High9Candidate.allowsMarketPhase(.seekingPeakEarly, excludeEarlyPeak: false))
        XCTAssertFalse(InternalHP04High9Candidate.allowsMarketPhase(nil, excludeEarlyPeak: true))
        XCTAssertFalse(InternalHP04High9Candidate.allowsMarketPhase(.seekingPeakEarly, excludeEarlyPeak: true))
        for raw in 1...9 {
            let phase = PricePathPhase(rawValue: raw)!
            XCTAssertEqual(InternalHP04High9Candidate.allowsMarketPhase(phase, excludeEarlyPeak: true),
                           phase != .seekingPeakEarly)
        }
    }

    func testHP04High9UpperGradeBoundaryPreservesOriginalCandidate() async {
        for grade: Trade.Grade in [.damn, .low, .weak, .none, .fine, .high, .wow] {
            XCTAssertTrue(InternalHP04High9Candidate.allowsSuppression(grade: grade, upperOnly: false))
            XCTAssertEqual(InternalHP04High9Candidate.allowsSuppression(grade: grade, upperOnly: true),
                           [.fine, .high, .wow].contains(grade))
        }
    }

    func testHP04High9CandidateUsesStrictPriorMarketDayAndInclusiveHigh() async {
        let observations: [InternalMarketLow9Input.Observation] = [
            .init(date: "2026-09-03", low: 90, low9: 80, high: 110, high9: 110),
            .init(date: "2026-09-04", low: 90, low9: 80, high: 105, high9: 110),
            .init(date: "2026-09-07", low: 90, low9: 80, high: 120, high9: 120)
        ]
        XCTAssertFalse(InternalHP04High9Candidate.suppressesVote(before: "2026-09-03", observations: observations))
        XCTAssertTrue(InternalHP04High9Candidate.suppressesVote(before: "2026-09-04", observations: observations))
        XCTAssertFalse(InternalHP04High9Candidate.suppressesVote(before: "2026-09-07", observations: observations))
        XCTAssertTrue(InternalHP04High9Candidate.suppressesVote(before: "2026-09-08", observations: observations))
    }

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
        XCTAssertEqual(lookup.phase(before: twDateTime.time1330(date(2026, 9, 1)).addingTimeInterval(3600)), .sideways)
    }

    func testLow9LookupReloadRequiresValidTechnicalValuesAndUsesPriorCalendarDay() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let prior = MarketDay(dateTime: date(2026, 9, 4), indexOpen: 110, indexHigh: 111,
                              indexLow: 100, indexClose: 105)
        let today = MarketDay(dateTime: date(2026, 9, 7), indexOpen: 100, indexHigh: 105,
                              indexLow: 90, indexClose: 95)
        context.insert(prior)
        context.insert(today)
        try context.save()
        let beforeRebuild = try MarketPricePathLookup(modelContext: context)
        XCTAssertNil(beforeRebuild.observation(before: date(2026, 9, 7))?.indexLowMin9)
        prior.indexHighMax9 = 111
        prior.indexLowMin9 = 100
        prior.technicalStateVersion = MarketDataStore.technicalStateVersion
        today.indexHighMax9 = 111
        today.indexLowMin9 = 90
        today.technicalStateVersion = MarketDataStore.technicalStateVersion
        try context.save()
        let lookup = try MarketPricePathLookup(modelContext: ModelContext(container))
        let afterClose = twDateTime.time1330(date(2026, 9, 7)).addingTimeInterval(3600)
        XCTAssertEqual(lookup.observation(before: afterClose)?.indexLow, 100)
        XCTAssertEqual(lookup.observation(before: afterClose)?.indexLowMin9, 100)
        XCTAssertEqual(lookup.observation(before: date(2026, 9, 8))?.indexLowMin9, 90)
        XCTAssertNil(lookup.observation(before: date(2026, 9, 4)))
    }

    func testSameDayMarketDisplayLookupNeverFallsBackToPriorDay() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(MarketDay(
            dateTime: date(2026, 9, 2),
            indexOpen: 24_000,
            indexHigh: 24_200,
            indexLow: 23_900,
            indexClose: 24_100
        ))
        try context.save()

        XCTAssertEqual(
            try MarketDay.fetchSameDay(as: date(2026, 9, 2), in: context)?.indexClose,
            24_100
        )
        XCTAssertNil(
            try MarketDay.fetchSameDay(as: date(2026, 9, 3), in: context)
        )
    }

    func testRequiredHistoryUsesEarliestGroupedStockPreparationMonth() async throws {
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

    func testRebuildPersistsMarketPricePathWithoutColdStartRecalculation() async throws {
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
        for (index, day) in persisted.enumerated() {
            let window = persisted[max(0, index - 8)...index]
            XCTAssertEqual(day.indexHighMax9, window.map(\.indexHigh).max())
            XCTAssertEqual(day.indexLowMin9, window.map(\.indexLow).min())
        }
    }

    func testNineDayExtremaUseHighLowPartialWindowsAndMarketSessions() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        // Spaced sessions prove this is a nine-observation, not nine-day window.
        for offset in 0..<12 {
            context.insert(MarketDay(
                dateTime: date(2026, 1, 1 + offset * 2),
                indexOpen: 100, indexHigh: offset == 0 ? 500 : 110,
                indexLow: offset == 0 ? 10 : 90, indexClose: 100
            ))
        }
        let store = MarketDataStore(modelContext: context)
        try store.rebuildPricePath()
        let days = try MarketDay.fetchAll(in: context)
        for (index, day) in days.enumerated() {
            XCTAssertEqual(day.indexHighMax9, index < 9 ? 500 : 110)
            XCTAssertEqual(day.indexLowMin9, index < 9 ? 10 : 90)
            XCTAssertTrue(day.hasCurrentTechnicalValues)
        }
        let lookup = try MarketIndexExtremaLookup(modelContext: context)
        XCTAssertEqual(lookup.observations.map(\.observationCount), [1,2,3,4,5,6,7,8,9,9,9,9])
        let lateSameDay = calendar.date(byAdding: .hour, value: 23, to: date(2026, 1, 19))!
        XCTAssertEqual(lookup.observation(before: lateSameDay)?.indexHighMax9, 500)
        XCTAssertEqual(lookup.observation(before: date(2026, 1, 20))?.indexHighMax9, 110)
        XCTAssertNil(lookup.observation(before: date(2026, 1, 1)))
        let encoded = try JSONEncoder().encode(lookup.observations)
        XCTAssertEqual(try JSONDecoder().decode([MarketIndexExtremaLookup.Observation].self, from: encoded), lookup.observations)
    }

    func testExtremaRebuildAfterCorrectionBackfillAndAppendPreservesPricePath() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = MarketDataStore(modelContext: context)
        for offset in 0..<90 {
            let close = 10_000 + Double(offset * offset)
            context.insert(MarketDay(
                dateTime: calendar.date(byAdding: .day, value: offset, to: date(2020, 1, 2))!,
                indexOpen: close, indexHigh: close + 10, indexLow: close - 10, indexClose: close
            ))
        }
        try store.rebuildPricePath()
        var days = try MarketDay.fetchAll(in: context)
        let originalStates = days.map(\.storedPricePathState)
        days[50].indexHigh = 30_000
        days[50].indexLow = 1
        days[50].technicalStateVersion = 0
        XCTAssertThrowsError(try MarketIndexExtremaLookup(modelContext: context))
        try store.rebuildPricePath()
        XCTAssertEqual(days.map(\.storedPricePathState), originalStates)
        XCTAssertEqual(days[58].indexHighMax9, 30_000)
        XCTAssertNotEqual(days[59].indexHighMax9, 30_000)
        context.insert(MarketDay(dateTime: date(2020, 1, 1), indexOpen: 10_000,
                                 indexHigh: 40_000, indexLow: 1, indexClose: 10_000))
        context.insert(MarketDay(dateTime: date(2020, 5, 1), indexOpen: 20_000,
                                 indexHigh: 50_000, indexLow: 2, indexClose: 20_000))
        try store.rebuildPricePath()
        days = try MarketDay.fetchAll(in: context)
        var control = PricePathRollingContext()
        for (index, day) in days.enumerated() {
            XCTAssertEqual(day.storedPricePathState, control.update(date: day.dateTime, close: day.indexClose))
            let window = days[max(0, index - 8)...index]
            XCTAssertEqual(day.indexHighMax9, window.map(\.indexHigh).max())
            XCTAssertEqual(day.indexLowMin9, window.map(\.indexLow).min())
        }
    }

    func testMarketOnlyVersionMigrationNeedsNoHistoryDownload() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let stock = Stock(sId: "TEST", sName: "測試", group: "A",
                          dateFirst: date(2026, 1, 1), dateStart: date(2027, 1, 1))
        context.insert(stock)
        let day = MarketDay(dateTime: date(2026, 1, 2), indexOpen: 100,
                            indexHigh: 110, indexLow: 90, indexClose: 101)
        context.insert(day)
        day.technicalStateVersion = 1
        let store = MarketDataStore(modelContext: context)
        let before = await store.update(stocks: [stock], through: date(2026, 1, 2))
        XCTAssertEqual(before.requestedMonths, 0)
        XCTAssertTrue(before.isInputComplete)
        XCTAssertTrue(before.requiresTechnicalRebuild)
        XCTAssertFalse(before.isReadyForSimulation)
        try store.rebuildPricePath()
        let after = await store.update(stocks: [stock], through: date(2026, 1, 2))
        XCTAssertEqual(after.requestedMonths, 0)
        XCTAssertTrue(after.isReadyForSimulation)
        day.indexHighMax9 = nil
        let incomplete = await store.update(stocks: [stock], through: date(2026, 1, 2))
        XCTAssertTrue(incomplete.requiresTechnicalRebuild, "版本正確但欄位缺失仍須回填")
    }

    func testLegacySchemaAddsOptionalExtremaThenBackfillsWithoutChangingOHLC() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarketLegacy-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        try autoreleasepool {
            let schema = Schema([Stock.self, Trade.self, MarketV1Fixture.MarketDay.self])
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            ])
            container.mainContext.insert(MarketV1Fixture.MarketDay(date: twDateTime.time1330(date(2026, 1, 2))))
            try container.mainContext.save()
        }
        let schema = Schema([Stock.self, Trade.self, MarketDay.self])
        let migrated = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        ])
        let rows = try MarketDay.fetchAll(in: migrated.mainContext)
        let day = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(day.technicalStateVersion, 1)
        XCTAssertNil(day.indexHighMax9)
        XCTAssertNil(day.indexLowMin9)
        XCTAssertFalse(day.hasCurrentTechnicalValues)
        XCTAssertThrowsError(try MarketIndexExtremaLookup(modelContext: migrated.mainContext))
        try MarketDataStore(modelContext: migrated.mainContext).rebuildPricePath()
        XCTAssertEqual(day.indexOpen, 100)
        XCTAssertEqual(day.indexClose, 101)
        XCTAssertEqual(day.indexHighMax9, 110)
        XCTAssertEqual(day.indexLowMin9, 90)
        XCTAssertTrue(day.hasCurrentTechnicalValues)
    }

    func testFormalSellVoteRequiresBothLatePeaksAndHighOrWowGrade() {
        XCTAssertEqual(
            MarketPricePathSellRule.contribution(
                marketPhase: .seekingPeakLate,
                stockPhase: .seekingPeakLate,
                grade: .high
            ),
            1
        )
        XCTAssertEqual(
            MarketPricePathSellRule.contribution(
                marketPhase: .seekingPeakLate,
                stockPhase: .seekingPeakLate,
                grade: .wow
            ),
            1
        )
        XCTAssertEqual(
            MarketPricePathSellRule.contribution(
                marketPhase: .seekingPeakLate,
                stockPhase: .seekingPeakLate,
                grade: .fine
            ),
            0
        )
        XCTAssertEqual(
            MarketPricePathSellRule.contribution(
                marketPhase: .seekingPeakEarly,
                stockPhase: .seekingPeakLate,
                grade: .wow
            ),
            0
        )
    }
}

// Exact v1 market entity: intentionally has no nine-session extrema columns.
private enum MarketV1Fixture {
    @Model
    final class MarketDay {
        @Attribute(.unique) var dateTime: Date
        var dataSource: String
        var indexOpen: Double
        var indexHigh: Double
        var indexLow: Double
        var indexClose: Double
        var pricePathPhaseRaw: Int
        var pricePathBarrier: Double?
        var pricePathAnchorClose: Double?
        var pricePathExtremeClose: Double?
        var pricePathDaysSinceExtreme: Int
        var technicalStateVersion: Int

        init(date: Date) {
            dateTime = date
            dataSource = "TWSE-MI_5MINS_HIST"
            indexOpen = 100
            indexHigh = 110
            indexLow = 90
            indexClose = 101
            pricePathPhaseRaw = 0
            pricePathDaysSinceExtreme = 0
            technicalStateVersion = 1
        }
    }
}
