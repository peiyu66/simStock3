import Foundation
/// S59 / H-E02: adopted HC-I01-F1; missing added inputs retain original HC-I01 behavior.
enum HEntryIncrementalDelayRule {
    static func matches(dZ125: Double, marketHighDiff250: Double, highDiff: Double, lowDiffZ250: Double, mature: Bool) -> Bool {
        guard mature, dZ125.isFinite, marketHighDiff250.isFinite,
              dZ125 < -0.85, marketHighDiff250 > -10, marketHighDiff250 < -1.7 else { return false }
        guard highDiff.isFinite, lowDiffZ250.isFinite else { return true }
        return highDiff > 2.2 || lowDiffZ250 < -0.92
    }
}
