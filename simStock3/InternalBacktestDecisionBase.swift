import Foundation
import SQLite3

#if DEBUG
@MainActor
enum InternalBacktestDecisionRecorder {
    enum Phase: Int, Codable, CaseIterable {
        case grade = 0
        case hBuy = 1
        case lBuy = 2
        case sell = 3
        case add = 4

        var code: String {
            switch self {
            case .grade: "GRADE"
            case .hBuy: "H_BUY"
            case .lBuy: "L_BUY"
            case .sell: "SELL"
            case .add: "ADD"
            }
        }
    }

    struct Vote: Codable, Equatable {
        let ruleID: String
        let contribution: Double
    }

    /// P6a stores only normalized technical inputs for L-buy boundary events.
    /// Simulation state remains in `decision_events`; this value is shared by
    /// stock/date so overlapping fixed windows do not duplicate technical data.
    struct TechnicalObservation: Equatable {
        let closeChangePercent: Double
        let highDiff: Double
        let lowDiff: Double
        let highDiffZ125: Double
        let highDiffZ250: Double
        let lowDiffZ125: Double
        let lowDiffZ250: Double
        let ma20Days: Double
        let ma20Diff: Double
        let ma20DiffZ125: Double
        let ma20DiffZ250: Double
        let ma60Days: Double
        let ma60Diff: Double
        let ma60DiffZ125: Double
        let ma60DiffZ250: Double
        let priceZ125: Double
        let priceZ250: Double
        let kdK: Double
        let kdKZ125: Double
        let kdKZ250: Double
        let kdD: Double
        let kdDZ125: Double
        let kdDZ250: Double
        let kdJ: Double
        let kdJZ125: Double
        let kdJZ250: Double
        let osc: Double
        let oscZ125: Double
        let oscZ250: Double
        let volumeMA20Days: Double
        let volumeMA20Diff: Double
        let volumeMA20DiffZ125: Double
        let volumeMA20DiffZ250: Double
        let volumeMA60Days: Double
        let volumeMA60Diff: Double
        let volumeMA60DiffZ125: Double
        let volumeMA60DiffZ250: Double
        let volumeZ125: Double
        let volumeZ250: Double
        let minimum9Mask: Int
        let maximum9Mask: Int
    }

    /// FT1 research-only state captured before the day's Grade/H/L/S/A decisions.
    /// The EMA is updated only after the entire simulation day has completed, so
    /// these values never contain the current day's resulting state.
    struct StrategyFitObservation: Equatable {
        let fitLevel: Double
        let fitFast: Double?
        let fitSlow: Double?
        let fitTrend: Double?
        let fitTrendPhaseRaw: Int
        let fitEvidenceRounds: Double
        let fitEvidenceDays: Double
        let fitObservationCount: Int
        let roiTrend: Double?
        let daysTrend: Double?
        let gradeName: String
        let gradeActivationPassed: Bool
        let hasInventory: Bool
        let isValid: Bool
        let isFinite: Bool
    }

    struct StrategyFitEMA: Equatable {
        static let fastPeriod = 20
        static let slowPeriod = 125

        private(set) var fitFast: Double?
        private(set) var fitSlow: Double?
        private(set) var roiFast: Double?
        private(set) var roiSlow: Double?
        private(set) var daysFast: Double?
        private(set) var daysSlow: Double?
        private(set) var observationCount = 0
        private(set) var fitTrendPhase: StrategyFitTrendPhase = .unavailable

        var fitTrend: Double? { difference(fitFast, fitSlow) }
        var roiTrend: Double? { difference(roiFast, roiSlow) }
        var daysTrend: Double? { difference(daysFast, daysSlow) }
        var isValid: Bool {
            observationCount > 0
                && [fitFast, fitSlow, roiFast, roiSlow, daysFast, daysSlow]
                    .allSatisfy { $0?.isFinite == true }
        }

        mutating func update(fitLevel: Double, roi: Double, days: Double) {
            guard fitLevel.isFinite, roi.isFinite, days.isFinite else { return }
            fitFast = Self.updated(fitFast, with: fitLevel, period: Self.fastPeriod)
            fitSlow = Self.updated(fitSlow, with: fitLevel, period: Self.slowPeriod)
            fitTrendPhase = StrategyFitTrendPhaseUpdater.next(
                fitTrend: fitTrend,
                previousPhase: fitTrendPhase
            )
            roiFast = Self.updated(roiFast, with: roi, period: Self.fastPeriod)
            roiSlow = Self.updated(roiSlow, with: roi, period: Self.slowPeriod)
            daysFast = Self.updated(daysFast, with: days, period: Self.fastPeriod)
            daysSlow = Self.updated(daysSlow, with: days, period: Self.slowPeriod)
            observationCount += 1
        }

        private static func updated(_ previous: Double?, with value: Double, period: Int) -> Double {
            guard let previous else { return value }
            let alpha = 2 / Double(period + 1)
            return previous + alpha * (value - previous)
        }

        private func difference(_ lhs: Double?, _ rhs: Double?) -> Double? {
            guard let lhs, let rhs else { return nil }
            return lhs - rhs
        }
    }

    struct PendingEvent {
        let windowStart: String
        let windowEnd: String
        let stockID: String
        let stockName: String
        let group: String
        let date: String
        let phase: Phase
        let grade: Int
        let gradeName: String
        let score: Double
        let threshold: Double?
        let plannedAction: String
        let inventoryBefore: Double
        let unitCostBefore: Double
        let unitROIBefore: Double
        let holdingDaysBefore: Double
        let investTimesBefore: Double
        let balanceBefore: Double
        let rollROIBefore: Double
        let rollDaysBefore: Double
        let rollRoundsBefore: Double
        let buyRuleBefore: String
        let stateFingerprint: Int64
        let votes: [Vote]
        let passedGateIDs: [String]
        let technicalObservation: TechnicalObservation?
        let strategyFitObservation: StrategyFitObservation?
    }

    struct Event {
        let pending: PendingEvent
        let executedAction: String
    }

    struct Configuration {
        let sampleID: String
        let inputSnapshotID: String
        let decisionBaseID: String
        let dataRuleVersion: String
        let ruleVersion: String
        let ruleCommit: String
        let through: String
        let moneyBaseWan: Double
        let automaticInvestments: Double
    }

    private struct RuleDefinition: Codable {
        let ruleID: String
        let phase: String
        let kind: String
        let description: String
    }

    private struct Manifest: Codable {
        let formatVersion: Int
        let createdAt: String
        let sampleID: String
        let inputSnapshotID: String
        let decisionBaseID: String
        let dataRuleVersion: String
        let ruleVersion: String
        let ruleCommit: String
        let through: String
        let moneyBaseWan: Double
        let automaticInvestments: Double
        let eventCount: Int
        let voteCount: Int
        let gateCount: Int
        let stockCount: Int
        let windowCount: Int
        let outcomeCount: Int
        let technicalObservationCount: Int
        let technicalObservationLinkCount: Int
        let strategyFitObservationCount: Int
        let strategyFitObservationLinkCount: Int
        let sqliteBytes: Int64
        let files: [String]
    }

