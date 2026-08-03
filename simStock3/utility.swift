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
    static func set (start:Date,money:Double,invest:Double,userDefined:Bool=true) {
        UserDefaults.standard.set(start, forKey: "simDateStart")
        UserDefaults.standard.set(money, forKey: "simMoneyBase")
        UserDefaults.standard.set(invest, forKey: "simAutoInvest")
        UserDefaults.standard.set(userDefined, forKey: "simDefaultUserDefined")
    }
    static func bootstrapIfNeeded() {   //simObject的init會負責這個起始呼叫
        // `simAction` was an incomplete legacy resume flag. Clear any value
        // left by an older build now that startup no longer reads it.
        UserDefaults.standard.removeObject(forKey: "simAction")

        let today = twDateTime.startOfDay()
        let dateStart = twDateTime.calendar.date(byAdding: .year, value: -1, to: today) ?? Date.distantFuture
        if self.money == 0 {
            self.set(start: dateStart, money: 70.0, invest: 2, userDefined: false)
        } else if !UserDefaults.standard.bool(forKey: "simDefaultPeriodOneYearMigrated"),
                  !UserDefaults.standard.bool(forKey: "simDefaultUserDefined") {
            // Migrate former automatic defaults without replacing a
            // date that the user has deliberately customized.
            let legacyStarts = [-2, -3].compactMap {
                twDateTime.calendar.date(byAdding: .year, value: $0, to: today)
            }
            if legacyStarts.contains(where: { twDateTime.calendar.isDate(self.start, inSameDayAs: $0) }), self.money == 70, self.invest == 2 {
                self.set(start: dateStart, money: self.money, invest: self.invest, userDefined: false)
            }
            UserDefaults.standard.set(true, forKey: "simDefaultPeriodOneYearMigrated")
        }
    }
    
    static var first: Date {twDateTime.calendar.date(byAdding: .year, value: -1, to: start) ?? start}

    static var version: String {UserDefaults.standard.string(forKey: "simStockVersion") ?? ""}
    static func setVersion(_ version:String) {
        UserDefaults.standard.set(version, forKey: "simStockVersion")
    }

    /*
    // RETIRED: The UserDefaults-driven legacy test runner was replaced by the
    // isolated Internal Backtest dataset/report workflow.
    static var simTesting: Bool {UserDefaults.standard.bool(forKey: "simTesting")}
    static func setTesting(_ testing:Bool) {
        UserDefaults.standard.set(testing, forKey: "simTesting")
    }
    */

    static func remove(_ objectKey:String) {
        UserDefaults.standard.removeObject(forKey: objectKey)
    }

    static var timeTradesUpdated:Date {UserDefaults.standard.object(forKey: "timeTradesUpdated") as? Date ?? Date.distantPast}
    static func setTimeTradesUpdated(_ date:Date=Date()) {
        UserDefaults.standard.set(date, forKey: "timeTradesUpdated")
    }

    static var timeYahooCloseRefreshed: Date? {
        UserDefaults.standard.object(forKey: "timeYahooCloseRefreshed") as? Date
    }

    static var yahooCloseRefreshedStockIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "yahooCloseRefreshedStockIDs") ?? [])
    }

    static func recordYahooCloseRefresh(stockIDs: Set<String>, at date: Date = Date()) {
        guard !stockIDs.isEmpty else { return }

        let existingIDs: Set<String>
        if let previous = timeYahooCloseRefreshed,
           twDateTime.calendar.isDate(previous, inSameDayAs: date) {
            existingIDs = yahooCloseRefreshedStockIDs
        } else {
            existingIDs = []
        }

        UserDefaults.standard.set(date, forKey: "timeYahooCloseRefreshed")
        UserDefaults.standard.set(
            Array(existingIDs.union(stockIDs)).sorted(),
            forKey: "yahooCloseRefreshedStockIDs"
        )
    }

    static var timeStocksDownloaded:Date? {UserDefaults.standard.object(forKey: "timeStocksDownloaded") as? Date}
    static func setTimeStocksDownloaded(_ date:Date=Date()) {
        UserDefaults.standard.set(date, forKey: "timeStocksDownloaded")
    }

    static var stockCatalogLastUpdated: Date? {
        UserDefaults.standard.object(forKey: "stockCatalogLastUpdated") as? Date
    }

    static func setStockCatalogLastUpdated(_ date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: "stockCatalogLastUpdated")
    }

    static var timeCompanyInfoUpdated:Date? {UserDefaults.standard.object(forKey: "timeCompanyInfoUpdated") as? Date}
    static func setTimeCompanyInfoUpdated(_ date:Date=Date()) {
        UserDefaults.standard.set(date, forKey: "timeCompanyInfoUpdated")
    }
}

