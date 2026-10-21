import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class OrdinaryTechnicalStatisticTests: XCTestCase {
    private func date(_ i: Int) -> Date { Date(timeIntervalSinceReferenceDate: Double(i) * 86400) }
    private func rows(_ count: Int) -> [Trade] {
        let stock = Stock(sId: "STAT", sName: "統計", group: "測試", dateFirst: date(0), dateStart: date(365))
        return (0..<count).map { i in
            let row = Trade(stock: stock, dateTime: date(i))
            row.priceClose = 100; row.volumeClose = 0; row.dataSource = "TWSE"
            row.tOsc = sin(Double(i) / 10); return row
        }
    }

    func testExactDependencyWindowsDoNotIncludeReadsOrRawOnlyStatistics() {
        let values = rows(600)
        let work = OrdinaryTechnicalStatistic.dependentWrites(ordinary: [date(10)], trades: values)
        XCTAssertEqual(work[.tOscMax9], (11...18).map(date))
        XCTAssertEqual(work[.tOscZ125], (11...134).map(date))
        XCTAssertEqual(work[.tOscZ250], (11...259).map(date))
        XCTAssertEqual(work.count, 32)
        XCTAssertNil(work[.tZ250]); XCTAssertNil(work[.vZ250]); XCTAssertNil(work[.vMax9])
        XCTAssertTrue(OrdinaryTechnicalStatistic.dependentWrites(ordinary: [], trades: values).isEmpty)
    }

    func testVolumeWindowsCountQualifiedObservationsAndCarryAcrossYahooRows() {
        let values = rows(510)
        for i in values.indices where i % 2 == 1 { values[i].dataSource = "Yahoo" }
        let work = OrdinaryTechnicalStatistic.dependentWrites(ordinary: [date(0)], trades: values)
        XCTAssertEqual(work[.vMa20DiffZ250], (1...499).map(date))
        XCTAssertEqual(work[.vMa20DiffZ125], (1...249).map(date))
        XCTAssertEqual(work[.vMa20DiffMax9], (1...17).map(date))
        XCTAssertEqual(work[.tOscZ250], (1...249).map(date))
        let yahooOnly = OrdinaryTechnicalStatistic.dependentWrites(ordinary: [date(1)], trades: values)
        XCTAssertNil(yahooOnly[.vMa20DiffZ250])
    }

    func testOnlyRequestedFieldIsWrittenUsingOriginalPopulationFormula() {
        let values = rows(300)
        values[299].tOscZ125 = 123; values[299].tKdK = 456; values[299].tUpdated = true
        let originalOSC = values.map(\.tOsc)
        OrdinaryTechnicalStatistic.update([.tOscZ250], trades: values, index: 299)
        let input = Array(originalOSC.suffix(250))
        let average = input.reduce(0, +) / 250
        let sd = sqrt(input.reduce(0) { $0 + pow($1 - average, 2) } / 250)
        XCTAssertEqual(values[299].tOscZ250, (input.last! - average) / sd)
        XCTAssertEqual(values[299].tOscZ125, 123); XCTAssertEqual(values[299].tKdK, 456)
        XCTAssertTrue(values[299].tUpdated); XCTAssertEqual(values.map(\.tOsc), originalOSC)
    }

    func testDurableRemainingFieldsDoNotExpandAgainAfterSourceWritesComplete() throws {
        let values = rows(600), dates = (0..<600).map(date)
        let base = TechnicalReplayWork(version: 4, configuredStart: date(365), ordinary: (0...249).map(date),
            pricePath: [], allDates: dates).includingStatisticDependencies(trades: values)
        XCTAssertEqual(base, base.includingStatisticDependencies(trades: values))
        let remaining = base.remaining(ordinaryDone: (0...249).map(date), pricePathDone: [], allDates: dates,
            statisticsDone: [date(250): [.tOscZ250]])
        let decoded = try XCTUnwrap(TechnicalReplayWork.decode(remaining.encoded(), version: 4, configuredStart: date(365)))
        XCTAssertTrue(decoded.ordinaryDates(in: dates).isEmpty)
        XCTAssertEqual(decoded, decoded.includingStatisticDependencies(trades: values))
        XCTAssertEqual(decoded.statisticDates(in: dates)[.tOscZ250], (251...498).map(date))
        XCTAssertEqual(decoded.statisticDates(in: dates)[.tKdKZ250], (250...498).map(date))
        XCTAssertEqual(decoded.statisticDates(in: dates)[.tOscMax9], (250...257).map(date))
        var merged = decoded
        merged.merge(.init(version: 4, configuredStart: date(365), ordinary: [date(550)], pricePath: [], allDates: dates))
        let expanded = merged.includingStatisticDependencies(trades: values)
        XCTAssertFalse(expanded.allDates(in: dates).contains(date(500)))
        XCTAssertEqual(expanded.statisticDates(in: dates)[.tOscZ250], ((251...498).map(date) + (551..<600).map(date)))
    }

    func testLegacyPendingFormatRetainsMatureBoundaryAndGainsMissingDependencies() throws {
        let values = rows(600), dates = (0..<600).map(date)
        let original = TechnicalReplayWork(version: 4, configuredStart: date(365), ordinary: (0...249).map(date),
            pricePath: [], allDates: dates)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original.encoded()) as? [String: Any])
        json["formatVersion"] = 1; json.removeValue(forKey: "statisticIntervals")
        let old = try XCTUnwrap(TechnicalReplayWork.decode(JSONSerialization.data(withJSONObject: json),
            version: 4, configuredStart: date(365)))
        let upgraded = old.includingStatisticDependencies(trades: values)
        XCTAssertEqual(upgraded.ordinaryDates(in: dates), (0...249).map(date))
        XCTAssertEqual(upgraded.statisticDates(in: dates)[.tOscZ250], (250...498).map(date))
        XCTAssertEqual(upgraded.formatVersion, 2)
    }
}
