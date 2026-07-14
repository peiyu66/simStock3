import Foundation

enum TechnicalRecalculationScope: Equatable {
    case none
    case from(Date)
    case backfill(from: Date)
    case all
}

enum SimulationRecalculationScope: Equatable {
    case none
    case from(Date)
    case all
}

enum SimulationResetPolicy: Equatable {
    case preserveUserActions
    case clearUserActions
}

struct RecalculationPlan: Equatable {
    var technical: TechnicalRecalculationScope
    var simulation: SimulationRecalculationScope
    var resetPolicy: SimulationResetPolicy = .preserveUserActions
    var resetDerivedSimulationState: Bool = false
    var saveResults: Bool = true
    var simulationEnd: Date? = nil

    static let none = RecalculationPlan(technical: .none, simulation: .none)
}

struct TradeChangeSet: Equatable {
    var previousFirstDate: Date?
    var previousLastDate: Date?
    var insertedDates: Set<Date> = []
    var modifiedDates: Set<Date> = []

    var changedDates: Set<Date> { insertedDates.union(modifiedDates) }
    var earliestChangedDate: Date? { changedDates.min() }
    var isEmpty: Bool { changedDates.isEmpty }

    func plan(simulationStart: Date, firstStableTechnicalDate: Date?) -> RecalculationPlan {
        guard let earliestChangedDate else { return .none }

        guard let previousFirstDate, let previousLastDate else {
            return RecalculationPlan(
                technical: .all,
                simulation: .all,
                resetDerivedSimulationState: true
            )
        }

        let isPureAppend = modifiedDates.isEmpty
            && !insertedDates.isEmpty
            && insertedDates.allSatisfy { $0 > previousLastDate }

        if isPureAppend {
            return RecalculationPlan(
                technical: .from(earliestChangedDate),
                simulation: .from(max(earliestChangedDate, simulationStart))
            )
        }

        let isPureBackfill = modifiedDates.isEmpty
            && !insertedDates.isEmpty
            && insertedDates.allSatisfy { $0 < previousFirstDate }

        if isPureBackfill {
            let simulation: SimulationRecalculationScope
            if let firstStableTechnicalDate, firstStableTechnicalDate <= simulationStart {
                simulation = .none
            } else {
                simulation = .from(simulationStart)
            }
            return RecalculationPlan(
                technical: .backfill(from: earliestChangedDate),
                simulation: simulation,
                resetDerivedSimulationState: simulation != .none
            )
        }

        // A correction or a gap can change every later recursive technical value.
        // Simulation is therefore restarted at its configured beginning.
        return RecalculationPlan(
            technical: .from(earliestChangedDate),
            simulation: .from(simulationStart),
            resetDerivedSimulationState: true
        )
    }
}

struct RecalculationTrace: Equatable {
    var technicalDates: [Date] = []
    var simulationDates: [Date] = []
}
