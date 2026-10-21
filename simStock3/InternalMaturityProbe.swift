#if DEBUG
import Foundation
import SwiftData
import CryptoKit

/// Same-rule diagnostic only. The cold arm is the first completed P5 period;
/// the other arm receives identical raw input in newest-first six-month batches.
/// Ordinary T retains the product's maturity contract. Any resulting decision
/// differences are evidence, never silently accepted as a zero-difference pass.
@MainActor
enum InternalMaturityProbe {
    enum ProbeError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let detail): return "成熟形成對照未通過：\(detail)" }
        }
    }
    struct Raw: Codable, Equatable {
        let date: Date
        let source: String
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double
        init(_ row: Trade) {
            date = row.dateTime; source = row.dataSource
            open = row.priceOpen; high = row.priceHigh; low = row.priceLow
            close = row.priceClose; volume = row.volumeClose
        }
        var valid: Bool { close.isFinite && close > 0 }
        func insert(stock: Stock, in context: ModelContext) {
            let row = Trade(stock: stock, dateTime: date)
            row.dataSource = source; row.priceOpen = open; row.priceHigh = high
            row.priceLow = low; row.priceClose = close; row.volumeClose = volume
            context.insert(row)
        }
    }
    struct Batch: Codable {
        let lower: Date
        let upperExclusive: Date
        let raw: [Raw]
    }
    struct BatchTrace: Codable {
        let batch: Int
        let lower: Date
        let upperExclusive: Date
        let insertedDates: [Date]
        let ordinaryDates: [Date]
        let pricePathDates: [Date]
        let simulationDates: [Date]
        let technicalVersion: Int
        let technicalDirtyFrom: Date?
        let simulationDirtyFrom: Date?
        let effectiveStart: Date?
    }
    struct Value: Codable, Equatable {
        var number: Double? = nil
        var text: String? = nil
        static func numeric(_ value: Double?) -> Self { .init(number: value) }
        static func string(_ value: String) -> Self { .init(text: value) }
    }
    struct Difference: Codable {
        let date: Date
        let group: String
        let field: String
        let cold: Value
        let batched: Value
    }
    struct FieldSummary: Codable {
        let group: String
        let field: String
        let changedRows: Int
        let firstDate: Date
        let maximumAbsoluteDifference: Double?
    }
    struct StockReport: Codable {
        let stockID: String
        let requestStart: Date
        let effectiveStart: Date
        let targetEnd: Date
        let allRawCount: Int
        let retainedOutsideWindowCount: Int
        let technicalComparisonCount: Int
        let simulationComparisonCount: Int
        let rawSHA256: String
        let batchCount: Int
        let ordinaryChangedRows: Int
        let pathChangedRows: Int
        let simulationChangedRows: Int
        // Includes rule/intent and quantity changes; not every row is a fill.
        let transactionChangedRows: Int
        let gradeChangedRows: Int
        let warningChangedRows: Int
        let accountChangedRows: Int
        let fields: [FieldSummary]
        let remainingSimulationDirtyFrom: Date?
        let wholeStockSimulationVersion: Int
    }
    struct Report: Codable {
        let comparisonCompleted: Bool
        let boundedPathIdentical: Bool
        let simulationIdentical: Bool
        let ordinaryIdentical: Bool
        let formalStrategy: Bool
        let formalBaseline: Bool
        let completeMeaning: String
        let ruleCommit: String
        let dataRules: String
        let marketVersion: Int
        let ordinaryFieldNames: [String]
        let pathFieldNames: [String]
        let validityScope: String
        let technicalBaseSHA256: String
        let coldStoreSHA256: String
        let stocks: [StockReport]
    }

    static let ordinaryFields: [(String, KeyPath<Trade, Double>)] = [

            ("tHighDiff", \Trade.tHighDiff),
            ("tHighDiff125", \Trade.tHighDiff125),
            ("tHighDiff250", \Trade.tHighDiff250),
            ("tHighDiffZ125", \Trade.tHighDiffZ125),
            ("tHighDiffZ250", \Trade.tHighDiffZ250),
            ("tHighMax9", \Trade.tHighMax9),
            ("tLowDiff", \Trade.tLowDiff),
            ("tLowDiff125", \Trade.tLowDiff125),
            ("tLowDiff250", \Trade.tLowDiff250),
            ("tLowDiffZ125", \Trade.tLowDiffZ125),
            ("tLowDiffZ250", \Trade.tLowDiffZ250),
            ("tLowMin9", \Trade.tLowMin9),
            ("tMa20", \Trade.tMa20),
            ("tMa20Days", \Trade.tMa20Days),
            ("tMa20Diff", \Trade.tMa20Diff),
            ("tMa20DiffMax9", \Trade.tMa20DiffMax9),
            ("tMa20DiffMin9", \Trade.tMa20DiffMin9),
            ("tMa20DiffZ125", \Trade.tMa20DiffZ125),
            ("tMa20DiffZ250", \Trade.tMa20DiffZ250),
            ("tMa60", \Trade.tMa60),
            ("tMa60Days", \Trade.tMa60Days),
            ("tMa60Diff", \Trade.tMa60Diff),
            ("tMa60DiffMax9", \Trade.tMa60DiffMax9),
            ("tMa60DiffMin9", \Trade.tMa60DiffMin9),
            ("tMa60DiffZ125", \Trade.tMa60DiffZ125),
            ("tMa60DiffZ250", \Trade.tMa60DiffZ250),
            ("tZ125", \Trade.tZ125),
            ("tZ250", \Trade.tZ250),
            ("tKdK", \Trade.tKdK),
            ("tKdKMax9", \Trade.tKdKMax9),
            ("tKdKMin9", \Trade.tKdKMin9),
            ("tKdKZ125", \Trade.tKdKZ125),
            ("tKdKZ250", \Trade.tKdKZ250),
            ("tKdD", \Trade.tKdD),
            ("tKdDZ125", \Trade.tKdDZ125),
            ("tKdDZ250", \Trade.tKdDZ250),
            ("tKdJ", \Trade.tKdJ),
            ("tKdJZ125", \Trade.tKdJZ125),
            ("tKdJZ250", \Trade.tKdJZ250),
            ("tOsc", \Trade.tOsc),
            ("tOscEma12", \Trade.tOscEma12),
            ("tOscEma26", \Trade.tOscEma26),
            ("tOscMacd9", \Trade.tOscMacd9),
            ("tOscMax9", \Trade.tOscMax9),
            ("tOscMin9", \Trade.tOscMin9),
            ("tOscZ125", \Trade.tOscZ125),
            ("tOscZ250", \Trade.tOscZ250),
            ("vMa20", \Trade.vMa20),
            ("vMa20Days", \Trade.vMa20Days),
            ("vMa20Diff", \Trade.vMa20Diff),
            ("vMa20DiffMax9", \Trade.vMa20DiffMax9),
            ("vMa20DiffMin9", \Trade.vMa20DiffMin9),
            ("vMa20DiffZ125", \Trade.vMa20DiffZ125),
            ("vMa20DiffZ250", \Trade.vMa20DiffZ250),
            ("vMa60", \Trade.vMa60),
            ("vMa60Days", \Trade.vMa60Days),
            ("vMa60Diff", \Trade.vMa60Diff),
            ("vMa60DiffMax9", \Trade.vMa60DiffMax9),
            ("vMa60DiffMin9", \Trade.vMa60DiffMin9),
            ("vMa60DiffZ125", \Trade.vMa60DiffZ125),
            ("vMa60DiffZ250", \Trade.vMa60DiffZ250),
            ("vMax9", \Trade.vMax9),
            ("vMin9", \Trade.vMin9),
            ("vZ125", \Trade.vZ125),
            ("vZ250", \Trade.vZ250),

    ]
    static let pathFieldNames = ["tPricePathPhaseRaw", "tPricePathBarrier", "tPricePathAnchorClose",
                                 "tPricePathExtremeClose", "tPricePathDaysSinceExtreme"]
    private static let accountFields: [(String, KeyPath<Trade, Double>)] = [
        ("rollAmtCost", \.rollAmtCost), ("rollAmtProfit", \.rollAmtProfit), ("rollAmtRoi", \.rollAmtRoi),
        ("rollDays", \.rollDays), ("rollRounds", \.rollRounds), ("simAmtBalance", \.simAmtBalance),
        ("simAmtCost", \.simAmtCost), ("simAmtProfit", \.simAmtProfit), ("simAmtRoi", \.simAmtRoi),
        ("simDays", \.simDays), ("simUnitCost", \.simUnitCost), ("simUnitRoi", \.simUnitRoi),
        ("simInvestExceedCumulative", \.simInvestExceedCumulative), ("roi", \.roi),
        ("baseRoi", \.baseRoi), ("days", \.days), ("years", \.years)
    ]
    private static let transactionFields: [(String, KeyPath<Trade, Double>)] = [
        ("simQtyBuy", \.simQtyBuy), ("simQtySell", \.simQtySell), ("simQtyInventory", \.simQtyInventory),
        ("simInvestAdded", \.simInvestAdded), ("simInvestByUser", \.simInvestByUser),
        ("simInvestTimes", \.simInvestTimes)
    ]

    static func validateActivation(diagnostic: Bool, sample: String, fullWindow: Bool, identifier: String?) throws {
        guard diagnostic, sample.uppercased() == "A", !fullWindow,
              let identifier, identifier.count <= 80,
              identifier.range(of: "^p5-maturity-[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
            throw ProbeError.invalid("只允許 diagnostic / A / fixed3y，且唯一 id 必須以 p5-maturity- 開始")
        }
    }

    /// Include all retained raw records in storage, but never insert outside-W
    /// observations as calculation changes. Invalid raw is retained separately,
    /// matching fetchCalculationWindow's finite-positive calculation sequence.
    static func batches(raw: [Raw], requestStart: Date) -> [Batch] {
        let rows = raw.filter { $0.date >= requestStart && $0.valid }.sorted { $0.date < $1.date }
        guard let latest = rows.last?.date else { return [] }
        let calendar = twDateTime.calendar
        var upper = calendar.date(byAdding: .day, value: 1, to: twDateTime.startOfDay(latest))!
        var result: [Batch] = []
        while upper > requestStart {
            let lower = max(requestStart, calendar.date(byAdding: .month, value: -6, to: upper)!)
            let selected = rows.filter { $0.date >= lower && $0.date < upper }
            if !selected.isEmpty { result.append(.init(lower: lower, upperExclusive: upper, raw: selected)) }
            upper = lower
        }
        return result
    }

    @discardableResult
    static func run(technicalBaseURL: URL, coldStoreURL: URL, outputURL: URL,
                    start: Date, end: Date, money: Double, investments: Double,
                    marketLookup: MarketPricePathLookup, ruleCommit: String,
                    expectedStockIDs: [String], coldTraces: [String: RecalculationTrace],
                    progress: (String) -> Void = { _ in }) throws -> Report {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: outputURL.path) else { throw ProbeError.invalid("對照輸出已存在，拒絕覆寫") }
        guard ruleCommit.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil,
              expectedStockIDs.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }),
              ordinaryFields.count == 65, Set(ordinaryFields.map(\.0)).count == 65 else {
            throw ProbeError.invalid("commit／股票身分無效，或普通 T 不是 65 個唯一欄位")
        }
        let baseDigest = try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: technicalBaseURL)
        let coldDigest = try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: coldStoreURL)
        let baseContainer = try container(url: technicalBaseURL, writable: false)
        let coldContainer = try container(url: coldStoreURL, writable: false)
        // Keep only value identities between stocks. A long-lived context can
        // retain registered models and Foundation temporaries across all batches.
        let stockIDs = try autoreleasepool {
            let baseContext = ModelContext(baseContainer); baseContext.autosaveEnabled = false
            let coldContext = ModelContext(coldContainer); coldContext.autosaveEnabled = false
            return (base: try Stock.fetchAll(in: baseContext).map(\.sId),
                    cold: try Stock.fetchAll(in: coldContext).map(\.sId))
        }
        guard stockIDs.base.sorted() == expectedStockIDs.sorted(),
              stockIDs.cold.sorted() == expectedStockIDs.sorted(),
              Set(expectedStockIDs).count == expectedStockIDs.count,
              Set(coldTraces.keys) == Set(expectedStockIDs) else { throw ProbeError.invalid("股票／冷臂 trace 範圍不符") }
        try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let batchedContainer = try container(url: outputURL.appendingPathComponent("batched.store"), writable: true)
        defer { withExtendedLifetime((baseContainer, coldContainer, batchedContainer)) {} }
        var reports: [StockReport] = []
        for (stockIndex, stockID) in stockIDs.base.enumerated() {
            let report = try autoreleasepool {
                let baseContext = ModelContext(baseContainer); baseContext.autosaveEnabled = false
                let coldContext = ModelContext(coldContainer); coldContext.autosaveEnabled = false
                let context = ModelContext(batchedContainer); context.autosaveEnabled = false
                let technical = Technical(modelContext: context, marketPricePathLookup: marketLookup)
                let descriptor = FetchDescriptor<Stock>(predicate: #Predicate { $0.sId == stockID })
                guard let base = try baseContext.fetch(descriptor).first,
                      let cold = try coldContext.fetch(descriptor).first else {
                    throw ProbeError.invalid("\(stockID) 已核對的股票在來源中缺席")
                }
                let baseRows = try Trade.fetch(in: baseContext, for: base)
                let coldRows = try Trade.fetch(in: coldContext, for: cold)
                let raw = baseRows.map(Raw.init)
                guard raw == coldRows.map(Raw.init), Set(raw.map(\.date)).count == raw.count,
                      Set(raw.map { twDateTime.startOfDay($0.date) }).count == raw.count else {
                    throw ProbeError.invalid("\(base.sId) 兩臂原始資料不同或日期重複")
                }
                let window = CalculationWindow(configuredStart: start, prices: raw.map { ($0.date, $0.close) })
                let valid = baseRows.filter { $0.dateTime >= window.requestStart && $0.priceClose.isFinite && $0.priceClose > 0 }
                let coldValid = coldRows.filter { $0.dateTime >= window.requestStart && $0.priceClose.isFinite && $0.priceClose > 0 }
                guard let effective = window.simulationStart, window.hasSimulationDates,
                      twDateTime.startOfDay(base.dateStart) == twDateTime.startOfDay(start), cold.dateStart == start,
                      sameWindow(base.calculationWindow, window), sameWindow(cold.calculationWindow, window),
                      cold.simMoneyBase == money, cold.simInvestAuto == investments,
                      base.technicalStateVersion == Int(Technical.technicalRuleVersion.dropFirst())!,
                      cold.technicalStateVersion == base.technicalStateVersion,
                      base.technicalDirtyFrom == nil, cold.technicalDirtyFrom == nil,
                      base.technicalPendingWork == nil, cold.technicalPendingWork == nil,
                      base.simulationDirtyFrom != nil else {
                    throw ProbeError.invalid("\(base.sId) 冷臂不是本次首窗的完整 T-only 基底／設定不符")
                }
                let coldTarget = coldValid.filter { $0.dateTime >= effective && $0.dateTime <= end }
                guard !coldTarget.isEmpty, let coldTrace = coldTraces[base.sId],
                      coldTrace.technicalDates.isEmpty,
                      coldTrace.simulationDates == coldTarget.map(\.dateTime),
                      coldTrace.simulationDependencyIssue == nil, coldTrace.blockedSimulationDate == nil,
                      cold.simulationDirtyFrom.map({ $0 > coldTarget.last!.dateTime }) ?? true else {
                    throw ProbeError.invalid("\(base.sId) 冷臂首窗未完整寫入 S 或曾重算 T")
                }
                // This verifies that the reused cold arm really is the full raw
                // initialization, not a later-window mature-preserving prefix replay.
                for (a, b) in zip(valid, coldValid) {
                    guard technicalValues(a) == technicalValues(b) else {
                        throw ProbeError.invalid("\(base.sId) 首窗 T 與完整基底不同")
                    }
                }
                for row in coldTarget {
                    try autoreleasepool { _ = try simulationValues(row) }
                }
                let stockDirectory = outputURL.appendingPathComponent(base.sId, isDirectory: true)
                try fm.createDirectory(at: stockDirectory, withIntermediateDirectories: true)
                try write(raw, to: stockDirectory.appendingPathComponent("raw-input.json"))
                let stock = Stock(sId: base.sId, sName: base.sName, group: base.group,
                    dateFirst: base.dateFirst, dateStart: start, simInvestAuto: investments, simMoneyBase: money)
                context.insert(stock)
                let outside = raw.filter { $0.date < window.requestStart }
                // Invalid raw remains stored but neither sets the batch anchor nor
                // participates in a changeSet or technical initialization.
                for point in raw where point.date < window.requestStart || !point.valid {
                    point.insert(stock: stock, in: context)
                }
                try context.save()
                let chunks = batches(raw: raw, requestStart: window.requestStart)
                var traces: [BatchTrace] = []
                for (index, chunk) in chunks.enumerated() {
                    try autoreleasepool {
                        progress("MATURITY \(stockIndex + 1)/\(stockIDs.base.count) \(stock.sId) batch=\(index + 1)/\(chunks.count) insert=\(chunk.raw.count) begin")
                        for point in chunk.raw { point.insert(stock: stock, in: context) }
                        let changes = TradeChangeSet(insertedDates: Set(chunk.raw.map(\.date)))
                        var plan = try technical.recalculationPlan(stock: stock, changes: changes)
                        plan.deferSimulation = true
                        let trace = try technical.recalculate(stock: stock, plan: plan)
                        try context.save()
                        guard trace.simulationDates.isEmpty, stock.technicalDirtyFrom == nil,
                              stock.technicalPendingWork == nil,
                              stock.technicalStateVersion == Int(Technical.technicalRuleVersion.dropFirst())!,
                              stock.simulationDirtyFrom != nil else {
                            throw ProbeError.invalid("\(stock.sId) batch \(index + 1) T-only 完成契約失敗")
                        }
                        traces.append(.init(batch: index + 1, lower: chunk.lower, upperExclusive: chunk.upperExclusive,
                            insertedDates: chunk.raw.map(\.date), ordinaryDates: trace.ordinaryTechnicalDates,
                            pricePathDates: trace.pricePathDates, simulationDates: trace.simulationDates,
                            technicalVersion: stock.technicalStateVersion, technicalDirtyFrom: stock.technicalDirtyFrom,
                            simulationDirtyFrom: stock.simulationDirtyFrom, effectiveStart: stock.effectiveSimulationStart))
                        try write(traces, to: stockDirectory.appendingPathComponent("batches.json"))
                        progress("MATURITY \(stock.sId) batch=\(index + 1)/\(chunks.count) ordinary=\(trace.ordinaryTechnicalDates.count) path=\(trace.pricePathDates.count) S=0 Tdirty=nil Sdirty=\(String(describing: stock.simulationDirtyFrom))")
                    }
                }
                guard stock.calculationWindow == window,
                      try Trade.fetch(in: context, for: stock).map(Raw.init) == raw else {
                    throw ProbeError.invalid("\(stock.sId) 分批結束後 raw／窗口不同")
                }
                progress("MATURITY \(stock.sId) final target S begin")
                let replay = try autoreleasepool {
                    try InternalPeriodReplay.replay(stock: stock, start: start, end: end,
                        money: money, investments: investments, technical: technical, in: context)
                }
                guard replay.status == .targetPeriodValid, replay.trace.technicalDates.isEmpty,
                      replay.trace.simulationDates == coldTrace.simulationDates else {
                    throw ProbeError.invalid("\(stock.sId) 最後 S 意外改寫 T 或有效期間不同")
                }
                let batchedValid = try Trade.fetchCalculationWindow(in: context, for: stock)
                guard batchedValid.map(\.dateTime) == valid.map(\.dateTime) else {
                    throw ProbeError.invalid("\(stock.sId) T 比較域不符")
                }
                var differences: [Difference] = []
                for (a, b) in zip(valid, batchedValid) {
                    differences += compare(date: a.dateTime, cold: technicalValues(a), batched: technicalValues(b))
                }
                for (a, b) in zip(coldTarget, replay.targetTrades) {
                    differences += try autoreleasepool {
                        compare(date: a.dateTime, cold: try simulationValues(a), batched: try simulationValues(b))
                    }
                }
                try write(differences, to: stockDirectory.appendingPathComponent("daily-differences.json"))
                let summaries = Dictionary(grouping: differences, by: { $0.group + ":" + $0.field }).values.map { values in
                    let first = values.min { $0.date < $1.date }!
                    return FieldSummary(group: first.group, field: first.field, changedRows: values.count,
                        firstDate: first.date, maximumAbsoluteDifference: values.compactMap { difference -> Double? in
                            guard let a = difference.cold.number, let b = difference.batched.number else { return nil }
                            return abs(a - b)
                        }.max())
                }.sorted { ($0.group, $0.field) < ($1.group, $1.field) }
                func count(_ groups: Set<String>) -> Int {
                    Set(differences.filter { groups.contains($0.group) }.map(\.date)).count
                }
                let report = StockReport(stockID: base.sId, requestStart: window.requestStart, effectiveStart: effective,
                    targetEnd: end, allRawCount: raw.count, retainedOutsideWindowCount: outside.count,
                    technicalComparisonCount: valid.count, simulationComparisonCount: coldTarget.count,
                    rawSHA256: try digest(raw), batchCount: chunks.count,
                    ordinaryChangedRows: count(["ordinary"]), pathChangedRows: count(["path"]),
                    simulationChangedRows: count(["transaction", "account", "grade", "warning", "provenance"]),
                    transactionChangedRows: count(["transaction"]), gradeChangedRows: count(["grade"]),
                    warningChangedRows: count(["warning"]), accountChangedRows: count(["account"]), fields: summaries,
                    remainingSimulationDirtyFrom: stock.simulationDirtyFrom,
                    wholeStockSimulationVersion: stock.simulationStateVersion)
                try write(report, to: stockDirectory.appendingPathComponent("comparison.json"))
                progress("MATURITY \(stock.sId) comparison ordinary=\(report.ordinaryChangedRows) path=\(report.pathChangedRows) S=\(report.simulationChangedRows) Grade=\(report.gradeChangedRows) warning=\(report.warningChangedRows) account=\(report.accountChangedRows)")
                guard report.pathChangedRows == 0 else {
                    throw ProbeError.invalid("\(stock.sId) 有界價格路徑不一致；逐日反例已保存")
                }
                return report
            }
            reports.append(report)
        }
        guard try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: technicalBaseURL) == baseDigest,
              try UpdateCycleDiagnosticIdentity.inputDigest(storeURL: coldStoreURL) == coldDigest else {
            throw ProbeError.invalid("唯讀來源雜湊改變")
        }
        let report = Report(comparisonCompleted: true, boundedPathIdentical: reports.allSatisfy { $0.pathChangedRows == 0 },
            simulationIdentical: reports.allSatisfy { $0.simulationChangedRows == 0 },
            ordinaryIdentical: reports.allSatisfy { $0.ordinaryChangedRows == 0 }, formalStrategy: false, formalBaseline: false,
            completeMeaning: "comparison artifacts complete; differences require review; not plan acceptance or strategy validation",
            ruleCommit: ruleCommit, dataRules: Technical.dataRuleVersion, marketVersion: MarketDataStore.technicalStateVersion,
            ordinaryFieldNames: ordinaryFields.map(\.0), pathFieldNames: pathFieldNames,
            validityScope: "T: all valid raw in configured W; S: first target period only; future raw and dirty retained; outside-W raw never seeds",
            technicalBaseSHA256: baseDigest, coldStoreSHA256: coldDigest, stocks: reports)
        try write(report, to: outputURL.appendingPathComponent("report.json"))
        try "comparison-artifacts-complete; not acceptance".write(to: outputURL.appendingPathComponent(".complete"), atomically: true, encoding: .utf8)
        return report
    }

    static func technicalValues(_ row: Trade) -> [String: [String: Value]] {
        let path: [Double?] = [Double(row.tPricePathPhaseRaw), row.tPricePathBarrier, row.tPricePathAnchorClose,
                              row.tPricePathExtremeClose, Double(row.tPricePathDaysSinceExtreme)]
        return ["ordinary": Dictionary(uniqueKeysWithValues: ordinaryFields.map { ($0.0, .numeric(row[keyPath: $0.1])) }),
                "path": Dictionary(uniqueKeysWithValues: zip(pathFieldNames, path).map { ($0.0, .numeric($0.1)) })]
    }

    static func simulationValues(_ row: Trade) throws -> [String: [String: Value]] {
        // Whole-stock S can legitimately remain old because raw after end is
        // still dirty. Do not use storedAnnualWarning's whole-stock UI gate.
        guard let warning = AnnualWarningPersistence.decode(row) else {
            throw ProbeError.invalid("\(row.stock.sId) \(row.dateTime) 缺少當期有效警示 payload")
        }
        var transaction = Dictionary(uniqueKeysWithValues: transactionFields.map { ($0.0, Value.numeric(row[keyPath: $0.1])) })
        transaction["simRule"] = .string(row.simRule)
        transaction["simRuleBuy"] = .string(row.simRuleBuy)
        transaction["simRuleInvest"] = .string(row.simRuleInvest)
        transaction["simReversed"] = .string(row.simReversed)
        var account = Dictionary(uniqueKeysWithValues: accountFields.map { ($0.0, Value.numeric(row[keyPath: $0.1])) })
        account["simMoneyLackedCumulative"] = .string(String(row.simMoneyLackedCumulative))
        return ["transaction": transaction, "account": account,
                "grade": ["grade": .numeric(Double(row.grade.rawValue)), "score": .numeric(row.gradeEfficiencyScore),
                          "simFitFast": .numeric(row.simFitFast), "simFitSlow": .numeric(row.simFitSlow),
                          "simFitTrend": .numeric(row.simFitTrend), "simFitTrendPhaseExtreme": .numeric(row.simFitTrendPhaseExtreme),
                          "simFitObservationCount": .numeric(Double(row.simFitObservationCount)),
                          "simFitTrendPhaseRaw": .numeric(Double(row.simFitTrendPhaseRaw))],
                "warning": ["payload": .string(String(decoding: try encoder().encode(warning), as: UTF8.self))],
                "provenance": ["marketSource": .numeric(row.simMarketSourceDate?.timeIntervalSinceReferenceDate),
                               "marketQuote": .numeric(row.simMarketQuoteTime?.timeIntervalSinceReferenceDate),
                               "marketProvisional": .string(String(row.simMarketIsProvisional)),
                               "provisionalInvestment": .numeric(row.simProvisionalEffectiveInvestment)]]
    }

    static func compare(date: Date, cold: [String: [String: Value]], batched: [String: [String: Value]]) -> [Difference] {
        var differences: [Difference] = []
        for group in Set(cold.keys).union(batched.keys).sorted() {
            for field in Set(cold[group, default: [:]].keys).union(batched[group, default: [:]].keys).sorted() {
                let a = cold[group]?[field] ?? Value()
                let b = batched[group]?[field] ?? Value()
                if a != b { differences.append(.init(date: date, group: group, field: field, cold: a, batched: b)) }
            }
        }
        return differences
    }
    private static func sameWindow(_ a: CalculationWindow, _ b: CalculationWindow) -> Bool {
        a.requestStart == b.requestStart && a.firstPriceDate == b.firstPriceDate
            && a.simulationStart == b.simulationStart && a.lastPriceDate == b.lastPriceDate
    }
    private static func container(url: URL, writable: Bool) throws -> ModelContainer {
        let schema = Schema([Stock.self, Trade.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            url: url, allowsSave: writable, cloudKitDatabase: .none)])
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder().encode(value).write(to: url, options: .atomic)
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try encoder().encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
