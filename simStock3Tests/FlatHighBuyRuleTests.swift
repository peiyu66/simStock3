import XCTest
@testable import simStock3

@MainActor
final class FlatHighBuyRuleTests: XCTestCase {
    func testRatedSidewaysNeedsHP01Support() async {
        for grade: Trade.Grade in [.damn, .low, .weak, .fine, .high, .wow] {
            XCTAssertTrue(FlatHighBuyRule.suppressesVote(grade: grade, pricePhase: .sideways, hp01Applies: false))
            XCTAssertFalse(FlatHighBuyRule.suppressesVote(grade: grade, pricePhase: .sideways, hp01Applies: true))
        }
    }

    func testUnratedAndOtherPricePhasesKeepOriginalVote() async {
        for hp01 in [false, true] {
            XCTAssertFalse(FlatHighBuyRule.suppressesVote(grade: .none, pricePhase: .sideways, hp01Applies: hp01))
            for raw in 0...9 {
                let phase = PricePathPhase(rawValue: raw)!
                guard phase != .sideways else { continue }
                for grade: Trade.Grade in [.damn, .low, .weak, .none, .fine, .high, .wow] {
                    XCTAssertFalse(FlatHighBuyRule.suppressesVote(grade: grade, pricePhase: phase, hp01Applies: hp01))
                }
            }
        }
        XCTAssertEqual(Technical.dataRuleVersion, "T3/S48")
    }
}
