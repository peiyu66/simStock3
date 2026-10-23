import Foundation

/// A calculation window derived only from the configured start and the supplied
/// raw prices. Callers supply their own data cutoff; wall-clock time and stored
/// technical or simulation results do not participate in this calculation.
struct CalculationWindow: Codable, Equatable {
    /// Preserve the original value so callers can detect configuration changes.
    let configuredStart: Date
    let requestStart: Date
    let firstPriceDate: Date?
    let simulationStart: Date?
    let lastPriceDate: Date?

    init(configuredStart: Date, prices: [(date: Date, close: Double)]) {
        self.configuredStart = configuredStart
        let configuredDay = twDateTime.startOfDay(configuredStart)
        let requestStart = twDateTime.requestStart(for: configuredStart)
        self.requestStart = requestStart

        var first: Date?
        var last: Date?
        for price in prices where price.close.isFinite && price.close > 0 {
            let day = twDateTime.startOfDay(price.date)
            guard day >= requestStart else { continue }
            first = min(first ?? day, day)
            last = max(last ?? day, day)
        }
        firstPriceDate = first
        lastPriceDate = last
        // Calendar year arithmetic clamps Feb 29 to Feb 28. Protect the
        // configured lower bound when subtracting then adding a year would
        // otherwise place the effective start one day before that setting.
        simulationStart = first.map {
            max(configuredDay, twDateTime.startOfDay(twDateTime.addYears(1, to: $0)))
        }
    }

    /// A valid technical history can exist without reaching the simulation
    /// start. Such a window still supplies prices for technical calculation.
    var hasSimulationDates: Bool {
        guard let simulationStart, let lastPriceDate else { return false }
        return simulationStart <= lastPriceDate
    }
}
