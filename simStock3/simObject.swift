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
            let skippedYahooStocks = twse.realtimeBlockedStockIDs.count
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
            return "\(marketText)；\(twse.statusText)；\(yahooText)"
        }
    }

    struct TWSEUpdateSummary {
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

        func permitsYahooUpdate(for stockID: String) -> Bool {
            !forwardFailedStockIDs.contains(stockID)
                && !realtimeBlockedStockIDs.contains(stockID)
        }

        var statusText: String {
            let historyText = remainingHistoryMonths > 0
                ? "；歷史尚待補 \(remainingHistoryMonths) 個月份"
                : ""
            let recentText = remainingRecentMonths > 0
                ? "；近期尚待補 \(remainingRecentMonths) 個月份" : ""
            let realtimeText = realtimeBlockedStockIDs.isEmpty ? "" : "；盤中功能暫停"
            if requestedMonths == 0 {
                return remainingHistoryMonths > 0
                    ? "近期股價已是最新\(historyText)\(recentText)\(realtimeText)"
                    : "股價已是最新，歷史資料也已補齊\(realtimeText)"
            } else if failedMonths == 0 {
                return "更新完成（共 \(requestedMonths) 個月份）\(historyText)\(recentText)\(realtimeText)"
            } else {
                return "部分更新完成：\(requestedMonths - failedMonths)/\(requestedMonths) 個月份成功\(historyText)\(recentText)\(realtimeText)"
            }
        }
    }

    private var context: ModelContext
    private let marketStore: MarketDataStore

    var stocks:[Stock] = []


    let tech:Technical

    init(modelContext: ModelContext) {
        self.context = modelContext
        self.marketStore = MarketDataStore(modelContext: modelContext)
        self.tech = Technical(modelContext: modelContext)

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
        
    private func needsForwardUpdate(for stock: Stock, through completedDay: Date?) -> Bool {
        guard let completedDay,
              let latest = try? Trade.fetch(in: context, for: stock, TWSE: true,
                                            fetchLimit: 1, ascending: false).first else { return true }
        return twDateTime.startOfDay(latest.dateTime) < completedDay
    }

    /// Freeze actual work subjects before downloading; reuse through continued
    /// batches and replay phases. Merely inspecting current data isn't work.
    func officialUpdateProgress(stocks: [Stock], allGroupedStocks: [Stock],
                                through completedDay: Date?) -> OperationProgress {
        let pendingIDs = Set(tech.stocksRequiringRecalculation(in: stocks).map(\.sId))
        let inputStocks = stocks.filter { stock in
            if needsForwardUpdate(for: stock, through: completedDay) || pendingIDs.contains(stock.sId) {
                return true
            }
            guard let earliest = try? stock.firstTrade(in: context) else { return false }
            return twDateTime.startOfMonth(earliest.dateTime) > stock.requiredTWSEHistoryStartMonth
        }
        let needsMarketWork = marketStore.inputPlan(stocks: allGroupedStocks,
            through: completedDay)?.hasWork == true
        return OperationProgress(subjects:
            (needsMarketWork ? [.market] : []) + inputStocks.map { .stock($0.sId) })
    }

    @MainActor
    func updateTWSEPrices(
        stocks sourceStocks: [Stock]? = nil,
        onProgress: ((String) -> Void)? = nil,
        onRecalculationProgress: ((String) -> Void)? = nil,
        onBatchCompletion: ((TWSEBatchProgress) async -> Int?)? = nil
    ) async -> TWSEUpdateSummary {
        let requestedStocks = (sourceStocks ?? self.stocks).filter { !$0.group.isEmpty }
        let allGroupedStocks = (try? Stock.fetchGrouped(in: context)) ?? requestedStocks
        // A single-stock refresh must not punch through a store-wide migration.
        // If any grouped stock is still old or dirty, the unified pipeline owns
        // the whole group and only releases realtime features after all succeed.
        var targetStocks = unifiedUpdateScope(for: requestedStocks)
        guard !targetStocks.isEmpty else { return TWSEUpdateSummary() }

        tech.countTWSE = targetStocks.count
        tech.progressTWSE = 0
        tech.errorTWSE = 0
        defer {
            tech.progressTWSE = nil
            tech.countTWSE = nil
        }

        // 大盤和個股先完成同一次正式日資料更新，再查詢 Yahoo 當日行情。
        // S40 首次升級必須先取得完整市場歷史與持久化路徑，才能重播股票模擬。
        let calendarDecision = await tech.refreshTradingCalendar()
        let expectedCompletedTradingDay = await tech.latestCompletedTWSETradingDay()
        if marketStore.inputPlan(stocks: allGroupedStocks, through: expectedCompletedTradingDay)?.hasWork == true {
            targetStocks = allGroupedStocks
            tech.countTWSE = targetStocks.count
        }
        var marketSummary = MarketDataStore.UpdateSummary()
        var summary = TWSEUpdateSummary()
        let currentMonth = twDateTime.startOfMonth()
        var maximumMonthsPerSource = 6
        // These cursors only live for this update session. Continuing does not
        // re-fetch the last successful forward month; cancelling keeps the
        // existing manual-resume behaviour on the next update.
        var nextForwardMonths: [String: Date] = [:]
        var nextMarketForwardMonth: Date?
        var totalRequestedMonths = 0
        var totalMarketRequestedMonths = 0
        var totalMarketDays = 0
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
            let succeeded = await tech.twseRequestAsync(
                stock: stock,
                dateStart: month,
                recalculate: false
            )
            if !succeeded {
                summary.failedMonths += 1
            }
            try? await Task.sleep(for: .seconds(1.5))
            return succeeded
        }

        func latestOfficialTrade(for stock: Stock) -> Trade? {
            (try? Trade.fetch(
                in: context,
                for: stock,
                TWSE: true,
                fetchLimit: 1,
                ascending: false
            ))?.first
        }

        func hasOfficialDataForToday(for stock: Stock) -> Bool {
            guard let latestOfficialTrade = latestOfficialTrade(for: stock) else {
                return false
            }
            return twDateTime.startOfDay(latestOfficialTrade.dateTime) >= twDateTime.startOfDay()
        }

        func remainingHistoryMonthCount(for stock: Stock) -> Int {
            let floorMonth = stock.requiredTWSEHistoryStartMonth
            guard let earliestTrade = try? Trade.fetch(
                in: context,
                for: stock,
                TWSE: true,
                fetchLimit: 1,
                ascending: true
            ).first else {
                let difference = twDateTime.calendar.dateComponents(
                    [.month],
                    from: floorMonth,
                    to: currentMonth
                ).month ?? 0
                return max(0, difference + 1)
            }
            let earliestMonth = twDateTime.startOfMonth(earliestTrade.dateTime)
            return max(
                0,
                twDateTime.calendar.dateComponents(
                    [.month],
                    from: floorMonth,
                    to: earliestMonth
                ).month ?? 0
            )
        }

        let operationProgress = officialUpdateProgress(stocks: targetStocks,
            allGroupedStocks: allGroupedStocks, through: expectedCompletedTradingDay)
        tech.countTWSE = operationProgress.subjects.count

        while true {
            if Task.isCancelled { break }
            marketSummary = await marketStore.update(
                stocks: allGroupedStocks,
                through: expectedCompletedTradingDay,
                maximumHistoryMonths: maximumMonthsPerSource,
                forwardStartMonth: nextMarketForwardMonth,
                onProgress: { message in
                    onProgress?(operationProgress.message(for: .market, message))
                }
            )
            nextMarketForwardMonth = marketSummary.nextForwardMonth ?? nextMarketForwardMonth
            summary = TWSEUpdateSummary(
                marketDayStatus: calendarDecision.status,
                expectedCompletedTradingDay: expectedCompletedTradingDay,
                market: marketSummary
            )

            for stock in targetStocks {
                if Task.isCancelled || summary.failedMonths > 0 || marketSummary.failedMonths > 0 { break }
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
                if needsForwardUpdate(for: stock, through: expectedCompletedTradingDay) {
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

                if hasOfficialDataForToday(for: stock) {
                    summary.officialDataTodayStockIDs.insert(stock.sId)
                }

                // `firstTrade` uses a dateTime-ascending FetchDescriptor with fetchLimit = 1.
                // Query again after the forward phase, then walk backward to the month that
                // contains max(dateStart - 1 year, 2010/01/01).
                guard didCompleteForwardUpdate,
                      let earliestTrade = try? stock.firstTrade(in: context),
                      let monthBeforeEarliest = twDateTime.calendar.date(
                        byAdding: .month,
                        value: -1,
                        to: twDateTime.startOfMonth(earliestTrade.dateTime)
                      ) else {
                    continue
                }

                let twseFirstMonth = twDateTime.startOfMonth(twDateTime.dateFromString("2010/01/01")!)
                let requestedStartMonth = twDateTime.startOfMonth(stock.dateRequestStart)
                let historyFloorMonth = max(twseFirstMonth, requestedStartMonth)
                var historyMonth = twDateTime.startOfMonth(monthBeforeEarliest)
                while historyMonth >= historyFloorMonth && requestedStockMonths < maximumMonthsPerSource {
                    if Task.isCancelled { break }
                    requestedStockMonths += 1
                    if !(await requestMonth(historyMonth, for: stock, phase: "補齊歷史股價")) {
                        break
                    }
                    guard let previous = twDateTime.calendar.date(byAdding: .month, value: -1, to: historyMonth) else {
                        break
                    }
                    historyMonth = twDateTime.startOfMonth(previous)
                }
                if historyMonth >= historyFloorMonth && requestedStockMonths == maximumMonthsPerSource {
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
                continue
            }
            break
        }
        summary.requestedMonths = totalRequestedMonths
        marketSummary.requestedMonths = totalMarketRequestedMonths
        marketSummary.insertedOrUpdatedDays = totalMarketDays

        // The container has already completed the structural schema migration.
        // Semantic T/S migration is deliberately last: complete every official
        // stock/market input, replay once, then open Yahoo and P10.
        let stockInputsReady = summary.failedMonths == 0
            && summary.remainingHistoryMonths == 0
            && summary.remainingRecentMonths == 0
            && !Task.isCancelled
            && summary.forwardFailedStockIDs.isEmpty
            && summary.incompleteHistoryStockIDs.isEmpty

        if stockInputsReady,
           marketSummary.isInputComplete,
           marketSummary.requiresTechnicalRebuild {
            do {
                (onRecalculationProgress ?? onProgress)?(operationProgress.message(for: .market,
                    "大盤 正在重算技術數值"))
                try marketStore.rebuildPricePath()
                marketSummary.requiresTechnicalRebuild = false
                marketSummary.isReadyForSimulation = true
            } catch {
                simLog.addLog("大盤技術數值統一重算失敗：\(error)")
                marketSummary.isReadyForSimulation = false
            }
        }
        if marketSummary.isReadyForSimulation {
            tech.reloadMarketPricePathLookup()
        }
        summary.market = marketSummary

        let officialInputsReady = stockInputsReady
            && marketSummary.isReadyForSimulation

        if officialInputsReady {
            var recalculationFailedStockIDs: Set<String> = []
            let recalculationStocks = tech.stocksRequiringRecalculation(in: targetStocks)
            tech.progressTWSE = 0
            for stock in recalculationStocks {
                tech.progressTWSE = operationProgress.position(of: .stock(stock.sId)) ?? 0
                let neededDataRuleMigration = tech.hasPendingDataRuleMigration(in: [stock])
                do {
                    let actions = try await tech.recoverOrMigrateRecalculationState(for: stock) { message in
                        (onRecalculationProgress ?? onProgress)?(operationProgress.message(for: .stock(stock.sId),
                            "\(stock.sId) \(stock.sName) \(message)"))
                    }
                    summary.userActions.merge(actions)
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
            if !recalculationFailedStockIDs.isEmpty
                || tech.hasPendingDataRecalculation(in: targetStocks) {
                summary.realtimeBlockedStockIDs.formUnion(targetStocks.map(\.sId))
            }
        } else {
            summary.realtimeBlockedStockIDs.formUnion(targetStocks.map(\.sId))
            if tech.hasPendingDataRecalculation(in: targetStocks) {
                (onRecalculationProgress ?? onProgress)?(
                    "正式大盤與個股日資料尚未補齊，暫不重算 \(Technical.dataRuleVersion)"
                )
            }
        }
        return summary
    }

    @MainActor
    func updateDailyPrices(
        stocks sourceStocks: [Stock]? = nil,
        onProgress: ((String) -> Void)? = nil,
        onRecalculationProgress: ((String) -> Void)? = nil,
        onBatchCompletion: ((TWSEBatchProgress) async -> Int?)? = nil
    ) async -> DailyPriceUpdateSummary {
        let targetStocks = (sourceStocks ?? self.stocks).filter { !$0.group.isEmpty }
        let twseSummary = await updateTWSEPrices(
            stocks: targetStocks,
            onProgress: onProgress,
            onRecalculationProgress: onRecalculationProgress,
            onBatchCompletion: onBatchCompletion
        )

        // Yahoo may advance the latest Trade date only after the unified official
        // input and recalculation pipeline completes. The writer also never
        // overwrites a TWSE Trade.
        let now = Date()
        let lastYahooCloseRefresh = defaults.timeYahooCloseRefreshed
        let closeRefreshedStockIDs = defaults.yahooCloseRefreshedStockIDs
        let yahooStocks = targetStocks.filter { stock in
            guard twseSummary.permitsYahooUpdate(for: stock.sId) else { return false }
            return DailyPriceUpdatePolicy.shouldRequestYahoo(
                marketStatus: twseSummary.marketDayStatus,
                asOf: now,
                hasOfficialDataForToday: twseSummary.officialDataTodayStockIDs.contains(stock.sId),
                lastSuccessfulCloseRefresh: closeRefreshedStockIDs.contains(stock.sId)
                    ? lastYahooCloseRefresh
                    : nil,
                calendar: twDateTime.calendar
            )
        }
        let todayMarket = try? MarketDay.fetchSameDay(as: now, in: context)
        let shouldUpdateMarket = twseSummary.market.isReadyForSimulation
            && twseSummary.realtimeBlockedStockIDs.isEmpty
            && todayMarket?.isOfficial != true
            && DailyPriceUpdatePolicy.shouldRequestYahoo(
                marketStatus: twseSummary.marketDayStatus, asOf: now,
                hasOfficialDataForToday: false,
                lastSuccessfulCloseRefresh: todayMarket?.quoteTime,
                calendar: twDateTime.calendar)
        let yahooSummary = yahooStocks.isEmpty && !shouldUpdateMarket
            ? Technical.YahooUpdateSummary()
            : await tech.updateYahooPrices(stocks: yahooStocks, updateMarket: shouldUpdateMarket, onProgress: onProgress)
        let completedAt = Date()
        if twseSummary.marketDayStatus == .tradingDay,
           now >= twDateTime.time1330(now) {
            defaults.recordYahooCloseRefresh(
                stockIDs: yahooSummary.successfulStockIDs,
                at: completedAt
            )
        }
        try? context.save()

        return DailyPriceUpdateSummary(twse: twseSummary, yahoo: yahooSummary)
    }

    private func newStock(stocks:[(sId:String,sName:String)], group:String?=nil) {
        for stock in stocks {
            _ = try? Stock.ensureStock(in: context, sId: stock.sId, sName: stock.sName, group: group, dateFirst: defaults.first, dateStart: defaults.start, simMoneyBase: defaults.money, simInvestAuto: defaults.invest)
        }
        NSLog("new stocks added: \(stocks)")
    }
    
    func reloadNow(_ stocks: [Stock], action: Technical.simAction) {
        for stock in stocks {
            if stock.simInvestAuto == 0 {
                stock.simInvestAuto = 2
            }
        }
        try? context.save()
        tech.downloadTrades(stocks, requestAction: action, allStocks: self.stocks)
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
        guard !trade.isBeforeSimulationStart else { return }
            if trade.simInvestByUser == 0 {
                if trade.simInvestAdded > 0 {
                    trade.simInvestByUser = -1
                } else if trade.simInvestAdded == 0 {
                    trade.simInvestByUser = 1
                }
                trade.stock.simInvestUser += 1
            } else {
//                trade.simInvestByUser = 0
//                trade.stock.simInvestUser -= 1
                trade.resetInvestByUser()
            }
            NSLog("\(trade.stock.sId)\(trade.stock.sName) simInvestUser: \(trade.stock.simInvestUser)")
            try? context.save()
            tech.downloadTrades([trade.stock], requestAction: .simUpdateFrom(trade.dateTime), allStocks: self.stocks)

    }
    
    func setReversed(_ trade: Trade) {
        guard !trade.isBeforeSimulationStart else { return }
        guard let trades = try? Trade.fetch(in: context, for: trade.stock) else { return }
        let simQty = trade.simQty
        if trade.simReversed == "" {
            switch simQty.action {
            case "買":
                if trade.invested > 0 {
                    trade.simReversed = "S+"
                } else {
                    trade.simReversed = "B-"
                }
            case "賣":
                trade.simReversed = "S-"
            case "餘":
                trade.simReversed = "S+"
            default:
                trade.simReversed = "B+"
            }
            trade.stock.simReversed = true
            if trade.simInvestByUser != 0 {
                trade.simInvestByUser = 0
                trade.stock.simInvestUser -= 1
            }
        } else {
            trade.simReversed = ""
        }
        trade.stock.rebuildUserActionSummary(from: trades)
        try? context.save()
        tech.downloadTrades([trade.stock], requestAction: .simUpdateFrom(trade.dateTime), allStocks: self.stocks)
    }
    
    func settingStocks(_ stocks:[Stock],dateStart:Date,moneyBase:Double,autoInvest:Double) {
        do {
            for stock in stocks {
                try StockHistory.changeStart(stock, to: dateStart, in: context)
                stock.simMoneyBase = moneyBase
                stock.simInvestAuto = autoInvest
            }
            try context.save()
            tech.downloadTrades(stocks, requestAction: .simUpdateAll, allStocks: self.stocks)
        } catch {
            context.rollback()
            simLog.addLog("模擬設定未套用：\(error.localizedDescription)")
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
