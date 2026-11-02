import Foundation
import SwiftData

/// Detached, read-only presentation models. Never insert these into the live
/// context or pass them to calculation/input writers. Keeping the model shape
/// lets existing badges, technical details and explanations share one snapshot.
@MainActor
final class RetainedStockPresentation {
    let stock: Stock
    private var rows: [ObjectIdentifier: Trade] = [:]
    private(set) var latest: Trade?
    var capturedRowCount: Int { rows.count }
    private let lastVisibleDay: Date
    private let window: CalculationWindow
    let marketDays: [Date: MarketDay]

    init(stock source: Stock, trades sourceTrades: [Trade], marketDays: [Date: MarketDay] = [:]) {
        self.marketDays = marketDays
        window = source.calculationWindow
        lastVisibleDay = window.lastPriceDate ?? .distantPast
        stock = Stock(sId: source.sId, sName: source.sName, group: source.group,
                      dateFirst: source.dateFirst, dateStart: source.dateStart)
        stock.sName = source.sName
        stock.group = source.group
        stock.p10Action = source.p10Action
        stock.p10Date = source.p10Date
        stock.p10L = source.p10L
        stock.p10H = source.p10H
        stock.p10Rule = source.p10Rule
        stock.proport = source.proport
        stock.dateFirst = source.dateFirst
        stock.dateStart = source.dateStart
        stock.simInvestAuto = source.simInvestAuto
        stock.simInvestExceed = source.simInvestExceed
        stock.simInvestUser = source.simInvestUser
        stock.simMoneyBase = source.simMoneyBase
        stock.simMoneyLacked = source.simMoneyLacked
        stock.simReversed = source.simReversed
        stock.isListed = source.isListed
        stock.technicalStateVersion = source.technicalStateVersion
        stock.simulationStateVersion = source.simulationStateVersion
        stock.technicalDirtyFrom = source.technicalDirtyFrom
        stock.technicalPendingWork = source.technicalPendingWork
        stock.twseHistoryCoverage = source.twseHistoryCoverage
        stock.twseListingDate = source.twseListingDate
        stock.technicalRollingOrigin = source.technicalRollingOrigin
        stock.simulationDirtyFrom = source.simulationDirtyFrom
        stock.manualIntentValidationFrom = source.manualIntentValidationFrom
        stock.yahooCheckedAt = source.yahooCheckedAt
        stock.cachedCalculationWindow = window
        for trade in sourceTrades { retain(trade) }
    }

