import Foundation

enum SellDelayF01Rule {
    static func matches(marketHighZ250: Double, oscMax9: Double,
                        stockOscDelta: Double, marketOscDelta: Double,
                        mature: Bool) -> Bool {
        guard mature, [marketHighZ250, oscMax9, stockOscDelta, marketOscDelta].allSatisfy({ $0.isFinite }) else { return false }
        return marketHighZ250 > -0.97 && marketHighZ250 < 0.83 && oscMax9 < 0
            && (stockOscDelta < 0.22 || marketOscDelta > 0)
    }
    // Positive Grade retains R2. Otherwise avoid delaying a whole-day gap-up recovery.
    static func passesRecoveryContext(gradeRaw: Int, lowDiff: Double) -> Bool {
        gradeRaw >= 1 || (lowDiff.isFinite && lowDiff > -0.53)
    }
    static func shouldSuppress(technicalMatch: Bool, normalSell: Bool,
                               profitExit: Bool, recoveryExit: Bool, gradeRaw: Int, lowDiff: Double) -> Bool {
        technicalMatch && normalSell && !profitExit && recoveryExit
            && passesRecoveryContext(gradeRaw: gradeRaw, lowDiff: lowDiff)
    }
}
