import Foundation
import SwiftData

extension Stock {
    /// A persistent full-rebuild boundary, using the existing dirty fields.
    /// Each flagged stage must restart; simulation alone can be invalidated
    /// while its technical history remains valid.
    var requiresHistoryRebuild: Bool {
        technicalDirtyFrom == .distantPast || simulationDirtyFrom == .distantPast
    }
}

@MainActor
enum StockHistory {
    static func invalidate(_ stock: Stock, technical: Bool = true) {
        // A simulation-only change must not discard a valid technical history,
        // nor erase technical work that was already pending.
        if technical { stock.technicalDirtyFrom = .distantPast }
        stock.simulationDirtyFrom = .distantPast
        stock.p10Action = nil
        stock.p10Date = nil
        stock.p10Rule = nil
        stock.p10L = ""
        stock.p10H = ""
    }

    /// Call before changing dateStart. Actions in the intersection of the old
    /// and new simulation periods survive and are revalidated by the replay.
    static func changeStart(_ stock: Stock, to start: Date, in context: ModelContext) throws {
        guard twDateTime.startOfDay(stock.dateStart) != twDateTime.startOfDay(start) else { return }
        let movesEarlier = twDateTime.startOfDay(start) < twDateTime.startOfDay(stock.dateStart)
        let retainedStart = max(twDateTime.startOfDay(stock.dateStart), twDateTime.startOfDay(start))
        let trades = try Trade.fetch(in: context, for: stock, ascending: true)
        stock.rebuildUserActionSummary(from: trades)
        for trade in trades where trade.date < retainedStart {
            trade.setDefaultValues()
            trade.simRule = "_"
        }
        stock.dateStart = start
        stock.dateFirst = min(stock.dateFirst, stock.dateRequestStart)
        stock.rebuildUserActionSummary(from: trades)
        invalidate(stock, technical: movesEarlier)
    }

    /// Leaving all groups ends the old simulation. A direct group-to-group
    /// move keeps the current simulation, settings and user actions.
    static func changeGroup(_ stock: Stock, to group: String, start: Date,
                            money: Double, investments: Double, in context: ModelContext) throws {
        guard stock.group != group else { return }
        if stock.group.isEmpty || group.isEmpty {
            let trades = try Trade.fetch(in: context, for: stock, ascending: true)
            stock.rebuildUserActionSummary(from: trades)
            for trade in trades {
                trade.setDefaultValues()
                trade.simRule = "_"
            }
            stock.rebuildUserActionSummary(from: trades)
            stock.simInvestExceed = 0
            stock.simMoneyLacked = false
            if !group.isEmpty {
                // Always apply current defaults, even when retained prices
                // already cover an earlier start date.
                stock.dateStart = start
                stock.dateFirst = min(stock.dateFirst, stock.dateRequestStart)
                stock.simMoneyBase = money
                stock.simInvestAuto = investments
            }
            invalidate(stock)
        }
        stock.group = group
    }

    static func prepareRebuild(_ stock: Stock, trades: [Trade]) {
        stock.rebuildUserActionSummary(from: trades)
        for trade in trades {
            let reversal = trade.simReversed
            let investment = trade.simInvestByUser
            trade.resetHistoricalTechnicalValues()
            trade.setDefaultValues()
            trade.simUpdated = false
            if !trade.isBeforeSimulationStart {
                trade.simReversed = reversal
                trade.simInvestByUser = investment
            }
        }
        stock.rebuildUserActionSummary(from: trades)
    }

    struct Candidate: Identifiable, Equatable {
        let id: String
        let name: String
        let isUngrouped: Bool
        let first: Date
        let last: Date
        let count: Int
        let userActions: Int
        let cutoff: Date?
    }

