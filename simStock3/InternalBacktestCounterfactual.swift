import Foundation
import SQLite3

#if DEBUG
@MainActor
enum InternalBacktestCounterfactual {
    enum Mode: String, Codable {
        case noop
        case forceSell = "force-sell"
    }

    struct Target: Codable {
        let windowStart: String
        let windowEnd: String
        let stockID: String
        let date: String
        let expectedStateFingerprint: Int64
    }

    private struct Configuration {
        let id: String
        let mode: Mode
        let target: Target
    }

    private struct Outcome: Codable {
        let roi: Double?
        let averageDays: Double?
        let rounds: Double
        let grade: String
        let moneyLacked: Bool
        let status: String
    }

    private struct Delta: Codable {
        let roi: Double?
        let averageDays: Double?
        let rounds: Double
        let gradeChanged: Bool
        let moneyLackedChanged: Bool
    }

    private struct Summary: Codable {
        let formatVersion: Int
        let createdAt: String
        let counterfactualID: String
        let baselineDecisionBaseID: String
        let mode: Mode
        let target: Target
        let matchedEventCount: Int
        let observedStateFingerprint: Int64?
        let prestateMatched: Bool
        let baselineAction: String?
        let counterfactualAction: String?
        let interventionApplied: Bool
        let baselineOutcome: Outcome
        let counterfactualOutcome: Outcome
        let delta: Delta
        let decisionDeltaDirectory: String
        let interpretation: String
    }

    private struct DecisionSummary: Decodable {
        let baselineEventCount: Int
        let candidateEventCount: Int
        let isZeroDecisionDelta: Bool
        let isZeroOutcomeDelta: Bool
    }

