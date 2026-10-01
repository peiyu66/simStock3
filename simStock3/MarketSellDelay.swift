import Foundation

/// Market v5. Carries only S-E01's population-Z windows and EMA continuation state.
/// Each intraday trial is seeded from completed prior sessions, never another trial.
struct MarketSellDelayRollingContext {
    struct Value: Equatable {
        let highDiffZ250: Double
        let oscZ125: Double
        let ema12: Double
        let ema26: Double
        let macd9: Double
        var osc: Double { ema12 - ema26 - macd9 }
    }
    private var count = 0
    private var ema12 = 0.0
    private var ema26 = 0.0
    private var macd9 = 0.0
    private var highDiffs: [Double] = []
    private var oscillators: [Double] = []

    init() {}
    init(observationCount: Int, ema12: Double, ema26: Double, macd9: Double,
         priorHighDiffs: [Double], priorOscillators: [Double]) {
        count = observationCount
        self.ema12 = ema12; self.ema26 = ema26; self.macd9 = macd9
        highDiffs = Array(priorHighDiffs.suffix(249))
        oscillators = Array(priorOscillators.suffix(124))
    }

    mutating func update(high: Double, low: Double, close: Double, highDiff250: Double) -> Value {
        let demand = (max(high, close) + min(low, close) + 2 * close) / 4
        if count == 0 {
            ema12 = demand; ema26 = demand; macd9 = 0
        } else {
            ema12 = (11 * ema12 + 2 * demand) / 13
            ema26 = (25 * ema26 + 2 * demand) / 27
            macd9 = (8 * macd9 + 2 * (ema12 - ema26)) / 10
        }
        // Frozen research seeds the first distance observation at zero.
        // Keep v4's actual distance unchanged; only this Z window uses that seed.
        highDiffs.append(count == 0 ? 0 : highDiff250)
        if highDiffs.count > 250 { highDiffs.removeFirst() }
        oscillators.append(ema12 - ema26 - macd9)
        if oscillators.count > 125 { oscillators.removeFirst() }
        count += 1
        return Value(highDiffZ250: Self.z(highDiffs), oscZ125: Self.z(oscillators),
                     ema12: ema12, ema26: ema26, macd9: macd9)
    }

    private static func z(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let sd = sqrt(variance)
        return sd == 0 ? 0 : (values.last! - mean) / sd
    }
}
