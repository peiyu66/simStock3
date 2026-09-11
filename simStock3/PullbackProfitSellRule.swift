import Foundation

/// S-T01c: use the existing low-profit exit in a warmed improving pullback.
enum PullbackProfitSellRule {
    static func roiThreshold(base: Double, grade: Trade.Grade, holdingDays: Double,
                             pricePhase: PricePathPhase, trend: StrategyFitTrendPreview) -> Double {
        guard grade != .none, holdingDays > 1,
              pricePhase == .pullingBackEarly || pricePhase == .pullingBackLate,
              trend.observationCount >= StrategyFitTrendClassifier.minimumObservationCount,
              trend.phase == .improvingConfirmedPullingBack else { return base }
        return 0.45
    }
}
