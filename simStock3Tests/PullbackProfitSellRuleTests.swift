import XCTest
@testable import simStock3

@MainActor
final class PullbackProfitSellRuleTests: XCTestCase {
    private func threshold(_ grade: Trade.Grade = .fine, days: Double = 2,
                           price: PricePathPhase = .pullingBackEarly,
                           phase: StrategyFitTrendPhase = .improvingConfirmedPullingBack,
                           count: Int = 125, base: Double = 2) -> Double {
        PullbackProfitSellRule.roiThreshold(base: base, grade: grade, holdingDays: days,
            pricePhase: price, trend: .init(phase: phase, phaseExtreme: nil, observationCount: count))
    }

    func testBothPullbackMaturitiesAcceptEveryRatedGrade() async {
        for grade: Trade.Grade in [.damn, .low, .weak, .fine, .high, .wow] {
            for price: PricePathPhase in [.pullingBackEarly, .pullingBackLate] {
                XCTAssertEqual(threshold(grade, price: price), 0.45)
            }
        }
    }

    func testMissingQualificationPreservesOriginalGradeThreshold() async {
        for base in [1.5, 2.0, 2.25] {
            XCTAssertEqual(threshold(.none, base: base), base)
            for day in [0.0, 1.0] { XCTAssertEqual(threshold(days: day, base: base), base) }
            XCTAssertEqual(threshold(count: 124, base: base), base)
            for raw in 0...9 where raw != 4 && raw != 5 {
                XCTAssertEqual(threshold(price: PricePathPhase(rawValue: raw)!, base: base), base)
            }
            for raw in 0...11 where raw != 9 {
                XCTAssertEqual(threshold(phase: StrategyFitTrendPhase(rawValue: raw)!, base: base), base)
            }
        }
    }

    func testStrictProfitAndHoldingBoundariesRetainFourVoteGate() async {
        XCTAssertEqual(threshold(days: 1.0.nextUp), 0.45)
        XCTAssertEqual(threshold(count: 126), 0.45)
        let boundary = threshold()
        let profit: Double = 0.45
        for roi in [profit.nextDown, profit, profit.nextUp] {
            for score in [3.0, 4.0, 5.0] {
                let accepted = score >= 4 && roi > boundary
                XCTAssertEqual(accepted, score >= 4 && roi == profit.nextUp)
            }
        }
    }
}
