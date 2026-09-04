import Foundation

enum StrategyFitTrendClassification: Equatable {
    case unavailable
    case stable
    case improving
    case worsening
}

enum StrategyFitTrendDisplayClassification: Equatable {
    case unavailable
    case stable
    case improvingWarning
    case worseningWarning
    case improvingConfirmed
    case worseningConfirmed
}

enum StrategyFitTrendPhase: Int, Equatable {
    case unavailable = 0
    case neutral = 1
    case improvingWarning = 2
    case worseningWarning = 3
    // 保留既有 raw value，讓舊資料仍可解碼；新版完整重播不再產生這兩個未分段狀態。
    case improvingConfirmed = 4
    case worseningConfirmed = 5
    case improvingCooldown = 6
    case worseningCooldown = 7
    case improvingConfirmedSeekingPeak = 8
    case improvingConfirmedPullingBack = 9
    case worseningConfirmedSeekingBottom = 10
    case worseningConfirmedRebounding = 11

    var isImprovingConfirmed: Bool {
        switch self {
        case .improvingConfirmed, .improvingConfirmedSeekingPeak, .improvingConfirmedPullingBack:
            return true
        default:
            return false
        }
    }

    var isWorseningConfirmed: Bool {
        switch self {
        case .worseningConfirmed, .worseningConfirmedSeekingBottom, .worseningConfirmedRebounding:
            return true
        default:
            return false
        }
    }

    var displayClassification: StrategyFitTrendDisplayClassification {
        switch self {
        case .improvingWarning:
            return .improvingWarning
        case .worseningWarning:
            return .worseningWarning
        case .improvingConfirmed, .improvingConfirmedSeekingPeak, .improvingConfirmedPullingBack:
            return .improvingConfirmed
        case .worseningConfirmed, .worseningConfirmedSeekingBottom, .worseningConfirmedRebounding:
            return .worseningConfirmed
        case .unavailable, .neutral, .improvingCooldown, .worseningCooldown:
            return .stable
        }
    }

    var displayIconSystemName: String? {
        switch self {
        case .improvingWarning, .improvingConfirmed, .improvingConfirmedSeekingPeak:
            return "arrow.up.right.circle.fill"
        case .worseningWarning, .worseningConfirmed, .worseningConfirmedSeekingBottom:
            return "arrow.down.right.circle.fill"
        case .improvingConfirmedPullingBack:
            return "arrow.down.right.circle"
        case .worseningConfirmedRebounding:
            return "arrow.up.right.circle"
        case .unavailable, .neutral, .improvingCooldown, .worseningCooldown:
            return nil
        }
    }
}

struct StrategyFitTrendPhaseState: Equatable {
    let phase: StrategyFitTrendPhase
    let extreme: Double?
}

enum StrategyFitTrendConfirmedMaturity: Equatable {
    case early
    case late
}

struct StrategyFitTrendClassifier {
    static let displayThreshold = 0.611888
    static let displayThresholdVersion = "FT3-Q75-v1"
    static let minimumObservationCount = 125

    static func classify(
        fitTrend: Double?,
        observationCount: Int
    ) -> StrategyFitTrendClassification {
        guard observationCount >= minimumObservationCount,
              let fitTrend,
              fitTrend.isFinite else {
            return .unavailable
        }
        if fitTrend > displayThreshold {
            return .improving
        }
        if fitTrend < -displayThreshold {
            return .worsening
        }
        return .stable
    }
}

struct StrategyFitTrendPhaseUpdater {
    static let warningThreshold = 0.3
    static let warningThresholdVersion = "PW1-ABCD-v1"
    // S33：確認趨勢自本段谷底／高點反向超過 0.3，才切換為反彈／回落段。
    static let confirmedTurnThreshold = 0.3
    // 探頂／探底從確認門檻再延伸一個既有轉折幅度後，顯示為後期。
    // 這是由既有持久極值衍生的顯示分類，不改寫 phase raw value。
    static let confirmedLateThreshold =
        StrategyFitTrendClassifier.displayThreshold + confirmedTurnThreshold
    // 惡化反彈若比前一交易日下降超過此值，視為新一輪探底。
    static let worseningReboundResetThreshold = 0.3

