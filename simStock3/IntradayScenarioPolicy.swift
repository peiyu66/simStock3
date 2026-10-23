import Foundation

/// Price scenarios help place an order during today's session. Yahoo's
/// post-close provisional quote remains a normal T/S input, never a P10 input.
enum IntradayScenarioPolicy {
    static func permits(_ trade: Trade, asOf now: Date = twDateTime.now()) -> Bool {
        guard trade.dataSource.lowercased() == "yahoo",
              twDateTime.isSameDay(trade.dateTime, now), trade.dateTime <= now,
              trade.priceClose.isFinite, trade.priceClose > 0 else { return false }
        return twDateTime.isInSession(now) && twDateTime.isInSession(trade.dateTime)
    }
}
