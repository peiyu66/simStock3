import Foundation

/// One market-history pass; Yahoo seeds from yesterday and never reuses today's trial.
struct MarketKDRollingContext {
    struct Value {
        let k: Double
        let d: Double
        let jZ250: Double
        let observationCount: Int
    }
    private var k = 50.0
    private var d = 50.0
    private var count = 0
    private var recentJ: [Double] = []

    init() {}

    init(k: Double, d: Double, observationCount: Int, recentJ: [Double]) {
        self.k = k
        self.d = d
        self.count = observationCount
        self.recentJ = Array(recentJ.suffix(249))
    }

    mutating func update(close: Double, high9: Double, low9: Double) -> Value {
        if count > 0 {
            let rsv = high9 == low9 ? 50 : 100 * (close - low9) / (high9 - low9)
            k = 2 * k / 3 + rsv / 3
            d = 2 * d / 3 + k / 3
        }
        let j = 3 * k - 2 * d
        recentJ.append(j)
        if recentJ.count > 250 { recentJ.removeFirst() }
        let mean = recentJ.reduce(0, +) / Double(recentJ.count)
        let variance = recentJ.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(recentJ.count)
        let deviation = sqrt(variance)
        count += 1
        return Value(k: k, d: d, jZ250: deviation == 0 ? 0 : (j - mean) / deviation,
                     observationCount: count)
    }
}
