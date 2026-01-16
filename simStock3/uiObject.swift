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
    @Published var selected: Date?
    @Published var pageStock: Stock?

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

    init(modelContext: ModelContext) {
        self.context = modelContext

        self.sim = simObject(modelContext: modelContext)
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

        configureObservers()
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
        if let g = group {
            return prefixedStocks.filter { $0[0].prefix == prefix }[0].filter { $0.group == g }
        }
        return prefixedStocks.filter { $0[0].prefix == prefix }[0]
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

    func deleteTrades(_ stocks: [Stock], oneMonth: Bool = false) {
        guard !stocks.isEmpty else { return }

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
                let _ = self.sim.tech.downloadTrades(list, requestAction: (list.count > 1 ? .allTrades : .newTrades), allStocks: self.sim.stocks)
            }
        } catch {
            NSLog("deleteTrades(fetch with end) error: \(error.localizedDescription)")
        }
    }

//    func moveStocks(_ stocks: [Stock], toGroup: String = "") {
//        self.moveStocksToGroup(stocks, group: toGroup)
//    }

    func addInvest(_ trade: Trade) {
        self.addInvestLocal(trade)
    }

    func setReversed(_ trade: Trade) {
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

    func reloadNow(_ stocks: [Stock], action: technical.simAction) {
        self.reloadNowLocal(stocks, action: action)
    }

    func applySetting(_ stock: Stock? = nil, dateStart: Date, moneyBase: Double, autoInvest: Double, applyToGroup: Bool? = false, applyToAll: Bool, saveToDefaults: Bool) {
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
        if saveToDefaults {
//            self.setDefaults(start: dateStart, money: moneyBase, invest: autoInvest)
            defaults.set(start: dateStart, money: moneyBase, invest: autoInvest)
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
                var action: technical.simAction? {
                    if let a = defaults.action {
                        switch a {
                        case "ResetAll":
                            return .simResetAll
                        case "UpdateAll":
                            return .simUpdateAll
                        default:
                            break
                        }
                        defaults.remove("simAction")
                    } else if versionLast != versionNow {
                        if buildNo == "0" || versionLast == "" {
                            return .tUpdateAll      //改版後需要重算技術值時，應另起版號其build為0
                        } else {
                            return .simUpdateAll    //否則就只會更新模擬，不清除反轉和加碼，即使另起新版其build不為0或留空
                        }
                    }
                    return nil
                }
//                var action: technical.simAction? {
//                    if defaults.bool(forKey: "simResetAll") {
//                        defaults.removeObject(forKey: "simResetAll")
//                        return .simResetAll
//                    } else if defaults.bool(forKey: "simUpdateAll") {
//                        defaults.removeObject(forKey: "simUpdateAll")
//                        return .simUpdateAll
//                    } else if versionLast != versionNow {
//                        //                        let lastNo = (versionLast == "" ? "" : versionLast.split(separator: ".")[0])
//                        //                        let thisNo = versionNow.split(separator: ".")[0]
//                        if buildNo == "0" || versionLast == "" {
//                            return .tUpdateAll      //改版後需要重算技術值時，應另起版號其build為0
//                        } else {
//                            return .simUpdateAll    //否則就只會更新模擬，不清除反轉和加碼，即使另起新版其build不為0或留空
//                        }
//                    }
//                    return nil  //其他由現況來判斷
//                }
                self.appJustActivated = true
//                self.simUpdateNow(action: action)
                sim.tech.downloadStocks()    //更新股票代號和簡稱的對照表   doItNow: true
                sim.tech.reviseCompanyInfo(self.sim.stocks)
//                DispatchQueue.global().async {
                    self.sim.tech.downloadTrades(self.sim.stocks, requestAction: action)
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
        self.sim.stocks = (try? Stock.fetchAll(in: context)) ?? []
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

    func reloadNowLocal(_ stocks: [Stock], action: technical.simAction) {
        for stock in stocks {
            if stock.simInvestAuto == 0 {
                stock.simInvestAuto = 2
            }
        }
        try? self.context.save()
        self.sim.tech.downloadTrades(stocks, requestAction: action, allStocks: self.sim.stocks)
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

    func moveStocksToGroup(_ stocks: [Stock], group: String) {
        var newStocks: [Stock] = []
//        let simDefaults = self.simDefaults
        for stock in stocks {
            if stock.group == "" && group != "" {
                if defaults.first < stock.dateFirst {
                    stock.dateFirst = defaults.first
                    stock.dateStart = defaults.start
                }
                stock.simMoneyBase = defaults.money
                stock.simInvestUser = 0
                stock.simInvestExceed = 0
                stock.simMoneyLacked = false
                stock.simReversed = false
                newStocks.append(stock)
            }
            stock.group = group
            if group == "" {
                self.sim.stocks = self.sim.stocks.filter { $0 != stock }
            }   //搜尋而加入新股不用append到self.stocks因為searchText在給值或清除時都會fetchStocks
        }
        try? self.context.save()
        if newStocks.count > 0 {
            let _ = sim.tech.downloadTrades(newStocks, requestAction: .newTrades, allStocks: self.sim.stocks)
        }
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
        let trades = (try? Trade.fetch(for: trade.stock, in: context)) ?? []
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
        sim.tech.downloadTrades([trade.stock], requestAction: .simUpdateAll, allStocks: self.sim.stocks)
    }

    func setReversedLocal(_ trade: Trade) {
        let trades = (try? Trade.fetch(for: trade.stock, in: context)) ?? []
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
        sim.tech.downloadTrades([trade.stock], requestAction: .simUpdateAll, allStocks: self.sim.stocks)
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
            sim.tech.downloadTrades(stocks, requestAction: (dateChanged ? .allTrades : .simResetAll), allStocks: self.sim.stocks)
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
//        defaults.setAction("simUpdateAll")
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
