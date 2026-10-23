import Foundation

/// An observation-based pause, not an authoritative trading calendar entry.
/// It never certifies TWSE history or changes the simulation's date range.
nonisolated struct YahooTradingDayFallback: Codable, Equatable, Sendable {
    let day: Date

    func applies(to now: Date) -> Bool {
        twDateTime.startOfDay(now) == day
    }

    static func evaluate(asOf now: Date, expectedStockCount: Int,
                         stockQuoteDates: [Date], marketQuoteDate: Date?,
                         previousTradingDay: Date?, interrupted: Bool) -> Self? {
        let day = twDateTime.startOfDay(now)
        let grace = twDateTime.time0905(day)
        guard !interrupted, now > grace, expectedStockCount > 0,
              stockQuoteDates.count == expectedStockCount,
              let marketQuoteDate, let previousTradingDay,
              twDateTime.isSameDay(marketQuoteDate, previousTradingDay),
              marketQuoteDate < day,
              stockQuoteDates.allSatisfy({ $0 < day }) else { return nil }
        return Self(day: day)
    }
}
