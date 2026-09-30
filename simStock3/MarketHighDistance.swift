import Foundation

/// Inclusive 250 market sessions. Seed only completed prior sessions for intraday trials.
struct MarketHighDistanceRollingContext {
    private var highs: [Double]
    init(priorHighs: [Double] = []) { highs = Array(priorHighs.suffix(249)) }
    mutating func update(high: Double, close: Double) -> Double {
        highs.append(high)
        if highs.count > 250 { highs.removeFirst() }
        guard high.isFinite, close.isFinite, close > 0,
              let maximum = highs.max(), maximum.isFinite, maximum > 0 else { return .nan }
        return 100 * (close - maximum) / maximum
    }
}
