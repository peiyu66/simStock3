import Foundation

/// L-P10 eligibility; the existing rolling recovery bonus remains a separate gate.
enum RecoveryLowBuyRule {
    static func applies(grade: Trade.Grade, inventory: Double, pricePhase: PricePathPhase,
                        marketHigh: Double?, marketHighMax9: Double?) -> Bool {
        if grade == .weak || grade == .fine { return true }
        guard grade == .low, inventory > 0, pricePhase != .sideways,
              let high = marketHigh, high.isFinite, high > 0 else { return false }
        return marketHighMax9 == high
    }
}
