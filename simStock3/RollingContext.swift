import Foundation
import SwiftData

/// 技術值重播期間共用的滾動前態；目前保存價格路徑所需的有限歷史與區段摘要。
struct TechnicalRollingContext: Sendable {
    private var pricePath = PricePathRollingContext()

    static func seeded(before index: Int, in trades: [Trade]) -> Self {
        guard index > 0 else { return Self() }
        let priorTrades = trades[..<min(index, trades.count)]
        let points = priorTrades.suffix(
            RollingPricePathClassifier.volatilityLookback + 1
        ).map {
            RollingPricePathPoint(date: $0.dateTime, close: $0.priceClose)
        }
        return Self(
            pricePath: .seeded(
                points: points,
                state: priorTrades.last?.storedPricePathState
            )
        )
    }

    @MainActor
    static func seeded(
        before date: Date,
        for stock: Stock,
        in modelContext: ModelContext
    ) throws -> Self {
        let stockID = stock.persistentModelID
        var descriptor = FetchDescriptor<Trade>(
            predicate: #Predicate {
                $0.stock.persistentModelID == stockID && $0.dateTime < date
            },
            sortBy: [SortDescriptor(\.dateTime, order: .reverse)]
        )
        descriptor.fetchLimit = RollingPricePathClassifier.volatilityLookback + 1
        let priorTrades = try modelContext.fetch(descriptor).reversed()
        return Self(
            pricePath: .seeded(
                points: priorTrades.map {
                    RollingPricePathPoint(date: $0.dateTime, close: $0.priceClose)
                },
                state: priorTrades.last?.storedPricePathState
            )
        )
    }

    mutating func update(after trade: Trade) {
        trade.applyPricePathState(
            pricePath.update(date: trade.dateTime, close: trade.priceClose)
        )
    }
}

/// 模擬重播期間共用的滾動前態，只保存已通過檢驗且正式規則需要的摘要。
struct SimulationRollingContext: Sendable {
    enum WorseningBoundary: Sendable {
        case warning
        case confirmed
    }

    /// 最近一次有效自動結案是否為認賠；0 代表沒有認賠降級，1 代表降一級。
    private(set) var gradeLossCutPenaltyLevel: Int = 0
    /// 最近一次惡化邊界的種類；L-P10 只需此摘要，不保留整段 Trade 歷史。
    private(set) var lastWorseningBoundary: WorseningBoundary?
    /// 決策日前最近一次有效加碼的交易日距離；昨天加碼為 0，nil 代表本輪尚未加碼。
    private(set) var tradingDaysSinceLastInvestment: Int?

    /// 從已載入的完整交易序列，建立指定列開始決策前的模擬前態。
    static func seeded(before index: Int, in trades: [Trade]) -> Self {
        guard index > 0 else { return Self() }
        var gradeLossCutPenaltyLevel = 0
        var foundGradeLossCutPenaltyLevel = false
        var lastWorseningBoundary: WorseningBoundary?
        var tradingDaysSinceLastInvestment: Int?
        var resolvedLastInvestment = false

        for (distance, priorIndex) in stride(from: index - 1, through: 0, by: -1).enumerated() {
            let priorTrade = trades[priorIndex]
            if !foundGradeLossCutPenaltyLevel,
               let level = Self.gradeLossCutPenaltyLevel(after: priorTrade) {
                gradeLossCutPenaltyLevel = level
                foundGradeLossCutPenaltyLevel = true
            }
            if lastWorseningBoundary == nil {
                lastWorseningBoundary = worseningBoundary(after: priorTrade)
            }
            if !resolvedLastInvestment {
                if priorTrade.invested == 1 {
                    tradingDaysSinceLastInvestment = distance
                    resolvedLastInvestment = true
                } else if priorTrade.simDays <= 1 {
                    resolvedLastInvestment = true
                }
            }
            if foundGradeLossCutPenaltyLevel,
               lastWorseningBoundary != nil,
               resolvedLastInvestment {
                break
            }
        }
        return Self(
            gradeLossCutPenaltyLevel: gradeLossCutPenaltyLevel,
            lastWorseningBoundary: lastWorseningBoundary,
            tradingDaysSinceLastInvestment: tradingDaysSinceLastInvestment
        )
    }

