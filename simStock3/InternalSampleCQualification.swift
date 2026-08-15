import Foundation
import SwiftData

#if DEBUG
@MainActor
enum InternalSampleCQualification {
    static let recentWindowStart = requiredDate("2023/07/22")

    struct Observation: Sendable {
        let date: Date
        let close: Double
        let grade: Trade.Grade
        let roi: Double
        let days: Double
        let rounds: Double
    }

    struct StockResult: Codable, Sendable {
        let id: String
        let name: String
        let observationCount: Int
        let firstObservation: String
        let lastObservation: String
        let terminalGrade: String
        let firstWowDate: String?
        let maximumDrawdownPercent: Double?
        let maximumDrawdownPeakDate: String?
        let maximumDrawdownTroughDate: String?
        let qualifyingPeakDate: String?
        let qualifyingTroughDate: String?
        let qualifyingPeakClose: Double?
        let qualifyingTroughClose: Double?
        let qualifyingDrawdownPercent: Double?
        let qualifyingObservationGap: Int?
        let followThroughEndDate: String?
        let qualified: Bool
        let reasons: [String]
        let moneyLacked: Bool
    }

    struct Manifest: Codable, Sendable {
        let formatVersion: Int
        let phase: String
        let evaluationID: String
        let sampleID: String
        let createdAt: String
        let dataRuleVersion: String
        let ruleVersion: String
        let periodStart: String
        let periodEnd: String
        let moneyBaseWan: Double
        let automaticInvestments: Double
        let criteria: [String]
        let qualifiedCount: Int
        let stocks: [StockResult]
    }

    struct Result: Sendable {
        let directoryURL: URL
        let storeURL: URL
        let manifestURL: URL
        let manifest: Manifest
    }

    enum QualificationError: LocalizedError {
        case missingInput(URL)
        case missingStocks
        case invalidValues(String)

        var errorDescription: String? {
            switch self {
            case .missingInput(let url): "找不到研究池基底：\(url.path)"
            case .missingStocks: "研究池基底沒有股票。"
            case .invalidValues(let detail): "最近窗口包含無效資料：\(detail)"
            }
        }
    }

    static func run(
        configuration: InternalBacktestDataset.EvaluationConfiguration,
        documents: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> Result {
        let fm = FileManager.default
        let evaluationURL = documents
            .appendingPathComponent("InternalBacktest/SampleCEvaluations", isDirectory: true)
            .appendingPathComponent(configuration.directoryName, isDirectory: true)
        let inputURL = evaluationURL.appendingPathComponent("baseline.store")
        guard fm.fileExists(atPath: inputURL.path) else {
            throw QualificationError.missingInput(inputURL)
        }

        let outputURL = evaluationURL.appendingPathComponent(
            configuration.qualificationID,
            isDirectory: true
        )
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let storeURL = outputURL.appendingPathComponent("recent-window.store")
        try copyStore(from: inputURL, to: storeURL)

        let schema = Schema([Stock.self, Trade.self])
        let modelConfiguration = ModelConfiguration(
            "SampleCQualification",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [modelConfiguration]
        )
        let context = container.mainContext
        let technical = Technical(modelContext: context)
        let stocks = try Stock.fetchAll(in: context).sorted { $0.sId < $1.sId }
        guard !stocks.isEmpty else { throw QualificationError.missingStocks }

        var results: [StockResult] = []
        var csv = ["stock_id,stock_name,date,close,daily_return_percent,grade,roi,average_days,rounds"]
        for (index, stock) in stocks.enumerated() {
            progress("\(index + 1)/\(stocks.count) \(stock.sId) \(stock.sName) 最近窗口重播")
            stock.dateStart = recentWindowStart
            stock.simMoneyBase = InternalBacktestDataset.moneyBaseWan
            stock.simInvestAuto = InternalBacktestDataset.automaticInvestments
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
                    simulationEnd: InternalBacktestDataset.snapshotThrough
                )
            )

            let trades = try Trade.fetch(in: context, for: stock, ascending: true)
                .filter {
                    $0.dateTime >= recentWindowStart
                        && $0.dateTime <= InternalBacktestDataset.snapshotThrough
                }
            let observations = try trades.map { trade -> Observation in
                let values = [
                    trade.priceClose, trade.roi, trade.days, trade.rollRounds
                ]
                guard trade.priceClose > 0, values.allSatisfy(\.isFinite) else {
                    throw QualificationError.invalidValues(
                        "\(stock.sId) \(dateText(trade.dateTime))"
                    )
                }
                return Observation(
                    date: trade.dateTime,
                    close: trade.priceClose,
                    grade: trade.grade,
                    roi: trade.roi,
                    days: trade.days,
                    rounds: trade.rollRounds
                )
            }
            guard !observations.isEmpty else {
                throw QualificationError.invalidValues("\(stock.sId) 沒有最近窗口資料")
            }

            for observationIndex in observations.indices {
                let row = observations[observationIndex]
                let dailyReturn = observationIndex > 0
                    ? (row.close / observations[observationIndex - 1].close - 1) * 100
                    : nil
                csv.append([
                    stock.sId,
                    csvEscape(stock.sName),
                    dateText(row.date),
                    decimal(row.close),
                    dailyReturn.map(decimal) ?? "",
                    gradeText(row.grade),
                    decimal(row.roi),
                    decimal(row.days),
                    decimal(row.rounds)
                ].joined(separator: ","))
            }
            results.append(evaluate(
                id: stock.sId,
                name: stock.sName,
                observations: observations,
                moneyLacked: stock.simMoneyLacked
            ))
        }
        try context.save()