    private struct DistributionSummary: Codable {
        struct Count: Codable {
            let key: String
            let count: Int
        }

        let eventCount: Int
        let voteCount: Int
        let gateCount: Int
        let byPhase: [Count]
        let byGrade: [Count]
        let byWindow: [Count]
        let byStock: [Count]
        let byRule: [Count]
    }

    private static var configuration: Configuration?
    private static var currentWindowEnd = ""
    private static var strategyFitStates: [String: StrategyFitEMA] = [:]
    private(set) static var events: [Event] = []

    static var isEnabled: Bool {
        configuration != nil
    }

    static func begin(_ value: Configuration) {
        configuration = value
        currentWindowEnd = ""
        events.removeAll(keepingCapacity: true)
        strategyFitStates.removeAll(keepingCapacity: true)
    }

    static func beginWindow(end: Date) {
        guard isEnabled else { return }
        currentWindowEnd = dateText(end)
    }

    static func reset() {
        configuration = nil
        currentWindowEnd = ""
        events.removeAll(keepingCapacity: false)
        strategyFitStates.removeAll(keepingCapacity: false)
    }

    static func makePending(
        trade: Trade,
        grade: Trade.Grade,
        phase: Phase,
        score: Double,
        threshold: Double?,
        plannedAction: String,
        votes: [Vote],
        passedGateIDs: [String] = [],
        technicalObservation: TechnicalObservation? = nil,
        strategyFitObservation: StrategyFitObservation? = nil
    ) -> PendingEvent? {
        guard isEnabled, !trade.isBeforeSimulationStart else { return nil }
        let fingerprint = stateFingerprint(
            trade: trade,
            grade: grade,
            includesGradeOutput: phase != .grade
        )
        return PendingEvent(
            windowStart: dateText(trade.stock.dateStart),
            windowEnd: currentWindowEnd,
            stockID: trade.stock.sId,
            stockName: trade.stock.sName,
            group: trade.stock.group,
            date: dateText(trade.dateTime),
            phase: phase,
            grade: grade.rawValue,
            gradeName: gradeText(grade),
            score: score,
            threshold: threshold,
            plannedAction: plannedAction,
            inventoryBefore: trade.simQtyInventory,
            unitCostBefore: trade.simUnitCost,
            unitROIBefore: trade.simUnitRoi,
            holdingDaysBefore: trade.simDays,
            investTimesBefore: trade.simInvestTimes,
            balanceBefore: trade.simAmtBalance,
            rollROIBefore: trade.rollAmtRoi,
            rollDaysBefore: trade.rollDays,
            rollRoundsBefore: trade.rollRounds,
            buyRuleBefore: trade.simRuleBuy,
            stateFingerprint: fingerprint,
            votes: votes.filter { $0.contribution != 0 },
            passedGateIDs: Array(Set(passedGateIDs)).sorted(),
            technicalObservation: technicalObservation,
            strategyFitObservation: strategyFitObservation
        )
    }

    static func updateStrategyFitState(after trade: Trade) {
        guard isEnabled, !trade.isBeforeSimulationStart, trade.days > 0 else { return }
        let key = strategyFitKey(trade)
        var state = strategyFitStates[key] ?? StrategyFitEMA()
        state.update(
            fitLevel: trade.gradeEfficiencyScore,
            roi: trade.roi,
            days: trade.days
        )
        strategyFitStates[key] = state
    }

    private static func makeStrategyFitObservation(
        trade: Trade,
        grade: Trade.Grade,
        activationPassed: Bool
    ) -> StrategyFitObservation {
        let state = strategyFitStates[strategyFitKey(trade)] ?? StrategyFitEMA()
        return StrategyFitObservation(
            fitLevel: trade.gradeEfficiencyScore,
            fitFast: state.fitFast,
            fitSlow: state.fitSlow,
            fitTrend: state.fitTrend,
            fitTrendPhaseRaw: state.fitTrendPhase.rawValue,
            fitEvidenceRounds: trade.rollRounds,
            fitEvidenceDays: trade.rollDays,
            fitObservationCount: state.observationCount,
            roiTrend: state.roiTrend,
            daysTrend: state.daysTrend,
            gradeName: gradeText(grade),
            gradeActivationPassed: activationPassed,
            hasInventory: trade.simQtyInventory > 0,
            isValid: state.isValid,
            isFinite: trade.gradeEfficiencyScore.isFinite
                && trade.rollRounds.isFinite
                && trade.rollDays.isFinite
                && [state.fitFast, state.fitSlow, state.fitTrend, state.roiTrend, state.daysTrend]
                    .allSatisfy { $0 == nil || $0?.isFinite == true }
        )
    }

    private static func strategyFitKey(_ trade: Trade) -> String {
        [dateText(trade.stock.dateStart), currentWindowEnd, trade.stock.sId]
            .joined(separator: "|")
    }

    static func makeLBuyTechnicalObservation(
        trade: Trade,
        previousClose: Double,
        score: Double
    ) -> TechnicalObservation? {
        guard isEnabled, score >= 4, score <= 6, previousClose > 0 else { return nil }
        let minimum9Mask =
            (trade.tMa20Diff == trade.tMa20DiffMin9 ? 1 << 0 : 0)
            | (trade.tMa60Diff == trade.tMa60DiffMin9 ? 1 << 1 : 0)
            | (trade.tOsc == trade.tOscMin9 ? 1 << 2 : 0)
            | (trade.tKdK == trade.tKdKMin9 ? 1 << 3 : 0)
            | (trade.volumeClose == trade.vMin9 ? 1 << 4 : 0)
        let maximum9Mask =
            (trade.tMa20Diff == trade.tMa20DiffMax9 ? 1 << 0 : 0)
            | (trade.tMa60Diff == trade.tMa60DiffMax9 ? 1 << 1 : 0)
            | (trade.tOsc == trade.tOscMax9 ? 1 << 2 : 0)
            | (trade.tKdK == trade.tKdKMax9 ? 1 << 3 : 0)
            | (trade.volumeClose == trade.vMax9 ? 1 << 4 : 0)
        return TechnicalObservation(
            closeChangePercent: 100 * (trade.priceClose - previousClose) / previousClose,
            highDiff: trade.tHighDiff,
            lowDiff: trade.tLowDiff,
            highDiffZ125: trade.tHighDiffZ125,
            highDiffZ250: trade.tHighDiffZ250,
            lowDiffZ125: trade.tLowDiffZ125,
            lowDiffZ250: trade.tLowDiffZ250,
            ma20Days: trade.tMa20Days,
            ma20Diff: trade.tMa20Diff,
            ma20DiffZ125: trade.tMa20DiffZ125,
            ma20DiffZ250: trade.tMa20DiffZ250,
            ma60Days: trade.tMa60Days,
            ma60Diff: trade.tMa60Diff,
            ma60DiffZ125: trade.tMa60DiffZ125,
            ma60DiffZ250: trade.tMa60DiffZ250,
            priceZ125: trade.tZ125,
            priceZ250: trade.tZ250,
            kdK: trade.tKdK,
            kdKZ125: trade.tKdKZ125,
            kdKZ250: trade.tKdKZ250,
            kdD: trade.tKdD,
            kdDZ125: trade.tKdDZ125,
            kdDZ250: trade.tKdDZ250,
            kdJ: trade.tKdJ,
            kdJZ125: trade.tKdJZ125,
            kdJZ250: trade.tKdJZ250,
            osc: trade.tOsc,
            oscZ125: trade.tOscZ125,
            oscZ250: trade.tOscZ250,
            volumeMA20Days: trade.vMa20Days,
            volumeMA20Diff: trade.vMa20Diff,
            volumeMA20DiffZ125: trade.vMa20DiffZ125,
            volumeMA20DiffZ250: trade.vMa20DiffZ250,
            volumeMA60Days: trade.vMa60Days,
            volumeMA60Diff: trade.vMa60Diff,
            volumeMA60DiffZ125: trade.vMa60DiffZ125,
            volumeMA60DiffZ250: trade.vMa60DiffZ250,
            volumeZ125: trade.vZ125,
            volumeZ250: trade.vZ250,
            minimum9Mask: minimum9Mask,
            maximum9Mask: maximum9Mask
        )
    }

