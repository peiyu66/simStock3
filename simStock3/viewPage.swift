//
//  simStockPageView.swift
//  simStock21
//
//  Created by peiyu on 2020/6/28.
//  Copyright © 2020 peiyu. All rights reserved.
//

import SwiftUI
import Combine
import SwiftData

struct viewPage: View {
    @Environment(\.horizontalSizeClass) var hClass
    @Environment(\.modelContext) private var context
    @EnvironmentObject var ui: uiObject
    @State var stock : Stock
    @State var prefix: String
    @State var showPrefixMsg:Bool = false
    @State var groupPrefixsOnly:Bool = true
    @State var filterIsOn = false
    @State private var localShowTechnical = false
    @State private var localSelectedTradeDate: Date?
    @State private var orderedTrades: [Trade] = []
    @State private var orderedTradesStockID: String?
    @State private var tradeListScrollRequest = 0
    @State private var priceUpdateIsRunning = false
    @State private var priceUpdateStatusMessage = ""
    let isSplitDetail: Bool
    let showsPriceUpdateStatus: Bool
    private let sharedTechnicalVisibility: Binding<Bool>?
    private let sharedTechnicalDate: Binding<Date?>?

    init(
        stock: Stock,
        prefix: String,
        isSplitDetail: Bool = false,
        showsPriceUpdateStatus: Bool = true,
        sharedTechnicalVisibility: Binding<Bool>? = nil,
        sharedTechnicalDate: Binding<Date?>? = nil
    ) {
        _stock = State(initialValue: stock)
        _prefix = State(initialValue: prefix)
        self.isSplitDetail = isSplitDetail
        self.showsPriceUpdateStatus = showsPriceUpdateStatus
        self.sharedTechnicalVisibility = sharedTechnicalVisibility
        self.sharedTechnicalDate = sharedTechnicalDate
    }

    private var showTechnicalBinding: Binding<Bool> {
        sharedTechnicalVisibility ?? $localShowTechnical
    }

    private var selectedTradeDateBinding: Binding<Date?> {
        sharedTechnicalDate ?? $localSelectedTradeDate
    }

    private var showTechnical: Bool {
        showTechnicalBinding.wrappedValue
    }

    private var selectedTradeDate: Date? {
        selectedTradeDateBinding.wrappedValue
    }

    private var sortedTrades: [Trade] {
        orderedTrades
    }

    private var selectedTrade: Trade? {
        if let selected = selectedTradeDate,
           let trade = sortedTrades.first(where: { $0.date == selected }) {
            return trade
        }
        return sortedTrades.first
    }

    private func resolvedTradeDate(
        for requestedDate: Date?,
        in trades: [Trade]? = nil
    ) -> Date? {
        let trades = trades ?? orderedTrades
        guard !trades.isEmpty else { return nil }
        guard let requestedDate else { return trades.first?.date }

        if let exact = trades.first(where: { $0.date == requestedDate }) {
            return exact.date
        }
        if let nearestEarlier = trades.first(where: { $0.date < requestedDate }) {
            return nearestEarlier.date
        }
        return trades.last?.date
    }

    private func reloadOrderedTrades(
        resolveSelection: Bool = true,
        force: Bool = false
    ) {
        if !force,
           orderedTradesStockID == stock.sId,
           !orderedTrades.isEmpty {
            if resolveSelection {
                setSelectedTrade(
                    resolvedTradeDate(for: selectedTradeDate ?? ui.selected)
                )
            }
            return
        }

        let trades: [Trade]
        if !force, let cachedTrades = ui.cachedOrderedTrades(for: stock.sId) {
            trades = cachedTrades
        } else {
            do {
                trades = try Trade.fetch(
                    in: context,
                    for: stock,
                    ascending: false
                )
                ui.storeOrderedTrades(trades, for: stock.sId)
            } catch {
                simLog.addLog(
                    "讀取 \(stock.sId)\(stock.sName) 交易清單失敗：\(error.localizedDescription)"
                )
                trades = []
            }
        }

        orderedTrades = trades
        orderedTradesStockID = stock.sId
        if resolveSelection {
            setSelectedTrade(
                resolvedTradeDate(
                    for: selectedTradeDate ?? ui.selected,
                    in: trades
                )
            )
        }
        tradeListScrollRequest &+= 1
    }

    private func setSelectedTrade(_ date: Date?) {
        selectedTradeDateBinding.wrappedValue = date
        ui.selected = date
    }

    private func selectTrade(offset: Int) {
        guard !sortedTrades.isEmpty else { return }
        let currentIndex = selectedTrade.flatMap { selected in
            sortedTrades.firstIndex(where: { $0.date == selected.date })
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), sortedTrades.count - 1)
        setSelectedTrade(sortedTrades[nextIndex].date)
    }

    func pageViewTools(
        _ geometry: GeometryProxy,
        pageColumn: Bool,
        showTechnical: Binding<Bool>
    ) -> some View {
        Group {
            if pageColumn {
                pageTools(stock: $stock, filterIsOn: $filterIsOn, showTechnical: showTechnical, geometry: geometry)
            } else {
                prefixPicker(prefix:self.$prefix, stock:self.$stock, groupPrefixsOnly: self.$groupPrefixsOnly, geometry: geometry)
            }
        }
    }
    
    func pageViewTitle(_ geometry:GeometryProxy, pageColumn: Bool) -> some View {
        Group {
            if pageColumn {
                pageTitle(stock: $stock, geometry: geometry)
            } else {
                EmptyView()
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let pageColumn = isSplitDetail
                    || (hClass == .regular && geo.size.width > geo.size.height && geo.size.width >= 800)
                let usesSpaciousTechnicalSidebar = geo.size.width >= 920
                let showsTechnicalSidebar = showTechnical && geo.size.width >= 720
                let hidesTradeIcons = SummaryIconLayoutPolicy.hidesTradeIcons(
                    showsTechnicalSidebar: showsTechnicalSidebar,
                    usesSpaciousTechnicalSidebar: usesSpaciousTechnicalSidebar
                )
                VStack (alignment: .center) {
                if showTechnical && !showsTechnicalSidebar {
                    if let trade = selectedTrade {
                        tradeTechnicalView(
                            stock: stock,
                            trade: trade,
                            showsCloseButton: true,
                            showsDateNavigation: true,
                            onClose: { showTechnicalBinding.wrappedValue = false },
                            onNewer: { selectTrade(offset: -1) },
                            onOlder: { selectTrade(offset: 1) }
                        )
                    } else {
                        ContentUnavailableView("尚無技術資料", systemImage: "waveform.path.ecg")
                    }
                } else {
                    HStack(spacing: 0) {
                        tradeListView(
                            stock: self.$stock,
                            orderedTrades: orderedTrades,
                            scrollRequest: tradeListScrollRequest,
                            prefix: self.$prefix,
                            filterIsOn: $filterIsOn,
                            showTechnical: showTechnicalBinding,
                            selectedTradeDate: selectedTradeDateBinding,
                            groupPrefixsOnly: self.$groupPrefixsOnly,
                            pageColumn: pageColumn,
                            hidesSummaryIcons: hidesTradeIcons
                        )
                        if showsTechnicalSidebar {
                            Divider()
                            if let trade = selectedTrade {
                                tradeTechnicalView(
                                    stock: stock,
                                    trade: trade,
                                    showsCloseButton: false,
                                    showsDateNavigation: false,
                                    onClose: { showTechnicalBinding.wrappedValue = false },
                                    onNewer: { selectTrade(offset: -1) },
                                onOlder: { selectTrade(offset: 1) }
                            )
                                .frame(
                                    minWidth: usesSpaciousTechnicalSidebar ? 320 : 270,
                                    idealWidth: usesSpaciousTechnicalSidebar ? 350 : 285,
                                    maxWidth: usesSpaciousTechnicalSidebar ? 390 : 305
                                )
                            }
                        }
                    }
                }
                if !pageColumn && !showTechnical {
                    Spacer(minLength: 24)   //不知為何是24？
                    stockPicker(prefix: self.$prefix, stock: self.$stock, groupPrefixsOnly: self.$groupPrefixsOnly,  geometry: geo)
                        .alert(isPresented: $showPrefixMsg) {
                            Alert(title: Text("提醒您"), message: Text("有多股的首字相同時，\n於畫面底處可按切換。"), dismissButton: .default(Text("知道了。")))
                        }
                }
            }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        pageViewTitle(geo, pageColumn: pageColumn)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        pageViewTools(
                            geo,
                            pageColumn: pageColumn,
                            showTechnical: showTechnicalBinding
                        )
                    }
                }
                .onAppear {
                    ui.pageStock = self.stock
                    reloadOrderedTrades()
                    if !pageColumn && ui.versionLast == "" && ui.prefixStocks(prefix: prefix, group: (groupPrefixsOnly ? stock.group : nil)).count > 1 {
                        showPrefixMsg = true
                    }
                }
                .onChange(of: stock.sId) { _, _ in
                    ui.pageStock = self.stock
                    reloadOrderedTrades()
                }
            }

            if showsPriceUpdateStatus {
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
        .onReceive(ui.$isUpdatingPrices) { isUpdating in
            let didFinishUpdating = priceUpdateIsRunning && !isUpdating
            priceUpdateIsRunning = isUpdating
            if didFinishUpdating {
                reloadOrderedTrades(resolveSelection: false, force: true)
            }
        }
        .onReceive(ui.$priceUpdateMessage) { message in
            priceUpdateStatusMessage = message
        }
    }
}


