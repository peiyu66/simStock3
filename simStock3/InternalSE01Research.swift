#if DEBUG
import Foundation
import CryptoKit

/// E1-only, explicit opt-in. No parameter or old feature can enter Release.
@MainActor
enum InternalSE01Research {
    static let baseRule = "8932a9d78fb2c2e4376138e4dce1e2419603db50"
    enum Mode: String, Codable { case control, legacy, unit }
    struct Source: Codable { let file: String; let digest: String }
    struct Manifest: Codable {
        let baseRule: String
        let sample: String
        let fullWindow: Bool
        let stores: [String: Source]
    }
    struct Event: Codable {
        let period: String, stock: String, date: String
        let newZ: Double?, oldZ: Double?, selectedZ: Double?
        let oscMax9: Double?, stockDelta: Double?, marketDelta: Double?
        let mature: Bool, normalSell: Bool, profitExit: Bool, recoveryExit: Bool
        let grade: Int
        let lowDiff: Double?
        let controlSuppressed: Bool, suppressed: Bool
    }
    enum ResearchError: Error { case invalidActivation, invalidSource, missingPeriod, unexpectedTechnicalWrite }
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--se01-e1-mode") }
    static var mode: Mode {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--se01-e1-mode"), args.indices.contains(i + 1) else { return .control }
        return Mode(rawValue: args[i + 1]) ?? .control
    }
    private static var root: URL?
    private static var manifest: Manifest?
    private static var legacyZ: [Date: Double] = [:]
    private static var events: [Event] = []
    static var period = ""

    static func validate(arguments: [String], diagnostic: Bool, maturity: Bool) throws -> Mode? {
        let indices = arguments.indices.filter { arguments[$0] == "--se01-e1-mode" }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, diagnostic, !maturity,
              let index = indices.first, arguments.indices.contains(index + 1),
              let selected = Mode(rawValue: arguments[index + 1]),
              !arguments.contains(where: { $0.hasPrefix("--formal-") || $0.hasPrefix("--candidate-")
                  || $0.hasPrefix("--record-decision") || $0.hasPrefix("--counterfactual") }) else {
            throw ResearchError.invalidActivation
        }
        return selected
    }

    static func prepare(documents: URL, sample: String, fullWindow: Bool) throws {
        guard let _ = try validate(arguments: ProcessInfo.processInfo.arguments,
            diagnostic: InternalBacktestReport.isUpdateCycleDiagnostic,
            maturity: InternalBacktestReport.isUpdateCycleMaturityProbe) else { return }
        let directory = documents.appendingPathComponent("InternalBacktest/E1/\(sample.lowercased())-\(fullWindow ? "full" : "fixed")")
        let source = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("sources.json")))
        guard source.baseRule == baseRule, source.sample == sample, source.fullWindow == fullWindow else {
            throw ResearchError.invalidSource
        }
        root = directory; manifest = source; events = []; legacyZ = [:]
        let data = try Data(contentsOf: documents.appendingPathComponent("InternalBacktest/Research/Market/market-daily.csv"))
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == InternalMarketLow9Input.dailySHA,
              let text = String(data: data, encoding: .utf8) else { throw ResearchError.invalidSource }
        var high = MarketHighDistanceRollingContext()
        var delay = MarketSellDelayRollingContext()
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 5,
                  let date = twDateTime.dateFromString(String(columns[0]), format: "yyyy-MM-dd"),
                  let h = Double(columns[2]), let l = Double(columns[3]), let c = Double(columns[4]) else {
                throw ResearchError.invalidSource
            }
            let distance = high.update(high: h, close: c)
            legacyZ[twDateTime.time1330(date)] = delay.update(high: h, low: l, close: c, highDiff250: distance).highDiffZ250
        }
        guard legacyZ.count == 2569 else { throw ResearchError.invalidSource }
    }

    static func sourceStore(start: Date) throws -> URL {
        guard let root, let source = manifest?.stores[twDateTime.stringFromDate(start)] else {
            throw ResearchError.missingPeriod
        }
        guard !source.file.contains("/"), source.file.hasSuffix(".store") else { throw ResearchError.invalidSource }
        let url = root.appendingPathComponent(source.file)
        guard try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: url) == source.digest else { throw ResearchError.invalidSource }
        return url
    }

    static func technicalMatch(mode: Mode, selectedZ: Double, oscMax9: Double,
                               stockDelta: Double, marketDelta: Double, mature: Bool) -> Bool {
        guard mode == .unit else {
            return SellDelayF01Rule.matches(marketHighZ125: selectedZ, oscMax9: oscMax9,
                stockOscDelta: stockDelta, marketOscDelta: marketDelta, mature: mature)
        }
        guard mature, [selectedZ, oscMax9, stockDelta, marketDelta].allSatisfy(\.isFinite) else { return false }
        return selectedZ > -1 && selectedZ < 1 && oscMax9 < 0 && (stockDelta < 0.22 || marketDelta > 0)
    }

    static func suppress(stock: String, date: Date, newZ: Double, oscMax9: Double,
                         stockDelta: Double, marketDelta: Double, mature: Bool,
                         normalSell: Bool, profitExit: Bool, recoveryExit: Bool,
                         grade: Int, lowDiff: Double, control: Bool) -> Bool {
        precondition(enabled && manifest != nil)
        let old = legacyZ[date] ?? .nan
        let selected = mode == .legacy ? old : newZ
        let suppressed = SellDelayF01Rule.shouldSuppress(
            technicalMatch: technicalMatch(mode: mode, selectedZ: selected, oscMax9: oscMax9,
                stockDelta: stockDelta, marketDelta: marketDelta, mature: mature),
            normalSell: normalSell, profitExit: profitExit, recoveryExit: recoveryExit,
            gradeRaw: grade, lowDiff: lowDiff)
        if mode == .control { precondition(suppressed == control, "E1 control changed S-E01") }
        if normalSell {
            func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
            events.append(Event(period: period, stock: stock, date: twDateTime.stringFromDate(date),
                newZ: finite(newZ), oldZ: finite(old), selectedZ: finite(selected),
                oscMax9: finite(oscMax9), stockDelta: finite(stockDelta), marketDelta: finite(marketDelta),
                mature: mature, normalSell: normalSell, profitExit: profitExit, recoveryExit: recoveryExit,
                grade: grade, lowDiff: finite(lowDiff), controlSuppressed: control, suppressed: suppressed))
        }
        return suppressed
    }

    static func write(to directory: URL) throws {
        guard enabled else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(events).write(to: directory.appendingPathComponent("se01-events.json"), options: .atomic)
    }
}
#endif
