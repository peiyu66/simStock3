import Foundation

#if DEBUG
@MainActor
enum InternalBacktestDecisionAnalyzer {
    struct Result {
        let outputDirectoryURL: URL
        let summaryURL: URL
        let reportURL: URL
        let firstDivergenceCount: Int
        let outcomeDifferenceCount: Int
    }

    private struct Count: Codable {
        let key: String
        let count: Int
    }

    private struct GroupScoreDelta: Codable {
        let windowStart: String
        let group: String
        let baselineScore: Double?
        let candidateScore: Double?
        let delta: Double?
    }

    private struct OriginRule: Codable {
        let ruleID: String
        let firstDivergenceCount: Int
        let directChangeCount: Int
        let affectedStockWindowCount: Int
    }

    private struct Summary: Codable {
        let formatVersion: Int
        let createdAt: String
        let decisionBaseID: String
        let candidateID: String
        let baselineEventCount: Int
        let candidateEventCount: Int
        let changedEventCount: Int
        let addedEventCount: Int
        let removedEventCount: Int
        let directRuleChangedEventCount: Int
        let pathOnlyChangedEventCount: Int
        let firstDivergenceCount: Int
        let reconvergenceCount: Int
        let outcomeDifferenceCount: Int
        let combinedMainScoreDelta: Double?
        let firstDivergencesByGrade: [Count]
        let firstDivergencesByWindow: [Count]
        let firstDivergencesByGroup: [Count]
        let firstDivergencesByStock: [Count]
        let candidateRuleChanges: [OriginRule]
        let groupScoreDeltas: [GroupScoreDelta]
        let interpretation: [String]
    }

    private struct BaselineEvent {
        let eventID: Int64
        let grade: Int64
        let score: Double
        let action: String
    }

    private struct BaselineStock {
        let name: String
        let group: String
    }

    private struct BaselineOutcome {
        let roi: Double?
        let averageDays: Double?
        let grade: String
    }

    private struct RuleRow {
        let ruleID: String
        let phase: String
        let kind: String
        let description: String
        let phaseEventCount: Int
        let activationCount: Int
        let actionEventCount: Int
        let positiveCount: Int
        let negativeCount: Int
        let contributionSum: Double?
        let scoreBoundaryCrossingCount: Int?
        let solePassedGateActionCount: Int?
        var directChangeCount = 0
        var firstDivergenceCount = 0
        var affectedStockWindowCount = 0
    }

    private struct CandidateRuleMetric {
        var directChangeCount = 0
        var firstDivergenceCount = 0
        var stockWindows: Set<String> = []
    }

    private struct EventAggregate {
        var changedEventCount = 0
        var directRuleChangedEventCount = 0
        var reconvergenceCount = 0
    }

    private struct OutcomeDelta {
        let baselineROI: Double?
        let candidateROI: Double?
        let baselineDays: Double?
        let candidateDays: Double?
        let baselineGrade: String?
        let candidateGrade: String?
    }

    private struct FirstRow {
        let windowStart: Int64
        let windowEnd: Int64
        let stockID: String
        let stockName: String
        let group: String
        let date: Int64
        let phase: String
        let grade: String
        let firstChangedRules: String
        let samePrestate: Bool
        let baselineScore: Double?
        let candidateScore: Double?
        let baselineAction: String?
        let candidateAction: String?
        let changedEventCount: Int
        let directRuleChangedEventCount: Int
        let pathOnlyChangedEventCount: Int
        let reconvergenceCount: Int
        let baselineROI: Double?
        let candidateROI: Double?
        let roiDelta: Double?
        let baselineDays: Double?
        let candidateDays: Double?
        let daysDelta: Double?
        let baselineFinalGrade: String?
        let candidateFinalGrade: String?
        let outcomeChanged: Bool
    }

