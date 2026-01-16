//
//  Item.swift
//  simStock3
//
//  Created by peiyu on 2025/12/14.
//

import Foundation
import SwiftData
import SwiftUI

@Model
final class Stock {
    @Attribute(.unique) var sId: String
    var sName: String
    var group: String
    var p10Action: String?
    var p10Date: Date?
    var p10L: String   //五檔試算
    var p10H: String   //五檔試算
    var p10Rule: String?
    var proport: String?  //營收比重
    var dateFirst: Date   //歷史價格起始
    var dateStart: Date   //模擬交易起始
    var simInvestAuto:Double      //自動加碼次數：0～9，10為無限次
    var simInvestExceed:Double    //自動加碼超次：跌太深自動超次加碼
    var simInvestUser:Double      //user變更加碼次數
    var simMoneyBase: Double      //每次投入本金額度(單位：萬元）
    var simMoneyLacked: Bool      //本金不足？
    var simReversed:Bool          //反轉買賣
    @Relationship(deleteRule: .cascade, inverse: \Trade.stock) var trades: [Trade]

    init(sId: String, sName: String, group: String, p10Action: String? = nil, p10Date: Date? = nil, p10L: String = "", p10H: String = "", p10Rule: String? = nil, proport: String? = nil, dateFirst: Date, dateStart: Date, simInvestAuto: Double = 0, simInvestExceed: Double = 0, simInvestUser: Double = 0, simMoneyBase: Double = 0, simMoneyLacked: Bool = false, simReversed: Bool = false) {
        self.sId = sId
        self.sName = sName
        self.group = group
        self.p10Action = p10Action
        self.p10Date = p10Date
        self.p10L = p10L
        self.p10H = p10H
        self.p10Rule = p10Rule
        self.proport = proport
        self.dateFirst = dateFirst
        self.dateStart = dateStart
        self.simInvestAuto = simInvestAuto
        self.simInvestExceed = simInvestExceed
        self.simInvestUser = simInvestUser
        self.simMoneyBase = simMoneyBase
        self.simMoneyLacked = simMoneyLacked
        self.simReversed = simReversed
        self.trades = []
    }
}

// MARK: - SwiftData Query Helpers for Stock
extension Stock {

