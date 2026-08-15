import Foundation
import SwiftData

#if DEBUG
@MainActor
enum InternalBacktestDataset {
    enum DatasetError: LocalizedError {
        case sampleCNotConfigured

        var errorDescription: String? {
            switch self {
            case .sampleCNotConfigured:
                return "Sample C 暫定名單已撤回；完成 FT4 重組與鎖定前不得建立資料集。"
            }
        }
    }

    enum Sample: String, Sendable {
        case a = "A"
        case b = "B"
        case c = "C"

        static func from(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
            if arguments.contains("--sample-c") { return .c }
            if arguments.contains("--sample-b") { return .b }
            return .a
        }

        var baselineDirectoryName: String {
            switch self {
            case .a: "2019-01-02-baseline"
            case .b: "sample-b-2019-01-02-baseline"
            case .c: "sample-c-2019-01-02-baseline"
            }
        }

        var browseDirectoryName: String {
            switch self {
            case .a: "2019-01-02-browse"
            case .b: "sample-b-2019-01-02-browse"
            case .c: "sample-c-2019-01-02-browse"
            }
        }

        var members: [Member] {
            switch self {
            case .a: InternalBacktestDataset.sampleAMembers
            case .b: InternalBacktestDataset.sampleBMembers
            case .c: InternalBacktestDataset.sampleCMembers
            }
        }
    }

    struct Member: Sendable {
        let id: String
        let name: String
        let group: String
    }

    struct StockSummary: Codable {
        let id: String
        let name: String
        let group: String
        let firstTrade: String
        let lastTrade: String
        let tradeCount: Int
        let technicalCount: Int
        let simulationCount: Int
        let invalidPriceCount: Int
        let invalidTechnicalCount: Int
        let invalidSimulationCount: Int
        let finalRollRoi: Double
        let finalAverageDays: Double
        let finalGrade: String
        let moneyLacked: Bool
    }

    struct Manifest: Codable {
        let sampleID: String
        let createdAt: String
        let historyStart: String
        let simulationStart: String
        let through: String
        let moneyBaseWan: Double
        let automaticInvestments: Double
        let requestedMonthCount: Int
        let failedRequests: [String]
        let stocks: [StockSummary]
    }

    struct Result {
        let storeURL: URL
        let manifestURL: URL
        let manifest: Manifest
    }

    private static let sampleAMembers: [Member] = [
        Member(id: "2449", name: "京元電子", group: "H"),
        Member(id: "3653", name: "健策", group: "H"),
        Member(id: "2368", name: "金像電", group: "H"),
        Member(id: "8996", name: "高力", group: "H"),
        Member(id: "3017", name: "奇鋐", group: "H"),
        Member(id: "2201", name: "裕隆", group: "L"),
        Member(id: "1216", name: "統一", group: "L"),
        Member(id: "8454", name: "富邦媒", group: "L"),
        Member(id: "1301", name: "台塑", group: "L"),
        Member(id: "2317", name: "鴻海", group: "L")
    ]

    private static let sampleBMembers: [Member] = [
        Member(id: "2330", name: "台積電", group: "第 1 股群"),
        Member(id: "2308", name: "台達電", group: "第 1 股群"),
        Member(id: "2382", name: "廣達", group: "第 1 股群"),
        Member(id: "1590", name: "亞德客-KY", group: "第 1 股群"),
        Member(id: "2882", name: "國泰金", group: "第 1 股群"),
        Member(id: "1101", name: "台泥", group: "第 2 股群"),
        Member(id: "2002", name: "中鋼", group: "第 2 股群"),
        Member(id: "2912", name: "統一超", group: "第 2 股群"),
        Member(id: "3045", name: "台灣大", group: "第 2 股群"),
        Member(id: "1477", name: "聚陽", group: "第 2 股群")
    ]

    // FT0: the first industry-only proposal was withdrawn before candidate
    // generation. FT4 must populate and lock the replacement before C runs.
    private static let sampleCMembers: [Member] = []

    static let members = Sample.a.members

    static let historyStart = requiredDate("2018/01/02")
    static let simulationStart = requiredDate("2019/01/02")
    static let snapshotThrough = requiredDate("2026/07/22")
    static let moneyBaseWan = 600.0
    static let automaticInvestments = 2.0

    private static func requiredDate(_ text: String) -> Date {
        guard let date = twDateTime.dateFromString(text) else {
            preconditionFailure("Invalid internal backtest date: \(text)")
        }
        return date
    }

    private static func months(from firstDate: Date, through lastDate: Date) -> [Date] {
        var result: [Date] = []
        var month = twDateTime.startOfMonth(firstDate)
        let lastMonth = twDateTime.startOfMonth(lastDate)
        while month <= lastMonth {
            result.append(month)
            guard let next = twDateTime.calendar.date(byAdding: .month, value: 1, to: month) else {
                break
            }
            month = twDateTime.startOfMonth(next)
        }
        return result
    }

    private static func finite(_ values: [Double]) -> Bool {
        values.allSatisfy(\.isFinite)
    }

