import Foundation

/// H-P02: rated sideways prices need the existing H-P01 support.
enum FlatHighBuyRule {
    static func suppressesVote(grade: Trade.Grade, pricePhase: PricePathPhase,
                               hp01Applies: Bool) -> Bool {
        grade != .none && pricePhase == .sideways && !hp01Applies
    }
}