        let manifest = Manifest(
            formatVersion: 1,
            phase: displayPhase(configuration.qualificationID),
            evaluationID: configuration.id,
            sampleID: "C-EVAL-\(configuration.id)",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            dataRuleVersion: Technical.dataRuleVersion,
            ruleVersion: InternalBacktestReport.baselineRuleVersion,
            periodStart: dateText(recentWindowStart),
            periodEnd: dateText(InternalBacktestDataset.snapshotThrough),
            moneyBaseWan: InternalBacktestDataset.moneyBaseWan,
            automaticInvestments: InternalBacktestDataset.automaticInvestments,
            criteria: [
                "recent-window terminal Grade is wow",
                "after first wow, close drawdown from prior peak is at least 20%",
                "peak to trough spans at least 10 formal observations",
                "peak through trough contains no daily close return below -12%",
                "Grade remains wow from peak through 20 observations after trough"
            ],
            qualifiedCount: results.filter(\.qualified).count,
            stocks: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = outputURL.appendingPathComponent("qualification.json")
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try csv.joined(separator: "\n").appending("\n").write(
            to: outputURL.appendingPathComponent("observations.csv"),
            atomically: true,
            encoding: .utf8
        )
        return Result(
            directoryURL: outputURL,
            storeURL: storeURL,
            manifestURL: manifestURL,
            manifest: manifest
        )
    }

    static func evaluate(
        id: String,
        name: String,
        observations: [Observation],
        moneyLacked: Bool
    ) -> StockResult {
        precondition(!observations.isEmpty)
        let firstWow = observations.firstIndex { $0.grade == .wow }
        var maximum: (peak: Int, trough: Int, drawdown: Double)?
        var qualifying: (peak: Int, trough: Int, end: Int, drawdown: Double)?

        if let firstWow {
            for peak in firstWow..<observations.count {
                let firstTrough = peak + 10
                guard firstTrough < observations.count else { continue }
                for trough in firstTrough..<observations.count {
                    let drawdown = observations[trough].close / observations[peak].close - 1
                    if maximum == nil || drawdown < maximum!.drawdown {
                        maximum = (peak, trough, drawdown)
                    }
                    guard drawdown <= -0.20, trough + 20 < observations.count else { continue }
                    let hasJump = ((peak + 1)...trough).contains { index in
                        observations[index].close / observations[index - 1].close - 1 < -0.12
                    }
                    let followThroughEnd = trough + 20
                    let stayedWow = observations[peak...followThroughEnd]
                        .allSatisfy { $0.grade == .wow }
                    guard !hasJump, stayedWow else { continue }
                    if qualifying == nil || drawdown < qualifying!.drawdown {
                        qualifying = (peak, trough, followThroughEnd, drawdown)
                    }
                }
            }
        }

        var reasons: [String] = []
        if observations.last?.grade != .wow { reasons.append("期末 Grade 不是 wow") }
        if firstWow == nil { reasons.append("最近窗口從未成為 wow") }
        if firstWow != nil, qualifying == nil {
            reasons.append("沒有同時通過回撤、間隔、跳點與 wow 持續性的區段")
        }
        if moneyLacked { reasons.append("最近窗口曾發生本金不足") }
        let qualified = observations.last?.grade == .wow
            && qualifying != nil
            && !moneyLacked
        let selected = qualifying

        return StockResult(
            id: id,
            name: name,
            observationCount: observations.count,
            firstObservation: dateText(observations[0].date),
            lastObservation: dateText(observations[observations.count - 1].date),
            terminalGrade: gradeText(observations[observations.count - 1].grade),
            firstWowDate: firstWow.map { dateText(observations[$0].date) },
            maximumDrawdownPercent: maximum.map { $0.drawdown * 100 },
            maximumDrawdownPeakDate: maximum.map { dateText(observations[$0.peak].date) },
            maximumDrawdownTroughDate: maximum.map { dateText(observations[$0.trough].date) },
            qualifyingPeakDate: selected.map { dateText(observations[$0.peak].date) },
            qualifyingTroughDate: selected.map { dateText(observations[$0.trough].date) },
            qualifyingPeakClose: selected.map { observations[$0.peak].close },
            qualifyingTroughClose: selected.map { observations[$0.trough].close },
            qualifyingDrawdownPercent: selected.map { $0.drawdown * 100 },
            qualifyingObservationGap: selected.map { $0.trough - $0.peak },
            followThroughEndDate: selected.map { dateText(observations[$0.end].date) },
            qualified: qualified,
            reasons: reasons,
            moneyLacked: moneyLacked
        )
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

    private static func requiredDate(_ text: String) -> Date {
        guard let date = twDateTime.dateFromString(text) else {
            preconditionFailure("Invalid Sample C qualification date: \(text)")
        }
        return date
    }

    private static func dateText(_ date: Date) -> String {
        twDateTime.stringFromDate(date)
    }

    private static func displayPhase(_ id: String) -> String {
        id.replacingOccurrences(of: "ft4b-", with: "FT4b-")
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

    private static func decimal(_ value: Double) -> String {
        String(format: "%.8f", value)
    }

    private static func csvEscape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
#endif
