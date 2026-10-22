//
//  simStock.swift
//  simStock21
//
//  Created by peiyu on 2020/6/24.
//  Copyright © 2020 peiyu. All rights reserved.
//

import Foundation 
import SwiftData

nonisolated enum DailyPriceUpdatePolicy {
    static func shouldRequestYahoo(
        marketStatus: TWSEMarketDayStatus,
        asOf date: Date,
        hasOfficialDataForToday: Bool,
        lastSuccessfulCloseRefresh: Date?,
        calendar: Calendar
    ) -> Bool {
        switch marketStatus {
        case .closed:
            return false
        case .unknown:
            // Without a reliable calendar, retain the conservative one-shot check.
            return true
        case .tradingDay:
            let components = calendar.dateComponents([.hour, .minute], from: date)
            guard let hour = components.hour, let minute = components.minute else {
                return true
            }
            let minuteOfDay = hour * 60 + minute
            let marketOpen = 9 * 60
            let marketClose = 13 * 60 + 30

            if minuteOfDay >= marketOpen, minuteOfDay < marketClose {
                return true
            }
            if minuteOfDay >= marketClose {
                guard !hasOfficialDataForToday else { return false }
                guard let marketCloseTime = calendar.date(
                    bySettingHour: 13,
                    minute: 30,
                    second: 0,
                    of: date
                ) else {
                    return true
                }
                if let lastSuccessfulCloseRefresh,
                   calendar.isDate(lastSuccessfulCloseRefresh, inSameDayAs: date),
                   lastSuccessfulCloseRefresh >= marketCloseTime {
                    return false
                }
                return true
            }
            return false
        }
    }
}

class simObject {

    static func unifiedUpdateScope(
        requestedStocks: [Stock],
        allGroupedStocks: [Stock],
        requiresGroupCompletion: Bool
    ) -> [Stock] {
        requiresGroupCompletion ? allGroupedStocks : requestedStocks
    }

    func unifiedUpdateScope(for requestedStocks: [Stock]) -> [Stock] {
        let allGroupedStocks = (try? Stock.fetchGrouped(in: context)) ?? requestedStocks
        return Self.unifiedUpdateScope(
            requestedStocks: requestedStocks,
            allGroupedStocks: allGroupedStocks,
            requiresGroupCompletion: tech.hasPendingDataRecalculation(in: allGroupedStocks)
        )
    }

    struct DailyPriceUpdateSummary {
        let twse: TWSEUpdateSummary
        let yahoo: Technical.YahooUpdateSummary

        var statusText: String {
            let skippedYahooStocks = yahoo.requestedStocks - yahoo.successfulStockIDs.count
            let yahooText: String
            if skippedYahooStocks > 0 {
                yahooText = yahoo.updatedStocks > 0
                    ? "Yahoo 更新 \(yahoo.updatedStocks) 檔，略過 \(skippedYahooStocks) 檔"
                    : "Yahoo 略過 \(skippedYahooStocks) 檔"
            } else {
                if yahoo.updatedStocks > 0 {
                    yahooText = "Yahoo 更新 \(yahoo.updatedStocks) 檔"
                } else if yahoo.requestedStocks > 0 {
                    yahooText = "Yahoo 已檢查"
                } else {
                    yahooText = "Yahoo 無需查詢"
                }
            }
            let marketText = yahoo.marketUpdated ? "大盤當日指數已更新"
                : (yahoo.marketFailed ? "大盤當日指數查詢失敗" : twse.market.statusText)
            let provisional = twse.previousMarketStockIDs.isEmpty ? "" : "；\(twse.previousMarketStockIDs.count) 檔暫算（沿用前一交易日大盤）"
            return "\(twse.statusText)；\(yahooText)；\(marketText)\(provisional)"
        }
    }

    struct TWSEUpdateSummary {
        var timings = PriceUpdateTimings()
        var requestedMonths = 0
        var failedMonths = 0
        var remainingHistoryMonths = 0
        var remainingRecentMonths = 0
        var reachedBatchLimit = false
        var incompleteHistoryStockIDs: Set<String> = []
        var forwardFailedStockIDs: Set<String> = []
        var officialDataTodayStockIDs: Set<String> = []
        var marketDayStatus: TWSEMarketDayStatus = .unknown
        var expectedCompletedTradingDay: Date?
        var userActions = UserActionRecalculationSummary()
        var migratedDataRuleStocks = 0
        var market = MarketDataStore.UpdateSummary()
        var realtimeBlockedStockIDs: Set<String> = []
        var provisionalStockIDs: Set<String> = []
        var previousMarketStockIDs: Set<String> = []
        var calculatedStockIDs: Set<String> = []
        var technicalOnlyStockIDs: Set<String> = []
        var historyCoverageSaveFailed = false
        var wasInterrupted = false

        var continuationProgress: TWSEBatchProgress? {
            TWSEBatchProgress.make(
                stockHistoryMonths: remainingHistoryMonths,
                stockRecentMonths: remainingRecentMonths,
                marketMonths: market.remainingHistoryMonths + market.remainingRecentMonths,
                requestedMonths: requestedMonths + market.requestedMonths,
                failedMonths: failedMonths + market.failedMonths,
                reachedBatchLimit: reachedBatchLimit || market.reachedBatchLimit
            )
        }

        func permitsRealtimeSimulation(for stockID: String) -> Bool {
            !forwardFailedStockIDs.contains(stockID)
                && !realtimeBlockedStockIDs.contains(stockID)
        }

