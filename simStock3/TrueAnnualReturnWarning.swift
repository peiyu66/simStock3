import Foundation

/// Presentation-only history; persisted after simulation, never a trading input.
struct TrueAnnualReturnWarning: Sendable {
    enum Status: String, Codable, Sendable {
        case unavailable, normal, caution, recovering, released
    }

    enum PrewarningReason: String, Codable, Sendable {
        case returnWeakness, priceBottom, both, anchorWeakness
        case returnAndAnchor = "returnWeakness+anchorWeakness"
        case bottomAndAnchor = "priceBottom+anchorWeakness"
        case all = "both+anchorWeakness"
    }

    enum LocalReleaseReason: String, Codable, Sendable {
        case breakout, stableProfit
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
        var stableRecoveryConfirmed: Bool = false
        var localReleaseReason: LocalReleaseReason? = nil

        var breakoutReference: Double? = nil
        var breakoutConfirmationDays: Int? = nil
        var anchorFailureDays: Int = 0

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

    struct BreakoutSetup: Codable, Equatable, Sendable {
        var age: Int
        let level: Double
        let annual: Double
        let grade: Double
        let profit: Double
        var isValid: Bool {
            (1...20).contains(age) && level.isFinite && level > 0
                && annual.isFinite && grade.isFinite && grade != 0 && profit.isFinite
        }
    }
    struct ReleaseAnchor: Codable, Equatable, Sendable {
        let close: Double
        let annual: Double
        let grade: Double
        let profit: Double
        let level: Double
        var isValid: Bool {
            close.isFinite && close > 0 && annual.isFinite && grade.isFinite
                && grade != 0 && profit.isFinite && level.isFinite && level > 0
        }
    }
    /// Always encoded, even with empty setup/anchor, so incomplete v6 payloads fail closed.
    struct Continuation: Codable, Equatable, Sendable {
        var setup: BreakoutSetup?
        var anchor: ReleaseAnchor?
        var failureDays = 0
    }
    private(set) var continuation = Continuation()

    private struct Point: Sendable {
        let annual: Double
        let close: Double
        let ma60: Double
        let gradeSeekingPeak: Bool
        let gradeScore: Double?
        let cumulativeProfit: Double?
    }
    private var history: [Point] = []
    private(set) var recoveryFloor: Double?
    private(set) var warningPriceHigh: Double?
    private(set) var locallyReleased = false
    private(set) var localReleaseReason: LocalReleaseReason?
    private(set) var prewarningFailureDays: Int?
    private(set) var prewarningReason: PrewarningReason?

    /// Restore the long-lived reference without replaying old warning decisions.
    /// Only the finite trailing observation window is read once at a replay boundary.
    static func seeded(recoveryFloor: Double?, warningPriceHigh: Double?, locallyReleased: Bool,
                       prewarningFailureDays: Int? = nil,
                       prewarningReason: PrewarningReason? = nil,
                       observations: [(annual: Double, close: Double, ma60: Double, grade: Bool)],
                       recoveryObservations: [(gradeScore: Double, cumulativeProfit: Double)] = [],
                       localReleaseReason: LocalReleaseReason? = nil,
                       continuation: Continuation = .init()) -> Self {
        var result = Self()
        result.continuation = continuation
        result.recoveryFloor = recoveryFloor
        result.warningPriceHigh = warningPriceHigh
        result.locallyReleased = locallyReleased
        result.localReleaseReason = locallyReleased ? localReleaseReason : nil
        result.prewarningFailureDays = prewarningFailureDays
        result.prewarningReason = prewarningReason
        let points = Array(observations.suffix(61))
        let recovery = Array(recoveryObservations.suffix(61))
        for (index, point) in points.enumerated() {
            guard point.annual.isFinite, point.close.isFinite, point.ma60.isFinite,
                  point.close > 0, point.ma60 > 0 else {
                result.history.removeAll(keepingCapacity: true)
                result.prewarningFailureDays = nil
                result.prewarningReason = nil
                continue
            }
            let values = recovery.count == points.count ? recovery[index] : nil
            result.history.append(Point(annual: point.annual, close: point.close, ma60: point.ma60,
                gradeSeekingPeak: point.grade, gradeScore: values?.gradeScore,
                cumulativeProfit: values?.cumulativeProfit))
        }
        return result
    }

