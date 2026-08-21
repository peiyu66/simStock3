import Foundation
import SwiftData

#if DEBUG
@MainActor
enum InternalBacktestDataset {
    enum DatasetError: LocalizedError {
        case sampleCNotConfigured
        case sampleCLockedUntilFinalValidation
        case invalidEvaluationConfiguration(String)
        case missingPoolSource(String)
        case poolAlreadyExists(String)
        case missingPoolStock(String)
        case duplicatePoolStock(String)
        case poolCopyMismatch(String)
        case missingABPool(String)
        case completeABPoolAlreadyExists(String)
        case invalidABPool(String)

        var errorDescription: String? {
            switch self {
            case .sampleCNotConfigured:
                return "Sample C 暫定名單已撤回；完成 FT4 重組與鎖定前不得建立資料集。"
            case .sampleCLockedUntilFinalValidation:
                return "Sample C 已鎖定；候選完全凍結並進入 FT7 前不得建立或重播。"
            case .invalidEvaluationConfiguration(let detail):
                return "Sample C 研究池設定無效：\(detail)"
            case .missingPoolSource(let path):
                return "找不到資料池搬移來源：\(path)"
            case .poolAlreadyExists(let path):
                return "集中資料池已存在，為避免覆蓋而停止：\(path)"
            case .missingPoolStock(let id):
                return "資料池搬移來源缺少股票：\(id)"
            case .duplicatePoolStock(let id):
                return "資料池搬移來源重複包含股票：\(id)"
            case .poolCopyMismatch(let detail):
                return "資料池搬移核對失敗：\(detail)"
            case .missingABPool(let path):
                return "找不到待補齊的 A／B 資料池：\(path)"
            case .completeABPoolAlreadyExists(let path):
                return "完整 A／B 資料池已存在，為避免覆蓋而停止：\(path)"
            case .invalidABPool(let detail):
                return "A／B 資料池品質檢查失敗：\(detail)"
            }
        }
    }

    enum Sample: String, Sendable {
        case a = "A"
        case b = "B"
        case c = "C"
        case d = "D"

        static func from(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
            if arguments.contains("--sample-d") { return .d }
            if arguments.contains("--sample-c") { return .c }
            if arguments.contains("--sample-b") { return .b }
            return .a
        }

        var baselineDirectoryName: String {
            switch self {
            case .a: "2019-01-02-baseline"
            case .b: "sample-b-2019-01-02-baseline"
            case .c: "sample-c-2019-01-02-baseline"
            case .d: "sample-d-2019-01-02-baseline"
            }
        }

        var browseDirectoryName: String {
            switch self {
            case .a: "2019-01-02-browse"
            case .b: "sample-b-2019-01-02-browse"
            case .c: "sample-c-2019-01-02-browse"
            case .d: "sample-d-2019-01-02-browse"
            }
        }

        var nineYearBaselineDirectoryName: String {
            switch self {
            case .a: "sample-a-2017-07-22-t2-baseline-v2"
            case .b: "sample-b-2017-07-22-t2-baseline-v2"
            case .c: "sample-c-2017-07-22-t2-baseline-v2"
            case .d: "sample-d-2017-07-22-t2-baseline-v2"
            }
        }

        var members: [Member] {
            switch self {
            case .a: InternalBacktestDataset.sampleAMembers
            case .b: InternalBacktestDataset.sampleBMembers
            case .c: InternalBacktestDataset.sampleCMembers
            case .d: InternalBacktestDataset.sampleDMembers
            }
        }
    }

    struct Member: Sendable {
        let id: String
        let name: String
        let group: String
    }

    static let documentationScreenshotMembers: [Member] = [
        .init(id: "2449", name: "京元電子", group: "股群_1"),
        .init(id: "3231", name: "緯創", group: "股群_1"),
        .init(id: "1101", name: "台泥", group: "股群_1"),
        .init(id: "2882", name: "國泰金", group: "股群_1"),
        .init(id: "2634", name: "漢翔", group: "股群_1"),
        .init(id: "9910", name: "豐泰", group: "股群_1"),
        .init(id: "2317", name: "鴻海", group: "股群_1"),
        .init(id: "1477", name: "聚陽", group: "股群_1")
    ]

    struct EvaluationConfiguration: Sendable {
        let id: String
        let members: [Member]

        var directoryName: String {
            "sample-c-evaluation-\(id)"
        }

        var qualificationID: String {
            guard id.hasSuffix("a") else { return "\(id)-qualification" }
            return String(id.dropLast()) + "b"
        }
    }

    private struct EvaluationMemberPayload: Decodable {
        let id: String
        let name: String
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

    struct PoolSource: Sendable {
        let sample: Sample
        let storeURL: URL
        let members: [Member]
    }

    struct PoolSourceSummary: Codable, Sendable {
        let sampleID: String
        let storePath: String
        let stockIDs: [String]
    }

    struct PoolStockSummary: Codable, Sendable {
        let id: String
        let name: String
        let firstTrade: String
        let lastTrade: String
        let tradeCount: Int
        let technicalCount: Int
    }

    struct PoolManifest: Codable, Sendable {
        let poolID: String
        let createdAt: String
        let historyTargetStart: String
        let simulationTargetStart: String
        let through: String
        let technicalRuleVersion: String
        let simulationStateCopied: Bool
        let coverageStatus: String
        let sources: [PoolSourceSummary]
        let stocks: [PoolStockSummary]
    }

    struct PoolResult: Sendable {
        let storeURL: URL
        let manifestURL: URL
        let manifest: PoolManifest
    }

    struct PoolBackfillResult {
        let completed: Bool
        let directoryURL: URL
        let storeURL: URL
        let manifestURL: URL?
        let failedRequests: [String]
    }

    struct FortyStockSummary: Codable, Sendable {
        let id: String
        let name: String
        let role: String
        var status: String
        var firstTrade: String
        var lastTrade: String
        var tradeCount: Int
        var technicalCount: Int
        var simulationCount: Int? = nil
        var completedMonths: [String]
        var listingDate: String? = nil
    }

    struct FortyStockDownloadPolicy: Codable, Sendable {
        let initialDelaySeconds: Double
        let fallbackDelaySeconds: Double
        let retryDelaySeconds: [Double]
        let maximumRequestsPerBatch: Int
    }

    struct FortyStockManifest: Codable, Sendable {
        var poolID: String
        let createdAt: String
        var updatedAt: String
        let sourcePoolID: String
        let historyTargetStart: String
        let simulationTargetStart: String
        let through: String
        let technicalRuleVersion: String
        var dataRuleVersion: String? = nil
        var simulationMoneyBase: Double? = nil
        var simulationInvestAuto: Double? = nil
        let simulationStateCopied: Bool
        var coverageStatus: String
        let targetMonthCount: Int
        var completedStockCount: Int
        var pendingStockIDs: [String]
        let downloadPolicy: FortyStockDownloadPolicy
        var stocks: [FortyStockSummary]
    }

    struct FortyStockResult: Sendable {
        let directoryURL: URL
        let storeURL: URL
        let manifestURL: URL
        let manifest: FortyStockManifest
    }

    struct FortyStockBackfillResult: Sendable {
        let completed: Bool
        let attemptedRequests: Int
        let failedRequests: [String]
        let pendingMonthCount: Int
        let manifest: FortyStockManifest
    }

    struct TWSEDiagnosticResult: Sendable {
        let stockID: String
        let month: String
        let technicalSucceeded: Bool
        let httpStatus: Int?
        let mimeType: String?
        let byteCount: Int
        let responsePrefix: String
        let transportError: String?
    }

    private static let sampleAMembers: [Member] = [
        Member(id: "2368", name: "金像電", group: "較強股群"),
        Member(id: "3533", name: "嘉澤", group: "較強股群"),
        Member(id: "8046", name: "南電", group: "較強股群"),
        Member(id: "2308", name: "台達電", group: "較強股群"),
        Member(id: "3231", name: "緯創", group: "較強股群"),
        Member(id: "9910", name: "豐泰", group: "較弱股群"),
        Member(id: "2882", name: "國泰金", group: "較弱股群"),
        Member(id: "2634", name: "漢翔", group: "較弱股群"),
        Member(id: "8454", name: "富邦媒", group: "較弱股群"),
        Member(id: "1101", name: "台泥", group: "較弱股群")
    ]

    private static let sampleBMembers: [Member] = [
        Member(id: "3653", name: "健策", group: "較強股群"),
        Member(id: "1519", name: "華城", group: "較強股群"),
        Member(id: "3037", name: "欣興", group: "較強股群"),
        Member(id: "2454", name: "聯發科", group: "較強股群"),
        Member(id: "2303", name: "聯電", group: "較強股群"),
        Member(id: "1477", name: "聚陽", group: "較弱股群"),
        Member(id: "2317", name: "鴻海", group: "較弱股群"),
        Member(id: "1907", name: "永豐餘", group: "較弱股群"),
        Member(id: "2912", name: "統一超", group: "較弱股群"),
        Member(id: "2642", name: "宅配通", group: "較弱股群")
    ]

    private static let sampleCMembers: [Member] = [
        Member(id: "3017", name: "奇鋐", group: "較強股群"),
        Member(id: "3661", name: "世芯-KY", group: "較強股群"),
        Member(id: "8210", name: "勤誠", group: "較強股群"),
        Member(id: "2330", name: "台積電", group: "較強股群"),
        Member(id: "2382", name: "廣達", group: "較弱股群"),
        Member(id: "8499", name: "鼎炫-KY", group: "較弱股群"),
        Member(id: "2816", name: "旺旺保", group: "較弱股群"),
        Member(id: "1216", name: "統一", group: "較弱股群"),
        Member(id: "2911", name: "麗嬰房", group: "較弱股群"),
        Member(id: "2002", name: "中鋼", group: "較弱股群")
    ]

