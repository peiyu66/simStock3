//
//  simTechnicalRequest.swift
//  simStock21
//
//  Created by peiyu on 2021/5/22.
//  Copyright © 2021 peiyu. All rights reserved.
//

import Foundation
import SwiftData

enum YahooValueParser {
    static func labeledValue(_ label: String, inHTML html: String) -> String? {
        let escapedLabel = NSRegularExpression.escapedPattern(for: label)
        let pattern = ">\(escapedLabel)</span><span[^>]*>([^<]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let valueRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[valueRange])
    }

    static func number(_ rawValue: String, strippingHTML: Bool = false) -> Double? {
        let text = strippingHTML
            ? rawValue.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            : rawValue
        let normalized = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    static func price(_ rawValue: String, strippingHTML: Bool = false) -> Double? {
        guard let value = number(rawValue, strippingHTML: strippingHTML), value > 0 else {
            return nil
        }
        return value
    }

    static func volume(_ rawValue: String, strippingHTML: Bool = false) -> Double? {
        guard let value = number(rawValue, strippingHTML: strippingHTML), value >= 0 else {
            return nil
        }
        return value
    }
}

class Technical {
    struct YahooUpdateSummary {
        var requestedStocks = 0
        var updatedStocks = 0
        var successfulStockIDs: Set<String> = []
    }

    struct CompanyInfoUpdateSummary {
        var requestedStocks = 0
        var updatedStocks = 0
        var unavailableStocks = 0
        var failedStocks = 0
    }

    private struct YahooQuoteResult {
        let succeeded: Bool
        let updated: Bool
    }

    private static let currentTechnicalStateVersion = 1
    private static let currentSimulationStateVersion = 1
    private var timer:Timer?
    var automaticYahooUpdateRequest: (([Stock]) -> Void)?
    private var isOffDay:Bool = false
    private var timeTradesUpdated:Date = defaults.timeTradesUpdated
    private var timeLastTrade:Date = Date.distantPast
    private let requestInterval:TimeInterval = 120
    private var nextInterval:TimeInterval? = nil
    private let tradingCalendar = TWSETradingCalendar.shared
    private var calendarRequestPending = false
    private var companyInfoAttemptedStockIDs: Set<String> = []
    
    private let context: ModelContext

    private var marketTimeInterval:TimeInterval {
        let intervalTill0900 = twDateTime.time0900().timeIntervalSinceNow
        if intervalTill0900 > requestInterval {
            return intervalTill0900
        }
        return requestInterval
    }
    
    private var isMarketingTime:Bool {
        (twDateTime.inMarketingTime(timeLastTrade, forToday: true) || (twDateTime.inMarketingTime(timeTradesUpdated, forToday: true) && twDateTime.inMarketingTime(delay: 2, forToday: true))) && !isOffDay
    }
    
    private var realtime:Bool {
        isMarketingTime || (timeTradesUpdated > twDateTime.time1330(twDateTime.yesterday(), delayMinutes: 3) && timeTradesUpdated < twDateTime.time1330(delayMinutes: 2) && !isOffDay)
    }
    
    enum simAction: Equatable {
        case realtime       //下載了盤中價
        case newTrades      //下載了最近的歷史價
        case allTrades      //下載從頭開始的歷史價，根據cnyes的下載範圍切換到此，也包含simResetAll的工作
        case tUpdateAll     //重算技術數值，也包含simResetAll的工作
        // RETIRED: Legacy live-store test action. Internal Backtest now creates
        // explicit RecalculationPlan values for isolated database copies.
        // case simTesting
        case simUpdateAll   //更新模擬，不清除反轉和加碼
        case simResetAll    //重算模擬，要清除反轉和加碼
        case TWSE
    }

    init(modelContext: ModelContext) {
        self.context = modelContext
//        timeTradesUpdated = defaults.timeTradesUpdated
    }

    @discardableResult
    @MainActor func refreshTradingCalendar(for date: Date = Date()) async -> TWSEMarketDayDecision {
        let decision = await tradingCalendar.decision(for: date)
        isOffDay = decision.status == .closed
        if decision.refreshed {
            simLog.addLog("TWSE 休市日曆已更新並保存。")
        } else if let error = decision.refreshError {
            simLog.addLog("TWSE 休市日曆更新失敗，改用本機資料：\(error)")
        }
        if decision.status == .unknown {
            simLog.addLog("尚無本年度 TWSE 休市日曆；Yahoo 仍依回傳交易日期逐筆核對來源。")
        }
        return decision
    }

    func latestCompletedTWSETradingDay(asOf date: Date = Date()) async -> Date? {
        await tradingCalendar.latestCompletedTradingDay(asOf: date)
    }

    @MainActor
    func updateYahooPrices(
        stocks: [Stock],
        onProgress: ((String) -> Void)? = nil
    ) async -> YahooUpdateSummary {
        invalidateTimer()

        var summary = YahooUpdateSummary()
        for (index, stock) in stocks.enumerated() {
            summary.requestedStocks += 1
            onProgress?("\(index + 1)/\(stocks.count) \(stock.sId) \(stock.sName) 查詢 Yahoo")
            let result = await yahooQuoteAsync(stock)
            if result.succeeded {
                summary.successfulStockIDs.insert(stock.sId)
            }
            if result.updated {
                summary.updatedStocks += 1
            }
        }

        scheduleIntradayYahooUpdates(stocks)
        return summary
    }

    @MainActor
    private func yahooQuoteAsync(_ stock: Stock) async -> YahooQuoteResult {
        await withCheckedContinuation { continuation in
            yahooQuote(stock, participatesInLegacyGroup: false) { result in
                continuation.resume(returning: result)
            }
        }
    }

    @MainActor
    private func scheduleIntradayYahooUpdates(_ stocks: [Stock]) {
        invalidateTimer()
        guard !isOffDay, twDateTime.inMarketingTime() else { return }
        let stockIDs = stocks.map(\.sId)

        timer = Timer.scheduledTimer(withTimeInterval: requestInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isOffDay, twDateTime.inMarketingTime() else {
                    self.invalidateTimer()
                    return
                }
                let currentStocks = (try? Stock.fetch(in: self.context, sId: stockIDs)) ?? []
                if let automaticYahooUpdateRequest = self.automaticYahooUpdateRequest {
                    automaticYahooUpdateRequest(currentStocks)
                } else {
                    _ = await self.updateYahooPrices(stocks: currentStocks)
                }
            }
        }

        if let timer, timer.isValid {
            simLog.addLog("Yahoo 盤中更新排程：" + String(format: "%.1fs", timer.fireDate.timeIntervalSinceNow))
        }
    }
        
    func downloadStocks(doItNow:Bool = false) { //每10天下載股票代號簡稱清單
        if doItNow {
            twseDailyMI()
        } else if let timeStocksDownloaded = defaults.timeStocksDownloaded {
            let days:TimeInterval = (0 - timeStocksDownloaded.timeIntervalSinceNow) / 86400
            if days > 10 {    //10天更新一次
                twseDailyMI()
            } else {
                simLog.addLog("stocks list 上次：\(twDateTime.stringFromDate(timeStocksDownloaded,format: "yyyy/MM/dd HH:mm:ss")), next in \(String(format:"%.1f",10 - days))d")
            }
        } else {
            twseDailyMI()
        }
    }
    
    func reviseCompanyInfo(_ stocks:[Stock]) {
        Task { @MainActor [weak self] in
            _ = await self?.updateCompanyInfoIfNeeded(stocks)
        }
    }

    /// MoneyDJ supplies a ready-made revenue mix string. It is convenient
    /// supplementary company information, not a prerequisite for prices or
    /// simulation, so failures never interrupt the caller's workflow.
    @MainActor
    func updateCompanyInfoIfNeeded(
        _ stocks: [Stock],
        force: Bool = false
    ) async -> CompanyInfoUpdateSummary {
        var summary = CompanyInfoUpdateSummary()
        let groupedStocks = stocks.filter { !$0.group.isEmpty }
        guard !groupedStocks.isEmpty else { return summary }

        let refreshInterval: TimeInterval = 30 * 24 * 60 * 60
        let refreshAll = force
            || defaults.timeCompanyInfoUpdated == nil
            || Date().timeIntervalSince(defaults.timeCompanyInfoUpdated ?? .distantPast) >= refreshInterval

        let candidates = groupedStocks.filter { stock in
            let isMissing = (stock.proport ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return (refreshAll || isMissing)
                && !companyInfoAttemptedStockIDs.contains(stock.sId)
        }
        guard !candidates.isEmpty else { return summary }

        var completedResponses = 0
        for stock in candidates {
            companyInfoAttemptedStockIDs.insert(stock.sId)
            summary.requestedStocks += 1
            do {
                if let companyInfo = try await fetchCompanyInfo(stockID: stock.sId) {
                    completedResponses += 1
                    if stock.proport != companyInfo {
                        stock.proport = companyInfo
                        summary.updatedStocks += 1
                    }
                } else {
                    completedResponses += 1
                    summary.unavailableStocks += 1
                    if stock.proport == nil {
                        stock.proport = ""
                    }
                }
            } catch {
                summary.failedStocks += 1
            }
        }

        try? context.save()
        if refreshAll, completedResponses == candidates.count {
            defaults.setTimeCompanyInfoUpdated()
        }

        var message = "MoneyDJ 主要營收項目：更新 \(summary.updatedStocks)/\(summary.requestedStocks)"
        if summary.unavailableStocks > 0 {
            message += "，無資料 \(summary.unavailableStocks)"
        }
        if summary.failedStocks > 0 {
            message += "，稍後再試 \(summary.failedStocks)"
        }
        simLog.addLog(message)
        return summary
    }
        
    func downloadTrades(
        _ stocks: [Stock],
        requestAction: simAction? = nil,
        allStocks: [Stock]? = nil,
        completion: (() -> Void)? = nil
    ) {
        if let action = requestAction {
            self.runRequest(
                stocks,
                action: action,
                allStocks: allStocks,
                completion: completion
            )
        } else {
            let last1332 = twDateTime.time1330(twDateTime.yesterday(), delayMinutes: 2)
            let time1332 = twDateTime.time1330(delayMinutes: 2)
            let time0858 = twDateTime.time0900(delayMinutes: -2)
            if timeTradesUpdated > time1332 {
                simLog.addLog("上次更新是今天收盤之後。")
                self.progressNotify(-9)
            } else if (isOffDay && twDateTime.isDateInToday(timeTradesUpdated)) {
                simLog.addLog("休市日且今天已更新。")
                self.progressNotify(-9)
            } else if timeTradesUpdated > last1332 && Date() < time0858 {
                simLog.addLog("今天還沒開盤且上次更新是昨收盤後。")
                self.progressNotify(-9)
                self.setupTimer(allStocks ?? stocks)
            } else {
                self.runRequest(allStocks ?? stocks, action: (realtime ? .realtime : .newTrades))
            }
        }
    }
    
    private let allGroup:DispatchGroup = DispatchGroup()
    //這是stocks共用的group，等候全部的背景作業完成時通知主畫面
    private let twseGroup:DispatchGroup = DispatchGroup() //這是控制twse依序下載以避免同時多條連線被拒
    private var stockCount:Int = 0
    private var stockProgress:Int = 0
    private var stockAction:String = ""
    private(set) var isRequestActive = false
    private func progressNotify(_ increase:Int = 0) {
        DispatchQueue.main.async {
            if increase >= 0 {
                self.stockProgress += (self.stockProgress < self.stockCount ? increase : 0)
                let message:String = "\(self.stockAction)(\(self.stockProgress)/\(self.stockCount))"
                NotificationCenter.default.post(name: Notification.Name("requestRunning"), object: nil, userInfo: ["msg":message])  //通知股群清單計算的進度
            } else if increase < -1 {   //不用更新股價，pass!
                NotificationCenter.default.post(name: Notification.Name("requestRunning"), object: nil, userInfo: ["msg":"pass!"])
            } else {    //股價更新完畢，解除UI「背景作業中」的提示
                NotificationCenter.default.post(name: Notification.Name("requestRunning"), object: nil, userInfo: ["msg":""])
            }
        }
    }

    @MainActor private func runRequest(
        _ stocks: [Stock],
        action: simAction = .realtime,
        allStocks: [Stock]? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard !isRequestActive else {
            simLog.addLog("已有股價下載或重算作業，略過重複要求。")
            completion?()
            return
        }
        guard !calendarRequestPending else {
            simLog.addLog("TWSE 休市日曆查詢中，略過重複更新。")
            nextInterval = 30
            completion?()
            return
        }
        isRequestActive = true
        calendarRequestPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshTradingCalendar()
            calendarRequestPending = false
            performRunRequest(
                stocks,
                action: action,
                allStocks: allStocks,
                completion: completion
            )
        }
    }

