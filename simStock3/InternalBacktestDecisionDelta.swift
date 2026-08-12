import Foundation
import SQLite3

#if DEBUG
@MainActor
enum InternalBacktestDecisionDelta {
    struct Configuration {
        let sampleID: String
        let inputSnapshotID: String
        let baselineDecisionBaseID: String
        let candidateID: String
        let candidateRunID: String
        let baselineRuleVersion: String
        let baselineRuleCommit: String
        let through: String
        let moneyBaseWan: Double
        let automaticInvestments: Double
    }

    fileprivate struct EventKey: Hashable, Comparable {
        let windowStart: Int64
        let windowEnd: Int64
        let stockID: String
        let tradeDate: Int64
        let phase: Int64

        static func < (lhs: EventKey, rhs: EventKey) -> Bool {
            (lhs.windowStart, lhs.windowEnd, lhs.stockID, lhs.tradeDate, lhs.phase)
                < (rhs.windowStart, rhs.windowEnd, rhs.stockID, rhs.tradeDate, rhs.phase)
        }

        var text: String {
            "\(windowStart)|\(windowEnd)|\(stockID)|\(tradeDate)|\(phase)"
        }

        var stockWindowKey: String {
            "\(windowStart)|\(windowEnd)|\(stockID)"
        }
    }

    fileprivate struct NormalizedEvent {
        let baselineEventID: Int64?
        let key: EventKey
        let stockName: String
        let group: String
        let grade: Int64
        let gradeName: String
        let score: Double
        let threshold: Double?
        let plannedAction: String
        let executedAction: String
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
        var votes: [String: Double]
        var gates: Set<String>
    }

    fileprivate struct OutcomeKey: Hashable, Comparable {
        let windowStart: Int64
        let windowEnd: Int64
        let stockID: String

        static func < (lhs: OutcomeKey, rhs: OutcomeKey) -> Bool {
            (lhs.windowStart, lhs.windowEnd, lhs.stockID)
                < (rhs.windowStart, rhs.windowEnd, rhs.stockID)
        }
    }

    fileprivate struct Outcome {
        let key: OutcomeKey
        let stockName: String
        let group: String
        let roi: Double?
        let averageDays: Double?
        let rounds: Double
        let gradeName: String
        let moneyLacked: Bool
        let status: String
    }

    private struct BaselineData {
        let events: [EventKey: NormalizedEvent]
        let outcomes: [OutcomeKey: Outcome]
    }

    fileprivate enum DeltaKind: Int64 {
        case changed = 1
        case added = 2
        case removed = 3
    }

    fileprivate struct Fields: OptionSet {
        let rawValue: Int64

        static let state = Fields(rawValue: 1 << 0)
        static let grade = Fields(rawValue: 1 << 1)
        static let score = Fields(rawValue: 1 << 2)
        static let threshold = Fields(rawValue: 1 << 3)
        static let plannedAction = Fields(rawValue: 1 << 4)
        static let executedAction = Fields(rawValue: 1 << 5)
        static let inventory = Fields(rawValue: 1 << 6)
        static let unitCost = Fields(rawValue: 1 << 7)
        static let unitROI = Fields(rawValue: 1 << 8)
        static let holdingDays = Fields(rawValue: 1 << 9)
        static let investTimes = Fields(rawValue: 1 << 10)
        static let balance = Fields(rawValue: 1 << 11)
        static let rollROI = Fields(rawValue: 1 << 12)
        static let rollDays = Fields(rawValue: 1 << 13)
        static let rollRounds = Fields(rawValue: 1 << 14)
        static let buyRule = Fields(rawValue: 1 << 15)
        static let votes = Fields(rawValue: 1 << 16)
        static let gates = Fields(rawValue: 1 << 17)
        static let all: Fields = [
            .state, .grade, .score, .threshold, .plannedAction, .executedAction,
            .inventory, .unitCost, .unitROI, .holdingDays, .investTimes, .balance,
            .rollROI, .rollDays, .rollRounds, .buyRule, .votes, .gates
        ]
    }

    fileprivate struct VoteDelta {
        let ruleID: String
        let baseline: Double?
        let candidate: Double?
    }

    fileprivate struct GateDelta {
        let ruleID: String
        let baselinePassed: Bool
        let candidatePassed: Bool
    }

    fileprivate struct EventDelta {
        let deltaID: Int64
        let kind: DeltaKind
        let fields: Fields
        let baseline: NormalizedEvent?
        let candidate: NormalizedEvent?
        let voteDeltas: [VoteDelta]
        let gateDeltas: [GateDelta]

        var key: EventKey { candidate?.key ?? baseline!.key }
        var displayEvent: NormalizedEvent { candidate ?? baseline! }
    }

    fileprivate struct FirstDivergence {
        let key: EventKey
        let deltaID: Int64
        let baselineFingerprint: Int64?
        let candidateFingerprint: Int64?
        let samePrestate: Bool
        let baselineScore: Double?
        let candidateScore: Double?
        let baselineAction: String?
        let candidateAction: String?
    }

    fileprivate struct Reconvergence {
        let segment: Int64
        let key: EventKey
    }

    fileprivate struct OutcomeDelta {
        let baseline: Outcome?
        let candidate: Outcome?

        var key: OutcomeKey { candidate?.key ?? baseline!.key }
    }

    fileprivate struct GroupOutcome: Equatable {
        let windowStart: Int64
        let group: String
        let averageROI: Double?
        let averageDays: Double?
        let score: Double?
    }

    fileprivate struct GroupOutcomeDelta {
        let baseline: GroupOutcome
        let candidate: GroupOutcome
    }

    private struct Summary: Codable {
        struct GroupMainScoreDelta: Codable {
            let group: String
            let baseline: Double?
            let candidate: Double?
            let delta: Double?
        }

