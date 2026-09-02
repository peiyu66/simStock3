import Foundation
import SwiftData

#if DEBUG
@MainActor
enum InternalBacktestReport {
    static let recordsDecisionBase = ProcessInfo.processInfo.arguments.contains(
        "--record-decision-base"
    )
    static let recordsDecisionDelta = ProcessInfo.processInfo.arguments.contains(
        "--record-decision-delta"
    )
    static let recordsDecisionDeltaControl = ProcessInfo.processInfo.arguments.contains(
        "--record-decision-delta-control"
    )

    enum Candidate: String {
        case baseline
        case gwS01
        case gwS01b
        case gwA01
        case gwA02
        case gwA02b
        case gwS02
        case removeST01g
        case investCooldown45
        case noInvestCooldown
        case removeGradeActivationGate
        case gradeActivationRounds1
        case gradeActivationRounds3
        case gradeActivationDays300
        case gradeActivationDays420
        case gradeActivationExtremeNegative69
        case ht01WantThresholdM1
        case ht01WantThreshold1
        case ht01WeakOrBelowThreshold1
        case ht01LowOnlyThreshold1
        case removeGradeWow
        case removeGradeHigh
        case removeGradeFine
        case removeGradeDamn
        case removeGradeLow
        case removeGradeWeak
        case neutralGradeMapping
        case scoreBasedGrade
        case scoreBasedGradeSellCompatibility
        case scoreBasedGradeAllCompatibility
        case scoreBasedGradeUpperCompatibility
        case scoreBasedGradeCalibratedBands
        case scoreBasedGradeCalibratedAllBands
        case scoreBasedGradeNeutralBand
        case scoreBasedGradeWeakUsesNeutralMapping
        case scoreGradeFine18
        case removeHN06
        case removeHN02b
        case removeHN01a
        case hn09Strict
        case hn09Loose
        case hn09LowGradeHighStrict
        case hn09LowGradeHighLoose
        case hn09LowGradeHigh06
        case hn09LowGradeHigh08
        case hn09LowGradeHigh10
        case hn09LowGradeHigh12
        case hn09High081313
        case hn09High081315
        case hn09High081520
        case hn09High081515
        case hn09Low081215
        case hn09HighOnly
        case hn09Low051218
        case hn03ThresholdM07
        case hn03ThresholdM03
        case hp01LowerLoose
        case hp01LowerStrict
        case hp01LowUpper19
        case hp01LowUpper21
        case hp01LowUpper15
        case hp01LowUpper25
        case hp01OtherUpper24
        case hp01OtherUpper26
        case hp01OtherUpper20
        case hp01OtherUpper30
        case hp04WeakThreshold19
        case hp04WeakThreshold21
        case hp04WeakThreshold15
        case hp04WeakThreshold25
        case hp03LowBoundaryLow
        case hp03LowBoundaryFine
        case hp03OtherThresholdM025
        case hp03OtherThresholdP025
        case hp03OtherThresholdM05
        case hp03OtherThresholdP05
        case hp03RatedThresholdM025
        case hp03RatedThresholdP025
        case hp03RatedThresholdM05
        case hp03RatedThresholdP05
        case hp03LowerThresholdM075
        case hp03LowerThresholdM025
        case hp03LowerThresholdM10
        case hp03LowerThreshold00
        case hn01aGradeWeakOrBelow
        case hn01aGradeBelowWow
        case hn02bHighBoundaryLow
        case hn02bHighBoundaryFine
        case hn05GradeWeakOrBetter
        case hn05GradeAll
        case hn08Threshold15
        case hn08Threshold17
        case hn08Threshold12
        case hn08Threshold20
        case hn06GradeBoundaryLow
        case hn06GradeBoundaryFine
        case hn06MA20Threshold55
        case hn06MA20Threshold65
        case hn06MA60Threshold65
        case hn06MA60Threshold75
        case hn07MA20Threshold55
        case hn07MA20Threshold65
        case hc01GradeBoundaryLow
        case hc01GradeBoundaryFine
        case hc02GradeBoundaryLow
        case hc02GradeBoundaryFine
        case hc02EarlyStart0216
        case hc02EarlyStart0226
        case hc03RemoveOverlap
        case hc03RemoveLate
        case hc04RemoveOverlap
        case hc04RemoveLate
        case hn01bThreshold17
        case hn01bThreshold19
        case hn02aThresholdM09
        case hn02aThresholdM07
        case hn06RemoveMA20Branch
        case hn06RemoveMA60Branch
        case lc03RemoveC01Overlap
        case lc03RemoveC02Overlap
        case lc03RemoveC01OverlapFineOrBetter
        case lc03RemoveC01OverlapNoneOrBelow
        case lc03RemoveC01OverlapFineOnly
        case lc03RemoveC01OverlapHighOrBetter
        case lc03RemoveMiddle
        case lc01Remove
        case lc02Remove
        case lp07MA60ThresholdM06
        case lp07MA60ThresholdM04
        case lp07MA60ThresholdM10
        case lp07MA60Threshold00
        case lp09MA60ThresholdM25
        case lp09MA60ThresholdM35
        case lp09MA20ThresholdM25
        case lp09MA20ThresholdM35
        case lp03KZ125ThresholdM10
        case lp03KZ125ThresholdM08
        case lp03KZ250ThresholdM10
        case lp03KZ250ThresholdM08
        case lp04DZ125ThresholdM10
        case lp04DZ125ThresholdM08
        case lp04DZ250ThresholdM10
        case lp04DZ250ThresholdM08
        case lp04DZ250ThresholdM11
        case lp04DZ250ThresholdM07
        case lp05OscZ125ThresholdM10
        case lp05OscZ125ThresholdM08
        case lp05OscZ125ThresholdM11
        case lp05OscZ125ThresholdM07
        case lp05OscZ250ThresholdM10
        case lp05OscZ250ThresholdM08
        case lp08HighThresholdM13
        case lp08HighThresholdM11
        case lp08HighThresholdM14
        case lp08HighThresholdM10
        case lp08LowThresholdM16
        case lp08LowThresholdM14
        case lp08MiddleThresholdM145
        case lp08MiddleThresholdM125
        case lp08MiddleThresholdM155
        case lp08MiddleThresholdM115
        case removeLP08
        case ln01MA20DaysThresholdM18
        case ln01MA20DaysThresholdM22
        case ln02DamnOnly
        case ln02WowOnly
        case lt01WantThreshold4
        case lt01WantThreshold6
        case lt01FineOrBetterThreshold6
        case lt01HighOrBetterThreshold6
        case lt01WowThreshold6
        case sp06RemoveABranch
        case sp06RemoveBBranch
        case sp06aUpperLowThreshold06
        case sp06aUpperLowThreshold10
        case sp06aUpperHighThresholdM02
        case sp06aUpperHighThresholdP02
        case sp06aUpperHighThresholdM04
        case sp06aUpperHighThresholdP04
        case sp06bLowerThreshold10
        case sp06bLowerThreshold14
        case sp06bLowerThreshold08
        case sp06bLowerThreshold16
        case sn01RemoveABranch
        case sn01RemoveBBranch
        case st02bRangeThreshold25
        case st02bRangeThreshold35
        case removeAP01a
        case removeAP01b
        case ap01bLowBoundary
        case ap02WowMinimum2
        case ap02WowMinimum4
        case ap05DiffThresholdM175
        case ap05DiffThresholdM225
        case ap06MA20ZThresholdM23
        case ap06MA20ZThresholdM27
        case ap06MA20ZThresholdM21
        case ap06MA20ZThresholdM29
        case ap06MA60ZThresholdM26
        case ap06MA60ZThresholdM30
        case ap07MA20DiffThresholdM7
        case ap07MA20DiffThresholdM9
        case ap07MA20DiffThresholdM6
        case ap07MA20DiffThresholdM10
        case at01WantThreshold2
        case at01WantThreshold4
        case at01WantThreshold1
        case at01WantThreshold5
        case at01ShortDays150
        case at01ShortDays210
        case at01LongDays330
        case at01LongDays390
        case at01ROIThresholdM275
        case at01ROIThresholdM325
        case at01ROIThresholdM3125
        case at01ROIThresholdM35
        case at01Wow35Other325
        case at01Wow35Middle325Low30
        case at01Upper325Low30
        case ae01CooldownDays20 = "A-E01-D20-S1"
        case ae01CooldownDays30
        case ae01CooldownDays60
        case ae01CooldownDays15
        case ae01CooldownDays75
        case ae01CooldownDays38
        case ae03Limit1
        case ae03Limit3
        case ae04ROIThresholdM45
        case ae04ROIThresholdM55
        case removeAE02
        case removeAN02
        case st02RemoveBBranch
        case st02RemoveCBranch
        case st02RemoveScoreGate
        case st01aROI20
        case st01aROI25
        case st01aHighScoreM1
        case st01aHighScore1
        case st01aGeneralScore0
        case st01aGeneralScore2
        case st01aEdgeScore
        case st01cScore4
        case st01cScore6
        case st01cLowROI10
        case st01cLowROI20
        case st01cOtherROI20
        case st01cOtherROI225
        case st01cOtherROI30
        case st01cWeakOrBetterROI20
        case st01cGradeTieredROI
        case st01cWow25Weak20
        case st01cWow25Weak15
        case st01cMiddle225Wow20
        case st01cMiddle20Wow225
        case st01eDays60
        case st01eDays68
        case st01eDays90
        case an01PenaltyM1
        case an01PenaltyM3
        case an01Control
        case an01FineBoundary
        case an01FinePenaltyM1
        case an01FinePenaltyM1NoNone
        case an01FinePenaltyM1LowBelowM1
        case an01FinePenaltyM1LowBelowP1
        case an01FinePenaltyM3
        case an01HighPenaltyM3
        case sn0203FineHighGroup
        case sn0203HighGeneralGroup
        case sn02WowThreshold625
        case sn02WowThreshold875
        case sn02WowCapWithSN05
        case sn05HighOrBetter
        case sn05WeakOrBetter
        case marketVoteNever = "mkt-r02-q0-never"
        case marketVotePulseH = "mkt-r02-q0-pulse-h"
        case marketVotePulseL = "mkt-r02-q0-pulse-l"
        case marketVotePulseS = "mkt-r02-q0-pulse-s"
        case marketVotePulseA = "mkt-r02-q0-pulse-a"
    }

