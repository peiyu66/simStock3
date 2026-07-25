//
//  simStockList.swift
//  simStock21
//
//  Created by peiyu on 2020/6/24.
//  Copyright © 2020 peiyu. All rights reserved.
//

import Foundation
import SwiftUI
import SwiftData
import MobileCoreServices
import BackgroundTasks
import Combine
import CoreData

private enum SimulationDataOperation {
    case deleteAndRecalculate
    case manualInvest
    case reverseTrade
    case recalculate
    case applySettings
    case saveDefaults
    case changeGroup

    var startMessage: String {
        switch self {
        case .deleteAndRecalculate:
            return "準備刪除並重算資料..."
        case .manualInvest:
            return "準備套用手動加碼..."
        case .reverseTrade:
            return "準備套用反轉買賣..."
        case .recalculate:
            return "準備重新計算..."
        case .applySettings:
            return "準備套用模擬設定並重算..."
        case .saveDefaults:
            return "準備儲存新股模擬設定..."
        case .changeGroup:
            return "準備更新股群..."
        }
    }

    var completionMessage: String {
        switch self {
        case .deleteAndRecalculate:
            return "刪除與重算完成"
        case .manualInvest:
            return "手動加碼重算完成"
        case .reverseTrade:
            return "反轉買賣重算完成"
        case .recalculate:
            return "重新計算完成"
        case .applySettings:
            return "模擬設定已套用，重算完成"
        case .saveDefaults:
            return "新股模擬預設已儲存"
        case .changeGroup:
            return "股群更新完成"
        }
    }

    func progressMessage(from message: String) -> String {
        switch self {
        case .changeGroup:
            return message
                .replacingOccurrences(
                    of: "請等候股群完成資料的下載...",
                    with: "正在下載新加入股票的歷史資料..."
                )
                .replacingOccurrences(
                    of: "請等候股群完成歷史資料的計算",
                    with: "正在計算新加入股票"
                )
        case .deleteAndRecalculate:
            return message
                .replacingOccurrences(
                    of: "請等候股群完成資料的下載...",
                    with: "正在補回刪除範圍的資料..."
                )
                .replacingOccurrences(
                    of: "請等候股群完成歷史資料的計算",
                    with: "正在重算刪除後的資料"
                )
        default:
            return message
                .replacingOccurrences(
                    of: "請等候股群完成資料的下載...",
                    with: "正在準備模擬重算..."
                )
                .replacingOccurrences(
                    of: "請等候股群完成歷史資料的計算",
                    with: "正在重算模擬"
                )
        }
    }
}

class uiObject: ObservableObject {
    var objectWillChange = ObservableObjectPublisher()
    
    @Published private var isLandScape: Bool = {
        let o = UIDevice.current.orientation
        if o.isValidInterfaceOrientation {
            return o.isLandscape
        }
        // Fallback when orientation is unknown/flat: prefer trait-based guess if available; default to portrait
        let traits = UITraitCollection.current
        if traits.horizontalSizeClass != .unspecified && traits.verticalSizeClass != .unspecified {
            return traits.horizontalSizeClass == .regular && traits.verticalSizeClass == .compact
        }
        return false
    }()
    @Published var sim:simObject
    @Published var runningMsg: String = ""
    @Published var isUpdatingPrices = false
    @Published private(set) var isChangingSimulation = false
    @Published var priceUpdateMessage = ""
    @Published var simulationStatusMessage = ""
    @Published private(set) var isCatalogSearchActive = false
    @Published var selected: Date?
    @Published var pageStock: Stock?
    let isReadOnlySnapshot: Bool
    private var priceUpdateTask: Task<Void, Never>?
    private var pendingPriceUpdateStocks: [Stock]?
    private var pendingAutomaticPriceUpdateStocks: [Stock]?
    private var officialCloseUpdateTask: Task<Void, Never>?
    private var stockCatalogUpdateTask: Task<Void, Never>?
    private var companyInfoUpdateTask: Task<Void, Never>?
    private var orderedTradeCache: [String: [Trade]] = [:]
    private var orderedTradeCacheOrder: [String] = []
    private let stockCatalogUpdater: StockCatalogUpdater
    private var simulationOperation: SimulationDataOperation?

//    @Published private(set) var stocks: [Stock] = []

//    private let tech: technical

    var versionNow: String
    var versionLast: String = ""
    var appJustActivated: Bool = false
    var simTestStart: Date? = nil

    private let buildNo: String = Bundle.main.infoDictionary!["CFBundleVersion"] as! String
    private let versionNo: String = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    private var context: ModelContext

    var rotated: (d: Double, x: CGFloat, y: CGFloat) {
        let orient = UIDevice.current.orientation
        switch orient {
        case .portraitUpsideDown:
            return (180, 1, 0)
        case .landscapeLeft:
            return (0, 0, 0)
        case .landscapeRight:
            return (180, 0, 1)
        default:
            return (0, 0, 0)
        }
    }

