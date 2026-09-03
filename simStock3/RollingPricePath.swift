import Foundation

/// Stable values persisted in `Trade.tPricePathPhaseRaw`. New cases must only
/// be appended so an existing store never changes the meaning of a raw value.
enum PricePathPhase: Int, CaseIterable, Sendable {
    case unavailable = 0
    case sideways = 1
    case seekingPeakEarly = 2
    case seekingPeakLate = 3
    case pullingBackEarly = 4
    case pullingBackLate = 5
    case seekingBottomEarly = 6
    case seekingBottomLate = 7
    case reboundingEarly = 8
    case reboundingLate = 9
}

enum PricePathStageLine: Equatable, Sendable {
    case none
    case bottom
    case top
}

extension PricePathPhase {
    var displayName: String {
        switch self {
        case .unavailable: "資料不足"
        case .sideways: "盤整"
        case .seekingPeakEarly: "探頂前期"
        case .seekingPeakLate: "探頂後期"
        case .pullingBackEarly: "拉回前期"
        case .pullingBackLate: "拉回後期"
        case .seekingBottomEarly: "探底前期"
        case .seekingBottomLate: "探底後期"
        case .reboundingEarly: "反彈前期"
        case .reboundingLate: "反彈後期"
        }
    }

    var strategyFitIconPhase: StrategyFitTrendPhase {
        switch self {
        case .unavailable, .sideways:
            return .neutral
        case .seekingPeakEarly, .seekingPeakLate:
            return .improvingConfirmedSeekingPeak
        case .pullingBackEarly, .pullingBackLate:
            return .improvingConfirmedPullingBack
        case .seekingBottomEarly, .seekingBottomLate:
            return .worseningConfirmedSeekingBottom
        case .reboundingEarly, .reboundingLate:
            return .worseningConfirmedRebounding
        }
    }

    var stageLine: PricePathStageLine {
        switch self {
        case .seekingPeakEarly, .pullingBackEarly,
             .seekingBottomEarly, .reboundingEarly:
            return .bottom
        case .seekingPeakLate, .pullingBackLate,
             .seekingBottomLate, .reboundingLate:
            return .top
        case .unavailable, .sideways:
            return .none
        }
    }
}

struct PricePathStoredState: Equatable, Sendable {
    var phase: PricePathPhase
    var barrier: Double
    var anchorClose: Double
    var extremeClose: Double
    var daysSinceExtreme: Int
}

extension Trade {
    var pricePathPhase: PricePathPhase {
        get { PricePathPhase(rawValue: tPricePathPhaseRaw) ?? .unavailable }
        set { tPricePathPhaseRaw = newValue.rawValue }
    }

    func resetPricePathTechnicalValues() {
        pricePathPhase = .unavailable
        tPricePathBarrier = nil
        tPricePathAnchorClose = nil
        tPricePathExtremeClose = nil
        tPricePathDaysSinceExtreme = 0
    }

    var storedPricePathState: PricePathStoredState? {
        guard pricePathPhase != .unavailable,
              let barrier = tPricePathBarrier,
              let anchorClose = tPricePathAnchorClose,
              let extremeClose = tPricePathExtremeClose,
              barrier.isFinite,
              barrier >= RollingPricePathClassifier.minimumBarrier,
              barrier <= RollingPricePathClassifier.maximumBarrier,
              anchorClose.isFinite,
              anchorClose > 0,
              extremeClose.isFinite,
              extremeClose > 0,
              tPricePathDaysSinceExtreme >= 0 else {
            return nil
        }
        return PricePathStoredState(
            phase: pricePathPhase,
            barrier: barrier,
            anchorClose: anchorClose,
            extremeClose: extremeClose,
            daysSinceExtreme: tPricePathDaysSinceExtreme
        )
    }

    func applyPricePathState(_ state: PricePathStoredState?) {
        guard let state else {
            resetPricePathTechnicalValues()
            return
        }
        pricePathPhase = state.phase
        tPricePathBarrier = state.barrier
        tPricePathAnchorClose = state.anchorClose
        tPricePathExtremeClose = state.extremeClose
        tPricePathDaysSinceExtreme = state.daysSinceExtreme
    }
}