nonisolated enum DiagnosticSeverity: String, Codable, CaseIterable {
    case warning
    case error
    case critical

    var title: String {
        switch self {
        case .warning: return "注意"
        case .error: return "錯誤"
        case .critical: return "資料異常"
        }
    }
}

nonisolated enum DiagnosticSource: String, Codable, CaseIterable {
    case twse = "TWSE"
    case yahoo = "Yahoo"
    case network = "網路"
    case simulation = "模擬"
    case catalog = "股票名錄"
    case system = "系統"
}

nonisolated enum DiagnosticCategory: String, Codable {
    case connectivity = "連線"
    case response = "伺服器回應"
    case parsing = "資料解析"
    case dataIntegrity = "資料完整性"
    case calculation = "計算"
    case scheduling = "排程"
    case other = "其他"
}

nonisolated struct DiagnosticEvent: Codable, Identifiable {
    let id: UUID
    let date: Date
    let source: DiagnosticSource
    let severity: DiagnosticSeverity
    let category: DiagnosticCategory
    let stockID: String?
    let message: String
    var recoveredAt: Date?
}

nonisolated struct PriceUpdateDiagnosticSnapshot: Codable {
    let completedAt: Date
    let statusText: String
    let expectedTradingDate: Date?
    let marketStatus: String
    let twseRequestedMonths: Int
    let twseFailedMonths: Int
    let twsePendingHistoryMonths: Int?
    let yahooRequestedStocks: Int
    let yahooUpdatedStocks: Int
    let yahooSuccessfulStocks: Int
    let yahooSkippedStocks: Int

    var hasFailures: Bool {
        twseFailedMonths > 0 || yahooSuccessfulStocks < yahooRequestedStocks
    }
}

extension Notification.Name {
    static let diagnosticEventAdded = Notification.Name("simStock3.diagnosticEventAdded")
}

public class simLog {
    static var Log:[(time:String, text:String)] = []
    static var shrink:[(time:String, text:String)] = []
    private static let diagnosticEventsKey = "diagnosticEvents.v1"
    private static let diagnosticLastViewedKey = "diagnosticLastViewed.v1"
    private static let priceUpdateSnapshotKey = "priceUpdateDiagnosticSnapshot.v1"
    private static let diagnosticLimit = 100
    private static let diagnosticRetention: TimeInterval = 7 * 24 * 60 * 60
    private static let lock = NSLock()
    private static var storedDiagnosticEvents: [DiagnosticEvent] = loadDiagnosticEvents()
    
    static func addLog(_ text:String) {
        if text.count > 0 {
            NSLog(text)
            lock.lock()
            Log.append((time:twDateTime.stringFromDate(format: "yyyy/MM/dd HH:mm:ss"), text:text))
            lock.unlock()
            if let event = diagnosticEvent(from: text) {
                addDiagnosticEvent(event)
            }
        }
    }

