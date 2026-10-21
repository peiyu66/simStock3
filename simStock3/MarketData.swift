import Foundation
import SwiftData

/// 加權指數的日資料；Yahoo 當日暫時行情最後由 TWSE 正式日資料取代。
@Model
final class MarketDay {
    @Attribute(.unique) var dateTime: Date
    var dataSource: String
    var quoteTime: Date? = nil
    var indexOpen: Double
    var indexHigh: Double
    var indexLow: Double
    var indexClose: Double
    // Nil distinguishes a legacy/uncomputed row from a valid partial window.
    var indexHighMax9: Double? = nil
    var indexLowMin9: Double? = nil
    // Market technical v3: nil is legacy/uncomputed, never a valid zero.
    // Market technical v4; nil is legacy/uncomputed.
    var indexHighDiff250: Double? = nil
    // Market v6: S-E02 decision values; raw OHLC supplies bounded continuation.
    var indexLowDiffZ125: Double? = nil
    var ma20DiffMax9: Double? = nil
    // Market v5: nil means not rebuilt. EMA fields support isolated intraday trials.
    var indexHighDiffZ250: Double? = nil // Legacy 250 x 250; not used by current rules.
    var indexHighDiffZ125: Double? = nil
    var oscZ125: Double? = nil
    var oscEMA12: Double? = nil
    var oscEMA26: Double? = nil
    var oscMACD9: Double? = nil
    var kdK: Double? = nil
    var kdD: Double? = nil
    var kdJZ250: Double? = nil
    var priceObservationCount: Int? = nil
    var pricePathPhaseRaw: Int
    var pricePathBarrier: Double?
    var pricePathAnchorClose: Double?
    var pricePathExtremeClose: Double?
    var pricePathDaysSinceExtreme: Int
    var technicalStateVersion: Int

    init(
        dateTime: Date,
        dataSource: String = "TWSE-MI_5MINS_HIST",
        indexOpen: Double,
        indexHigh: Double,
        indexLow: Double,
        indexClose: Double
    ) {
        self.dateTime = twDateTime.time1330(dateTime)
        self.dataSource = dataSource
        self.indexOpen = indexOpen
        self.indexHigh = indexHigh
        self.indexLow = indexLow
        self.indexClose = indexClose
        self.pricePathPhaseRaw = PricePathPhase.unavailable.rawValue
        self.pricePathBarrier = nil
        self.pricePathAnchorClose = nil
        self.pricePathExtremeClose = nil
        self.pricePathDaysSinceExtreme = 0
        self.technicalStateVersion = 0
    }

    var pricePathPhase: PricePathPhase {
        get { PricePathPhase(rawValue: pricePathPhaseRaw) ?? .unavailable }
        set { pricePathPhaseRaw = newValue.rawValue }
    }

    var hasCurrentTechnicalValues: Bool {
        guard hasUsableRawValues, technicalStateVersion == MarketDataStore.technicalStateVersion,
              let high = indexHighMax9, let low = indexLowMin9,
              let k = kdK, let d = kdD, let z = kdJZ250,
              let highDiff = indexHighDiff250, highDiff.isFinite,
              let lowZ = indexLowDiffZ125, let maMax = ma20DiffMax9,
              let highZ = indexHighDiffZ125, let oscZ = oscZ125,
              let ema12 = oscEMA12, let ema26 = oscEMA26, let macd9 = oscMACD9,
              [highZ, oscZ, ema12, ema26, macd9, lowZ, maMax].allSatisfy({ $0.isFinite }),
              let count = priceObservationCount, (1...250).contains(count),
              k.isFinite, d.isFinite, z.isFinite else { return false }
        return (count < 41 ? pricePathPhase == .unavailable : storedPricePathState != nil)
            && high.isFinite && low.isFinite && low > 0
            && high >= indexHigh && low <= indexLow
    }

    var isOfficial: Bool { dataSource == "TWSE-MI_5MINS_HIST" }

    var storedPricePathState: PricePathStoredState? {
        guard pricePathPhase != .unavailable,
              let barrier = pricePathBarrier,
              let anchorClose = pricePathAnchorClose,
              let extremeClose = pricePathExtremeClose,
              barrier.isFinite,
              barrier >= RollingPricePathClassifier.minimumBarrier,
              barrier <= RollingPricePathClassifier.maximumBarrier,
              anchorClose.isFinite,
              anchorClose > 0,
              extremeClose.isFinite,
              extremeClose > 0,
              (0..<250).contains(pricePathDaysSinceExtreme) else {
            return nil
        }
        return PricePathStoredState(
            phase: pricePathPhase,
            barrier: barrier,
            anchorClose: anchorClose,
            extremeClose: extremeClose,
            daysSinceExtreme: pricePathDaysSinceExtreme
        )
    }