        var statusText: String {
            let source: String
            if historyCoverageSaveFailed {
                source = "歷史完整性紀錄保存失敗，保留待辦，請重新更新"
            } else if wasInterrupted {
                source = "更新已中斷，已保存行情與待重算範圍"
            } else if marketDayStatus == .unknown {
                source = "交易日尚未確認，保留已保存行情"
            } else if requestedMonths == 0 {
                source = remainingRecentMonths > 0 || !forwardFailedStockIDs.isEmpty
                    ? "近期正式股價尚未補齊"
                    : (remainingHistoryMonths > 0 ? "近期股價已是最新" : "股價已是最新，歷史資料也已補齊")
            } else if failedMonths == 0 {
                source = "股價下載完成（共 \(requestedMonths) 個月份）"
            } else {
                source = "部分下載完成：\(requestedMonths - failedMonths)/\(requestedMonths) 個月份成功"
            }
            var parts = [source]
            if remainingHistoryMonths > 0 { parts.append("歷史尚待補 \(remainingHistoryMonths) 個月份") }
            if remainingRecentMonths > 0 { parts.append("近期尚待補 \(remainingRecentMonths) 個月份") }
            if !calculatedStockIDs.isEmpty { parts.append("已依現有資料計算 \(calculatedStockIDs.count) 檔") }
            if !technicalOnlyStockIDs.isEmpty { parts.append("\(technicalOnlyStockIDs.count) 檔尚未滿一年，僅計算技術值") }
            if !realtimeBlockedStockIDs.isEmpty { parts.append("模擬待補齊或重算（\(realtimeBlockedStockIDs.count) 檔）") }
            return parts.joined(separator: "；")
        }
    }

    private var context: ModelContext
    private let marketStore: MarketDataStore

    var stocks:[Stock] = []


    let tech:Technical
    let simulationInputs: SimulationInputWriter

    init(modelContext: ModelContext, tradingCalendar: TWSETradingCalendar = .shared,
         marketSession: URLSession = .shared, marketRetryDelays: [TimeInterval] = [15, 30, 60]) {
        self.context = modelContext
        self.marketStore = MarketDataStore(modelContext: modelContext, session: marketSession, retryDelays: marketRetryDelays)
        let technical = Technical(modelContext: modelContext, tradingCalendar: tradingCalendar, priceSession: marketSession)
        self.tech = technical
        self.simulationInputs = SimulationInputWriter(context: modelContext, technical: technical)

        defaults.bootstrapIfNeeded()
        self.stocks =  getStocks()
        if self.stocks.count == 0 {
            let group1:[(sId:String,sName:String)] = [
//                (sId:"3653", sName:"健策"),
                (sId:"3017", sName:"奇鋐"),
//                (sId:"2368", sName:"金像電"),
                (sId:"2330", sName:"台積電")]
            self.newStock(stocks: group1, group: "股群_1")
            
            let group2:[(sId:String,sName:String)] = [
//                (sId:"2324", sName:"仁寶"),
//                (sId:"1301", sName:"台塑"),
                (sId:"1216", sName:"統一"),
                (sId:"2317", sName:"鴻海")]
            self.newStock(stocks: group2, group: "股群_2")

            self.stocks =  getStocks()
        }
        if let repairedCount = try? Stock.repairUserActionSummaries(for: self.stocks, in: context),
           repairedCount > 0 {
            NSLog("已修復 \(repairedCount) 檔股票的人工操作摘要。")
        }
    }
        
    func getStocks(_ searchText:[String]?=nil) -> [Stock] {
        guard let searchText, !searchText.isEmpty else {
            return (try? Stock.fetchGrouped(in: context)) ?? []
        }
        return ((try? Stock.fetch(
            in: context,
            sId: searchText,
            sName: searchText
        )) ?? []).filter { !$0.group.isEmpty }
    }
        
    private func needsForwardUpdate(for stock: Stock, through completedDay: Date?,
                                    readSession: OfficialPriceReadSession? = nil) -> Bool {
        guard let completedDay else { return false }
        let latest: Trade?
        if let readSession {
            latest = (try? readSession.stockTrades(stock))?.last { $0.hasUsableOfficialPrice }
        } else {
            latest = try? Trade.fetch(in: context, for: stock, start: stock.dateRequestStart, TWSE: true, ascending: false)
                .first(where: \.hasUsableOfficialPrice)
        }
        guard let latest else { return true }
        return twDateTime.startOfDay(latest.dateTime) < completedDay
    }

    /// Freeze actual work subjects before downloading; reuse through continued
    /// batches and replay phases. Merely inspecting current data isn't work.
    func officialUpdateProgress(stocks: [Stock], allGroupedStocks: [Stock],
                                through completedDay: Date?,
                                readSession: OfficialPriceReadSession? = nil) -> OperationProgress {
        let pendingIDs = Set(tech.stocksRequiringRecalculation(in: stocks, readSession: readSession).map(\.sId))
        let inputStocks = stocks.filter { stock in
            if needsForwardUpdate(for: stock, through: completedDay, readSession: readSession) || pendingIDs.contains(stock.sId) {
                return true
            }
            return completedDay.map { !stock.unconfirmedHistoryMonths(through: $0).isEmpty } ?? false
        }
        let needsMarketWork = marketStore.inputPlan(stocks: allGroupedStocks,
            through: completedDay, readSession: readSession)?.hasWork == true
        return OperationProgress(subjects:
            inputStocks.map { .stock($0.sId) } + (needsMarketWork ? [.market] : []))
    }

    struct ProvisionalNoPriceWork {
        let expectedCompletedTradingDay: Date
        let stockHistoryReads: Int
        let marketHistoryReads: Int
    }

