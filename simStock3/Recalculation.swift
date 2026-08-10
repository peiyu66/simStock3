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

        // A correction or a gap can change every later recursive value, but the
        // preceding Trade remains a valid simulation checkpoint.
        return RecalculationPlan(
            technical: .from(earliestChangedDate),
            simulation: .from(max(earliestChangedDate, simulationStart))
        )
    }
}

struct RecalculationTrace: Equatable {
    var technicalDates: [Date] = []
    var simulationDates: [Date] = []
    var userActions = UserActionRecalculationSummary()
}

enum UserActionResolution: Equatable {
    case none
    case retained
    case clearedRedundant
    case clearedInvalid
}

struct UserActionValidation: Equatable {
    var reversal: UserActionResolution = .none
    var manualInvestment: UserActionResolution = .none
}

struct UserActionRecalculationSummary: Equatable {
    var retained = 0
    var clearedRedundant = 0
    var clearedInvalid = 0

    var total: Int {
        retained + clearedRedundant + clearedInvalid
    }

    var cleared: Int {
        clearedRedundant + clearedInvalid
    }

    mutating func record(_ resolution: UserActionResolution) {
        switch resolution {
        case .none:
            break
        case .retained:
            retained += 1
        case .clearedRedundant:
            clearedRedundant += 1
        case .clearedInvalid:
            clearedInvalid += 1
        }
    }

    mutating func record(_ validation: UserActionValidation) {
        record(validation.reversal)
        record(validation.manualInvestment)
    }

    mutating func merge(_ other: UserActionRecalculationSummary) {
        retained += other.retained
        clearedRedundant += other.clearedRedundant
        clearedInvalid += other.clearedInvalid
    }

    var resultMessage: String {
        "人工操作重新驗證完成：保留 \(retained) 筆、冗餘清除 \(clearedRedundant) 筆、無法成立清除 \(clearedInvalid) 筆。"
    }
}