    static func prepare(
        in directoryURL: URL,
        reset: Bool,
        sample: Sample = .a,
        through endDate: Date,
        requestDelay: Duration = .milliseconds(750),
        progress: (String) -> Void = { _ in }
    ) async throws -> Result {
        guard !sample.members.isEmpty else {
            throw DatasetError.sampleCNotConfigured
        }
        let fileManager = FileManager.default
        if reset, fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let storeURL = directoryURL.appendingPathComponent("baseline.store")
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalBacktestBaseline",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let technical = Technical(modelContext: context)

        let configuredIDs = Set(sample.members.map(\.id))
        for stock in try Stock.fetchAll(in: context) where !configuredIDs.contains(stock.sId) {
            context.delete(stock)
        }
        try context.save()

        var stocks: [Stock] = []
        for member in sample.members {
            let stock = try Stock.ensureStock(
                in: context,
                sId: member.id,
                sName: member.name,
                group: member.group,
                dateFirst: historyStart,
                dateStart: simulationStart,
                simMoneyBase: moneyBaseWan,
                simInvestAuto: automaticInvestments
            )
            stock.group = member.group
            stock.dateFirst = historyStart
            stock.dateStart = simulationStart
            stock.simMoneyBase = moneyBaseWan
            stock.simInvestAuto = automaticInvestments
            stocks.append(stock)
        }
        try context.save()

        let requestedMonths = months(from: historyStart, through: endDate)
        var failedRequests: [String] = []
        technical.countTWSE = stocks.count

        for (stockIndex, stock) in stocks.enumerated() {
            technical.progressTWSE = stockIndex + 1
            let existingTrades = try Trade.fetch(
                in: context,
                for: stock,
                TWSE: true,
                ascending: true
            )
            let completedHistoricalMonths = Set(
                existingTrades.map { twDateTime.startOfMonth($0.dateTime) }
            )
            let currentMonth = twDateTime.startOfMonth(endDate)
            for (monthIndex, month) in requestedMonths.enumerated() {
                let monthText = twDateTime.stringFromDate(month, format: "yyyy/MM")
                if month < currentMonth, completedHistoricalMonths.contains(month) {
                    continue
                }
                progress("\(stockIndex + 1)/\(stocks.count) \(stock.sId) \(stock.sName) \(monthIndex + 1)/\(requestedMonths.count) \(monthText)")

                let succeeded = await technical.twseRequestAsync(
                    stock: stock,
                    dateStart: month,
                    recalculate: false
                )
                if !succeeded {
                    failedRequests.append("\(stock.sId) \(monthText)")
                }
                try await Task.sleep(for: requestDelay)
            }

            let downloadedTrades = try Trade.fetch(
                in: context,
                for: stock,
                TWSE: true,
                ascending: true
            )
            for trade in downloadedTrades where trade.dateTime > endDate {
                context.delete(trade)
            }
            try context.save()

            progress("\(stock.sId) 開始完整 tUpdate／simUpdate")
            _ = try technical.recalculate(
                stock: stock,
                plan: RecalculationPlan(
                    technical: .all,
                    simulation: .all,
                    resetPolicy: .clearUserActions,
                    resetDerivedSimulationState: true
                )
            )
        }
        technical.progressTWSE = nil
        technical.countTWSE = nil
        try context.save()

        var summaries: [StockSummary] = []
        for stock in stocks {
            let trades = try Trade.fetch(in: context, for: stock, ascending: true)
            let simulationTrades = trades.filter { $0.dateTime >= simulationStart && $0.dateTime <= endDate }
            let invalidPriceCount = trades.filter {
                !finite([$0.priceOpen, $0.priceHigh, $0.priceLow, $0.priceClose, $0.volumeClose])
                    || $0.priceOpen <= 0 || $0.priceHigh <= 0 || $0.priceLow <= 0 || $0.priceClose <= 0
            }.count
            let invalidTechnicalCount = trades.filter {
                !finite([
                    $0.tMa20, $0.tMa60, $0.tKdK, $0.tKdD, $0.tKdJ, $0.tOsc,
                    $0.tZ125, $0.tZ250, $0.vZ125, $0.vZ250
                ])
            }.count
            let invalidSimulationCount = simulationTrades.filter {
                !finite([
                    $0.rollAmtCost, $0.rollAmtProfit, $0.rollAmtRoi, $0.rollDays,
                    $0.simAmtBalance, $0.simAmtCost, $0.simAmtProfit, $0.simAmtRoi,
                    $0.simDays, $0.simUnitCost, $0.simUnitRoi
                ])
            }.count
            let finalTrade = simulationTrades.last

            summaries.append(
                StockSummary(
                    id: stock.sId,
                    name: stock.sName,
                    group: stock.group,
                    firstTrade: trades.first.map { twDateTime.stringFromDate($0.dateTime) } ?? "",
                    lastTrade: trades.last.map { twDateTime.stringFromDate($0.dateTime) } ?? "",
                    tradeCount: trades.count,
                    technicalCount: trades.filter(\.tUpdated).count,
                    simulationCount: simulationTrades.count,
                    invalidPriceCount: invalidPriceCount,
                    invalidTechnicalCount: invalidTechnicalCount,
                    invalidSimulationCount: invalidSimulationCount,
                    finalRollRoi: finalTrade?.rollAmtRoi ?? 0,
                    finalAverageDays: finalTrade?.days ?? 0,
                    finalGrade: finalTrade.map { gradeText($0.grade) } ?? "none",
                    moneyLacked: stock.simMoneyLacked
                )
            )
        }

        let manifest = Manifest(
            sampleID: sample.rawValue,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            historyStart: twDateTime.stringFromDate(historyStart),
            simulationStart: twDateTime.stringFromDate(simulationStart),
            through: twDateTime.stringFromDate(endDate),
            moneyBaseWan: moneyBaseWan,
            automaticInvestments: automaticInvestments,
            requestedMonthCount: requestedMonths.count * stocks.count,
            failedRequests: failedRequests,
            stocks: summaries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return Result(storeURL: storeURL, manifestURL: manifestURL, manifest: manifest)
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
}
#endif