    /// Read-only preflight for automatic foreground checks. Always checks the
    /// whole current group; no rows or completion timestamps are changed.
    func provisionalNoPriceWork(asOf date: Date) async -> ProvisionalNoPriceWork? {
        guard let snapshot = await tech.provisionalTradingCalendar(for: date) else { return nil }
        let status = TWSETradingCalendar.status(for: date, snapshot: snapshot)
        let calendar = twDateTime.calendar
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        guard status == .closed || (status == .tradingDay && (minutes < 9 * 60 || minutes >= 15 * 60 + 35)),
              let cutoff = TWSETradingCalendar.latestCompletedTradingDay(asOf: date, snapshot: snapshot),
              let stocks = try? Stock.fetchGrouped(in: context), !stocks.isEmpty else { return nil }
        let reads = OfficialPriceReadSession(context: context)
        guard tech.stocksRequiringRecalculation(in: stocks, readSession: reads).isEmpty else { return nil }
        for stock in stocks {
            guard let trades = try? reads.stockTrades(stock),
                  trades.contains(where: { $0.hasUsableOfficialPrice }),
                  stock.unconfirmedHistoryMonths(through: cutoff).isEmpty,
                  !needsForwardUpdate(for: stock, through: cutoff, readSession: reads) else { return nil }
        }
        // Explicitly require authoritative market history at both ends. A
        // Yahoo row must not make a missing official history month look covered.
        guard let days = try? reads.marketDays(),
              let first = days.first(where: \.isOfficial),
              let floor = MarketDataStore.requiredStartMonth(for: stocks),
              twDateTime.startOfMonth(first.dateTime) <= floor,
              let plan = marketStore.inputPlan(stocks: stocks, through: cutoff, readSession: reads),
              !plan.hasWork else { return nil }
        return ProvisionalNoPriceWork(expectedCompletedTradingDay: cutoff,
            stockHistoryReads: reads.stockHistoryReads, marketHistoryReads: reads.marketHistoryReads)
    }