    init(modelContext: ModelContext, isReadOnlySnapshot: Bool = false) {
        self.context = modelContext
        self.isReadOnlySnapshot = isReadOnlySnapshot

        self.sim = simObject(modelContext: modelContext)
        self.stockCatalogUpdater = StockCatalogUpdater(modelContext: modelContext)
//        self.tech = technical(modelContext: modelContext)

//        if defaults.money == 0 {
//            let dateStart = twDateTime.calendar.date(byAdding: .year, value: -3, to: twDateTime.startOfDay()) ?? Date.distantFuture
//            setDefaults(start: dateStart, money: 70.0, invest: 2)
//            defaults.set(start: dateStart, money: 70.0, invest: 2)
//        }
//        self.stocks = (try? Stock.fetchAll(in: context)) ?? []
//        if self.stocks.count == 0 {
//            let group1: [(sId: String, sName: String)] = [
//                (sId: "3653", sName: "健策"),
//                (sId: "3017", sName: "奇鋐"),
//                (sId: "2368", sName: "金像電"),
//                (sId: "2330", sName: "台積電")]
//            self.newStock(in: context, stocks: group1, group: "股群_1")
//
//            let group2: [(sId: String, sName: String)] = [
//                (sId: "2324", sName: "仁寶"),
//                (sId: "1301", sName: "台塑"),
//                (sId: "1216", sName: "統一"),
//                (sId: "2317", sName: "鴻海")]
//            self.newStock(in: context, stocks: group2, group: "股群_2")
//        }

        self.versionNow = versionNo + (buildNo == "0" ? "" : "(\(buildNo))")

        self.sim.tech.automaticYahooUpdateRequest = { [weak self] stocks in
            self?.startAutomaticYahooUpdate(stocks: stocks)
        }
        configureObservers()
    }

    func cachedOrderedTrades(for stockID: String) -> [Trade]? {
        guard let trades = orderedTradeCache[stockID] else { return nil }
        orderedTradeCacheOrder.removeAll { $0 == stockID }
        orderedTradeCacheOrder.append(stockID)
        return trades
    }

    func storeOrderedTrades(_ trades: [Trade], for stockID: String) {
        orderedTradeCache[stockID] = trades
        orderedTradeCacheOrder.removeAll { $0 == stockID }
        orderedTradeCacheOrder.append(stockID)

        while orderedTradeCacheOrder.count > 12 {
            let removedStockID = orderedTradeCacheOrder.removeFirst()
            orderedTradeCache.removeValue(forKey: removedStockID)
        }
    }

    func invalidateOrderedTradeCache() {
        orderedTradeCache.removeAll(keepingCapacity: true)
        orderedTradeCacheOrder.removeAll(keepingCapacity: true)
    }