    static func next(
        fitTrend: Double?,
        previousPhase: StrategyFitTrendPhase,
        previousExtreme: Double?,
        previousFitTrend: Double? = nil
    ) -> StrategyFitTrendPhaseState {
        guard let fitTrend, fitTrend.isFinite else {
            return StrategyFitTrendPhaseState(phase: .unavailable, extreme: nil)
        }
        let confirmed = StrategyFitTrendClassifier.classify(
            fitTrend: fitTrend,
            observationCount: StrategyFitTrendClassifier.minimumObservationCount
        )
        switch confirmed {
        case .improving:
            return nextImprovingConfirmed(
                fitTrend: fitTrend,
                previousPhase: previousPhase,
                previousExtreme: previousExtreme
            )
        case .worsening:
            return nextWorseningConfirmed(
                fitTrend: fitTrend,
                previousPhase: previousPhase,
                previousExtreme: previousExtreme,
                previousFitTrend: previousFitTrend
            )
        case .stable, .unavailable:
            break
        }

        if abs(fitTrend) < warningThreshold {
            return StrategyFitTrendPhaseState(phase: .neutral, extreme: nil)
        }
        if fitTrend >= warningThreshold {
            let phase: StrategyFitTrendPhase = previousPhase.isImprovingConfirmed
                || previousPhase == .improvingCooldown
                ? .improvingCooldown : .improvingWarning
            return StrategyFitTrendPhaseState(phase: phase, extreme: nil)
        }
        if fitTrend <= -warningThreshold {
            let phase: StrategyFitTrendPhase = previousPhase.isWorseningConfirmed
                || previousPhase == .worseningCooldown
                ? .worseningCooldown : .worseningWarning
            return StrategyFitTrendPhaseState(phase: phase, extreme: nil)
        }
        return StrategyFitTrendPhaseState(phase: .neutral, extreme: nil)
    }

    private static func nextImprovingConfirmed(
        fitTrend: Double,
        previousPhase: StrategyFitTrendPhase,
        previousExtreme: Double?
    ) -> StrategyFitTrendPhaseState {
        guard previousPhase.isImprovingConfirmed,
              let previousExtreme,
              previousExtreme.isFinite else {
            return StrategyFitTrendPhaseState(
                phase: .improvingConfirmedSeekingPeak,
                extreme: fitTrend
            )
        }
        if previousPhase == .improvingConfirmedPullingBack {
            if fitTrend > previousExtreme {
                return StrategyFitTrendPhaseState(
                    phase: .improvingConfirmedSeekingPeak,
                    extreme: fitTrend
                )
            }
            return StrategyFitTrendPhaseState(
                phase: .improvingConfirmedPullingBack,
                extreme: previousExtreme
            )
        }
        let peak = max(previousExtreme, fitTrend)
        let phase: StrategyFitTrendPhase = fitTrend < peak - confirmedTurnThreshold
            ? .improvingConfirmedPullingBack : .improvingConfirmedSeekingPeak
        return StrategyFitTrendPhaseState(phase: phase, extreme: peak)
    }

    private static func nextWorseningConfirmed(
        fitTrend: Double,
        previousPhase: StrategyFitTrendPhase,
        previousExtreme: Double?,
        previousFitTrend: Double?
    ) -> StrategyFitTrendPhaseState {
        guard previousPhase.isWorseningConfirmed,
              let previousExtreme,
              previousExtreme.isFinite else {
            return StrategyFitTrendPhaseState(
                phase: .worseningConfirmedSeekingBottom,
                extreme: fitTrend
            )
        }
        if previousPhase == .worseningConfirmedRebounding {
            let dailyDropRestartsSeeking = previousFitTrend.map {
                fitTrend < $0 - worseningReboundResetThreshold
            } ?? false
            if fitTrend < previousExtreme || dailyDropRestartsSeeking {
                return StrategyFitTrendPhaseState(
                    phase: .worseningConfirmedSeekingBottom,
                    extreme: fitTrend
                )
            }
            return StrategyFitTrendPhaseState(
                phase: .worseningConfirmedRebounding,
                extreme: previousExtreme
            )
        }
        let bottom = min(previousExtreme, fitTrend)
        let phase: StrategyFitTrendPhase = fitTrend > bottom + confirmedTurnThreshold
            ? .worseningConfirmedRebounding : .worseningConfirmedSeekingBottom
        return StrategyFitTrendPhaseState(phase: phase, extreme: bottom)
    }
}