    static func fetch(
        in context: ModelContext,
        sId: [String]? = nil,
        sName: [String]? = nil,
        fetchLimit: Int? = nil
    ) throws -> [Stock] {

        // 1) group != "" 的基本條件
        var basePredicate = #Predicate<Stock> { $0.group != "" }

        // 2) 動態組出 sId/sName 的 OR 條件
        if let sName = sName, !sName.isEmpty {
            // 多筆 sName 用 OR: 任一包含就算
            let uppercased = sName.map { $0.localizedUppercase }
            let namePredicates: [Predicate<Stock>] = uppercased.map { name in
                #Predicate<Stock> { $0.sName.localizedStandardContains(name) }
            }
            let nameOr = namePredicates.reduce(nil as Predicate<Stock>?) { partial, next in
                if let p = partial { return #Predicate<Stock> { p.evaluate($0) || next.evaluate($0) } }
                return next
            }
            if let nameOr {
                basePredicate = #Predicate<Stock> { basePredicate.evaluate($0) && nameOr.evaluate($0) }
            }
        }
        // - sId: 若只有一筆且無 sName，就用等於；否則使用 CONTAINS
        if let sId = sId, !sId.isEmpty {
            let uppercased = sId.map { $0.localizedUppercase }
            if uppercased.count == 1, (sName == nil || sName?.isEmpty == true) {
                let singleId = uppercased[0]
                let idPredicate = #Predicate<Stock> { $0.sId == singleId }
                // 多條件時 AND group != ""
                basePredicate = #Predicate<Stock> { idPredicate.evaluate($0) }
            } else {
                // 多筆 sId 用 OR: 任一包含就算
                let idPredicates: [Predicate<Stock>] = uppercased.map { id in
                    #Predicate<Stock> { $0.sId.localizedStandardContains(id) }
                }
                let idOr = idPredicates.reduce(nil as Predicate<Stock>?) { partial, next in
                    if let p = partial { return #Predicate<Stock> { p.evaluate($0) || next.evaluate($0) } }
                    return next
                }
                if let idOr {
                    basePredicate = #Predicate<Stock> { basePredicate.evaluate($0) && idOr.evaluate($0) }
                }
            }
        }
        //以上接非，就是sId和sName皆是nil，則使用group != ""


        // 3) 排序與限制筆數
        var descriptor = FetchDescriptor<Stock>(
            predicate: basePredicate,
            sortBy: [SortDescriptor(\.sName, order: .forward)]
        )
        if let limit = fetchLimit { descriptor.fetchLimit = limit }

        // 4) 執行查詢
        return try context.fetch(descriptor)
    }


    static func ensureStock(
        in context: ModelContext,
        sId: String,
        sName: String,
        group:String?=nil,
        dateFirst: Date,
        dateStart: Date,
        simMoneyBase: Double
    ) throws -> Stock {
        if let existing = try self.fetch(in: context, sId: [sId]).first {
            return existing
        }
        // Create a new Stock with minimal required defaults; callers can update fields later
        let newStock = Stock(
            sId: sId,
            sName: sName,
            group: group ?? "",
            p10Action: nil,
            p10Date: nil,
            p10L: "",
            p10H: "",
            p10Rule: nil,
            proport: nil,
            dateFirst: dateFirst,
            dateStart: dateStart,
            simInvestAuto: 0,
            simInvestExceed: 0,
            simInvestUser: 0,
            simMoneyBase: simMoneyBase,
            simMoneyLacked: false,
            simReversed: false
        )
        context.insert(newStock)
        try context.save()
        return newStock
    }


    // Convenience: fetch all stocks
    static func fetchAll(in context: ModelContext, sortedBy keyPath: KeyPath<Stock, String>? = \.sId) throws -> [Stock] {
        let sort: [SortDescriptor<Stock>] = keyPath.map { [SortDescriptor($0)] } ?? []
        let descriptor = FetchDescriptor<Stock>(sortBy: sort)
        return try context.fetch(descriptor)
    }

    // First trade for this stock (by dateTime ascending)
    func firstTrade(in context: ModelContext) throws -> Trade? {
        try Trade.first(in: context, for: self)
    }

    // Last trade for this stock (by dateTime descending)
    func lastTrade(in context: ModelContext, on day:Date?=nil) throws -> Trade? {
        if let day = day {
            return try Trade.fetch(in: context, for: self, on: day)
        } else {
            return try Trade.last(in: context, for :self)
        }
    }

    // Delete all trades for this stock
    func deleteTrades(in context: ModelContext) throws {
        for t in trades {
            context.delete(t)
        }
        try context.save()
    }

    var proport1:String {
        if let proport = self.proport {
            if let range = proport.range(of: "(.+?)[0-9|.|%|,|(]+?", options: .regularExpression) {
                let endIndex = proport.index(range.upperBound, offsetBy: -1)
                var item0 = String(proport[..<endIndex])
                if let r = item0.last, (r == "," || r == "及" || r == "-") {
                    item0 = String(item0.dropLast())
                }
                return item0
            }
            return proport
        }
        return ""
    }


    func p10Reset() {
        self.p10Action = nil
        self.p10Date = nil
        self.p10L = ""
        self.p10H = ""
        self.p10Rule = nil
    }

    var moneyBase: Double {
        self.simMoneyBase * 10000
    }

    var prefix: String {
        String(sName.first ?? Character(""))
    }

    var years: Double { max(1.0, Date().timeIntervalSince(dateFirst) / 86400.0 / 365.0) }

    var dateRequestStart:Date { //起始模擬日往前1年，作為分析數值的基礎
        return twDateTime.calendar.date(byAdding: .year, value: -1, to: self.dateStart) ?? self.dateStart
    }

    func dateRequestTWSE(in context: ModelContext ) -> Date? {
        let yesterday = (twDateTime.calendar.date(byAdding: .day, value: -1, to: twDateTime.endOfDay()) ?? Date.distantFuture)
        let twseStart:Date = twDateTime.dateFromString("2010/01/01")! //TWSE只能查到2010之後
        let dStart:Date = dateRequestStart < twseStart ? twseStart : dateRequestStart
        if let trade = try? Trade.fetch(in: context, for: self, end: yesterday, TWSE: false, fetchLimit: 1, ascending: false).first {
            if trade.date >= dStart { //2010之前的沒得查
                return trade.date
            }
        } else if let trade = self.trades.last {
            if let d = twDateTime.calendar.dateComponents([.day], from: dStart, to: trade.date).day, d > 10 {
                if let s = twDateTime.calendar.date(byAdding: .month, value: -1, to: trade.date), d > 30 {
                    let s0 = twDateTime.startOfMonth(s)
                    return s0
                }
                if let d1 = twDateTime.calendar.dateComponents([.day], from: dStart, to: trade.date).day, d1 > 10 {
                    return dStart
                }
            }
        }
        return nil
    }

}

/// 這是 Swift Data 用 Trade model。
@Model
final class Trade {    
    var dataSource: String        //價格來源
    var dateTime: Date            //成交/收盤時間
    var priceClose: Double        //成交/收盤價
    var priceHigh: Double         //最高價
    var priceLow: Double          //最低價
    var priceOpen: Double         //開盤價
    var volumeClose: Double       //成交量
    var rollAmtCost: Double
    var rollAmtProfit: Double
    var rollAmtRoi: Double
    var rollDays: Double
    var rollRounds: Double
    var simAmtBalance: Double
    var simAmtCost: Double
    var simAmtProfit: Double
    var simAmtRoi: Double
    var simDays: Double           //持股日數
    var simInvestAdded: Double    //自動加碼
    var simInvestByUser: Double   //玩家變更加碼
    var simInvestTimes: Double    //本金倍數：初始1倍+加碼次數
    var simQtyBuy: Double         //買入張數
    var simQtyInventory: Double   //庫存張數
    var simQtySell: Double        //賣出張數
    var simReversed: String        //反轉行動
    var simRule: String            //模擬預定
    var simRuleBuy: String         //模擬行動：高買H或低賣L
    var simRuleInvest: String      //模擬行動：加碼
    var simUnitCost: Double       //成本單價
    var simUnitRoi: Double
    var simUpdated: Bool
    var tHighDiff: Double         //最高價差比
    var tHighDiff125: Double      //0.5年內的最高價與收盤價跌幅比率
    var tHighDiff250: Double      //1.0年內的最高價與收盤價跌幅比率
    var tHighDiffZ125: Double      //0.5年內的tHighDiff125標準差分
    var tHighDiffZ250: Double      //1.0年內的tHighDiff250標準差分
    var tHighMax9: Double         //9天內的最高價
    var tLowDiff: Double          //最低價差比
    var tLowDiff125: Double       //0.5年內的最低價與收盤價跌幅比率
    var tLowDiff250: Double       //1.0年內的最低價與收盤價跌幅比率
    var tLowDiffZ125: Double       //0.5年內的tLowDiffZ125標準差分
    var tLowDiffZ250: Double       //1.0年內的tLowDiff250標準差分
    var tLowMin9: Double          //9天內的最低價
    var tMa20: Double             //20天均價
    var tMa20Days: Double         //Ma20延續漲跌天數
    var tMa20Diff: Double
    var tMa20DiffMax9: Double
    var tMa20DiffMin9: Double
    var tMa20DiffZ125: Double     //Ma20Diff於0.5年標準差分
    var tMa20DiffZ250: Double     //Ma20Diff於1.0年標準差分
    var tMa60: Double             //60天均價
    var tMa60Days: Double         //Ma60延續漲跌天數
    var tMa60Diff: Double         //現價對Ma60差比
    var tMa60DiffMax9: Double     //Ma60Diff於9天內最高
    var tMa60DiffMin9: Double     //Ma60Diff於9天內最低
    var tMa60DiffZ125: Double     //Ma60Diff於0.5年標準差分
    var tMa60DiffZ250: Double     //Ma60Diff於1.0年標準差分
    var tZ125: Double
    var tZ250: Double
    var tKdK: Double              //K值
    var tKdKMax9: Double
    var tKdKMin9: Double
    var tKdKZ125: Double          //0.5年標準差分
    var tKdKZ250: Double          //1.0年標準差分
    var tKdD: Double              //D值
    var tKdDZ125: Double          //0.5年標準差分
    var tKdDZ250: Double          //1.0年標準差分
    var tKdJ: Double              //J值
    var tKdJZ125: Double          //0.5年標準差分
    var tKdJZ250: Double          //1.0年標準差分
    var tOsc: Double              //Macd的Osc
    var tOscEma12: Double
    var tOscEma26: Double
    var tOscMacd9: Double
    var tOscMax9: Double
    var tOscMin9: Double
    var tOscZ125: Double          //0.5年標準差分
    var tOscZ250: Double          //1.0年標準差分
    var tPriceZ125: Double
    var tPriceZ250: Double
    var vMa20: Double             //20天均價 以下都是昨日以前的成交量統計值
    var vMa20Days: Double         //Ma20延續漲跌天數
    var vMa20Diff: Double
    var vMa20DiffMax9: Double
    var vMa20DiffMin9: Double
    var vMa20DiffZ125: Double     //Ma20Diff於0.5年標準差分
    var vMa20DiffZ250: Double     //Ma20Diff於1.0年標準差分
    var vMa60: Double             //60天均價
    var vMa60Days: Double         //Ma60延續漲跌天數
    var vMa60Diff: Double         //現價對Ma60差比
    var vMa60DiffMax9: Double     //Ma60Diff於9天內最高
    var vMa60DiffMin9: Double     //Ma60Diff於9天內最低
    var vMa60DiffZ125: Double     //Ma60Diff於0.5年標準差分
    var vMa60DiffZ250: Double     //Ma60Diff於1.0年標準差分
    var vMax9: Double
    var vMin9: Double
    var vZ125: Double
    var vZ250: Double
    var tUpdated: Bool
    @Relationship var stock: Stock

    init(
        dataSource: String,
        dateTime: Date,
        priceClose: Double,
        priceHigh: Double,
        priceLow: Double,
        priceOpen: Double,
        volumeClose: Double,
        rollAmtCost: Double,
        rollAmtProfit: Double,
        rollAmtRoi: Double,
        rollDays: Double,
        rollRounds: Double,
        simAmtBalance: Double,
        simAmtCost: Double,
        simAmtProfit: Double,
        simAmtRoi: Double,
        simDays: Double,
        simInvestAdded: Double,
        simInvestByUser: Double,
        simInvestTimes: Double,
        simQtyBuy: Double,
        simQtyInventory: Double,
        simQtySell: Double,
        simReversed: String,
        simRule: String,
        simRuleBuy: String,
        simRuleInvest: String,
        simUnitCost: Double,
        simUnitRoi: Double,
        simUpdated: Bool,
        tHighDiff: Double,
        tHighDiff125: Double,
        tHighDiff250: Double,
        tHighDiffZ125: Double,
        tHighDiffZ250: Double,
        tHighMax9: Double,
        tLowDiff: Double,
        tLowDiff125: Double,
        tLowDiff250: Double,
        tLowDiffZ125: Double,
        tLowDiffZ250: Double,
        tLowMin9: Double,
        tMa20: Double,
        tMa20Days: Double,
        tMa20Diff: Double,
        tMa20DiffMax9: Double,
        tMa20DiffMin9: Double,
        tMa20DiffZ125: Double,
        tMa20DiffZ250: Double,
        tMa60: Double,
        tMa60Days: Double,
        tMa60Diff: Double,
        tMa60DiffMax9: Double,
        tMa60DiffMin9: Double,
        tMa60DiffZ125: Double,
        tMa60DiffZ250: Double,
        tZ125: Double,
        tZ250: Double,
        tKdK: Double,
        tKdKMax9: Double,
        tKdKMin9: Double,
        tKdKZ125: Double,
        tKdKZ250: Double,
        tKdD: Double,
        tKdDZ125: Double,
        tKdDZ250: Double,
        tKdJ: Double,
        tKdJZ125: Double,
        tKdJZ250: Double,
        tOsc: Double,
        tOscEma12: Double,
        tOscEma26: Double,
        tOscMacd9: Double,
        tOscMax9: Double,
        tOscMin9: Double,
        tOscZ125: Double,
        tOscZ250: Double,
        tPriceZ125: Double,
        tPriceZ250: Double,
        vMa20: Double,
        vMa20Days: Double,
        vMa20Diff: Double,
        vMa20DiffMax9: Double,
        vMa20DiffMin9: Double,
        vMa20DiffZ125: Double,
        vMa20DiffZ250: Double,
        vMa60: Double,
        vMa60Days: Double,
        vMa60Diff: Double,
        vMa60DiffMax9: Double,
        vMa60DiffMin9: Double,
        vMa60DiffZ125: Double,
        vMa60DiffZ250: Double,
        vMax9: Double,
        vMin9: Double,
        vZ125: Double,
        vZ250: Double,
        tUpdated: Bool,
        stock: Stock
    ) {
        self.dataSource = dataSource
        self.dateTime = dateTime
        self.priceClose = priceClose
        self.priceHigh = priceHigh
        self.priceLow = priceLow
        self.priceOpen = priceOpen
        self.volumeClose = volumeClose
        self.rollAmtCost = rollAmtCost
        self.rollAmtProfit = rollAmtProfit
        self.rollAmtRoi = rollAmtRoi
        self.rollDays = rollDays
        self.rollRounds = rollRounds
        self.simAmtBalance = simAmtBalance
        self.simAmtCost = simAmtCost
        self.simAmtProfit = simAmtProfit
        self.simAmtRoi = simAmtRoi
        self.simDays = simDays
        self.simInvestAdded = simInvestAdded
        self.simInvestByUser = simInvestByUser
        self.simInvestTimes = simInvestTimes
        self.simQtyBuy = simQtyBuy
        self.simQtyInventory = simQtyInventory
        self.simQtySell = simQtySell
        self.simReversed = simReversed
        self.simRule = simRule
        self.simRuleBuy = simRuleBuy
        self.simRuleInvest = simRuleInvest
        self.simUnitCost = simUnitCost
        self.simUnitRoi = simUnitRoi
        self.simUpdated = simUpdated
        self.tHighDiff = tHighDiff
        self.tHighDiff125 = tHighDiff125
        self.tHighDiff250 = tHighDiff250
        self.tHighDiffZ125 = tHighDiffZ125
        self.tHighDiffZ250 = tHighDiffZ250
        self.tHighMax9 = tHighMax9
        self.tLowDiff = tLowDiff
        self.tLowDiff125 = tLowDiff125
        self.tLowDiff250 = tLowDiff250
        self.tLowDiffZ125 = tLowDiffZ125
        self.tLowDiffZ250 = tLowDiffZ250
        self.tLowMin9 = tLowMin9
        self.tMa20 = tMa20
        self.tMa20Days = tMa20Days
        self.tMa20Diff = tMa20Diff
        self.tMa20DiffMax9 = tMa20DiffMax9
        self.tMa20DiffMin9 = tMa20DiffMin9
        self.tMa20DiffZ125 = tMa20DiffZ125
        self.tMa20DiffZ250 = tMa20DiffZ250
        self.tMa60 = tMa60
        self.tMa60Days = tMa60Days
        self.tMa60Diff = tMa60Diff
        self.tMa60DiffMax9 = tMa60DiffMax9
        self.tMa60DiffMin9 = tMa60DiffMin9
        self.tMa60DiffZ125 = tMa60DiffZ125
        self.tMa60DiffZ250 = tMa60DiffZ250
        self.tZ125 = tZ125
        self.tZ250 = tZ250
        self.tKdK = tKdK
        self.tKdKMax9 = tKdKMax9
        self.tKdKMin9 = tKdKMin9
        self.tKdKZ125 = tKdKZ125
        self.tKdKZ250 = tKdKZ250
        self.tKdD = tKdD
        self.tKdDZ125 = tKdDZ125
        self.tKdDZ250 = tKdDZ250
        self.tKdJ = tKdJ
        self.tKdJZ125 = tKdJZ125
        self.tKdJZ250 = tKdJZ250
        self.tOsc = tOsc
        self.tOscEma12 = tOscEma12
        self.tOscEma26 = tOscEma26
        self.tOscMacd9 = tOscMacd9
        self.tOscMax9 = tOscMax9
        self.tOscMin9 = tOscMin9
        self.tOscZ125 = tOscZ125
        self.tOscZ250 = tOscZ250
        self.tPriceZ125 = tPriceZ125
        self.tPriceZ250 = tPriceZ250
        self.vMa20 = vMa20
        self.vMa20Days = vMa20Days
        self.vMa20Diff = vMa20Diff
        self.vMa20DiffMax9 = vMa20DiffMax9
        self.vMa20DiffMin9 = vMa20DiffMin9
        self.vMa20DiffZ125 = vMa20DiffZ125
        self.vMa20DiffZ250 = vMa20DiffZ250
        self.vMa60 = vMa60
        self.vMa60Days = vMa60Days
        self.vMa60Diff = vMa60Diff
        self.vMa60DiffMax9 = vMa60DiffMax9
        self.vMa60DiffMin9 = vMa60DiffMin9
        self.vMa60DiffZ125 = vMa60DiffZ125
        self.vMa60DiffZ250 = vMa60DiffZ250
        self.vMax9 = vMax9
        self.vMin9 = vMin9
        self.vZ125 = vZ125
        self.vZ250 = vZ250
        self.tUpdated = tUpdated
        self.stock = stock
    }

}


// MARK: - Color scheme key moved out to avoid actor-isolated conformance issues in Swift 6
enum ColorSchemeKey: Equatable {
    case price  // 開盤、最高、最低、收盤價
    case time   // 盤中的日期、時間、收盤價
    case ruleR  // 收盤價的圓框
    case ruleB  // 收盤價的背景
    case ruleF  // 收盤價的文字
    case rule   // 只供ruleR, ruleB, qty的延伸規則
    case qty    // 買、賣的狀態
}



// MARK: - SwiftData Query Helpers for Trade
extension Trade {
    // Convenience: fetch all trades for a stock, optionally sorted
    static func fetch(for stock: Stock, in context: ModelContext, ascending: Bool = true) throws -> [Trade] {
        let descriptor = FetchDescriptor<Trade>(
            predicate: #Predicate { $0.stock == stock },
            sortBy: [SortDescriptor(\.dateTime, order: ascending ? .forward : .reverse)]
        )
        return try context.fetch(descriptor)
    }

    // Convenience: fetch first trade (earliest)
    static func first(in context: ModelContext, for stock: Stock) throws -> Trade? {
        var descriptor = FetchDescriptor<Trade>(
            predicate: #Predicate { $0.stock == stock },
            sortBy: [SortDescriptor(\.dateTime, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // Convenience: fetch last trade (latest)
    static func last(in context: ModelContext, for stock: Stock) throws -> Trade? {
        var descriptor = FetchDescriptor<Trade>(
            predicate: #Predicate { $0.stock == stock },
            sortBy: [SortDescriptor(\.dateTime, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // Convenience: fetch trade on a specific date (matching by day granularity)
    static func fetch(
        in context: ModelContext,
        for stock: Stock,
        on day: Date,
        calendar: Calendar = .current) throws -> Trade? {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        var descriptor = FetchDescriptor<Trade>(
            predicate: #Predicate { $0.stock == stock && $0.dateTime >= start && $0.dateTime < end },
            sortBy: [SortDescriptor(\.dateTime, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // Convenience: fetch trades with rich filters similar to Core Data helpers
    static func fetch(
        in context: ModelContext,
        for stock: Stock,
        start: Date? = nil,
        end: Date? = nil,
        TWSE: Bool? = nil,
        userActions: Bool? = nil,
        fetchLimit: Int? = nil,
        ascending: Bool = false
    ) throws -> [Trade] {
        // Build predicate pieces
        let base = #Predicate<Trade> { $0.stock == stock }
        let startPred: Predicate<Trade>? = start.map { s in
            #Predicate<Trade> { $0.dateTime >= s }
        }
        let endPred: Predicate<Trade>? = end.map { e in
            #Predicate<Trade> { $0.dateTime <= e }
        }
        // dataSource equals/unequals "TWSE" depending on flag
        let twsePred: Predicate<Trade>? = TWSE.map { t in
            t ? #Predicate<Trade> { $0.dataSource == "TWSE" } : #Predicate<Trade> { $0.dataSource != "TWSE" }
        }

        // userActions: simReversed != "" OR simInvestByUser != 0
        let userActionsPred: Predicate<Trade>? = (userActions == true) ?
            #Predicate<Trade> { ($0.simReversed != "") || ($0.simInvestByUser != 0) } : nil

        // Combine with AND
        var predicate = base
        for p in [startPred, endPred, twsePred, userActionsPred].compactMap({ $0 }) {
            let prev = predicate
            predicate = #Predicate<Trade> { prev.evaluate($0) && p.evaluate($0) }
        }

        var descriptor = FetchDescriptor<Trade>(
            predicate: predicate,
            sortBy: [
                // Keep stock equality already in predicate; primary sort by dateTime
                SortDescriptor(\.dateTime, order: ascending ? .forward : .reverse)
            ]
        )
        if let limit = fetchLimit { descriptor.fetchLimit = limit }
        return try context.fetch(descriptor)
    }
    
    // Convenience: fetch only user action trades (simReversed != "" OR simInvestByUser != 0)
    static func fetchUserActions(
        for stock: Stock,
        in context: ModelContext,
        start: Date? = nil,
        end: Date? = nil,
        TWSE: Bool? = nil,
        fetchLimit: Int? = nil,
        ascending: Bool = false
    ) throws -> [Trade] {
        return try fetch(
            in: context,
            for: stock,
            start: start,
            end: end,
            TWSE: TWSE,
            userActions: true,
            fetchLimit: fetchLimit,
            ascending: ascending
        )
    }

    // Delete duplicate trades on a given day for a stock, keeping the first by time (ascending)
    static func deleteDuplicates(
        in context: ModelContext,
        for stock: Stock,
        on day: Date,
        calendar: Calendar = .current
    ) throws {
        guard let startOfDay = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: day)),
              let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return }
        let trades = try fetch(
            in: context,
            for: stock,
            start: startOfDay,
            end: calendar.date(byAdding: .second, value: -1, to: endOfDay),
            TWSE: nil,
            userActions: nil,
            fetchLimit: nil,
            ascending: true
        )
        guard trades.count > 1 else { return }
        for (idx, t) in trades.enumerated() where idx > 0 {
            context.delete(t)
        }
        try context.save()
    }

    // Ensure a trade exists on a given day; if none, create one and attach to the provided stock
    static func ensureTrade(
        on day: Date,
        for stock: Stock,
        in context: ModelContext,
        calendar: Calendar = .current
    ) throws -> Trade {
        if let existing = try fetch(in: context, for: stock,  on: day, calendar: calendar) {
            return existing
        }
        // Create a new Trade with minimal defaults; callers should fill fields as needed
        let newTrade = Trade(
            dataSource: "TWSE",
            dateTime: calendar.startOfDay(for: day),
            priceClose: 0,
            priceHigh: 0,
            priceLow: 0,
            priceOpen: 0,
            volumeClose: 0,
            rollAmtCost: 0,
            rollAmtProfit: 0,
            rollAmtRoi: 0,
            rollDays: 0,
            rollRounds: 0,
            simAmtBalance: 0,
            simAmtCost: 0,
            simAmtProfit: 0,
            simAmtRoi: 0,
            simDays: 0,
            simInvestAdded: 0,
            simInvestByUser: 0,
            simInvestTimes: 0,
            simQtyBuy: 0,
            simQtyInventory: 0,
            simQtySell: 0,
            simReversed: "",
            simRule: "",
            simRuleBuy: "",
            simRuleInvest: "",
            simUnitCost: 0,
            simUnitRoi: 0,
            simUpdated: false,
            tHighDiff: 0,
            tHighDiff125: 0,
            tHighDiff250: 0,
            tHighDiffZ125: 0,
            tHighDiffZ250: 0,
            tHighMax9: 0,
            tLowDiff: 0,
            tLowDiff125: 0,
            tLowDiff250: 0,
            tLowDiffZ125: 0,
            tLowDiffZ250: 0,
            tLowMin9: 0,
            tMa20: 0,
            tMa20Days: 0,
            tMa20Diff: 0,
            tMa20DiffMax9: 0,
            tMa20DiffMin9: 0,
            tMa20DiffZ125: 0,
            tMa20DiffZ250: 0,
            tMa60: 0,
            tMa60Days: 0,
            tMa60Diff: 0,
            tMa60DiffMax9: 0,
            tMa60DiffMin9: 0,
            tMa60DiffZ125: 0,
            tMa60DiffZ250: 0,
            tZ125: 0,
            tZ250: 0,
            tKdK: 0,
            tKdKMax9: 0,
            tKdKMin9: 0,
            tKdKZ125: 0,
            tKdKZ250: 0,
            tKdD: 0,
            tKdDZ125: 0,
            tKdDZ250: 0,
            tKdJ: 0,
            tKdJZ125: 0,
            tKdJZ250: 0,
            tOsc: 0,
            tOscEma12: 0,
            tOscEma26: 0,
            tOscMacd9: 0,
            tOscMax9: 0,
            tOscMin9: 0,
            tOscZ125: 0,
            tOscZ250: 0,
            tPriceZ125: 0,
            tPriceZ250: 0,
            vMa20: 0,
            vMa20Days: 0,
            vMa20Diff: 0,
            vMa20DiffMax9: 0,
            vMa20DiffMin9: 0,
            vMa20DiffZ125: 0,
            vMa20DiffZ250: 0,
            vMa60: 0,
            vMa60Days: 0,
            vMa60Diff: 0,
            vMa60DiffMax9: 0,
            vMa60DiffMin9: 0,
            vMa60DiffZ125: 0,
            vMa60DiffZ250: 0,
            vMax9: 0,
            vMin9: 0,
            vZ125: 0,
            vZ250: 0,
            tUpdated: false,
            stock: stock
        )
        context.insert(newTrade)
        try context.save()
        return newTrade
    }
// MARK: - Lightweight shims to reduce compile errors from legacy usages
//xtension Trade {
    // Legacy aliases often referenced elsewhere
//    var date: Date { dateTime }

    // Some code expects a combined quantity `simQty`; map to inventory by default
//    var simQty: Double { simQtyInventory }

    // Price-volume convenience if referenced; compute as priceClose * volumeClose
//    var priceVolume: Double { priceClose * volumeClose }
//}

// MARK: - Optional placeholders for missing legacy fields
// If other parts of the code still reference fields like `grade`, `byGrade`, etc.,
// consider defining them here once you decide their semantics. For now, we avoid
// adding stubs that could hide logic bugs.

//extension Trade {

    
    // 對齊 Core Data: 以日為粒度的日期（startOfDay）
    var date: Date {
        Calendar.current.startOfDay(for: dateTime)
    }

    // 對齊 Core Data: 年數（至少為 1）
    var years: Double {
        let start = self.stock.dateStart
        let y = date.timeIntervalSince(start) / 86400.0 / 365.0
        return y >= 1 ? y : 1
    }

    // 對齊 Core Data: 平均持有天數計算
    var days: Double {
        if self.rollRounds <= 1 {
            return self.rollDays
        } else {
            let hasInventory = (self.simQtyInventory > 0)
            let prevRounds = self.rollRounds - (hasInventory ? 1 : 0)
            let prevDays = (self.rollDays - (hasInventory ? self.simDays : 0)) / prevRounds
            return (self.simDays > prevDays ? self.rollDays / self.rollRounds : prevDays)
        }
    }

    // 實年保酬率：未使用的加碼備用金不計入成本，取每輪使用到的現金乘以天數佔比合計為成本。
    var roi: Double {
        self.rollAmtRoi / self.years
    }

    // 真年報酬率：未使用到的加碼備用金也計入成本
    var baseRoi: Double {
        let s = self.stock
        if s.simInvestAuto < 10 {
            let base = (s.simInvestAuto + 1) * s.simMoneyBase * 10000
            return (100 * self.rollAmtProfit / base / self.years)
        } else {
            return 0
        }
    }

    // 總投資次數（人工 + 自動）
    var invested: Double {
        self.simInvestByUser + self.simInvestAdded
    }


    func resetInvestByUser() {
        self.simInvestByUser = 0
        if self.stock.simInvestUser > 0 {
            self.stock.simInvestUser -= 1
        } else {
            simLog.addLog("bug: \(self.stock.sId)\(self.stock.sName) \(twDateTime.stringFromDate(self.dateTime)) stock.simInvestUser = \(self.stock.simInvestUser) ???")
            self.stock.simInvestUser = 0
        }
    }

    var simQty:(action:String,qty:Double,roi:Double) {
        if self.simQtySell > 0 {
            return ("賣", simQtySell, simAmtRoi)
        } else if self.simQtyBuy > 0 {
            return ("買", simQtyBuy, simAmtRoi)
        } else if self.simQtyInventory > 0 {
            return ("餘", simQtyInventory, simAmtRoi)
        } else {
            return ("", 0, 0)
        }
    }

    func resetSimValues() {
        self.simAmtCost = 0
        self.simAmtProfit = 0
        self.simAmtRoi = 0
        self.simDays = 0
        self.simQtyBuy = 0
        self.simQtyInventory = 0
        self.simQtySell = 0
        self.simUnitCost = 0
        self.simUnitRoi = 0
        self.simRule = ""
        self.simRuleBuy = ""
        self.simRuleInvest = ""
        self.simInvestAdded = 0
    }

    func setDefaultValues() {
        self.rollAmtCost = 0
        self.rollAmtProfit = 0
        self.rollAmtRoi = 0
        self.rollDays = 0
        self.rollRounds = 0
        self.resetSimValues()
        if self.simInvestByUser != 0 {
            self.resetInvestByUser()
        }
        self.simInvestTimes = 0
        self.simAmtBalance = 0
        self.simReversed = ""
    }

    enum Grade: Int, Comparable {
        static func < (lhs: Trade.Grade, rhs: Trade.Grade) -> Bool { lhs.rawValue < rhs.rawValue }
        case wow  = 3
        case high = 2
        case fine = 1
        case none = 0
        case weak = -1
        case low  = -2
        case damn = -3
    }

    var grade: Grade {
        if self.rollRounds > 2 || self.days > 360 {
            if self.days < 65 && self.roi > 20 {
                return .wow
            } else if self.days < 65 && self.roi > 10 {
                return .high
            } else if self.days < 70 && self.roi > 5 {
                return .fine
            } else if self.days > 180 || self.roi < -20 {
                return .damn
            } else if self.days > 120 || self.roi < -10 {
                return .low
            } else if self.days > 60 || self.roi < -1 {
                return .weak
            }
        }
        return .none
    }

    func byGrade(_ values: [Double], L: Grade? = nil, H: Grade? = nil) -> Double {
        let l = L ?? .weak
        let h = H ?? .high
        if self.grade.rawValue <= l.rawValue {
            return values.first ?? 0
        } else if self.grade.rawValue >= h.rawValue {
            return values.last ?? 0
        } else if values.count == 3 {
            return values[1]
        } else if H != nil && L == nil {
            return values.first ?? 0
        } else {
            return values.last ?? 0
        }
    }
}

@MainActor
extension Trade {
    func gradeIcon(gray: Bool = false) -> some View {
        let color: Color = {
            if gray { return .gray }
            else if self.stock.simMoneyLacked { return Color(.darkGray) }
            else if self.grade.rawValue > 0 { return .red }
            else if self.grade.rawValue < 0 { return .green }
            else { return .gray }
        }()
        switch self.grade {
        case .wow:
            return Image(systemName: "star.square.fill").foregroundColor(color)
        case .damn:
            return Image(systemName: "3.square").foregroundColor(color)
        case .high, .low:
            return Image(systemName: "2.square").foregroundColor(color)
        case .fine, .weak:
            return Image(systemName: "1.square").foregroundColor(color)
        default:
            return Image(systemName: "0.square").foregroundColor(.gray)
        }
    }

    func color(_ scheme: ColorSchemeKey, gray: Bool = false, price: Double? = nil) -> Color {
        if gray {
            if scheme == .ruleB || (scheme == .ruleR && self.simRule != "L" && self.simRule != "H") {
                return .clear
            } else {
                return .gray
            }
        }
        let thePrice: Double = price ?? self.priceClose
        let p10Action: String = self.stock.p10Action ?? ""
        let p10Rule: String? = self.stock.p10Rule
        let p10Date: Date = self.stock.p10Date ?? .distantFuture
        switch scheme {
        case .price:
            if p10Action == "" || p10Date != self.date {
                if self.tLowDiff == 10 && self.priceLow == thePrice {
                    return .green
                } else if self.tHighDiff == 10 && self.priceHigh == thePrice {
                    return .red
                }
            }
            return self.color(price == nil ? .ruleF : .time)
        case .time:
            if twDateTime.inMarketingTime(self.dateTime) {
                return Color(UIColor.purple)
            } else if self.simRule == "_" {
                return .gray
            } else {
                return .primary
            }
        case .rule:
            let rule = (p10Action != "買" || p10Date != self.date ? self.simRule : (p10Rule ?? self.simRule))
            switch rule {
            case "L": return .green
            case "H": return .red
            default:
                if self.simRuleInvest == "A" { return .green }
                else if self.simInvestByUser > 0 { return .orange }
                return .primary
            }
        case .ruleF:
            if p10Action != "" && p10Date == self.date {
                return .white
            } else {
                return self.color(.time)
            }
        case .ruleB:
            if p10Action != "" && p10Date == self.date {
                if p10Rule == "B" || p10Rule == "S" { return .gray }
                else if p10Action == "賣" { return .blue }
                else { return self.color(.rule) }
            } else {
                return .clear
            }
        case .ruleR:
            if self.simRule == "L" || self.simRule == "H" { return self.color(.rule) }
            else { return .clear }
        case .qty:
            switch self.simQty.action {
            case "賣": return .blue
            case "買": return self.color(.rule)
            default: return .primary
            }
        }
    }


}