    @MainActor
    func updateStockCatalogIfNeeded(force: Bool = false) {
        guard !isReadOnlySnapshot, stockCatalogUpdateTask == nil else { return }
        guard force || StockCatalogUpdater.needsRefresh(
            lastSuccess: defaults.stockCatalogLastUpdated
        ) else {
            return
        }

        stockCatalogUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { stockCatalogUpdateTask = nil }
            do {
                if let summary = try await stockCatalogUpdater.refreshIfNeeded(force: force) {
                    sim.stocks = sim.getStocks()
                    simLog.addLog(
                        "TWSE 股票名錄完成：\(summary.total) 筆，新增 \(summary.inserted)，"
                        + "改名 \(summary.renamed)，下市標記 \(summary.markedUnlisted)。"
                    )
                }
            } catch {
                simLog.addLog("TWSE 股票名錄更新失敗：\(error.localizedDescription)")
            }
        }
    }

    private func configureObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.onViewWillTransition), name: UIDevice.orientationDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.appNotification), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.appNotification), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.setRequestStatus), name: NSNotification.Name("requestRunning"), object: nil)
    }

    let classIcon: [String] = ["iphone", "iphone.landscape", "ipad", "ipad.landscape", "ipad"]

    enum WidthClass: Int, Comparable {
        static func < (lhs: WidthClass, rhs: WidthClass) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
        case compact = 0
        case widePhone = 1
        case regular = 2
        case widePad = 3
    }


    var doubleColumn: Bool {
        return isPad && isLandScape && UIApplication.shared.isNotSplitOrSlideOver
    }

    func pageColumn(_ hClass: UserInterfaceSizeClass?) -> Bool {
        return hClass == .regular && doubleColumn
    }

    var currentWidthClass: WidthClass = .compact
    func widthClass(_ hClass: UserInterfaceSizeClass?) -> WidthClass {
        var wClass: WidthClass
        switch hClass {
        case .compact:
            if !isPad && isLandScape && UIApplication.shared.isNotSplitOrSlideOver {
                wClass = .widePhone
            } else {
                wClass = .compact
            }
        case .regular:
            if isPad && isLandScape && UIApplication.shared.isNotSplitOrSlideOver {
                wClass = .widePad
            } else if isPad {
                wClass = .regular
            } else {
                wClass = .widePhone
            }
        default:
            wClass = .compact
        }
        if currentWidthClass != wClass && (!isPad || wClass != .compact) { //排除.compact column的情形
            currentWidthClass = wClass
            NSLog("widthClass: \(wClass)")
        }
        return wClass
    }

    func widthCG(_ hClass: UserInterfaceSizeClass?, CG: [CGFloat]) -> CGFloat {
        let i = widthClass(hClass).rawValue
        if i < CG.count {
            return CG[i]
        } else if let cg = CG.last {
            return cg
        } else {
            return 0
        }
    }

    var searchText: [String]? = nil {    //搜尋String以空格逗號分離為關鍵字Array
        didSet {
            self.fetchStocks(searchText)
        }
    }

    var searchTextInGroup: Bool {    //單詞的搜尋目標已在股群內？
        if let search = searchText, search.count == 1 {
            if self.sim.stocks.map({ $0.sId }).contains(search[0]) || self.sim.stocks.map({ $0.sName }).contains(search[0]) {
                return true
            }
        }
        return false
    }

    private var prefixedStocks: [[Stock]] {
        Dictionary(grouping: self.sim.stocks) { (stock: Stock) in
            stock.prefix
        }.values
            .map { $0.map { $0 }.sorted { $0.sName < $1.sName } }
            .sorted { $0[0].prefix < $1[0].prefix }
    }

    var prefixs: [String] {
        prefixedStocks.map { $0[0].prefix }
    }

    func theGroupStocks(_ stock: Stock) -> [Stock] {
        return self.sim.stocks.filter { $0.group == stock.group }.sorted { $0.sName < $1.sName }
    }

    func theGroupPrefixs(_ stock: Stock) -> [String] {
        var thePrefixs: [String] = []
        let stocks = theGroupStocks(stock)
        for s in stocks {
            if let p = thePrefixs.last, s.prefix == p {
                //首字重複不取
            } else {
                thePrefixs.append(s.prefix)
            }
        }
        return thePrefixs
    }

    func shiftRightStock(_ stock: Stock, groupStocks: [Stock]? = nil) -> Stock {
        let stocks = groupStocks ?? self.sim.stocks
        if let i = stocks.firstIndex(of: stock) {
            if i > 0 {
                return stocks[i - 1]
            } else {
                return stocks[stocks.count - 1]
            }
        }
        return stock
    }

    func shiftLeftStock(_ stock: Stock, groupStocks: [Stock]? = nil) -> Stock {
        let stocks = groupStocks ?? self.sim.stocks
        if let i = stocks.firstIndex(of: stock) {
            if i < stocks.count - 1 {
                return stocks[i + 1]
            } else {
                return stocks[0]
            }
        }
        return stock
    }

    func shiftLeftGroup(_ stock: Stock) -> Stock {
        if let i = groups.firstIndex(of: stock.group) {
            if i < groups.count - 1 {
                return groupStocks[i + 1][0]
            } else {
                return groupStocks[0][0]
            }
        }
        return stock
    }

    func shiftRightGroup(_ stock: Stock) -> Stock {
        if let i = groups.firstIndex(of: stock.group) {
            if i > 0 {
                return groupStocks[i - 1][0]
            } else {
                return groupStocks[groups.count - 1][0]
            }
        }
        return stock
    }


    func prefixStocks(prefix: String, group: String? = nil) -> [Stock] {
        guard let stocks = prefixedStocks.first(where: { $0.first?.prefix == prefix }) else {
            return []
        }

        if let g = group {
            return stocks.filter { $0.group == g }
        }
        return stocks
    }

    var groupStocks: [[Stock]] {
        return self.groupStocksComputed
    }

    private var groupStocksComputed: [[Stock]] {
        Dictionary(grouping: sim.stocks) { (stock: Stock) in
            stock.group
        }.values
            .map { $0.map { $0 }.sorted { $0.sName < $1.sName } }
            .sorted { $0[0].group < $1[0].group }
    }

    var groups: [String] {
        groupStocks.map { $0[0].group }.filter { $0 != "" }
    }

    var newGroupName: String {
        var nameInGroup: String = "股群_"
        var numberInGroup: Int = 0
        for groupName in self.groups {
            if let numbersRange = groupName.rangeOfCharacter(from: .decimalDigits) {
                let n = Int(groupName[numbersRange.lowerBound..<numbersRange.upperBound]) ?? 0
                if n > numberInGroup {
                    nameInGroup = String(groupName[..<numbersRange.lowerBound])
                    numberInGroup = n
                }
            }
        }
        return (nameInGroup + String(numberInGroup + 1))
    }

    var searchGotResults: Bool { //查無搜尋目標？
        if let firstGroup = groupStocks.first?[0].group, firstGroup == "" {
            return true
        }
        return false
    }

    var isRunning: Bool {
        self.runningMsg.count > 0
    }

    /// Any operation that can write Trade prices, technical values, or
    /// simulation results must be serialized with the others.
    var isTradeOperationLocked: Bool {
        isUpdatingPrices || isChangingSimulation || isRunning || sim.tech.isRequestActive
    }

    @discardableResult
    private func beginSimulationChange(_ operation: SimulationDataOperation) -> Bool {
        guard !isTradeOperationLocked else { return false }
        invalidateOrderedTradeCache()
        isChangingSimulation = true
        runningMsg = operation.startMessage
        priceUpdateMessage = ""
        simulationStatusMessage = operation.startMessage
        simulationOperation = operation
        return true
    }

    private func finishSimulationChange() {
        isChangingSimulation = false

        if let pendingStocks = pendingPriceUpdateStocks {
            pendingPriceUpdateStocks = nil
            startDailyPriceUpdate(stocks: pendingStocks)
        }
    }

    private func completeSimulationChange(_ message: String? = nil) {
        runningMsg = ""
        simulationStatusMessage = message
            ?? simulationOperation?.completionMessage
            ?? "模擬資料作業完成"
        finishSimulationChange()
    }

    /// Progress notifications remain useful for presenting intermediate text,
    /// but the operation that started the recalculation owns the final unlock.
    /// This direct completion path prevents a missed notification from leaving
    /// the UI permanently disabled after the calculation has already finished.
    private func simulationRequestDidComplete() {
        guard isChangingSimulation else { return }
        completeSimulationChange()
    }

    @MainActor
    func startDailyPriceUpdate(
        stocks: [Stock],
        ensureFollowUpIfBusy: Bool = false,
        deferWhileSearching: Bool = false
    ) {
        guard !isReadOnlySnapshot else { return }
        guard !stocks.isEmpty else { return }

        if deferWhileSearching, isCatalogSearchActive {
            pendingAutomaticPriceUpdateStocks = mergedStocks(
                pendingAutomaticPriceUpdateStocks,
                with: stocks
            )
            simLog.addLog("搜尋股票中；自動股價更新已延後至離開搜尋後。")
            return
        }

        guard priceUpdateTask == nil, !isUpdatingPrices else {
            // A foreground transition can arrive while the task that was
            // suspended in the background is still finishing. Coalesce any
            // number of such requests into one guaranteed follow-up pass.
            if ensureFollowUpIfBusy {
                pendingPriceUpdateStocks = stocks
                simLog.addLog("App 回到前景；已排定目前更新完成後再更新一次。")
            }
            return
        }

        guard !isChangingSimulation, !isRunning else {
            if ensureFollowUpIfBusy {
                pendingPriceUpdateStocks = stocks
                simLog.addLog("目前正在修改模擬資料；已排定完成後再更新股價。")
            }
            return
        }

        startCompanyInfoUpdateIfNeeded(stocks: stocks)

        // The legacy real-time timer calls Technical directly, so stop it
        // before the modern daily-price pipeline begins.
        invalidateTimer()
        cancelScheduledOfficialCloseUpdate()

        invalidateOrderedTradeCache()
        isUpdatingPrices = true
        simulationStatusMessage = ""
        priceUpdateMessage = "準備更新股價..."

        priceUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let summary = await sim.updateDailyPrices(stocks: stocks) { [weak self] message in
                self?.priceUpdateMessage = message
            }

            let marketStatus: String
            switch summary.twse.marketDayStatus {
            case .tradingDay:
                marketStatus = "交易日"
            case .closed:
                marketStatus = "休市"
            case .unknown:
                marketStatus = "尚未確認"
            }
            simLog.recordPriceUpdate(
                PriceUpdateDiagnosticSnapshot(
                    completedAt: Date(),
                    statusText: summary.statusText,
                    expectedTradingDate: summary.twse.expectedCompletedTradingDay,
                    marketStatus: marketStatus,
                    twseRequestedMonths: summary.twse.requestedMonths,
                    twseFailedMonths: summary.twse.failedMonths,
                    twsePendingHistoryMonths: summary.twse.remainingHistoryMonths,
                    yahooRequestedStocks: summary.yahoo.requestedStocks,
                    yahooUpdatedStocks: summary.yahoo.updatedStocks,
                    yahooSuccessfulStocks: summary.yahoo.successfulStockIDs.count,
                    yahooSkippedStocks: summary.twse.forwardFailedStockIDs.count
                )
            )
            priceUpdateMessage = summary.statusText
            isUpdatingPrices = false
            priceUpdateTask = nil

            scheduleOfficialCloseUpdateIfNeeded(stocks: stocks, summary: summary.twse)

            if let pendingStocks = pendingPriceUpdateStocks {
                pendingPriceUpdateStocks = nil
                startDailyPriceUpdate(stocks: pendingStocks)
            }
        }
    }

    @MainActor
    private func startCompanyInfoUpdateIfNeeded(stocks: [Stock]) {
        guard companyInfoUpdateTask == nil else { return }
        companyInfoUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await sim.tech.updateCompanyInfoIfNeeded(stocks)
            companyInfoUpdateTask = nil
        }
    }

    @MainActor
    func cancelScheduledOfficialCloseUpdate() {
        officialCloseUpdateTask?.cancel()
        officialCloseUpdateTask = nil
    }

    @MainActor
    private func scheduleOfficialCloseUpdateIfNeeded(
        stocks: [Stock],
        summary: simObject.TWSEUpdateSummary
    ) {
        cancelScheduledOfficialCloseUpdate()
        guard summary.marketDayStatus == .tradingDay else { return }

        let now = Date()
        let publicationTime = twDateTime.timeAtDate(now, hour: 15, minute: 35)
        guard now < publicationTime else { return }

        let interval = publicationTime.timeIntervalSince(now)
        simLog.addLog("已排定 15:35 補抓 TWSE 當日正式資料。")
        officialCloseUpdateTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.officialCloseUpdateTask = nil
            self.startDailyPriceUpdate(
                stocks: stocks,
                ensureFollowUpIfBusy: true,
                deferWhileSearching: true
            )
        }
    }

    @MainActor
    func catalogSearchDidBegin() {
        guard !isCatalogSearchActive else { return }
        isCatalogSearchActive = true

        // The intraday Yahoo timer lives in Technical and otherwise fires
        // without changing uiObject.isUpdatingPrices. Pause it explicitly so
        // it cannot interrupt or race with catalog selection.
        if sim.tech.hasScheduledPriceUpdate {
            pendingAutomaticPriceUpdateStocks = mergedStocks(
                pendingAutomaticPriceUpdateStocks,
                with: sim.stocks
            )
            invalidateTimer()
            simLog.addLog("搜尋股票中；盤中定時更新已暫停。")
        }
    }

    @MainActor
    func catalogSearchDidEnd() {
        guard isCatalogSearchActive else { return }
        isCatalogSearchActive = false

        guard let stocks = pendingAutomaticPriceUpdateStocks else { return }
        pendingAutomaticPriceUpdateStocks = nil
        startDailyPriceUpdate(
            stocks: stocks,
            ensureFollowUpIfBusy: true
        )
    }

    @MainActor
    private func startAutomaticYahooUpdate(stocks: [Stock]) {
        guard !isReadOnlySnapshot, !stocks.isEmpty else { return }

        if isCatalogSearchActive {
            pendingAutomaticPriceUpdateStocks = mergedStocks(
                pendingAutomaticPriceUpdateStocks,
                with: stocks
            )
            simLog.addLog("搜尋股票中；盤中定時更新已延後至離開搜尋後。")
            return
        }

        guard priceUpdateTask == nil, !isTradeOperationLocked else {
            pendingAutomaticPriceUpdateStocks = mergedStocks(
                pendingAutomaticPriceUpdateStocks,
                with: stocks
            )
            simLog.addLog("其他資料作業進行中；盤中定時更新已延後。")
            return
        }

        invalidateOrderedTradeCache()
        isUpdatingPrices = true
        simulationStatusMessage = ""
        priceUpdateMessage = "盤中定時更新..."

        priceUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let summary = await sim.tech.updateYahooPrices(stocks: stocks) { [weak self] message in
                self?.priceUpdateMessage = message
            }
            priceUpdateMessage = summary.updatedStocks > 0
                ? "盤中股價已更新 \(summary.updatedStocks) 檔"
                : "盤中股價已檢查"
            isUpdatingPrices = false
            priceUpdateTask = nil

            if let pendingStocks = pendingAutomaticPriceUpdateStocks,
               !isCatalogSearchActive {
                pendingAutomaticPriceUpdateStocks = nil
                startAutomaticYahooUpdate(stocks: pendingStocks)
            }
        }
    }

    private func mergedStocks(_ existing: [Stock]?, with incoming: [Stock]) -> [Stock] {
        var byID = Dictionary(uniqueKeysWithValues: (existing ?? []).map { ($0.sId, $0) })
        for stock in incoming {
            byID[stock.sId] = stock
        }
        return Array(byID.values)
    }

    func deleteTrades(_ stocks: [Stock], oneMonth: Bool = false) {
        guard !isReadOnlySnapshot else { return }
        guard !stocks.isEmpty else { return }
        guard beginSimulationChange(.deleteAndRecalculate) else { return }

        // If deleting only the last month, we use a [start, end) half-open window for clarity
        let endExclusive = twDateTime.startOfDay() // delete trades strictly before 'today'
        let startInclusive: Date? = oneMonth ? (twDateTime.calendar.date(byAdding: .month, value: -1, to: endExclusive)) : nil

        do {
            var affected = Set<Stock>()
            for stock in stocks {
                // Build a descriptor-level filter instead of post-fetch filtering
                let trades = try Trade.fetch(
                    in: context,
                    for: stock,
                    start: startInclusive,
                    end: endExclusive,
                    TWSE: nil,
                    userActions: nil,
                    fetchLimit: nil,
                    ascending: true
                )
                guard !trades.isEmpty else { continue }
                for t in trades { context.delete(t) }
                affected.insert(stock)
            }
            try context.save()

            if !affected.isEmpty {
                let list = Array(affected)
                pendingPriceUpdateStocks = list
                completeSimulationChange("資料已刪除，準備由 TWSE 補回並重算")
            } else {
                completeSimulationChange("沒有需要刪除或重算的資料")
            }
        } catch {
            NSLog("deleteTrades(fetch with end) error: \(error.localizedDescription)")
            completeSimulationChange("刪除與重算失敗")
        }
    }