    @MainActor
    func updateTWSEPrices(
        stocks sourceStocks: [Stock]? = nil,
        asOf: Date = Date(),
        onProgress: ((String) -> Void)? = nil,
        onRecalculationProgress: ((String) -> Void)? = nil,
        onBatchCompletion: ((TWSEBatchProgress) async -> Int?)? = nil,
        allowsLiveFallback: Bool = false,
        onStockInputsSaved: ((TWSEMarketDayStatus) async -> Void)? = nil,
        onMarketInputsSaved: ((Bool) async -> Bool)? = nil
    ) async -> TWSEUpdateSummary {
        let requestedStocks = (sourceStocks ?? self.stocks).filter { !$0.group.isEmpty }
        let allGroupedStocks = (try? Stock.fetchGrouped(in: context)) ?? requestedStocks
        // A single-stock refresh includes pending grouped work. Each stock only
        // releases derived results once its own historical dependencies are ready.
        var targetStocks = unifiedUpdateScope(for: requestedStocks)
        guard !targetStocks.isEmpty else { return TWSEUpdateSummary() }

        tech.countTWSE = targetStocks.count
        tech.progressTWSE = 0
        tech.errorTWSE = 0
        defer {
            tech.progressTWSE = nil
            tech.countTWSE = nil
        }

        // Each source saves independently. Available stock T and market T run
        // independently; the shared executor settles only the safe S prefix.
        let started = ProcessInfo.processInfo.systemUptime
        if await tech.needsTradingCalendarRefreshWait(for: asOf) {
            onProgress?("正在確認交易日曆…")
        } else {
            onProgress?("正在檢查本機股價完整性…")
        }
        let calendarDecision = await tech.refreshTradingCalendar(for: asOf)
        let calendarFinished = ProcessInfo.processInfo.systemUptime
        let expectedCompletedTradingDay = await tech.latestCompletedTWSETradingDay(asOf: asOf)
        let previousTradingDay = await tech.latestCompletedTWSETradingDay(asOf: twDateTime.startOfDay(asOf))
        if allowsLiveFallback, calendarDecision.status == .tradingDay, let previousTradingDay {
            tech.liveMarketContext = .init(asOf: asOf, previousTradingDay: previousTradingDay)
        }
        defer { tech.liveMarketContext = nil }
        var didRunStockQuotePhase = false
        // Do not plan from an expired snapshot while its refresh is suspended.
        let reads = OfficialPriceReadSession(context: context)
        let lookupReloadsBefore = tech.marketLookupReloadCount
        onProgress?("正在檢查本機股價完整性…")
        if marketStore.inputPlan(stocks: allGroupedStocks, through: expectedCompletedTradingDay, readSession: reads)?.hasWork == true {
            targetStocks = allGroupedStocks
            tech.countTWSE = targetStocks.count
        }
        do {
            let legacyStocks = targetStocks.filter { $0.confirmedHistory.legacyAdoptionCompleted != true }
            if !legacyStocks.isEmpty {
                let marketDays = try reads.marketDays()
                for stock in legacyStocks {
                    try tech.adoptLegacyHistoryCoverage(for: stock, trades: reads.stockTrades(stock), marketDays: marketDays)
                }
            }
        } catch {
            // A failed source checkpoint is not a successful update. Previously
            // saved receipts remain intact; retry the uncommitted adoption later.
            var failed = TWSEUpdateSummary(marketDayStatus: calendarDecision.status,
                expectedCompletedTradingDay: expectedCompletedTradingDay)
            failed.historyCoverageSaveFailed = true
            failed.realtimeBlockedStockIDs = Set(targetStocks.map(\.sId))
            failed.remainingHistoryMonths = targetStocks.reduce(0) { total, stock in
                let last = (try? reads.stockTrades(stock))?.last(where: \.hasUsableOfficialPrice)?.dateTime
                return total + stock.unconfirmedHistoryMonths(through: last ?? expectedCompletedTradingDay ?? asOf).count
            }
            return failed
        }
        var marketSummary = MarketDataStore.UpdateSummary()
        var summary = TWSEUpdateSummary()
        let currentMonth = twDateTime.startOfMonth(expectedCompletedTradingDay ?? asOf)
        var maximumMonthsPerSource = 6
        // In-session cursors avoid repeating a completed batch. Across restarts,
        // saved authoritative coverage is the checkpoint for every stock.
        var nextForwardMonths: [String: Date] = [:]
        var nextMarketForwardMonth: Date?
        var totalRequestedMonths = 0
        var totalMarketRequestedMonths = 0
        var totalMarketDays = 0
        var totalUserActions = UserActionRecalculationSummary()
        var totalMigratedStocks = 0
        var previousRemainingMonths: Int?

        func months(from firstMonth: Date, through lastMonth: Date) -> [Date] {
            guard firstMonth <= lastMonth else { return [] }
            var result: [Date] = []
            var month = firstMonth
            while month <= lastMonth {
                result.append(month)
                guard let next = twDateTime.calendar.date(byAdding: .month, value: 1, to: month) else {
                    break
                }
                month = twDateTime.startOfMonth(next)
            }
            return result
        }

        func requestMonth(_ month: Date, for stock: Stock, phase: String) async -> Bool {
            summary.requestedMonths += 1
            let monthText = twDateTime.stringFromDate(month, format: "yyyy/MM")
            onProgress?(operationProgress.message(for: .stock(stock.sId),
                "\(stock.sId) \(stock.sName) \(phase) \(monthText)"))
            let previousRevision = tech.officialPriceRevision
            let succeeded = await tech.twseRequestAsync(
                stock: stock,
                dateStart: month,
                recalculate: false
            )
            if tech.officialPriceRevision != previousRevision { reads.invalidateStock(stock) }
            if !succeeded {
                summary.failedMonths += 1
            }
            try? await Task.sleep(for: .seconds(1.5))
            return succeeded
        }

        func latestOfficialTrade(for stock: Stock) -> Trade? {
            (try? reads.stockTrades(stock))?.last { $0.hasUsableOfficialPrice }
        }

        func hasOfficialDataForToday(for stock: Stock) -> Bool {
            guard let latestOfficialTrade = latestOfficialTrade(for: stock) else {
                return false
            }
            return twDateTime.startOfDay(latestOfficialTrade.dateTime) >= twDateTime.startOfDay(asOf)
        }

        func remainingHistoryMonthCount(for stock: Stock) -> Int {
            // Recent catch-up has a separate count; historical confirmation
            // ends at the last actually saved official day.
            return stock.unconfirmedHistoryMonths(through:
                latestOfficialTrade(for: stock)?.dateTime ?? expectedCompletedTradingDay ?? asOf).count
        }

        func stockInputsReady(for stock: Stock) -> Bool {
            guard !Task.isCancelled, let expected = expectedCompletedTradingDay,
                  stock.calculationWindow.hasSimulationDates else { return false }
            // Today's unpublished official close must not block a provisional
            // calculation. Older missing official inputs still block replay.
            let requiredDay = tech.liveMarketContext.map { min(expected, $0.previousTradingDay) } ?? expected
            return !needsForwardUpdate(for: stock, through: requiredDay, readSession: reads)
        }

        let operationProgress = officialUpdateProgress(stocks: targetStocks,
            allGroupedStocks: allGroupedStocks, through: expectedCompletedTradingDay, readSession: reads)
        tech.countTWSE = operationProgress.subjects.count

        while true {
            if Task.isCancelled { break }
            summary = TWSEUpdateSummary(
                marketDayStatus: calendarDecision.status,
                expectedCompletedTradingDay: expectedCompletedTradingDay,
                market: marketSummary
            )

            for stock in targetStocks {
                if Task.isCancelled { break }
                guard expectedCompletedTradingDay != nil else { continue }
                tech.progressTWSE = operationProgress.position(of: .stock(stock.sId)) ?? 0

                // Only re-fetch recent months when the latest authoritative TWSE
                // trade is older than the last official close expected by now.
                // A Yahoo intraday Trade must not make this decision for TWSE.
                let latestTWSETrade = latestOfficialTrade(for: stock)
                let firstForwardMonth = nextForwardMonths[stock.sId] ?? latestTWSETrade.map {
                    twDateTime.startOfMonth($0.dateTime)
                } ?? currentMonth
                var didCompleteForwardUpdate = true
                var requestedStockMonths = 0
                if needsForwardUpdate(for: stock, through: expectedCompletedTradingDay, readSession: reads) {
                    let forwardMonths = months(from: firstForwardMonth, through: currentMonth)
                    for month in forwardMonths.prefix(maximumMonthsPerSource) {
                        if Task.isCancelled { didCompleteForwardUpdate = false; break }
                        requestedStockMonths += 1
                        if !(await requestMonth(month, for: stock, phase: "補齊近期股價")) {
                            didCompleteForwardUpdate = false
                            summary.forwardFailedStockIDs.insert(stock.sId)
                            break
                        }
                        nextForwardMonths[stock.sId] = twDateTime.calendar.date(byAdding: .month, value: 1, to: month)
                    }
                    let deferredMonths = max(0, forwardMonths.count - requestedStockMonths)
                    if deferredMonths > 0 {
                        summary.remainingRecentMonths += deferredMonths
                        summary.reachedBatchLimit = requestedStockMonths == maximumMonthsPerSource
                            || summary.reachedBatchLimit
                        didCompleteForwardUpdate = false
                    }
                }

                if didCompleteForwardUpdate,
                   needsForwardUpdate(for: stock, through: expectedCompletedTradingDay, readSession: reads) {
                    summary.forwardFailedStockIDs.insert(stock.sId)
                }
                if hasOfficialDataForToday(for: stock) {
                    summary.officialDataTodayStockIDs.insert(stock.sId)
                }

                // Fill older missing history first, then confirm retained
                // legacy months whose source receipts are unknown. Checkpoints
                // survive cancellation/restart, including unchanged responses.
                guard didCompleteForwardUpdate,
                      let earliestTrade = (try? reads.stockTrades(stock))?.first(where: { $0.hasUsableOfficialPrice }),
                      let latestTrade = latestOfficialTrade(for: stock) else {
                    continue
                }
                let earliestMonth = twDateTime.startOfMonth(earliestTrade.dateTime)
                let unconfirmed = stock.unconfirmedHistoryMonths(through: latestTrade.dateTime).reversed()
                let historyMonths = unconfirmed.filter { $0 < earliestMonth }
                    + unconfirmed.filter { $0 >= earliestMonth }
                for historyMonth in historyMonths.prefix(max(0, maximumMonthsPerSource - requestedStockMonths)) {
                    if Task.isCancelled { break }
                    requestedStockMonths += 1
                    if !(await requestMonth(historyMonth, for: stock, phase: "補齊歷史股價")) {
                        break
                    }
                }
                if remainingHistoryMonthCount(for: stock) > 0 && requestedStockMonths == maximumMonthsPerSource {
                    summary.reachedBatchLimit = true
                }
            }

            try? context.save()
            for stock in targetStocks {
                let remaining = remainingHistoryMonthCount(for: stock)
                if remaining > 0 {
                    summary.remainingHistoryMonths += remaining
                    summary.incompleteHistoryStockIDs.insert(stock.sId)
                }
            }

            if !didRunStockQuotePhase && !Task.isCancelled {
                didRunStockQuotePhase = true
                if calendarDecision.status == .tradingDay, let onStockInputsSaved {
                    await onStockInputsSaved(calendarDecision.status)
                    reads.invalidateAll()
                }
                // Publish a usable provisional result before an unreliable market request.
                // No history is synthesized: a complete cached official prior state is required.
                if tech.liveMarketContext != nil,
                   let prior = marketStore.inputPlan(stocks: allGroupedStocks,
                        through: previousTradingDay, readSession: reads), !prior.hasWork {
                    tech.reloadMarketPricePathLookupIfNeeded()
                    if tech.marketObservation(on: asOf) != nil {
                        for stock in targetStocks where stockInputsReady(for: stock) {
                            do {
                                let neededMigration = tech.hasPendingDataRuleMigration(in: [stock])
                                let actions = try await tech.recoverOrMigrateRecalculationState(for: stock) { message in
                                    (onRecalculationProgress ?? onProgress)?("\(stock.sId) \(message)")
                                }
                                summary.userActions.merge(actions)
                                if neededMigration && !tech.hasPendingDataRuleMigration(in: [stock]) {
                                    summary.migratedDataRuleStocks += 1
                                }
                            } catch {
                                simLog.addLog("\(stock.sId) 暫算未完成：\(error)")
                            }
                        }
                    }
                }
            }
            marketSummary = await marketStore.update(
                stocks: allGroupedStocks,
                through: expectedCompletedTradingDay,
                maximumHistoryMonths: maximumMonthsPerSource,
                forwardStartMonth: nextMarketForwardMonth,
                readSession: reads,
                onProgress: { message in
                    onProgress?(operationProgress.message(for: .market, message))
                }
            )
            if marketSummary.insertedOrUpdatedDays > 0 || marketSummary.requiresTechnicalRebuild {
                tech.invalidateMarketPricePathLookup()
            }
            nextMarketForwardMonth = marketSummary.nextForwardMonth ?? nextMarketForwardMonth
            summary.market = marketSummary

            totalUserActions.merge(summary.userActions)
            totalMigratedStocks += summary.migratedDataRuleStocks
            totalRequestedMonths += summary.requestedMonths
            totalMarketRequestedMonths += marketSummary.requestedMonths
            totalMarketDays += marketSummary.insertedOrUpdatedDays
            let progress = summary.continuationProgress
            // A successful response that does not advance coverage must not
            // generate an endless series of continuation prompts.
            if let progress,
               progress.remainingMonths < (previousRemainingMonths ?? Int.max),
               !Task.isCancelled,
               let onBatchCompletion,
               let months = await onBatchCompletion(progress),
               TWSEBatchProgress.monthChoices.contains(months) {
                previousRemainingMonths = progress.remainingMonths
                maximumMonthsPerSource = months
                // User confirmation suspends this pass; another operation may have changed inputs.
                reads.invalidateAll()
                continue
            }
            break
        }
        summary.userActions = totalUserActions
        summary.migratedDataRuleStocks = totalMigratedStocks
        summary.requestedMonths = totalRequestedMonths
        marketSummary.requestedMonths = totalMarketRequestedMonths
        marketSummary.insertedOrUpdatedDays = totalMarketDays

        // Raw source success is durable. Recalculation readiness is evaluated
        // per stock after the last market input, independently of source failures.
        if !Task.isCancelled, marketSummary.requiresTechnicalRebuild {
            do {
                (onRecalculationProgress ?? onProgress)?(operationProgress.message(for: .market,
                    "大盤 正在重算技術數值"))
                try marketStore.rebuildPricePath()
                reads.invalidateMarket()
                marketSummary.requiresTechnicalRebuild = (try? reads.marketDays())?.contains {
                    !$0.hasCurrentTechnicalValues
                } ?? true
                marketSummary.isReadyForSimulation = marketSummary.isInputComplete
                    && !marketSummary.requiresTechnicalRebuild
            } catch {
                simLog.addLog("大盤技術數值統一重算失敗：\(error)")
                marketSummary.isReadyForSimulation = false
            }
        }
        tech.reloadMarketPricePathLookupIfNeeded()
        // Missing early months do not erase a usable bounded prior window.
        // This is source/technical readiness, not a claim of complete history.
        let priorMarketInputsReady = previousTradingDay.flatMap {
            tech.marketObservation(on: $0)
        }.map { $0.isOfficial && $0.hasSimulationValues } ?? false
        if !Task.isCancelled, let onMarketInputsSaved {
            let changed = await onMarketInputsSaved(priorMarketInputsReady || marketSummary.isReadyForSimulation)
            if changed {
                reads.invalidateAll()
                tech.reloadMarketPricePathLookup()
                // A shared market revision affects every grouped stock, even
                // when the user requested a single stock's price update.
                targetStocks = allGroupedStocks
            }
        }
        summary.market = marketSummary

        let calculationStocks = Task.isCancelled ? [] : targetStocks
        // Availability is evaluated by date inside the executor. Neither a
        // remaining download month nor an absent market may block stock T.
        if !calculationStocks.isEmpty {
            if tech.liveMarketContext != nil {
                for stock in calculationStocks {
                    if let latest = try? Trade.last(in: context, for: stock),
                       twDateTime.startOfDay(latest.dateTime) == twDateTime.startOfDay(asOf),
                       latest.simMarketSourceDate == nil
                        || latest.simMarketSourceDate != tech.marketObservation(on: latest.dateTime)?.date
                        || latest.simMarketQuoteTime != tech.marketObservation(on: latest.dateTime)?.quoteTime {
                        let today = twDateTime.startOfDay(asOf)
                        stock.simulationDirtyFrom = min(stock.simulationDirtyFrom ?? today, today)
                    }
                }
            }
            var recalculationFailedStockIDs: Set<String> = []
            let recalculationStocks = tech.stocksRequiringRecalculation(in: calculationStocks, readSession: reads)
            tech.progressTWSE = 0
            for stock in recalculationStocks {
                if Task.isCancelled { break }
                tech.progressTWSE = operationProgress.position(of: .stock(stock.sId)) ?? 0
                let neededDataRuleMigration = tech.hasPendingDataRuleMigration(in: [stock])
                do {
                    let actions = try await tech.recoverOrMigrateRecalculationState(for: stock) { message in
                        (onRecalculationProgress ?? onProgress)?(operationProgress.message(for: .stock(stock.sId),
                            "\(stock.sId) \(stock.sName) \(message)"))
                    }
                    summary.userActions.merge(actions)
                    let trace = tech.lastRecalculationTrace
                    if !trace.technicalDates.isEmpty || !trace.simulationDates.isEmpty {
                        summary.calculatedStockIDs.insert(stock.sId)
                    }
                    if !stock.calculationWindow.hasSimulationDates {
                        summary.technicalOnlyStockIDs.insert(stock.sId)
                    }
                    if neededDataRuleMigration,
                       !tech.hasPendingDataRuleMigration(in: [stock]) {
                        summary.migratedDataRuleStocks += 1
                    }
                } catch {
                    tech.errorTWSE += 1
                    recalculationFailedStockIDs.insert(stock.sId)
                    (onRecalculationProgress ?? onProgress)?(operationProgress.message(for: .stock(stock.sId),
                        "\(stock.sId) \(stock.sName) 重算恢復失敗"))
                    simLog.addLog("\(stock.sId)\(stock.sName) 重算恢復失敗：\(error)")
                }
            }
            summary.realtimeBlockedStockIDs.formUnion(recalculationFailedStockIDs)
            summary.realtimeBlockedStockIDs.formUnion(calculationStocks.filter {
                tech.hasPendingDataRecalculation(in: [$0])
            }.map(\.sId))
        } else {
            summary.realtimeBlockedStockIDs.formUnion(targetStocks.map(\.sId))
            if Task.isCancelled {
                (onRecalculationProgress ?? onProgress)?("更新已中斷，已保存行情與待重算範圍")
            }
        }
        let readyStocks = calculationStocks.filter { stock in
            guard stockInputsReady(for: stock), !tech.hasPendingDataRecalculation(in: [stock]),
                  let last = (try? reads.stockTrades(stock))?.last else { return false }
            return tech.marketObservation(on: last.dateTime)?.hasSimulationValues == true
        }
        let readyIDs = Set(readyStocks.map(\.sId))
        summary.realtimeBlockedStockIDs.formUnion(targetStocks.filter { !readyIDs.contains($0.sId) }.map(\.sId))
        if tech.liveMarketContext != nil && !readyStocks.isEmpty {
            tech.refreshLivePriceScenarios(readyStocks)
            for stock in readyStocks {
                if let latest = try? Trade.last(in: context, for: stock), latest.simMarketIsProvisional {
                    summary.provisionalStockIDs.insert(stock.sId)
                    if latest.isUsingPreviousMarketInput { summary.previousMarketStockIDs.insert(stock.sId) }
                }
            }
        }
        summary.wasInterrupted = Task.isCancelled
        summary.timings.calendarSeconds = calendarFinished - started
        summary.timings.officialSeconds = ProcessInfo.processInfo.systemUptime - calendarFinished
        summary.timings.calendarRequests = calendarDecision.requestCount
        summary.timings.stockHistoryReads = reads.stockHistoryReads
        summary.timings.marketHistoryReads = reads.marketHistoryReads
        summary.timings.marketLookupReloads = tech.marketLookupReloadCount - lookupReloadsBefore
        return summary
    }

