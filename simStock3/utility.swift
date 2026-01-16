//
//  checkInternet.swift
//  simStock
//
//  Created by peiyu on 2016/6/23.
//  Copyright © 2016年 unLock.com.tw. All rights reserved.
//

import Foundation
import SystemConfiguration
import Network

//public let defaults = UserDefaults.standard // UserDefaults(suiteName: "group.com.mystock.simStock21") ??
public class defaults {
    static var start:Date {UserDefaults.standard.object(forKey: "simDateStart") as? Date ?? Date.distantFuture}
    static var money:Double {UserDefaults.standard.double(forKey: "simMoneyBase")}
    static var invest:Double {UserDefaults.standard.double(forKey: "simAutoInvest")}
    static var simDefault: String {
        let startX = twDateTime.stringFromDate(self.start, format: "起始日yyyy/MM/dd")
        let moneyX = String(format: "起始本金%.f萬元", self.money)
        let investX = (self.invest > 9 ? "自動無限加碼" : (self.invest > 0 ? String(format: "自動%.0f次加碼", self.invest) : ""))
        return "新股預設：\(startX) \(moneyX) \(investX)"

    }
    static func set (start:Date,money:Double,invest:Double) {
        UserDefaults.standard.set(start, forKey: "simDateStart")
        UserDefaults.standard.set(money, forKey: "simMoneyBase")
        UserDefaults.standard.set(invest, forKey: "simAutoInvest")
    }
    static func bootstrapIfNeeded() {   //simObject的init會負責這個起始呼叫
        if self.money == 0 {
            let dateStart = twDateTime.calendar.date(byAdding: .year, value: -3, to: twDateTime.startOfDay()) ?? Date.distantFuture
            self.set(start: dateStart, money: 70.0, invest: 2)
        }
    }
    
    static var first: Date {twDateTime.calendar.date(byAdding: .year, value: -1, to: start) ?? start}

    static var action: String? {UserDefaults.standard.string(forKey: "simAction")}
    static func setAction(_ action:String) {
        UserDefaults.standard.set(version, forKey: "simAction")
    }

    static var version: String {UserDefaults.standard.string(forKey: "simStockVersion") ?? ""}
    static func setVersion(_ version:String) {
        UserDefaults.standard.set(version, forKey: "simStockVersion")
    }

    static var simTesting: Bool {UserDefaults.standard.bool(forKey: "simTesting")}
    static func setTesting(_ testing:Bool) {
        UserDefaults.standard.set(testing, forKey: "simTesting")
    }

    static func remove(_ objectKey:String) {
        UserDefaults.standard.removeObject(forKey: objectKey)
    }

    static var timeTradesUpdated:Date {UserDefaults.standard.object(forKey: "timeTradesUpdated") as? Date ?? Date.distantPast}
    static func setTimeTradesUpdated(_ date:Date=Date()) {
        UserDefaults.standard.set(date, forKey: "timeTradesUpdated")
    }

    static var timeStocksDownloaded:Date? {UserDefaults.standard.object(forKey: "timeStocksDownloaded") as? Date}
    static func setTimeStocksDownloaded(_ date:Date=Date()) {
        UserDefaults.standard.set(date, forKey: "timeStocksDownloaded")
    }

    static var timeCompanyInfoUpdated:Date? {UserDefaults.standard.object(forKey: "timeCompanyInfoUpdated") as? Date}
    static func setTimeCompanyInfoUpdated(_ date:Date=Date()) {
        UserDefaults.standard.set(date, forKey: "timeCompanyInfoUpdated")
    }
}

public class simLog {
    static var Log:[(time:String, text:String)] = []
    static var shrink:[(time:String, text:String)] = []
    
    static func addLog(_ text:String) {
        if text.count > 0 {
            NSLog(text)
            Log.append((time:twDateTime.stringFromDate(format: "yyyy/MM/dd HH:mm:ss"), text:text))
        }
    }
    
    static func logReportText() -> String {
        var logReport:String = ""
        var logTime:String = ""
        for log in Log.reversed() {
            if log.time != logTime {
                if logTime != ""  {
                    logReport += "\n"
                }
                logTime = log.time
                logReport += log.time + "\n"
            }
            logReport += log.text + "\n"
        }
        return logReport
    }
    
    static func logReportArray() -> [String] {
        let reportText = logReportText().replacingOccurrences(of: "\n\n", with: "\n \n")
        let reportArray = Array(reportText.split(separator: "\n").map{String($0)}) + [""]
        return reportArray
    }
    
    static func shrinkLog (_ number:Int) {
        if Log.count > Int(1.5 * Float(number)) {
            shrink.append((twDateTime.stringFromDate(format: "yyyy/MM/dd HH:mm:ss"),"log被縮減\(number)則。"))
            if shrink.count > 3 {
                let left = shrink.count - 3
                shrink = Array(shrink[left...])
            }
            let left = Log.count - number
            Log = shrink + Array(Log[left...])
        }
    }
    
//    static func lineLog() {
//        linePush(logReportText())
//        Log = []
//    }
//    
//    static func linePush (_ message:String="") {    //debug時才使用
//        let toUser:String = ""
//        let lineChannelToken = ""
//
//        let textMessages1 = ["type":"text","text":message]
//        let jsonMessages  = ["to":toUser,"messages":[textMessages1]] as [String : Any]
//        let jsonData = try? JSONSerialization.data(withJSONObject: jsonMessages)
//
//        let url = URL(string: "https://api.line.me/v2/bot/message/push")
//        var request = URLRequest(url: url!)
//        request.httpMethod = "POST"
//        request.httpBody = jsonData
//        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
//        request.setValue("Bearer \(lineChannelToken)", forHTTPHeaderField: "Authorization")
//
//        let task = URLSession.shared.dataTask(with: request) { data, response, error in
//            guard let data = data, error == nil else {
//                NSLog(error?.localizedDescription ?? "No response from LINE.")
//                return
//            }
//            let responseJSONData = try? JSONSerialization.jsonObject(with: data, options: [])
//            if let responseJSON = responseJSONData as? [String: Any] {
//                if responseJSON.count > 0 {
//                    NSLog("Response from LINE:\n\(responseJSON)\n")
//                }
//            }
//        }
//        task.resume()
//    }
//

}