//    func moveStocks(_ stocks: [Stock], toGroup: String = "") {
//        self.moveStocksToGroup(stocks, group: toGroup)
//    }

    func addInvest(_ trade: Trade) {
        guard !isReadOnlySnapshot else { return }
        guard beginSimulationChange(.manualInvest) else { return }
        self.addInvestLocal(trade)
    }

    func setReversed(_ trade: Trade) {
        guard !isReadOnlySnapshot else { return }
        guard beginSimulationChange(.reverseTrade) else { return }
        self.setReversedLocal(trade)
    }

//    var simDefaults: (first: Date, start: Date, money: Double, invest: Double, text: String) {
//        let defaults = self.simDefaultsLocal
//        let startX = twDateTime.stringFromDate(defaults.start, format: "起始日yyyy/MM/dd")
//        let moneyX = String(format: "起始本金%.f萬元", defaults.money)
//        let investX = (defaults.invest > 9 ? "自動無限加碼" : (defaults.invest > 0 ? String(format: "自動%.0f次加碼", defaults.invest) : ""))
//        let txt = "新股預設：\(startX) \(moneyX) \(investX)"
//        return (defaults.first, defaults.start, defaults.money, defaults.invest, txt)
//    }

    func stocksSummary(_ stocks: [Stock]) -> String {
        let summary = self.stocksSummaryLocal(stocks)
        let count = String(format: "%.f支股 ", summary.count)
        let roi = String(format: "平均年報酬:%.1f%% ", summary.roi)
        let days = String(format: "平均週期:%.f天", summary.days)
        return "\(count) \(roi) \(days)"
    }

    @discardableResult
    func reloadNow(_ stocks: [Stock], action: Technical.simAction) -> Bool {
        guard !isReadOnlySnapshot else { return false }
        guard !stocks.isEmpty else { return false }
        guard beginSimulationChange(.recalculate) else { return false }
        self.reloadNowLocal(stocks, action: action)
        return true
    }

    func applySetting(_ stock: Stock? = nil, dateStart: Date, moneyBase: Double, autoInvest: Double, applyToGroup: Bool? = false, applyToAll: Bool) {
        guard !isReadOnlySnapshot else { return }
        guard beginSimulationChange(.applySettings) else { return }
        var stocks: [Stock] = []
        if applyToAll {
            stocks = self.sim.stocks
        } else if let st = stock {
            if let ag = applyToGroup, ag == true {
                for g in self.groupStocks {
                    if g[0].group == st.group {
                        for s in g {
                            stocks.append(s)
                        }
                    }
                }
            } else {
                stocks = [st]
            }
        }
        if stocks.count > 0 {
            self.settingStocks(stocks, dateStart: dateStart, moneyBase: moneyBase, autoInvest: autoInvest)
        }
        if stocks.isEmpty || defaults.simTesting {
            completeSimulationChange()
        }
    }

    func applyDefaultSetting(
        dateStart: Date,
        moneyBase: Double,
        autoInvest: Double,
        groupNames: Set<String>,
        applyToAll: Bool
    ) {
        guard !isReadOnlySnapshot else { return }
        let appliesToExistingStocks = applyToAll || !groupNames.isEmpty
        guard beginSimulationChange(
            appliesToExistingStocks ? .applySettings : .saveDefaults
        ) else { return }

        defaults.set(start: dateStart, money: moneyBase, invest: autoInvest)

        let groupedStocks = sim.stocks.filter { !$0.group.isEmpty }
        let targetStocks: [Stock]
        if applyToAll {
            targetStocks = groupedStocks
        } else if !groupNames.isEmpty {
            targetStocks = groupedStocks.filter { groupNames.contains($0.group) }
        } else {
            targetStocks = []
        }

        if targetStocks.isEmpty {
            completeSimulationChange()
        } else {
            settingStocks(
                targetStocks,
                dateStart: dateStart,
                moneyBase: moneyBase,
                autoInvest: autoInvest
            )
        }
    }

    @objc private func onViewWillTransition(_ notification: Notification) {
        if UIDevice.current.orientation.isValidInterfaceOrientation {
            if UIDevice.current.orientation.isLandscape {
                self.isLandScape = true
            } else if !UIDevice.current.orientation.isFlat {
                if self.isLandScape {   //由橫轉直時
                    self.selected = nil
                }
                self.isLandScape = false
            }
            //            NSLog("\(isLandScape ? "LandScape" : "Portrait")")
        } else {
            // When orientation is not valid (e.g., face up/unknown), avoid deprecated UIScreen.main; infer from current traits when possible
            let traits = UITraitCollection.current
            if traits.horizontalSizeClass != .unspecified && traits.verticalSizeClass != .unspecified {
                self.isLandScape = (traits.horizontalSizeClass == .regular && traits.verticalSizeClass == .compact)
            } else {
                // Default to previous value to avoid flicker when we can't infer reliably
                self.isLandScape = self.isLandScape
            }
        }
    }

    @objc private func setRequestStatus(_ notification: Notification) {
        if let userInfo = notification.userInfo, let msg = userInfo["msg"] as? String {
            let isSimulationRequest = isChangingSimulation
            runningMsg = ""
            if msg == "" {   //股價更新完畢自動展開最新一筆
                if let stock = pageStock, self.appJustActivated {
                    self.selected = try? stock.lastTrade(in: context)?.date 
                    self.appJustActivated = false
                }
            } else if msg == "pass!" {
                self.appJustActivated = false
            } else {
                runningMsg = msg
            }
            if isSimulationRequest {
                if msg == "" {
                    simulationStatusMessage = simulationOperation?.completionMessage
                        ?? "模擬資料作業完成"
                } else if msg == "pass!" {
                    simulationStatusMessage = simulationOperation?.completionMessage
                        ?? "模擬資料作業完成"
                } else {
                    simulationStatusMessage = simulationOperation?.progressMessage(from: msg)
                        ?? msg
                }
            }
            if msg == "" || msg == "pass!" {
                finishSimulationChange()
            }
        }
    }

    @objc private func appNotification(_ notification: Notification) {
        switch notification.name {
        case UIApplication.didBecomeActiveNotification:
            simLog.addLog("=== appDidBecomeActive v\(versionNow) ===")
            simLog.shrinkLog(200)
            self.versionLast = defaults.version
            if defaults.simTesting {
                sim.runTest()
            } else {
                defaults.setVersion(versionNow)
                var action: Technical.simAction? {
                    if versionLast != versionNow {
                        if buildNo == "0" || versionLast == "" {
                            return .tUpdateAll      //改版後需要重算技術值時，應另起版號其build為0
                        } else {
                            return .simUpdateAll    //否則就只會更新模擬，不清除反轉和加碼，即使另起新版其build不為0或留空
                        }
                    }
                    return nil
                }
                self.appJustActivated = true
//                self.simUpdateNow(action: action)
//                sim.tech.downloadStocks()    //更新股票代號和簡稱的對照表   doItNow: true
//                sim.tech.reviseCompanyInfo(self.sim.stocks)
//                DispatchQueue.global().async {
//                    self.sim.tech.downloadTrades(self.sim.stocks, requestAction: action)
//                }
            }
        case UIApplication.willResignActiveNotification:
            simLog.addLog("=== appWillResignActive ===")
            self.invalidateTimer()
        default:
            break
        }

    }

    // --------------------------------------------------

    func fetchStocks(_ searchText: [String]? = nil, in context: ModelContext? = nil) {
        let context = context ?? self.context
        if let searchText, !searchText.isEmpty {
            self.sim.stocks = ((try? Stock.fetch(
                in: context,
                sId: searchText,
                sName: searchText
            )) ?? []).filter { !$0.group.isEmpty }
        } else {
            self.sim.stocks = (try? Stock.fetchGrouped(in: context)) ?? []
        }
    }

    private func newStock(in context: ModelContext, stocks: [(sId: String, sName: String)], group: String? = nil) {
        for item in stocks {
//            let simDefaults = self.simDefaults
            let s = Stock(sId: item.sId, sName: item.sName, group: group ?? "", dateFirst: defaults.first, dateStart: defaults.start, simInvestAuto: defaults.invest, simMoneyBase: defaults.money)
            context.insert(s)
        }
        try? context.save()
        self.fetchStocks()
        NSLog("new stocks added: \(stocks)")
    }

    func reloadNowLocal(_ stocks: [Stock], action: Technical.simAction) {
        for stock in stocks {
            if stock.simInvestAuto == 0 {
                stock.simInvestAuto = 2
            }
        }
        try? self.context.save()
        self.sim.tech.downloadTrades(
            stocks,
            requestAction: action,
            allStocks: self.sim.stocks
        ) { [weak self] in
            self?.simulationRequestDidComplete()
        }
    }

