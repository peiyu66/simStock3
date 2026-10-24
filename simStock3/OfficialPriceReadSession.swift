import Foundation
import Combine
import SwiftData

/// Loaded rows live for this pass. Confirmed source/work evidence survives in
/// the ledger and is invalidated by saved changes, not by foreground itself.
@MainActor
final class OfficialPriceReadSession {
    private let context: ModelContext
    let ledger: UpdateWorkLedger
    private struct StockRows {
        let requestStart: Date
        let rows: [Trade]
    }
    private var trades: [String: StockRows] = [:]
    private struct MarketRows {
        let from: Date
        let through: Date
        let rows: [MarketDay]
    }
    private var market: MarketRows?
    // Keep the demand of this update pass across invalidations. A fresh
    // bounded session never inherits another session's broader request.
    private var marketRequestedRange: ClosedRange<Date>?
    private var journalNeedsRefresh = false
    private var saveSubscription: AnyCancellable?
    private(set) var stockHistoryReads = 0
    private(set) var marketHistoryReads = 0

    init(context: ModelContext) {
        self.context = context
        ledger = .shared(in: context)
        refreshChanges()
        // A pass can span source writes. Mark its journal boundary stale on
        // save, then consume that journal once before the next cached read.
        // This also covers another context writing to the same container.
        saveSubscription = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .sink { [weak self] notification in
                guard let self, let changed = notification.object as? ModelContext,
                      changed.container === self.context.container else { return }
                self.journalNeedsRefresh = true
            }
    }

    func refreshChanges() {
        ledger.refresh()
        journalNeedsRefresh = false
        let changed = ledger.takeInvalidations()
        if changed.allStocks {
            for cached in trades.values { cached.rows.first?.stock.invalidateCalculationWindow() }
            trades.removeAll()
        }
        for id in changed.stocks { trades[id] = nil }
        if changed.market { market = nil }
    }

    private func refreshAfterSaveIfNeeded() {
        if journalNeedsRefresh { refreshChanges() }
    }

    func stockTrades(_ stock: Stock) throws -> [Trade] {
        refreshAfterSaveIfNeeded()
        try ledger.confirmListingEvidenceAfterJournalRefresh(for: stock)
        let requestStart = twDateTime.startOfDay(stock.dateRequestStart)
        if let cached = trades[stock.sId], cached.requestStart == requestStart { return cached.rows }
        stockHistoryReads += 1
        let fetched = try Trade.fetch(in: context, for: stock, start: requestStart, ascending: true)
        trades[stock.sId] = StockRows(requestStart: requestStart, rows: fetched)
        stock.installCalculationWindow(from: fetched)
        return fetched
    }

    /// Call in the update/maintenance phase, after raw inputs have been saved.
    /// No startup view calls this method merely to render history status.
    func prepareSourceEvidence(for stocks: [Stock]) throws {
        refreshChanges()
        for stock in stocks { try ledger.confirmListingEvidenceAfterJournalRefresh(for: stock) }
    }

    func marketDays(from start: Date = .distantPast,
                    through end: Date = .distantFuture) throws -> [MarketDay] {
        refreshAfterSaveIfNeeded()
        if let market, market.from <= start, market.through >= end {
            return market.rows.filter { $0.dateTime >= start && $0.dateTime <= end }
        }
        let lower = min(start, marketRequestedRange?.lowerBound ?? start)
        let upper = max(end, marketRequestedRange?.upperBound ?? end)
        marketHistoryReads += 1
        let fetched = try MarketDay.fetch(in: context, from: lower, through: upper)
        marketRequestedRange = lower...upper
        market = MarketRows(from: lower, through: upper, rows: fetched)
        return fetched.filter { $0.dateTime >= start && $0.dateTime <= end }
    }

    func invalidateStock(_ stock: Stock) { trades[stock.sId] = nil; ledger.invalidate(stock, source: true) }
    func invalidateMarket(source: Bool = true) { market = nil; ledger.invalidateMarket(source: source) }
    func invalidateAll() { trades.removeAll(); market = nil }

    func finish(stocks: [Stock], through cutoff: Date?, technical: Technical) throws {
        if context.hasChanges { try context.save() }
        refreshChanges()
        for stock in stocks {
            if ledger.proof(for: stock) == nil {
                let rows = try stockTrades(stock)
                ledger.rememberSource(stock, trades: rows, through: cutoff)
            } else {
                ledger.confirmUnchangedSource(stock, through: cutoff)
            }
            if !ledger.hasCompletedWork(stock),
               technical.stocksRequiringRecalculation(in: [stock], readSession: self).isEmpty {
                ledger.rememberCompletedWork(stock)
            }
        }
    }
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
    var windowBuilds = 0
    var windowInputScans = 0
    var windowObservedRows = 0
    var p10Executions = 0
    var journalReads = 0
    var changedTransactions = 0

    var diagnosticText: String {
        String(format: "股價檢查耗時：日曆 %.3fs（%d 請求）、正式資料 %.3fs、Yahoo %.3fs、總計 %.3fs；檢查讀取 個股 %d／大盤 %d，查詢表重建 %d。",
            calendarSeconds, calendarRequests, officialSeconds, yahooSeconds,
            totalSeconds, stockHistoryReads, marketHistoryReads, marketLookupReloads)
    }

}

// Keep older saved diagnostics readable when counters are added. Missing counts
// mean they were not collected by that version, not a failed update.
extension PriceUpdateTimings {
    nonisolated init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        calendarSeconds = try values.decodeIfPresent(Double.self, forKey: .calendarSeconds) ?? 0
        officialSeconds = try values.decodeIfPresent(Double.self, forKey: .officialSeconds) ?? 0
        yahooSeconds = try values.decodeIfPresent(Double.self, forKey: .yahooSeconds) ?? 0
        totalSeconds = try values.decodeIfPresent(Double.self, forKey: .totalSeconds) ?? 0
        calendarRequests = try values.decodeIfPresent(Int.self, forKey: .calendarRequests) ?? 0
        stockHistoryReads = try values.decodeIfPresent(Int.self, forKey: .stockHistoryReads) ?? 0
        marketHistoryReads = try values.decodeIfPresent(Int.self, forKey: .marketHistoryReads) ?? 0
        marketLookupReloads = try values.decodeIfPresent(Int.self, forKey: .marketLookupReloads) ?? 0
        windowBuilds = try values.decodeIfPresent(Int.self, forKey: .windowBuilds) ?? 0
        windowInputScans = try values.decodeIfPresent(Int.self, forKey: .windowInputScans) ?? 0
        windowObservedRows = try values.decodeIfPresent(Int.self, forKey: .windowObservedRows) ?? 0
        p10Executions = try values.decodeIfPresent(Int.self, forKey: .p10Executions) ?? 0
        journalReads = try values.decodeIfPresent(Int.self, forKey: .journalReads) ?? 0
        changedTransactions = try values.decodeIfPresent(Int.self, forKey: .changedTransactions) ?? 0
    }
}