private struct LatestTradeFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull {
            value = next
        }
    }
}

struct tradeListView: View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var stock : Stock
    let orderedTrades: [Trade]
    let scrollRequest: Int
    @Binding var prefix: String
    @Binding var filterIsOn:Bool
    @Binding var showTechnical: Bool
    @Binding var selectedTradeDate: Date?
    @Binding var groupPrefixsOnly:Bool
    let pageColumn: Bool
    let hidesSummaryIcons: Bool
    @State private var isLatestTradeVisible = true
    @State private var hasMeasuredLatestTrade = false

    private var sortedTrades: [Trade] {
        orderedTrades
    }

    private var latestTradeDate: Date? {
        sortedTrades.first?.date
    }

    private var displayedTrades: [Trade] {
        let latestDate = latestTradeDate
        return sortedTrades.filter {
            self.filterIsOn == false
                || $0.simInvestByUser != 0
                || $0.simReversed != ""
                || $0.simQtySell > 0
                || $0.simQtyBuy > 0
                || $0.simRuleInvest != ""
                || $0.date == $0.stock.dateFirst
                || $0.date == twDateTime.startOfDay()
                || selectedTradeDate == $0.date
                || latestDate == $0.date
        }
    }
    
    private func scrollToSelectionOrLatest(_ sv: ScrollViewProxy) {
        if let selectedTradeDate {
            sv.scrollTo(selectedTradeDate, anchor: .center)
        } else if let latestTradeDate {
            sv.scrollTo(latestTradeDate, anchor: .top)
        }
    }

    private func scrollToLatest(_ sv: ScrollViewProxy) {
        guard let latestTradeDate else { return }
        selectedTradeDate = latestTradeDate
        ui.selected = latestTradeDate
        withAnimation(.easeInOut(duration: 0.25)) {
            sv.scrollTo(latestTradeDate, anchor: .top)
        }
    }
    
    var body: some View {
        GeometryReader { pageGeometry in
            VStack(alignment: .leading) {
                //== 表頭：股票名稱、模擬摘要 ==
                tradeHeading(
                    stock: self.$stock,
                    filterIsOn: self.$filterIsOn,
                    showTechnical: self.$showTechnical,
                    pageColumn: pageColumn,
                    hidesSummaryIcons: hidesSummaryIcons,
                    geometry: pageGeometry
                )
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onEnded({ value in
                        if value.translation.width < 0 {
                            self.stock = ui.shiftLeftStock(stock, groupStocks: (groupPrefixsOnly ? ui.theGroupStocks(self.stock) : nil))
                            self.prefix = self.stock.prefix
                        }
                        if value.translation.width > 0 {
                            self.stock = ui.shiftRightStock(stock, groupStocks: (groupPrefixsOnly ? ui.theGroupStocks(self.stock) : nil))
                            self.prefix = self.stock.prefix
                        }
                        if value.translation.height < 0 {
                            // up
                        }
                        if value.translation.height > 0 {
                            // down
                        }
                    }))
            //== 日交易明細列表 ==
                GeometryReader { geo in
                ScrollViewReader { sv in
                    ZStack(alignment: .bottomTrailing) {
                        LazyVStack {
                            Divider()
//                        List (stock.trades.filter{self.filterIsOn == false || $0.simInvestByUser != 0 || $0.simReversed != "" || $0.simQtySell > 0 || $0.simQtyBuy > 0 || $0.simRuleInvest != "" || $0.date == $0.stock.dateFirst || $0.date == twDateTime.startOfDay()}, id:\.self.date) { trade in
                            List(displayedTrades, id: \.self.date) { trade in
                                tradeCell(
                                    stock: self.$stock,
                                    trade: trade,
                                    technicalSelected: selectedTradeDate == trade.date,
                                    hidesSummaryIcons: hidesSummaryIcons,
                                    onTechnicalSelect: {
                                        selectedTradeDate = trade.date
                                        ui.selected = trade.date
                                    },
                                    geometry: pageGeometry
                                )
                                .listRowInsets(
                                    EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 4)
                                )
                                .background {
                                    if trade.date == latestTradeDate {
                                        GeometryReader { rowGeometry in
                                            Color.clear.preference(
                                                key: LatestTradeFramePreferenceKey.self,
                                                value: rowGeometry.frame(
                                                    in: .named("tradeListViewport")
                                                )
                                            )
                                        }
                                    }
                                }
                            }
                            .offset(x: 0, y: -8)
                            .listStyle(GroupedListStyle())
                            .frame(width: geo.size.width, height: geo.size.height + 8, alignment: .center)
                        }
                        .background(Color(.systemGroupedBackground))

                        if latestTradeDate != nil && !isLatestTradeVisible {
                            Button {
                                scrollToLatest(sv)
                            } label: {
                                Label("最新", systemImage: "arrow.up.to.line")
                                    .font(.callout.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.regular)
                            .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                            .padding(.trailing, 18)
                            .padding(.bottom, 18)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            .accessibilityLabel("跳到最新一筆交易")
                        }
                    }
                    .coordinateSpace(name: "tradeListViewport")
                    .onPreferenceChange(LatestTradeFramePreferenceKey.self) { frame in
                        if frame.isNull {
                            guard hasMeasuredLatestTrade else { return }
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isLatestTradeVisible = false
                            }
                            return
                        }

                        hasMeasuredLatestTrade = true
                        let viewport = CGRect(origin: .zero, size: geo.size)
                        let isVisible = frame.maxY > viewport.minY
                            && frame.minY < viewport.maxY
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isLatestTradeVisible = isVisible
                        }
                    }
                    .onChange(of: stock) {
                        hasMeasuredLatestTrade = false
                        isLatestTradeVisible = true
                        ui.pageStock = self.stock
                    }
                    .onChange(of: self.filterIsOn) {
                        scrollToSelectionOrLatest(sv)
                    }
                    .onChange(of: scrollRequest) {
                        scrollToSelectionOrLatest(sv)
                    }
                    .onAppear() {
                        scrollToSelectionOrLatest(sv)
                    }
                }
                }
            }   //VStack
        }
    }
}

























private func pickerIndexRange(index:Int, count:Int, max: Int) -> (from:Int, to:Int) {
    var from:Int = 0
    var to:Int = count - 1
    let center:Int = (max - 1) / 2
    
    if count > max {
        if index <= center {
            from = 0
            to = max - 1
        } else if index >= (count - center) {
            from = count - max
            to = count - 1
        } else {
            from = index - center
            to = index + center
        }
    }
    
    return(from,to)
}

