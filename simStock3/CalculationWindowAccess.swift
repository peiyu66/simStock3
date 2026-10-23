import Foundation
import SwiftData
import Observation

extension Stock {
    static var calculationWindowBuildCount = 0
    static var calculationWindowInputScanCount = 0
    static var calculationWindowObservedRowCount = 0
    /// A nonpersistent snapshot of the inputs that determine the visible period.
    /// Raw row insertion, date/quote writes and deletion invalidate it. The
    /// replay installs it once from its already loaded, ordered raw inputs.
    var calculationWindow: CalculationWindow {
        // Observe one input signal, never the retained to-many relationship.
        _ = tradeInputChanges.revision
        if let cachedCalculationWindow, cachedCalculationWindow.configuredStart == dateStart,
           cachedWindowDeletionCount == (modelContext?.deletedModelsArray.count ?? 0),
           cachedWindowEndpoints.allSatisfy({ !$0.isDeleted && $0.modelContext === modelContext }) {
            return cachedCalculationWindow
        }
        guard let context = modelContext else {
            // Uninserted construction fixtures have no database to query.
            // Production stocks always belong to their ModelContext.
            return installCalculationWindow(from: trades.filter { !$0.isDeleted })
        }
        do {
            let first = try Trade.windowEndpoint(in: context, for: self, ascending: true)
            let last = try Trade.windowEndpoint(in: context, for: self, ascending: false)
            return installCalculationWindow(from: [first, last].compactMap { $0 })
        } catch {
            // A failed read is not evidence for an empty, reusable window.
            simLog.addLog("日期範圍查詢失敗：\(sId) \(error.localizedDescription)")
            return CalculationWindow(configuredStart: dateStart, prices: [])
        }
    }

    @discardableResult
    func installCalculationWindow(from trades: [Trade]) -> CalculationWindow {
        Self.calculationWindowInputScanCount += 1
        let candidate = CalculationWindow(configuredStart: dateStart,
            prices: trades.filter { !$0.isDeleted }.map { (date: $0.dateTime, close: $0.priceClose) })
        // Keep only the extrema as deletion guards. Replay supplies its already
        // loaded window, while a presentation summary supplies at most two rows.
        let lower = twDateTime.startOfDay(dateRequestStart)
        let valid = trades.filter { !$0.isDeleted && $0.dateTime >= lower
            && $0.priceClose.isFinite && $0.priceClose > 0 }
        cachedWindowEndpoints = [valid.min { $0.dateTime < $1.dateTime },
                                 valid.max { $0.dateTime < $1.dateTime }].compactMap { $0 }
        if cachedCalculationWindow != candidate { Self.calculationWindowBuildCount += 1 }
        cachedWindowDeletionCount = modelContext?.deletedModelsArray.count ?? 0
        cachedCalculationWindow = candidate
        return candidate
    }

    func invalidateCalculationWindow() {
        cachedCalculationWindow = nil
        cachedWindowEndpoints = []
        tradeInputChanges.changed()
    }

    var effectiveSimulationStart: Date? { calculationWindow.simulationStart }
}

extension Trade {
    var hasUsableOfficialPrice: Bool {
        dataSource == "TWSE" && priceClose.isFinite && priceClose > 0
    }

    /// Raw-data management keeps using fetch; calculation and presentation use
    /// this explicit window so retained rows cannot become a hidden checkpoint.
    static func fetchCalculationWindow(in context: ModelContext, for stock: Stock,
                                      ascending: Bool = true) throws -> [Trade] {
        let stockID = stock.persistentModelID
        let lower = twDateTime.startOfDay(stock.dateRequestStart)
        let maximum = Double.greatestFiniteMagnitude
        let descriptor = FetchDescriptor<Trade>(predicate: #Predicate {
            $0.stock.persistentModelID == stockID && $0.dateTime >= lower
                && $0.priceClose > 0 && $0.priceClose <= maximum
        }, sortBy: [SortDescriptor(\.dateTime, order: ascending ? .forward : .reverse)])
        let trades = try context.fetch(descriptor)
        stock.installCalculationWindow(from: trades)
        return trades
    }

    /// The first/last usable price in the current calculation range. Invalid
    /// prices are rejected by the predicate before applying the one-row limit.
    static func windowEndpoint(in context: ModelContext, for stock: Stock,
                               ascending: Bool, officialOnly: Bool = false) throws -> Trade? {
        let stockID = stock.persistentModelID
        let lower = twDateTime.startOfDay(stock.dateRequestStart)
        let maximum = Double.greatestFiniteMagnitude
        // SwiftData's pending-change merge can apply a fetchLimit before a
        // deleted/invalidated endpoint is removed. Merge only the pending rows
        // ourselves, excluding their persisted versions from the limited SQL.
        // This is bounded by current edits, never by retained stock history.
        let changed = context.changedModelsArray.compactMap { $0 as? Trade }
        let deleted = context.deletedModelsArray.compactMap { $0 as? Trade }
        let inserted = context.insertedModelsArray.compactMap { $0 as? Trade }
        let excluded = Array(Set((changed + deleted).compactMap { row in
            row.persistentModelID.storeIdentifier == nil ? nil : row.persistentModelID
        }))
        let base = #Predicate<Trade> {
            $0.stock.persistentModelID == stockID && $0.dateTime >= lower
                && $0.priceClose > 0 && $0.priceClose <= maximum
                && (!officialOnly || $0.dataSource == "TWSE")
        }
        let predicate = excluded.isEmpty ? base : #Predicate<Trade> {
            base.evaluate($0) && !excluded.contains($0.persistentModelID)
        }
        var descriptor = FetchDescriptor<Trade>(predicate: predicate,
            sortBy: [SortDescriptor(\.dateTime, order: ascending ? .forward : .reverse)])
        descriptor.includePendingChanges = false
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [\.dateTime, \.priceClose]
        let persisted = stockID.storeIdentifier == nil ? nil : try context.fetch(descriptor).first
        let pending = (inserted + changed).filter {
            !$0.isDeleted && $0.stock === stock && $0.dateTime >= lower
                && $0.priceClose.isFinite && $0.priceClose > 0
                && (!officialOnly || $0.dataSource == "TWSE")
        }
        let candidates = pending + [persisted].compactMap { $0 }
        return ascending ? candidates.min { $0.dateTime < $1.dateTime }
                         : candidates.max { $0.dateTime < $1.dateTime }

    }

    /// Leaving the configured period can remove intent. Not yet reaching the
    /// effective, data-dependent start only defers validation of that intent.
    var isBeforeConfiguredSimulationStart: Bool {
        twDateTime.startOfDay(dateTime) < twDateTime.startOfDay(stock.dateStart)
    }
}