/// Causal price-path state used by tUpdate. It holds at most 60 returns plus
/// the current segment summary, so sequential replay never searches history
/// once the context has been seeded.
struct PricePathRollingContext: Equatable, Sendable {
    private var recentLogReturns: [Double] = []
    private var previousDate: Date?
    private var previousClose: Double?
    private var state: PricePathStoredState?

    static func seeded(
        points: [RollingPricePathPoint],
        state: PricePathStoredState?
    ) -> Self {
        var context = Self()
        for point in points {
            context.appendPriceHistory(point)
        }
        context.state = state
        return context
    }

    mutating func update(date: Date, close: Double) -> PricePathStoredState? {
        guard close.isFinite, close > 0 else {
            resetContinuity()
            return nil
        }
        guard let previousDate, let previousClose else {
            self.previousDate = date
            self.previousClose = close
            state = nil
            return nil
        }
        guard date > previousDate else {
            resetContinuity()
            self.previousDate = date
            self.previousClose = close
            return nil
        }

        recentLogReturns.append(log(close / previousClose))
        if recentLogReturns.count > RollingPricePathClassifier.volatilityLookback {
            recentLogReturns.removeFirst(
                recentLogReturns.count - RollingPricePathClassifier.volatilityLookback
            )
        }
        self.previousDate = date
        self.previousClose = close

        guard let availableBarrier = RollingPricePathClassifier.barrier(
            forLogReturns: recentLogReturns
        ) else {
            state = nil
            return nil
        }
        if let previousState = state {
            state = next(
                from: previousState,
                close: close,
                availableBarrier: availableBarrier
            )
        } else {
            state = sidewaysState(close: close, barrier: availableBarrier)
        }
        return state
    }

    private mutating func appendPriceHistory(_ point: RollingPricePathPoint) {
        guard point.close.isFinite, point.close > 0 else {
            resetContinuity()
            return
        }
        guard let previousDate, let previousClose else {
            self.previousDate = point.date
            self.previousClose = point.close
            return
        }
        guard point.date > previousDate else {
            resetContinuity()
            self.previousDate = point.date
            self.previousClose = point.close
            return
        }
        recentLogReturns.append(log(point.close / previousClose))
        if recentLogReturns.count > RollingPricePathClassifier.volatilityLookback {
            recentLogReturns.removeFirst(
                recentLogReturns.count - RollingPricePathClassifier.volatilityLookback
            )
        }
        self.previousDate = point.date
        self.previousClose = point.close
    }

    private mutating func resetContinuity() {
        recentLogReturns.removeAll(keepingCapacity: true)
        previousDate = nil
        previousClose = nil
        state = nil
    }