    static func makeGradePending(
        trade: Trade,
        grade: Trade.Grade,
        activationPassed: Bool
    ) -> PendingEvent? {
        let score = trade.gradeEfficiencyScore
        var gates = activationPassed ? ["G-T01"] : []
        if activationPassed, let gradeRuleID = gradeRuleID(grade) {
            gates.append(gradeRuleID)
        }
        return makePending(
            trade: trade,
            grade: grade,
            phase: .grade,
            score: score,
            threshold: nil,
            plannedAction: activationPassed ? "GRADE" : "NONE",
            votes: [],
            passedGateIDs: gates,
            strategyFitObservation: makeStrategyFitObservation(
                trade: trade,
                grade: grade,
                activationPassed: activationPassed
            )
        )
    }

    static func stateFingerprint(
        trade: Trade,
        grade: Trade.Grade,
        includesGradeOutput: Bool = true
    ) -> Int64 {
        var values: [String] = []
        if includesGradeOutput {
            values.append(String(grade.rawValue))
        }
        values.append(contentsOf: [
            finiteText(trade.simQtyInventory),
            finiteText(trade.simUnitCost),
            finiteText(trade.simUnitRoi),
            finiteText(trade.simDays),
            finiteText(trade.simInvestTimes),
            finiteText(trade.simAmtBalance),
            finiteText(trade.rollAmtRoi),
            finiteText(trade.rollDays),
            finiteText(trade.rollRounds),
            trade.simRuleBuy
        ])
        let canonicalState = values.joined(separator: "|")
        return fnv1a64(canonicalState)
    }

    static func append(_ pending: PendingEvent?, executedAction: String) {
        guard let pending else { return }
        events.append(Event(pending: pending, executedAction: executedAction))
    }

    static func write(
        to directoryURL: URL,
        outcomes: [InternalBacktestReport.StockPeriod]
    ) throws {
        guard let configuration else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: directoryURL.path) {
            try fm.removeItem(at: directoryURL)
        }
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let sqliteURL = directoryURL.appendingPathComponent("decisions.sqlite")
        let writer = try SQLiteWriter(url: sqliteURL)
        try writer.createSchema()
        try writer.write(configuration: configuration, events: events, outcomes: outcomes)
        try writer.close()