    mutating func advance(annual: Double, close: Double, ma20: Double, ma60: Double,
                          gradeSeekingPeak: Bool, ma20Days: Double = 0, ma60Days: Double = 0,
                          priceSeekingBottom: Bool = false, ma20DiffZ125: Double = 0,
                          ma60DiffZ125: Double = 0, hasMatureZ125: Bool = false,
                          gradeScore: Double? = nil, cumulativeProfit: Double? = nil) -> Snapshot {
        // Price history must not forget a valid high during an ROI/MA data gap.
        defer {
            if recoveryFloor != nil, close.isFinite, close > 0 {
                warningPriceHigh = max(warningPriceHigh ?? close, close)
            }
        }
        guard annual.isFinite, close.isFinite, ma60.isFinite, close > 0, ma60 > 0 else {
            // Missing data is unknown, never an implicit release. Retain any active target.
            history.removeAll(keepingCapacity: true)
            continuation.setup = nil
            continuation.failureDays = 0
            prewarningFailureDays = nil
            prewarningReason = nil
            return unavailableSnapshot
        }
        defer {
            history.append(Point(annual: annual, close: close, ma60: ma60, gradeSeekingPeak: gradeSeekingPeak,
                                 gradeScore: gradeScore, cumulativeProfit: cumulativeProfit))
            if history.count > 61 { history.removeFirst() }
        }
        guard history.count == 61 else {
            continuation.setup = nil
            continuation.failureDays = 0
            prewarningFailureDays = nil
            prewarningReason = nil
            return unavailableSnapshot
        }
        let prior = history[60]
        let prior20 = history[40].annual
        let prior60 = history[0].annual
        let priceRecovered = close >= ma60 && ma60 >= history[41].ma60
        let recentRecovered = prior.annual > prior20
        let maRecoveryConfirmed = close > ma20 && close > ma60
            && ma20Days > 20 && ma60Days > 20
        // Only completed observations enter this calculation; today's simulation
        // is appended after the decision. A missing/zero denominator never qualifies.
        let stableRecoveryConfirmed = close > ma20 && close > ma60
            && ma20Days > 0 && ma60Days > 0 && hasStableRecentResults
        let activation = prior.annual < prior60 && prior.annual <= prior20
            && close < ma60 && ma60 < history[41].ma60
        // Price is today's input; efficiency always comes from the completed prior day.
        let anchorFailed: Bool
        if locallyReleased, let anchor = continuation.anchor,
           ma20.isFinite, ma20 > 0, let score = prior.gradeScore, score.isFinite,
           let profit = prior.cumulativeProfit, profit.isFinite {
            anchorFailed = close < ma20 && (close < anchor.close || close < anchor.level)
                && prior.annual < anchor.annual && (score < anchor.grade || profit < anchor.profit)
        } else { anchorFailed = false }
        continuation.failureDays = anchorFailed ? continuation.failureDays + 1 : 0
        let gates = priceRecovered && recentRecovered && (prior.gradeSeekingPeak || maRecoveryConfirmed)
        var compound = false
        if !ma20.isFinite || ma20 <= 0 || recoveryFloor == nil || locallyReleased {
            continuation.setup = nil
        } else {
            if var setup = continuation.setup {
                setup.age += 1
                if setup.age > 20 || close <= ma20 || close <= setup.level {
                    continuation.setup = nil
                } else {
                    if let score = prior.gradeScore, let score20 = history[40].gradeScore,
                       let score60 = history[0].gradeScore, let profit = prior.cumulativeProfit,
                       [score, score20, score60, setup.grade].allSatisfy({ $0.isFinite && $0 != 0 }),
                       profit.isFinite {
                        compound = setup.age >= 3 && gates && prior.annual > setup.annual
                            && profit >= setup.profit && score >= setup.grade
                            && score >= score20 && score >= score60
                    }
                    continuation.setup = setup
                }
            }
            if continuation.setup == nil, gates, close > ma20,
               let high = history.suffix(20).map(\.close).max(), close > high,
               let score = prior.gradeScore, score.isFinite, score != 0,
               let profit = prior.cumulativeProfit, profit.isFinite {
                continuation.setup = BreakoutSetup(age: 1, level: high, annual: prior.annual,
                                                    grade: score, profit: profit)
            }
        }
        let wasLocallyReleased = locallyReleased
        var transitioned = false
        if let floor = recoveryFloor {
            if priceRecovered && recentRecovered && prior.annual >= floor {
                recoveryFloor = nil
                warningPriceHigh = nil
                locallyReleased = false
                localReleaseReason = nil
                continuation.anchor = nil
                transitioned = true
            } else if locallyReleased {
                // Full release wins; a paired failure never overwrites it on the same day.
                let failed = ma20.isFinite && ma20 > 0 && close < ma20
                    && !recentRecovered && !prior.gradeSeekingPeak
                if activation || failed || continuation.failureDays >= 2 {
                    locallyReleased = false
                    localReleaseReason = nil
                    continuation.anchor = nil
                    transitioned = true
                }
            } else if compound, let setup = continuation.setup,
                      let score = prior.gradeScore, let profit = prior.cumulativeProfit {
                locallyReleased = true
                localReleaseReason = .breakout
                continuation.anchor = ReleaseAnchor(close: close, annual: prior.annual,
                    grade: score, profit: profit, level: setup.level)
                transitioned = true
            } else if stableRecoveryConfirmed {
                locallyReleased = true
                localReleaseReason = .stableProfit
                transitioned = true
            }
        } else if activation {
            recoveryFloor = prior60
            warningPriceHigh = history.suffix(60).map(\.close).max()
            locallyReleased = false
            localReleaseReason = nil
            transitioned = true
        }
        if transitioned { continuation.failureDays = 0 }
        if recoveryFloor == nil || locallyReleased { continuation.setup = nil }
        let status: Status = recoveryFloor == nil ? .normal :
            locallyReleased ? .released :
            !wasLocallyReleased && priceRecovered && recentRecovered && prior.gradeSeekingPeak ? .recovering : .caution
        if (status == .normal || status == .released), hasMatureZ125,
           ma20DiffZ125.isFinite, ma60DiffZ125.isFinite {
            let returnWeakness = prior.annual <= prior20 && prior.annual < prior60
                && ma20DiffZ125 < 0 && ma60DiffZ125 < 0
            let priceBottom = status == .released && priceSeekingBottom
            let pairedWeakness = status == .released && anchorFailed
            if returnWeakness || priceBottom || pairedWeakness {
                prewarningFailureDays = 0
                if pairedWeakness {
                    prewarningReason = returnWeakness ? (priceBottom ? .all : .returnAndAnchor)
                        : (priceBottom ? .bottomAndAnchor : .anchorWeakness)
                } else {
                    prewarningReason = returnWeakness ? (priceBottom ? .both : .returnWeakness) : .priceBottom
                }
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
                        maRecoveryConfirmed: maRecoveryConfirmed,
                        stableRecoveryConfirmed: stableRecoveryConfirmed,
                        localReleaseReason: localReleaseReason,
                        breakoutReference: continuation.setup?.level ?? continuation.anchor?.level,
                        breakoutConfirmationDays: continuation.setup?.age,
                        anchorFailureDays: continuation.failureDays)
    }

    private var unavailableSnapshot: Snapshot {
        var snapshot = Snapshot.unavailable
        snapshot.localReleaseReason = localReleaseReason
        return snapshot
    }

    private var hasStableRecentResults: Bool {
        guard history.count == 61,
              let current = history[60].gradeScore, current.isFinite,
              let grade20 = history[40].gradeScore, grade20.isFinite, grade20 != 0,
              let grade60 = history[0].gradeScore, grade60.isFinite, grade60 != 0 else { return false }
        let change20 = 100 * (current - grade20) / abs(grade20)
        let change60 = 100 * (current - grade60) / abs(grade60)
        guard change20.isFinite, change60.isFinite,
              change20 >= -10, change60 >= -10 else { return false }
        let profits = history.compactMap(\.cumulativeProfit)
        guard profits.count == 61, profits.allSatisfy({ $0.isFinite }),
              let peak = profits.max(), peak != 0, let currentProfit = profits.last else { return false }
        let drawdown = 100 * (peak - currentProfit) / abs(peak)
        return drawdown.isFinite && drawdown <= 10
    }

}
