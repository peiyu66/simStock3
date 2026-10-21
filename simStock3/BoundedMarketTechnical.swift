import Foundation

/// Market technical values rebuilt from at most 250 valid raw OHLC points per
/// target. The raw buffer is the only continuation state: no stored market T,
/// prior K/D, EMA, or price-path anchor enters a target's calculation.
struct BoundedMarketTechnicalContext: Equatable, Sendable {
    static let maximumObservationCount = 250

    struct Point: Equatable, Sendable {
        let date: Date
        let open: Double
        let high: Double
        let low: Double
        let close: Double

        /// Same price consistency contract as the official market OHLC parser.
        fileprivate var isValid: Bool {
            [open, high, low, close].allSatisfy(\.isFinite)
                && open > 0 && close > 0 && low > 0
                && high >= max(open, close) && low <= min(open, close)
        }
    }

    struct Value: Equatable, Sendable {
        let pricePath: PricePathStoredState?
        let highMax9: Double
        let lowMin9: Double
        let highDiff250: Double
        let highDiffZ125: Double
        let oscZ125: Double
        let ema12: Double
        let ema26: Double
        let macd9: Double
        let kdK: Double
        let kdD: Double
        let kdJZ250: Double
        let lowDiffZ125: Double
        let ma20DiffMax9: Double
        let observationCount: Int
    }

    private var points: [Point] = []

    /// Callers provide raw points in ascending date order, already restricted
    /// to their allowed market period. Invalid OHLC does not advance or break
    /// the valid sequence. Duplicate/decreasing dates start a fresh sequence,
    /// preventing a later observation from becoming an earlier target's seed.
    init(priorPoints: [Point] = []) {
        for point in priorPoints where point.isValid {
            append(point, limit: Self.maximumObservationCount - 1)
        }
    }

    mutating func update(_ point: Point) -> Value? {
        guard point.isValid else { return nil }
        append(point, limit: Self.maximumObservationCount)
        return Self.calculate(points)
    }

    /// Batch entry point; the last point is the target, not an as-of date that
    /// permits later observations. It selects raw input independently of the
    /// incremental buffer, then performs the same cold calculation.
    static func referenceValue(points: [Point]) -> Value? {
        guard let target = points.last, target.isValid else { return nil }
        var segment: [Point] = []
        for point in points where point.isValid {
            if let previous = segment.last, point.date <= previous.date {
                segment.removeAll(keepingCapacity: true)
            }
            segment.append(point)
        }
        return calculate(Array(segment.suffix(maximumObservationCount)))
    }

    private mutating func append(_ point: Point, limit: Int) {
        if let previous = points.last, point.date <= previous.date {
            points.removeAll(keepingCapacity: true)
        }
        points.append(point)
        if points.count > limit { points.removeFirst(points.count - limit) }
    }

    /// One cold pass over a target's bounded window. Intermediate derived
    /// observations exist only inside this pass and are never returned as
    /// updated values for earlier market days.
    private static func calculate(_ points: [Point]) -> Value? {
        guard let target = points.last else { return nil }
        var path = PricePathRollingContext()
        var pricePath: PricePathStoredState?
        var high9 = Extremum(maximum: true)
        var low9 = Extremum(maximum: false)
        var high125 = Extremum(maximum: true)
        var low125 = Extremum(maximum: false)
        var currentHigh9 = 0.0
        var currentLow9 = 0.0
        var k = 50.0
        var d = 50.0
        var ema12 = 0.0
        var ema26 = 0.0
        var macd9 = 0.0
        var jValues: [Double] = []
        var oscillators: [Double] = []
        var highDistances: [Double] = []
        var lowDistances: [Double] = []
        var ma20Deviations: [Double] = []
        var closes20: [Double] = []

        for (index, point) in points.enumerated() {
            pricePath = path.update(date: point.date, close: point.close)
            currentHigh9 = high9.update(point.high, index: index, lowerBound: index - 8)
            currentLow9 = low9.update(point.low, index: index, lowerBound: index - 8)
            let maximum125 = high125.update(point.high, index: index, lowerBound: index - 124)
            let minimum125 = low125.update(point.low, index: index, lowerBound: index - 124)
            let demand = (point.high + point.low + 2 * point.close) / 4
            closes20.append(point.close)
            if closes20.count > 20 { closes20.removeFirst() }

            if index == 0 {
                // Existing market initial conditions. Zero is a local derived
                // observation, never a fabricated raw OHLC point or maturity.
                ema12 = demand
                ema26 = demand
                highDistances.append(0)
                lowDistances.append(0)
                ma20Deviations.append(0)
            } else {
                let rsv = currentHigh9 == currentLow9
                    ? 50 : 100 * (point.close - currentLow9) / (currentHigh9 - currentLow9)
                k = 2 * k / 3 + rsv / 3
                d = 2 * d / 3 + k / 3
                ema12 = (11 * ema12 + 2 * demand) / 13
                ema26 = (25 * ema26 + 2 * demand) / 27
                macd9 = (8 * macd9 + 2 * (ema12 - ema26)) / 10
                highDistances.append(100 * (point.close - maximum125) / maximum125)
                lowDistances.append(100 * (point.close - minimum125) / minimum125)
                let average = closes20.reduce(0, +) / Double(closes20.count)
                ma20Deviations.append((10000 * (point.close - average) / point.close).rounded() / 100)
            }
            jValues.append(3 * k - 2 * d)
            oscillators.append(ema12 - ema26 - macd9)
        }

        let maximum250 = points.map(\.high).max()!
        return Value(
            pricePath: pricePath,
            highMax9: currentHigh9,
            lowMin9: currentLow9,
            // H-E02 retains its direct 250-high distance, including on day one.
            highDiff250: 100 * (target.close - maximum250) / maximum250,
            // S-E01's new feature is 125 highs followed by 125 distances (249
            // raw observations). Strategy validation/gating is owned by callers.
            highDiffZ125: populationZ(Array(highDistances.suffix(125))),
            oscZ125: populationZ(Array(oscillators.suffix(125))),
            ema12: ema12, ema26: ema26, macd9: macd9,
            kdK: k, kdD: d, kdJZ250: populationZ(jValues),
            lowDiffZ125: populationZ(Array(lowDistances.suffix(125))),
            ma20DiffMax9: ma20Deviations.suffix(9).max()!,
            observationCount: points.count
        )
    }

    private static func populationZ(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { sum, value in
            let difference = value - mean
            return sum + difference * difference
        } / Double(values.count)
        let deviation = sqrt(variance)
        return deviation == 0 ? 0 : (values.last! - mean) / deviation
    }

    /// Local monotone queue; each raw observation enters/leaves at most once.
    /// It is discarded with the target's cold pass, not kept as derived seed.
    private struct Extremum {
        let maximum: Bool
        private var candidates: [(index: Int, value: Double)] = []
        private var head = 0

        init(maximum: Bool) { self.maximum = maximum }

        mutating func update(_ value: Double, index: Int, lowerBound: Int) -> Double {
            while head < candidates.count && candidates[head].index < lowerBound { head += 1 }
            while candidates.count > head,
                  let last = candidates.last,
                  (maximum ? last.value <= value : last.value >= value) {
                candidates.removeLast()
            }
            candidates.append((index, value))
            return candidates[head].value
        }
    }
}
