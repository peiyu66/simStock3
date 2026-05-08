//
//  csvData.swift
//  simStock21
//
//  Created by peiyu on 2021/5/23.
//  Copyright © 2021 peiyu. All rights reserved.
//

import Foundation
import SwiftData

public class csvData {
    
    static let shared = csvData()
    
    typealias StocksInfo = [(id:String,name:String,group:String,proport1:String,dateStart:Date)]
    
    static func csvToFile(_ csv:String, prefix:String?=nil) -> URL? { //產生單csv檔案
        let fileName:String = (prefix ?? "") + twDateTime.stringFromDate(format: "yyyyMMdd-HHmmssSSS") + ".csv"
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = dir.appendingPathComponent(fileName)
            do {
                try csv.write(to: fileURL, atomically: false, encoding: .utf8)
                return fileURL
            } catch {
                NSLog("csvToFile error \t\(error)")
            }
        }
        return nil
    }
    
    static func fetchStocksInfo(in context: ModelContext, _ sId:[String]?=nil) -> StocksInfo {
        //在intents互傳NSManagedObject都會壞掉，可能是只能傳struct不能傳class？所以要在同個function內轉換。
        var info:StocksInfo = []
        let stocks: [Stock] = (try? Stock.fetch(in: context, sId: sId)) ?? []
        for stock in stocks {
            info.append((stock.sId,stock.sName,stock.group,stock.proport1,stock.dateStart))
        }
        return info
    }
        
    static func getStocks(in context: ModelContext, _ info:StocksInfo) -> [Stock] {
        let stockIds = info.map { $0.id }
        return (try? Stock.fetch(in: context, sId: stockIds)) ?? []
    }
    
    static func csvStocksIdName(_ stocks:[Stock], byGroup:Bool=true) -> String {
        let groupStocks:[[Stock]] = Dictionary(grouping: stocks)
            { (stock:Stock)  in stock.group}.values
            .map{$0.map{$0}.sorted{$0.sName < $1.sName}}
            .sorted {$0[0].group < $1[0].group}
        var csv:String = ""
        var ids:String = ""
        for group in groupStocks {
            if byGroup {
                ids = ""
            }
            if byGroup {
                csv += "\(group[0].group)\n"
            }
            for stock in group {
                if csv.count > 0 && csv.suffix(1) != "\n" {
                    csv += ", "
                }
                csv += stock.sId + " " + stock.sName
                if ids.count > 0 {
                    ids += ","
                }
                ids += "\(stock.sId)"
            }
            if byGroup {
                csv += "\n\n\(ids)\n\n"
            }
        }
        if !byGroup {
            csv += "\n\n\(ids)\n"
        }
        return csv
    }
    
    static func csvTrans(in context: ModelContext, _ stocks:StocksInfo, start:Date?=nil) -> String {
        var csv:String = ""
        var stockObjects:[Stock] = []
        let stockIds = stocks.map{$0.id}
        for sId in stockIds {
            if let stock = try? Stock.fetch(in: context, sId: [sId]).first {
                stockObjects.append(stock)
            }
        }
        for stock in stockObjects {
            let startDate = start ?? stock.dateStart
            let trades: [Trade] = (try? Trade.fetch(in: context, for: stock, start: startDate, end: nil, TWSE: nil, userActions: nil, fetchLimit: nil, ascending: true)) ?? []
            for trade in trades {
                let date = twDateTime.stringFromDate(trade.dateTime, format: "yyyy/MM/dd")
                let time = twDateTime.stringFromDate(trade.dateTime, format: "HH:mm")
                csv += "\(stock.sId),\(stock.sName),\(stock.group),\(date),\(time),"
                let close:String = String(format: "%.2f", trade.priceClose)
                let open:String = String(format: "%.2f", trade.priceOpen)
                let high:String = String(format: "%.2f", trade.priceHigh)
                let low:String = String(format: "%.2f", trade.priceLow)
                let volume:String = String(format: "%.0f", trade.volumeClose)
                let volz:String = String(format: "%.2f", trade.vZ125)
                csv += "\(close),\(open),\(high),\(low),\(volume),\(volz),"
                let buy:String = String(format: "%.0f", trade.simQtyBuy)
                let inv:String = String(format: "%.0f", trade.simQtyInventory)
                let sell:String = String(format: "%.0f", trade.simQtySell)
                let cost:String = String(format: "%.2f", trade.simUnitCost)
                let invt:String = String(format: "%.0f", trade.simInvestTimes)
                let days:String = String(format: "%.0f", trade.simDays)
                var rule:String {
                    var rules:String = ""
                    if trade.simRuleInvest == "A" {
                        rules = "加碼"
                    } else if trade.simRule == "L" {
                        rules = "低買"
                    } else if trade.simRule == "H" {
                        rules = "高買"
                    }
                    return rules
                }
                let pRule:String = (rule != "" ? close : "-1")
                csv += "\(buy),\(inv),\(sell),\(cost),\(invt),\(days),\(rule),\(pRule),"
                let ma20:String = String(format: "%.2f", trade.tMa20)
                let ma20d:String = String(format: "%.2f", trade.tMa20Diff)
                let ma20z:String = String(format: "%.2f", trade.tMa20DiffZ125)
                let ma60:String = String(format: "%.2f", trade.tMa60)
                let ma60d:String = String(format: "%.2f", trade.tMa60Diff)
                let ma60z:String = String(format: "%.2f", trade.tMa60DiffZ125)
                let highdz:String = String(format: "%.2f", trade.tHighDiffZ125)
                let lowdz:String = String(format: "%.2f", trade.tLowDiffZ125)
                let closez:String = String(format: "%.2f", trade.tPriceZ125)
                csv += "\(ma20),\(ma20d),\(ma20z),\(ma60),\(ma60d),\(ma60z),\(highdz),\(lowdz),\(closez),"
                let k:String = String(format: "%.2f", trade.tKdK)
                let kz:String = String(format: "%.2f", trade.tKdKZ125)
                let d:String = String(format: "%.2f", trade.tKdD)
                let dz:String = String(format: "%.2f", trade.tKdDZ125)
                let j:String = String(format: "%.2f", trade.tKdJ)
                let jz:String = String(format: "%.2f", trade.tKdJZ125)
                let osc:String = String(format: "%.2f", trade.tOsc)
                let oscz:String = String(format: "%.2f", trade.tOscZ125)
                csv += "\(k),\(kz),\(d),\(dz),\(j),\(jz),\(osc),\(oscz),"
                let roi:String = String(format: "%.1f", trade.roi)
                let bRoi:String = String(format: "%.1f", trade.baseRoi)
                let rDays:String = String(format: "%.0f", trade.days)
                csv += "\(roi),\(bRoi),\(rDays)"
                csv += "\n"

            }
        }
        //header
        csv =   "代號,簡稱,股群,日期,時間,收盤價,開盤價,最高價,最低價,成交量,volz," +
                "買入,庫存,賣出,成本價,加碼次,持股日數,建議,買點," +
                "ma20,ma20d,ma20dz,ma60,ma60d,ma60dz,highdz,lowdz,closez," +
                "k,kz,d,dz,j,jz,osc,oscz," +
                "實年報酬率,真年報酬率,平均日數" +
                "\n" + csv
        return csv
    }
    

        
    static func csvMonthlyRoi(in context: ModelContext, _ stocks: [Stock], from:Date?=nil) -> String {
        var csv:String = ""
        var txtMonthly:String = ""

        func combineMM(_ allHeader:[String], newHeader:[String], newBody:[String]) -> (header:[String],body:[String]) {
            var mm = allHeader
            var bb = newBody
            for n in newHeader {
                var lm:String = ""
                var inserted:Bool = false
                for (idxM,m) in mm.enumerated() {
                    if n < m && n > lm {
                        mm.insert(n, at: idxM)
                        inserted = true
                        break
                    }
                    lm = m
                }
                if let ml = mm.last {
                    if !inserted && n > ml {
                        mm.append(n)
                    }
                } else {
                    mm.append(n)
                }
            }
            for m in mm {   // 反過來用補完的header來補body的欄位
                var ln:String = ""
                var inserted:Bool = false
                for (idxN,n) in newHeader.enumerated() {
                    if m < n && m > ln {
                        bb.insert("", at: idxN)
                        inserted = true
                        break
                    }
                    ln = n
                }
                if let nl = newHeader.last {
                    if !inserted && m > nl {
                        bb.append("")
                    }
                } else {
                    bb.append("")
                }
            }
            return (mm,bb)
        }

        var allHeader:[String] = []     // 合併後的月別標題：如果各股起迄月別不一致？所以需要合併
        var allHeaderX2:[String] = []   // 前兩欄，即簡稱和本金
        for stock in stocks {
            // 以最後一筆成交時間往前 6 個月作為起算點；若呼叫方提供 from 則採用 from
            let tFrom: Date = {
                if let f = from { return f }
                if let last = try? stock.lastTrade(in: context),
                   let f = twDateTime.calendar.date(byAdding: .month, value: -6, to: last.dateTime) {
                    return f
                }
                return Date.distantPast
            }()

            let txt = csvData.shared.csvStockRoi(context: context, stock: stock, from: tFrom)
            if txt.body.count > 0 { // 有損益才有字
                let subHeader = txt.header.split(separator: ",")
                var newHeader:[String] = []   // 待合併的新的月別標題
                if subHeader.count >= 3 {
                    for (i,s) in subHeader.enumerated() {
                        if i < 2 {
                            if allHeaderX2.count < 2 {
                                allHeaderX2.append(String(s).replacingOccurrences(of: " ", with: ""))
                            }
                        } else {
                            newHeader.append(String(s).replacingOccurrences(of: " ", with: ""))   // 順便去空白
                        }
                    }
                }
                let subBody = txt.body.split(separator: ",")
                var newBody:[String] = []   // 待補","分隔的數值欄
                var newBodyX2:[String] = [] // 前兩欄，即簡稱和本金
                if subBody.count >= 3 {
                    for (i,s) in subBody.enumerated() {
                        if i < 2 {
                            newBodyX2.append(String(s).replacingOccurrences(of: " ", with: "")) // 順便去空白
                        } else {
                            newBody.append(String(s).replacingOccurrences(of: " ", with: ""))   // 順便去空白
                        }
                    }
                }
                if newBody.count > 0 && newHeader.count > 0 {
                    // 每次都把標題和逐月損益，跟之前各股的合併，這樣才能確保全部股的月欄是對齊的
                    let all = combineMM(allHeader, newHeader:newHeader, newBody:newBody)
                    let allBody = newBodyX2 + all.body
                    let txtBody = (allBody.map{String($0)}).joined(separator: ", ")
                    txtMonthly += txtBody + "\n"
                    allHeader   = all.header
                }
            }
        }
        if txtMonthly.count > 0 {
            let title:String = "逐月已實現損益(%)"
            for (idx,h) in allHeader.enumerated() {
                if let d = twDateTime.dateFromString(h + "/01") {
                    if h.suffix(2) == "01" {
                        allHeader[idx] = twDateTime.stringFromDate(d, format: "yyyy/M月")
                    } else {
                        allHeader[idx] = twDateTime.stringFromDate(d, format: "M月")
                    }
                }
            }

            // 計算逐月合計，只能等全部股都合併完成後才好合計
            var sumMonthly:[Double]=[]  // 月別合計
            let txtBody:[String] = txtMonthly.components(separatedBy: CharacterSet.newlines) as [String]
            for b in txtBody where !b.isEmpty {
                let txtROI:[String] = b.components(separatedBy: ", ") as [String]
                for (idx,r) in txtROI.enumerated() {
                    var roi:Double = 0
                    if let dROI = Double(r) {
                        roi = dROI
                    }
                    if idx >= 2 {   // 前兩欄是簡稱和本金，故跳過
                        let i = idx - 2
                        if i == sumMonthly.count {
                            sumMonthly.append(roi)
                        } else {
                            sumMonthly[i] += roi
                        }
                    }
                }
            }
            let txtSummary = "合計,," + (sumMonthly.map{String(format:"%.1f",$0)}).joined(separator: ", ")

            // 把文字通通串起來
            let allHeader2 = allHeaderX2 + allHeader // 冠上之前保存的前兩欄標題，即簡稱和本金
            let txtHeader = (allHeader2.map{String($0)}).joined(separator: ", ") + "\n"
            csv = "\(txtHeader)\(txtMonthly)\(txtSummary)\n\n\(title)\n" // 最後空行可使版面周邊的留白對稱
        }

        return csv
    }
    
    
    
    private func csvStockRoi(context: ModelContext, stock: Stock, from: Date) -> (header:String,body:String) {
        /*
        func padding(_ text:String ,toLength: Int=7, character: Character=" ", toRight:Bool=false) -> String {
            var txt:String = ""
            var len:Int = 0
            if text.count > 0 {
                for c in text {
                    let C = Character(String(c).uppercased())
                    if c >= "0" && c < "9" || C >= "A" && C <= "Z" || c == "­" || c == "%" || c == "." || c == " " {
                        len += 1
                    } else {
                        len += 2    //可能是中文字，要算2個space的位置
                        if len - toLength == 1 {    //超過截斷，但是只超過1位要補1位的space
                            txt += " "
                        }
                    }
                    if len <= toLength {
                        txt += String(c)
                    }

                }
                let newLength = len //text.count    //在固定長度的String左邊填空白
                if newLength < toLength {
                    if toRight {
                        txt = txt + String(repeatElement(character, count: toLength - newLength))
                    } else {
                        txt = String(repeatElement(character, count: toLength - newLength)) + txt
                    }
                }
            } else {
                txt = String(repeatElement(character, count: toLength))
            }
            return txt
        }   */

        var txtHeader:String = ""
        var txtBody:String = ""
        var mm:Date = twDateTime.startOfMonth(from)
        var roi:Double = 0
        var roiSum:Double = 0
        var maxMoney:Double = 0
        let trades: [Trade] = (try? Trade.fetch(in: context, for: stock, start: from, end: nil, TWSE: nil, userActions: nil, fetchLimit: nil, ascending: true)) ?? []
        for trade in trades {
            let mmTrade = twDateTime.startOfMonth(trade.dateTime)
            if mmTrade > mm {  //跨月了
                let txtRoi = (roi == 0 ? "" : String(format:"%.1f%",roi))
                txtHeader += ", \(twDateTime.stringFromDate(mm, format: "yyyy/MM"))"
                txtBody   += ", \(txtRoi)"
                mm  = mmTrade
                roi = 0
            }
            if trade.simQtySell > 0 {
                roi += trade.simAmtRoi
                roiSum += trade.simAmtRoi
                if trade.simInvestTimes > maxMoney {
                    maxMoney = trade.simInvestTimes
                }
            }
        }
        if maxMoney > 0 {
            let txtRoi = (roi == 0 ? "" : String(format:"%.1f%",roi))
            let txtSum = String(format:"%.1f%",roiSum)
            txtHeader = "簡稱" + ", 本金" + txtHeader + ", \(twDateTime.stringFromDate(mm, format: "yyyy/MM"))" + ",小計"
            txtBody   = stock.sName + ", \(String(format:"x%.f",maxMoney))" + txtBody + ", \(txtRoi)" + ", \(txtSum)"
        } else {
            txtHeader = ""
            txtBody   = ""
        }
        return (txtHeader,txtBody)
    }

}

