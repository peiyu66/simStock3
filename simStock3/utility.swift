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
        let dateStart = twDateTime.requestStart(for: today)
        if self.money == 0 {
            self.set(start: dateStart, money: 70.0, invest: 2, userDefined: false)
        } else if !UserDefaults.standard.bool(forKey: "simDefaultPeriodOneYearMigrated"),
                  !UserDefaults.standard.bool(forKey: "simDefaultUserDefined") {
            // Migrate former automatic defaults without replacing a
            // date that the user has deliberately customized.
            let legacyStarts = [-2, -3].compactMap {
                twDateTime.calendar.date(byAdding: .year, value: $0, to: today)
            }
            if legacyStarts.contains(where: { twDateTime.isSameDay(self.start, $0) }), self.money == 70, self.invest == 2 {
                self.set(start: dateStart, money: self.money, invest: self.invest, userDefined: false)
            }
            UserDefaults.standard.set(true, forKey: "simDefaultPeriodOneYearMigrated")
        }
    }
    
    static var first: Date {twDateTime.requestStart(for: start)}

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
    static func setTimeTradesUpdated(_ date:Date=twDateTime.now()) {
        UserDefaults.standard.set(date, forKey: "timeTradesUpdated")
    }

    static var timeYahooCloseRefreshed: Date? {
        UserDefaults.standard.object(forKey: "timeYahooCloseRefreshed") as? Date
    }

    static var yahooCloseRefreshedStockIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "yahooCloseRefreshedStockIDs") ?? [])
    }

    static func recordYahooCloseRefresh(stockIDs: Set<String>, at date: Date = twDateTime.now()) {
        guard !stockIDs.isEmpty else { return }

        let existingIDs: Set<String>
        if let previous = timeYahooCloseRefreshed,
           twDateTime.isSameDay(previous, date) {
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
    static func setTimeStocksDownloaded(_ date:Date=twDateTime.now()) {
        UserDefaults.standard.set(date, forKey: "timeStocksDownloaded")
    }

    static var stockCatalogLastUpdated: Date? {
        UserDefaults.standard.object(forKey: "stockCatalogLastUpdated") as? Date
    }

    static func setStockCatalogLastUpdated(_ date: Date = twDateTime.now()) {
        UserDefaults.standard.set(date, forKey: "stockCatalogLastUpdated")
    }

    static var timeCompanyInfoUpdated:Date? {UserDefaults.standard.object(forKey: "timeCompanyInfoUpdated") as? Date}
    static func setTimeCompanyInfoUpdated(_ date:Date=twDateTime.now()) {
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
    var timings: PriceUpdateTimings? = nil
    var marketRequestedMonths: Int? = nil
    var marketFailedMonths: Int? = nil
    var yahooMarketFailed: Bool? = nil
    var provisionalStocks: Int? = nil

    var hasFailures: Bool {
        twseFailedMonths > 0 || yahooSuccessfulStocks < yahooRequestedStocks
            || (marketFailedMonths ?? 0) > 0 || yahooMarketFailed == true
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

    static func markYahooRecovered(stockID: String, at recoveredAt: Date = twDateTime.now()) {
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
        UserDefaults.standard.set(twDateTime.now(), forKey: diagnosticLastViewedKey)
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
            if let timings = snapshot.timings { lines.append(timings.diagnosticText) }
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
        let cutoff = twDateTime.now().addingTimeInterval(-diagnosticRetention)
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
        let cutoff = twDateTime.now().addingTimeInterval(-diagnosticRetention)
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
            date: twDateTime.now(),
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

/// Taiwan calendar rules and display. A `Date` remains an absolute instant;
/// never add an offset before persisting it. Inject a `() -> Date` clock at
/// orchestration boundaries and pass the captured value to pure helpers.
nonisolated public final class twDateTime {
    static let timeZone = TimeZone(identifier: "Asia/Taipei")!
    static let locale = Locale(identifier: "zh_Hant_TW")
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }()

    /// The only wall-clock source. Taiwan representation belongs to the
    /// formatter/calendar, not to the stored timestamp.
    static func now() -> Date { Date() }

    /// Source timestamps may tolerate clock skew; P10 intentionally does not.
    static let quoteFutureTolerance: TimeInterval = 300

    static func formatter(_ format: String = "yyyy/MM/dd") -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    static func timeAtDate(_ date: Date = now(), hour: Int, minute: Int, second: Int = 0) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = 0
        return calendar.date(from: components) ?? date
    }

    static func time0900(_ date: Date = now(), delayMinutes: Int = 0) -> Date {
        let open = timeAtDate(date, hour: 9, minute: 0)
        return calendar.date(byAdding: .minute, value: delayMinutes, to: open) ?? open
    }

    static func time0905(_ date: Date = now()) -> Date {
        time0900(date, delayMinutes: 5)
    }

    static func time1330(_ date: Date = now(), delayMinutes: Int = 0) -> Date {
        let close = timeAtDate(date, hour: 13, minute: 30)
        return calendar.date(byAdding: .minute, value: delayMinutes, to: close) ?? close
    }

    static func time1535(_ date: Date = now()) -> Date {
        timeAtDate(date, hour: 15, minute: 35)
    }

    static func startOfDay(_ date: Date = now()) -> Date {
        calendar.startOfDay(for: date)
    }

    /// A half-open range includes fractional seconds before the next midnight.
    static func dayRange(containing date: Date) -> Range<Date> {
        let start = startOfDay(date)
        return start..<addDays(1, to: start)
    }

    /// Compatibility endpoint for existing whole-second inclusive storage.
    /// Queries and membership must use `dayRange` instead.
    static func endOfDay(_ date: Date = now()) -> Date {
        timeAtDate(date, hour: 23, minute: 59, second: 59)
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    static func isDateInToday(_ date: Date, asOf now: Date = now()) -> Bool {
        dayRange(containing: now).contains(date)
    }

    static func startOfMonth(_ date: Date = now()) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? startOfDay(date)
    }

    static func monthRange(containing date: Date) -> Range<Date> {
        let start = startOfMonth(date)
        return start..<addMonths(1, to: start)
    }

    /// Compatibility: the start of the month's final calendar day, not an
    /// inclusive timestamp endpoint. Use `monthRange` for date membership.
    static func endOfMonth(_ date: Date = now()) -> Date {
        addDays(-1, to: monthRange(containing: date).upperBound)
    }

    static func addDays(_ value: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: value, to: date) ?? date
    }

    static func addMonths(_ value: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: value, to: date) ?? date
    }

    static func addYears(_ value: Int, to date: Date) -> Date {
        calendar.date(byAdding: .year, value: value, to: date) ?? date
    }

    static func requestStart(for configuredStart: Date) -> Date {
        startOfDay(addYears(-1, to: startOfDay(configuredStart)))
    }

    /// Capture one date for both picker limits, even across midnight.
    static func simulationStartRange(asOf now: Date = now()) -> ClosedRange<Date> {
        let today = startOfDay(now)
        return addYears(-15, to: today)...addYears(-1, to: today)
    }

    static func yesterday(_ date: Date = now()) -> Date {
        startOfDay(addDays(-1, to: date))
    }

    static func back10Days(_ date: Date) -> Date {
        startOfDay(addDays(-10, to: date))
    }

    /// Elapsed calendar days, including weekends; never trading-row count.
    static func calendarDays(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: startOfDay(start), to: startOfDay(end)).day ?? 0
    }

    /// Preserve the established 365-day denominator and one-year floor.
    /// This intentionally differs from calendar-year window arithmetic.
    static func annualizationYears(from start: Date, to end: Date) -> Double {
        max(1.0, end.timeIntervalSince(start) / 86400.0 / 365.0)
    }

    static func monthDay(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    /// Existing formatted input. When the format contains an offset token,
    /// DateFormatter honors that offset and returns the corresponding instant.
    static func dateFromString(_ date: String, format: String = "yyyy/MM/dd") -> Date? {
        formatter(format).date(from: date)
    }

    /// Strict canonical Taiwan input (no embedded timezone), rejecting date
    /// rollover, partial input, suffixes and non-canonical field widths.
    static func strictDateFromString(_ text: String, format: String = "yyyy/MM/dd") -> Date? {
        let parser = formatter(format)
        guard let date = parser.date(from: text), parser.string(from: date) == text else { return nil }
        return date
    }

    static func dateFromROCString(_ text: String) -> Date? {
        guard text.range(of: #"^[0-9]{1,4}/[0-9]{1,2}/[0-9]{1,2}$"#,
                         options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: "/")
        guard let year = Int(parts[0]), (1...8088).contains(year),
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else { return nil }
        return strictDateFromString(String(format: "%04d/%02d/%02d", year + 1911, month, day))
    }

    /// TWSE calendar protocol uses exactly three ROC-year digits plus MMdd.
    static func dateFromROCKey(_ text: String) -> Date? {
        guard text.range(of: #"^[0-9]{7}$"#, options: .regularExpression) != nil else { return nil }
        let year = text.prefix(3)
        let month = text.dropFirst(3).prefix(2)
        let day = text.suffix(2)
        return dateFromROCString("\(year)/\(month)/\(day)")
    }

    static func rocDateKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%03d%02d%02d", year - 1911, month, day)
    }

    private static let internetTimestampPattern = try! NSRegularExpression(
        pattern: #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?(Z|([+-])([0-9]{2}):([0-9]{2}))\z"#
    )

    /// Fixed RFC3339-style input: YYYY-MM-DDTHH:mm:ss, optional 1...9
    /// fractional digits, and mandatory Z or ±HH:mm. Years 0001...9999,
    /// hours 00...23, seconds 00...59 and offsets up to 23:59 are supported;
    /// rollover dates, 24:00, leap-second notation and trailing text are not.
    /// Validate civil fields before applying the source offset exactly once.
    /// Taiwan display is a separate step and never replaces the source zone.
    static func dateFromInternetTimestamp(_ text: String) -> Date? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = internetTimestampPattern.firstMatch(in: text, range: fullRange),
              match.range == fullRange else { return nil }
        func field(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let year = field(1).flatMap(Int.init), (1...9999).contains(year),
              let month = field(2).flatMap(Int.init), (1...12).contains(month),
              let day = field(3).flatMap(Int.init), (1...31).contains(day),
              let hour = field(4).flatMap(Int.init), (0...23).contains(hour),
              let minute = field(5).flatMap(Int.init), (0...59).contains(minute),
              let second = field(6).flatMap(Int.init), (0...59).contains(second) else { return nil }

        var offset = 0
        if field(8) != "Z" {
            guard let offsetHour = field(10).flatMap(Int.init), (0...23).contains(offsetHour),
                  let offsetMinute = field(11).flatMap(Int.init), (0...59).contains(offsetMinute) else { return nil }
            offset = (offsetHour * 3600 + offsetMinute * 60) * (field(9) == "-" ? -1 : 1)
        }

        // UTC is only a neutral basis for validating the source's civil
        // fields, independent of Taiwan DST history or the device timezone.
        var protocolCalendar = calendar
        protocolCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day,
                                   hour: hour, minute: minute, second: second)
        guard let civil = protocolCalendar.date(from: parts) else { return nil }
        let roundTrip = protocolCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: civil)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              roundTrip.hour == hour, roundTrip.minute == minute, roundTrip.second == second else { return nil }
        let fraction = field(7).flatMap { Double("0." + $0) } ?? 0
        return civil.addingTimeInterval(-Double(offset) + fraction)
    }

    static func stringFromDate(_ date: Date = now(), format: String = "yyyy/MM/dd") -> String {
        formatter(format).string(from: date)
    }

    /// Session time only. Holidays and exceptional trading days belong to
    /// TWSETradingCalendar; delay extends both sides by the existing policy.
    static func isInSession(_ date: Date, delayMinutes: Int = 0) -> Bool {
        date >= time0900(date, delayMinutes: -delayMinutes)
            && date < time1330(date, delayMinutes: delayMinutes)
    }

    static func inMarketingTime(_ time: Date = now(), delay: Int = 0,
                                forToday: Bool = false, asOf now: Date = now()) -> Bool {
        isInSession(time, delayMinutes: delay) && (!forToday || isDateInToday(time, asOf: now))
    }

    /// Elapsed-duration freshness, independent of timezone. A future timestamp
    /// cannot extend a cache or retry deadline after the wall clock moves back.
    static func isFresh(_ timestamp: Date, asOf now: Date, maxAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age >= 0 && age < maxAge
    }
}
