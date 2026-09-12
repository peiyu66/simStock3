import XCTest
@testable import simStock3

@MainActor
final class LateReboundLowBuyRuleTests: XCTestCase {
    func testOnlyLateReboundReceivesTheFlatVote() async {
        for raw in 0...9 {
            let phase = PricePathPhase(rawValue: raw)!
            XCTAssertEqual(LateReboundLowBuyRule.contribution(inventory: 0, pricePhase: phase),
                           raw == 9 ? 1 : 0)
        }
    }

    func testHeldPositionsCannotReceiveTheVote() async {
        for inventory in [0.001, 1, 100] {
            XCTAssertEqual(LateReboundLowBuyRule.contribution(inventory: inventory,
                                                             pricePhase: .reboundingLate), 0)
        }
    }
}
