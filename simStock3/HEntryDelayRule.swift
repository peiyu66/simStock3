import Foundation

/// S58 / H-E01: adopted HC-Q10-12-F1. Only delays a feasible flat H entry.
enum HEntryDelayRule {
    static func matches(marketJZ250: Double?, marketPhaseRaw: Int?, marketObservationCount: Int,
                        gradeRaw: Int?, ma60Diff: Double, stockMature: Bool) -> Bool {
        guard marketObservationCount >= 250, marketPhaseRaw == 7,
              let j = marketJZ250, j.isFinite, j > -0.88 else { return false }
        // Invalid stock inputs retain the original market-only delay.
        guard stockMature, ma60Diff.isFinite,
              let grade = gradeRaw, (-3...3).contains(grade) else { return true }
        return grade >= 1 || ma60Diff > -3.6
    }

    // Mirrors the existing automatic one-lot feasibility, before any manual override.
    static func canOpen(qualifiedH: Bool, inventory: Double, previousSell: Double,
                        previousReversal: String, requestedReversal: String,
                        balance: Double, budget: Double, price: Double) -> Bool {
        guard qualifiedH, inventory == 0, price.isFinite, price > 0,
              balance.isFinite, budget.isFinite, requestedReversal != "B-",
              !(previousSell > 0 && previousReversal.isEmpty) else { return false }
        let oneCost = price * 1000 + max(20, (price * 1.425).rounded())
        let money = min(balance, budget)
        guard balance >= oneCost else { return false }
        var quantity = max(0, floor(money / (price * 1000 * 1.001425)))
        let feeQuantity = ceil(20 / (price * 1.425))
        if quantity < feeQuantity { quantity = max(0, floor((money - 20) / (price * 1000))) }
        if quantity == 0 && money > oneCost { quantity = 1 }
        return quantity > 0
    }
}
