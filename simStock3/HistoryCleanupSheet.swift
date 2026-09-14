import SwiftUI
import SwiftData

struct HistoryCleanupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var ui: uiObject
    @State private var candidates: [StockHistory.Candidate] = []
    @State private var selection: Set<String> = []
    @State private var confirming = false
    @State private var message: String?

    private var selected: [StockHistory.Candidate] { candidates.filter { selection.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Section { Text(message).accessibilityIdentifier("history-cleanup-result") }
                }
                Group {
                    Section {
                        Text("選擇要清理的股票。仍在股群的股票會保留目前模擬及前一年技術準備期（含完整起始月份），其餘較早資料才可清除。")
                        Text("清除包含所選範圍的歷史價格、計算結果、手動反轉與加碼。日後需要時會重新下載及計算，舊人工操作不會恢復。")
                    }
                    if candidates.isEmpty {
                        ContentUnavailableView("沒有可清理的歷史資料", systemImage: "checkmark.circle")
                    } else {
                        Section {
                            HStack {
                                Text("已選 \(selection.count)／\(candidates.count) 檔")
                                Spacer()
                                Button(selection.count == candidates.count ? "取消全選" : "全選") {
                                    selection = selection.count == candidates.count ? [] : Set(candidates.map(\.id))
                                }
                                .disabled(ui.isTradeOperationLocked)
                                .accessibilityIdentifier("history-select-all")
                            }
                        }
                        candidateSection("未加入股群", ungrouped: true)
                        candidateSection("超出目前所需期間", ungrouped: false)
                    }
                }
            }
            .navigationTitle("清理歷史資料")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !candidates.isEmpty {
                    Button("清除所選 \(selection.count) 檔", role: .destructive) { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(selection.isEmpty || ui.isTradeOperationLocked)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
            .alert("清除所選歷史資料？", isPresented: $confirming) {
                Button("取消", role: .cancel) {}
                Button("清除 \(selected.count) 檔", role: .destructive) { clean() }
            } message: {
                Text("將清除 \(selected.count) 檔、\(selected.reduce(0) { $0 + $1.count }) 筆歷史資料，連同該範圍的手動反轉與加碼一起清除。此操作無法復原；仍在股群的股票會完整重算，保留並重驗有效期間內的人工操作。")
            }
            .task { load() }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func candidateSection(_ title: String, ungrouped: Bool) -> some View {
        let rows = candidates.filter { $0.isUngrouped == ungrouped }
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    Button {
                        if !selection.insert(row.id).inserted { selection.remove(row.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selection.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(row.id) ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(row.id) \(row.name)").font(.headline)
                                Text("\(twDateTime.stringFromDate(row.first)) ～ \(twDateTime.stringFromDate(row.last))")
                                Text("\(row.count) 筆歷史資料")
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(ui.isTradeOperationLocked)
                    .accessibilityAddTraits(selection.contains(row.id) ? .isSelected : [])
                }
            }
        }
    }

    private func load() {
        do {
            candidates = try StockHistory.candidates(in: context)
            selection = selection.intersection(Set(candidates.map(\.id)))
        } catch { message = "無法讀取歷史資料：\(error.localizedDescription)" }
    }

    private func clean() {
        do {
            try ui.requestHistoryCleanup(selected)
            dismiss()
        } catch {
            message = error.localizedDescription
            load()
        }
    }
}

#if DEBUG
struct HistoryRebuildPreview: View {
    @State private var container: ModelContainer
    @StateObject private var ui: uiObject

    init(settings: Bool = false, cleanup: Bool = false, cleaning: Bool = false) {
        let container = try! ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let stock = Stock(sId: "1101", sName: "測試股票", group: "測試股群",
            dateFirst: twDateTime.dateFromString("2023/01/01")!,
            dateStart: twDateTime.dateFromString("2024/01/01")!)
        container.mainContext.insert(stock)
        if cleanup {
            for day in ["2020/01/01", "2025/01/01"] {
                let trade = Trade(stock: stock, dateTime: twDateTime.time1330(twDateTime.dateFromString(day)!))
                trade.priceClose = 100
                container.mainContext.insert(trade)
            }
        }
        stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
        stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
        if !settings || cleaning { StockHistory.invalidate(stock) }
        if cleaning {
            let other = Stock(sId: "2330", sName: "保留股票", group: "測試股群",
                dateFirst: stock.dateFirst, dateStart: stock.dateStart)
            other.technicalStateVersion = stock.technicalStateVersion
            other.simulationStateVersion = stock.simulationStateVersion
            container.mainContext.insert(other)
            let trade = Trade(stock: other, dateTime: twDateTime.time1330(twDateTime.dateFromString("2025/01/01")!))
            trade.priceClose = 200
            container.mainContext.insert(trade)
        }
        try! container.mainContext.save()
        let ui = uiObject(modelContext: container.mainContext, isReadOnlySnapshot: !settings)
        ui.previewsHistorySettings = settings
        if cleaning { ui.previewHistoryCleanupProgress() }
        if !settings {
            ui.previewHistoryRecalculationProgress()
        }
        _container = State(initialValue: container)
        _ui = StateObject(wrappedValue: ui)
    }

    var body: some View {
        viewList()
            .environmentObject(ui)
            .modelContainer(container)
    }
}

struct HistoryCleanupPreview: View {
    @State private var container: ModelContainer
    @StateObject private var ui: uiObject
    @State private var presented = true

    init() {
        let container = try! ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        for (code, name, group) in [("1101", "測試甲", ""), ("2330", "測試乙", "測試股群")] {
            let stock = Stock(sId: code, sName: name, group: group,
                dateFirst: twDateTime.dateFromString("2020/01/01")!,
                dateStart: twDateTime.dateFromString("2024/07/15")!)
            container.mainContext.insert(stock)
            for value in ["2020/01/01", "2023/06/30", "2023/07/01", "2025/01/01"] {
                let trade = Trade(stock: stock, dateTime: twDateTime.time1330(twDateTime.dateFromString(value)!))
                trade.priceClose = 100
                if value == "2020/01/01" { trade.simReversed = "B+" }
                container.mainContext.insert(trade)
            }
        }
        try! container.mainContext.save()
        let ui = uiObject(modelContext: container.mainContext)
        NotificationCenter.default.removeObserver(ui)
        _container = State(initialValue: container)
        _ui = StateObject(wrappedValue: ui)
    }

    var body: some View {
        Button("開啟清理頁") { presented = true }
            .sheet(isPresented: $presented, onDismiss: ui.historyCleanupDidDismiss) {
                HistoryCleanupSheet().environmentObject(ui)
                    .onAppear { ui.historyCleanupWillPresent() }
            }
            .modelContainer(container)
    }
}
#endif
