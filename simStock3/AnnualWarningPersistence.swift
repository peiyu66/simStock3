import Foundation
import SwiftData

/// One schema field, scoped to this warning. Changing its ingredients changes
/// the versioned payload and S replay code, not the SwiftData column layout.
enum AnnualWarningPersistence {
    static let formatVersion = 5

    struct Configuration: Codable, Equatable {
        let start: Date
        let budget: Double
        let additions: Double
        init(_ stock: Stock) {
            start = stock.dateStart
            budget = stock.simMoneyBase
            additions = stock.simInvestAuto
        }
    }

    struct Record: Codable {
        let formatVersion: Int
        let dataRules: String
        let configuration: Configuration
        let snapshot: TrueAnnualReturnWarning.Snapshot
        // Unlike snapshot.recoveryFloor, this survives an unavailable-data gap.
        let continuationFloor: Double?
        let continuationPriceHigh: Double?
        let locallyReleased: Bool
    }

    static func isEligible(_ stock: Stock) -> Bool {
        stock.simMoneyBase.isFinite && stock.simMoneyBase > 0
            && stock.simInvestAuto >= 0 && stock.simInvestAuto < 10
    }

    static func decode(_ trade: Trade) -> Record? {
        guard let data = trade.simAnnualWarningData,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.formatVersion == formatVersion,
              record.dataRules == Technical.dataRuleVersion,
              record.configuration == Configuration(trade.stock) else { return nil }
        if let floor = record.continuationFloor {
            guard floor.isFinite, let high = record.continuationPriceHigh,
                  high.isFinite, high > 0 else { return nil }
        } else if record.continuationPriceHigh != nil || record.locallyReleased { return nil }
        guard record.locallyReleased == (record.snapshot.localReleaseReason != nil) else { return nil }
        if let failed = record.snapshot.prewarningFailureDays {
            guard (0...2).contains(failed), record.snapshot.isPrewarning,
                  record.snapshot.prewarningReason != nil else { return nil }
        } else if record.snapshot.prewarningReason != nil { return nil }
        return record
    }

    static func write(_ snapshot: TrueAnnualReturnWarning.Snapshot,
                      continuationFloor: Double?, continuationPriceHigh: Double?,
                      locallyReleased: Bool, to trade: Trade) {
        let record = Record(formatVersion: formatVersion, dataRules: Technical.dataRuleVersion,
                            configuration: Configuration(trade.stock), snapshot: snapshot,
                            continuationFloor: continuationFloor,
                            continuationPriceHigh: continuationPriceHigh, locallyReleased: locallyReleased)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        trade.simAnnualWarningData = try? encoder.encode(record)
    }

    static func seed(from priorTrades: [Trade]) -> TrueAnnualReturnWarning {
        let eligible = priorTrades.filter { !$0.isBeforeSimulationStart }
        guard let last = eligible.last, isEligible(last.stock) else { return .init() }
        if let checkpoint = decode(last) {
            return .seeded(recoveryFloor: checkpoint.continuationFloor,
                          warningPriceHigh: checkpoint.continuationPriceHigh,
                          locallyReleased: checkpoint.locallyReleased,
                          prewarningFailureDays: checkpoint.snapshot.prewarningFailureDays,
                          prewarningReason: checkpoint.snapshot.prewarningReason,
                          observations: eligible.suffix(61).map {
                (annual: $0.baseRoi, close: $0.priceClose, ma60: $0.tMa60,
                 grade: $0.simFitTrendPhaseRaw == 8)
            }, recoveryObservations: eligible.suffix(61).map {
                (gradeScore: $0.gradeEfficiencyScore, cumulativeProfit: $0.rollAmtProfit)
            }, localReleaseReason: checkpoint.snapshot.localReleaseReason)
        }
        // Missing/corrupt/old checkpoint is repaired only at a calculation boundary,
        // never while reading UI. Full S migration normally starts before all history.
        var state = TrueAnnualReturnWarning()
        for (index, trade) in priorTrades.enumerated() where !trade.isBeforeSimulationStart {
            _ = state.advance(annual: trade.baseRoi, close: trade.priceClose, ma20: trade.tMa20, ma60: trade.tMa60,
                              gradeSeekingPeak: trade.simFitTrendPhaseRaw == 8,
                              ma20Days: trade.tMa20Days, ma60Days: trade.tMa60Days,
                              priceSeekingBottom: trade.pricePathPhase == .seekingBottomEarly
                                || trade.pricePathPhase == .seekingBottomLate,
                              ma20DiffZ125: trade.tMa20DiffZ125, ma60DiffZ125: trade.tMa60DiffZ125,
                              hasMatureZ125: index >= 183,
                              gradeScore: trade.gradeEfficiencyScore, cumulativeProfit: trade.rollAmtProfit)
        }
        return state
    }

    @MainActor
    static func seed(before date: Date, stock: Stock, context: ModelContext) throws -> TrueAnnualReturnWarning {
        let stockID = stock.persistentModelID
        var descriptor = FetchDescriptor<Trade>(predicate: #Predicate {
            $0.stock.persistentModelID == stockID && $0.dateTime < date
        }, sortBy: [SortDescriptor(\.dateTime, order: .reverse)])
        descriptor.fetchLimit = 61
        let recent = try context.fetch(descriptor)
        if let last = recent.first, !last.isBeforeSimulationStart, isEligible(stock), decode(last) == nil {
            descriptor.fetchLimit = nil
            return seed(from: try context.fetch(descriptor).reversed())
        }
        return seed(from: recent.reversed())
    }
}

extension Trade {
    /// A cold UI read only decodes the persisted result. It cannot run the engine.
    var storedAnnualWarning: TrueAnnualReturnWarning.Snapshot {
        guard !isBeforeSimulationStart, AnnualWarningPersistence.isEligible(stock),
              stock.technicalStateVersion >= Int(Technical.technicalRuleVersion.dropFirst())!,
              stock.simulationStateVersion >= Int(Technical.simulationRuleVersion.dropFirst())!,
              !(stock.technicalDirtyFrom.map { dateTime >= $0 } ?? false),
              !(stock.simulationDirtyFrom.map { dateTime >= $0 } ?? false) else { return .unavailable }
        return AnnualWarningPersistence.decode(self)?.snapshot ?? .unavailable
    }
}