//    func simUpdateNow(action: technical.simAction? = nil) {
//        sim.tech.downloadStocks()    //更新股票代號和簡稱的對照表   doItNow: true
//        sim.tech.reviseCompanyInfo(self.sim.stocks)
//        DispatchQueue.global().async {
//            self.sim.tech.downloadTrades(self.sim.stocks, requestAction: action)
//        }
//
//    }

    func invalidateTimer() {
        sim.tech.invalidateTimer()
    }

    @discardableResult
    func moveStocksToGroup(
        _ stocks: [Stock],
        group: String = "",
        downloadNewStocks: Bool = true
    ) -> Bool {
        guard !isReadOnlySnapshot else { return false }
        guard !stocks.isEmpty else { return false }
        guard beginSimulationChange(.changeGroup) else { return false }
        var newStocks: [Stock] = []
//        let simDefaults = self.simDefaults
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
        try? self.context.save()
        self.sim.stocks = self.sim.getStocks()
        if downloadNewStocks && newStocks.count > 0 {
            pendingPriceUpdateStocks = newStocks
            completeSimulationChange("已加入股群，準備下載歷史資料")
        } else {
            completeSimulationChange()
        }
        return true
    }

//    func deleteTradesLocal(_ stocks: [Stock], oneMonth: Bool = false) {
//        DispatchQueue.global().async {
//            for stock in stocks {
//                stock.deleteTrades(oneMonth: oneMonth)
//            }
//            DispatchQueue.main.async {
//                let _ = self.sim.tech.downloadTrades(stocks, requestAction: (stocks.count > 1 ? .allTrades : .newTrades), allStocks: self.stocks)    //allTrades才會提示等候訊息
//            }
//        }
//    //}

    func addInvestLocal(_ trade: Trade) {
        let trades = (try? Trade.fetch(in: context, for: trade.stock)) ?? []
        if trade.simInvestByUser == 0 {
            if trade.simInvestAdded > 0 {
                trade.simInvestByUser = -1
            } else if trade.simInvestAdded == 0 {
                trade.simInvestByUser = 1
            }
            trade.stock.simInvestUser += 1
        } else {
            trade.resetInvestByUser()
        }
        for tr in trades {
            if tr.date > trade.date {
                tr.simReversed = ""
                if tr.simInvestByUser != 0 {
                    tr.resetInvestByUser()
                }
            }
        }
        NSLog("\(trade.stock.sId)\(trade.stock.sName) simInvestUser: \(trade.stock.simInvestUser)")
        try? self.context.save()
        sim.tech.downloadTrades(
            [trade.stock],
            requestAction: .simUpdateAll,
            allStocks: self.sim.stocks
        ) { [weak self] in
            self?.simulationRequestDidComplete()
        }
    }

    func setReversedLocal(_ trade: Trade) {
        let trades = (try? Trade.fetch(in: context, for: trade.stock)) ?? []
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
            if trade.simInvestByUser != 0 {
                trade.simInvestByUser = 0
                trade.stock.simInvestUser -= 1
            }
        } else {
            trade.simReversed = ""
            trade.stock.simReversed = false
        }
        for tr in trades {
            if tr.date > trade.date {
                tr.simReversed = ""
                if tr.simInvestByUser != 0 {
                    tr.resetInvestByUser()
                }
            } else if tr.date < trade.date && tr.simReversed != "" {
                tr.stock.simReversed = true
            }
        }
        try? self.context.save()
        sim.tech.downloadTrades(
            [trade.stock],
            requestAction: .simUpdateAll,
            allStocks: self.sim.stocks
        ) { [weak self] in
            self?.simulationRequestDidComplete()
        }
    }

    func settingStocks(_ stocks: [Stock], dateStart: Date, moneyBase: Double, autoInvest: Double) {
        var dateChanged: Bool = false
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
        }
        try? self.context.save()
        if !defaults.simTesting {
            if dateChanged {
                pendingPriceUpdateStocks = stocks
            }
            sim.tech.downloadTrades(
                stocks,
                requestAction: (dateChanged ? .allTrades : .simResetAll),
                allStocks: self.sim.stocks
            ) { [weak self] in
                self?.simulationRequestDidComplete()
            }
        }
    }

