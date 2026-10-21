import Foundation

/// Shared date-local presentation gate. Reading a retained result does not
/// establish validity, and an intraday timestamp cannot hide same-day dirty.
extension Trade {
    var technicalResultPending: Bool {
        stock.technicalStateVersion < Int(Technical.technicalRuleVersion.dropFirst())!
            || includesPendingDay(stock.technicalDirtyFrom)
    }

    var simulationResultPending: Bool {
        technicalResultPending
            || stock.simulationStateVersion < Int(Technical.simulationRuleVersion.dropFirst())!
            || includesPendingDay(stock.simulationDirtyFrom)
    }

    private func includesPendingDay(_ from: Date?) -> Bool {
        from.map { twDateTime.startOfDay($0) <= twDateTime.startOfDay(dateTime) } ?? false
    }
}