    @MainActor
    func updateDailyPrices(
        stocks sourceStocks: [Stock]? = nil,
        clock: @escaping () -> Date = { Date() },
        onProgress: ((String) -> Void)? = nil,
        onRecalculationProgress: ((String) -> Void)? = nil,
        onBatchCompletion: ((TWSEBatchProgress) async -> Int?)? = nil
    ) async -> DailyPriceUpdateSummary {
        let targetStocks = (sourceStocks ?? self.stocks).filter { !$0.group.isEmpty }
        let started = ProcessInfo.processInfo.systemUptime
        let now = clock()
        let updateDay = twDateTime.startOfDay(now)
        var yahooSummary = Technical.YahooUpdateSummary()
        var yahooSeconds: TimeInterval = 0
        var dayStatus = TWSEMarketDayStatus.unknown
        var twseSummary = await updateTWSEPrices(
            stocks: targetStocks, asOf: now, onProgress: onProgress,
            onRecalculationProgress: onRecalculationProgress, onBatchCompletion: onBatchCompletion,
            allowsLiveFallback: true,
            onStockInputsSaved: { status in
                dayStatus = status
                let now = clock()
                guard status == .tradingDay, twDateTime.startOfDay(now) == updateDay else { return }
                if let live = self.tech.liveMarketContext {
                    self.tech.liveMarketContext = .init(asOf: now, previousTradingDay: live.previousTradingDay)
                }
                let yahooStocks = targetStocks.filter { stock in
                    let latest = try? Trade.last(in: self.context, for: stock)
                    let officialToday = latest?.dataSource == "TWSE"
                        && latest.map { twDateTime.startOfDay($0.dateTime) == twDateTime.startOfDay(now) } == true
                    let closeTime = latest?.dataSource == "yahoo" ? latest?.dateTime : nil
                    if let checked = stock.yahooCheckedAt, checked <= now,
                       now.timeIntervalSince(checked) < 120,
                       twDateTime.startOfDay(checked) == twDateTime.startOfDay(now),
                       (now < twDateTime.time1330(now) || closeTime.map { $0 >= twDateTime.time1330(now) } == true) {
                        return false
                    }
                    return DailyPriceUpdatePolicy.shouldRequestYahoo(marketStatus: status, asOf: now,
                        hasOfficialDataForToday: officialToday, lastSuccessfulCloseRefresh: closeTime,
                        calendar: twDateTime.calendar)
                }
                let start = ProcessInfo.processInfo.systemUptime
                yahooSummary = await self.tech.updateYahooPrices(stocks: yahooStocks, updateMarket: false,
                    asOf: now, rawPricesOnly: true, onProgress: onProgress)
                yahooSeconds += ProcessInfo.processInfo.systemUptime - start
            },
            onMarketInputsSaved: { ready in
                let now = clock()
                guard dayStatus == .tradingDay, twDateTime.startOfDay(now) == updateDay else { return false }
                if let live = self.tech.liveMarketContext {
                    self.tech.liveMarketContext = .init(asOf: now, previousTradingDay: live.previousTradingDay)
                }
                let todayMarket = try? MarketDay.fetchSameDay(as: now, in: self.context)
                guard DailyPriceUpdatePolicy.shouldRequestYahoo(marketStatus: dayStatus, asOf: now,
                    hasOfficialDataForToday: todayMarket?.isOfficial == true,
                    lastSuccessfulCloseRefresh: todayMarket?.quoteTime,
                    calendar: twDateTime.calendar) else { return false }
                // Missing prior history cannot be fabricated from one Yahoo tick.
                guard ready else { yahooSummary.marketFailed = true; return false }
                let start = ProcessInfo.processInfo.systemUptime
                let market = await self.tech.updateYahooPrices(stocks: [], updateMarket: true,
                    asOf: now, rawPricesOnly: true, onProgress: onProgress)
                yahooSummary.marketUpdated = market.marketUpdated
                yahooSummary.marketFailed = market.marketFailed
                yahooSeconds += ProcessInfo.processInfo.systemUptime - start
                return market.marketUpdated
            }
        )
        try? context.save()
        twseSummary.timings.yahooSeconds = yahooSeconds
        twseSummary.timings.totalSeconds = ProcessInfo.processInfo.systemUptime - started
        return DailyPriceUpdateSummary(twse: twseSummary, yahoo: yahooSummary)
    }

