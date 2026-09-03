import Foundation

enum RollingPricePathPhase: Equatable, Hashable {
    case sideways
    case continuationUp
    case topThenPullback
    case continuationDown
    case bottomThenRebound

    var displayName: String {
        switch self {
        case .sideways: "盤整"
        case .continuationUp: "續漲"
        case .topThenPullback: "探頂後回落"
        case .continuationDown: "續跌"
        case .bottomThenRebound: "探底後反彈"
        }
    }

    var strategyFitIconPhase: StrategyFitTrendPhase {
        switch self {
        case .sideways: .neutral
        case .continuationUp: .improvingConfirmedSeekingPeak
        case .topThenPullback: .improvingConfirmedPullingBack
        case .continuationDown: .worseningConfirmedSeekingBottom
        case .bottomThenRebound: .worseningConfirmedRebounding
        }
    }

}

struct RollingPricePathPoint: Equatable {
    let date: Date
    let close: Double
}

struct RollingPricePathObservation: Equatable {
    let phase: RollingPricePathPhase
    let barrier: Double
    let anchorDate: Date
}

/// Replays a causal price-trend state machine in trading-date order. The
/// volatility barrier is frozen when a trend segment starts. A pullback can
/// therefore only follow an established rising/peak-seeking segment, and a
/// rebound can only follow an established falling/bottom-seeking segment.
enum RollingPricePathClassifier {
    static let horizon = 20
    static let volatilityLookback = 60
    static let minimumReturnCount = 40
    static let minimumBarrier = 0.05
    static let maximumBarrier = 0.15

    private struct State {
        var phase: RollingPricePathPhase
        var barrier: Double
        var anchorClose: Double
        var anchorDate: Date
        var extremeClose: Double
        var extremeDate: Date
        var daysSinceExtreme: Int
    }

    static func observations(
        for sourcePoints: [RollingPricePathPoint]
    ) -> [Date: RollingPricePathObservation] {
        let points = sourcePoints.sorted { $0.date < $1.date }
        var result: [Date: RollingPricePathObservation] = [:]
        var recentLogReturns: [Double] = []
        var previousPoint: RollingPricePathPoint?
        var state: State?

        for point in points {
            guard point.close.isFinite, point.close > 0 else {
                previousPoint = nil
                recentLogReturns.removeAll(keepingCapacity: true)
                state = nil
                continue
            }
            guard let previous = previousPoint else {
                previousPoint = point
                continue
            }
            guard point.date > previous.date else {
                previousPoint = point
                recentLogReturns.removeAll(keepingCapacity: true)
                state = nil
                continue
            }

            recentLogReturns.append(log(point.close / previous.close))
            if recentLogReturns.count > volatilityLookback {
                recentLogReturns.removeFirst(recentLogReturns.count - volatilityLookback)
            }
            previousPoint = point

            guard let availableBarrier = barrier(forLogReturns: recentLogReturns) else {
                continue
            }
            if let previousState = state {
                state = next(
                    from: previousState,
                    point: point,
                    availableBarrier: availableBarrier
                )
            } else {
                state = sidewaysState(at: point, barrier: availableBarrier)
            }
            guard let state else { continue }
            result[point.date] = RollingPricePathObservation(
                phase: state.phase,
                barrier: state.barrier,
                anchorDate: state.anchorDate
            )
        }
        return result
    }

    static func barrier(forLogReturns returns: [Double]) -> Double? {
        let values = returns.filter(\.isFinite)
        guard values.count >= minimumReturnCount else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let squaredDeviation = values.reduce(0) { partial, value in
            let difference = value - mean
            return partial + difference * difference
        }
        let sigma = sqrt(squaredDeviation / Double(values.count - 1))
        guard sigma.isFinite else { return nil }
        return min(max(sigma * sqrt(Double(horizon)), minimumBarrier), maximumBarrier)
    }

    private static func next(
        from previous: State,
        point: RollingPricePathPoint,
        availableBarrier: Double
    ) -> State {
        var state = previous
        switch state.phase {
        case .sideways:
            let change = point.close / state.anchorClose - 1
            if change >= state.barrier {
                state.phase = .continuationUp
                state.extremeClose = point.close
                state.extremeDate = point.date
                state.daysSinceExtreme = 0
            } else if change <= -state.barrier {
                state.phase = .continuationDown
                state.extremeClose = point.close
                state.extremeDate = point.date
                state.daysSinceExtreme = 0
            }
            return state

        case .continuationUp:
            if point.close > state.extremeClose {
                state.extremeClose = point.close
                state.extremeDate = point.date
                state.daysSinceExtreme = 0
                return state
            }
            state.daysSinceExtreme += 1
            if (state.extremeClose - point.close) / state.extremeClose >= state.barrier / 2 {
                state.phase = .topThenPullback
                return state
            }
            return resetToSidewaysIfStale(
                state,
                at: point,
                availableBarrier: availableBarrier
            )

        case .topThenPullback:
            if point.close > state.extremeClose {
                state.phase = .continuationUp
                state.extremeClose = point.close
                state.extremeDate = point.date
                state.daysSinceExtreme = 0
                return state
            }
            state.daysSinceExtreme += 1
            if (state.extremeClose - point.close) / state.extremeClose >= state.barrier {
                return State(
                    phase: .continuationDown,
                    barrier: availableBarrier,
                    anchorClose: state.extremeClose,
                    anchorDate: state.extremeDate,
                    extremeClose: point.close,
                    extremeDate: point.date,
                    daysSinceExtreme: 0
                )
            }
            return resetToSidewaysIfStale(
                state,
                at: point,
                availableBarrier: availableBarrier
            )

        case .continuationDown:
            if point.close < state.extremeClose {
                state.extremeClose = point.close
                state.extremeDate = point.date
                state.daysSinceExtreme = 0
                return state
            }
            state.daysSinceExtreme += 1
            if (point.close - state.extremeClose) / state.extremeClose >= state.barrier / 2 {
                state.phase = .bottomThenRebound
                return state
            }
            return resetToSidewaysIfStale(
                state,
                at: point,
                availableBarrier: availableBarrier
            )

        case .bottomThenRebound:
            if point.close < state.extremeClose {
                state.phase = .continuationDown
                state.extremeClose = point.close
                state.extremeDate = point.date
                state.daysSinceExtreme = 0
                return state
            }
            state.daysSinceExtreme += 1
            if (point.close - state.extremeClose) / state.extremeClose >= state.barrier {
                return State(
                    phase: .continuationUp,
                    barrier: availableBarrier,
                    anchorClose: state.extremeClose,
                    anchorDate: state.extremeDate,
                    extremeClose: point.close,
                    extremeDate: point.date,
                    daysSinceExtreme: 0
                )
            }
            return resetToSidewaysIfStale(
                state,
                at: point,
                availableBarrier: availableBarrier
            )
        }
    }

    private static func resetToSidewaysIfStale(
        _ state: State,
        at point: RollingPricePathPoint,
        availableBarrier: Double
    ) -> State {
        guard state.daysSinceExtreme >= horizon else { return state }
        return sidewaysState(at: point, barrier: availableBarrier)
    }

    private static func sidewaysState(
        at point: RollingPricePathPoint,
        barrier: Double
    ) -> State {
        State(
            phase: .sideways,
            barrier: barrier,
            anchorClose: point.close,
            anchorDate: point.date,
            extremeClose: point.close,
            extremeDate: point.date,
            daysSinceExtreme: 0
        )
    }
}