    private static let sampleDMembers: [Member] = [
        Member(id: "2345", name: "智邦", group: "較強股群"),
        Member(id: "8996", name: "高力", group: "較強股群"),
        Member(id: "2449", name: "京元電子", group: "較強股群"),
        Member(id: "1590", name: "亞德客-KY", group: "較強股群"),
        Member(id: "6142", name: "友勁", group: "較弱股群"),
        Member(id: "3593", name: "力銘", group: "較弱股群"),
        Member(id: "2028", name: "威致", group: "較弱股群"),
        Member(id: "2201", name: "裕隆", group: "較弱股群"),
        Member(id: "3045", name: "台灣大", group: "較弱股群"),
        Member(id: "1201", name: "味全", group: "較弱股群")
    ]

    // Keep the original FT4 pool candidates independent from the current
    // A/B/C/D sample assignment so regrouping never changes the central pool.
    private static let poolCandidateMembers: [Member] = [
        Member(id: "4562", name: "穎漢", group: "未分組候選"),
        Member(id: "3593", name: "力銘", group: "未分組候選"),
        Member(id: "8473", name: "山林水", group: "未分組候選"),
        Member(id: "8422", name: "可寧衛*", group: "未分組候選"),
        Member(id: "2816", name: "旺旺保", group: "未分組候選"),
        Member(id: "2601", name: "益航", group: "未分組候選"),
        Member(id: "9910", name: "豐泰", group: "未分組候選"),
        Member(id: "2462", name: "良得電", group: "未分組候選"),
        Member(id: "8499", name: "鼎炫-KY", group: "未分組候選"),
        Member(id: "2642", name: "宅配通", group: "未分組候選"),
        Member(id: "1201", name: "味全", group: "未分組候選"),
        Member(id: "8213", name: "志超", group: "未分組候選"),
        Member(id: "6142", name: "友勁", group: "未分組候選"),
        Member(id: "9904", name: "寶成", group: "未分組候選"),
        Member(id: "2028", name: "威致", group: "未分組候選"),
        Member(id: "2345", name: "智邦", group: "未分組候選"),
        Member(id: "2911", name: "麗嬰房", group: "未分組候選"),
        Member(id: "2913", name: "農林", group: "未分組候選"),
        Member(id: "1907", name: "永豐餘", group: "未分組候選"),
        Member(id: "2354", name: "鴻準", group: "未分組候選")
    ]

    private static let reservedSampleIDs = Set([
        "2449", "3653", "2368", "8996", "3017", "2201", "1216", "8454", "1301", "2317",
        "2330", "2308", "2382", "1590", "2882", "1101", "2002", "2912", "3045", "1477"
    ])

    static let members = Sample.a.members

    static let historyStart = requiredDate("2018/01/02")
    static let simulationStart = requiredDate("2019/01/02")
    static let snapshotThrough = requiredDate("2026/07/22")
    static let moneyBaseWan = 600.0
    static let automaticInvestments = 2.0
    static let abPoolDirectoryName = "ab-2016-07-22-pool"
    static let abPoolWorkingDirectoryName = "ab-2016-07-22-pool-backfill-working"
    static let abPoolCompleteDirectoryName = "ab-2016-07-22-pool-t2-complete"
    static let abPoolHistoryStart = requiredDate("2016/07/22")
    static let abPoolSimulationStart = requiredDate("2017/07/22")
    static let abPoolBackfillThrough = requiredDate("2017/12/31")
    static let abNineYearProfileID = "abcd9-t2s20-20160722-20260722-v2"
    static let fortyStockPoolDirectoryName = "central-pool-2016-07-22-working-v1"
    static let fortyStockPoolID = "central-pool-t2s20-20160722-20260722-v1"
    private static let legacyFortyStockPoolDirectoryName = "pool-40-2016-07-22-t2-working-v1"
    private static let legacyFortyStockPoolID = "pool40-t2-20160722-20260722-v1"
    static let fortyStockBatchRequestLimit = 120

    private static let expansionPoolMembers: [Member] = [
        Member(id: "1519", name: "華城", group: "未分組候選"),
        Member(id: "2303", name: "聯電", group: "未分組候選"),
        Member(id: "2454", name: "聯發科", group: "未分組候選"),
        Member(id: "2634", name: "漢翔", group: "未分組候選"),
        Member(id: "3037", name: "欣興", group: "未分組候選"),
        Member(id: "3231", name: "緯創", group: "未分組候選"),
        Member(id: "3533", name: "嘉澤", group: "未分組候選"),
        Member(id: "3661", name: "世芯-KY", group: "未分組候選"),
        Member(id: "8046", name: "南電", group: "未分組候選"),
        Member(id: "8210", name: "勤誠", group: "未分組候選")
    ]

    private static let additionalPoolMembers: [Member] = poolCandidateMembers + expansionPoolMembers

    private static let additionalPoolListingDateTexts: [String: String] = [
        "1201": "1962/02/09", "1907": "1977/02/22",
        "2028": "1996/12/13", "2345": "1995/11/15",
        "2354": "1996/10/08", "2462": "2001/09/17",
        "2601": "1965/11/04", "2642": "2013/12/12",
        "2816": "1992/05/05", "2911": "1997/01/18",
        "2913": "1962/02/09", "3593": "2009/03/16",
        "4562": "2017/08/21", "6142": "2003/08/04",
        "8213": "2009/12/25", "8422": "2011/10/05",
        "8473": "2016/09/08", "8499": "2017/11/24",
        "9904": "1990/01/19", "9910": "1992/02/18",
        "1519": "1997/04/16", "2303": "1985/07/16",
        "2454": "2001/07/23", "2634": "2014/08/25",
        "3037": "2002/08/26", "3231": "2003/08/19",
        "3533": "2007/12/10", "3661": "2014/10/28",
        "8046": "2006/04/07", "8210": "2011/12/01"
    ]

    static func sampleCExecutionIsUnlocked(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("--unlock-sample-c-ft7")
    }

    static func evaluationConfiguration(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> EvaluationConfiguration {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        guard let id = value(after: "--evaluation-id"),
              id.range(of: #"^ft4b-[a-z0-9-]{1,24}$"#, options: .regularExpression) != nil else {
            throw DatasetError.invalidEvaluationConfiguration("缺少或不合法的 evaluation id")
        }
        guard let encoded = value(after: "--evaluation-members-base64"),
              let data = Data(base64Encoded: encoded),
              let payloads = try? JSONDecoder().decode(
                [EvaluationMemberPayload].self,
                from: data
              ),
              (1...20).contains(payloads.count) else {
            throw DatasetError.invalidEvaluationConfiguration("成員必須是 1～20 檔的 base64 JSON")
        }

        let ids = payloads.map(\.id)
        guard Set(ids).count == ids.count else {
            throw DatasetError.invalidEvaluationConfiguration("股票代號重複")
        }
        guard ids.allSatisfy({
            $0.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil
        }) else {
            throw DatasetError.invalidEvaluationConfiguration("股票代號必須是四位數")
        }
        guard reservedSampleIDs.isDisjoint(with: ids) else {
            throw DatasetError.invalidEvaluationConfiguration("不得包含 Sample A／B 股票")
        }
        guard payloads.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw DatasetError.invalidEvaluationConfiguration("股票名稱不得空白")
        }

        return EvaluationConfiguration(
            id: id,
            members: payloads.map {
                Member(
                    id: $0.id,
                    name: $0.name.trimmingCharacters(in: .whitespaces),
                    group: "研究池"
                )
            }
        )
    }

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

    static func diagnoseCurrentTWSE1101(rootURL: URL) async throws -> TWSEDiagnosticResult {
        let fileManager = FileManager.default
        let sourceStore = rootURL
            .appendingPathComponent(abPoolDirectoryName, isDirectory: true)
            .appendingPathComponent("pool.store")
        guard fileManager.fileExists(atPath: sourceStore.path) else {
            throw DatasetError.missingABPool(sourceStore.path)
        }
        let diagnosticDirectory = rootURL.appendingPathComponent(
            ".twse-1101-diagnostic-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: diagnosticDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: diagnosticDirectory) }
        let diagnosticStore = diagnosticDirectory.appendingPathComponent("diagnostic.store")
        try copyPoolSourceStore(from: sourceStore, to: diagnosticStore)

        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalTWSE1101Diagnostic",
            schema: schema,
            url: diagnosticStore,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        guard let stock = try Stock.fetch(in: context, sId: ["1101"]).first else {
            throw DatasetError.missingPoolStock("1101")
        }
        let month = twDateTime.startOfMonth(Date())
        let monthText = twDateTime.stringFromDate(month, format: "yyyy/MM")
        let technical = Technical(modelContext: context)
        let technicalSucceeded = await technical.twseRequestAsync(
            stock: stock,
            dateStart: month,
            recalculate: false
        )
        if technicalSucceeded {
            return TWSEDiagnosticResult(
                stockID: stock.sId,
                month: monthText,
                technicalSucceeded: true,
                httpStatus: nil,
                mimeType: nil,
                byteCount: 0,
                responsePrefix: "",
                transportError: nil
            )
        }

        let ymd = twDateTime.stringFromDate(month, format: "yyyyMMdd")
        let url = URL(
            string: "https://www.twse.com.tw/exchangeReport/STOCK_DAY?&date=\(ymd)&stockNo=1101"
        )!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let prefix = String(data: data.prefix(240), encoding: .utf8)
                ?? data.prefix(120).base64EncodedString()
            return TWSEDiagnosticResult(
                stockID: stock.sId,
                month: monthText,
                technicalSucceeded: false,
                httpStatus: http?.statusCode,
                mimeType: response.mimeType,
                byteCount: data.count,
                responsePrefix: prefix,
                transportError: nil
            )
        } catch {
            let nsError = error as NSError
            return TWSEDiagnosticResult(
                stockID: stock.sId,
                month: monthText,
                technicalSucceeded: false,
                httpStatus: nil,
                mimeType: nil,
                byteCount: 0,
                responsePrefix: "",
                transportError: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
            )
        }
    }