    private func newStock(stocks:[(sId:String,sName:String)], group:String?=nil) {
        for stock in stocks {
            _ = try? Stock.ensureStock(in: context, sId: stock.sId, sName: stock.sName, group: group, dateFirst: defaults.first, dateStart: defaults.start, simMoneyBase: defaults.money, simInvestAuto: defaults.invest)
        }
        NSLog("new stocks added: \(stocks)")
    }
    
    func reloadNow(_ stocks: [Stock], action: Technical.simAction) {
        do {
            try simulationInputs.prepareReload(stocks, action: action)
            tech.downloadTrades(stocks, requestAction: action, allStocks: self.stocks)
        } catch {
            simLog.addLog("重新計算要求保存失敗，未啟動重算：\(error.localizedDescription)")
        }
    }
    
    func simUpdateNow(action: Technical.simAction?=nil) {
        tech.downloadStocks()    //更新股票代號和簡稱的對照表   doItNow: true
        tech.reviseCompanyInfo(self.stocks)
        DispatchQueue.global().async {
            self.tech.downloadTrades(self.stocks, requestAction: action)
        }

    }
    
    func invalidateTimer() {
        tech.invalidateTimer()
    }
    
    func moveStocksToGroup(
        _ stocks: [Stock],
        group: String = "",
        downloadNewStocks: Bool = true
    ) {
        let newStocks = stocks.filter { $0.group.isEmpty && !group.isEmpty }
        do {
            for stock in stocks {
                try StockHistory.changeGroup(stock, to: group, start: defaults.start,
                    money: defaults.money, investments: defaults.invest, in: context)
            }
            try context.save()
            self.stocks = getStocks()
            if downloadNewStocks && !newStocks.isEmpty {
                tech.downloadTrades(newStocks, requestAction: .newTrades, allStocks: self.stocks)
            }
        } catch {
            context.rollback()
            simLog.addLog("股群更新失敗：\(error.localizedDescription)")
        }
    }

//    func deleteTrades(_ stocks:[Stock], oneMonth:Bool=false) {
//        DispatchQueue.global().async {
//            for stock in stocks {
//                stock.deleteTrades(oneMonth: oneMonth)
//            }
//            DispatchQueue.main.async {
//                let _ = self.technical.downloadTrades(stocks, requestAction: (stocks.count > 1 ? .allTrades : .newTrades), allStocks: self.stocks)    //allTrades才會提示等候訊息
//            }
//        }
//    }

