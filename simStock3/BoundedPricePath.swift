import Foundation

/// Rebuilds each target's price-path state from at most 250 raw prices,
/// including the target. No persisted phase, anchor, or barrier is a seed.
///
/// Callers supply prices inside their calculation window, in ascending order.
/// Non-finite/non-positive closes are excluded, matching fetchCalculationWindow:
/// they return no state and do not advance or break the valid-price sequence.
/// A duplicate or decreasing date starts a new sequence at that point instead
/// of allowing later prices or an ambiguous same-date observation to be reused.
struct BoundedPricePathContext: Equatable, Sendable {
    static let maximumObservationCount = 250

    // Keep the bounded raw buffer Sendable without changing the existing
    // RollingPricePathPoint API or carrying any derived path state.
    private struct Observation: Equatable, Sendable {
        let date: Date
        let close: Double
    }

    private var observations: [Observation] = []

    init(priorPoints: [RollingPricePathPoint] = []) {
        for point in priorPoints where point.close.isFinite && point.close > 0 {
            append(
                date: point.date,
                close: point.close,
                limit: Self.maximumObservationCount - 1
            )
        }
    }

    mutating func update(date: Date, close: Double) -> PricePathStoredState? {
        guard close.isFinite, close > 0 else { return nil }
        append(date: date, close: close, limit: Self.maximumObservationCount)
        return Self.replay(observations)
    }

    /// Batch counterpart for a sequence whose last point is the target.
    /// Earlier invalid closes are excluded; an invalid target has no state.
    /// This deliberately replays the original state machine from an empty
    /// context after selecting the target's bounded raw observations.
    static func referenceState(points: [RollingPricePathPoint]) -> PricePathStoredState? {
        guard let target = points.last,
              target.close.isFinite, target.close > 0 else { return nil }
        var segment: [RollingPricePathPoint] = []
        for point in points where point.close.isFinite && point.close > 0 {
            if let previous = segment.last, point.date <= previous.date {
                segment.removeAll(keepingCapacity: true)
            }
            segment.append(point)
        }
        var path = PricePathRollingContext()
        var state: PricePathStoredState?
        for point in segment.suffix(maximumObservationCount) {
            state = path.update(date: point.date, close: point.close)
        }
        return state
    }

    private mutating func append(date: Date, close: Double, limit: Int) {
        if let previous = observations.last, date <= previous.date {
            observations.removeAll(keepingCapacity: true)
        }
        observations.append(Observation(date: date, close: close))
        if observations.count > limit {
            observations.removeFirst(observations.count - limit)
        }
    }

    private static func replay(_ observations: [Observation]) -> PricePathStoredState? {
        var path = PricePathRollingContext()
        var state: PricePathStoredState?
        for observation in observations {
            state = path.update(date: observation.date, close: observation.close)
        }
        return state
    }
}