    private func next(
        from previous: PricePathStoredState,
        close: Double,
        availableBarrier: Double
    ) -> PricePathStoredState {
        var state = previous
        switch state.phase {
        case .unavailable:
            return sidewaysState(close: close, barrier: availableBarrier)

        case .sideways:
            let change = close / state.anchorClose - 1
            if change >= state.barrier {
                state.extremeClose = close
                state.daysSinceExtreme = 0
                state.phase = seekingPeakPhase(for: state)
            } else if change <= -state.barrier {
                state.extremeClose = close
                state.daysSinceExtreme = 0
                state.phase = seekingBottomPhase(for: state)
            }
            return state

        case .seekingPeakEarly, .seekingPeakLate:
            if close > state.extremeClose {
                state.extremeClose = close
                state.daysSinceExtreme = 0
                state.phase = seekingPeakPhase(for: state)
                return state
            }
            state.daysSinceExtreme += 1
            let pullback = (state.extremeClose - close) / state.extremeClose
            if pullback >= state.barrier / 2 {
                state.phase = pullingBackPhase(pullback: pullback, barrier: state.barrier)
                return state
            }
            return resetToSidewaysIfStale(
                state,
                close: close,
                availableBarrier: availableBarrier
            )

        case .pullingBackEarly, .pullingBackLate:
            if close > state.extremeClose {
                state.extremeClose = close
                state.daysSinceExtreme = 0
                state.phase = seekingPeakPhase(for: state)
                return state
            }
            state.daysSinceExtreme += 1
            let pullback = (state.extremeClose - close) / state.extremeClose
            if pullback >= state.barrier {
                return PricePathStoredState(
                    phase: seekingBottomPhase(
                        anchorClose: state.extremeClose,
                        extremeClose: close,
                        barrier: availableBarrier
                    ),
                    barrier: availableBarrier,
                    anchorClose: state.extremeClose,
                    extremeClose: close,
                    daysSinceExtreme: 0
                )
            }
            state.phase = pullingBackPhase(pullback: pullback, barrier: state.barrier)
            return resetToSidewaysIfStale(
                state,
                close: close,
                availableBarrier: availableBarrier
            )

        case .seekingBottomEarly, .seekingBottomLate:
            if close < state.extremeClose {
                state.extremeClose = close
                state.daysSinceExtreme = 0
                state.phase = seekingBottomPhase(for: state)
                return state
            }
            state.daysSinceExtreme += 1
            let rebound = (close - state.extremeClose) / state.extremeClose
            if rebound >= state.barrier / 2 {
                state.phase = reboundingPhase(rebound: rebound, barrier: state.barrier)
                return state
            }
            return resetToSidewaysIfStale(
                state,
                close: close,
                availableBarrier: availableBarrier
            )

        case .reboundingEarly, .reboundingLate:
            if close < state.extremeClose {
                state.extremeClose = close
                state.daysSinceExtreme = 0
                state.phase = seekingBottomPhase(for: state)
                return state
            }
            state.daysSinceExtreme += 1
            let rebound = (close - state.extremeClose) / state.extremeClose
            if rebound >= state.barrier {
                return PricePathStoredState(
                    phase: seekingPeakPhase(
                        anchorClose: state.extremeClose,
                        extremeClose: close,
                        barrier: availableBarrier
                    ),
                    barrier: availableBarrier,
                    anchorClose: state.extremeClose,
                    extremeClose: close,
                    daysSinceExtreme: 0
                )
            }
            state.phase = reboundingPhase(rebound: rebound, barrier: state.barrier)
            return resetToSidewaysIfStale(
                state,
                close: close,
                availableBarrier: availableBarrier
            )
        }
    }

    private func resetToSidewaysIfStale(
        _ state: PricePathStoredState,
        close: Double,
        availableBarrier: Double
    ) -> PricePathStoredState {
        guard state.daysSinceExtreme >= RollingPricePathClassifier.horizon else {
            return state
        }
        return sidewaysState(close: close, barrier: availableBarrier)
    }

    private func sidewaysState(close: Double, barrier: Double) -> PricePathStoredState {
        PricePathStoredState(
            phase: .sideways,
            barrier: barrier,
            anchorClose: close,
            extremeClose: close,
            daysSinceExtreme: 0
        )
    }

    private func seekingPeakPhase(for state: PricePathStoredState) -> PricePathPhase {
        seekingPeakPhase(
            anchorClose: state.anchorClose,
            extremeClose: state.extremeClose,
            barrier: state.barrier
        )
    }

    private func seekingPeakPhase(
        anchorClose: Double,
        extremeClose: Double,
        barrier: Double
    ) -> PricePathPhase {
        let progress = (extremeClose / anchorClose - 1) / barrier
        return progress >= 1.5 ? .seekingPeakLate : .seekingPeakEarly
    }

    private func seekingBottomPhase(for state: PricePathStoredState) -> PricePathPhase {
        seekingBottomPhase(
            anchorClose: state.anchorClose,
            extremeClose: state.extremeClose,
            barrier: state.barrier
        )
    }

    private func seekingBottomPhase(
        anchorClose: Double,
        extremeClose: Double,
        barrier: Double
    ) -> PricePathPhase {
        let progress = ((anchorClose - extremeClose) / anchorClose) / barrier
        return progress >= 1.5 ? .seekingBottomLate : .seekingBottomEarly
    }

    private func pullingBackPhase(pullback: Double, barrier: Double) -> PricePathPhase {
        pullback / barrier >= 0.75 ? .pullingBackLate : .pullingBackEarly
    }

    private func reboundingPhase(rebound: Double, barrier: Double) -> PricePathPhase {
        rebound / barrier >= 0.75 ? .reboundingLate : .reboundingEarly
    }
}

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
