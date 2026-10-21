import Foundation
import SwiftData

/// User inputs and the S work they invalidate are one persistence unit. Both
/// UI and legacy entry points use this writer before asking recovery to run.
/// On save failure the unsaved input and its dirty boundary stay paired in
/// memory; callers must report failure and must not dispatch recalculation.
@MainActor
final class SimulationInputWriter {
    struct SettingsChange {
        let stocks: [Stock]
        let startChanged: Bool
    }

    private let context: ModelContext
    private let technical: Technical
    // Narrow persistence seam for isolated failure tests; no work is dispatched here.
    var save: (() throws -> Void)?

    init(context: ModelContext, technical: Technical) {
        self.context = context
        self.technical = technical
    }

    private func persist() throws {
        if let save { try save() } else { try context.save() }
    }

    private func canChange(_ trade: Trade) -> Bool {
        !trade.isDeleted && trade.priceClose.isFinite && trade.priceClose > 0
            && trade.dateTime >= twDateTime.startOfDay(trade.stock.dateRequestStart)
            && !trade.isBeforeSimulationStart
            && !technical.hasPendingDataRuleMigration(in: [trade.stock])
            && ![trade.stock.technicalDirtyFrom, trade.stock.simulationDirtyFrom]
                .compactMap { $0 }.contains {
                    twDateTime.startOfDay($0) <= twDateTime.startOfDay(trade.dateTime)
                }
    }

    @discardableResult
    func toggleInvestment(_ trade: Trade) throws -> Bool {
        guard canChange(trade) else { return false }
        let next: Double
        if trade.simInvestByUser != 0 { next = 0 }
        else if trade.simInvestAdded > 0 { next = -1 }
        else if trade.simInvestAdded == 0 { next = 1 }
        else { return false }
        let trades = try Trade.fetchCalculationWindow(in: context, for: trade.stock)
        trade.simInvestByUser = next
        RecalculationInvalidation.simulation(trade.stock, from: trade.dateTime)
        trade.stock.rebuildUserActionSummary(from: trades)
        try persist()
        return true
    }

    @discardableResult
    func toggleReversal(_ trade: Trade) throws -> Bool {
        guard canChange(trade) else { return false }
        let trades = try Trade.fetchCalculationWindow(in: context, for: trade.stock)
        if trade.simReversed.isEmpty {
            switch trade.simQty.action {
            case "買": trade.simReversed = trade.invested > 0 ? "S+" : "B-"
            case "賣": trade.simReversed = "S-"
            case "餘": trade.simReversed = "S+"
            default: trade.simReversed = "B+"
            }
            trade.simInvestByUser = 0
        } else {
            trade.simReversed = ""
        }
        RecalculationInvalidation.simulation(trade.stock, from: trade.dateTime)
        trade.stock.rebuildUserActionSummary(from: trades)
        try persist()
        return true
    }

    func applySettings(_ stocks: [Stock], start: Date, money: Double,
                       investments: Double) throws -> SettingsChange {
        var changed: [Stock] = []
        var startChanged = false
        for stock in stocks {
            let movesStart = twDateTime.startOfDay(stock.dateStart) != twDateTime.startOfDay(start)
            let changesCapital = stock.simMoneyBase != money || stock.simInvestAuto != investments
            guard movesStart || changesCapital else { continue }
            // Existing date-window handling owns T invalidation and action
            // retention. Capital changes only invalidate S, even in a mixed batch.
            if movesStart { try StockHistory.changeStart(stock, to: start, in: context) }
            stock.simMoneyBase = money
            stock.simInvestAuto = investments
            if changesCapital { RecalculationInvalidation.simulation(stock, from: .distantPast) }
            startChanged = startChanged || movesStart
            changed.append(stock)
        }
        if !changed.isEmpty { try persist() }
        return SettingsChange(stocks: changed, startChanged: startChanged)
    }

    /// Keep explicit rebuild requests durable too: the dispatcher may redirect
    /// an already-dirty stock to recovery instead of executing this action.
    /// TWSE/live refresh requests do not force a rebuild without a change.
    func prepareReload(_ stocks: [Stock], action: Technical.simAction) throws {
        var needsSave = false
        for stock in stocks {
            if stock.simInvestAuto == 0 {
                stock.simInvestAuto = 2
                RecalculationInvalidation.simulation(stock, from: .distantPast)
                needsSave = true
            }
            switch action {
            case .newTrades, .allTrades, .tUpdateAll:
                // These legacy explicit actions request full T/S in technicalUpdate.
                StockHistory.invalidate(stock)
                needsSave = true
            case .simUpdateAll, .simResetAll:
                RecalculationInvalidation.simulation(stock, from: .distantPast)
                needsSave = true
            case .simUpdateFrom(let date):
                RecalculationInvalidation.simulation(stock, from: date)
                needsSave = true
            case .TWSE, .realtime: break
            }
        }
        if needsSave { try persist() }
    }
}