//    var simDefaultsLocal: (first: Date, start: Date, money: Double, invest: Double) {
//        let start = defaults.object(forKey: "simDateStart") as? Date ?? Date.distantFuture
//        let money = defaults.double(forKey: "simMoneyBase")
//        let invest = defaults.double(forKey: "simAutoInvest")
//        let first = twDateTime.calendar.date(byAdding: .year, value: -1, to: start) ?? start
//        return (first, start, money, invest)
//    }
//
//    func setDefaults(start: Date, money: Double, invest: Double) {
//        defaults.set(start, forKey: "simDateStart")
//        defaults.set(money, forKey: "simMoneyBase")
//        defaults.set(invest, forKey: "simAutoInvest")
//    }

    func stocksSummaryLocal(_ stocks: [Stock], date: Date? = nil) -> (count: Double, roi: Double, days: Double) {
        if stocks.count == 0 {
            return (0, 0, 0)
        }
        var sumRoi: Double = 0
        var sumDays: Double = 0
        for stock in stocks {
            let trade: Trade? = {
                if let end = date {
                    return (try? Trade.fetch(in: context, for: stock, end: end, fetchLimit: 1, ascending: false).first) ?? nil
                } else {
                    return try? stock.lastTrade(in: self.context)
                }
            }()
            if let trade {
                sumRoi += (trade.rollAmtRoi / stock.years)
                sumDays += trade.days
            }
        }
        let count = Double(stocks.count)
        let roi = sumRoi / count
        let days = sumDays / count
        return (count, roi, days)
    }

