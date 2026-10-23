import Foundation

/// Price scenarios help place an order during today's session. Yahoo's
/// post-close provisional quote remains a normal T/S input, never a P10 input.
enum IntradayScenarioPolicy {
    static func permits(_ trade: Trade, asOf now: Date = Date()) -> Bool {
        let calendar = twDateTime.calendar
        guard trade.dataSource.lowercased() == "yahoo",
              calendar.isDate(trade.dateTime, inSameDayAs: now), trade.dateTime <= now,
              trade.priceClose.isFinite, trade.priceClose > 0 else { return false }
        func inSession(_ date: Date) -> Bool {
            let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            return (9 * 60..<13 * 60 + 30).contains(minute)
        }
        return inSession(now) && inSession(trade.dateTime)
    }
}