    static func backfillABPool(
        rootURL: URL,
        requestDelay: Duration = .seconds(1.5),
        progress: (String) -> Void = { _ in }
    ) async throws -> PoolBackfillResult {
        let fileManager = FileManager.default
        let sourceDirectory = rootURL.appendingPathComponent(
            abPoolDirectoryName,
            isDirectory: true
        )
        let sourceStore = sourceDirectory.appendingPathComponent("pool.store")
        guard fileManager.fileExists(atPath: sourceStore.path) else {
            throw DatasetError.missingABPool(sourceStore.path)
        }
        let completeDirectory = rootURL.appendingPathComponent(
            abPoolCompleteDirectoryName,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: completeDirectory.path) else {
            throw DatasetError.completeABPoolAlreadyExists(completeDirectory.path)
        }
        let workingDirectory = rootURL.appendingPathComponent(
            abPoolWorkingDirectoryName,
            isDirectory: true
        )
        if !fileManager.fileExists(atPath: workingDirectory.path) {
            try fileManager.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
            try copyPoolSourceStore(
                from: sourceStore,
                to: workingDirectory.appendingPathComponent("pool.store")
            )
        }

        let failedRequests = try await downloadABPoolBackfill(
            storeURL: workingDirectory.appendingPathComponent("pool.store"),
            requestDelay: requestDelay,
            progress: progress
        )
        let backfillLogURL = workingDirectory.appendingPathComponent("backfill.log")
        if !failedRequests.isEmpty {
            try failedRequests.joined(separator: "\n").appending("\n").write(
                to: backfillLogURL,
                atomically: true,
                encoding: .utf8
            )
            return PoolBackfillResult(
                completed: false,
                directoryURL: workingDirectory,
                storeURL: workingDirectory.appendingPathComponent("pool.store"),
                manifestURL: nil,
                failedRequests: failedRequests
            )
        }

        let sourceManifestURL = sourceDirectory.appendingPathComponent("manifest.json")
        let sourceManifest = try JSONDecoder().decode(
            PoolManifest.self,
            from: Data(contentsOf: sourceManifestURL)
        )
        let manifest = try recalculateAndValidateABPool(
            storeURL: workingDirectory.appendingPathComponent("pool.store"),
            sourceManifest: sourceManifest,
            progress: progress
        )
        let manifestURL = workingDirectory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try "COMPLETE \(ISO8601DateFormatter().string(from: Date()))\n".write(
            to: backfillLogURL,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.moveItem(at: workingDirectory, to: completeDirectory)
        return PoolBackfillResult(
            completed: true,
            directoryURL: completeDirectory,
            storeURL: completeDirectory.appendingPathComponent("pool.store"),
            manifestURL: completeDirectory.appendingPathComponent("manifest.json"),
            failedRequests: []
        )
    }

    private static func downloadABPoolBackfill(
        storeURL: URL,
        requestDelay: Duration,
        progress: (String) -> Void
    ) async throws -> [String] {
        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalBacktestABPoolBackfill",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let technical = Technical(modelContext: context)
        let stocks = try Stock.fetchAll(in: context).sorted { $0.sId < $1.sId }
        guard stocks.count == 20 else {
            throw DatasetError.invalidABPool("預期 20 檔，實際 \(stocks.count) 檔")
        }
        let requestedMonths = months(from: abPoolHistoryStart, through: abPoolBackfillThrough)
        var failedRequests: [String] = []
        var activeRequestDelay = requestDelay
        let fallbackRequestDelay: Duration = .seconds(5)
        let retryDelays: [Duration] = [.seconds(15), .seconds(30), .seconds(60)]
        var consecutiveFailures = 0
        technical.countTWSE = stocks.count

        for (stockIndex, stock) in stocks.enumerated() {
            technical.progressTWSE = stockIndex + 1
            stock.dateFirst = abPoolHistoryStart
            stock.dateStart = abPoolSimulationStart
            let existingTrades = try Trade.fetch(
                in: context,
                for: stock,
                TWSE: true,
                ascending: true
            )
            let completedMonths = Set(
                existingTrades.map { twDateTime.startOfMonth($0.dateTime) }
            )
            for (monthIndex, month) in requestedMonths.enumerated()
                where !completedMonths.contains(month) {
                let monthText = twDateTime.stringFromDate(month, format: "yyyy/MM")
                let message = "\(stockIndex + 1)/\(stocks.count) \(stock.sId) "
                    + "\(stock.sName) \(monthIndex + 1)/\(requestedMonths.count) \(monthText)"
                progress(message)
                var succeeded = false
                for attempt in 0...retryDelays.count {
                    succeeded = await technical.twseRequestAsync(
                        stock: stock,
                        dateStart: month,
                        recalculate: false
                    )
                    if succeeded {
                        break
                    }
                    activeRequestDelay = fallbackRequestDelay
                    guard attempt < retryDelays.count else { break }
                    let retryDelay = retryDelays[attempt]
                    progress("\(message) 失敗，等待 \(retryDelay) 後重試")
                    try await Task.sleep(for: retryDelay)
                }
                if !succeeded {
                    failedRequests.append("\(stock.sId) \(monthText)")
                    consecutiveFailures += 1
                } else {
                    consecutiveFailures = 0
                }
                try await Task.sleep(for: activeRequestDelay)
                if consecutiveFailures >= 3 {
                    progress("連續三個月份下載失敗，停止本次回填")
                    technical.progressTWSE = nil
                    technical.countTWSE = nil
                    try context.save()
                    return failedRequests
                }
            }
            try context.save()
        }
        technical.progressTWSE = nil
        technical.countTWSE = nil
        try context.save()
        return failedRequests
    }

    private static func recalculateAndValidateABPool(
        storeURL: URL,
        sourceManifest: PoolManifest,
        progress: (String) -> Void
    ) throws -> PoolManifest {
        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalBacktestABPoolT2Complete",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let technical = Technical(modelContext: context)
        let stocks = try Stock.fetchAll(in: context).sorted { $0.sId < $1.sId }
        var summaries: [PoolStockSummary] = []

        for (index, stock) in stocks.enumerated() {
            let allTrades = try Trade.fetch(in: context, for: stock, ascending: true)
            for trade in allTrades where trade.dateTime < abPoolHistoryStart {
                context.delete(trade)
            }
            try context.save()
            progress("T2 \(index + 1)/\(stocks.count) \(stock.sId) \(stock.sName)")
            _ = try technical.recalculate(
                stock: stock,
                plan: RecalculationPlan(technical: .all, simulation: .none)
            )
            let trades = try Trade.fetch(in: context, for: stock, ascending: true)
            guard let first = trades.first,
                  twDateTime.startOfDay(first.dateTime) == twDateTime.startOfDay(abPoolHistoryStart) else {
                throw DatasetError.invalidABPool("\(stock.sId) 首筆不是 2016/07/22")
            }
            let invalidPriceCount = trades.filter {
                !finite([$0.priceOpen, $0.priceHigh, $0.priceLow, $0.priceClose, $0.volumeClose])
                    || $0.priceOpen <= 0 || $0.priceHigh <= 0
                    || $0.priceLow <= 0 || $0.priceClose <= 0
            }.count
            let invalidTechnicalCount = trades.filter {
                !finite([
                    $0.tMa20, $0.tMa60, $0.tKdK, $0.tKdD, $0.tKdJ, $0.tOsc,
                    $0.tZ125, $0.tZ250, $0.vZ125, $0.vZ250
                ])
            }.count
            guard invalidPriceCount == 0, invalidTechnicalCount == 0 else {
                throw DatasetError.invalidABPool(
                    "\(stock.sId) 價格異常 \(invalidPriceCount)、技術異常 \(invalidTechnicalCount)"
                )
            }
            summaries.append(PoolStockSummary(
                id: stock.sId,
                name: stock.sName,
                firstTrade: twDateTime.stringFromDate(first.dateTime),
                lastTrade: trades.last.map { twDateTime.stringFromDate($0.dateTime) } ?? "",
                tradeCount: trades.count,
                technicalCount: trades.filter(\.tUpdated).count
            ))
        }
        try context.save()
        return PoolManifest(
            poolID: "ab20-t2-20160722-20260722-v2",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            historyTargetStart: twDateTime.stringFromDate(abPoolHistoryStart),
            simulationTargetStart: twDateTime.stringFromDate(abPoolSimulationStart),
            through: twDateTime.stringFromDate(snapshotThrough),
            technicalRuleVersion: Technical.technicalRuleVersion,
            simulationStateCopied: false,
            coverageStatus: "complete",
            sources: sourceManifest.sources,
            stocks: summaries
        )
    }

    nonisolated static func migrateABPool(
        in directoryURL: URL,
        sources: [PoolSource],
        historyStart: Date,
        simulationStart: Date,
        through endDate: Date,
        technicalRuleVersion: String
    ) throws -> PoolResult {
        let fileManager = FileManager.default
        let logURL = directoryURL.deletingLastPathComponent()
            .appendingPathComponent("ab-pool-migration.log")
        try "START \(ISO8601DateFormatter().string(from: Date()))\n".write(
            to: logURL,
            atomically: true,
            encoding: .utf8
        )
        guard !fileManager.fileExists(atPath: directoryURL.path) else {
            throw DatasetError.poolAlreadyExists(directoryURL.path)
        }

        let sourceSamples = Set(sources.map(\.sample))
        guard sourceSamples == Set([Sample.a, Sample.b]), sources.count == 2 else {
            throw DatasetError.poolCopyMismatch("來源必須各包含一次 Sample A 與 Sample B")
        }
        for source in sources where !fileManager.fileExists(atPath: source.storeURL.path) {
            throw DatasetError.missingPoolSource(source.storeURL.path)
        }

        try fileManager.createDirectory(
            at: directoryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = directoryURL.deletingLastPathComponent().appendingPathComponent(
            ".\(directoryURL.lastPathComponent)-building-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)

        do {
            let manifest = try buildABPool(
                in: temporaryURL,
                sources: sources,
                historyStart: historyStart,
                simulationStart: simulationStart,
                through: endDate,
                technicalRuleVersion: technicalRuleVersion,
                progress: { appendPoolMigrationLog($0, to: logURL) }
            )
            try? fileManager.removeItem(
                at: temporaryURL.appendingPathComponent("source-staging", isDirectory: true)
            )
            let manifestURL = temporaryURL.appendingPathComponent("manifest.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            try fileManager.moveItem(at: temporaryURL, to: directoryURL)
            appendPoolMigrationLog("COMPLETE \(manifest.stocks.count) stocks", to: logURL)
            return PoolResult(
                storeURL: directoryURL.appendingPathComponent("pool.store"),
                manifestURL: directoryURL.appendingPathComponent("manifest.json"),
                manifest: manifest
            )
        } catch {
            appendPoolMigrationLog("FAILED \(poolMigrationErrorDescription(error))", to: logURL)
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    nonisolated private static func buildABPool(
        in directoryURL: URL,
        sources: [PoolSource],
        historyStart: Date,
        simulationStart: Date,
        through endDate: Date,
        technicalRuleVersion: String,
        progress: (String) -> Void
    ) throws -> PoolManifest {
        progress("OPEN DESTINATION")
        let schema = Schema([Stock.self, Trade.self])
        let destinationURL = directoryURL.appendingPathComponent("pool.store")
        let destinationConfiguration = ModelConfiguration(
            "InternalBacktestABPool",
            schema: schema,
            url: destinationURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let destinationContainer = try ModelContainer(
            for: schema,
            configurations: [destinationConfiguration]
        )
        progress("DESTINATION READY")
        let expectedMembers = Dictionary(
            uniqueKeysWithValues: sources.flatMap(\.members).map { ($0.id, $0) }
        )
        guard expectedMembers.count == 20 else {
            throw DatasetError.poolCopyMismatch(
                "A／B來源應為 20 檔不同股票，實際為 \(expectedMembers.count) 檔"
            )
        }
        var copiedIDs: Set<String> = []
        var sourceSummaries: [PoolSourceSummary] = []
        var stockSummaries: [PoolStockSummary] = []
        let sourceStagingURL = directoryURL.appendingPathComponent(
            "source-staging",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceStagingURL,
            withIntermediateDirectories: true
        )

        for source in sources.sorted(by: { $0.sample.rawValue < $1.sample.rawValue }) {
            progress("STAGE SOURCE \(source.sample.rawValue)")
            let stagedSourceURL = sourceStagingURL.appendingPathComponent(
                "source-\(source.sample.rawValue.lowercased()).store"
            )
            try copyPoolSourceStore(from: source.storeURL, to: stagedSourceURL)
            progress("OPEN SOURCE \(source.sample.rawValue)")
            let sourceConfiguration = ModelConfiguration(
                "InternalBacktestPoolSource-\(source.sample.rawValue)",
                schema: schema,
                url: stagedSourceURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let sourceContainer = try ModelContainer(
                for: schema,
                configurations: [sourceConfiguration]
            )
            progress("SOURCE \(source.sample.rawValue) READY")
            let sourceContext = ModelContext(sourceContainer)
            let sourceStocks = Dictionary(
                uniqueKeysWithValues: try Stock.fetchAll(in: sourceContext).map { ($0.sId, $0) }
            )
            let memberIDs = source.members.map(\.id)

            for id in memberIDs {
                guard let member = expectedMembers[id], let sourceStock = sourceStocks[id] else {
                    throw DatasetError.missingPoolStock(id)
                }
                guard copiedIDs.insert(id).inserted else {
                    throw DatasetError.duplicatePoolStock(id)
                }

                progress("COPYING \(member.id) \(member.name)")
                let summary = try autoreleasepool {
                    let destinationContext = ModelContext(destinationContainer)
                    let destinationStock = Stock(
                        sId: member.id,
                        sName: member.name,
                        group: "",
                        dateFirst: historyStart,
                        dateStart: simulationStart,
                        simInvestAuto: 0,
                        simMoneyBase: 0
                    )
                    destinationStock.isListed = sourceStock.isListed
                    destinationStock.technicalStateVersion = sourceStock.technicalStateVersion
                    destinationStock.simulationStateVersion = 0
                    destinationStock.technicalDirtyFrom = sourceStock.technicalDirtyFrom
                    destinationStock.simulationDirtyFrom = nil
                    destinationContext.insert(destinationStock)

                    let sourceTrades = try Trade.fetch(
                        in: sourceContext,
                        for: sourceStock,
                        ascending: true
                    ).filter { $0.dateTime <= endDate }
                    for sourceTrade in sourceTrades {
                        let destinationTrade = Trade(
                            stock: destinationStock,
                            dateTime: sourceTrade.dateTime,
                            dataSource: sourceTrade.dataSource
                        )
                        copyMarketAndTechnical(from: sourceTrade, to: destinationTrade)
                        destinationContext.insert(destinationTrade)
                    }
                    try destinationContext.save()
                    return PoolStockSummary(
                        id: member.id,
                        name: member.name,
                        firstTrade: sourceTrades.first.map {
                            twDateTime.stringFromDate($0.dateTime)
                        } ?? "",
                        lastTrade: sourceTrades.last.map {
                            twDateTime.stringFromDate($0.dateTime)
                        } ?? "",
                        tradeCount: sourceTrades.count,
                        technicalCount: sourceTrades.filter(\.tUpdated).count
                    )
                }
                stockSummaries.append(summary)
                progress("COPIED \(summary.id) \(summary.tradeCount) trades")
            }

            sourceSummaries.append(PoolSourceSummary(
                sampleID: source.sample.rawValue,
                storePath: source.storeURL.path,
                stockIDs: memberIDs
            ))
        }

        guard copiedIDs == Set(expectedMembers.keys) else {
            let missing = Set(expectedMembers.keys).subtracting(copiedIDs).sorted().joined(separator: ",")
            throw DatasetError.poolCopyMismatch("尚未搬入：\(missing)")
        }
        let validationContext = ModelContext(destinationContainer)
        let destinationStocks = try Stock.fetchAll(in: validationContext)
        guard destinationStocks.count == expectedMembers.count else {
            throw DatasetError.poolCopyMismatch(
                "預期 \(expectedMembers.count) 檔，實際 \(destinationStocks.count) 檔"
            )
        }
        for summary in stockSummaries {
            guard let stock = destinationStocks.first(where: { $0.sId == summary.id }) else {
                throw DatasetError.poolCopyMismatch("目的資料庫缺少 \(summary.id)")
            }
            let copiedCount = try Trade.fetch(
                in: validationContext,
                for: stock,
                ascending: true
            ).count
            guard copiedCount == summary.tradeCount else {
                throw DatasetError.poolCopyMismatch(
                    "\(summary.id) 預期 \(summary.tradeCount) 筆，實際 \(copiedCount) 筆"
                )
            }
        }

        return PoolManifest(
            poolID: "ab20-t2-20160722-20260722-v1",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            historyTargetStart: twDateTime.stringFromDate(historyStart),
            simulationTargetStart: twDateTime.stringFromDate(simulationStart),
            through: twDateTime.stringFromDate(endDate),
            technicalRuleVersion: technicalRuleVersion,
            simulationStateCopied: false,
            coverageStatus: "needs-backfill",
            sources: sourceSummaries,
            stocks: stockSummaries.sorted { $0.id < $1.id }
        )
    }

    nonisolated private static func appendPoolMigrationLog(_ message: String, to url: URL) {
        guard let data = "\(message)\n".data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static func prepareFortyStockPool(rootURL: URL) throws -> FortyStockResult {
        let fileManager = FileManager.default
        let sourceDirectory = rootURL.appendingPathComponent(
            abPoolCompleteDirectoryName,
            isDirectory: true
        )
        let sourceStoreURL = sourceDirectory.appendingPathComponent("pool.store")
        let sourceManifestURL = sourceDirectory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: sourceStoreURL.path),
              fileManager.fileExists(atPath: sourceManifestURL.path) else {
            throw DatasetError.missingABPool(sourceDirectory.path)
        }
        let sourceManifest = try JSONDecoder().decode(
            PoolManifest.self,
            from: Data(contentsOf: sourceManifestURL)
        )
        guard sourceManifest.coverageStatus == "complete",
              sourceManifest.technicalRuleVersion == Technical.technicalRuleVersion,
              sourceManifest.stocks.count == 20 else {
            throw DatasetError.invalidABPool("40 檔擴充來源必須是完整的 20 檔 T2 資料池")
        }
        let existingIDs = Set(sourceManifest.stocks.map(\.id))
        let additionalIDs = Set(additionalPoolMembers.map(\.id))
        guard existingIDs.count == 20,
              additionalIDs.count == 20,
              existingIDs.isDisjoint(with: additionalIDs) else {
            throw DatasetError.invalidABPool("既有與新增候選必須各為 20 檔且不可重複")
        }

        let destinationURL = rootURL.appendingPathComponent(
            fortyStockPoolDirectoryName,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw DatasetError.poolAlreadyExists(destinationURL.path)
        }
        let temporaryURL = rootURL.appendingPathComponent(
            ".\(fortyStockPoolDirectoryName)-building-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let storeURL = temporaryURL.appendingPathComponent("pool.store")
        try copyPoolSourceStore(from: sourceStoreURL, to: storeURL)
        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalBacktestFortyStockPool",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        for member in additionalPoolMembers {
            let stock = Stock(
                sId: member.id,
                sName: member.name,
                group: member.group,
                dateFirst: abPoolHistoryStart,
                dateStart: abPoolSimulationStart,
                simInvestAuto: 0,
                simMoneyBase: 0
            )
            stock.isListed = true
            stock.technicalStateVersion = 0
            stock.simulationStateVersion = 0
            stock.technicalDirtyFrom = abPoolHistoryStart
            stock.simulationDirtyFrom = nil
            context.insert(stock)
        }
        try context.save()
        guard try Stock.fetchAll(in: context).count == 20 + additionalPoolMembers.count else {
            throw DatasetError.poolCopyMismatch("集中資料池股票數不正確")
        }

        let targetMonths = months(from: abPoolHistoryStart, through: snapshotThrough).map {
            twDateTime.stringFromDate($0, format: "yyyy/MM")
        }
        let existingSummaries = sourceManifest.stocks.map {
            FortyStockSummary(
                id: $0.id,
                name: $0.name,
                role: "既有 A/B",
                status: "complete",
                firstTrade: $0.firstTrade,
                lastTrade: $0.lastTrade,
                tradeCount: $0.tradeCount,
                technicalCount: $0.technicalCount,
                completedMonths: targetMonths
            )
        }
        let pendingSummaries = additionalPoolMembers.map {
            FortyStockSummary(
                id: $0.id,
                name: $0.name,
                role: "新增未分組候選",
                status: "pending-download",
                firstTrade: "",
                lastTrade: "",
                tradeCount: 0,
                technicalCount: 0,
                completedMonths: [],
                listingDate: additionalPoolListingDateTexts[$0.id]
            )
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let manifest = FortyStockManifest(
            poolID: fortyStockPoolID,
            createdAt: now,
            updatedAt: now,
            sourcePoolID: sourceManifest.poolID,
            historyTargetStart: twDateTime.stringFromDate(abPoolHistoryStart),
            simulationTargetStart: twDateTime.stringFromDate(abPoolSimulationStart),
            through: twDateTime.stringFromDate(snapshotThrough),
            technicalRuleVersion: Technical.technicalRuleVersion,
            simulationStateCopied: false,
            coverageStatus: "pending-download",
            targetMonthCount: targetMonths.count,
            completedStockCount: 20,
            pendingStockIDs: additionalPoolMembers.map(\.id).sorted(),
            downloadPolicy: FortyStockDownloadPolicy(
                initialDelaySeconds: 1.5,
                fallbackDelaySeconds: 5,
                retryDelaySeconds: [15, 30, 60],
                maximumRequestsPerBatch: fortyStockBatchRequestLimit
            ),
            stocks: (existingSummaries + pendingSummaries).sorted { $0.id < $1.id }
        )
        let manifestURL = temporaryURL.appendingPathComponent("manifest.json")
        try writeFortyStockManifest(manifest, to: manifestURL)

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return FortyStockResult(
            directoryURL: destinationURL,
            storeURL: destinationURL.appendingPathComponent("pool.store"),
            manifestURL: destinationURL.appendingPathComponent("manifest.json"),
            manifest: manifest
        )
    }

    @MainActor
    static func expandCentralStockPool(rootURL: URL) throws -> FortyStockResult {
        let fileManager = FileManager.default
        let legacyURL = rootURL.appendingPathComponent(
            legacyFortyStockPoolDirectoryName,
            isDirectory: true
        )
        let directoryURL = rootURL.appendingPathComponent(
            fortyStockPoolDirectoryName,
            isDirectory: true
        )
        if !fileManager.fileExists(atPath: directoryURL.path) {
            guard fileManager.fileExists(atPath: legacyURL.path) else {
                throw DatasetError.missingABPool(legacyURL.path)
            }
            try fileManager.moveItem(at: legacyURL, to: directoryURL)
        }

        let storeURL = directoryURL.appendingPathComponent("pool.store")
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: storeURL.path),
              fileManager.fileExists(atPath: manifestURL.path) else {
            throw DatasetError.missingABPool(directoryURL.path)
        }
        var manifest = try JSONDecoder().decode(
            FortyStockManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.poolID == legacyFortyStockPoolID || manifest.poolID == fortyStockPoolID else {
            throw DatasetError.invalidABPool("集中資料池 manifest 不相符")
        }

        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalBacktestCentralPoolExpansion",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        var existingIDs = Set(try Stock.fetchAll(in: context).map(\.sId))
        let requestedMonths = months(from: abPoolHistoryStart, through: snapshotThrough)

        for member in additionalPoolMembers where !existingIDs.contains(member.id) {
            guard let listingText = additionalPoolListingDateTexts[member.id],
                  let listingDate = twDateTime.dateFromString(listingText) else {
                throw DatasetError.invalidABPool("缺少 \(member.id) 的上市日期")
            }
            let stock = Stock(
                sId: member.id,
                sName: member.name,
                group: member.group,
                dateFirst: max(abPoolHistoryStart, listingDate),
                dateStart: abPoolSimulationStart,
                simInvestAuto: 0,
                simMoneyBase: 0
            )
            stock.isListed = true
            stock.technicalStateVersion = 0
            stock.simulationStateVersion = 0
            stock.technicalDirtyFrom = max(abPoolHistoryStart, listingDate)
            stock.simulationDirtyFrom = nil
            context.insert(stock)
            existingIDs.insert(member.id)

            let listingMonth = twDateTime.startOfMonth(listingDate)
            let prelistingMonths = requestedMonths
                .filter { $0 < listingMonth }
                .map { twDateTime.stringFromDate($0, format: "yyyy/MM") }
            manifest.stocks.append(FortyStockSummary(
                id: member.id,
                name: member.name,
                role: "新增未分組候選",
                status: "pending-download",
                firstTrade: "",
                lastTrade: "",
                tradeCount: 0,
                technicalCount: 0,
                completedMonths: prelistingMonths,
                listingDate: listingText
            ))
        }
        try context.save()

        let expectedCount = 20 + additionalPoolMembers.count
        guard existingIDs.count == expectedCount else {
            throw DatasetError.poolCopyMismatch("集中資料池應有 \(expectedCount) 檔，實際 \(existingIDs.count) 檔")
        }
        manifest.poolID = fortyStockPoolID
        manifest.stocks.sort { $0.id < $1.id }
        refreshFortyStockManifest(&manifest)
        try writeFortyStockManifest(manifest, to: manifestURL)
        return FortyStockResult(
            directoryURL: directoryURL,
            storeURL: storeURL,
            manifestURL: manifestURL,
            manifest: manifest
        )
    }

    static func backfillFortyStockPoolBatch(
        rootURL: URL,
        maximumRequests: Int = fortyStockBatchRequestLimit,
        progress: (String) -> Void = { _ in }
    ) async throws -> FortyStockBackfillResult {
        let directoryURL = rootURL.appendingPathComponent(
            fortyStockPoolDirectoryName,
            isDirectory: true
        )
        let storeURL = directoryURL.appendingPathComponent("pool.store")
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: storeURL.path),
              FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw DatasetError.missingABPool(directoryURL.path)
        }
        var manifest = try JSONDecoder().decode(
            FortyStockManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.poolID == fortyStockPoolID,
              manifest.stocks.count == 20 + additionalPoolMembers.count else {
            throw DatasetError.invalidABPool("集中資料池 manifest 不相符")
        }

        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalBacktestFortyStockBackfill",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let technical = Technical(modelContext: context)
        let stocksByID = Dictionary(
            uniqueKeysWithValues: try Stock.fetchAll(in: context).map { ($0.sId, $0) }
        )
        let requestedMonths = months(from: abPoolHistoryStart, through: snapshotThrough)
        for member in additionalPoolMembers {
            guard let index = manifest.stocks.firstIndex(where: { $0.id == member.id }),
                  let listingText = additionalPoolListingDateTexts[member.id],
                  let listingDate = twDateTime.dateFromString(listingText) else {
                throw DatasetError.invalidABPool("缺少 \(member.id) 的上市日期")
            }
            let listingMonth = twDateTime.startOfMonth(listingDate)
            let prelistingMonths = requestedMonths
                .filter { $0 < listingMonth }
                .map { twDateTime.stringFromDate($0, format: "yyyy/MM") }
            manifest.stocks[index].listingDate = listingText
            manifest.stocks[index].completedMonths = Array(
                Set(manifest.stocks[index].completedMonths).union(prelistingMonths)
            ).sorted()
        }
        refreshFortyStockManifest(&manifest)
        try writeFortyStockManifest(manifest, to: manifestURL)
        let retryDelays: [Duration] = [.seconds(15), .seconds(30), .seconds(60)]
        var activeRequestDelay: Duration = .seconds(1.5)
        let fallbackRequestDelay: Duration = .seconds(5)
        var attemptedRequests = 0
        var failedRequests: [String] = []
        var consecutiveFailures = 0
        technical.countTWSE = additionalPoolMembers.count

        downloadLoop: for (stockIndex, member) in additionalPoolMembers.enumerated() {
            guard let stock = stocksByID[member.id],
                  let manifestIndex = manifest.stocks.firstIndex(where: { $0.id == member.id }) else {
                throw DatasetError.missingPoolStock(member.id)
            }
            technical.progressTWSE = stockIndex + 1
            guard let listingText = additionalPoolListingDateTexts[member.id],
                  let listingDate = twDateTime.dateFromString(listingText) else {
                throw DatasetError.invalidABPool("缺少 \(member.id) 的上市日期")
            }
            stock.dateFirst = max(abPoolHistoryStart, listingDate)
            stock.dateStart = abPoolSimulationStart
            let completed = Set(manifest.stocks[manifestIndex].completedMonths)
            for (monthIndex, month) in requestedMonths.enumerated() {
                let monthText = twDateTime.stringFromDate(month, format: "yyyy/MM")
                guard !completed.contains(monthText) else { continue }
                guard attemptedRequests < maximumRequests else { break downloadLoop }
                attemptedRequests += 1
                let message = "\(stockIndex + 1)/\(additionalPoolMembers.count) "
                    + "\(member.id) \(member.name) \(monthIndex + 1)/\(requestedMonths.count) \(monthText)"
                progress(message)
                var succeeded = false
                for attempt in 0...retryDelays.count {
                    succeeded = await technical.twseRequestAsync(
                        stock: stock,
                        dateStart: month,
                        recalculate: false
                    )
                    if succeeded { break }
                    activeRequestDelay = fallbackRequestDelay
                    guard attempt < retryDelays.count else { break }
                    let retryDelay = retryDelays[attempt]
                    progress("\(message) 失敗，等待 \(retryDelay) 後重試")
                    try await Task.sleep(for: retryDelay)
                }
                if succeeded {
                    consecutiveFailures = 0
                    manifest.stocks[manifestIndex].completedMonths.append(monthText)
                    manifest.stocks[manifestIndex].completedMonths.sort()
                } else {
                    failedRequests.append("\(member.id) \(monthText)")
                    consecutiveFailures += 1
                }
                try context.save()
                refreshFortyStockManifest(&manifest)
                try writeFortyStockManifest(manifest, to: manifestURL)
                if consecutiveFailures >= 3 { break downloadLoop }
                try await Task.sleep(for: activeRequestDelay)
            }
        }

        for member in additionalPoolMembers {
            guard let stock = stocksByID[member.id],
                  let index = manifest.stocks.firstIndex(where: { $0.id == member.id }) else {
                continue
            }
            let trades = try Trade.fetch(in: context, for: stock, TWSE: true, ascending: true)
            manifest.stocks[index].firstTrade = trades.first.map {
                twDateTime.stringFromDate($0.dateTime)
            } ?? ""
            manifest.stocks[index].lastTrade = trades.last.map {
                twDateTime.stringFromDate($0.dateTime)
            } ?? ""
            manifest.stocks[index].tradeCount = trades.count
            manifest.stocks[index].technicalCount = trades.filter(\.tUpdated).count
        }
        refreshFortyStockManifest(&manifest)
        try writeFortyStockManifest(manifest, to: manifestURL)
        technical.progressTWSE = nil
        technical.countTWSE = nil
        try context.save()

        let pendingMonthCount = manifest.stocks
            .filter { $0.role == "新增未分組候選" }
            .reduce(0) { $0 + max(0, manifest.targetMonthCount - $1.completedMonths.count) }
        return FortyStockBackfillResult(
            completed: pendingMonthCount == 0,
            attemptedRequests: attemptedRequests,
            failedRequests: failedRequests,
            pendingMonthCount: pendingMonthCount,
            manifest: manifest
        )
    }

    private static func refreshFortyStockManifest(_ manifest: inout FortyStockManifest) {
        for index in manifest.stocks.indices where manifest.stocks[index].role == "新增未分組候選" {
            if manifest.stocks[index].completedMonths.count == manifest.targetMonthCount {
                if manifest.stocks[index].status != "t2-complete"
                    && manifest.stocks[index].status != "s20-complete" {
                    manifest.stocks[index].status = "download-complete-awaiting-t2"
                }
            } else {
                manifest.stocks[index].status = "pending-download"
            }
        }
        manifest.pendingStockIDs = manifest.stocks
            .filter { $0.status == "pending-download" }
            .map(\.id)
            .sorted()
        manifest.completedStockCount = manifest.stocks.count - manifest.pendingStockIDs.count
        manifest.coverageStatus = manifest.pendingStockIDs.isEmpty
            ? "download-complete-awaiting-t2"
            : "pending-download"
        manifest.updatedAt = ISO8601DateFormatter().string(from: Date())
    }

    @MainActor
    static func runFortyStockPoolT2(
        rootURL: URL,
        progress: (String) -> Void
    ) throws -> FortyStockManifest {
        let directoryURL = rootURL.appendingPathComponent(
            fortyStockPoolDirectoryName,
            isDirectory: true
        )
        let storeURL = directoryURL.appendingPathComponent("pool.store")
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: storeURL.path),
              FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw DatasetError.missingABPool(directoryURL.path)
        }
        var manifest = try JSONDecoder().decode(
            FortyStockManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.poolID == fortyStockPoolID,
              manifest.stocks.count == 20 + additionalPoolMembers.count else {
            throw DatasetError.invalidABPool("集中資料池 manifest 不相符")
        }
        let downloadsComplete = manifest.stocks
            .filter { $0.role == "新增未分組候選" }
            .allSatisfy { $0.completedMonths.count == manifest.targetMonthCount }
        guard downloadsComplete else {
            throw DatasetError.invalidABPool("40 檔行情尚未下載完成，不能執行 T2")
        }

        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalBacktestFortyStockT2",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let technical = Technical(modelContext: context)
        let stocksByID = Dictionary(
            uniqueKeysWithValues: try Stock.fetchAll(in: context).map { ($0.sId, $0) }
        )

        for (stockIndex, summary) in manifest.stocks.enumerated() {
            if (summary.status == "t2-complete" || summary.status == "s20-complete"),
               summary.tradeCount > 0,
               summary.technicalCount > 0 {
                continue
            }
            guard let stock = stocksByID[summary.id] else {
                throw DatasetError.missingPoolStock(summary.id)
            }
            progress("T2 \(stockIndex + 1)/\(manifest.stocks.count) \(stock.sId) \(stock.sName)")
            _ = try technical.recalculate(
                stock: stock,
                plan: RecalculationPlan(technical: .all, simulation: .none)
            )
            try context.save()

            let trades = try Trade.fetch(in: context, for: stock, ascending: true)
            let technicalCount = trades.filter(\.tUpdated).count
            guard !trades.isEmpty else {
                throw DatasetError.invalidABPool("\(stock.sId) 沒有行情資料")
            }
            let invalidPriceCount = trades.filter {
                !finite([$0.priceOpen, $0.priceHigh, $0.priceLow, $0.priceClose, $0.volumeClose])
                    || $0.priceOpen <= 0 || $0.priceHigh <= 0
                    || $0.priceLow <= 0 || $0.priceClose <= 0
            }.count
            let invalidTechnicalCount = trades.filter {
                !finite([
                    $0.tMa20, $0.tMa60, $0.tKdK, $0.tKdD, $0.tKdJ, $0.tOsc,
                    $0.tZ125, $0.tZ250, $0.vZ125, $0.vZ250
                ])
            }.count
            guard invalidPriceCount == 0, invalidTechnicalCount == 0 else {
                throw DatasetError.invalidABPool(
                    "\(stock.sId) 價格異常 \(invalidPriceCount)、技術異常 \(invalidTechnicalCount)"
                )
            }
            manifest.stocks[stockIndex].firstTrade = trades.first.map {
                twDateTime.stringFromDate($0.dateTime)
            } ?? ""
            manifest.stocks[stockIndex].lastTrade = trades.last.map {
                twDateTime.stringFromDate($0.dateTime)
            } ?? ""
            manifest.stocks[stockIndex].tradeCount = trades.count
            manifest.stocks[stockIndex].technicalCount = technicalCount
            manifest.stocks[stockIndex].status = "t2-complete"
            manifest.pendingStockIDs = manifest.stocks
                .filter { $0.status != "t2-complete" }
                .map(\.id)
                .sorted()
            manifest.completedStockCount = manifest.stocks.count - manifest.pendingStockIDs.count
            manifest.coverageStatus = "t2-in-progress"
            manifest.updatedAt = ISO8601DateFormatter().string(from: Date())
            try writeFortyStockManifest(manifest, to: manifestURL)
        }

        manifest.pendingStockIDs = []
        manifest.completedStockCount = manifest.stocks.count
        manifest.coverageStatus = "t2-complete-awaiting-s20"
        manifest.updatedAt = ISO8601DateFormatter().string(from: Date())
        try writeFortyStockManifest(manifest, to: manifestURL)
        return manifest
    }

    @MainActor
    static func runFortyStockPoolS20(
        rootURL: URL,
        progress: (String) -> Void
    ) throws -> FortyStockManifest {
        let directoryURL = rootURL.appendingPathComponent(
            fortyStockPoolDirectoryName,
            isDirectory: true
        )
        let storeURL = directoryURL.appendingPathComponent("pool.store")
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: storeURL.path),
              FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw DatasetError.missingABPool(directoryURL.path)
        }
        var manifest = try JSONDecoder().decode(
            FortyStockManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.poolID == fortyStockPoolID,
              manifest.stocks.count == 20 + additionalPoolMembers.count,
              manifest.stocks.allSatisfy({
                  $0.status == "t2-complete" || $0.status == "s20-complete"
              }) else {
            throw DatasetError.invalidABPool("40 檔 T2 尚未完成，不能執行 S20")
        }

        let schema = Schema([Stock.self, Trade.self])
        let configuration = ModelConfiguration(
            "InternalBacktestFortyStockS20",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let technical = Technical(modelContext: context)
        let stocksByID = Dictionary(
            uniqueKeysWithValues: try Stock.fetchAll(in: context).map { ($0.sId, $0) }
        )

        for (stockIndex, summary) in manifest.stocks.enumerated() {
            guard let stock = stocksByID[summary.id] else {
                throw DatasetError.missingPoolStock(summary.id)
            }
            if summary.status == "s20-complete",
               (summary.simulationCount ?? 0) > 0,
               stock.simMoneyBase == 600,
               stock.simInvestAuto == 2 {
                continue
            }
            stock.dateStart = abPoolSimulationStart
            stock.simMoneyBase = 600
            stock.simInvestAuto = 2
            let storedTrades = try Trade.fetch(in: context, for: stock, ascending: true)
            for trade in storedTrades where trade.dateTime > snapshotThrough {
                context.delete(trade)
            }
            try context.save()

            progress("S20 \(stockIndex + 1)/\(manifest.stocks.count) \(stock.sId) \(stock.sName)")
            _ = try technical.recalculate(
                stock: stock,
                plan: RecalculationPlan(
                    technical: .none,
                    simulation: .all,
                    resetPolicy: .clearUserActions,
                    resetDerivedSimulationState: true,
                    simulationEnd: snapshotThrough
                )
            )
            try context.save()

            let trades = try Trade.fetch(in: context, for: stock, ascending: true)
            let simulationTrades = trades.filter {
                $0.dateTime >= abPoolSimulationStart && $0.dateTime <= snapshotThrough
            }
            let invalidSimulationCount = simulationTrades.filter {
                !finite([$0.rollAmtRoi, $0.days])
            }.count
            guard !simulationTrades.isEmpty, invalidSimulationCount == 0 else {
                throw DatasetError.invalidABPool(
                    "\(stock.sId) S20 異常：筆數 \(simulationTrades.count)、數值異常 \(invalidSimulationCount)"
                )
            }

            manifest.stocks[stockIndex].firstTrade = trades.first.map {
                twDateTime.stringFromDate($0.dateTime)
            } ?? ""
            manifest.stocks[stockIndex].lastTrade = trades.last.map {
                twDateTime.stringFromDate($0.dateTime)
            } ?? ""
            manifest.stocks[stockIndex].tradeCount = trades.count
            manifest.stocks[stockIndex].technicalCount = trades.filter(\.tUpdated).count
            manifest.stocks[stockIndex].simulationCount = simulationTrades.count
            manifest.stocks[stockIndex].status = "s20-complete"
            manifest.pendingStockIDs = manifest.stocks
                .filter { $0.status != "s20-complete" }
                .map(\.id)
                .sorted()
            manifest.completedStockCount = manifest.stocks.count - manifest.pendingStockIDs.count
            manifest.coverageStatus = "s20-in-progress"
            manifest.dataRuleVersion = Technical.dataRuleVersion
            manifest.simulationMoneyBase = 600
            manifest.simulationInvestAuto = 2
            manifest.updatedAt = ISO8601DateFormatter().string(from: Date())
            try writeFortyStockManifest(manifest, to: manifestURL)
        }

        manifest.pendingStockIDs = []
        manifest.completedStockCount = manifest.stocks.count
        manifest.coverageStatus = "s20-complete"
        manifest.dataRuleVersion = Technical.dataRuleVersion
        manifest.simulationMoneyBase = 600
        manifest.simulationInvestAuto = 2
        manifest.updatedAt = ISO8601DateFormatter().string(from: Date())
        try writeFortyStockManifest(manifest, to: manifestURL)
        return manifest
    }

    private static func writeFortyStockManifest(
        _ manifest: FortyStockManifest,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    nonisolated static func createABNineYearShards(rootURL: URL) throws -> [PoolResult] {
        let fileManager = FileManager.default
        let sourceDirectory = rootURL.appendingPathComponent(
            fortyStockPoolDirectoryName,
            isDirectory: true
        )
        let sourceStoreURL = sourceDirectory.appendingPathComponent("pool.store")
        let sourceManifestURL = sourceDirectory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: sourceStoreURL.path),
              fileManager.fileExists(atPath: sourceManifestURL.path) else {
            throw DatasetError.missingABPool(sourceDirectory.path)
        }

        let sourceManifest = try JSONDecoder().decode(
            FortyStockManifest.self,
            from: Data(contentsOf: sourceManifestURL)
        )
        guard sourceManifest.poolID == fortyStockPoolID,
              sourceManifest.coverageStatus == "s20-complete",
              sourceManifest.technicalRuleVersion == Technical.technicalRuleVersion,
              sourceManifest.stocks.count == 50,
              sourceManifest.stocks.allSatisfy({ $0.status == "s20-complete" }) else {
            throw DatasetError.invalidABPool(
                "九年分片來源必須是 50 檔、完整 T2/S20 的集中資料池"
            )
        }

        let samples: [Sample] = [.a, .b, .c, .d]
        let destinationURLs = samples.map {
            rootURL.appendingPathComponent($0.nineYearBaselineDirectoryName, isDirectory: true)
        }
        if let existing = destinationURLs.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) {
            throw DatasetError.poolAlreadyExists(existing.path)
        }

        let temporaryRoot = rootURL.appendingPathComponent(
            ".ab-nine-year-shards-building-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        var staged: [(sample: Sample, manifest: PoolManifest)] = []
        for sample in samples {
            let directory = temporaryRoot.appendingPathComponent(
                sample.nineYearBaselineDirectoryName,
                isDirectory: true
            )
            let manifest = try buildNineYearSampleShard(
                sample: sample,
                in: directory,
                sourceStoreURL: sourceStoreURL,
                sourceManifest: sourceManifest
            )
            staged.append((sample, manifest))
        }

        var results: [PoolResult] = []
        for item in staged {
            let stagedURL = temporaryRoot.appendingPathComponent(
                item.sample.nineYearBaselineDirectoryName,
                isDirectory: true
            )
            let destinationURL = rootURL.appendingPathComponent(
                item.sample.nineYearBaselineDirectoryName,
                isDirectory: true
            )
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
            results.append(PoolResult(
                storeURL: destinationURL.appendingPathComponent("baseline.store"),
                manifestURL: destinationURL.appendingPathComponent("manifest.json"),
                manifest: item.manifest
            ))
        }
        return results
    }

    nonisolated private static func buildNineYearSampleShard(
        sample: Sample,
        in directoryURL: URL,
        sourceStoreURL: URL,
        sourceManifest: FortyStockManifest
    ) throws -> PoolManifest {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let stagedSourceURL = directoryURL.appendingPathComponent("source.store")
        try copyPoolSourceStore(from: sourceStoreURL, to: stagedSourceURL)

        let schema = Schema([Stock.self, Trade.self])
        let sourceConfiguration = ModelConfiguration(
            "InternalBacktestABNineYearSource-\(sample.rawValue)",
            schema: schema,
            url: stagedSourceURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let sourceContainer = try ModelContainer(for: schema, configurations: [sourceConfiguration])
        let sourceContext = ModelContext(sourceContainer)
        let sourceStocks = Dictionary(
            uniqueKeysWithValues: try Stock.fetchAll(in: sourceContext).map { ($0.sId, $0) }
        )

        let destinationStoreURL = directoryURL.appendingPathComponent("baseline.store")
        let destinationConfiguration = ModelConfiguration(
            "InternalBacktestABNineYear-\(sample.rawValue)",
            schema: schema,
            url: destinationStoreURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let destinationContainer = try ModelContainer(
            for: schema,
            configurations: [destinationConfiguration]
        )
        var summaries: [PoolStockSummary] = []

        for member in sample.members {
            guard let sourceStock = sourceStocks[member.id],
                  let expected = sourceManifest.stocks.first(where: { $0.id == member.id }) else {
                throw DatasetError.missingPoolStock(member.id)
            }
            let allSourceTrades = try Trade.fetch(
                in: sourceContext,
                for: sourceStock,
                ascending: true
            )
            let sourceFirstTrade = allSourceTrades.first.map {
                twDateTime.stringFromDate($0.dateTime)
            } ?? ""
            let sourceLastTrade = allSourceTrades.last.map {
                twDateTime.stringFromDate($0.dateTime)
            } ?? ""
            guard sourceFirstTrade == expected.firstTrade,
                  sourceLastTrade == expected.lastTrade,
                  allSourceTrades.count == expected.tradeCount,
                  allSourceTrades.filter(\.tUpdated).count == expected.technicalCount else {
                throw DatasetError.poolCopyMismatch("\(member.id) 集中資料池內容與 manifest 不一致")
            }
            let sourceTrades = allSourceTrades.filter {
                $0.dateTime >= abPoolHistoryStart && $0.dateTime <= snapshotThrough
            }
            let destinationContext = ModelContext(destinationContainer)
            let destinationStock = Stock(
                sId: member.id,
                sName: member.name,
                group: member.group,
                dateFirst: abPoolHistoryStart,
                dateStart: abPoolSimulationStart,
                simInvestAuto: 0,
                simMoneyBase: 0
            )
            destinationStock.isListed = sourceStock.isListed
            destinationStock.technicalStateVersion = sourceStock.technicalStateVersion
            destinationStock.simulationStateVersion = 0
            destinationStock.technicalDirtyFrom = sourceStock.technicalDirtyFrom
            destinationStock.simulationDirtyFrom = nil
            destinationContext.insert(destinationStock)
            for sourceTrade in sourceTrades {
                let destinationTrade = Trade(
                    stock: destinationStock,
                    dateTime: sourceTrade.dateTime,
                    dataSource: sourceTrade.dataSource
                )
                copyMarketAndTechnical(from: sourceTrade, to: destinationTrade)
                destinationContext.insert(destinationTrade)
            }
            try destinationContext.save()

            let summary = PoolStockSummary(
                id: member.id,
                name: member.name,
                firstTrade: sourceTrades.first.map {
                    twDateTime.stringFromDate($0.dateTime)
                } ?? "",
                lastTrade: sourceTrades.last.map {
                    twDateTime.stringFromDate($0.dateTime)
                } ?? "",
                tradeCount: sourceTrades.count,
                technicalCount: sourceTrades.filter(\.tUpdated).count
            )
            summaries.append(summary)
        }

        let validationContext = ModelContext(destinationContainer)
        guard try Stock.fetchAll(in: validationContext).count == sample.members.count else {
            throw DatasetError.poolCopyMismatch("Sample \(sample.rawValue) 分片股票數不正確")
        }
        try? fileManager.removeItem(at: stagedSourceURL)
        for suffix in ["-wal", "-shm"] {
            try? fileManager.removeItem(atPath: stagedSourceURL.path + suffix)
        }

        let manifest = PoolManifest(
            poolID: "\(abNineYearProfileID)-sample-\(sample.rawValue.lowercased())",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            historyTargetStart: twDateTime.stringFromDate(abPoolHistoryStart),
            simulationTargetStart: twDateTime.stringFromDate(abPoolSimulationStart),
            through: twDateTime.stringFromDate(snapshotThrough),
            technicalRuleVersion: sourceManifest.technicalRuleVersion,
            simulationStateCopied: false,
            coverageStatus: "complete",
            sources: [PoolSourceSummary(
                sampleID: sample.rawValue,
                storePath: sourceStoreURL.path,
                stockIDs: sample.members.map(\.id)
            )],
            stocks: summaries.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: directoryURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        return manifest
    }

    nonisolated private static func copyPoolSourceStore(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: sourceSidecar.path) else { continue }
            try fileManager.copyItem(
                at: sourceSidecar,
                to: URL(fileURLWithPath: destination.path + suffix)
            )
        }
    }

    nonisolated private static func poolMigrationErrorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        let details = nsError.userInfo
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "; ")
        return "\(String(reflecting: error)) domain=\(nsError.domain) "
            + "code=\(nsError.code) userInfo=[\(details)]"
    }

    nonisolated private static func copyMarketAndTechnical(from source: Trade, to destination: Trade) {
        destination.priceOpen = source.priceOpen
        destination.priceHigh = source.priceHigh
        destination.priceLow = source.priceLow
        destination.priceClose = source.priceClose
        destination.volumeClose = source.volumeClose

        destination.tHighDiff = source.tHighDiff
        destination.tHighDiff125 = source.tHighDiff125
        destination.tHighDiff250 = source.tHighDiff250
        destination.tHighDiffZ125 = source.tHighDiffZ125
        destination.tHighDiffZ250 = source.tHighDiffZ250
        destination.tHighMax9 = source.tHighMax9
        destination.tLowDiff = source.tLowDiff
        destination.tLowDiff125 = source.tLowDiff125
        destination.tLowDiff250 = source.tLowDiff250
        destination.tLowDiffZ125 = source.tLowDiffZ125
        destination.tLowDiffZ250 = source.tLowDiffZ250
        destination.tLowMin9 = source.tLowMin9

        destination.tMa20 = source.tMa20
        destination.tMa20Days = source.tMa20Days
        destination.tMa20Diff = source.tMa20Diff
        destination.tMa20DiffMax9 = source.tMa20DiffMax9
        destination.tMa20DiffMin9 = source.tMa20DiffMin9
        destination.tMa20DiffZ125 = source.tMa20DiffZ125
        destination.tMa20DiffZ250 = source.tMa20DiffZ250
        destination.tMa60 = source.tMa60
        destination.tMa60Days = source.tMa60Days
        destination.tMa60Diff = source.tMa60Diff
        destination.tMa60DiffMax9 = source.tMa60DiffMax9
        destination.tMa60DiffMin9 = source.tMa60DiffMin9
        destination.tMa60DiffZ125 = source.tMa60DiffZ125
        destination.tMa60DiffZ250 = source.tMa60DiffZ250
        destination.tZ125 = source.tZ125
        destination.tZ250 = source.tZ250

        destination.tKdK = source.tKdK
        destination.tKdKMax9 = source.tKdKMax9
        destination.tKdKMin9 = source.tKdKMin9
        destination.tKdKZ125 = source.tKdKZ125
        destination.tKdKZ250 = source.tKdKZ250
        destination.tKdD = source.tKdD
        destination.tKdDZ125 = source.tKdDZ125
        destination.tKdDZ250 = source.tKdDZ250
        destination.tKdJ = source.tKdJ
        destination.tKdJZ125 = source.tKdJZ125
        destination.tKdJZ250 = source.tKdJZ250

        destination.tOsc = source.tOsc
        destination.tOscEma12 = source.tOscEma12
        destination.tOscEma26 = source.tOscEma26
        destination.tOscMacd9 = source.tOscMacd9
        destination.tOscMax9 = source.tOscMax9
        destination.tOscMin9 = source.tOscMin9
        destination.tOscZ125 = source.tOscZ125
        destination.tOscZ250 = source.tOscZ250

        destination.vMa20 = source.vMa20
        destination.vMa20Days = source.vMa20Days
        destination.vMa20Diff = source.vMa20Diff
        destination.vMa20DiffMax9 = source.vMa20DiffMax9
        destination.vMa20DiffMin9 = source.vMa20DiffMin9
        destination.vMa20DiffZ125 = source.vMa20DiffZ125
        destination.vMa20DiffZ250 = source.vMa20DiffZ250
        destination.vMa60 = source.vMa60
        destination.vMa60Days = source.vMa60Days
        destination.vMa60Diff = source.vMa60Diff
        destination.vMa60DiffMax9 = source.vMa60DiffMax9
        destination.vMa60DiffMin9 = source.vMa60DiffMin9
        destination.vMa60DiffZ125 = source.vMa60DiffZ125
        destination.vMa60DiffZ250 = source.vMa60DiffZ250
        destination.vMax9 = source.vMax9
        destination.vMin9 = source.vMin9
        destination.vZ125 = source.vZ125
        destination.vZ250 = source.vZ250
        destination.tUpdated = source.tUpdated
    }

    nonisolated static func prepareDocumentationScreenshotStore(
        sourceStoreURL: URL,
        destinationStoreURL: URL
    ) throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceStoreURL.path) else {
            throw DatasetError.missingPoolSource(sourceStoreURL.path)
        }

        let directoryURL = destinationStoreURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        for url in [destinationStoreURL, URL(fileURLWithPath: destinationStoreURL.path + "-wal"), URL(fileURLWithPath: destinationStoreURL.path + "-shm")] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let stagedSourceURL = directoryURL.appendingPathComponent("source.store")
        for url in [stagedSourceURL, URL(fileURLWithPath: stagedSourceURL.path + "-wal"), URL(fileURLWithPath: stagedSourceURL.path + "-shm")] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try copyPoolSourceStore(from: sourceStoreURL, to: stagedSourceURL)

        let schema = Schema([Stock.self, Trade.self])
        let sourceConfiguration = ModelConfiguration(
            "DocumentationScreenshotSource",
            schema: schema,
            url: stagedSourceURL,
            allowsSave: false,
            cloudKitDatabase: .none
        )
        let sourceContainer = try ModelContainer(for: schema, configurations: [sourceConfiguration])
        let sourceContext = ModelContext(sourceContainer)
        let sourceStocks = Dictionary(
            uniqueKeysWithValues: try Stock.fetchAll(in: sourceContext).map { ($0.sId, $0) }
        )

        let destinationConfiguration = ModelConfiguration(
            "DocumentationScreenshotSeed",
            schema: schema,
            url: destinationStoreURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let destinationContainer = try ModelContainer(
            for: schema,
            configurations: [destinationConfiguration]
        )
        let destinationContext = ModelContext(destinationContainer)

        for member in documentationScreenshotMembers {
            guard let sourceStock = sourceStocks[member.id] else {
                throw DatasetError.missingPoolStock(member.id)
            }
            let destinationStock = Stock(
                sId: member.id,
                sName: member.name,
                group: member.group,
                dateFirst: sourceStock.dateFirst,
                dateStart: sourceStock.dateStart,
                simInvestAuto: sourceStock.simInvestAuto,
                simMoneyBase: sourceStock.simMoneyBase
            )
            destinationStock.isListed = sourceStock.isListed
            destinationStock.technicalStateVersion = sourceStock.technicalStateVersion
            destinationStock.simulationStateVersion = 0
            destinationStock.technicalDirtyFrom = sourceStock.technicalDirtyFrom
            destinationStock.simulationDirtyFrom = sourceStock.dateStart
            destinationContext.insert(destinationStock)

            let sourceTrades = try Trade.fetch(
                in: sourceContext,
                for: sourceStock,
                ascending: true
            ).filter { $0.dateTime <= snapshotThrough }
            for sourceTrade in sourceTrades {
                let destinationTrade = Trade(
                    stock: destinationStock,
                    dateTime: sourceTrade.dateTime,
                    dataSource: sourceTrade.dataSource
                )
                copyMarketAndTechnical(from: sourceTrade, to: destinationTrade)
                destinationContext.insert(destinationTrade)
            }
        }
        try destinationContext.save()

        let count = try Stock.fetchAll(in: destinationContext).count
        guard count == documentationScreenshotMembers.count else {
            throw DatasetError.poolCopyMismatch("文件截圖資料庫股票數不正確：\(count)")
        }
        return count
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
        if sample == .c && !sampleCExecutionIsUnlocked() {
            throw DatasetError.sampleCLockedUntilFinalValidation
        }
        return try await prepare(
            in: directoryURL,
            reset: reset,
            members: sample.members,
            sampleID: sample.rawValue,
            through: endDate,
            requestDelay: requestDelay,
            progress: progress
        )
    }

    static func prepareEvaluation(
        in directoryURL: URL,
        reset: Bool,
        configuration: EvaluationConfiguration,
        through endDate: Date,
        requestDelay: Duration = .milliseconds(750),
        progress: (String) -> Void = { _ in }
    ) async throws -> Result {
        guard !configuration.members.isEmpty,
              configuration.members.count <= 20 else {
            throw DatasetError.invalidEvaluationConfiguration("研究池成員數不合法")
        }
        return try await prepare(
            in: directoryURL,
            reset: reset,
            members: configuration.members,
            sampleID: "C-EVAL-\(configuration.id)",
            through: endDate,
            requestDelay: requestDelay,
            progress: progress
        )
    }

    private static func prepare(
        in directoryURL: URL,
        reset: Bool,
        members: [Member],
        sampleID: String,
        through endDate: Date,
        requestDelay: Duration,
        progress: (String) -> Void
    ) async throws -> Result {
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

        let configuredIDs = Set(members.map(\.id))
        for stock in try Stock.fetchAll(in: context) where !configuredIDs.contains(stock.sId) {
            context.delete(stock)
        }
        try context.save()

        var stocks: [Stock] = []
        for member in members {
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
            sampleID: sampleID,
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