struct prefixPicker: View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var prefix: String
    @Binding var stock : Stock
    @Binding var groupPrefixsOnly:Bool
    let geometry: GeometryProxy
    
    var allPrefixs:[String] {
        (groupPrefixsOnly ? ui.theGroupPrefixs(self.stock) : ui.prefixs)
    }
    
    var maxCount:Int {
        var c = Int(geometry.size.width * 0.6 / 32)
        if c < 3 {
            c = 3
        } else if c % 2 == 0 {
            c -= 1
        }
        return c
    }

    var prefixs:[String] {
        let prefixIndex = allPrefixs.firstIndex(of: prefix) ?? 0
        let index = pickerIndexRange(index: prefixIndex, count: allPrefixs.count, max: maxCount)
        return Array(allPrefixs[index.from...index.to])
    }
    
    var groupLabel:String {
        " " + (self.groupPrefixsOnly ? (stock.group.count > 5 ? String(stock.group.prefix(2) + stock.group.suffix(3)) : stock.group) : "全部股")  + " "
    }

    var body: some View {
        HStack {
            Button(action: {
                self.groupPrefixsOnly = !self.groupPrefixsOnly
            }) {
                Text(groupLabel)
                    .font(.footnote)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.blue, lineWidth: 1))
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onEnded({ value in
                    if value.translation.width < 0, groupPrefixsOnly {
                        self.stock = ui.shiftLeftGroup(stock)
                        self.prefix = self.stock.prefix
                    }
                    if value.translation.width > 0, groupPrefixsOnly {
                        self.stock = ui.shiftRightGroup(stock)
                        self.prefix = self.stock.prefix
                    }
                    if value.translation.height < 0 {
                        // up
                    }
                    if value.translation.height > 0 {
                        // down
                    }
                }))

            if self.prefixs.first == allPrefixs.first {
                Text("|").foregroundColor(.gray).fixedSize()
            } else {
                Text("-").foregroundColor(.gray).fixedSize()
            }
            Picker("", selection: $prefix) {
                ForEach(self.prefixs, id:\.self) {prefix in
                    Text(prefix).tag(prefix)
                }
            }
                .pickerStyle(SegmentedPickerStyle())
                .labelsHidden()
                .fixedSize()
                .onReceive([self.prefix].publisher.first()) { value in
                    if self.stock.prefix != self.prefix {
                        if let firstStock = self.ui.prefixStocks(
                            prefix: value,
                            group: groupPrefixsOnly ? stock.group : nil
                        ).first {
                            self.stock = firstStock
                        }
                    }
                }
            if self.prefixs.last == allPrefixs.last {
                Text("|").foregroundColor(.gray).fixedSize()
            } else {
                Text("-").foregroundColor(.gray).fixedSize()
            }
        }
        .frame(minWidth: 100, alignment: .trailing)
    }
}

struct stockPicker: View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var prefix:String
    @Binding var stock :Stock
    @Binding var groupPrefixsOnly:Bool
    let geometry: GeometryProxy
    
    var allStocks:[Stock] {
        ui.prefixStocks(prefix: self.prefix, group: (groupPrefixsOnly ? stock.group : nil))
    }
    
    var prefixStocks:[Stock] {
        guard !allStocks.isEmpty else { return [] }

        let maxChars = Float(geometry.size.width) * 0.8 / 16
        let sNameMaxCount = Float(allStocks.map{$0.sName.count}.max() ?? 6)
        var maxCount = Int(maxChars / (sNameMaxCount > 6 ? 6 : sNameMaxCount))
        if maxCount < 3 {
            maxCount = 3
        } else if maxCount % 2 == 0 {
            maxCount -= 1
        }
        let stockIndex = allStocks.firstIndex(of: self.stock) ?? 0
        let index = pickerIndexRange(index: stockIndex, count: allStocks.count, max: (maxCount < 3 ? 3 : maxCount))
        return Array(allStocks[index.from...index.to])
    }

    var body: some View {
        VStack (alignment: .center) {
            if self.prefixStocks.count > 1 {
                HStack {
                    if self.prefixStocks.first == allStocks.first {
                        Text("|").foregroundColor(.gray).fixedSize()
                    } else {
                        Text("-").foregroundColor(.gray)
                    }
                    Picker("", selection: $stock) {
                        ForEach(self.prefixStocks, id:\.self.sId) { stock in
                            let sName = stock.sName
                            Text(sName.count > 6 ? String(sName.prefix(4) + sName.suffix(2)) : sName).tag(stock)
                        }
                    }
                        .pickerStyle(SegmentedPickerStyle())
                        .labelsHidden()
                        .fixedSize()
                    if self.prefixStocks.last == allStocks.last {
                        Text("|").foregroundColor(.gray).fixedSize()
                    } else {
                        Text("-").foregroundColor(.gray).fixedSize()
                    }
                }
            }
		}
    }    
}




































struct sheetPageSetting: View {
    @EnvironmentObject var ui: uiObject
    @Binding var stock:Stock
    @Binding var showSetting: Bool
    @State var dateStart:Date
    @State var moneyBase:Double
    @State var autoInvest:Double
    @State var applyToGroup:Bool = false
    @State var applyToAll:Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("\(stock.sId)\(stock.sName)的設定").font(.title)) {
                    DatePicker(selection: $dateStart, in: (twDateTime.calendar.date(byAdding: .year, value: -15, to: Date()) ?? stock.dateFirst)...(twDateTime.calendar.date(byAdding: .year, value: -1, to: Date()) ?? Date()), displayedComponents: .date) {
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
                }
                Section(header: Text("擴大設定範圍").font(.title)) {
                    Toggle("套用到全部股", isOn: $applyToAll)
                    .onReceive([self.applyToAll].publisher.first()) { (value) in
                        if value == true {
                            self.applyToGroup = value
                        }
                    }
                    Toggle("套用到同股群 [\(stock.group)]", isOn: $applyToGroup)
                        .disabled(self.applyToAll)
                }

            }
            .navigationBarTitle("模擬設定")
            .navigationBarItems(leading: cancel, trailing: done)

        }
            .navigationViewStyle(StackNavigationViewStyle())
    }
    
    var cancel: some View {
        Button("取消") {
            self.showSetting = false
        }
    }
    var done: some View {
        Button("確認") {
            self.ui.applySetting(
                self.stock,
                dateStart: self.dateStart,
                moneyBase: self.moneyBase,
                autoInvest: self.autoInvest,
                applyToGroup: self.applyToGroup,
                applyToAll: self.applyToAll
            )
            self.showSetting = false
        }
        .disabled(ui.isTradeOperationLocked)
    }
    

    
}

struct pageTitle: View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var stock: Stock
    let geometry: GeometryProxy

    var body: some View {
        VStack (alignment: .leading) {
//            if ui.isRunning {
//                runningMsg(padding: 4)
//                    .frame(minWidth:200, alignment: .leading)
//            }
            HStack {
                Text("\(stock.sId) \(stock.sName)")
                    .font(.title)
                if ui.widthClass(hClass) > .compact && stock.proport1.count > 0 {
                    Text("[\(stock.proport1)]")
                        .font(.footnote)
                        .padding(.top)
                }
            }
            .foregroundColor(ui.isTradeOperationLocked ? .gray : .primary)
            .lineLimit(2)
            .frame(minWidth: geometry.size.width * 0.45 , alignment: .leading)
            .padding(.leading)
        }

    }
}

struct runningMsg: View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @State var padding:CGFloat = 0
    
    var body: some View {
        HStack {
            if ui.isRunning {
                Text(ui.runningMsg)
            } else {
                Text(" ")
            }
        }
            .font(.body)
            .foregroundColor(.orange)
            .lineLimit(1)
            .padding(.bottom,padding)
    }
}

private struct PageViewModeIconStyle: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.blue)
            .fontWeight(isActive ? .semibold : .regular)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive ? Color.blue.opacity(0.14) : .clear)
            )
    }
}

