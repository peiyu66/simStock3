import XCTest
@testable import simStock3

@MainActor
final class RecoveryLowBuyRuleTests: XCTestCase {
    func testFormalEligibilityMatchesFrozenS5() async {
        for grade: Trade.Grade in [.damn, .low, .weak, .none, .fine, .high, .wow] {
            for raw in 0...9 {
                let phase = PricePathPhase(rawValue: raw)!
                for inventory in [0.0, 1.0, 100.0] {
                    for high: Double? in [nil, 0, -1, .nan, .infinity, 100, 101] {
                        for maximum: Double? in [nil, 0, .nan, .infinity, 100, 101] {
                            let expected = grade == .weak || grade == .fine
                                || (grade == .low && inventory > 0 && phase != .sideways
                                    && high.map { $0.isFinite && $0 > 0 && maximum == $0 } == true)
                            XCTAssertEqual(RecoveryLowBuyRule.applies(grade: grade,
                                inventory: inventory, pricePhase: phase,
                                priorHigh: high, priorHighMax9: maximum), expected)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(Technical.dataRuleVersion, "T3/S45")
    }
}
