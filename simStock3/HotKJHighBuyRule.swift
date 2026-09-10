import Foundation

/// H-N13: the existing 1.8 K/J boundaries qualify one additional H penalty.
enum HotKJHighBuyRule {
    static func penalty(inventory: Double, grade: Trade.Grade, pricePhase: PricePathPhase,
                        kZ125: Double, jZ125: Double) -> Double {
        inventory == 0 && grade == .wow && pricePhase == .seekingPeakEarly
            && kZ125 > 1.8 && jZ125 > 1.8 ? -1 : 0
    }
}
