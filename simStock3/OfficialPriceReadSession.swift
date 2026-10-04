import Foundation
import SwiftData

/// One update only. Never survives a foreground pass or a batch confirmation.
/// Writers invalidate the affected source; Stock dirty/version flags are read live.
@MainActor
final class OfficialPriceReadSession {
    private let context: ModelContext
    private var trades: [String: [Trade]] = [:]
    private var market: [MarketDay]?
    private(set) var stockHistoryReads = 0
    private(set) var marketHistoryReads = 0

    init(context: ModelContext) { self.context = context }

    func stockTrades(_ stock: Stock) throws -> [Trade] {
        if let cached = trades[stock.sId] { return cached }
        stockHistoryReads += 1
        let fetched = try Trade.fetch(in: context, for: stock, ascending: true)
        trades[stock.sId] = fetched
        return fetched
    }

    func marketDays() throws -> [MarketDay] {
        if let market { return market }
        marketHistoryReads += 1
        let fetched = try MarketDay.fetchAll(in: context)
        market = fetched
        return fetched
    }

    func invalidateStock(_ stock: Stock) { trades[stock.sId] = nil }
    func invalidateMarket() { market = nil }
    func invalidateAll() { trades.removeAll(); market = nil }
}

nonisolated struct PriceUpdateTimings: Codable {
    var calendarSeconds: Double = 0
    var officialSeconds: Double = 0
    var yahooSeconds: Double = 0
    var totalSeconds: Double = 0
    var calendarRequests = 0
    var stockHistoryReads = 0
    var marketHistoryReads = 0
    var marketLookupReloads = 0

    var diagnosticText: String {
        String(format: "股價檢查耗時：日曆 %.3fs（%d 請求）、正式資料 %.3fs、Yahoo %.3fs、總計 %.3fs；檢查讀取 個股 %d／大盤 %d，查詢表重建 %d。",
            calendarSeconds, calendarRequests, officialSeconds, yahooSeconds,
            totalSeconds, stockHistoryReads, marketHistoryReads, marketLookupReloads)
    }

}
