#if DEBUG
import SwiftUI
import SwiftData

/// Isolated in-memory UI fixture. Uses production icons, popovers and formatters;
/// never imports a user's store or runs technical/simulation calculations.
@MainActor
struct IconExplanationPreview: View {
    private let container: ModelContainer
    private let trades: [Trade]
    private let markets: [MarketDay]
    private var warningCase: Int? {
        ProcessInfo.processInfo.arguments.compactMap { arg -> Int? in
            guard arg.hasPrefix("--warning-preview-") else { return nil }
            return Int(arg.replacingOccurrences(of: "--warning-preview-", with: ""))
        }.first
    }
    private var previewWarning: TrueAnnualReturnWarning.Snapshot {
        let n = warningCase ?? 1
        var value = TrueAnnualReturnWarning.Snapshot(status: n == 0 ? .caution : n == 1 ? .recovering : .released,
            priorAnnual: n == 6 ? nil : -2.4, recoveryFloor: n == 6 ? nil : -1.8,
            priceRecovered: n != 0, recentReturnRecovered: n != 0, gradeSeekingPeak: n != 0)
        if (2...5).contains(n) {
            value.prewarningFailureDays = n == 5 ? 2 : 0
            value.prewarningReason = n == 2 ? .returnWeakness : n == 3 ? .priceBottom : .both
        }
        if n == 6 { value = .unavailable }
        return value
    }
    @State private var selection = 0
    @State private var narrow = false
    @State private var actionCount = 0

    init() {
        let container = try! ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        self.container = container
        var trades: [Trade] = []
        var markets: [MarketDay] = []
        for i in 0..<3 {
            let date = twDateTime.dateFromString(i == 1 ? "2026-10-05" : "2026-10-06")!
            let stock = i == 1 ? trades[0].stock : Stock(sId: i == 2 ? "DEMO2" : "DEMO1", sName: i == 2 ? "另一示例股" : "示例股",
                              group: "UI 測試", dateFirst: date, dateStart: date.addingTimeInterval(-200 * 86400),
                              simInvestAuto: 2, simMoneyBase: 100)
            stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
            stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
            if i != 1 { container.mainContext.insert(stock) }
            let t = Trade(stock: stock, dateTime: date)
            container.mainContext.insert(t)
            t.dataSource = "TWSE"; t.priceClose = i == 1 ? 117 : 111
            t.priceHigh = i == 1 ? 118 : 115; t.priceLow = 109; t.tMa60 = 110.2
            t.rollRounds = 4; t.rollDays = 200
            t.rollAmtRoi = i == 2 ? -12 : 20.5
            t.rollAmtProfit = i == 2 ? -230000 : 1234567
            t.simFitObservationCount = 180
            t.simFitFast = 41.5; t.simFitSlow = 40.5; t.simFitTrend = 1
            t.simFitTrendPhaseRaw = StrategyFitTrendPhase.improvingConfirmedSeekingPeak.rawValue
            t.simFitTrendPhaseExtreme = 1.1
            t.simInvestTimes = 2
            t.applyPricePathState(.init(phase: i == 1 ? .seekingPeakLate : .pullingBackLate,
                                       barrier: 0.08, anchorClose: 100, extremeClose: 120, daysSinceExtreme: 2))
            trades.append(t)
            let m = MarketDay(dateTime: date, indexOpen: 21000, indexHigh: 22000, indexLow: 20900, indexClose: 21100)
            m.technicalStateVersion = MarketDataStore.technicalStateVersion
            m.applyPricePathState(.init(phase: .pullingBackLate, barrier: 0.05, anchorClose: 20000, extremeClose: 22000, daysSinceExtreme: 2))
            if i != 2 { container.mainContext.insert(m) }
            markets.append(m)
        }
        // Active bottom prewarnings must agree with the displayed price phase;
        // grace-period examples deliberately retain a past cause after recovery.
        if ProcessInfo.processInfo.arguments.contains("--warning-preview-3")
            || ProcessInfo.processInfo.arguments.contains("--warning-preview-4") {
            for t in trades {
                t.applyPricePathState(.init(phase: .seekingBottomEarly, barrier: 0.08,
                    anchorClose: 120, extremeClose: t.priceClose, daysSinceExtreme: 0))
            }
        }
        try! container.mainContext.save()
        self.trades = trades
        self.markets = markets
    }

    var body: some View {
        if let warningCase {
            VStack {
                Text("隔離警示解說・示意數值")
                Text("警示範例 \(warningCase)")
                    .popover(isPresented: .constant(true)) {
                        TrueAnnualReturnWarningDetails(snapshot: previewWarning, trade: trades[warningCase % 3])
                            .presentationCompactAdaptation(.popover)
                    }
            }.modelContainer(container)
        } else if ProcessInfo.processInfo.arguments.contains("--icon-real-list") {
            SimStockRootView(modelContainer: container, isReadOnlySnapshot: true)
        } else {
            componentPreview
        }
    }

    @ViewBuilder
    private var componentPreview: some View {
        let t = trades[selection]
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("隔離 UI 測試・示意數值").foregroundStyle(.secondary)
                    Picker("股票與日期", selection: $selection) {
                        Text("示例股 10/06").tag(0)
                        Text("示例股 10/05").tag(1)
                        Text("另一示例股 10/06").tag(2)
                    }
                    .pickerStyle(.menu)
                    Toggle("窄欄", isOn: $narrow)
                    Text(t.explanationContext)
                    HStack(spacing: 24) {
                        GradeTrendIcons(trade: t, showsExplanation: true)
                        PricePathTrendIcon(phase: t.pricePathPhase, gray: false, explanation: t.pricePathExplanation, size: 24)
                        PricePathTrendIcon(phase: markets[selection].pricePathPhase, gray: false, explanation: .market(markets[selection]), size: 24)
                    }
                    Text("評等 · 評等趨勢 · 個股價格 · 大盤價格").font(.caption)
                    HStack(spacing: 24) {
                        TrueAnnualReturnWarningIcon(snapshot: previewWarning, trade: t, size: 24, showsExplanation: true)
                        Image(systemName: "arrow.up.to.line").accessibilityLabel("漲停")
                        Image(systemName: "circle").explainedAction(t.reversalExplanation) { actionCount += 1 }
                        Image(systemName: "plus.circle").explainedAction(t.investmentExplanation) { actionCount += 1 }
                        Image(systemName: "wrench").explainedAction(.stockSettings(t.stock)) { actionCount += 1 }
                    }
                    Text("警示 · 漲停 · 反轉 · 加碼 · 設定").font(.caption)
                    Text("操作點按次數 \(actionCount)")
                }
                .frame(maxWidth: narrow ? 320 : 650, alignment: .leading)
                .padding(24)
                .id(selection)
            }
            .navigationTitle("圖示解說驗收")
        }
        .modelContainer(container)
    }
}
#endif
