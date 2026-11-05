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
    var now: () -> Date = Date.init

    init(context: ModelContext, technical: Technical) {
        self.context = context
        self.technical = technical
    }

    private func persist() throws {
        if let save { try save() } else { try context.save() }
    }

    private func canChange(_ trade: Trade) -> Bool {
        !trade.isDeleted && twDateTime.startOfDay(trade.dateTime) <= twDateTime.startOfDay(now())
            && trade.priceClose.isFinite && trade.priceClose > 0
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
        try replaceManualInputs(trade, investment: next, reversal: "")
        return true
    }

    @discardableResult
    func toggleReversal(_ trade: Trade) throws -> Bool {
        guard canChange(trade) else { return false }
        // Resolve the user's requested toggle against the old result before
        // clearing any input, including the selected row's previous intent.
        let next: String
        if !trade.simReversed.isEmpty { next = "" }
        else {
            switch trade.simQty.action {
            case "買": next = trade.invested > 0 ? "S+" : "B-"
            case "賣": next = "S-"
            case "餘": next = "S+"
            default: next = "B+"
            }
        }
        try replaceManualInputs(trade, investment: 0, reversal: next)
        return true
    }

    private func replaceManualInputs(_ trade: Trade, investment: Double,
                                     reversal: String) throws {
        let stockID = trade.stock.persistentModelID
        let start = twDateTime.startOfDay(trade.dateTime)
        let end = twDateTime.calendar.date(byAdding: .day, value: 1,
                                         to: twDateTime.startOfDay(now()))!
        // Raw rows, not the calculation window: invalid prices and duplicate
        // same-day rows must not retain hidden manual inputs.
        let rows = try context.fetch(FetchDescriptor<Trade>(predicate: #Predicate {
            $0.stock.persistentModelID == stockID && $0.dateTime >= start && $0.dateTime < end
        }))
        let trades = try Trade.fetchCalculationWindow(in: context, for: trade.stock)
        for row in rows {
            row.simReversed = ""
            row.simInvestByUser = 0
        }
        trade.simInvestByUser = investment
        trade.simReversed = reversal
        let replayStart = rows.map(\.dateTime).min() ?? trade.dateTime
        RecalculationInvalidation.manualInput(trade.stock, from: replayStart)
        trade.stock.rebuildUserActionSummary(from: trades)
        // One save commits replacement, summary and durable replay together.
        // Failure retains the paired pending transaction, as existing callers expect.
        try persist()
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
            // The setting change affects the full retained simulation window.
            RecalculationInvalidation.manualInput(stock, from: .distantPast)
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