    /// 單日更新只查一次最近有效自動結案，不受技術值 251 筆視窗限制。
    @MainActor
    static func seeded(
        before date: Date,
        for stock: Stock,
        in modelContext: ModelContext
    ) throws -> Self {
        let stockID = stock.persistentModelID
        var descriptor = FetchDescriptor<Trade>(
            predicate: #Predicate {
                $0.stock.persistentModelID == stockID &&
                $0.dateTime < date &&
                $0.simQtySell > 0 &&
                $0.simReversed == ""
            },
            sortBy: [SortDescriptor(\.dateTime, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        let gradeLossCutPenaltyLevel = try modelContext.fetch(descriptor).first
            .flatMap { Self.gradeLossCutPenaltyLevel(after: $0) } ?? 0

        var boundaryDescriptor = FetchDescriptor<Trade>(
            predicate: #Predicate {
                $0.stock.persistentModelID == stockID &&
                $0.dateTime < date &&
                ($0.simFitTrendPhaseRaw == 3 ||
                    $0.simFitTrendPhaseRaw == 5 ||
                    $0.simFitTrendPhaseRaw == 10 ||
                    $0.simFitTrendPhaseRaw == 11)
            },
            sortBy: [SortDescriptor(\.dateTime, order: .reverse)]
        )
        boundaryDescriptor.fetchLimit = 1
        let lastWorseningBoundary = try modelContext.fetch(boundaryDescriptor).first
            .flatMap { worseningBoundary(after: $0) }

        var investmentDescriptor = FetchDescriptor<Trade>(
            predicate: #Predicate {
                $0.stock.persistentModelID == stockID &&
                $0.dateTime < date
            },
            sortBy: [SortDescriptor(\.dateTime, order: .reverse)]
        )
        investmentDescriptor.fetchLimit = 60
        var tradingDaysSinceLastInvestment: Int?
        for (distance, priorTrade) in try modelContext.fetch(investmentDescriptor).enumerated() {
            if priorTrade.invested == 1 {
                tradingDaysSinceLastInvestment = distance
                break
            }
            if priorTrade.simDays <= 1 {
                break
            }
        }

        return Self(
            gradeLossCutPenaltyLevel: gradeLossCutPenaltyLevel,
            lastWorseningBoundary: lastWorseningBoundary,
            tradingDaysSinceLastInvestment: tradingDaysSinceLastInvestment
        )
    }

    /// 當日正式模擬完成後推進前態；手動反轉與零損益不改變既有狀態。
    mutating func update(after trade: Trade) {
        if let level = Self.gradeLossCutPenaltyLevel(after: trade) {
            gradeLossCutPenaltyLevel = level
        }
        if let boundary = Self.worseningBoundary(after: trade) {
            lastWorseningBoundary = boundary
        }
        if trade.invested == 1 {
            tradingDaysSinceLastInvestment = 0
        } else if trade.simDays <= 1 {
            tradingDaysSinceLastInvestment = nil
        } else if let distance = tradingDaysSinceLastInvestment {
            tradingDaysSinceLastInvestment = distance + 1
        }
    }

    func hasNoInvestment(inPreviousTradingDays dayCount: Int) -> Bool {
        guard let tradingDaysSinceLastInvestment else { return true }
        return tradingDaysSinceLastInvestment >= dayCount
    }

    func lP10RecoveryBuyBonus(
        decisionPhase: StrategyFitTrendPhase,
        observationCount: Int
    ) -> Double {
        guard observationCount >= StrategyFitTrendClassifier.minimumObservationCount,
              decisionPhase != .worseningWarning,
              !decisionPhase.isWorseningConfirmed,
              lastWorseningBoundary == .confirmed else {
            return 0
        }
        return 1
    }

    private static func gradeLossCutPenaltyLevel(after trade: Trade) -> Int? {
        guard trade.simQtySell > 0, trade.simReversed.isEmpty else { return nil }
        if trade.simAmtRoi < 0 { return 1 }
        if trade.simAmtRoi > 0 { return 0 }
        return nil
    }

    private static func worseningBoundary(after trade: Trade) -> WorseningBoundary? {
        let phase = trade.strategyFitTrendPhase
        if phase == .worseningWarning {
            return .warning
        }
        if phase.isWorseningConfirmed {
            return .confirmed
        }
        return nil
    }
}

/// 一次股票重播共用的滾動狀態；值型別複製可隔離 P10 與盤中假設分支。
struct ReplayRollingContext: Sendable {
    var technical = TechnicalRollingContext()
    var simulation: SimulationRollingContext

    static func seeded(before index: Int, in trades: [Trade]) -> Self {
        Self(
            technical: .seeded(before: index, in: trades),
            simulation: .seeded(before: index, in: trades)
        )
    }

    @MainActor
    static func seeded(
        before date: Date,
        for stock: Stock,
        in modelContext: ModelContext
    ) throws -> Self {
        Self(
            technical: try .seeded(before: date, for: stock, in: modelContext),
            simulation: try .seeded(before: date, for: stock, in: modelContext)
        )
    }

    /// 明確建立互不污染的情境前態；目前值型別複製不需要額外配置。
    func fork() -> Self { self }
}