    func addInvest(_ trade: Trade) {
        do {
            guard try simulationInputs.toggleInvestment(trade) else { return }
            tech.downloadTrades([trade.stock], requestAction: .simUpdateFrom(trade.dateTime), allStocks: self.stocks)
        } catch {
            simLog.addLog("手動加碼保存失敗，未啟動重算：\(error.localizedDescription)")
        }
    }
    
    func setReversed(_ trade: Trade) {
        do {
            guard try simulationInputs.toggleReversal(trade) else { return }
            tech.downloadTrades([trade.stock], requestAction: .simUpdateFrom(trade.dateTime), allStocks: self.stocks)
        } catch {
            simLog.addLog("反轉買賣保存失敗，未啟動重算：\(error.localizedDescription)")
        }
    }
    
    func settingStocks(_ stocks:[Stock],dateStart:Date,moneyBase:Double,autoInvest:Double) {
        do {
            let change = try simulationInputs.applySettings(stocks, start: dateStart,
                money: moneyBase, investments: autoInvest)
            guard !change.stocks.isEmpty else { return }
            tech.downloadTrades(change.stocks, requestAction: .simUpdateAll, allStocks: self.stocks)
        } catch {
            simLog.addLog("模擬設定保存失敗，未啟動重算：\(error.localizedDescription)")
        }
    }
    

//    var simDefaults:(first:Date,start:Date,money:Double,invest:Double) {
//        let start = defaults.object(forKey: "simDateStart") as? Date ?? Date.distantFuture
//        let money = defaults.double(forKey: "simMoneyBase")
//        let invest = defaults.double(forKey: "simAutoInvest")
//        let first = twDateTime.calendar.date(byAdding: .year, value: -1, to: start) ?? start
//        return (first,start,money,invest)
//    }
//    
//    func setDefaults(start:Date,money:Double,invest:Double) {
//        defaults.set(start, forKey: "simDateStart")
//        defaults.set(money, forKey: "simMoneyBase")
//        defaults.set(invest,forKey: "simAutoInvest")
//    }
//    
//    var t00:Stock? {
//        let t00 = stocks.filter{$0.sId == "t00"}
//        if t00.count > 0 {
//            return t00[0]
//        }
//        return nil
//    }
    
        
    var groupStocks:[[Stock]] {
        Dictionary(grouping: stocks) { (stock:Stock)  in
            stock.group
        }.values
            .map{$0.map{$0}.sorted{$0.sName < $1.sName}}
            .sorted {$0[0].group < $1[0].group}
    }
    
