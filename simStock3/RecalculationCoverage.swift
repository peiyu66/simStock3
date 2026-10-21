import Foundation
import SwiftData

/// The dates below are writes, never the history read to seed a rolling context.
/// Stock S reads today's and the preceding stock row's T. Once affected, its
/// accounting, Grade and warnings must replay through the remaining period.
struct RecalculationCoverage: Equatable {
    let technicalDates: [Date]
    let simulationDates: [Date]

    @MainActor
    static func dependentSimulationStart(
        technicalDates: [Date], tradeDates: [Date], simulationStart: Date
    ) -> Date? {
        let writes = Set(technicalDates.map { twDateTime.startOfDay($0) })
        return tradeDates.enumerated().first { index, date in
            guard twDateTime.startOfDay(date) >= twDateTime.startOfDay(simulationStart) else { return false }
            return writes.contains(twDateTime.startOfDay(date))
                || (index > 0 && writes.contains(twDateTime.startOfDay(tradeDates[index - 1])))
        }?.element
    }

    /// Completion can consume only a contiguous prefix of the pending work.
    /// A truncated replay retains its first unprocessed date, including after a
    /// restart. Work earlier than the first completed date is never discarded.
    static func remainingDirty(_ dirty: Date?, completed: [Date], requiredDates: [Date]) -> Date? {
        guard let dirty else { return nil }
        let pending = requiredDates.filter { $0 >= dirty }
        guard !pending.isEmpty else { return dirty }
        let done = Set(completed)
        guard done.contains(pending[0]) else { return dirty }
        return pending.first { !done.contains($0) }
    }
}

extension SimulationRecalculationScope {
    func including(_ date: Date?) -> Self {
        guard let date else { return self }
        switch self {
        case .all: return .all
        case .none: return .from(date)
        case .from(let current): return .from(min(current, date))
        }
    }
}

/// Shared invalidation for both stock and market technical writers. Persistence
/// belongs to the surrounding write transaction, so prices and pending S cannot
/// be committed independently. No comparison of old/new technical values occurs.
@MainActor
enum RecalculationInvalidation {
    static func simulation(_ stock: Stock, from date: Date?) {
        guard let date else { return }
        stock.simulationDirtyFrom = min(stock.simulationDirtyFrom ?? date, date)
        stock.p10Reset()
    }

    static func stockTechnical(_ stock: Stock, writes: [Date], trades: [Trade]) {
        guard let simulationStart = stock.effectiveSimulationStart else { return }
        simulation(stock, from: RecalculationCoverage.dependentSimulationStart(
            technicalDates: writes, tradeDates: trades.map(\.dateTime), simulationStart: simulationStart
        ))
    }

    static func marketTechnical(writes: [Date], in context: ModelContext) throws {
        guard !writes.isEmpty else { return }
        let earliest = writes.min()!
        for stock in try Stock.fetchGrouped(in: context) {
            let trades = try Trade.fetchCalculationWindow(in: context, for: stock)
            guard let simulationStart = stock.effectiveSimulationStart else { continue }
            var from = RecalculationCoverage.dependentSimulationStart(
                technicalDates: writes, tradeDates: trades.map(\.dateTime), simulationStart: simulationStart
            )
            // A live row may borrow a previous official market day which is
            // absent from this stock's own dates (e.g. suspension).
            if let borrowed = trades.first(where: {
                !$0.isBeforeSimulationStart && $0.dateTime >= earliest
                    && $0.simMarketSourceDate.map { source in
                        writes.contains { twDateTime.startOfDay($0) == twDateTime.startOfDay(source) }
                    } == true
            }) {
                from = min(from ?? borrowed.dateTime, borrowed.dateTime)
            }
            simulation(stock, from: from)
        }
    }
}
