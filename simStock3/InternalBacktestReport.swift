import Foundation
import SwiftData

#if DEBUG
@MainActor
enum InternalBacktestReport {
    enum Candidate: String {
        case baseline
        case removeST01g
        case investCooldown45
        case noInvestCooldown
        case removeGradeActivationGate
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
        case sn0203FineHighGroup
        case sn0203HighGeneralGroup
        case sn05HighOrBetter
        case sn05WeakOrBetter
    }

    static let candidate: Candidate = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--candidate-remove-st01g") { return .removeST01g }
        if arguments.contains("--candidate-invest-cooldown45") { return .investCooldown45 }
        if arguments.contains("--candidate-no-invest-cooldown") { return .noInvestCooldown }
        if arguments.contains("--candidate-remove-grade-activation-gate") {
            return .removeGradeActivationGate
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
        if arguments.contains("--candidate-sn0203-fine-high-group") {
            return .sn0203FineHighGroup
        }
        if arguments.contains("--candidate-sn0203-high-general-group") {
            return .sn0203HighGeneralGroup
        }
        if arguments.contains("--candidate-sn05-high-or-better") {
            return .sn05HighOrBetter
        }
        if arguments.contains("--candidate-sn05-weak-or-better") {
            return .sn05WeakOrBetter
        }
        return .baseline
    }()
    static let isSummaryOnly = ProcessInfo.processInfo.arguments.contains("--summary-only")
    static let isHN09Diagnostic =
        ProcessInfo.processInfo.arguments.contains("--diagnose-hn09")
    static let sample: InternalBacktestDataset.Sample =
        ProcessInfo.processInfo.arguments.contains("--sample-b") ? .b : .a
    static let isFullWindowStress =
        ProcessInfo.processInfo.arguments.contains("--full-window-stress")
    static let ruleCommit: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--rule-commit"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }()
    static let runID: String = {
        if isHN09Diagnostic {
            return sample == .b
                ? "h19-d-b-hn09-threshold-diagnostic-fixed3y-20260803"
                : "h19-d-a-hn09-threshold-diagnostic-fixed3y-20260803"
        }
        switch candidate {
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
        case .sn0203FineHighGroup:
            return sample == .b
                ? "s13a-b-sn0203-fine-high-group-fixed3y-600w-20260803"
                : "s13a-a-sn0203-fine-high-group-fixed3y-600w-20260803"
        case .sn0203HighGeneralGroup:
            return sample == .b
                ? "s13b-b-sn0203-high-general-group-fixed3y-600w-20260803"
                : "s13b-a-sn0203-high-general-group-fixed3y-600w-20260803"
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
        case .baseline:
            break
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
    static let referenceRunID: String = {
        if candidate == .hp01LowerLoose || candidate == .hp01LowerStrict
            || candidate == .hp01LowUpper19 || candidate == .hp01LowUpper21
            || candidate == .hp01LowUpper15 || candidate == .hp01LowUpper25
            || candidate == .hp01OtherUpper24 || candidate == .hp01OtherUpper26
            || candidate == .hp01OtherUpper20 || candidate == .hp01OtherUpper30 {
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
                ? "baseline-b-s7-score-grade-fullstress-600w-20260802"
                : "baseline-b-s7-score-grade-fixed3y-600w-20260802"
        }
        if isFullWindowStress {
            return "baseline-s7-score-grade-fullstress-600w-20260802"
        }
        return "baseline-s7-score-grade-fixed3y-600w-20260802"
    }()
    static let reportTitle: String = {
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
        if sample == .b {
            return isFullWindowStress
                ? "Sample B · S8 S-N05 high 門檻 2019–2026 全程壓力測試"
                : "Sample B · S8 S-N05 high 門檻固定三年 Baseline"
        }
        if isFullWindowStress {
            return "Sample A · S8 S-N05 high 門檻 2019–2026 全程壓力測試"
        }
        return "Sample A · S8 S-N05 high 門檻固定三年 Baseline"
    }()
    static let moneyBaseWan = 600.0
    static let automaticInvestments = 2.0
    static let currentRuleVersion: String = {
        switch candidate {
        case .baseline: return "s8-sn05-high-grade-20260803"
        case .removeST01g: return "s6-candidate-remove-st01g"
        case .investCooldown45: return "s6-candidate-invest-cooldown45"
        case .noInvestCooldown: return "s6-candidate-no-invest-cooldown"
        case .removeGradeActivationGate: return "s6-candidate-remove-grade-activation-gate"
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
        case .sn0203FineHighGroup:
            return "s7-candidate-sn0203-fine-high-group"
        case .sn0203HighGeneralGroup:
            return "s7-candidate-sn0203-high-general-group"
        case .sn05HighOrBetter:
            return "s7-candidate-sn05-high-or-better"
        case .sn05WeakOrBetter:
            return "s7-candidate-sn05-weak-or-better"
        }
    }()
    static let firstSimulationStart = requiredDate("2019/01/02")
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

        var errorDescription: String? {
            switch self {
            case .missingInput(let url): return "找不到基準快照：\(url.path)"
            case .noPeriods: return "沒有符合完整三年的回測期間。"
            case .invalidValues(let detail): return "偵測到 0、Inf 或 NaN，已停止回測：\(detail)"
            case .missingStocks: return "基準快照內沒有股票。"
            }
        }
    }

    static func run(progress: (String) -> Void = { _ in }) throws -> Result {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inputURL = documents
            .appendingPathComponent(
                "InternalBacktest/\(sample.baselineDirectoryName)",
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
            if index == 0 {
                firstPeriodStore = periodStore
                stockCount = periodResult.stockCount
                tradeCount = periodResult.tradeCount
            } else {
                try fm.removeItem(at: periodStore)
                removeSidecars(for: periodStore)
            }
        }
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
            historyStart: "2018/01/02",
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

        let excluded = allStocks.filter { $0.status == "無成交，不計分" }.count
        let manifest = Manifest(
            sampleID: sample.rawValue,
            runID: runID,
            createdAt: createdAt,
            inputStore: "\(sample.baselineDirectoryName)/baseline.store",
            browseStore: "browse.store",
            reportFiles: isHN09Diagnostic
                ? ["baseline.json", "periods.csv", "manifest.json", "hn09-diagnostic.csv"]
                : (isSummaryOnly
                    ? ["baseline.json", "periods.csv", "manifest.json"]
                    : ["report.html", "baseline.json", "periods.csv", "manifest.json"]),
            dataRuleVersion: Technical.dataRuleVersion,
            ruleVersion: currentRuleVersion,
            ruleCommit: ruleCommit,
            historyStart: "2018/01/02",
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
        if isFullWindowStress {
            try publishBrowseSnapshot(from: browseStoreURL, in: documents)
        }
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
            hn09DiagnosticRows: exactHN09Rows
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
        let crossSampleRunID = isFullWindowStress
            ? "baseline-s8-sn05-high-grade-fullstress-600w-20260803"
            : "baseline-s8-sn05-high-grade-fixed3y-600w-20260803"
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
        </style></head><body><main><div class="eyebrow">SIMSTOCK3 · SAMPLE \(sample.rawValue) BASELINE</div><h1>\(reportTitle)</h1><p class="sub">固定技術資料快照 · 起始本金 600 萬元 · 與 \(referenceRunID) 比較</p>
        <section class="panel"><div class="head"><h2>分析摘要</h2></div><div class="opinion">\(escape(analysisCommentary(report, reference: reference)))</div></section>
        \(crossSampleInterpretationSection(report, crossSample: crossSample))
        <section class="cards"><article class="card primary"><div class="label">兩股群主分數</div><div class="value">\(number(report.combinedScore))</div><div>參考 \(number(reference?.combinedScore)) · 差異 \(delta(report.combinedScore, reference?.combinedScore))</div></article><article class="card"><div class="label">\(firstGroup)</div><div class="value h">\(number(h?.mainScore))</div><div class="muted">參考 \(number(referenceH?.mainScore)) · 差異 \(delta(h?.mainScore, referenceH?.mainScore))</div></article><article class="card"><div class="label">\(secondGroup)</div><div class="value l">\(number(l?.mainScore))</div><div class="muted">參考 \(number(referenceL?.mainScore)) · 差異 \(delta(l?.mainScore, referenceL?.mainScore))</div></article><article class="card"><div class="label">資料品質</div><div class="value">100%</div><div class="muted">無 0、Inf 或 NaN</div></article></section>
        <section class="panel"><div class="head"><h2>本次回測設定</h2></div><div class="meta"><div><span>歷史資料</span>2018/01/02–\(report.through)</div><div><span>\(isFullWindowStress ? "全程窗口" : "固定三年窗口")</span>\(windowDescriptions)</div><div><span>本金／加碼</span>600 萬／2 次</div><div><span>資料／策略規則</span>\(report.dataRuleVersion ?? "未記錄")<br>\(report.ruleVersion)<br>\(report.ruleCommit ?? "未記錄規則 commit")</div></div><p class="note">\(isFullWindowStress ? "全程壓力測試只使用 2019 起始至資料截止日的一個窗口，不納入固定三年主分。" : "三個主期間各自只模擬三年；最後一段由資料截止日倒推三年，因此可與前一段部分重疊。少於六個有效期間時不去除最佳期。")</p></section>
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
            <section class="panel"><div class="head"><h2>與 Baseline A 的比較解讀</h2></div><div class="opinion">找不到同版 S8 Baseline A，暫時無法產生跨樣本數值比較。</div></section>
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
        <section class="panel"><div class="head"><h2>與同版 Baseline A 的比較解讀</h2></div><div class="opinion">S8 Baseline B 相較 A：股群 1 \(delta(bFirst?.mainScore, aFirst?.mainScore))、股群 2 \(delta(bSecond?.mainScore, aSecond?.mainScore))、合計 \(delta(report.combinedScore, crossSample.combinedScore))；\(windowSummary) A、B 使用相同 S8 規則與窗口但股票不同，因此差異表示樣本敏感度，不表示規則本身改善或退步。依<a href="../../../doc/選股評等.md">選股評等</a>的用途，策略應盡量讓適合者累積為 <strong>wow</strong>，並把低效率股票辨識至 <strong>weak</strong> 以下；Sample B 是代表性驗證樣本，不是實際推薦買進清單。</div></section>
        """
    }

    private static var comparisonNote: String {
        "同一樣本比較；正值代表新版改善，負值代表退步。"
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