    enum CounterfactualError: LocalizedError {
        case missingArgument(String)
        case invalidArgument(String)
        case eventCount(Int)
        case prestateMismatch(expected: Int64, observed: Int64)
        case unexpectedBaselineAction(String)
        case nonzeroNoopControl
        case missingBaselineOutcome
        case missingCounterfactualOutcome
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .missingArgument(let name):
                return "P5 缺少參數：\(name)"
            case .invalidArgument(let name):
                return "P5 參數無效：\(name)"
            case .eventCount(let count):
                return "P5 目標事件必須精確命中一次，實際為 \(count) 次。"
            case .prestateMismatch(let expected, let observed):
                return "P5 事件前狀態不一致：預期 \(expected)，實際 \(observed)。"
            case .unexpectedBaselineAction(let action):
                return "P5 force-sell 只接受 Baseline HOLD 事件，實際為 \(action)。"
            case .nonzeroNoopControl:
                return "P5 零變更控制出現決策或期末差異，已停止且不建立完成標記。"
            case .missingBaselineOutcome:
                return "P5 找不到 DecisionBase 的目標期末結果。"
            case .missingCounterfactualOutcome:
                return "P5 找不到反事實重播的目標期末結果。"
            case .sqlite(let detail):
                return "P5 讀取 DecisionBase 失敗：\(detail)"
            }
        }
    }

    private static let arguments = ProcessInfo.processInfo.arguments
    private static let mode: Mode? = arguments.contains("--p5-counterfactual-noop")
        ? .noop
        : (arguments.contains("--p5-counterfactual-force-sell") ? .forceSell : nil)
    private static var matchedEventCount = 0
    private static var observedStateFingerprint: Int64?
    private static var baselineAction: String?
    private static var counterfactualAction: String?
    private static var interventionApplied = false

    static var isEnabled: Bool { mode != nil }

    static var counterfactualID: String? {
        guard let mode else { return nil }
        return argument("--p5-id") ?? "p5-\(mode.rawValue)"
    }

    static var runID: String? {
        argument("--p5-run-id") ?? counterfactualID.map { "\($0)-fixed3y-600w" }
    }

    static func prepare() throws {
        guard isEnabled else { return }
        guard !(arguments.contains("--p5-counterfactual-noop")
            && arguments.contains("--p5-counterfactual-force-sell")) else {
            throw CounterfactualError.invalidArgument("只能選擇一種 P5 mode")
        }
        _ = try configuration()
        matchedEventCount = 0
        observedStateFingerprint = nil
        baselineAction = nil
        counterfactualAction = nil
        interventionApplied = false
    }

    static func overrideSellIfNeeded(
        trade: Trade,
        grade: Trade.Grade,
        normalSell: Bool
    ) -> Bool {
        guard let configuration = try? configuration() else { return normalSell }
        let target = configuration.target
        let eventIdentity = [
            dateText(trade.stock.dateStart),
            trade.stock.sId,
            dateText(trade.dateTime),
            "SELL"
        ].joined(separator: "|")
        let targetIdentity = [
            target.windowStart,
            target.stockID,
            target.date,
            "SELL"
        ].joined(separator: "|")
        guard eventIdentity == targetIdentity else { return normalSell }

        matchedEventCount += 1
        let fingerprint = InternalBacktestDecisionRecorder.stateFingerprint(
            trade: trade,
            grade: grade
        )
        observedStateFingerprint = fingerprint
        baselineAction = normalSell ? "SELL" : "HOLD"
        guard fingerprint == target.expectedStateFingerprint else {
            counterfactualAction = baselineAction
            return normalSell
        }

        switch configuration.mode {
        case .noop:
            counterfactualAction = baselineAction
            return normalSell
        case .forceSell:
            guard !normalSell else {
                counterfactualAction = "SELL"
                return normalSell
            }
            interventionApplied = true
            counterfactualAction = "SELL"
            return true
        }
    }

    static func validate() throws {
        guard isEnabled else { return }
        let configuration = try configuration()
        guard matchedEventCount == 1 else {
            throw CounterfactualError.eventCount(matchedEventCount)
        }
        guard let observedStateFingerprint else {
            throw CounterfactualError.eventCount(0)
        }
        guard observedStateFingerprint == configuration.target.expectedStateFingerprint else {
            throw CounterfactualError.prestateMismatch(
                expected: configuration.target.expectedStateFingerprint,
                observed: observedStateFingerprint
            )
        }
        if configuration.mode == .forceSell, baselineAction != "HOLD" {
            throw CounterfactualError.unexpectedBaselineAction(baselineAction ?? "nil")
        }
    }

    static func writeSummary(
        baselineDecisionBaseID: String,
        baselineDirectoryURL: URL,
        deltaDirectoryURL: URL,
        outputRootURL: URL,
        outcomes: [InternalBacktestReport.StockPeriod]
    ) throws {
        guard isEnabled else { return }
        let configuration = try configuration()
        try validate()
        let baseline = try baselineOutcome(
            databaseURL: baselineDirectoryURL.appendingPathComponent("decisions.sqlite"),
            target: configuration.target
        )
        guard let counterfactualRow = outcomes.first(where: {
            $0.periodStart == configuration.target.windowStart
                && $0.periodEnd == configuration.target.windowEnd
                && $0.id == configuration.target.stockID
        }) else {
            throw CounterfactualError.missingCounterfactualOutcome
        }
        let counterfactual = Outcome(
            roi: counterfactualRow.roi,
            averageDays: counterfactualRow.averageDays,
            rounds: counterfactualRow.rounds,
            grade: counterfactualRow.grade,
            moneyLacked: counterfactualRow.moneyLacked,
            status: counterfactualRow.status
        )
        let delta = Delta(
            roi: optionalDelta(counterfactual.roi, baseline.roi),
            averageDays: optionalDelta(counterfactual.averageDays, baseline.averageDays),
            rounds: counterfactual.rounds - baseline.rounds,
            gradeChanged: counterfactual.grade != baseline.grade,
            moneyLackedChanged: counterfactual.moneyLacked != baseline.moneyLacked
        )
        let summary = Summary(
            formatVersion: 1,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            counterfactualID: configuration.id,
            baselineDecisionBaseID: baselineDecisionBaseID,
            mode: configuration.mode,
            target: configuration.target,
            matchedEventCount: matchedEventCount,
            observedStateFingerprint: observedStateFingerprint,
            prestateMatched: observedStateFingerprint
                == configuration.target.expectedStateFingerprint,
            baselineAction: baselineAction,
            counterfactualAction: counterfactualAction,
            interventionApplied: interventionApplied,
            baselineOutcome: baseline,
            counterfactualOutcome: counterfactual,
            delta: delta,
            decisionDeltaDirectory: [
                "DecisionDeltas",
                baselineDecisionBaseID,
                configuration.id
            ].joined(separator: "/"),
            interpretation: configuration.mode == .noop
                ? "零變更控制：應與 DecisionBase 完全一致。"
                : "單一已核准事件的行動級反事實；只代表該事件的局部邊際效果。"
        )

        let directoryURL = outputRootURL
            .appendingPathComponent(baselineDecisionBaseID, isDirectory: true)
            .appendingPathComponent(configuration.id, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: directoryURL.path) {
            try fm.removeItem(at: directoryURL)
        }
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(
            to: directoryURL.appendingPathComponent("counterfactual-summary.json"),
            options: .atomic
        )
        try "complete\n".write(
            to: directoryURL.appendingPathComponent(".complete"),
            atomically: true,
            encoding: .utf8
        )
    }

    static func validateDecisionDeltaIfNeeded(at directoryURL: URL) throws {
        guard let configuration = try? configuration(), configuration.mode == .noop else {
            return
        }
        let summaryURL = directoryURL.appendingPathComponent("decision-summary.json")
        let summary = try JSONDecoder().decode(
            DecisionSummary.self,
            from: Data(contentsOf: summaryURL)
        )
        guard summary.baselineEventCount == summary.candidateEventCount,
              summary.isZeroDecisionDelta,
              summary.isZeroOutcomeDelta else {
            try? FileManager.default.removeItem(
                at: directoryURL.appendingPathComponent(".complete")
            )
            throw CounterfactualError.nonzeroNoopControl
        }
    }

    private static func configuration() throws -> Configuration {
        guard let mode else { throw CounterfactualError.invalidArgument("mode") }
        guard let id = argument("--p5-id"), !id.isEmpty else {
            throw CounterfactualError.missingArgument("--p5-id")
        }
        guard let windowStart = argument("--p5-window-start") else {
            throw CounterfactualError.missingArgument("--p5-window-start")
        }
        guard let windowEnd = argument("--p5-window-end") else {
            throw CounterfactualError.missingArgument("--p5-window-end")
        }
        guard let stockID = argument("--p5-stock-id") else {
            throw CounterfactualError.missingArgument("--p5-stock-id")
        }
        guard let date = argument("--p5-date") else {
            throw CounterfactualError.missingArgument("--p5-date")
        }
        guard let rawFingerprint = argument("--p5-expected-state-fingerprint"),
              let fingerprint = Int64(rawFingerprint) else {
            throw CounterfactualError.invalidArgument("--p5-expected-state-fingerprint")
        }
        return Configuration(
            id: id,
            mode: mode,
            target: Target(
                windowStart: windowStart,
                windowEnd: windowEnd,
                stockID: stockID,
                date: date,
                expectedStateFingerprint: fingerprint
            )
        )
    }

    private static func argument(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func optionalDelta(_ candidate: Double?, _ baseline: Double?) -> Double? {
        guard let candidate, let baseline else { return nil }
        return candidate - baseline
    }

    private static func dateText(_ date: Date) -> String {
        twDateTime.stringFromDate(date, format: "yyyy/MM/dd")
    }

    private static func baselineOutcome(databaseURL: URL, target: Target) throws -> Outcome {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw CounterfactualError.sqlite("無法開啟 \(databaseURL.path)")
        }
        defer { sqlite3_close(database) }
        let sql = """
        SELECT o.roi, o.average_days, o.rounds, o.grade_name, o.money_lacked, o.status
        FROM period_outcomes o
        JOIN windows w ON w.window_id = o.window_id
        JOIN stocks s ON s.stock_key = o.stock_key
        WHERE w.start_date = ? AND w.end_date = ? AND s.stock_id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CounterfactualError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let compactStart = target.windowStart.replacingOccurrences(of: "/", with: "")
        let compactEnd = target.windowEnd.replacingOccurrences(of: "/", with: "")
        sqlite3_bind_int64(statement, 1, Int64(compactStart) ?? 0)
        sqlite3_bind_int64(statement, 2, Int64(compactEnd) ?? 0)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 3, target.stockID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CounterfactualError.missingBaselineOutcome
        }
        func optionalDouble(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, column)
        }
        func text(_ column: Int32) -> String {
            guard let value = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: value)
        }
        return Outcome(
            roi: optionalDouble(0),
            averageDays: optionalDouble(1),
            rounds: sqlite3_column_double(statement, 2),
            grade: text(3),
            moneyLacked: sqlite3_column_int(statement, 4) != 0,
            status: text(5)
        )
    }
}
#endif
