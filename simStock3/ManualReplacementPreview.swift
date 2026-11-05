#if DEBUG
import SwiftUI
import Combine
import SwiftData

/// Disposable, in-memory fixture for tapping the production trade row.
/// It never opens the normal store or starts the foreground price pipeline.
@MainActor
private final class ManualReplacementFixture: ObservableObject {
    final class Probe: ObservableObject {
        @Published var attempts = 0
        @Published var saved = false
    }
    private enum Failure: Error { case injected }
    let container: ModelContainer
    let stock: Stock
    let row: Trade
    let later: Trade
    let ui: uiObject
    let probe: Probe

    init() {
        do {
            let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            let c = container.mainContext
            c.autosaveEnabled = false
            let first = twDateTime.dateFromString("2024/01/02")!
            let dates = (0..<30).map { index in
                twDateTime.time1330(twDateTime.calendar.date(byAdding: .day,
                    value: index < 10 ? index * 366 / 10 : 366 + index - 10, to: first)!)
            }
            let marketDates = dates + (1...249).map {
                twDateTime.calendar.date(byAdding: .day, value: -$0, to: first)!
            }
            let market = MarketDataStore(modelContext: c)
            _ = try market.applyOfficialRecords(marketDates.map {
                MarketDataStore.Record(date: $0, open: 10_000, high: 11_000, low: 9_000, close: 10_000)
            })
            try market.rebuildPricePath()
            let stock = Stock(sId: "UITEST", sName: "隔離操作測試", group: "測試",
                dateFirst: first, dateStart: dates[10], simInvestAuto: 2, simMoneyBase: 100)
            c.insert(stock)
            let rows = dates.enumerated().map { index, date in
                let row = Trade(stock: stock, dateTime: date)
                row.priceClose = 100 + Double(index) * 0.2
                row.priceOpen = row.priceClose; row.priceHigh = row.priceClose + 1
                row.priceLow = row.priceClose - 1; row.volumeClose = 1_000; row.dataSource = "TWSE"
                c.insert(row)
                return row
            }
            try c.save()
            let ui = uiObject(modelContext: c)
            NotificationCenter.default.removeObserver(ui)
            _ = try ui.sim.tech.recalculate(stock: stock,
                plan: .init(technical: .all, simulation: .all, resetDerivedSimulationState: true))
            rows[15].simInvestAdded = 0
            rows[20].simInvestByUser = 1
            stock.rebuildUserActionSummary(from: rows)
            try c.save()
            let probe = Probe()
            let fails = ProcessInfo.processInfo.arguments.contains("--manual-save-failure")
            ui.sim.simulationInputs.save = {
                probe.attempts += 1
                if fails { throw Failure.injected }
                try c.save()
                probe.saved = true
            }
            self.container = container; self.stock = stock
            row = rows[15]; later = rows[20]
            self.ui = ui; self.probe = probe
        } catch { fatalError("Isolated manual fixture failed: \(error)") }
    }

}

@MainActor
struct ManualReplacementPreview: View {
    @StateObject private var fixture = ManualReplacementFixture()
    var body: some View { ManualReplacementPreviewContent(fixture: fixture) }
}

@MainActor
private struct ManualReplacementPreviewContent: View {
    let fixture: ManualReplacementFixture
    @ObservedObject var ui: uiObject
    @ObservedObject var probe: ManualReplacementFixture.Probe
    init(fixture: ManualReplacementFixture) {
        self.fixture = fixture; ui = fixture.ui; probe = fixture.probe
    }
    private var row: Trade { fixture.row }
    private var stock: Stock { fixture.stock }
    private var later: Trade { fixture.later }
    private var container: ModelContainer { fixture.container }

    var body: some View {
        VStack {
            Text("隔離 UI 操作測試")
            GeometryReader { geometry in
                tradeCell(stock: .constant(stock), trade: row, annualWarning: row.storedAnnualWarning,
                    technicalSelected: false, hidesSummaryIcons: false, hidesTrendIcons: false,
                    onTechnicalSelect: {}, geometry: geometry)
            }.frame(height: 280)
            Text("attempts=\(probe.attempts);saved=\(probe.saved);later=\(Int(later.simInvestByUser))")
                .accessibilityIdentifier("manualProbe")
            Text(ui.simulationStatusMessage).accessibilityIdentifier("manualStatus")
        }
        .frame(width: ProcessInfo.processInfo.arguments.contains("--manual-compact") ? 350 : nil)
        .environment(\.dynamicTypeSize,
            ProcessInfo.processInfo.arguments.contains("--manual-compact") ? .xxxLarge : .large)
        .padding()
        .environmentObject(ui)
        .modelContainer(container)
    }
}
#endif
