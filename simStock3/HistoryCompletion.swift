import Foundation

/// A successful, fully parsed monthly response is evidence; the existence of
/// one Trade, an empty response, and a failed request are not evidence.
nonisolated struct TWSEHistoryCoverage: Codable, Equatable {
    var months: [String: Date] = [:]

    static func key(_ date: Date) -> String {
        twDateTime.stringFromDate(date, format: "yyyyMM")
    }

    mutating func confirm(month: Date, through: Date) {
        let key = Self.key(month)
        months[key] = max(months[key] ?? .distantPast, through)
    }

    func contains(month: Date, through: Date) -> Bool {
        (months[Self.key(month)] ?? .distantPast) >= through
    }
}

/// This records a successful computation, not a user setting or a new
/// simulation start. The start is still derived from the visible raw prices.
nonisolated struct TechnicalRollingOrigin: Codable, Equatable {
    let requestStart: Date
    let firstPrice: Date
    let version: Int
}

extension Stock {
    var confirmedHistory: TWSEHistoryCoverage {
        twseHistoryCoverage.flatMap { try? JSONDecoder().decode(TWSEHistoryCoverage.self, from: $0) }
            ?? TWSEHistoryCoverage()
    }

    var savedRollingOrigin: TechnicalRollingOrigin? {
        technicalRollingOrigin.flatMap { try? JSONDecoder().decode(TechnicalRollingOrigin.self, from: $0) }
    }

    func rollingOrigin(for trades: [Trade], version: Int) -> TechnicalRollingOrigin? {
        guard let first = trades.first else { return nil }
        return TechnicalRollingOrigin(requestStart: twDateTime.startOfDay(dateRequestStart),
            firstPrice: twDateTime.startOfDay(first.dateTime), version: version)
    }

    /// Confirmed catalog listing dates can exclude whole pre-listing months.
    /// The listing month itself must still have a valid monthly response.
    func unconfirmedHistoryMonths(through end: Date) -> [Date] {
        let calendar = twDateTime.calendar
        let lastMonth = twDateTime.startOfMonth(end)
        var month = requiredTWSEHistoryStartMonth
        if let listing = twseListingDate,
           // A relisting date must not hide demonstrably older price history.
           !trades.contains(where: { $0.hasUsableOfficialPrice && $0.dateTime < listing }) {
            month = max(month, twDateTime.startOfMonth(listing))
        }
        let coverage = confirmedHistory
        var missing: [Date] = []
        while month <= lastMonth {
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            let required = min(twDateTime.startOfDay(end), next.addingTimeInterval(-1))
            if !coverage.contains(month: month, through: required) { missing.append(month) }
            month = next
        }
        return missing
    }

    func needsCompletedHistoryReplay(trades: [Trade], version: Int) -> Bool {
        guard let origin = rollingOrigin(for: trades, version: version),
              savedRollingOrigin?.firstPrice != origin.firstPrice
                || savedRollingOrigin?.version != origin.version else { return false }
        // A new visible window cannot inherit a former window's recursive
        // state, even when all its raw rows were already retained on disk.
        if let old = savedRollingOrigin, old.requestStart != origin.requestStart { return true }
        // Removing the former first raw row is not a backfill waiting for a
        // completion event. The surviving window needs a new rolling origin.
        if let old = savedRollingOrigin, origin.firstPrice > old.firstPrice { return true }
        guard let lastOfficial = trades.last(where: \.hasUsableOfficialPrice) else { return false }
        return unconfirmedHistoryMonths(through: lastOfficial.dateTime).isEmpty
    }

    func confirmHistoryMonth(_ month: Date, through: Date) throws {
        var coverage = confirmedHistory
        coverage.confirm(month: twDateTime.startOfMonth(month), through: through)
        twseHistoryCoverage = try JSONEncoder().encode(coverage)
    }

    func forgetHistoryMonths(containing dates: [Date]) throws {
        guard twseHistoryCoverage != nil, !dates.isEmpty else { return }
        var coverage = confirmedHistory
        for date in dates { coverage.months.removeValue(forKey: TWSEHistoryCoverage.key(date)) }
        twseHistoryCoverage = coverage.months.isEmpty ? nil : try JSONEncoder().encode(coverage)
    }
}