struct pageTools:View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var stock : Stock
    @State var showSetting: Bool = false
    @State var showInformation:Bool = false
    @State var showLog:Bool = false
    @State private var unreadDiagnosticCount = simLog.unreadDiagnosticCount()
    @Binding var filterIsOn:Bool
    @Binding var showTechnical: Bool
    let geometry: GeometryProxy

    private func openUrl(_ url:String) {
        if let URL = URL(string: url) {
            if UIApplication.shared.canOpenURL(URL) {
                UIApplication.shared.open(URL, options:[:], completionHandler: nil)
            }
        }
    }
    
    var cgWidth:CGFloat {
        if ui.pageColumn(hClass) {
            return geometry.size.width - (geometry.size.width > 1050 ? 450 : 420)
        } else {
            return 150
        }
    }
    
    var body: some View {
        HStack {
            //== 技術檢視：寬視窗使用側欄，窄視窗使用獨立頁面 ==
            Button(action: { showTechnical.toggle() }) {
                Image(systemName: "waveform.path.ecg")
                    .modifier(PageViewModeIconStyle(isActive: showTechnical))
            }
            .disabled(stock.trades.isEmpty)
            .accessibilityLabel(showTechnical ? "關閉技術檢視" : "開啟技術檢視")

            //== 過濾交易模擬 ==
            Button(action: {self.filterIsOn = !self.filterIsOn}) {
                Image(systemName: self.filterIsOn ? "square.2.stack.3d" : "square.3.stack.3d")
                    .modifier(PageViewModeIconStyle(isActive: filterIsOn))
            }
            .padding(.trailing, ui.widthClass(hClass) == .compact ? 2 : 8)

            //== 更新目前股票的股價 ==
            Button {
                ui.startDailyPriceUpdate(stocks: [stock])
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(ui.isReadOnlySnapshot || ui.isTradeOperationLocked)
            .help("更新此股股價")
            .accessibilityLabel("更新此股股價")

            //== 個股模擬設定 ==
            Button(action: {self.showSetting = true}) {
                Image(systemName: "wrench")
            }
            .disabled(ui.isReadOnlySnapshot || ui.isTradeOperationLocked)
            .help("個股模擬設定")
            .accessibilityLabel("個股模擬設定")
            .sheet(isPresented: $showSetting) {
                sheetPageSetting(stock: self.$stock, showSetting: self.$showSetting, dateStart: self.stock.dateStart, moneyBase: self.stock.simMoneyBase, autoInvest: self.stock.simInvestAuto)
                    .environmentObject(ui)
            }

            //== 更新診斷 ==
            Button(action: {self.showLog = true}) {
                Image(systemName: "doc.text")
                    .overlay(alignment: .topTrailing) {
                        if unreadDiagnosticCount > 0 {
                            Circle()
                                .fill(.orange)
                                .frame(width: 7, height: 7)
                                .offset(x: 4, y: -3)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .help("更新診斷")
            .accessibilityLabel(
                unreadDiagnosticCount > 0
                    ? "更新診斷，有 \(unreadDiagnosticCount) 項新異常"
                    : "更新診斷"
            )
            .sheet(isPresented: $showLog) {
                sheetLog(showLog: self.$showLog)
            }
            .onReceive(NotificationCenter.default.publisher(for: .diagnosticEventAdded)) { _ in
                unreadDiagnosticCount = simLog.unreadDiagnosticCount()
            }

            //== 參考訊息 ==
//            Spacer()
            Button(action: {self.showInformation = true}) {
                Image(systemName: "questionmark.circle")
            }
//            .padding(.trailing, ui.widthCG(hClass, CG: [2,8]))
            .padding(.trailing, ui.widthClass(hClass) == .compact ? 2 : 8)
            .actionSheet(isPresented: $showInformation) {
                ActionSheet(title: Text("參考訊息"), message: Text(ui.referenceVersion),
                buttons: [
                    .default(Text("小確幸網站")) {
                        self.openUrl("https://peiyu66.github.io/simStock3/")
                    },
                    .default(Text("鉅亨個股走勢")) {
                        self.openUrl("https://invest.cnyes.com/twstock/tws/" + self.stock.sId)
                    },
                    .default(Text("Yahoo!技術分析")) {
                        self.openUrl("https://tw.stock.yahoo.com/q/ta?s=" + self.stock.sId)
                    },
                    .cancel(Text("關閉"))
                ])
            }
        } //工具按鈕的HStack
        .tint(.blue)
        .frame(maxWidth: geometry.size.width * 0.3 , alignment: .trailing)
        .lineLimit(2)
        .font(.body)
    }
}
































struct tradeHeading:View {
    @Environment(\.horizontalSizeClass) var hClass
    @Environment(\.modelContext) private var context
    @EnvironmentObject var ui: uiObject
    @Binding var stock : Stock
    @Binding var filterIsOn:Bool
    @Binding var showTechnical: Bool
    let pageColumn: Bool
    let hidesSummaryIcons: Bool
    let geometry: GeometryProxy

//    var totalSummary: (profit:String, roi:String, days:String) {
//        if let trade = stock.lastTrade(stock.context), trade.rollRounds > 0 {
//            let numberFormatter = NumberFormatter()
//            numberFormatter.numberStyle = .currency   //貨幣格式
//            numberFormatter.maximumFractionDigits = 0
//            let rollAmtProfit = "累計損益" + (numberFormatter.string(for: trade.rollAmtProfit) ?? "$0")
//            let rollAmtRoi = String(format:"年報酬率%.1f%%",trade.rollAmtRoi/stock.years)
//            let rollDays = String(format:"平均週期%.f天",trade.days)
//            return (rollAmtProfit,rollAmtRoi,rollDays)
//        }
//        return ("","","尚無模擬交易")
//    }
    
    var totalSummaryText: some View {
        if let trade = try? stock.lastTrade(in: context), trade.rollRounds > 0 {
            let numberFormatter = NumberFormatter()
            numberFormatter.numberStyle = .currency   //貨幣格式
            numberFormatter.maximumFractionDigits = 0
            var s = AttributedString("")
            let part1 = AttributedString("\(ui.widthClass(hClass) == .compact ? "" : "累計")損益\(numberFormatter.string(for: trade.rollAmtProfit) ?? "$0")")
            s += part1
            var part2 = AttributedString(" 年報酬\(ui.widthClass(hClass) == .compact ? "" : "率")\(String(format: "%.1f%%", trade.roi))")
            part2.foregroundColor = stock.hasManualInvestAdjustment ? .orange : .primary
            s += part2
            var part3 = AttributedString(" \(ui.widthClass(hClass) == .compact ? "" : "平均")週期\(String(format: "%.f天", trade.days))")
            part3.foregroundColor = stock.hasReversedTrade ? .orange : .primary
            s += part3
            let accessibilityHint = [
                stock.hasManualInvestAdjustment ? "年報酬率包含手動加碼" : nil,
                stock.hasReversedTrade ? "平均週期包含反轉買賣" : nil
            ]
            .compactMap { $0 }
            .joined(separator: "；")
            return Text(s)
                .accessibilityHint(accessibilityHint)

        }
        return Text("尚無模擬交易")
            .accessibilityHint("")
    }
    
    var textAutoInvested: Text {
        if stock.simInvestAuto == 10 {
            return Text("自動無限加碼")
                .foregroundColor(.red)
        } else if stock.simInvestAuto > 0 {
            if stock.simInvestExceed > 0 {
                var s = AttributedString("自動\(Int(stock.simInvestAuto)) + \(Int(stock.simInvestExceed))次加碼")
                if let range = s.range(of: "\(Int(stock.simInvestExceed))") {
                    s[range].foregroundColor = .red
                }
                return Text(s)
            } else {
                return Text("自動\(Int(stock.simInvestAuto))次加碼")
            }
        } else {
            return Text("不自動加碼")
                .foregroundColor(.red)
        }
    }


    var body: some View {
        let latestTrade = try? stock.lastTrade(in: context)

        VStack (alignment: .trailing) {
            //=== 單頁面的標題 ===
            if !pageColumn {
                HStack(alignment: .top) {
                    pageTitle(stock: $stock, geometry: geometry)
                    Spacer(minLength: 30)
                    pageTools(stock: $stock, filterIsOn: $filterIsOn, showTechnical: $showTechnical, geometry: geometry)
                }   //sId,sName,工具按鈕的整個HStack
                .font(.title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding()
            }   //Group （表頭）
            runningMsg(padding: 4)
            if stock.simMoneyLacked {
                Text("起始本金不足 ↓↓↓ 模擬結果可能失真")
                    .foregroundColor(.red)
            }
            HStack(spacing: 6) {
                Spacer()

                HistoryBackfillStatusSlot(
                    isPending: stock.needsTWSEHistoryBackfill(in: context),
                    width: 20,
                    font: .caption
                )

                Text(String(format:"期間%.1f年", stock.years))
                Text(stock.simMoneyBase > 0 ? String(format:"起始" + (ui.widthClass(hClass) == .compact ? "" : "本金") + "%.f萬元",stock.simMoneyBase) : "")
                HStack(spacing: 0) {
                    textAutoInvested
                    Text(stock.simInvestUser != 0 ? String(format: "+%.0f", stock.simInvestUser) : "")
                        .foregroundColor(.orange)
                }
            }
            HStack(spacing: 6) {
                Spacer()
                totalSummaryText

                if !hidesSummaryIcons, let latestTrade, latestTrade.days > 0 {
                    GradeTrendIcons(trade: latestTrade)
                        .frame(width: 43, alignment: .center)
                }
            }
        }
        .font(.callout)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.leading)
        .padding(.trailing)
        .frame(width: geometry.size.width, alignment: .trailing)
    }
}


struct tradeCell: View {
    @Environment(\.horizontalSizeClass) var hClass
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var ui: uiObject
    @Binding var stock: Stock    //用@State會造成P10更新怪異
    let trade: Trade
    let technicalSelected: Bool
    let hidesSummaryIcons: Bool
    let onTechnicalSelect: () -> Void
    let geometry: GeometryProxy
    
    private func textSize(textStyle: UIFont.TextStyle) -> CGFloat {
       return UIFont.preferredFont(forTextStyle: textStyle).pointSize
    }

    /// The 13-inch three-column layout retains its existing regular-width row.
    /// Only a narrower trade column, such as a 10-inch iPad with the technical
    /// sidebar open, uses the already-established compact row presentation.
    private var usesCompactTradeLayout: Bool {
        geometry.size.width < 620
    }

    private var effectiveWidthClass: uiObject.WidthClass {
        usesCompactTradeLayout ? .compact : ui.widthClass(hClass)
    }

    private var tradeRowSpacing: CGFloat {
        if hidesSummaryIcons {
            return 2
        }
        return usesCompactTradeLayout ? 1 : 4
    }

    private var dateColumnWidth: CGFloat {
        widthCG(hidesSummaryIcons ? [16] : [22, 19], max: hidesSummaryIcons ? 120 : 150)
    }

    private var priceColumnWidth: CGFloat {
        if hidesSummaryIcons {
            return widthCG([18])
        }
        return widthCG([18, 17], max: 112)
    }

    private var priceBadgeWidth: CGFloat {
        hidesSummaryIcons ? max(priceColumnWidth - 8, 0) : priceColumnWidth
    }

    private var investControlWidth: CGFloat {
        if hidesSummaryIcons {
            return widthCG([18])
        }
        return widthCG(usesCompactTradeLayout ? [12] : [7, 15, 15, 10])
    }

    private var investControlFont: Font {
        if hidesSummaryIcons && compactInvestLabel.contains("加碼") {
            return .footnote
        }
        return .callout
    }

    private func layoutValue(_ values: [CGFloat]) -> CGFloat {
        if usesCompactTradeLayout {
            return values.first ?? values.last ?? 0
        }
        return ui.widthCG(hClass, CG: values)
    }
    
    private func widthCG(_ CG:[CGFloat], width:CGFloat?=nil, max:CGFloat?=100) -> CGFloat {
        var w:CGFloat
        if let w0 = width {
            w = w0
        } else {
            w = geometry.size.width
        }
        let cg = w * layoutValue(CG) / 100
//        NSLog("\(ui.widthClass(hClass)) \(w) \(CG) \(cg)")
        if let limit = max, cg > limit {
            return limit
        } else {
            return cg
        }
    }

    private var showsSimulationMetrics: Bool {
        trade.simQtyInventory > 0 || trade.simQtySell > 0
    }

    private var showsInvestControl: Bool {
        !trade.isBeforeSimulationStart
            && (!usesCompactTradeLayout || !compactInvestLabel.isEmpty)
    }

    private var tradeRowContentWidth: CGFloat {
        var widths = [
            layoutValue([16, 20]),
            dateColumnWidth,
            priceColumnWidth,
            widthCG(usesCompactTradeLayout ? [3] : [4, 4]),
            widthCG(usesCompactTradeLayout ? [6] : [5, 10])
        ]
        if showsSimulationMetrics {
            widths.append(widthCG(usesCompactTradeLayout ? [6] : [7, 8]))
            widths.append(widthCG(usesCompactTradeLayout ? [11] : [10]))
            widths.append(widthCG(usesCompactTradeLayout ? [9] : [12.5, 9]))
        }
        if showsInvestControl {
            widths.append(investControlWidth)
        }
        return widths.reduce(0, +)
            + CGFloat(max(widths.count - 1, 0)) * tradeRowSpacing
    }

    private var suggestionLeadingInset: CGFloat {
        layoutValue([16, 20]) + tradeRowSpacing
    }

    private var suggestionContentWidth: CGFloat {
        max(tradeRowContentWidth - suggestionLeadingInset, 0)
    }

    // Basic price and moving average summary used in compact layout
    var priceAndMA: some View {
        HStack(spacing: 8) {
            // Close price
            Text(String(format: "收盤 %.2f", trade.priceClose))
                .foregroundColor(trade.color(.price))
            // Simple MA display if values appear to be set (non-zero)
            if trade.tMa20Diff != 0 || trade.tMa60Diff != 0 {
                Divider()
                Text(String(format: "MA20Δ %.2f", trade.tMa20Diff))
                    .foregroundColor(.secondary)
                Text(String(format: "MA60Δ %.2f", trade.tMa60Diff))
                    .foregroundColor(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    // Compact simulation summary used in expanded details
    var simSummary: some View {
        HStack(spacing: 12) {
            // Inventory days / holding period
            if trade.simQtyInventory > 0 || trade.simQtySell > 0 {
                Text(String(format: "持有%.0f天", trade.simDays))
                    .foregroundColor(.primary)
            }
            // Unit cost when meaningful
            if trade.simQtyInventory > 0 && trade.simUnitCost > 0 {
                Text(String(format: "成本 %.2f", trade.simUnitCost))
                    .foregroundColor(.secondary)
            }
            // ROI when available
            if trade.simQtySell > 0 || trade.simAmtRoi != 0 {
                Text(String(format: "報酬 %.1f%%", trade.simAmtRoi))
                    .foregroundColor(trade.simQtySell > 0 ? trade.color(.qty) : .gray)
            }
            // Invest indicator
            if trade.simRuleInvest != "" || trade.simInvestByUser != 0 || trade.invested > 0 {
                let investedText: String = {
                    if trade.invested > 0 {
                        return "已加碼(\(Int(trade.simInvestTimes - 1)))"
                    } else if trade.simRuleInvest != "" {
                        return "請加碼"
                    } else {
                        return ""
                    }
                }()
                if !investedText.isEmpty {
                    Text(investedText)
                        .foregroundColor((trade.simInvestByUser != 0 || (trade.simInvestAdded != 0 && trade.simInvestTimes > trade.stock.simInvestAuto + 1)) ? .red : .blue)
                }
            }
        }
        .font(.callout)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    var headerRow: some View {
        HStack(spacing: tradeRowSpacing) {
            //== 1反轉 ==
            Group {
                if !trade.isBeforeSimulationStart {
                    Image(systemName: trade.simReversed == "" ? "circle" : "circle.fill")
                        .foregroundColor(self.ui.isTradeOperationLocked ? .gray : .blue)
                        .onTapGesture {
                            if !self.ui.isTradeOperationLocked {
                                self.ui.setReversed(self.trade)
                            }
                        }
                } else {
                    Text("")
                }
            }
            .frame(width: layoutValue([16,20]), alignment: .center)

            //== 2日期、星期、時間、來源、Grade／趨勢 ==
            HStack(spacing: usesCompactTradeLayout ? 2 : 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(twDateTime.stringFromDate(trade.dateTime))
                        .foregroundColor(trade.color(.time))
                    Text("\(twDateTime.stringFromDate(trade.dateTime, format: "EEE HH:mm")) · \(trade.dataSource)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !hidesSummaryIcons {
                    GradeTrendIcons(
                        trade: trade,
                        gray: trade.isBeforeSimulationStart,
                        spacing: 1.5
                    )
                        .font(usesCompactTradeLayout ? .caption2 : .caption)
                        .frame(width: usesCompactTradeLayout ? 29 : 36, alignment: .center)
                }
            }
            .frame(width: dateColumnWidth, alignment: .leading)

            //== 3單價 ==
            let marketDay = try? MarketDay.fetchSameDay(
                as: trade.date,
                in: modelContext
            )
            let priceStack = PriceBadge(
                trade: trade,
                marketDay: marketDay,
                width: priceBadgeWidth,
                height: 30,
                cornerRadius: 15,
                symbolWidth: 10,
                trendIconSize: effectiveWidthClass == .compact ? 10 : 12,
                showsPricePath: !hidesSummaryIcons
            )
            .font(effectiveWidthClass == .compact ? .footnote : .body)
            priceStack
                .frame(width: priceColumnWidth, alignment: .center)

            //== 4買賣 ==
            Text(trade.simQty.action)
                .frame(
                    width: widthCG(usesCompactTradeLayout ? [3] : [4,4]),
                    alignment: .center
                )
                .foregroundColor(trade.color(.qty))

            //== 5數量 ==
            Text(trade.simQty.qty > 0 ? String(format:"%.f",trade.simQty.qty) : "")
                .frame(
                    width: widthCG(usesCompactTradeLayout ? [6] : [5,10]),
                    alignment: .center
                )
                .foregroundColor(trade.color(.qty))

            //== 6天數,7成本價,8報酬率 ==
            if showsSimulationMetrics {
                Text(String(format:"%.f天",trade.simDays))
                    .frame(
                        width: widthCG(usesCompactTradeLayout ? [6] : [7,8]),
                        alignment: .trailing
                    )

                Text(String(format:"%.2f",trade.simUnitCost))
                    .frame(
                        width: widthCG(usesCompactTradeLayout ? [11] : [10]),
                        alignment: .trailing
                    )
                    .foregroundColor(.gray)
                    .font(usesCompactTradeLayout ? .footnote : .callout)

                Text(String(format:"%.1f%%",trade.simAmtRoi))
                    .frame(
                        width: widthCG(usesCompactTradeLayout ? [9] : [12.5,9]),
                        alignment: .trailing
                    )
                    .foregroundColor(trade.simQtySell > 0 ? trade.color(.qty) : .gray)
                    .font(
                        usesCompactTradeLayout
                            ? .footnote
                            : (trade.simQtySell > 0 ? .body : .callout)
                    )
            }

            //== 9加碼 ==
            if showsInvestControl {
                Text(compactInvestLabel)
                    .foregroundColor(self.ui.isTradeOperationLocked ? .gray : (trade.simInvestByUser != 0 || (trade.simInvestAdded != 0 && trade.simInvestTimes > trade.stock.simInvestAuto + 1) ? .red : .blue))
                    .font(investControlFont)
                    .frame(
                        width: investControlWidth,
                        alignment: .leading
                    )
                    .onTapGesture {
                        if !self.ui.isTradeOperationLocked {
                            self.ui.addInvest(self.trade)
                        }
                    }
            }
        }
        .font(usesCompactTradeLayout ? .callout : .body)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var compactInvestLabel: String {
        guard !trade.isBeforeSimulationStart else { return "" }
        if trade.simRuleInvest == "A" {
            if !usesCompactTradeLayout {
                return "\(trade.invested > 0 ? "已加碼(\(Int(trade.simInvestTimes - 1)))" : "請加碼   ")\(trade.simInvestByUser > 0 ? "+" : (trade.simInvestByUser < 0 ? "-" : " "))"
            }
            return "\(trade.invested > 0 ? "已加碼(\(Int(trade.simInvestTimes - 1)))" : "請加碼")\(trade.simInvestByUser > 0 ? "+" : (trade.simInvestByUser < 0 ? "-" : ""))"
        }
        if trade.simQtyInventory > 0 && (trade.simQtyBuy == 0 || trade.simInvestByUser != 0) {
            if !usesCompactTradeLayout {
                return "\(trade.invested > 0 ? "已加碼(\(Int(trade.simInvestTimes - 1)))" : "+   ")\(trade.simInvestByUser > 0 ? "+" : (trade.simInvestByUser < 0 ? "-" : " "))"
            }
            return "\(trade.invested > 0 ? "已加碼(\(Int(trade.simInvestTimes - 1)))" : "+")\(trade.simInvestByUser > 0 ? "+" : (trade.simInvestByUser < 0 ? "-" : ""))"
        }
        return ""
    }

    private var lowerPriceSuggestions: [String] {
        stock.p10L
            .split(separator: "|")
            .map(String.init)
    }

    private var higherPriceSuggestions: [String] {
        stock.p10H
            .split(separator: "|")
            .map(String.init)
    }

    private var hasStoredIntradaySuggestions: Bool {
        guard let p10Date = stock.p10Date else { return false }
        return trade.date == p10Date
            && (!lowerPriceSuggestions.isEmpty || !higherPriceSuggestions.isEmpty)
            && trade.dataSource.compare("yahoo", options: .caseInsensitive) == .orderedSame
            && twDateTime.isDateInToday(trade.dateTime)
    }

    private func showsIntradaySuggestions(at date: Date) -> Bool {
        hasStoredIntradaySuggestions
            && twDateTime.inMarketingTime(date, forToday: true)
    }

    private func suggestionColor(_ suggestion: String) -> Color {
        suggestion.contains("賣") ? .blue : trade.color(.rule)
    }

    private func suggestionRow(_ suggestions: [String]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                let color = suggestionColor(suggestion)
                Text(suggestion)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(color.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(color.opacity(0.45), lineWidth: 1)
                    )
            }
        }
        .frame(width: suggestionContentWidth, alignment: .leading)
    }

    @ViewBuilder
    private var intradaySuggestions: some View {
        if hasStoredIntradaySuggestions {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if showsIntradaySuggestions(at: context.date) {
                    VStack(alignment: .leading, spacing: 5) {
                        suggestionRow(lowerPriceSuggestions)
                        suggestionRow(higherPriceSuggestions)
                    }
                    .padding(.leading, suggestionLeadingInset)
                    .padding(.bottom, 5)
                }
            }
        }
    }

    var expandedDetails: some View {
        VStack {
            //== 時間及五檔試算 ==
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Text("").frame(width: 20.0, alignment: .center)
                        Text(twDateTime.stringFromDate(trade.dateTime, format: "EEE HH:mm:ss"))
                            .frame(width: widthCG([25,20]), alignment: .leading)
                    }
                    HStack {
                        Text("").frame(width: 20.0, alignment: .center)
                        Text(trade.dataSource)
                            .frame(width: widthCG([25,20]), alignment: .leading)
                    }
                }
                .font(.caption)
                .foregroundColor(trade.color(.time))

                //== 五檔價格試算建議 ==
                if let p10Date = stock.p10Date, trade.date == p10Date {
                    VStack(alignment: .leading, spacing: 2) {
                        let L = stock.p10L.split(separator: "|")
                        let H = stock.p10H.split(separator: "|")
                        if effectiveWidthClass > .compact || (L.count <= 2 && H.count <= 2){
                            HStack {
                                ForEach(L.indices, id:\.self) { i in
                                    Group {
                                        if i > 0 { Divider() }
                                        Text(L[i])
                                    }
                                }
                            }
                            HStack {
                                ForEach(H.indices, id:\.self) { i in
                                    Group {
                                        if i > 0 { Divider() }
                                        Text(H[i])
                                    }
                                }
                            }
                        } else {
                            HStack() {
                                Divider()
                                Text("手機置橫以查看五檔試算")
                                Divider()
                            }
                        }
                    }
                    .font(.custom("Courier", size: textSize(textStyle: .footnote)))
                    .foregroundColor(trade.color(.ruleB))
                    .padding(8)
                }
            }
            Spacer()
            //== 模擬摘要 ==
            if effectiveWidthClass == .compact {
                VStack {
                    HStack {
                        Text("").frame(width: 20.0, alignment: .center)
                        self.priceAndMA
                    }
                    Spacer()
                    HStack {
                        Text("").frame(width: 20.0, alignment: .center)
                        self.simSummary
                    }
                }
                .frame(minHeight:100)
            } else {
                HStack (alignment: .center) {
                    Text("").frame(width: 20.0, alignment: .center)
                    self.priceAndMA
                        .frame(width: widthCG([35], width:geometry.size.width, max:nil))
                    self.simSummary
                        .frame(width: widthCG([55], width:geometry.size.width, max:nil))
                }
                .frame(minHeight:60)
            }
            Spacer()

            //=== 擴充技術數值 ===
            if effectiveWidthClass > .widePhone {
                HStack {
                    Text("").frame(width: 20.0, alignment: .center)
                    Group {
                        VStack(alignment: .trailing,spacing: 2) {
                            Text("")
                            Text("value")
                            Text("max9")
                                .foregroundColor(trade.tMa20DiffMax9 == trade.tMa20Diff || trade.tMa60DiffMax9 == trade.tMa60Diff || trade.tOscMax9 == trade.tOsc || trade.tKdKMax9 == trade.tKdK ? .red : .primary)
                            Text("min9")
                                .foregroundColor(trade.tMa20DiffMin9 == trade.tMa20Diff || trade.tMa60DiffMin9 == trade.tMa60Diff || trade.tOscMin9 == trade.tOsc || trade.tKdKMin9 == trade.tKdK ? .green : .primary)
                            Text("z125")
                            Text("z250")
                        }
                        Spacer()
                        VStack(alignment: .trailing,spacing: 2) {
                            Text("ma20x")
                            Text(String(format:"%.2f",trade.tMa20Diff))
                            Text(String(format:"%.2f",trade.tMa20DiffMax9))
                                .foregroundColor(trade.tMa20DiffMax9 == trade.tMa20Diff ? .red : .primary)
                            Text(String(format:"%.2f",trade.tMa20DiffMin9))
                                .foregroundColor(trade.tMa20DiffMin9 == trade.tMa20Diff ? .green : .primary)
                            Text(String(format:"%.2f",trade.tMa20DiffZ125))
                            Text(String(format:"%.2f",trade.tMa20DiffZ250))
                        }
                        Spacer()
                        VStack(alignment: .trailing,spacing: 2) {
                            Text("ma60x")
                            Text(String(format:"%.2f",trade.tMa60Diff))
                            Text(String(format:"%.2f",trade.tMa60DiffMax9))
                                .foregroundColor(trade.tMa60DiffMax9 == trade.tMa60Diff ? .red : .primary)
                            Text(String(format:"%.2f",trade.tMa60DiffMin9))
                                .foregroundColor(trade.tMa60DiffMin9 == trade.tMa60Diff ? .green : .primary)
                            Text(String(format:"%.2f",trade.tMa60DiffZ125))
                            Text(String(format:"%.2f",trade.tMa60DiffZ250))
                        }
                    }
                    // Replaced Group block with HStack here
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing,spacing: 2) {
                            Text("k")
                            Text(String(format:"%.2f",trade.tKdK))
                            Text(String(format:"%.2f",trade.tKdKMax9))
                                .foregroundColor(trade.tKdKMax9 == trade.tKdK ? .red : .primary)
                            Text(String(format:"%.2f",trade.tKdKMin9))
                                .foregroundColor(trade.tKdKMin9 == trade.tKdK ? .green : .primary)
                            Text(String(format:"%.2f",trade.tKdKZ125))
                            Text(String(format:"%.2f",trade.tKdKZ250))
                        }
                        Spacer()
                        VStack(alignment: .trailing,spacing: 2) {
                            Text("d")
                            Text(String(format:"%.2f",trade.tKdD))
                            Text("-")
                            Text("-")
                            Text(String(format:"%.2f",trade.tKdDZ125))
                            Text(String(format:"%.2f",trade.tKdDZ250))
                        }
                        Spacer()
                        VStack(alignment: .trailing,spacing: 2) {
                            Text("j")
                            Text(String(format:"%.2f",trade.tKdJ))
                            Text("-")
                            Text("-")
                            Text(String(format:"%.2f",trade.tKdJZ125))
                            Text(String(format:"%.2f",trade.tKdJZ250))
                        }
                    }
                    // Replaced Group block with HStack here
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing,spacing: 2) {
                            Text("high")
                            Text(String(format:"%.2f",trade.tHighDiff))
                            Text(String(format:"%.2f",trade.tHighDiff125))
                                .foregroundColor(trade.tHighDiff125 == 0 ? .red : .gray)
                            Text(String(format:"%.2f",trade.tHighDiff250))
                                .foregroundColor(trade.tHighDiff250 == 0 ? .red : .gray)
                            Text(String(format:"%.2f",trade.tHighDiffZ125))
                            Text(String(format:"%.2f",trade.tHighDiffZ250))
                        }
                        Spacer()
                        VStack(alignment: .trailing,spacing: 2) {
                            Text("low")
                            Text(String(format:"%.2f",trade.tLowDiff))
                            Text(String(format:"%.2f",trade.tLowDiff125))
                                .foregroundColor(trade.tLowDiff125 == 0 ? .green : .gray)
                            Text(String(format:"%.2f",trade.tLowDiff250))
                                .foregroundColor(trade.tLowDiff250 == 0 ? .green : .gray)
                            Text(String(format:"%.2f",trade.tLowDiffZ125))
                            Text(String(format:"%.2f",trade.tLowDiffZ250))
                        }
                        Spacer()
                        VStack(alignment: .trailing,spacing: 2) {
                            Text("price")
                            Text(String(format:"%.2f",trade.priceClose))
                            Text(String(format:"%.2f",trade.tHighMax9))
                                .foregroundColor(trade.tHighMax9 == trade.priceClose ? .red : .primary)
                            Text(String(format:"%.2f",trade.tLowMin9))
                                .foregroundColor(trade.tLowMin9 == trade.priceClose ? .green : .primary)
                            Text(String(format:"%.2f",trade.tZ125))
                            Text(String(format:"%.2f",trade.tZ250))
                        }
                        Spacer()
                        VStack(alignment: .trailing,spacing: 2) {
                            Text("volume")
                            Text(String(format:"%.0f",trade.volumeClose))
                            Text(String(format:"%.0f",trade.vMax9))
                                .foregroundColor(trade.vMax9 == trade.volumeClose ? .red : .primary)
                            Text(String(format:"%.0f",trade.vMin9))
                                .foregroundColor(trade.vMin9 == trade.volumeClose ? .green : .primary)
                            Text(String(format:"%.2f",trade.vZ125))
                            Text(String(format:"%.2f",trade.vZ250))
                        }
                    }
                    Spacer()
                }
                .font(.custom("Courier", size: textSize(textStyle: .footnote)))
                .frame(minHeight: 100, alignment: .top)
            }
        }
    }

    @ViewBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                onTechnicalSelect()
            } label: {
                headerRow
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "選取 \(twDateTime.stringFromDate(trade.dateTime)) 的交易"
            )

            intradaySuggestions
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .contentShape(Rectangle())
        .listRowBackground(
            technicalSelected
                ? Color.accentColor.opacity(0.10)
                : Color.clear
        )
    }

}

