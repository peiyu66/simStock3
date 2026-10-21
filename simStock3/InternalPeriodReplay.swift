#if DEBUG
import Foundation
import SwiftData

/// A research period uses the same window transition and pending T work as
/// the app. Completion here is scoped to the requested period, never the store.
@MainActor
enum InternalPeriodReplay {
    enum Status: String, Codable { case targetPeriodValid = "target-period-valid", noSimulationDates = "no-simulation-dates" }
    struct Result {
        let trace: RecalculationTrace
        let status: Status
        let simulationStart: Date?
        let targetTrades: [Trade]
        var finalTrade: Trade? { status == .targetPeriodValid ? targetTrades.last : nil }
    }
    enum ReplayError: LocalizedError {
        case incomplete(String)
        var errorDescription: String? {
            switch self { case .incomplete(let detail): return "研究期間未完成，拒絕計分：\(detail)" }
        }
    }

    static func replay(stock: Stock, start: Date, end: Date, money: Double, investments: Double,
                       technical: Technical, in context: ModelContext) throws -> Result {
        try StockHistory.changeStart(stock, to: start, in: context)
        stock.simMoneyBase = money
        stock.simInvestAuto = investments
        // Research uses the prescribed initial capital and no manual actions.
        // Input and invalidation are saved by recalculate before any derived writes.
        RecalculationInvalidation.simulation(stock, from: .distantPast)
        let requiresTechnicalMigration = stock.technicalStateVersion < Int(Technical.technicalRuleVersion.dropFirst())!
        let technicalScope: TechnicalRecalculationScope = requiresTechnicalMigration || stock.technicalDirtyFrom == .distantPast
            ? .all : stock.technicalDirtyFrom.map { .from($0) } ?? .none
        let trace = try technical.recalculate(stock: stock, plan: .init(
            technical: technicalScope, simulation: .all, resetPolicy: .clearUserActions,
            resetDerivedSimulationState: true, simulationEnd: end, resumePendingTechnicalWork: true))
        let window = try Trade.fetchCalculationWindow(in: context, for: stock)
        let target = window.filter { !$0.isBeforeSimulationStart && $0.dateTime <= end }
        let targetTechnical = window.filter { $0.dateTime <= end }
        let detail = "\(stock.sId) \(twDateTime.stringFromDate(start))–\(twDateTime.stringFromDate(end))"
        guard trace.simulationDependencyIssue == nil,
              trace.blockedSimulationDate == nil,
              trace.simulationDates == target.map(\.dateTime) else {
            throw ReplayError.incomplete(detail + "：S 實際寫入日期未涵蓋目標或依賴不足")
        }
        if let last = targetTechnical.last,
           stock.technicalDirtyFrom.map({ $0 <= last.dateTime }) == true {
            throw ReplayError.incomplete(detail + "：目標期間仍有 T 待辦")
        }
        if let last = target.last,
           stock.simulationDirtyFrom.map({ $0 <= last.dateTime }) == true {
            throw ReplayError.incomplete(detail + "：目標期間仍有 S 待辦")
        }
        // recalculate has no derived work to save when the raw window is empty.
        // The period's settings and retained pending state must still persist.
        try context.save()
        // A dirty boundary after end is legitimate. Do not erase it or promote
        // the whole-stock version just to make a period report look complete.
        return Result(trace: trace, status: target.isEmpty ? .noSimulationDates : .targetPeriodValid,
                      simulationStart: stock.effectiveSimulationStart, targetTrades: target)
    }
}
#endif
