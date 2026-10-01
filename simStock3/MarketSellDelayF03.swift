import Foundation

/// S-E02's inclusive windows. Only the two decision values are persisted.
/// 249 completed raw observations suffice to reconstruct the 124 prior low
/// distances (each needs 125 lows) and eight MA20 deviations for a fresh trial.
struct MarketSellDelayF03RollingContext {
    struct Point { let low: Double; let close: Double }
    struct Value: Equatable { let lowDiffZ125: Double; let ma20DiffMax9: Double }
    private var count = 0
    private var lows: [Double] = []
    private var closes: [Double] = []
    private var distances: [Double] = []
    private var deviations: [Double] = []

    init(prior: [Point] = []) {
        for point in prior.suffix(249) { _ = update(low: point.low, close: point.close) }
    }

    mutating func update(low: Double, close: Double) -> Value {
        lows.append(min(low, close)); closes.append(close)
        if lows.count > 125 { lows.removeFirst() }
        if closes.count > 20 { closes.removeFirst() }
        let minimum = lows.min()!
        let average = closes.reduce(0, +) / Double(closes.count)
        // Frozen research seeds all first-day derived values at zero.
        distances.append(count == 0 ? 0 : 100 * (close - minimum) / minimum)
        deviations.append(count == 0 || close == 0 ? 0 : (10000 * (close - average) / close).rounded() / 100)
        if distances.count > 125 { distances.removeFirst() }
        if deviations.count > 9 { deviations.removeFirst() }
        count += 1
        let mean = distances.reduce(0, +) / Double(distances.count)
        let sd = sqrt(distances.reduce(0) { $0 + pow($1 - mean, 2) } / Double(distances.count))
        return Value(lowDiffZ125: sd == 0 ? 0 : (distances.last! - mean) / sd,
                     ma20DiffMax9: deviations.max()!)
    }
}