    static let candidate: Candidate = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--candidate-gw-s01") { return .gwS01 }
        if arguments.contains("--candidate-gw-s01b") { return .gwS01b }
        if arguments.contains("--candidate-gw-a01") { return .gwA01 }
        if arguments.contains("--candidate-gw-a02") { return .gwA02 }
        if arguments.contains("--candidate-gw-a02b") { return .gwA02b }
        if arguments.contains("--candidate-gw-s02") { return .gwS02 }
        if arguments.contains("--candidate-remove-st01g") { return .removeST01g }
        if arguments.contains("--candidate-invest-cooldown45") { return .investCooldown45 }
        if arguments.contains("--candidate-no-invest-cooldown") { return .noInvestCooldown }
        if arguments.contains("--candidate-remove-grade-activation-gate") {
            return .removeGradeActivationGate
        }
        if arguments.contains("--candidate-grade-activation-rounds-1") {
            return .gradeActivationRounds1
        }
        if arguments.contains("--candidate-grade-activation-rounds-3") {
            return .gradeActivationRounds3
        }
        if arguments.contains("--candidate-grade-activation-days-300") {
            return .gradeActivationDays300
        }
        if arguments.contains("--candidate-grade-activation-days-420") {
            return .gradeActivationDays420
        }
        if arguments.contains("--candidate-grade-activation-extreme-negative-m69") {
            return .gradeActivationExtremeNegative69
        }
        if arguments.contains("--candidate-ht01-want-threshold-m1") {
            return .ht01WantThresholdM1
        }
        if arguments.contains("--candidate-ht01-want-threshold-1") {
            return .ht01WantThreshold1
        }
        if arguments.contains("--candidate-ht01-weak-or-below-threshold-1") {
            return .ht01WeakOrBelowThreshold1
        }
        if arguments.contains("--candidate-ht01-low-only-threshold-1") {
            return .ht01LowOnlyThreshold1
        }
        if arguments.contains("--candidate-remove-grade-wow") { return .removeGradeWow }
        if arguments.contains("--candidate-remove-grade-high") { return .removeGradeHigh }
        if arguments.contains("--candidate-remove-grade-fine") { return .removeGradeFine }
        if arguments.contains("--candidate-remove-grade-damn") { return .removeGradeDamn }
        if arguments.contains("--candidate-remove-grade-low") { return .removeGradeLow }
        if arguments.contains("--candidate-remove-grade-weak") { return .removeGradeWeak }
        if arguments.contains("--candidate-neutral-grade-mapping") { return .neutralGradeMapping }
        if arguments.contains("--candidate-score-based-grade") { return .scoreBasedGrade }
        if arguments.contains("--candidate-score-grade-s-compatibility") {
            return .scoreBasedGradeSellCompatibility
        }
        if arguments.contains("--candidate-score-grade-all-compatibility") {
            return .scoreBasedGradeAllCompatibility
        }
        if arguments.contains("--candidate-score-grade-upper-compatibility") {
            return .scoreBasedGradeUpperCompatibility
        }
        if arguments.contains("--candidate-score-grade-calibrated-bands") {
            return .scoreBasedGradeCalibratedBands
        }
        if arguments.contains("--candidate-score-grade-calibrated-all-bands") {
            return .scoreBasedGradeCalibratedAllBands
        }
        if arguments.contains("--candidate-score-grade-neutral-band") {
            return .scoreBasedGradeNeutralBand
        }
        if arguments.contains("--candidate-score-grade-weak-neutral-mapping") {
            return .scoreBasedGradeWeakUsesNeutralMapping
        }
        if arguments.contains("--candidate-score-grade-fine18") {
            return .scoreGradeFine18
        }
        if arguments.contains("--candidate-remove-hn06") {
            return .removeHN06
        }
        if arguments.contains("--candidate-remove-hn02b") {
            return .removeHN02b
        }
        if arguments.contains("--candidate-remove-hn01a") {
            return .removeHN01a
        }
        if arguments.contains("--candidate-hn09-strict") {
            return .hn09Strict
        }
        if arguments.contains("--candidate-hn09-loose") {
            return .hn09Loose
        }
        if arguments.contains("--candidate-hn09-low-grade-high-strict") {
            return .hn09LowGradeHighStrict
        }
        if arguments.contains("--candidate-hn09-low-grade-high-loose") {
            return .hn09LowGradeHighLoose
        }
        if arguments.contains("--candidate-hn09-low-grade-high06") {
            return .hn09LowGradeHigh06
        }
        if arguments.contains("--candidate-hn09-low-grade-high08") {
            return .hn09LowGradeHigh08
        }
        if arguments.contains("--candidate-hn09-low-grade-high10") {
            return .hn09LowGradeHigh10
        }
        if arguments.contains("--candidate-hn09-low-grade-high12") {
            return .hn09LowGradeHigh12
        }
        if arguments.contains("--candidate-hn09-high-081313") {
            return .hn09High081313
        }
        if arguments.contains("--candidate-hn09-high-081315") {
            return .hn09High081315
        }
        if arguments.contains("--candidate-hn09-high-081520") {
            return .hn09High081520
        }
        if arguments.contains("--candidate-hn09-high-081515") {
            return .hn09High081515
        }
        if arguments.contains("--candidate-hn09-low-081215") {
            return .hn09Low081215
        }
        if arguments.contains("--candidate-hn09-high-only") {
            return .hn09HighOnly
        }
        if arguments.contains("--candidate-hn09-low-051218") {
            return .hn09Low051218
        }
        if arguments.contains("--candidate-hn03-m07") {
            return .hn03ThresholdM07
        }
        if arguments.contains("--candidate-hn03-m03") {
            return .hn03ThresholdM03
        }
        if arguments.contains("--candidate-hp01-lower-loose") {
            return .hp01LowerLoose
        }
        if arguments.contains("--candidate-hp01-lower-strict") {
            return .hp01LowerStrict
        }
        if arguments.contains("--candidate-hp01-low-upper-19") {
            return .hp01LowUpper19
        }
        if arguments.contains("--candidate-hp01-low-upper-21") {
            return .hp01LowUpper21
        }
        if arguments.contains("--candidate-hp01-low-upper-15") {
            return .hp01LowUpper15
        }
        if arguments.contains("--candidate-hp01-low-upper-25") {
            return .hp01LowUpper25
        }
        if arguments.contains("--candidate-hp01-other-upper-24") {
            return .hp01OtherUpper24
        }
        if arguments.contains("--candidate-hp01-other-upper-26") {
            return .hp01OtherUpper26
        }
        if arguments.contains("--candidate-hp01-other-upper-20") {
            return .hp01OtherUpper20
        }
        if arguments.contains("--candidate-hp01-other-upper-30") {
            return .hp01OtherUpper30
        }
        if arguments.contains("--candidate-hp04-weak-threshold-19") {
            return .hp04WeakThreshold19
        }
        if arguments.contains("--candidate-hp04-weak-threshold-21") {
            return .hp04WeakThreshold21
        }
        if arguments.contains("--candidate-hp04-weak-threshold-15") {
            return .hp04WeakThreshold15
        }
        if arguments.contains("--candidate-hp04-weak-threshold-25") {
            return .hp04WeakThreshold25
        }
        if arguments.contains("--candidate-hp03-low-boundary-low") {
            return .hp03LowBoundaryLow
        }
        if arguments.contains("--candidate-hp03-low-boundary-fine") {
            return .hp03LowBoundaryFine
        }
        if arguments.contains("--candidate-hp03-other-threshold-m025") {
            return .hp03OtherThresholdM025
        }
        if arguments.contains("--candidate-hp03-other-threshold-p025") {
            return .hp03OtherThresholdP025
        }
        if arguments.contains("--candidate-hp03-other-threshold-m05") {
            return .hp03OtherThresholdM05
        }
        if arguments.contains("--candidate-hp03-other-threshold-p05") {
            return .hp03OtherThresholdP05
        }
        if arguments.contains("--candidate-hp03-rated-threshold-m025") {
            return .hp03RatedThresholdM025
        }
        if arguments.contains("--candidate-hp03-rated-threshold-p025") {
            return .hp03RatedThresholdP025
        }
        if arguments.contains("--candidate-hp03-rated-threshold-m05") {
            return .hp03RatedThresholdM05
        }
        if arguments.contains("--candidate-hp03-rated-threshold-p05") {
            return .hp03RatedThresholdP05
        }
        if arguments.contains("--candidate-hp03-lower-threshold-m075") {
            return .hp03LowerThresholdM075
        }
        if arguments.contains("--candidate-hp03-lower-threshold-m025") {
            return .hp03LowerThresholdM025
        }
        if arguments.contains("--candidate-hp03-lower-threshold-m10") {
            return .hp03LowerThresholdM10
        }
        if arguments.contains("--candidate-hp03-lower-threshold-00") {
            return .hp03LowerThreshold00
        }
        if arguments.contains("--candidate-hn01a-grade-weak-or-below") {
            return .hn01aGradeWeakOrBelow
        }
        if arguments.contains("--candidate-hn01a-grade-below-wow") {
            return .hn01aGradeBelowWow
        }
        if arguments.contains("--candidate-hn02b-high-boundary-low") {
            return .hn02bHighBoundaryLow
        }
        if arguments.contains("--candidate-hn02b-high-boundary-fine") {
            return .hn02bHighBoundaryFine
        }
        if arguments.contains("--candidate-hn05-grade-weak-or-better") {
            return .hn05GradeWeakOrBetter
        }
        if arguments.contains("--candidate-hn05-grade-all") {
            return .hn05GradeAll
        }
        if arguments.contains("--candidate-hn08-threshold-15") {
            return .hn08Threshold15
        }
        if arguments.contains("--candidate-hn08-threshold-17") {
            return .hn08Threshold17
        }
        if arguments.contains("--candidate-hn08-threshold-12") {
            return .hn08Threshold12
        }
        if arguments.contains("--candidate-hn08-threshold-20") {
            return .hn08Threshold20
        }
        if arguments.contains("--candidate-hn06-grade-boundary-low") {
            return .hn06GradeBoundaryLow
        }
        if arguments.contains("--candidate-hn06-grade-boundary-fine") {
            return .hn06GradeBoundaryFine
        }
        if arguments.contains("--candidate-hn06-ma20-threshold-55") {
            return .hn06MA20Threshold55
        }
        if arguments.contains("--candidate-hn06-ma20-threshold-65") {
            return .hn06MA20Threshold65
        }
        if arguments.contains("--candidate-hn06-ma60-threshold-65") {
            return .hn06MA60Threshold65
        }
        if arguments.contains("--candidate-hn06-ma60-threshold-75") {
            return .hn06MA60Threshold75
        }
        if arguments.contains("--candidate-hn07-ma20-threshold-55") {
            return .hn07MA20Threshold55
        }
        if arguments.contains("--candidate-hn07-ma20-threshold-65") {
            return .hn07MA20Threshold65
        }
        if arguments.contains("--candidate-hc01-grade-boundary-low") {
            return .hc01GradeBoundaryLow
        }
        if arguments.contains("--candidate-hc01-grade-boundary-fine") {
            return .hc01GradeBoundaryFine
        }
        if arguments.contains("--candidate-hc02-grade-boundary-low") {
            return .hc02GradeBoundaryLow
        }
        if arguments.contains("--candidate-hc02-grade-boundary-fine") {
            return .hc02GradeBoundaryFine
        }
        if arguments.contains("--candidate-hc02-early-start-0216") {
            return .hc02EarlyStart0216
        }
        if arguments.contains("--candidate-hc02-early-start-0226") {
            return .hc02EarlyStart0226
        }
        if arguments.contains("--candidate-hc03-remove-overlap") {
            return .hc03RemoveOverlap
        }
        if arguments.contains("--candidate-hc03-remove-late") {
            return .hc03RemoveLate
        }
        if arguments.contains("--candidate-hc04-remove-overlap") {
            return .hc04RemoveOverlap
        }
        if arguments.contains("--candidate-hc04-remove-late") {
            return .hc04RemoveLate
        }
        if arguments.contains("--candidate-hn01b-threshold-17") {
            return .hn01bThreshold17
        }
        if arguments.contains("--candidate-hn01b-threshold-19") {
            return .hn01bThreshold19
        }
        if arguments.contains("--candidate-hn02a-threshold-m09") {
            return .hn02aThresholdM09
        }
        if arguments.contains("--candidate-hn02a-threshold-m07") {
            return .hn02aThresholdM07
        }
        if arguments.contains("--candidate-hn06-remove-ma20-branch") {
            return .hn06RemoveMA20Branch
        }
        if arguments.contains("--candidate-hn06-remove-ma60-branch") {
            return .hn06RemoveMA60Branch
        }
        if arguments.contains("--candidate-lc03-remove-c01-overlap") {
            return .lc03RemoveC01Overlap
        }
        if arguments.contains("--candidate-lc03-remove-c02-overlap") {
            return .lc03RemoveC02Overlap
        }
        if arguments.contains("--candidate-lc03-remove-c01-overlap-fine-or-better") {
            return .lc03RemoveC01OverlapFineOrBetter
        }
        if arguments.contains("--candidate-lc03-remove-c01-overlap-none-or-below") {
            return .lc03RemoveC01OverlapNoneOrBelow
        }
        if arguments.contains("--candidate-lc03-remove-c01-overlap-fine-only") {
            return .lc03RemoveC01OverlapFineOnly
        }
        if arguments.contains("--candidate-lc03-remove-c01-overlap-high-or-better") {
            return .lc03RemoveC01OverlapHighOrBetter
        }
        if arguments.contains("--candidate-lc03-remove-middle") {
            return .lc03RemoveMiddle
        }
        if arguments.contains("--candidate-lc01-remove") {
            return .lc01Remove
        }
        if arguments.contains("--candidate-lc02-remove") {
            return .lc02Remove
        }
        if arguments.contains("--candidate-lp07-ma60-threshold-m06") {
            return .lp07MA60ThresholdM06
        }
        if arguments.contains("--candidate-lp07-ma60-threshold-m04") {
            return .lp07MA60ThresholdM04
        }
        if arguments.contains("--candidate-lp07-ma60-threshold-m10") {
            return .lp07MA60ThresholdM10
        }
        if arguments.contains("--candidate-lp07-ma60-threshold-00") {
            return .lp07MA60Threshold00
        }
        if arguments.contains("--candidate-lp09-ma60-threshold-m25") {
            return .lp09MA60ThresholdM25
        }
        if arguments.contains("--candidate-lp09-ma60-threshold-m35") {
            return .lp09MA60ThresholdM35
        }
        if arguments.contains("--candidate-lp09-ma20-threshold-m25") {
            return .lp09MA20ThresholdM25
        }
        if arguments.contains("--candidate-lp09-ma20-threshold-m35") {
            return .lp09MA20ThresholdM35
        }
        if arguments.contains("--candidate-lp03-k-z125-threshold-m10") {
            return .lp03KZ125ThresholdM10
        }
        if arguments.contains("--candidate-lp03-k-z125-threshold-m08") {
            return .lp03KZ125ThresholdM08
        }
        if arguments.contains("--candidate-lp03-k-z250-threshold-m10") {
            return .lp03KZ250ThresholdM10
        }
        if arguments.contains("--candidate-lp03-k-z250-threshold-m08") {
            return .lp03KZ250ThresholdM08
        }
        if arguments.contains("--candidate-lp04-d-z125-threshold-m10") {
            return .lp04DZ125ThresholdM10
        }
        if arguments.contains("--candidate-lp04-d-z125-threshold-m08") {
            return .lp04DZ125ThresholdM08
        }
        if arguments.contains("--candidate-lp04-d-z250-threshold-m10") {
            return .lp04DZ250ThresholdM10
        }
        if arguments.contains("--candidate-lp04-d-z250-threshold-m08") {
            return .lp04DZ250ThresholdM08
        }
        if arguments.contains("--candidate-lp04-d-z250-threshold-m11") {
            return .lp04DZ250ThresholdM11
        }
        if arguments.contains("--candidate-lp04-d-z250-threshold-m07") {
            return .lp04DZ250ThresholdM07
        }
        if arguments.contains("--candidate-lp05-osc-z125-threshold-m10") {
            return .lp05OscZ125ThresholdM10
        }
        if arguments.contains("--candidate-lp05-osc-z125-threshold-m08") {
            return .lp05OscZ125ThresholdM08
        }
        if arguments.contains("--candidate-lp05-osc-z125-threshold-m11") {
            return .lp05OscZ125ThresholdM11
        }
        if arguments.contains("--candidate-lp05-osc-z125-threshold-m07") {
            return .lp05OscZ125ThresholdM07
        }
        if arguments.contains("--candidate-lp05-osc-z250-threshold-m10") {
            return .lp05OscZ250ThresholdM10
        }
        if arguments.contains("--candidate-lp05-osc-z250-threshold-m08") {
            return .lp05OscZ250ThresholdM08
        }
        if arguments.contains("--candidate-lp08-high-threshold-m13") {
            return .lp08HighThresholdM13
        }
        if arguments.contains("--candidate-lp08-high-threshold-m11") {
            return .lp08HighThresholdM11
        }
        if arguments.contains("--candidate-lp08-high-threshold-m14") {
            return .lp08HighThresholdM14
        }
        if arguments.contains("--candidate-lp08-high-threshold-m10") {
            return .lp08HighThresholdM10
        }
        if arguments.contains("--candidate-lp08-low-threshold-m16") {
            return .lp08LowThresholdM16
        }
        if arguments.contains("--candidate-lp08-low-threshold-m14") {
            return .lp08LowThresholdM14
        }
        if arguments.contains("--candidate-lp08-middle-threshold-m145") {
            return .lp08MiddleThresholdM145
        }
        if arguments.contains("--candidate-lp08-middle-threshold-m125") {
            return .lp08MiddleThresholdM125
        }
        if arguments.contains("--candidate-lp08-middle-threshold-m155") {
            return .lp08MiddleThresholdM155
        }
        if arguments.contains("--candidate-lp08-middle-threshold-m115") {
            return .lp08MiddleThresholdM115
        }
        if arguments.contains("--candidate-remove-lp08") {
            return .removeLP08
        }
        if arguments.contains("--candidate-ln01-ma20-days-threshold-m18") {
            return .ln01MA20DaysThresholdM18
        }
        if arguments.contains("--candidate-ln01-ma20-days-threshold-m22") {
            return .ln01MA20DaysThresholdM22
        }
        if arguments.contains("--candidate-ln02-damn-only") {
            return .ln02DamnOnly
        }
        if arguments.contains("--candidate-ln02-wow-only") {
            return .ln02WowOnly
        }
        if arguments.contains("--candidate-lt01-want-threshold4") {
            return .lt01WantThreshold4
        }
        if arguments.contains("--candidate-lt01-want-threshold6") {
            return .lt01WantThreshold6
        }
        if arguments.contains("--candidate-lt01-fine-or-better-threshold6") {
            return .lt01FineOrBetterThreshold6
        }
        if arguments.contains("--candidate-lt01-high-or-better-threshold6") {
            return .lt01HighOrBetterThreshold6
        }
        if arguments.contains("--candidate-lt01-wow-threshold6") {
            return .lt01WowThreshold6
        }
        if arguments.contains("--candidate-sp06-remove-a-branch") {
            return .sp06RemoveABranch
        }
        if arguments.contains("--candidate-sp06-remove-b-branch") {
            return .sp06RemoveBBranch
        }
        if arguments.contains("--candidate-sp06a-upper-low-threshold06") {
            return .sp06aUpperLowThreshold06
        }
        if arguments.contains("--candidate-sp06a-upper-low-threshold10") {
            return .sp06aUpperLowThreshold10
        }
        if arguments.contains("--candidate-sp06a-upper-high-threshold-m02") {
            return .sp06aUpperHighThresholdM02
        }
        if arguments.contains("--candidate-sp06a-upper-high-threshold-p02") {
            return .sp06aUpperHighThresholdP02
        }
        if arguments.contains("--candidate-sp06a-upper-high-threshold-m04") {
            return .sp06aUpperHighThresholdM04
        }
        if arguments.contains("--candidate-sp06a-upper-high-threshold-p04") {
            return .sp06aUpperHighThresholdP04
        }
        if arguments.contains("--candidate-sp06b-lower-threshold10") {
            return .sp06bLowerThreshold10
        }
        if arguments.contains("--candidate-sp06b-lower-threshold14") {
            return .sp06bLowerThreshold14
        }
        if arguments.contains("--candidate-sp06b-lower-threshold08") {
            return .sp06bLowerThreshold08
        }
        if arguments.contains("--candidate-sp06b-lower-threshold16") {
            return .sp06bLowerThreshold16
        }
        if arguments.contains("--candidate-sn01-remove-a-branch") {
            return .sn01RemoveABranch
        }
        if arguments.contains("--candidate-sn01-remove-b-branch") {
            return .sn01RemoveBBranch
        }
        if arguments.contains("--candidate-st02b-range-threshold25") {
            return .st02bRangeThreshold25
        }
        if arguments.contains("--candidate-st02b-range-threshold35") {
            return .st02bRangeThreshold35
        }
        if arguments.contains("--candidate-remove-ap01a") {
            return .removeAP01a
        }
        if arguments.contains("--candidate-remove-ap01b") {
            return .removeAP01b
        }
        if arguments.contains("--candidate-ap01b-low-boundary") {
            return .ap01bLowBoundary
        }
        if arguments.contains("--candidate-ap02-wow-minimum2") {
            return .ap02WowMinimum2
        }
        if arguments.contains("--candidate-ap02-wow-minimum4") {
            return .ap02WowMinimum4
        }
        if arguments.contains("--candidate-ap05-diff-threshold-m175") {
            return .ap05DiffThresholdM175
        }
        if arguments.contains("--candidate-ap05-diff-threshold-m225") {
            return .ap05DiffThresholdM225
        }
        if arguments.contains("--candidate-ap06-ma20-z-threshold-m23") {
            return .ap06MA20ZThresholdM23
        }
        if arguments.contains("--candidate-ap06-ma20-z-threshold-m27") {
            return .ap06MA20ZThresholdM27
        }
        if arguments.contains("--candidate-ap06-ma20-z-threshold-m21") {
            return .ap06MA20ZThresholdM21
        }
        if arguments.contains("--candidate-ap06-ma20-z-threshold-m29") {
            return .ap06MA20ZThresholdM29
        }
        if arguments.contains("--candidate-ap06-ma60-z-threshold-m26") {
            return .ap06MA60ZThresholdM26
        }
        if arguments.contains("--candidate-ap06-ma60-z-threshold-m30") {
            return .ap06MA60ZThresholdM30
        }
        if arguments.contains("--candidate-ap07-ma20-diff-threshold-m7") {
            return .ap07MA20DiffThresholdM7
        }
        if arguments.contains("--candidate-ap07-ma20-diff-threshold-m9") {
            return .ap07MA20DiffThresholdM9
        }
        if arguments.contains("--candidate-ap07-ma20-diff-threshold-m6") {
            return .ap07MA20DiffThresholdM6
        }
        if arguments.contains("--candidate-ap07-ma20-diff-threshold-m10") {
            return .ap07MA20DiffThresholdM10
        }
        if arguments.contains("--candidate-at01-want-threshold2") {
            return .at01WantThreshold2
        }
        if arguments.contains("--candidate-at01-want-threshold4") {
            return .at01WantThreshold4
        }
        if arguments.contains("--candidate-at01-want-threshold1") {
            return .at01WantThreshold1
        }
        if arguments.contains("--candidate-at01-want-threshold5") {
            return .at01WantThreshold5
        }
        if arguments.contains("--candidate-at01-short-days150") {
            return .at01ShortDays150
        }
        if arguments.contains("--candidate-at01-short-days210") {
            return .at01ShortDays210
        }
        if arguments.contains("--candidate-at01-long-days330") {
            return .at01LongDays330
        }
        if arguments.contains("--candidate-at01-long-days390") {
            return .at01LongDays390
        }
        if arguments.contains("--candidate-at01-roi-threshold-m275") {
            return .at01ROIThresholdM275
        }
        if arguments.contains("--candidate-at01-roi-threshold-m325") {
            return .at01ROIThresholdM325
        }
        if arguments.contains("--candidate-at01-roi-threshold-m3125") {
            return .at01ROIThresholdM3125
        }
        if arguments.contains("--candidate-at01-roi-threshold-m35") {
            return .at01ROIThresholdM35
        }
        if arguments.contains("--candidate-at01-wow35-other325") {
            return .at01Wow35Other325
        }
        if arguments.contains("--candidate-at01-wow35-middle325-low30") {
            return .at01Wow35Middle325Low30
        }
        if arguments.contains("--candidate-at01-upper325-low30") {
            return .at01Upper325Low30
        }
        if arguments.contains("--candidate-ae01-cooldown-days20") {
            return .ae01CooldownDays20
        }
        if arguments.contains("--candidate-ae01-cooldown-days30") {
            return .ae01CooldownDays30
        }
        if arguments.contains("--candidate-ae01-cooldown-days60") {
            return .ae01CooldownDays60
        }
        if arguments.contains("--candidate-ae01-cooldown-days15") {
            return .ae01CooldownDays15
        }
        if arguments.contains("--candidate-ae01-cooldown-days75") {
            return .ae01CooldownDays75
        }
        if arguments.contains("--candidate-ae01-cooldown-days38") {
            return .ae01CooldownDays38
        }
        if arguments.contains("--candidate-ae03-limit1") {
            return .ae03Limit1
        }
        if arguments.contains("--candidate-ae03-limit3") {
            return .ae03Limit3
        }
        if arguments.contains("--candidate-ae04-roi-threshold-m45") {
            return .ae04ROIThresholdM45
        }
        if arguments.contains("--candidate-ae04-roi-threshold-m55") {
            return .ae04ROIThresholdM55
        }
        if arguments.contains("--candidate-remove-ae02") {
            return .removeAE02
        }
        if arguments.contains("--candidate-remove-an02") {
            return .removeAN02
        }
        if arguments.contains("--candidate-st02-remove-b-branch") {
            return .st02RemoveBBranch
        }
        if arguments.contains("--candidate-st02-remove-c-branch") {
            return .st02RemoveCBranch
        }
        if arguments.contains("--candidate-st02-remove-score-gate") {
            return .st02RemoveScoreGate
        }
        if arguments.contains("--candidate-st01a-roi20") {
            return .st01aROI20
        }
        if arguments.contains("--candidate-st01a-roi25") {
            return .st01aROI25
        }
        if arguments.contains("--candidate-st01a-high-score-m1") {
            return .st01aHighScoreM1
        }
        if arguments.contains("--candidate-st01a-high-score-1") {
            return .st01aHighScore1
        }
        if arguments.contains("--candidate-st01a-general-score-0") {
            return .st01aGeneralScore0
        }
        if arguments.contains("--candidate-st01a-general-score-2") {
            return .st01aGeneralScore2
        }
        if arguments.contains("--candidate-st01a-edge-score") {
            return .st01aEdgeScore
        }
        if arguments.contains("--candidate-st01c-score4") {
            return .st01cScore4
        }
        if arguments.contains("--candidate-st01c-score6") {
            return .st01cScore6
        }
        if arguments.contains("--candidate-st01c-low-roi10") {
            return .st01cLowROI10
        }
        if arguments.contains("--candidate-st01c-low-roi20") {
            return .st01cLowROI20
        }
        if arguments.contains("--candidate-st01c-other-roi20") {
            return .st01cOtherROI20
        }
        if arguments.contains("--candidate-st01c-other-roi225") {
            return .st01cOtherROI225
        }
        if arguments.contains("--candidate-st01c-other-roi30") {
            return .st01cOtherROI30
        }
        if arguments.contains("--candidate-st01c-weak-or-better-roi20") {
            return .st01cWeakOrBetterROI20
        }
        if arguments.contains("--candidate-st01c-grade-tiered-roi") {
            return .st01cGradeTieredROI
        }
        if arguments.contains("--candidate-st01c-wow25-weak20") {
            return .st01cWow25Weak20
        }
        if arguments.contains("--candidate-st01c-wow25-weak15") {
            return .st01cWow25Weak15
        }
        if arguments.contains("--candidate-st01c-middle225-wow20") {
            return .st01cMiddle225Wow20
        }
        if arguments.contains("--candidate-st01c-middle20-wow225") {
            return .st01cMiddle20Wow225
        }
        if arguments.contains("--candidate-st01e-days60") {
            return .st01eDays60
        }
        if arguments.contains("--candidate-st01e-days68") {
            return .st01eDays68
        }
        if arguments.contains("--candidate-st01e-days90") {
            return .st01eDays90
        }
        if arguments.contains("--candidate-an01-penalty-m1") {
            return .an01PenaltyM1
        }
        if arguments.contains("--candidate-an01-penalty-m3") {
            return .an01PenaltyM3
        }
        if arguments.contains("--candidate-an01-control") {
            return .an01Control
        }
        if arguments.contains("--candidate-an01-fine-boundary") {
            return .an01FineBoundary
        }
        if arguments.contains("--candidate-an01-fine-penalty-m1") {
            return .an01FinePenaltyM1
        }
        if arguments.contains("--candidate-an01-fine-penalty-m1-no-none") {
            return .an01FinePenaltyM1NoNone
        }
        if arguments.contains("--candidate-an01-fine-penalty-m1-low-below-m1") {
            return .an01FinePenaltyM1LowBelowM1
        }
        if arguments.contains("--candidate-an01-fine-penalty-m1-low-below-p1") {
            return .an01FinePenaltyM1LowBelowP1
        }
        if arguments.contains("--candidate-an01-fine-penalty-m3") {
            return .an01FinePenaltyM3
        }
        if arguments.contains("--candidate-an01-high-penalty-m3") {
            return .an01HighPenaltyM3
        }
        if arguments.contains("--candidate-sn0203-fine-high-group") {
            return .sn0203FineHighGroup
        }
        if arguments.contains("--candidate-sn0203-high-general-group") {
            return .sn0203HighGeneralGroup
        }
        if arguments.contains("--candidate-sn02-wow-threshold625") {
            return .sn02WowThreshold625
        }
        if arguments.contains("--candidate-sn02-wow-threshold875") {
            return .sn02WowThreshold875
        }
        if arguments.contains("--candidate-sn02-wow-cap-with-sn05") {
            return .sn02WowCapWithSN05
        }
        if arguments.contains("--candidate-sn05-high-or-better") {
            return .sn05HighOrBetter
        }
        if arguments.contains("--candidate-sn05-weak-or-better") {
            return .sn05WeakOrBetter
        }
        if arguments.contains("--candidate-market-vote-never") { return .marketVoteNever }
        if arguments.contains("--candidate-market-vote-pulse-h") { return .marketVotePulseH }
        if arguments.contains("--candidate-market-vote-pulse-l") { return .marketVotePulseL }
        if arguments.contains("--candidate-market-vote-pulse-s") { return .marketVotePulseS }
        if arguments.contains("--candidate-market-vote-pulse-a") { return .marketVotePulseA }
        return .baseline
    }()
    static let isSummaryOnly = ProcessInfo.processInfo.arguments.contains("--summary-only")
    static let retainsPeriodStores =
        ProcessInfo.processInfo.arguments.contains("--retain-period-stores")
    static let isHN09Diagnostic =
        ProcessInfo.processInfo.arguments.contains("--diagnose-hn09")
    static let isLC02Diagnostic =
        ProcessInfo.processInfo.arguments.contains("--diagnose-lc02")
    static let isAN01Diagnostic =
        candidate == .an01PenaltyM1 || candidate == .an01PenaltyM3
            || candidate == .an01Control || candidate == .an01FineBoundary
            || candidate == .an01FinePenaltyM1
            || candidate == .an01FinePenaltyM1NoNone
            || candidate == .an01FinePenaltyM1LowBelowM1
            || candidate == .an01FinePenaltyM1LowBelowP1
            || candidate == .an01FinePenaltyM3 || candidate == .an01HighPenaltyM3
    static let sample = InternalBacktestDataset.Sample.from()
    static let isFullWindowStress =
        ProcessInfo.processInfo.arguments.contains("--full-window-stress")
    static let isNineYearABProfile =
        ProcessInfo.processInfo.arguments.contains("--nine-year-ab-baseline")
    static let ruleCommit: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--rule-commit"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }()
    static let runID: String = {
        if let counterfactualRunID = InternalBacktestCounterfactual.runID {
            return counterfactualRunID
        }
        if isNineYearABProfile && candidate == .ae01CooldownDays20 {
            return "ae01-d20-s1-\(sample.rawValue.lowercased())-cooldown-days20-t2s39-9y-fixed3y-600w-20260902"
        }
        if isNineYearABProfile && [
            Candidate.marketVoteNever, .marketVotePulseH, .marketVotePulseL,
            .marketVotePulseS, .marketVotePulseA
        ].contains(candidate) {
            return "\(candidate.rawValue)-\(sample.rawValue.lowercased())-v20-t2s39-fixed3y-600w-20260902"
        }
        if isNineYearABProfile && sample == .c && candidate == .lc03RemoveMiddle {
            return "lc03-r1-c-remove-middle-t2s21-9y-fixed3y-600w-20260821"
        }
        if isNineYearABProfile && candidate == .at01ShortDays150 {
            return "a25a-a-at01-short-days150-t2s21-9y-fixed3y-600w-20260821"
        }
        if isNineYearABProfile && candidate == .at01ShortDays210 {
            return "a25b-a-at01-short-days210-t2s21-9y-fixed3y-600w-20260821"
        }
        if isNineYearABProfile && candidate == .at01LongDays330 {
            return "a25c-a-at01-long-days330-t2s21-9y-fixed3y-600w-20260821"
        }
        if isNineYearABProfile && candidate == .at01LongDays390 {
            return "a25d-a-at01-long-days390-t2s21-9y-fixed3y-600w-20260821"
        }
        if isNineYearABProfile && candidate == .gwS01 {
            return "gw-s01-a-worsening-warning-first-day-sell-p1-t2s22-9y-fixed3y-600w-20260821"
        }
        if isNineYearABProfile && candidate == .gwS01b {
            return "gw-s01b-a-worsening-warning-first-day-st01-p1-t2s22-9y-fixed3y-600w-20260821"
        }
        if isNineYearABProfile && candidate == .gwA01 {
            return "gw-a01-a-improving-warning-first-day-add-p1-t2s22-9y-fixed3y-600w-20260822"
        }
        if isNineYearABProfile && candidate == .gwA02 {
            return "gw-a02-a-worsening-warning-first-day-add-m1-t2s22-9y-fixed3y-600w-20260822"
        }
        if isNineYearABProfile && candidate == .gwA02b {
            return "gw-a02b-a-worsening-warning-first-day-add-m2-t2s22-9y-fixed3y-600w-20260822"
        }
        if isNineYearABProfile && candidate == .gwS02 {
            return "gw-s02-a-improving-warning-first-day-sell-m1-t2s22-9y-fixed3y-600w-20260822"
        }
        if isNineYearABProfile && candidate == .baseline {
            let window = isFullWindowStress ? "9y-fullstress" : "9y-fixed3y"
            return "baseline-\(sample.rawValue.lowercased())-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-\(window)-600w-20260901"
        }
        if isHN09Diagnostic {
            return sample == .b
                ? "h19-d-b-hn09-threshold-diagnostic-fixed3y-20260803"
                : "h19-d-a-hn09-threshold-diagnostic-fixed3y-20260803"
        }
        if isLC02Diagnostic {
            return sample == .b
                ? "l15-d-b-lc02-decision-diagnostic-fixed3y-20260809"
                : "l15-d-a-lc02-decision-diagnostic-fixed3y-20260809"
        }
        switch candidate {
        case .gwS01:
            return "gw-s01-a-worsening-warning-first-day-sell-p1-fixed3y-600w-20260821"
        case .gwS01b:
            return "gw-s01b-a-worsening-warning-first-day-st01-p1-fixed3y-600w-20260821"
        case .gwA01:
            return "gw-a01-a-improving-warning-first-day-add-p1-fixed3y-600w-20260822"
        case .gwA02:
            return "gw-a02-a-worsening-warning-first-day-add-m1-fixed3y-600w-20260822"
        case .gwA02b:
            return "gw-a02b-a-worsening-warning-first-day-add-m2-fixed3y-600w-20260822"
        case .gwS02:
            return "gw-s02-a-improving-warning-first-day-sell-m1-fixed3y-600w-20260822"
        case .removeST01g:
            return "s6c-b-remove-st01g-fixed3y-600w-20260802"
        case .investCooldown45:
            return "s7c-b-invest-cooldown45-fixed3y-600w-20260802"
        case .noInvestCooldown:
            return "s7d-b-no-invest-cooldown-fixed3y-600w-20260802"
        case .removeGradeActivationGate:
            return sample == .b
                ? "gt01-b-remove-activation-gate-fixed3y-600w-20260802"
                : "gt01-a-remove-activation-gate-fixed3y-600w-20260802"
        case .gradeActivationRounds1:
            return sample == .b
                ? "gt02a-b-grade-activation-rounds1-fixed3y-600w-20260813"
                : "gt02a-a-grade-activation-rounds1-fixed3y-600w-20260813"
        case .gradeActivationRounds3:
            return sample == .b
                ? "gt02b-b-grade-activation-rounds3-fixed3y-600w-20260813"
                : "gt02b-a-grade-activation-rounds3-fixed3y-600w-20260813"
        case .gradeActivationDays300:
            return sample == .b
                ? "gt03a-b-grade-activation-days300-fixed3y-600w-20260813"
                : "gt03a-a-grade-activation-days300-fixed3y-600w-20260813"
        case .gradeActivationDays420:
            return sample == .b
                ? "gt03b-b-grade-activation-days420-fixed3y-600w-20260813"
                : "gt03b-a-grade-activation-days420-fixed3y-600w-20260813"
        case .gradeActivationExtremeNegative69:
            return sample == .b
                ? "gt04a-b-grade-activation-extreme-negative-m69-fixed3y-600w-20260813"
                : "gt04a-a-grade-activation-extreme-negative-m69-fixed3y-600w-20260813"
        case .ht01WantThresholdM1:
            return sample == .b
                ? "h45a-b-ht01-want-threshold-m1-fixed3y-600w-20260813"
                : "h45a-a-ht01-want-threshold-m1-fixed3y-600w-20260813"
        case .ht01WantThreshold1:
            return sample == .b
                ? "h45b-b-ht01-want-threshold-1-fixed3y-600w-20260813"
                : "h45b-a-ht01-want-threshold-1-fixed3y-600w-20260813"
        case .ht01WeakOrBelowThreshold1:
            return sample == .b
                ? "h46a-b-ht01-weak-or-below-threshold-1-fixed3y-600w-20260813"
                : "h46a-a-ht01-weak-or-below-threshold-1-fixed3y-600w-20260813"
        case .ht01LowOnlyThreshold1:
            if isFullWindowStress {
                return sample == .b
                    ? "h46b-b-ht01-low-only-threshold-1-fullstress-600w-20260814"
                    : "h46b-a-ht01-low-only-threshold-1-fullstress-600w-20260814"
            }
            return sample == .b
                ? "h46b-b-ht01-low-only-threshold-1-fixed3y-600w-20260813"
                : "h46b-a-ht01-low-only-threshold-1-fixed3y-600w-20260813"
        case .removeGradeWow:
            return sample == .b
                ? "gp01-b-remove-wow-fixed3y-600w-20260802"
                : "gp01-a-remove-wow-fixed3y-600w-20260802"
        case .removeGradeHigh:
            return sample == .b
                ? "gp02-b-remove-high-fixed3y-600w-20260802"
                : "gp02-a-remove-high-fixed3y-600w-20260802"
        case .removeGradeFine:
            return sample == .b
                ? "gp03-b-remove-fine-fixed3y-600w-20260802"
                : "gp03-a-remove-fine-fixed3y-600w-20260802"
        case .removeGradeDamn:
            return sample == .b
                ? "gn01-b-remove-damn-fixed3y-600w-20260802"
                : "gn01-a-remove-damn-fixed3y-600w-20260802"
        case .removeGradeLow:
            return sample == .b
                ? "gn02-b-remove-low-fixed3y-600w-20260802"
                : "gn02-a-remove-low-fixed3y-600w-20260802"
        case .removeGradeWeak:
            return sample == .b
                ? "gn03-b-remove-weak-fixed3y-600w-20260802"
                : "gn03-a-remove-weak-fixed3y-600w-20260802"
        case .neutralGradeMapping:
            return sample == .b
                ? "gm01-b-neutral-mapping-fixed3y-600w-20260802"
                : "gm01-a-neutral-mapping-fixed3y-600w-20260802"
        case .scoreBasedGrade:
            return sample == .b
                ? "gsc02-b-score-grade-fixed3y-600w-20260802"
                : "gsc02-a-score-grade-fixed3y-600w-20260802"
        case .scoreBasedGradeSellCompatibility:
            return sample == .b
                ? "gsc03-s-b-score-grade-s-compat-fixed3y-600w-20260802"
                : "gsc03-s-a-score-grade-s-compat-fixed3y-600w-20260802"
        case .scoreBasedGradeAllCompatibility:
            return sample == .b
                ? "gsc04-all-b-score-grade-all-compat-fixed3y-600w-20260802"
                : "gsc04-all-a-score-grade-all-compat-fixed3y-600w-20260802"
        case .scoreBasedGradeUpperCompatibility:
            return sample == .b
                ? "gsc05-all-b-score-grade-upper-shift-fixed3y-600w-20260802"
                : "gsc05-all-a-score-grade-upper-shift-fixed3y-600w-20260802"
        case .scoreBasedGradeCalibratedBands:
            return sample == .b
                ? "gsc06-b-score-grade-calibrated-bands-fixed3y-600w-20260802"
                : "gsc06-a-score-grade-calibrated-bands-fixed3y-600w-20260802"
        case .scoreBasedGradeCalibratedAllBands:
            return sample == .b
                ? "gsc07-b-score-grade-calibrated-all-bands-fixed3y-600w-20260802"
                : "gsc07-a-score-grade-calibrated-all-bands-fixed3y-600w-20260802"
        case .scoreBasedGradeNeutralBand:
            return sample == .b
                ? "gsc08-b-score-grade-neutral-band-fixed3y-600w-20260802"
                : "gsc08-a-score-grade-neutral-band-fixed3y-600w-20260802"
        case .scoreBasedGradeWeakUsesNeutralMapping:
            return sample == .b
                ? "gsc09-b-score-grade-weak-neutral-mapping-fixed3y-600w-20260802"
                : "gsc09-a-score-grade-weak-neutral-mapping-fixed3y-600w-20260802"
        case .scoreGradeFine18:
            return sample == .b
                ? "gsc10-b-score-grade-fine18-fixed3y-600w-20260803"
                : "gsc10-a-score-grade-fine18-fixed3y-600w-20260803"
        case .removeHN06:
            return sample == .b
                ? "h16-b-remove-hn06-fixed3y-600w-20260803"
                : "h16-a-remove-hn06-fixed3y-600w-20260803"
        case .removeHN02b:
            return sample == .b
                ? "h17-b-remove-hn02b-fixed3y-600w-20260803"
                : "h17-a-remove-hn02b-fixed3y-600w-20260803"
        case .removeHN01a:
            return sample == .b
                ? "h18-b-remove-hn01a-fixed3y-600w-20260803"
                : "h18-a-remove-hn01a-fixed3y-600w-20260803"
        case .hn09Strict:
            return sample == .b
                ? "h19a-b-hn09-strict-m01-fixed3y-600w-20260803"
                : "h19a-a-hn09-strict-m01-fixed3y-600w-20260803"
        case .hn09Loose:
            return sample == .b
                ? "h19b-b-hn09-loose-p01-fixed3y-600w-20260803"
                : "h19b-a-hn09-loose-p01-fixed3y-600w-20260803"
        case .hn09LowGradeHighStrict:
            return sample == .b
                ? "h19c-b-hn09-low-grade-high03-fixed3y-600w-20260803"
                : "h19c-a-hn09-low-grade-high03-fixed3y-600w-20260803"
        case .hn09LowGradeHighLoose:
            return sample == .b
                ? "h19d-b-hn09-low-grade-high05-fixed3y-600w-20260803"
                : "h19d-a-hn09-low-grade-high05-fixed3y-600w-20260803"
        case .hn09LowGradeHigh06:
            return sample == .b
                ? "h19e-b-hn09-low-grade-high06-fixed3y-600w-20260803"
                : "h19e-a-hn09-low-grade-high06-fixed3y-600w-20260803"
        case .hn09LowGradeHigh08:
            return sample == .b
                ? "h19f-b-hn09-low-grade-high08-fixed3y-600w-20260803"
                : "h19f-a-hn09-low-grade-high08-fixed3y-600w-20260803"
        case .hn09LowGradeHigh10:
            return sample == .b
                ? "h19g-b-hn09-low-grade-high10-fixed3y-600w-20260803"
                : "h19g-a-hn09-low-grade-high10-fixed3y-600w-20260803"
        case .hn09LowGradeHigh12:
            return sample == .b
                ? "h19h-b-hn09-low-grade-high12-fixed3y-600w-20260803"
                : "h19h-a-hn09-low-grade-high12-fixed3y-600w-20260803"
        case .hn09High081313:
            return sample == .b
                ? "h19i-b-hn09-high-081313-fixed3y-600w-20260803"
                : "h19i-a-hn09-high-081313-fixed3y-600w-20260803"
        case .hn09High081315:
            return sample == .b
                ? "h19j-b-hn09-high-081315-fixed3y-600w-20260803"
                : "h19j-a-hn09-high-081315-fixed3y-600w-20260803"
        case .hn09High081520:
            return sample == .b
                ? "h19k-b-hn09-high-081520-fixed3y-600w-20260803"
                : "h19k-a-hn09-high-081520-fixed3y-600w-20260803"
        case .hn09High081515:
            return sample == .b
                ? "h19l-b-hn09-high-081515-fixed3y-600w-20260803"
                : "h19l-a-hn09-high-081515-fixed3y-600w-20260803"
        case .hn09Low081215:
            return sample == .b
                ? "h20a-b-hn09-low-081215-fixed3y-600w-20260803"
                : "h20a-a-hn09-low-081215-fixed3y-600w-20260803"
        case .hn09HighOnly:
            return sample == .b
                ? "h20b-b-hn09-high-only-fixed3y-600w-20260803"
                : "h20b-a-hn09-high-only-fixed3y-600w-20260803"
        case .hn09Low051218:
            return sample == .b
                ? "h20c-b-hn09-low-051218-fixed3y-600w-20260803"
                : "h20c-a-hn09-low-051218-fixed3y-600w-20260803"
        case .hn03ThresholdM07:
            return sample == .b
                ? "h21a-b-hn03-m07-fixed3y-600w-20260803"
                : "h21a-a-hn03-m07-fixed3y-600w-20260803"
        case .hn03ThresholdM03:
            return sample == .b
                ? "h21b-b-hn03-m03-fixed3y-600w-20260803"
                : "h21b-a-hn03-m03-fixed3y-600w-20260803"
        case .hp01LowerLoose:
            return sample == .b
                ? "h22a-b-hp01-lower-loose-fixed3y-600w-20260803"
                : "h22a-a-hp01-lower-loose-fixed3y-600w-20260803"
        case .hp01LowerStrict:
            return sample == .b
                ? "h22b-b-hp01-lower-strict-fixed3y-600w-20260803"
                : "h22b-a-hp01-lower-strict-fixed3y-600w-20260803"
        case .hp01LowUpper19:
            return sample == .b
                ? "h23a-b-hp01-low-upper19-fixed3y-600w-20260803"
                : "h23a-a-hp01-low-upper19-fixed3y-600w-20260803"
        case .hp01LowUpper21:
            return sample == .b
                ? "h23b-b-hp01-low-upper21-fixed3y-600w-20260803"
                : "h23b-a-hp01-low-upper21-fixed3y-600w-20260803"
        case .hp01LowUpper15:
            return sample == .b
                ? "h23c-b-hp01-low-upper15-fixed3y-600w-20260803"
                : "h23c-a-hp01-low-upper15-fixed3y-600w-20260803"
        case .hp01LowUpper25:
            return sample == .b
                ? "h23d-b-hp01-low-upper25-fixed3y-600w-20260803"
                : "h23d-a-hp01-low-upper25-fixed3y-600w-20260803"
        case .hp01OtherUpper24:
            return sample == .b
                ? "h24a-b-hp01-other-upper24-fixed3y-600w-20260803"
                : "h24a-a-hp01-other-upper24-fixed3y-600w-20260803"
        case .hp01OtherUpper26:
            return sample == .b
                ? "h24b-b-hp01-other-upper26-fixed3y-600w-20260803"
                : "h24b-a-hp01-other-upper26-fixed3y-600w-20260803"
        case .hp01OtherUpper20:
            return sample == .b
                ? "h24c-b-hp01-other-upper20-fixed3y-600w-20260803"
                : "h24c-a-hp01-other-upper20-fixed3y-600w-20260803"
        case .hp01OtherUpper30:
            return sample == .b
                ? "h24d-b-hp01-other-upper30-fixed3y-600w-20260803"
                : "h24d-a-hp01-other-upper30-fixed3y-600w-20260803"
        case .hp04WeakThreshold19:
            return sample == .b
                ? "h25a-b-hp04-weak-threshold19-fixed3y-600w-20260803"
                : "h25a-a-hp04-weak-threshold19-fixed3y-600w-20260803"
        case .hp04WeakThreshold21:
            return sample == .b
                ? "h25b-b-hp04-weak-threshold21-fixed3y-600w-20260803"
                : "h25b-a-hp04-weak-threshold21-fixed3y-600w-20260803"
        case .hp04WeakThreshold15:
            return sample == .b
                ? "h25c-b-hp04-weak-threshold15-fixed3y-600w-20260803"
                : "h25c-a-hp04-weak-threshold15-fixed3y-600w-20260803"
        case .hp04WeakThreshold25:
            return sample == .b
                ? "h25d-b-hp04-weak-threshold25-fixed3y-600w-20260803"
                : "h25d-a-hp04-weak-threshold25-fixed3y-600w-20260803"
        case .hp03LowBoundaryLow:
            return sample == .b
                ? "h26a-b-hp03-low-boundary-low-fixed3y-600w-20260804"
                : "h26a-a-hp03-low-boundary-low-fixed3y-600w-20260804"
        case .hp03LowBoundaryFine:
            return sample == .b
                ? "h26b-b-hp03-low-boundary-fine-fixed3y-600w-20260804"
                : "h26b-a-hp03-low-boundary-fine-fixed3y-600w-20260804"
        case .hp03OtherThresholdM025:
            return sample == .b
                ? "h43a-b-hp03-other-threshold-m025-fixed3y-600w-20260810"
                : "h43a-a-hp03-other-threshold-m025-fixed3y-600w-20260810"
        case .hp03OtherThresholdP025:
            return sample == .b
                ? "h43b-b-hp03-other-threshold-p025-fixed3y-600w-20260810"
                : "h43b-a-hp03-other-threshold-p025-fixed3y-600w-20260810"
        case .hp03OtherThresholdM05:
            return sample == .b
                ? "h43c-b-hp03-other-threshold-m05-fixed3y-600w-20260810"
                : "h43c-a-hp03-other-threshold-m05-fixed3y-600w-20260810"
        case .hp03OtherThresholdP05:
            return sample == .b
                ? "h43d-b-hp03-other-threshold-p05-fixed3y-600w-20260810"
                : "h43d-a-hp03-other-threshold-p05-fixed3y-600w-20260810"
        case .hp03RatedThresholdM025:
            return sample == .b
                ? "h43e-b-hp03-rated-threshold-m025-fixed3y-600w-20260810"
                : "h43e-a-hp03-rated-threshold-m025-fixed3y-600w-20260810"
        case .hp03RatedThresholdP025:
            return sample == .b
                ? "h43f-b-hp03-rated-threshold-p025-fixed3y-600w-20260810"
                : "h43f-a-hp03-rated-threshold-p025-fixed3y-600w-20260810"
        case .hp03RatedThresholdM05:
            return sample == .b
                ? "h43g-b-hp03-rated-threshold-m05-fixed3y-600w-20260810"
                : "h43g-a-hp03-rated-threshold-m05-fixed3y-600w-20260810"
        case .hp03RatedThresholdP05:
            return sample == .b
                ? "h43h-b-hp03-rated-threshold-p05-fixed3y-600w-20260810"
                : "h43h-a-hp03-rated-threshold-p05-fixed3y-600w-20260810"
        case .hp03LowerThresholdM075:
            return sample == .b
                ? "h44a-b-hp03-lower-threshold-m075-fixed3y-600w-20260810"
                : "h44a-a-hp03-lower-threshold-m075-fixed3y-600w-20260810"
        case .hp03LowerThresholdM025:
            return sample == .b
                ? "h44b-b-hp03-lower-threshold-m025-fixed3y-600w-20260810"
                : "h44b-a-hp03-lower-threshold-m025-fixed3y-600w-20260810"
        case .hp03LowerThresholdM10:
            return sample == .b
                ? "h44c-b-hp03-lower-threshold-m10-fixed3y-600w-20260810"
                : "h44c-a-hp03-lower-threshold-m10-fixed3y-600w-20260810"
        case .hp03LowerThreshold00:
            return sample == .b
                ? "h44d-b-hp03-lower-threshold-00-fixed3y-600w-20260810"
                : "h44d-a-hp03-lower-threshold-00-fixed3y-600w-20260810"
        case .hn01aGradeWeakOrBelow:
            return sample == .b
                ? "h27a-b-hn01a-grade-weak-or-below-fixed3y-600w-20260804"
                : "h27a-a-hn01a-grade-weak-or-below-fixed3y-600w-20260804"
        case .hn01aGradeBelowWow:
            return sample == .b
                ? "h27b-b-hn01a-grade-below-wow-fixed3y-600w-20260804"
                : "h27b-a-hn01a-grade-below-wow-fixed3y-600w-20260804"
        case .hn02bHighBoundaryLow:
            return sample == .b
                ? "h28a-b-hn02b-high-boundary-low-fixed3y-600w-20260804"
                : "h28a-a-hn02b-high-boundary-low-fixed3y-600w-20260804"
        case .hn02bHighBoundaryFine:
            return sample == .b
                ? "h28b-b-hn02b-high-boundary-fine-fixed3y-600w-20260804"
                : "h28b-a-hn02b-high-boundary-fine-fixed3y-600w-20260804"
        case .hn05GradeWeakOrBetter:
            return sample == .b
                ? "h29a-b-hn05-grade-weak-or-better-fixed3y-600w-20260804"
                : "h29a-a-hn05-grade-weak-or-better-fixed3y-600w-20260804"
        case .hn05GradeAll:
            return sample == .b
                ? "h29b-b-hn05-grade-all-fixed3y-600w-20260804"
                : "h29b-a-hn05-grade-all-fixed3y-600w-20260804"
        case .hn08Threshold15:
            return sample == .b
                ? "h30a-b-hn08-threshold15-fixed3y-600w-20260804"
                : "h30a-a-hn08-threshold15-fixed3y-600w-20260804"
        case .hn08Threshold17:
            return sample == .b
                ? "h30b-b-hn08-threshold17-fixed3y-600w-20260804"
                : "h30b-a-hn08-threshold17-fixed3y-600w-20260804"
        case .hn08Threshold12:
            return sample == .b
                ? "h30c-b-hn08-threshold12-fixed3y-600w-20260804"
                : "h30c-a-hn08-threshold12-fixed3y-600w-20260804"
        case .hn08Threshold20:
            return sample == .b
                ? "h30d-b-hn08-threshold20-fixed3y-600w-20260804"
                : "h30d-a-hn08-threshold20-fixed3y-600w-20260804"
        case .hn06GradeBoundaryLow:
            return sample == .b
                ? "h31a-b-hn06-grade-boundary-low-fixed3y-600w-20260804"
                : "h31a-a-hn06-grade-boundary-low-fixed3y-600w-20260804"
        case .hn06GradeBoundaryFine:
            return sample == .b
                ? "h31b-b-hn06-grade-boundary-fine-fixed3y-600w-20260804"
                : "h31b-a-hn06-grade-boundary-fine-fixed3y-600w-20260804"
        case .hn06MA20Threshold55:
            return sample == .b
                ? "h32a-b-hn06-ma20-threshold55-fixed3y-600w-20260804"
                : "h32a-a-hn06-ma20-threshold55-fixed3y-600w-20260804"
        case .hn06MA20Threshold65:
            return sample == .b
                ? "h32b-b-hn06-ma20-threshold65-fixed3y-600w-20260804"
                : "h32b-a-hn06-ma20-threshold65-fixed3y-600w-20260804"
        case .hn06MA60Threshold65:
            return sample == .b
                ? "h33a-b-hn06-ma60-threshold65-fixed3y-600w-20260804"
                : "h33a-a-hn06-ma60-threshold65-fixed3y-600w-20260804"
        case .hn06MA60Threshold75:
            return sample == .b
                ? "h33b-b-hn06-ma60-threshold75-fixed3y-600w-20260804"
                : "h33b-a-hn06-ma60-threshold75-fixed3y-600w-20260804"
        case .hn07MA20Threshold55:
            return sample == .b
                ? "h34a-b-hn07-ma20-threshold55-fixed3y-600w-20260804"
                : "h34a-a-hn07-ma20-threshold55-fixed3y-600w-20260804"
        case .hn07MA20Threshold65:
            return sample == .b
                ? "h34b-b-hn07-ma20-threshold65-fixed3y-600w-20260804"
                : "h34b-a-hn07-ma20-threshold65-fixed3y-600w-20260804"
        case .hc01GradeBoundaryLow:
            return sample == .b
                ? "h35a-b-hc01-grade-boundary-low-fixed3y-600w-20260804"
                : "h35a-a-hc01-grade-boundary-low-fixed3y-600w-20260804"
        case .hc01GradeBoundaryFine:
            return sample == .b
                ? "h35b-b-hc01-grade-boundary-fine-fixed3y-600w-20260804"
                : "h35b-a-hc01-grade-boundary-fine-fixed3y-600w-20260804"
        case .hc02GradeBoundaryLow:
            return sample == .b
                ? "h36a-b-hc02-grade-boundary-low-fixed3y-600w-20260804"
                : "h36a-a-hc02-grade-boundary-low-fixed3y-600w-20260804"
        case .hc02GradeBoundaryFine:
            return sample == .b
                ? "h36b-b-hc02-grade-boundary-fine-fixed3y-600w-20260804"
                : "h36b-a-hc02-grade-boundary-fine-fixed3y-600w-20260804"
        case .hc02EarlyStart0216:
            return sample == .b
                ? "h37a-b-hc02-early-start-0216-fixed3y-600w-20260804"
                : "h37a-a-hc02-early-start-0216-fixed3y-600w-20260804"
        case .hc02EarlyStart0226:
            return sample == .b
                ? "h37b-b-hc02-early-start-0226-fixed3y-600w-20260804"
                : "h37b-a-hc02-early-start-0226-fixed3y-600w-20260804"
        case .hc03RemoveOverlap:
            return sample == .b
                ? "h38a-b-hc03-remove-overlap-fixed3y-600w-20260808"
                : "h38a-a-hc03-remove-overlap-fixed3y-600w-20260808"
        case .hc03RemoveLate:
            return sample == .b
                ? "h38b-b-hc03-remove-late-fixed3y-600w-20260808"
                : "h38b-a-hc03-remove-late-fixed3y-600w-20260808"
        case .hc04RemoveOverlap:
            return sample == .b
                ? "h39a-b-hc04-remove-overlap-fixed3y-600w-20260808"
                : "h39a-a-hc04-remove-overlap-fixed3y-600w-20260808"
        case .hc04RemoveLate:
            return sample == .b
                ? "h39b-b-hc04-remove-late-fixed3y-600w-20260808"
                : "h39b-a-hc04-remove-late-fixed3y-600w-20260808"
        case .hn01bThreshold17:
            return sample == .b
                ? "h40a-b-hn01b-threshold17-fixed3y-600w-20260808"
                : "h40a-a-hn01b-threshold17-fixed3y-600w-20260808"
        case .hn01bThreshold19:
            return sample == .b
                ? "h40b-b-hn01b-threshold19-fixed3y-600w-20260808"
                : "h40b-a-hn01b-threshold19-fixed3y-600w-20260808"
        case .hn02aThresholdM09:
            return sample == .b
                ? "h41a-b-hn02a-threshold-m09-fixed3y-600w-20260808"
                : "h41a-a-hn02a-threshold-m09-fixed3y-600w-20260808"
        case .hn02aThresholdM07:
            return sample == .b
                ? "h41b-b-hn02a-threshold-m07-fixed3y-600w-20260808"
                : "h41b-a-hn02a-threshold-m07-fixed3y-600w-20260808"
        case .hn06RemoveMA20Branch:
            return sample == .b
                ? "h42a-b-hn06-remove-ma20-branch-fixed3y-600w-20260808"
                : "h42a-a-hn06-remove-ma20-branch-fixed3y-600w-20260808"
        case .hn06RemoveMA60Branch:
            return sample == .b
                ? "h42b-b-hn06-remove-ma60-branch-fixed3y-600w-20260808"
                : "h42b-a-hn06-remove-ma60-branch-fixed3y-600w-20260808"
        case .lc03RemoveC01Overlap:
            return sample == .b
                ? "l10a-b-lc03-remove-c01-overlap-fixed3y-600w-20260808"
                : "l10a-a-lc03-remove-c01-overlap-fixed3y-600w-20260808"
        case .lc03RemoveC02Overlap:
            return sample == .b
                ? "l10b-b-lc03-remove-c02-overlap-fixed3y-600w-20260808"
                : "l10b-a-lc03-remove-c02-overlap-fixed3y-600w-20260808"
        case .lc03RemoveC01OverlapFineOrBetter:
            return sample == .b
                ? "l11a-b-lc03-remove-c01-overlap-fine-or-better-fixed3y-600w-20260808"
                : "l11a-a-lc03-remove-c01-overlap-fine-or-better-fixed3y-600w-20260808"
        case .lc03RemoveC01OverlapNoneOrBelow:
            return sample == .b
                ? "l11b-b-lc03-remove-c01-overlap-none-or-below-fixed3y-600w-20260808"
                : "l11b-a-lc03-remove-c01-overlap-none-or-below-fixed3y-600w-20260808"
        case .lc03RemoveC01OverlapFineOnly:
            return sample == .b
                ? "l12a-b-lc03-remove-c01-overlap-fine-only-fixed3y-600w-20260808"
                : "l12a-a-lc03-remove-c01-overlap-fine-only-fixed3y-600w-20260808"
        case .lc03RemoveC01OverlapHighOrBetter:
            return sample == .b
                ? "l12b-b-lc03-remove-c01-overlap-high-or-better-fixed3y-600w-20260808"
                : "l12b-a-lc03-remove-c01-overlap-high-or-better-fixed3y-600w-20260808"
        case .lc03RemoveMiddle:
            return sample == .b
                ? "l13-b-lc03-remove-middle-fixed3y-600w-20260808"
                : "l13-a-lc03-remove-middle-fixed3y-600w-20260808"
        case .lc01Remove:
            return sample == .b
                ? "l14-b-lc01-remove-fixed3y-600w-20260809"
                : "l14-a-lc01-remove-fixed3y-600w-20260809"
        case .lc02Remove:
            return sample == .b
                ? "l15-b-lc02-remove-fixed3y-600w-20260809"
                : "l15-a-lc02-remove-fixed3y-600w-20260809"
        case .lp07MA60ThresholdM06:
            return sample == .b
                ? "l16a-b-lp07-ma60-threshold-m06-fixed3y-600w-20260809"
                : "l16a-a-lp07-ma60-threshold-m06-fixed3y-600w-20260809"
        case .lp07MA60ThresholdM04:
            return sample == .b
                ? "l16b-b-lp07-ma60-threshold-m04-fixed3y-600w-20260809"
                : "l16b-a-lp07-ma60-threshold-m04-fixed3y-600w-20260809"
        case .lp07MA60ThresholdM10:
            return sample == .b
                ? "l16c-b-lp07-ma60-threshold-m10-fixed3y-600w-20260809"
                : "l16c-a-lp07-ma60-threshold-m10-fixed3y-600w-20260809"
        case .lp07MA60Threshold00:
            return sample == .b
                ? "l16d-b-lp07-ma60-threshold-00-fixed3y-600w-20260809"
                : "l16d-a-lp07-ma60-threshold-00-fixed3y-600w-20260809"
        case .lp09MA60ThresholdM25:
            return sample == .b
                ? "l17a-b-lp09-ma60-threshold-m25-fixed3y-600w-20260809"
                : "l17a-a-lp09-ma60-threshold-m25-fixed3y-600w-20260809"
        case .lp09MA60ThresholdM35:
            return sample == .b
                ? "l17b-b-lp09-ma60-threshold-m35-fixed3y-600w-20260809"
                : "l17b-a-lp09-ma60-threshold-m35-fixed3y-600w-20260809"
        case .lp09MA20ThresholdM25:
            return sample == .b
                ? "l18a-b-lp09-ma20-threshold-m25-fixed3y-600w-20260809"
                : "l18a-a-lp09-ma20-threshold-m25-fixed3y-600w-20260809"
        case .lp09MA20ThresholdM35:
            return sample == .b
                ? "l18b-b-lp09-ma20-threshold-m35-fixed3y-600w-20260809"
                : "l18b-a-lp09-ma20-threshold-m35-fixed3y-600w-20260809"
        case .lp03KZ125ThresholdM10:
            return sample == .b
                ? "l19a-b-lp03-k-z125-threshold-m10-fixed3y-600w-20260814"
                : "l19a-a-lp03-k-z125-threshold-m10-fixed3y-600w-20260814"
        case .lp03KZ125ThresholdM08:
            return sample == .b
                ? "l19b-b-lp03-k-z125-threshold-m08-fixed3y-600w-20260814"
                : "l19b-a-lp03-k-z125-threshold-m08-fixed3y-600w-20260814"
        case .lp03KZ250ThresholdM10:
            return sample == .b
                ? "l20a-b-lp03-k-z250-threshold-m10-fixed3y-600w-20260814"
                : "l20a-a-lp03-k-z250-threshold-m10-fixed3y-600w-20260814"
        case .lp03KZ250ThresholdM08:
            return sample == .b
                ? "l20b-b-lp03-k-z250-threshold-m08-fixed3y-600w-20260814"
                : "l20b-a-lp03-k-z250-threshold-m08-fixed3y-600w-20260814"
        case .lp04DZ125ThresholdM10:
            return sample == .b
                ? "l21a-b-lp04-d-z125-threshold-m10-fixed3y-600w-20260814"
                : "l21a-a-lp04-d-z125-threshold-m10-fixed3y-600w-20260814"
        case .lp04DZ125ThresholdM08:
            return sample == .b
                ? "l21b-b-lp04-d-z125-threshold-m08-fixed3y-600w-20260814"
                : "l21b-a-lp04-d-z125-threshold-m08-fixed3y-600w-20260814"
        case .lp04DZ250ThresholdM10:
            return sample == .b
                ? "l22a-b-lp04-d-z250-threshold-m10-fixed3y-600w-20260814"
                : "l22a-a-lp04-d-z250-threshold-m10-fixed3y-600w-20260814"
        case .lp04DZ250ThresholdM08:
            return sample == .b
                ? "l22b-b-lp04-d-z250-threshold-m08-fixed3y-600w-20260814"
                : "l22b-a-lp04-d-z250-threshold-m08-fixed3y-600w-20260814"
        case .lp04DZ250ThresholdM11:
            return sample == .b
                ? "l22c-b-lp04-d-z250-threshold-m11-fixed3y-600w-20260814"
                : "l22c-a-lp04-d-z250-threshold-m11-fixed3y-600w-20260814"
        case .lp04DZ250ThresholdM07:
            return sample == .b
                ? "l22d-b-lp04-d-z250-threshold-m07-fixed3y-600w-20260814"
                : "l22d-a-lp04-d-z250-threshold-m07-fixed3y-600w-20260814"
        case .lp05OscZ125ThresholdM10:
            return sample == .b
                ? "l23a-b-lp05-osc-z125-threshold-m10-fixed3y-600w-20260814"
                : "l23a-a-lp05-osc-z125-threshold-m10-fixed3y-600w-20260814"
        case .lp05OscZ125ThresholdM08:
            return sample == .b
                ? "l23b-b-lp05-osc-z125-threshold-m08-fixed3y-600w-20260814"
                : "l23b-a-lp05-osc-z125-threshold-m08-fixed3y-600w-20260814"
        case .lp05OscZ125ThresholdM11:
            return sample == .b
                ? "l23c-b-lp05-osc-z125-threshold-m11-fixed3y-600w-20260814"
                : "l23c-a-lp05-osc-z125-threshold-m11-fixed3y-600w-20260814"
        case .lp05OscZ125ThresholdM07:
            return sample == .b
                ? "l23d-b-lp05-osc-z125-threshold-m07-fixed3y-600w-20260814"
                : "l23d-a-lp05-osc-z125-threshold-m07-fixed3y-600w-20260814"
        case .lp05OscZ250ThresholdM10:
            return sample == .b
                ? "l24a-b-lp05-osc-z250-threshold-m10-fixed3y-600w-20260814"
                : "l24a-a-lp05-osc-z250-threshold-m10-fixed3y-600w-20260814"
        case .lp05OscZ250ThresholdM08:
            return sample == .b
                ? "l24b-b-lp05-osc-z250-threshold-m08-fixed3y-600w-20260814"
                : "l24b-a-lp05-osc-z250-threshold-m08-fixed3y-600w-20260814"
        case .lp08HighThresholdM13:
            return sample == .b
                ? "l28a-b-lp08-high-threshold-m13-fixed3y-600w-20260814"
                : "l28a-a-lp08-high-threshold-m13-fixed3y-600w-20260814"
        case .lp08HighThresholdM11:
            return sample == .b
                ? "l28b-b-lp08-high-threshold-m11-fixed3y-600w-20260814"
                : "l28b-a-lp08-high-threshold-m11-fixed3y-600w-20260814"
        case .lp08HighThresholdM14:
            return sample == .b
                ? "l28c-b-lp08-high-threshold-m14-fixed3y-600w-20260814"
                : "l28c-a-lp08-high-threshold-m14-fixed3y-600w-20260814"
        case .lp08HighThresholdM10:
            return sample == .b
                ? "l28d-b-lp08-high-threshold-m10-fixed3y-600w-20260814"
                : "l28d-a-lp08-high-threshold-m10-fixed3y-600w-20260814"
        case .lp08LowThresholdM16:
            return sample == .b
                ? "l29a-b-lp08-low-threshold-m16-fixed3y-600w-20260814"
                : "l29a-a-lp08-low-threshold-m16-fixed3y-600w-20260814"
        case .lp08LowThresholdM14:
            return sample == .b
                ? "l29b-b-lp08-low-threshold-m14-fixed3y-600w-20260814"
                : "l29b-a-lp08-low-threshold-m14-fixed3y-600w-20260814"
        case .lp08MiddleThresholdM145:
            return sample == .b
                ? "l30a-b-lp08-middle-threshold-m145-fixed3y-600w-20260814"
                : "l30a-a-lp08-middle-threshold-m145-fixed3y-600w-20260814"
        case .lp08MiddleThresholdM125:
            return sample == .b
                ? "l30b-b-lp08-middle-threshold-m125-fixed3y-600w-20260814"
                : "l30b-a-lp08-middle-threshold-m125-fixed3y-600w-20260814"
        case .lp08MiddleThresholdM155:
            return sample == .b
                ? "l30c-b-lp08-middle-threshold-m155-fixed3y-600w-20260814"
                : "l30c-a-lp08-middle-threshold-m155-fixed3y-600w-20260814"
        case .lp08MiddleThresholdM115:
            return sample == .b
                ? "l30d-b-lp08-middle-threshold-m115-fixed3y-600w-20260814"
                : "l30d-a-lp08-middle-threshold-m115-fixed3y-600w-20260814"
        case .removeLP08:
            return sample == .b
                ? "l31-b-lp08-remove-fixed3y-600w-20260814"
                : "l31-a-lp08-remove-fixed3y-600w-20260814"
        case .ln01MA20DaysThresholdM18:
            return sample == .b
                ? "l25a-b-ln01-ma20-days-threshold-m18-fixed3y-600w-20260814"
                : "l25a-a-ln01-ma20-days-threshold-m18-fixed3y-600w-20260814"
        case .ln01MA20DaysThresholdM22:
            return sample == .b
                ? "l25b-b-ln01-ma20-days-threshold-m22-fixed3y-600w-20260814"
                : "l25b-a-ln01-ma20-days-threshold-m22-fixed3y-600w-20260814"
        case .ln02DamnOnly:
            return sample == .b
                ? "l27a-b-ln02-damn-only-fixed3y-600w-20260814"
                : "l27a-a-ln02-damn-only-fixed3y-600w-20260814"
        case .ln02WowOnly:
            return sample == .b
                ? "l27b-b-ln02-wow-only-fixed3y-600w-20260814"
                : "l27b-a-ln02-wow-only-fixed3y-600w-20260814"
        case .lt01WantThreshold4:
            return sample == .b
                ? "l26a-b-lt01-want-threshold4-fixed3y-600w-20260814"
                : "l26a-a-lt01-want-threshold4-fixed3y-600w-20260814"
        case .lt01WantThreshold6:
            return sample == .b
                ? "l26b-b-lt01-want-threshold6-fixed3y-600w-20260814"
                : "l26b-a-lt01-want-threshold6-fixed3y-600w-20260814"
        case .lt01FineOrBetterThreshold6:
            return sample == .b
                ? "l26c-b-lt01-fine-or-better-threshold6-fixed3y-600w-20260814"
                : "l26c-a-lt01-fine-or-better-threshold6-fixed3y-600w-20260814"
        case .lt01HighOrBetterThreshold6:
            return sample == .b
                ? "l26d-b-lt01-high-or-better-threshold6-fixed3y-600w-20260814"
                : "l26d-a-lt01-high-or-better-threshold6-fixed3y-600w-20260814"
        case .lt01WowThreshold6:
            return sample == .b
                ? "l26e-b-lt01-wow-threshold6-fixed3y-600w-20260814"
                : "l26e-a-lt01-wow-threshold6-fixed3y-600w-20260814"
        case .sp06RemoveABranch:
            return sample == .b
                ? "s15a-b-sp06-remove-a-branch-fixed3y-600w-20260809"
                : "s15a-a-sp06-remove-a-branch-fixed3y-600w-20260809"
        case .sp06RemoveBBranch:
            return sample == .b
                ? "s15b-b-sp06-remove-b-branch-fixed3y-600w-20260809"
                : "s15b-a-sp06-remove-b-branch-fixed3y-600w-20260809"
        case .sp06aUpperLowThreshold06:
            return sample == .b
                ? "s26a-b-sp06a-upper-low-threshold06-fixed3y-600w-20260812"
                : "s26a-a-sp06a-upper-low-threshold06-fixed3y-600w-20260812"
        case .sp06aUpperLowThreshold10:
            return sample == .b
                ? "s26b-b-sp06a-upper-low-threshold10-fixed3y-600w-20260812"
                : "s26b-a-sp06a-upper-low-threshold10-fixed3y-600w-20260812"
        case .sp06aUpperHighThresholdM02:
            return sample == .b
                ? "s27a-b-sp06a-upper-high-threshold-m02-fixed3y-600w-20260812"
                : "s27a-a-sp06a-upper-high-threshold-m02-fixed3y-600w-20260812"
        case .sp06aUpperHighThresholdP02:
            return sample == .b
                ? "s27b-b-sp06a-upper-high-threshold-p02-fixed3y-600w-20260812"
                : "s27b-a-sp06a-upper-high-threshold-p02-fixed3y-600w-20260812"
        case .sp06aUpperHighThresholdM04:
            return sample == .b
                ? "s27c-b-sp06a-upper-high-threshold-m04-fixed3y-600w-20260812"
                : "s27c-a-sp06a-upper-high-threshold-m04-fixed3y-600w-20260812"
        case .sp06aUpperHighThresholdP04:
            return sample == .b
                ? "s27d-b-sp06a-upper-high-threshold-p04-fixed3y-600w-20260812"
                : "s27d-a-sp06a-upper-high-threshold-p04-fixed3y-600w-20260812"
        case .sp06bLowerThreshold10:
            return sample == .b
                ? "s28a-b-sp06b-lower-threshold10-fixed3y-600w-20260812"
                : "s28a-a-sp06b-lower-threshold10-fixed3y-600w-20260812"
        case .sp06bLowerThreshold14:
            return sample == .b
                ? "s28b-b-sp06b-lower-threshold14-fixed3y-600w-20260812"
                : "s28b-a-sp06b-lower-threshold14-fixed3y-600w-20260812"
        case .sp06bLowerThreshold08:
            return sample == .b
                ? "s28c-b-sp06b-lower-threshold08-fixed3y-600w-20260812"
                : "s28c-a-sp06b-lower-threshold08-fixed3y-600w-20260812"
        case .sp06bLowerThreshold16:
            return sample == .b
                ? "s28d-b-sp06b-lower-threshold16-fixed3y-600w-20260812"
                : "s28d-a-sp06b-lower-threshold16-fixed3y-600w-20260812"
        case .sn01RemoveABranch:
            return sample == .b
                ? "s16a-b-sn01-remove-a-branch-fixed3y-600w-20260809"
                : "s16a-a-sn01-remove-a-branch-fixed3y-600w-20260809"
        case .sn01RemoveBBranch:
            return sample == .b
                ? "s16b-b-sn01-remove-b-branch-fixed3y-600w-20260809"
                : "s16b-a-sn01-remove-b-branch-fixed3y-600w-20260809"
        case .st02bRangeThreshold25:
            return sample == .b
                ? "s29a-b-st02b-range-threshold25-fixed3y-600w-20260813"
                : "s29a-a-st02b-range-threshold25-fixed3y-600w-20260813"
        case .st02bRangeThreshold35:
            return sample == .b
                ? "s29b-b-st02b-range-threshold35-fixed3y-600w-20260813"
                : "s29b-a-st02b-range-threshold35-fixed3y-600w-20260813"
        case .removeAP01a:
            return sample == .b
                ? "a20-b-remove-ap01a-fixed3y-600w-20260813"
                : "a20-a-remove-ap01a-fixed3y-600w-20260813"
        case .removeAP01b:
            return sample == .b
                ? "a21-b-remove-ap01b-fixed3y-600w-20260813"
                : "a21-a-remove-ap01b-fixed3y-600w-20260813"
        case .ap01bLowBoundary:
            if isFullWindowStress {
                return sample == .b
                    ? "a21b-b-ap01b-low-boundary-fullstress-600w-20260813"
                    : "a21b-a-ap01b-low-boundary-fullstress-600w-20260813"
            }
            return sample == .b
                ? "a21b-b-ap01b-low-boundary-fixed3y-600w-20260813"
                : "a21b-a-ap01b-low-boundary-fixed3y-600w-20260813"
        case .ap02WowMinimum2:
            return sample == .b
                ? "a11a-b-ap02-wow-minimum2-fixed3y-600w-20260813"
                : "a11a-a-ap02-wow-minimum2-fixed3y-600w-20260813"
        case .ap02WowMinimum4:
            return sample == .b
                ? "a11b-b-ap02-wow-minimum4-fixed3y-600w-20260813"
                : "a11b-a-ap02-wow-minimum4-fixed3y-600w-20260813"
        case .ap05DiffThresholdM175:
            return sample == .b
                ? "a12a-b-ap05-diff-threshold-m175-fixed3y-600w-20260813"
                : "a12a-a-ap05-diff-threshold-m175-fixed3y-600w-20260813"
        case .ap05DiffThresholdM225:
            return sample == .b
                ? "a12b-b-ap05-diff-threshold-m225-fixed3y-600w-20260813"
                : "a12b-a-ap05-diff-threshold-m225-fixed3y-600w-20260813"
        case .ap06MA20ZThresholdM23:
            return sample == .b
                ? "a13a-b-ap06-ma20-z-threshold-m23-fixed3y-600w-20260813"
                : "a13a-a-ap06-ma20-z-threshold-m23-fixed3y-600w-20260813"
        case .ap06MA20ZThresholdM27:
            return sample == .b
                ? "a13b-b-ap06-ma20-z-threshold-m27-fixed3y-600w-20260813"
                : "a13b-a-ap06-ma20-z-threshold-m27-fixed3y-600w-20260813"
        case .ap06MA20ZThresholdM21:
            return sample == .b
                ? "a13c-b-ap06-ma20-z-threshold-m21-fixed3y-600w-20260813"
                : "a13c-a-ap06-ma20-z-threshold-m21-fixed3y-600w-20260813"
        case .ap06MA20ZThresholdM29:
            return sample == .b
                ? "a13d-b-ap06-ma20-z-threshold-m29-fixed3y-600w-20260813"
                : "a13d-a-ap06-ma20-z-threshold-m29-fixed3y-600w-20260813"
        case .ap06MA60ZThresholdM26:
            return sample == .b
                ? "a24a-b-ap06-ma60-z-threshold-m26-fixed3y-600w-20260813"
                : "a24a-a-ap06-ma60-z-threshold-m26-fixed3y-600w-20260813"
        case .ap06MA60ZThresholdM30:
            return sample == .b
                ? "a24b-b-ap06-ma60-z-threshold-m30-fixed3y-600w-20260813"
                : "a24b-a-ap06-ma60-z-threshold-m30-fixed3y-600w-20260813"
        case .ap07MA20DiffThresholdM7:
            return sample == .b
                ? "a14a-b-ap07-ma20-diff-threshold-m7-fixed3y-600w-20260813"
                : "a14a-a-ap07-ma20-diff-threshold-m7-fixed3y-600w-20260813"
        case .ap07MA20DiffThresholdM9:
            return sample == .b
                ? "a14b-b-ap07-ma20-diff-threshold-m9-fixed3y-600w-20260813"
                : "a14b-a-ap07-ma20-diff-threshold-m9-fixed3y-600w-20260813"
        case .ap07MA20DiffThresholdM6:
            return sample == .b
                ? "a14c-b-ap07-ma20-diff-threshold-m6-fixed3y-600w-20260813"
                : "a14c-a-ap07-ma20-diff-threshold-m6-fixed3y-600w-20260813"
        case .ap07MA20DiffThresholdM10:
            return sample == .b
                ? "a14d-b-ap07-ma20-diff-threshold-m10-fixed3y-600w-20260813"
                : "a14d-a-ap07-ma20-diff-threshold-m10-fixed3y-600w-20260813"
        case .at01ShortDays150:
            return "a25a-a-at01-short-days150-t2s21-9y-fixed3y-600w-20260821"
        case .at01ShortDays210:
            return "a25b-a-at01-short-days210-t2s21-9y-fixed3y-600w-20260821"
        case .at01LongDays330:
            return "a25c-a-at01-long-days330-t2s21-9y-fixed3y-600w-20260821"
        case .at01LongDays390:
            return "a25d-a-at01-long-days390-t2s21-9y-fixed3y-600w-20260821"
        case .at01WantThreshold2:
            return sample == .b
                ? "a15a-b-at01-want-threshold2-fixed3y-600w-20260813"
                : "a15a-a-at01-want-threshold2-fixed3y-600w-20260813"
        case .at01WantThreshold4:
            return sample == .b
                ? "a15b-b-at01-want-threshold4-fixed3y-600w-20260813"
                : "a15b-a-at01-want-threshold4-fixed3y-600w-20260813"
        case .at01WantThreshold1:
            return sample == .b
                ? "a15c-b-at01-want-threshold1-fixed3y-600w-20260813"
                : "a15c-a-at01-want-threshold1-fixed3y-600w-20260813"
        case .at01WantThreshold5:
            return sample == .b
                ? "a15d-b-at01-want-threshold5-fixed3y-600w-20260813"
                : "a15d-a-at01-want-threshold5-fixed3y-600w-20260813"
        case .at01ROIThresholdM275:
            return sample == .b
                ? "a23a-b-at01-roi-threshold-m275-fixed3y-600w-20260813"
                : "a23a-a-at01-roi-threshold-m275-fixed3y-600w-20260813"
        case .at01ROIThresholdM325:
            return sample == .b
                ? "a23b-b-at01-roi-threshold-m325-fixed3y-600w-20260813"
                : "a23b-a-at01-roi-threshold-m325-fixed3y-600w-20260813"
        case .at01ROIThresholdM3125:
            return sample == .b
                ? "a23c-b-at01-roi-threshold-m3125-fixed3y-600w-20260813"
                : "a23c-a-at01-roi-threshold-m3125-fixed3y-600w-20260813"
        case .at01ROIThresholdM35:
            return sample == .b
                ? "a23d-b-at01-roi-threshold-m35-fixed3y-600w-20260813"
                : "a23d-a-at01-roi-threshold-m35-fixed3y-600w-20260813"
        case .at01Wow35Other325:
            return sample == .b
                ? "a23e-b-at01-wow35-other325-fixed3y-600w-20260813"
                : "a23e-a-at01-wow35-other325-fixed3y-600w-20260813"
        case .at01Wow35Middle325Low30:
            if isFullWindowStress {
                return sample == .b
                    ? "a23f-b-at01-wow35-middle325-low30-fullstress-600w-20260813"
                    : "a23f-a-at01-wow35-middle325-low30-fullstress-600w-20260813"
            }
            return sample == .b
                ? "a23f-b-at01-wow35-middle325-low30-fixed3y-600w-20260813"
                : "a23f-a-at01-wow35-middle325-low30-fixed3y-600w-20260813"
        case .at01Upper325Low30:
            if isFullWindowStress {
                return sample == .b
                    ? "a23g-b-at01-upper325-low30-fullstress-600w-20260813"
                    : "a23g-a-at01-upper325-low30-fullstress-600w-20260813"
            }
            return sample == .b
                ? "a23g-b-at01-upper325-low30-fixed3y-600w-20260813"
                : "a23g-a-at01-upper325-low30-fixed3y-600w-20260813"
        case .ae01CooldownDays20:
            return "ae01-d20-s1-\(sample.rawValue.lowercased())-cooldown-days20-t2s39-9y-fixed3y-600w-20260902"
        case .ae01CooldownDays30:
            return sample == .b
                ? "a16a-b-ae01-cooldown-days30-fixed3y-600w-20260813"
                : "a16a-a-ae01-cooldown-days30-fixed3y-600w-20260813"
        case .ae01CooldownDays60:
            return sample == .b
                ? "a16b-b-ae01-cooldown-days60-fixed3y-600w-20260813"
                : "a16b-a-ae01-cooldown-days60-fixed3y-600w-20260813"
        case .ae01CooldownDays15:
            return sample == .b
                ? "a16c-b-ae01-cooldown-days15-fixed3y-600w-20260813"
                : "a16c-a-ae01-cooldown-days15-fixed3y-600w-20260813"
        case .ae01CooldownDays75:
            return sample == .b
                ? "a16d-b-ae01-cooldown-days75-fixed3y-600w-20260813"
                : "a16d-a-ae01-cooldown-days75-fixed3y-600w-20260813"
        case .ae01CooldownDays38:
            return sample == .b
                ? "a16e-b-ae01-cooldown-days38-fixed3y-600w-20260813"
                : "a16e-a-ae01-cooldown-days38-fixed3y-600w-20260813"
        case .ae03Limit1:
            return sample == .b
                ? "a17a-b-ae03-limit1-fixed3y-600w-20260813"
                : "a17a-a-ae03-limit1-fixed3y-600w-20260813"
        case .ae03Limit3:
            return sample == .b
                ? "a17b-b-ae03-limit3-fixed3y-600w-20260813"
                : "a17b-a-ae03-limit3-fixed3y-600w-20260813"
        case .ae04ROIThresholdM45:
            return sample == .b
                ? "a22a-b-ae04-roi-threshold-m45-fixed3y-600w-20260813"
                : "a22a-a-ae04-roi-threshold-m45-fixed3y-600w-20260813"
        case .ae04ROIThresholdM55:
            return sample == .b
                ? "a22b-b-ae04-roi-threshold-m55-fixed3y-600w-20260813"
                : "a22b-a-ae04-roi-threshold-m55-fixed3y-600w-20260813"
        case .removeAE02:
            return sample == .b
                ? "a18-b-remove-ae02-fixed3y-600w-20260813"
                : "a18-a-remove-ae02-fixed3y-600w-20260813"
        case .removeAN02:
            return sample == .b
                ? "a19-b-remove-an02-fixed3y-600w-20260813"
                : "a19-a-remove-an02-fixed3y-600w-20260813"
        case .st02RemoveBBranch:
            return sample == .b
                ? "s17a-b-st02-remove-b-branch-fixed3y-600w-20260809"
                : "s17a-a-st02-remove-b-branch-fixed3y-600w-20260809"
        case .st02RemoveCBranch:
            return sample == .b
                ? "s17b-b-st02-remove-c-branch-fixed3y-600w-20260809"
                : "s17b-a-st02-remove-c-branch-fixed3y-600w-20260809"
        case .st02RemoveScoreGate:
            return sample == .b
                ? "s18-b-st02-remove-score-gate-fixed3y-600w-20260809"
                : "s18-a-st02-remove-score-gate-fixed3y-600w-20260809"
        case .st01aROI20:
            return sample == .b
                ? "s19a-b-st01a-roi20-fixed3y-600w-20260810"
                : "s19a-a-st01a-roi20-fixed3y-600w-20260810"
        case .st01aROI25:
            return sample == .b
                ? "s19b-b-st01a-roi25-fixed3y-600w-20260810"
                : "s19b-a-st01a-roi25-fixed3y-600w-20260810"
        case .st01aHighScoreM1:
            return sample == .b
                ? "s20a-b-st01a-high-score-m1-fixed3y-600w-20260810"
                : "s20a-a-st01a-high-score-m1-fixed3y-600w-20260810"
        case .st01aHighScore1:
            return sample == .b
                ? "s20b-b-st01a-high-score-1-fixed3y-600w-20260810"
                : "s20b-a-st01a-high-score-1-fixed3y-600w-20260810"
        case .st01aGeneralScore0:
            return sample == .b
                ? "s21a-b-st01a-general-score-0-fixed3y-600w-20260810"
                : "s21a-a-st01a-general-score-0-fixed3y-600w-20260810"
        case .st01aGeneralScore2:
            return sample == .b
                ? "s21b-b-st01a-general-score-2-fixed3y-600w-20260810"
                : "s21b-a-st01a-general-score-2-fixed3y-600w-20260810"
        case .st01aEdgeScore:
            return sample == .b
                ? "s21c-b-st01a-edge-score-fixed3y-600w-20260810"
                : "s21c-a-st01a-edge-score-fixed3y-600w-20260810"
        case .st01cScore4:
            if isFullWindowStress {
                return sample == .b
                    ? "s22a-b-st01c-score4-fullstress-600w-20260810"
                    : "s22a-a-st01c-score4-fullstress-600w-20260810"
            }
            return sample == .b
                ? "s22a-b-st01c-score4-fixed3y-600w-20260810"
                : "s22a-a-st01c-score4-fixed3y-600w-20260810"
        case .st01cScore6:
            return sample == .b
                ? "s22b-b-st01c-score6-fixed3y-600w-20260810"
                : "s22b-a-st01c-score6-fixed3y-600w-20260810"
        case .st01cLowROI10:
            return sample == .b
                ? "s23a-b-st01c-low-roi10-fixed3y-600w-20260811"
                : "s23a-a-st01c-low-roi10-fixed3y-600w-20260811"
        case .st01cLowROI20:
            return sample == .b
                ? "s23b-b-st01c-low-roi20-fixed3y-600w-20260811"
                : "s23b-a-st01c-low-roi20-fixed3y-600w-20260811"
        case .st01cOtherROI20:
            return sample == .b
                ? "s24a-b-st01c-other-roi20-fixed3y-600w-20260811"
                : "s24a-a-st01c-other-roi20-fixed3y-600w-20260811"
        case .st01cOtherROI225:
            return sample == .b
                ? "s24c-b-st01c-other-roi225-fixed3y-600w-20260811"
                : "s24c-a-st01c-other-roi225-fixed3y-600w-20260811"
        case .st01cOtherROI30:
            return sample == .b
                ? "s24b-b-st01c-other-roi30-fixed3y-600w-20260811"
                : "s24b-a-st01c-other-roi30-fixed3y-600w-20260811"
        case .st01cWeakOrBetterROI20:
            return sample == .b
                ? "s24d-b-st01c-weak-or-better-roi20-fixed3y-600w-20260811"
                : "s24d-a-st01c-weak-or-better-roi20-fixed3y-600w-20260811"
        case .st01cGradeTieredROI:
            return sample == .b
                ? "s24e-b-st01c-grade-tiered-roi-fixed3y-600w-20260811"
                : "s24e-a-st01c-grade-tiered-roi-fixed3y-600w-20260811"
        case .st01cWow25Weak20:
            return sample == .b
                ? "s24f-b-st01c-wow25-weak20-fixed3y-600w-20260811"
                : "s24f-a-st01c-wow25-weak20-fixed3y-600w-20260811"
        case .st01cWow25Weak15:
            return sample == .b
                ? "s24g-b-st01c-wow25-weak15-fixed3y-600w-20260811"
                : "s24g-a-st01c-wow25-weak15-fixed3y-600w-20260811"
        case .st01cMiddle225Wow20:
            return sample == .b
                ? "s24h-b-st01c-middle225-wow20-fixed3y-600w-20260811"
                : "s24h-a-st01c-middle225-wow20-fixed3y-600w-20260811"
        case .st01cMiddle20Wow225:
            if isFullWindowStress {
                return sample == .b
                    ? "s24i-b-st01c-middle20-wow225-fullstress-600w-20260811"
                    : "s24i-a-st01c-middle20-wow225-fullstress-600w-20260811"
            }
            return sample == .b
                ? "s24i-b-st01c-middle20-wow225-fixed3y-600w-20260811"
                : "s24i-a-st01c-middle20-wow225-fixed3y-600w-20260811"
        case .an01PenaltyM1:
            if isFullWindowStress {
                return sample == .b
                    ? "a10a-b-an01-penalty-m1-fullstress-600w-20260809"
                    : "a10a-a-an01-penalty-m1-fullstress-600w-20260809"
            }
            return sample == .b
                ? "a10a-b-an01-penalty-m1-fixed3y-600w-20260809"
                : "a10a-a-an01-penalty-m1-fixed3y-600w-20260809"
        case .an01PenaltyM3:
            return sample == .b
                ? "a10b-b-an01-penalty-m3-fixed3y-600w-20260809"
                : "a10b-a-an01-penalty-m3-fixed3y-600w-20260809"
        case .an01Control:
            return sample == .b
                ? "a10-control-b-an01-formal-fixed3y-600w-20260809"
                : "a10-control-a-an01-formal-fixed3y-600w-20260809"
        case .an01FineBoundary:
            return sample == .b
                ? "a10c-b-an01-fine-boundary-m2-fixed3y-600w-20260809"
                : "a10c-a-an01-fine-boundary-m2-fixed3y-600w-20260809"
        case .an01FinePenaltyM1:
            return sample == .b
                ? "a10f-b-an01-fine-or-better-m1-fixed3y-600w-20260809"
                : "a10f-a-an01-fine-or-better-m1-fixed3y-600w-20260809"
        case .an01FinePenaltyM1NoNone:
            return sample == .b
                ? "a10g-b-an01-fine-or-better-m1-no-none-fixed3y-600w-20260809"
                : "a10g-a-an01-fine-or-better-m1-no-none-fixed3y-600w-20260809"
        case .an01FinePenaltyM1LowBelowM1:
            return sample == .b
                ? "a10h-b-an01-u-shape-low-fine-m1-fixed3y-600w-20260809"
                : "a10h-a-an01-u-shape-low-fine-m1-fixed3y-600w-20260809"
        case .an01FinePenaltyM1LowBelowP1:
            return sample == .b
                ? "a10i-b-an01-low-p1-fine-m1-fixed3y-600w-20260809"
                : "a10i-a-an01-low-p1-fine-m1-fixed3y-600w-20260809"
        case .an01FinePenaltyM3:
            return sample == .b
                ? "a10d-b-an01-fine-or-better-m3-fixed3y-600w-20260809"
                : "a10d-a-an01-fine-or-better-m3-fixed3y-600w-20260809"
        case .an01HighPenaltyM3:
            return sample == .b
                ? "a10e-b-an01-high-or-better-m3-fixed3y-600w-20260809"
                : "a10e-a-an01-high-or-better-m3-fixed3y-600w-20260809"
        case .sn0203FineHighGroup:
            return sample == .b
                ? "s13a-b-sn0203-fine-high-group-fixed3y-600w-20260803"
                : "s13a-a-sn0203-fine-high-group-fixed3y-600w-20260803"
        case .sn0203HighGeneralGroup:
            return sample == .b
                ? "s13b-b-sn0203-high-general-group-fixed3y-600w-20260803"
                : "s13b-a-sn0203-high-general-group-fixed3y-600w-20260803"
        case .sn02WowThreshold625:
            return sample == .b
                ? "s30a-b-sn02-wow-threshold625-fixed3y-600w-20260813"
                : "s30a-a-sn02-wow-threshold625-fixed3y-600w-20260813"
        case .sn02WowThreshold875:
            return sample == .b
                ? "s30b-b-sn02-wow-threshold875-fixed3y-600w-20260813"
                : "s30b-a-sn02-wow-threshold875-fixed3y-600w-20260813"
        case .sn02WowCapWithSN05:
            return sample == .b
                ? "s30c-b-sn02-wow-cap-with-sn05-fixed3y-600w-20260813"
                : "s30c-a-sn02-wow-cap-with-sn05-fixed3y-600w-20260813"
        case .sn05HighOrBetter:
            if isFullWindowStress {
                return sample == .b
                    ? "s14a-b-sn05-high-or-better-fullstress-600w-20260803"
                    : "s14a-a-sn05-high-or-better-fullstress-600w-20260803"
            }
            return sample == .b
                ? "s14a-b-sn05-high-or-better-fixed3y-600w-20260803"
                : "s14a-a-sn05-high-or-better-fixed3y-600w-20260803"
        case .sn05WeakOrBetter:
            return sample == .b
                ? "s14b-b-sn05-weak-or-better-fixed3y-600w-20260803"
                : "s14b-a-sn05-weak-or-better-fixed3y-600w-20260803"
        case .st01eDays60:
            return sample == .b
                ? "s25a-b-st01e-days60-fixed3y-600w-20260812"
                : "s25a-a-st01e-days60-fixed3y-600w-20260812"
        case .st01eDays68:
            if isFullWindowStress {
                return sample == .b
                    ? "s25d-b-st01e-days68-fullstress-600w-20260812"
                    : "s25d-a-st01e-days68-fullstress-600w-20260812"
            }
            return sample == .b
                ? "s25c-b-st01e-days68-fixed3y-600w-20260812"
                : "s25c-a-st01e-days68-fixed3y-600w-20260812"
        case .st01eDays90:
            return sample == .b
                ? "s25b-b-st01e-days90-fixed3y-600w-20260812"
                : "s25b-a-st01e-days90-fixed3y-600w-20260812"
        case .marketVoteNever, .marketVotePulseH, .marketVotePulseL,
             .marketVotePulseS, .marketVotePulseA, .baseline:
            break
        }
        if sample == .b {
            return isFullWindowStress
                ? "baseline-b-s17-ap08-wow-early-boundary-fullstress-600w-20260814"
                : "baseline-b-s17-ap08-wow-early-boundary-fixed3y-600w-20260814"
        }
        if isFullWindowStress {
            return "baseline-s17-ap08-wow-early-boundary-fullstress-600w-20260814"
        }
        return "baseline-s17-ap08-wow-early-boundary-fixed3y-600w-20260814"
    }()
    static let referenceRunID: String = {
        if isNineYearABProfile {
            let lowerSample = sample.rawValue.lowercased()
            let window = isFullWindowStress ? "9y-fullstress" : "9y-fixed3y"
            if candidate == .baseline {
                return "baseline-\(lowerSample)-v19-s31-st02h-efficiency-loss-cut-t2s38-\(window)-600w-20260831"
            }
            return "baseline-\(lowerSample)-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-\(window)-600w-20260901"
        }
        if candidate == .ln02DamnOnly || candidate == .ln02WowOnly
            || candidate == .lp08HighThresholdM13 || candidate == .lp08HighThresholdM11
            || candidate == .lp08HighThresholdM14 || candidate == .lp08HighThresholdM10
            || candidate == .lp08LowThresholdM16 || candidate == .lp08LowThresholdM14
            || candidate == .lp08MiddleThresholdM145 || candidate == .lp08MiddleThresholdM125
            || candidate == .lp08MiddleThresholdM155 || candidate == .lp08MiddleThresholdM115
            || candidate == .removeLP08 {
            return sample == .b
                ? "baseline-b-s17-ap08-wow-early-boundary-fixed3y-600w-20260814"
                : "baseline-s17-ap08-wow-early-boundary-fixed3y-600w-20260814"
        }
        if candidate == .lp03KZ125ThresholdM10 || candidate == .lp03KZ125ThresholdM08
            || candidate == .lp03KZ250ThresholdM10 || candidate == .lp03KZ250ThresholdM08
            || candidate == .lp04DZ125ThresholdM10 || candidate == .lp04DZ125ThresholdM08
            || candidate == .lp04DZ250ThresholdM10 || candidate == .lp04DZ250ThresholdM08
            || candidate == .lp04DZ250ThresholdM11 || candidate == .lp04DZ250ThresholdM07
            || candidate == .lp05OscZ125ThresholdM10 || candidate == .lp05OscZ125ThresholdM08
            || candidate == .lp05OscZ125ThresholdM11 || candidate == .lp05OscZ125ThresholdM07
            || candidate == .lp05OscZ250ThresholdM10 || candidate == .lp05OscZ250ThresholdM08
            || candidate == .ln01MA20DaysThresholdM18 || candidate == .ln01MA20DaysThresholdM22
            || candidate == .lt01WantThreshold4 || candidate == .lt01WantThreshold6
            || candidate == .lt01FineOrBetterThreshold6 || candidate == .lt01HighOrBetterThreshold6
            || candidate == .lt01WowThreshold6 {
            return sample == .b
                ? "baseline-b-s16-ht01-low-only-fixed3y-600w-20260814"
                : "baseline-s16-ht01-low-only-fixed3y-600w-20260814"
        }
        if candidate == .ap06MA60ZThresholdM26 || candidate == .ap06MA60ZThresholdM30
            || candidate == .gradeActivationRounds1 || candidate == .gradeActivationRounds3
            || candidate == .gradeActivationDays300 || candidate == .gradeActivationDays420
            || candidate == .gradeActivationExtremeNegative69
            || candidate == .ht01WantThresholdM1 || candidate == .ht01WantThreshold1
            || candidate == .ht01WeakOrBelowThreshold1
            || candidate == .ht01LowOnlyThreshold1 {
            if candidate == .ht01LowOnlyThreshold1 && isFullWindowStress {
                return sample == .b
                    ? "baseline-b-s15-at01-grade-roi-fullstress-600w-20260813"
                    : "baseline-s15-at01-grade-roi-fullstress-600w-20260813"
            }
            return sample == .b
                ? "baseline-b-s15-at01-grade-roi-fixed3y-600w-20260813"
                : "baseline-s15-at01-grade-roi-fixed3y-600w-20260813"
        }
        if candidate == .sn02WowThreshold625 || candidate == .sn02WowThreshold875
            || candidate == .sn02WowCapWithSN05 {
            if isFullWindowStress {
                return sample == .b
                    ? "baseline-b-s15-at01-grade-roi-fullstress-600w-20260813"
                    : "baseline-s15-at01-grade-roi-fullstress-600w-20260813"
            }
            return sample == .b
                ? "baseline-b-s15-at01-grade-roi-fixed3y-600w-20260813"
                : "baseline-s15-at01-grade-roi-fixed3y-600w-20260813"
        }
        if candidate == .baseline {
            if isFullWindowStress {
                return sample == .b
                    ? "baseline-b-s16-ht01-low-only-fullstress-600w-20260814"
                    : "baseline-s16-ht01-low-only-fullstress-600w-20260814"
            }
            return sample == .b
                ? "baseline-b-s16-ht01-low-only-fixed3y-600w-20260814"
                : "baseline-s16-ht01-low-only-fixed3y-600w-20260814"
        }
        if candidate == .ae04ROIThresholdM45 || candidate == .ae04ROIThresholdM55
            || candidate == .at01ROIThresholdM275 || candidate == .at01ROIThresholdM325
            || candidate == .at01ROIThresholdM3125 || candidate == .at01ROIThresholdM35
            || candidate == .at01Wow35Other325 || candidate == .at01Wow35Middle325Low30
            || candidate == .at01Upper325Low30 {
            if isFullWindowStress {
                return sample == .b
                    ? "baseline-b-s14-ap01b-low-fullstress-600w-20260813"
                    : "baseline-s14-ap01b-low-fullstress-600w-20260813"
            }
            return sample == .b
                ? "baseline-b-s14-ap01b-low-fixed3y-600w-20260813"
                : "baseline-s14-ap01b-low-fixed3y-600w-20260813"
        }
        if candidate == .ae03Limit1 || candidate == .ae03Limit3
            || candidate == .removeAE02 || candidate == .removeAN02
            || candidate == .removeAP01a || candidate == .removeAP01b
            || candidate == .ap01bLowBoundary {
            if isFullWindowStress {
                return sample == .b
                    ? "baseline-b-s13-ae01-days38-fullstress-600w-20260813"
                    : "baseline-s13-ae01-days38-fullstress-600w-20260813"
            }
            return sample == .b
                ? "baseline-b-s13-ae01-days38-fixed3y-600w-20260813"
                : "baseline-s13-ae01-days38-fixed3y-600w-20260813"
        }
        if candidate == .sp06aUpperLowThreshold06
            || candidate == .sp06aUpperLowThreshold10
            || candidate == .sp06aUpperHighThresholdM02
            || candidate == .sp06aUpperHighThresholdP02
            || candidate == .sp06aUpperHighThresholdM04
            || candidate == .sp06aUpperHighThresholdP04
            || candidate == .sp06bLowerThreshold10
            || candidate == .sp06bLowerThreshold14
            || candidate == .sp06bLowerThreshold08
            || candidate == .sp06bLowerThreshold16
            || candidate == .st02bRangeThreshold25
            || candidate == .st02bRangeThreshold35
            || candidate == .ap02WowMinimum2
            || candidate == .ap02WowMinimum4
            || candidate == .ap05DiffThresholdM175
            || candidate == .ap05DiffThresholdM225
            || candidate == .ap06MA20ZThresholdM23
            || candidate == .ap06MA20ZThresholdM27
            || candidate == .ap06MA20ZThresholdM21
            || candidate == .ap06MA20ZThresholdM29
            || candidate == .ap07MA20DiffThresholdM7
            || candidate == .ap07MA20DiffThresholdM9
            || candidate == .ap07MA20DiffThresholdM6
            || candidate == .ap07MA20DiffThresholdM10
            || candidate == .at01WantThreshold2
            || candidate == .at01WantThreshold4
            || candidate == .at01WantThreshold1
            || candidate == .at01WantThreshold5
            || candidate == .ae01CooldownDays30
            || candidate == .ae01CooldownDays60
            || candidate == .ae01CooldownDays15
            || candidate == .ae01CooldownDays75
            || candidate == .ae01CooldownDays38 {
            return sample == .b
                ? "baseline-b-s12-st01e-days68-fixed3y-600w-20260812"
                : "baseline-s12-st01e-days68-fixed3y-600w-20260812"
        }
        if candidate == .hp03RatedThresholdM025
            || candidate == .hp03RatedThresholdP025
            || candidate == .hp03RatedThresholdM05
            || candidate == .hp03RatedThresholdP05
            || candidate == .hp03LowerThresholdM075
            || candidate == .hp03LowerThresholdM025
            || candidate == .hp03LowerThresholdM10
            || candidate == .hp03LowerThreshold00
            || candidate == .st01aROI20
            || candidate == .st01aROI25
            || candidate == .st01aHighScoreM1
            || candidate == .st01aHighScore1
            || candidate == .st01aGeneralScore0
            || candidate == .st01aGeneralScore2
            || candidate == .st01aEdgeScore
            || candidate == .st01cScore4
            || candidate == .st01cScore6 {
            if isFullWindowStress {
                return sample == .b
                    ? "baseline-b-s9-an01-penalty-m1-fullstress-600w-20260809"
                    : "baseline-s9-an01-penalty-m1-fullstress-600w-20260809"
            }
            return sample == .b
                ? "baseline-b-s9-an01-penalty-m1-fixed3y-600w-20260809"
                : "baseline-s9-an01-penalty-m1-fixed3y-600w-20260809"
        }
        if candidate == .hp01LowerLoose || candidate == .hp01LowerStrict
            || candidate == .hp01LowUpper19 || candidate == .hp01LowUpper21
            || candidate == .hp01LowUpper15 || candidate == .hp01LowUpper25
            || candidate == .hp01OtherUpper24 || candidate == .hp01OtherUpper26
            || candidate == .hp01OtherUpper20 || candidate == .hp01OtherUpper30
            || candidate == .hp04WeakThreshold19 || candidate == .hp04WeakThreshold21
            || candidate == .hp04WeakThreshold15 || candidate == .hp04WeakThreshold25
            || candidate == .hp03LowBoundaryLow || candidate == .hp03LowBoundaryFine
            || candidate == .hp03OtherThresholdM025 || candidate == .hp03OtherThresholdP025
            || candidate == .hp03OtherThresholdM05 || candidate == .hp03OtherThresholdP05
            || candidate == .hp03RatedThresholdM025 || candidate == .hp03RatedThresholdP025
            || candidate == .hp03RatedThresholdM05 || candidate == .hp03RatedThresholdP05
            || candidate == .hp03LowerThresholdM075 || candidate == .hp03LowerThresholdM025
            || candidate == .hp03LowerThresholdM10 || candidate == .hp03LowerThreshold00
            || candidate == .hn01aGradeWeakOrBelow || candidate == .hn01aGradeBelowWow
            || candidate == .hn02bHighBoundaryLow || candidate == .hn02bHighBoundaryFine
            || candidate == .hn05GradeWeakOrBetter || candidate == .hn05GradeAll
            || candidate == .hn08Threshold15 || candidate == .hn08Threshold17
            || candidate == .hn08Threshold12 || candidate == .hn08Threshold20
            || candidate == .hn06GradeBoundaryLow || candidate == .hn06GradeBoundaryFine
            || candidate == .hn06MA20Threshold55 || candidate == .hn06MA20Threshold65
            || candidate == .hn06MA60Threshold65 || candidate == .hn06MA60Threshold75
            || candidate == .hn07MA20Threshold55 || candidate == .hn07MA20Threshold65
            || candidate == .hc01GradeBoundaryLow || candidate == .hc01GradeBoundaryFine
            || candidate == .hc02GradeBoundaryLow || candidate == .hc02GradeBoundaryFine
            || candidate == .hc02EarlyStart0216 || candidate == .hc02EarlyStart0226
            || candidate == .hc03RemoveOverlap || candidate == .hc03RemoveLate
            || candidate == .hc04RemoveOverlap || candidate == .hc04RemoveLate
            || candidate == .hn01bThreshold17 || candidate == .hn01bThreshold19
            || candidate == .hn02aThresholdM09 || candidate == .hn02aThresholdM07
            || candidate == .hn06RemoveMA20Branch || candidate == .hn06RemoveMA60Branch
            || candidate == .lc03RemoveC01Overlap || candidate == .lc03RemoveC02Overlap
            || candidate == .lc03RemoveC01OverlapFineOrBetter
            || candidate == .lc03RemoveC01OverlapNoneOrBelow
            || candidate == .lc03RemoveC01OverlapFineOnly
            || candidate == .lc03RemoveC01OverlapHighOrBetter
            || candidate == .lc03RemoveMiddle
            || candidate == .lc01Remove || candidate == .lc02Remove
            || candidate == .lp07MA60ThresholdM06
            || candidate == .lp07MA60ThresholdM04
            || candidate == .lp07MA60ThresholdM10
            || candidate == .lp07MA60Threshold00
            || candidate == .lp09MA60ThresholdM25
            || candidate == .lp09MA60ThresholdM35
            || candidate == .lp09MA20ThresholdM25
            || candidate == .lp09MA20ThresholdM35
            || candidate == .sp06RemoveABranch
            || candidate == .sp06RemoveBBranch
            || candidate == .sn01RemoveABranch
            || candidate == .sn01RemoveBBranch
            || candidate == .st02RemoveBBranch
            || candidate == .st02RemoveCBranch
            || candidate == .st02RemoveScoreGate
            || candidate == .st01aROI20
            || candidate == .st01aROI25
            || candidate == .st01aHighScoreM1
            || candidate == .st01aHighScore1
            || candidate == .st01aGeneralScore0
            || candidate == .st01aGeneralScore2
            || candidate == .st01aEdgeScore
            || candidate == .st01cScore4
            || candidate == .st01cScore6
            || candidate == .an01PenaltyM1
            || candidate == .an01PenaltyM3
            || candidate == .an01Control
            || candidate == .an01FineBoundary
            || candidate == .an01FinePenaltyM1
            || candidate == .an01FinePenaltyM1NoNone
            || candidate == .an01FinePenaltyM1LowBelowM1
            || candidate == .an01FinePenaltyM1LowBelowP1
            || candidate == .an01FinePenaltyM3
            || candidate == .an01HighPenaltyM3 {
            if isFullWindowStress {
                return sample == .b
                    ? "baseline-b-s8-sn05-high-grade-fullstress-600w-20260803"
                    : "baseline-s8-sn05-high-grade-fullstress-600w-20260803"
            }
            return sample == .b
                ? "baseline-b-s8-sn05-high-grade-fixed3y-600w-20260803"
                : "baseline-s8-sn05-high-grade-fixed3y-600w-20260803"
        }
        if candidate == .sn05HighOrBetter && isFullWindowStress {
            return sample == .b
                ? "baseline-b-s7-score-grade-fullstress-600w-20260802"
                : "baseline-s7-score-grade-fullstress-600w-20260802"
        }
        if candidate == .scoreGradeFine18 || candidate == .removeHN06
            || candidate == .removeHN02b || candidate == .removeHN01a
            || candidate == .hn09Strict || candidate == .hn09Loose
            || candidate == .hn09LowGradeHighStrict
            || candidate == .hn09LowGradeHighLoose
            || candidate == .hn09LowGradeHigh06
            || candidate == .hn09LowGradeHigh08
            || candidate == .hn09LowGradeHigh10
            || candidate == .hn09LowGradeHigh12
            || candidate == .hn09High081313
            || candidate == .hn09High081315
            || candidate == .hn09High081520
            || candidate == .hn09High081515
            || candidate == .hn09Low081215
            || candidate == .hn09HighOnly
            || candidate == .hn09Low051218
            || candidate == .hn03ThresholdM07
            || candidate == .hn03ThresholdM03
            || candidate == .sn0203FineHighGroup
            || candidate == .sn0203HighGeneralGroup
            || candidate == .sn05HighOrBetter
            || candidate == .sn05WeakOrBetter {
            return sample == .b
                ? "baseline-b-s7-score-grade-fixed3y-600w-20260802"
                : "baseline-s7-score-grade-fixed3y-600w-20260802"
        }
        if candidate != .baseline {
            return sample == .b
                ? "baseline-b-s6-volume-low-veto-fixed3y-600w-20260802"
                : "baseline-s6-volume-low-veto-fixed3y-600w-20260730"
        }
        if sample == .b {
            return isFullWindowStress
                ? "baseline-b-s8-sn05-high-grade-fullstress-600w-20260803"
                : "baseline-b-s8-sn05-high-grade-fixed3y-600w-20260803"
        }
        if isFullWindowStress {
            return "baseline-s8-sn05-high-grade-fullstress-600w-20260803"
        }
        return "baseline-s8-sn05-high-grade-fixed3y-600w-20260803"
    }()
    static let reportTitle: String = {
        if isNineYearABProfile && candidate == .marketVoteNever {
            return "Sample \(sample.rawValue) · MKT-R02-Q0 永假市場條件接線控制"
        }
        if isNineYearABProfile && candidate == .marketVotePulseH {
            return "Sample \(sample.rawValue) · MKT-R02-Q0 H買診斷脈衝"
        }
        if isNineYearABProfile && candidate == .marketVotePulseL {
            return "Sample \(sample.rawValue) · MKT-R02-Q0 L買診斷脈衝"
        }
        if isNineYearABProfile && candidate == .marketVotePulseS {
            return "Sample \(sample.rawValue) · MKT-R02-Q0 賣出診斷脈衝"
        }
        if isNineYearABProfile && candidate == .marketVotePulseA {
            return "Sample \(sample.rawValue) · MKT-R02-Q0 加碼診斷脈衝"
        }
        if isNineYearABProfile && sample == .c && candidate == .lc03RemoveMiddle {
            return "Sample C · L-C03-R1 移除 8/16～8/20 加分固定三年候選"
        }
        if isNineYearABProfile && candidate == .at01ShortDays150 {
            return "Sample A · A25a A-T01 短期持股門檻縮短至 150 日固定三年候選"
        }
        if isNineYearABProfile && candidate == .at01ShortDays210 {
            return "Sample A · A25b A-T01 短期持股門檻延長至 210 日固定三年候選"
        }
        if isNineYearABProfile && candidate == .at01LongDays330 {
            return "Sample A · A25c A-T01 長期持股門檻提前至 330 日固定三年候選"
        }
        if isNineYearABProfile && candidate == .at01LongDays390 {
            return "Sample A · A25d A-T01 長期持股門檻延後至 390 日固定三年候選"
        }
        if isNineYearABProfile && candidate == .ae01CooldownDays20 {
            return "Sample \(sample.rawValue) · A-E01-D20-S1 A-E01 一般加碼冷卻縮短至 20 日固定三年候選"
        }
        if isNineYearABProfile && candidate == .gwS01 {
            return "Sample A · GW-S01 惡化預警第一日賣出加 1 分固定三年候選"
        }
        if isNineYearABProfile && candidate == .gwS01b {
            return "Sample A · GW-S01b 惡化預警第一日僅 S-T01 賣出加 1 分固定三年候選"
        }
        if isNineYearABProfile && candidate == .gwA01 {
            return "Sample A · GW-A01 改善預警第一日加碼加 1 分固定三年候選"
        }
        if isNineYearABProfile && candidate == .gwA02 {
            return "Sample A · GW-A02 惡化預警第一日加碼減 1 分固定三年候選"
        }
        if isNineYearABProfile && candidate == .gwA02b {
            return "Sample A · GW-A02b 惡化預警第一日加碼減 2 分固定三年候選"
        }
        if isNineYearABProfile && candidate == .gwS02 {
            return "Sample A · GW-S02 改善預警第一日賣出減 1 分固定三年候選"
        }
        if isNineYearABProfile {
            let window = isFullWindowStress ? "九年全期間" : "九年三窗口"
            return "Sample \(sample.rawValue) · T2/S39 S32 exact wow 非探底且無 A-P02 加碼扣分 \(window) Baseline"
        }
        if candidate == .sn02WowThreshold625 {
            return "Sample \(sample.rawValue) · S30a S-N02 wow 收盤漲幅門檻放寬至 6.25% 固定三年候選"
        }
        if candidate == .sn02WowThreshold875 {
            return "Sample \(sample.rawValue) · S30b S-N02 wow 收盤漲幅門檻收緊至 8.75% 固定三年候選"
        }
        if candidate == .sn02WowCapWithSN05 {
            return "Sample \(sample.rawValue) · S30c wow 的 S-N02／S-N05 合計最多扣 1 分固定三年候選"
        }
        if candidate == .hp01LowerLoose {
            return "Sample \(sample.rawValue) · H22a H-P01 下限放寬固定三年候選"
        }
        if candidate == .hp01LowerStrict {
            return "Sample \(sample.rawValue) · H22b H-P01 下限收緊固定三年候選"
        }
        if candidate == .hp01LowUpper19 {
            return "Sample \(sample.rawValue) · H23a H-P01 low 以下上限 1.9 固定三年候選"
        }
        if candidate == .hp01LowUpper21 {
            return "Sample \(sample.rawValue) · H23b H-P01 low 以下上限 2.1 固定三年候選"
        }
        if candidate == .hp01LowUpper15 {
            return "Sample \(sample.rawValue) · H23c H-P01 low 以下上限 1.5 固定三年候選"
        }
        if candidate == .hp01LowUpper25 {
            return "Sample \(sample.rawValue) · H23d H-P01 low 以下上限 2.5 固定三年候選"
        }
        if candidate == .hp01OtherUpper24 {
            return "Sample \(sample.rawValue) · H24a H-P01 weak 以上上限 2.4 固定三年候選"
        }
        if candidate == .hp01OtherUpper26 {
            return "Sample \(sample.rawValue) · H24b H-P01 weak 以上上限 2.6 固定三年候選"
        }
        if candidate == .hp01OtherUpper20 {
            return "Sample \(sample.rawValue) · H24c H-P01 weak 以上上限 2.0 固定三年候選"
        }
        if candidate == .hp01OtherUpper30 {
            return "Sample \(sample.rawValue) · H24d H-P01 weak 以上上限 3.0 固定三年候選"
        }
        if candidate == .hp04WeakThreshold19 {
            return "Sample \(sample.rawValue) · H25a H-P04 weak 以下爆量門檻 1.9 固定三年候選"
        }
        if candidate == .hp04WeakThreshold21 {
            return "Sample \(sample.rawValue) · H25b H-P04 weak 以下爆量門檻 2.1 固定三年候選"
        }
        if candidate == .hp04WeakThreshold15 {
            return "Sample \(sample.rawValue) · H25c H-P04 weak 以下爆量門檻 1.5 固定三年候選"
        }
        if candidate == .hp04WeakThreshold25 {
            return "Sample \(sample.rawValue) · H25d H-P04 weak 以下爆量門檻 2.5 固定三年候選"
        }
        if candidate == .hp03LowBoundaryLow {
            return "Sample \(sample.rawValue) · H26a H-P03a 放寬範圍縮至 low 以下固定三年候選"
        }
        if candidate == .hp03LowBoundaryFine {
            return "Sample \(sample.rawValue) · H26b H-P03a 放寬範圍擴至 fine 以下固定三年候選"
        }
        if candidate == .hp03RatedThresholdM025 {
            return "Sample \(sample.rawValue) · H43e H-P03a fine 以上一般門檻 -0.25 固定三年候選"
        }
        if candidate == .hp03RatedThresholdP025 {
            return "Sample \(sample.rawValue) · H43f H-P03a fine 以上一般門檻 +0.25 固定三年候選"
        }
        if candidate == .hp03RatedThresholdM05 {
            return "Sample \(sample.rawValue) · H43g H-P03a fine 以上一般門檻 -0.5 固定三年候選"
        }
        if candidate == .hp03RatedThresholdP05 {
            return "Sample \(sample.rawValue) · H43h H-P03a fine 以上一般門檻 +0.5 固定三年候選"
        }
        if candidate == .hp03LowerThresholdM075 {
            return "Sample \(sample.rawValue) · H44a H-P03a weak／low 門檻 -0.75 固定三年候選"
        }
        if candidate == .hp03LowerThresholdM025 {
            return "Sample \(sample.rawValue) · H44b H-P03a weak／low 門檻 -0.25 固定三年候選"
        }
        if candidate == .hp03LowerThresholdM10 {
            return "Sample \(sample.rawValue) · H44c H-P03a weak／low 門檻 -1.0 固定三年候選"
        }
        if candidate == .hp03LowerThreshold00 {
            return "Sample \(sample.rawValue) · H44d H-P03a weak／low 門檻 0 固定三年候選"
        }
        if candidate == .hn01aGradeWeakOrBelow {
            return "Sample \(sample.rawValue) · H27a H-N01a 只適用 weak 以下固定三年候選"
        }
        if candidate == .hn01aGradeBelowWow {
            return "Sample \(sample.rawValue) · H27b H-N01a 適用至 high 固定三年候選"
        }
        if candidate == .hn02bHighBoundaryLow {
            return "Sample \(sample.rawValue) · H28a H-N02b 2.0 門檻縮至 low 以下固定三年候選"
        }
        if candidate == .hn02bHighBoundaryFine {
            return "Sample \(sample.rawValue) · H28b H-N02b 2.0 門檻擴至 fine 以下固定三年候選"
        }
        if candidate == .hn05GradeWeakOrBetter {
            return "Sample \(sample.rawValue) · H29a H-N05 適用範圍縮至 weak 以上固定三年候選"
        }
        if candidate == .hn05GradeAll {
            return "Sample \(sample.rawValue) · H29b H-N05 適用所有 Grade 固定三年候選"
        }
        if candidate == .hn08Threshold15 {
            return "Sample \(sample.rawValue) · H30a H-N08 MA20 過熱門檻 1.5 固定三年候選"
        }
        if candidate == .hn08Threshold17 {
            return "Sample \(sample.rawValue) · H30b H-N08 MA20 過熱門檻 1.7 固定三年候選"
        }
        if candidate == .hn08Threshold12 {
            return "Sample \(sample.rawValue) · H30c H-N08 MA20 過熱門檻 1.2 固定三年候選"
        }
        if candidate == .hn08Threshold20 {
            return "Sample \(sample.rawValue) · H30d H-N08 MA20 過熱門檻 2.0 固定三年候選"
        }
        if candidate == .hn06GradeBoundaryLow {
            return "Sample \(sample.rawValue) · H31a H-N06 適用範圍縮至 low 以下固定三年候選"
        }
        if candidate == .hn06GradeBoundaryFine {
            return "Sample \(sample.rawValue) · H31b H-N06 適用範圍擴至 fine 以下固定三年候選"
        }
        if candidate == .hn06MA20Threshold55 {
            return "Sample \(sample.rawValue) · H32a H-N06a MA20 九日波幅門檻 5.5 固定三年候選"
        }
        if candidate == .hn06MA20Threshold65 {
            return "Sample \(sample.rawValue) · H32b H-N06a MA20 九日波幅門檻 6.5 固定三年候選"
        }
        if candidate == .hn06MA60Threshold65 {
            return "Sample \(sample.rawValue) · H33a H-N06b MA60 九日波幅門檻 6.5 固定三年候選"
        }
        if candidate == .hn06MA60Threshold75 {
            return "Sample \(sample.rawValue) · H33b H-N06b MA60 九日波幅門檻 7.5 固定三年候選"
        }
        if candidate == .hn07MA20Threshold55 {
            return "Sample \(sample.rawValue) · H34a H-N07 MA20 九日波幅門檻 5.5 固定三年候選"
        }
        if candidate == .hn07MA20Threshold65 {
            return "Sample \(sample.rawValue) · H34b H-N07 MA20 九日波幅門檻 6.5 固定三年候選"
        }
        if candidate == .hc01GradeBoundaryLow {
            return "Sample \(sample.rawValue) · H35a H-C01 提前扣分縮至 low 以下固定三年候選"
        }
        if candidate == .hc01GradeBoundaryFine {
            return "Sample \(sample.rawValue) · H35b H-C01 提前扣分擴至 fine 以下固定三年候選"
        }
        if candidate == .hc02GradeBoundaryLow {
            return "Sample \(sample.rawValue) · H36a H-C02 提前扣分縮至 low 以下固定三年候選"
        }
        if candidate == .hc02GradeBoundaryFine {
            return "Sample \(sample.rawValue) · H36b H-C02 提前扣分擴至 fine 以下固定三年候選"
        }
        if candidate == .hc02EarlyStart0216 {
            return "Sample \(sample.rawValue) · H37a H-C02 weak 以下提前扣分改從 2/16 開始固定三年候選"
        }
        if candidate == .hc02EarlyStart0226 {
            return "Sample \(sample.rawValue) · H37b H-C02 weak 以下提前扣分改從 2/26 開始固定三年候選"
        }
        if candidate == .hc03RemoveOverlap {
            return "Sample \(sample.rawValue) · H38a H-C03 移除 8/1～8/10 重疊加分固定三年候選"
        }
        if candidate == .hc03RemoveLate {
            return "Sample \(sample.rawValue) · H38b H-C03 移除 8/11～8/31 獨立加分固定三年候選"
        }
        if candidate == .hc04RemoveOverlap {
            return "Sample \(sample.rawValue) · H39a H-C04 移除 3/1～3/5 重疊加分固定三年候選"
        }
        if candidate == .hc04RemoveLate {
            return "Sample \(sample.rawValue) · H39b H-C04 移除 3/6～3/31 獨立加分固定三年候選"
        }
        if candidate == .hn01bThreshold17 {
            return "Sample \(sample.rawValue) · H40a H-N01b J Z125 門檻降至 1.7 固定三年候選"
        }
        if candidate == .hn01bThreshold19 {
            return "Sample \(sample.rawValue) · H40b H-N01b J Z125 門檻升至 1.9 固定三年候選"
        }
        if candidate == .hn02aThresholdM09 {
            return "Sample \(sample.rawValue) · H41a H-N02a K Z125 門檻降至 -0.9 固定三年候選"
        }
        if candidate == .hn02aThresholdM07 {
            return "Sample \(sample.rawValue) · H41b H-N02a K Z125 門檻升至 -0.7 固定三年候選"
        }
        if candidate == .hn06RemoveMA20Branch {
            return "Sample \(sample.rawValue) · H42a 移除 H-N06a MA20 第一層扣分固定三年候選"
        }
        if candidate == .hn06RemoveMA60Branch {
            return "Sample \(sample.rawValue) · H42b 移除 H-N06b MA60 第一層扣分固定三年候選"
        }
        if candidate == .lc03RemoveC01Overlap {
            return "Sample \(sample.rawValue) · L10a 移除 L-C03 8/1～8/15 與 L-C01 重疊加分固定三年候選"
        }
        if candidate == .lc03RemoveC02Overlap {
            return "Sample \(sample.rawValue) · L10b 移除 L-C03 8/21～8/31 與 L-C02 重疊加分固定三年候選"
        }
        if candidate == .lc03RemoveC01OverlapFineOrBetter {
            return "Sample \(sample.rawValue) · L11a 僅對 fine 以上移除 L-C03 8/1～8/15 重疊加分固定三年候選"
        }
        if candidate == .lc03RemoveC01OverlapNoneOrBelow {
            return "Sample \(sample.rawValue) · L11b 僅對 none 以下移除 L-C03 8/1～8/15 重疊加分固定三年候選"
        }
        if candidate == .lc03RemoveC01OverlapFineOnly {
            return "Sample \(sample.rawValue) · L12a 僅對 fine 移除 L-C03 8/1～8/15 重疊加分固定三年候選"
        }
        if candidate == .lc03RemoveC01OverlapHighOrBetter {
            return "Sample \(sample.rawValue) · L12b 僅對 high／wow 移除 L-C03 8/1～8/15 重疊加分固定三年候選"
        }
        if candidate == .lc03RemoveMiddle {
            return "Sample \(sample.rawValue) · L13 移除 L-C03 8/16～8/20 獨立加分固定三年候選"
        }
        if candidate == .lc01Remove {
            return "Sample \(sample.rawValue) · L14 移除整條 L-C01 夏季風險扣分固定三年候選"
        }
        if candidate == .lc02Remove {
            return "Sample \(sample.rawValue) · L15 移除整條 L-C02 弱評股八月底加分固定三年候選"
        }
        if candidate == .lp07MA60ThresholdM06 {
            return "Sample \(sample.rawValue) · L16a L-P07 MA60 Z125 門檻放寬至 -0.6 固定三年候選"
        }
        if candidate == .lp07MA60ThresholdM04 {
            return "Sample \(sample.rawValue) · L16b L-P07 MA60 Z125 門檻收緊至 -0.4 固定三年候選"
        }
        if candidate == .lp07MA60ThresholdM10 {
            return "Sample \(sample.rawValue) · L16c L-P07 MA60 Z125 門檻放寬至 -1.0 固定三年候選"
        }
        if candidate == .lp07MA60Threshold00 {
            return "Sample \(sample.rawValue) · L16d L-P07 MA60 Z125 門檻收緊至 0.0 固定三年候選"
        }
        if candidate == .lp09MA60ThresholdM25 {
            return "Sample \(sample.rawValue) · L17a L-P09 MA60 深跌門檻放寬至 -25 固定三年候選"
        }
        if candidate == .lp09MA60ThresholdM35 {
            return "Sample \(sample.rawValue) · L17b L-P09 MA60 深跌門檻收緊至 -35 固定三年候選"
        }
        if candidate == .lp09MA20ThresholdM25 {
            return "Sample \(sample.rawValue) · L18a L-P09 MA20 深跌門檻放寬至 -25 固定三年候選"
        }
        if candidate == .lp09MA20ThresholdM35 {
            return "Sample \(sample.rawValue) · L18b L-P09 MA20 深跌門檻收緊至 -35 固定三年候選"
        }
        if candidate == .lp03KZ125ThresholdM10 {
            return "Sample \(sample.rawValue) · L19a L-P03 K Z125 門檻收緊至 -1.0 固定三年候選"
        }
        if candidate == .lp03KZ125ThresholdM08 {
            return "Sample \(sample.rawValue) · L19b L-P03 K Z125 門檻放寬至 -0.8 固定三年候選"
        }
        if candidate == .lp03KZ250ThresholdM10 {
            return "Sample \(sample.rawValue) · L20a L-P03 K Z250 門檻收緊至 -1.0 固定三年候選"
        }
        if candidate == .lp03KZ250ThresholdM08 {
            return "Sample \(sample.rawValue) · L20b L-P03 K Z250 門檻放寬至 -0.8 固定三年候選"
        }
        if candidate == .lp04DZ125ThresholdM10 {
            return "Sample \(sample.rawValue) · L21a L-P04 D Z125 門檻收緊至 -1.0 固定三年候選"
        }
        if candidate == .lp04DZ125ThresholdM08 {
            return "Sample \(sample.rawValue) · L21b L-P04 D Z125 門檻放寬至 -0.8 固定三年候選"
        }
        if candidate == .lp04DZ250ThresholdM10 {
            return "Sample \(sample.rawValue) · L22a L-P04 D Z250 門檻收緊至 -1.0 固定三年候選"
        }
        if candidate == .lp04DZ250ThresholdM08 {
            return "Sample \(sample.rawValue) · L22b L-P04 D Z250 門檻放寬至 -0.8 固定三年候選"
        }
        if candidate == .lp04DZ250ThresholdM11 {
            return "Sample \(sample.rawValue) · L22c L-P04 D Z250 門檻放大收緊至 -1.1 固定三年候選"
        }
        if candidate == .lp04DZ250ThresholdM07 {
            return "Sample \(sample.rawValue) · L22d L-P04 D Z250 門檻放大放寬至 -0.7 固定三年候選"
        }
        if candidate == .lp05OscZ125ThresholdM10 {
            return "Sample \(sample.rawValue) · L23a L-P05 OSC Z125 門檻收緊至 -1.0 固定三年候選"
        }
        if candidate == .lp05OscZ125ThresholdM08 {
            return "Sample \(sample.rawValue) · L23b L-P05 OSC Z125 門檻放寬至 -0.8 固定三年候選"
        }
        if candidate == .lp05OscZ125ThresholdM11 {
            return "Sample \(sample.rawValue) · L23c L-P05 OSC Z125 門檻放大收緊至 -1.1 固定三年候選"
        }
        if candidate == .lp05OscZ125ThresholdM07 {
            return "Sample \(sample.rawValue) · L23d L-P05 OSC Z125 門檻放大放寬至 -0.7 固定三年候選"
        }
        if candidate == .lp05OscZ250ThresholdM10 {
            return "Sample \(sample.rawValue) · L24a L-P05 OSC Z250 門檻收緊至 -1.0 固定三年候選"
        }
        if candidate == .lp05OscZ250ThresholdM08 {
            return "Sample \(sample.rawValue) · L24b L-P05 OSC Z250 門檻放寬至 -0.8 固定三年候選"
        }
        if candidate == .lp08HighThresholdM13 {
            return "Sample \(sample.rawValue) · L28a L-P08 high／wow 高價位置 Z 門檻收緊至 -1.3 固定三年候選"
        }
        if candidate == .lp08HighThresholdM11 {
            return "Sample \(sample.rawValue) · L28b L-P08 high／wow 高價位置 Z 門檻放寬至 -1.1 固定三年候選"
        }
        if candidate == .lp08HighThresholdM14 {
            return "Sample \(sample.rawValue) · L28c L-P08 high／wow 高價位置 Z 門檻放大收緊至 -1.4 固定三年候選"
        }
        if candidate == .lp08HighThresholdM10 {
            return "Sample \(sample.rawValue) · L28d L-P08 high／wow 高價位置 Z 門檻放大放寬至 -1.0 固定三年候選"
        }
        if candidate == .lp08LowThresholdM16 {
            return "Sample \(sample.rawValue) · L29a L-P08 weak 以下高價位置 Z 門檻收緊至 -1.6 固定三年候選"
        }
        if candidate == .lp08LowThresholdM14 {
            return "Sample \(sample.rawValue) · L29b L-P08 weak 以下高價位置 Z 門檻放寬至 -1.4 固定三年候選"
        }
        if candidate == .lp08MiddleThresholdM145 {
            return "Sample \(sample.rawValue) · L30a L-P08 none／fine 高價位置 Z 門檻收緊至 -1.45 固定三年候選"
        }
        if candidate == .lp08MiddleThresholdM125 {
            return "Sample \(sample.rawValue) · L30b L-P08 none／fine 高價位置 Z 門檻放寬至 -1.25 固定三年候選"
        }
        if candidate == .lp08MiddleThresholdM155 {
            return "Sample \(sample.rawValue) · L30c L-P08 none／fine 高價位置 Z 門檻放大收緊至 -1.55 固定三年候選"
        }
        if candidate == .lp08MiddleThresholdM115 {
            return "Sample \(sample.rawValue) · L30d L-P08 none／fine 高價位置 Z 門檻放大放寬至 -1.15 固定三年候選"
        }
        if candidate == .removeLP08 {
            return "Sample \(sample.rawValue) · L31 完整移除 L-P08 現代重驗固定三年候選"
        }
        if candidate == .ln01MA20DaysThresholdM18 {
            return "Sample \(sample.rawValue) · L25a L-N01 MA20 長期下彎門檻放寬至 -18 日固定三年候選"
        }
        if candidate == .ln01MA20DaysThresholdM22 {
            return "Sample \(sample.rawValue) · L25b L-N01 MA20 長期下彎門檻收緊至 -22 日固定三年候選"
        }
        if candidate == .ln02DamnOnly {
            return "Sample \(sample.rawValue) · L27a L-N02 移除 wow 分支、只保留 damn 固定三年候選"
        }
        if candidate == .ln02WowOnly {
            return "Sample \(sample.rawValue) · L27b L-N02 移除 damn 分支、只保留 wow 固定三年候選"
        }
        if candidate == .lt01WantThreshold4 {
            return "Sample \(sample.rawValue) · L26a L-T01 承低總分門檻放寬至 4 固定三年候選"
        }
        if candidate == .lt01WantThreshold6 {
            return "Sample \(sample.rawValue) · L26b L-T01 承低總分門檻收緊至 6 固定三年候選"
        }
        if candidate == .lt01FineOrBetterThreshold6 {
            return "Sample \(sample.rawValue) · L26c L-T01 fine 以上門檻 6、其餘 5 固定三年候選"
        }
        if candidate == .lt01HighOrBetterThreshold6 {
            return "Sample \(sample.rawValue) · L26d L-T01 high 以上門檻 6、其餘 5 固定三年候選"
        }
        if candidate == .lt01WowThreshold6 {
            return "Sample \(sample.rawValue) · L26e L-T01 僅 wow 門檻 6、其餘 5 固定三年候選"
        }
        if candidate == .sp06RemoveABranch {
            return "Sample \(sample.rawValue) · S15a 移除 S-P06a 高低價位置分支固定三年候選"
        }
        if candidate == .sp06RemoveBBranch {
            return "Sample \(sample.rawValue) · S15b 移除 S-P06b 整體股價位置分支固定三年候選"
        }
        if candidate == .sp06aUpperLowThreshold06 {
            return "Sample \(sample.rawValue) · S26a S-P06a high／wow 低價位置 Z 門檻放寬至 0.6 固定三年候選"
        }
        if candidate == .sp06aUpperLowThreshold10 {
            return "Sample \(sample.rawValue) · S26b S-P06a high／wow 低價位置 Z 門檻收緊至 1.0 固定三年候選"
        }
        if candidate == .sp06aUpperHighThresholdM02 {
            return "Sample \(sample.rawValue) · S27a S-P06a high／wow 高價位置 Z 門檻放寬至 -0.2 固定三年候選"
        }
        if candidate == .sp06aUpperHighThresholdP02 {
            return "Sample \(sample.rawValue) · S27b S-P06a high／wow 高價位置 Z 門檻收緊至 0.2 固定三年候選"
        }
        if candidate == .sp06aUpperHighThresholdM04 {
            return "Sample \(sample.rawValue) · S27c S-P06a high／wow 高價位置 Z 門檻放寬至 -0.4 固定三年候選"
        }
        if candidate == .sp06aUpperHighThresholdP04 {
            return "Sample \(sample.rawValue) · S27d S-P06a high／wow 高價位置 Z 門檻收緊至 0.4 固定三年候選"
        }
        if candidate == .sp06bLowerThreshold10 {
            return "Sample \(sample.rawValue) · S28a S-P06b weak／low／damn 整體股價位置 Z 門檻放寬至 1.0 固定三年候選"
        }
        if candidate == .sp06bLowerThreshold14 {
            return "Sample \(sample.rawValue) · S28b S-P06b weak／low／damn 整體股價位置 Z 門檻收緊至 1.4 固定三年候選"
        }
        if candidate == .sp06bLowerThreshold08 {
            return "Sample \(sample.rawValue) · S28c S-P06b weak／low／damn 整體股價位置 Z 門檻放寬至 0.8 固定三年候選"
        }
        if candidate == .sp06bLowerThreshold16 {
            return "Sample \(sample.rawValue) · S28d S-P06b weak／low／damn 整體股價位置 Z 門檻收緊至 1.6 固定三年候選"
        }
        if candidate == .sn01RemoveABranch {
            return "Sample \(sample.rawValue) · S16a 移除 S-N01a MA60 九日低點分支固定三年候選"
        }
        if candidate == .sn01RemoveBBranch {
            return "Sample \(sample.rawValue) · S16b 移除 S-N01b MA20 九日低點分支固定三年候選"
        }
        if candidate == .st02bRangeThreshold25 {
            return "Sample \(sample.rawValue) · S29a S-T02b 半年高低幅門檻收窄至 25 固定三年候選"
        }
        if candidate == .st02bRangeThreshold35 {
            return "Sample \(sample.rawValue) · S29b S-T02b 半年高低幅門檻放寬至 35 固定三年候選"
        }
        if candidate == .removeAP01a {
            return "Sample \(sample.rawValue) · A20 移除 A-P01a 多項技術低檔加分固定三年候選"
        }
        if candidate == .removeAP01b {
            return "Sample \(sample.rawValue) · A21 移除 A-P01b 弱評保留加分固定三年候選"
        }
        if candidate == .ap01bLowBoundary {
            return isFullWindowStress
                ? "Sample \(sample.rawValue) · A21b A-P01b 收緊至 low 以下全期間壓力測試"
                : "Sample \(sample.rawValue) · A21b A-P01b 收緊至 low 以下固定三年候選"
        }
        if candidate == .ap02WowMinimum2 {
            return "Sample \(sample.rawValue) · A11a A-P02 wow 九日低點項目門檻放寬至 2 固定三年候選"
        }
        if candidate == .ap02WowMinimum4 {
            return "Sample \(sample.rawValue) · A11b A-P02 wow 九日低點項目門檻收緊至 4 固定三年候選"
        }
        if candidate == .ap05DiffThresholdM175 {
            return "Sample \(sample.rawValue) · A12a A-P05 均線深跌門檻放寬至 -17.5 固定三年候選"
        }
        if candidate == .ap05DiffThresholdM225 {
            return "Sample \(sample.rawValue) · A12b A-P05 均線深跌門檻收緊至 -22.5 固定三年候選"
        }
        if candidate == .ap06MA20ZThresholdM23 {
            return "Sample \(sample.rawValue) · A13a A-P06 MA20 半年 Z 門檻放寬至 -2.3 固定三年候選"
        }
        if candidate == .ap06MA20ZThresholdM27 {
            return "Sample \(sample.rawValue) · A13b A-P06 MA20 半年 Z 門檻收緊至 -2.7 固定三年候選"
        }
        if candidate == .ap06MA20ZThresholdM21 {
            return "Sample \(sample.rawValue) · A13c A-P06 MA20 半年 Z 門檻放寬至 -2.1 固定三年候選"
        }
        if candidate == .ap06MA20ZThresholdM29 {
            return "Sample \(sample.rawValue) · A13d A-P06 MA20 半年 Z 門檻收緊至 -2.9 固定三年候選"
        }
        if candidate == .ap06MA60ZThresholdM26 {
            return "Sample \(sample.rawValue) · A24a A-P06 MA60 半年 Z 門檻放寬至 -2.6 固定三年候選"
        }
        if candidate == .ap06MA60ZThresholdM30 {
            return "Sample \(sample.rawValue) · A24b A-P06 MA60 半年 Z 門檻收緊至 -3.0 固定三年候選"
        }
        if candidate == .gradeActivationRounds1 {
            return "Sample \(sample.rawValue) · GT02a G-T01 完成輪次啟用門檻放寬至 >1 固定三年候選"
        }
        if candidate == .gradeActivationRounds3 {
            return "Sample \(sample.rawValue) · GT02b G-T01 完成輪次啟用門檻收緊至 >3 固定三年候選"
        }
        if candidate == .gradeActivationDays300 {
            return "Sample \(sample.rawValue) · GT03a G-T01 平均持股週期啟用門檻放寬至 >300 日固定三年候選"
        }
        if candidate == .gradeActivationDays420 {
            return "Sample \(sample.rawValue) · GT03b G-T01 平均持股週期啟用門檻收緊至 >420 日固定三年候選"
        }
        if candidate == .gradeActivationExtremeNegative69 {
            return "Sample \(sample.rawValue) · GT04a G-T01 至少一輪且效率分數低於 -69 時提早啟用 Grade 固定三年候選"
        }
        if candidate == .ht01WantThresholdM1 {
            return "Sample \(sample.rawValue) · H45a H-T01 追高分數門檻放寬至 -1 固定三年候選"
        }
        if candidate == .ht01WantThreshold1 {
            return "Sample \(sample.rawValue) · H45b H-T01 追高分數門檻收緊至 1 固定三年候選"
        }
        if candidate == .ht01WeakOrBelowThreshold1 {
            return "Sample \(sample.rawValue) · H46a H-T01 weak 以下追高分數門檻收緊至 1 固定三年候選"
        }
        if candidate == .ht01LowOnlyThreshold1 {
            return "Sample \(sample.rawValue) · H46b H-T01 僅 low 追高分數門檻收緊至 1 \(isFullWindowStress ? "全期間壓力測試" : "固定三年候選")"
        }
        if candidate == .ap07MA20DiffThresholdM7 {
            return "Sample \(sample.rawValue) · A14a A-P07 MA20 差值門檻放寬至 -7 固定三年候選"
        }
        if candidate == .ap07MA20DiffThresholdM9 {
            return "Sample \(sample.rawValue) · A14b A-P07 MA20 差值門檻收緊至 -9 固定三年候選"
        }
        if candidate == .ap07MA20DiffThresholdM6 {
            return "Sample \(sample.rawValue) · A14c A-P07 MA20 差值門檻放寬至 -6 固定三年候選"
        }
        if candidate == .ap07MA20DiffThresholdM10 {
            return "Sample \(sample.rawValue) · A14d A-P07 MA20 差值門檻收緊至 -10 固定三年候選"
        }
        if candidate == .at01WantThreshold2 {
            return "Sample \(sample.rawValue) · A15a A-T01 加碼分數門檻放寬至 2 固定三年候選"
        }
        if candidate == .at01WantThreshold4 {
            return "Sample \(sample.rawValue) · A15b A-T01 加碼分數門檻收緊至 4 固定三年候選"
        }
        if candidate == .at01WantThreshold1 {
            return "Sample \(sample.rawValue) · A15c A-T01 加碼分數門檻放寬至 1 固定三年候選"
        }
        if candidate == .at01WantThreshold5 {
            return "Sample \(sample.rawValue) · A15d A-T01 加碼分數門檻收緊至 5 固定三年候選"
        }
        if candidate == .at01ROIThresholdM275 {
            return "Sample \(sample.rawValue) · A23a A-T01 深虧 ROI 門檻放寬至 -27.5% 固定三年候選"
        }
        if candidate == .at01ROIThresholdM325 {
            return "Sample \(sample.rawValue) · A23b A-T01 深虧 ROI 門檻收緊至 -32.5% 固定三年候選"
        }
        if candidate == .at01ROIThresholdM3125 {
            return "Sample \(sample.rawValue) · A23c A-T01 深虧 ROI 門檻收緊至 -31.25% 固定三年候選"
        }
        if candidate == .at01ROIThresholdM35 {
            return "Sample \(sample.rawValue) · A23d A-T01 深虧 ROI 門檻收緊至 -35% 固定三年候選"
        }
        if candidate == .at01Wow35Other325 {
            return "Sample \(sample.rawValue) · A23e A-T01 wow 用 -35%、其他 Grade 用 -32.5% 固定三年候選"
        }
        if candidate == .at01Wow35Middle325Low30 {
            return "Sample \(sample.rawValue) · A23f A-T01 wow 用 -35%、high／fine／none 用 -32.5%、weak 以下用 -30% \(isFullWindowStress ? "全期間壓力測試" : "固定三年候選")"
        }
        if candidate == .at01Upper325Low30 {
            return "Sample \(sample.rawValue) · A23g A-T01 none 以上用 -32.5%、weak 以下用 -30% \(isFullWindowStress ? "全期間壓力測試" : "固定三年候選")"
        }
        if candidate == .ae01CooldownDays30 {
            return "Sample \(sample.rawValue) · A16a A-E01 一般加碼冷卻縮短至 30 日固定三年候選"
        }
        if candidate == .ae01CooldownDays60 {
            return "Sample \(sample.rawValue) · A16b A-E01 一般加碼冷卻延長至 60 日固定三年候選"
        }
        if candidate == .ae01CooldownDays15 {
            return "Sample \(sample.rawValue) · A16c A-E01 一般加碼冷卻縮短至 15 日固定三年候選"
        }
        if candidate == .ae01CooldownDays75 {
            return "Sample \(sample.rawValue) · A16d A-E01 一般加碼冷卻延長至 75 日固定三年候選"
        }
        if candidate == .ae01CooldownDays38 {
            return "Sample \(sample.rawValue) · A16e A-E01 一般加碼冷卻縮短至 38 日固定三年候選"
        }
        if candidate == .ae03Limit1 {
            return "Sample \(sample.rawValue) · A17a A-E03 一般自動加碼上限降至 1 次固定三年候選"
        }
        if candidate == .ae03Limit3 {
            return "Sample \(sample.rawValue) · A17b A-E03 一般自動加碼上限增至 3 次固定三年候選"
        }
        if candidate == .ae04ROIThresholdM45 {
            return "Sample \(sample.rawValue) · A22a A-E04 極深虧損全豁免門檻放寬至 -45% 固定三年候選"
        }
        if candidate == .ae04ROIThresholdM55 {
            return "Sample \(sample.rawValue) · A22b A-E04 極深虧損全豁免門檻收緊至 -55% 固定三年候選"
        }
        if candidate == .removeAE02 {
            return "Sample \(sample.rawValue) · A18 移除 A-E02 好評深跌冷卻豁免固定三年候選"
        }
        if candidate == .removeAN02 {
            return "Sample \(sample.rawValue) · A19 移除 A-N02 低評反彈離低點扣分固定三年候選"
        }
        if candidate == .st02RemoveBBranch {
            return "Sample \(sample.rawValue) · S17a 移除 S-T02b 久套低波動出口固定三年候選"
        }
        if candidate == .st02RemoveCBranch {
            return "Sample \(sample.rawValue) · S17b 移除 S-T02c 400 日解套出口固定三年候選"
        }
        if candidate == .st02RemoveScoreGate {
            return "Sample \(sample.rawValue) · S18 移除 S-T02a 賣出分數門檻固定三年候選"
        }
        if candidate == .st01aROI20 {
            return "Sample \(sample.rawValue) · S19a S-T01a 高報酬門檻 20% 固定三年候選"
        }
        if candidate == .st01aROI25 {
            return "Sample \(sample.rawValue) · S19b S-T01a 高報酬門檻 25% 固定三年候選"
        }
        if candidate == .st01aHighScoreM1 {
            return "Sample \(sample.rawValue) · S20a S-T01a high／wow 零分即可高報酬退出固定三年候選"
        }
        if candidate == .st01aHighScore1 {
            return "Sample \(sample.rawValue) · S20b S-T01a high／wow 至少兩分才高報酬退出固定三年候選"
        }
        if candidate == .st01aGeneralScore0 {
            return "Sample \(sample.rawValue) · S21a S-T01a 低於 high 至少一分即可高報酬退出固定三年候選"
        }
        if candidate == .st01aGeneralScore2 {
            return "Sample \(sample.rawValue) · S21b S-T01a 低於 high 至少三分才高報酬退出固定三年候選"
        }
        if candidate == .st01aEdgeScore {
            return "Sample \(sample.rawValue) · S21c S-T01a 兩端 Grade 分數門檻交互固定三年候選"
        }
        if candidate == .st01cScore4 {
            return isFullWindowStress
                ? "Sample \(sample.rawValue) · S22a S-T01c 賣出分數放寬至至少四分全期間壓力測試"
                : "Sample \(sample.rawValue) · S22a S-T01c 賣出分數放寬至至少四分固定三年候選"
        }
        if candidate == .st01cScore6 {
            return "Sample \(sample.rawValue) · S22b S-T01c 賣出分數收緊至至少六分固定三年候選"
        }
        if candidate == .st01cLowROI10 {
            return "Sample \(sample.rawValue) · S23a S-T01c weak 以下 ROI 門檻放寬至 1.0% 固定三年候選"
        }
        if candidate == .st01cLowROI20 {
            return "Sample \(sample.rawValue) · S23b S-T01c weak 以下 ROI 門檻收緊至 2.0% 固定三年候選"
        }
        if candidate == .st01cOtherROI20 {
            return "Sample \(sample.rawValue) · S24a S-T01c none 以上 ROI 門檻放寬至 2.0% 固定三年候選"
        }
        if candidate == .st01cOtherROI225 {
            return "Sample \(sample.rawValue) · S24c S-T01c none 以上 ROI 門檻放寬至 2.25% 固定三年邊界候選"
        }
        if candidate == .st01cOtherROI30 {
            return "Sample \(sample.rawValue) · S24b S-T01c none 以上 ROI 門檻收緊至 3.0% 固定三年候選"
        }
        if candidate == .st01cWeakOrBetterROI20 {
            return "Sample \(sample.rawValue) · S24d S-T01c weak 以上 ROI 門檻 2.0%、low 以下 1.5% 固定三年候選"
        }
        if candidate == .st01cGradeTieredROI {
            return "Sample \(sample.rawValue) · S24e S-T01c high 以上 2.5%、weak 至 fine 2.0%、low 以下 1.5% 固定三年候選"
        }
        if candidate == .st01cWow25Weak20 {
            return "Sample \(sample.rawValue) · S24f S-T01c wow 2.5%、weak 至 high 2.0%、low 以下 1.5% 固定三年候選"
        }
        if candidate == .st01cWow25Weak15 {
            return "Sample \(sample.rawValue) · S24g S-T01c wow 2.5%、none 至 high 2.0%、weak 以下 1.5% 固定三年候選"
        }
        if candidate == .st01cMiddle225Wow20 {
            return "Sample \(sample.rawValue) · S24h S-T01c wow 2.0%、none 至 high 2.25%、weak 以下 1.5% 固定三年候選"
        }
        if candidate == .st01cMiddle20Wow225 {
            return "Sample \(sample.rawValue) · S24i S-T01c wow 2.25%、none 至 high 2.0%、weak 以下 1.5% 固定三年候選"
        }
        if candidate == .st01eDays60 {
            return "Sample \(sample.rawValue) · S25a S-T01e 長期小幅獲利退出提前至 60 日固定三年候選"
        }
        if candidate == .st01eDays68 {
            return isFullWindowStress
                ? "Sample \(sample.rawValue) · S25d S-T01e 長期小幅獲利退出提前至 68 日全期間壓力測試"
                : "Sample \(sample.rawValue) · S25c S-T01e 長期小幅獲利退出提前至 68 日固定三年候選"
        }
        if candidate == .st01eDays90 {
            return "Sample \(sample.rawValue) · S25b S-T01e 長期小幅獲利退出延後至 90 日固定三年候選"
        }
        if candidate == .an01PenaltyM1 {
            return isFullWindowStress
                ? "Sample \(sample.rawValue) · A10a A-N01 扣分放寬至 -1 全期間壓力測試"
                : "Sample \(sample.rawValue) · A10a A-N01 扣分放寬至 -1 固定三年候選"
        }
        if candidate == .an01PenaltyM3 {
            return "Sample \(sample.rawValue) · A10b A-N01 扣分收緊至 -3 固定三年候選"
        }
        if candidate == .an01Control {
            return "Sample \(sample.rawValue) · A10 A-N01 正式 -2 控制組"
        }
        if candidate == .an01FineBoundary {
            return "Sample \(sample.rawValue) · A10c A-N01 改由 fine 以上扣 2 分固定三年候選"
        }
        if candidate == .an01FinePenaltyM1 {
            return "Sample \(sample.rawValue) · A10f A-N01 none 扣 2 分、fine 以上扣 1 分固定三年候選"
        }
        if candidate == .an01FinePenaltyM1NoNone {
            return "Sample \(sample.rawValue) · A10g A-N01 none 以下不扣分、fine 以上扣 1 分固定三年候選"
        }
        if candidate == .an01FinePenaltyM1LowBelowM1 {
            return "Sample \(sample.rawValue) · A10h A-N01 low 以下與 fine 以上扣 1 分的 U 型固定三年候選"
        }
        if candidate == .an01FinePenaltyM1LowBelowP1 {
            return "Sample \(sample.rawValue) · A10i A-N01 low 以下加 1 分、fine 以上扣 1 分固定三年候選"
        }
        if candidate == .an01FinePenaltyM3 {
            return "Sample \(sample.rawValue) · A10d A-N01 none 扣 2 分、fine 以上扣 3 分固定三年候選"
        }
        if candidate == .an01HighPenaltyM3 {
            return "Sample \(sample.rawValue) · A10e A-N01 none／fine 扣 2 分、high 以上扣 3 分固定三年候選"
        }
        if sample == .b {
            return isFullWindowStress
                ? "Sample B · S17 A-P08 wow 早期邊界保護全期間 Baseline"
                : "Sample B · S17 A-P08 wow 早期邊界保護固定三年 Baseline"
        }
        if isFullWindowStress {
            return "Sample A · S17 A-P08 wow 早期邊界保護全期間 Baseline"
        }
        return "Sample A · S17 A-P08 wow 早期邊界保護固定三年 Baseline"
    }()
    static let moneyBaseWan = 600.0
    static let automaticInvestments = 2.0
    static let baselineRuleVersion = "s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901"
    static let baselineRuleChangeSummary =
        "新增 A-N03 加碼扣分：交易當日 Grade 為 exact wow、適配趨勢已暖機、尚未進入惡化確認探底，且 A-P02 多項九日低點票未成立時，加碼總分扣 1 分。既有 A-P02 與其他 H／L 買入、賣出、加碼、Grade 及趨勢規則不變。"
    static let currentRuleChangeSummary: String = {
        if isNineYearABProfile && candidate == .baseline {
            return baselineRuleChangeSummary + " 技術規則維持 T2，模擬資料規則推進至 S39；股票、技術輸入、窗口、資金與加碼設定維持不變。"
        }
        if candidate == .baseline {
            return baselineRuleChangeSummary
        }
        return "候選唯一變因：\(reportTitle)"
    }()
    static let currentRuleVersion: String = {
        if isNineYearABProfile && candidate == .lc03RemoveMiddle {
            return "s18-candidate-lc03-remove-middle"
        }
        switch candidate {
        case .baseline: return baselineRuleVersion
        case .marketVoteNever, .marketVotePulseH, .marketVotePulseL,
             .marketVotePulseS, .marketVotePulseA:
            return "s32-research-mkt-r02-q0"
        case .gwS01: return "s18-candidate-gw-s01"
        case .gwS01b: return "s18-candidate-gw-s01b"
        case .gwA01: return "s18-candidate-gw-a01"
        case .gwA02: return "s18-candidate-gw-a02"
        case .gwA02b: return "s18-candidate-gw-a02b"
        case .gwS02: return "s18-candidate-gw-s02"
        case .removeST01g: return "s6-candidate-remove-st01g"
        case .investCooldown45: return "s6-candidate-invest-cooldown45"
        case .noInvestCooldown: return "s6-candidate-no-invest-cooldown"
        case .removeGradeActivationGate: return "s6-candidate-remove-grade-activation-gate"
        case .gradeActivationRounds1: return "s15-candidate-grade-activation-rounds1"
        case .gradeActivationRounds3: return "s15-candidate-grade-activation-rounds3"
        case .gradeActivationDays300: return "s15-candidate-grade-activation-days300"
        case .gradeActivationDays420: return "s15-candidate-grade-activation-days420"
        case .gradeActivationExtremeNegative69:
            return "s15-candidate-grade-activation-extreme-negative-m69"
        case .ht01WantThresholdM1: return "s15-candidate-ht01-want-threshold-m1"
        case .ht01WantThreshold1: return "s15-candidate-ht01-want-threshold-1"
        case .ht01WeakOrBelowThreshold1:
            return "s15-candidate-ht01-weak-or-below-threshold-1"
        case .ht01LowOnlyThreshold1:
            return "s15-candidate-ht01-low-only-threshold-1"
        case .removeGradeWow: return "s6-candidate-remove-grade-wow"
        case .removeGradeHigh: return "s6-candidate-remove-grade-high"
        case .removeGradeFine: return "s6-candidate-remove-grade-fine"
        case .removeGradeDamn: return "s6-candidate-remove-grade-damn"
        case .removeGradeLow: return "s6-candidate-remove-grade-low"
        case .removeGradeWeak: return "s6-candidate-remove-grade-weak"
        case .neutralGradeMapping: return "s6-candidate-neutral-grade-mapping"
        case .scoreBasedGrade: return "s6-candidate-score-based-grade"
        case .scoreBasedGradeSellCompatibility:
            return "s6-candidate-score-grade-s-compatibility"
        case .scoreBasedGradeAllCompatibility:
            return "s6-candidate-score-grade-all-compatibility"
        case .scoreBasedGradeUpperCompatibility:
            return "s6-candidate-score-grade-upper-compatibility"
        case .scoreBasedGradeCalibratedBands:
            return "s6-candidate-score-grade-calibrated-bands"
        case .scoreBasedGradeCalibratedAllBands:
            return "s6-candidate-score-grade-calibrated-all-bands"
        case .scoreBasedGradeNeutralBand:
            return "s6-candidate-score-grade-neutral-band"
        case .scoreBasedGradeWeakUsesNeutralMapping:
            return "s6-candidate-score-grade-weak-neutral-mapping"
        case .scoreGradeFine18:
            return "s7-candidate-score-grade-fine18"
        case .removeHN06:
            return "s7-candidate-remove-hn06"
        case .removeHN02b:
            return "s7-candidate-remove-hn02b"
        case .removeHN01a:
            return "s7-candidate-remove-hn01a"
        case .hn09Strict:
            return "s7-candidate-hn09-strict-m01"
        case .hn09Loose:
            return "s7-candidate-hn09-loose-p01"
        case .hn09LowGradeHighStrict:
            return "s7-candidate-hn09-low-grade-high03"
        case .hn09LowGradeHighLoose:
            return "s7-candidate-hn09-low-grade-high05"
        case .hn09LowGradeHigh06:
            return "s7-candidate-hn09-low-grade-high06"
        case .hn09LowGradeHigh08:
            return "s7-candidate-hn09-low-grade-high08"
        case .hn09LowGradeHigh10:
            return "s7-candidate-hn09-low-grade-high10"
        case .hn09LowGradeHigh12:
            return "s7-candidate-hn09-low-grade-high12"
        case .hn09High081313:
            return "s7-candidate-hn09-high-081313"
        case .hn09High081315:
            return "s7-candidate-hn09-high-081315"
        case .hn09High081520:
            return "s7-candidate-hn09-high-081520"
        case .hn09High081515:
            return "s7-candidate-hn09-high-081515"
        case .hn09Low081215:
            return "s7-candidate-hn09-low-081215"
        case .hn09HighOnly:
            return "s7-candidate-hn09-high-only"
        case .hn09Low051218:
            return "s7-candidate-hn09-low-051218"
        case .hn03ThresholdM07:
            return "s7-candidate-hn03-m07"
        case .hn03ThresholdM03:
            return "s7-candidate-hn03-m03"
        case .hp01LowerLoose:
            return "s8-candidate-hp01-lower-loose"
        case .hp01LowerStrict:
            return "s8-candidate-hp01-lower-strict"
        case .hp01LowUpper19:
            return "s8-candidate-hp01-low-upper19"
        case .hp01LowUpper21:
            return "s8-candidate-hp01-low-upper21"
        case .hp01LowUpper15:
            return "s8-candidate-hp01-low-upper15"
        case .hp01LowUpper25:
            return "s8-candidate-hp01-low-upper25"
        case .hp01OtherUpper24:
            return "s8-candidate-hp01-other-upper24"
        case .hp01OtherUpper26:
            return "s8-candidate-hp01-other-upper26"
        case .hp01OtherUpper20:
            return "s8-candidate-hp01-other-upper20"
        case .hp01OtherUpper30:
            return "s8-candidate-hp01-other-upper30"
        case .hp04WeakThreshold19:
            return "s8-candidate-hp04-weak-threshold19"
        case .hp04WeakThreshold21:
            return "s8-candidate-hp04-weak-threshold21"
        case .hp04WeakThreshold15:
            return "s8-candidate-hp04-weak-threshold15"
        case .hp04WeakThreshold25:
            return "s8-candidate-hp04-weak-threshold25"
        case .hp03LowBoundaryLow:
            return "s8-candidate-hp03-low-boundary-low"
        case .hp03LowBoundaryFine:
            return "s8-candidate-hp03-low-boundary-fine"
        case .hp03OtherThresholdM025:
            return "s9-candidate-hp03-other-threshold-m025"
        case .hp03OtherThresholdP025:
            return "s9-candidate-hp03-other-threshold-p025"
        case .hp03OtherThresholdM05:
            return "s9-candidate-hp03-other-threshold-m05"
        case .hp03OtherThresholdP05:
            return "s9-candidate-hp03-other-threshold-p05"
        case .hp03RatedThresholdM025:
            return "s9-candidate-hp03-rated-threshold-m025"
        case .hp03RatedThresholdP025:
            return "s9-candidate-hp03-rated-threshold-p025"
        case .hp03RatedThresholdM05:
            return "s9-candidate-hp03-rated-threshold-m05"
        case .hp03RatedThresholdP05:
            return "s9-candidate-hp03-rated-threshold-p05"
        case .hp03LowerThresholdM075:
            return "s9-candidate-hp03-lower-threshold-m075"
        case .hp03LowerThresholdM025:
            return "s9-candidate-hp03-lower-threshold-m025"
        case .hp03LowerThresholdM10:
            return "s9-candidate-hp03-lower-threshold-m10"
        case .hp03LowerThreshold00:
            return "s9-candidate-hp03-lower-threshold-00"
        case .hn01aGradeWeakOrBelow:
            return "s8-candidate-hn01a-grade-weak-or-below"
        case .hn01aGradeBelowWow:
            return "s8-candidate-hn01a-grade-below-wow"
        case .hn02bHighBoundaryLow:
            return "s8-candidate-hn02b-high-boundary-low"
        case .hn02bHighBoundaryFine:
            return "s8-candidate-hn02b-high-boundary-fine"
        case .hn05GradeWeakOrBetter:
            return "s8-candidate-hn05-grade-weak-or-better"
        case .hn05GradeAll:
            return "s8-candidate-hn05-grade-all"
        case .hn08Threshold15:
            return "s8-candidate-hn08-threshold15"
        case .hn08Threshold17:
            return "s8-candidate-hn08-threshold17"
        case .hn08Threshold12:
            return "s8-candidate-hn08-threshold12"
        case .hn08Threshold20:
            return "s8-candidate-hn08-threshold20"
        case .hn06GradeBoundaryLow:
            return "s8-candidate-hn06-grade-boundary-low"
        case .hn06GradeBoundaryFine:
            return "s8-candidate-hn06-grade-boundary-fine"
        case .hn06MA20Threshold55:
            return "s8-candidate-hn06-ma20-threshold55"
        case .hn06MA20Threshold65:
            return "s8-candidate-hn06-ma20-threshold65"
        case .hn06MA60Threshold65:
            return "s8-candidate-hn06-ma60-threshold65"
        case .hn06MA60Threshold75:
            return "s8-candidate-hn06-ma60-threshold75"
        case .hn07MA20Threshold55:
            return "s8-candidate-hn07-ma20-threshold55"
        case .hn07MA20Threshold65:
            return "s8-candidate-hn07-ma20-threshold65"
        case .hc01GradeBoundaryLow:
            return "s8-candidate-hc01-grade-boundary-low"
        case .hc01GradeBoundaryFine:
            return "s8-candidate-hc01-grade-boundary-fine"
        case .hc02GradeBoundaryLow:
            return "s8-candidate-hc02-grade-boundary-low"
        case .hc02GradeBoundaryFine:
            return "s8-candidate-hc02-grade-boundary-fine"
        case .hc02EarlyStart0216:
            return "s8-candidate-hc02-early-start-0216"
        case .hc02EarlyStart0226:
            return "s8-candidate-hc02-early-start-0226"
        case .hc03RemoveOverlap:
            return "s8-candidate-hc03-remove-overlap"
        case .hc03RemoveLate:
            return "s8-candidate-hc03-remove-late"
        case .hc04RemoveOverlap:
            return "s8-candidate-hc04-remove-overlap"
        case .hc04RemoveLate:
            return "s8-candidate-hc04-remove-late"
        case .hn01bThreshold17:
            return "s8-candidate-hn01b-threshold17"
        case .hn01bThreshold19:
            return "s8-candidate-hn01b-threshold19"
        case .hn02aThresholdM09:
            return "s8-candidate-hn02a-threshold-m09"
        case .hn02aThresholdM07:
            return "s8-candidate-hn02a-threshold-m07"
        case .hn06RemoveMA20Branch:
            return "s8-candidate-hn06-remove-ma20-branch"
        case .hn06RemoveMA60Branch:
            return "s8-candidate-hn06-remove-ma60-branch"
        case .lc03RemoveC01Overlap:
            return "s8-candidate-lc03-remove-c01-overlap"
        case .lc03RemoveC02Overlap:
            return "s8-candidate-lc03-remove-c02-overlap"
        case .lc03RemoveC01OverlapFineOrBetter:
            return "s8-candidate-lc03-remove-c01-overlap-fine-or-better"
        case .lc03RemoveC01OverlapNoneOrBelow:
            return "s8-candidate-lc03-remove-c01-overlap-none-or-below"
        case .lc03RemoveC01OverlapFineOnly:
            return "s8-candidate-lc03-remove-c01-overlap-fine-only"
        case .lc03RemoveC01OverlapHighOrBetter:
            return "s8-candidate-lc03-remove-c01-overlap-high-or-better"
        case .lc03RemoveMiddle:
            return "s8-candidate-lc03-remove-middle"
        case .lc01Remove:
            return "s8-candidate-lc01-remove"
        case .lc02Remove:
            return "s8-candidate-lc02-remove"
        case .lp07MA60ThresholdM06:
            return "s8-candidate-lp07-ma60-threshold-m06"
        case .lp07MA60ThresholdM04:
            return "s8-candidate-lp07-ma60-threshold-m04"
        case .lp07MA60ThresholdM10:
            return "s8-candidate-lp07-ma60-threshold-m10"
        case .lp07MA60Threshold00:
            return "s8-candidate-lp07-ma60-threshold-00"
        case .lp09MA60ThresholdM25:
            return "s8-candidate-lp09-ma60-threshold-m25"
        case .lp09MA60ThresholdM35:
            return "s8-candidate-lp09-ma60-threshold-m35"
        case .lp09MA20ThresholdM25:
            return "s8-candidate-lp09-ma20-threshold-m25"
        case .lp09MA20ThresholdM35:
            return "s8-candidate-lp09-ma20-threshold-m35"
        case .lp03KZ125ThresholdM10:
            return "s16-candidate-lp03-k-z125-threshold-m10"
        case .lp03KZ125ThresholdM08:
            return "s16-candidate-lp03-k-z125-threshold-m08"
        case .lp03KZ250ThresholdM10:
            return "s16-candidate-lp03-k-z250-threshold-m10"
        case .lp03KZ250ThresholdM08:
            return "s16-candidate-lp03-k-z250-threshold-m08"
        case .lp04DZ125ThresholdM10:
            return "s16-candidate-lp04-d-z125-threshold-m10"
        case .lp04DZ125ThresholdM08:
            return "s16-candidate-lp04-d-z125-threshold-m08"
        case .lp04DZ250ThresholdM10:
            return "s16-candidate-lp04-d-z250-threshold-m10"
        case .lp04DZ250ThresholdM08:
            return "s16-candidate-lp04-d-z250-threshold-m08"
        case .lp04DZ250ThresholdM11:
            return "s16-candidate-lp04-d-z250-threshold-m11"
        case .lp04DZ250ThresholdM07:
            return "s16-candidate-lp04-d-z250-threshold-m07"
        case .lp05OscZ125ThresholdM10:
            return "s16-candidate-lp05-osc-z125-threshold-m10"
        case .lp05OscZ125ThresholdM08:
            return "s16-candidate-lp05-osc-z125-threshold-m08"
        case .lp05OscZ125ThresholdM11:
            return "s16-candidate-lp05-osc-z125-threshold-m11"
        case .lp05OscZ125ThresholdM07:
            return "s16-candidate-lp05-osc-z125-threshold-m07"
        case .lp05OscZ250ThresholdM10:
            return "s16-candidate-lp05-osc-z250-threshold-m10"
        case .lp05OscZ250ThresholdM08:
            return "s16-candidate-lp05-osc-z250-threshold-m08"
        case .lp08HighThresholdM13:
            return "s17-candidate-lp08-high-threshold-m13"
        case .lp08HighThresholdM11:
            return "s17-candidate-lp08-high-threshold-m11"
        case .lp08HighThresholdM14:
            return "s17-candidate-lp08-high-threshold-m14"
        case .lp08HighThresholdM10:
            return "s17-candidate-lp08-high-threshold-m10"
        case .lp08LowThresholdM16:
            return "s17-candidate-lp08-low-threshold-m16"
        case .lp08LowThresholdM14:
            return "s17-candidate-lp08-low-threshold-m14"
        case .lp08MiddleThresholdM145:
            return "s17-candidate-lp08-middle-threshold-m145"
        case .lp08MiddleThresholdM125:
            return "s17-candidate-lp08-middle-threshold-m125"
        case .lp08MiddleThresholdM155:
            return "s17-candidate-lp08-middle-threshold-m155"
        case .lp08MiddleThresholdM115:
            return "s17-candidate-lp08-middle-threshold-m115"
        case .removeLP08:
            return "s17-candidate-remove-lp08"
        case .ln01MA20DaysThresholdM18:
            return "s16-candidate-ln01-ma20-days-threshold-m18"
        case .ln01MA20DaysThresholdM22:
            return "s16-candidate-ln01-ma20-days-threshold-m22"
        case .ln02DamnOnly:
            return "s17-candidate-ln02-damn-only"
        case .ln02WowOnly:
            return "s17-candidate-ln02-wow-only"
        case .lt01WantThreshold4:
            return "s16-candidate-lt01-want-threshold4"
        case .lt01WantThreshold6:
            return "s16-candidate-lt01-want-threshold6"
        case .lt01FineOrBetterThreshold6:
            return "s16-candidate-lt01-fine-or-better-threshold6"
        case .lt01HighOrBetterThreshold6:
            return "s16-candidate-lt01-high-or-better-threshold6"
        case .lt01WowThreshold6:
            return "s16-candidate-lt01-wow-threshold6"
        case .sp06RemoveABranch:
            return "s8-candidate-sp06-remove-a-branch"
        case .sp06RemoveBBranch:
            return "s8-candidate-sp06-remove-b-branch"
        case .sp06aUpperLowThreshold06:
            return "s12-candidate-sp06a-upper-low-threshold06"
        case .sp06aUpperLowThreshold10:
            return "s12-candidate-sp06a-upper-low-threshold10"
        case .sp06aUpperHighThresholdM02:
            return "s12-candidate-sp06a-upper-high-threshold-m02"
        case .sp06aUpperHighThresholdP02:
            return "s12-candidate-sp06a-upper-high-threshold-p02"
        case .sp06aUpperHighThresholdM04:
            return "s12-candidate-sp06a-upper-high-threshold-m04"
        case .sp06aUpperHighThresholdP04:
            return "s12-candidate-sp06a-upper-high-threshold-p04"
        case .sp06bLowerThreshold10:
            return "s12-candidate-sp06b-lower-threshold10"
        case .sp06bLowerThreshold14:
            return "s12-candidate-sp06b-lower-threshold14"
        case .sp06bLowerThreshold08:
            return "s12-candidate-sp06b-lower-threshold08"
        case .sp06bLowerThreshold16:
            return "s12-candidate-sp06b-lower-threshold16"
        case .sn01RemoveABranch:
            return "s8-candidate-sn01-remove-a-branch"
        case .sn01RemoveBBranch:
            return "s8-candidate-sn01-remove-b-branch"
        case .st02bRangeThreshold25:
            return "s12-candidate-st02b-range-threshold25"
        case .st02bRangeThreshold35:
            return "s12-candidate-st02b-range-threshold35"
        case .removeAP01a:
            return "s13-candidate-remove-ap01a"
        case .removeAP01b:
            return "s13-candidate-remove-ap01b"
        case .ap01bLowBoundary:
            return "s13-candidate-ap01b-low-boundary"
        case .ap02WowMinimum2:
            return "s12-candidate-ap02-wow-minimum2"
        case .ap02WowMinimum4:
            return "s12-candidate-ap02-wow-minimum4"
        case .ap05DiffThresholdM175:
            return "s12-candidate-ap05-diff-threshold-m175"
        case .ap05DiffThresholdM225:
            return "s12-candidate-ap05-diff-threshold-m225"
        case .ap06MA20ZThresholdM23:
            return "s12-candidate-ap06-ma20-z-threshold-m23"
        case .ap06MA20ZThresholdM27:
            return "s12-candidate-ap06-ma20-z-threshold-m27"
        case .ap06MA20ZThresholdM21:
            return "s12-candidate-ap06-ma20-z-threshold-m21"
        case .ap06MA20ZThresholdM29:
            return "s12-candidate-ap06-ma20-z-threshold-m29"
        case .ap06MA60ZThresholdM26:
            return "s15-candidate-ap06-ma60-z-threshold-m26"
        case .ap06MA60ZThresholdM30:
            return "s15-candidate-ap06-ma60-z-threshold-m30"
        case .ap07MA20DiffThresholdM7:
            return "s12-candidate-ap07-ma20-diff-threshold-m7"
        case .ap07MA20DiffThresholdM9:
            return "s12-candidate-ap07-ma20-diff-threshold-m9"
        case .ap07MA20DiffThresholdM6:
            return "s12-candidate-ap07-ma20-diff-threshold-m6"
        case .ap07MA20DiffThresholdM10:
            return "s12-candidate-ap07-ma20-diff-threshold-m10"
        case .at01WantThreshold2:
            return "s12-candidate-at01-want-threshold2"
        case .at01WantThreshold4:
            return "s12-candidate-at01-want-threshold4"
        case .at01WantThreshold1:
            return "s12-candidate-at01-want-threshold1"
        case .at01WantThreshold5:
            return "s12-candidate-at01-want-threshold5"
        case .at01ShortDays150:
            return "s18-candidate-at01-short-days150"
        case .at01ShortDays210:
            return "s18-candidate-at01-short-days210"
        case .at01LongDays330:
            return "s18-candidate-at01-long-days330"
        case .at01LongDays390:
            return "s18-candidate-at01-long-days390"
        case .at01ROIThresholdM275:
            return "s14-candidate-at01-roi-threshold-m275"
        case .at01ROIThresholdM325:
            return "s14-candidate-at01-roi-threshold-m325"
        case .at01ROIThresholdM3125:
            return "s14-candidate-at01-roi-threshold-m3125"
        case .at01ROIThresholdM35:
            return "s14-candidate-at01-roi-threshold-m35"
        case .at01Wow35Other325:
            return "s14-candidate-at01-wow35-other325"
        case .at01Wow35Middle325Low30:
            return "s14-candidate-at01-wow35-middle325-low30"
        case .at01Upper325Low30:
            return "s14-candidate-at01-upper325-low30"
        case .ae01CooldownDays20:
            return "s32-candidate-ae01-cooldown-days20"
        case .ae01CooldownDays30:
            return "s12-candidate-ae01-cooldown-days30"
        case .ae01CooldownDays60:
            return "s12-candidate-ae01-cooldown-days60"
        case .ae01CooldownDays15:
            return "s12-candidate-ae01-cooldown-days15"
        case .ae01CooldownDays75:
            return "s12-candidate-ae01-cooldown-days75"
        case .ae01CooldownDays38:
            return "s12-candidate-ae01-cooldown-days38"
        case .ae03Limit1:
            return "s13-candidate-ae03-limit1"
        case .ae03Limit3:
            return "s13-candidate-ae03-limit3"
        case .ae04ROIThresholdM45:
            return "s14-candidate-ae04-roi-threshold-m45"
        case .ae04ROIThresholdM55:
            return "s14-candidate-ae04-roi-threshold-m55"
        case .removeAE02:
            return "s13-candidate-remove-ae02"
        case .removeAN02:
            return "s13-candidate-remove-an02"
        case .st02RemoveBBranch:
            return "s8-candidate-st02-remove-b-branch"
        case .st02RemoveCBranch:
            return "s8-candidate-st02-remove-c-branch"
        case .st02RemoveScoreGate:
            return "s8-candidate-st02-remove-score-gate"
        case .st01aROI20:
            return "s9-candidate-st01a-roi20"
        case .st01aROI25:
            return "s9-candidate-st01a-roi25"
        case .st01aHighScoreM1:
            return "s9-candidate-st01a-high-score-m1"
        case .st01aHighScore1:
            return "s9-candidate-st01a-high-score-1"
        case .st01aGeneralScore0:
            return "s9-candidate-st01a-general-score-0"
        case .st01aGeneralScore2:
            return "s9-candidate-st01a-general-score-2"
        case .st01aEdgeScore:
            return "s9-candidate-st01a-edge-score"
        case .st01cScore4:
            return "s9-candidate-st01c-score4"
        case .st01cScore6:
            return "s9-candidate-st01c-score6"
        case .st01cLowROI10:
            return "s10-candidate-st01c-low-roi10"
        case .st01cLowROI20:
            return "s10-candidate-st01c-low-roi20"
        case .st01cOtherROI20:
            return "s10-candidate-st01c-other-roi20"
        case .st01cOtherROI225:
            return "s10-candidate-st01c-other-roi225"
        case .st01cOtherROI30:
            return "s10-candidate-st01c-other-roi30"
        case .st01cWeakOrBetterROI20:
            return "s10-candidate-st01c-weak-or-better-roi20"
        case .st01cGradeTieredROI:
            return "s10-candidate-st01c-grade-tiered-roi"
        case .st01cWow25Weak20:
            return "s10-candidate-st01c-wow25-weak20"
        case .st01cWow25Weak15:
            return "s10-candidate-st01c-wow25-weak15"
        case .st01cMiddle225Wow20:
            return "s10-candidate-st01c-middle225-wow20"
        case .st01cMiddle20Wow225:
            return "s10-candidate-st01c-middle20-wow225"
        case .st01eDays60:
            return "s11-candidate-st01e-days60"
        case .st01eDays68:
            return "s11-candidate-st01e-days68"
        case .st01eDays90:
            return "s11-candidate-st01e-days90"
        case .an01PenaltyM1:
            return "s8-candidate-an01-penalty-m1"
        case .an01PenaltyM3:
            return "s8-candidate-an01-penalty-m3"
        case .an01Control:
            return "s8-an01-formal-control"
        case .an01FineBoundary:
            return "s8-candidate-an01-fine-boundary-m2"
        case .an01FinePenaltyM1:
            return "s8-candidate-an01-fine-or-better-m1"
        case .an01FinePenaltyM1NoNone:
            return "s8-candidate-an01-fine-or-better-m1-no-none"
        case .an01FinePenaltyM1LowBelowM1:
            return "s8-candidate-an01-u-shape-low-fine-m1"
        case .an01FinePenaltyM1LowBelowP1:
            return "s8-candidate-an01-low-p1-fine-m1"
        case .an01FinePenaltyM3:
            return "s8-candidate-an01-fine-or-better-m3"
        case .an01HighPenaltyM3:
            return "s8-candidate-an01-high-or-better-m3"
        case .sn0203FineHighGroup:
            return "s7-candidate-sn0203-fine-high-group"
        case .sn0203HighGeneralGroup:
            return "s7-candidate-sn0203-high-general-group"
        case .sn02WowThreshold625:
            return "s15-candidate-sn02-wow-threshold625"
        case .sn02WowThreshold875:
            return "s15-candidate-sn02-wow-threshold875"
        case .sn02WowCapWithSN05:
            return "s15-candidate-sn02-wow-cap-with-sn05"
        case .sn05HighOrBetter:
            return "s7-candidate-sn05-high-or-better"
        case .sn05WeakOrBetter:
            return "s7-candidate-sn05-weak-or-better"
        }
    }()
    static let firstSimulationStart = isNineYearABProfile
        ? requiredDate("2017/07/22")
        : requiredDate("2019/01/02")
    static let historyStartText = isNineYearABProfile ? "2016/07/22" : "2018/01/02"
    static let inputDirectoryName = isNineYearABProfile
        ? sample.nineYearBaselineDirectoryName
        : sample.baselineDirectoryName
    static let profileID = isNineYearABProfile
        ? (sample == .e ? "abcde9-v2" : "abcd9-v2")
        : "legacy"
    static let through = requiredDate("2026/07/22")

    struct StockPeriod: Codable {
        let periodStart: String
        let periodEnd: String
        let years: Double
        let id: String
        let name: String
        let group: String
        let roi: Double?
        let averageDays: Double?
        let rounds: Double
        let grade: String
        let moneyLacked: Bool
        let status: String
    }

    struct GroupPeriod: Codable {
        let periodStart: String
        let group: String
        let validStocks: Int
        let totalStocks: Int
        let averageROI: Double?
        let averageDays: Double?
        let score: Double?
    }

    struct GroupSummary: Codable {
        let group: String
        let stockCount: Int
        let validPeriods: Int
        let mainScore: Double?
        let averageROI: Double?
        let averageDays: Double?
        let removedBestPeriod: String?
    }

    struct Baseline: Codable {
        let sampleID: String?
        let runID: String
        let createdAt: String
        let dataRuleVersion: String?
        let ruleVersion: String
        let ruleCommit: String?
        let ruleChangeSummary: String?
        let historyStart: String
        let through: String
        let moneyBaseWan: Double
        let automaticInvestments: Double
        let periodStepYears: Int
        let minimumPeriodYears: Int
        let periodStarts: [String]
        let combinedScore: Double?
        let groups: [GroupSummary]
        let periods: [GroupPeriod]
        let stocks: [StockPeriod]
    }

    struct Manifest: Codable {
        let sampleID: String?
        let runID: String
        let createdAt: String
        let inputStore: String
        let browseStore: String
        let reportFiles: [String]
        let dataRuleVersion: String?
        let ruleVersion: String
        let ruleCommit: String?
        let ruleChangeSummary: String?
        let historyStart: String
        let through: String
        let moneyBaseWan: Double
        let automaticInvestments: Double
        let periodStepYears: Int
        let minimumPeriodYears: Int
        let periodStarts: [String]
        let stockCount: Int
        let tradeCount: Int
        let invalidValueCount: Int
        let excludedNoTransactionCount: Int
    }

    struct Result {
        let directoryURL: URL
        let browseStoreURL: URL
        let reportURL: URL
        let baseline: Baseline
    }

    enum ReportError: LocalizedError {
        case missingInput(URL)
        case noPeriods
        case invalidValues(String)
        case missingStocks
        case sampleCNotConfigured
        case sampleCLockedUntilFinalValidation
        case missingDecisionBaseRuleCommit
        case invalidDecisionDeltaCandidate

        var errorDescription: String? {
            switch self {
            case .missingInput(let url): return "找不到基準快照：\(url.path)"
            case .noPeriods: return "沒有符合完整三年的回測期間。"
            case .invalidValues(let detail): return "偵測到 0、Inf 或 NaN，已停止回測：\(detail)"
            case .missingStocks: return "基準快照內沒有股票。"
            case .sampleCNotConfigured:
                return "Sample C 暫定名單已撤回；完成 FT4 重組與鎖定前不得執行回測。"
            case .sampleCLockedUntilFinalValidation:
                return "Sample C 已鎖定；候選完全凍結並進入 FT7 前不得執行回測。"
            case .missingDecisionBaseRuleCommit: return "DecisionBase 必須指定完整規則 commit。"
            case .invalidDecisionDeltaCandidate:
                return "Decision delta 必須指定候選；Baseline 零差異控制組需使用 control 參數。"
            }
        }
    }

    static func run(progress: (String) -> Void = { _ in }) throws -> Result {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if sample == .c
            && !CommandLine.arguments.contains("--nine-year-ab-baseline")
            && !InternalBacktestDataset.sampleCExecutionIsUnlocked() {
            throw ReportError.sampleCLockedUntilFinalValidation
        }
        try InternalBacktestCounterfactual.prepare()
        try InternalMarketVoteResearch.prepare()
        let shouldRecordDecisionBase = recordsDecisionBase
            && candidate == .baseline
            && !isFullWindowStress
            && !InternalBacktestCounterfactual.isEnabled
        let shouldRecordDecisionDelta = !isFullWindowStress && (
            InternalBacktestCounterfactual.isEnabled
                || recordsDecisionDeltaControl
                || (recordsDecisionDelta && candidate != .baseline)
        )
        let decisionDeltaCandidateID = InternalBacktestCounterfactual.counterfactualID
            ?? (recordsDecisionDeltaControl ? "p3-z-baseline-control" : candidate.rawValue)
        if recordsDecisionDelta && candidate == .baseline
            && !recordsDecisionDeltaControl && !InternalBacktestCounterfactual.isEnabled {
            throw ReportError.invalidDecisionDeltaCandidate
        }
        if (shouldRecordDecisionBase || shouldRecordDecisionDelta) && ruleCommit == nil {
            throw ReportError.missingDecisionBaseRuleCommit
        }
        let inputSnapshotID = [
            sample.rawValue.lowercased(), profileID,
            Technical.dataRuleVersion.lowercased().replacingOccurrences(of: "/", with: "-"),
            compactDate(through)
        ].joined(separator: "-")
        let decisionBaseID = [
            sample.rawValue.lowercased(), profileID, baselineRuleVersion,
            Technical.dataRuleVersion.lowercased().replacingOccurrences(of: "/", with: "-"),
            String((ruleCommit ?? "unknown").prefix(12)), "fixed3y", compactDate(through), "v6"
        ].joined(separator: "-")
        if shouldRecordDecisionBase || shouldRecordDecisionDelta {
            InternalBacktestDecisionRecorder.begin(.init(
                sampleID: sample.rawValue,
                inputSnapshotID: inputSnapshotID,
                decisionBaseID: decisionBaseID,
                dataRuleVersion: Technical.dataRuleVersion,
                ruleVersion: currentRuleVersion,
                ruleCommit: ruleCommit ?? "unknown",
                through: dateText(through),
                moneyBaseWan: moneyBaseWan,
                automaticInvestments: automaticInvestments
            ))
            if shouldRecordDecisionBase {
                let previousCompleteMarker = documents
                    .appendingPathComponent("InternalBacktest/DecisionBases", isDirectory: true)
                    .appendingPathComponent(decisionBaseID, isDirectory: true)
                    .appendingPathComponent(".complete")
                if fm.fileExists(atPath: previousCompleteMarker.path) {
                    try fm.removeItem(at: previousCompleteMarker)
                }
            }
            if shouldRecordDecisionDelta {
                let previousCompleteMarker = documents
                    .appendingPathComponent("InternalBacktest/DecisionDeltas", isDirectory: true)
                    .appendingPathComponent(decisionBaseID, isDirectory: true)
                    .appendingPathComponent(decisionDeltaCandidateID, isDirectory: true)
                    .appendingPathComponent(".complete")
                if fm.fileExists(atPath: previousCompleteMarker.path) {
                    try fm.removeItem(at: previousCompleteMarker)
                }
            }
        } else {
            InternalBacktestDecisionRecorder.reset()
        }
        defer { InternalBacktestDecisionRecorder.reset() }
        let inputURL = documents
            .appendingPathComponent(
                "InternalBacktest/\(inputDirectoryName)",
                isDirectory: true
            )
            .appendingPathComponent("baseline.store")
        guard fm.fileExists(atPath: inputURL.path) else { throw ReportError.missingInput(inputURL) }

        let outputURL = documents
            .appendingPathComponent("InternalBacktest/Runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let technicalBasesURL = documents
            .appendingPathComponent("InternalBacktest/TechnicalBases", isDirectory: true)
        try fm.createDirectory(at: technicalBasesURL, withIntermediateDirectories: true)
        let technicalBaseName = sample.rawValue.lowercased() + "-"
            + profileID + "-"
            + Technical.technicalRuleVersion
            + "-"
            + compactDate(through)
        let technicalBaseURL = technicalBasesURL
            .appendingPathComponent(technicalBaseName + ".store")
        let technicalBaseMarkerURL = technicalBasesURL
            .appendingPathComponent(technicalBaseName + ".complete")
        if !fm.fileExists(atPath: technicalBaseMarkerURL.path) {
            removeStore(at: technicalBaseURL)
            try copyStore(from: inputURL, to: technicalBaseURL)
            progress("建立 \(Technical.dataRuleVersion) 技術資料基底")
            try recalculateTechnicalBase(storeURL: technicalBaseURL, progress: progress)
            try Technical.technicalRuleVersion.write(
                to: technicalBaseMarkerURL,
                atomically: true,
                encoding: .utf8
            )
        } else {
            progress("沿用 \(Technical.dataRuleVersion) 技術資料基底")
        }

        let windows = periodWindows()
        guard !windows.isEmpty else { throw ReportError.noPeriods }
        var allStocks: [StockPeriod] = []
        var allGroups: [GroupPeriod] = []
        var hn09DiagnosticRows: [String] = [hn09DiagnosticHeader]
        var lc02DiagnosticRows: [String] = [lc02DiagnosticHeader]
        var an01DiagnosticRows: [String] = [an01DiagnosticHeader]
        var firstPeriodStore: URL?
        var stockCount = 0
        var tradeCount = 0

        for (index, window) in windows.enumerated() {
            let start = window.start
            let end = window.end
            let startText = dateText(start)
            progress("\(index + 1)/\(windows.count) 建立 \(startText)–\(dateText(end)) 回測副本")
            let periodStore = outputURL.appendingPathComponent("period-\(compactDate(start)).store")
            try copyStore(from: technicalBaseURL, to: periodStore)
            let periodResult = try evaluatePeriod(
                storeURL: periodStore,
                start: start,
                end: end,
                progress: progress
            )
            allStocks.append(contentsOf: periodResult.stocks)
            allGroups.append(contentsOf: periodResult.groups)
            hn09DiagnosticRows.append(contentsOf: periodResult.hn09DiagnosticRows)
            lc02DiagnosticRows.append(contentsOf: periodResult.lc02DiagnosticRows)
            an01DiagnosticRows.append(contentsOf: periodResult.an01DiagnosticRows)
            if index == 0 {
                firstPeriodStore = periodStore
                stockCount = periodResult.stockCount
                tradeCount = periodResult.tradeCount
            } else if !retainsPeriodStores {
                try fm.removeItem(at: periodStore)
                removeSidecars(for: periodStore)
            }
        }
        try InternalBacktestCounterfactual.validate()
        guard let firstPeriodStore else { throw ReportError.noPeriods }
        let browseStoreURL = outputURL.appendingPathComponent("browse.store")
        try fm.moveItem(at: firstPeriodStore, to: browseStoreURL)
        moveSidecars(from: firstPeriodStore, to: browseStoreURL)

        let summaries = groupNames.map { group in
            summarize(group: group, periods: allGroups, stocks: allStocks)
        }
        let scores = summaries.compactMap(\.mainScore)
        let combinedScore = scores.count == summaries.count ? scores.reduce(0, +) : nil
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let baseline = Baseline(
            sampleID: sample.rawValue,
            runID: runID,
            createdAt: createdAt,
            dataRuleVersion: Technical.dataRuleVersion,
            ruleVersion: currentRuleVersion,
            ruleCommit: ruleCommit,
            ruleChangeSummary: currentRuleChangeSummary,
            historyStart: historyStartText,
            through: dateText(through),
            moneyBaseWan: moneyBaseWan,
            automaticInvestments: automaticInvestments,
            periodStepYears: 3,
            minimumPeriodYears: 3,
            periodStarts: windows.map { dateText($0.start) },
            combinedScore: combinedScore,
            groups: summaries,
            periods: allGroups,
            stocks: allStocks
        )

        progress(
            isSummaryOnly
                ? "產生摘要用 baseline.json、periods.csv、manifest.json"
                : "產生 report.html、baseline.json、periods.csv、manifest.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(baseline).write(
            to: outputURL.appendingPathComponent("baseline.json"),
            options: .atomic
        )
        try periodsCSV(allStocks).write(
            to: outputURL.appendingPathComponent("periods.csv"),
            atomically: true,
            encoding: .utf8
        )
        if isHN09Diagnostic {
            try hn09DiagnosticRows.joined(separator: "\n").appending("\n").write(
                to: outputURL.appendingPathComponent("hn09-diagnostic.csv"),
                atomically: true,
                encoding: .utf8
            )
        }
        if isLC02Diagnostic {
            try lc02DiagnosticRows.joined(separator: "\n").appending("\n").write(
                to: outputURL.appendingPathComponent("lc02-diagnostic.csv"),
                atomically: true,
                encoding: .utf8
            )
        }
        if isAN01Diagnostic {
            try an01DiagnosticRows.joined(separator: "\n").appending("\n").write(
                to: outputURL.appendingPathComponent("an01-diagnostic.csv"),
                atomically: true,
                encoding: .utf8
            )
        }

        let excluded = allStocks.filter { $0.status == "無成交，不計分" }.count
        let manifest = Manifest(
            sampleID: sample.rawValue,
            runID: runID,
            createdAt: createdAt,
            inputStore: "\(inputDirectoryName)/baseline.store",
            browseStore: "browse.store",
            reportFiles: (isHN09Diagnostic
                ? ["baseline.json", "periods.csv", "manifest.json", "hn09-diagnostic.csv"]
                : (isLC02Diagnostic
                    ? ["baseline.json", "periods.csv", "manifest.json", "lc02-diagnostic.csv"]
                    : (isAN01Diagnostic
                        ? ["baseline.json", "periods.csv", "manifest.json", "an01-diagnostic.csv"]
                        : (isSummaryOnly
                            ? ["baseline.json", "periods.csv", "manifest.json"]
                            : ["report.html", "baseline.json", "periods.csv", "manifest.json"]))))
                + (InternalMarketVoteResearch.isConfigured
                    ? ["market-vote-diagnostics.json"] : []),
            dataRuleVersion: Technical.dataRuleVersion,
            ruleVersion: currentRuleVersion,
            ruleCommit: ruleCommit,
            ruleChangeSummary: currentRuleChangeSummary,
            historyStart: historyStartText,
            through: dateText(through),
            moneyBaseWan: moneyBaseWan,
            automaticInvestments: automaticInvestments,
            periodStepYears: 3,
            minimumPeriodYears: 3,
            periodStarts: windows.map { dateText($0.start) },
            stockCount: stockCount,
            tradeCount: tradeCount,
            invalidValueCount: 0,
            excludedNoTransactionCount: excluded
        )
        try encoder.encode(manifest).write(
            to: outputURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        let reportURL = outputURL.appendingPathComponent("report.html")
        if !isSummaryOnly {
            try html(
                baseline,
                reference: loadReferenceBaseline(from: documents),
                crossSample: loadCrossSampleBaseline(from: documents)
            ).write(to: reportURL, atomically: true, encoding: .utf8)
        }
        if shouldRecordDecisionBase {
            let decisionBaseURL = documents
                .appendingPathComponent("InternalBacktest/DecisionBases", isDirectory: true)
                .appendingPathComponent(decisionBaseID, isDirectory: true)
            progress("寫入 DecisionBase：\(decisionBaseID)")
            try InternalBacktestDecisionRecorder.write(to: decisionBaseURL, outcomes: allStocks)
        }
        if shouldRecordDecisionDelta {
            let baselineDecisionBaseURL = documents
                .appendingPathComponent("InternalBacktest/DecisionBases", isDirectory: true)
                .appendingPathComponent(decisionBaseID, isDirectory: true)
            let deltaDirectoryURL = documents
                .appendingPathComponent("InternalBacktest/DecisionDeltas", isDirectory: true)
                .appendingPathComponent(decisionBaseID, isDirectory: true)
                .appendingPathComponent(decisionDeltaCandidateID, isDirectory: true)
            progress("寫入 Decision delta：\(decisionDeltaCandidateID)")
            try InternalBacktestDecisionDelta.write(
                configuration: .init(
                    sampleID: sample.rawValue,
                    inputSnapshotID: inputSnapshotID,
                    baselineDecisionBaseID: decisionBaseID,
                    candidateID: decisionDeltaCandidateID,
                    candidateRunID: runID,
                    baselineRuleVersion: baselineRuleVersion,
                    baselineRuleCommit: ruleCommit ?? "unknown",
                    through: dateText(through),
                    moneyBaseWan: moneyBaseWan,
                    automaticInvestments: automaticInvestments
                ),
                baselineDirectoryURL: baselineDecisionBaseURL,
                outputDirectoryURL: deltaDirectoryURL,
                events: InternalBacktestDecisionRecorder.events,
                outcomes: allStocks
            )
            try InternalBacktestCounterfactual.validateDecisionDeltaIfNeeded(
                at: deltaDirectoryURL
            )
            progress("產生 P4a 決策分析摘要：\(decisionDeltaCandidateID)")
            _ = try InternalBacktestDecisionAnalyzer.write(
                decisionBaseID: decisionBaseID,
                candidateID: decisionDeltaCandidateID,
                baselineDirectoryURL: baselineDecisionBaseURL,
                deltaDirectoryURL: deltaDirectoryURL
            )
            if InternalBacktestCounterfactual.isEnabled {
                progress("產生 P5 限定反事實效用摘要：\(decisionDeltaCandidateID)")
                try InternalBacktestCounterfactual.writeSummary(
                    baselineDecisionBaseID: decisionBaseID,
                    baselineDirectoryURL: baselineDecisionBaseURL,
                    deltaDirectoryURL: deltaDirectoryURL,
                    outputRootURL: documents.appendingPathComponent(
                        "InternalBacktest/Counterfactuals",
                        isDirectory: true
                    ),
                    outcomes: allStocks
                )
            }
        }
        if isFullWindowStress && candidate == .baseline {
            try publishBrowseSnapshot(from: browseStoreURL, in: documents)
        }
        try InternalMarketVoteResearch.writeDiagnostics(to: outputURL)
        try runID.write(
            to: outputURL.appendingPathComponent(".complete"),
            atomically: true,
            encoding: .utf8
        )
        return Result(
            directoryURL: outputURL,
            browseStoreURL: browseStoreURL,
            reportURL: reportURL,
            baseline: baseline
        )
    }

    private struct PeriodResult {
        let stocks: [StockPeriod]
        let groups: [GroupPeriod]
        let stockCount: Int
        let tradeCount: Int
        let hn09DiagnosticRows: [String]
        let lc02DiagnosticRows: [String]
        let an01DiagnosticRows: [String]
    }

    private static func recalculateTechnicalBase(
        storeURL: URL,
        progress: (String) -> Void
    ) throws {
        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalBacktestTechnicalBase",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let technical = Technical(modelContext: context)
        let stocks = try Stock.fetchAll(in: context).sorted { $0.sId < $1.sId }
        guard !stocks.isEmpty else { throw ReportError.missingStocks }
        for (index, stock) in stocks.enumerated() {
            progress(
                "\(Technical.dataRuleVersion) \(index + 1)/\(stocks.count) "
                + "\(stock.sId) \(stock.sName) tUpdate"
            )
            _ = try technical.recalculate(
                stock: stock,
                plan: RecalculationPlan(technical: .all, simulation: .none)
            )
        }
        try context.save()
    }

    private static func evaluatePeriod(
        storeURL: URL,
        start: Date,
        end: Date,
        progress: (String) -> Void
    ) throws -> PeriodResult {
        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalBacktestPeriod",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let technical = Technical(modelContext: context)
        let stocks = try Stock.fetchAll(in: context).sorted {
            ($0.group, $0.sId) < ($1.group, $1.sId)
        }
        guard !stocks.isEmpty else { throw ReportError.missingStocks }
        resetHN09DiagnosticRecords()
        resetLC02DiagnosticRecords()
        resetAN01DiagnosticRecords()
        InternalBacktestDecisionRecorder.beginWindow(end: end)

        for (index, stock) in stocks.enumerated() {
            progress("\(dateText(start))–\(dateText(end)) \(index + 1)/\(stocks.count) \(stock.sId) \(stock.sName) simUpdate")
            stock.dateStart = start
            stock.simMoneyBase = moneyBaseWan
            stock.simInvestAuto = automaticInvestments
            stock.simInvestUser = 0
            stock.simInvestExceed = 0
            stock.simMoneyLacked = false
            stock.simReversed = false
            _ = try technical.recalculate(
                stock: stock,
                plan: RecalculationPlan(
                    technical: .none,
                    simulation: .all,
                    resetPolicy: .clearUserActions,
                    resetDerivedSimulationState: true,
                    simulationEnd: end
                )
            )
        }
        try context.save()
        let exactHN09Rows = isHN09Diagnostic ? hn09DiagnosticRecords.map(\.csvRow) : []
        let exactLC02Rows = isLC02Diagnostic ? lc02DiagnosticRecords.map(\.csvRow) : []
        let exactAN01Rows = isAN01Diagnostic ? an01DiagnosticRecords.map(\.csvRow) : []

        var rows: [StockPeriod] = []
        var totalTrades = 0
        let years = end.timeIntervalSince(start) / 86_400 / 365
        for stock in stocks {
            let trades = try Trade.fetch(in: context, for: stock, ascending: true)
            totalTrades += trades.count
            try validate(trades: trades, stock: stock, start: start)
            let final = trades.last { $0.dateTime <= end }
            let hasTransaction = (final?.rollRounds ?? 0) > 0 && (final?.days ?? 0) > 0
            rows.append(
                StockPeriod(
                    periodStart: dateText(start),
                    periodEnd: dateText(end),
                    years: years,
                    id: stock.sId,
                    name: stock.sName,
                    group: stock.group,
                    roi: hasTransaction ? final?.roi : nil,
                    averageDays: hasTransaction ? final?.days : nil,
                    rounds: final?.rollRounds ?? 0,
                    grade: final.map { gradeText($0.grade) } ?? "none",
                    moneyLacked: stock.simMoneyLacked,
                    status: hasTransaction ? (stock.simMoneyLacked ? "曾發生本金不足" : "正常") : "無成交，不計分"
                )
            )
        }

        let groups = groupNames.map { group -> GroupPeriod in
            let groupRows = rows.filter { $0.group == group }
            let valid = groupRows.filter { $0.roi != nil && $0.averageDays != nil }
            let roi = mean(valid.compactMap(\.roi))
            let days = mean(valid.compactMap(\.averageDays))
            return GroupPeriod(
                periodStart: dateText(start),
                group: group,
                validStocks: valid.count,
                totalStocks: groupRows.count,
                averageROI: roi,
                averageDays: days,
                score: score(roi: roi, days: days)
            )
        }
        return PeriodResult(
            stocks: rows,
            groups: groups,
            stockCount: stocks.count,
            tradeCount: totalTrades,
            hn09DiagnosticRows: exactHN09Rows,
            lc02DiagnosticRows: exactLC02Rows,
            an01DiagnosticRows: exactAN01Rows
        )
    }

    private static let hn09Offsets = [-0.4, -0.2, -0.1, 0.1, 0.2, 0.4]
    private static let hn09DiagnosticHeader: String = {
        let fixed = [
            "periodStart", "group", "stockID", "stockName", "date", "grade",
            "highZ", "lowZ", "highThreshold", "lowThreshold", "wantHWithoutHN09",
            "currentTrigger", "currentH"
        ]
        let offset = hn09Offsets.flatMap { value -> [String] in
            let key = value < 0
                ? "m" + String(format: "%.1f", -value).replacingOccurrences(of: ".", with: "p")
                : "p" + String(format: "%.1f", value).replacingOccurrences(of: ".", with: "p")
            return ["trigger_\(key)", "h_\(key)"]
        }
        return (fixed + offset).joined(separator: ",")
    }()

    private struct HN09DiagnosticRecord {
        let periodStart: String
        let group: String
        let stockID: String
        let stockName: String
        let date: String
        let grade: String
        let highZ: Double
        let lowZ: Double
        let highThreshold: Double
        let lowThreshold: Double
        let wantHWithoutHN09: Double
        let currentTrigger: Bool
        let currentH: Bool
        let alternativeTriggers: [Bool]
        let alternativeH: [Bool]

        var csvRow: String {
            var values = [
                periodStart, group, stockID, stockName, date, grade,
                String(format: "%.6f", highZ), String(format: "%.6f", lowZ),
                String(format: "%.2f", highThreshold), String(format: "%.2f", lowThreshold),
                String(format: "%.0f", wantHWithoutHN09),
                currentTrigger ? "1" : "0", currentH ? "1" : "0"
            ]
            for index in alternativeTriggers.indices {
                values.append(alternativeTriggers[index] ? "1" : "0")
                values.append(alternativeH[index] ? "1" : "0")
            }
            return values.map(csvEscape).joined(separator: ",")
        }
    }

    private static var hn09DiagnosticRecords: [HN09DiagnosticRecord] = []

    static func resetHN09DiagnosticRecords() {
        hn09DiagnosticRecords.removeAll(keepingCapacity: true)
    }

    static func recordHN09Diagnostic(
        trade: Trade,
        grade: Trade.Grade,
        highThreshold: Double,
        lowThreshold: Double,
        currentTrigger: Bool,
        wantHWithoutHN09: Double
    ) {
        guard isHN09Diagnostic, !trade.isBeforeSimulationStart else { return }
        func trigger(offset: Double) -> Bool {
            trade.tHighDiffZ125 > highThreshold + offset
                && trade.tLowDiffZ125 > lowThreshold + offset
        }
        let alternatives = hn09Offsets.map(trigger)
        hn09DiagnosticRecords.append(HN09DiagnosticRecord(
            periodStart: dateText(trade.stock.dateStart),
            group: trade.stock.group,
            stockID: trade.stock.sId,
            stockName: trade.stock.sName,
            date: dateText(trade.dateTime),
            grade: gradeText(grade),
            highZ: trade.tHighDiffZ125,
            lowZ: trade.tLowDiffZ125,
            highThreshold: highThreshold,
            lowThreshold: lowThreshold,
            wantHWithoutHN09: wantHWithoutHN09,
            currentTrigger: currentTrigger,
            currentH: wantHWithoutHN09 - (currentTrigger ? 1 : 0) >= 0,
            alternativeTriggers: alternatives,
            alternativeH: alternatives.map { wantHWithoutHN09 - ($0 ? 1 : 0) >= 0 }
        ))
    }

    private static let lc02DiagnosticHeader = [
        "periodStart", "group", "stockID", "stockName", "date", "grade",
        "inventoryBefore", "buyRuleBefore", "wantLWithoutLC02", "wantLWithLC02",
        "lWithoutLC02", "lWithLC02", "decisionChanged", "actualRule",
        "actualBuyRule", "actualBuyQty"
    ].joined(separator: ",")

    private struct LC02DiagnosticRecord {
        let trade: Trade
        let grade: Trade.Grade
        let inventoryBefore: Double
        let buyRuleBefore: String
        let wantLWithoutLC02: Double
        let wantLWithLC02: Double

        var csvRow: String {
            let lWithoutLC02 = wantLWithoutLC02 >= 5
            let lWithLC02 = wantLWithLC02 >= 5
            return [
                dateText(trade.stock.dateStart), trade.stock.group, trade.stock.sId,
                trade.stock.sName, dateText(trade.dateTime), gradeText(grade),
                String(format: "%.0f", inventoryBefore), buyRuleBefore,
                String(format: "%.0f", wantLWithoutLC02),
                String(format: "%.0f", wantLWithLC02),
                lWithoutLC02 ? "1" : "0", lWithLC02 ? "1" : "0",
                lWithoutLC02 == lWithLC02 ? "0" : "1", trade.simRule,
                trade.simRuleBuy, String(format: "%.0f", trade.simQtyBuy)
            ].map(csvEscape).joined(separator: ",")
        }
    }

    private static var lc02DiagnosticRecords: [LC02DiagnosticRecord] = []

    static func resetLC02DiagnosticRecords() {
        lc02DiagnosticRecords.removeAll(keepingCapacity: true)
    }

    static func recordLC02Diagnostic(
        trade: Trade,
        grade: Trade.Grade,
        triggered: Bool,
        inventoryBefore: Double,
        buyRuleBefore: String,
        wantLWithoutLC02: Double
    ) {
        guard isLC02Diagnostic, triggered, !trade.isBeforeSimulationStart else { return }
        lc02DiagnosticRecords.append(LC02DiagnosticRecord(
            trade: trade,
            grade: grade,
            inventoryBefore: inventoryBefore,
            buyRuleBefore: buyRuleBefore,
            wantLWithoutLC02: wantLWithoutLC02,
            wantLWithLC02: wantLWithoutLC02 + 1
        ))
    }

    private static let an01DiagnosticHeader = [
        "periodStart", "group", "stockID", "stockName", "date", "grade",
        "buyRule", "unitROI", "simDays", "investTimes", "wantWithoutAN01",
        "currentPenalty", "currentWant", "formalCandidate", "fineBoundaryCandidate",
        "finePenaltyM3Candidate", "highPenaltyM3Candidate", "actualCandidate",
        "actualExecuted"
    ].joined(separator: ",")

    private struct AN01DiagnosticRecord {
        let periodStart: String
        let group: String
        let stockID: String
        let stockName: String
        let date: String
        let grade: String
        let buyRule: String
        let unitROI: Double
        let simDays: Double
        let investTimes: Double
        let wantWithoutAN01: Double
        let currentPenalty: Double
        let formalCandidate: Bool
        let fineBoundaryCandidate: Bool
        let finePenaltyM3Candidate: Bool
        let highPenaltyM3Candidate: Bool
        let actualCandidate: Bool
        let actualExecuted: Bool

        var csvRow: String {
            [
                periodStart, group, stockID, stockName, date, grade, buyRule,
                String(format: "%.6f", unitROI), String(format: "%.0f", simDays),
                String(format: "%.0f", investTimes), String(format: "%.0f", wantWithoutAN01),
                String(format: "%.0f", currentPenalty),
                String(format: "%.0f", wantWithoutAN01 + currentPenalty),
                formalCandidate ? "1" : "0", fineBoundaryCandidate ? "1" : "0",
                finePenaltyM3Candidate ? "1" : "0", highPenaltyM3Candidate ? "1" : "0",
                actualCandidate ? "1" : "0", actualExecuted ? "1" : "0"
            ].map(csvEscape).joined(separator: ",")
        }
    }

    private static var an01DiagnosticRecords: [AN01DiagnosticRecord] = []

    static func resetAN01DiagnosticRecords() {
        an01DiagnosticRecords.removeAll(keepingCapacity: true)
    }

    static func recordAN01Diagnostic(
        trade: Trade,
        grade: Trade.Grade,
        aWantWithoutAN01: Double,
        currentPenalty: Double,
        actualCandidate: Bool,
        actualExecuted: Bool
    ) {
        // A10h also changes the low/damn branch, so the diagnostic must retain
        // every Grade instead of silently dropping the branch under test.
        guard isAN01Diagnostic, !trade.isBeforeSimulationStart else { return }
        func isCandidate(penalty: Double) -> Bool {
            let want = aWantWithoutAN01 + penalty
            let deepLoss = (trade.simUnitRoi < -30
                || (trade.simUnitRoi < -25 && (trade.simDays < 180 || trade.simDays > 360)))
                && want >= 3
            let earlyL = trade.simUnitRoi > -10 && trade.simUnitRoi < 1
                && trade.simRule == "L" && want >= (grade <= .low ? 2 : 3)
                && trade.simDays < 60
            return deepLoss || earlyL
        }
        let formalPenalty = grade >= .none ? -2.0 : 0
        let fineBoundaryPenalty = grade >= .fine ? -2.0 : 0
        let finePenaltyM3 = grade >= .fine ? -3.0 : (grade >= .none ? -2.0 : 0)
        let highPenaltyM3 = grade >= .high ? -3.0 : (grade >= .none ? -2.0 : 0)
        an01DiagnosticRecords.append(AN01DiagnosticRecord(
            periodStart: dateText(trade.stock.dateStart),
            group: trade.stock.group,
            stockID: trade.stock.sId,
            stockName: trade.stock.sName,
            date: dateText(trade.dateTime),
            grade: gradeText(grade),
            buyRule: trade.simRule,
            unitROI: trade.simUnitRoi,
            simDays: trade.simDays,
            investTimes: trade.simInvestTimes,
            wantWithoutAN01: aWantWithoutAN01,
            currentPenalty: currentPenalty,
            formalCandidate: isCandidate(penalty: formalPenalty),
            fineBoundaryCandidate: isCandidate(penalty: fineBoundaryPenalty),
            finePenaltyM3Candidate: isCandidate(penalty: finePenaltyM3),
            highPenaltyM3Candidate: isCandidate(penalty: highPenaltyM3),
            actualCandidate: actualCandidate,
            actualExecuted: actualExecuted
        ))
    }

    private static func validate(trades: [Trade], stock: Stock, start: Date) throws {
        for trade in trades {
            let prices = [trade.priceOpen, trade.priceHigh, trade.priceLow, trade.priceClose]
            if prices.contains(where: { !$0.isFinite || $0 <= 0 }) || !trade.volumeClose.isFinite {
                throw ReportError.invalidValues("\(stock.sId) \(dateText(trade.dateTime)) 價量")
            }
            let technical = [
                trade.tMa20, trade.tMa60, trade.tKdK, trade.tKdD, trade.tKdJ,
                trade.tOsc, trade.tZ125, trade.tZ250, trade.vZ125, trade.vZ250
            ]
            if technical.contains(where: { !$0.isFinite }) {
                throw ReportError.invalidValues("\(stock.sId) \(dateText(trade.dateTime)) 技術值")
            }
            if trade.dateTime >= start {
                let simulation = [
                    trade.rollAmtCost, trade.rollAmtProfit, trade.rollAmtRoi, trade.rollDays,
                    trade.simAmtBalance, trade.simAmtCost, trade.simAmtProfit, trade.simAmtRoi,
                    trade.simDays, trade.simUnitCost, trade.simUnitRoi
                ]
                if simulation.contains(where: { !$0.isFinite }) {
                    throw ReportError.invalidValues("\(stock.sId) \(dateText(trade.dateTime)) 模擬值")
                }
            }
        }
    }

    private static func summarize(
        group: String,
        periods: [GroupPeriod],
        stocks: [StockPeriod]
    ) -> GroupSummary {
        let groupPeriods = periods.filter { $0.group == group && $0.score != nil }
        var scored = groupPeriods
        var removed: String?
        if scored.count >= 6,
           let best = scored.max(by: { ($0.score ?? -.infinity) < ($1.score ?? -.infinity) }) {
            removed = best.periodStart
            scored.removeAll { $0.periodStart == best.periodStart }
        }
        return GroupSummary(
            group: group,
            stockCount: Set(stocks.filter { $0.group == group }.map(\.id)).count,
            validPeriods: groupPeriods.count,
            mainScore: mean(scored.compactMap(\.score)),
            averageROI: mean(groupPeriods.compactMap(\.averageROI)),
            averageDays: mean(groupPeriods.compactMap(\.averageDays)),
            removedBestPeriod: removed
        )
    }

    private static func score(roi: Double?, days: Double?) -> Double? {
        guard let roi, let days, days > 0 else { return nil }
        return roi >= 0 ? roi * 100 / days : roi * days / 100
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func periodWindows() -> [(start: Date, end: Date)] {
        if isFullWindowStress {
            return [(firstSimulationStart, through)]
        }
        var result: [Date] = []
        var start = firstSimulationStart
        while through.timeIntervalSince(start) / 86_400 / 365 >= 3 {
            result.append(start)
            guard let next = twDateTime.calendar.date(byAdding: .year, value: 3, to: start) else { break }
            start = next
        }
        // Keep a full three-year window ending at the snapshot date even when
        // it overlaps the final regular three-year step.
        if let latestFullWindow = twDateTime.calendar.date(
            byAdding: .year,
            value: -3,
            to: through
        ), result.last != latestFullWindow {
            result.append(latestFullWindow)
        }
        return result.compactMap { start in
            guard let fullEnd = twDateTime.calendar.date(
                byAdding: .year,
                value: 3,
                to: start
            ) else {
                return nil
            }
            return (start, min(fullEnd, through))
        }
    }

    private static func gradeText(_ grade: Trade.Grade) -> String {
        switch grade {
        case .wow: return "wow"
        case .high: return "high"
        case .fine: return "fine"
        case .none: return "none"
        case .weak: return "weak"
        case .low: return "low"
        case .damn: return "damn"
        }
    }

    private static func periodsCSV(_ rows: [StockPeriod]) -> String {
        var lines = ["起始日,截止日,期間年數,股群,代號,簡稱,實年報酬率,平均週期,交易輪次,評等,本金不足,狀態"]
        for row in rows {
            lines.append([
                row.periodStart, row.periodEnd, format(row.years, 2), row.group,
                row.id, row.name, row.roi.map { format($0, 4) } ?? "",
                row.averageDays.map { format($0, 2) } ?? "", format(row.rounds, 0),
                row.grade, row.moneyLacked ? "是" : "否", row.status
            ].map(csvEscape).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    private static func loadReferenceBaseline(from documents: URL) -> Baseline? {
        let url = documents
            .appendingPathComponent("InternalBacktest/Runs", isDirectory: true)
            .appendingPathComponent(referenceRunID, isDirectory: true)
            .appendingPathComponent("baseline.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Baseline.self, from: data)
    }

    private static func loadCrossSampleBaseline(from documents: URL) -> Baseline? {
        guard sample == .b, candidate == .baseline else { return nil }
        let crossSampleRunID: String
        if isNineYearABProfile {
            crossSampleRunID = isFullWindowStress
                ? "baseline-a-v13-s26-fit-trend-phase-split-t2s31-9y-fullstress-600w-20260827"
                : "baseline-a-v13-s26-fit-trend-phase-split-t2s31-9y-fixed3y-600w-20260827"
        } else {
            crossSampleRunID = isFullWindowStress
                ? "baseline-s17-ap08-wow-early-boundary-fullstress-600w-20260814"
                : "baseline-s17-ap08-wow-early-boundary-fixed3y-600w-20260814"
        }
        let url = documents
            .appendingPathComponent("InternalBacktest/Runs", isDirectory: true)
            .appendingPathComponent(crossSampleRunID, isDirectory: true)
            .appendingPathComponent("baseline.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Baseline.self, from: data)
    }

    private static func html(
        _ report: Baseline,
        reference: Baseline?,
        crossSample: Baseline?
    ) -> String {
        let firstGroup = groupNames[0]
        let secondGroup = groupNames[1]
        let h = report.groups.first { $0.group == firstGroup }
        let l = report.groups.first { $0.group == secondGroup }
        let referenceH = reference?.groups.first
        let referenceL = reference?.groups.dropFirst().first
        let windowDescriptions = report.stocks.reduce(into: [String]()) { result, row in
            let description = "\(row.periodStart)–\(row.periodEnd)"
            if !result.contains(description) {
                result.append(description)
            }
        }.joined(separator: "、")
        let periodRows = report.periods.filter { $0.group == firstGroup }.map { hp in
            let lp = report.periods.first {
                $0.group == secondGroup && $0.periodStart == hp.periodStart
            }
            let referenceHP = reference?.periods.first {
                $0.group == referenceH?.group && $0.periodStart == hp.periodStart
            }
            let referenceLP = reference?.periods.first {
                $0.group == referenceL?.group && $0.periodStart == hp.periodStart
            }
            let combined = sum(hp.score, lp?.score)
            let referenceCombined = sum(referenceHP?.score, referenceLP?.score)
            let periodYears = report.stocks.first {
                $0.periodStart == hp.periodStart
            }?.years
            return """
            <tr><td>\(hp.periodStart)</td><td>\(number(periodYears, digits: 1)) 年</td>
            <td>\(number(referenceHP?.score))</td><td class='h'>\(number(hp.score))</td><td class='\(deltaClass(hp.score, referenceHP?.score))'>\(delta(hp.score, referenceHP?.score))</td>
            <td>\(number(referenceLP?.score))</td><td class='l'>\(number(lp?.score))</td><td class='\(deltaClass(lp?.score, referenceLP?.score))'>\(delta(lp?.score, referenceLP?.score))</td>
            <td>\(number(referenceCombined))</td><td>\(number(combined))</td><td class='\(deltaClass(combined, referenceCombined))'>\(delta(combined, referenceCombined))</td></tr>
            """
        }.joined(separator: "\n")
        let stockRows = report.stocks.map { row in
            "<tr><td>\(row.periodStart)</td><td>\(row.group)</td><td>\(row.id) \(escape(row.name))</td><td>\(percent(row.roi))</td><td>\(number(row.averageDays, digits: 0))</td><td>\(row.grade)</td><td>\(escape(row.status))</td></tr>"
        }.joined(separator: "\n")
        return """
        <!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>simStock3 \(reportTitle) 回測報告</title><style>
        :root{--bg:#f4f5f9;--panel:#fff;--ink:#191c24;--muted:#747987;--line:#e4e6ed;--accent:#6b4eff;--h:#e64646;--l:#15945a;font-family:-apple-system,BlinkMacSystemFont,"PingFang TC",sans-serif}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink)}main{width:min(1240px,calc(100% - 32px));margin:32px auto 60px}h1{font-size:36px;margin:5px 0}.eyebrow{color:var(--accent);font-weight:750}.sub,.muted{color:var(--muted)}.cards{display:grid;grid-template-columns:1.2fr 1fr 1fr 1fr;gap:12px;margin:22px 0}.card,.panel{background:var(--panel);border:1px solid var(--line);border-radius:17px}.card{padding:18px}.card.primary{background:linear-gradient(145deg,#7457ff,#5538df);color:white;border:0}.label{font-size:13px;color:var(--muted)}.primary .label{color:#ffffffbd}.value{font-size:34px;font-weight:780;margin:8px 0}.panel{margin-top:16px;overflow:hidden}.head{padding:18px 22px 10px}.head h2{margin:0}.meta{display:grid;grid-template-columns:repeat(4,1fr);padding:0 22px 18px}.meta div{padding:10px;border-left:1px solid var(--line)}.meta div:first-child{border:0}.meta span{display:block;color:var(--muted);font-size:12px}.table{overflow-x:auto}table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}th,td{padding:11px 13px;border-top:1px solid var(--line);text-align:right;white-space:nowrap}th:first-child,td:first-child{text-align:left;padding-left:22px}th{background:#fafafd;color:var(--muted);font-size:12px}.h{color:var(--h);font-weight:700}.l{color:var(--l);font-weight:700}.note{padding:0 22px 18px;color:var(--muted);font-size:13px}@media(max-width:850px){.cards,.meta{grid-template-columns:1fr 1fr}}@media(max-width:560px){.cards,.meta{grid-template-columns:1fr}}
        .opinion{padding:20px 22px;font-size:16px;line-height:1.75}.positive{color:#15945a;font-weight:700}.negative{color:#d53d3d;font-weight:700}.neutral{color:var(--muted)}
        </style></head><body><main><div class="eyebrow">SIMSTOCK3 · SAMPLE \(sample.rawValue) BASELINE</div><h1>\(reportTitle)</h1><p class="sub">固定技術資料快照 · 起始本金 600 萬元\(isNineYearABProfile && candidate == .baseline ? " · 九年初始基準，不與舊窗口直接比較" : " · 與 \(referenceRunID) 比較")</p>
        <section class="panel"><div class="head"><h2>本版規則變更</h2></div><div class="opinion">\(escape(report.ruleChangeSummary ?? "未記錄規則變更摘要；請依策略規則版本與規則 commit 查核。"))</div></section>
        <section class="panel"><div class="head"><h2>分析摘要</h2></div><div class="opinion">\(escape(analysisCommentary(report, reference: reference)))</div></section>
        \(crossSampleInterpretationSection(report, crossSample: crossSample))
        <section class="cards"><article class="card primary"><div class="label">兩股群主分數</div><div class="value">\(number(report.combinedScore))</div><div>參考 \(number(reference?.combinedScore)) · 差異 \(delta(report.combinedScore, reference?.combinedScore))</div></article><article class="card"><div class="label">\(firstGroup)</div><div class="value h">\(number(h?.mainScore))</div><div class="muted">參考 \(number(referenceH?.mainScore)) · 差異 \(delta(h?.mainScore, referenceH?.mainScore))</div></article><article class="card"><div class="label">\(secondGroup)</div><div class="value l">\(number(l?.mainScore))</div><div class="muted">參考 \(number(referenceL?.mainScore)) · 差異 \(delta(l?.mainScore, referenceL?.mainScore))</div></article><article class="card"><div class="label">資料品質</div><div class="value">100%</div><div class="muted">無 0、Inf 或 NaN</div></article></section>
        <section class="panel"><div class="head"><h2>本次回測設定</h2></div><div class="meta"><div><span>歷史資料</span>\(historyStartText)–\(report.through)</div><div><span>\(isFullWindowStress ? "全程窗口" : "固定三年窗口")</span>\(windowDescriptions)</div><div><span>本金／加碼</span>600 萬／2 次</div><div><span>資料／策略規則</span>\(report.dataRuleVersion ?? "未記錄")<br>\(report.ruleVersion)<br>\(report.ruleCommit ?? "未記錄規則 commit")</div></div><p class="note">\(isFullWindowStress ? "全程壓力測試只使用 \(dateText(firstSimulationStart)) 起始至資料截止日的一個窗口，不納入固定三年主分。" : "三個主期間各自只模擬三年；少於六個有效期間時不去除最佳期。")</p></section>
        <section class="panel"><div class="head"><h2>\(comparisonSectionTitle)</h2></div><div class="table"><table><thead><tr><th>起始日</th><th>期間</th><th>股群 1 參考</th><th>股群 1 本次</th><th>差異</th><th>股群 2 參考</th><th>股群 2 本次</th><th>差異</th><th>合計參考</th><th>合計本次</th><th>差異</th></tr></thead><tbody>\(periodRows)</tbody></table></div><p class="note">\(comparisonNote) ROI ≥ 0：分數 = ROI × 100 ÷平均天數；ROI &lt; 0：分數 = ROI × 平均天數 ÷ 100。</p></section>
        <section class="panel"><div class="head"><h2>逐股逐期結果</h2></div><div class="table"><table><thead><tr><th>起始日</th><th>股群</th><th>股票</th><th>實年報酬</th><th>平均週期</th><th>評等</th><th>狀態</th></tr></thead><tbody>\(stockRows)</tbody></table></div></section>
        <p class="sub">產生時間 \(report.createdAt) · \(report.runID)</p></main></body></html>
        """
    }

    private static func requiredDate(_ text: String) -> Date {
        guard let date = twDateTime.dateFromString(text) else { preconditionFailure(text) }
        return date
    }

    private static func dateText(_ date: Date) -> String { twDateTime.stringFromDate(date) }
    private static func compactDate(_ date: Date) -> String { twDateTime.stringFromDate(date, format: "yyyyMMdd") }
    private static func format(_ value: Double, _ digits: Int) -> String { String(format: "%.*f", digits, value) }
    private static func number(_ value: Double?, digits: Int = 2) -> String { value.map { format($0, digits) } ?? "—" }
    private static func percent(_ value: Double?) -> String { value.map { format($0, 1) + "%" } ?? "—" }
    private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }
    private static func analysisCommentary(_ report: Baseline, reference: Baseline?) -> String {
        guard let reference else {
            return "本次資料／策略規則為 \(report.dataRuleVersion ?? "未記錄")／\(report.ruleVersion)；"
                + "找不到參考 Baseline，無法產生差異摘要。"
        }
        let firstGroup = groupNames[0]
        let secondGroup = groupNames[1]
        let h = report.groups.first { $0.group == firstGroup }
        let l = report.groups.first { $0.group == secondGroup }
        let referenceH = reference.groups.first
        let referenceL = reference.groups.dropFirst().first
        let periodDeltas = report.periods.compactMap { period -> Double? in
            guard period.group == firstGroup,
                  let currentH = period.score,
                  let currentL = report.periods.first(where: {
                      $0.group == secondGroup && $0.periodStart == period.periodStart
                  })?.score,
                  let oldH = reference.periods.first(where: {
                      $0.group == referenceH?.group && $0.periodStart == period.periodStart
                  })?.score,
                  let oldL = reference.periods.first(where: {
                      $0.group == referenceL?.group && $0.periodStart == period.periodStart
                  })?.score else {
                return nil
            }
            return (currentH + currentL) - (oldH + oldL)
        }
        let higher = periodDeltas.filter { $0 > 0 }.count
        let lower = periodDeltas.filter { $0 < 0 }.count
        let windowSummary = isFullWindowStress
            ? "全期間合計差異 \(delta(report.combinedScore, reference.combinedScore))。"
            : "\(periodDeltas.count) 個固定窗口中 \(higher) 個較高、\(lower) 個較低。"
        let comparisonMeaning = "兩者輸入樣本相同，正負差異可用來判讀規則版本變化。"
        return "本次資料／策略規則為 \(report.dataRuleVersion ?? "未記錄")／\(report.ruleVersion)，"
            + "參考 Baseline 為 \(reference.runID)。"
            + "股群 1 \(delta(h?.mainScore, referenceH?.mainScore))、"
            + "股群 2 \(delta(l?.mainScore, referenceL?.mainScore))、"
            + "合計 \(delta(report.combinedScore, reference.combinedScore))；"
            + windowSummary
            + "股群 1 平均 ROI \(delta(h?.averageROI, referenceH?.averageROI))、平均週期 \(delta(h?.averageDays, referenceH?.averageDays)) 天；"
            + "股群 2 平均 ROI \(delta(l?.averageROI, referenceL?.averageROI))、平均週期 \(delta(l?.averageDays, referenceL?.averageDays)) 天。"
            + comparisonMeaning
    }

    private static var groupNames: [String] {
        sample.members.reduce(into: [String]()) { result, member in
            if !result.contains(member.group) { result.append(member.group) }
        }
    }

    private static var comparisonSectionTitle: String {
        if isNineYearABProfile && candidate == .baseline {
            return "九年初始 Baseline 各窗口"
        }
        if sample == .b {
            return isFullWindowStress
                ? "上一版 Baseline B 與新版全期間比較"
                : "上一版 Baseline B 與新版各窗口比較"
        }
        return isFullWindowStress
            ? "上一版 Baseline 與新版全期間比較"
            : "上一版 Baseline 與新版各期間比較"
    }

    private static func crossSampleInterpretationSection(
        _ report: Baseline,
        crossSample: Baseline?
    ) -> String {
        guard sample == .b else { return "" }
        guard let crossSample else {
            return """
            <section class="panel"><div class="head"><h2>與 Baseline A 的比較解讀</h2></div><div class="opinion">找不到同版 Baseline A，暫時無法產生跨樣本數值比較。</div></section>
            """
        }
        let bFirst = report.groups.first
        let bSecond = report.groups.dropFirst().first
        let aFirst = crossSample.groups.first
        let aSecond = crossSample.groups.dropFirst().first
        let windowSummary: String = {
            let deltas = report.periods.compactMap { period -> Double? in
                guard period.group == bFirst?.group,
                      let b1 = period.score,
                      let b2 = report.periods.first(where: {
                          $0.group == bSecond?.group && $0.periodStart == period.periodStart
                      })?.score,
                      let a1 = crossSample.periods.first(where: {
                          $0.group == aFirst?.group && $0.periodStart == period.periodStart
                      })?.score,
                      let a2 = crossSample.periods.first(where: {
                          $0.group == aSecond?.group && $0.periodStart == period.periodStart
                      })?.score else { return nil }
                return (b1 + b2) - (a1 + a2)
            }
            guard !deltas.isEmpty else { return "沒有可對齊的窗口。" }
            return "各窗口 B−A 為 " + deltas.map { String(format: "%+.2f", $0) }.joined(separator: "、") + "。"
        }()
        return """
        <section class="panel"><div class="head"><h2>與同版 Baseline A 的比較解讀</h2></div><div class="opinion">Baseline B 相較 A：股群 1 \(delta(bFirst?.mainScore, aFirst?.mainScore))、股群 2 \(delta(bSecond?.mainScore, aSecond?.mainScore))、合計 \(delta(report.combinedScore, crossSample.combinedScore))；\(windowSummary) A、B 使用相同策略規則與窗口但股票不同，因此差異表示樣本敏感度，不表示規則本身改善或退步。依<a href="../../../doc/選股評等.md">選股評等</a>的用途，策略應盡量讓適合者累積為 <strong>wow</strong>，並把低效率股票辨識至 <strong>weak</strong> 以下；Sample B 是代表性驗證樣本，不是實際推薦買進清單。</div></section>
        """
    }

    private static var comparisonNote: String {
        if isNineYearABProfile && candidate == .baseline {
            return "這是新資料範圍的初始基準；舊 Baseline 窗口不同，不直接計算改善或退步。"
        }
        return "同一樣本比較；正值代表新版改善，負值代表退步。"
    }
    private static func delta(_ candidate: Double?, _ reference: Double?) -> String {
        guard let candidate, let reference else { return "—" }
        return String(format: "%+.2f", candidate - reference)
    }
    private static func deltaClass(_ candidate: Double?, _ reference: Double?) -> String {
        guard let candidate, let reference else { return "neutral" }
        if candidate > reference { return "positive" }
        if candidate < reference { return "negative" }
        return "neutral"
    }
    private static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    private static func csvEscape(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private static func removeSidecars(for storeURL: URL) {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(atPath: storeURL.path + suffix)
        }
    }

    private static func removeStore(at storeURL: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: storeURL)
        removeSidecars(for: storeURL)
    }

    private static func publishBrowseSnapshot(from source: URL, in documents: URL) throws {
        let directoryURL = documents.appendingPathComponent(
            "InternalBacktest/\(sample.browseDirectoryName)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let destination = directoryURL.appendingPathComponent("browse.store")
        removeStore(at: destination)
        try copyStore(from: source, to: destination)
    }

    private static func copyStore(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: source.path + suffix) {
            try fm.copyItem(
                atPath: source.path + suffix,
                toPath: destination.path + suffix
            )
        }
    }

    private static func moveSidecars(from source: URL, to destination: URL) {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: source.path + suffix) {
            try? fm.moveItem(atPath: source.path + suffix, toPath: destination.path + suffix)
        }
    }
}
#endif
