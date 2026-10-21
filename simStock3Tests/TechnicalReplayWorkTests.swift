import XCTest
@testable import simStock3

@MainActor
final class TechnicalReplayWorkTests: XCTestCase {
    private func date(_ index: Int) -> Date {
        twDateTime.calendar.date(byAdding: .day, value: index, to: twDateTime.dateFromString("2024/01/01")!)!
    }
    private func work(_ ordinary: [Int], _ path: [Int], count: Int = 420) -> TechnicalReplayWork {
        .init(version: 4, configuredStart: date(365), ordinary: ordinary.map(date), pricePath: path.map(date),
              allDates: (0..<count).map(date))
    }

    func testBackfillAndAppendKeepTheMatureGapAfterSerialization() throws {
        var pending = work(Array(0...260), Array(0...259))
        pending.merge(work(Array(400...402), Array(400...402)))
        let restored = try XCTUnwrap(TechnicalReplayWork.decode(pending.encoded(), version: 4, configuredStart: date(365)))
        XCTAssertEqual(restored, pending)
        XCTAssertEqual(restored.ordinaryDates(in: (0..<420).map(date)), (Array(0...260) + Array(400...402)).map(date))
        XCTAssertFalse(restored.allDates(in: [date(300)]).contains(date(300)))
        XCTAssertEqual(restored.ordinaryIntervals.count, 2)
    }

    func testCorrectionMergesOnlyOverlappingComponentIntervals() {
        var pending = work(Array(0...260), Array(0...259))
        pending.merge(work(Array(400...402), Array(400...402)))
        pending.merge(work(Array(300...419), Array(300...419)))
        XCTAssertEqual(pending.ordinaryDates(in: (0..<420).map(date)), (Array(0...260) + Array(300...419)).map(date))
        XCTAssertEqual(pending.pricePathDates(in: (0..<420).map(date)), (Array(0...259) + Array(300...419)).map(date))
    }

    func testCompletionConsumesOnlyTheWrittenComponentAndDates() {
        let pending = work(Array(0...260), Array(0...259))
        let remaining = pending.remaining(ordinaryDone: (0...260).map(date), pricePathDone: (0..<20).map(date),
                                          allDates: (0..<420).map(date))
        XCTAssertTrue(remaining.ordinaryIntervals.isEmpty)
        XCTAssertEqual(remaining.pricePathDates(in: (0..<420).map(date)), (20...259).map(date))
        XCTAssertFalse(remaining.isEmpty)
        XCTAssertEqual(pending.remaining(ordinaryDone: [], pricePathDone: [], allDates: (0..<420).map(date)), pending)
    }

    func testIntradayClockReplacementDoesNotLosePendingTradingDay() {
        let pending = work([10], [10])
        let replaced = twDateTime.time1330(date(10))
        XCTAssertEqual(pending.ordinaryDates(in: [replaced]), [replaced])
        XCTAssertTrue(pending.remaining(ordinaryDone: [replaced], pricePathDone: [replaced], allDates: [replaced]).isEmpty)
    }

    func testUnknownVersionConfigurationOrCorruptPayloadCannotBecomeTrustedWork() throws {
        let data = try work([10], [10]).encoded()
        XCTAssertNil(TechnicalReplayWork.decode(data, version: 5, configuredStart: date(365)))
        XCTAssertNil(TechnicalReplayWork.decode(data, version: 4, configuredStart: date(366)))
        XCTAssertNil(TechnicalReplayWork.decode(Data("broken".utf8), version: 4, configuredStart: date(365)))
        var future = work([10], [10]); future.formatVersion = 999
        XCTAssertNil(TechnicalReplayWork.decode(try future.encoded(), version: 4, configuredStart: date(365)))
    }

    func testLaterSettingKeepsOnlyVisiblePendingWorkAndChangesIdentity() throws {
        let pending = work(Array(0...260), Array(0...259))
        let clipped = pending.restricted(to: date(375), requestStart: date(10), allDates: (0..<420).map(date))
        XCTAssertEqual(clipped.ordinaryDates(in: (0..<420).map(date)), (10...260).map(date))
        XCTAssertEqual(clipped.pricePathDates(in: (0..<420).map(date)), (10...259).map(date))
        XCTAssertNotNil(TechnicalReplayWork.decode(try clipped.encoded(), version: 4, configuredStart: date(375)))
    }
}