        let definitions = ruleDefinitions(for: events)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definitions).write(
            to: directoryURL.appendingPathComponent("rule-catalog.json"),
            options: .atomic
        )

        let summary = distributionSummary(events)
        try encoder.encode(summary).write(
            to: directoryURL.appendingPathComponent("distribution-summary.json"),
            options: .atomic
        )

        let sqliteBytes = (try? sqliteURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        let strategyFitKeys = Set(events.compactMap {
            $0.pending.strategyFitObservation == nil ? nil : strategyFitKey($0.pending)
        })
        let manifest = Manifest(
            formatVersion: 5,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            sampleID: configuration.sampleID,
            inputSnapshotID: configuration.inputSnapshotID,
            decisionBaseID: configuration.decisionBaseID,
            dataRuleVersion: configuration.dataRuleVersion,
            ruleVersion: configuration.ruleVersion,
            ruleCommit: configuration.ruleCommit,
            through: configuration.through,
            moneyBaseWan: configuration.moneyBaseWan,
            automaticInvestments: configuration.automaticInvestments,
            eventCount: events.count,
            voteCount: events.reduce(0) { $0 + $1.pending.votes.count },
            gateCount: events.reduce(0) { $0 + $1.pending.passedGateIDs.count },
            stockCount: Set(events.map { $0.pending.stockID }).count,
            windowCount: Set(events.map { $0.pending.windowStart + "|" + $0.pending.windowEnd }).count,
            outcomeCount: outcomes.count,
            technicalObservationCount: Set(events.compactMap {
                $0.pending.technicalObservation == nil
                    ? nil : $0.pending.stockID + "|" + $0.pending.date
            }).count,
            technicalObservationLinkCount: events.filter {
                $0.pending.technicalObservation != nil
            }.count,
            strategyFitObservationCount: strategyFitKeys.count,
            strategyFitObservationLinkCount: events.filter {
                strategyFitKeys.contains(strategyFitKey($0.pending))
            }.count,
            sqliteBytes: sqliteBytes,
            files: ["decisions.sqlite", "distribution-summary.json", "rule-catalog.json", ".complete"]
        )
        try encoder.encode(manifest).write(
            to: directoryURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try configuration.decisionBaseID.write(
            to: directoryURL.appendingPathComponent(".complete"),
            atomically: true,
            encoding: .utf8
        )
        _ = try InternalBacktestDecisionBaseProfiler.write(
            decisionBaseID: configuration.decisionBaseID,
            baselineDirectoryURL: directoryURL
        )
    }

    private static func strategyFitKey(_ pending: PendingEvent) -> String {
        [pending.windowStart, pending.windowEnd, pending.stockID, pending.date]
            .joined(separator: "|")
    }

    private static func distributionSummary(_ events: [Event]) -> DistributionSummary {
        func counts(_ values: [String]) -> [DistributionSummary.Count] {
            Dictionary(grouping: values, by: { $0 })
                .map { DistributionSummary.Count(key: $0.key, count: $0.value.count) }
                .sorted { ($0.count, $1.key) > ($1.count, $0.key) }
        }
        let ruleActivations = events.flatMap { event in
            event.pending.votes.map { event.pending.phase.code + ":" + $0.ruleID }
                + event.pending.passedGateIDs.map { event.pending.phase.code + ":" + $0 }
        }
        return DistributionSummary(
            eventCount: events.count,
            voteCount: events.reduce(0) { $0 + $1.pending.votes.count },
            gateCount: events.reduce(0) { $0 + $1.pending.passedGateIDs.count },
            byPhase: counts(events.map { $0.pending.phase.code }),
            byGrade: counts(events.map { $0.pending.gradeName }),
            byWindow: counts(events.map { $0.pending.windowStart + "–" + $0.pending.windowEnd }),
            byStock: counts(events.map { $0.pending.stockID + " " + $0.pending.stockName }),
            byRule: counts(ruleActivations)
        )
    }

    private static func ruleDefinitions(for events: [Event]) -> [RuleDefinition] {
        var phaseByRule = Dictionary(
            uniqueKeysWithValues: ruleDescriptions.keys.map { ($0, phaseCode(for: $0)) }
        )
        for event in events {
            for vote in event.pending.votes {
                phaseByRule[vote.ruleID] = event.pending.phase.code
            }
            for gate in event.pending.passedGateIDs {
                phaseByRule[gate] = event.pending.phase.code
            }
        }
        return phaseByRule.keys.sorted().map { ruleID in
            RuleDefinition(
                ruleID: ruleID,
                phase: phaseByRule[ruleID] ?? "",
                kind: ruleID.hasPrefix("G-") || ruleID.contains("-T") || ruleID.contains("-E")
                    ? "gate" : "vote",
                description: ruleDescriptions[ruleID] ?? ruleID
            )
        }
    }

    private static let ruleDescriptions: [String: String] = [
        "G-T01": "完成足夠輪次或平均持股週期過長後啟用 Grade",
        "G-P01": "效率分數進入 wow",
        "G-P02": "效率分數進入 high",
        "G-P03": "效率分數進入 fine",
        "G-N03": "效率分數進入 weak",
        "G-N02": "效率分數進入 low",
        "G-N01": "效率分數進入 damn",
        "G-M01": "依 Grade 路由下游規則門檻",
        "H-P01": "MA60 位於適合追高的強勢區間",
        "H-P02": "MA20 領先 MA60 且持續向上",
        "H-P03a": "兩條均線都不弱，才鼓勵追高",
        "H-P03b": "替 damn 股票保留反彈買點",
        "H-P04": "前一完整 TWSE 日爆量後仍維持強勢",
        "H-N01a": "OSC 和 J 都過熱，避免追價",
        "H-N01b": "J 極度過熱，避免追價",
        "H-N02a": "K 太弱，表示追高動能不足",
        "H-N02b": "K 太熱，避免追在短線高點",
        "H-N03": "OSC 偏弱",
        "H-N05": "技術指標落到九日低點",
        "H-N06a": "弱評股短均線波動太大，少追高",
        "H-N06b": "弱評股中期均線波動太大，少追高",
        "H-N07": "damn 額外均線波動扣分",
        "H-N08": "damn 股票 MA20 過熱",
        "H-N09": "價格位置過高",
        "H-N10": "成交量創九日低點",
        "H-C01": "夏季風險扣分",
        "H-C02": "春季風險扣分",
        "H-C03": "八月追高加分",
        "H-C04": "三月追高加分",
        "H-T01": "追高成立門檻",
        "L-P01a": "J 進低檔，增加低接意願",
        "L-P01b": "K 進低檔，增加低接意願",
        "L-P02": "J 進入極端低檔",
        "L-P03": "K 長短期 Z 值偏低",
        "L-P04": "D 長短期 Z 值偏低",
        "L-P05": "OSC 長短期 Z 值偏低",
        "L-P06": "成交量偏低",
        "L-P07": "多項九日低點且 MA60 未過弱",
        "L-P08": "價格位於相對低檔",
        "L-P09": "良好評等股票強烈拉回",
        "L-P10": "weak 或 fine 評等在適配惡化確認解除後增加低接意願",
        "L-N01": "MA20 長期下彎",
        "L-N02": "極端評等且多項指標同創九日低點",
        "L-C01": "夏季風險扣分",
        "L-C02": "差評股票八月底加分",
        "L-C03": "八月承低加分",
        "L-T01": "承低成立門檻",
        "S-P01": "J 絕對過熱",
        "S-P02": "J 長短期相對過熱",
        "S-P03": "K 半年相對過熱",
        "S-P04": "D 半年相對過熱",
        "S-P05": "OSC 長短期相對過熱",
        "S-P06a": "高低價位置都偏高，增加賣出意願",
        "S-P06b": "整體股價位置偏高，補一分賣出意願",
        "S-N01a": "MA60 創九日低點，先別在弱點賣",
        "S-N01b": "MA20 創九日低點，先別在弱點賣",
        "S-N02": "高評等股票收盤大漲時惜賣",
        "S-N03": "一般評等股票盤中大漲時惜賣",
        "S-N04": "多次投入後惜賣",
        "S-N05": "良好評等股票放量時惜賣",
        "S-T01a": "高報酬出口",
        "S-T01b": "極高分一般獲利出口",
        "S-T01c": "高分 Grade ROI 出口",
        "S-T01d": "技術過熱獲利出口",
        "S-T01e": "長期小幅獲利出口",
        "S-T01f": "中高報酬短週期出口",
        "S-T01g": "中報酬短週期出口",
        "S-T01h": "一般報酬短週期出口",
        "S-T02": "長期解套出口",
        "A-P01a": "多項指標都低，鼓勵加碼",
        "A-P01b": "弱評股不必等多項都低，也保留加碼",
        "A-P02": "多項九日低點加分",
        "A-P03": "深度虧損加分",
        "A-P04": "價格位置加分",
        "A-P05": "均線深跌加分",
        "A-P06": "均線 Z 深跌加分",
        "A-P07": "兩均線下跌加分",
        "A-P08": "L買深跌加分；wow 早期邊界訊號除外",
        "A-N01": "依 Grade 的加碼扣分",
        "A-N02": "反彈離低點扣分",
        "A-T01": "深度虧損加碼出口",
        "A-T02": "L買早期小幅虧損加碼出口",
        "A-E": "加碼執行資格"
    ]

    fileprivate static func ruleDescription(_ ruleID: String) -> String {
        ruleDescriptions[ruleID] ?? ruleID
    }

    fileprivate static var knownRuleIDs: [String] {
        ruleDescriptions.keys.sorted()
    }

    fileprivate static func phaseCode(for ruleID: String) -> String {
        if ruleID.hasPrefix("G-") { return Phase.grade.code }
        if ruleID.hasPrefix("H-") { return Phase.hBuy.code }
        if ruleID.hasPrefix("L-") { return Phase.lBuy.code }
        if ruleID.hasPrefix("S-") { return Phase.sell.code }
        if ruleID.hasPrefix("A-") { return Phase.add.code }
        return ""
    }

    private static func gradeRuleID(_ grade: Trade.Grade) -> String? {
        switch grade {
        case .wow: "G-P01"
        case .high: "G-P02"
        case .fine: "G-P03"
        case .none: nil
        case .weak: "G-N03"
        case .low: "G-N02"
        case .damn: "G-N01"
        }
    }

    private static func finiteText(_ value: Double) -> String {
        value.isFinite ? String(format: "%.8f", value) : "invalid"
    }

    private static func dateText(_ date: Date) -> String {
        twDateTime.stringFromDate(date, format: "yyyy/MM/dd")
    }

    private static func gradeText(_ grade: Trade.Grade) -> String {
        switch grade {
        case .wow: "wow"
        case .high: "high"
        case .fine: "fine"
        case .none: "none"
        case .weak: "weak"
        case .low: "low"
        case .damn: "damn"
        }
    }

    private static func fnv1a64(_ text: String) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int64(bitPattern: hash)
    }
}

