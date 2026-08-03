//
//  simStockListView.swift
//  simStock21
//
//  Created by peiyu on 2020/6/24.
//  Copyright © 2020 peiyu. All rights reserved.
//  

/*
import SwiftUI
import SwiftData
*/

//final class LocalTechnicalService: TechnicalService {
//    var progressTWSE: Int?
//    var countTWSE: Int?
//    var errorTWSE: Int = 0
//    func twseRequest(stock: Stock, dateStart: Date, stockGroup: DispatchGroup) {
//        // TODO: Replace with real implementation. For now, simulate an async completion.
//        simLog.addLog("[LocalTechnicalService] twseRequest for \(stock.sId) from \(twDateTime.stringFromDate(dateStart, format: "yyyy/MM/dd"))")
//        stockGroup.leave()
//    }
//}


import SwiftUI
import SwiftData

struct viewList: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var ui: uiObject

    @Query(
        sort: [
            SortDescriptor(\Stock.group, order: .forward),
            SortDescriptor(\Stock.sName, order: .forward)
        ]
    )
    private var stocks: [Stock]

    @State private var didStartTWSEUpdate = false
    @State private var didEnterBackground = false
    @State private var isSelecting = false
    @State private var selectedStocks: [Stock] = []
    @State private var stockPendingRemoval: Stock?
    @State private var isShowingGroupEditor = false
    @State private var isShowingSimulationSettings = false
    @State private var priceUpdateIsRunning = false
    @State private var priceUpdateStatusMessage = ""
    @State private var selectedStockID: String?
    @State private var singleColumnPath: [String] = []
    @State private var pageShowsTechnical = false
    @State private var pageTechnicalDate: Date?
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var catalogSearchText = ""
    @State private var isCatalogSearchPresented = false
    @State private var isCatalogSearchDismissalRequested = false
    @State private var didInitializeCatalogSearch = false
    @State private var shouldResumeCatalogSearchAfterGroupEditor = false
    @State private var pendingCatalogDownloadStockIDs: Set<String> = []
    @State private var pendingCatalogDownloadTask: Task<Void, Never>?
    @State private var catalogSearchRefocusTask: Task<Void, Never>?
    @FocusState private var isCatalogSearchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            Group {
                if usesSplitLayout(in: geometry.size) {
                    splitLayout(compactLandscape: geometry.size.width < 1_200)
                } else {
                    singleColumnLayout
                }
            }
        }
        .task(id: stocks.count) {
            guard !ui.isReadOnlySnapshot else { return }
            ui.updateStockCatalogIfNeeded()
            guard !didStartTWSEUpdate, !selectableStocks.isEmpty else { return }

            didStartTWSEUpdate = true
            startTWSEUpdate(deferWhileSearching: true)
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
        .onReceive(ui.$isUpdatingPrices) { isUpdating in
            priceUpdateIsRunning = isUpdating
        }
        .onReceive(ui.$priceUpdateMessage) { message in
            priceUpdateStatusMessage = message
        }
        .onChange(of: ui.isTradeOperationLocked) { _, isLocked in
            if isLocked {
                stopCatalogSearchForTradeOperation()
            }
        }
        .sheet(
            isPresented: $isShowingGroupEditor,
            onDismiss: resumeCatalogSearchAfterGroupEditorIfNeeded
        ) {
            GroupCompositionSheet(
                stocks: selectedStocks,
                groups: groupedStocks.map(\.group),
                suggestedGroupName: ui.newGroupName,
                onMove: moveSelectedStocks,
                onRemove: removeSelectedStocks
            )
        }
        .sheet(isPresented: $isShowingSimulationSettings) {
            sheetListSetting(
                showSetting: $isShowingSimulationSettings,
                dateStart: defaults.start,
                moneyBase: defaults.money,
                autoInvest: defaults.invest,
                groups: groupedStocks.map(\.group)
            )
            .environmentObject(ui)
        }
        .alert(
            stockRemovalConfirmationTitle,
            isPresented: isShowingStockRemovalConfirmation
        ) {
            Button("移出股群", role: .destructive) {
                removePendingStockFromGroup()
            }
            Button("取消", role: .cancel) {
                stockPendingRemoval = nil
            }
        } message: {
            Text("移出後將停止自動更新與模擬計算；歷史股價仍會保留。之後可由搜尋重新加入。")
        }
    }

    private func usesSplitLayout(in size: CGSize) -> Bool {
        horizontalSizeClass == .regular
            // The software keyboard reduces the available height. Requiring a
            // clearly landscape-shaped window prevents a portrait iPad from
            // switching to two columns merely because search gained focus.
            && size.width >= size.height * 1.2
            && size.width >= 800
    }

    private var selectedStock: Stock? {
        guard let selectedStockID else { return nil }
        return selectableStocks.first { $0.sId == selectedStockID }
    }

    private var isShowingStockRemovalConfirmation: Binding<Bool> {
        Binding(
            get: { stockPendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    stockPendingRemoval = nil
                }
            }
        )
    }

    private var stockRemovalConfirmationTitle: String {
        guard let stockPendingRemoval else { return "移出股群？" }
        return "將\(stockPendingRemoval.sName)移出「\(stockPendingRemoval.group)」？"
    }

    private var singleColumnLayout: some View {
        NavigationStack(path: $singleColumnPath) {
            List {
                if !isCatalogSearchPresented {
                    ForEach(groupedStocks, id: \.group) { section in
                        Section(section.group) {
                            ForEach(section.stocks) { stock in
                                if isSelecting {
                                    Button {
                                        toggleSelection(of: stock)
                                    } label: {
                                        SelectableStockRow(stock: stock, isSelected: isSelected(stock))
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink(value: stock.sId) {
                                        StockRow(stock: stock)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        stockRemovalSwipeAction(for: stock)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Section("尚未加入股群的上市股票") {
                        if catalogSearchKeywords.isEmpty {
                            ContentUnavailableView(
                                "搜尋上市股票",
                                systemImage: "magnifyingglass",
                                description: Text("輸入股票代號或簡稱；空格與逗號可分隔多個條件。")
                            )
                        } else if catalogSearchResults.isEmpty {
                            if let stock = exactGroupedStockMatch {
                                ContentUnavailableView(
                                    "\(stock.sId) \(stock.sName)已在股群中",
                                    systemImage: "checkmark.circle",
                                    description: Text("目前位於「\(stock.group)」，不需重複加入。")
                                )
                            } else {
                                ContentUnavailableView(
                                    "查無符合的上市股票",
                                    systemImage: "magnifyingglass",
                                    description: Text("請嘗試輸入部分代號或簡稱。")
                                )
                            }
                        } else {
                            ForEach(catalogSearchResults) { stock in
                                Button {
                                    toggleSelection(of: stock)
                                } label: {
                                    CatalogSearchStockRow(
                                        stock: stock,
                                        isSelected: isSelected(stock)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .modifier(
                StockCatalogSearchModifier(
                    text: $catalogSearchText,
                    isPresented: $isCatalogSearchPresented,
                    isFocused: $isCatalogSearchFocused,
                    isEnabled: !ui.isTradeOperationLocked
                )
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                if isCatalogSearchPresented {
                    HStack {
                        Button("取消") {
                            dismissCatalogSearch()
                        }

                        Spacer()

                        if hasValidCatalogSelection {
                            Button("加入股群") {
                                isShowingGroupEditor = true
                            }
                            .fontWeight(.semibold)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.bar)
                    .overlay(alignment: .bottom) {
                        Divider()
                    }
                }
            }
            .onAppear {
                guard !didInitializeCatalogSearch else { return }
                didInitializeCatalogSearch = true
                isCatalogSearchFocused = false
                isCatalogSearchPresented = false
            }
            .onChange(of: isCatalogSearchPresented) { wasPresented, isPresented in
                if isPresented {
                    if !wasPresented {
                        ui.catalogSearchDidBegin()
                        selectedStocks.removeAll()
                        isSelecting = false
                    }
                    pendingCatalogDownloadTask?.cancel()
                    pendingCatalogDownloadTask = nil
                } else if wasPresented {
                    if isCatalogSearchDismissalRequested {
                        completeCatalogSearchDismissal()
                    } else if isCatalogSearchFocused
                                || isShowingGroupEditor
                                || shouldResumeCatalogSearchAfterGroupEditor {
                        // SwiftUI may set `isPresented` to false when the
                        // search field's clear button is tapped or while the
                        // group editor is being presented. Keep that workflow
                        // active, but do not let a stale refocus override a
                        // later explicit cancellation.
                        isCatalogSearchPresented = true
                        requestCatalogSearchFocus()
                    } else {
                        // The native searchable Cancel button does not pass
                        // through dismissCatalogSearch(). Once focus has
                        // actually left, treat it as a real dismissal.
                        completeCatalogSearchDismissal()
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if ui.isChangingSimulation || !ui.simulationStatusMessage.isEmpty {
                    SimulationStatusBar(
                        isRecalculating: ui.isChangingSimulation
                            || ui.isMigratingSimulationData,
                        message: ui.simulationStatusMessage
                    )
                } else if priceUpdateIsRunning || !priceUpdateStatusMessage.isEmpty {
                    PriceUpdateStatusBar(
                        isUpdating: priceUpdateIsRunning,
                        message: priceUpdateStatusMessage
                    )
                }
            }
            .navigationTitle(
                isSelecting || (isCatalogSearchPresented && hasValidCatalogSelection)
                    ? "已選 \(selectedStocks.count) 檔"
                    : ""
            )
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { stockID in
                if let stock = selectableStocks.first(where: { $0.sId == stockID }) {
                    viewPage(
                        stock: stock,
                        prefix: stock.prefix,
                        sharedTechnicalVisibility: $pageShowsTechnical,
                        sharedTechnicalDate: $pageTechnicalDate
                    )
                } else {
                    ContentUnavailableView(
                        "找不到股票",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .toolbar {
                stockListToolbar(showsSimulationSettings: true)
            }
        }
        .onChange(of: singleColumnPath) { _, path in
            if let stockID = path.last {
                selectedStockID = stockID
            }
        }
    }

    private func splitLayout(compactLandscape: Bool) -> some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $splitColumnVisibility) {
                List {
                    ForEach(groupedStocks, id: \.group) { section in
                        Section(section.group) {
                            ForEach(section.stocks) { stock in
                                if isSelecting {
                                    Button {
                                        toggleSelection(of: stock)
                                    } label: {
                                        SidebarSelectableStockRow(
                                            stock: stock,
                                            isSelected: isSelected(stock),
                                            usesCompactLayout: compactLandscape
                                        )
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button {
                                        selectStockForPage(stock.sId)
                                    } label: {
                                        SidebarStockRow(
                                            stock: stock,
                                            usesCompactLayout: compactLandscape
                                        )
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .listRowBackground(
                                        selectedStockID == stock.sId
                                            ? Color.accentColor.opacity(0.14)
                                            : Color.clear
                                    )
                                    .accessibilityValue(
                                        selectedStockID == stock.sId ? "已選取" : ""
                                    )
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        stockRemovalSwipeAction(for: stock)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .navigationSplitViewColumnWidth(
                    min: compactLandscape ? 240 : 300,
                    ideal: compactLandscape ? 260 : 340,
                    max: compactLandscape ? 285 : 390
                )
                .toolbar {
                    stockListToolbar(showsSimulationSettings: false)
                }
            } detail: {
                if let selectedStock {
                    viewPage(
                        stock: selectedStock,
                        prefix: selectedStock.prefix,
                        isSplitDetail: true,
                        showsPriceUpdateStatus: false,
                        sharedTechnicalVisibility: $pageShowsTechnical,
                        sharedTechnicalDate: $pageTechnicalDate
                    )
                    .id(selectedStock.sId)
                } else {
                    ContentUnavailableView(
                        "選擇股票",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("從左側股票清單選擇要查看的個股。")
                    )
                }
            }
            .navigationSplitViewStyle(.balanced)
            .onAppear {
                splitColumnVisibility = .all
                ensureSplitSelection()
            }
            .onChange(of: selectableStocks.map(\.sId)) { _, _ in
                ensureSplitSelection()
            }

            if ui.isChangingSimulation || !ui.simulationStatusMessage.isEmpty {
                SimulationStatusBar(
                    isRecalculating: ui.isChangingSimulation
                        || ui.isMigratingSimulationData,
                    message: ui.simulationStatusMessage
                )
            } else if priceUpdateIsRunning || !priceUpdateStatusMessage.isEmpty {
                PriceUpdateStatusBar(
                    isUpdating: priceUpdateIsRunning,
                    message: priceUpdateStatusMessage
                )
            }
        }
    }

    @ToolbarContentBuilder
    private func stockListToolbar(showsSimulationSettings: Bool) -> some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") {
                    finishSelecting()
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(selectedStocks.count == selectableStocks.count ? "全不選" : "全選") {
                    if selectedStocks.count == selectableStocks.count {
                        selectedStocks.removeAll()
                    } else {
                        selectedStocks = selectableStocks
                    }
                }

                Button("修改股群") {
                    isShowingGroupEditor = true
                }
                .disabled(selectedStocks.isEmpty)
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if ui.isReadOnlySnapshot {
                    Label("回測快照", systemImage: "lock")
                        .foregroundStyle(.secondary)
                } else {
                    StockListToolbarActions(
                        ui: ui,
                        stocksEmpty: selectableStocks.isEmpty,
                        onSelect: { isSelecting = true },
                        onUpdate: { startTWSEUpdate() }
                    )

                    if showsSimulationSettings {
                        Button {
                            isShowingSimulationSettings = true
                        } label: {
                            Label("模擬設定", systemImage: "wrench")
                        }
                        .disabled(ui.isTradeOperationLocked)
                    }
                }
            }
        }
    }

    private func ensureSplitSelection() {
        if let selectedStockID,
           selectableStocks.contains(where: { $0.sId == selectedStockID }) {
            synchronizeSingleColumnPath(with: selectedStockID)
            return
        }
        if let stockID = ui.pageStock.flatMap({ pageStock in
            selectableStocks.first(where: { $0.sId == pageStock.sId })?.sId
        }) ?? selectableStocks.first?.sId {
            selectStockForPage(stockID)
        }
    }

    private func selectStockForPage(_ stockID: String) {
        selectedStockID = stockID
        synchronizeSingleColumnPath(with: stockID)
    }

    private func synchronizeSingleColumnPath(with stockID: String) {
        guard singleColumnPath != [stockID] else { return }
        singleColumnPath = [stockID]
    }
    private var selectableStocks: [Stock] {
        groupedStocks.flatMap(\.stocks)
    }

    private var groupedStocks: [(group: String, stocks: [Stock])] {
        Dictionary(grouping: stocks.filter { !$0.group.isEmpty }) { stock in
            stock.group
        }
        .map { key, value in
            (
                group: key,
                stocks: value.sorted {
                    if $0.sName == $1.sName {
                        return $0.sId < $1.sId
                    }
                    return $0.sName < $1.sName
                }
            )
        }
        .sorted { $0.group < $1.group }
    }

    private var catalogSearchResults: [Stock] {
        guard !catalogSearchKeywords.isEmpty else { return [] }
        return Array(
            stocks.lazy
                .filter {
                    $0.group.isEmpty
                        && $0.isListed
                        && StockCatalogSearch.matches(
                            code: $0.sId,
                            name: $0.sName,
                            keywords: catalogSearchKeywords
                        )
                }
                .sorted {
                    if $0.sId == $1.sId {
                        return $0.sName < $1.sName
                    }
                    return $0.sId < $1.sId
                }
                .prefix(50)
        )
    }

    private var catalogSearchKeywords: [String] {
        StockCatalogSearch.keywords(from: catalogSearchText)
    }

    private var hasValidCatalogSelection: Bool {
        isCatalogSearchPresented
            && !selectedStocks.isEmpty
            && selectedStocks.allSatisfy { $0.group.isEmpty && $0.isListed }
    }

    /// The legacy search only showed the "already in a group" hint when one
    /// search token exactly matched a grouped stock's full code or full name.
    /// Partial and multi-token searches remain ordinary no-result searches.
    private var exactGroupedStockMatch: Stock? {
        guard catalogSearchKeywords.count == 1,
              let keyword = catalogSearchKeywords.first else {
            return nil
        }
        return stocks.first {
            !$0.group.isEmpty
                && ($0.sId == keyword || $0.sName == keyword)
        }
    }

    private func isSelected(_ stock: Stock) -> Bool {
        selectedStocks.contains(stock)
    }

    @ViewBuilder
    private func stockRemovalSwipeAction(for stock: Stock) -> some View {
        if !ui.isReadOnlySnapshot
            && !ui.isTradeOperationLocked
            && !isSelecting
            && !isCatalogSearchPresented {
            Button {
                stockPendingRemoval = stock
            } label: {
                Label("移出", systemImage: "folder.badge.minus")
            }
            .tint(.orange)
            .accessibilityLabel("將\(stock.sName)移出股群")
        }
    }

    private func removePendingStockFromGroup() {
        guard let stock = stockPendingRemoval else { return }
        stockPendingRemoval = nil
        guard !ui.isReadOnlySnapshot,
              !ui.isTradeOperationLocked,
              !stock.group.isEmpty else {
            return
        }
        _ = ui.moveStocksToGroup([stock], group: "")
    }

    private func toggleSelection(of stock: Stock) {
        if isSelected(stock) {
            selectedStocks.removeAll { $0 == stock }
        } else {
            selectedStocks.append(stock)
        }
    }

    private func finishSelecting() {
        isShowingGroupEditor = false
        selectedStocks.removeAll()
        isSelecting = false
    }

    private func moveSelectedStocks(to group: String) {
        guard !ui.isReadOnlySnapshot else { return }
        guard !selectedStocks.isEmpty, !group.isEmpty else { return }
        let isAddingCatalogStocks = hasValidCatalogSelection
        let newlyAddedIDs = Set(
            selectedStocks.lazy
                .filter(\.group.isEmpty)
                .map(\.sId)
        )

        guard ui.moveStocksToGroup(
            selectedStocks,
            group: group,
            downloadNewStocks: !isAddingCatalogStocks
        ) else { return }
        isShowingGroupEditor = false

        if isAddingCatalogStocks {
            pendingCatalogDownloadStockIDs.formUnion(newlyAddedIDs)
            catalogSearchText = ""
            selectedStocks.removeAll()
            isSelecting = false
            shouldResumeCatalogSearchAfterGroupEditor = true
        } else {
            finishSelecting()
        }
    }

    private func resumeCatalogSearchAfterGroupEditorIfNeeded() {
        guard shouldResumeCatalogSearchAfterGroupEditor else { return }
        shouldResumeCatalogSearchAfterGroupEditor = false
        isCatalogSearchPresented = true
        requestCatalogSearchFocus()
    }

    private func removeSelectedStocks() {
        guard !ui.isReadOnlySnapshot else { return }
        guard !selectedStocks.isEmpty else { return }
        guard ui.moveStocksToGroup(selectedStocks, group: "") else { return }
        finishSelecting()
    }

    private func finishCatalogSearch() {
        catalogSearchText = ""
        selectedStocks.removeAll()
        isSelecting = false
        schedulePendingCatalogDownloads()
    }

    private func dismissCatalogSearch() {
        isCatalogSearchDismissalRequested = true
        catalogSearchRefocusTask?.cancel()
        catalogSearchRefocusTask = nil
        isCatalogSearchFocused = false
        if isCatalogSearchPresented {
            isCatalogSearchPresented = false
        } else {
            // Repeated sheet presentation can leave the searchable UI focused
            // while its isPresented binding is already false. In that state
            // another false assignment produces no onChange callback.
            completeCatalogSearchDismissal()
        }
    }

    private func stopCatalogSearchForTradeOperation() {
        guard isCatalogSearchPresented
                || isCatalogSearchFocused
                || isShowingGroupEditor
                || shouldResumeCatalogSearchAfterGroupEditor else {
            return
        }
        isShowingGroupEditor = false
        isCatalogSearchDismissalRequested = true
        catalogSearchRefocusTask?.cancel()
        catalogSearchRefocusTask = nil
        isCatalogSearchFocused = false
        if isCatalogSearchPresented {
            isCatalogSearchPresented = false
        } else {
            completeCatalogSearchDismissal()
        }
    }

    private func requestCatalogSearchFocus() {
        catalogSearchRefocusTask?.cancel()
        catalogSearchRefocusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  !isCatalogSearchDismissalRequested,
                  isCatalogSearchPresented else {
                return
            }
            isCatalogSearchFocused = true
            catalogSearchRefocusTask = nil
        }
    }

    private func completeCatalogSearchDismissal() {
        catalogSearchRefocusTask?.cancel()
        catalogSearchRefocusTask = nil
        shouldResumeCatalogSearchAfterGroupEditor = false
        isCatalogSearchDismissalRequested = false
        isCatalogSearchFocused = false
        finishCatalogSearch()
        ui.catalogSearchDidEnd()
    }

    private func schedulePendingCatalogDownloads() {
        pendingCatalogDownloadTask?.cancel()
        guard !pendingCatalogDownloadStockIDs.isEmpty else { return }

        pendingCatalogDownloadTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !isCatalogSearchPresented else { return }

            let stockIDs = pendingCatalogDownloadStockIDs
            pendingCatalogDownloadStockIDs.removeAll()
            pendingCatalogDownloadTask = nil
            let newStocks = selectableStocks.filter { stockIDs.contains($0.sId) }
            guard !newStocks.isEmpty else { return }
            if ui.isTradeOperationLocked {
                pendingCatalogDownloadStockIDs.formUnion(stockIDs)
                schedulePendingCatalogDownloads()
            } else {
                ui.startDailyPriceUpdate(stocks: newStocks)
            }
        }
    }

    @MainActor
    private func startTWSEUpdate(
        ensureFollowUpIfBusy: Bool = false,
        deferWhileSearching: Bool = false
    ) {
        guard !ui.isReadOnlySnapshot else { return }
        ui.startDailyPriceUpdate(
            stocks: selectableStocks,
            ensureFollowUpIfBusy: ensureFollowUpIfBusy,
            deferWhileSearching: deferWhileSearching
        )
    }

    @MainActor
    private func handleScenePhase(_ phase: ScenePhase) {
        guard !ui.isReadOnlySnapshot else { return }
        if phase == .background {
            didEnterBackground = true
            ui.cancelScheduledOfficialCloseUpdate()
        } else if phase == .active, didEnterBackground {
            didEnterBackground = false
            ui.updateStockCatalogIfNeeded()
            guard didStartTWSEUpdate, !selectableStocks.isEmpty else { return }
            startTWSEUpdate(
                ensureFollowUpIfBusy: true,
                deferWhileSearching: true
            )
        }
    }
}

private struct StockCatalogSearchModifier: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let isFocused: FocusState<Bool>.Binding
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(
                    text: $text,
                    isPresented: $isPresented,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "以代號或簡稱搜尋上市股票"
                )
                .searchFocused(isFocused)
        } else {
            content
        }
    }
}

private struct StockListToolbarActions: View {
    @ObservedObject var ui: uiObject
    let stocksEmpty: Bool
    let onSelect: () -> Void
    let onUpdate: () -> Void

    var body: some View {
        Group {
            Button("選取", action: onSelect)
                .disabled(ui.isTradeOperationLocked || stocksEmpty)

            Button("更新股價", action: onUpdate)
                .disabled(ui.isTradeOperationLocked || stocksEmpty)
        }
    }
}

struct PriceUpdateStatusBar: View {
    let isUpdating: Bool
    let message: String

    private var showsWarning: Bool {
        message.contains("部分")
            || message.contains("失敗")
            || message.contains("略過")
    }

    var body: some View {
        if isUpdating || !message.isEmpty {
            HStack(spacing: 12) {
                if isUpdating {
                    ProgressView()
                        .controlSize(.regular)
                } else {
                    Image(systemName: showsWarning ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(showsWarning ? .orange : .green)
                }

                Text(message)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        }
    }
}

struct SimulationStatusBar: View {
    let isRecalculating: Bool
    let message: String

    private var showsFailure: Bool {
        message.contains("失敗")
    }

    var body: some View {
        if isRecalculating || !message.isEmpty {
            HStack(spacing: 12) {
                if isRecalculating {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.blue)
                } else {
                    Image(systemName: showsFailure ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(showsFailure ? .orange : .blue)
                }

                Text(message)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        }
    }
}

private enum StockListColumnWidth {
    static let id: CGFloat = 64
    static let name: CGFloat = 100
    static let price: CGFloat = 126
    static let years: CGFloat = 82
    static let days: CGFloat = 82
    static let roi: CGFloat = 92
    static let baseRoi: CGFloat = 92
    static let grade: CGFloat = 40
    static let historyStatus: CGFloat = 32
}

private struct StockRowMetrics {
    let spacing: CGFloat
    let id: CGFloat
    let name: CGFloat
    let price: CGFloat
    let years: CGFloat
    let days: CGFloat
    let roi: CGFloat
    let baseRoi: CGFloat
    let grade: CGFloat
    let historyStatus: CGFloat

    static let regular = StockRowMetrics(
        spacing: 12,
        id: StockListColumnWidth.id,
        name: StockListColumnWidth.name,
        price: StockListColumnWidth.price,
        years: StockListColumnWidth.years,
        days: StockListColumnWidth.days,
        roi: StockListColumnWidth.roi,
        baseRoi: StockListColumnWidth.baseRoi,
        grade: StockListColumnWidth.grade,
        historyStatus: StockListColumnWidth.historyStatus
    )

    static let compact = StockRowMetrics(
        spacing: 8,
        id: 44,
        name: 72,
        price: 106,
        years: 54,
        days: 54,
        roi: 64,
        baseRoi: 64,
        grade: 28,
        historyStatus: 20
    )
}

private struct StockRow: View {
    @Environment(\.modelContext) private var modelContext
    let stock: Stock

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(metrics: .regular)
            row(metrics: .compact)
        }
        .font(.body)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func row(metrics: StockRowMetrics) -> some View {
        HStack(spacing: metrics.spacing) {
            Text(stock.sId)
                .frame(width: metrics.id, alignment: .leading)

            Text(stock.sName)
                .frame(width: metrics.name, alignment: .leading)

            if let trade = try? stock.lastTrade(in: modelContext) {
                PriceBadge(trade: trade, width: metrics.price)

                metric(String(format: "%.1f年", stock.years), width: metrics.years)
                metric(
                    trade.days > 0 ? String(format: "%.0f天", trade.days) : "—",
                    width: metrics.days,
                    emphasized: stock.hasReversedTrade,
                    accessibilityHint: stock.hasReversedTrade ? "包含反轉買賣" : nil
                )
                metric(
                    trade.days > 0 ? String(format: "%.1f%%", trade.roi) : "—",
                    width: metrics.roi,
                    emphasized: stock.hasManualInvestAdjustment,
                    accessibilityHint: stock.hasManualInvestAdjustment ? "包含手動加碼" : nil
                )
                metric(trade.days > 0 ? String(format: "%.1f%%", trade.baseRoi) : "—", width: metrics.baseRoi, secondary: true)

                trade.gradeIcon()
                    .frame(width: metrics.grade, alignment: .center)
                    .accessibilityLabel("選股評等")
            } else {
                Text("無資料")
                    .foregroundStyle(.secondary)
                    .frame(
                        width: metrics.price
                            + metrics.years
                            + metrics.days
                            + metrics.roi
                            + metrics.baseRoi
                            + metrics.grade
                            + metrics.spacing * 5,
                        alignment: .leading
                    )
            }

            if stock.needsTWSEHistoryBackfill(in: modelContext) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: metrics.historyStatus, alignment: .center)
                    .help("歷史價格尚未補齊")
                    .accessibilityLabel("歷史價格尚未補齊")
            } else {
                Color.clear
                    .frame(width: metrics.historyStatus)
                    .accessibilityHidden(true)
            }
        }
    }

    private func metric(
        _ text: String,
        width: CGFloat,
        secondary: Bool = false,
        emphasized: Bool = false,
        accessibilityHint: String? = nil
    ) -> some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(
                emphasized
                    ? AnyShapeStyle(.orange)
                    : secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
            )
            .frame(width: width, alignment: .trailing)
            .accessibilityHint(accessibilityHint ?? "")
    }
}

private struct SelectableStockRow: View {
    let stock: Stock
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            StockRow(stock: stock)
        }
    }
}

private struct CatalogSearchStockRow: View {
    let stock: Stock
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            Text(stock.sId)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(stock.sName)
                .foregroundStyle(.primary)

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stock.sId) \(stock.sName)")
        .accessibilityValue(isSelected ? "已選取" : "未選取")
    }
}

private struct SidebarStockRow: View {
    @Environment(\.modelContext) private var modelContext
    let stock: Stock
    let usesCompactLayout: Bool

    var body: some View {
        HStack(spacing: usesCompactLayout ? 6 : 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(stock.sName)
                    .font(.body.weight(.medium))
                Text(stock.sId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .layoutPriority(1)

            Spacer(minLength: usesCompactLayout ? 2 : 8)

            if let trade = try? stock.lastTrade(in: modelContext) {
                Text(String(format: "%.2f", trade.priceClose))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(trade.color(.price))
                    .padding(.horizontal, usesCompactLayout ? 6 : 10)
                    .frame(
                        minWidth: usesCompactLayout ? 74 : 88,
                        minHeight: usesCompactLayout ? 28 : 30
                    )
                    .background {
                        Capsule().fill(trade.color(.ruleB))
                    }
                    .overlay {
                        Capsule().stroke(trade.color(.ruleR), lineWidth: 1)
                    }

                trade.gradeIcon()
                    .frame(width: usesCompactLayout ? 20 : 24)
                    .accessibilityLabel("選股評等")
            } else {
                Text("無資料")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if stock.needsTWSEHistoryBackfill(in: modelContext) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("歷史價格尚未補齊")
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stock.sId) \(stock.sName)")
    }
}

private struct SidebarSelectableStockRow: View {
    let stock: Stock
    let isSelected: Bool
    let usesCompactLayout: Bool

    var body: some View {
        HStack(spacing: usesCompactLayout ? 6 : 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            SidebarStockRow(stock: stock, usesCompactLayout: usesCompactLayout)
        }
    }
}

private struct PriceBadge: View {
    let trade: Trade
    let width: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text(String(format: "%.2f", trade.priceClose))
                .monospacedDigit()

            if trade.tLowDiff == 10 && trade.priceClose == trade.priceLow {
                Image(systemName: "arrow.down.to.line")
            } else if trade.tHighDiff == 10 && trade.priceClose == trade.priceHigh {
                Image(systemName: "arrow.up.to.line")
            }
        }
        .frame(width: width, height: 30, alignment: .center)
        .foregroundStyle(trade.color(.price))
        .background {
            RoundedRectangle(cornerRadius: 15)
                .fill(trade.color(.ruleB))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(trade.color(.ruleR), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("最新成交價")
        .accessibilityValue(String(format: "%.2f", trade.priceClose))
    }
}

private struct GroupCompositionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let stocks: [Stock]
    let groups: [String]
    let suggestedGroupName: String
    let onMove: (String) -> Void
    let onRemove: () -> Void

    @State private var newGroupName = ""
    @State private var isShowingRemoveConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("已選取") {
                    Text(stockSummary)
                }

                Section("移動到既有股群") {
                    ForEach(groups, id: \.self) { group in
                        Button {
                            onMove(group)
                        } label: {
                            HStack {
                                Text(group)
                                Spacer()
                                if allStocksAreIn(group) {
                                    Text("目前所在")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(allStocksAreIn(group))
                    }
                }

                Section("建立新股群") {
                    TextField(suggestedGroupName, text: $newGroupName)

                    Button("建立並移入") {
                        onMove(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if stocks.contains(where: { !$0.group.isEmpty }) {
                    Section {
                        Button("從股群移除", role: .destructive) {
                            isShowingRemoveConfirmation = true
                        }
                    } footer: {
                        Text("只停止更新與計算；既有歷史價格仍會保留。")
                    }
                }
            }
            .navigationTitle(
                stocks.allSatisfy(\.group.isEmpty) ? "加入股群" : "修改股群組成"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .alert("從股群移除？", isPresented: $isShowingRemoveConfirmation) {
                Button("取消", role: .cancel) {}
                Button("移除", role: .destructive) {
                    onRemove()
                }
            } message: {
                Text("將移除 \(stocks.count) 檔股票。歷史價格不會刪除。")
            }
            .onAppear {
                if newGroupName.isEmpty {
                    newGroupName = suggestedGroupName
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var stockSummary: String {
        stocks.map { "\($0.sId) \($0.sName)" }.joined(separator: "、")
    }

    private func allStocksAreIn(_ group: String) -> Bool {
        !stocks.isEmpty && stocks.allSatisfy { $0.group == group }
    }
}

/*
struct viewList: View {
    @Environment(\.horizontalSizeClass) var hClass
    @Environment(\.modelContext) private var context
    @StateObject private var ui: uiObject

    @State var isChoosing = false           //進入了選取模式
    @State var isSearching:Bool = false     //進入了搜尋模式
    @State var checkedStocks: [Stock] = []  //已選取的股票們
    @State var editText:String = ""         //輸入的搜尋文字
    @State var stock0:Stock?                //預設已選取的股

    init() {
        // Always create a fallback in-memory ModelContext for initialization.
        // This avoids using Environment values in init and keeps previews/builds stable.
        let container: ModelContainer
        do {
            let schema = Schema([Stock.self, Trade.self])
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            container = try! ModelContainer(for: Schema([]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        let ctx = ModelContext(container)
        _ui = StateObject(wrappedValue: uiObject(modelContext: ctx))
    }

    func sectionHeader(_ stocks:[Stock]) -> some View {
        HStack {
            if isChoosing {
                groupCheckbox(stocks: stocks, checkedStocks: self.$checkedStocks)
            }
            Text((stocks[0].group == "" ? "<搜尋結果>" : "[\(stocks[0].group)]"))
                .font(.headline)
        }
    }
    
    func sectionFooter(_ stocks:[Stock]) -> some View {
        Text(ui.stocksSummary(stocks))
    }

    @ViewBuilder
    private func buildRow(g: GeometryProxy, stock: Stock) -> some View {
        let rowContent = {
            stockCell(
                hClass: _hClass,
                isChoosing: self.$isChoosing,
                isSearching: self.$isSearching,
                checkedStocks: self.$checkedStocks,
                prefix: "",
                geometry: g,
                stock: stock
            )
        }

        if stock.group != "" && !isChoosing && !isSearching {
            // Use modern NavigationLink(destination:label:) to navigate on tap
            NavigationLink(destination: {
                viewPage(stock: stock, prefix: stock.prefix)
            }) {
                rowContent()
            }
        } else {
            // When choosing or searching, just show the row without navigation
            HStack {
                rowContent()
            }
        }
    }

    @ViewBuilder
    private func buildSection(g: GeometryProxy, stocks: [Stock]) -> some View {
        Section(header: sectionHeader(stocks), footer: sectionFooter(stocks)) {
            ForEach(stocks, id: \.self) { (stock: Stock) in
                buildRow(g: g, stock: stock)
            }
            .onDelete { indexSet in
                let s = indexSet.map { stocks[$0] }
                self.ui.moveStocksToGroup(s)
            }
        }
        .deleteDisabled(isSearching || isChoosing || ui.isTradeOperationLocked)
        .onAppear {
            if ui.doubleColumn {
                if let pageStock = ui.pageStock {
                    self.stock0 = pageStock
                } else if let first = ui.groupStocks.first?.first {
                    self.stock0 = first
                }
            }
        }
    }

    @ViewBuilder
    private func buildList(geometry: GeometryProxy) -> some View {
        ScrollViewReader { sv in
            GeometryReader { g in
                List {
                    ForEach(ui.groupStocks, id: \.self) { (stocks: [Stock]) in
                        buildSection(g: g, stocks: stocks)
                    }
                }
                .listStyle(GroupedListStyle())
                .onChange(of: isSearching) { _, _ in
                    if ui.groupStocks.count > 0 {
                        sv.scrollTo(ui.groupStocks[0])
                    }
                }
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                VStack(alignment: .leading) {
                    Spacer()
                    SearchBar(editText: self.$editText, isSearching: self.$isSearching)
                        .disabled(self.isChoosing || ui.isTradeOperationLocked)
                    Spacer()
                    buildList(geometry: geometry)
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        HStack {
                            chooseCommand(isChoosing: self.$isChoosing, isSearching: self.$isSearching, checkedStocks: self.$checkedStocks, searchText: self.$editText, geometry: geometry)
                            listTools(isChoosing: self.$isChoosing, isSearching: self.$isSearching, checkedStocks: self.$checkedStocks, searchText: self.$editText)
                        }
                    }
                }
            }
            .environmentObject(ui)
        }
    }
}
 */

struct groupCheckbox: View {
    @State var isChecked:Bool = false
    @State var stocks : [Stock]
    @Binding var checkedStocks:[Stock]
    
    
    private func checkGroup() {
        self.isChecked = !self.isChecked
        if self.isChecked {
            self.checkedStocks += stocks
        } else {
            self.checkedStocks = self.checkedStocks.filter{!stocks.contains($0)}
        }
    }

    var body: some View {
        Group {
            Button(action: checkGroup) {
                Image(systemName: isChecked ? "checkmark.square" : "square")
            }
        }
    }
}


struct stockCell : View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Environment(\.modelContext) private var context
    @Binding var isChoosing:Bool
    @Binding var isSearching:Bool
    @Binding var checkedStocks:[Stock]
    @State   var prefix:String = ""
    @State   var geometry:GeometryProxy
    let stock: Stock

    private func checkStock() {
        if self.checkedStocks.contains(self.stock) {
            self.checkedStocks.removeAll(where: {$0 == stock})
        } else {
            self.checkedStocks.append(stock)
        }
    }
    
    private func cgWidth(_ CG:[CGFloat]) -> CGFloat {
        let base = ui.doubleColumn ? CG[0] : ui.widthCG(hClass, CG: CG)
        let w = base * geometry.size.width / 100
        return min(w, 90)
    }

    
    var body: some View {
        let showCheckbox = isChoosing || (isSearching && stock.group == "")
        let idWidth: CGFloat = (isSearching && stock.group == "") ? 100 : cgWidth([20,10])
        let nameWidth: CGFloat = (isSearching && stock.group == "") ? 100 : cgWidth([30,12])
        let isGray = ui.isTradeOperationLocked || ((isChoosing || isSearching) && !self.checkedStocks.contains(self.stock))
        let finalColor: Color = self.checkedStocks.contains(stock) ? .orange : ((isSearching && stock.group != "") ? .gray : .primary)
        let font: Font = (ui.widthClass(hClass) == .compact) ? .callout : .body

        return HStack {
            if showCheckbox {
                Button(action: checkStock) {
                    Image(systemName: self.checkedStocks.contains(self.stock) ? "checkmark.square" : "square")
                }
            }
            Group {
                Text(stock.sId)
                    .frame(width: idWidth, alignment: .leading)
                    .lineLimit(stock.sId.count > 4 ? 2 : 1)
                Text(stock.sName)
                    .frame(width: nameWidth, alignment: .leading)
                    .lineLimit(stock.sName.count > 4 ? 2 : 1)
            }
            .foregroundColor(isGray ? .gray : .primary)
            if stock.group != "", let trade = try? stock.lastTrade(in: context) {
                let priceColor = trade.color(.price, gray: (isChoosing || isSearching))
                let ruleBColor = trade.color(.ruleB, gray: (isChoosing || isSearching))
                let ruleRColor = trade.color(.ruleR, gray: (isSearching))
                Group {
                    HStack (spacing: 2) {
                        Text(" ")
                        Text(String(format: "%.2f", trade.priceClose))
                        if trade.tLowDiff == 10 && trade.priceClose == trade.priceLow {
                            Image(systemName: "arrow.down.to.line")
                        } else if trade.tHighDiff == 10 && trade.priceClose == trade.priceHigh {
                            Image(systemName: "arrow.up.to.line")
                        } else {
                            Text("  ")
                        }
                    }
                    .frame(width: cgWidth([30,12]), alignment: .center)
                    .foregroundColor(priceColor)
                    .background(RoundedRectangle(cornerRadius: 20).fill(ruleBColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(ruleRColor, lineWidth: 1)
                    )
                    if ui.widthClass(hClass) > .compact && !ui.doubleColumn {
                        Text(trade.simQty.action)
                            .frame(width: cgWidth([6]), alignment: .trailing)
                            .foregroundColor(trade.color(.qty, gray: (isSearching)))
                        Text(trade.simQty.qty > 0 ? String(format: "%.f", trade.simQty.qty) : "")
                            .frame(width: cgWidth([6.5]), alignment: .center)
                            .foregroundColor(trade.color(.qty, gray: (isSearching)))
                        Text(String(format: "%.1f年", stock.years))
                            .frame(width: cgWidth([7.5]), alignment: .trailing)
                        Text(trade.days > 0 ? String(format: "%.f天", trade.days) : "")
                            .foregroundColor(isSearching ? .gray : (stock.hasReversedTrade ? .orange : .primary))
                            .frame(width: cgWidth([7.5]), alignment: .trailing)
                            .accessibilityHint(stock.hasReversedTrade ? "包含反轉買賣" : "")
                        Text(trade.days > 0 ? (trade.rollAmtRoi/stock.years < 10 ? " " : "") + String(format: "%.1f%%", trade.rollAmtRoi/stock.years) : "")
                            .foregroundColor(isSearching ? .gray : (stock.hasManualInvestAdjustment ? .orange : .primary))
                            .frame(width: cgWidth([8.5]), alignment: .trailing)
                            .accessibilityHint(stock.hasManualInvestAdjustment ? "包含手動加碼" : "")
                        Text(trade.days > 0 ? (trade.baseRoi > 0 ? (trade.baseRoi < 10 ? " " : "") + String(format: "%.1f%%", trade.baseRoi) : "") : "")
                            .foregroundColor(.gray)
                            .frame(width: cgWidth([7]), alignment: .trailing)
                    }
                    trade.gradeIcon(gray: isSearching)
                        .frame(width: cgWidth([5,3]), alignment: .center)
                }
                .foregroundColor(isSearching ? .gray : .primary)
            } else {
                EmptyView()
            }
        }
        .font(font)
        .lineLimit(1)
        .minimumScaleFactor(0.3)
        .foregroundColor(finalColor)
    }
}









































struct listTools:View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var isChoosing:Bool            //進入了選取模式
    @Binding var isSearching:Bool           //進入了搜尋模式
    @Binding var checkedStocks: [Stock]     //已選取的股票們
    @Binding var searchText:String          //輸入的搜尋文字
    @State var showLog:Bool = false         //顯示log
    @State var showSetting:Bool = false
    @State var showInformation:Bool = false

    private func openUrl(_ url:String) {
        if let URL = URL(string: url) {
            if UIApplication.shared.canOpenURL(URL) {
                UIApplication.shared.open(URL, options:[:], completionHandler: nil)
            }
        }
    }

    var body: some View {
        HStack {
            Spacer()
            if isChoosing {
                Button("取消" + (ui.widthClass(hClass) > .compact ? "選取模式" : "")) {
                    self.isChoosing = false
                    self.checkedStocks = []
                }
            } else if self.ui.searchGotResults {
                Button("放棄" + (ui.widthClass(hClass) > .compact ? "搜尋結果" : "")) {
                    self.searchText = ""
                    self.ui.searchText = nil
                    self.isSearching = false
                    self.isChoosing = false
                    self.checkedStocks = []
                }
            } else if self.isSearching || self.ui.isTradeOperationLocked {
                EmptyView()
            } else if true { //!ui.doubleColumn {
                Group {
                    /*
                    if !ui.doubleColumn {
                        Button(action: {self.showLog = true}) {
                            Image(systemName: "doc.text")
                        }
                        .padding(.trailing, 4)
                        .sheet(isPresented: $showLog) {
                            sheetLog(showLog: self.$showLog)
                        }
                        Spacer()
                    }
                    */
                    Button(action: {self.showSetting = true}) {
                        Image(systemName: "wrench")
                    }
                    .sheet(isPresented: $showSetting) {
                        sheetListSetting(
                            showSetting: self.$showSetting,
                            dateStart: defaults.start,
                            moneyBase: defaults.money,
                            autoInvest: defaults.invest,
                            groups: ui.groups
                        )
                    }
                    .environmentObject(ui)
                    Spacer()
                    if !ui.doubleColumn {
                        Button(action: {self.showInformation = true}) {
                            Image(systemName: "questionmark.circle")
                        }
                        .actionSheet(isPresented: $showInformation) {
                            ActionSheet(title: Text("參考訊息"), message: Text(ui.referenceVersion),
                                        buttons: [
                                            .default(Text("小確幸網站")) {
                                                self.openUrl("https://peiyu66.github.io/simStock21/")
                                            },
                                            .cancel(Text("關閉"))
                                        ])
                        }
                    }
                }
            }
        }   //HStack
        .lineLimit(1)
//        .frame(alignment: .trailing)
        .minimumScaleFactor(0.5)
        .padding(.leading,16)
        .padding(.trailing,16)
    }   //body
}

/*
// RETIRED: Toolbar command for the commented legacy viewList. The current
// viewList owns its selection and search controls directly.
struct chooseCommand:View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var isChoosing:Bool            //進入了選取模式
    @Binding var isSearching:Bool           //進入了搜尋模式
    @Binding var checkedStocks: [Stock]     //已選取的股票們
    @Binding var searchText:String          //輸入的搜尋文字
    @State var showFilter:Bool = false      //顯示pickerGroups
    @State var geometry:GeometryProxy

    var body: some View {
            HStack {
                if !ui.doubleColumn && geometry.size.width >= 375 {
                    Image(systemName: ui.classIcon[ui.widthClass(hClass).rawValue])
                        .foregroundColor(isSearching || isChoosing ? Color(.darkGray) : .gray)
                        .rotation3DEffect(.degrees(ui.rotated.d), axis: (x: ui.rotated.x, y: ui.rotated.y, z: 0))
                }
                if self.isChoosing || self.ui.searchGotResults {
                    Text(ui.widthClass(hClass) > .widePhone ? "請勾選" : "勾選")
                        .foregroundColor(Color(.darkGray))
                    Image(systemName: "chevron.right")
                        .foregroundColor(.gray)
                        .padding(0)
                    if self.checkedStocks.count > 0 {
                        stockActionMenu(isChoosing: self.$isChoosing, isSearching: self.$isSearching, checkedStocks: self.$checkedStocks, searchText: self.$searchText)
                    } else {
                        Button("全選") {
                            for stocks in self.ui.groupStocks {
                                if let s = stocks.first, (s.group == "" || !self.ui.searchGotResults) {
                                    for stock in stocks {
                                        self.checkedStocks.append(stock)
                                    }
                                }
                            }
                        }
                    }
                } else if !self.isSearching {
                    if ui.isTradeOperationLocked {
                        if !ui.doubleColumn {
                            runningMsg()
                            .frame(minWidth: 200, alignment: .leading)
                        }
                    } else {
                        Button("選取") {
                            self.isChoosing = true
                            self.searchText = ""
                            self.ui.searchText = nil
                            self.isSearching = false
                        }
                    }
                }
                Divider()
                Spacer()
//                Text("\(String(format:"[%.0f]",geometry.size.width))")
            }   //HStack
//            .frame(alignment: .leading)  //太寬會造成旋轉後位移
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .padding(.leading,16)
            .padding(.trailing,16)
    }

}
*/

/*
// RETIRED: This action menu belonged to the commented legacy viewList.
// The current list implements selection, group changes, recalculation, and
// removal directly, and intentionally does not expose the former CSV menu.
struct stockActionMenu:View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Environment(\.modelContext) private var context
    @Binding var isChoosing:Bool            //進入了選取模式
    @Binding var isSearching:Bool           //進入了搜尋模式
    @Binding var checkedStocks: [Stock]     //已選取的股票們
    @Binding var searchText:String          //輸入的搜尋文字
    
    @State var shareText:String = ""        //要匯出的文字內容
    @State var showGroupMenu:Bool = false
    @State var showGroupFilter:Bool = false //顯示pickerGroups
    @State var showExport:Bool = false      //顯示匯出選單
    @State var showShare:Bool = false       //分享代號簡稱
    @State var deleteAll:Bool = false
    @State var showDeleteAlert:Bool = false
    @State var showMoveAlert:Bool = false
    @State var showReload:Bool = false

    private func isChoosingOff() {
        self.isSearching = false
        self.isChoosing = false
        self.checkedStocks = []
    }

    private func twseRevise() {
        let br = backgroundRequest(context: context, technical: Technical(modelContext: context))
        br.reviseWithTWSE(self.checkedStocks)
        self.isChoosingOff()
    }

    var body: some View {
        HStack {
            if self.ui.searchGotResults {
                Button("加入" + (ui.widthClass(hClass) > .compact ? "股群" : "")) {
                    self.showGroupFilter = true
                }
                .sheet(isPresented: self.$showGroupFilter) {
                    sheetGroupPicker(checkedStocks: self.$checkedStocks, isChoosing: self.$isChoosing, isSearching: self.$isSearching, isMoving: self.$isChoosing, isPresented: self.$showGroupFilter, searchText: self.$searchText, newGroup: ui.newGroupName)
                    }
                    .environmentObject(ui)
            }
            if isChoosing {
//                if !ui.doubleColumn {
                    Button("股群" + (ui.widthClass(hClass) > .widePhone ? "組成" : "")) {
                        self.showGroupMenu = true
                    }
                    .actionSheet(isPresented: self.$showGroupMenu) {
                            ActionSheet(title: Text("加入或移除股群"), message: Text("組成股群的行動？"), buttons: [
                                .default(Text("自股群移除")) {
                                    self.showMoveAlert = true
                                },
                                .default(Text("+ 遷入他群")) {
                                    self.showGroupFilter = true
                                },
                                .destructive(Text("沒事，不用了。")) {
                                    self.isChoosingOff()
                                }
                            ])
                        }
                    .alert(isPresented: self.$showMoveAlert) {
                            Alert(title: Text("自股群移除"), message: Text("移除不會刪去歷史價，\n只不再更新、計算或復驗。"), primaryButton: .default(Text("移除"), action: {
                                self.ui.moveStocksToGroup(self.checkedStocks)
                                self.isChoosingOff()
                            }), secondaryButton: .default(Text("取消"), action: {self.isChoosingOff()}))
                        }
                    .sheet(isPresented: self.$showGroupFilter) {
                        sheetGroupPicker(checkedStocks: self.$checkedStocks, isChoosing: self.$isChoosing, isSearching: self.$isSearching, isMoving: self.$isChoosing, isPresented: self.$showGroupFilter, searchText: self.$searchText, newGroup: ui.newGroupName)
                        }
                        .environmentObject(ui)
                    Divider()
//                }
                Button((ui.widthClass(hClass) > .widePhone ? "刪除或" : "") + "重算") {
                    self.showReload = true
                }
                .actionSheet(isPresented: self.$showReload) {
                        ActionSheet(title: Text("刪除或重算"), message: Text("內容和範圍？"), buttons: [
                            .default(Text("重算模擬")) {
                                self.ui.reloadNow(self.checkedStocks, action: .simResetAll)
                                self.isChoosingOff()
                            },
                            .default(Text("重算技術數值")) {
                                self.ui.reloadNow(self.checkedStocks, action: .tUpdateAll)
                                self.isChoosingOff()
                            },
                            .default(Text("刪除最後1個月")) {
                                self.deleteAll = false
                                self.showDeleteAlert = true
                            },
                            .default(Text("刪除全部")) {
                                self.deleteAll  = true
                                self.showDeleteAlert = true
                            },
                            .default(Text("[TWSE復驗]")) {
                                twseRevise()
                            },
                            .destructive(Text("沒事，不用了。")) {
                                self.isChoosingOff()
                            }
                        ])
                    }
                .alert(isPresented: self.$showDeleteAlert) {
                    Alert(title: Text("刪除\(deleteAll ? "全部" : "最後1個月")歷史價"), message: Text("刪除歷史價，再重新下載、計算。"), primaryButton: .default(Text("刪除"), action: {
                            self.ui.deleteTrades(self.checkedStocks, oneMonth: !deleteAll)
                            self.isChoosingOff()
                        }), secondaryButton: .default(Text("取消"), action: {self.isChoosingOff()}))
                    }
                if !ui.doubleColumn {
                    Divider()
                    Button("匯出" + (ui.widthClass(hClass) > .widePhone ? "CSV" : "")) {
                        self.showExport = true
                    }
                    .actionSheet(isPresented: self.$showExport) {
                            ActionSheet(title: Text("匯出"), message: Text("文字內容？"), buttons: [
                                .default(Text("代號和名稱")) {
                                    self.shareText = csvData.csvStocksIdName(self.checkedStocks)
                                    self.showShare = true
                                },
                                .default(Text("逐月已實現" + (ui.widthClass(hClass) > .compact ? "損益" : ""))) {
                                    self.shareText = csvData.csvMonthlyRoi(in: context, self.checkedStocks)
                                    self.showShare = true
                                },
                                .destructive(Text("沒事，不用了。")) {
                                    self.isChoosingOff()
                                }
                            ])
                        }
                        .sheet(isPresented: self.$showShare) {   //分享窗
                            sheetShare(activityItems: [self.shareText]) { (activity, success, items, error) in
                                self.isChoosingOff()
                            }
                        }
                }
            }
        }
    }
}
*/
















struct sheetLog: View {
    @Binding var showLog: Bool
    @State private var events = simLog.diagnosticEvents()
    @State private var snapshot = simLog.latestPriceUpdate()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DiagnosticUpdateSummary(snapshot: snapshot)
                } header: {
                    Text("最近一次股價更新")
                }

                Section {
                    if events.isEmpty {
                        Label {
                            Text("最近 7 天未記錄到網路、解析或資料異常。")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
                        ForEach(events.prefix(20)) { event in
                            DiagnosticEventRow(event: event)
                        }
                    }
                } header: {
                    Text("最近異常")
                } footer: {
                    if events.count > 20 {
                        Text("顯示最近 20 筆，共保存 \(events.count) 筆。")
                    }
                }

                Section {
                    NavigationLink {
                        AdvancedDiagnosticLog()
                    } label: {
                        Label("查看完整開發記錄", systemImage: "text.alignleft")
                    }
                } footer: {
                    Text("一般操作進度與原始解析細節收在這裡，問題回報時通常不必查看。")
                }
            }
            .navigationTitle("更新診斷")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(
                        item: simLog.diagnosticReportText(
                            deviceDescription: "\(UIDevice.current.model)，\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                        )
                    ) {
                        Label("分享診斷報告", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    cancel
                }
            }
            .onAppear {
                refresh()
                simLog.markDiagnosticsViewed()
            }
            .onReceive(NotificationCenter.default.publisher(for: .diagnosticEventAdded)) { _ in
                refresh()
            }
        }
    }

    var cancel: some View {
        Button("關閉") {
            self.showLog = false
        }
    }

    private func refresh() {
        events = simLog.diagnosticEvents()
        snapshot = simLog.latestPriceUpdate()
    }
}

private struct DiagnosticUpdateSummary: View {
    let snapshot: PriceUpdateDiagnosticSnapshot?

    var body: some View {
        if let snapshot {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: snapshot.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(snapshot.hasFailures ? .orange : .green)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text(snapshot.statusText)
                        .font(.headline)

                    DiagnosticValueRow(
                        title: "完成時間",
                        value: twDateTime.stringFromDate(snapshot.completedAt, format: "yyyy/MM/dd HH:mm:ss")
                    )
                    if let expectedDate = snapshot.expectedTradingDate {
                        DiagnosticValueRow(
                            title: "TWSE 資料日",
                            value: twDateTime.stringFromDate(expectedDate)
                        )
                    }
                    DiagnosticValueRow(
                        title: "TWSE",
                        value: twseText(snapshot)
                    )
                    DiagnosticValueRow(
                        title: "Yahoo",
                        value: yahooText(snapshot)
                    )
                    DiagnosticValueRow(title: "市場狀態", value: snapshot.marketStatus)
                }
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("尚無更新摘要")
                        .font(.headline)
                    Text("下次完成股價更新後，這裡會顯示 TWSE 與 Yahoo 的結果。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func twseText(_ snapshot: PriceUpdateDiagnosticSnapshot) -> String {
        let pending = snapshot.twsePendingHistoryMonths ?? 0
        guard snapshot.twseRequestedMonths > 0 else {
            return pending > 0
                ? "近期資料已完整，歷史尚待補 \(pending) 個月份"
                : "歷史資料已完整，無需查詢"
        }
        let successes = max(0, snapshot.twseRequestedMonths - snapshot.twseFailedMonths)
        let result = "\(successes)/\(snapshot.twseRequestedMonths) 個月份成功"
        return pending > 0 ? "\(result)，尚待補 \(pending) 個月份" : result
    }

    private func yahooText(_ snapshot: PriceUpdateDiagnosticSnapshot) -> String {
        guard snapshot.yahooRequestedStocks > 0 else {
            return snapshot.yahooSkippedStocks > 0
                ? "略過 \(snapshot.yahooSkippedStocks) 檔"
                : "無需查詢"
        }
        var parts = ["成功 \(snapshot.yahooSuccessfulStocks)/\(snapshot.yahooRequestedStocks) 檔"]
        if snapshot.yahooUpdatedStocks > 0 {
            parts.append("寫入 \(snapshot.yahooUpdatedStocks) 檔")
        }
        if snapshot.yahooSkippedStocks > 0 {
            parts.append("略過 \(snapshot.yahooSkippedStocks) 檔")
        }
        return parts.joined(separator: "，")
    }
}

private struct DiagnosticValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct DiagnosticEventRow: View {
    let event: DiagnosticEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: severityIcon)
                .foregroundStyle(severityColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(event.source.rawValue)
                        .font(.subheadline.weight(.semibold))
                    Text(event.category.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if event.recoveredAt != nil {
                        Text("已恢復")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    if let stockID = event.stockID {
                        Text(stockID)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(twDateTime.stringFromDate(event.date, format: "MM/dd HH:mm"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(event.message)
                    .font(.footnote)
                    .foregroundStyle(event.recoveredAt == nil ? .primary : .secondary)
                    .textSelection(.enabled)

                if let recoveredAt = event.recoveredAt {
                    Text("恢復時間 \(twDateTime.stringFromDate(recoveredAt, format: "MM/dd HH:mm:ss"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var severityIcon: String {
        if event.recoveredAt != nil {
            return "checkmark.circle.fill"
        }
        switch event.severity {
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private var severityColor: Color {
        if event.recoveredAt != nil {
            return .green
        }
        switch event.severity {
        case .warning: return .yellow
        case .error: return .orange
        case .critical: return .red
        }
    }
}

private struct AdvancedDiagnosticLog: View {
    private let lines = Array(simLog.logReportArray().prefix(200))

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("進階記錄")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: simLog.logReportText()) {
                Label("分享完整記錄", systemImage: "square.and.arrow.up")
            }
        }
    }
}

struct sheetGroupPicker:View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var checkedStocks: [Stock]
    @Binding var isChoosing:Bool            //進入了選取模式
    @Binding var isSearching:Bool           //進入了搜尋模式
    @Binding var isMoving:Bool
    @Binding var isPresented:Bool
    @Binding var searchText:String
    @State   var newGroup:String //= "股群_"
    @State   var groupPicked:String = "新增股群"
    
    func allOneGroup(_ group:String) -> Bool {  //選取的股都來自同股群，就別讓原股群被重複選為將要加入的股群
        for stock in checkedStocks {
            if stock.group != group  {
                return false
            }
        }
        return true
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text((ui.widthClass(hClass) > .compact ? "選取的股票要" : "") + "加入「新的股群」或「既有股群」？"), footer: Text(self.groupPicked == "新增股群" ? "加入新增的[\(self.newGroup)]。" : "加入[\(self.groupPicked)]。")) {
                    Group {
                        ForEach(self.ui.groups, id: \.self) { (gName:String) in
                            HStack {
                                if self.groupPicked == gName {
                                    Image(systemName: "checkmark")
                                } else {
                                    Text("    ")
                                }
                                Text(gName)
                                    .onTapGesture {
                                        self.groupPicked = gName
                                    }
                            }
                            .foregroundColor(self.groupPicked == gName ? .red : (allOneGroup(gName) ? .gray : .primary))
                            .disabled(allOneGroup(gName))
                        }
                        HStack {
                            if self.groupPicked == "新增股群" {
                                Image(systemName: "checkmark")
                            } else {
                                Text("    ")
                            }
                            Text("新增股群")
                                .onTapGesture {
                                    self.groupPicked = "新增股群"
                                }
                            Group {
                                Spacer()
                                Text("：")
                                TextField("輸入股群名稱", text: self.$newGroup, onEditingChanged: { _ in    //began or end (bool)
                                    }, onCommit: {
                                    })
                                .frame(height: 40)
                                .padding([.leading, .trailing], 10)
                                .foregroundColor(Color(.darkGray))
                                .background(Color(.systemGray6))
                                .minimumScaleFactor(0.8)
                                .cornerRadius(8)
                                Spacer()
                            }
                            .disabled(self.groupPicked != "新增股群")
                            .foregroundColor(.primary)

                        }
                        .foregroundColor(self.groupPicked == "新增股群" ? .red : .primary)
                    }
                }
            }
            .navigationBarTitle("加入股群")
            .navigationBarItems(leading: cancel, trailing: done)

        }
            .navigationViewStyle(StackNavigationViewStyle())
    }
    
    var cancel: some View {
        Button("取消") {
            self.isPresented = false
            self.isMoving = false
            self.searchText = ""
            self.ui.searchText = nil
            self.checkedStocks = []            
            self.isChoosing = false
            self.isSearching = false
        }
    }
    var done: some View {
        Group {
            if self.groupPicked != "新增股群" || self.newGroup != "" {
                Button("確認") {
                    let toGroup:String = (self.groupPicked != "新增股群" ? self.groupPicked : self.newGroup)
                    guard self.ui.moveStocksToGroup(self.checkedStocks, group: toGroup) else {
                        return
                    }
                    self.isPresented = false
                    self.isMoving = false
                    self.searchText = ""
                    self.ui.searchText = nil
                    self.checkedStocks = []
                    self.isChoosing = false
                    self.isSearching = false
                }
            }
        }
    }


}

struct sheetShare: UIViewControllerRepresentable {
    typealias Callback = (_ activityType: UIActivity.ActivityType?, _ completed: Bool, _ returnedItems: [Any]?, _ error: Error?) -> Void

    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil
    let excludedActivityTypes: [UIActivity.ActivityType]? = [    //標為註解以排除可用的，留下不要的
                    .addToReadingList,
                    .airDrop,
                    .assignToContact,
    //                .copyToPasteboard,
    //                .mail,
    //                .markupAsPDF,   //iOS11之後才有
    //                .message,
                    .openInIBooks,
                    .postToFacebook,
                    .postToFlickr,
                    .postToTencentWeibo,
                    .postToTwitter,
                    .postToVimeo,
                    .postToWeibo,
                    .print,
                    .saveToCameraRoll]
    let callback: Callback

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities)
        controller.excludedActivityTypes = excludedActivityTypes
        controller.completionWithItemsHandler = callback
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // nothing to do here
    }
    
    static func dismantleUIViewController(_ uiViewController: Self.UIViewControllerType, coordinator: Self.Coordinator) {
    }
}

private enum ListSimulationSettingScope: String, CaseIterable, Identifiable {
    case defaultsOnly
    case selectedGroups
    case allStocks

    var id: Self { self }

    var title: String {
        switch self {
        case .defaultsOnly:
            return "只儲存新股預設"
        case .selectedGroups:
            return "同時套用到指定股群"
        case .allStocks:
            return "同時套用到全部既有股票"
        }
    }
}

private struct PaddedFormPresentationSizing: PresentationSizing {
    let extraHeight: CGFloat

    func proposedSize(
        for root: PresentationSizingRoot,
        context: PresentationSizingContext
    ) -> ProposedViewSize {
        let formSizing: FormPresentationSizing = .form
        let baseSize = formSizing.proposedSize(for: root, context: context)
        return ProposedViewSize(
            width: baseSize.width,
            height: baseSize.height.map { $0 + extraHeight }
        )
    }
}

struct sheetListSetting: View {
    @EnvironmentObject var ui: uiObject
    @Binding var showSetting: Bool
    @State var dateStart:Date
    @State var moneyBase:Double
    @State var autoInvest:Double
    let groups: [String]
    @State private var scope: ListSimulationSettingScope = .defaultsOnly
    @State private var selectedGroups: Set<String> = []

    var body: some View {
        NavigationView {
            Form {
                Section {
                    DatePicker(selection: $dateStart, in: (twDateTime.calendar.date(byAdding: .year, value: -15, to: Date()) ?? defaults.first)...(twDateTime.calendar.date(byAdding: .year, value: -1, to: Date()) ?? Date()), displayedComponents: .date) {
                        Text("起始日期")
                    }
                    .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
                    HStack {
                        Text(String(format:"起始本金%.f萬元",self.moneyBase))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(width: 180, alignment: .leading)
                        Slider(value: $moneyBase, in: 10...1000, step: 10)
                    }
                    HStack {
                        Text(self.autoInvest > 9 ? "自動無限加碼" : (self.autoInvest > 0 ? String(format:"自動%.0f次加碼", self.autoInvest) : "不自動加碼"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(width: 180, alignment: .leading)
                        Slider(value: $autoInvest, in: 0...10, step: 1)
                    }
                } header: {
                    Text("新股預設").font(.title)
                } footer: {
                    Text("修改前：\(defaults.simDefault)")
                }

                Section {
                    Picker("套用範圍", selection: $scope) {
                        ForEach(ListSimulationSettingScope.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    if scope == .selectedGroups {
                        if groups.isEmpty {
                            Text("目前沒有可套用的股群")
                                .foregroundStyle(.secondary)
                        } else {
                            NavigationLink {
                                ListSimulationGroupSelection(
                                    groups: groups,
                                    selectedGroups: $selectedGroups
                                )
                            } label: {
                                HStack {
                                    Text("選擇股群")
                                    Spacer()
                                    Text(selectedGroupSummary)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("套用範圍").font(.title)
                }

            }
            .safeAreaPadding(.bottom, 12)
            .navigationBarTitle("模擬設定")
            .navigationBarItems(leading: cancel, trailing: done)

        }
        .navigationViewStyle(StackNavigationViewStyle())
        .presentationSizing(PaddedFormPresentationSizing(extraHeight: 48))
    }
    
    var cancel: some View {
        Button("取消") {
            self.showSetting = false
        }
    }
    var done: some View {
        Button(confirmTitle) {
            self.ui.applyDefaultSetting(
                dateStart: self.dateStart,
                moneyBase: self.moneyBase,
                autoInvest: self.autoInvest,
                groupNames: scope == .selectedGroups ? selectedGroups : [],
                applyToAll: scope == .allStocks
            )
            self.showSetting = false
        }
        .disabled(
            ui.isTradeOperationLocked
                || (scope == .selectedGroups && selectedGroups.isEmpty)
        )
    }

    private var confirmTitle: String {
        switch scope {
        case .defaultsOnly:
            return "儲存預設"
        case .selectedGroups:
            return "儲存並套用 \(selectedGroups.count) 個股群"
        case .allStocks:
            return "儲存並套用全部"
        }
    }

    private var selectedGroupSummary: String {
        selectedGroups.isEmpty ? "尚未選擇" : "已選 \(selectedGroups.count) 個"
    }
}

private struct ListSimulationGroupSelection: View {
    let groups: [String]
    @Binding var selectedGroups: Set<String>

    var body: some View {
        List {
            ForEach(groups, id: \.self) { group in
                Button {
                    toggleGroup(group)
                } label: {
                    HStack {
                        Text(group)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedGroups.contains(group) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("選擇股群")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggleGroup(_ group: String) {
        if selectedGroups.contains(group) {
            selectedGroups.remove(group)
        } else {
            selectedGroups.insert(group)
        }
    }
}
























struct SearchBar: View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var editText: String
    @Binding var isSearching:Bool
    @State var isEditing:Bool = false
    
    var title:String {
        if ui.widthClass(hClass) > .compact {
            return "以代號或簡稱來搜尋尚未加入股群的上市股票"
        } else {
            return "以代號或簡稱來搜尋上市股票"
        }
    }

    //來自： https://www.appcoda.com/swiftui-search-bar/
    var body: some View {
        VStack (alignment: .leading) {
            HStack {
                TextField(title, text: $editText    /*, onEditingChanged: { editing in
                    if !editing {
                        isEditing = false
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)  // Dismiss the keyboard
                    }
                } */, onCommit: {
                    ui.searchText = editText.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "  ", with: " ").replacingOccurrences(of: "  ", with: " ").components(separatedBy: " ")
                    isEditing = false
                    isSearching = true
                })
                    .padding(7)
                    .padding(.horizontal, 25)
                    .lineLimit(nil)
                    .minimumScaleFactor(0.8)
                    .background(Color(.systemGray6))
    //                .keyboardType(.webSearch)
                    .cornerRadius(8)
                    .onTapGesture {
                        isEditing = true
                        isSearching = true
                    }
                    .overlay(
                       HStack {
                           Image(systemName: "magnifyingglass")
                               .foregroundColor(.gray)
                               .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                               .padding(.leading, 8)
                    
                           if isEditing {
                                Button(action: {
                                    editText = ""
                                    isSearching = true
                                    ui.searchText = nil
                               })
                               {
                                    Image(systemName: "multiply.circle.fill")
                                       .foregroundColor(.gray)
                                       .padding(.trailing, 8)
                               }
                           }
                       }
                    )
                    .padding(.horizontal, 10)
                if isEditing && isSearching {
                    Button(action: {
                        editText = ""
                        isEditing = false
                        isSearching = false
                        ui.searchText = nil
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)  // Dismiss the keyboard
                    })
                    {
                        Text("取消")
                    }
                    .padding(.trailing, 10)
                    .transition(.move(edge: .trailing))
//                    .animation(.default)
                }
            }   //HStack
            HStack(alignment: .bottom){
                if isSearching && ui.searchText != nil && !ui.searchGotResults {
                    if ui.searchTextInGroup {
                        Text("\(ui.searchText?[0] ?? "搜尋的股票")已在股群中。")
                            .foregroundColor(.orange)
                    } else {
                        Text("查無符合者，試以部分的代號或簡稱來查詢？")
                            .foregroundColor(.orange)
                    }
                    Button("[知道了]") {
                        editText = ""
                        isSearching = false
                        ui.searchText = nil
                    }
                }
            }
            .font(.footnote)
            .padding(.horizontal, 20)
        }   //VStack
    }
}