    static func recordPriceUpdate(_ snapshot: PriceUpdateDiagnosticSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: priceUpdateSnapshotKey)
        }
    }

    static func latestPriceUpdate() -> PriceUpdateDiagnosticSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: priceUpdateSnapshotKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PriceUpdateDiagnosticSnapshot.self, from: data)
    }

    static func diagnosticEvents() -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedDiagnosticEvents
            .filter { !isBenignDiagnosticEvent($0) }
            .sorted { $0.date > $1.date }
    }

    static func markYahooRecovered(stockID: String, at recoveredAt: Date = Date()) {
        lock.lock()
        var didChange = false
        for index in storedDiagnosticEvents.indices
        where shouldMarkRecovered(
            storedDiagnosticEvents[index],
            source: .yahoo,
            stockID: stockID,
            at: recoveredAt
        ) {
            storedDiagnosticEvents[index].recoveredAt = recoveredAt
            didChange = true
        }
        let events = storedDiagnosticEvents
        lock.unlock()

        guard didChange else { return }
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: diagnosticEventsKey)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .diagnosticEventAdded, object: nil)
        }
    }

    static func shouldMarkRecovered(
        _ event: DiagnosticEvent,
        source: DiagnosticSource,
        stockID: String,
        at recoveredAt: Date
    ) -> Bool {
        event.recoveredAt == nil
            && event.date < recoveredAt
            && event.source == source
            && event.stockID == stockID
            && event.category == .connectivity
    }

    static func unreadDiagnosticCount() -> Int {
        let lastViewed = UserDefaults.standard.object(forKey: diagnosticLastViewedKey) as? Date
            ?? Date.distantPast
        return diagnosticEvents().filter { $0.date > lastViewed }.count
    }

    static func markDiagnosticsViewed() {
        UserDefaults.standard.set(Date(), forKey: diagnosticLastViewedKey)
        NotificationCenter.default.post(name: .diagnosticEventAdded, object: nil)
    }

    static func diagnosticReportText(deviceDescription: String) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "simStock3 更新診斷報告",
            "產生時間：\(twDateTime.stringFromDate(format: "yyyy/MM/dd HH:mm:ss"))",
            "App：\(version) (\(build))",
            "系統：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "裝置：\(deviceDescription)"
        ]

        if let snapshot = latestPriceUpdate() {
            lines.append("")
            lines.append("最近更新：\(twDateTime.stringFromDate(snapshot.completedAt, format: "yyyy/MM/dd HH:mm:ss"))")
            lines.append("結果：\(snapshot.statusText)")
            if let expectedDate = snapshot.expectedTradingDate {
                lines.append("預期 TWSE 資料日：\(twDateTime.stringFromDate(expectedDate))")
            }
            lines.append("市場狀態：\(snapshot.marketStatus)")
            let pendingHistoryMonths = snapshot.twsePendingHistoryMonths ?? 0
            if snapshot.twseRequestedMonths > 0 {
                var twseLine = "TWSE：成功 \(snapshot.twseRequestedMonths - snapshot.twseFailedMonths)/\(snapshot.twseRequestedMonths) 個月份"
                if pendingHistoryMonths > 0 {
                    twseLine += "，尚待補 \(pendingHistoryMonths) 個月份"
                }
                lines.append(twseLine)
            } else {
                lines.append(
                    pendingHistoryMonths > 0
                        ? "TWSE：近期資料已完整，歷史尚待補 \(pendingHistoryMonths) 個月份"
                        : "TWSE：歷史資料已完整，無需查詢"
                )
            }
            if snapshot.yahooRequestedStocks > 0 {
                lines.append("Yahoo：要求 \(snapshot.yahooRequestedStocks)，成功 \(snapshot.yahooSuccessfulStocks)，更新 \(snapshot.yahooUpdatedStocks)，略過 \(snapshot.yahooSkippedStocks)")
            } else {
                lines.append(
                    snapshot.yahooSkippedStocks > 0
                        ? "Yahoo：略過 \(snapshot.yahooSkippedStocks) 檔"
                        : "Yahoo：無需查詢"
                )
            }
        } else {
            lines.append("")
            lines.append("最近更新：尚無摘要")
        }

        let events = Array(diagnosticEvents().prefix(20))
        lines.append("")
        lines.append("最近異常（\(events.count)）")
        if events.isEmpty {
            lines.append("未記錄到網路、解析或資料異常。")
        } else {
            for event in events {
                let stock = event.stockID.map { " [\($0)]" } ?? ""
                let recovery = event.recoveredAt.map {
                    "（已恢復 \(twDateTime.stringFromDate($0, format: "MM/dd HH:mm:ss"))）"
                } ?? ""
                lines.append(
                    "\(twDateTime.stringFromDate(event.date, format: "MM/dd HH:mm:ss")) "
                    + "\(event.severity.title)\(recovery) \(event.source.rawValue)/\(event.category.rawValue)\(stock)：\(event.message)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }
    
    static func logReportText() -> String {
        lock.lock()
        let logs = Log
        lock.unlock()
        var logReport:String = ""
        var logTime:String = ""
        for log in logs.reversed() {
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
        lock.lock()
        defer { lock.unlock() }
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

    private static func addDiagnosticEvent(_ event: DiagnosticEvent) {
        lock.lock()
        let cutoff = Date().addingTimeInterval(-diagnosticRetention)
        storedDiagnosticEvents.append(event)
        storedDiagnosticEvents = Array(
            storedDiagnosticEvents
                .filter { $0.date >= cutoff }
                .suffix(diagnosticLimit)
        )
        let events = storedDiagnosticEvents
        lock.unlock()

        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: diagnosticEventsKey)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .diagnosticEventAdded, object: nil)
        }
    }

    private static func loadDiagnosticEvents() -> [DiagnosticEvent] {
        guard let data = UserDefaults.standard.data(forKey: diagnosticEventsKey),
              let events = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-diagnosticRetention)
        return Array(
            events
                .filter { $0.date >= cutoff && !isBenignDiagnosticEvent($0) }
                .suffix(diagnosticLimit)
        )
    }

    private static func diagnosticEvent(from text: String) -> DiagnosticEvent? {
        let lower = text.lowercased()
        // Cnyes is no longer a price source. Ignore diagnostics retained from
        // the retired legacy parser so they do not masquerade as current
        // update failures after upgrading the app.
        guard !lower.contains("cnyes") else { return nil }
        guard !isBenignYahooNoChangeMessage(lower) else { return nil }
        guard !isBenignTimerLifecycleMessage(lower) else { return nil }
        let severity: DiagnosticSeverity?

        let criticalTokens = [
            "inf", "nan", "無效數值", "成交價無效",
            "save/recalc error", "raw save error", "重算失敗", "重算恢復失敗"
        ]
        let errorTokens = [
            "下載有誤", "下載無資料", "解析無交易資料", "解析失敗",
            "欄位不足", "invalid", "no data", "error:", "失敗", "有誤",
            "逾時", "timeout", "timed out", "網路未連線", "中斷"
        ]
        let warningTokens = [
            "略過", "未更新", "非今日資料", "日期在未來",
            "查無", "沒有交易資料", "無交易資料", "改用本機資料",
            "前查價未完"
        ]

        if criticalTokens.contains(where: lower.contains) {
            severity = .critical
        } else if errorTokens.contains(where: lower.contains) {
            severity = .error
        } else if warningTokens.contains(where: lower.contains) {
            severity = .warning
        } else {
            severity = nil
        }
        guard let severity else { return nil }

        let source: DiagnosticSource
        if lower.contains("yahoo") {
            source = .yahoo
        } else if lower.contains("twse") {
            source = .twse
        } else if lower.contains("網路") {
            source = .network
        } else if lower.contains("模擬") || lower.contains("重算") {
            source = .simulation
        } else if lower.contains("股票名錄") || lower.contains("companyinfo") {
            source = .catalog
        } else {
            source = .system
        }

        let category: DiagnosticCategory
        if lower.contains("網路") || lower.contains("timeout") || lower.contains("timed out") || lower.contains("下載") {
            category = .connectivity
        } else if lower.contains("解析") || lower.contains("欄位") || lower.contains("invalid") || lower.contains("no data") {
            category = .parsing
        } else if lower.contains("inf") || lower.contains("nan") || lower.contains("無效數值") || lower.contains("成交價無效") {
            category = .dataIntegrity
        } else if lower.contains("重算") || lower.contains("模擬") || lower.contains("save") {
            category = .calculation
        } else if lower.contains("排程") || lower.contains("timer") {
            category = .scheduling
        } else if lower.contains("回應") || lower.contains("stat") {
            category = .response
        } else {
            category = .other
        }

        let stockID = text.range(of: #"(?<!\d)\d{4}(?!\d)"#, options: .regularExpression)
            .map { String(text[$0]) }
        let trimmed = text.count > 1_000 ? String(text.prefix(1_000)) + "…" : text
        return DiagnosticEvent(
            id: UUID(),
            date: Date(),
            source: source,
            severity: severity,
            category: category,
            stockID: stockID,
            message: trimmed,
            recoveredAt: nil
        )
    }

    private static func isBenignDiagnosticEvent(_ event: DiagnosticEvent) -> Bool {
        let lower = event.message.lowercased()
        return lower.contains("cnyes")
            || (event.source == .yahoo && isBenignYahooNoChangeMessage(lower))
            || isBenignTimerLifecycleMessage(lower)
    }

    private static func isBenignYahooNoChangeMessage(_ lowercasedMessage: String) -> Bool {
        lowercasedMessage.contains("yahoo 未更新")
    }

    static func isBenignTimerLifecycleMessage(_ message: String) -> Bool {
        message.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == "timer invalidated."
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