    /// Called before live scalar writes, so both raw prices and derived values
    /// are captured before their first mutation. Normal intraday refreshes
    /// copy only changed rows, not every stock's entire history.
    func retain(_ source: Trade) {
        guard source.modelContext != nil, source.stock.sId == stock.sId,
              rows[ObjectIdentifier(source)] == nil,
              source.date <= lastVisibleDay else { return }
        let result = Trade(stock: stock, dateTime: source.dateTime, dataSource: source.dataSource)
        result.dataSource = source.dataSource
        result.dateTime = source.dateTime
        result.priceClose = source.priceClose
        result.priceHigh = source.priceHigh
        result.priceLow = source.priceLow
        result.priceOpen = source.priceOpen
        result.volumeClose = source.volumeClose
        result.rollAmtCost = source.rollAmtCost
        result.rollAmtProfit = source.rollAmtProfit
        result.rollAmtRoi = source.rollAmtRoi
        result.rollDays = source.rollDays
        result.rollRounds = source.rollRounds
        result.simAmtBalance = source.simAmtBalance
        result.simAmtCost = source.simAmtCost
        result.simAmtProfit = source.simAmtProfit
        result.simAmtRoi = source.simAmtRoi
        result.simDays = source.simDays
        result.simInvestAdded = source.simInvestAdded
        result.simInvestByUser = source.simInvestByUser
        result.simInvestTimes = source.simInvestTimes
        result.simQtyBuy = source.simQtyBuy
        result.simQtyInventory = source.simQtyInventory
        result.simQtySell = source.simQtySell
        result.simReversed = source.simReversed
        result.simRule = source.simRule
        result.simRuleBuy = source.simRuleBuy
        result.simRuleInvest = source.simRuleInvest
        result.simUnitCost = source.simUnitCost
        result.simUnitRoi = source.simUnitRoi
        result.simUpdated = source.simUpdated
        result.simMoneyLackedCumulative = source.simMoneyLackedCumulative
        result.simInvestExceedCumulative = source.simInvestExceedCumulative
        result.simFitFast = source.simFitFast
        result.simFitSlow = source.simFitSlow
        result.simFitTrend = source.simFitTrend
        result.simFitObservationCount = source.simFitObservationCount
        result.simFitTrendPhaseRaw = source.simFitTrendPhaseRaw
        result.simFitTrendPhaseExtreme = source.simFitTrendPhaseExtreme
        result.simMarketSourceDate = source.simMarketSourceDate
        result.simMarketQuoteTime = source.simMarketQuoteTime
        result.simMarketIsProvisional = source.simMarketIsProvisional
        result.simProvisionalEffectiveInvestment = source.simProvisionalEffectiveInvestment
        result.simProvisionalEffectiveReversal = source.simProvisionalEffectiveReversal
        result.simAnnualWarningData = source.simAnnualWarningData
        result.tPricePathPhaseRaw = source.tPricePathPhaseRaw
        result.tPricePathBarrier = source.tPricePathBarrier
        result.tPricePathAnchorClose = source.tPricePathAnchorClose
        result.tPricePathExtremeClose = source.tPricePathExtremeClose
        result.tPricePathDaysSinceExtreme = source.tPricePathDaysSinceExtreme
        result.tHighDiff = source.tHighDiff
        result.tHighDiff125 = source.tHighDiff125
        result.tHighDiff250 = source.tHighDiff250
        result.tHighDiffZ125 = source.tHighDiffZ125
        result.tHighDiffZ250 = source.tHighDiffZ250
        result.tHighMax9 = source.tHighMax9
        result.tLowDiff = source.tLowDiff
        result.tLowDiff125 = source.tLowDiff125
        result.tLowDiff250 = source.tLowDiff250
        result.tLowDiffZ125 = source.tLowDiffZ125
        result.tLowDiffZ250 = source.tLowDiffZ250
        result.tLowMin9 = source.tLowMin9
        result.tMa20 = source.tMa20
        result.tMa20Days = source.tMa20Days
        result.tMa20Diff = source.tMa20Diff
        result.tMa20DiffMax9 = source.tMa20DiffMax9
        result.tMa20DiffMin9 = source.tMa20DiffMin9
        result.tMa20DiffZ125 = source.tMa20DiffZ125
        result.tMa20DiffZ250 = source.tMa20DiffZ250
        result.tMa60 = source.tMa60
        result.tMa60Days = source.tMa60Days
        result.tMa60Diff = source.tMa60Diff
        result.tMa60DiffMax9 = source.tMa60DiffMax9
        result.tMa60DiffMin9 = source.tMa60DiffMin9
        result.tMa60DiffZ125 = source.tMa60DiffZ125
        result.tMa60DiffZ250 = source.tMa60DiffZ250
        result.tZ125 = source.tZ125
        result.tZ250 = source.tZ250
        result.tKdK = source.tKdK
        result.tKdKMax9 = source.tKdKMax9
        result.tKdKMin9 = source.tKdKMin9
        result.tKdKZ125 = source.tKdKZ125
        result.tKdKZ250 = source.tKdKZ250
        result.tKdD = source.tKdD
        result.tKdDZ125 = source.tKdDZ125
        result.tKdDZ250 = source.tKdDZ250
        result.tKdJ = source.tKdJ
        result.tKdJZ125 = source.tKdJZ125
        result.tKdJZ250 = source.tKdJZ250
        result.tOsc = source.tOsc
        result.tOscEma12 = source.tOscEma12
        result.tOscEma26 = source.tOscEma26
        result.tOscMacd9 = source.tOscMacd9
        result.tOscMax9 = source.tOscMax9
        result.tOscMin9 = source.tOscMin9
        result.tOscZ125 = source.tOscZ125
        result.tOscZ250 = source.tOscZ250
        result.vMa20 = source.vMa20
        result.vMa20Days = source.vMa20Days
        result.vMa20Diff = source.vMa20Diff
        result.vMa20DiffMax9 = source.vMa20DiffMax9
        result.vMa20DiffMin9 = source.vMa20DiffMin9
        result.vMa20DiffZ125 = source.vMa20DiffZ125
        result.vMa20DiffZ250 = source.vMa20DiffZ250
        result.vMa60 = source.vMa60
        result.vMa60Days = source.vMa60Days
        result.vMa60Diff = source.vMa60Diff
        result.vMa60DiffMax9 = source.vMa60DiffMax9
        result.vMa60DiffMin9 = source.vMa60DiffMin9
        result.vMa60DiffZ125 = source.vMa60DiffZ125
        result.vMa60DiffZ250 = source.vMa60DiffZ250
        result.vMax9 = source.vMax9
        result.vMin9 = source.vMin9
        result.vZ125 = source.vZ125
        result.vZ250 = source.vZ250
        result.tUpdated = source.tUpdated
        rows[ObjectIdentifier(source)] = result
        if latest == nil || result.dateTime > latest!.dateTime { latest = result }
        // Constructing a detached row invalidates its owner's window. Retain
        // the original bounded summary without attaching live model endpoints.
        stock.cachedCalculationWindow = window
        stock.cachedWindowEndpoints = []
    }

