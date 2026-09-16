import Foundation

/// Presentation-only history; persisted after simulation, never a trading input.
struct TrueAnnualReturnWarning: Sendable {
    enum Status: String, Codable, Sendable {
        case unavailable, normal, caution, recovering, released
    }

    enum PrewarningReason: String, Codable, Sendable {
        case returnWeakness, priceBottom, both
    }

    struct Snapshot: Equatable, Codable, Sendable {
        let status: Status
        let priorAnnual: Double?
        let recoveryFloor: Double?
        let priceRecovered: Bool
        let recentReturnRecovered: Bool
        let gradeSeekingPeak: Bool
        var warningPriceHigh: Double? = nil
        // nil = inactive; 0 = qualified today; 1/2 = clearance grace days.
        // Keep the original status independent so prewarning cannot alter S53 recovery.
        var prewarningFailureDays: Int? = nil
        // Keep the last qualifying cause during the two clearance grace days.
        var prewarningReason: PrewarningReason? = nil
        var maRecoveryConfirmed: Bool = false

        static let unavailable = Snapshot(status: .unavailable, priorAnnual: nil,
            recoveryFloor: nil, priceRecovered: false,
            recentReturnRecovered: false, gradeSeekingPeak: false)

        var isPrewarning: Bool {
            (status == .normal || status == .released) && prewarningFailureDays != nil
        }
        var isWarning: Bool { status == .caution || status == .recovering || isPrewarning }
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
    private(set) var prewarningFailureDays: Int?
    private(set) var prewarningReason: PrewarningReason?

    /// Restore the long-lived reference without replaying old warning decisions.
    /// Only the finite trailing observation window is read once at a replay boundary.
    static func seeded(recoveryFloor: Double?, warningPriceHigh: Double?, locallyReleased: Bool,
                       prewarningFailureDays: Int? = nil,
                       prewarningReason: PrewarningReason? = nil,
                       observations: [(annual: Double, close: Double, ma60: Double, grade: Bool)]) -> Self {
        var result = Self()
        result.recoveryFloor = recoveryFloor
        result.warningPriceHigh = warningPriceHigh
        result.locallyReleased = locallyReleased
        result.prewarningFailureDays = prewarningFailureDays
        result.prewarningReason = prewarningReason
        for point in observations.suffix(61) {
            guard point.annual.isFinite, point.close.isFinite, point.ma60.isFinite,
                  point.close > 0, point.ma60 > 0 else {
                result.history.removeAll(keepingCapacity: true)
                result.prewarningFailureDays = nil
                result.prewarningReason = nil
                continue
            }
            result.history.append(Point(annual: point.annual, close: point.close, ma60: point.ma60, gradeSeekingPeak: point.grade))
        }
        return result
    }

    mutating func advance(annual: Double, close: Double, ma20: Double, ma60: Double,
                          gradeSeekingPeak: Bool, ma20Days: Double = 0, ma60Days: Double = 0,
                          priceSeekingBottom: Bool = false, ma20DiffZ125: Double = 0,
                          ma60DiffZ125: Double = 0, hasMatureZ125: Bool = false) -> Snapshot {
        // Price history must not forget a valid high during an ROI/MA data gap.
        defer {
            if recoveryFloor != nil, close.isFinite, close > 0 {
                warningPriceHigh = max(warningPriceHigh ?? close, close)
            }
        }
        guard annual.isFinite, close.isFinite, ma60.isFinite, close > 0, ma60 > 0 else {
            // Missing data is unknown, never an implicit release. Retain any active target.
            history.removeAll(keepingCapacity: true)
            prewarningFailureDays = nil
            prewarningReason = nil
            return .unavailable
        }
        defer {
            history.append(Point(annual: annual, close: close, ma60: ma60, gradeSeekingPeak: gradeSeekingPeak))
            if history.count > 61 { history.removeFirst() }
        }
        guard history.count == 61 else {
            prewarningFailureDays = nil
            prewarningReason = nil
            return .unavailable
        }
        let prior = history[60]
        let prior20 = history[40].annual
        let prior60 = history[0].annual
        let priceRecovered = close >= ma60 && ma60 >= history[41].ma60
        let recentRecovered = prior.annual > prior20
        let maRecoveryConfirmed = close > ma20 && close > ma60
            && ma20Days > 20 && ma60Days > 20
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
                      priceRecovered && recentRecovered && (prior.gradeSeekingPeak || maRecoveryConfirmed)
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
        if (status == .normal || status == .released), hasMatureZ125,
           ma20DiffZ125.isFinite, ma60DiffZ125.isFinite {
            let returnWeakness = prior.annual <= prior20 && prior.annual < prior60
                && ma20DiffZ125 < 0 && ma60DiffZ125 < 0
            let priceBottom = status == .released && priceSeekingBottom
            if returnWeakness || priceBottom {
                prewarningFailureDays = 0
                prewarningReason = returnWeakness ? (priceBottom ? .both : .returnWeakness) : .priceBottom
            } else if let failed = prewarningFailureDays {
                prewarningFailureDays = failed < 2 ? failed + 1 : nil
                if prewarningFailureDays == nil { prewarningReason = nil }
            }
        } else {
            // Original warning has priority; immature/missing Z data is not grace.
            prewarningFailureDays = nil
            prewarningReason = nil
        }
        return Snapshot(status: status, priorAnnual: prior.annual, recoveryFloor: recoveryFloor,
                        priceRecovered: priceRecovered, recentReturnRecovered: recentRecovered,
                        gradeSeekingPeak: prior.gradeSeekingPeak, warningPriceHigh: warningPriceHigh,
                        prewarningFailureDays: prewarningFailureDays, prewarningReason: prewarningReason,
                        maRecoveryConfirmed: maRecoveryConfirmed)
    }
}
