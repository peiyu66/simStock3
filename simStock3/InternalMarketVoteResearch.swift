import Foundation

#if DEBUG
/// Research-only market vote socket. It is inert unless an explicit Q0 launch flag is present.
@MainActor
enum InternalMarketVoteResearch {
    static let ruleID = "MKT-Q0-PULSE"
    static let phenomenonID = "level:market_high_from_prev_close_pct:q10:le"
    static let sourceField = "market_high_from_prev_close_pct"
    static let threshold = -0.30616316995948056
    static let snapshotID = "taiex-market-mt1-20260722-a00beac8d4af"

    enum Mode: Equatable {
        case disabled
        case never
        case pulse(InternalBacktestDecisionRecorder.Phase)

        var code: String {
            switch self {
            case .disabled: "disabled"
            case .never: "never"
            case .pulse(let phase): "pulse-\(phase.code.lowercased())"
            }
        }
    }

    enum ResearchError: LocalizedError {
        case missingSnapshot(String)
        case invalidSnapshot(String)

        var errorDescription: String? {
            switch self {
            case .missingSnapshot(let path):
                return "Q0 市場研究快照不存在：\(path)"
            case .invalidSnapshot(let detail):
                return "Q0 市場研究快照無效：\(detail)"
            }
        }
    }

    static let mode: Mode? = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--candidate-market-vote-disabled") { return .disabled }
        if arguments.contains("--candidate-market-vote-never") { return .never }
        if arguments.contains("--candidate-market-vote-pulse-h") { return .pulse(.hBuy) }
        if arguments.contains("--candidate-market-vote-pulse-l") { return .pulse(.lBuy) }
        if arguments.contains("--candidate-market-vote-pulse-s") { return .pulse(.sell) }
        if arguments.contains("--candidate-market-vote-pulse-a") { return .pulse(.add) }
        return nil
    }()

    static var isConfigured: Bool { mode != nil }

    private static var qualifyingDates: Set<String> = []
    private static var sourceRowCount = 0
    private static var evaluations: [InternalBacktestDecisionRecorder.Phase: Int] = [:]
    private static var marketRowsFound: [InternalBacktestDecisionRecorder.Phase: Int] = [:]
    private static var contributions: [InternalBacktestDecisionRecorder.Phase: Int] = [:]

    static func prepare() throws {
        qualifyingDates.removeAll(keepingCapacity: true)
        sourceRowCount = 0
        evaluations.removeAll(keepingCapacity: true)
        marketRowsFound.removeAll(keepingCapacity: true)
        contributions.removeAll(keepingCapacity: true)

        guard let mode, mode != .disabled else { return }
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let url = documents
            .appendingPathComponent("InternalBacktest/Research/Market", isDirectory: true)
            .appendingPathComponent("market-technical.csv")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ResearchError.missingSnapshot(url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else {
            throw ResearchError.invalidSnapshot("空白 CSV")
        }
        let header = String(lines.removeFirst()).split(separator: ",").map(String.init)
        guard let dateIndex = header.firstIndex(of: "date"),
              let fieldIndex = header.firstIndex(of: sourceField) else {
            throw ResearchError.invalidSnapshot("缺少 date 或 \(sourceField) 欄位")
        }
        var seenDates: Set<String> = []
        var previousDate = ""
        for (offset, line) in lines.enumerated() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.indices.contains(dateIndex), columns.indices.contains(fieldIndex) else {
                throw ResearchError.invalidSnapshot("第 \(offset + 2) 列欄位不足")
            }
            let date = String(columns[dateIndex])
            guard date.count == 10, date > previousDate, seenDates.insert(date).inserted else {
                throw ResearchError.invalidSnapshot("日期未嚴格遞增或重複：\(date)")
            }
            guard let value = Double(columns[fieldIndex]), value.isFinite else {
                throw ResearchError.invalidSnapshot("\(date) 的 \(sourceField) 非有限數值")
            }
            if value <= threshold {
                qualifyingDates.insert(date)
            }
            previousDate = date
        }
        sourceRowCount = lines.count
        guard sourceRowCount == 2_569, previousDate == "2026-07-22",
              !qualifyingDates.isEmpty else {
            throw ResearchError.invalidSnapshot(
                "MT1 身分不符（rows=\(sourceRowCount), through=\(previousDate), matches=\(qualifyingDates.count)）"
            )
        }
    }

    static func contribution(
        for phase: InternalBacktestDecisionRecorder.Phase,
        date: Date
    ) -> Double? {
        guard let mode, mode != .disabled else { return nil }
        evaluations[phase, default: 0] += 1
        let dateText = twDateTime.stringFromDate(date, format: "yyyy-MM-dd")
        let marketRowFound = dateText >= "2016-01-04" && dateText <= "2026-07-22"
        if marketRowFound {
            marketRowsFound[phase, default: 0] += 1
        }
        guard case .pulse(let targetPhase) = mode,
              phase == targetPhase,
              qualifyingDates.contains(dateText) else { return nil }
        contributions[phase, default: 0] += 1
        return 1
    }

    static func writeDiagnostics(to directoryURL: URL) throws {
        guard let mode else { return }
        func phaseCounts(_ values: [InternalBacktestDecisionRecorder.Phase: Int]) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: InternalBacktestDecisionRecorder.Phase.allCases.map {
                ($0.code, values[$0, default: 0])
            })
        }
        let object: [String: Any] = [
            "formatVersion": 1,
            "studyID": "MKT-R02-Q0",
            "mode": mode.code,
            "snapshotID": snapshotID,
            "sourceFile": "market-technical.csv",
            "sourceRowCount": sourceRowCount,
            "phenomenonID": phenomenonID,
            "sourceField": sourceField,
            "operator": "<=",
            "threshold": threshold,
            "qualifyingMarketDateCount": qualifyingDates.count,
            "ruleID": ruleID,
            "contribution": 1,
            "evaluationsByPhase": phaseCounts(evaluations),
            "marketRowsFoundByPhase": phaseCounts(marketRowsFound),
            "contributionsByPhase": phaseCounts(contributions)
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: directoryURL.appendingPathComponent("market-vote-diagnostics.json"),
            options: .atomic
        )
    }
}
#endif
