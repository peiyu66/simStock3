import Foundation

/// A calculation window derived only from the configured start and the supplied
/// raw prices. Callers supply their own data cutoff; wall-clock time and stored
/// technical or simulation results do not participate in this calculation.
struct CalculationWindow: Equatable {
    /// Preserve the original value so callers can detect configuration changes.
    let configuredStart: Date
    let requestStart: Date
    let firstPriceDate: Date?
    let simulationStart: Date?
    let lastPriceDate: Date?

    init(configuredStart: Date, prices: [(date: Date, close: Double)]) {
        self.configuredStart = configuredStart
        let calendar = twDateTime.calendar
        let configuredDay = calendar.startOfDay(for: configuredStart)
        let requestStart = calendar.startOfDay(for:
            calendar.date(byAdding: .year, value: -1, to: configuredDay) ?? configuredDay)
        self.requestStart = requestStart

        var first: Date?
        var last: Date?
        for price in prices where price.close.isFinite && price.close > 0 {
            let day = calendar.startOfDay(for: price.date)
            guard day >= requestStart else { continue }
            first = min(first ?? day, day)
            last = max(last ?? day, day)
        }
        firstPriceDate = first
        lastPriceDate = last
        // Calendar year arithmetic clamps Feb 29 to Feb 28. Protect the
        // configured lower bound when subtracting then adding a year would
        // otherwise place the effective start one day before that setting.
        simulationStart = first
            .flatMap { calendar.date(byAdding: .year, value: 1, to: $0) }
            .map { max(configuredDay, calendar.startOfDay(for: $0)) }
    }

    /// A valid technical history can exist without reaching the simulation
    /// start. Such a window still supplies prices for technical calculation.
    var hasSimulationDates: Bool {
        guard let simulationStart, let lastPriceDate else { return false }
        return simulationStart <= lastPriceDate
    }
}
