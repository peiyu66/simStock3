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
    static let formatVersion = 1
    var formatVersion = Self.formatVersion
    var targetTechnicalVersion: Int
    var configuredStart: Date
    var ordinaryIntervals: [TechnicalWriteInterval]
    var pricePathIntervals: [TechnicalWriteInterval]

    init(version: Int, configuredStart: Date, ordinary: [Date], pricePath: [Date], allDates: [Date]) {
        targetTechnicalVersion = version
        self.configuredStart = twDateTime.startOfDay(configuredStart)
        ordinaryIntervals = Self.intervals(selecting: ordinary, from: allDates)
        pricePathIntervals = Self.intervals(selecting: pricePath, from: allDates)
    }

    var isEmpty: Bool { ordinaryIntervals.isEmpty && pricePathIntervals.isEmpty }

    func ordinaryDates(in dates: [Date]) -> [Date] {
        dates.filter { date in ordinaryIntervals.contains { $0.contains(date) } }
    }

    func pricePathDates(in dates: [Date]) -> [Date] {
        dates.filter { date in pricePathIntervals.contains { $0.contains(date) } }
    }

    func allDates(in dates: [Date]) -> [Date] {
        dates.filter { date in (ordinaryIntervals + pricePathIntervals).contains { $0.contains(date) } }
    }

    mutating func merge(_ other: Self) {
        precondition(targetTechnicalVersion == other.targetTechnicalVersion && configuredStart == other.configuredStart)
        ordinaryIntervals = Self.normalized(ordinaryIntervals + other.ordinaryIntervals)
        pricePathIntervals = Self.normalized(pricePathIntervals + other.pricePathIntervals)
    }

    /// Completion only removes actual writes of the appropriate T component.
    /// An S-only pass cannot accidentally consume either list.
    func remaining(ordinaryDone: [Date], pricePathDone: [Date], allDates: [Date]) -> Self {
        let ordinaryDone = Set(ordinaryDone.map { twDateTime.startOfDay($0) })
        let pathDone = Set(pricePathDone.map { twDateTime.startOfDay($0) })
        return Self(version: targetTechnicalVersion, configuredStart: configuredStart,
            ordinary: ordinaryDates(in: allDates).filter { !ordinaryDone.contains(twDateTime.startOfDay($0)) },
            pricePath: pricePathDates(in: allDates).filter { !pathDone.contains(twDateTime.startOfDay($0)) },
            allDates: allDates)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data?, version: Int, configuredStart: Date) -> Self? {
        guard let data, let work = try? JSONDecoder().decode(Self.self, from: data),
              work.formatVersion == formatVersion, work.targetTechnicalVersion == version,
              work.configuredStart == twDateTime.startOfDay(configuredStart),
              (work.ordinaryIntervals + work.pricePathIntervals).allSatisfy({
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
            ordinary: ordinaryDates(in: visible), pricePath: pricePathDates(in: visible), allDates: visible)
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
