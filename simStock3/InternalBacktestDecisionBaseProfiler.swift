import Foundation

#if DEBUG
@MainActor
enum InternalBacktestDecisionBaseProfiler {
    private static let formatVersion = 1

    struct Result {
        let outputDirectoryURL: URL
        let reportURL: URL
        let overlapPairCount: Int
        let thresholdCandidateCount: Int
        let boundaryEventCount: Int
    }

    private struct KeyCount: Codable {
        let key: String
        let count: Int
    }

    private struct Rule {
        let key: Int64
        let id: String
        let phase: String
        let kind: String
        let description: String
        var activationCount: Int
    }

    private struct RulePair: Codable {
        let phase: String
        let ruleA: String
        let kindA: String
        let activationA: Int
        let ruleB: String
        let kindB: String
        let activationB: Int
        let coactivationCount: Int
        let jaccard: Double?
        let containmentA: Double?
        let containmentB: Double?
        let sameDirectionCount: Int?
        let oppositeDirectionCount: Int?
    }

    private struct PairAggregate {
        let count: Int
        let sameDirectionCount: Int
        let oppositeDirectionCount: Int
    }

    private struct ThresholdKey: Hashable {
        let phaseValue: Int64
        let currentThreshold: Double
    }

    private struct ThresholdDraft {
        let key: ThresholdKey
        let phase: String
        let direction: String
        let candidateThreshold: Double
        var eventCount = 0
        var stockIDs: Set<String> = []
        var windows: Set<String> = []
        var grades: [String] = []
        var windowValues: [String] = []
    }

    private struct ThresholdCandidate: Codable {
        let phase: String
        let direction: String
        let currentThreshold: Double
        let candidateThreshold: Double
        let affectedEventCount: Int
        let affectedStockCount: Int
        let affectedWindowCount: Int
        let byGrade: [KeyCount]
        let byWindow: [KeyCount]
    }

    private struct BoundaryEvent {
        let eventID: Int64
        let phase: String
        let direction: String
        let currentThreshold: Double
        let candidateThreshold: Double
        let windowStart: Int64
        let windowEnd: Int64
        let stockID: String
        let stockName: String
        let group: String
        let date: Int64
        let grade: String
        let decisionScore: Double
        let baselineAction: String
        let candidateAction: String
        let activeRules: String
    }

    private struct Summary: Codable {
        let formatVersion: Int
        let createdAt: String
        let decisionBaseID: String
        let ruleCount: Int
        let overlapPairCount: Int
        let nonzeroOverlapPairCount: Int
        let highSimilarityPairCount: Int
        let topOverlapPairs: [RulePair]
        let thresholdCandidates: [ThresholdCandidate]
        let boundaryEventCount: Int
        let interpretation: [String]
    }

