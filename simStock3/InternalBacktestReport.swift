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
        return .baseline
    }()
    static let isSummaryOnly = ProcessInfo.processInfo.arguments.contains("--summary-only")
    static let sample: InternalBacktestDataset.Sample =
        ProcessInfo.processInfo.arguments.contains("--sample-b") ? .b : .a
    static let isFullWindowStress =
        ProcessInfo.processInfo.arguments.contains("--full-window-stress")
    static let runID: String = {
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
        case .baseline:
            break
        }
        if sample == .b {
            return isFullWindowStress
                ? "baseline-b-s6-volume-low-veto-fullstress-600w-20260802"
                : "baseline-b-s6-volume-low-veto-fixed3y-600w-20260802"
        }
        if isFullWindowStress {
            return "baseline-s6-volume-low-veto-fullstress-600w-20260730"
        }
        return "baseline-s6-volume-low-veto-fixed3y-600w-20260730"
    }()
    static let referenceRunID: String = {
        if candidate != .baseline {
            return sample == .b
                ? "baseline-b-s6-volume-low-veto-fixed3y-600w-20260802"
                : "baseline-s6-volume-low-veto-fixed3y-600w-20260730"
        }
        if sample == .b {
            return isFullWindowStress
                ? "baseline-s6-volume-low-veto-fullstress-600w-20260730"
                : "baseline-s6-volume-low-veto-fixed3y-600w-20260730"
        }
        if isFullWindowStress {
            return "baseline-s5-volume-hold-fullstress-600w-20260730"
        }
        return "baseline-s5-volume-hold-fixed3y-600w-20260730"
    }()
    static let reportTitle: String = {
        if sample == .b {
            return isFullWindowStress
                ? "Sample B · S6 2019–2026 全程壓力測試"
                : "Sample B · S6 固定三年 Baseline"
        }
        if isFullWindowStress {
            return "S6 H 九日最低量否決 2019–2026 全程壓力測試"
        }
        return "S6 H 九日最低量否決固定三年 Baseline"
    }()
    static let moneyBaseWan = 600.0
    static let automaticInvestments = 2.0
    static let currentRuleVersion: String = {
        switch candidate {
        case .baseline: return "s6-hn10-volume-low-veto-20260730"
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

        let excluded = allStocks.filter { $0.status == "無成交，不計分" }.count
        let manifest = Manifest(
            sampleID: sample.rawValue,
            runID: runID,
            createdAt: createdAt,
            inputStore: "\(sample.baselineDirectoryName)/baseline.store",
            browseStore: "browse.store",
            reportFiles: isSummaryOnly
                ? ["baseline.json", "periods.csv", "manifest.json"]
                : ["report.html", "baseline.json", "periods.csv", "manifest.json"],
            dataRuleVersion: Technical.dataRuleVersion,
            ruleVersion: currentRuleVersion,
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
                reference: loadReferenceBaseline(from: documents)
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
            tradeCount: totalTrades
        )
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

    private static func html(_ report: Baseline, reference: Baseline?) -> String {
        let firstGroup = groupNames[0]
        let secondGroup = groupNames[1]
        let h = report.groups.first { $0.group == firstGroup }
        let l = report.groups.first { $0.group == secondGroup }
        let referenceH = reference?.groups.first { $0.group == "H" }
        let referenceL = reference?.groups.first { $0.group == "L" }
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
                $0.group == "H" && $0.periodStart == hp.periodStart
            }
            let referenceLP = reference?.periods.first {
                $0.group == "L" && $0.periodStart == hp.periodStart
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
        \(crossSampleInterpretationSection)
        <section class="cards"><article class="card primary"><div class="label">兩股群主分數</div><div class="value">\(number(report.combinedScore))</div><div>參考 \(number(reference?.combinedScore)) · 差異 \(delta(report.combinedScore, reference?.combinedScore))</div></article><article class="card"><div class="label">\(firstGroup)</div><div class="value h">\(number(h?.mainScore))</div><div class="muted">參考 \(number(referenceH?.mainScore)) · 差異 \(delta(h?.mainScore, referenceH?.mainScore))</div></article><article class="card"><div class="label">\(secondGroup)</div><div class="value l">\(number(l?.mainScore))</div><div class="muted">參考 \(number(referenceL?.mainScore)) · 差異 \(delta(l?.mainScore, referenceL?.mainScore))</div></article><article class="card"><div class="label">資料品質</div><div class="value">100%</div><div class="muted">無 0、Inf 或 NaN</div></article></section>
        <section class="panel"><div class="head"><h2>本次回測設定</h2></div><div class="meta"><div><span>歷史資料</span>2018/01/02–\(report.through)</div><div><span>\(isFullWindowStress ? "全程窗口" : "固定三年窗口")</span>\(windowDescriptions)</div><div><span>本金／加碼</span>600 萬／2 次</div><div><span>資料／策略規則</span>\(report.dataRuleVersion ?? "未記錄")<br>\(report.ruleVersion)</div></div><p class="note">\(isFullWindowStress ? "全程壓力測試只使用 2019 起始至資料截止日的一個窗口，不納入固定三年主分。" : "三個主期間各自只模擬三年；最後一段由資料截止日倒推三年，因此可與前一段部分重疊。少於六個有效期間時不去除最佳期。")</p></section>
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
        let referenceH = reference.groups.first { $0.group == "H" }
        let referenceL = reference.groups.first { $0.group == "L" }
        let periodDeltas = report.periods.compactMap { period -> Double? in
            guard period.group == firstGroup,
                  let currentH = period.score,
                  let currentL = report.periods.first(where: {
                      $0.group == secondGroup && $0.periodStart == period.periodStart
                  })?.score,
                  let oldH = reference.periods.first(where: {
                      $0.group == "H" && $0.periodStart == period.periodStart
                  })?.score,
                  let oldL = reference.periods.first(where: {
                      $0.group == "L" && $0.periodStart == period.periodStart
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
        let comparisonMeaning = sample == .b
            ? "兩者股票不同，差異只表示樣本敏感度，不視為規則改善或退步。"
            : "兩者輸入樣本相同，正負差異可用來判讀規則版本變化。"
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
                ? "與 Baseline A 的全期間比較"
                : "與 Baseline A 的各窗口比較"
        }
        return isFullWindowStress
            ? "上一版 Baseline 與新版全期間比較"
            : "上一版 Baseline 與新版各期間比較"
    }

    private static var crossSampleInterpretationSection: String {
        guard sample == .b else { return "" }
        return """
        <section class="panel"><div class="head"><h2>與 Baseline A 的比較解讀</h2></div><div class="opinion">Baseline B 的分數明顯低於 A，代表策略績效會隨股票不同而變化，不表示 S6 規則本身退步。依<a href="../../../doc/選股評等.md">選股評等</a>的用途，策略規則應盡量讓適合本策略的股票透過較佳實年報酬率與較短持股週期累積為 <strong>wow</strong>，並把低效率股票辨識至 <strong>weak</strong> 以下；S 賣出規則是形成這種績效與週期差異的關鍵環節之一。Sample B 是用來檢查這項分辨力的代表性驗證樣本，不是實際推薦買進清單；真要納入等候買賣的股群，仍須確認三年紅星、兩年仍為紅星及近半年走勢。</div></section>
        """
    }

    private static var comparisonNote: String {
        sample == .b
            ? "Sample A、B 使用相同規則與窗口但股票不同；差異用於觀察樣本敏感度，不代表規則改善或退步。"
            : "正值代表新版改善，負值代表退步。"
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
