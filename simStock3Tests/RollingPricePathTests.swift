import XCTest
@testable import simStock3

final class RollingPricePathTests: XCTestCase {
    func testPersistedPhaseRawValuesRemainStable() {
        XCTAssertEqual(
            PricePathPhase.allCases.map(\.rawValue),
            Array(0...9)
        )
        XCTAssertEqual(PricePathPhase(rawValue: 0), .unavailable)
        XCTAssertEqual(PricePathPhase(rawValue: 1), .sideways)
        XCTAssertEqual(PricePathPhase(rawValue: 2), .seekingPeakEarly)
        XCTAssertEqual(PricePathPhase(rawValue: 3), .seekingPeakLate)
        XCTAssertEqual(PricePathPhase(rawValue: 4), .pullingBackEarly)
        XCTAssertEqual(PricePathPhase(rawValue: 5), .pullingBackLate)
        XCTAssertEqual(PricePathPhase(rawValue: 6), .seekingBottomEarly)
        XCTAssertEqual(PricePathPhase(rawValue: 7), .seekingBottomLate)
        XCTAssertEqual(PricePathPhase(rawValue: 8), .reboundingEarly)
        XCTAssertEqual(PricePathPhase(rawValue: 9), .reboundingLate)
    }

    @MainActor
    func testTradePricePathFieldsStartUnavailableAndResetTogether() async {
        let stock = Stock(
            sId: "TEST",
            sName: "測試股",
            group: "測試",
            dateFirst: Date(),
            dateStart: Date(),
            simInvestAuto: 2,
            simMoneyBase: 100
        )
        let trade = Trade(stock: stock, dateTime: Date())

        XCTAssertEqual(trade.pricePathPhase, .unavailable)
        XCTAssertNil(trade.tPricePathBarrier)
        XCTAssertNil(trade.tPricePathAnchorClose)
        XCTAssertNil(trade.tPricePathExtremeClose)
        XCTAssertEqual(trade.tPricePathDaysSinceExtreme, 0)

        trade.pricePathPhase = .pullingBackLate
        trade.tPricePathBarrier = 0.08
        trade.tPricePathAnchorClose = 100
        trade.tPricePathExtremeClose = 115
        trade.tPricePathDaysSinceExtreme = 7
        trade.resetPricePathTechnicalValues()

        XCTAssertEqual(trade.pricePathPhase, .unavailable)
        XCTAssertNil(trade.tPricePathBarrier)
        XCTAssertNil(trade.tPricePathAnchorClose)
        XCTAssertNil(trade.tPricePathExtremeClose)
        XCTAssertEqual(trade.tPricePathDaysSinceExtreme, 0)
        XCTAssertEqual(Technical.technicalRuleVersion, "T3")
        XCTAssertEqual(Technical.simulationRuleVersion, "S39")
    }

    func testBarrierUsesSampleDeviationAndClampsRange() {
        let lowVolatilityBarrier = RollingPricePathClassifier.barrier(
            forLogReturns: Array(repeating: 0, count: 40)
        )
        let highVolatilityBarrier = RollingPricePathClassifier.barrier(
            forLogReturns: (0..<40).map { $0.isMultiple(of: 2) ? 0.2 : -0.2 }
        )
        XCTAssertNotNil(lowVolatilityBarrier)
        XCTAssertNotNil(highVolatilityBarrier)
        XCTAssertEqual(lowVolatilityBarrier!, 0.05, accuracy: 0.000_000_1)
        XCTAssertEqual(highVolatilityBarrier!, 0.15, accuracy: 0.000_000_1)
        XCTAssertNil(
            RollingPricePathClassifier.barrier(
                forLogReturns: Array(repeating: 0, count: 39)
            )
        )
    }

    func testTrendTransitionsRequireTheirLogicalPredecessors() {
        let closes = Array(repeating: 100.0, count: 41)
            + [106, 109, 105, 110, 102, 102, 95, 104, 90, 98, 104, 95]
        let points = makePoints(closes)
        let observations = RollingPricePathClassifier.observations(for: points)

        XCTAssertEqual(observations[points[40].date]?.phase, .sideways)
        XCTAssertEqual(observations[points[41].date]?.phase, .continuationUp)
        XCTAssertEqual(observations[points[42].date]?.phase, .continuationUp)
        XCTAssertEqual(observations[points[43].date]?.phase, .topThenPullback)
        XCTAssertEqual(observations[points[44].date]?.phase, .continuationUp)
        XCTAssertEqual(observations[points[45].date]?.phase, .topThenPullback)
        XCTAssertEqual(observations[points[46].date]?.phase, .continuationDown)
        XCTAssertEqual(observations[points[47].date]?.phase, .continuationDown)
        XCTAssertEqual(observations[points[48].date]?.phase, .bottomThenRebound)
        XCTAssertEqual(observations[points[49].date]?.phase, .continuationDown)
        XCTAssertEqual(observations[points[50].date]?.phase, .bottomThenRebound)
        XCTAssertEqual(observations[points[51].date]?.phase, .continuationUp)
        XCTAssertEqual(observations[points[52].date]?.phase, .topThenPullback)
    }