        let formatVersion: Int
        let sampleID: String
        let baselineDecisionBaseID: String
        let candidateID: String
        let candidateRunID: String
        let baselineEventCount: Int
        let candidateEventCount: Int
        let changedEventCount: Int
        let addedEventCount: Int
        let removedEventCount: Int
        let changedVoteCount: Int
        let changedGateCount: Int
        let firstDivergenceCount: Int
        let reconvergenceCount: Int
        let prestateMismatchCount: Int
        let outcomeDifferenceCount: Int
        let groupOutcomeDifferenceCount: Int
        let groupMainScoreDeltas: [GroupMainScoreDelta]
        let combinedMainScoreDelta: Double?
        let isZeroDecisionDelta: Bool
        let isZeroOutcomeDelta: Bool
        let sqliteBytes: Int64
    }

    enum DeltaError: LocalizedError {
        case baselineIncomplete(String)
        case duplicateEvent(String)
        case firstDivergencePrestate(String)
        case invalidValue(String)

        var errorDescription: String? {
            switch self {
            case .baselineIncomplete(let text): "Baseline DecisionBase 不完整：\(text)"
            case .duplicateEvent(let text): "Decision delta 事件鍵重複：\(text)"
            case .firstDivergencePrestate(let text): "第一次分歧前狀態不一致：\(text)"
            case .invalidValue(let text): "Decision delta 出現無效數值：\(text)"
            }
        }
    }

    static func write(
        configuration: Configuration,
        baselineDirectoryURL: URL,
        outputDirectoryURL: URL,
        events: [InternalBacktestDecisionRecorder.Event],
        outcomes: [InternalBacktestReport.StockPeriod]
    ) throws {
        let fm = FileManager.default
        let baselineMarker = baselineDirectoryURL.appendingPathComponent(".complete")
        guard fm.fileExists(atPath: baselineMarker.path) else {
            throw DeltaError.baselineIncomplete(baselineDirectoryURL.path)
        }
        let baselineSQLiteURL = baselineDirectoryURL.appendingPathComponent("decisions.sqlite")
        let baseline = try loadBaseline(from: baselineSQLiteURL)
        let candidateEvents = try normalize(events)
        let candidateOutcomes = normalize(outcomes)
        let deltas = compareEvents(baseline: baseline.events, candidate: candidateEvents)
        let outcomeDeltas = compareOutcomes(baseline: baseline.outcomes, candidate: candidateOutcomes)
        let groupBaseline = groupOutcomes(Array(baseline.outcomes.values))
        let groupCandidate = groupOutcomes(Array(candidateOutcomes.values))
        let groupDeltas = compareGroupOutcomes(baseline: groupBaseline, candidate: groupCandidate)
        let (firstDivergences, reconvergences) = divergenceTopology(
            baseline: baseline.events,
            candidate: candidateEvents,
            deltas: deltas
        )
        let prestateMismatches = firstDivergences.filter { !$0.samePrestate }
        if let mismatch = prestateMismatches.first {
            throw DeltaError.firstDivergencePrestate(mismatch.key.text)
        }

        if fm.fileExists(atPath: outputDirectoryURL.path) {
            try fm.removeItem(at: outputDirectoryURL)
        }
        try fm.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)

