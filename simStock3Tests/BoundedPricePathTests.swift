import Foundation
import XCTest
@testable import simStock3

final class BoundedPricePathTests: XCTestCase {
    func testFortyReturnsRequireFortyOnePricesInsideTheWindow() {
        let points = makePoints(Array(repeating: 100, count: 41))
        var context = BoundedPricePathContext()
        for index in 0..<40 {
            XCTAssertNil(context.update(date: points[index].date, close: points[index].close))
        }
        let state = context.update(date: points[40].date, close: points[40].close)
        assertState(state, equals: PricePathStoredState(
            phase: .sideways, barrier: 0.05, anchorClose: 100,
            extremeClose: 100, daysSinceExtreme: 0
        ))
        assertState(state, equals: oracle(points))
    }

    func testEveryFieldMatchesIndependentColdReplayAtEveryStep() {
        let points = variedPoints(count: 620)
        var context = BoundedPricePathContext()
        for index in points.indices {
            let state = context.update(date: points[index].date, close: points[index].close)
            assertState(state, equals: oracle(Array(points[...index])), message: "index \(index)")
        }
    }

    func test249250251ObservationBoundaryUsesAtMost250IncludingTarget() {
        XCTAssertEqual(BoundedPricePathContext.maximumObservationCount, 250)
        let points = risingPoints(count: 251)
        for count in [249, 250, 251] {
            let prefix = Array(points.prefix(count))
            var context = BoundedPricePathContext(priorPoints: Array(prefix.dropLast()))
            let target = prefix[count - 1]
            let state = context.update(date: target.date, close: target.close)
            assertState(state, equals: oracle(prefix), message: "count \(count)")
            // At 251 the first raw price is outside the target's window.
            let firstIncludedIndex = max(0, count - 250)
            XCTAssertEqual(state?.anchorClose, points[firstIncludedIndex + 40].close)
        }
    }

    func testReplacingAllHistoryBeforeTheLast250PricesCannotChangeTarget() {
        let points = variedPoints(count: 560)
        var altered = points
        for index in 0..<(points.count - 250) {
            altered[index] = RollingPricePathPoint(
                date: points[index].date,
                close: index.isMultiple(of: 2) ? 10_000 + Double(index) : 1 + Double(index) / 1_000
            )
        }
        let original = replay(points).last ?? nil
        let changed = replay(altered).last ?? nil
        XCTAssertNotNil(original)
        assertState(changed, equals: original)
        assertState(changed, equals: oracle(points))
    }

    func testDifferentBatchSeedsAndColdStartsMatchUninterruptedResults() {
        let points = variedPoints(count: 560)
        let uninterrupted = replay(points)
        for batchSize in [1, 7, 40, 125, 249, 250, 251] {
            var context = BoundedPricePathContext()
            for index in points.indices {
                if index.isMultiple(of: batchSize) {
                    context = BoundedPricePathContext(priorPoints: Array(points[..<index]))
                }
                let state = context.update(date: points[index].date, close: points[index].close)
                assertState(state, equals: uninterrupted[index], message: "batch \(batchSize), index \(index)")
                assertState(state, equals: oracle(Array(points[...index])), message: "cold index \(index)")
            }
        }
    }

    func testSeedUsesLast249ValidPricesInsteadOfLast249InputRows() {
        let points = variedPoints(count: 400)
        let target = points[399]
        var seed: [RollingPricePathPoint] = []
        for (index, point) in points.dropLast().enumerated() {
            seed.append(point)
            let invalid: Double = index.isMultiple(of: 2) ? .nan : 0
            seed.append(RollingPricePathPoint(date: point.date.addingTimeInterval(1), close: invalid))
        }
        var context = BoundedPricePathContext(priorPoints: seed)
        assertState(
            context.update(date: target.date, close: target.close),
            equals: oracle(points)
        )
    }