    func testEveryAdjacentPhaseChangeIsAllowedByTheStateMachine() {
        let closes = Array(repeating: 100.0, count: 41)
            + [106, 109, 105, 110, 102, 102, 95, 104, 90, 98, 104, 95]
            + Array(repeating: 92, count: 25)
        let points = makePoints(closes)
        let observations = RollingPricePathClassifier.observations(for: points)
        let phases = points.compactMap { observations[$0.date]?.phase }
        let allowed: [RollingPricePathPhase: Set<RollingPricePathPhase>] = [
            .sideways: [.sideways, .continuationUp, .continuationDown],
            .continuationUp: [.continuationUp, .topThenPullback, .sideways],
            .topThenPullback: [.topThenPullback, .continuationUp, .continuationDown, .sideways],
            .continuationDown: [.continuationDown, .bottomThenRebound, .sideways],
            .bottomThenRebound: [.bottomThenRebound, .continuationDown, .continuationUp, .sideways]
        ]

        for (previous, current) in zip(phases, phases.dropFirst()) {
            XCTAssertTrue(
                allowed[previous, default: []].contains(current),
                "Disallowed transition: \(previous) -> \(current)"
            )
        }
    }

    func testTrendWithoutANewExtremeReturnsToSidewaysAfterTwentyDays() {
        let closes = Array(repeating: 100.0, count: 41)
            + [106]
            + Array(repeating: 106, count: 20)
        let points = makePoints(closes)
        let observations = RollingPricePathClassifier.observations(for: points)

        XCTAssertEqual(observations[points[60].date]?.phase, .continuationUp)
        XCTAssertEqual(observations[points[61].date]?.phase, .sideways)
    }

    func testAppendingFuturePricesDoesNotRelabelEarlierDates() {
        let prefix = Array(repeating: 100.0, count: 41) + [106, 109, 105]
        let allCloses = prefix + [103, 101, 99, 96]
        let prefixPoints = makePoints(prefix)
        let allPoints = makePoints(allCloses)

        let prefixObservations = RollingPricePathClassifier.observations(for: prefixPoints)
        let allObservations = RollingPricePathClassifier.observations(for: allPoints)

        for point in prefixPoints {
            XCTAssertEqual(prefixObservations[point.date], allObservations[point.date])
        }
    }

    func testInvalidCloseResetsContinuityAndRequiresFreshWarmup() {
        let closes = Array(repeating: 100.0, count: 41)
            + [106, 0]
            + Array(repeating: 100, count: 41)
        let points = makePoints(closes)
        let observations = RollingPricePathClassifier.observations(for: points)

        XCTAssertEqual(observations[points[41].date]?.phase, .continuationUp)
        XCTAssertNil(observations[points[42].date])
        XCTAssertNil(observations[points[81].date])
        XCTAssertEqual(observations[points[83].date]?.phase, .sideways)
    }

    func testPricePathPhasesReuseGradeTrendIcons() {
        XCTAssertEqual(
            RollingPricePathPhase.continuationUp.strategyFitIconPhase.displayIconSystemName,
            "arrow.up.right.circle.fill"
        )
        XCTAssertEqual(
            RollingPricePathPhase.topThenPullback.strategyFitIconPhase.displayIconSystemName,
            "arrow.down.right.circle"
        )
        XCTAssertEqual(
            RollingPricePathPhase.continuationDown.strategyFitIconPhase.displayIconSystemName,
            "arrow.down.right.circle.fill"
        )
        XCTAssertEqual(
            RollingPricePathPhase.bottomThenRebound.strategyFitIconPhase.displayIconSystemName,
            "arrow.up.right.circle"
        )
    }

    private func makePoints(_ closes: [Double]) -> [RollingPricePathPoint] {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        return closes.enumerated().map { index, close in
            RollingPricePathPoint(
                date: start.addingTimeInterval(Double(index) * 86_400),
                close: close
            )
        }
    }
}