    enum AnalysisError: LocalizedError {
        case missingArgument(String)
        case incomplete(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .missingArgument(let value): "P4a 缺少參數：\(value)"
            case .incomplete(let value): "P4a 輸入不完整：\(value)"
            case .invalid(let value): "P4a 資料不一致：\(value)"
            }
        }
    }

    static func runFromArguments(progress: (String) -> Void = { _ in }) throws -> Result {
        guard let decisionBaseID = argument(after: "--decision-base-id") else {
            throw AnalysisError.missingArgument("--decision-base-id")
        }
        guard let candidateID = argument(after: "--candidate-id") else {
            throw AnalysisError.missingArgument("--candidate-id")
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baselineURL = documents
            .appendingPathComponent("InternalBacktest/DecisionBases", isDirectory: true)
            .appendingPathComponent(decisionBaseID, isDirectory: true)
        let deltaURL = documents
            .appendingPathComponent("InternalBacktest/DecisionDeltas", isDirectory: true)
            .appendingPathComponent(decisionBaseID, isDirectory: true)
            .appendingPathComponent(candidateID, isDirectory: true)
        return try write(
            decisionBaseID: decisionBaseID,
            candidateID: candidateID,
            baselineDirectoryURL: baselineURL,
            deltaDirectoryURL: deltaURL,
            progress: progress
        )
    }

    static func write(
        decisionBaseID: String,
        candidateID: String,
        baselineDirectoryURL: URL,
        deltaDirectoryURL: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> Result {
        let fm = FileManager.default
        for directory in [baselineDirectoryURL, deltaDirectoryURL] {
            guard fm.fileExists(atPath: directory.appendingPathComponent(".complete").path) else {
                throw AnalysisError.incomplete(directory.path)
            }
        }
        let baselineSQLiteURL = baselineDirectoryURL.appendingPathComponent("decisions.sqlite")
        let deltaSQLiteURL = deltaDirectoryURL.appendingPathComponent("decision-delta.sqlite")
        let decisionSummaryURL = deltaDirectoryURL.appendingPathComponent("decision-summary.json")
        guard fm.fileExists(atPath: baselineSQLiteURL.path),
              fm.fileExists(atPath: decisionSummaryURL.path) else {
            throw AnalysisError.incomplete(deltaDirectoryURL.path)
        }

        _ = try InternalBacktestDecisionBaseProfiler.ensure(
            decisionBaseID: decisionBaseID,
            baselineDirectoryURL: baselineDirectoryURL,
            progress: progress
        )

        let completeMarker = deltaDirectoryURL.appendingPathComponent(".analysis-complete")
        if fm.fileExists(atPath: completeMarker.path) { try fm.removeItem(at: completeMarker) }
        progress("讀取 DecisionBase 規則貢獻…")
        let baseline = try loadBaseline(from: baselineSQLiteURL)
        var ruleRows = try loadRuleRows(from: baselineSQLiteURL)
        let decisionSummary = try jsonObject(at: decisionSummaryURL)
        let hasDelta = fm.fileExists(atPath: deltaSQLiteURL.path)
        let zeroDecision = bool(decisionSummary["isZeroDecisionDelta"])
        let zeroOutcome = bool(decisionSummary["isZeroOutcomeDelta"])
        if !hasDelta && !(zeroDecision && zeroOutcome) {
            throw AnalysisError.invalid("非零差異候選缺少 decision-delta.sqlite")
        }

        progress("整理候選直接差異與路徑連鎖…")
        var candidateMetrics: [String: CandidateRuleMetric] = [:]
        var firstRows: [FirstRow] = []
        var groupScores: [GroupScoreDelta] = []
        var directRuleChangedEventCount = 0
        if hasDelta {
            let delta = try loadDelta(
                from: deltaSQLiteURL,
                baseline: baseline
            )
            candidateMetrics = delta.metrics
            firstRows = delta.firstRows
            groupScores = delta.groupScores
            directRuleChangedEventCount = delta.directRuleChangedEventCount
        } else {
            groupScores = groupScoresFromDecisionSummary(decisionSummary)
        }
        for index in ruleRows.indices {
            guard let metric = candidateMetrics[ruleRows[index].ruleID] else { continue }
            ruleRows[index].directChangeCount = metric.directChangeCount
            ruleRows[index].firstDivergenceCount = metric.firstDivergenceCount
            ruleRows[index].affectedStockWindowCount = metric.stockWindows.count
        }

        let changed = integer(decisionSummary["changedEventCount"])
        let added = integer(decisionSummary["addedEventCount"])
        let removed = integer(decisionSummary["removedEventCount"])
        let allChanged = changed + added + removed
        let origins = candidateMetrics.map { ruleID, value in
            OriginRule(
                ruleID: ruleID,
                firstDivergenceCount: value.firstDivergenceCount,
                directChangeCount: value.directChangeCount,
                affectedStockWindowCount: value.stockWindows.count
            )
        }.filter { $0.directChangeCount > 0 }
            .sorted {
                if $0.firstDivergenceCount != $1.firstDivergenceCount {
                    return $0.firstDivergenceCount > $1.firstDivergenceCount
                }
                if $0.directChangeCount != $1.directChangeCount {
                    return $0.directChangeCount > $1.directChangeCount
                }
                return $0.ruleID < $1.ruleID
            }
        let summary = Summary(
            formatVersion: 1,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            decisionBaseID: decisionBaseID,
            candidateID: candidateID,
            baselineEventCount: integer(decisionSummary["baselineEventCount"]),
            candidateEventCount: integer(decisionSummary["candidateEventCount"]),
            changedEventCount: changed,
            addedEventCount: added,
            removedEventCount: removed,
            directRuleChangedEventCount: directRuleChangedEventCount,
            pathOnlyChangedEventCount: max(0, allChanged - directRuleChangedEventCount),
            firstDivergenceCount: integer(decisionSummary["firstDivergenceCount"]),
            reconvergenceCount: integer(decisionSummary["reconvergenceCount"]),
            outcomeDifferenceCount: integer(decisionSummary["outcomeDifferenceCount"]),
            combinedMainScoreDelta: double(decisionSummary["combinedMainScoreDelta"]),
            firstDivergencesByGrade: counts(firstRows.map(\.grade)),
            firstDivergencesByWindow: counts(firstRows.map { dateText($0.windowStart) }),
            firstDivergencesByGroup: counts(firstRows.map(\.group)),
            firstDivergencesByStock: counts(firstRows.map { $0.stockID + " " + $0.stockName }),
            candidateRuleChanges: origins,
            groupScoreDeltas: groupScores,
            interpretation: [
                "directRuleChangedEventCount 是票數或門檻通過狀態直接改變的事件數。",
                "pathOnlyChangedEventCount 是沒有直接規則差異、但受先前分歧連鎖影響的事件數。",
                "scoreBoundaryCrossingCount 只表示移除該票會跨越已記錄的分數門檻，不等同完整反事實因果。",
                "solePassedGateActionCount 只表示實際行動事件中該規則是唯一已通過的 gate。"
            ]
        )

        progress("寫入 P4a 標準摘要…")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let summaryURL = deltaDirectoryURL.appendingPathComponent("analysis-summary.json")
        try encoder.encode(summary).write(to: summaryURL, options: .atomic)
        try ruleCSV(ruleRows).write(
            to: deltaDirectoryURL.appendingPathComponent("rule-contribution.csv"),
            atomically: true,
            encoding: .utf8
        )
        try firstCSV(firstRows).write(
            to: deltaDirectoryURL.appendingPathComponent("analysis-by-stock-window.csv"),
            atomically: true,
            encoding: .utf8
        )
        let reportURL = deltaDirectoryURL.appendingPathComponent("analysis.html")
        try html(summary: summary, rules: ruleRows, rows: firstRows).write(
            to: reportURL,
            atomically: true,
            encoding: .utf8
        )
        let manifest: [String: Any] = [
            "formatVersion": 1,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "decisionBaseID": decisionBaseID,
            "candidateID": candidateID,
            "files": [
                "analysis-summary.json", "rule-contribution.csv",
                "analysis-by-stock-window.csv", "analysis.html",
                "analysis-manifest.json", ".analysis-complete"
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(
                to: deltaDirectoryURL.appendingPathComponent("analysis-manifest.json"),
                options: .atomic
            )
        try candidateID.write(to: completeMarker, atomically: true, encoding: .utf8)
        return Result(
            outputDirectoryURL: deltaDirectoryURL,
            summaryURL: summaryURL,
            reportURL: reportURL,
            firstDivergenceCount: summary.firstDivergenceCount,
            outcomeDifferenceCount: summary.outcomeDifferenceCount
        )
    }

    private static func loadBaseline(
        from url: URL
    ) throws -> (
        events: [Int64: BaselineEvent],
        stocks: [String: BaselineStock],
        outcomes: [String: BaselineOutcome]
    ) {
        let reader = try DeltaSQLiteReader(url: url)
        defer { reader.close() }
        var events: [Int64: BaselineEvent] = [:]
        try reader.rows(
            "SELECT event_id,grade,decision_score,planned_action FROM decision_events"
        ) { row in
            let id = row.integer(0)
            events[id] = BaselineEvent(
                eventID: id, grade: row.integer(1), score: row.real(2), action: row.text(3)
            )
        }
        var stocks: [String: BaselineStock] = [:]
        try reader.rows("SELECT stock_id,name,group_name FROM stocks") { row in
            stocks[row.text(0)] = BaselineStock(name: row.text(1), group: row.text(2))
        }
        var outcomes: [String: BaselineOutcome] = [:]
        try reader.rows(
            """
            SELECT w.start_date,w.end_date,s.stock_id,o.roi,o.average_days,o.grade_name
            FROM period_outcomes o JOIN windows w USING(window_id) JOIN stocks s USING(stock_key)
            """
        ) { row in
            outcomes[key(row.integer(0), row.integer(1), row.text(2))] = BaselineOutcome(
                roi: row.optionalReal(3), averageDays: row.optionalReal(4), grade: row.text(5)
            )
        }
        return (events, stocks, outcomes)
    }

    private static func loadRuleRows(from url: URL) throws -> [RuleRow] {
        let reader = try DeltaSQLiteReader(url: url)
        defer { reader.close() }
        var rows: [RuleRow] = []
        try reader.rows(
            """
            SELECT r.rule_id,
                CASE r.phase WHEN 0 THEN 'GRADE' WHEN 1 THEN 'H_BUY' WHEN 2 THEN 'L_BUY'
                    WHEN 3 THEN 'SELL' WHEN 4 THEN 'ADD' END,
                CASE r.kind WHEN 1 THEN 'vote' ELSE 'gate' END,
                r.description,
                (SELECT COUNT(*) FROM decision_events e WHERE e.phase=r.phase),
                CASE r.kind WHEN 1 THEN (SELECT COUNT(*) FROM event_votes v WHERE v.rule_key=r.rule_key)
                    ELSE (SELECT COUNT(*) FROM event_gates g WHERE g.rule_key=r.rule_key) END,
                CASE r.kind WHEN 1 THEN (
                    SELECT COUNT(*) FROM event_votes v JOIN decision_events e USING(event_id)
                    WHERE v.rule_key=r.rule_key AND e.planned_action NOT IN ('NONE','HOLD')
                ) ELSE (
                    SELECT COUNT(*) FROM event_gates g JOIN decision_events e USING(event_id)
                    WHERE g.rule_key=r.rule_key AND e.planned_action NOT IN ('NONE','HOLD')
                ) END,
                CASE r.kind WHEN 1 THEN (SELECT COUNT(*) FROM event_votes v
                    WHERE v.rule_key=r.rule_key AND v.contribution>0) ELSE 0 END,
                CASE r.kind WHEN 1 THEN (SELECT COUNT(*) FROM event_votes v
                    WHERE v.rule_key=r.rule_key AND v.contribution<0) ELSE 0 END,
                CASE r.kind WHEN 1 THEN (SELECT SUM(v.contribution) FROM event_votes v
                    WHERE v.rule_key=r.rule_key) END,
                CASE r.kind WHEN 1 THEN (
                    SELECT COUNT(*) FROM event_votes v JOIN decision_events e USING(event_id)
                    WHERE v.rule_key=r.rule_key AND e.decision_threshold IS NOT NULL AND (
                        (e.decision_score>=e.decision_threshold AND
                            e.decision_score-v.contribution<e.decision_threshold) OR
                        (e.decision_score<e.decision_threshold AND
                            e.decision_score-v.contribution>=e.decision_threshold)
                    )
                ) END,
                CASE r.kind WHEN 2 THEN (
                    SELECT COUNT(*) FROM event_gates g JOIN decision_events e USING(event_id)
                    WHERE g.rule_key=r.rule_key AND e.planned_action NOT IN ('NONE','HOLD')
                        AND (SELECT COUNT(*) FROM event_gates all_g
                            WHERE all_g.event_id=g.event_id)=1
                ) END
            FROM rules r ORDER BY r.rule_id
            """
        ) { row in
            rows.append(RuleRow(
                ruleID: row.text(0), phase: row.text(1), kind: row.text(2),
                description: row.text(3), phaseEventCount: Int(row.integer(4)),
                activationCount: Int(row.integer(5)), actionEventCount: Int(row.integer(6)),
                positiveCount: Int(row.integer(7)), negativeCount: Int(row.integer(8)),
                contributionSum: row.optionalReal(9),
                scoreBoundaryCrossingCount: row.optionalInteger(10).map(Int.init),
                solePassedGateActionCount: row.optionalInteger(11).map(Int.init)
            ))
        }
        return rows
    }

    private static func loadDelta(
        from url: URL,
        baseline: (
            events: [Int64: BaselineEvent],
            stocks: [String: BaselineStock],
            outcomes: [String: BaselineOutcome]
        )
    ) throws -> (
        metrics: [String: CandidateRuleMetric],
        firstRows: [FirstRow],
        groupScores: [GroupScoreDelta],
        directRuleChangedEventCount: Int
    ) {
        let reader = try DeltaSQLiteReader(url: url)
        defer { reader.close() }
        var ruleByDelta: [Int64: Set<String>] = [:]
        var metrics: [String: CandidateRuleMetric] = [:]
        try reader.rows(
            """
            SELECT d.delta_id,d.rule_id,e.window_start,e.window_end,e.stock_id
            FROM (
                SELECT delta_id,rule_id FROM vote_deltas
                UNION ALL SELECT delta_id,rule_id FROM gate_deltas
            ) d JOIN event_deltas e USING(delta_id)
            """
        ) { row in
            let deltaID = row.integer(0)
            let ruleID = row.text(1)
            ruleByDelta[deltaID, default: []].insert(ruleID)
            var metric = metrics[ruleID] ?? CandidateRuleMetric()
            metric.directChangeCount += 1
            metric.stockWindows.insert(key(row.integer(2), row.integer(3), row.text(4)))
            metrics[ruleID] = metric
        }
        let directRuleChangedEventCount = ruleByDelta.count
        var eventAggregates: [String: EventAggregate] = [:]
        try reader.rows(
            """
            SELECT e.window_start,e.window_end,e.stock_id,COUNT(*),
                SUM(CASE WHEN EXISTS(SELECT 1 FROM vote_deltas v WHERE v.delta_id=e.delta_id)
                    OR EXISTS(SELECT 1 FROM gate_deltas g WHERE g.delta_id=e.delta_id)
                    THEN 1 ELSE 0 END)
            FROM event_deltas e GROUP BY e.window_start,e.window_end,e.stock_id
            """
        ) { row in
            eventAggregates[key(row.integer(0), row.integer(1), row.text(2))] = EventAggregate(
                changedEventCount: Int(row.integer(3)),
                directRuleChangedEventCount: Int(row.integer(4)),
                reconvergenceCount: 0
            )
        }
        try reader.rows(
            """
            SELECT window_start,window_end,stock_id,COUNT(*) FROM reconvergences
            GROUP BY window_start,window_end,stock_id
            """
        ) { row in
            let valueKey = key(row.integer(0), row.integer(1), row.text(2))
            var value = eventAggregates[valueKey] ?? EventAggregate()
            value.reconvergenceCount = Int(row.integer(3))
            eventAggregates[valueKey] = value
        }
        var outcomeDeltas: [String: OutcomeDelta] = [:]
        try reader.rows(
            """
            SELECT window_start,window_end,stock_id,baseline_roi,candidate_roi,
                baseline_average_days,candidate_average_days,baseline_grade,candidate_grade
            FROM period_outcome_deltas
            """
        ) { row in
            outcomeDeltas[key(row.integer(0), row.integer(1), row.text(2))] = OutcomeDelta(
                baselineROI: row.optionalReal(3), candidateROI: row.optionalReal(4),
                baselineDays: row.optionalReal(5), candidateDays: row.optionalReal(6),
                baselineGrade: row.optionalText(7), candidateGrade: row.optionalText(8)
            )
        }
        var firstRows: [FirstRow] = []
        try reader.rows(
            """
            SELECT f.window_start,f.window_end,f.stock_id,f.trade_date,f.phase,f.same_prestate,
                f.baseline_score,f.candidate_score,f.baseline_action,f.candidate_action,
                f.delta_id,e.baseline_event_id,e.candidate_grade
            FROM first_divergences f JOIN event_deltas e USING(delta_id)
            ORDER BY f.window_start,f.stock_id
            """
        ) { row in
            let windowStart = row.integer(0)
            let windowEnd = row.integer(1)
            let stockID = row.text(2)
            let valueKey = key(windowStart, windowEnd, stockID)
            let baselineEvent = row.optionalInteger(11).flatMap { baseline.events[$0] }
            let gradeValue = row.optionalInteger(12) ?? baselineEvent?.grade
            let aggregate = eventAggregates[valueKey] ?? EventAggregate()
            let outcome = outcomeDeltas[valueKey]
            let baselineOutcome = baseline.outcomes[valueKey]
            let baselineROI = outcome?.baselineROI ?? baselineOutcome?.roi
            let candidateROI = outcome?.candidateROI ?? baselineOutcome?.roi
            let baselineDays = outcome?.baselineDays ?? baselineOutcome?.averageDays
            let candidateDays = outcome?.candidateDays ?? baselineOutcome?.averageDays
            let rules = (ruleByDelta[row.integer(10)] ?? []).sorted()
            for ruleID in rules {
                var metric = metrics[ruleID] ?? CandidateRuleMetric()
                metric.firstDivergenceCount += 1
                metrics[ruleID] = metric
            }
            let stock = baseline.stocks[stockID] ?? BaselineStock(name: stockID, group: "")
            firstRows.append(FirstRow(
                windowStart: windowStart, windowEnd: windowEnd, stockID: stockID,
                stockName: stock.name, group: stock.group, date: row.integer(3),
                phase: phaseText(row.integer(4)), grade: gradeText(gradeValue),
                firstChangedRules: rules.joined(separator: "+"), samePrestate: row.integer(5) != 0,
                baselineScore: row.optionalReal(6), candidateScore: row.optionalReal(7),
                baselineAction: row.optionalText(8), candidateAction: row.optionalText(9),
                changedEventCount: aggregate.changedEventCount,
                directRuleChangedEventCount: aggregate.directRuleChangedEventCount,
                pathOnlyChangedEventCount: max(
                    0, aggregate.changedEventCount - aggregate.directRuleChangedEventCount
                ),
                reconvergenceCount: aggregate.reconvergenceCount,
                baselineROI: baselineROI, candidateROI: candidateROI,
                roiDelta: optionalDelta(baselineROI, candidateROI),
                baselineDays: baselineDays, candidateDays: candidateDays,
                daysDelta: optionalDelta(baselineDays, candidateDays),
                baselineFinalGrade: outcome?.baselineGrade ?? baselineOutcome?.grade,
                candidateFinalGrade: outcome?.candidateGrade ?? baselineOutcome?.grade,
                outcomeChanged: outcome != nil
            ))
        }
        var groupScores: [GroupScoreDelta] = []
        try reader.rows(
            """
            SELECT window_start,group_name,baseline_score,candidate_score
            FROM group_outcome_deltas ORDER BY window_start,group_name
            """
        ) { row in
            let lhs = row.optionalReal(2)
            let rhs = row.optionalReal(3)
            groupScores.append(GroupScoreDelta(
                windowStart: dateText(row.integer(0)), group: row.text(1),
                baselineScore: lhs, candidateScore: rhs, delta: optionalDelta(lhs, rhs)
            ))
        }
        return (metrics, firstRows, groupScores, directRuleChangedEventCount)
    }

    private static func ruleCSV(_ rows: [RuleRow]) -> String {
        var result = [[
            "ruleID", "phase", "kind", "description", "phaseEventCount",
            "activationCount", "activationRate", "actionEventCount", "positiveCount",
            "negativeCount", "contributionSum", "scoreBoundaryCrossingCount",
            "solePassedGateActionCount", "candidateDirectChangeCount",
            "candidateFirstDivergenceCount", "candidateAffectedStockWindowCount"
        ].joined(separator: ",")]
        for row in rows {
            let columns: [String] = [
                row.ruleID, row.phase, row.kind, row.description, String(row.phaseEventCount),
                String(row.activationCount), ratio(row.activationCount, row.phaseEventCount),
                String(row.actionEventCount), String(row.positiveCount), String(row.negativeCount),
                optionalText(row.contributionSum), row.scoreBoundaryCrossingCount.map(String.init) ?? "",
                row.solePassedGateActionCount.map(String.init) ?? "",
                String(row.directChangeCount), String(row.firstDivergenceCount),
                String(row.affectedStockWindowCount)
            ]
            result.append(columns.map(csvEscape).joined(separator: ","))
        }
        return result.joined(separator: "\n") + "\n"
    }

    private static func firstCSV(_ rows: [FirstRow]) -> String {
        var result = [[
            "windowStart", "windowEnd", "stockID", "stockName", "group", "firstDate",
            "phase", "grade", "firstChangedRules", "samePrestate", "baselineScore",
            "candidateScore", "baselineAction", "candidateAction", "changedEventCount",
            "directRuleChangedEventCount", "pathOnlyChangedEventCount", "reconvergenceCount",
            "baselineROI", "candidateROI", "roiDelta", "baselineDays", "candidateDays",
            "daysDelta", "baselineFinalGrade", "candidateFinalGrade", "outcomeChanged"
        ].joined(separator: ",")]
        for row in rows {
            let identity: [String] = [
                dateText(row.windowStart), dateText(row.windowEnd), row.stockID, row.stockName,
                row.group, dateText(row.date), row.phase, row.grade, row.firstChangedRules,
                row.samePrestate ? "1" : "0", optionalText(row.baselineScore),
                optionalText(row.candidateScore), row.baselineAction ?? "", row.candidateAction ?? ""
            ]
            let topology: [String] = [
                String(row.changedEventCount), String(row.directRuleChangedEventCount),
                String(row.pathOnlyChangedEventCount), String(row.reconvergenceCount)
            ]
            let outcome: [String] = [
                optionalText(row.baselineROI), optionalText(row.candidateROI),
                optionalText(row.roiDelta), optionalText(row.baselineDays),
                optionalText(row.candidateDays), optionalText(row.daysDelta),
                row.baselineFinalGrade ?? "", row.candidateFinalGrade ?? "",
                row.outcomeChanged ? "1" : "0"
            ]
            result.append((identity + topology + outcome).map(csvEscape).joined(separator: ","))
        }
        return result.joined(separator: "\n") + "\n"
    }

    private static func html(summary: Summary, rules: [RuleRow], rows: [FirstRow]) -> String {
        let groups = summary.groupScoreDeltas.map { value in
            "<tr><td>\(htmlEscape(value.windowStart))</td><td>\(htmlEscape(value.group))</td>" +
            "<td>\(htmlEscape(optionalText(value.baselineScore)))</td>" +
            "<td>\(htmlEscape(optionalText(value.candidateScore)))</td>" +
            "<td>\(htmlEscape(optionalText(value.delta)))</td></tr>"
        }.joined()
        let first = rows.map { value in
            "<tr><td>\(htmlEscape(dateText(value.windowStart)))</td>" +
            "<td>\(htmlEscape(value.stockID + " " + value.stockName))</td>" +
            "<td>\(htmlEscape(value.group))</td><td>\(htmlEscape(value.grade))</td>" +
            "<td>\(htmlEscape(dateText(value.date)))</td><td>\(htmlEscape(value.phase))</td>" +
            "<td>\(htmlEscape(value.firstChangedRules))</td><td>\(value.changedEventCount)</td>" +
            "<td>\(value.directRuleChangedEventCount)</td>" +
            "<td>\(htmlEscape(optionalText(value.roiDelta)))</td>" +
            "<td>\(htmlEscape(optionalText(value.daysDelta)))</td></tr>"
        }.joined()
        let contribution = rules.map { value in
            "<tr><td>\(htmlEscape(value.ruleID))</td><td>\(htmlEscape(value.phase))</td>" +
            "<td>\(htmlEscape(value.kind))</td><td>\(value.activationCount)</td>" +
            "<td>\(htmlEscape(ratio(value.activationCount, value.phaseEventCount)))</td>" +
            "<td>\(value.actionEventCount)</td>" +
            "<td>\(value.scoreBoundaryCrossingCount.map(String.init) ?? "")</td>" +
            "<td>\(value.solePassedGateActionCount.map(String.init) ?? "")</td>" +
            "<td>\(value.directChangeCount)</td><td>\(value.firstDivergenceCount)</td></tr>"
        }.joined()
        return """
        <!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>P4a \(htmlEscape(summary.candidateID))</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"Noto Sans TC",sans-serif;margin:24px;color:#17212b}
        h1{font-size:24px}h2{margin-top:28px;font-size:18px}.cards{display:flex;flex-wrap:wrap;gap:10px}
        .card{background:#f2f5f8;border-radius:10px;padding:10px 14px;min-width:145px}.n{font-size:22px;font-weight:700}
        table{border-collapse:collapse;width:100%;font-size:13px}th,td{border-bottom:1px solid #dce2e8;padding:7px;text-align:right}
        th:first-child,td:first-child{text-align:left}th{position:sticky;top:0;background:#fff}.scroll{overflow:auto;max-height:520px}
        code{font-size:12px}small{color:#536273}
        </style></head><body>
        <h1>P4a 決策差異分析</h1>
        <p><code>\(htmlEscape(summary.decisionBaseID))</code><br><code>\(htmlEscape(summary.candidateID))</code></p>
        <div class="cards">
          <div class="card"><small>直接規則差異事件</small><div class="n">\(summary.directRuleChangedEventCount)</div></div>
          <div class="card"><small>後續路徑事件</small><div class="n">\(summary.pathOnlyChangedEventCount)</div></div>
          <div class="card"><small>第一次分歧</small><div class="n">\(summary.firstDivergenceCount)</div></div>
          <div class="card"><small>結果改變窗口</small><div class="n">\(summary.outcomeDifferenceCount)</div></div>
          <div class="card"><small>H+L 主分差</small><div class="n">\(htmlEscape(optionalText(summary.combinedMainScoreDelta)))</div></div>
        </div>
        <h2>股群 × 窗口主分</h2><table><tr><th>窗口</th><th>股群</th><th>Baseline</th><th>候選</th><th>差異</th></tr>\(groups)</table>
        <h2>第一次分歧與期末結果</h2><div class="scroll"><table><tr><th>窗口</th><th>個股</th><th>股群</th><th>Grade</th><th>日期</th><th>階段</th><th>首次改變規則</th><th>差異事件</th><th>直接事件</th><th>ROI Δ</th><th>週期 Δ</th></tr>\(first)</table></div>
        <h2>規則貢獻</h2><div class="scroll"><table><tr><th>規則</th><th>階段</th><th>類型</th><th>觸發</th><th>觸發率</th><th>行動事件</th><th>分數跨界</th><th>唯一 gate</th><th>候選直接差異</th><th>首次起源</th></tr>\(contribution)</table></div>
        <p><small>「分數跨界」與「唯一 gate」是局部決策指標，不等同完整反事實因果；正式解讀仍以第一次分歧及完整回測結果為準。</small></p>
        </body></html>
        """
    }

    private static func groupScoresFromDecisionSummary(_ object: [String: Any]) -> [GroupScoreDelta] {
        guard let values = object["groupMainScoreDeltas"] as? [[String: Any]] else { return [] }
        return values.map { value in
            GroupScoreDelta(
                windowStart: "固定三年平均", group: value["group"] as? String ?? "",
                baselineScore: double(value["baseline"]), candidateScore: double(value["candidate"]),
                delta: double(value["delta"])
            )
        }
    }

    private static func counts(_ values: [String]) -> [Count] {
        Dictionary(grouping: values, by: { $0 }).map { Count(key: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.key) > ($1.count, $0.key) }
    }

    private static func argument(after name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any] else {
            throw AnalysisError.invalid(url.path)
        }
        return value
    }

    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func key(_ start: Int64, _ end: Int64, _ stockID: String) -> String {
        "\(start)|\(end)|\(stockID)"
    }

    private static func phaseText(_ value: Int64) -> String {
        switch value {
        case 0: "GRADE"
        case 1: "H_BUY"
        case 2: "L_BUY"
        case 3: "SELL"
        case 4: "ADD"
        default: "UNKNOWN"
        }
    }

    private static func gradeText(_ value: Int64?) -> String {
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

    private static func dateText(_ value: Int64) -> String {
        String(format: "%04lld/%02lld/%02lld", value / 10_000, value / 100 % 100, value % 100)
    }

    private static func optionalDelta(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return rhs - lhs
    }

    private static func optionalText(_ value: Double?) -> String {
        value.map { String(format: "%.6f", $0) } ?? ""
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> String {
        guard denominator > 0 else { return "" }
        return String(format: "%.6f", Double(numerator) / Double(denominator))
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func htmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
#endif
