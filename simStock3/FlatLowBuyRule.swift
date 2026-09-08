import Foundation

/// L-P03：盤整時，低 Grade 或惡化探底後期不額外鼓勵空手低接。
enum FlatLowBuyRule {
    static func suppressesVote(inventory: Double, pricePhase: PricePathPhase,
                               grade: Trade.Grade, trend: StrategyFitTrendPreview) -> Bool {
        guard inventory == 0, pricePhase == .sideways else { return false }
        let lateWorsening = trend.observationCount >= StrategyFitTrendClassifier.minimumObservationCount
            && trend.phase == .worseningConfirmedSeekingBottom
            && trend.phaseExtreme.map {
                $0.isFinite && $0 <= -StrategyFitTrendPhaseUpdater.confirmedLateThreshold
            } == true
        return lateWorsening || grade <= .low
    }
}