    func testInvalidPricesReturnNilWithoutChangingValidSequence() {
        let points = variedPoints(count: 310)
        var context = BoundedPricePathContext(priorPoints: Array(points.prefix(280)))
        let before = context
        for invalid in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(context.update(date: points[280].date, close: invalid))
            XCTAssertEqual(context, before)
        }
        assertState(
            context.update(date: points[280].date, close: points[280].close),
            equals: oracle(Array(points.prefix(281)))
        )
    }

    func testDuplicateDateStartsNewSequenceAndRequiresFreshWarmup() {
        let points = variedPoints(count: 100)
        var context = BoundedPricePathContext(priorPoints: points)
        let date = points[99].date
        XCTAssertNil(context.update(date: date, close: 100))
        let replacement = makePoints(Array(repeating: 100, count: 41), startingAt: date)
        for index in 1..<40 {
            XCTAssertNil(context.update(date: replacement[index].date, close: replacement[index].close))
        }
        assertState(
            context.update(date: replacement[40].date, close: replacement[40].close),
            equals: oracle(replacement)
        )
    }

    func testDecreasingDateCannotUseLaterSeedPrices() {
        let points = variedPoints(count: 400)
        var context = BoundedPricePathContext(priorPoints: points)
        let target = points[100]
        XCTAssertNil(context.update(date: target.date, close: target.close))
        let restarted = Array(points[100...140])
        for point in restarted.dropFirst().dropLast() {
            XCTAssertNil(context.update(date: point.date, close: point.close))
        }
        let last = restarted[40]
        assertState(context.update(date: last.date, close: last.close), equals: oracle(restarted))
    }

    func testSeedResetsAtDuplicateOrDecreasingDateAndExcludesInvalidCloses() {
        let points = variedPoints(count: 200)
        for restartIndex in [100, 199] {
            let fresh = makePoints(Array(repeating: 120, count: 41), startingAt: points[restartIndex].date)
            var seed = points
            seed.append(RollingPricePathPoint(date: fresh[0].date, close: 0))
            seed.append(contentsOf: fresh.dropLast())
            var context = BoundedPricePathContext(priorPoints: seed)
            assertState(
                context.update(date: fresh[40].date, close: fresh[40].close),
                equals: oracle(fresh),
                message: "restart index \(restartIndex)"
            )
        }
    }

    func testLongTrendCannotRetainAnAnchorOutsideItsRawWindow() {
        let points = risingPoints(count: 600)
        var original = PricePathRollingContext()
        var originalState: PricePathStoredState?
        for point in points {
            originalState = original.update(date: point.date, close: point.close)
        }
        let bounded = replay(points).last ?? nil
        XCTAssertEqual(originalState?.anchorClose, points[40].close)
        XCTAssertEqual(bounded?.anchorClose, points[390].close)
        XCTAssertNotEqual(bounded?.anchorClose, originalState?.anchorClose)
        XCTAssertEqual(bounded?.phase, .seekingPeakLate)
        XCTAssertEqual(bounded?.daysSinceExtreme, 0)
        assertState(bounded, equals: oracle(points))
    }

    func testFuturePricesDoNotChangeAnyEarlierResult() {
        let prefix = variedPoints(count: 300)
        let future = makePoints(
            (0..<80).map { $0.isMultiple(of: 2) ? 10_000 : 1 },
            startingAt: prefix[299].date.addingTimeInterval(86_400)
        )
        let prefixStates = replay(prefix)
        let allStates = replay(prefix + future)
        for index in prefix.indices {
            assertState(allStates[index], equals: prefixStates[index], message: "index \(index)")
            assertState(allStates[index], equals: oracle(Array(prefix[...index])))
        }
    }

    func testCopiedContextsKeepIndependentHypothesesAndFormalResult() {
        let points = variedPoints(count: 400)
        let formal = points[399]
        let seed = BoundedPricePathContext(priorPoints: Array(points.dropLast()))
        for multiplier in [1.2, 0.7, 1.0] {
            var hypothesis = seed
            let target = RollingPricePathPoint(date: formal.date, close: formal.close * multiplier)
            let result = hypothesis.update(date: target.date, close: target.close)
            assertState(result, equals: oracle(Array(points.dropLast()) + [target]))
        }
        var restored = seed
        assertState(
            restored.update(date: formal.date, close: formal.close),
            equals: oracle(points)
        )
    }

    func testBatchReferenceMatchesIndependentOracleAndRejectsInvalidTarget() {
        let points = variedPoints(count: 400)
        for count in [0, 1, 40, 41, 60, 61, 249, 250, 251, 400] {
            let prefix = Array(points.prefix(count))
            assertState(
                BoundedPricePathContext.referenceState(points: prefix),
                equals: oracle(prefix), message: "count \(count)"
            )
        }
        for invalid in [0, -1, Double.nan, Double.infinity] {
            let invalidTarget = RollingPricePathPoint(
                date: points[399].date.addingTimeInterval(86_400), close: invalid
            )
            XCTAssertNil(BoundedPricePathContext.referenceState(points: points + [invalidTarget]))
        }
    }

    /// Independent oracle: select the allowed raw observations, then call the
    /// original state machine directly. Never call the bounded helper here.
    private func oracle(_ points: [RollingPricePathPoint]) -> PricePathStoredState? {
        guard let target = points.last,
              target.close.isFinite, target.close > 0 else { return nil }
        var validSegment: [RollingPricePathPoint] = []
        for point in points where point.close.isFinite && point.close > 0 {
            if let previous = validSegment.last, point.date <= previous.date {
                validSegment = []
            }
            validSegment.append(point)
        }
        var original = PricePathRollingContext()
        var state: PricePathStoredState?
        for point in validSegment.suffix(250) {
            state = original.update(date: point.date, close: point.close)
        }
        return state
    }

    private func replay(_ points: [RollingPricePathPoint]) -> [PricePathStoredState?] {
        var context = BoundedPricePathContext()
        return points.map { context.update(date: $0.date, close: $0.close) }
    }

    private func assertState(
        _ actual: PricePathStoredState?,
        equals expected: PricePathStoredState?,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, message, file: file, line: line)
        // Assert all five stored fields exactly, not merely the phase or a
        // tolerance that could hide a changed frozen threshold or anchor.
        XCTAssertEqual(actual?.phase, expected?.phase, message, file: file, line: line)
        XCTAssertEqual(actual?.barrier, expected?.barrier, message, file: file, line: line)
        XCTAssertEqual(actual?.anchorClose, expected?.anchorClose, message, file: file, line: line)
        XCTAssertEqual(actual?.extremeClose, expected?.extremeClose, message, file: file, line: line)
        XCTAssertEqual(actual?.daysSinceExtreme, expected?.daysSinceExtreme, message, file: file, line: line)
    }

    private func variedPoints(count: Int) -> [RollingPricePathPoint] {
        makePoints((0..<count).map { index in
            100 + 12 * sin(Double(index) / 17)
                + 7 * cos(Double(index) / 9) + Double(index) / 30
        })
    }

    private func risingPoints(count: Int) -> [RollingPricePathPoint] {
        makePoints((0..<count).map { 100 * pow(1.002, Double($0)) })
    }

    private func makePoints(
        _ closes: [Double],
        startingAt start: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) -> [RollingPricePathPoint] {
        closes.enumerated().map { index, close in
            RollingPricePathPoint(date: start.addingTimeInterval(Double(index) * 86_400), close: close)
        }
    }
}
