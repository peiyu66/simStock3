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
            return "\(twse.market.statusText)；\(twse.statusText)；\(yahooText)"
        }
    }

    struct TWSEUpdateSummary {
        var requestedMonths = 0
        var failedMonths = 0
        var remainingHistoryMonths = 0
        var incompleteHistoryStockIDs: Set<String> = []
        var forwardFailedStockIDs: Set<String> = []
        var officialDataTodayStockIDs: Set<String> = []
        var marketDayStatus: TWSEMarketDayStatus = .unknown
        var expectedCompletedTradingDay: Date?
        var userActions = UserActionRecalculationSummary()
        var migratedDataRuleStocks = 0
        var market = MarketDataStore.UpdateSummary()
        var realtimeBlockedStockIDs: Set<String> = []

        func permitsYahooUpdate(for stockID: String) -> Bool {
            !forwardFailedStockIDs.contains(stockID)
                && !realtimeBlockedStockIDs.contains(stockID)
        }

        var statusText: String {
            let historyText = remainingHistoryMonths > 0
                ? "；歷史尚待補 \(remainingHistoryMonths) 個月份"
                : ""
            let realtimeText = realtimeBlockedStockIDs.isEmpty ? "" : "；盤中功能暫停"
            if requestedMonths == 0 {
                return remainingHistoryMonths > 0
                    ? "近期股價已是最新\(historyText)\(realtimeText)"
                    : "股價已是最新，歷史資料也已補齊\(realtimeText)"
            } else if failedMonths == 0 {
                return "更新完成（共 \(requestedMonths) 個月份）\(historyText)\(realtimeText)"
            } else {
                return "部分更新完成：\(requestedMonths - failedMonths)/\(requestedMonths) 個月份成功\(historyText)\(realtimeText)"
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
        
    @MainActor
    func updateTWSEPrices(
        stocks sourceStocks: [Stock]? = nil,
        onProgress: ((String) -> Void)? = nil,
        onRecalculationProgress: ((String) -> Void)? = nil
    ) async -> TWSEUpdateSummary {
        let requestedStocks = (sourceStocks ?? self.stocks).filter { !$0.group.isEmpty }
        let allGroupedStocks = (try? Stock.fetchGrouped(in: context)) ?? requestedStocks
        // A single-stock refresh must not punch through a store-wide migration.
        // If any grouped stock is still old or dirty, the unified pipeline owns
        // the whole group and only releases realtime features after all succeed.
        let targetStocks = unifiedUpdateScope(for: requestedStocks)
        guard !targetStocks.isEmpty else { return TWSEUpdateSummary() }

        tech.countTWSE = targetStocks.count
        tech.progressTWSE = 0
        tech.errorTWSE = 0
        defer {
            tech.progressTWSE = nil
            tech.countTWSE = nil
        }

        // 大盤和個股共用同一次收盤後更新週期，但大盤不做 Yahoo／盤中查詢。
        // S40 首次升級必須先取得完整市場歷史與持久化路徑，才能重播股票模擬。
        let calendarDecision = await tech.refreshTradingCalendar()
        let expectedCompletedTradingDay = await tech.latestCompletedTWSETradingDay()
        var marketSummary = await marketStore.update(
            stocks: allGroupedStocks,
            through: expectedCompletedTradingDay,
            onProgress: onProgress
        )

        var summary = TWSEUpdateSummary(
            marketDayStatus: calendarDecision.status,
            expectedCompletedTradingDay: expectedCompletedTradingDay,
            market: marketSummary
        )
        let currentMonth = twDateTime.startOfMonth()
        let maximumHistoryMonthsPerStock = 6

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

        func requestMonth(_ month: Date, for stock: Stock, stockIndex: Int, phase: String) async -> Bool {
            summary.requestedMonths += 1
            let monthText = twDateTime.stringFromDate(month, format: "yyyy/MM")
            onProgress?("\(stockIndex + 1)/\(targetStocks.count) \(stock.sId) \(stock.sName) \(phase) \(monthText)")
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

        for (index, stock) in targetStocks.enumerated() {
            tech.progressTWSE = index + 1

            // Only re-fetch recent months when the latest authoritative TWSE
            // trade is older than the last official close expected by now.
            // A Yahoo intraday Trade must not make this decision for TWSE.
            let latestTWSETrade = latestOfficialTrade(for: stock)
            let needsForwardUpdate: Bool
            if let expectedCompletedTradingDay, let latestTWSETrade {
                needsForwardUpdate = twDateTime.startOfDay(latestTWSETrade.dateTime)
                    < expectedCompletedTradingDay
            } else {
                needsForwardUpdate = true
            }
            let firstForwardMonth = latestTWSETrade.map {
                twDateTime.startOfMonth($0.dateTime)
            } ?? currentMonth
            var didCompleteForwardUpdate = true
            if needsForwardUpdate {
                for month in months(from: min(firstForwardMonth, currentMonth), through: currentMonth) {
                    if !(await requestMonth(month, for: stock, stockIndex: index, phase: "補近期")) {
                        didCompleteForwardUpdate = false
                        summary.forwardFailedStockIDs.insert(stock.sId)
                        break
                    }
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
            var historyMonthCount = 0

            while historyMonth >= historyFloorMonth && historyMonthCount < maximumHistoryMonthsPerStock {
                historyMonthCount += 1
                if !(await requestMonth(historyMonth, for: stock, stockIndex: index, phase: "補歷史")) {
                    break
                }
                guard let previous = twDateTime.calendar.date(byAdding: .month, value: -1, to: historyMonth) else {
                    break
                }
                historyMonth = twDateTime.startOfMonth(previous)
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

        // The container has already completed the structural schema migration.
        // Semantic T/S migration is deliberately last: complete every official
        // stock/market input, replay once, then open Yahoo and P10.
        let stockInputsReady = summary.failedMonths == 0
            && summary.remainingHistoryMonths == 0
            && summary.forwardFailedStockIDs.isEmpty
            && summary.incompleteHistoryStockIDs.isEmpty

        if stockInputsReady,
           marketSummary.isInputComplete,
           marketSummary.requiresTechnicalRebuild {
            do {
                (onRecalculationProgress ?? onProgress)?("正在統一重算大盤價格路徑")
                try marketStore.rebuildPricePath()
                marketSummary.requiresTechnicalRebuild = false
                marketSummary.isReadyForSimulation = true
            } catch {
                simLog.addLog("大盤價格路徑統一重算失敗：\(error)")
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
            for (index, stock) in targetStocks.enumerated() {
                tech.progressTWSE = index + 1
                let neededDataRuleMigration = tech.hasPendingDataRuleMigration(in: [stock])
                do {
                    let actions = try await tech.recoverOrMigrateRecalculationState(for: stock) { message in
                        (onRecalculationProgress ?? onProgress)?(
                            "\(index + 1)/\(targetStocks.count) "
                            + "\(stock.sId) \(stock.sName) \(message)"
                        )
                    }
                    summary.userActions.merge(actions)
                    if neededDataRuleMigration,
                       !tech.hasPendingDataRuleMigration(in: [stock]) {
                        summary.migratedDataRuleStocks += 1
                    }
                } catch {
                    tech.errorTWSE += 1
                    recalculationFailedStockIDs.insert(stock.sId)
                    (onRecalculationProgress ?? onProgress)?(
                        "\(index + 1)/\(targetStocks.count) "
                        + "\(stock.sId) \(stock.sName) 重算恢復失敗"
                    )
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
        onRecalculationProgress: ((String) -> Void)? = nil
    ) async -> DailyPriceUpdateSummary {
        let targetStocks = (sourceStocks ?? self.stocks).filter { !$0.group.isEmpty }
        let twseSummary = await updateTWSEPrices(
            stocks: targetStocks,
            onProgress: onProgress,
            onRecalculationProgress: onRecalculationProgress
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
        let yahooSummary = yahooStocks.isEmpty
            ? Technical.YahooUpdateSummary()
            : await tech.updateYahooPrices(stocks: yahooStocks, onProgress: onProgress)
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
            var newStocks:[Stock] = []
            for stock in stocks {
                if stock.group == "" && group != "" {
                    if defaults.first < stock.dateFirst {
                        stock.dateFirst = defaults.first
                        stock.dateStart = defaults.start
                    }
                    stock.simMoneyBase = defaults.money
                    stock.simInvestAuto = defaults.invest
                    stock.simInvestUser = 0
                    stock.simInvestExceed = 0
                    stock.simMoneyLacked = false
                    stock.simReversed = false
                    newStocks.append(stock)
                }
                stock.group = group
            }
            try? context.save()
            self.stocks = getStocks()
            if downloadNewStocks && newStocks.count > 0 {
                let _ = tech.downloadTrades(newStocks, requestAction: .newTrades, allStocks: self.stocks)
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
        var dateChanged:Bool = false
        for stock in stocks {
            if dateStart != stock.dateStart {
                stock.dateStart = dateStart
                let dtFirst = twDateTime.calendar.date(byAdding: .year, value: -1, to: dateStart) ?? stock.dateStart
                if dtFirst < stock.dateFirst {
                    stock.dateFirst = dtFirst
                }
                dateChanged = true
            }
            stock.simMoneyBase = moneyBase
            stock.simInvestAuto = autoInvest
            DispatchQueue.main.async {
                try? self.context.save()
            }
        }
        /*
        // RETIRED: The old in-place simTesting runner suppressed persistence
        // updates here. Internal Backtest now runs against an isolated store.
        if !simTesting {
            tech.downloadTrades(stocks, requestAction: (dateChanged ? .allTrades : .simResetAll), allStocks: self.stocks)
        }
        */
        tech.downloadTrades(
            stocks,
            requestAction: (dateChanged ? .allTrades : .simUpdateAll),
            allStocks: self.stocks
        )
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