    static func candidates(in context: ModelContext) throws -> [Candidate] {
        try Stock.fetch(in: context).compactMap { stock in
            // Keep the entire first download month, so the monthly downloader
            // will not immediately restore a partially deleted month.
            let cutoff = stock.group.isEmpty ? nil : stock.requiredTWSEHistoryStartMonth
            let trades = try Trade.fetch(in: context, for: stock, end: cutoff, ascending: true)
                .filter { trade in cutoff.map { trade.dateTime < $0 } ?? true }
            guard let first = trades.first, let last = trades.last else { return nil }
            return Candidate(id: stock.sId, name: stock.sName, isUngrouped: stock.group.isEmpty,
                             first: first.date, last: last.date, count: trades.count,
                             userActions: trades.reduce(0) {
                                 $0 + ($1.simReversed.isEmpty ? 0 : 1) + ($1.simInvestByUser == 0 ? 0 : 1)
                             }, cutoff: cutoff)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    enum CleanupError: LocalizedError {
        case selectionChanged
        var errorDescription: String? { "資料或模擬範圍已改變，請重新檢查清理清單。" }
    }

    struct CleanupResult {
        var stocks = 0
        var rows = 0
        var userActions = 0
        var rebuildStocks: [Stock] = []
    }

    static func clean(_ selected: [Candidate], in context: ModelContext,
                      onProgress: (String) async -> Void = { _ in }) async throws -> CleanupResult {
        guard !selected.isEmpty else { return CleanupResult() }
        await onProgress("正在檢查歷史資料清理範圍…")
        let current = Dictionary(uniqueKeysWithValues: try candidates(in: context).map { ($0.id, $0) })
        guard Set(selected.map(\.id)).count == selected.count,
              selected.allSatisfy({ current[$0.id] == $0 }) else { throw CleanupError.selectionChanged }
        let stocks = Dictionary(uniqueKeysWithValues: try Stock.fetch(in: context).map { ($0.sId, $0) })
        var result = CleanupResult()
        let autosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosaveEnabled }
        do {
            for (index, candidate) in selected.enumerated() {
                await onProgress(OperationProgress.message(position: index + 1, total: selected.count,
                    "\(candidate.id) \(candidate.name) 正在清理 \(candidate.count) 筆歷史資料"))
                guard let stock = stocks[candidate.id] else { throw CleanupError.selectionChanged }
                let trades = try Trade.fetch(in: context, for: stock, ascending: true)
                let removed = trades.filter { trade in candidate.cutoff.map { trade.dateTime < $0 } ?? true }
                // Use the exact same half-open boundary as the preview.
                for trade in removed { context.delete(trade) }
                let retained = trades.filter { trade in candidate.cutoff.map { trade.dateTime >= $0 } ?? false }
                stock.rebuildUserActionSummary(from: retained)
                stock.dateFirst = retained.first?.date ?? stock.dateRequestStart
                invalidate(stock)
                result.stocks += 1
                result.rows += removed.count
                result.userActions += candidate.userActions
                if !stock.group.isEmpty { result.rebuildStocks.append(stock) }
            }
            await onProgress("正在儲存歷史資料清理結果…")
            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }
}

extension Trade {
    /// Complete reset for discarded historical checkpoints only. Keep these
    /// defaults aligned with Trade.init when adding persisted technical fields.
    func resetHistoricalTechnicalValues() {
        self.tHighDiff = 0
        self.tHighDiff125 = 0
        self.tHighDiff250 = 0
        self.tHighDiffZ125 = 0
        self.tHighDiffZ250 = 0
        self.tHighMax9 = 0

        self.tLowDiff = 0
        self.tLowDiff125 = 0
        self.tLowDiff250 = 0
        self.tLowDiffZ125 = 0
        self.tLowDiffZ250 = 0
        self.tLowMin9 = 0

        self.tMa20 = 0
        self.tMa20Days = 0
        self.tMa20Diff = 0
        self.tMa20DiffMax9 = 0
        self.tMa20DiffMin9 = 0
        self.tMa20DiffZ125 = 0
        self.tMa20DiffZ250 = 0

        self.tMa60 = 0
        self.tMa60Days = 0
        self.tMa60Diff = 0
        self.tMa60DiffMax9 = 0
        self.tMa60DiffMin9 = 0
        self.tMa60DiffZ125 = 0
        self.tMa60DiffZ250 = 0

        self.tZ125 = 0
        self.tZ250 = 0

        self.tKdK = 0
        self.tKdKMax9 = 0
        self.tKdKMin9 = 0
        self.tKdKZ125 = 0
        self.tKdKZ250 = 0

        self.tKdD = 0
        self.tKdDZ125 = 0
        self.tKdDZ250 = 0

        self.tKdJ = 0
        self.tKdJZ125 = 0
        self.tKdJZ250 = 0

        self.tOsc = 0
        self.tOscEma12 = 0
        self.tOscEma26 = 0
        self.tOscMacd9 = 0
        self.tOscMax9 = 0
        self.tOscMin9 = 0
        self.tOscZ125 = 0
        self.tOscZ250 = 0

        self.vMa20 = 0
        self.vMa20Days = 0
        self.vMa20Diff = 0
        self.vMa20DiffMax9 = 0
        self.vMa20DiffMin9 = 0
        self.vMa20DiffZ125 = 0
        self.vMa20DiffZ250 = 0

        self.vMa60 = 0
        self.vMa60Days = 0
        self.vMa60Diff = 0
        self.vMa60DiffMax9 = 0
        self.vMa60DiffMin9 = 0
        self.vMa60DiffZ125 = 0
        self.vMa60DiffZ250 = 0

        self.vMax9 = 0
        self.vMin9 = 0
        self.vZ125 = 0
        self.vZ250 = 0

        self.tUpdated = false
        tPricePathPhaseRaw = 0
        tPricePathBarrier = nil
        tPricePathAnchorClose = nil
        tPricePathExtremeClose = nil
        tPricePathDaysSinceExtreme = 0
    }
}
