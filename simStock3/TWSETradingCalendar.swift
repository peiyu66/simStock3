//
//  TWSETradingCalendar.swift
//  simStock3
//
//  Keeps the official TWSE market calendar available when the app is offline.
//

import Foundation

nonisolated enum TWSEMarketDayStatus: Equatable, Sendable {
    case tradingDay
    case closed
    case unknown
}

nonisolated struct TWSEHolidayEntry: Codable, Equatable, Sendable {
    let name: String
    let date: String
    let weekday: String
    let description: String

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case date = "Date"
        case weekday = "Weekday"
        case description = "Description"
    }

    var isExplicitTradingDay: Bool {
        guard !name.contains("無交易") else { return false }
        return name.contains("開始交易")
            || name.contains("最後交易")
            || name.contains("補行交易")
    }
}

nonisolated struct TWSETradingCalendarSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let sourceURL: String
    let fetchedAt: Date
    let year: Int
    let entries: [TWSEHolidayEntry]
}

nonisolated struct TWSEMarketDayDecision: Equatable, Sendable {
    let status: TWSEMarketDayStatus
    let refreshed: Bool
    let refreshError: String?
}

actor TWSETradingCalendar {
    static let shared = TWSETradingCalendar()

    static let sourceURL = URL(string: "https://openapi.twse.com.tw/v1/holidaySchedule/holidaySchedule")!
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    static let retryInterval: TimeInterval = 60 * 60

    private let fileURL: URL
    private let session: URLSession
    private var snapshot: TWSETradingCalendarSnapshot?
    private var lastRefreshAttempt: Date?

    init(fileURL: URL? = nil, session: URLSession = .shared) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL
        self.session = session
        self.snapshot = Self.loadSnapshot(from: resolvedURL)
    }

    func decision(for date: Date = Date()) async -> TWSEMarketDayDecision {
        let now = Date()
        var refreshed = false
        var refreshError: String?

        if shouldRefresh(for: date, now: now) {
            lastRefreshAttempt = now
            do {
                try await refresh(expectedYear: Self.gregorianYear(of: date))
                refreshed = true
            } catch {
                refreshError = error.localizedDescription
            }
        }

        return TWSEMarketDayDecision(
            status: Self.status(for: date, snapshot: snapshot),
            refreshed: refreshed,
            refreshError: refreshError
        )
    }

    func cachedSnapshot() -> TWSETradingCalendarSnapshot? {
        snapshot
    }

    func latestCompletedTradingDay(asOf date: Date = Date()) -> Date? {
        Self.latestCompletedTradingDay(asOf: date, snapshot: snapshot)
    }

    static func status(
        for date: Date,
        snapshot: TWSETradingCalendarSnapshot?,
        calendar: Calendar = taipeiCalendar
    ) -> TWSEMarketDayStatus {
        let key = dateKey(for: date, calendar: calendar)
        let weekday = calendar.component(.weekday, from: date)

        guard let snapshot,
              snapshot.version == TWSETradingCalendarSnapshot.currentVersion,
              snapshot.year == calendar.component(.year, from: date) else {
            return weekday == 1 || weekday == 7 ? .closed : .unknown
        }

        if snapshot.entries.contains(where: { $0.date == key && $0.isExplicitTradingDay }) {
            return .tradingDay
        }
        if snapshot.entries.contains(where: { $0.date == key && !$0.isExplicitTradingDay }) {
            return .closed
        }
        return weekday == 1 || weekday == 7 ? .closed : .tradingDay
    }

    static func rocDateKey(for date: Date, calendar: Calendar = taipeiCalendar) -> String {
        dateKey(for: date, calendar: calendar)
    }

    /// Returns the latest trading day whose official daily price should be
    /// available. During a trading session this is the previous trading day;
    /// after the official daily-data publication time it is today. An incomplete calendar returns
    /// nil so callers can conservatively perform the normal network check.
    static func latestCompletedTradingDay(
        asOf date: Date,
        snapshot: TWSETradingCalendarSnapshot?,
        publicationHour: Int = 15,
        publicationMinute: Int = 35,
        calendar: Calendar = taipeiCalendar
    ) -> Date? {
        let today = calendar.startOfDay(for: date)
        let todayStatus = status(for: today, snapshot: snapshot, calendar: calendar)
        guard todayStatus != .unknown else { return nil }

        let publicationTime = calendar.date(
            bySettingHour: publicationHour,
            minute: publicationMinute,
            second: 0,
            of: today
        ) ?? today

        var candidate: Date
        if todayStatus == .tradingDay, date >= publicationTime {
            candidate = today
        } else {
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: today) else {
                return nil
            }
            candidate = previousDay
        }

        for _ in 0..<31 {
            switch status(for: candidate, snapshot: snapshot, calendar: calendar) {
            case .tradingDay:
                return calendar.startOfDay(for: candidate)
            case .closed:
                guard let previousDay = calendar.date(byAdding: .day, value: -1, to: candidate) else {
                    return nil
                }
                candidate = previousDay
            case .unknown:
                return nil
            }
        }
        return nil
    }

    private func shouldRefresh(for date: Date, now: Date) -> Bool {
        if let lastRefreshAttempt,
           now.timeIntervalSince(lastRefreshAttempt) < Self.retryInterval {
            return false
        }
        guard let snapshot else { return true }
        guard snapshot.year == Self.gregorianYear(of: date) else { return true }
        return now.timeIntervalSince(snapshot.fetchedAt) >= Self.refreshInterval
    }

    private func refresh(expectedYear: Int) async throws {
        var request = URLRequest(url: Self.sourceURL, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw CalendarError.invalidResponse
        }

        let entries = try JSONDecoder().decode([TWSEHolidayEntry].self, from: data)
        guard !entries.isEmpty else { throw CalendarError.emptySchedule }

        let years = Set(entries.compactMap { Self.gregorianYear(fromROCDateKey: $0.date) })
        guard years == Set([expectedYear]) else {
            throw CalendarError.unexpectedYear(expected: expectedYear, received: years.sorted())
        }

        let newSnapshot = TWSETradingCalendarSnapshot(
            version: TWSETradingCalendarSnapshot.currentVersion,
            sourceURL: Self.sourceURL.absoluteString,
            fetchedAt: Date(),
            year: expectedYear,
            entries: entries
        )
        try Self.save(newSnapshot, to: fileURL)
        snapshot = newSnapshot
    }

    private static let taipeiCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()

    private static func gregorianYear(of date: Date) -> Int {
        taipeiCalendar.component(.year, from: date)
    }

    private static func dateKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return "" }
        return String(format: "%03d%02d%02d", year - 1911, month, day)
    }

    private static func gregorianYear(fromROCDateKey key: String) -> Int? {
        guard key.count == 7,
              let rocYear = Int(key.prefix(3)) else { return nil }
        return rocYear + 1911
    }

    private static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let directory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return directory.appendingPathComponent("TWSETradingCalendar.json")
    }

    private static func loadSnapshot(from url: URL) -> TWSETradingCalendarSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(TWSETradingCalendarSnapshot.self, from: data),
              snapshot.version == TWSETradingCalendarSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    private static func save(_ snapshot: TWSETradingCalendarSnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    private enum CalendarError: LocalizedError {
        case invalidResponse
        case emptySchedule
        case unexpectedYear(expected: Int, received: [Int])

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "TWSE 休市日曆回應無效"
            case .emptySchedule:
                return "TWSE 休市日曆沒有資料"
            case let .unexpectedYear(expected, received):
                return "TWSE 休市日曆年度不符，預期 \(expected)，收到 \(received)"
            }
        }
    }
}
