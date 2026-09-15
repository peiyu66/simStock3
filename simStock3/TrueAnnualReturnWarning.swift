import Foundation

/// Presentation-only history; persisted after simulation, never a trading input.
struct TrueAnnualReturnWarning: Sendable {
    enum Status: String, Codable, Sendable {
        case unavailable, normal, caution, recovering, released
    }

    struct Snapshot: Equatable, Codable, Sendable {
        let status: Status
        let priorAnnual: Double?
        let recoveryFloor: Double?
        let priceRecovered: Bool
        let recentReturnRecovered: Bool
        let gradeSeekingPeak: Bool
        var warningPriceHigh: Double? = nil

        static let unavailable = Snapshot(status: .unavailable, priorAnnual: nil,
            recoveryFloor: nil, priceRecovered: false,
            recentReturnRecovered: false, gradeSeekingPeak: false)

        var isWarning: Bool { status == .caution || status == .recovering }
        var recoveryGap: Double? {
            guard let priorAnnual, let recoveryFloor else { return nil }
            return max(0, recoveryFloor - priorAnnual)
        }
    }

    private struct Point: Sendable {
        let annual: Double
        let close: Double
        let ma60: Double
        let gradeSeekingPeak: Bool
    }
    private var history: [Point] = []
    private(set) var recoveryFloor: Double?
    private(set) var warningPriceHigh: Double?
    private(set) var locallyReleased = false

    /// Restore the long-lived reference without replaying old warning decisions.
    /// Only the finite trailing observation window is read once at a replay boundary.
    static func seeded(recoveryFloor: Double?, warningPriceHigh: Double?, locallyReleased: Bool,
                       observations: [(annual: Double, close: Double, ma60: Double, grade: Bool)]) -> Self {
        var result = Self()
        result.recoveryFloor = recoveryFloor
        result.warningPriceHigh = warningPriceHigh
        result.locallyReleased = locallyReleased
        for point in observations.suffix(61) {
            guard point.annual.isFinite, point.close.isFinite, point.ma60.isFinite,
                  point.close > 0, point.ma60 > 0 else {
                result.history.removeAll(keepingCapacity: true)
                continue
            }
            result.history.append(Point(annual: point.annual, close: point.close, ma60: point.ma60, gradeSeekingPeak: point.grade))
        }
        return result
    }

    mutating func advance(annual: Double, close: Double, ma20: Double, ma60: Double,
                          gradeSeekingPeak: Bool) -> Snapshot {
        // Price history must not forget a valid high during an ROI/MA data gap.
        defer {
            if recoveryFloor != nil, close.isFinite, close > 0 {
                warningPriceHigh = max(warningPriceHigh ?? close, close)
            }
        }
        guard annual.isFinite, close.isFinite, ma60.isFinite, close > 0, ma60 > 0 else {
            // Missing data is unknown, never an implicit release. Retain any active target.
            history.removeAll(keepingCapacity: true)
            return .unavailable
        }
        defer {
            history.append(Point(annual: annual, close: close, ma60: ma60, gradeSeekingPeak: gradeSeekingPeak))
            if history.count > 61 { history.removeFirst() }
        }
        guard history.count == 61 else { return .unavailable }
        let prior = history[60]
        let prior20 = history[40].annual
        let prior60 = history[0].annual
        let priceRecovered = close >= ma60 && ma60 >= history[41].ma60
        let recentRecovered = prior.annual > prior20
        let activation = prior.annual < prior60 && prior.annual <= prior20
            && close < ma60 && ma60 < history[41].ma60
        if let floor = recoveryFloor {
            if priceRecovered && recentRecovered && prior.annual >= floor {
                recoveryFloor = nil
                warningPriceHigh = nil
                locallyReleased = false
            } else if locallyReleased {
                // Full release takes precedence. Rearming never lowers either reference.
                let failed = ma20.isFinite && ma20 > 0 && close < ma20
                    && !recentRecovered && !prior.gradeSeekingPeak
                if activation || failed { locallyReleased = false }
            } else if let high = warningPriceHigh,
                      priceRecovered && recentRecovered && prior.gradeSeekingPeak
                        && close > high
                        && prior.annual > history.prefix(60).map(\.annual).max()! {
                locallyReleased = true
            }
        } else if activation {
            recoveryFloor = prior60
            warningPriceHigh = history.suffix(60).map(\.close).max()
            locallyReleased = false
        }
        let status: Status = recoveryFloor == nil ? .normal :
            locallyReleased ? .released :
            priceRecovered && recentRecovered && prior.gradeSeekingPeak ? .recovering : .caution
        return Snapshot(status: status, priorAnnual: prior.annual, recoveryFloor: recoveryFloor,
                        priceRecovered: priceRecovered, recentReturnRecovered: recentRecovered,
                        gradeSeekingPeak: prior.gradeSeekingPeak, warningPriceHigh: warningPriceHigh)
    }
}
