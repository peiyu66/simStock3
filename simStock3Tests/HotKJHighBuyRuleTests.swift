import XCTest
@testable import simStock3

@MainActor
final class HotKJHighBuyRuleTests: XCTestCase {
    func testFormalScoreMatchesFrozenCandidateGateAndPreservesLRouting() async {
        for grade: Trade.Grade in [.damn, .low, .weak, .none, .fine, .high, .wow] {
            for raw in 0...9 {
                for inventory in [0.0, 1, 3000] {
                    for k in [-2.0, 1.8.nextDown, 1.8, 1.8.nextUp, 3.0] {
                        for j in [-2.0, 1.8.nextDown, 1.8, 1.8.nextUp, 3.0] {
                            // Frozen candidate raises the gate only in this exact prestate.
                            let candidateIncrement = inventory == 0 && grade == .wow && raw == 2 && k > 1.8 && j > 1.8 ? 1.0 : 0.0
                            let penalty = HotKJHighBuyRule.penalty(inventory: inventory, grade: grade,
                                pricePhase: PricePathPhase(rawValue: raw)!, kZ125: k, jZ125: j)
                            XCTAssertEqual(penalty, -candidateIncrement)
                            for score in [-2.0, -1, 0, 1, 2] {
                                let threshold = grade == .low ? 1.0 : 0.0
                                for lScore in [4.0, 5.0, 6.0] {
                                    let frozen = score >= threshold + candidateIncrement ? "H" : (lScore >= 5 ? "L" : "")
                                    let formal = score + penalty >= threshold ? "H" : (lScore >= 5 ? "L" : "")
                                    XCTAssertEqual(formal, frozen)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
