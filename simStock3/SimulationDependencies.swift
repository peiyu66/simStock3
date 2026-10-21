import Foundation

extension MarketPricePathLookup.Observation {
    /// Computed partial windows are distinct from absent values. A phase still
    /// in warmup cannot stand in for "not an early peak" in ungated rules.
    var hasSimulationValues: Bool {
        guard phase != .unavailable, (1...250).contains(priceObservationCount),
              let low = indexLow, let low9 = indexLowMin9,
              let high = indexHigh, let high9 = indexHighMax9,
              let lowZ = indexLowDiffZ125, let ma = ma20DiffMax9,
              let highZ = indexHighDiffZ125, let osc = oscZ125,
              let highDiff = indexHighDiff250, let j = kdJZ250 else { return false }
        return [low, low9, high, high9, lowZ, ma, highZ, osc, highDiff, j].allSatisfy(\.isFinite)
            && low > 0 && low9 > 0 && high >= low && high9 >= high && low9 <= low
    }
}

enum SimulationDependencyIssue: Equatable {
    case technicalPending
    case stockOfficialPriceMissing
    case marketMissing
    case previousMarketMissing
    case interrupted

    var statusText: String {
        switch self {
        case .technicalPending: "個股技術值待重算"
        case .stockOfficialPriceMissing: "等待個股正式行情"
        case .marketMissing: "等待同日大盤技術資料"
        case .previousMarketMissing: "等待前一筆行情所需的大盤資料"
        case .interrupted: "計算已中斷，待下次接續"
        }
    }
}

extension Technical {
    /// Shared by persisted S replay and P10 before either can mutate a Trade.
    /// No rule votes are evaluated here; established source/maturity gates keep
    /// their meanings, including S64's explicit live previous-session fallback.
    func simulationDependencyIssue(trades: [Trade], index: Int,
                                   technicalPendingFrom: Date? = nil,
                                   technicalVersionIsCurrent: Bool = true) -> SimulationDependencyIssue? {
        let trade = trades[index]
        if !technicalVersionIsCurrent
            || technicalPendingFrom.map({ $0 <= trade.dateTime }) == true { return .technicalPending }
        let isLive = liveMarketContext.map {
            twDateTime.startOfDay($0.asOf) == twDateTime.startOfDay(trade.dateTime)
        } ?? false
        if !isLive && trade.dataSource != "TWSE" { return .stockOfficialPriceMissing }
        // S reads the preceding stock row even when that row is preparation
        // before the effective simulation start and never enters the S loop.
        if index > 0 && !trades[index - 1].hasUsableOfficialPrice { return .stockOfficialPriceMissing }
        guard let market = marketObservation(on: trade.dateTime), market.hasSimulationValues,
              isLive || market.isOfficial else { return .marketMissing }
        let borrowedLive = isLive && twDateTime.startOfDay(market.date) != twDateTime.startOfDay(trade.dateTime)
        // The delta gate uses the preceding stock row's market date. A mature
        // current market cannot turn a missing previous value into mature=false.
        // Borrowed live input intentionally has no same-day delta under S64.
        if !borrowedLive && index >= 249 && market.priceObservationCount >= 250 {
            guard index > 0, let previous = marketObservation(on: trades[index - 1].dateTime),
                  previous.hasSimulationValues, previous.isOfficial else { return .previousMarketMissing }
        }
        return nil
    }
}