struct StrategyFitState: Equatable {
    static let fastPeriod = 20
    static let slowPeriod = 125

    private(set) var fitFast: Double?
    private(set) var fitSlow: Double?
    private(set) var observationCount: Int

    init(
        fitFast: Double? = nil,
        fitSlow: Double? = nil,
        observationCount: Int = 0
    ) {
        self.fitFast = fitFast
        self.fitSlow = fitSlow
        self.observationCount = observationCount
    }

    var fitTrend: Double? {
        guard let fitFast,
              let fitSlow,
              fitFast.isFinite,
              fitSlow.isFinite else {
            return nil
        }
        return fitFast - fitSlow
    }

    var isValid: Bool {
        observationCount > 0 && fitTrend != nil
    }

    @discardableResult
    mutating func update(
        fitLevel: Double,
        roi: Double,
        days: Double
    ) -> Bool {
        guard fitLevel.isFinite,
              roi.isFinite,
              days.isFinite,
              days > 0 else {
            return false
        }

        if observationCount == 0 && fitFast == nil && fitSlow == nil {
            fitFast = fitLevel
            fitSlow = fitLevel
            observationCount = 1
            return true
        }

        guard observationCount > 0,
              let fitFast,
              let fitSlow,
              fitFast.isFinite,
              fitSlow.isFinite else {
            return false
        }

        self.fitFast = Self.ema(
            previous: fitFast,
            value: fitLevel,
            period: Self.fastPeriod
        )
        self.fitSlow = Self.ema(
            previous: fitSlow,
            value: fitLevel,
            period: Self.slowPeriod
        )
        observationCount += 1
        return true
    }

    private static func ema(
        previous: Double,
        value: Double,
        period: Int
    ) -> Double {
        let alpha = 2.0 / Double(period + 1)
        return previous + alpha * (value - previous)
    }
}

struct StrategyFitTrendPreview: Equatable {
    let phase: StrategyFitTrendPhase
    let phaseExtreme: Double?
    let observationCount: Int
}

extension Trade {
    var strategyFitState: StrategyFitState {
        StrategyFitState(
            fitFast: simFitFast,
            fitSlow: simFitSlow,
            observationCount: simFitObservationCount
        )
    }

    var strategyFitTrendClassification: StrategyFitTrendClassification {
        StrategyFitTrendClassifier.classify(
            fitTrend: simFitTrend,
            observationCount: simFitObservationCount
        )
    }

    var strategyFitTrendPhase: StrategyFitTrendPhase {
        StrategyFitTrendPhase(rawValue: simFitTrendPhaseRaw) ?? .unavailable
    }

    var strategyFitTrendDisplayClassification: StrategyFitTrendDisplayClassification {
        guard simFitObservationCount >= StrategyFitTrendClassifier.minimumObservationCount else {
            return .unavailable
        }
        return strategyFitTrendPhase.displayClassification
    }

    var strategyFitTrendDisplayPhase: StrategyFitTrendPhase {
        guard simFitObservationCount >= StrategyFitTrendClassifier.minimumObservationCount else {
            return .unavailable
        }
        return strategyFitTrendPhase
    }

    var strategyFitTrendConfirmedMaturity: StrategyFitTrendConfirmedMaturity? {
        guard simFitObservationCount >= StrategyFitTrendClassifier.minimumObservationCount,
              let extreme = simFitTrendPhaseExtreme,
              extreme.isFinite else {
            return nil
        }
        switch strategyFitTrendDisplayPhase {
        case .improvingConfirmedSeekingPeak:
            return extreme >= StrategyFitTrendPhaseUpdater.confirmedLateThreshold
                ? .late : .early
        case .worseningConfirmedSeekingBottom:
            return extreme <= -StrategyFitTrendPhaseUpdater.confirmedLateThreshold
                ? .late : .early
        default:
            return nil
        }
    }