//    var simTesting: Bool {
//        defaults.testing
//    }

//    func runTest() {
//        let start = self.simTestStart ?? (twDateTime.calendar.date(byAdding: .year, value: -15, to: twDateTime.startOfDay()) ?? Date.distantPast)   //測試15年內每年的模擬3年的成績
//        NSLog("")
//        NSLog("== simTesting \(twDateTime.stringFromDate(start)) ==")
//        var groupRoi: String = ""
//        var groupDays: String = ""
//        for g in 0...(groupStocks.count - 1) {
//            let stocks = groupStocks[g]
//            let result = testStocks(stocks, start: start)
//            groupRoi = groupRoi + (groupRoi.count > 0 ? ",, " : "") + result.roi
//            groupDays = groupDays + (groupDays.count > 0 ? ",, " : "") + result.days
//        }
//        print("\n")
//        print(groupRoi)
//        print(groupDays)
//        print("\n")
//        NSLog("== simTesting finished. ==")
//        NSLog("")
//    }
//
//    private func testStocks(_ stocks: [Stock], start: Date) -> (roi: String, days: String) {
//        var roi: String = ""
//        var days: String = ""
//        let years: Int = Int(round(Date().timeIntervalSince(start) / 86400 / 365))
//        print("\n\n\(stocks[0].group)：(\(stocks.count)) 自\(twDateTime.stringFromDate(start, format: "yyyy"))第\(years)年起 ... ", terminator: "")
//        var nextYear: Date = start
//        while nextYear <= (twDateTime.calendar.date(byAdding: .year, value: -1, to: twDateTime.startOfDay()) ?? Date.distantPast) {
//            settingStocks(stocks, dateStart: nextYear, moneyBase: 500, autoInvest: 2)
//            for stock in stocks {
//                sim.tech.technicalUpdate(stock: stock, action: .simTesting)
//            }
//            let endYear = (twDateTime.calendar.date(byAdding: .year, value: 3, to: nextYear) ?? Date.distantFuture)
//            let summary = stocksSummaryLocal(stocks, date: endYear)
//            roi = String(format: "%.1f", summary.roi) + (roi.count > 0 ? ", " : "") + roi
//            days = String(format: "%.f", summary.days) + (days.count > 0 ? ", " : "") + days
//            print("\(twDateTime.stringFromDate(nextYear, format: "yyyy"))" + String(format: "(%.1f/%.f) ", summary.roi, summary.days), terminator: "")
//            nextYear = (twDateTime.calendar.date(byAdding: .year, value: 1, to: nextYear) ?? Date.distantPast)
//        }
//        return (roi, days)
//    }
}

extension UIApplication {
    public var isNotSplitOrSlideOver: Bool {
        // Prefer the key window from the active UIWindowScene to avoid deprecated UIApplication.windows
        let scenes = self.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }

        if let window = scenes
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return window.frame.width == window.screen.bounds.width
        }

        // Fallback: if we couldn't find a key window (e.g., during early launch), try any visible window from active scenes
        if let window = scenes
            .flatMap({ $0.windows })
            .first(where: { !$0.isHidden && $0.alpha > 0 }) {
            return window.frame.width == window.screen.bounds.width
        }

        return false
    }
}
