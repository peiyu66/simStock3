import Foundation

/// A successful, fully parsed monthly response is evidence; the existence of
/// one Trade, an empty response, and a failed request are not evidence.
nonisolated struct TWSEHistoryCoverage: Codable, Equatable {
    var months: [String: Date] = [:]
    /// Raw source statistics only; never part of price/volume indicators or S.
    struct NoPriceDay: Codable, Equatable {
        let date: Date
        let shares: Int64
        let amount: Int64
        let transactions: Int64
    }
    var noPriceDays: [String: [NoPriceDay]]?
    // Compatibility evidence is deliberately separate from download receipts.
    // Optional keys decode the original 3.7.0 payload without a schema change.
    struct LegacyInterval: Codable, Equatable {
        let from: Date
        let through: Date
    }
    var legacyIntervals: [String: LegacyInterval]?
    var legacyAdoptionCompleted: Bool?

    static var newStock: Self { Self(legacyAdoptionCompleted: true) }

    static func key(_ date: Date) -> String {
        twDateTime.stringFromDate(date, format: "yyyyMM")
    }

    mutating func confirm(month: Date, through: Date, noPriceDays: [NoPriceDay]? = nil) {
        let key = Self.key(month)
        months[key] = max(months[key] ?? .distantPast, through)
        if let noPriceDays {
            if !noPriceDays.isEmpty, self.noPriceDays == nil { self.noPriceDays = [:] }
            self.noPriceDays?[key] = noPriceDays.isEmpty ? nil : noPriceDays
        }
    }

    func contains(month: Date, from: Date? = nil, through: Date) -> Bool {
        let key = Self.key(month)
        if (months[key] ?? .distantPast) >= through { return true }
        guard let interval = legacyIntervals?[key] else { return false }
        return interval.from <= (from ?? month) && interval.through >= through
    }

    /// One-time compatibility policy approved for stores lacking receipts.
    /// Exact date equality against saved official market rows is evidence only
    /// within the visible interval. It cannot detect a day missing in both feeds.
    mutating func adoptLegacy(stockDates: Set<Date>, marketDates: Set<Date>,
                              requestStart: Date, through end: Date) {
        guard legacyAdoptionCompleted != true else { return }
        legacyAdoptionCompleted = true
        var month = twDateTime.startOfMonth(requestStart)
        let last = twDateTime.startOfDay(end)
        let lastMarket = marketDates.max() ?? .distantPast
        while month <= last {
            let next = twDateTime.monthRange(containing: month).upperBound
            let from = max(month, twDateTime.startOfDay(requestStart))
            // Persisted receipts use an inclusive second-resolution cutoff.
            // Keep their existing values; the month range itself is half-open.
            let through = min(last, twDateTime.endOfDay(twDateTime.yesterday(next)))
            if !contains(month: month, from: from, through: through) {
                let reference = marketDates.filter { $0 >= from && $0 <= through }
                let prices = stockDates.filter { $0 >= from && $0 <= through }
                if !reference.isEmpty, reference == prices,
                   lastMarket >= min(last, next) {
                    if legacyIntervals == nil { legacyIntervals = [:] }
                    legacyIntervals?[Self.key(month)] = LegacyInterval(from: from, through: through)
                }
            }
            month = next
        }
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
            let next = twDateTime.monthRange(containing: month).upperBound
            let required = min(twDateTime.startOfDay(end), twDateTime.endOfDay(twDateTime.yesterday(next)))
            if !coverage.contains(month: month, from: max(month, twDateTime.startOfDay(dateRequestStart)), through: required) { missing.append(month) }
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

    func confirmHistoryMonth(_ month: Date, through: Date, noPriceDays: [TWSEHistoryCoverage.NoPriceDay]? = nil) throws {
        var coverage = confirmedHistory
        coverage.confirm(month: twDateTime.startOfMonth(month), through: through, noPriceDays: noPriceDays)
        twseHistoryCoverage = try JSONEncoder().encode(coverage)
    }

    func forgetHistoryMonths(containing dates: [Date]) throws {
        guard twseHistoryCoverage != nil, !dates.isEmpty else { return }
        var coverage = confirmedHistory
        for date in dates {
            let key = TWSEHistoryCoverage.key(date)
            coverage.months.removeValue(forKey: key)
            coverage.noPriceDays?.removeValue(forKey: key)
            coverage.legacyIntervals?.removeValue(forKey: key)
        }
        // Deletion must not make this store eligible for legacy adoption again.
        coverage.legacyAdoptionCompleted = true
        twseHistoryCoverage = try JSONEncoder().encode(coverage)
    }
}