    @MainActor private func performRunRequest(
        _ stocks: [Stock],
        action: simAction = .realtime,
        allStocks: [Stock]? = nil,
        completion: (() -> Void)? = nil
    ) {
        self.stockCount = stocks.count
        simLog.addLog("\(action)(\(stocks.count)) " + twDateTime.stringFromDate(timeTradesUpdated, format: "上次：yyyy/MM/dd HH:mm:ss") + (isOffDay ? " 今天休市" : " \(self.isMarketingTime ? "盤中待續" : "已收盤")"))
        if self.stockProgress > 0 {
            simLog.addLog("\t前查價未完？？？(\(self.stockProgress)/\(self.stockCount))")
            self.nextInterval = 30
            self.isRequestActive = false
            self.progressNotify(-9)
            completion?()
            return
        }
        if netConnect.isNotOK() {
            simLog.addLog("暫停查價：網路未連線。")
            self.isRequestActive = false
            self.progressNotify(-9)
            completion?()
            return
        }
//        self.twseCount = 0
        self.stockProgress = 1
        for stock in stocks {
            allGroup.enter()
            if action == .realtime && self.realtime {
                self.stockAction = (isOffDay ? "休市日" : "查詢盤中價")
                let op = BlockOperation { [weak self] in
                    guard let self else { return }
                    // Capture a stable identifier to avoid non-Sendable capture warnings
                    let sId = stock.sId
                    Task { @MainActor in
                        // Use the original stock reference only on the main actor where it's safe
                        // Verify id to ensure we're still operating on the intended stock if needed
                        if stock.sId == sId {
                            self.yahooQuote(stock)
                        } else {
                            // Fallback: if identity changed, try to fetch by id and proceed if found
                            if let fetched = try? Stock.fetch(in: self.context, sId: [sId]).first {
                                self.yahooQuote(fetched)
                            }
                        }
                    }
                }
                operation.serialQueue.addOperation(op)

//                operation.serialQueue.addOperation { [weak self] in
//                    guard let strongSelf = self else { return }
//                    let capturedStock = stock
//                    Task { @MainActor in
//                        strongSelf.yahooQuote(capturedStock)
//                    }
//                }
            } else {    //newTrades, allTrades, tUpdateAll, simResetAll, simUpdateAll
                self.stockAction = "請等候股群完成歷史資料的計算"
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("requestRunning"), object: nil, userInfo: ["msg":"請等候股群完成資料的下載..."])  //通知股群清單要更新了
                }
                let op2 = BlockOperation {
                    Task { @MainActor in
                        // Historical prices are downloaded exclusively by the
                        // official TWSE monthly pipeline. Recalculation actions
                        // must remain local and must never trigger Cnyes.
                        self.technicalUpdate(stock: stock, action: action)
                        self.progressNotify(1)
                        // Price downloads and Yahoo checks are owned by
                        // simObject.updateDailyPrices. This legacy worker only
                        // recalculates values already present in SwiftData.
                        self.runP10([stock])
                        self.allGroup.leave()
//                        if action == .allTrades {
//                            backgroundRequest(context: context, technical: self).reviseWithTWSE(stocks)
//                        }
                    }
                }
                operation.serialQueue.addOperation(op2)
            }
        }
        allGroup.notify(queue: .main) {
            self.stockProgress = 0
            self.stockAction = ""
            self.isRequestActive = false
            if  action != .realtime || twDateTime.inMarketingTime() || !self.isMarketingTime {
                self.timeTradesUpdated = Date() //收盤後仍有可能是剛睡醒的收盤前價格？那就維持前timeTradesUpdated不能動
            }
            defaults.setTimeTradesUpdated(self.timeTradesUpdated,)
            simLog.addLog("\(self.isOffDay ? "休市日" : "完成") \(action)\(self.isOffDay ? "" : "(\(stocks.count))") \(twDateTime.stringFromDate(self.timeTradesUpdated, format: "HH:mm:ss")) \(self.isMarketingTime ? "盤中待續" : "已收盤")")
            self.progressNotify(-1) //解除UI「背景作業中」的提示
            completion?()
//            DispatchQueue.main.async {
//                NotificationCenter.default.post(name: Notification.Name("requestRunning"), object: nil, userInfo: ["msg":""])  //解除UI「背景作業中」的提示
//            }
            if self.realtime{
                self.setupTimer(allStocks ?? stocks, timeInterval: self.nextInterval)
            }
        }
    }
    
    func setupTimer(_ stocks:[Stock], timeInterval:TimeInterval?=nil) {
        self.invalidateTimer()
        self.timer = Timer.scheduledTimer(withTimeInterval: (timeInterval ?? self.marketTimeInterval), repeats: false) {_ in
            self.runRequest(stocks, action: .realtime)
        }
        if let t = self.timer, t.isValid {
            simLog.addLog("timer scheduled in " + String(format:"%.1fs",t.fireDate.timeIntervalSinceNow))
        }
    }
    
    func invalidateTimer() {
        self.nextInterval = nil
        if let t = self.timer, t.isValid {
            t.invalidate()
            self.timer = nil
            simLog.addLog("timer invalidated.")
        }
    }

    var hasScheduledPriceUpdate: Bool {
        timer?.isValid == true
    }

    
    
    /*
     action         | tUpdate | simUpdate | simReset
     ---------------+---------+-----------+----------
     realtime       |    v    |     v     |
     newTrades      |    v    |     v     |
     allTrades      |    v    |     v     |    v
     tUpdateAll     |    v    |     v     |    v
     simTesting     |         |     v     |    v
     simUpdateAll   |         |     v     |
     simResetAll    |    v    |     v     |    v
     */
    
    var countTWSE:Int? = nil
    var progressTWSE:Int? = nil
    var errorTWSE:Int = 0
    private(set) var lastRecalculationTrace = RecalculationTrace()

    @discardableResult
    func recalculate(stock: Stock, plan: RecalculationPlan) throws -> RecalculationTrace {
        let trades = try Trade.fetch(in: context, for: stock, ascending: true)
        guard !trades.isEmpty else {
            lastRecalculationTrace = RecalculationTrace()
            return lastRecalculationTrace
        }

        if plan.resetDerivedSimulationState {
            stock.simMoneyLacked = false
            stock.simInvestExceed = 0
        }
        if plan.resetPolicy == .clearUserActions {
            for trade in trades where plan.simulationEnd.map({ trade.dateTime <= $0 }) ?? true {
                trade.simReversed = ""
                if trade.simInvestByUser != 0 {
                    trade.resetInvestByUser()
                }
            }
            stock.simReversed = false
        }

        func firstIndex(onOrAfter date: Date) -> Int? {
            trades.firstIndex { $0.dateTime >= date }
        }

        var trace = RecalculationTrace()
        let technicalStart: Int?
        switch plan.technical {
        case .none:
            technicalStart = nil
        case .all:
            technicalStart = 0
        case .from(let date), .backfill(let date):
            technicalStart = firstIndex(onOrAfter: date)
        }

        if let technicalStart {
            let backfillStopIndex: Int? = {
                guard case .backfill = plan.technical,
                      let firstStableIndex = trades.firstIndex(where: \.tUpdated) else {
                    return nil
                }
                // Volume statistics are stored one Trade later than their raw
                // volume endpoint. Recalculate the first stable price Trade as
                // well, then older backfill can no longer affect either family.
                return min(firstStableIndex + 1, trades.count)
            }()

            for index in technicalStart..<trades.count {
                if let backfillStopIndex, index >= backfillStopIndex {
                    break
                }
                autoreleasepool {
                    self.tUpdate(trades, index: index)
                }
                trace.technicalDates.append(trades[index].dateTime)
            }
            if case .all = plan.technical, plan.saveResults {
                stock.technicalStateVersion = Self.currentTechnicalStateVersion
            }
        }

        let simulationStart: Int?
        switch plan.simulation {
        case .none:
            simulationStart = nil
        case .all:
            simulationStart = 0
        case .from(let date):
            simulationStart = firstIndex(onOrAfter: date)
        }

        if let simulationStart {
            for index in simulationStart..<trades.count {
                if let simulationEnd = plan.simulationEnd,
                   trades[index].dateTime > simulationEnd {
                    break
                }
                autoreleasepool {
                    self.simUpdate(trades, index: index)
                }
                trace.simulationDates.append(trades[index].dateTime)
            }
            if case .all = plan.simulation, plan.saveResults {
                stock.simulationStateVersion = Self.currentSimulationStateVersion
            }
        }

        if plan.saveResults {
            stock.technicalDirtyFrom = nil
            stock.simulationDirtyFrom = nil
            try context.save()
        }
        lastRecalculationTrace = trace
        return trace
    }

    @discardableResult
    func recalculate(stock: Stock, changes: TradeChangeSet) throws -> RecalculationTrace {
        let plan = try recalculationPlan(stock: stock, changes: changes)
        return try recalculate(stock: stock, plan: plan)
    }

    func recalculationPlan(stock: Stock, changes: TradeChangeSet) throws -> RecalculationPlan {
        let trades = try Trade.fetch(in: context, for: stock, ascending: true)
        let firstStableDate = trades.first(where: \.tUpdated)?.dateTime
        var plan = changes.plan(
            simulationStart: stock.dateStart,
            firstStableTechnicalDate: firstStableDate
        )

        // Existing stores predate the working tUpdated marker. Migrate each stock
        // once before incremental ranges are trusted.
        if stock.technicalStateVersion < Self.currentTechnicalStateVersion,
           !changes.isEmpty {
            plan = RecalculationPlan(
                technical: .all,
                simulation: .all,
                resetDerivedSimulationState: true
            )
        } else if trades.count >= 250, firstStableDate == nil, !changes.isEmpty {
            plan = RecalculationPlan(
                technical: .all,
                simulation: .all,
                resetDerivedSimulationState: true
            )
        } else if stock.simulationStateVersion < Self.currentSimulationStateVersion,
                  !changes.isEmpty {
            plan.simulation = .all
            plan.resetDerivedSimulationState = true
        }
        return plan
    }

    func persistDirtyState(for stock: Stock, plan: RecalculationPlan) throws {
        let firstTradeDate = try Trade.first(in: context, for: stock)?.dateTime

        switch plan.technical {
        case .none:
            stock.technicalDirtyFrom = nil
        case .all:
            stock.technicalDirtyFrom = firstTradeDate
        case .from(let date), .backfill(let date):
            stock.technicalDirtyFrom = date
        }

        switch plan.simulation {
        case .none:
            stock.simulationDirtyFrom = nil
        case .all:
            stock.simulationDirtyFrom = firstTradeDate
        case .from(let date):
            stock.simulationDirtyFrom = date
        }
        try context.save()
    }

    func recoverOrMigrateRecalculationState(for stock: Stock) throws {
        let trades = try Trade.fetch(in: context, for: stock, ascending: true)
        guard !trades.isEmpty else { return }

        let needsTechnicalMigration = trades.count >= 250 && !trades.contains(where: \.tUpdated)
        let needsTechnicalVersionMigration = stock.technicalStateVersion
            < Self.currentTechnicalStateVersion
        let needsVolumeStatisticsMigration = trades.count > 1
            && trades.contains { $0.volumeClose != 0 }
            && trades.dropFirst().allSatisfy { $0.vMa20 == 0 && $0.vMa60 == 0 }
        let needsSimulationMigration = stock.simulationStateVersion < Self.currentSimulationStateVersion
        if stock.technicalDirtyFrom != nil || stock.simulationDirtyFrom != nil
            || needsTechnicalMigration || needsTechnicalVersionMigration
            || needsVolumeStatisticsMigration
            || needsSimulationMigration {
            let plan = RecalculationPlan(
                technical: needsTechnicalMigration || needsTechnicalVersionMigration
                    || needsVolumeStatisticsMigration
                    ? .all
                    : stock.technicalDirtyFrom.map { .from($0) } ?? .none,
                simulation: needsTechnicalVersionMigration || needsSimulationMigration
                    ? .all
                    : stock.simulationDirtyFrom.map { .from($0) } ?? .none,
                resetDerivedSimulationState: needsTechnicalVersionMigration
                    || needsSimulationMigration
                    || stock.simulationDirtyFrom != nil
            )
            try recalculate(stock: stock, plan: plan)
        }
    }

    func technicalUpdate (stock:Stock, action:simAction) {
        if action == .realtime {
            let fetched = (try? Trade.fetch(in: context, for: stock, fetchLimit: 251, ascending: false)) ?? []
            let trades = Array(fetched.reversed())
            guard !trades.isEmpty else { return }
            let index = trades.count - 1
            tUpdate(trades, index: index)
            simUpdate(trades, index: index)
            lastRecalculationTrace = RecalculationTrace(
                technicalDates: [trades[index].dateTime],
                simulationDates: [trades[index].dateTime]
            )
            try? context.save()
            return
        }

        let plan: RecalculationPlan
        switch action {
        case .newTrades:
            // Legacy callers do not provide a change set, so retain the safe full pass.
            plan = RecalculationPlan(technical: .all, simulation: .all, resetDerivedSimulationState: true)
        case .allTrades:
            plan = RecalculationPlan(technical: .all, simulation: .all, resetDerivedSimulationState: true)
        case .tUpdateAll:
            plan = RecalculationPlan(
                technical: .all,
                simulation: .all,
                resetPolicy: .clearUserActions,
                resetDerivedSimulationState: true
            )
        /*
        // RETIRED: The old simTesting action limited each live-stock run to
        // three years without saving. InternalBacktestReport now supplies the
        // period and isolated store directly.
        case .simTesting:
            plan = RecalculationPlan(
                technical: .none,
                simulation: .all,
                resetPolicy: .clearUserActions,
                resetDerivedSimulationState: true,
                saveResults: false,
                simulationEnd: twDateTime.calendar.date(
                    byAdding: .year,
                    value: 3,
                    to: stock.dateStart
                )
            )
        */
        case .simUpdateAll:
            plan = RecalculationPlan(
                technical: .none,
                simulation: .all,
                resetDerivedSimulationState: true
            )
        case .simResetAll:
            plan = RecalculationPlan(
                technical: .none,
                simulation: .all,
                resetPolicy: .clearUserActions,
                resetDerivedSimulationState: true
            )
        case .TWSE, .realtime:
            plan = .none
        }

        do {
            let trace = try recalculate(stock: stock, plan: plan)
            let tradesCount = (try? Trade.fetch(in: context, for: stock).count) ?? 0
            let progress = self.progressTWSE ?? self.stockProgress
            let count = self.countTWSE ?? self.stockCount
            simLog.addLog("(\(progress)/\(count))\(stock.sId)\(stock.sName) 歷史價\(tradesCount)筆" + (trace.technicalDates.isEmpty ? "" : "/技術\(trace.technicalDates.count)筆") + (trace.simulationDates.isEmpty ? "" : "/模擬\(trace.simulationDates.count)筆") + " \(action)")
        } catch {
            simLog.addLog("\(stock.sId)\(stock.sName) 重算失敗：\(error)")
        }
    }
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    //== 五檔價格試算建議 ==
    struct P10 {
        var rule:String? = nil
        var action:String? = nil
        var date:Date? = nil
        var L:[String] = []
        var H:[String] = []
    }

    @MainActor
    private func runP10(_ stocks:[Stock]) {
        for stock in stocks {
            let p10 = p10(stock)
            if let action = p10.action {
                stock.p10Action = p10.action
                stock.p10Date = p10.date
                stock.p10L = p10.L.joined(separator: "|")
                stock.p10H = p10.H.joined(separator: "|")
                stock.p10Rule = p10.rule
                try? self.context.save()
                simLog.addLog("P10:\(stock.sId)\(stock.sName):\(action)(L\(p10.L.count),H\(p10.H.count))")
            } else if stock.p10Action != nil {
                stock.p10Reset()
                try? self.context.save()
            }
        }
    
        func p10(_ stock:Stock) -> P10 {
            
            var p10:P10 = P10()
            let fetched = (try? Trade.fetch(in: context, for: stock, fetchLimit: 251, ascending: false)) ?? []
            let trades = Array(fetched.reversed())
            if trades.count > 0 {
                let trade = trades[trades.count - 1]
                let price = trade.priceClose
                guard price.isFinite, price > 0 else {
                    simLog.addLog("P10 略過 \(stock.sId)\(stock.sName)：成交價無效 \(price)")
                    return p10
                }
                let diff = priceDiff(price)
                defer {
                    // P10 temporarily tries ten nearby prices on the live Trade.
                    // Recalculate once with the real quote so no scenario value or
                    // derived simulation field can leak into persistent storage.
                    trade.priceClose = price
                    tUpdate(trades, index: trades.count - 1)
                    simUpdate(trades, index: trades.count - 1)
                }
                p10.date = trade.date
                for i in 1...10 {
                    let d = Double(i > 5 ? i - 5 : i - 6) //-5到-1，1到5
                    trade.priceClose = price + (d * diff)
                    let overHL:Bool = (trade.tHighDiff == 10 && trade.priceClose > trade.priceHigh) || (trade.tLowDiff == 10 && trade.priceClose < trade.priceLow)
                    if overHL {
                        continue //超過漲停或跌停的檔次就不用試算了
                    }
                    tUpdate(trades, index: trades.count - 1)
                    simUpdate(trades, index: trades.count - 1)
                    let simQty = trade.simQty
                    if (simQty.action == "買" || simQty.action == "賣") {
                        let close = String(format: "%.2f", trade.priceClose)
                        let value = (simQty.action == "買" ? String(format:"%.0f",simQty.qty) : String(format:"%.1f%%",simQty.roi))
                        if trade.priceClose < price {
                            p10.L.append("\(close)\(simQty.action)\(value)")
                        } else {
                            p10.H.append("\(close)\(simQty.action)\(value)")
                        }
                        if p10.rule == nil {
                            if trade.simReversed.contains("+") {
                                p10.rule = String(trade.simReversed.prefix(1))
                            } else {
                                p10.rule = trade.simRuleBuy
                            }
                        }
                        if p10.action == nil {
                            p10.action = simQty.action
                        }
                    }
                }
            }
            return p10
        }
        
    }


    private func priceDiff(_ price:Double) -> Double {  //每檔差額
        switch price {
        case let p where p < 10:
            return 0.01
        case let p where p < 50:
            return 0.05
        case let p where p < 100:
            return 0.1
        case let p where p < 500:
            return 0.5
        case let p where p < 1000:
            return 1
        default:
            return 5    //1000元以上檔位
        }
    }
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    private func twseDailyMI() {
        if netConnect.isNotOK() {
            simLog.addLog("放棄代號更新：網路未連線。")
            return
        }
        //        let y = calendar.component(.Year, fromDate: qDate) - 1911
        //        let m = calendar.component(.Month, fromDate: qDate)
        //        let d = calendar.component(.Day, fromDate: qDate)
        //        let YYYMMDD = String(format: "%3d/%02d/%02d", y,m,d)
        //================================================================================
        //從當日收盤行情取股票代號名稱
        //2017-05-24因應TWSE網站改版變更查詢方式為URLRequest
        //https://www.twse.com.tw/exchangeReport/MI_INDEX?response=csv&date=20170523&type=ALLBUT0999

        let url = URL(string: "https://www.twse.com.tw/exchangeReport/MI_INDEX?response=csv&type=ALLBUT0999")
        let urlRequest = URLRequest(url: url!,timeoutInterval: 30)

        let task = URLSession.shared.dataTask(with: urlRequest, completionHandler: {(data, response, error) in
            if error == nil {
                let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosChineseTrad.rawValue))
                if let downloadedData = String(data:data!, encoding:String.Encoding(rawValue: big5)) {

                    /* csv檔案的內容是混合格式：
                     2016年07月19日大盤統計資訊
                     "指數","收盤指數","漲跌(+/-)","漲跌點數","漲跌百分比(%)"
                     寶島股價指數,10452.88,+,26.8,0.26
                     發行量加權股價指數,9034.87,+,26.66,0.3
                     "成交統計","成交金額(元)","成交股數(股)","成交筆數"
                     "1.一般股票","86290700501","2396982245","807880"
                     "2.台灣存託憑證","25070276","4935658","1405"
                     "證券代號","證券名稱","成交股數","成交筆數","成交金額","開盤價","最高價","最低價","收盤價","漲跌(+/-)","漲跌價差","最後揭示買價","最後揭示買量","最後揭示賣價","最後揭示賣量","本益比"
                     ="0050  ","元大台灣50      ","17045587","2165","1179010803","69.2","69.3","68.8","69.25","+","0.1","69.25","615","69.3","40","0.00"
                     "1101  ","台泥            ","10196350","5055","362488555","35.55","35.75","35.4","35.6","+","0.1","35.55","122","35.6","152","25.25"
                     "1102  ","亞泥            ","5021942","3083","144691768","28.7","29","28.55","28.9","+","0.2","28.85","106","28.9","147","27.01"

                     "說明："
                     */

                    //去掉千分位逗號和雙引號
                    var textString:String = ""
                    var quoteCount:Int=0
                    for e in downloadedData {
                        if e == "\r\n" {
                            quoteCount = 0
                        } else if e == "\"" {
                            quoteCount = quoteCount + 1
                        }
                        if e != "," || quoteCount % 2 == 0 {
                            textString.append(e)
                        }
                    }
                    textString = textString.replacingOccurrences(of: " ", with: "")   //去空白
                    textString = textString.replacingOccurrences(of: "\"", with: "")  //去雙引號
                    textString = textString.replacingOccurrences(of: "\r\n", with: "\n")  //去換行

                    let lines:[String] = textString.components(separatedBy: CharacterSet.newlines) as [String]
                    var stockListBegins:Bool = false
                    var allStockCount:Int = 0
                    for (index, lineText) in lines.enumerated() {
                        var line:String = lineText
                        if lineText.first == "=" {
                            stockListBegins = true
                        }
                        if lineText != "" && lineText.contains(",") && lineText.contains(".") && index > 2 && stockListBegins {
                            if lineText.first == "=" {
                                line = lineText.replacingOccurrences(of: "=", with: "")   //去首列等號
                            }

                            let sId = line.components(separatedBy: ",")[0]
                            let sName = line.components(separatedBy: ",")[1]
                            let existing = (try? Stock.fetch(in: self.context, sId: [sId])) ?? []
                            if existing.first == nil {
                                let s = Stock(sId: sId, sName: sName, group: "", dateFirst: Date.distantFuture, dateStart: Date.distantFuture, simInvestAuto: 0, simInvestExceed: 0, simInvestUser: 0, simMoneyBase: 0, simMoneyLacked: false, simReversed: false)
                                self.context.insert(s)
                            }
                            allStockCount += 1
                        }   //if line != ""
                    } //for
                    try? self.context.save()
                    defaults.setTimeStocksDownloaded()
                    simLog.addLog("twseDailyMI(ALLBUT0999): \(allStockCount)筆")
                }   //if let downloadedData
            } else {  //if error == nil
                defaults.remove("timeStocksDownloaded")
                simLog.addLog("twseDailyMI(ALLBUT0999) error:\(String(describing: error))")
            }
        })
        task.resume()
    }

    private func fetchCompanyInfo(stockID: String) async throws -> String? {
        let url = URL(
            string: "https://concords.moneydj.com/z/zc/zca/zca_\(stockID).djhtm"
        )!
        var urlRequest = URLRequest(url: url, timeoutInterval: 30)
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/605.1.12 (KHTML, like Gecko) Version/11.1 Safari/605.1.12"
        urlRequest.addValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let big5 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosChineseTrad.rawValue)
        )
        guard let html = String(
            data: data,
            encoding: String.Encoding(rawValue: big5)
        ) else {
            throw URLError(.cannotDecodeContentData)
        }

        /*
         <td class="t4t1">營收比重</td>
         <td class="t3t1" colspan="7">汽車86.56%、零件13.44% (2019年)</td>
         */
        let pattern = #"營收比重</td>\s*<td[^>]*>(.*?)</td>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
              let match = regex.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let valueRange = Range(match.range(at: 1), in: html) else {
            return nil
        }

        let value = String(html[valueRange])
            .replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    
    
    private func yahooHistory( _ stock:Stock, dateStart:Date, dateEnd:Date, group:DispatchGroup) {
        group.enter()
        let p1 = Int(dateStart.timeIntervalSince1970)
        let p2 = Int(dateEnd.timeIntervalSince1970)
        let url = URL(string: "https://query1.finance.yahoo.com/v7/finance/download/\(stock.sId).TW?period1=\(p1)&period2=\(p2)&interval=1d&events=history&includeAdjustedClose=true" )
        let urlRequest = URLRequest(url: url!,timeoutInterval: 30)
        let task = URLSession.shared.dataTask(with: urlRequest, completionHandler: {(data, response, error) in
            if error == nil {
                if let downloadedData = String(data:data!, encoding:.utf8) {
                    
                    /* csv檔案的內容：
                     Date,Open,High,Low,Close,Adj Close,Volume
                     2019-02-11,36.700001,36.950001,35.950001,36.450001,26.204914,12349555
                     2019-02-12,36.450001,37.349998,36.250000,37.299999,26.816002,9301127
                     */
                    
                    let lines:[String] = downloadedData.components(separatedBy: CharacterSet.newlines) as [String]
                    
                    if lines.count > 2 {
                        var count:Int = 0
                        for (index, line) in lines.enumerated() {
                            if index < 2 {
                                continue
                            }
                            
                            let column = line.components(separatedBy: ",")
                            guard column.count >= 7 else {
                                simLog.addLog("\(stock.sId)\(stock.sName) yahoo 歷史價欄位不足：\(line)")
                                continue
                            }
                            if let dt = twDateTime.dateFromString(column[0],format: "yyyy-MM-dd") {
                                if let close = YahooValueParser.price(column[4]),
                                   let open = YahooValueParser.price(column[1]),
                                   let high = YahooValueParser.price(column[2]),
                                   let low = YahooValueParser.price(column[3]),
                                   let volume = YahooValueParser.volume(column[6]) {
                                    let trade = try? Trade.ensureTrade(in: self.context, for: stock, on: dt)
                                    if let trade {
                                        trade.dateTime = twDateTime.time1330(dt)
                                        trade.priceClose = close
                                        
                                        trade.priceOpen = open
                                        trade.priceHigh = high
                                        trade.priceLow  = low
                                        // Yahoo historical CSV reports shares;
                                        // Trade.volumeClose is stored in lots.
                                        trade.volumeClose = volume / 1000
                                        trade.dataSource   = "yahoo"
                                        count += 1
                                        
                                        if stock.dateFirst > dt {
                                            stock.dateFirst = dt
                                            if stock.dateStart <= stock.dateFirst {
                                                stock.dateStart = twDateTime.calendar.date(byAdding: .day, value: 1, to: stock.dateFirst) ?? stock.dateFirst
                                            }
                                        }
                                    }
                                } else {
                                    simLog.addLog("\(stock.sId)\(stock.sName) yahoo 歷史價含無效數值：\(line)")
                                }   //if let close
                            }   //if let dt
                       
                        }   //for
                        try? self.context.save()
                        simLog.addLog("\(stock.sId)\(stock.sName) yahoo \(twDateTime.stringFromDate(dateStart)) \(count)筆")
                    } else {  //if lines.count > 2
                        simLog.addLog("\(stock.sId)\(stock.sName) yahoo \(twDateTime.stringFromDate(dateStart)) no data")
                    } // if lines.count
                }
            }
            group.leave()
        })
        task.resume()
    }
    
    private func cnyesLegacy(_ stock:Stock, ymdStart:String, ymdEnd:String, cnyesGroup:DispatchGroup, action: simAction) {
        cnyesGroup.enter()
        let url = URL(string: "https://www.cnyes.com/twstock/ps_historyPrice.aspx?code=\(stock.sId)&ctl00$ContentPlaceHolder1$startText=\(ymdStart)&ctl00$ContentPlaceHolder1$endText=\(ymdEnd)")
        let urlRequest = URLRequest(url: url!,timeoutInterval: 30)
        let task = URLSession.shared.dataTask(with: urlRequest, completionHandler: {(data, response, error) in
            if error == nil {
                if let downloadedData = String(data:data!, encoding:.utf8) {

                    let leading     = "<tr class=\'thbtm2\'>\r\n    <th>日期</th>\r\n    <th>開盤</th>\r\n    <th>最高</th>\r\n    <th>最低</th>\r\n    <th>收盤</th>\r\n    <th>漲跌</th>\r\n    <th>漲%</th>\r\n    <th>成交量</th>\r\n    <th>成交金額</th>\r\n    <th>本益比</th>\r\n    </tr>\r\n    "
                    let trailing    = "\r\n</table>\r\n</div>\r\n  <!-- tab:end -->\r\n</div>\r\n<!-- bd3:end -->"
                    if let findRange = downloadedData.range(of: leading+"(.+)"+trailing, options: .regularExpression) {
                        let startIndex = downloadedData.index(findRange.lowerBound, offsetBy: leading.count)
                        let endIndex = downloadedData.index(findRange.upperBound, offsetBy: 0-trailing.count)
                        let textString = downloadedData[startIndex..<endIndex].replacingOccurrences(of: "</td></tr>", with: "\n").replacingOccurrences(of: "<tr><td class=\'cr\'>", with: "").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "</td><td class=\'rt\'>", with: ",").replacingOccurrences(of: "</td><td class=\'rt r\'>", with: ",").replacingOccurrences(of: "</td><td class=\'rt g\'>", with: ",")
                        //日期,開盤,最高,最低,收盤,漲跌,漲%,成交量,交金額,本益比
                        //2017/06/22,217.00,218.00,216.50,218.00,2.50,1.16%,24228,5268473,15.83
                        //2017/06/21,216.00,217.00,214.50,215.50,-1.00,-0.46%,44826,9673307,15.65
                        //2017/06/20,215.00,218.00,214.50,216.50,3.50,1.64%,28684,6208332,15.72
                        var lines:[String] = textString.components(separatedBy: CharacterSet.newlines) as [String]
                        if lines.last == "" {
                            lines.removeLast()
                        }
                        var tradesCount:Int = 0
                        var firstDate:Date = Date.distantFuture
                        for line in lines.reversed() {
                            if let dt0 = twDateTime.dateFromString(line.components(separatedBy: ",")[0]) {
                                let dateTime = twDateTime.time1330(dt0)
                                if let close = Double(line.components(separatedBy: ",")[4]) {
                                    if close > 0 {
                                        if dt0 < firstDate {
                                            firstDate = dt0
                                        }
                                        if let trade = try? Trade.ensureTrade(in: self.context, for: stock, on: dt0) {
                                            if trade.dataSource != "TWSE" {
                                                trade.dateTime = dateTime
                                                trade.priceClose = close
                                                if let open = Double(line.components(separatedBy: ",")[1]) {
                                                    trade.priceOpen = open
                                                }
                                                if let high = Double(line.components(separatedBy: ",")[2]) {
                                                    trade.priceHigh = high
                                                }
                                                if let low  = Double(line.components(separatedBy: ",")[3]) {
                                                    trade.priceLow = low
                                                }
                                                if let volume  = Double(line.components(separatedBy: ",")[7]) {
                                                    trade.volumeClose = volume
                                                }
                                                trade.dataSource = "cnyes"
                                                tradesCount += 1
                                            }
                                        }
                                    }
                                }   //if let close
                            }   //if let dt0
                        }   //for
                        if tradesCount > 0 {
                            simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) cnyes \(ymdStart)~\(ymdEnd) 有效\(tradesCount)筆/全部\(lines.count)筆")
                            try? self.context.save()
                            if twDateTime.stringFromDate(stock.dateFirst) == ymdStart && firstDate > stock.dateFirst {
                                DispatchQueue.main.async {
                                    stock.dateFirst = firstDate
                                    if stock.dateStart <= stock.dateFirst {
                                        stock.dateStart = twDateTime.calendar.date(byAdding: .day, value: 1, to: stock.dateFirst) ?? stock.dateFirst
                                    }
//                                    stock.save()
                                }
                            }
                        } else {
                            simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) cnyes \(ymdStart)~\(ymdEnd) 全部\(lines.count)筆，但無有效交易？")
                        }
                    } else {  //if let findRange 有資料無交易故touch
                        simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) cnyes \(ymdStart)~\(ymdEnd) 解析無交易資料。")
                    }
                } else {  //if let downloadedData 下無資料故touch
                    simLog.addLog("(\(self.stockProgress)/\(self.stockCount))cnyes\(stock.sId)\(stock.sName) \(ymdStart)~\(ymdEnd) 下載無資料。")
                }
            } else {  //if error == nil 下載有失誤也要touch
                simLog.addLog("(\(self.stockProgress)/\(self.stockCount))cnyes\(stock.sId)\(stock.sName) \(ymdStart)~\(ymdEnd) 下載有誤 \(String(describing: error))")
            }
            cnyesGroup.leave()
        })
        task.resume()
     }
     
    private func cnyesRequest(_ stock:Stock, ymdStart:String, ymdEnd:String, cnyesGroup:DispatchGroup, action:simAction) {
//        if let dtStart = twDateTime.dateFromString(ymdStart) {
//            if let dtEnd = twDateTime.dateFromString(ymdEnd) {
//                self.yahooHistory(stock, dateStart: dtStart, dateEnd: dtEnd, group: cnyesGroup)
//            }
//        }
        self.cnyesLegacy(stock, ymdStart: ymdStart, ymdEnd: ymdEnd, cnyesGroup: cnyesGroup, action: action)
        return
    }

    private func cnyesPrice(stock:Stock, cnyesGroup:DispatchGroup, action:simAction) -> Bool {
        var allTrades:Bool = false      //應重頭更新全部的技術值
        if stock.trades.count == 0 {    //資料庫是空的
            let ymdS = twDateTime.stringFromDate(stock.dateFirst)
            let ymdE = twDateTime.stringFromDate()  //今天
            cnyesRequest(stock, ymdStart: ymdS, ymdEnd: ymdE, cnyesGroup: cnyesGroup, action:action)
            allTrades = true
        } else {
            if let firstTrade = try? stock.firstTrade(in: context) {
                if firstTrade.stock.dateFirst < firstTrade.date  {    //起日在首日之前
                    let ymdS = twDateTime.stringFromDate(stock.dateFirst)
                    let ymdE = twDateTime.stringFromDate(firstTrade.dateTime)
                    cnyesRequest(stock, ymdStart: ymdS, ymdEnd: ymdE, cnyesGroup: cnyesGroup, action:action)
                    allTrades = true
                }
            }
            if let lastTrade = try? stock.lastTrade(in: context) {
                if lastTrade.dateTime < twDateTime.startOfDay()  {    //末日在今天之前
                    let ymdS = twDateTime.stringFromDate(lastTrade.dateTime)
                    let ymdE = twDateTime.stringFromDate(twDateTime.startOfDay())
                    cnyesRequest(stock, ymdStart: ymdS, ymdEnd: ymdE, cnyesGroup: cnyesGroup, action:action)
                }
            }
        }
        return allTrades
    }
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    private func yahooRequest(_ stock:Stock) { //, allGroup:DispatchGroup, twseGroup:DispatchGroup) {
        if self.isOffDay {
            self.runP10([stock])
            allGroup.leave()
            return
        }
        let url = URL(string: "https://tw.stock.yahoo.com/q/q?s=" + stock.sId)
        var urlRequest = URLRequest(url: url!,timeoutInterval: 30)
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/605.1.12 (KHTML, like Gecko) Version/11.1 Safari/605.1.12"
        urlRequest.addValue(userAgent, forHTTPHeaderField: "User-Agent")
//        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        let task = URLSession.shared.dataTask(with: urlRequest, completionHandler: {(data, response, error) in
            if error == nil {
                let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosChineseTrad.rawValue))
                if let downloadedData = String(data:data!, encoding:String.Encoding(rawValue: big5)) {
                    
                    /* sample data
                     <td width=160 align=right><font color=#3333FF class=tt>　資料日期: 106/04/25</font></td>\n\t</tr>\n    </table>\n<table border=0 cellSpacing=0 cellpadding=\"0\" width=\"750\">\n  <tr>\n    <td>\n      <table border=2 width=\"750\">\n        <tr bgcolor=#fff0c1>\n          <th align=center >股票<br>代號</th>\n          <th align=center width=\"55\">時間</th>\n          <th align=center width=\"55\">成交</th>\n\n          <th align=center width=\"55\">買進</th>\n          <th align=center width=\"55\">賣出</th>\n          <th align=center width=\"55\">漲跌</th>\n          <th align=center width=\"55\">張數</th>\n          <th align=center width=\"55\">昨收</th>\n          <th align=center width=\"55\">開盤</th>\n\n          <th align=center width=\"55\">最高</th>\n          <th align=center width=\"55\">最低</th>\n          <th align=center>個股資料</th>\n        </tr>\n        <tr>\n          <td align=center width=105><a\n\t  href=\"/q/bc?s=2330\">2330台積電</a><br><a href=\"/pf/pfsel?stocklist=2330;\"><font size=-1>加到投資組合</font><br></a></td>\n                <td align=\"center\" bgcolor=\"#FFFfff\" nowrap>13:11</td>\n                <td align=\"center\" bgcolor=\"#FFFfff\" nowrap><b>191.0</b></td>\n                <td align=\"center\" bgcolor=\"#FFFfff\" nowrap>190.5</td>\n                <td align=\"center\" bgcolor=\"#FFFfff\" nowrap>191.0</td>\n                <td align=\"center\" bgcolor=\"#FFFfff\" nowrap><font color=#ff0000>△1.0\n                <td align=\"center\" bgcolor=\"#FFFfff\" nowrap>23,282</td>\n                <td align=\"center\" bgcolor=\"#FFFfff\" nowrap>190.0</td>\n                <td align=\"center\" bgcolor=\"#FFFfff\" nowrap>190.5</td>\n                <td align=\"center\" bgcolor=\"#FFFfff\" nowrap>191.0</td>\n                <td align=\"center\" bgcolor=\"#FFFfff\" nowrap>189.5</td>\n          <td align=center width=137 class=\"tt\">
                     */

                    //取日期 -> yDate
                    let leading = "<td width=160 align=right><font color=#3333FF class=tt>　資料日期: "
                    let trailing = "</font></td>\n\t</tr>\n    </table>\n<table border=0 cellSpacing=0 cellpadding=\"0\" width=\"750\">\n  <tr>\n    <td>\n      <table border=2 width=\"750\">\n        <tr bgcolor=#fff0c1>\n          <th align=center >股票<br>代號</th>"
                    if let yDateRange = downloadedData.range(of: leading+"(.+)"+trailing, options: .regularExpression) {
                        let startIndex = downloadedData.index(yDateRange.lowerBound, offsetBy: leading.count)
                        let endIndex = downloadedData.index(yDateRange.upperBound, offsetBy: 0-trailing.count)
                        let yDate = downloadedData[startIndex..<endIndex]

                        let leading = "<td align=\"center\" bgcolor=\"#FFFfff\" nowrap>"
                        let trailing = "</td>"
                        let yColumn:[String] = self.matches(for: leading, with: trailing, in: downloadedData)
                        if yColumn.count >= 9 {
                            let yTime = yColumn[0]
                            if let dt =  twDateTime.dateFromString(yDate+" "+yTime, format: "yyyy/MM/dd HH:mm") {
                                if let dt1 = twDateTime.calendar.date(byAdding: .year, value: 1911, to: dt) {
                                    if !twDateTime.isDateInToday(dt1) {
                                        simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo 非今日資料，略過")
                                    } else {
                                        if let close = YahooValueParser.price(yColumn[1], strippingHTML: true),
                                           let open = YahooValueParser.price(yColumn[6], strippingHTML: true),
                                           let high = YahooValueParser.price(yColumn[7], strippingHTML: true),
                                           let low = YahooValueParser.price(yColumn[8], strippingHTML: true),
                                           let volume = YahooValueParser.volume(yColumn[4], strippingHTML: true) {
                                            if let trade = try? Trade.ensureTrade(in: self.context, for: stock, on: dt1) {
                                                let hasAuthoritativeTWSEPrice = trade.dataSource == "TWSE"
                                                    && trade.priceClose.isFinite
                                                    && trade.priceClose > 0
                                                if (dt1 > trade.dateTime || trade.priceClose != close)
                                                    && !hasAuthoritativeTWSEPrice {
                                                    self.timeLastTrade = dt1
                                                    trade.dateTime = dt1
                                                    trade.priceClose = close
                                                    trade.priceOpen = open
                                                    trade.priceHigh = high
                                                    trade.priceLow  = low
                                                    trade.volumeClose = volume
                                                    trade.dataSource   = "yahoo"
                                                    try? self.context.save() //由simTechnical執行trade.objectWillChange.send()
                                                    let sName:String? = stock.sName
                                                    simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(sName ?? "????") yahoo 成交價 \(String(format:"%.2f ",close))" + twDateTime.stringFromDate(dt1, format: "HH:mm:ss"))
                                                    self.technicalUpdate(stock: stock, action: .realtime)
                                                } else {
                                                    simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo 未更新 \(String(format:"%.2f",close))")
                                                }
                                            }
                                        } else {
                                            simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo 行情含無效數值：\(yColumn.prefix(9))")
                                        }
                                    }
                                }   //if let dt0
                            }   //if let dt
                        }   //if yColumn.count >= 9
                    } else {  //取quoteTime: if let yDateRange
                        simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo：解析無交易資料。")
                    }
                }  else { //if let downloadedData =
                    simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo：下載無資料。")
                }   //if let downloadedData
            } else {
                simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo：下載有誤 \(String(describing: error))")
            }   //if error == nil
            self.runP10([stock])
            self.progressNotify(self.stockAction == "查詢盤中價" ? 1 : 0)
            self.allGroup.leave()
        })  //let task =
        task.resume()
    }
    
    private func matches(for leading: String, with trailing: String, in text: String) -> [String] {
        do {    //依頭尾正規式切割欄位
            let regex = try NSRegularExpression(pattern: leading+"([0-9|,.%]+?)"+trailing)
            let nsString = text as NSString
            let results = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
            return results.map {nsString.substring(with: $0.range).replacingOccurrences(of: leading, with: "").replacingOccurrences(of: trailing, with: "")}
        } catch let error {
            simLog.addLog("(\(self.stockProgress)/\(self.stockCount))yahoo matches：正規式切割欄位失敗 \( error.localizedDescription)\n\(leading)\n\(trailing)\n\(text)")
            return []
        }
    }
    
    private func yahooQuote(
        _ stock: Stock,
        participatesInLegacyGroup: Bool = true,
        completion: ((YahooQuoteResult) -> Void)? = nil
    ) { //, allGroup:DispatchGroup, twseGroup:DispatchGroup) {
        var didSucceed = false
        var didUpdate = false
        let url = URL(string: "https://tw.stock.yahoo.com/quote/" + stock.sId)
        let urlRequest = URLRequest(url: url!,timeoutInterval: 30)
        let task = URLSession.shared.dataTask(with: urlRequest, completionHandler: {(data, response, error) in
            Task { @MainActor in
            if error == nil {
                if let downloadedData = String(data:data!, encoding:.utf8) {
                    
                    /* sample data
                     <li class=\"price-detail-item H(32px) Mx(10px) D(f) Jc(sb) Ai(c) Bxz(bb) Px(0px) Py(4px) Bdbs(s) Bdbc($bd-primary-divider) Bdbw(1px)\"><span class=\"C(#232a31) Fz(16px)--mobile Fz(14px)\">開盤</span><span class=\"Fw(600) Fz(16px)--mobile Fz(14px) D(f) Ai(c) C($c-trend-up)\">295.0</span></li>
                     <li class=\"price-detail-item H(32px) Mx(10px) D(f) Jc(sb) Ai(c) Bxz(bb) Px(0px) Py(4px) Bdbs(s) Bdbc($bd-primary-divider) Bdbw(1px)\"><span class=\"C(#232a31) Fz(16px)--mobile Fz(14px)\">最高</span><span class=\"Fw(600) Fz(16px)--mobile Fz(14px) D(f) Ai(c) C($c-trend-up)\">296.5</span></li>
                     <li class=\"price-detail-item H(32px) Mx(10px) D(f) Jc(sb) Ai(c) Bxz(bb) Px(0px) Py(4px) Bdbs(s) Bdbc($bd-primary-divider) Bdbw(1px)\"><span class=\"C(#232a31) Fz(16px)--mobile Fz(14px)\">最低</span><span class=\"Fw(600) Fz(16px)--mobile Fz(14px) D(f) Ai(c) C($c-trend-down)\">289.0</span></li>
                     <li class=\"price-detail-item H(32px) Mx(10px) D(f) Jc(sb) Ai(c) Bxz(bb) Px(0px) Py(4px) Bdbs(s) Bdbc($bd-primary-divider) Bdbw(1px)\"><span class=\"C(#232a31) Fz(16px)--mobile Fz(14px)\">均價</span><span class=\"Fw(600) Fz(16px)--mobile Fz(14px) D(f) Ai(c) C($c-trend-up)\">292.9</span></li>
                     <li class=\"price-detail-item H(32px) Mx(10px) D(f) Jc(sb) Ai(c) Bxz(bb) Px(0px) Py(4px) Bdbs(s) Bdbc($bd-primary-divider) Bdbw(1px)\"><span class=\"C(#232a31) Fz(16px)--mobile Fz(14px)\">成交</span><span class=\"Fw(600) Fz(16px)--mobile Fz(14px)\">1.02</span></li>
                     <li class=\"price-detail-item H(32px) Mx(10px) D(f) Jc(sb) Ai(c) Bxz(bb) Px(0px) Py(4px) Bdbs(s) Bdbc($bd-primary-divider) Bdbw(1px)\"><span class=\"C(#232a31) Fz(16px)--mobile Fz(14px)\">昨收</span><span class=\"Fw(600) Fz(16px)--mobile Fz(14px) D(f) Ai(c)\">290.5</span></li>
                     <li class=\"price-detail-item H(32px) Mx(10px) D(f) Jc(sb) Ai(c) Bxz(bb) Px(0px) Py(4px) Bdbs(s) Bdbc($bd-primary-divider) Bdbw(1px)\"><span class=\"C(#232a31) Fz(16px)--mobile Fz(14px)\">漲跌</span><span class=\"Fw(600) Fz(16px)--mobile Fz(14px) D(f) Ai(c) C($c-trend-down)\"><span class=\"Mend(4px) Bds(s)\" style=\"border-color:#00ab5e transparent transparent transparent;border-width:7px 5px 0 5px\"></span>0.34%</span></li>
                     <li class=\"price-detail-item H(32px) Mx(10px) D(f) Jc(sb) Ai(c) Bxz(bb) Px(0px) Py(4px) Bdbs(s) Bdbc($bd-primary-divider) Bdbw(1px)\"><span class=\"C(#232a31) Fz(16px)--mobile Fz(14px)\">漲跌</span><span class=\"Fw(600) Fz(16px)--mobile Fz(14px) D(f) Ai(c) C($c-trend-down)\"><span class=\"Mend(4px) Bds(s)\" style=\"border-color:#00ab5e transparent transparent transparent;border-width:7px 5px 0 5px\"></span>1.0</span></li>
                     <li class=\"price-detail-item H(32px) Mx(10px) D(f) Jc(sb) Ai(c) Bxz(bb) Px(0px) Py(4px) Bdbs(s) Bdbc($bd-primary-divider) Bdbw(1px)\"><span class=\"C(#232a31) Fz(16px)--mobile Fz(14px)\">總量</span><span class=\"Fw(600) Fz(16px)--mobile Fz(14px)\">348</span></li>
                     <li class=\"price-detail-item H(32px) Mx(10px) D(f) Jc(sb) Ai(c) Bxz(bb) Px(0px) Py(4px) Bdbs(s) Bdbc($bd-primary-divider) Bdbw(1px)\"><span class=\"C(#232a31) Fz(16px)--mobile Fz(14px)\">昨量</span><span class=\"Fw(600) Fz(16px)--mobile Fz(14px)\">1,340</span></li>
                     */

                    //取日期 -> yDate
                    let leading = "<time datatime=\""
                    let trailing = "\">"
                    if let yDateRange = downloadedData.range(of: leading+"(.+?)"+trailing, options: .regularExpression) {
                        let startIndex = downloadedData.index(yDateRange.lowerBound, offsetBy: leading.count)
                        let endIndex = downloadedData.index(yDateRange.upperBound, offsetBy: 0-trailing.count)
                        let yDate = String(downloadedData[startIndex..<endIndex])

                        if let dt =  twDateTime.dateFromString(yDate, format: "yyyy/MM/dd HH:mm") {
                            if dt > Date().addingTimeInterval(300) {
                                simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo 日期在未來，略過")
                            } else {
                                let rawValues = [
                                    "成交": YahooValueParser.labeledValue("成交", inHTML: downloadedData),
                                    "開盤": YahooValueParser.labeledValue("開盤", inHTML: downloadedData),
                                    "最高": YahooValueParser.labeledValue("最高", inHTML: downloadedData),
                                    "最低": YahooValueParser.labeledValue("最低", inHTML: downloadedData),
                                    "總量": YahooValueParser.labeledValue("總量", inHTML: downloadedData)
                                ]
                                if let closeRaw = rawValues["成交"] ?? nil,
                                   let openRaw = rawValues["開盤"] ?? nil,
                                   let highRaw = rawValues["最高"] ?? nil,
                                   let lowRaw = rawValues["最低"] ?? nil,
                                   let volumeRaw = rawValues["總量"] ?? nil,
                                   let close = YahooValueParser.price(closeRaw),
                                   let open = YahooValueParser.price(openRaw),
                                   let high = YahooValueParser.price(highRaw),
                                   let low = YahooValueParser.price(lowRaw),
                                   let volume = YahooValueParser.volume(volumeRaw) {
                                            if let trade = try? Trade.ensureTrade(in: self.context, for: stock, on: dt) {
                                                let hasAuthoritativeTWSEPrice = trade.dataSource == "TWSE"
                                                    && trade.priceClose.isFinite
                                                    && trade.priceClose > 0
                                                if (dt > trade.dateTime || trade.priceClose != close)
                                                    && !hasAuthoritativeTWSEPrice {
                                                    self.timeLastTrade = dt
                                                    trade.dateTime = dt
                                                    trade.priceClose = close
                                                    trade.priceOpen = open
                                                    trade.priceHigh = high
                                                    trade.priceLow  = low
                                                    trade.volumeClose = volume
                                                    trade.dataSource   = "yahoo"
                                                    didUpdate = true
                                                    try? self.context.save() //由simTechnical執行trade.objectWillChange.send()
                                                    let sName:String? = trade.stock.sName
                                                    simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(trade.stock.sId)\(sName ?? "????") yahoo 成交價 \(String(format:"%.2f ",close))" + twDateTime.stringFromDate(dt, format: "HH:mm:ss"))
                                                    self.technicalUpdate(stock: stock, action: .realtime)
                                                } else {
                                                    simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo 未更新 \(String(format:"%.2f",close))")
                                                }
                                                didSucceed = true
                                            }
                                } else {
                                    simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo 行情含無效數值：\(rawValues)")
                                }
                            }
                        }   //if let dt
                    } else {  //取quoteTime: if let yDateRange
                        simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo：解析無交易資料。")
                    }
                }  else {//if let downloadedData
                    simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo：下載無資料。")
                }
            } else {
                simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(stock.sId)\(stock.sName) yahoo：下載有誤 \(String(describing: error))")
            }   //if error == nil
            self.runP10([stock])
            if participatesInLegacyGroup {
                self.progressNotify(self.stockAction == "查詢盤中價" ? 1 : 0)
                self.allGroup.leave()
            }
            completion?(YahooQuoteResult(succeeded: didSucceed, updated: didUpdate))
            }
        })  //let task =
        task.resume()
    }
    
    
    
    
    
    
    
    
    
    
    
    
    @MainActor
    func twseRequestAsync(
        stock: Stock,
        dateStart: Date,
        recalculate: Bool = true
    ) async -> Bool {
        let errorCountBeforeRequest = errorTWSE
        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            group.enter()

            self.twseRequest(
                stock: stock,
                dateStart: dateStart,
                stockGroup: group,
                recalculate: recalculate
            )

            group.notify(queue: .main) {
                continuation.resume()
            }
        }
        return errorTWSE == errorCountBeforeRequest
    }

    func twseRequest(
        stock: Stock,
        dateStart: Date,
        stockGroup: DispatchGroup,
        recalculate: Bool = true
    ) {
        let sId = stock.sId
        let sName = stock.sName
        let dateStartText = twDateTime.stringFromDate(dateStart)
        let ymdStart = twDateTime.stringFromDate(dateStart, format: "yyyyMMdd")

        guard let url = URL(string: "https://www.twse.com.tw/exchangeReport/STOCK_DAY?&date=\(ymdStart)&stockNo=\(sId)") else {
            simLog.addLog("\(sId)\(sName) TWSE \(dateStartText) invalid url")
            errorTWSE += 1
            stockGroup.leave()
            return
        }

        struct TWSETradeRecord {
            let date: Date
            let open: Double
            let high: Double
            let low: Double
            let close: Double
            let volume: Double
        }

        let request = URLRequest(url: url, timeoutInterval: 30)

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                Task { @MainActor in stockGroup.leave() }
                return
            }

            do {
                if let error {
                    throw Technical.requestError.error(msg: "\(error)")
                }

                guard let jsonData = data else {
                    throw Technical.requestError.error(msg: "no data")
                }

                if recalculate, let jsonString = String(data: jsonData, encoding: .utf8) {
                    simLog.addLog("TWSE RAW \(sId): \(jsonString.prefix(200))")
                }

                guard let jroot = try JSONSerialization.jsonObject(
                    with: jsonData,
                    options: .allowFragments
                ) as? [String: Any] else {
                    throw Technical.requestError.error(msg: "invalid jroot")
                }

                guard let stat = jroot["stat"] as? String else {
                    throw Technical.requestError.error(msg: "no stat")
                }

                guard stat == "OK" else {
                    throw Technical.requestError.error(msg: "stat is not OK: \(stat)")
                }

                guard let jdata = jroot["data"] as? [[String]] else {
                    throw Technical.requestError.warning(msg: "沒有交易資料？")
                }

                let records: [TWSETradeRecord] = jdata.compactMap { element in
                    guard element.count >= 7 else { return nil }

                    let ymd = element[0].components(separatedBy: "/")
                    guard ymd.count == 3, let rocYear = Int(ymd[0]) else { return nil }

                    let westernYear = rocYear + 1911
                    let dateText = "\(westernYear)/\(ymd[1])/\(ymd[2])"

                    guard let date = twDateTime.dateFromString(dateText) else { return nil }

                    func number(_ index: Int) -> Double? {
                        guard element.indices.contains(index) else { return nil }
                        let text = element[index]
                            .replacingOccurrences(of: ",", with: "")
                            .replacingOccurrences(of: "--", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        return Double(text)
                    }

                    guard let close = number(6), close > 0 else { return nil }

                    return TWSETradeRecord(
                        date: date,
                        open: number(3) ?? 0,
                        high: number(4) ?? 0,
                        low: number(5) ?? 0,
                        close: close,
                        volume: (number(1) ?? 0) / 1000
                    )
                }

                if recalculate {
                    for r in records.prefix(3) {
                        simLog.addLog("PARSE \(sId): close=\(r.close) open=\(r.open)")
                    }
                }

                // ✅ 關鍵：回 MainActor 寫 SwiftData
                Task { @MainActor in
                    var count = 0
                    let previousFirstDate = try? Trade.first(in: self.context, for: stock)?.dateTime
                    let previousLastDate = try? Trade.last(in: self.context, for: stock)?.dateTime
                    var changes = TradeChangeSet(
                        previousFirstDate: previousFirstDate ?? nil,
                        previousLastDate: previousLastDate ?? nil
                    )

                    for record in records {
                        do {
                            let existing = try Trade.fetch(in: self.context, for: stock, on: record.date)
                            let trade = existing ?? Trade(
                                stock: stock,
                                dateTime: twDateTime.time1330(record.date)
                            )
                            if existing == nil {
                                self.context.insert(trade)
                            }
                            if recalculate {
                                simLog.addLog("BEFORE \(sId): old=\(trade.priceClose) new=\(record.close)")
                            }

                            let epsilon = 0.0001

                            if trade.dataSource == "TWSE",
                               abs(trade.priceClose - record.close) < epsilon,
                               abs(trade.priceOpen - record.open) < epsilon,
                               abs(trade.priceHigh - record.high) < epsilon,
                               abs(trade.priceLow - record.low) < epsilon,
                               abs(trade.volumeClose - record.volume) < epsilon {
                                continue
                            }

                            if existing == nil {
                                changes.insertedDates.insert(record.date)
                            } else {
                                changes.modifiedDates.insert(record.date)
                            }

                            trade.dateTime = twDateTime.time1330(record.date)
                            trade.priceOpen = record.open
                            trade.priceHigh = record.high
                            trade.priceLow = record.low
                            trade.priceClose = record.close
                            trade.volumeClose = record.volume
                            trade.dataSource = "TWSE"

                            if recalculate {
                                simLog.addLog("AFTER \(sId): now=\(trade.priceClose)")
                            }

                            if stock.dateFirst > record.date {
                                stock.dateFirst = record.date

                                if stock.dateStart <= stock.dateFirst {
                                    stock.dateStart =
                                        twDateTime.calendar.date(
                                            byAdding: .day,
                                            value: 1,
                                            to: stock.dateFirst
                                        ) ?? stock.dateFirst
                                }
                            }

                            count += 1
                        } catch {
                            simLog.addLog("\(sId)\(sName) TWSE trade save error: \(error)")
                        }
                    }

                    simLog.addLog("COUNT \(sId): \(count)")
                    if count > 0 {
                        if recalculate {
                            do {
                                let plan = try self.recalculationPlan(stock: stock, changes: changes)
                                // Save raw prices together with recovery markers first. If the
                                // app exits during recalculation, the next run resumes safely.
                                try self.persistDirtyState(for: stock, plan: plan)
                                simLog.addLog("RAW SAVE OK \(sId)")
                                let trace = try self.recalculate(stock: stock, plan: plan)
                                simLog.addLog("RECALC OK \(sId): 技術\(trace.technicalDates.count)筆/模擬\(trace.simulationDates.count)筆")
                            } catch {
                                simLog.addLog("SAVE/RECALC ERROR \(sId): \(error)")
                                self.errorTWSE += 1
                            }
                        } else {
                            do {
                                try self.context.save()
                                simLog.addLog("RAW SAVE OK \(sId): 延後統一重算")
                            } catch {
                                simLog.addLog("RAW SAVE ERROR \(sId): \(error)")
                                self.errorTWSE += 1
                            }
                        }
                        if let lastRecord = records.last,
                           let readback = try? Trade.fetch(in: self.context, for: stock, on: lastRecord.date) {
                            simLog.addLog("READBACK UPDATED \(sId): date=\(twDateTime.stringFromDate(readback.dateTime)) close=\(readback.priceClose)")
                        }
                    }

                    simLog.addLog("\(sId)\(sName) TWSE \(dateStartText) \(count)筆")
                    stockGroup.leave()
                }

            } catch Technical.requestError.warning(let msg) {
                Task { @MainActor in
                    simLog.addLog("\(sId)\(sName) TWSE \(dateStartText) \(msg)")
                    stockGroup.leave()
                }

            } catch Technical.requestError.error(let msg) {
                Task { @MainActor in
                    simLog.addLog("\(sId)\(sName) TWSE \(dateStartText) \(msg)")
                    self.errorTWSE += 1
                    stockGroup.leave()
                }

            } catch {
                Task { @MainActor in
                    simLog.addLog("\(sId)\(sName) TWSE \(dateStartText) \(error)")
                    self.errorTWSE += 1
                    stockGroup.leave()
                }
            }
        }

        task.resume()
    }

    enum requestError: Error {
        case error(msg:String)
        case warning(msg:String)
    }

    /*
    func twseRequest(stock:Stock, dateStart:Date, stockGroup:DispatchGroup) {
        let ymdStart = twDateTime.stringFromDate(dateStart, format: "yyyyMMdd")
        guard let url = URL(string: "https://www.twse.com.tw/exchangeReport/STOCK_DAY?&date=\(ymdStart)&stockNo=\(stock.sId)") else {return}
        let request = URLRequest(url: url,timeoutInterval: 30)
        let task = URLSession.shared.dataTask(with: request, completionHandler: {(data, response, error) in
            do {
                guard let jsonData = data else { throw technical.requestError.error(msg:"no data") }
                guard let jroot = try JSONSerialization.jsonObject(with: jsonData, options: .allowFragments) as? [String:Any] else {throw technical.requestError.error(msg: "invalid jroot") }
                guard let stat = jroot["stat"] as? String else {throw technical.requestError.error(msg:"no rtmessage") }
                if stat != "OK" {
                    throw technical.requestError.error(msg:"stat is not OK")
                }
                guard let jdata = jroot["data"] as? [[String]] else {throw technical.requestError.warning(msg:"沒有交易資料？")}

                /*
                 "date": "20201210"
                 "title": "109年12月 2330 台積電           各日成交資訊"
                 "data": [[109/12/01, 38,341,265, 18,719,729,411, 489.50, 490.00, 483.50, 490.00, +9.50, 24,827], [109/12/02, 60,208,035, 29,970,556,095, 499.50, 500.00, 493.50, 499.00, +9.00, 35,624],
                 ..... [109/12/10, 43,991,133, 22,516,917,355, 511.00, 515.00, 510.00, 512.00, -8.00, 49,079]]
                 "stat": "OK"
                 "notes": ["符號說明:+/-/X表示漲/跌/不比價", "當日統計資訊含一般、零股、盤後定價、鉅額交易，不含拍賣、標購。", "ETF證券代號第六碼為K、M、S、C者，表示該ETF以外幣交易。"]
                 "fields": [日期,成交股數,成交金額,開盤價,最高價,最低價,收盤價,漲跌價差,成交筆數]
                 */
                
                var count:Int = 0
                for element in jdata {
                    let dt0 = element[0]
                    let ymd0 = dt0.components(separatedBy: "/")
                    if let y0 =  Int(ymd0[0]) {
                        let sy0 = String(y0 + 1911)
                        let sdate0 = String(sy0) + "/" + ymd0 [1] + "/" + ymd0[2]
                        if let dt = twDateTime.dateFromString(sdate0) {
                            if let close = Double(element[6].replacingOccurrences(of: ",", with: "")), close > 0 {
                                if let trade = try? Trade.ensureTrade(in: self.context, for: stock, on: dt) {
                                    if trade.dataSource == "TWSE" {
                                        continue
                                    }
                                    trade.dateTime = twDateTime.time1330(dt)
                                    trade.priceClose = close

                                    trade.priceOpen = Double(element[3].replacingOccurrences(of: ",", with: "")) ?? 0
                                    trade.priceHigh = Double(element[4].replacingOccurrences(of: ",", with: "")) ?? 0
                                    trade.priceLow  = Double(element[5].replacingOccurrences(of: ",", with: "")) ?? 0
                                    trade.volumeClose = (Double(element[1].replacingOccurrences(of: ",", with: "")) ?? 0) / 1000
                                    trade.dataSource   = "TWSE"
                                    count += 1
                                    try? self.context.save()
                                    if stock.dateFirst > dt {
                                        DispatchQueue.main.async {
                                            stock.dateFirst = dt
                                            if stock.dateStart <= stock.dateFirst {
                                                stock.dateStart = twDateTime.calendar.date(byAdding: .day, value: 1, to: stock.dateFirst) ?? stock.dateFirst
                                            }
//                                            stock.save()
                                        }
                                    }
                                }
                            }   //if let close
                        }   //if let dt
                    }   //if let dt0
                }   //for
                simLog.addLog("\(stock.sId)\(stock.sName) TWSE \(twDateTime.stringFromDate(dateStart)) \(count)筆")
                if count > 0 {
                    self.technicalUpdate(stock: stock, action: .newTrades)
                }
            } catch technical.requestError.warning(let msg) {
                simLog.addLog("\(stock.sId)\(stock.sName) TWSE \(twDateTime.stringFromDate(dateStart)) \(msg)")
            } catch technical.requestError.error(let msg) {
                simLog.addLog("\(stock.sId)\(stock.sName) TWSE \(twDateTime.stringFromDate(dateStart)) \(msg)")
                self.errorTWSE += 1
            } catch {
                simLog.addLog("\(stock.sId)\(stock.sName) TWSE \(twDateTime.stringFromDate(dateStart)) \(error)")
                self.errorTWSE += 1
            }
            stockGroup.leave()
        })
        task.resume()
    }
    */


    
    
    


    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    

    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    private func tUpdate(_ trades:[Trade], index:Int) {
        let trade = trades[index]
        let demandIndex:Double = (trade.priceHigh + trade.priceLow + (trade.priceClose * 2)) / 4    //算macd用的
        if index > 0 {
            let prev = trades[index - 1]
            let d9  = tradeIndex(9, index:index)
            let d20 = tradeIndex(20, index:index)
            let d60 = tradeIndex(60, index:index)
            //250天約是1年，375是1年半，125天是半年
            let d125 = tradeIndex(125, index: index)
            let d250 = tradeIndex(250, index: index)

            let maxDouble:Double = Double.greatestFiniteMagnitude
            let minDouble:Double = Double.leastNormalMagnitude
            
            var sum60:Double = 0
            var sum20:Double = 0
            //高低價本是下載股價無須置疑，但是五檔試算時，高低界線需要隨試算價而調整
            if trade.priceClose < trade.priceLow {
                trade.priceLow = trade.priceClose
            }
            if trade.priceClose > trade.priceHigh {
                trade.priceHigh = trade.priceClose
            }
            //9天最高價最低價  <-- 要先提供9天高低價計算RSV，然後才能算K,D,J
            var ma60Sum:Double = 0
            trade.tHighMax9 = trade.priceHigh
            trade.tLowMin9  = trade.priceLow
            for (i,t) in trades[d60.thisIndex...index].enumerated() {
                sum60 += t.priceClose
                if i + d60.thisIndex >= d20.thisIndex {
                    sum20 += t.priceClose
                }
                if i + d60.thisIndex >= d9.thisIndex {
                    if t.priceHigh > trade.tHighMax9 {
                        trade.tHighMax9 = t.priceHigh
                    }
                    if t.priceLow < trade.tLowMin9 {
                        trade.tLowMin9 = t.priceLow
                    }
                }
                ma60Sum += t.tMa60Diff  //但是自己的ma60Diff還是0
            }
            //最高價差、最低價差
            let nextLow  = 100 * (prev.priceClose - trade.priceLow + priceDiff(trade.priceLow)) / prev.priceClose
            let nextHigh = 100 * (trade.priceHigh + priceDiff(trade.priceHigh) - prev.priceClose) / prev.priceClose
            trade.tLowDiff  = (nextLow > 10 ? 10 : 100 * (prev.priceClose - trade.priceLow) / prev.priceClose)
            trade.tHighDiff = (nextHigh > 10 ? 10 : 100 * (trade.priceHigh - prev.priceClose) / prev.priceClose)

            //ma60,ma20
            trade.tMa60 = sum60 / d60.thisCount
            trade.tMa20 = sum20 / d20.thisCount
            trade.tMa60Diff    = round(10000 * (trade.priceClose - trade.tMa60) / trade.priceClose) / 100
            trade.tMa20Diff    = round(10000 * (trade.priceClose - trade.tMa20) / trade.priceClose) / 100
            
            //9天最高價最低價  <-- 要先提供9天高低價計算RSV，然後才能算K,D,J
            var kdRSV:Double = 50
            if trade.tHighMax9 != trade.tLowMin9 {
                kdRSV = 100 * (trade.priceClose - trade.tLowMin9) / (trade.tHighMax9 - trade.tLowMin9)
            }

            //k, d, j
            trade.tKdK = ((2 * prev.tKdK / 3) + (kdRSV / 3))
            trade.tKdD = ((2 * prev.tKdD / 3) + (trade.tKdK / 3))
            trade.tKdJ = ((3 * trade.tKdK) - (2 * trade.tKdD))
            
            //MACD
            let doubleDI:Double = 2 * demandIndex
            trade.tOscEma12 = ((11 * prev.tOscEma12) + doubleDI) / 13
            trade.tOscEma26 = ((25 * prev.tOscEma26) + doubleDI) / 27
            let dif:Double = trade.tOscEma12 - trade.tOscEma26
            let doubleDif:Double = 2 * dif
            trade.tOscMacd9 = ((8 * prev.tOscMacd9) + doubleDif) / 10
            trade.tOsc = dif - trade.tOscMacd9
            
            trade.tMa20DiffMax9 = trade.tMa20Diff
            trade.tMa20DiffMin9 = trade.tMa20Diff
            trade.tMa60DiffMax9 = trade.tMa60Diff
            trade.tMa60DiffMin9 = trade.tMa60Diff
            trade.tOscMax9 = trade.tOsc
            trade.tOscMin9 = trade.tOsc
            trade.tKdKMax9 = trade.tKdK
            trade.tKdKMin9 = trade.tKdK
            trade.vMax9 = trade.volumeClose
            trade.vMin9 = trade.volumeClose
            for t in trades[d9.thisIndex...index] {
                //9天最高最低
                if t.tMa20Diff > trade.tMa20DiffMax9 {
                    trade.tMa20DiffMax9 = t.tMa20Diff
                }
                if t.tMa20Diff < trade.tMa20DiffMin9 {
                    trade.tMa20DiffMin9 = t.tMa20Diff
                }
                if t.tMa60Diff > trade.tMa60DiffMax9 {
                    trade.tMa60DiffMax9 = t.tMa60Diff
                }
                if t.tMa60Diff < trade.tMa60DiffMin9 {
                    trade.tMa60DiffMin9 = t.tMa60Diff
                }
                if t.tOsc > trade.tOscMax9 {
                    trade.tOscMax9 = t.tOsc
                }
                if t.tOsc < trade.tOscMin9 {
                    trade.tOscMin9 = t.tOsc
                }
                if t.tKdK > trade.tKdKMax9 {
                    trade.tKdKMax9 = t.tKdK
                }
                if t.tKdK < trade.tKdKMin9 {
                    trade.tKdKMin9 = t.tKdK
                }
                if t.volumeClose > trade.vMax9 {
                    trade.vMax9 = t.volumeClose
                }
                if t.volumeClose < trade.vMin9 {
                    trade.vMin9 = t.volumeClose
                }
            }

            //半年、1年、1年半內的最高價、最低價到今天跌或漲了多少
            func priceHighAndLow (_ dIndex:(prevIndex:Int,prevCount:Double,thisIndex:Int,thisCount:Double)) -> (highDiff:Double, lowDiff:Double) {
                var high:Double = minDouble
                var low:Double = maxDouble
                for t in trades[dIndex.thisIndex...index] {
                    if t.priceHigh > high {
                        high = t.priceHigh
                    }
                    if t.priceLow < low {
                        low = t.priceLow
                    }
                }
                let highDiff:Double = 100 * (trade.priceClose - high) / high
                let lowDiff:Double  = 100 * (trade.priceClose - low) / low
                return (highDiff,lowDiff)
            }
            let pDiff125  = priceHighAndLow(d125)
            let pDiff250  = priceHighAndLow(d250)
            trade.tHighDiff125 = pDiff125.highDiff
            trade.tHighDiff250 = pDiff250.highDiff
            trade.tLowDiff125  = pDiff125.lowDiff
            trade.tLowDiff250  = pDiff250.lowDiff

            //價格與各技術值在半年、1年內的標準分數
            func standardDeviationZ(_ key:String, dIndex:(prevIndex:Int,prevCount:Double,thisIndex:Int,thisCount:Double)) -> Double {
                func value(_ t: Trade, key: String) -> Double {
                    switch key {
                    case "tKdK": return t.tKdK
                    case "tKdD": return t.tKdD
                    case "tKdJ": return t.tKdJ
                    case "tOsc": return t.tOsc
                    case "tMa20Diff": return t.tMa20Diff
                    case "tMa60Diff": return t.tMa60Diff
                    case "priceClose": return t.priceClose
                    case "tHighDiff125": return t.tHighDiff125
                    case "tHighDiff250": return t.tHighDiff250
                    case "tLowDiff125": return t.tLowDiff125
                    case "tLowDiff250": return t.tLowDiff250
                    default: return 0
                    }
                }
                var sum:Double = 0
                for t in trades[dIndex.thisIndex...index] { sum += value(t, key: key) }
                let avg = sum / dIndex.thisCount
                var vsum:Double = 0
                for t in trades[dIndex.thisIndex...index] {
                    let variance = pow((value(t, key: key) - avg), 2)
                    vsum += variance
                }
                let sd = sqrt(vsum / dIndex.thisCount)
                let current = value(trade, key: key)
                return sd == 0 ? 0 : (current - avg) / sd
            }
            trade.tKdKZ125  = standardDeviationZ("tKdK", dIndex:d125)
            trade.tKdKZ250  = standardDeviationZ("tKdK", dIndex:d250)
            trade.tKdDZ125  = standardDeviationZ("tKdD", dIndex:d125)
            trade.tKdDZ250  = standardDeviationZ("tKdD", dIndex:d250)
            trade.tKdJZ125  = standardDeviationZ("tKdJ", dIndex:d125)
            trade.tKdJZ250  = standardDeviationZ("tKdJ", dIndex:d250)
            trade.tOscZ125  = standardDeviationZ("tOsc", dIndex:d125)
            trade.tOscZ250  = standardDeviationZ("tOsc", dIndex:d250)
            trade.tMa20DiffZ125 = standardDeviationZ("tMa20Diff", dIndex:d125)
            trade.tMa20DiffZ250 = standardDeviationZ("tMa20Diff", dIndex:d250)
            trade.tMa60DiffZ125 = standardDeviationZ("tMa60Diff", dIndex:d125)
            trade.tMa60DiffZ250 = standardDeviationZ("tMa60Diff", dIndex:d250)
            trade.tZ125 = standardDeviationZ("priceClose", dIndex:d125)
            trade.tZ250 = standardDeviationZ("priceClose", dIndex:d250)
            trade.tHighDiffZ125 = standardDeviationZ("tHighDiff125", dIndex:d125)
            trade.tHighDiffZ250 = standardDeviationZ("tHighDiff250", dIndex:d250)
            trade.tLowDiffZ125 = standardDeviationZ("tLowDiff125", dIndex:d125)
            trade.tLowDiffZ250 = standardDeviationZ("tLowDiff250", dIndex:d250)

            var ma20DaysBefore: Double = 0
            if prev.tMa20Days < 0 && prev.tMa20Days > -5 && index >= Int(0 - prev.tMa20Days + 1) {
                ma20DaysBefore = trades[index - Int(0 - prev.tMa20Days + 1)].tMa20Days
            } else if prev.tMa20Days > 0 && prev.tMa20Days < 5 && index > Int(prev.tMa20Days + 1) {
                ma20DaysBefore = trades[index - Int(prev.tMa20Days + 1)].tMa20Days
            }
            if trade.tMa20 > prev.tMa20 {
                if prev.tMa20Days < 0  {
                    if prev.tMa20Days > -5 && ma20DaysBefore > 0 {
                        trade.tMa20Days = ma20DaysBefore + 1
                    } else {
                        trade.tMa20Days = 1
                    }
                } else {
                    trade.tMa20Days = prev.tMa20Days + 1
                }
            } else if trade.tMa20 < prev.tMa20 {
                if prev.tMa20Days > 0  {
                    if prev.tMa20Days < 5 && ma20DaysBefore < 0 {
                        trade.tMa20Days = ma20DaysBefore - 1
                    } else {
                        trade.tMa20Days = -1
                    }
                } else {
                    trade.tMa20Days = prev.tMa20Days - 1
                }
            } else {
                if prev.tMa20Days > 0 {
                    trade.tMa20Days = prev.tMa20Days + 1
                } else if prev.tMa20Days < 0 {
                    trade.tMa20Days = prev.tMa20Days - 1
                } else {
                    trade.tMa20Days = 0
                }
            }


            var ma60DaysBefore: Double = 0
            if prev.tMa60Days < 0 && prev.tMa60Days > -5 && index >= Int(0 - prev.tMa60Days + 1) {
                ma60DaysBefore = trades[index - Int(0 - prev.tMa60Days + 1)].tMa60Days
            } else if prev.tMa60Days > 0 && prev.tMa60Days < 5 && index >= Int(prev.tMa60Days + 1) {
                ma60DaysBefore = trades[index - Int(prev.tMa60Days + 1)].tMa60Days
            }
            if trade.tMa60 > prev.tMa60 {
                if prev.tMa60Days < 0  {
                    if prev.tMa60Days > -5 && ma60DaysBefore > 0 {
                        trade.tMa60Days = ma60DaysBefore + 1
                    } else {
                        trade.tMa60Days = 1
                    }
                } else {
                    trade.tMa60Days = prev.tMa60Days + 1
                }
            } else if trade.tMa60 < prev.tMa60 {
                if prev.tMa60Days > 0  {
                    if prev.tMa60Days < 5 && ma60DaysBefore < 0 {
                        trade.tMa60Days = ma60DaysBefore - 1
                    } else {
                        trade.tMa60Days = -1
                    }
                } else {
                    trade.tMa60Days = prev.tMa60Days - 1
                }
            } else {
                if prev.tMa60Days > 0 {
                    trade.tMa60Days = prev.tMa60Days + 1
                } else if prev.tMa60Days < 0 {
                    trade.tMa60Days = prev.tMa60Days - 1
                } else {
                    trade.tMa60Days = 0
                }
            }
            if d250.thisCount >= 250 {
                trade.tUpdated = true
            } else {
                trade.tUpdated = false
            }
        } else {
            trade.tKdK = 50
            trade.tKdD = 50
            trade.tKdJ = 50
            trade.tOscEma12 = demandIndex
            trade.tOscEma26 = demandIndex
            trade.tUpdated = false
        }

        vUpdate(trades, index: index)
    }

    /// Calculates volume indicators using information available before the
    /// target Trade. The latest eligible endpoint must be a non-zero close at
    /// or after 13:30. Zeroes inside an established window remain observations.
    private func vUpdate(_ trades: [Trade], index: Int) {
        let trade = trades[index]

        func clear() {
            trade.vMa20 = 0
            trade.vMa20Days = 0
            trade.vMa20Diff = 0
            trade.vMa20DiffMax9 = 0
            trade.vMa20DiffMin9 = 0
            trade.vMa20DiffZ125 = 0
            trade.vMa20DiffZ250 = 0
            trade.vMa60 = 0
            trade.vMa60Days = 0
            trade.vMa60Diff = 0
            trade.vMa60DiffMax9 = 0
            trade.vMa60DiffMin9 = 0
            trade.vMa60DiffZ125 = 0
            trade.vMa60DiffZ250 = 0
            trade.vZ125 = 0
            trade.vZ250 = 0
        }

        guard index > 0,
              let endpoint = volumeEndpointIndex(in: trades, before: index) else {
            clear()
            return
        }

        // If no newer eligible close exists, retain the same observation
        // without advancing Days, extrema, or Z-score windows.
        if let previousEndpoint = volumeEndpointIndex(in: trades, before: index - 1),
           previousEndpoint == endpoint {
            copyVolumeStatistics(from: trades[index - 1], to: trade)
            return
        }

        func averageVolume(_ count: Int) -> Double {
            let start = max(0, endpoint - count + 1)
            let values = trades[start...endpoint].map(\.volumeClose)
            return values.reduce(0, +) / Double(values.count)
        }

        let endpointVolume = trades[endpoint].volumeClose
        trade.vMa20 = averageVolume(20)
        trade.vMa60 = averageVolume(60)
        trade.vMa20Diff = roundedPercentDifference(endpointVolume, trade.vMa20)
        trade.vMa60Diff = roundedPercentDifference(endpointVolume, trade.vMa60)

        // Raw-volume Z scores use the same formula as price Z scores, but only
        // advance from a complete, non-zero close at or after 13:30. Once such
        // an endpoint exists, interior zero-volume observations remain part of
        // the chronological window, matching the volume-average convention.
        func recentVolumes(_ count: Int) -> [Double] {
            let start = max(0, endpoint - count + 1)
            return trades[start...endpoint].reversed().map(\.volumeClose)
        }
        trade.vZ125 = volumeZScore(recentVolumes(125))
        trade.vZ250 = volumeZScore(recentVolumes(250))

        // Each target in this chain represents one distinct eligible endpoint.
        var observationTargets = [index]
        var cursor = endpoint
        while cursor > 0 && observationTargets.count < 250 {
            observationTargets.append(cursor)
            guard let earlier = volumeEndpointIndex(in: trades, before: cursor) else { break }
            cursor = earlier
        }

        if observationTargets.count > 1 {
            let previous = trades[observationTargets[1]]
            trade.vMa20Days = volumeTrendDays(
                current: trade.vMa20,
                previous: previous.vMa20,
                previousDays: previous.vMa20Days,
                observationTargets: observationTargets,
                trades: trades,
                days: \.vMa20Days
            )
            trade.vMa60Days = volumeTrendDays(
                current: trade.vMa60,
                previous: previous.vMa60,
                previousDays: previous.vMa60Days,
                observationTargets: observationTargets,
                trades: trades,
                days: \.vMa60Days
            )
        } else {
            trade.vMa20Days = 0
            trade.vMa60Days = 0
        }

        let recent9 = observationTargets.prefix(9).map { trades[$0] }
        let ma20Diff9 = recent9.map(\.vMa20Diff)
        let ma60Diff9 = recent9.map(\.vMa60Diff)
        trade.vMa20DiffMax9 = ma20Diff9.max() ?? trade.vMa20Diff
        trade.vMa20DiffMin9 = ma20Diff9.min() ?? trade.vMa20Diff
        trade.vMa60DiffMax9 = ma60Diff9.max() ?? trade.vMa60Diff
        trade.vMa60DiffMin9 = ma60Diff9.min() ?? trade.vMa60Diff

        trade.vMa20DiffZ125 = volumeZScore(
            observationTargets.prefix(125).map { trades[$0].vMa20Diff }
        )
        trade.vMa20DiffZ250 = volumeZScore(
            observationTargets.prefix(250).map { trades[$0].vMa20Diff }
        )
        trade.vMa60DiffZ125 = volumeZScore(
            observationTargets.prefix(125).map { trades[$0].vMa60Diff }
        )
        trade.vMa60DiffZ250 = volumeZScore(
            observationTargets.prefix(250).map { trades[$0].vMa60Diff }
        )
    }

    private func volumeEndpointIndex(in trades: [Trade], before index: Int) -> Int? {
        guard index > 0 else { return nil }
        for candidate in stride(from: index - 1, through: 0, by: -1) {
            let endpoint = trades[candidate]
            let time = twDateTime.calendar.dateComponents([.hour, .minute], from: endpoint.dateTime)
            let hour = time.hour ?? 0
            let minute = time.minute ?? 0
            let isClosed = hour > 13 || (hour == 13 && minute >= 30)
            if isClosed && endpoint.volumeClose != 0 {
                return candidate
            }
        }
        return nil
    }

    private func roundedPercentDifference(_ value: Double, _ average: Double) -> Double {
        guard value != 0 else { return 0 }
        return round(10000 * (value - average) / value) / 100
    }

    private func copyVolumeStatistics(from source: Trade, to target: Trade) {
        target.vMa20 = source.vMa20
        target.vMa20Days = source.vMa20Days
        target.vMa20Diff = source.vMa20Diff
        target.vMa20DiffMax9 = source.vMa20DiffMax9
        target.vMa20DiffMin9 = source.vMa20DiffMin9
        target.vMa20DiffZ125 = source.vMa20DiffZ125
        target.vMa20DiffZ250 = source.vMa20DiffZ250
        target.vMa60 = source.vMa60
        target.vMa60Days = source.vMa60Days
        target.vMa60Diff = source.vMa60Diff
        target.vMa60DiffMax9 = source.vMa60DiffMax9
        target.vMa60DiffMin9 = source.vMa60DiffMin9
        target.vMa60DiffZ125 = source.vMa60DiffZ125
        target.vMa60DiffZ250 = source.vMa60DiffZ250
        target.vZ125 = source.vZ125
        target.vZ250 = source.vZ250
    }

    private func volumeTrendDays(
        current: Double,
        previous: Double,
        previousDays: Double,
        observationTargets: [Int],
        trades: [Trade],
        days: KeyPath<Trade, Double>
    ) -> Double {
        var daysBeforeRun = 0.0
        let runLength = Int(abs(previousDays))
        if runLength > 0,
           runLength < 5,
           observationTargets.indices.contains(runLength + 1) {
            daysBeforeRun = trades[observationTargets[runLength + 1]][keyPath: days]
        }

        if current > previous {
            if previousDays < 0 {
                return previousDays > -5 && daysBeforeRun > 0 ? daysBeforeRun + 1 : 1
            }
            return previousDays + 1
        }
        if current < previous {
            if previousDays > 0 {
                return previousDays < 5 && daysBeforeRun < 0 ? daysBeforeRun - 1 : -1
            }
            return previousDays - 1
        }
        if previousDays > 0 { return previousDays + 1 }
        if previousDays < 0 { return previousDays - 1 }
        return 0
    }

    private func volumeZScore(_ values: [Double]) -> Double {
        guard let current = values.first, !values.isEmpty else { return 0 }
        let average = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - average, 2) } / Double(values.count)
        let standardDeviation = sqrt(variance)
        return standardDeviation == 0 ? 0 : (current - average) / standardDeviation
    }
    
    func tradeIndex(_ count:Double, index:Int) ->  (prevIndex:Int,prevCount:Double,thisIndex:Int,thisCount:Double) {
        let cnt:Double = (count < 1 ? 1 : round(count)) //count最小是1
        var prevIndex:Int = 0       //前第幾筆的Index不包含自己
        var prevCount:Double = 0    //前第幾筆的總筆數不包含自己
        var thisIndex:Int = 0       //前第幾筆的Index有包含自己
        var thisCount:Double = 0    //前第幾筆的總筆數有包含自己
        if index >= Int(cnt) {
            prevCount = cnt //前1天那筆開始算往前有幾筆用來平均ma60，含前1天自己
            prevIndex = index - Int(cnt)   //是自第幾筆起算
            thisCount = cnt
            thisIndex = prevIndex + 1
        } else {
            prevCount = Double(index)
            thisCount = prevCount + 1
            thisIndex = 0
            prevIndex = 0
        }
        return (prevIndex,prevCount,thisIndex,thisCount)
    }
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    

    private func simUpdate(_ trades:[Trade], index:Int) {
        let trade = trades[index]
        if index == 0 || trade.date < trade.stock.dateStart {
            trade.setDefaultValues()
            trade.simRule = "_"
            if index == trades.count - 1 {
                trade.stock.simMoneyLacked = false
                trade.stock.simInvestExceed = 0
            }
            return
        }
        let prev = trades[index - 1]
        trade.resetSimValues()
        trade.simMoneyLackedCumulative = prev.simMoneyLackedCumulative
        trade.simInvestExceedCumulative = prev.simInvestExceedCumulative
        trade.rollDays = prev.rollDays
        //cost,profit,roi:等最後面更新才有效，但grade會參考到，故...
        trade.rollAmtCost = prev.rollAmtCost
        trade.rollAmtProfit = prev.rollAmtProfit
        trade.rollAmtRoi = prev.rollAmtRoi
        //cost,profit,roi:需跟著上一筆更動，期間變動重算模擬時，判斷條件才會一致
        trade.simAmtBalance = (prev.simRule == "_" ? trade.stock.moneyBase : prev.simAmtBalance)
        trade.simInvestTimes = prev.simInvestTimes
        trade.rollRounds = prev.rollRounds
        var rollAmtCost = prev.rollAmtCost * prev.rollDays
        if prev.simQtyInventory > 0 { //前筆有庫存，更新結餘
            trade.simAmtCost = prev.simAmtCost
            trade.simQtyInventory = prev.simQtyInventory
            trade.simUnitCost = prev.simUnitCost
            trade.simUnitRoi = 100 * (trade.priceClose - trade.simUnitCost) / trade.simUnitCost
            let intervalDays = round(Double(trade.date.timeIntervalSince(prev.date)) / 86400)
            trade.simDays = prev.simDays + intervalDays
            trade.rollDays += intervalDays
            trade.simRuleBuy = prev.simRuleBuy
            rollAmtCost -= (prev.simAmtCost * prev.simDays)
        } else { //前筆沒有庫存，就沒有成本什麼的
            if prev.simQtySell > 0 {
                if trade.simInvestByUser != 0 {
//                    trade.simInvestByUser = 0
//                    trade.stock.simInvestUser -= 1
                    trade.resetInvestByUser()

                }
                if trade.simInvestTimes > 1 {
                    trade.simInvestAdded = 1 - trade.simInvestTimes
                } else {
                    trade.simInvestAdded = 0
                }
//            } else if trade.simInvestTimes == 0 {
//                trade.simInvestTimes = 1
            }
            trade.simInvestTimes = 1
        }

//        if twDateTime.stringFromDate(trade.dateTime) == "2021/06/24" && trade.stock.sId == "1590" {
//            NSLog("\(trade.stock.sId)\(trade.stock.sName) tracking... ")
//        }
        
        let ma20d = trade.tMa20DiffMax9 - trade.tMa20DiffMin9
        let ma60d = trade.tMa60DiffMax9 - trade.tMa60DiffMin9
        
        let min9s:Int = (trade.tMa60Diff == trade.tMa60DiffMin9 ? 1 : 0) + (trade.tMa20Diff == trade.tMa20DiffMin9 ? 1 : 0) + (trade.tKdK == trade.tKdKMin9 ? 1 : 0) + (trade.tOsc == trade.tOscMin9 ? 1 : 0)

        //*** Z=P? ***
        //0=0.5 0.26=0.6026 [0.5=0.6915]
        //0.84=0.7995 0.85=0.8023 [1=0.8413] 1.04=0.8508 1.3=0.9032 1.45=0.9265 [1.5=0.9332]
        //1.55=0.9394 1.65=0.9505 [2=0.9772] [2.5=0.9938] [3=0.9987] [3.5=0.9998] [4=0.99997]
        //-0.84=0.2005 -0.85=0.1977 -0.67=0.2514 -0.68=0.2483
        
        //== 高買 ==================================================
        var wantH:Double = 0
        wantH += (trade.tMa60DiffZ125 > trade.byGrade([0.85,0.75]) && trade.tMa60DiffZ125 < trade.byGrade([2,2.5],L:.low) ? 1 : 0)
        wantH += (trade.tMa20Diff - trade.tMa60Diff > 1 && trade.tMa20Days > 0 ? 1 : 0)
        wantH += ((trade.tMa60Diff > trade.byGrade([-0.5,0]) && trade.tMa20Diff > trade.byGrade([-0.5,0])) || trade.grade == .damn ? 1 : 0)
        wantH += (trade.vZ125 > (trade.grade <= .weak ? 2 : 1.5) ? 1 : 0)

//        wantH += (trade.tKdJ > 105 && trade.grade <= .weak ? -1 : 0)    //tKdJZ125也無效
        wantH += ((trade.tOscZ125 > 1.8 && trade.tKdJZ125 > 1.5 && trade.grade < .high) || trade.tKdJZ125 > 1.8 ? -1 : 0)
        wantH += (trade.tKdKZ125 < -0.8 || trade.tKdKZ125 > (trade.grade <= .weak ? 2 : 1.8) ? -1 : 0)
        wantH += (trade.tOscZ125 < -0.5 ? -1 : 0)
        wantH += (trade.tMa60DiffZ125 < -2 || trade.tMa20DiffZ125 > 3 ? -1 : 0) //Ma60過低, Ma20過高
        wantH += ((trade.tMa60Diff == trade.tMa60DiffMin9 || trade.tMa20Diff == trade.tMa20DiffMin9 || trade.tOsc == trade.tOscMin9 || trade.tKdK == trade.tKdKMin9) && trade.grade >= .low ? -1 : 0)
        wantH += (trade.grade <= .weak && (ma20d > 6 || ma60d > 7) ? -1 : 0)
        wantH += (trade.grade == .damn && (ma20d > 6 || ma60d > 7) ? -1 : 0)
        wantH += (trade.tMa20DiffZ125 > 1.6 && trade.grade <= .damn ? -1 : 0)
//        wantH += (trade.tLowDiffZ125 - trade.tHighDiffZ125 > trade.byGrade([1.5,2]) ? -1 : 0)
//        wantH += (trade.tZ125 < -2 && trade.grade >= .none ? -1 : 0)   //*** 有效的tZ125(兩則)取代高低價差
//        wantH += (trade.tZ125 > 0 && trade.grade >= .none && trade.tZ125 < trade.byGrade([1,0.5],H:.wow) ? -1 : 0)
        wantH += (trade.tHighDiffZ125 > trade.byGrade([0.4,1.1,1.3]) && trade.tLowDiffZ125 > trade.byGrade([0.5,1.2,1.5]) ? -1 : 0)
        let mmdd = twDateTime.stringFromDate(trade.dateTime, format: "MMdd")
        wantH += (mmdd >= (trade.grade <= .weak ? "0726" : "0801") && mmdd <= "0810" ? -1 : 0)
        wantH += (mmdd >= (trade.grade <= .weak ? "0221" : "0226") && mmdd <= "0305" ? -1 : 0)
        wantH += (mmdd >= "0801" && mmdd <= "0831" ? 1 : 0)
        wantH += (mmdd >= "0301" && mmdd <= "0331" ? 1 : 0)
//        wantH += (trade.tLowDiff125 > 200 && trade.tHighDiff125 > -15 && trade.grade >= .high ? -1 : 0)
//        wantH += (trade.tLowDiffZ125 > 3.5 && trade.tHighDiffZ125 > 1.5 ? -1 : 0)
//        wantH += (trade.tHighDiffZ125 > 1 ? -1 : 0)
//        wantH += (mmdd >= "0210" && mmdd <= "0310" ? -1 : 0)
//        wantH += (mmdd >= "0710" && mmdd <= "0810" ? -1 : 0)
//        wantH += (trade.priceHigh == trade.tHighMax9 && trade.tHighDiff < 7.5 && trade.grade <= .damn ? -1 : 0)

        if wantH >= 0 {
            trade.simRule = "H"
//            if (trade.grade <= .weak && prev.priceClose < trade.priceClose) && (prev.simRule == "H" || prev.simRule == "I") {
//                trade.simRule = "I"
//            } else {
//                trade.simRule = "H"
//            }
        }
        
        if trade.simRule == "" {
            //== 低買 ==================================================
            var wantL:Double = 0
            wantL += (trade.tKdJ < -1 || trade.tKdK < 9 ? 1 : 0)
            wantL += (trade.tKdJ < -7 ? 1 : 0)
            wantL += (trade.tKdKZ125 < -0.9 && trade.tKdKZ250 < -0.9 ? 1 : 0)
            wantL += (trade.tKdDZ125 < -0.9 && trade.tKdDZ250 < -0.9 ? 1 : 0)
            wantL += (trade.tOscZ125 < -0.9 && trade.tOscZ250 < -0.9 ? 1 : 0)
            wantL += (trade.vZ125 < trade.byGrade([-0.2,0.3]) && trade.tOscZ125 < 0 ? 1 : 0) //*** 有效
            wantL += (min9s >= 2 && trade.tMa60DiffZ125 > -0.5 && trade.grade >= .none ? 1 : 0)
            wantL += (trade.tHighDiffZ125 < trade.byGrade([-1.5,-1.35,-1.2]) && trade.tLowDiffZ125 < 1 ? 1 : 0)

            wantL += (trade.tMa20Days < -30 ? -1 : 0)
            wantL += (trade.tLowDiff >= trade.byGrade([9,8],L:Trade.Grade.none) && trade.grade >= .weak ? -1 : 0) //或是 >= .low
            wantL += (trade.tMa60Diff == trade.tMa60DiffMin9 && trade.tMa20Diff == trade.tMa20DiffMin9 && trade.tOsc == trade.tOscMin9 && (trade.grade <= .damn || trade.grade >= .wow) ? -1 : 0)   //&& trade.tKdK == trade.tKdKMin9
            wantL += (mmdd >= (trade.grade <= .weak ? "0726" : "0801") && mmdd <= "0815" ? -1 : 0)
            wantL += (mmdd >= "0821" && mmdd <= "0831" && trade.grade <= .weak ? 1 : 0)
            wantL += (mmdd >= "0801" && mmdd <= "0831" ? 1 : 0)
            wantL += (trade.grade >= .weak && (trade.tMa60Diff < -30 || trade.tMa20Diff < -30) ? 1 : 0)


            if wantL >= 5 {  //(trade.grade <= .weak ? 5 : 6) {
                trade.simRule = "L"
            }
        }
        
        if trade.simQtyInventory > 0 {
            //== 賣出 ==================================================
            var wantS:Double = 0
            wantS += (trade.tKdJ > 101 ? 1 : 0)
            wantS += (trade.tKdJZ125 > 1.0 && trade.tKdJZ250 > 1.0 ? 1 : 0)
            wantS += (trade.tKdKZ125 > 0.9 && (trade.tKdKZ250 > 0.9 || trade.grade >= .weak) ? 1 : 0)
            wantS += (trade.tKdDZ125 > 0.9 && (trade.tKdDZ250 > 0.9 || trade.grade >= .weak) ? 1 : 0)
            wantS += (trade.tOscZ125 > 0.9 && trade.tOscZ250 > 0.9 ? 1 : 0)
            wantS += ((trade.tHighDiffZ125 > trade.byGrade([-1,-0.5,0]) && trade.tLowDiffZ125 > trade.byGrade([-0.4,0.1,0.8])) || trade.tZ125 > trade.byGrade([1.2,1.5]) ? 1 : 0)

            wantS += (trade.tMa60Diff == trade.tMa60DiffMin9 || trade.tMa20Diff == trade.tMa20DiffMin9 || trade.tOsc == trade.tOscMin9 || trade.tKdK == trade.tKdKMin9 ? -1 : 0)
            wantS += (trade.grade > .fine && trade.tHighDiff >= 7.5 ? trade.byGrade([-2,-1],H:.wow) : 0)
            wantS += (trade.grade <= .fine  && trade.tHighDiff >= 9 ? -1 : 0)
            wantS += (trade.simInvestTimes >= 5 ? -1 : 0)   //套久而可賣，是因故狂漲，應稍微惜賣。
            wantS += (trade.simInvestTimes >= 4 ? -1 : 0)   //只對2006,2007年有效？

            let forRoiH = trade.tMa60DiffZ250 > 0 && trade.tMa60DiffZ125 > 0.5
//            let weekendDays:Double = (twDateTime.calendar.component(.weekday, from: trade.dateTime) <= 2 ? 2 : 0)
            let sRoi22 = trade.simUnitRoi > 22.5 && wantS > trade.byGrade([1,0], H: .high)
            let sRoi18 = trade.simUnitRoi > (forRoiH ? 18.5 : 15.5) && trade.simDays < trade.byGrade([40,60], H: .high)
            let sRoi13 = trade.simUnitRoi > (forRoiH ? 13.5 : 9.5) && trade.simDays < trade.byGrade([20,30], H: .high)
            let sRoi09 = trade.simUnitRoi > (forRoiH ? 9.5 : 6.5) && trade.simDays < trade.byGrade([45,10])
            let sRoi03 = trade.simUnitRoi > 3.5 && (trade.tKdKZ125 > 1.5 || trade.tKdDZ125 > 1.5)
            let sRoi02 = trade.simUnitRoi > trade.byGrade([1.5,2.5])
            let sRoi00 = trade.simUnitRoi > 0.45 && trade.simDays > 1 //(1 + weekendDays)
            
            let sBase5 = wantS >= 6 && sRoi00
            let sBase4 = wantS >= 5 && sRoi02
            let sBase3 = wantS >= 4 && (sRoi03 || (sRoi00 && trade.simDays > 75))
            let sBase2 = wantS >= 3 && (sRoi18 || sRoi13 || sRoi09)
            let sBase = sBase5 || sBase4 || sBase3 || sBase2 || sRoi22
            
            var noInvested60:Bool = true
            var noInvested45:Bool = true
            let d60 = tradeIndex(60, index: index)
            for (i,t) in trades[d60.prevIndex...(index - 1)].reversed().enumerated() {
                if t.invested == 1 {
                    if i < 45 {
                        noInvested45 = false
                    }
                    noInvested60 = false
                } else if t.simDays <= 1 {
                    break
                }
            }
            let cut1a = trade.tLowDiff125 - trade.tHighDiff125 < 30
            let cut1b = trade.simUnitRoi > -15 && (trade.grade > .weak)
            let cut1c = trade.simUnitRoi > -20 && (trade.simDays > 300 || trade.grade <= .weak)
            let cut1  = cut1a && (cut1b || cut1c) && trade.simDays > 240
            let cut2 = trade.simDays > 400 && trade.simUnitRoi > (trade.grade <= .weak ? -20 : -15)
            let sCut = wantS >= (trade.grade >= .none && trade.simDays < 400 ? 1 : 2) && (cut1 || cut2) && noInvested60 //&& (trade.simInvestTimes <= 3 || trade.simDays > 400)

            var sell:Bool = sBase || sCut
            
            //== 反轉賣 ==
            if sell && trade.simReversed == "S-" {
                sell = false
            } else if sell == false && trade.simReversed == "S+" {
                sell = true
            } else if trade.simReversed != "B+" && trade.simReversed != "B-" {
                trade.simReversed = ""
            }
            
            if sell {
                trade.simQtySell = trade.simQtyInventory
                trade.simQtyInventory = 0
            } else {
                //== 加碼 ==================================================
                var aWant:Double = 0
                let z125a = (trade.tMa20DiffZ125 < -1 ? 1 : 0) + (trade.tMa60DiffZ125 < -1 ? 1 : 0) + (trade.tKdKZ125 < -1 ? 1 : 0) + (trade.tKdDZ125 < -1 ? 1 : 0) + (trade.tKdJZ125 < -1 ? 1 : 0) + (trade.tOscZ125 < -1 ? 1 :0)
                aWant += (z125a >= 2 || trade.grade <= .weak ? 1 : 0)
                aWant += (min9s >= (trade.grade >= .wow ? 3 : 2) ? 1 : 0)
                aWant += (trade.simUnitRoi < -35 ? 1 : 0)
                aWant += (trade.tHighDiffZ125 < trade.byGrade([-2,-2.5],H:.high) && trade.tLowDiffZ125 > trade.byGrade([-1,-2],L:.low) ? 1 : 0)
                aWant += (trade.tMa20Diff < -20 || trade.tMa60Diff < -20 ? 1 : 0)
                aWant += (trade.tMa20DiffZ125 < -2.5 && trade.tMa60DiffZ125 < -2.8 ? 1 : 0)
                aWant += (trade.tMa20Diff < -8 && trade.tMa60Diff < -8 ? 1 : 0)
                aWant += (trade.simRule == "L" && trade.simUnitRoi < -25 ? (trade.grade >= .fine ? 2 : 1) : 0)
                aWant += (trade.grade >= .none ? -2 : 0)    //已測試必須none以上減兩分，不能weak/none/fine交錯各減1分
                aWant += (trade.tLowDiff >= 8.5 && trade.grade <= .low ? -1 : 0)
                
                let aRoi30 = trade.simUnitRoi < -30
                let aRoi25 = trade.simUnitRoi < -25 && (trade.simDays < 180 || trade.simDays > 360)
                let aRoi15 = trade.simUnitRoi < -15 && trade.simDays >= 180 && trade.simRule == "L"
                let aRoi = (aRoi30 || aRoi25 || aRoi15) && aWant >= 3
                
                let aLow = trade.simUnitRoi > -10 && trade.simUnitRoi < 1 && trade.simRule == "L" && aWant >= (trade.grade <= .low ? 2 : 3) && trade.simDays < 60
                
                let addInvest = aLow || aRoi
                
                if addInvest {
                    trade.simRuleInvest = "A"
                } else {
                    trade.simRuleInvest = ""
                }
                if trade.simRuleInvest == "A" {
                    if trade.simUnitRoi < -50 || ((noInvested45 || (trade.simUnitRoi < -45 && trade.grade >= .fine)) && (trade.stock.simInvestAuto > 9 || trade.simInvestTimes <= trade.stock.simInvestAuto)) { //自動加碼
                        trade.simInvestAdded = 1
                        if trade.stock.simInvestAuto < 10 && trade.simInvestTimes > trade.stock.simInvestAuto {
                            trade.simInvestExceedCumulative += 1
                        }
                    }
                } else {
                    trade.simInvestAdded = 0
                }
            }
        }
        if trade.invested != 0 {  //若前筆賣股則這裡抽回加碼本金，或這裡加碼則增加本金
            trade.simInvestTimes += trade.invested
            trade.simAmtBalance += (trade.invested * trade.stock.moneyBase)
        }

        var buyIt:Bool = false
        if trade.simAmtBalance > 0 && trade.simQtySell == 0 {    //有可能之前賠超過1個本金而不夠買
            if prev.simQtySell > 0 && prev.simReversed == "" {
                buyIt = false
                trade.simRuleBuy = ""
            } else if trade.simRuleBuy == "" && (trade.simRule == "H" || trade.simRule == "L") {
                trade.simRuleBuy = trade.simRule
                buyIt = true
            } else if trade.invested > 0 {
                buyIt = true
            }
        }
        
        let oneFee  = round(trade.priceClose * 1.425)    //1張的手續費
        let oneCost = (trade.priceClose * 1000) + (oneFee > 20 ? oneFee : 20)  //只買1張的成本
        if buyIt && trade.simAmtBalance < oneCost {
           //錢不夠先清除buyRule以簡化後面反轉的判斷規則
            buyIt = false
            trade.simMoneyLackedCumulative = true
        }

        //== 反轉買 ==
        if buyIt && trade.simQtyInventory == 0 && trade.simReversed == "B-" {
            buyIt = false
        } else if buyIt == false && trade.simQtyInventory == 0 && trade.simReversed == "B+" {
            buyIt = true
            trade.simRuleBuy = "R"
//        } else if trade.simReversed != "S+" && trade.simReversed != "S-" {
//            if trade.simQtyInventory == 0 { //都不是就不要改simReverse因為可能真的反轉「賣」「不賣」
//                trade.simReversed = ""
//            }
        }

        
        if buyIt {
            //money是本次買入的可用額度，通常即是1個初始本金的額度。如果是補買可把前次零頭餘額加入本次額度。
            var money:Double = (trade.simInvestTimes * trade.stock.moneyBase) - trade.simAmtCost
            if money > trade.simAmtBalance && (trade.simReversed == "" || trade.simAmtBalance > oneCost) {
                //money(本次額度)大於本金餘額(盈餘)時：只要不是反轉買，或是反轉買而餘額足以買1張時，不必給足money以免盈餘又虛增
                money = trade.simAmtBalance
                
            }
            if money < oneCost && trade.simReversed == "B+" { //玩家反轉買，錢又不夠時，給足初始本金的倍數使足以至少買1張
                let oneCostBase = ceil(oneCost / trade.stock.moneyBase)
                money = oneCostBase * trade.stock.moneyBase
                trade.simInvestTimes = oneCostBase
                trade.simInvestByUser = oneCostBase - 1
                simLog.addLog("(\(self.stockProgress)/\(self.stockCount))\(trade.stock.sId)\(trade.stock.sName) 給足\(String(format:"%.f",oneCostBase))倍起始本金\(String(format:"%.1f",money/10000))萬元買1張：成本單價\(String(format:"%.1f",oneCost/10000))萬元")
            }
            let unitCost:Double = trade.priceClose * 1000 * 1.001425 //每張含手續費的成本
            var estimateQty = floor(money / unitCost)             //則可以買這麼多張
            let feeQty:Double = ceil(20 / (trade.priceClose * 1.425))   //20元的手續費可買這麼多張
            //手續費最少20元，買不到feeQty張數則手續費要算20元
            if estimateQty < feeQty {
                estimateQty = floor((money - 20) / (trade.priceClose * 1000))
            }
            trade.simQtyBuy = estimateQty

            if trade.simQtyBuy == 0 && money > oneCost {
                trade.simQtyBuy = 1    //剩餘資金剛好只夠購買1張，就買咩
            }
            if trade.simQtyBuy > 0 {
                if trade.simQtyInventory == 0 { //首次買入
                    trade.simDays = 1
                    trade.rollRounds += 1
                    trade.rollDays += 1
                }
                var cost = round(trade.priceClose * trade.simQtyBuy * 1000)
                var fee = round(trade.priceClose * trade.simQtyBuy * 1000 * 0.001425)
                if fee < 20 {
                    fee = 20
                }
                cost += fee
                trade.simAmtBalance -= cost
                trade.simAmtCost += cost
                trade.simQtyInventory += trade.simQtyBuy
            } else {
                trade.simMoneyLackedCumulative = true
            }
        }
        if trade.simQtyInventory > 0 || trade.simQtySell > 0 {  //不管有沒有買賣，因為收盤價變了就需要重算報酬率
            let qty = trade.simQtyInventory > 0 ? trade.simQtyInventory : trade.simQtySell
            var fee = round(trade.priceClose * qty * 1000 * 0.001425)
            if fee < 20 {   //這是賣時的手續費
                fee = 20
            }
            let tax = round(trade.priceClose * qty * 1000 * 0.003)
            trade.simAmtProfit = (trade.priceClose * qty * 1000) - trade.simAmtCost - fee - tax
            trade.simAmtRoi = 100 * trade.simAmtProfit / trade.simAmtCost
            trade.simUnitCost = trade.simAmtCost / (1000 * qty) //就是除以1000股然後四捨五入到小數2位
            trade.simUnitRoi = 100 * (trade.priceClose - trade.simUnitCost) / trade.simUnitCost
            if trade.simQtySell > 0 {
                trade.simAmtBalance += (trade.priceClose * trade.simQtySell * 1000) - fee - tax
            }
        }
        
        //== 更新累計數值 ==
//        if twDateTime.stringFromDate(trade.dateTime) == "2020/05/28" && trade.stock.sId == "1476" {
//            NSLog("\(trade.stock.sId)\(trade.stock.sName) debug ... ")
//        }
        if trade.rollDays > 0 {
            trade.rollAmtCost = (rollAmtCost + (trade.simAmtCost * trade.simDays)) / trade.rollDays
        }
        if trade.rollAmtCost > 0 {
            //即使simQtyInventory是0也可能是剛賣出，所以還是要重算累計損益
            //剛賣時損益已計入simAmtBalance故不要重複計算
            //算rollAmtProfit是先加總現值再扣本金，故需計入simAmtCost
            trade.rollAmtProfit = (trade.simQtyInventory == 0 ? 0 : (trade.simAmtProfit + trade.simAmtCost)) + trade.simAmtBalance - (trade.simInvestTimes * trade.stock.moneyBase)
            trade.rollAmtRoi = 100 * trade.rollAmtProfit / trade.rollAmtCost
        }
        trade.stock.simMoneyLacked = trade.simMoneyLackedCumulative
        trade.stock.simInvestExceed = trade.simInvestExceedCumulative
    }
}
