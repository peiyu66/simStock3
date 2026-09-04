import Foundation
import SwiftData

/// TWSE 發行量加權股價指數的正式日資料。指數點位可像價格一樣計算路徑，
/// 但它不是可成交的個股價格；正式策略只讀取決策日前一個已完成交易日的階段。
@Model
final class MarketDay {
    @Attribute(.unique) var dateTime: Date
    var dataSource: String
    var indexOpen: Double
    var indexHigh: Double
    var indexLow: Double
    var indexClose: Double
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

    var storedPricePathState: PricePathStoredState? {
        guard pricePathPhase != .unavailable,
              let barrier = pricePathBarrier,
              let anchorClose = pricePathAnchorClose,
              let extremeClose = pricePathExtremeClose,
              barrier.isFinite,
              anchorClose.isFinite,
              extremeClose.isFinite,
              pricePathDaysSinceExtreme >= 0 else {
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
}

struct MarketPricePathLookup: Equatable, Sendable {
    struct Observation: Equatable, Sendable {
        let date: Date
        let phase: PricePathPhase
    }

    private(set) var observations: [Observation] = []

    init(observations: [Observation] = []) {
        self.observations = observations.sorted { $0.date < $1.date }
    }

    @MainActor
    init(modelContext: ModelContext) throws {
        self.init(observations: try MarketDay.fetchAll(in: modelContext).map {
            Observation(date: $0.dateTime, phase: $0.pricePathPhase)
        })
    }

    /// 嚴格使用決策日之前最後一筆大盤日資料；同日資料永遠不會被讀取。
    func phase(before decisionDate: Date) -> PricePathPhase? {
        var lower = 0
        var upper = observations.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if observations[middle].date < decisionDate {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        return observations[lower - 1].phase
    }

    var firstDate: Date? { observations.first?.date }
    var lastDate: Date? { observations.last?.date }
}

enum MarketPricePathSellRule {
    static let ruleID = "S-P08"

    static func contribution(
        priorMarketPhase: PricePathPhase?,
        stockPhase: PricePathPhase,
        grade: Trade.Grade
    ) -> Double {
        priorMarketPhase == .seekingPeakLate
            && stockPhase == .seekingPeakLate
            && grade >= .high
            ? 1
            : 0
    }
}

@MainActor
final class MarketDataStore {
    static let technicalStateVersion = 1
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

    struct UpdateSummary {
        var requestedMonths = 0
        var failedMonths = 0
        var remainingHistoryMonths = 0
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

    init(modelContext: ModelContext, session: URLSession = .shared) {
        self.context = modelContext
        self.session = session
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

    func rebuildPricePath() throws {
        let days = try MarketDay.fetchAll(in: context)
        var rolling = PricePathRollingContext()
        for day in days {
            day.applyPricePathState(
                rolling.update(date: day.dateTime, close: day.indexClose)
            )
            day.technicalStateVersion = Self.technicalStateVersion
        }
        try context.save()
    }

    func update(
        stocks: [Stock],
        through completedTradingDay: Date?,
        maximumHistoryMonths: Int = 6,
        onProgress: ((String) -> Void)? = nil
    ) async -> UpdateSummary {
        guard let floorMonth = Self.requiredStartMonth(for: stocks),
              let completedTradingDay else {
            return UpdateSummary()
        }

        var summary = UpdateSummary()
        requestInterval = 1.5
        let cutoff = twDateTime.startOfDay(completedTradingDay)
        let targetMonth = twDateTime.startOfMonth(cutoff)
        var days = (try? MarketDay.fetchAll(in: context)) ?? []

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
        if let latest = days.last?.dateTime {
            if twDateTime.startOfDay(latest) < cutoff {
                requestMonths += monthRange(
                    from: twDateTime.startOfMonth(latest),
                    through: targetMonth
                )
            }
        } else {
            requestMonths.append(targetMonth)
        }

        let earliestMonth = days.first.map { twDateTime.startOfMonth($0.dateTime) } ?? targetMonth
        if earliestMonth > floorMonth {
            let historyEnd = twDateTime.calendar.date(byAdding: .month, value: -1, to: earliestMonth)
                .map(twDateTime.startOfMonth)
            if let historyEnd {
                let allHistory = monthRange(from: floorMonth, through: historyEnd)
                requestMonths += allHistory.suffix(maximumHistoryMonths).reversed()
            }
        }

        var uniqueMonths: [Date] = []
        for month in requestMonths where !uniqueMonths.contains(month) {
            uniqueMonths.append(month)
        }

        for (index, month) in uniqueMonths.enumerated() {
            if Task.isCancelled { break }
            let monthText = twDateTime.stringFromDate(month, format: "yyyy/MM")
            onProgress?("大盤 \(index + 1)/\(uniqueMonths.count) 補齊 \(monthText)")
            summary.requestedMonths += 1
            do {
                let records = try await requestMonthWithLimitedRetry(month, cutoff: cutoff)
                summary.insertedOrUpdatedDays += try upsert(records)
            } catch {
                summary.failedMonths += 1
                simLog.addLog("大盤 \(monthText) 更新失敗：\(error)")
                // Forward months are requested oldest-to-newest and history months
                // newest-to-oldest. Stop at the first failed month so the stored
                // interval stays contiguous and the same boundary is retried next time.
                break
            }
            if index + 1 < uniqueMonths.count {
                try? await Task.sleep(for: .seconds(requestInterval))
            }
        }

        days = (try? MarketDay.fetchAll(in: context)) ?? []
        summary.firstDate = days.first?.dateTime
        summary.lastDate = days.last?.dateTime
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
            && summary.failedMonths == 0
            && summary.lastDate.map { twDateTime.startOfDay($0) >= cutoff } == true
        summary.requiresTechnicalRebuild = days.contains {
            $0.technicalStateVersion != Self.technicalStateVersion
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
        let retryDelays: [TimeInterval] = [15, 30, 60]
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

    private func upsert(_ records: [Record]) throws -> Int {
        let existing = try MarketDay.fetchAll(in: context)
        var byDate = Dictionary(uniqueKeysWithValues: existing.map {
            (twDateTime.startOfDay($0.dateTime), $0)
        })
        var changed = 0
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
                day.technicalStateVersion = 0
                changed += 1
            }
        }
        try context.save()
        return changed
    }
}
