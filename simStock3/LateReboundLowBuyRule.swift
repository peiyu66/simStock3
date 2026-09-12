import Foundation

/// L-P12: one independent L vote while flat in the late rebound phase.
/// The caller keeps the existing H-first routing and L execution gates.
enum LateReboundLowBuyRule {
    static func contribution(inventory: Double, pricePhase: PricePathPhase) -> Double {
        inventory == 0 && pricePhase == .reboundingLate ? 1 : 0
    }
}