private enum nineDayPosition {
    case high
    case low
    case normal
}

struct tradeTechnicalView: View {
    @Environment(\.modelContext) private var modelContext
    let stock: Stock
    let trade: Trade
    let showsCloseButton: Bool
    let showsDateNavigation: Bool
    let onClose: () -> Void
    let onNewer: () -> Void
    let onOlder: () -> Void

    private func storedNineDayPosition(
        value: Double,
        maximum: Double,
        minimum: Double
    ) -> nineDayPosition {
        if value == maximum { return .high }
        if value == minimum { return .low }
        return .normal
    }

    private func positionColor(_ position: nineDayPosition) -> Color {
        switch position {
        case .high: return .red
        case .low: return .green
        case .normal: return .primary
        }
    }

    private func positionBadge(_ position: nineDayPosition) -> String? {
        switch position {
        case .high: return "9日最高"
        case .low: return "9日最低"
        case .normal: return nil
        }
    }

    private func limitSymbol(for value: Double) -> String? {
        if trade.tLowDiff == 10 && value == trade.priceLow { return "arrow.down.to.line" }
        if trade.tHighDiff == 10 && value == trade.priceHigh { return "arrow.up.to.line" }
        return nil
    }

    private func price(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private var gradeAccessibilityText: String {
        switch trade.grade {
        case .wow: return "紅星"
        case .high: return "高"
        case .fine: return "良"
        case .none: return "一般"
        case .weak: return "弱"
        case .low: return "低"
        case .damn: return "差"
        }
    }

    private var cumulativePerformanceMetric: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("累計損益")
                Spacer()
                Text("平均週期")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    cumulativeProfitValue
                        .fixedSize(horizontal: true, vertical: false)
                    cumulativeGradeTrendValues
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 8)

