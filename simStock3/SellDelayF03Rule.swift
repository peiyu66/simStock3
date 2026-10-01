import Foundation

enum SellDelayF03Rule {
    static func matches(ma20Max9: Double, marketPhase: Int, stockHigh: Double,
                        stockMax9: Double, lowZ125: Double, mature: Bool) -> Bool {
        mature && [ma20Max9, stockHigh, stockMax9, lowZ125].allSatisfy { $0.isFinite }
        && ma20Max9 < 1.2 && (marketPhase == 2 || marketPhase == 3)
        && (stockHigh != stockMax9 || lowZ125 < 0)
    }
}
