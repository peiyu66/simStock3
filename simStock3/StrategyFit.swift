import Foundation

enum StrategyFitTrendClassification: Equatable {
    case unavailable
    case stable
    case improving
    case worsening
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

    var strategyFitTrendAccessibilityText: String? {
        switch strategyFitTrendClassification {
        case .improving:
            return "適配趨勢改善"
        case .worsening:
            return "適配趨勢惡化"
        case .stable, .unavailable:
            return nil
        }
    }
}

extension Technical {
    func updateStrategyFitState(_ trades: [Trade], index: Int) {
        guard trades.indices.contains(index) else { return }
        let trade = trades[index]

        guard index > 0, !trade.isBeforeSimulationStart else {
            trade.simFitFast = nil
            trade.simFitSlow = nil
            trade.simFitTrend = nil
            trade.simFitObservationCount = 0
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
    }
}
