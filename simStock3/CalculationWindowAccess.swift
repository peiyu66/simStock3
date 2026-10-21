import Foundation
import SwiftData
import Observation

extension Stock {
    /// A nonpersistent snapshot of the inputs that determine the visible period.
    /// Raw row insertion, date/quote writes and deletion invalidate it. The
    /// replay installs it once from its already loaded, ordered raw inputs.
    var calculationWindow: CalculationWindow {
        if let cachedCalculationWindow, cachedCalculationWindow.configuredStart == dateStart {
            return cachedCalculationWindow
        }
        return installCalculationWindow(from: trades.filter { !$0.isDeleted })
    }

    @discardableResult
    func installCalculationWindow(from trades: [Trade]) -> CalculationWindow {
        // Observe the generated SwiftData accessors themselves. Stored-property
        // didSet observers are not called by every generated model write.
        let window = withObservationTracking {
            // Even currently invalid/outside rows can become the first valid
            // window input after a correction; observe them before filtering.
            for raw in self.trades {
                _ = raw.dateTime
                _ = raw.priceClose
                _ = raw.isDeleted
            }
            return CalculationWindow(configuredStart: dateStart,
                prices: trades.map { (date: $0.dateTime, close: $0.priceClose) })
        } onChange: { [weak self] in
            // Stock/Trade mutations are MainActor-isolated, and invalidation
            // must be synchronous: a Task would leave an immediate read stale.
            MainActor.assumeIsolated { self?.invalidateCalculationWindow() }
        }
        cachedCalculationWindow = window
        return window
    }

    func invalidateCalculationWindow() { cachedCalculationWindow = nil }

    var effectiveSimulationStart: Date? { calculationWindow.simulationStart }
}

extension Trade {
    /// Raw-data management keeps using fetch; calculation and presentation use
    /// this explicit window so retained rows cannot become a hidden checkpoint.
    static func fetchCalculationWindow(in context: ModelContext, for stock: Stock,
                                      ascending: Bool = true) throws -> [Trade] {
        let trades = try fetch(in: context, for: stock,
            start: twDateTime.startOfDay(stock.dateRequestStart), ascending: ascending)
            .filter { $0.priceClose.isFinite && $0.priceClose > 0 }
        stock.installCalculationWindow(from: trades)
        return trades
    }

    /// Leaving the configured period can remove intent. Not yet reaching the
    /// effective, data-dependent start only defers validation of that intent.
    var isBeforeConfiguredSimulationStart: Bool {
        twDateTime.startOfDay(dateTime) < twDateTime.startOfDay(stock.dateStart)
    }
}