    func presentedTrades(_ source: [Trade]) -> [Trade] {
        var result: [Trade] = []
        var seen: Set<Date> = []
        for trade in source {
            if trade.simulationResultPending || trade.technicalResultPending { retain(trade) }
            let shown = rows[ObjectIdentifier(trade)] ?? trade
            if shown.date <= lastVisibleDay, seen.insert(shown.date).inserted { result.append(shown) }
        }
        // A replaced/deleted latest quote is still part of the previous UI.
        for row in rows.values where seen.insert(row.date).inserted { result.append(row) }
        return result.sorted { $0.dateTime > $1.dateTime }
    }

    isolated deinit {
        // Detached inverse relationships must not retain the previous graph
        // after publication releases its owner.
        stock.cachedWindowEndpoints = []
        stock.trades = []
    }

    static func copyMarketDay(_ source: MarketDay) -> MarketDay {
        let result = MarketDay(dateTime: source.dateTime, dataSource: source.dataSource,
            indexOpen: source.indexOpen, indexHigh: source.indexHigh,
            indexLow: source.indexLow, indexClose: source.indexClose)
        result.dataSource = source.dataSource
        result.quoteTime = source.quoteTime
        result.indexOpen = source.indexOpen
        result.indexHigh = source.indexHigh
        result.indexLow = source.indexLow
        result.indexClose = source.indexClose
        result.indexHighMax9 = source.indexHighMax9
        result.indexLowMin9 = source.indexLowMin9
        result.indexHighDiff250 = source.indexHighDiff250
        result.indexLowDiffZ125 = source.indexLowDiffZ125
        result.ma20DiffMax9 = source.ma20DiffMax9
        result.indexHighDiffZ250 = source.indexHighDiffZ250
        result.indexHighDiffZ125 = source.indexHighDiffZ125
        result.oscZ125 = source.oscZ125
        result.oscEMA12 = source.oscEMA12
        result.oscEMA26 = source.oscEMA26
        result.oscMACD9 = source.oscMACD9
        result.kdK = source.kdK
        result.kdD = source.kdD
        result.kdJZ250 = source.kdJZ250
        result.priceObservationCount = source.priceObservationCount
        result.pricePathPhaseRaw = source.pricePathPhaseRaw
        result.pricePathBarrier = source.pricePathBarrier
        result.pricePathAnchorClose = source.pricePathAnchorClose
        result.pricePathExtremeClose = source.pricePathExtremeClose
        result.pricePathDaysSinceExtreme = source.pricePathDaysSinceExtreme
        result.technicalStateVersion = source.technicalStateVersion
        return result
    }
}
