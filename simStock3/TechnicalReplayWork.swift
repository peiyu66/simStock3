import Foundation

/// Inclusive trading-day bounds, stable when Yahoo replaces a quote's clock time.
struct TechnicalWriteInterval: Codable, Equatable {
    var first: Date
    var last: Date

    init(_ first: Date, _ last: Date) {
        self.first = twDateTime.startOfDay(first)
        self.last = twDateTime.startOfDay(last)
    }

    func contains(_ date: Date) -> Bool {
        let day = twDateTime.startOfDay(date)
        return first <= day && day <= last
    }
}

/// The minimum durable description of an already planned T request. A single
/// dirty start cannot distinguish a mature-preserving backfill from a correction,
/// or retain a gap between pending backfill work and a later append.
struct TechnicalReplayWork: Codable, Equatable {
    static let formatVersion = 2
    var formatVersion = Self.formatVersion
    var targetTechnicalVersion: Int
    var configuredStart: Date
    var ordinaryIntervals: [TechnicalWriteInterval]
    var pricePathIntervals: [TechnicalWriteInterval]
    var statisticIntervals: [OrdinaryTechnicalStatistic: [TechnicalWriteInterval]]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, targetTechnicalVersion, configuredStart, ordinaryIntervals, pricePathIntervals, statisticIntervals
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        targetTechnicalVersion = try c.decode(Int.self, forKey: .targetTechnicalVersion)
        configuredStart = try c.decode(Date.self, forKey: .configuredStart)
        ordinaryIntervals = try c.decode([TechnicalWriteInterval].self, forKey: .ordinaryIntervals)
        pricePathIntervals = try c.decode([TechnicalWriteInterval].self, forKey: .pricePathIntervals)
        statisticIntervals = try c.decodeIfPresent([OrdinaryTechnicalStatistic: [TechnicalWriteInterval]].self,
                                                  forKey: .statisticIntervals) ?? [:]
    }

    init(version: Int, configuredStart: Date, ordinary: [Date], pricePath: [Date], allDates: [Date],
         statistics: [OrdinaryTechnicalStatistic: [Date]] = [:]) {
        targetTechnicalVersion = version
        self.configuredStart = twDateTime.startOfDay(configuredStart)
        ordinaryIntervals = Self.intervals(selecting: ordinary, from: allDates)
        pricePathIntervals = Self.intervals(selecting: pricePath, from: allDates)
        statisticIntervals = statistics.mapValues { Self.intervals(selecting: $0, from: allDates) }.filter { !$0.value.isEmpty }
    }

    var isEmpty: Bool { ordinaryIntervals.isEmpty && pricePathIntervals.isEmpty && statisticIntervals.isEmpty }

    func ordinaryDates(in dates: [Date]) -> [Date] {
        dates.filter { date in ordinaryIntervals.contains { $0.contains(date) } }
    }

    func pricePathDates(in dates: [Date]) -> [Date] {
        dates.filter { date in pricePathIntervals.contains { $0.contains(date) } }
    }

    func statisticDates(in dates: [Date]) -> [OrdinaryTechnicalStatistic: [Date]] {
        statisticIntervals.mapValues { intervals in dates.filter { date in intervals.contains { $0.contains(date) } } }
    }

    func statisticWrites(in dates: [Date]) -> [Date: Set<OrdinaryTechnicalStatistic>] {
        var result: [Date: Set<OrdinaryTechnicalStatistic>] = [:]
        for (field, targets) in statisticDates(in: dates) {
            for date in targets { result[date, default: []].insert(field) }
        }
        return result
    }

    @MainActor func includingStatisticDependencies(trades: [Trade]) -> Self {
        var result = self
        result.formatVersion = Self.formatVersion
        let dates = trades.map(\.dateTime)
        let expansion = OrdinaryTechnicalStatistic.dependentWrites(ordinary: ordinaryDates(in: dates), trades: trades)
        for (field, targets) in expansion {
            result.statisticIntervals[field] = Self.normalized((result.statisticIntervals[field] ?? [])
                + Self.intervals(selecting: targets, from: dates))
        }
        return result
    }

    func allDates(in dates: [Date]) -> [Date] {
        dates.filter { date in (ordinaryIntervals + pricePathIntervals + statisticIntervals.values.flatMap { $0 }).contains { $0.contains(date) } }
    }

    mutating func merge(_ other: Self) {
        precondition(targetTechnicalVersion == other.targetTechnicalVersion && configuredStart == other.configuredStart)
        ordinaryIntervals = Self.normalized(ordinaryIntervals + other.ordinaryIntervals)
        pricePathIntervals = Self.normalized(pricePathIntervals + other.pricePathIntervals)
        for (field, intervals) in other.statisticIntervals {
            statisticIntervals[field] = Self.normalized((statisticIntervals[field] ?? []) + intervals)
        }
        formatVersion = Self.formatVersion
    }

    /// Completion only removes actual writes of the appropriate T component.
    /// An S-only pass cannot accidentally consume either list.
    func remaining(ordinaryDone: [Date], pricePathDone: [Date], allDates: [Date],
                   statisticsDone: [Date: Set<OrdinaryTechnicalStatistic>] = [:]) -> Self {
        let ordinaryDone = Set(ordinaryDone.map { twDateTime.startOfDay($0) })
        let pathDone = Set(pricePathDone.map { twDateTime.startOfDay($0) })
        var completed: [OrdinaryTechnicalStatistic: Set<Date>] = [:]
        for (date, fields) in statisticsDone {
            for field in fields { completed[field, default: []].insert(twDateTime.startOfDay(date)) }
        }
        var remainingStatistics: [OrdinaryTechnicalStatistic: [Date]] = [:]
        for (field, targets) in statisticDates(in: allDates) {
            remainingStatistics[field] = targets.filter {
                let day = twDateTime.startOfDay($0)
                return !ordinaryDone.contains(day) && !(completed[field]?.contains(day) ?? false)
            }
        }
        return Self(version: targetTechnicalVersion, configuredStart: configuredStart,
            ordinary: ordinaryDates(in: allDates).filter { !ordinaryDone.contains(twDateTime.startOfDay($0)) },
            pricePath: pricePathDates(in: allDates).filter { !pathDone.contains(twDateTime.startOfDay($0)) },
            allDates: allDates, statistics: remainingStatistics)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data?, version: Int, configuredStart: Date) -> Self? {
        guard let data, let work = try? JSONDecoder().decode(Self.self, from: data),
              (work.formatVersion == 1 || work.formatVersion == formatVersion), work.targetTechnicalVersion == version,
              work.configuredStart == twDateTime.startOfDay(configuredStart),
              (work.ordinaryIntervals + work.pricePathIntervals + work.statisticIntervals.values.flatMap { $0 }).allSatisfy({
                  $0.first.timeIntervalSinceReferenceDate.isFinite && $0.last.timeIntervalSinceReferenceDate.isFinite
                      && $0.first <= $0.last
              }) else { return nil }
        return work
    }

    /// Changing to a later setting preserves only still-visible pending work.
    /// Moving earlier is a full rebuild and must not reuse this description.
    func restricted(to configuredStart: Date, requestStart: Date, allDates: [Date]) -> Self {
        let visible = allDates.filter { $0 >= twDateTime.startOfDay(requestStart) }
        return Self(version: targetTechnicalVersion, configuredStart: configuredStart,
            ordinary: ordinaryDates(in: visible), pricePath: pricePathDates(in: visible), allDates: visible,
            statistics: statisticDates(in: visible))
    }

    private static func intervals(selecting selected: [Date], from dates: [Date]) -> [TechnicalWriteInterval] {
        let selected = Set(selected.map { twDateTime.startOfDay($0) })
        var result: [TechnicalWriteInterval] = []
        var open: TechnicalWriteInterval?
        for day in Set(dates.map { twDateTime.startOfDay($0) }).sorted() {
            if selected.contains(day) {
                if open == nil { open = TechnicalWriteInterval(day, day) } else { open!.last = day }
            } else if let interval = open {
                result.append(interval)
                open = nil
            }
        }
        if let open { result.append(open) }
        return result
    }

    private static func normalized(_ intervals: [TechnicalWriteInterval]) -> [TechnicalWriteInterval] {
        var result: [TechnicalWriteInterval] = []
        for interval in intervals.sorted(by: { $0.first < $1.first }) {
            if let last = result.last, interval.first <= last.last {
                result[result.count - 1].last = max(last.last, interval.last)
            } else {
                result.append(interval)
            }
        }
        return result
    }
}
