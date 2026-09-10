import XCTest
@testable import simStock3

@MainActor
final class PullbackHighBuyRuleTests: XCTestCase {
    func testFormalIdentityCannotOverwriteOldBaseline() async {
        XCTAssertEqual(Technical.dataRuleVersion, "T3/S49")
        XCTAssertEqual(InternalBacktestReport.baselineRuleVersion, "s42-hn13-kj-hot-20260911")
        XCTAssertThrowsError(try InternalBacktestReport.run()) { error in
            XCTAssertTrue(error.localizedDescription.contains("不得以新版規則覆寫"))
        }
    }

    func testAdoptedRuleMatchesFrozenCandidateAcrossAllBoundaries() async {
        for grade: Trade.Grade in [.damn, .low, .weak, .none, .fine, .high, .wow] {
            for rawPrice in 0...9 {
                let price = PricePathPhase(rawValue: rawPrice)!
                for rawTrend in 0...11 {
                    let phase = StrategyFitTrendPhase(rawValue: rawTrend)!
                    for count in [0, 124, 125, 126, 1000] {
                        let preview = StrategyFitTrendPreview(phase: phase, phaseExtreme: nil, observationCount: count)
                        for marketRaw in [-1] + Array(0...9) {
                            let market = PricePathPhase(rawValue: marketRaw)
                            // Frozen S3 predicate, independent of the production helper.
                            let frozen = marketRaw == 3 && grade != .none && count >= 125 && rawTrend == 9
                                && (rawPrice == 4 || rawPrice == 5)
                            XCTAssertEqual(PullbackHighBuyRule.suppressesVote(
                                grade: grade, pricePhase: price, decisionTrend: preview, priorMarketPhase: market), frozen)
                            // H-P03b still supplies the shared capped point for damn.
                            for originalA in [false, true] {
                                let formalPoint = (originalA && !PullbackHighBuyRule.suppressesVote(
                                    grade: grade, pricePhase: price, decisionTrend: preview, priorMarketPhase: market)) || grade == .damn
                                let frozenPoint = (originalA && !frozen) || grade == .damn
                                XCTAssertEqual(formalPoint, frozenPoint)
                            }
                        }
                    }
                }
            }
        }
    }
}