                    cumulativeAverageCycleValue
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        cumulativeProfitValue
                        cumulativeGradeTrendValues
                    }

                    Spacer(minLength: 8)

                    cumulativeAverageCycleValue
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "累計損益 \(String(format: "%.2f萬元", trade.rollAmtProfit / 10_000))，"
            + "實年報酬率 \(percent(trade.roi))，平均週期 \(String(format: "%.f天", trade.days))，"
            + "評等 \(gradeAccessibilityText)"
            + (trade.strategyFitTrendAccessibilityText.map { "，\($0)" } ?? "")
        )
    }

    private var cumulativeProfitValue: some View {
        Text(
            String(
                format: "%.2f萬元 (%.1f%%)",
                trade.rollAmtProfit / 10_000,
                trade.roi
            )
        )
        .font(.body.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }

    private var cumulativeGradeTrendValues: some View {
        GradeTrendIcons(trade: trade, showsValues: true)
            .font(.caption)
    }

    private var cumulativeAverageCycleValue: some View {
        Text(String(format: "%.f天", trade.days))
            .font(.body.monospacedDigit())
            .lineLimit(1)
    }

    private var sameDayMarket: MarketDay? {
        try? MarketDay.fetchSameDay(as: trade.date, in: modelContext)
    }

    private var closeAndMarketMetric: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trade.dataSource == "TWSE" ? "收盤" : "成交價")
                Spacer()
                Text("加權指數")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Text(price(trade.priceClose))
                    .font(.title2.monospacedDigit())
                    .fontWeight(.semibold)
                    .foregroundColor(trade.color(.price, price: trade.priceClose))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Group {
                    if let symbol = limitSymbol(for: trade.priceClose) {
                        Image(systemName: symbol)
                            .font(.caption.weight(.bold))
                            .foregroundColor(trade.color(.price, price: trade.priceClose))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14, alignment: .trailing)

                PricePathTrendIcon(
                    phase: trade.pricePathPhase,
                    gray: false
                )

                Spacer(minLength: 8)

                if let market = sameDayMarket {
                    Text(price(market.indexClose))
                        .font(.body.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    PricePathTrendIcon(
                        phase: market.pricePathPhase,
                        gray: false
                    )
                    .accessibilityLabel(
                        "加權指數價格趨勢，\(market.pricePathPhase.displayName)"
                    )
                } else {
                    Text("—")
                        .font(.body.monospacedDigit())
                        .foregroundColor(.secondary)
                    Color.clear
                        .frame(width: 15, height: 15)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(closeAndMarketAccessibilityLabel)
    }

    private var closeAndMarketAccessibilityLabel: String {
        let tradeLabel = trade.dataSource == "TWSE" ? "收盤" : "成交價"
        guard let market = sameDayMarket else {
            return "\(tradeLabel) \(price(trade.priceClose))，加權指數當日尚無資料"
        }
        return "\(tradeLabel) \(price(trade.priceClose))，"
            + "加權指數 \(price(market.indexClose))，"
            + "價格趨勢 \(market.pricePathPhase.displayName)"
    }

    private func metric(
        _ title: String,
        value: String,
        color: Color = .primary,
        badge: String? = nil,
        symbol: String? = nil,
        showsPricePath: Bool = false,
        emphasized: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(color.opacity(0.12), in: Capsule())
                }
            }
            HStack(spacing: 4) {
                Text(value)
                    .font(emphasized ? .title2.monospacedDigit() : .body.monospacedDigit())
                    .fontWeight(emphasized ? .semibold : .regular)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption.weight(.bold))
                        .foregroundColor(color)
                }
                if showsPricePath {
                    PricePathTrendIcon(
                        phase: trade.pricePathPhase,
                        gray: false
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            content()
        }
    }

    private func equalRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 7) {
            content()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if showsCloseButton {
                    Button(action: onClose) {
                        Label("交易紀錄", systemImage: "chevron.left")
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(stock.sId) \(stock.sName)")
                        .font(.headline)
                    Text("技術檢視")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !showsCloseButton {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("關閉技術檢視")
                }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        if showsDateNavigation {
                            Button(action: onNewer) {
                                Label("較新", systemImage: "chevron.left")
                            }
                        }
                        Spacer()
                        Text(twDateTime.stringFromDate(trade.dateTime))
                            .font(.subheadline.weight(.semibold))
                        Text("\(twDateTime.stringFromDate(trade.dateTime, format: "EEE HH:mm")) · \(trade.dataSource)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if showsDateNavigation {
                            Button(action: onOlder) {
                                Label("較舊", systemImage: "chevron.right")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }

                    section("行情") {
                        closeAndMarketMetric
                        equalRow {
                            metric(
                                "開盤",
                                value: price(trade.priceOpen),
                                color: trade.color(.price, price: trade.priceOpen),
                                symbol: limitSymbol(for: trade.priceOpen)
                            )
                            metric(
                                "最高",
                                value: price(trade.priceHigh),
                                color: trade.tHighDiff > 7.5
                                    ? .red
                                    : trade.color(.price, price: trade.priceHigh),
                                symbol: limitSymbol(for: trade.priceHigh)
                            )
                            metric(
                                "最低",
                                value: price(trade.priceLow),
                                color: trade.tLowDiff == 10
                                    ? .green
                                    : trade.color(.price, price: trade.priceLow),
                                symbol: limitSymbol(for: trade.priceLow)
                            )
                        }
                    }

                    section("均線") {
                        equalRow {
                            metric(
                                "MA20",
                                value: price(trade.tMa20)
                            )
                            metric(
                                "MA60",
                                value: price(trade.tMa60)
                            )
                        }
                    }

                    section("成交量") {
                        let volumePosition = storedNineDayPosition(
                            value: trade.volumeClose,
                            maximum: trade.vMax9,
                            minimum: trade.vMin9
                        )
                        equalRow {
                            metric(
                                "V Z125",
                                value: price(trade.vZ125)
                            )
                            metric(
                                "當日成交量",
                                value: String(format: "%.0f", trade.volumeClose),
                                color: positionColor(volumePosition),
                                badge: positionBadge(volumePosition)
                            )
                        }
                    }

                    section("技術指標") {
                        let kPosition = storedNineDayPosition(
                            value: trade.tKdK,
                            maximum: trade.tKdKMax9,
                            minimum: trade.tKdKMin9
                        )
                        let oscPosition = storedNineDayPosition(
                            value: trade.tOsc,
                            maximum: trade.tOscMax9,
                            minimum: trade.tOscMin9
                        )
                        equalRow {
                            metric(
                                "K",
                                value: price(trade.tKdK),
                                color: positionColor(kPosition),
                                badge: positionBadge(kPosition)
                            )
                            metric(
                                "D",
                                value: price(trade.tKdD)
                            )
                            metric(
                                "J",
                                value: price(trade.tKdJ)
                            )
                        }
                        metric(
                            "OSC",
                            value: price(trade.tOsc),
                            color: positionColor(oscPosition),
                            badge: positionBadge(oscPosition)
                        )
                    }

                    section("模擬績效") {
                        cumulativePerformanceMetric
                        equalRow {
                            metric(
                                "本輪損益",
                                value: String(format: "%.0f仟元", trade.simAmtProfit / 1_000)
                            )
                            metric(
                                "本金餘額",
                                value: String(format: "%.0f萬元", trade.simAmtBalance / 10_000)
                            )
                        }
                        equalRow {
                            metric("本輪報酬", value: percent(trade.simAmtRoi))
                            metric("真年報酬", value: percent(trade.baseRoi))
                        }
                        metric("單位成本", value: price(trade.simUnitCost))
                    }
                }
                .padding(12)
            }
            .background(Color(.systemGroupedBackground))
        }
    }
}

//struct sheetLog: View {
//    @Environment(\.dismiss) private var dismiss
//    @Binding var showLog: Bool
//
//    var body: some View {
//        NavigationView {
//            ScrollView {
//                VStack(alignment: .leading, spacing: 8) {
//                    Text("執行紀錄")
//                        .font(.title2)
//                        .padding(.bottom, 4)
//                    // TODO: Replace with real log content when available.
//                    Text("尚無可顯示的紀錄。")
//                        .foregroundColor(.secondary)
//                }
//                .padding()
//            }
//            .navigationTitle("Log")
//            .toolbar {
//                ToolbarItem(placement: .cancellationAction) {
//                    Button("關閉") {
//                        showLog = false
//                        dismiss()
//                    }
//                }
//            }
//        }
//        .navigationViewStyle(StackNavigationViewStyle())
//    }
//}
