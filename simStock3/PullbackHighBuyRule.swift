import Foundation

/// H-P03a: do not add a trend vote when price and warmed Grade pull back while the same-day market is peak-late.
enum PullbackHighBuyRule {
    static func suppressesVote(grade: Trade.Grade, pricePhase: PricePathPhase,
                               decisionTrend: StrategyFitTrendPreview, marketPhase: PricePathPhase?) -> Bool {
        marketPhase == .seekingPeakLate
            && grade != .none
            && decisionTrend.observationCount >= StrategyFitTrendClassifier.minimumObservationCount
            && decisionTrend.phase == .improvingConfirmedPullingBack
            && (pricePhase == .pullingBackEarly || pricePhase == .pullingBackLate)
    }
}
