import Foundation

/// An observation-based pause, not an authoritative trading calendar entry.
/// It never certifies TWSE history or changes the simulation's date range.
nonisolated struct YahooTradingDayFallback: Codable, Equatable, Sendable {
    let day: Date

    func applies(to now: Date) -> Bool {
        TWSETradingCalendar.taipeiCalendar.startOfDay(for: now) == day
    }

    static func evaluate(asOf now: Date, expectedStockCount: Int,
                         stockQuoteDates: [Date], marketQuoteDate: Date?,
                         previousTradingDay: Date?, interrupted: Bool) -> Self? {
        let calendar = TWSETradingCalendar.taipeiCalendar
        let day = calendar.startOfDay(for: now)
        let grace = calendar.date(bySettingHour: 9, minute: 5, second: 0, of: day)!
        guard !interrupted, now > grace, expectedStockCount > 0,
              stockQuoteDates.count == expectedStockCount,
              let marketQuoteDate, let previousTradingDay,
              calendar.startOfDay(for: marketQuoteDate) == calendar.startOfDay(for: previousTradingDay),
              marketQuoteDate < day,
              stockQuoteDates.allSatisfy({ $0 < day }) else { return nil }
        return Self(day: day)
    }
}