    var strategyFitTrendIconColorOpacity: Double {
        switch strategyFitTrendConfirmedMaturity {
        case .early:
            return 0.58
        case .late, nil:
            return 1.0
        }
    }

    var strategyFitTrendAccessibilityText: String? {
        switch strategyFitTrendDisplayPhase {
        case .improvingWarning:
            return "適配趨勢改善預警"
        case .worseningWarning:
            return "適配趨勢惡化預警"
        case .improvingConfirmed:
            return "適配趨勢確認改善"
        case .worseningConfirmed:
            return "適配趨勢確認惡化"
        case .improvingConfirmedSeekingPeak:
            switch strategyFitTrendConfirmedMaturity {
            case .early:
                return "適配趨勢改善確認，探頂前期"
            case .late:
                return "適配趨勢改善確認，探頂後期"
            case nil:
                return "適配趨勢改善確認，探頂段"
            }
        case .improvingConfirmedPullingBack:
            return "適配趨勢改善確認，拉回段"
        case .worseningConfirmedSeekingBottom:
            switch strategyFitTrendConfirmedMaturity {
            case .early:
                return "適配趨勢惡化確認，探底前期"
            case .late:
                return "適配趨勢惡化確認，探底後期"
            case nil:
                return "適配趨勢惡化確認，探底段"
            }
        case .worseningConfirmedRebounding:
            return "適配趨勢惡化確認，反彈段"
        case .unavailable, .neutral, .improvingCooldown, .worseningCooldown:
            return nil
        }
    }
}

extension Technical {
    func previewStrategyFitTrend(
        _ trades: [Trade],
        index: Int
    ) -> StrategyFitTrendPreview {
        guard trades.indices.contains(index), index > 0 else {
            return StrategyFitTrendPreview(phase: .unavailable, phaseExtreme: nil, observationCount: 0)
        }

        let trade = trades[index]
        let previous = trades[index - 1]
        guard !trade.isBeforeSimulationStart else {
            return StrategyFitTrendPreview(phase: .unavailable, phaseExtreme: nil, observationCount: 0)
        }

        var state = previous.strategyFitState
        guard state.update(
            fitLevel: trade.gradeEfficiencyScore,
            roi: trade.roi,
            days: trade.days
        ) else {
            return StrategyFitTrendPreview(phase: .unavailable, phaseExtreme: nil, observationCount: 0)
        }
        let phaseState = StrategyFitTrendPhaseUpdater.next(
            fitTrend: state.fitTrend,
            previousPhase: previous.strategyFitTrendPhase,
            previousExtreme: previous.simFitTrendPhaseExtreme,
            previousFitTrend: previous.simFitTrend
        )
        return StrategyFitTrendPreview(
            phase: phaseState.phase,
            phaseExtreme: phaseState.extreme,
            observationCount: state.observationCount
        )
    }

    func updateStrategyFitState(_ trades: [Trade], index: Int) {
        guard trades.indices.contains(index) else { return }
        let trade = trades[index]

        guard index > 0, !trade.isBeforeSimulationStart else {
            trade.simFitFast = nil
            trade.simFitSlow = nil
            trade.simFitTrend = nil
            trade.simFitObservationCount = 0
            trade.simFitTrendPhaseRaw = StrategyFitTrendPhase.unavailable.rawValue
            trade.simFitTrendPhaseExtreme = nil
            return
        }

        var state = trades[index - 1].strategyFitState
        _ = state.update(
            fitLevel: trade.gradeEfficiencyScore,
            roi: trade.roi,
            days: trade.days
        )
        trade.simFitFast = state.fitFast
        trade.simFitSlow = state.fitSlow
        trade.simFitTrend = state.fitTrend
        trade.simFitObservationCount = state.observationCount
        let phaseState = StrategyFitTrendPhaseUpdater.next(
            fitTrend: state.fitTrend,
            previousPhase: trades[index - 1].strategyFitTrendPhase,
            previousExtreme: trades[index - 1].simFitTrendPhaseExtreme,
            previousFitTrend: trades[index - 1].simFitTrend
        )
        trade.simFitTrendPhaseRaw = phaseState.phase.rawValue
        trade.simFitTrendPhaseExtreme = phaseState.extreme
    }
}
