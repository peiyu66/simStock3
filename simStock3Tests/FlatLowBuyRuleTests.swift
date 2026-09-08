import XCTest
@testable import simStock3

@MainActor
final class FlatLowBuyRuleTests: XCTestCase {
    func testFormalRuleMatchesAdoptedS5AcrossBoundaries() async {
        let late = -StrategyFitTrendPhaseUpdater.confirmedLateThreshold
        let minimum = StrategyFitTrendClassifier.minimumObservationCount
        for raw in 0...9 {
            let price = PricePathPhase(rawValue: raw)!
            for grade: Trade.Grade in [.damn, .low, .weak, .none, .fine, .high, .wow] {
                for phaseRaw in 0...11 {
                    guard let phase = StrategyFitTrendPhase(rawValue: phaseRaw) else { continue }
                    for count in [0, minimum - 1, minimum, minimum + 1] {
                        for extreme: Double? in [nil, .nan, .infinity, -.infinity, late - 0.001, late, late + 0.001] {
                            for inventory in [0.0, 1.0] {
                                let expected = inventory == 0 && price == .sideways
                                    && ((count >= minimum && phase == .worseningConfirmedSeekingBottom
                                         && extreme.map { $0.isFinite && $0 <= late } == true)
                                        || grade <= .low)
                                XCTAssertEqual(FlatLowBuyRule.suppressesVote(inventory: inventory,
                                    pricePhase: price, grade: grade,
                                    trend: .init(phase: phase, phaseExtreme: extreme, observationCount: count)), expected)
                            }
                        }
                    }
                }
            }
        }
    }

    func testLowGradeDoesNotRequireTrendWarmupAndPullbackIsExcluded() async {
        let unavailable = StrategyFitTrendPreview(phase: .unavailable, phaseExtreme: nil, observationCount: 0)
        XCTAssertTrue(FlatLowBuyRule.suppressesVote(inventory: 0, pricePhase: .sideways, grade: .low, trend: unavailable))
        XCTAssertFalse(FlatLowBuyRule.suppressesVote(inventory: 1, pricePhase: .sideways, grade: .low, trend: unavailable))
        XCTAssertFalse(FlatLowBuyRule.suppressesVote(inventory: 0, pricePhase: .pullingBackLate, grade: .low, trend: unavailable))
        XCTAssertFalse(FlatLowBuyRule.suppressesVote(inventory: 0, pricePhase: .sideways, grade: .weak, trend: unavailable))
        XCTAssertEqual(Technical.dataRuleVersion, "T3/S44")
    }
}