    func applyPricePathState(_ state: PricePathStoredState?) {
        guard let state else {
            pricePathPhase = .unavailable
            pricePathBarrier = nil
            pricePathAnchorClose = nil
            pricePathExtremeClose = nil
            pricePathDaysSinceExtreme = 0
            return
        }
        pricePathPhase = state.phase
        pricePathBarrier = state.barrier
        pricePathAnchorClose = state.anchorClose
        pricePathExtremeClose = state.extremeClose
        pricePathDaysSinceExtreme = state.daysSinceExtreme
    }

    @MainActor
    static func fetchAll(in context: ModelContext) throws -> [MarketDay] {
        try context.fetch(
            FetchDescriptor<MarketDay>(
                sortBy: [SortDescriptor(\.dateTime, order: .forward)]
            )
        )
    }

    /// Same-day UI comparison. Like S55 strategy lookup, missing data stays
    /// missing instead of falling back to a different market day.
    @MainActor
    static func fetchSameDay(
        as date: Date,
        in context: ModelContext
    ) throws -> MarketDay? {
        let target = twDateTime.time1330(date)
        var descriptor = FetchDescriptor<MarketDay>(
            predicate: #Predicate { $0.dateTime == target }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

/// Research input, separate from strategy votes and the same-day UI lookup.
/// Build from the complete, frozen market history before slicing stock windows.
struct MarketIndexExtremaLookup: Sendable {
    struct Observation: Codable, Equatable, Sendable {
        let date: Date
        let indexClose: Double
        let indexHighMax9: Double
        let indexLowMin9: Double
        let observationCount: Int
    }

    let observations: [Observation]

    @MainActor
    init(modelContext: ModelContext) throws {
        let days = try MarketDay.fetchAll(in: modelContext).filter(\.isOfficial)
        guard days.allSatisfy(\.hasCurrentTechnicalValues) else {
            throw MarketDataStore.DataError.invalidResponse("大盤技術值尚未完成重建")
        }
        observations = days.enumerated().map { index, day in
            Observation(
                date: day.dateTime,
                indexClose: day.indexClose,
                indexHighMax9: day.indexHighMax9!,
                indexLowMin9: day.indexLowMin9!,
                observationCount: min(index + 1, 9)
            )
        }
    }

    func observation(before decisionDate: Date) -> Observation? {
        // Exclude the entire decision day, including queries made after 13:30.
        let cutoff = twDateTime.startOfDay(decisionDate)
        var lower = 0
        var upper = observations.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if observations[middle].date < cutoff {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? observations[lower - 1] : nil
    }
}

struct MarketPricePathLookup: Equatable, Sendable {
    struct Observation: Equatable, Sendable {
        let date: Date
        let isOfficial: Bool
        let quoteTime: Date?
        let phase: PricePathPhase
        let indexLow: Double?
        let indexLowMin9: Double?
        let indexHigh: Double?
        let indexHighMax9: Double?
        let indexLowDiffZ125: Double?
        let ma20DiffMax9: Double?
        let indexHighDiffZ250: Double?
        let indexHighDiffZ125: Double?
        let oscZ125: Double?
        let indexHighDiff250: Double?
        let kdJZ250: Double?
        let priceObservationCount: Int

        init(date: Date, phase: PricePathPhase, isOfficial: Bool = true, quoteTime: Date? = nil, indexLow: Double? = nil, indexLowMin9: Double? = nil,
             indexHigh: Double? = nil, indexHighMax9: Double? = nil,
             indexLowDiffZ125: Double? = nil, ma20DiffMax9: Double? = nil,
             indexHighDiffZ250: Double? = nil, indexHighDiffZ125: Double? = nil, oscZ125: Double? = nil,
             indexHighDiff250: Double? = nil, kdJZ250: Double? = nil, priceObservationCount: Int = 0) {
            self.date = date
            self.isOfficial = isOfficial
            self.quoteTime = quoteTime
            self.phase = phase
            self.indexLow = indexLow
            self.indexLowMin9 = indexLowMin9
            self.indexHigh = indexHigh
            self.indexHighMax9 = indexHighMax9
            self.indexLowDiffZ125 = indexLowDiffZ125
            self.ma20DiffMax9 = ma20DiffMax9
            self.indexHighDiffZ250 = indexHighDiffZ250
            self.indexHighDiffZ125 = indexHighDiffZ125
            self.oscZ125 = oscZ125
            self.indexHighDiff250 = indexHighDiff250
            self.kdJZ250 = kdJZ250
            self.priceObservationCount = priceObservationCount
        }
    }

    private(set) var observations: [Observation] = []

    init(observations: [Observation] = []) {
        self.observations = observations.sorted { $0.date < $1.date }
    }

    @MainActor
    init(modelContext: ModelContext) throws {
        self.init(observations: try MarketDay.fetchAll(in: modelContext).filter(\.hasCurrentTechnicalValues).map {
            Observation(date: $0.dateTime, phase: $0.pricePathPhase, isOfficial: $0.isOfficial, quoteTime: $0.quoteTime,
                        indexLow: $0.indexLow,
                        indexLowMin9: $0.hasCurrentTechnicalValues ? $0.indexLowMin9 : nil,
                        indexHigh: $0.indexHigh,
                        indexHighMax9: $0.hasCurrentTechnicalValues ? $0.indexHighMax9 : nil,
                        indexLowDiffZ125: $0.indexLowDiffZ125, ma20DiffMax9: $0.ma20DiffMax9,
                        indexHighDiffZ125: $0.indexHighDiffZ125, oscZ125: $0.oscZ125,
                        indexHighDiff250: $0.indexHighDiff250, kdJZ250: $0.kdJZ250, priceObservationCount: $0.priceObservationCount ?? 0)
        })
    }

    /// S55：只讀同一市場交易日，盤中列使用該次 Yahoo 快照的完整滾動值。
    /// 正式歷史以同日收盤重播；缺日不以前日或未來日補位。
    func observation(on decisionDate: Date) -> Observation? {
        let target = twDateTime.startOfDay(decisionDate)
        var lower = 0
        var upper = observations.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if twDateTime.startOfDay(observations[middle].date) < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < observations.count,
              twDateTime.startOfDay(observations[lower].date) == target else { return nil }
        return observations[lower]
    }

    /// Only the explicitly supplied live day may borrow the previous official state.
    /// Historical replay always keeps exact-day semantics. Never clone a MarketDay.
    func liveObservation(on decisionDate: Date, asOf now: Date, previousTradingDay: Date) -> Observation? {
        guard twDateTime.startOfDay(decisionDate) == twDateTime.startOfDay(now) else {
            return observation(on: decisionDate)
        }
        if let current = observation(on: decisionDate),
           current.isOfficial || (current.quoteTime.map { $0 <= now.addingTimeInterval(300) } ?? false) {
            return current
        }
        guard let previous = observation(on: previousTradingDay), previous.isOfficial,
              twDateTime.startOfDay(previous.date) < twDateTime.startOfDay(now) else { return nil }
        return previous
    }

    static func oscillatorDelta(current: Observation?, previous: Observation?, decisionDate: Date) -> Double {
        guard let current, let previous,
              twDateTime.startOfDay(current.date) == twDateTime.startOfDay(decisionDate),
              current.date > previous.date,
              let currentValue = current.oscZ125, let previousValue = previous.oscZ125 else { return .nan }
        return currentValue - previousValue
    }

    func phase(on decisionDate: Date) -> PricePathPhase? {
        observation(on: decisionDate)?.phase
    }

    /// Legacy reference lookup for tests of historical rules; S55 uses on:.
    func phase(before decisionDate: Date) -> PricePathPhase? {
        observation(before: decisionDate)?.phase
    }

    func observation(before decisionDate: Date) -> Observation? {
        let cutoff = twDateTime.startOfDay(decisionDate)
        var lower = 0
        var upper = observations.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if observations[middle].date < cutoff {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        return observations[lower - 1]
    }

    var firstDate: Date? { observations.first?.date }
    var lastDate: Date? { observations.last?.date }
}

enum MarketHigh9BuyRule {
    static func suppressesVote(market: MarketPricePathLookup.Observation?, grade: Trade.Grade,
                               decisionPhase: StrategyFitTrendPhase) -> Bool {
        guard grade >= .fine, decisionPhase != .neutral,
              let market, market.phase != .seekingPeakEarly,
              let high = market.indexHigh, let high9 = market.indexHighMax9,
              high.isFinite, high9.isFinite, high > 0 else { return false }
        return high == high9
    }
}

enum MarketPricePathSellRule {
    static let ruleID = "S-P08"

    static func contribution(
        marketPhase: PricePathPhase?,
        stockPhase: PricePathPhase,
        grade: Trade.Grade
    ) -> Double {
        marketPhase == .seekingPeakLate
            && stockPhase == .seekingPeakLate
            && grade >= .high
            ? 1
            : 0
    }
}

/// S-N01a/b 已扣分時不再加票；三個分支合計最多扣一分。
enum MarketLow9SellRule {
    static let ruleID = "S-N01c"

    static func contribution(originalMatched: Bool, market: MarketPricePathLookup.Observation?,
                             stockPhase: PricePathPhase, grade: Trade.Grade) -> Double {
        guard !originalMatched, grade != .none, grade < .wow,
              !(stockPhase == .seekingPeakLate && grade >= .fine),
              let low = market?.indexLow, let low9 = market?.indexLowMin9,
              low.isFinite, low9.isFinite, low > 0, low == low9 else { return 0 }
        return -1
    }
}

@MainActor
final class MarketDataStore {
    nonisolated static let technicalStateVersion = 7
    // Negative current version means an exact, already expanded pending row.
    // Zero/other versions remain unknown work and get conservative coverage.
    nonisolated static let pendingTechnicalStateVersion = -technicalStateVersion
    static let earliestSupportedMonth = twDateTime.startOfMonth(
        twDateTime.dateFromString("2010/01/01")!
    )

    struct Record: Equatable, Sendable {
        let date: Date
        let open: Double
        let high: Double
        let low: Double
        let close: Double
    }

    /// Yahoo 的時間是行情時間；不能把快取的前日頁面當成今日資料。
    static func parseYahooQuote(_ html: String, asOf now: Date) throws -> Record {
        let pattern = #"<time\s+(?:datatime|datetime)="([^"]+)""#
        guard html.contains("<title>加權指數(^TWII)"),
              let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let timestamp = twDateTime.dateFromString(String(html[range]), format: "yyyy/MM/dd HH:mm"),
              twDateTime.startOfDay(timestamp) == twDateTime.startOfDay(now),
              timestamp <= now.addingTimeInterval(300),
              let open = YahooValueParser.labeledValue("開盤", inHTML: html).flatMap({ YahooValueParser.price($0) }),
              let high = YahooValueParser.labeledValue("最高", inHTML: html).flatMap({ YahooValueParser.price($0) }),
              let low = YahooValueParser.labeledValue("最低", inHTML: html).flatMap({ YahooValueParser.price($0) }),
              let close = YahooValueParser.labeledValue("成交", inHTML: html).flatMap({ YahooValueParser.price($0) }),
              high >= max(open, close), low <= min(open, close) else {
            throw DataError.invalidResponse("Yahoo 當日時間或開高低成交指數無效")
        }
        return Record(date: timestamp, open: open, high: high, low: low, close: close)
    }

    func updateYahooQuote(asOf now: Date = Date()) async throws -> Bool {
        if try MarketDay.fetchSameDay(as: now, in: context)?.isOfficial == true { return false }
        let url = URL(string: "https://tw.stock.yahoo.com/quote/%5ETWII")!
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw DataError.invalidResponse("Yahoo HTTP 回應無效")
        }
        return try applyYahooQuote(Self.parseYahooQuote(html, asOf: now), asOf: now)
    }

    /// 每次從昨日正式前態重新試算，不能讓同日更新累加極值日數。
    @discardableResult
    func applyYahooQuote(_ record: Record, asOf now: Date) throws -> Bool {
        guard twDateTime.startOfDay(record.date) == twDateTime.startOfDay(now),
              record.date <= now.addingTimeInterval(300),
              [record.open, record.high, record.low, record.close].allSatisfy({ $0.isFinite && $0 > 0 }),
              record.high >= max(record.open, record.close),
              record.low <= min(record.open, record.close) else {
            throw DataError.invalidResponse("Yahoo 當日資料無效")
        }
        let existing = try MarketDay.fetchSameDay(as: record.date, in: context)
        if let existing {
            if existing.isOfficial { return false }
            if let quoteTime = existing.quoteTime, record.date < quoteTime { return false }
            if existing.quoteTime == record.date,
               existing.indexOpen == record.open, existing.indexHigh == record.high,
               existing.indexLow == record.low, existing.indexClose == record.close,
               existing.hasCurrentTechnicalValues { return false }
        }
        let cutoff = twDateTime.startOfDay(record.date)
        let prior = try MarketDay.fetchAll(in: context).filter {
            $0.dateTime < cutoff && $0.isOfficial && $0.hasUsableRawValues
        }.suffix(249)
        guard !prior.isEmpty else {
            throw DataError.invalidResponse("大盤正式原始前態尚未取得")
        }
        advanceLookupEpoch()
        defer { advanceLookupEpoch() }
        let day = existing ?? MarketDay(dateTime: record.date, dataSource: "Yahoo",
            indexOpen: record.open, indexHigh: record.high, indexLow: record.low, indexClose: record.close)
        if existing == nil { context.insert(day) }
        day.dataSource = "Yahoo"; day.quoteTime = record.date
        day.indexOpen = record.open; day.indexHigh = record.high
        day.indexLow = record.low; day.indexClose = record.close
        day.technicalStateVersion = Self.pendingTechnicalStateVersion
        try RecalculationInvalidation.marketTechnical(writes: [day.dateTime], in: context)
        try saveTechnicalState()
        var completed = false
        defer { if !completed { day.technicalStateVersion = Self.pendingTechnicalStateVersion } }
        var rolling = BoundedMarketTechnicalContext(priorPoints: prior.map(\.boundedRawPoint))
        guard let value = rolling.update(day.boundedRawPoint) else {
            throw DataError.invalidResponse("大盤當日有界技術值無法計算")
        }
        day.applyBoundedTechnicalValue(value)
        day.technicalStateVersion = Self.technicalStateVersion
        try saveTechnicalState()
        completed = true
        return true
    }

    struct UpdateSummary {
        var requestedMonths = 0
        var failedMonths = 0
        var remainingHistoryMonths = 0
        var remainingRecentMonths = 0
        var reachedBatchLimit = false
        var nextForwardMonth: Date?
        var insertedOrUpdatedDays = 0
        var isInputComplete = false
        var requiresTechnicalRebuild = false
        var isReadyForSimulation = false
        var firstDate: Date?
        var lastDate: Date?

        var statusText: String {
            if !isReadyForSimulation {
                if failedMonths > 0 {
                    return "大盤更新失敗 \(failedMonths) 個月份"
                }
                if remainingRecentMonths > 0 {
                    return "大盤近期尚待補 \(remainingRecentMonths) 個月份"
                }
                if remainingHistoryMonths == 0 {
                    return isInputComplete
                        ? "大盤等待統一重算"
                        : "大盤等待最近收盤資料"
                }
                return "大盤尚待補 \(remainingHistoryMonths) 個月份"
            }
            if insertedOrUpdatedDays > 0 {
                return "大盤更新 \(insertedOrUpdatedDays) 日"
            }
            return "大盤已是最新"
        }
    }

    enum DataError: LocalizedError {
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let detail): "大盤資料格式無效：\(detail)"
            }
        }
    }

    private let context: ModelContext
    private let session: URLSession
    private var requestInterval: TimeInterval = 1.5
    private let retryDelays: [TimeInterval]

    init(modelContext: ModelContext, session: URLSession = .shared, retryDelays: [TimeInterval] = [15, 30, 60]) {
        self.context = modelContext
        self.session = session
        self.retryDelays = retryDelays
    }

    static func requiredStartMonth(for stocks: [Stock]) -> Date? {
        stocks
            .filter { !$0.group.isEmpty }
            .map(\.requiredTWSEHistoryStartMonth)
            .min()
            .map { max(earliestSupportedMonth, $0) }
    }

    static func parseMonth(_ data: Data, expectedMonth: Date, cutoff: Date) throws -> [Record] {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["stat"] as? String == "OK",
              let fields = payload["fields"] as? [String],
              fields == ["日期", "開盤指數", "最高指數", "最低指數", "收盤指數"],
              let rows = payload["data"] as? [[String]] else {
            throw DataError.invalidResponse("stat、fields 或 data 不符")
        }

        let expectedMonthText = twDateTime.stringFromDate(expectedMonth, format: "yyyy-MM")
        var result: [Record] = []
        var seenDates: Set<Date> = []
        for (offset, row) in rows.enumerated() {
            guard row.count == 5 else {
                throw DataError.invalidResponse("第 \(offset + 1) 列欄位數不符")
            }
            let parts = row[0].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
            guard parts.count == 3,
                  let rocYear = Int(parts[0]),
                  let date = twDateTime.dateFromString("\(rocYear + 1911)/\(parts[1])/\(parts[2])"),
                  twDateTime.stringFromDate(date, format: "yyyy-MM") == expectedMonthText else {
                throw DataError.invalidResponse("第 \(offset + 1) 列日期無效")
            }
            if date > cutoff { continue }

            func number(_ index: Int) -> Double? {
                Double(
                    row[index]
                        .replacingOccurrences(of: ",", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard let open = number(1), let high = number(2),
                  let low = number(3), let close = number(4),
                  open.isFinite, high.isFinite, low.isFinite, close.isFinite,
                  open > 0, high >= max(open, close), low <= min(open, close), low > 0,
                  !seenDates.contains(date) else {
                throw DataError.invalidResponse("第 \(offset + 1) 列價格或重複日期無效")
            }
            seenDates.insert(date)
            result.append(Record(date: date, open: open, high: high, low: low, close: close))
        }
        guard !result.isEmpty else {
            throw DataError.invalidResponse("月份沒有截止日前的交易資料")
        }
        return result.sorted { $0.date < $1.date }
    }

    // Ephemeral lookup cache invalidation, scoped to this model container.
    // Durable validity remains the per-row technical version and stock S dirty.
    private static let lookupEpochs = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()
    static func lookupEpoch(in context: ModelContext) -> UInt64 {
        lookupEpochs.object(forKey: context.container)?.uint64Value ?? 0
    }
    private func advanceLookupEpoch() {
        Self.lookupEpochs.setObject(NSNumber(value: Self.lookupEpoch(in: context) &+ 1), forKey: context.container)
    }

    private(set) var lastTechnicalWriteDates: [Date] = []
    // Isolated failure fixtures use the same transaction seam as stock replay.
    var technicalSave: (() throws -> Void)?
    private func saveTechnicalState() throws {
        if let technicalSave { try technicalSave() } else { try context.save() }
    }

    /// Include unknown work before converting any rows to the already-expanded
    /// marker. A later raw batch must not erase an earlier unknown origin.
    private func pendingTechnicalDates(in days: [MarketDay], changedDates: [Date] = []) -> Set<Date> {
        let officialDates = days.filter { $0.isOfficial && $0.hasUsableRawValues }.map(\.dateTime)
        var count = 0
        var unknown = changedDates
        var staleCounts: Set<Date> = []
        for day in days {
            if day.hasUsableRawValues && day.isOfficial { count += 1 }
            let expected = min(count + (day.isOfficial ? 0 : 1), 250)
            if day.technicalStateVersion != Self.pendingTechnicalStateVersion {
                if !day.hasCurrentTechnicalValues { unknown.append(day.dateTime) }
                else if day.priceObservationCount != expected {
                    // A changed prefix count identifies this affected target,
                    // not a new raw correction to expand another 249 rows.
                    staleCounts.insert(day.dateTime)
                }
            }
        }
        let known = Set(days.filter { $0.technicalStateVersion == Self.pendingTechnicalStateVersion }.map(\.dateTime))
        return known.union(staleCounts).union(MarketTechnicalCoverage.affected(
            targetDates: days.map(\.dateTime), officialDates: officialDates, changedDates: unknown))
    }

    func rebuildPricePath(force: Bool = false) throws {
        let days = try MarketDay.fetchAll(in: context)
        let pending = force ? Set(days.map(\.dateTime)) : pendingTechnicalDates(in: days)
        let targets = days.filter { pending.contains($0.dateTime) }
        lastTechnicalWriteDates = []
        guard !targets.isEmpty else { return }
        advanceLookupEpoch()
        defer { advanceLookupEpoch() }
        for day in targets { day.technicalStateVersion = Self.pendingTechnicalStateVersion }
        try RecalculationInvalidation.marketTechnical(writes: targets.map(\.dateTime), in: context)
        try saveTechnicalState()
        var completed = false
        defer { if !completed { for day in targets { day.technicalStateVersion = Self.pendingTechnicalStateVersion } } }
        var prior: [BoundedMarketTechnicalContext.Point] = []
        for day in days {
            if pending.contains(day.dateTime), day.hasUsableRawValues {
                var rolling = BoundedMarketTechnicalContext(priorPoints: prior)
                if let value = rolling.update(day.boundedRawPoint) {
                    day.applyBoundedTechnicalValue(value)
                    day.technicalStateVersion = Self.technicalStateVersion
                    lastTechnicalWriteDates.append(day.dateTime)
                }
            }
            if day.isOfficial && day.hasUsableRawValues {
                prior.append(day.boundedRawPoint)
                if prior.count > 249 { prior.removeFirst(prior.count - 249) }
            }
        }
        try saveTechnicalState()
        completed = true
    }

    struct InputPlan {
        let floorMonth: Date
        let cutoff: Date
        let targetMonth: Date
        let forwardMonths: Set<Date>
        let months: [Date]
        let requiresTechnicalRebuild: Bool

        var hasWork: Bool { !months.isEmpty || requiresTechnicalRebuild }
    }

    func inputPlan(stocks: [Stock], through completedTradingDay: Date?,
                   forwardStartMonth: Date? = nil,
                   readSession: OfficialPriceReadSession? = nil) -> InputPlan? {
        guard let floorMonth = Self.requiredStartMonth(for: stocks),
              let completedTradingDay else {
            return nil
        }

        let cutoff = twDateTime.startOfDay(completedTradingDay)
        let targetMonth = twDateTime.startOfMonth(cutoff)
        let days = (try? (readSession?.marketDays() ?? MarketDay.fetchAll(in: context))) ?? []

        func monthRange(from first: Date, through last: Date) -> [Date] {
            guard first <= last else { return [] }
            var months: [Date] = []
            var value = twDateTime.startOfMonth(first)
            while value <= last {
                months.append(value)
                guard let next = twDateTime.calendar.date(byAdding: .month, value: 1, to: value) else { break }
                value = twDateTime.startOfMonth(next)
            }
            return months
        }

        var requestMonths: [Date] = []
        if let latest = days.last(where: \.isOfficial)?.dateTime {
            if twDateTime.startOfDay(latest) < cutoff {
                requestMonths += monthRange(
                    from: forwardStartMonth ?? twDateTime.startOfMonth(latest),
                    through: targetMonth
                )
            }
        } else {
            requestMonths += monthRange(from: forwardStartMonth ?? targetMonth, through: targetMonth)
        }

        let forwardMonths = Set(requestMonths)
        let earliestMonth = days.first.map { twDateTime.startOfMonth($0.dateTime) } ?? targetMonth
        if earliestMonth > floorMonth {
            let historyEnd = twDateTime.calendar.date(byAdding: .month, value: -1, to: earliestMonth)
                .map(twDateTime.startOfMonth)
            if let historyEnd {
                let allHistory = monthRange(from: floorMonth, through: historyEnd)
                requestMonths += allHistory.reversed()
            }
        }

        var uniqueMonths: [Date] = []
        for month in requestMonths where !uniqueMonths.contains(month) {
            uniqueMonths.append(month)
        }

        return InputPlan(floorMonth: floorMonth, cutoff: cutoff, targetMonth: targetMonth,
                         forwardMonths: forwardMonths, months: uniqueMonths,
                         requiresTechnicalRebuild: days.contains { !$0.hasCurrentTechnicalValues })
    }

    func update(
        stocks: [Stock],
        through completedTradingDay: Date?,
        maximumHistoryMonths: Int = 6,
        forwardStartMonth: Date? = nil,
        readSession: OfficialPriceReadSession? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async -> UpdateSummary {
        guard let plan = inputPlan(stocks: stocks, through: completedTradingDay,
                                   forwardStartMonth: forwardStartMonth, readSession: readSession) else { return UpdateSummary() }
        var summary = UpdateSummary()
        requestInterval = 1.5
        let floorMonth = plan.floorMonth
        let cutoff = plan.cutoff
        let targetMonth = plan.targetMonth
        let forwardMonths = plan.forwardMonths
        let uniqueMonths = plan.months
        var completedForwardMonths: Set<Date> = []
        let batchMonths = Array(uniqueMonths.prefix(maximumHistoryMonths))
        summary.reachedBatchLimit = uniqueMonths.count > batchMonths.count
        for (index, month) in batchMonths.enumerated() {
            if Task.isCancelled { break }
            let monthText = twDateTime.stringFromDate(month, format: "yyyy/MM")
            onProgress?("大盤 補齊歷史指數 \(monthText)"
                + OperationProgress.monthDetail(position: index + 1, total: batchMonths.count))
            summary.requestedMonths += 1
            do {
                let records = try await requestMonthWithLimitedRetry(month, cutoff: cutoff)
                summary.insertedOrUpdatedDays += try applyOfficialRecords(records, readSession: readSession)
                if forwardMonths.contains(month) {
                    completedForwardMonths.insert(month)
                    summary.nextForwardMonth = twDateTime.calendar.date(byAdding: .month, value: 1, to: month)
                }
            } catch {
                summary.failedMonths += 1
                simLog.addLog("大盤 \(monthText) 更新失敗：\(error)")
                // Forward months are requested oldest-to-newest and history months
                // newest-to-oldest. Stop at the first failed month so the stored
                // interval stays contiguous and the same boundary is retried next time.
                break
            }
            // Keep the same spacing before the next source or a continued batch.
            try? await Task.sleep(for: .seconds(requestInterval))
        }

        summary.remainingRecentMonths = forwardMonths.subtracting(completedForwardMonths).count
        let days = (try? (readSession?.marketDays() ?? MarketDay.fetchAll(in: context))) ?? []
        summary.firstDate = days.first(where: \.isOfficial)?.dateTime
        summary.lastDate = days.last(where: \.isOfficial)?.dateTime
        if let first = summary.firstDate {
            let firstMonth = twDateTime.startOfMonth(first)
            summary.remainingHistoryMonths = max(
                0,
                twDateTime.calendar.dateComponents([.month], from: floorMonth, to: firstMonth).month ?? 0
            )
        } else {
            summary.remainingHistoryMonths = max(
                0,
                (twDateTime.calendar.dateComponents([.month], from: floorMonth, to: targetMonth).month ?? 0) + 1
            )
        }
        summary.isInputComplete = summary.remainingHistoryMonths == 0
            && summary.remainingRecentMonths == 0
            && summary.failedMonths == 0
            && summary.lastDate.map { twDateTime.startOfDay($0) >= cutoff } == true
        summary.requiresTechnicalRebuild = days.contains {
            !$0.hasCurrentTechnicalValues
        }
        summary.isReadyForSimulation = summary.isInputComplete
            && !summary.requiresTechnicalRebuild
        return summary
    }

    private func requestMonthWithLimitedRetry(_ month: Date, cutoff: Date) async throws -> [Record] {
        let ymd = twDateTime.stringFromDate(month, format: "yyyyMMdd")
        guard let url = URL(
            string: "https://www.twse.com.tw/indicesReport/MI_5MINS_HIST?response=json&date=\(ymd)"
        ) else {
            throw DataError.invalidResponse("URL 無效")
        }
        var lastError: Error?
        for attempt in 0...retryDelays.count {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(retryDelays[attempt - 1]))
            }
            do {
                var request = URLRequest(url: url, timeoutInterval: 30)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw DataError.invalidResponse("HTTP 回應無效")
                }
                return try Self.parseMonth(data, expectedMonth: month, cutoff: cutoff)
            } catch {
                requestInterval = max(requestInterval, 5)
                lastError = error
            }
        }
        throw lastError ?? DataError.invalidResponse("未知錯誤")
    }

    func applyOfficialRecords(_ records: [Record],
                              readSession: OfficialPriceReadSession? = nil) throws -> Int {
        guard records.allSatisfy({ record in
            [record.open, record.high, record.low, record.close].allSatisfy { $0.isFinite && $0 > 0 }
                && record.high >= max(record.open, record.close) && record.low <= min(record.open, record.close)
        }) else { throw DataError.invalidResponse("正式大盤原始值無效") }
        let existing = try readSession?.marketDays() ?? MarketDay.fetchAll(in: context)
        var byDate = Dictionary(uniqueKeysWithValues: existing.map {
            (twDateTime.startOfDay($0.dateTime), $0)
        })
        var changed = 0
        var changedDays: [Date] = []
        for record in records {
            let key = twDateTime.startOfDay(record.date)
            let day = byDate[key] ?? MarketDay(
                dateTime: record.date,
                indexOpen: record.open,
                indexHigh: record.high,
                indexLow: record.low,
                indexClose: record.close
            )
            if byDate[key] == nil {
                context.insert(day)
                byDate[key] = day
                changed += 1
                changedDays.append(key)
            } else if day.indexOpen != record.open
                || day.indexHigh != record.high
                || day.indexLow != record.low
                || day.indexClose != record.close
                || day.dataSource != "TWSE-MI_5MINS_HIST" {
                day.indexOpen = record.open
                day.indexHigh = record.high
                day.indexLow = record.low
                day.indexClose = record.close
                day.dataSource = "TWSE-MI_5MINS_HIST"
                day.quoteTime = nil
                day.technicalStateVersion = 0
                changed += 1
                changedDays.append(key)
            }
        }
        if !changedDays.isEmpty {
            advanceLookupEpoch()
            readSession?.invalidateMarket()
            let all = byDate.values.sorted { $0.dateTime < $1.dateTime }
            let affected = pendingTechnicalDates(in: all, changedDates: changedDays)
            for day in all where affected.contains(day.dateTime) { day.technicalStateVersion = Self.pendingTechnicalStateVersion }
            try RecalculationInvalidation.marketTechnical(writes: Array(affected), in: context)
        }
        try saveTechnicalState()
        return changed
    }
}