private final class SQLiteWriter {
    enum WriterError: LocalizedError {
        case open(String)
        case execute(String)
        case prepare(String)
        case bind(String)
        case step(String)

        var errorDescription: String? {
            switch self {
            case .open(let text): "無法建立 DecisionBase SQLite：\(text)"
            case .execute(let text): "DecisionBase SQLite 指令失敗：\(text)"
            case .prepare(let text): "DecisionBase SQLite prepare 失敗：\(text)"
            case .bind(let text): "DecisionBase SQLite bind 失敗：\(text)"
            case .step(let text): "DecisionBase SQLite 寫入失敗：\(text)"
            }
        }
    }

    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(database)
            database = nil
            throw WriterError.open(message)
        }
        try execute("PRAGMA journal_mode = DELETE;")
        try execute("PRAGMA synchronous = FULL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    func close() throws {
        guard let database else { return }
        guard sqlite3_close(database) == SQLITE_OK else {
            throw WriterError.execute(String(cString: sqlite3_errmsg(database)))
        }
        self.database = nil
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func createSchema() throws {
        try execute("""
        CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE stocks (
            stock_key INTEGER PRIMARY KEY,
            stock_id TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            group_name TEXT NOT NULL
        );
        CREATE TABLE windows (
            window_id INTEGER PRIMARY KEY,
            start_date INTEGER NOT NULL,
            end_date INTEGER NOT NULL,
            UNIQUE(start_date, end_date)
        );
        CREATE TABLE rules (
            rule_key INTEGER PRIMARY KEY,
            rule_id TEXT NOT NULL UNIQUE,
            phase INTEGER NOT NULL,
            kind INTEGER NOT NULL,
            description TEXT NOT NULL
        );
        CREATE TABLE decision_events (
            event_id INTEGER PRIMARY KEY,
            window_id INTEGER NOT NULL REFERENCES windows(window_id),
            stock_key INTEGER NOT NULL REFERENCES stocks(stock_key),
            trade_date INTEGER NOT NULL,
            phase INTEGER NOT NULL,
            grade INTEGER NOT NULL,
            decision_score REAL NOT NULL,
            decision_threshold REAL,
            planned_action TEXT NOT NULL,
            executed_action TEXT NOT NULL,
            inventory_before REAL NOT NULL,
            unit_cost_before REAL NOT NULL,
            unit_roi_before REAL NOT NULL,
            holding_days_before REAL NOT NULL,
            invest_times_before REAL NOT NULL,
            balance_before REAL NOT NULL,
            roll_roi_before REAL NOT NULL,
            roll_days_before REAL NOT NULL,
            roll_rounds_before REAL NOT NULL,
            buy_rule_before TEXT NOT NULL,
            state_fingerprint INTEGER NOT NULL,
            UNIQUE(window_id, stock_key, trade_date, phase)
        );
        CREATE TABLE event_votes (
            event_id INTEGER NOT NULL REFERENCES decision_events(event_id) ON DELETE CASCADE,
            rule_key INTEGER NOT NULL REFERENCES rules(rule_key),
            contribution REAL NOT NULL,
            PRIMARY KEY(event_id, rule_key)
        ) WITHOUT ROWID;
        CREATE TABLE event_gates (
            event_id INTEGER NOT NULL REFERENCES decision_events(event_id) ON DELETE CASCADE,
            rule_key INTEGER NOT NULL REFERENCES rules(rule_key),
            PRIMARY KEY(event_id, rule_key)
        ) WITHOUT ROWID;
        CREATE TABLE technical_observations (
            observation_id INTEGER PRIMARY KEY,
            stock_key INTEGER NOT NULL REFERENCES stocks(stock_key),
            trade_date INTEGER NOT NULL,
            close_change_percent REAL NOT NULL,
            high_diff REAL NOT NULL,
            low_diff REAL NOT NULL,
            high_diff_z125 REAL NOT NULL,
            high_diff_z250 REAL NOT NULL,
            low_diff_z125 REAL NOT NULL,
            low_diff_z250 REAL NOT NULL,
            ma20_days REAL NOT NULL,
            ma20_diff REAL NOT NULL,
            ma20_diff_z125 REAL NOT NULL,
            ma20_diff_z250 REAL NOT NULL,
            ma60_days REAL NOT NULL,
            ma60_diff REAL NOT NULL,
            ma60_diff_z125 REAL NOT NULL,
            ma60_diff_z250 REAL NOT NULL,
            price_z125 REAL NOT NULL,
            price_z250 REAL NOT NULL,
            kd_k REAL NOT NULL,
            kd_k_z125 REAL NOT NULL,
            kd_k_z250 REAL NOT NULL,
            kd_d REAL NOT NULL,
            kd_d_z125 REAL NOT NULL,
            kd_d_z250 REAL NOT NULL,
            kd_j REAL NOT NULL,
            kd_j_z125 REAL NOT NULL,
            kd_j_z250 REAL NOT NULL,
            osc REAL NOT NULL,
            osc_z125 REAL NOT NULL,
            osc_z250 REAL NOT NULL,
            volume_ma20_days REAL NOT NULL,
            volume_ma20_diff REAL NOT NULL,
            volume_ma20_diff_z125 REAL NOT NULL,
            volume_ma20_diff_z250 REAL NOT NULL,
            volume_ma60_days REAL NOT NULL,
            volume_ma60_diff REAL NOT NULL,
            volume_ma60_diff_z125 REAL NOT NULL,
            volume_ma60_diff_z250 REAL NOT NULL,
            volume_z125 REAL NOT NULL,
            volume_z250 REAL NOT NULL,
            minimum9_mask INTEGER NOT NULL,
            maximum9_mask INTEGER NOT NULL,
            UNIQUE(stock_key, trade_date)
        );
        CREATE TABLE event_observations (
            event_id INTEGER PRIMARY KEY REFERENCES decision_events(event_id) ON DELETE CASCADE,
            observation_id INTEGER NOT NULL REFERENCES technical_observations(observation_id)
        ) WITHOUT ROWID;
        CREATE TABLE strategy_fit_observations (
            observation_id INTEGER PRIMARY KEY,
            window_id INTEGER NOT NULL REFERENCES windows(window_id),
            stock_key INTEGER NOT NULL REFERENCES stocks(stock_key),
            trade_date INTEGER NOT NULL,
            fit_level REAL NOT NULL,
            fit_fast REAL,
            fit_slow REAL,
            fit_trend REAL,
            fit_trend_phase INTEGER NOT NULL,
            fit_evidence_rounds REAL NOT NULL,
            fit_evidence_days REAL NOT NULL,
            fit_observation_count INTEGER NOT NULL,
            roi_trend REAL,
            days_trend REAL,
            grade_name TEXT NOT NULL,
            grade_activation_passed INTEGER NOT NULL,
            has_inventory INTEGER NOT NULL,
            is_valid INTEGER NOT NULL,
            is_finite INTEGER NOT NULL,
            fast_period INTEGER NOT NULL,
            slow_period INTEGER NOT NULL,
            UNIQUE(window_id, stock_key, trade_date)
        );
        CREATE TABLE event_strategy_fit_observations (
            event_id INTEGER PRIMARY KEY REFERENCES decision_events(event_id) ON DELETE CASCADE,
            observation_id INTEGER NOT NULL REFERENCES strategy_fit_observations(observation_id)
        ) WITHOUT ROWID;
        CREATE TABLE period_outcomes (
            window_id INTEGER NOT NULL REFERENCES windows(window_id),
            stock_key INTEGER NOT NULL REFERENCES stocks(stock_key),
            roi REAL,
            average_days REAL,
            rounds REAL NOT NULL,
            grade_name TEXT NOT NULL,
            money_lacked INTEGER NOT NULL,
            status TEXT NOT NULL,
            PRIMARY KEY(window_id, stock_key)
        ) WITHOUT ROWID;
        CREATE INDEX event_by_grade_phase
            ON decision_events(grade, phase);
        CREATE INDEX vote_by_rule_event
            ON event_votes(rule_key, event_id);
        CREATE INDEX gate_by_rule_event
            ON event_gates(rule_key, event_id);
        CREATE INDEX observation_by_stock_date
            ON technical_observations(stock_key, trade_date);
        CREATE INDEX strategy_fit_by_window_stock_date
            ON strategy_fit_observations(window_id, stock_key, trade_date);
        CREATE VIEW decision_event_lookup AS
            SELECT e.*, s.stock_id, s.name AS stock_name, s.group_name,
                CASE e.phase WHEN 0 THEN 'GRADE' WHEN 1 THEN 'H_BUY' WHEN 2 THEN 'L_BUY'
                    WHEN 3 THEN 'SELL' WHEN 4 THEN 'ADD' END AS phase_name,
                CASE e.grade WHEN 3 THEN 'wow' WHEN 2 THEN 'high' WHEN 1 THEN 'fine'
                    WHEN 0 THEN 'none' WHEN -1 THEN 'weak' WHEN -2 THEN 'low'
                    WHEN -3 THEN 'damn' END AS grade_name,
                printf('%04d/%02d/%02d', e.trade_date / 10000,
                    (e.trade_date / 100) % 100, e.trade_date % 100) AS trade_date_text,
                printf('%d|%s|%d|%d', e.window_id, s.stock_id, e.trade_date, e.phase) AS event_key
            FROM decision_events e JOIN stocks s USING(stock_key);
        CREATE VIEW event_vote_lookup AS
            SELECT v.event_id, r.rule_id, v.contribution
            FROM event_votes v JOIN rules r USING(rule_key);
        CREATE VIEW event_gate_lookup AS
            SELECT g.event_id, r.rule_id
            FROM event_gates g JOIN rules r USING(rule_key);
        CREATE VIEW l_buy_boundary_observation_lookup AS
            SELECT e.event_id, e.window_id, s.stock_id, s.name AS stock_name,
                s.group_name, e.grade, e.decision_score,
                e.decision_threshold, e.planned_action, e.executed_action,
                o.*
            FROM event_observations x
            JOIN decision_events e USING(event_id)
            JOIN stocks s USING(stock_key)
            JOIN technical_observations o USING(observation_id)
            WHERE e.phase = 2;
        CREATE VIEW strategy_fit_event_lookup AS
            SELECT e.event_id, e.window_id, s.stock_id, s.name AS stock_name,
                s.group_name, e.trade_date, e.phase,
                CASE e.phase WHEN 0 THEN 'GRADE' WHEN 1 THEN 'H_BUY' WHEN 2 THEN 'L_BUY'
                    WHEN 3 THEN 'SELL' WHEN 4 THEN 'ADD' END AS phase_name,
                e.decision_score, e.decision_threshold,
                e.planned_action, e.executed_action, o.*
            FROM event_strategy_fit_observations x
            JOIN decision_events e USING(event_id)
            JOIN stocks s USING(stock_key)
            JOIN strategy_fit_observations o USING(observation_id);
        """)
    }

    func write(
        configuration: InternalBacktestDecisionRecorder.Configuration,
        events: [InternalBacktestDecisionRecorder.Event],
        outcomes: [InternalBacktestReport.StockPeriod]
    ) throws {
        guard let database else { throw WriterError.execute("database closed") }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let metadata: [String: String] = [
                "formatVersion": "5",
                "sampleID": configuration.sampleID,
                "inputSnapshotID": configuration.inputSnapshotID,
                "decisionBaseID": configuration.decisionBaseID,
                "dataRuleVersion": configuration.dataRuleVersion,
                "ruleVersion": configuration.ruleVersion,
                "ruleCommit": configuration.ruleCommit,
                "through": configuration.through,
                "moneyBaseWan": String(format: "%.6f", configuration.moneyBaseWan),
                "automaticInvestments": String(format: "%.6f", configuration.automaticInvestments)
            ]
            for key in metadata.keys.sorted() {
                try run(
                    "INSERT INTO metadata(key, value) VALUES(?, ?)",
                    [.text(key), .text(metadata[key] ?? "")]
                )
            }

            let stocks = Dictionary(grouping: events, by: { $0.pending.stockID })
                .compactMapValues(\.first)
            var stockKeys: [String: Int64] = [:]
            for (index, stockID) in stocks.keys.sorted().enumerated() {
                guard let event = stocks[stockID]?.pending else { continue }
                let stockKey = Int64(index + 1)
                stockKeys[stockID] = stockKey
                try run(
                    "INSERT INTO stocks(stock_key, stock_id, name, group_name) VALUES(?, ?, ?, ?)",
                    [.integer(stockKey), .text(stockID), .text(event.stockName), .text(event.group)]
                )
            }

            let windowKeys = Set(events.map { $0.pending.windowStart + "|" + $0.pending.windowEnd }).sorted()
            var windowIDs: [String: Int64] = [:]
            for (index, key) in windowKeys.enumerated() {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                let id = Int64(index + 1)
                windowIDs[key] = id
                try run(
                    "INSERT INTO windows(window_id, start_date, end_date) VALUES(?, ?, ?)",
                    [.integer(id), .integer(dateNumber(parts[0])),
                     .integer(dateNumber(parts.count > 1 ? parts[1] : ""))]
                )
            }

            let definitions = ruleDefinitions(events)
            var ruleKeys: [String: Int64] = [:]
            for (index, definition) in definitions.enumerated() {
                let ruleKey = Int64(index + 1)
                ruleKeys[definition.ruleID] = ruleKey
                try run(
                    "INSERT INTO rules(rule_key, rule_id, phase, kind, description) VALUES(?, ?, ?, ?, ?)",
                    [
                        .integer(ruleKey), .text(definition.ruleID), .integer(phaseNumber(definition.phase)),
                        .integer(definition.kind == "gate" ? 2 : 1), .text(definition.description)
                    ]
                )
            }

            var observationsByKey: [String: InternalBacktestDecisionRecorder.TechnicalObservation] = [:]
            for event in events {
                guard let observation = event.pending.technicalObservation else { continue }
                let key = event.pending.stockID + "|" + event.pending.date
                if let existing = observationsByKey[key], existing != observation {
                    throw WriterError.bind("conflicting technical observation \(key)")
                }
                observationsByKey[key] = observation
            }
            var observationIDs: [String: Int64] = [:]
            for (index, key) in observationsByKey.keys.sorted().enumerated() {
                guard let observation = observationsByKey[key] else { continue }
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let stockKey = stockKeys[parts[0]] else {
                    throw WriterError.bind("invalid technical observation key \(key)")
                }
                let observationID = Int64(index + 1)
                observationIDs[key] = observationID
                try run(
                    """
                    INSERT INTO technical_observations(
                        observation_id, stock_key, trade_date,
                        close_change_percent, high_diff, low_diff,
                        high_diff_z125, high_diff_z250, low_diff_z125, low_diff_z250,
                        ma20_days, ma20_diff, ma20_diff_z125, ma20_diff_z250,
                        ma60_days, ma60_diff, ma60_diff_z125, ma60_diff_z250,
                        price_z125, price_z250,
                        kd_k, kd_k_z125, kd_k_z250,
                        kd_d, kd_d_z125, kd_d_z250,
                        kd_j, kd_j_z125, kd_j_z250,
                        osc, osc_z125, osc_z250,
                        volume_ma20_days, volume_ma20_diff,
                        volume_ma20_diff_z125, volume_ma20_diff_z250,
                        volume_ma60_days, volume_ma60_diff,
                        volume_ma60_diff_z125, volume_ma60_diff_z250,
                        volume_z125, volume_z250, minimum9_mask, maximum9_mask
                    ) VALUES(
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?
                    )
                    """,
                    observationBindings(
                        id: observationID,
                        stockKey: stockKey,
                        tradeDate: dateNumber(parts[1]),
                        value: observation
                    )
                )
            }

            var strategyObservationsByKey: [String: InternalBacktestDecisionRecorder.StrategyFitObservation] = [:]
            for event in events {
                guard let observation = event.pending.strategyFitObservation else { continue }
                let key = strategyObservationKey(event.pending)
                if let existing = strategyObservationsByKey[key], existing != observation {
                    throw WriterError.bind("conflicting strategy fit observation \(key)")
                }
                strategyObservationsByKey[key] = observation
            }
            var strategyObservationIDs: [String: Int64] = [:]
            for (index, key) in strategyObservationsByKey.keys.sorted().enumerated() {
                guard let observation = strategyObservationsByKey[key] else { continue }
                let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4,
                      let windowID = windowIDs[parts[0] + "|" + parts[1]],
                      let stockKey = stockKeys[parts[2]] else {
                    throw WriterError.bind("invalid strategy fit observation key \(key)")
                }
                let observationID = Int64(index + 1)
                strategyObservationIDs[key] = observationID
                try run(
                    """
                    INSERT INTO strategy_fit_observations(
                        observation_id, window_id, stock_key, trade_date,
                        fit_level, fit_fast, fit_slow, fit_trend, fit_trend_phase,
                        fit_evidence_rounds, fit_evidence_days, fit_observation_count,
                        roi_trend, days_trend, grade_name,
                        grade_activation_passed, has_inventory, is_valid, is_finite,
                        fast_period, slow_period
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    strategyObservationBindings(
                        id: observationID,
                        windowID: windowID,
                        stockKey: stockKey,
                        tradeDate: dateNumber(parts[3]),
                        value: observation
                    )
                )
            }

            for (index, event) in events.enumerated() {
                let value = event.pending
                let windowKey = value.windowStart + "|" + value.windowEnd
                guard let windowID = windowIDs[windowKey] else {
                    throw WriterError.bind("missing window \(windowKey)")
                }
                let eventID = Int64(index + 1)
                guard let stockKey = stockKeys[value.stockID] else {
                    throw WriterError.bind("missing stock \(value.stockID)")
                }
                try run(
                    """
                    INSERT INTO decision_events(
                        event_id, window_id, stock_key, trade_date, phase,
                        grade, decision_score, decision_threshold,
                        planned_action, executed_action, inventory_before, unit_roi_before,
                        unit_cost_before, holding_days_before, invest_times_before, balance_before,
                        roll_roi_before, roll_days_before, roll_rounds_before,
                        buy_rule_before, state_fingerprint
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .integer(eventID), .integer(windowID), .integer(stockKey),
                        .integer(dateNumber(value.date)), .integer(Int64(value.phase.rawValue)),
                        .integer(Int64(value.grade)), .real(value.score),
                        value.threshold.map(Binding.real) ?? .null,
                        .text(value.plannedAction), .text(event.executedAction),
                        .real(value.inventoryBefore), .real(value.unitROIBefore), .real(value.unitCostBefore),
                        .real(value.holdingDaysBefore), .real(value.investTimesBefore),
                        .real(value.balanceBefore), .real(value.rollROIBefore),
                        .real(value.rollDaysBefore), .real(value.rollRoundsBefore),
                        .text(value.buyRuleBefore), .integer(value.stateFingerprint)
                    ]
                )
                for vote in value.votes {
                    guard let ruleKey = ruleKeys[vote.ruleID] else {
                        throw WriterError.bind("missing rule \(vote.ruleID)")
                    }
                    try run(
                        "INSERT INTO event_votes(event_id, rule_key, contribution) VALUES(?, ?, ?)",
                        [.integer(eventID), .integer(ruleKey), .real(vote.contribution)]
                    )
                }
                for gate in value.passedGateIDs {
                    guard let ruleKey = ruleKeys[gate] else {
                        throw WriterError.bind("missing gate \(gate)")
                    }
                    try run(
                        "INSERT INTO event_gates(event_id, rule_key) VALUES(?, ?)",
                        [.integer(eventID), .integer(ruleKey)]
                    )
                }
                if value.technicalObservation != nil {
                    let observationKey = value.stockID + "|" + value.date
                    guard let observationID = observationIDs[observationKey] else {
                        throw WriterError.bind("missing technical observation \(observationKey)")
                    }
                    try run(
                        "INSERT INTO event_observations(event_id, observation_id) VALUES(?, ?)",
                        [.integer(eventID), .integer(observationID)]
                    )
                }
                let strategyKey = strategyObservationKey(value)
                if let observationID = strategyObservationIDs[strategyKey] {
                    try run(
                        "INSERT INTO event_strategy_fit_observations(event_id, observation_id) VALUES(?, ?)",
                        [.integer(eventID), .integer(observationID)]
                    )
                }
            }
            for outcome in outcomes {
                let windowKey = outcome.periodStart + "|" + outcome.periodEnd
                guard let windowID = windowIDs[windowKey], let stockKey = stockKeys[outcome.id] else {
                    throw WriterError.bind("missing outcome identity \(windowKey) \(outcome.id)")
                }
                try run(
                    """
                    INSERT INTO period_outcomes(
                        window_id, stock_key, roi, average_days, rounds,
                        grade_name, money_lacked, status
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .integer(windowID), .integer(stockKey),
                        outcome.roi.map(Binding.real) ?? .null,
                        outcome.averageDays.map(Binding.real) ?? .null,
                        .real(outcome.rounds), .text(outcome.grade),
                        .integer(outcome.moneyLacked ? 1 : 0), .text(outcome.status)
                    ]
                )
            }
            try execute("COMMIT;")
        } catch {
            _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func observationBindings(
        id: Int64,
        stockKey: Int64,
        tradeDate: Int64,
        value: InternalBacktestDecisionRecorder.TechnicalObservation
    ) -> [Binding] {
        [
            .integer(id), .integer(stockKey), .integer(tradeDate),
            .real(value.closeChangePercent), .real(value.highDiff), .real(value.lowDiff),
            .real(value.highDiffZ125), .real(value.highDiffZ250),
            .real(value.lowDiffZ125), .real(value.lowDiffZ250),
            .real(value.ma20Days), .real(value.ma20Diff),
            .real(value.ma20DiffZ125), .real(value.ma20DiffZ250),
            .real(value.ma60Days), .real(value.ma60Diff),
            .real(value.ma60DiffZ125), .real(value.ma60DiffZ250),
            .real(value.priceZ125), .real(value.priceZ250),
            .real(value.kdK), .real(value.kdKZ125), .real(value.kdKZ250),
            .real(value.kdD), .real(value.kdDZ125), .real(value.kdDZ250),
            .real(value.kdJ), .real(value.kdJZ125), .real(value.kdJZ250),
            .real(value.osc), .real(value.oscZ125), .real(value.oscZ250),
            .real(value.volumeMA20Days), .real(value.volumeMA20Diff),
            .real(value.volumeMA20DiffZ125), .real(value.volumeMA20DiffZ250),
            .real(value.volumeMA60Days), .real(value.volumeMA60Diff),
            .real(value.volumeMA60DiffZ125), .real(value.volumeMA60DiffZ250),
            .real(value.volumeZ125), .real(value.volumeZ250),
            .integer(Int64(value.minimum9Mask)), .integer(Int64(value.maximum9Mask))
        ]
    }

    private func strategyObservationKey(
        _ value: InternalBacktestDecisionRecorder.PendingEvent
    ) -> String {
        [value.windowStart, value.windowEnd, value.stockID, value.date]
            .joined(separator: "|")
    }

    private func strategyObservationBindings(
        id: Int64,
        windowID: Int64,
        stockKey: Int64,
        tradeDate: Int64,
        value: InternalBacktestDecisionRecorder.StrategyFitObservation
    ) -> [Binding] {
        [
            .integer(id), .integer(windowID), .integer(stockKey), .integer(tradeDate),
            .real(value.fitLevel), value.fitFast.map(Binding.real) ?? .null,
            value.fitSlow.map(Binding.real) ?? .null,
            value.fitTrend.map(Binding.real) ?? .null,
            .integer(Int64(value.fitTrendPhaseRaw)),
            .real(value.fitEvidenceRounds), .real(value.fitEvidenceDays),
            .integer(Int64(value.fitObservationCount)),
            value.roiTrend.map(Binding.real) ?? .null,
            value.daysTrend.map(Binding.real) ?? .null,
            .text(value.gradeName), .integer(value.gradeActivationPassed ? 1 : 0),
            .integer(value.hasInventory ? 1 : 0), .integer(value.isValid ? 1 : 0),
            .integer(value.isFinite ? 1 : 0),
            .integer(Int64(InternalBacktestDecisionRecorder.StrategyFitEMA.fastPeriod)),
            .integer(Int64(InternalBacktestDecisionRecorder.StrategyFitEMA.slowPeriod))
        ]
    }

    private struct SQLiteRuleDefinition {
        let ruleID: String
        let phase: String
        let kind: String
        let description: String
    }

    private func ruleDefinitions(
        _ events: [InternalBacktestDecisionRecorder.Event]
    ) -> [SQLiteRuleDefinition] {
        var result = Dictionary(
            uniqueKeysWithValues: InternalBacktestDecisionRecorder.knownRuleIDs.map { ruleID in
                (
                    ruleID,
                    SQLiteRuleDefinition(
                        ruleID: ruleID,
                        phase: InternalBacktestDecisionRecorder.phaseCode(for: ruleID),
                        kind: ruleID.hasPrefix("G-") || ruleID.contains("-T") || ruleID.contains("-E")
                            ? "gate" : "vote",
                        description: InternalBacktestDecisionRecorder.ruleDescription(ruleID)
                    )
                )
            }
        )
        for event in events {
            for vote in event.pending.votes {
                result[vote.ruleID] = SQLiteRuleDefinition(
                    ruleID: vote.ruleID,
                    phase: event.pending.phase.code,
                    kind: "vote",
                    description: InternalBacktestDecisionRecorder.ruleDescription(vote.ruleID)
                )
            }
            for gate in event.pending.passedGateIDs {
                result[gate] = SQLiteRuleDefinition(
                    ruleID: gate,
                    phase: event.pending.phase.code,
                    kind: "gate",
                    description: InternalBacktestDecisionRecorder.ruleDescription(gate)
                )
            }
        }
        return result.values.sorted { $0.ruleID < $1.ruleID }
    }

    private enum Binding {
        case text(String)
        case integer(Int64)
        case real(Double)
        case null
    }

    private func dateNumber(_ text: String) -> Int64 {
        Int64(text.replacingOccurrences(of: "/", with: "")) ?? 0
    }

    private func phaseNumber(_ text: String) -> Int64 {
        switch text {
        case "GRADE": 0
        case "H_BUY": 1
        case "L_BUY": 2
        case "SELL": 3
        case "ADD": 4
        default: 0
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw WriterError.execute("database closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let text = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw WriterError.execute(text)
        }
    }

    private func run(_ sql: String, _ bindings: [Binding]) throws {
        guard let database else { throw WriterError.execute("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw WriterError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, position, value, -1, transient)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, position, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, position, value)
            case .null:
                result = sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else {
                throw WriterError.bind(String(cString: sqlite3_errmsg(database)))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw WriterError.step(String(cString: sqlite3_errmsg(database)))
        }
    }
}
#endif