    enum ProfilerError: LocalizedError {
        case missingArgument(String)
        case incomplete(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .missingArgument(let value): "P4b 缺少參數：\(value)"
            case .incomplete(let value): "P4b DecisionBase 不完整：\(value)"
            case .invalid(let value): "P4b DecisionBase 資料不一致：\(value)"
            }
        }
    }

    static func runFromArguments(progress: (String) -> Void = { _ in }) throws -> Result {
        guard let decisionBaseID = argument(after: "--decision-base-id") else {
            throw ProfilerError.missingArgument("--decision-base-id")
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents
            .appendingPathComponent("InternalBacktest/DecisionBases", isDirectory: true)
            .appendingPathComponent(decisionBaseID, isDirectory: true)
        return try write(
            decisionBaseID: decisionBaseID,
            baselineDirectoryURL: directory,
            progress: progress
        )
    }

    static func ensure(
        decisionBaseID: String,
        baselineDirectoryURL: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> Result {
        let marker = baselineDirectoryURL.appendingPathComponent(".p4b-complete")
        let summaryURL = baselineDirectoryURL.appendingPathComponent("p4b-summary.json")
        if FileManager.default.fileExists(atPath: marker.path),
           let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: summaryURL))
                as? [String: Any],
           (object["formatVersion"] as? NSNumber)?.intValue == formatVersion {
            return Result(
                outputDirectoryURL: baselineDirectoryURL,
                reportURL: baselineDirectoryURL.appendingPathComponent("p4b.html"),
                overlapPairCount: (object["overlapPairCount"] as? NSNumber)?.intValue ?? 0,
                thresholdCandidateCount: (object["thresholdCandidates"] as? [Any])?.count ?? 0,
                boundaryEventCount: (object["boundaryEventCount"] as? NSNumber)?.intValue ?? 0
            )
        }
        return try write(
            decisionBaseID: decisionBaseID,
            baselineDirectoryURL: baselineDirectoryURL,
            progress: progress
        )
    }

    static func write(
        decisionBaseID: String,
        baselineDirectoryURL: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baselineDirectoryURL.appendingPathComponent(".complete").path) else {
            throw ProfilerError.incomplete(baselineDirectoryURL.path)
        }
        let databaseURL = baselineDirectoryURL.appendingPathComponent("decisions.sqlite")
        guard fm.fileExists(atPath: databaseURL.path) else {
            throw ProfilerError.incomplete(databaseURL.path)
        }
        let marker = baselineDirectoryURL.appendingPathComponent(".p4b-complete")
        if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }

        let reader = try DeltaSQLiteReader(url: databaseURL)
        defer { reader.close() }
        progress("建立規則重疊矩陣…")
        let rules = try loadRules(reader)
        let pairAggregates = try loadPairAggregates(reader)
        let pairs = buildPairs(rules: rules, aggregates: pairAggregates)

        progress("尋找相鄰決策分數臨界值…")
        let activeRules = try loadThresholdEventRules(reader)
        let thresholdResult = try loadThresholdCandidates(reader, activeRules: activeRules)
        let highSimilarity = pairs.filter {
            $0.coactivationCount >= 10
                && (($0.jaccard ?? 0) >= 0.8
                    || max($0.containmentA ?? 0, $0.containmentB ?? 0) >= 0.9)
        }
        let topPairs = pairs.filter { $0.coactivationCount >= 10 }
            .sorted {
                if ($0.jaccard ?? 0) != ($1.jaccard ?? 0) {
                    return ($0.jaccard ?? 0) > ($1.jaccard ?? 0)
                }
                if $0.coactivationCount != $1.coactivationCount {
                    return $0.coactivationCount > $1.coactivationCount
                }
                return ($0.ruleA, $0.ruleB) < ($1.ruleA, $1.ruleB)
            }
            .prefix(20)
        let summary = Summary(
            formatVersion: formatVersion,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            decisionBaseID: decisionBaseID,
            ruleCount: rules.count,
            overlapPairCount: pairs.count,
            nonzeroOverlapPairCount: pairs.filter { $0.coactivationCount > 0 }.count,
            highSimilarityPairCount: highSimilarity.count,
            topOverlapPairs: Array(topPairs),
            thresholdCandidates: thresholdResult.candidates,
            boundaryEventCount: thresholdResult.events.count,
            interpretation: [
                "重疊以同一決策事件內同時出現的非零票或已通過 gate 計算；共現不等於規則重複或因果等價。",
                "Jaccard 衡量兩規則事件集合的相似度，containment 衡量其中一條規則有多少被另一條涵蓋。",
                "臨界值清單只處理 DecisionBase 已記錄的 H買／L買最終分數門檻；候選值是目前門檻上下最近的實際分數。",
                "逐條技術條件的內部數值門檻尚未保存原始觀察值，因此本階段不從規則描述猜造參數；任何候選仍須完整回測。"
            ]
        )

        progress("寫入 P4b 標準輸出…")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let summaryURL = baselineDirectoryURL.appendingPathComponent("p4b-summary.json")
        try encoder.encode(summary).write(to: summaryURL, options: .atomic)
        try overlapPairsCSV(pairs).write(
            to: baselineDirectoryURL.appendingPathComponent("rule-overlap-pairs.csv"),
            atomically: true,
            encoding: .utf8
        )
        try overlapMatrixCSV(rules: rules, aggregates: pairAggregates).write(
            to: baselineDirectoryURL.appendingPathComponent("rule-overlap-matrix.csv"),
            atomically: true,
            encoding: .utf8
        )
        try thresholdCSV(thresholdResult.candidates).write(
            to: baselineDirectoryURL.appendingPathComponent("decision-threshold-candidates.csv"),
            atomically: true,
            encoding: .utf8
        )
        try boundaryCSV(thresholdResult.events).write(
            to: baselineDirectoryURL.appendingPathComponent("decision-boundary-events.csv"),
            atomically: true,
            encoding: .utf8
        )
        let reportURL = baselineDirectoryURL.appendingPathComponent("p4b.html")
        try html(summary: summary).write(to: reportURL, atomically: true, encoding: .utf8)
        let manifest: [String: Any] = [
            "formatVersion": formatVersion,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "decisionBaseID": decisionBaseID,
            "files": [
                "p4b-summary.json", "rule-overlap-pairs.csv", "rule-overlap-matrix.csv",
                "decision-threshold-candidates.csv", "decision-boundary-events.csv",
                "p4b.html", "p4b-manifest.json", ".p4b-complete"
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: baselineDirectoryURL.appendingPathComponent("p4b-manifest.json"), options: .atomic)
        try decisionBaseID.write(to: marker, atomically: true, encoding: .utf8)
        return Result(
            outputDirectoryURL: baselineDirectoryURL,
            reportURL: reportURL,
            overlapPairCount: pairs.count,
            thresholdCandidateCount: thresholdResult.candidates.count,
            boundaryEventCount: thresholdResult.events.count
        )
    }

    private static func loadRules(_ reader: DeltaSQLiteReader) throws -> [Rule] {
        var activations: [Int64: Int] = [:]
        try reader.rows(
            """
            SELECT rule_key,COUNT(*) FROM (
                SELECT event_id,rule_key FROM event_votes
                UNION ALL SELECT event_id,rule_key FROM event_gates
            ) GROUP BY rule_key
            """
        ) { row in
            activations[row.integer(0)] = Int(row.integer(1))
        }
        var rules: [Rule] = []
        try reader.rows(
            """
            SELECT rule_key,rule_id,
                CASE phase WHEN 0 THEN 'GRADE' WHEN 1 THEN 'H_BUY' WHEN 2 THEN 'L_BUY'
                    WHEN 3 THEN 'SELL' WHEN 4 THEN 'ADD' END,
                CASE kind WHEN 1 THEN 'vote' ELSE 'gate' END,description
            FROM rules ORDER BY rule_id
            """
        ) { row in
            rules.append(Rule(
                key: row.integer(0), id: row.text(1), phase: row.text(2), kind: row.text(3),
                description: row.text(4), activationCount: activations[row.integer(0)] ?? 0
            ))
        }
        return rules
    }

    private static func loadPairAggregates(
        _ reader: DeltaSQLiteReader
    ) throws -> [String: PairAggregate] {
        var result: [String: PairAggregate] = [:]
        try reader.rows(
            """
            WITH active AS (
                SELECT event_id,rule_key,contribution FROM event_votes
                UNION ALL SELECT event_id,rule_key,NULL AS contribution FROM event_gates
            )
            SELECT a.rule_key,b.rule_key,COUNT(*),
                SUM(CASE WHEN a.contribution*b.contribution>0 THEN 1 ELSE 0 END),
                SUM(CASE WHEN a.contribution*b.contribution<0 THEN 1 ELSE 0 END)
            FROM active a JOIN active b ON a.event_id=b.event_id AND a.rule_key<b.rule_key
            GROUP BY a.rule_key,b.rule_key
            """
        ) { row in
            result[pairKey(row.integer(0), row.integer(1))] = PairAggregate(
                count: Int(row.integer(2)), sameDirectionCount: Int(row.integer(3)),
                oppositeDirectionCount: Int(row.integer(4))
            )
        }
        return result
    }

    private static func buildPairs(
        rules: [Rule],
        aggregates: [String: PairAggregate]
    ) -> [RulePair] {
        var pairs: [RulePair] = []
        for leftIndex in rules.indices {
            for rightIndex in rules.indices where rightIndex > leftIndex {
                let left = rules[leftIndex]
                let right = rules[rightIndex]
                guard left.phase == right.phase else { continue }
                let aggregate = aggregates[pairKey(left.key, right.key)]
                    ?? PairAggregate(count: 0, sameDirectionCount: 0, oppositeDirectionCount: 0)
                let union = left.activationCount + right.activationCount - aggregate.count
                let votePair = left.kind == "vote" && right.kind == "vote"
                pairs.append(RulePair(
                    phase: left.phase, ruleA: left.id, kindA: left.kind,
                    activationA: left.activationCount, ruleB: right.id, kindB: right.kind,
                    activationB: right.activationCount, coactivationCount: aggregate.count,
                    jaccard: ratio(aggregate.count, union),
                    containmentA: ratio(aggregate.count, left.activationCount),
                    containmentB: ratio(aggregate.count, right.activationCount),
                    sameDirectionCount: votePair ? aggregate.sameDirectionCount : nil,
                    oppositeDirectionCount: votePair ? aggregate.oppositeDirectionCount : nil
                ))
            }
        }
        return pairs
    }

    private static func loadThresholdEventRules(
        _ reader: DeltaSQLiteReader
    ) throws -> [Int64: [String]] {
        var result: [Int64: [String]] = [:]
        try reader.rows(
            """
            SELECT a.event_id,r.rule_id FROM (
                SELECT event_id,rule_key FROM event_votes
                UNION ALL SELECT event_id,rule_key FROM event_gates
            ) a JOIN rules r USING(rule_key) JOIN decision_events e USING(event_id)
            WHERE e.decision_threshold IS NOT NULL ORDER BY a.event_id,r.rule_id
            """
        ) { row in
            result[row.integer(0), default: []].append(row.text(1))
        }
        return result
    }

    private static func loadThresholdCandidates(
        _ reader: DeltaSQLiteReader,
        activeRules: [Int64: [String]]
    ) throws -> (candidates: [ThresholdCandidate], events: [BoundaryEvent]) {
        var scores: [ThresholdKey: Set<Double>] = [:]
        try reader.rows(
            """
            SELECT phase,decision_threshold,decision_score FROM decision_events
            WHERE decision_threshold IS NOT NULL GROUP BY phase,decision_threshold,decision_score
            """
        ) { row in
            scores[ThresholdKey(
                phaseValue: row.integer(0), currentThreshold: row.real(1)
            ), default: []].insert(row.real(2))
        }
        var drafts: [ThresholdDraft] = []
        for (key, values) in scores {
            if let looser = values.filter({ $0 < key.currentThreshold }).max() {
                drafts.append(ThresholdDraft(
                    key: key, phase: phaseText(key.phaseValue), direction: "looser",
                    candidateThreshold: looser
                ))
            }
            if let stricter = values.filter({ $0 > key.currentThreshold }).min() {
                drafts.append(ThresholdDraft(
                    key: key, phase: phaseText(key.phaseValue), direction: "stricter",
                    candidateThreshold: stricter
                ))
            }
        }
        drafts.sort {
            ($0.key.phaseValue, $0.direction == "looser" ? 0 : 1)
                < ($1.key.phaseValue, $1.direction == "looser" ? 0 : 1)
        }

        var events: [BoundaryEvent] = []
        try reader.rows(
            """
            SELECT e.event_id,e.phase,e.decision_threshold,e.decision_score,
                w.start_date,w.end_date,s.stock_id,s.name,s.group_name,e.trade_date,e.grade,
                e.planned_action
            FROM decision_events e JOIN windows w USING(window_id) JOIN stocks s USING(stock_key)
            WHERE e.decision_threshold IS NOT NULL
            ORDER BY e.phase,w.start_date,s.stock_id,e.trade_date
            """
        ) { row in
            let key = ThresholdKey(phaseValue: row.integer(1), currentThreshold: row.real(2))
            let score = row.real(3)
            for index in drafts.indices where drafts[index].key == key {
                let candidate = drafts[index].candidateThreshold
                let affected = drafts[index].direction == "looser"
                    ? score >= candidate && score < key.currentThreshold
                    : score >= key.currentThreshold && score < candidate
                guard affected else { continue }
                let stockID = row.text(6)
                let window = dateText(row.integer(4)) + "–" + dateText(row.integer(5))
                let grade = gradeText(row.integer(10))
                drafts[index].eventCount += 1
                drafts[index].stockIDs.insert(stockID)
                drafts[index].windows.insert(window)
                drafts[index].grades.append(grade)
                drafts[index].windowValues.append(window)
                events.append(BoundaryEvent(
                    eventID: row.integer(0), phase: drafts[index].phase,
                    direction: drafts[index].direction,
                    currentThreshold: key.currentThreshold, candidateThreshold: candidate,
                    windowStart: row.integer(4), windowEnd: row.integer(5), stockID: stockID,
                    stockName: row.text(7), group: row.text(8), date: row.integer(9),
                    grade: grade, decisionScore: score, baselineAction: row.text(11),
                    candidateAction: action(phase: key.phaseValue, passes: score >= candidate),
                    activeRules: (activeRules[row.integer(0)] ?? []).joined(separator: "+")
                ))
            }
        }
        let candidates = drafts.map { value in
            ThresholdCandidate(
                phase: value.phase, direction: value.direction,
                currentThreshold: value.key.currentThreshold,
                candidateThreshold: value.candidateThreshold,
                affectedEventCount: value.eventCount, affectedStockCount: value.stockIDs.count,
                affectedWindowCount: value.windows.count, byGrade: counts(value.grades),
                byWindow: counts(value.windowValues)
            )
        }
        return (candidates, events)
    }

    private static func overlapPairsCSV(_ rows: [RulePair]) -> String {
        var result = [[
            "phase", "ruleA", "kindA", "activationA", "ruleB", "kindB", "activationB",
            "coactivationCount", "jaccard", "containmentA", "containmentB",
            "sameDirectionCount", "oppositeDirectionCount"
        ].joined(separator: ",")]
        for row in rows where row.coactivationCount > 0 {
            let values = [
                row.phase, row.ruleA, row.kindA, String(row.activationA), row.ruleB, row.kindB,
                String(row.activationB), String(row.coactivationCount), optionalText(row.jaccard),
                optionalText(row.containmentA), optionalText(row.containmentB),
                row.sameDirectionCount.map(String.init) ?? "",
                row.oppositeDirectionCount.map(String.init) ?? ""
            ]
            result.append(values.map(csvEscape).joined(separator: ","))
        }
        return result.joined(separator: "\n") + "\n"
    }

    private static func overlapMatrixCSV(
        rules: [Rule],
        aggregates: [String: PairAggregate]
    ) -> String {
        var result = [("ruleID," + rules.map { csvEscape($0.id) }.joined(separator: ","))]
        for left in rules {
            var values = [left.id]
            for right in rules {
                if left.phase != right.phase {
                    values.append("")
                } else if left.key == right.key {
                    values.append(left.activationCount > 0 ? "1.000000" : "")
                } else {
                    let aggregate = aggregates[pairKey(left.key, right.key)]?.count ?? 0
                    let union = left.activationCount + right.activationCount - aggregate
                    values.append(optionalText(ratio(aggregate, union)))
                }
            }
            result.append(values.map(csvEscape).joined(separator: ","))
        }
        return result.joined(separator: "\n") + "\n"
    }

    private static func thresholdCSV(_ rows: [ThresholdCandidate]) -> String {
        var result = [[
            "phase", "direction", "currentThreshold", "candidateThreshold",
            "affectedEventCount", "affectedStockCount", "affectedWindowCount",
            "gradeDistribution", "windowDistribution"
        ].joined(separator: ",")]
        for row in rows {
            let values = [
                row.phase, row.direction, optionalText(row.currentThreshold),
                optionalText(row.candidateThreshold), String(row.affectedEventCount),
                String(row.affectedStockCount), String(row.affectedWindowCount),
                countText(row.byGrade), countText(row.byWindow)
            ]
            result.append(values.map(csvEscape).joined(separator: ","))
        }
        return result.joined(separator: "\n") + "\n"
    }

    private static func boundaryCSV(_ rows: [BoundaryEvent]) -> String {
        var result = [[
            "eventID", "phase", "direction", "currentThreshold", "candidateThreshold", "windowStart",
            "windowEnd", "stockID", "stockName", "group", "date", "grade",
            "decisionScore", "baselineAction", "candidateLocalAction", "activeRules"
        ].joined(separator: ",")]
        for row in rows {
            let values = [
                String(row.eventID), row.phase, row.direction, optionalText(row.currentThreshold),
                optionalText(row.candidateThreshold), dateText(row.windowStart),
                dateText(row.windowEnd), row.stockID, row.stockName, row.group,
                dateText(row.date), row.grade, optionalText(row.decisionScore),
                row.baselineAction, row.candidateAction, row.activeRules
            ]
            result.append(values.map(csvEscape).joined(separator: ","))
        }
        return result.joined(separator: "\n") + "\n"
    }

    private static func html(summary: Summary) -> String {
        let candidates = summary.thresholdCandidates.map { value in
            "<tr><td>\(htmlEscape(value.phase))</td><td>\(htmlEscape(value.direction))</td>" +
            "<td>\(optionalText(value.currentThreshold))</td>" +
            "<td>\(optionalText(value.candidateThreshold))</td>" +
            "<td>\(value.affectedEventCount)</td><td>\(value.affectedStockCount)</td>" +
            "<td>\(htmlEscape(countText(value.byGrade)))</td></tr>"
        }.joined()
        let pairs = summary.topOverlapPairs.map { value in
            "<tr><td>\(htmlEscape(value.phase))</td><td>\(htmlEscape(value.ruleA))</td>" +
            "<td>\(htmlEscape(value.ruleB))</td><td>\(value.coactivationCount)</td>" +
            "<td>\(optionalText(value.jaccard))</td>" +
            "<td>\(optionalText(value.containmentA))</td>" +
            "<td>\(optionalText(value.containmentB))</td>" +
            "<td>\(value.sameDirectionCount.map(String.init) ?? "")</td>" +
            "<td>\(value.oppositeDirectionCount.map(String.init) ?? "")</td></tr>"
        }.joined()
        return """
        <!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>P4b \(htmlEscape(summary.decisionBaseID))</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"Noto Sans TC",sans-serif;margin:24px;color:#17212b}
        h1{font-size:24px}h2{margin-top:28px;font-size:18px}.cards{display:flex;flex-wrap:wrap;gap:10px}
        .card{background:#f2f5f8;border-radius:10px;padding:10px 14px;min-width:145px}.n{font-size:22px;font-weight:700}
        table{border-collapse:collapse;width:100%;font-size:13px}th,td{border-bottom:1px solid #dce2e8;padding:7px;text-align:right}
        th:first-child,td:first-child{text-align:left}th{background:#fff}.note{color:#536273;max-width:900px}code{font-size:12px}
        </style></head><body>
        <h1>P4b 規則重疊與決策臨界值</h1><p><code>\(htmlEscape(summary.decisionBaseID))</code></p>
        <div class="cards">
          <div class="card"><small>規則</small><div class="n">\(summary.ruleCount)</div></div>
          <div class="card"><small>同階段規則對</small><div class="n">\(summary.overlapPairCount)</div></div>
          <div class="card"><small>有共現規則對</small><div class="n">\(summary.nonzeroOverlapPairCount)</div></div>
          <div class="card"><small>相鄰分數候選</small><div class="n">\(summary.thresholdCandidates.count)</div></div>
          <div class="card"><small>局部邊界事件</small><div class="n">\(summary.boundaryEventCount)</div></div>
        </div>
        <h2>相鄰決策分數候選</h2><table><tr><th>階段</th><th>方向</th><th>現值</th><th>候選</th><th>局部事件</th><th>股票</th><th>Grade</th></tr>\(candidates)</table>
        <h2>共現相似度最高的規則對</h2><table><tr><th>階段</th><th>規則 A</th><th>規則 B</th><th>共現</th><th>Jaccard</th><th>A 被涵蓋</th><th>B 被涵蓋</th><th>同向</th><th>反向</th></tr>\(pairs)</table>
        <p class="note">重疊只表示同一決策事件共現，不等於規則重複。臨界值只涵蓋已記錄的 H買／L買最終分數門檻；逐條技術條件的原始觀察值尚未旁錄，因此不猜造內部參數。所有候選仍須完整回測。</p>
        </body></html>
        """
    }

    private static func counts(_ values: [String]) -> [KeyCount] {
        Dictionary(grouping: values, by: { $0 }).map { KeyCount(key: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.key < $1.key
            }
    }

    private static func countText(_ values: [KeyCount]) -> String {
        values.map { "\($0.key):\($0.count)" }.joined(separator: "|")
    }

    private static func pairKey(_ lhs: Int64, _ rhs: Int64) -> String {
        lhs < rhs ? "\(lhs)|\(rhs)" : "\(rhs)|\(lhs)"
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
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

    private static func action(phase: Int64, passes: Bool) -> String {
        guard passes else { return "NONE" }
        return phase == 1 ? "H" : (phase == 2 ? "L" : "PASS")
    }

    private static func dateText(_ value: Int64) -> String {
        String(format: "%04lld/%02lld/%02lld", value / 10_000, value / 100 % 100, value % 100)
    }

    private static func optionalText(_ value: Double?) -> String {
        value.map { String(format: "%.6f", $0) } ?? ""
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

    private static func argument(after name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
#endif