public class netConnect {  // 偵測網路連線是否有效
    static func isNotOK() -> Bool {
        // Use Network framework instead of deprecated SystemConfiguration reachability APIs
        // Returns true when network is not available or requires connection
        let monitor = NWPathMonitor()
        let queue = DispatchQueue.global(qos: .utility)
        let semaphore = DispatchSemaphore(value: 0)
        var isNotOKResult: Bool = true

        monitor.pathUpdateHandler = { path in
            // Consider satisfied paths as OK; otherwise not OK
            if path.status == .satisfied {
                // Optionally, require an interface (e.g., wifi/cellular). Here, any satisfied path is OK.
                isNotOKResult = false
            } else {
                isNotOKResult = true
            }
            semaphore.signal()
            monitor.cancel()
        }
        monitor.start(queue: queue)

        // Wait briefly for a path update; timeout to avoid blocking indefinitely
        let timeoutResult = semaphore.wait(timeout: .now() + 1.0)
        if timeoutResult == .timedOut {
            // If we timed out, conservatively assume not OK
            return true
        }
        return isNotOKResult
    }
}

public class operation {
    static let serialQueue = OperationQueue()
    init() {
        operation.serialQueue.maxConcurrentOperationCount = 1
    }
}

public class twDateTime { //用於台灣當地日期時間的一些計算函數，避免不同時區的時差問題

    static let calendar:Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_Hant_TW")
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    } ()

    static func formatter(_ format:String="yyyy/MM/dd") -> DateFormatter  {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")!
        formatter.dateFormat = format
        return formatter
    }

    static func timeAtDate(_ date:Date=Date(), hour:Int, minute:Int, second:Int=0) -> Date {
        var dtComponents = calendar.dateComponents(in: TimeZone(identifier: "Asia/Taipei")!, from: date)
        dtComponents.hour = hour
        dtComponents.minute = minute
        dtComponents.second = second
        dtComponents.nanosecond = 0
        if let theTime = calendar.date(from: dtComponents) {
            return theTime
        } else {
            return date
        }
    }


    static func time0900(_ date:Date=Date(), delayMinutes:Int=0) -> Date {
        if delayMinutes < 0 || delayMinutes > 60 {
            if let dt = self.calendar.date(byAdding: .minute, value: delayMinutes, to: self.timeAtDate(date, hour: 9, minute: 0)) {
                return dt
            }
        }
        return self.timeAtDate(date, hour: 09, minute: delayMinutes)
    }

    static func time1330(_ date:Date=Date(), delayMinutes:Int=0) -> Date {
        if delayMinutes < -30 || delayMinutes > 30 {
            if let dt = self.calendar.date(byAdding: .minute, value: delayMinutes, to: self.timeAtDate(date, hour: 13, minute: 30)) {
                return dt
            }
        }
        return self.timeAtDate(date, hour: 13, minute: 30+delayMinutes)
    }

    static func startOfDay(_ date:Date=Date()) -> Date {
        let dt = self.timeAtDate(date, hour: 0, minute: 0, second: 0)
        return dt
    }


    static func endOfDay(_ date:Date=Date()) -> Date {
        let dt = self.timeAtDate(date, hour: 23, minute: 59, second: 59)
        return dt
    }

    static func isDateInToday(_ date:Date) -> Bool {
        if date >= self.startOfDay() && date <= self.endOfDay() {
            return true
        } else {
            return false
        }
    }

    static func startOfMonth(_ date:Date=Date()) -> Date {
        let yyyyMM:DateComponents = self.calendar.dateComponents([.year, .month], from: date)

        if let dt = self.calendar.date(from: yyyyMM) {
            return self.startOfDay(dt)
        } else {
            return date
        }
    }

    static func endOfMonth(_ date:Date=Date()) -> Date {
        if let dt = self.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: self.startOfMonth(date)) {
            return dt
        } else {
            return date
        }
    }

    static func yesterday(_ date:Date=Date()) -> Date {
        if let dt = self.calendar.date(byAdding: .day, value: -1, to: date) {
            return self.startOfDay(dt)
        } else {
            return self.startOfDay(date)
        }
    }

    static func back10Days(_ date:Date) -> Date {
        if let dt = self.calendar.date(byAdding: .day, value: -10, to: date) {
            return self.startOfDay(dt)
        } else {
            return self.startOfDay(date)
        }
    }

    static func dateFromString(_ date:String, format:String="yyyy/MM/dd") -> Date? {
        if let dt = self.formatter(format).date(from: date) {
            return dt
        } else {
            return nil
        }
    }

    static func stringFromDate(_ date:Date=Date(), format:String="yyyy/MM/dd") -> String {
        let dt = self.formatter(format).string(from: date)
        return dt
    }

    static func inMarketingTime(_ time:Date=Date(), delay:Int = 0, forToday:Bool=false) -> Bool {
        let time1330 = self.time1330(time, delayMinutes:delay)
        let time0900 = self.time0900(time, delayMinutes:0 - delay)
        let inToday = self.isDateInToday(time)
        if time < time1330 && time >= time0900 && (inToday || !forToday) {
            return true
        } else {
            return false    //盤外時間
        }

    }
    
}
