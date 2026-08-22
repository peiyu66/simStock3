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
    case improvingConfirmed = 4
    case worseningConfirmed = 5
    case improvingCooldown = 6
    case worseningCooldown = 7

    var displayClassification: StrategyFitTrendDisplayClassification {
        switch self {
        case .improvingWarning:
            return .improvingWarning
        case .worseningWarning:
            return .worseningWarning
        case .improvingConfirmed:
            return .improvingConfirmed
        case .worseningConfirmed:
            return .worseningConfirmed
        case .unavailable, .neutral, .improvingCooldown, .worseningCooldown:
            return .stable
        }
    }
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

    static func next(
        fitTrend: Double?,
        previousPhase: StrategyFitTrendPhase
    ) -> StrategyFitTrendPhase {
        guard let fitTrend, fitTrend.isFinite else {
            return .unavailable
        }
        let confirmed = StrategyFitTrendClassifier.classify(
            fitTrend: fitTrend,
            observationCount: StrategyFitTrendClassifier.minimumObservationCount
        )
        switch confirmed {
        case .improving:
            return .improvingConfirmed
        case .worsening:
            return .worseningConfirmed
        case .stable, .unavailable:
            break
        }

        if abs(fitTrend) < warningThreshold {
            return .neutral
        }
        if fitTrend >= warningThreshold {
            switch previousPhase {
            case .improvingConfirmed, .improvingCooldown:
                return .improvingCooldown
            default:
                return .improvingWarning
            }
        }
        if fitTrend <= -warningThreshold {
            switch previousPhase {
            case .worseningConfirmed, .worseningCooldown:
                return .worseningCooldown
            default:
                return .worseningWarning
            }
        }
        return .neutral
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

    var strategyFitTrendAccessibilityText: String? {
        switch strategyFitTrendDisplayClassification {
        case .improvingWarning:
            return "適配趨勢改善預警"
        case .worseningWarning:
            return "適配趨勢惡化預警"
        case .improvingConfirmed:
            return "適配趨勢確認改善"
        case .worseningConfirmed:
            return "適配趨勢確認惡化"
        case .stable, .unavailable:
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
            return StrategyFitTrendPreview(phase: .unavailable, observationCount: 0)
        }

        let trade = trades[index]
        let previous = trades[index - 1]
        guard !trade.isBeforeSimulationStart else {
            return StrategyFitTrendPreview(phase: .unavailable, observationCount: 0)
        }

        var state = previous.strategyFitState
        guard state.update(
            fitLevel: trade.gradeEfficiencyScore,
            roi: trade.roi,
            days: trade.days
        ) else {
            return StrategyFitTrendPreview(phase: .unavailable, observationCount: 0)
        }
        return StrategyFitTrendPreview(
            phase: StrategyFitTrendPhaseUpdater.next(
                fitTrend: state.fitTrend,
                previousPhase: previous.strategyFitTrendPhase
            ),
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
        trade.simFitTrendPhaseRaw = StrategyFitTrendPhaseUpdater.next(
            fitTrend: state.fitTrend,
            previousPhase: trades[index - 1].strategyFitTrendPhase
        ).rawValue
    }
}