    func stocksSummary(_ stocks:[Stock], date:Date?=nil) -> (count:Double, roi:Double, days:Double) {
        if stocks.count == 0 {
            return (0,0,0)
        }
        var sumRoi:Double = 0
        var sumDays:Double = 0
        for stock in stocks {
            if let trade = try? stock.lastTrade(in:context) {
                sumRoi += (trade.rollAmtRoi / stock.years)
                sumDays += trade.days
            }
        }
        let count = Double(stocks.count)
        let roi = sumRoi / count
        let days = sumDays / count
        return (count, roi, days)
    }
    


//    var stocksJSON: Data? { try? JSONEncoder().encode(stocks) }
//    init?(stocksJSON: Data?) {
//        if let json = stocksJSON, let s = try? JSONDecoder().decode(Array<Stock>.self, from: json) {
//            stocks = s
//        } else {
//            stocks = []
//        }
//    }

    /*
    // RETIRED: This legacy runner changed the live stocks in place and printed
    // ad-hoc CSV-like output. It has been replaced by InternalBacktestDataset
    // and InternalBacktestReport, which operate on isolated database copies.
    // ==============================
    // simTesting
    // ==============================
    let simTesting:Bool = false
    let simTestStart:Date? = twDateTime.dateFromString("2009/09/01")

    func runTest() {
        let start = self.simTestStart ?? (twDateTime.calendar.date(byAdding: .year, value: -15, to: twDateTime.startOfDay()) ?? Date.distantPast)   //測試15年內每年的模擬3年的成績
        NSLog("")
        NSLog("== simTesting \(twDateTime.stringFromDate(start)) ==")
        var groupRoi:String = ""
        var groupDays:String = ""
        for g in 0...(groupStocks.count - 1) {
            let stocks = groupStocks[g]
            let result = testStocks(stocks, start: start)
            groupRoi = groupRoi + (groupRoi.count > 0 ? ",, " : "") + result.roi
            groupDays = groupDays + (groupDays.count > 0 ? ",, " : "") + result.days
        }
        print("\n")
        print(groupRoi)
        print(groupDays)
        print("\n")
        NSLog("== simTesting finished. ==")
        NSLog("")
    }

    private func testStocks(_ stocks:[Stock], start:Date) -> (roi:String, days:String) {
        var roi:String = ""
        var days:String = ""
        let years:Int = Int(round(Date().timeIntervalSince(start) / 86400 / 365))
        print("\n\n\(stocks[0].group)：(\(stocks.count)) 自\(twDateTime.stringFromDate(start,format:"yyyy"))第\(years)年起 ... ", terminator:"")
        var nextYear:Date = start
        while nextYear <= (twDateTime.calendar.date(byAdding: .year, value: -1, to: twDateTime.startOfDay()) ?? Date.distantPast) {
            settingStocks(stocks, dateStart: nextYear, moneyBase: 500, autoInvest: 2)
            for stock in stocks {
                tech.technicalUpdate(stock: stock, action: .simTesting)
            }
            let endYear = (twDateTime.calendar.date(byAdding: .year, value: 3, to: nextYear) ?? Date.distantFuture)
            let summary = stocksSummary(stocks, date: endYear)
            roi = String(format:"%.1f", summary.roi) + (roi.count > 0 ? ", " : "") + roi
            days = String(format:"%.f", summary.days) + (days.count > 0 ? ", " : "") + days
            print("\(twDateTime.stringFromDate(nextYear, format: "yyyy"))" + String(format:"(%.1f/%.f) ",summary.roi,summary.days), terminator:"")
            nextYear = (twDateTime.calendar.date(byAdding: .year, value: 1, to: nextYear) ?? Date.distantPast)
        }
        return (roi,days)
    }
    */

}