        var sqliteBytes: Int64 = 0
        if !deltas.isEmpty || !outcomeDeltas.isEmpty || !groupDeltas.isEmpty {
            let sqliteURL = outputDirectoryURL.appendingPathComponent("decision-delta.sqlite")
            let writer = try DeltaSQLiteWriter(url: sqliteURL)
            try writer.createSchema()
            try writer.write(
                configuration: configuration,
                deltas: deltas,
                firstDivergences: firstDivergences,
                reconvergences: reconvergences,
                outcomeDeltas: outcomeDeltas,
                groupDeltas: groupDeltas
            )
            try writer.close()
            sqliteBytes = (try? sqliteURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
        }

        let groupMain = groupMainScoreDeltas(baseline: groupBaseline, candidate: groupCandidate)
        let combinedDelta: Double? = {
            let values = groupMain.compactMap(\.delta)
            return values.count == groupMain.count ? values.reduce(0, +) : nil
        }()
        let summary = Summary(
            formatVersion: 1,
            sampleID: configuration.sampleID,
            baselineDecisionBaseID: configuration.baselineDecisionBaseID,
            candidateID: configuration.candidateID,
            candidateRunID: configuration.candidateRunID,
            baselineEventCount: baseline.events.count,
            candidateEventCount: candidateEvents.count,
            changedEventCount: deltas.filter { $0.kind == .changed }.count,
            addedEventCount: deltas.filter { $0.kind == .added }.count,
            removedEventCount: deltas.filter { $0.kind == .removed }.count,
            changedVoteCount: deltas.reduce(0) { $0 + $1.voteDeltas.count },
            changedGateCount: deltas.reduce(0) { $0 + $1.gateDeltas.count },
            firstDivergenceCount: firstDivergences.count,
            reconvergenceCount: reconvergences.count,
            prestateMismatchCount: prestateMismatches.count,
            outcomeDifferenceCount: outcomeDeltas.count,
            groupOutcomeDifferenceCount: groupDeltas.count,
            groupMainScoreDeltas: groupMain,
            combinedMainScoreDelta: combinedDelta,
            isZeroDecisionDelta: deltas.isEmpty,
            isZeroOutcomeDelta: outcomeDeltas.isEmpty && groupDeltas.isEmpty,
            sqliteBytes: sqliteBytes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(
            to: outputDirectoryURL.appendingPathComponent("decision-summary.json"),
            options: .atomic
        )
        try distributionCSV(
            configuration: configuration,
            deltas: deltas,
            outcomeDeltas: outcomeDeltas
        ).write(
            to: outputDirectoryURL.appendingPathComponent("distribution.csv"),
            atomically: true,
            encoding: .utf8
        )
        try firstDivergenceCSV(
            divergences: firstDivergences,
            outcomeDeltas: outcomeDeltas,
            baseline: baseline.events,
            candidate: candidateEvents
        ).write(
            to: outputDirectoryURL.appendingPathComponent("first-divergence.csv"),
            atomically: true,
            encoding: .utf8
        )
        let manifest: [String: Any] = [
            "formatVersion": 1,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "sampleID": configuration.sampleID,
            "inputSnapshotID": configuration.inputSnapshotID,
            "baselineDecisionBaseID": configuration.baselineDecisionBaseID,
            "candidateID": configuration.candidateID,
            "candidateRunID": configuration.candidateRunID,
            "baselineRuleVersion": configuration.baselineRuleVersion,
            "baselineRuleCommit": configuration.baselineRuleCommit,
            "through": configuration.through,
            "moneyBaseWan": configuration.moneyBaseWan,
            "automaticInvestments": configuration.automaticInvestments,
            "files": fm.fileExists(
                atPath: outputDirectoryURL.appendingPathComponent("decision-delta.sqlite").path
            ) ? [
                "decision-delta.sqlite", "decision-summary.json", "distribution.csv",
                "first-divergence.csv", "manifest.json", ".complete"
            ] : [
                "decision-summary.json", "distribution.csv", "first-divergence.csv",
                "manifest.json", ".complete"
            ]
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(
            to: outputDirectoryURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try configuration.candidateID.write(
            to: outputDirectoryURL.appendingPathComponent(".complete"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func normalize(
        _ events: [InternalBacktestDecisionRecorder.Event]
    ) throws -> [EventKey: NormalizedEvent] {
        var result: [EventKey: NormalizedEvent] = [:]
        for event in events {
            let value = event.pending
            let key = EventKey(
                windowStart: dateNumber(value.windowStart),
                windowEnd: dateNumber(value.windowEnd),
                stockID: value.stockID,
                tradeDate: dateNumber(value.date),
                phase: Int64(value.phase.rawValue)
            )
            guard result[key] == nil else { throw DeltaError.duplicateEvent(key.text) }
            let finiteValues = [
                value.score, value.inventoryBefore, value.unitCostBefore, value.unitROIBefore,
                value.holdingDaysBefore, value.investTimesBefore, value.balanceBefore,
                value.rollROIBefore, value.rollDaysBefore, value.rollRoundsBefore
            ] + value.votes.map(\.contribution)
            guard finiteValues.allSatisfy(\.isFinite), value.threshold?.isFinite != false else {
                throw DeltaError.invalidValue(key.text)
            }
            result[key] = NormalizedEvent(
                baselineEventID: nil,
                key: key,
                stockName: value.stockName,
                group: value.group,
                grade: Int64(value.grade),
                gradeName: value.gradeName,
                score: value.score,
                threshold: value.threshold,
                plannedAction: value.plannedAction,
                executedAction: event.executedAction,
                inventoryBefore: value.inventoryBefore,
                unitCostBefore: value.unitCostBefore,
                unitROIBefore: value.unitROIBefore,
                holdingDaysBefore: value.holdingDaysBefore,
                investTimesBefore: value.investTimesBefore,
                balanceBefore: value.balanceBefore,
                rollROIBefore: value.rollROIBefore,
                rollDaysBefore: value.rollDaysBefore,
                rollRoundsBefore: value.rollRoundsBefore,
                buyRuleBefore: value.buyRuleBefore,
                stateFingerprint: value.stateFingerprint,
                votes: Dictionary(uniqueKeysWithValues: value.votes.map { ($0.ruleID, $0.contribution) }),
                gates: Set(value.passedGateIDs)
            )
        }
        return result
    }

    private static func normalize(
        _ outcomes: [InternalBacktestReport.StockPeriod]
    ) -> [OutcomeKey: Outcome] {
        Dictionary(uniqueKeysWithValues: outcomes.map { value in
            let key = OutcomeKey(
                windowStart: dateNumber(value.periodStart),
                windowEnd: dateNumber(value.periodEnd),
                stockID: value.id
            )
            return (key, Outcome(
                key: key,
                stockName: value.name,
                group: value.group,
                roi: value.roi,
                averageDays: value.averageDays,
                rounds: value.rounds,
                gradeName: value.grade,
                moneyLacked: value.moneyLacked,
                status: value.status
            ))
        })
    }

    private static func compareEvents(
        baseline: [EventKey: NormalizedEvent],
        candidate: [EventKey: NormalizedEvent]
    ) -> [EventDelta] {
        let keys = Set(baseline.keys).union(candidate.keys).sorted()
        var result: [EventDelta] = []
        for key in keys {
            let base = baseline[key]
            let value = candidate[key]
            let kind: DeltaKind
            let fields: Fields
            if let base, let value {
                fields = changedFields(base, value)
                if fields.isEmpty { continue }
                kind = .changed
            } else if value != nil {
                kind = .added
                fields = .all
            } else {
                kind = .removed
                fields = .all
            }
            var voteKeySet = Set<String>()
            if let base { voteKeySet.formUnion(base.votes.keys) }
            if let value { voteKeySet.formUnion(value.votes.keys) }
            let voteKeys = voteKeySet.sorted()
            let voteDeltas = voteKeys.compactMap { ruleID -> VoteDelta? in
                let before = base?.votes[ruleID]
                let after = value?.votes[ruleID]
                return optionalEqual(before, after) ? nil : VoteDelta(
                    ruleID: ruleID, baseline: before, candidate: after
                )
            }
            var gateKeySet = Set<String>()
            if let base { gateKeySet.formUnion(base.gates) }
            if let value { gateKeySet.formUnion(value.gates) }
            let gateKeys = gateKeySet.sorted()
            let gateDeltas = gateKeys.compactMap { ruleID -> GateDelta? in
                let before = base?.gates.contains(ruleID) ?? false
                let after = value?.gates.contains(ruleID) ?? false
                return before == after ? nil : GateDelta(
                    ruleID: ruleID, baselinePassed: before, candidatePassed: after
                )
            }
            result.append(EventDelta(
                deltaID: Int64(result.count + 1),
                kind: kind,
                fields: fields,
                baseline: base,
                candidate: value,
                voteDeltas: voteDeltas,
                gateDeltas: gateDeltas
            ))
        }
        return result
    }

    private static func changedFields(_ lhs: NormalizedEvent, _ rhs: NormalizedEvent) -> Fields {
        var fields: Fields = []
        if lhs.stateFingerprint != rhs.stateFingerprint { fields.insert(.state) }
        if lhs.grade != rhs.grade { fields.insert(.grade) }
        if lhs.score != rhs.score { fields.insert(.score) }
        if !optionalEqual(lhs.threshold, rhs.threshold) { fields.insert(.threshold) }
        if lhs.plannedAction != rhs.plannedAction { fields.insert(.plannedAction) }
        if lhs.executedAction != rhs.executedAction { fields.insert(.executedAction) }
        if lhs.inventoryBefore != rhs.inventoryBefore { fields.insert(.inventory) }
        if lhs.unitCostBefore != rhs.unitCostBefore { fields.insert(.unitCost) }
        if lhs.unitROIBefore != rhs.unitROIBefore { fields.insert(.unitROI) }
        if lhs.holdingDaysBefore != rhs.holdingDaysBefore { fields.insert(.holdingDays) }
        if lhs.investTimesBefore != rhs.investTimesBefore { fields.insert(.investTimes) }
        if lhs.balanceBefore != rhs.balanceBefore { fields.insert(.balance) }
        if lhs.rollROIBefore != rhs.rollROIBefore { fields.insert(.rollROI) }
        if lhs.rollDaysBefore != rhs.rollDaysBefore { fields.insert(.rollDays) }
        if lhs.rollRoundsBefore != rhs.rollRoundsBefore { fields.insert(.rollRounds) }
        if lhs.buyRuleBefore != rhs.buyRuleBefore { fields.insert(.buyRule) }
        if lhs.votes != rhs.votes { fields.insert(.votes) }
        if lhs.gates != rhs.gates { fields.insert(.gates) }
        return fields
    }

    private static func compareOutcomes(
        baseline: [OutcomeKey: Outcome],
        candidate: [OutcomeKey: Outcome]
    ) -> [OutcomeDelta] {
        Set(baseline.keys).union(candidate.keys).sorted().compactMap { key in
            let lhs = baseline[key]
            let rhs = candidate[key]
            guard !outcomesEqual(lhs, rhs) else { return nil }
            return OutcomeDelta(baseline: lhs, candidate: rhs)
        }
    }

    private static func outcomesEqual(_ lhs: Outcome?, _ rhs: Outcome?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return optionalEqual(lhs.roi, rhs.roi)
            && optionalEqual(lhs.averageDays, rhs.averageDays)
            && lhs.rounds == rhs.rounds
            && lhs.gradeName == rhs.gradeName
            && lhs.moneyLacked == rhs.moneyLacked
            && lhs.status == rhs.status
    }

    private static func divergenceTopology(
        baseline: [EventKey: NormalizedEvent],
        candidate: [EventKey: NormalizedEvent],
        deltas: [EventDelta]
    ) -> ([FirstDivergence], [Reconvergence]) {
        let deltaByKey = Dictionary(uniqueKeysWithValues: deltas.map { ($0.key, $0) })
        let keys = Set(baseline.keys).union(candidate.keys).sorted()
        let groups = Dictionary(grouping: keys, by: \.stockWindowKey)
        var first: [FirstDivergence] = []
        var rejoined: [Reconvergence] = []
        var segment: Int64 = 0
        for groupKey in groups.keys.sorted() {
            guard let groupKeys = groups[groupKey]?.sorted() else { continue }
            var inDifference = false
            var capturedFirst = false
            for key in groupKeys {
                if let delta = deltaByKey[key] {
                    if !inDifference {
                        segment += 1
                        if !capturedFirst {
                            let base = delta.baseline
                            let value = delta.candidate
                            first.append(FirstDivergence(
                                key: key,
                                deltaID: delta.deltaID,
                                baselineFingerprint: base?.stateFingerprint,
                                candidateFingerprint: value?.stateFingerprint,
                                samePrestate: base != nil && value != nil
                                    && base?.stateFingerprint == value?.stateFingerprint,
                                baselineScore: base?.score,
                                candidateScore: value?.score,
                                baselineAction: base?.plannedAction,
                                candidateAction: value?.plannedAction
                            ))
                            capturedFirst = true
                        }
                    }
                    inDifference = true
                } else if inDifference {
                    rejoined.append(Reconvergence(segment: segment, key: key))
                    inDifference = false
                }
            }
        }
        return (first, rejoined)
    }

    private static func groupOutcomes(_ outcomes: [Outcome]) -> [String: GroupOutcome] {
        let grouped = Dictionary(grouping: outcomes, by: {
            "\($0.key.windowStart)|\($0.group)"
        })
        return grouped.mapValues { unsortedRows in
            let rows = unsortedRows.sorted { $0.key.stockID < $1.key.stockID }
            let valid = rows.filter { $0.roi != nil && $0.averageDays != nil }
            let roi = mean(valid.compactMap(\.roi))
            let days = mean(valid.compactMap(\.averageDays))
            return GroupOutcome(
                windowStart: rows[0].key.windowStart,
                group: rows[0].group,
                averageROI: roi,
                averageDays: days,
                score: score(roi: roi, days: days)
            )
        }
    }

    private static func compareGroupOutcomes(
        baseline: [String: GroupOutcome],
        candidate: [String: GroupOutcome]
    ) -> [GroupOutcomeDelta] {
        Set(baseline.keys).intersection(candidate.keys).sorted().compactMap { key in
            guard let lhs = baseline[key], let rhs = candidate[key], lhs != rhs else { return nil }
            return GroupOutcomeDelta(baseline: lhs, candidate: rhs)
        }
    }

    private static func groupMainScoreDeltas(
        baseline: [String: GroupOutcome],
        candidate: [String: GroupOutcome]
    ) -> [Summary.GroupMainScoreDelta] {
        let groups = Set(baseline.values.map(\.group)).union(candidate.values.map(\.group)).sorted()
        return groups.map { group in
            let lhs = mean(baseline.values.filter { $0.group == group }
                .sorted { $0.windowStart < $1.windowStart }.compactMap(\.score))
            let rhs = mean(candidate.values.filter { $0.group == group }
                .sorted { $0.windowStart < $1.windowStart }.compactMap(\.score))
            return Summary.GroupMainScoreDelta(
                group: group,
                baseline: lhs,
                candidate: rhs,
                delta: lhs.flatMap { before in rhs.map { $0 - before } }
            )
        }
    }

    private static func distributionCSV(
        configuration: Configuration,
        deltas: [EventDelta],
        outcomeDeltas: [OutcomeDelta]
    ) -> String {
        struct DistributionKey: Hashable {
            let windowStart: Int64
            let windowEnd: Int64
            let stockID: String
            let group: String
            let grade: String
            let phase: Int64
            let ruleID: String
        }
        let changedOutcomeKeys = Set(outcomeDeltas.map(\.key))
        var counts: [DistributionKey: (events: Int, details: Int)] = [:]
        for delta in deltas {
            let event = delta.displayEvent
            let ruleIDs = Set(delta.voteDeltas.map(\.ruleID))
                .union(delta.gateDeltas.map(\.ruleID))
            let displayRules = ruleIDs.isEmpty ? ["(event/state)"] : ruleIDs.sorted()
            for ruleID in displayRules {
                let key = DistributionKey(
                    windowStart: event.key.windowStart,
                    windowEnd: event.key.windowEnd,
                    stockID: event.key.stockID,
                    group: event.group,
                    grade: event.gradeName,
                    phase: event.key.phase,
                    ruleID: ruleID
                )
                let old = counts[key] ?? (0, 0)
                counts[key] = (old.events + 1, old.details + (ruleIDs.isEmpty ? 0 : 1))
            }
        }
        var rows = [
            "sampleID,windowStart,windowEnd,stockID,group,grade,phase,ruleID,eventDifferenceCount,voteOrGateDifferenceCount,outcomeChanged"
        ]
        let sorted = counts.keys.sorted {
            ($0.windowStart, $0.stockID, $0.grade, $0.phase, $0.ruleID)
                < ($1.windowStart, $1.stockID, $1.grade, $1.phase, $1.ruleID)
        }
        for key in sorted {
            let value = counts[key] ?? (0, 0)
            let outcomeKey = OutcomeKey(
                windowStart: key.windowStart,
                windowEnd: key.windowEnd,
                stockID: key.stockID
            )
            rows.append([
                configuration.sampleID, dateText(key.windowStart), dateText(key.windowEnd),
                key.stockID, key.group, key.grade, phaseText(key.phase), key.ruleID,
                String(value.events), String(value.details),
                changedOutcomeKeys.contains(outcomeKey) ? "1" : "0"
            ].map(csvEscape).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func firstDivergenceCSV(
        divergences: [FirstDivergence],
        outcomeDeltas: [OutcomeDelta],
        baseline: [EventKey: NormalizedEvent],
        candidate: [EventKey: NormalizedEvent]
    ) -> String {
        let outcomeByKey = Dictionary(uniqueKeysWithValues: outcomeDeltas.map { ($0.key, $0) })
        var rows = [
            "windowStart,windowEnd,stockID,date,phase,grade,baselineScore,candidateScore,baselineAction,candidateAction,samePrestate,baselineROI,candidateROI,roiDelta,baselineDays,candidateDays,daysDelta,baselineFinalGrade,candidateFinalGrade"
        ]
        for value in divergences.sorted(by: { $0.key < $1.key }) {
            let event = candidate[value.key] ?? baseline[value.key]
            let outcome = outcomeByKey[OutcomeKey(
                windowStart: value.key.windowStart,
                windowEnd: value.key.windowEnd,
                stockID: value.key.stockID
            )]
            let lhs = outcome?.baseline
            let rhs = outcome?.candidate
            rows.append([
                dateText(value.key.windowStart), dateText(value.key.windowEnd), value.key.stockID,
                dateText(value.key.tradeDate), phaseText(value.key.phase), event?.gradeName ?? "",
                optionalText(value.baselineScore), optionalText(value.candidateScore),
                value.baselineAction ?? "", value.candidateAction ?? "",
                value.samePrestate ? "1" : "0", optionalText(lhs?.roi), optionalText(rhs?.roi),
                optionalDelta(lhs?.roi, rhs?.roi), optionalText(lhs?.averageDays),
                optionalText(rhs?.averageDays), optionalDelta(lhs?.averageDays, rhs?.averageDays),
                lhs?.gradeName ?? "", rhs?.gradeName ?? ""
            ].map(csvEscape).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func loadBaseline(from url: URL) throws -> BaselineData {
        let reader = try DeltaSQLiteReader(url: url)
        defer { reader.close() }
        var events: [EventKey: NormalizedEvent] = [:]
        var keyByEventID: [Int64: EventKey] = [:]
        try reader.rows(
            """
            SELECT e.event_id, w.start_date, w.end_date, s.stock_id, s.name, s.group_name,
                e.trade_date, e.phase, e.grade, e.decision_score, e.decision_threshold,
                e.planned_action, e.executed_action, e.inventory_before, e.unit_cost_before,
                e.unit_roi_before, e.holding_days_before, e.invest_times_before,
                e.balance_before, e.roll_roi_before, e.roll_days_before, e.roll_rounds_before,
                e.buy_rule_before, e.state_fingerprint
            FROM decision_events e
            JOIN windows w USING(window_id)
            JOIN stocks s USING(stock_key)
            ORDER BY e.event_id
            """
        ) { row in
            let eventID = row.integer(0)
            let key = EventKey(
                windowStart: row.integer(1), windowEnd: row.integer(2),
                stockID: row.text(3), tradeDate: row.integer(6), phase: row.integer(7)
            )
            keyByEventID[eventID] = key
            events[key] = NormalizedEvent(
                baselineEventID: eventID,
                key: key,
                stockName: row.text(4), group: row.text(5), grade: row.integer(8),
                gradeName: gradeText(row.integer(8)), score: row.real(9),
                threshold: row.optionalReal(10), plannedAction: row.text(11),
                executedAction: row.text(12), inventoryBefore: row.real(13),
                unitCostBefore: row.real(14), unitROIBefore: row.real(15),
                holdingDaysBefore: row.real(16), investTimesBefore: row.real(17),
                balanceBefore: row.real(18), rollROIBefore: row.real(19),
                rollDaysBefore: row.real(20), rollRoundsBefore: row.real(21),
                buyRuleBefore: row.text(22), stateFingerprint: row.integer(23),
                votes: [:], gates: []
            )
        }
        try reader.rows(
            "SELECT v.event_id, r.rule_id, v.contribution FROM event_votes v JOIN rules r USING(rule_key)"
        ) { row in
            guard let key = keyByEventID[row.integer(0)], var event = events[key] else { return }
            event.votes[row.text(1)] = row.real(2)
            events[key] = event
        }
        try reader.rows(
            "SELECT g.event_id, r.rule_id FROM event_gates g JOIN rules r USING(rule_key)"
        ) { row in
            guard let key = keyByEventID[row.integer(0)], var event = events[key] else { return }
            event.gates.insert(row.text(1))
            events[key] = event
        }
        var outcomes: [OutcomeKey: Outcome] = [:]
        try reader.rows(
            """
            SELECT w.start_date, w.end_date, s.stock_id, s.name, s.group_name,
                o.roi, o.average_days, o.rounds, o.grade_name, o.money_lacked, o.status
            FROM period_outcomes o
            JOIN windows w USING(window_id)
            JOIN stocks s USING(stock_key)
            """
        ) { row in
            let key = OutcomeKey(
                windowStart: row.integer(0), windowEnd: row.integer(1), stockID: row.text(2)
            )
            outcomes[key] = Outcome(
                key: key, stockName: row.text(3), group: row.text(4),
                roi: row.optionalReal(5), averageDays: row.optionalReal(6),
                rounds: row.real(7), gradeName: row.text(8),
                moneyLacked: row.integer(9) != 0, status: row.text(10)
            )
        }
        return BaselineData(events: events, outcomes: outcomes)
    }

    private static func optionalEqual(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): lhs == rhs
        default: false
        }
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func score(roi: Double?, days: Double?) -> Double? {
        guard let roi, let days, days > 0 else { return nil }
        return roi >= 0 ? roi * 100 / days : roi * days / 100
    }

    private static func dateNumber(_ text: String) -> Int64 {
        Int64(text.replacingOccurrences(of: "/", with: "")) ?? 0
    }

    private static func dateText(_ value: Int64) -> String {
        String(format: "%04lld/%02lld/%02lld", value / 10_000, (value / 100) % 100, value % 100)
    }

    private static func phaseText(_ value: Int64) -> String {
        switch value {
        case 1: "H_BUY"
        case 2: "L_BUY"
        case 3: "SELL"
        case 4: "ADD"
        default: "UNKNOWN"
        }
    }

    private static func gradeText(_ value: Int64) -> String {
        switch value {
        case 3: "wow"
        case 2: "high"
        case 1: "fine"
        case 0: "none"
        case -1: "weak"
        case -2: "low"
        case -3: "damn"
        default: "unknown"
        }
    }

    private static func optionalText(_ value: Double?) -> String {
        value.map { String(format: "%.8f", $0) } ?? ""
    }

    private static func optionalDelta(_ lhs: Double?, _ rhs: Double?) -> String {
        guard let lhs, let rhs else { return "" }
        return String(format: "%.8f", rhs - lhs)
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

final class DeltaSQLiteReader {
    struct Row {
        fileprivate let statement: OpaquePointer

        func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func real(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func optionalReal(_ index: Int32) -> Double? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : real(index)
        }
        func optionalInteger(_ index: Int32) -> Int64? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : integer(index)
        }
        func text(_ index: Int32) -> String {
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }
        func optionalText(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(index)
        }
    }

    private var database: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(database)
            database = nil
            throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete(message)
        }
    }

    func rows(_ sql: String, consume: (Row) -> Void) throws {
        guard let database else {
            throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete("database closed")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete(
                String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                consume(Row(statement: statement))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete(
                    String(cString: sqlite3_errmsg(database))
                )
            }
        }
    }

    func close() {
        if let database { sqlite3_close(database) }
        database = nil
    }

    deinit { close() }
}

private final class DeltaSQLiteWriter {
    private enum Binding {
        case text(String)
        case integer(Int64)
        case real(Double)
        case null
    }

    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(
            url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(database)
            database = nil
            throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete(message)
        }
        try execute("PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON;")
    }

    func createSchema() throws {
        try execute("""
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE event_deltas (
            delta_id INTEGER PRIMARY KEY,
            kind INTEGER NOT NULL,
            changed_fields INTEGER NOT NULL,
            baseline_event_id INTEGER,
            event_key TEXT NOT NULL UNIQUE,
            window_start INTEGER NOT NULL,
            window_end INTEGER NOT NULL,
            stock_id TEXT NOT NULL,
            trade_date INTEGER NOT NULL,
            phase INTEGER NOT NULL,
            candidate_grade INTEGER,
            candidate_score REAL,
            candidate_threshold REAL,
            candidate_planned_action TEXT,
            candidate_executed_action TEXT,
            candidate_inventory_before REAL,
            candidate_unit_cost_before REAL,
            candidate_unit_roi_before REAL,
            candidate_holding_days_before REAL,
            candidate_invest_times_before REAL,
            candidate_balance_before REAL,
            candidate_roll_roi_before REAL,
            candidate_roll_days_before REAL,
            candidate_roll_rounds_before REAL,
            candidate_buy_rule_before TEXT,
            candidate_state_fingerprint INTEGER
        );
        CREATE TABLE vote_deltas (
            delta_id INTEGER NOT NULL REFERENCES event_deltas(delta_id) ON DELETE CASCADE,
            rule_id TEXT NOT NULL,
            baseline_contribution REAL,
            candidate_contribution REAL,
            PRIMARY KEY(delta_id, rule_id)
        ) WITHOUT ROWID;
        CREATE TABLE gate_deltas (
            delta_id INTEGER NOT NULL REFERENCES event_deltas(delta_id) ON DELETE CASCADE,
            rule_id TEXT NOT NULL,
            baseline_passed INTEGER NOT NULL,
            candidate_passed INTEGER NOT NULL,
            PRIMARY KEY(delta_id, rule_id)
        ) WITHOUT ROWID;
        CREATE TABLE first_divergences (
            window_start INTEGER NOT NULL,
            window_end INTEGER NOT NULL,
            stock_id TEXT NOT NULL,
            delta_id INTEGER NOT NULL REFERENCES event_deltas(delta_id),
            event_key TEXT NOT NULL,
            trade_date INTEGER NOT NULL,
            phase INTEGER NOT NULL,
            baseline_fingerprint INTEGER,
            candidate_fingerprint INTEGER,
            same_prestate INTEGER NOT NULL,
            baseline_score REAL,
            candidate_score REAL,
            baseline_action TEXT,
            candidate_action TEXT,
            PRIMARY KEY(window_start, window_end, stock_id)
        ) WITHOUT ROWID;
        CREATE TABLE reconvergences (
            segment INTEGER PRIMARY KEY,
            event_key TEXT NOT NULL,
            window_start INTEGER NOT NULL,
            window_end INTEGER NOT NULL,
            stock_id TEXT NOT NULL,
            trade_date INTEGER NOT NULL,
            phase INTEGER NOT NULL
        );
        CREATE TABLE period_outcome_deltas (
            window_start INTEGER NOT NULL,
            window_end INTEGER NOT NULL,
            stock_id TEXT NOT NULL,
            group_name TEXT NOT NULL,
            baseline_roi REAL,
            candidate_roi REAL,
            baseline_average_days REAL,
            candidate_average_days REAL,
            baseline_rounds REAL,
            candidate_rounds REAL,
            baseline_grade TEXT,
            candidate_grade TEXT,
            baseline_money_lacked INTEGER,
            candidate_money_lacked INTEGER,
            PRIMARY KEY(window_start, window_end, stock_id)
        ) WITHOUT ROWID;
        CREATE TABLE group_outcome_deltas (
            window_start INTEGER NOT NULL,
            group_name TEXT NOT NULL,
            baseline_average_roi REAL,
            candidate_average_roi REAL,
            baseline_average_days REAL,
            candidate_average_days REAL,
            baseline_score REAL,
            candidate_score REAL,
            PRIMARY KEY(window_start, group_name)
        ) WITHOUT ROWID;
        CREATE INDEX delta_by_stock_date ON event_deltas(window_start, stock_id, trade_date, phase);
        CREATE INDEX delta_by_phase_grade ON event_deltas(phase, candidate_grade);
        CREATE INDEX vote_delta_by_rule ON vote_deltas(rule_id, delta_id);
        """)
    }

    func write(
        configuration: InternalBacktestDecisionDelta.Configuration,
        deltas: [InternalBacktestDecisionDelta.EventDelta],
        firstDivergences: [InternalBacktestDecisionDelta.FirstDivergence],
        reconvergences: [InternalBacktestDecisionDelta.Reconvergence],
        outcomeDeltas: [InternalBacktestDecisionDelta.OutcomeDelta],
        groupDeltas: [InternalBacktestDecisionDelta.GroupOutcomeDelta]
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let metadata = [
                "formatVersion": "1", "sampleID": configuration.sampleID,
                "inputSnapshotID": configuration.inputSnapshotID,
                "baselineDecisionBaseID": configuration.baselineDecisionBaseID,
                "candidateID": configuration.candidateID,
                "candidateRunID": configuration.candidateRunID,
                "baselineRuleVersion": configuration.baselineRuleVersion,
                "baselineRuleCommit": configuration.baselineRuleCommit
            ]
            for key in metadata.keys.sorted() {
                try run("INSERT INTO metadata(key,value) VALUES(?,?)", [
                    .text(key), .text(metadata[key] ?? "")
                ])
            }
            for delta in deltas {
                let value = delta.candidate
                let all = delta.kind == .added
                func changed(_ field: InternalBacktestDecisionDelta.Fields) -> Bool {
                    all || delta.fields.contains(field)
                }
                try run("""
                    INSERT INTO event_deltas(
                        delta_id,kind,changed_fields,baseline_event_id,event_key,
                        window_start,window_end,stock_id,trade_date,phase,
                        candidate_grade,candidate_score,candidate_threshold,
                        candidate_planned_action,candidate_executed_action,
                        candidate_inventory_before,candidate_unit_cost_before,candidate_unit_roi_before,
                        candidate_holding_days_before,candidate_invest_times_before,candidate_balance_before,
                        candidate_roll_roi_before,candidate_roll_days_before,candidate_roll_rounds_before,
                        candidate_buy_rule_before,candidate_state_fingerprint
                    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [
                    .integer(delta.deltaID), .integer(delta.kind.rawValue),
                    .integer(delta.fields.rawValue),
                    delta.baseline?.baselineEventID.map(Binding.integer) ?? .null,
                    .text(delta.key.text), .integer(delta.key.windowStart),
                    .integer(delta.key.windowEnd), .text(delta.key.stockID),
                    .integer(delta.key.tradeDate), .integer(delta.key.phase),
                    changed(.grade) ? value.map { .integer($0.grade) } ?? .null : .null,
                    changed(.score) ? value.map { .real($0.score) } ?? .null : .null,
                    changed(.threshold) ? value?.threshold.map(Binding.real) ?? .null : .null,
                    changed(.plannedAction) ? value.map { .text($0.plannedAction) } ?? .null : .null,
                    changed(.executedAction) ? value.map { .text($0.executedAction) } ?? .null : .null,
                    changed(.inventory) ? value.map { .real($0.inventoryBefore) } ?? .null : .null,
                    changed(.unitCost) ? value.map { .real($0.unitCostBefore) } ?? .null : .null,
                    changed(.unitROI) ? value.map { .real($0.unitROIBefore) } ?? .null : .null,
                    changed(.holdingDays) ? value.map { .real($0.holdingDaysBefore) } ?? .null : .null,
                    changed(.investTimes) ? value.map { .real($0.investTimesBefore) } ?? .null : .null,
                    changed(.balance) ? value.map { .real($0.balanceBefore) } ?? .null : .null,
                    changed(.rollROI) ? value.map { .real($0.rollROIBefore) } ?? .null : .null,
                    changed(.rollDays) ? value.map { .real($0.rollDaysBefore) } ?? .null : .null,
                    changed(.rollRounds) ? value.map { .real($0.rollRoundsBefore) } ?? .null : .null,
                    changed(.buyRule) ? value.map { .text($0.buyRuleBefore) } ?? .null : .null,
                    changed(.state) ? value.map { .integer($0.stateFingerprint) } ?? .null : .null
                ])
                for vote in delta.voteDeltas {
                    try run(
                        "INSERT INTO vote_deltas VALUES(?,?,?,?)",
                        [.integer(delta.deltaID), .text(vote.ruleID),
                         vote.baseline.map(Binding.real) ?? .null,
                         vote.candidate.map(Binding.real) ?? .null]
                    )
                }
                for gate in delta.gateDeltas {
                    try run(
                        "INSERT INTO gate_deltas VALUES(?,?,?,?)",
                        [.integer(delta.deltaID), .text(gate.ruleID),
                         .integer(gate.baselinePassed ? 1 : 0),
                         .integer(gate.candidatePassed ? 1 : 0)]
                    )
                }
            }
            for value in firstDivergences {
                try run("INSERT INTO first_divergences VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    .integer(value.key.windowStart), .integer(value.key.windowEnd),
                    .text(value.key.stockID), .integer(value.deltaID), .text(value.key.text),
                    .integer(value.key.tradeDate), .integer(value.key.phase),
                    value.baselineFingerprint.map(Binding.integer) ?? .null,
                    value.candidateFingerprint.map(Binding.integer) ?? .null,
                    .integer(value.samePrestate ? 1 : 0),
                    value.baselineScore.map(Binding.real) ?? .null,
                    value.candidateScore.map(Binding.real) ?? .null,
                    value.baselineAction.map(Binding.text) ?? .null,
                    value.candidateAction.map(Binding.text) ?? .null
                ])
            }
            for value in reconvergences {
                try run("INSERT INTO reconvergences VALUES(?,?,?,?,?,?,?)", [
                    .integer(value.segment), .text(value.key.text),
                    .integer(value.key.windowStart), .integer(value.key.windowEnd),
                    .text(value.key.stockID), .integer(value.key.tradeDate), .integer(value.key.phase)
                ])
            }
            for value in outcomeDeltas {
                let lhs = value.baseline
                let rhs = value.candidate
                try run("INSERT INTO period_outcome_deltas VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    .integer(value.key.windowStart), .integer(value.key.windowEnd),
                    .text(value.key.stockID), .text(rhs?.group ?? lhs?.group ?? ""),
                    lhs?.roi.map(Binding.real) ?? .null, rhs?.roi.map(Binding.real) ?? .null,
                    lhs?.averageDays.map(Binding.real) ?? .null,
                    rhs?.averageDays.map(Binding.real) ?? .null,
                    lhs.map { .real($0.rounds) } ?? .null, rhs.map { .real($0.rounds) } ?? .null,
                    lhs.map { .text($0.gradeName) } ?? .null,
                    rhs.map { .text($0.gradeName) } ?? .null,
                    lhs.map { .integer($0.moneyLacked ? 1 : 0) } ?? .null,
                    rhs.map { .integer($0.moneyLacked ? 1 : 0) } ?? .null
                ])
            }
            for value in groupDeltas {
                try run("INSERT INTO group_outcome_deltas VALUES(?,?,?,?,?,?,?,?)", [
                    .integer(value.candidate.windowStart), .text(value.candidate.group),
                    value.baseline.averageROI.map(Binding.real) ?? .null,
                    value.candidate.averageROI.map(Binding.real) ?? .null,
                    value.baseline.averageDays.map(Binding.real) ?? .null,
                    value.candidate.averageDays.map(Binding.real) ?? .null,
                    value.baseline.score.map(Binding.real) ?? .null,
                    value.candidate.score.map(Binding.real) ?? .null
                ])
            }
            try execute("COMMIT;")
        } catch {
            if let database { _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil) }
            throw error
        }
    }

    func close() throws {
        guard let database else { return }
        guard sqlite3_close(database) == SQLITE_OK else {
            throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete(
                String(cString: sqlite3_errmsg(database))
            )
        }
        self.database = nil
    }

    deinit { if let database { sqlite3_close(database) } }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete("database closed")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let text = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete(text)
        }
    }

    private func run(_ sql: String, _ bindings: [Binding]) throws {
        guard let database else {
            throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete("database closed")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete(
                String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, transient)
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .real(let value): result = sqlite3_bind_double(statement, index, value)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete(
                    String(cString: sqlite3_errmsg(database))
                )
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw InternalBacktestDecisionDelta.DeltaError.baselineIncomplete(
                String(cString: sqlite3_errmsg(database))
            )
        }
    }
}
#endif
