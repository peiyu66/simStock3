//
//  simStockPageView.swift
//  simStock21
//
//  Created by peiyu on 2020/6/28.
//  Copyright © 2020 peiyu. All rights reserved.
//

import SwiftUI
import Combine

struct viewPage: View {
    @Environment(\.horizontalSizeClass) var hClass
    @Environment(\.modelContext) private var context
    @EnvironmentObject var ui: uiObject
    @State var stock : Stock
    @State var prefix: String
    @State var showPrefixMsg:Bool = false
    @State var groupPrefixsOnly:Bool = true
    @State var filterIsOn = false

    func pageViewTools(_ geometry:GeometryProxy) -> some View {
        Group {
            if ui.pageColumn(hClass) {
                pageTools(stock: $stock, filterIsOn: $filterIsOn, geometry: geometry)
            } else {
                prefixPicker(prefix:self.$prefix, stock:self.$stock, groupPrefixsOnly: self.$groupPrefixsOnly, geometry: geometry)
            }
        }
    }
    
    func pageViewTitle(_ geometry:GeometryProxy) -> some View {
        Group {
            if ui.pageColumn(hClass) {
                pageTitle(stock: $stock, geometry: geometry)
            } else {
                EmptyView()
            }
        }
    }
    
    var body: some View {
        GeometryReader { geo in
            VStack (alignment: .center) {
                tradeListView(stock: self.$stock, prefix: self.$prefix, filterIsOn: $filterIsOn, groupPrefixsOnly: self.$groupPrefixsOnly, geometry: geo)
                if !ui.doubleColumn { //!ui.pageColumn(hClass)
                    Spacer(minLength: 24)   //不知為何是24？
                    stockPicker(prefix: self.$prefix, stock: self.$stock, groupPrefixsOnly: self.$groupPrefixsOnly,  geometry: geo)
                        .alert(isPresented: $showPrefixMsg) {
                            Alert(title: Text("提醒您"), message: Text("有多股的首字相同時，\n於畫面底處可按切換。"), dismissButton: .default(Text("知道了。")))
                        }
                }
            }
            .navigationBarItems(leading: pageViewTitle(geo), trailing: pageViewTools(geo))
            .onAppear {
                ui.pageStock = self.stock
                if !ui.pageColumn(hClass) && ui.versionLast == "" && ui.prefixStocks(prefix: prefix, group: (groupPrefixsOnly ? stock.group : nil)).count > 1 {
                    showPrefixMsg = true
                }
            }
        }
    }
}


struct tradeListView: View {
    @Environment(\.horizontalSizeClass) var hClass
    @Environment(\.modelContext) private var context
    @EnvironmentObject var ui: uiObject
    @Binding var stock : Stock
    @Binding var prefix: String
    @Binding var filterIsOn:Bool
    @Binding var groupPrefixsOnly:Bool
    @State var geometry:GeometryProxy
    
    private func scrollToSelected(_ sv: ScrollViewProxy) {
        if let dt = ui.selected {
            sv.scrollTo(dt, anchor: .center)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            //== 表頭：股票名稱、模擬摘要 ==
            tradeHeading(stock: self.$stock, filterIsOn: self.$filterIsOn, geometry: geometry)
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
                    LazyVStack {
                        Divider()
                        List (stock.trades.filter{self.filterIsOn == false || $0.simInvestByUser != 0 || $0.simReversed != "" || $0.simQtySell > 0 || $0.simQtyBuy > 0 || $0.simRuleInvest != "" || $0.date == $0.stock.dateFirst || $0.date == twDateTime.startOfDay()}, id:\.self.date) { trade in
                            tradeCell(stock: self.$stock, trade: trade, geometry: geometry)
                                .onTapGesture {
                                    if ui.selected == trade.date {
                                        ui.selected = nil
                                    } else {
                                        ui.selected = trade.date
                                    }
                                 }
                        }
                        .offset(x: 0, y: -8)
                        .listStyle(GroupedListStyle())
                        .frame(width: geo.size.width, height: geo.size.height + 8, alignment: .center)
                    }
                    .background(Color(.systemGroupedBackground))
                    .onChange(of: stock) {
                        scrollToSelected(sv)
                        ui.pageStock = self.stock
                    }
                    .onChange(of: self.filterIsOn) {
                        scrollToSelected(sv)
                    }
                    .onAppear() {
                        if ui.selected == nil {
                            ui.selected = try? stock.lastTrade(in: context)?.date
                        } else {
                            scrollToSelected(sv)
                        }
                    }
                }
            }
        }   //VStack
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
    @State var geometry:GeometryProxy
    
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
                        self.stock = self.ui.prefixStocks(prefix: value, group: (groupPrefixsOnly ? stock.group : nil))[0]
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
    @State   var geometry:GeometryProxy
    
    var allStocks:[Stock] {
        ui.prefixStocks(prefix: self.prefix, group: (groupPrefixsOnly ? stock.group : nil))
    }
    
    var prefixStocks:[Stock] {
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
    @State var saveToDefaults:Bool = false

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
                Section(header: Text("擴大設定範圍").font(.title),footer: Text(self.ui.simDefaults.text).font(.footnote)) {
                    Toggle("套用到全部股", isOn: $applyToAll)
                    .onReceive([self.applyToAll].publisher.first()) { (value) in
                        if value == true {
                            self.applyToGroup = value
                        }
                    }
                    Toggle("套用到同股群 [\(stock.group)]", isOn: $applyToGroup)
                        .disabled(self.applyToAll)
                    Toggle("作為新股預設值", isOn: $saveToDefaults)
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
            DispatchQueue.global().async {
                self.ui.applySetting(self.stock, dateStart: self.dateStart, moneyBase: self.moneyBase, autoInvest: self.autoInvest, applyToGroup: self.applyToGroup, applyToAll: self.applyToAll, saveToDefaults: self.saveToDefaults)
            }
            self.showSetting = false
        }
    }
    

    
}

struct pageTitle: View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var stock: Stock
    @State var geometry:GeometryProxy

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
            .foregroundColor(ui.isRunning ? .gray : .primary)
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

struct pageTools:View {
    @Environment(\.horizontalSizeClass) var hClass
    @EnvironmentObject var ui: uiObject
    @Binding var stock : Stock
    @State var showReload:Bool = false
    @State var deleteAll:Bool = false
    @State var showDeleteAlert:Bool = false
    @State var showSetting: Bool = false
    @State var showInformation:Bool = false
    @State var showLog:Bool = false
    @Binding var filterIsOn:Bool
    @State var geometry:GeometryProxy

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
            //== 工具按鈕 1 == 過濾交易模擬
            Button(action: {self.filterIsOn = !self.filterIsOn}) {
                if self.filterIsOn {
                    Image(systemName: "square.2.stack.3d")
                        .foregroundColor(.red)
                } else {
                    Image(systemName: "square.3.stack.3d")
                }
            }
            .padding(.trailing, ui.widthClass(hClass) == .compact ? 2 : 8)

            //== 工具按鈕 2 == 查看log
            Button(action: {self.showLog = true}) {
                Image(systemName: "doc.text")
            }
            .sheet(isPresented: $showLog) {
                sheetLog(showLog: self.$showLog)
            }

            //== 工具按鈕 3 == 設定
            Button(action: {self.showSetting = true}) {
                Image(systemName: "wrench")
            }
            .disabled(ui.isRunning)
            .sheet(isPresented: $showSetting) {
                sheetPageSetting(stock: self.$stock, showSetting: self.$showSetting, dateStart: self.stock.dateStart, moneyBase: self.stock.simMoneyBase, autoInvest: self.stock.simInvestAuto)
                    .environmentObject(ui)
            }
            
            //== 工具按鈕 4 == 刪除或重算
//            Spacer()
            Button(action: {self.showReload = true}) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(ui.isRunning)
            .actionSheet(isPresented: $showReload) {
                ActionSheet(title: Text("立即更新"), message: Text("刪除或重算？"), buttons: [
                    .default(Text("重算模擬")) {
                        self.ui.reloadNow([self.stock], action: .simResetAll)
                    },
                    .default(Text("重算技術數值")) {
                        self.ui.reloadNow([self.stock], action: .tUpdateAll)
                    },
                    .default(Text("刪除最後1個月")) {
                        self.deleteAll = false
                        self.showDeleteAlert = true
                    },
                    .default(Text("刪除全部")) {
                        self.deleteAll = true
                        self.showDeleteAlert = true
                    },
                    .default(Text("[TWSE復驗]")) {
                        backgroundRequest(context: context, technical: ui.sim.tech).reviseWithTWSE([self.stock])
                    },
                    .destructive(Text("沒事，不用了。"))
                ])
            }
            .alert(isPresented: self.$showDeleteAlert) {
                Alert(title: Text("刪除\(deleteAll ? "全部" : "最後1個月")歷史價"), message: Text("刪除歷史價，再重新下載、計算。"), primaryButton: .default(Text("刪除"), action: {
                        self.ui.deleteTrades([self.stock], oneMonth: !deleteAll)
                }), secondaryButton: .default(Text("取消"), action: {showDeleteAlert = false}))
            }
            
            //== 工具按鈕 5 == 參考訊息
//            Spacer()
            Button(action: {self.showInformation = true}) {
                Image(systemName: "questionmark.circle")
            }
//            .padding(.trailing, ui.widthCG(hClass, CG: [2,8]))
            .padding(.trailing, ui.widthClass(hClass) == .compact ? 2 : 8)
            .actionSheet(isPresented: $showInformation) {
                ActionSheet(title: Text("參考訊息"), message: Text("小確幸v\(ui.versionNow)"),
                buttons: [
                    .default(Text("小確幸網站")) {
                        self.openUrl("https://peiyu66.github.io/simStock21/")
                    },
                    .default(Text("鉅亨個股走勢")) {
                        self.openUrl("https://invest.cnyes.com/twstock/tws/" + self.stock.sId)
                    },
                    .default(Text("Yahoo!技術分析")) {
                        self.openUrl("https://tw.stock.yahoo.com/q/ta?s=" + self.stock.sId)
                    },
                    .destructive(Text("沒事，不用了。"))
                ])
            }
        } //工具按鈕的HStack
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
    @State var geometry:GeometryProxy

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
            var part2 = AttributedString(" 年報酬\(ui.widthClass(hClass) == .compact ? "" : "率")\(String(format: "%.1f%%", trade.rollAmtRoi/stock.years))")
            part2.foregroundColor = stock.simInvestUser > 0 ? .orange : .primary
            s += part2
            var part3 = AttributedString(" \(ui.widthClass(hClass) == .compact ? "" : "平均")週期\(String(format: "%.f天", trade.days))")
            part3.foregroundColor = stock.simReversed ? .orange : .primary
            s += part3
            return Text(s)

        }
        return Text("尚無模擬交易")
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
        VStack (alignment: .trailing) {
            //=== 單頁面的標題 ===
            if !ui.doubleColumn {
                HStack(alignment: .top) {
                    pageTitle(stock: $stock, geometry: geometry)
                    Spacer(minLength: 30)
                    pageTools(stock: $stock, filterIsOn: $filterIsOn, geometry: geometry)
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
            HStack {
                Spacer()
                Text(String(format:"期間%.1f年", stock.years))
                Text(stock.simMoneyBase > 0 ? String(format:"起始" + (ui.widthClass(hClass) == .compact ? "" : "本金") + "%.f萬元",stock.simMoneyBase) : "")
                HStack(spacing: 0) {
                    textAutoInvested
                    Text(stock.simInvestUser != 0 ? String(format: "+%.0f", stock.simInvestUser) : "")
                        .foregroundColor(.orange)
                }
            }
            HStack {
                if let trade = try? stock.lastTrade(in: context), trade.days > 0 {
                    trade.gradeIcon()
                        .frame(width:25, alignment: .trailing)
                } else {
                    EmptyView()
                }
                totalSummaryText
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
    @EnvironmentObject var ui: uiObject
    @Binding var stock: Stock    //用@State會造成P10更新怪異
    @State var trade:Trade
    @State var geometry:GeometryProxy
    
    private func textSize(textStyle: UIFont.TextStyle) -> CGFloat {
       return UIFont.preferredFont(forTextStyle: textStyle).pointSize
    }
    
    private func widthCG(_ CG:[CGFloat], width:CGFloat?=nil, max:CGFloat?=100) -> CGFloat {
        var w:CGFloat
        if let w0 = width {
            w = w0
        } else {
            w = geometry.size.width
        }
        let cg = w * ui.widthCG(hClass, CG: CG) / 100
//        NSLog("\(ui.widthClass(hClass)) \(w) \(CG) \(cg)")
        if let limit = max, cg > limit {
            return limit
        } else {
            return cg
        }
    }

    
    var priceAndMA: some View {
        GeometryReader { geo in
            HStack {
                VStack(alignment: .leading,spacing: 2) {
                    Text("開盤")
                    Text(trade.tHighDiff == 10 ? "漲停" : "最高")
                        .foregroundColor(trade.tHighDiff == 10 ? .red : .primary)
                    Text(trade.tLowDiff == 10 ? "跌停" : "最低")
                        .foregroundColor(trade.tLowDiff == 10 ? .green : .primary)
                }
                .frame(minWidth: widthCG([15], width:geo.size.width) , alignment: .trailing)
                VStack(alignment: .trailing,spacing: 2) {
                    Text(String(format:"%.2f",trade.priceOpen))
                        .foregroundColor(trade.color(.price, price:trade.priceOpen))
                    Text(String(format:"%.2f",trade.priceHigh))
                        .foregroundColor(trade.tHighDiff > 7.5 ? .red : trade.color(.price, price:trade.priceHigh))
                    Text(String(format:"%.2f",trade.priceLow))
                        .foregroundColor(trade.tLowDiff == 10 ? .green : trade.color(.price, price:trade.priceLow))
                }
                .frame(minWidth: widthCG([20], width:geo.size.width) , alignment: .trailing)
                Spacer(minLength: widthCG([5,4], width:geo.size.width))
                VStack(alignment: .leading,spacing: 2) {
                    Text(twDateTime.inMarketingTime(trade.dateTime) ? "成交" : "收盤")
                        .foregroundColor(trade.color(.time))
                    Text("MA20")
                    Text("MA60")
                }
                .frame(minWidth: widthCG([15], width:geo.size.width) , alignment: .trailing)
                VStack(alignment: .trailing,spacing: 2) {
                    Text(String(format:"%.2f",trade.priceClose))
                        .foregroundColor(trade.color(.price, price:trade.priceClose))
                    Text(String(format:"%.2f",trade.tMa20))
                    Text(String(format:"%.2f",trade.tMa60))
                }
                .frame(minWidth: widthCG([20], width:geo.size.width) , alignment: .trailing)
                Spacer(minLength: widthCG([5], width:geo.size.width))
            }
            .minimumScaleFactor(0.5)
            .font(.custom("Courier", size: textSize(textStyle: .callout)))
            .frame(minHeight:40)
        }
    }
    
    var simSummary: some View {
        func vText(_ txt: [String], leadingSpace: Bool=true) -> some View {
            VStack (alignment: .trailing, spacing: 4){
                let maxLength = txt.map{$0.count}.max() ?? 0
                ForEach(txt, id:\.self) { t in
                    let bb = maxLength > 0 && leadingSpace ? String (repeatElement(" ", count: (maxLength - t.count))) : ""
                    Text(bb + t)
                }
            }
        }

        return GeometryReader { geo in
            HStack {
                if trade.simRule != "_" {
                    let L1 = [String(format:"%.f輪 \(trade.simRuleBuy)",trade.rollRounds),
                             "本金餘額",
                             "本輪損益"]
                    let V1 = [String(format:"平均%.f天",trade.days),
                             String(format:"%.f萬元",trade.simAmtBalance/10000),
                             trade.simDays > 0 ? String(format:"%.f仟元",trade.simAmtProfit/1000) : "-"]
                    vText(L1, leadingSpace: false)
                        .frame(minWidth: widthCG([13,14], width:geo.size.width))
                    vText(V1)
                        .frame(minWidth: widthCG([14], width:geo.size.width))
                    Spacer(minLength: widthCG([4], width:geo.size.width))
                    if trade.simDays > 0 {
                        let L2 = ["單位成本",
                                 "本輪成本",
                                 "單輪成本"]
                        let V2 = [String(format:"%.2f元",trade.simUnitCost),
                                 String(format:"%.1f萬元",trade.simAmtCost/10000),
                                 String(format:"%.1f萬元",trade.rollAmtCost/10000)]
                        vText(L2, leadingSpace: false)
                            .frame(minWidth: widthCG([13,14], width:geo.size.width))
                        vText(V2)
                            .frame(minWidth: widthCG([18], width:geo.size.width))
                        Spacer(minLength: widthCG([4], width:geo.size.width))
                    }
                    let L3 = ["本輪報酬",
                             "實年報酬",
                             "真年報酬"]
                    let V3 = [trade.simDays > 0 ? String(format:"%.1f%%",trade.simAmtRoi) : "-",
                              String(format:(trade.rollAmtRoi/stock.years < 100 ? " " : "") + "%.1f%%",trade.rollAmtRoi/stock.years),
                             String(format:"%.1f%%",trade.baseRoi)]
                    vText(L3, leadingSpace: false)
                        .frame(minWidth: widthCG([13,14], width:geo.size.width))
                    vText(V3)
                        .frame(minWidth: widthCG([10,10], width:geo.size.width))
                } else {   //if trade.simRule != "_"
                    EmptyView()
                }
            } //HStack
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .font(.custom("Courier", size: textSize(textStyle: .footnote)))
            .frame(minHeight:50)
            .frame(width: geo.size.width)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                //== 1反轉 ==
                Group {
                    if trade.simRule != "_" {
                        Image(systemName: trade.simReversed == "" ? "circle" : "circle.fill")
                            .foregroundColor(self.ui.isRunning ? .gray : .blue)
                            .onTapGesture {
                                if !self.ui.isRunning {
                                    self.ui.setReversed(self.trade)
                                }
                            }
                    } else {
                        Text("")
                    }
                }
                .frame(width: ui.widthCG(hClass, CG:[16,20]), alignment: .center)
                //== 2日期,3單價 ==
                Text(twDateTime.stringFromDate(trade.dateTime))
                    .foregroundColor(trade.color(.time))
                    .frame(width: widthCG([20,15]), alignment: .leading)
                HStack (spacing:2){
                    Text("  ")
                    Text(String(format:"%.2f",trade.priceClose))
                    Group {
                        if trade.tLowDiff == 10 && trade.priceClose == trade.priceLow {
                            Image(systemName: "arrow.down.to.line")
                        } else if trade.tHighDiff == 10 && trade.priceClose == trade.priceHigh {
                            Image(systemName: "arrow.up.to.line")
                        } else {
                            Text("  ")
                        }
                    }
                    .font(ui.widthClass(hClass) == .compact ? .footnote : .body)
                }
                    .frame(width: widthCG([20,15]), alignment: .center)
                    .foregroundColor(trade.color(.price))
                    .background(RoundedRectangle(cornerRadius: 20).fill(trade.color(.ruleB)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(trade.color(.ruleR), lineWidth: 1)
                    )


                //== 4買賣,5數量 ==
                Text(trade.simQty.action)
                    .frame(width: widthCG([4,4]), alignment: .center)
                    .foregroundColor(trade.color(.qty))
                Text(trade.simQty.qty > 0 ? String(format:"%.f",trade.simQty.qty) : "")
                    .frame(width: widthCG([9,10]), alignment: .center)
                    .foregroundColor(trade.color(.qty))
                //== 6天數,7成本價,8報酬率 ==
                if trade.simQtyInventory > 0 || trade.simQtySell > 0 {
                    Text(String(format:"%.f天",trade.simDays))
                        .frame(width: widthCG([9,8]), alignment: .trailing)
                    if ui.widthClass(hClass) > .compact {
                        Text(String(format:"%.2f",trade.simUnitCost))
                            .frame(width: widthCG([10]), alignment: .trailing)
                            .foregroundColor(.gray)
                            .font(.callout)
                    }
                    if ui.widthClass(hClass) > .compact || trade.simQtySell > 0 {
                        Text(String(format:"%.1f%%",trade.simAmtRoi))
                            .frame(width: widthCG([12.5,9]), alignment: .trailing)
                            .foregroundColor(trade.simQtySell > 0 ? trade.color(.qty) : .gray)
                            .font(trade.simQtySell > 0 ? .body : .callout)
                    }
                } else {
                    EmptyView()
                }
                //== 9加碼 ==
                Group {
                    if trade.simRuleInvest == "A" { //trade.invested = simInvestByUser + simInvestAdded
                        Text("\(trade.invested > 0 ? "已加碼(\(Int(trade.simInvestTimes - 1)))" : "請加碼   ")\(trade.simInvestByUser > 0 ? "+" : (trade.simInvestByUser < 0 ? "-" : " "))")
                    } else if trade.simQtyInventory > 0 && (trade.simQtyBuy == 0 || trade.simInvestByUser != 0) {
                        Text("\(trade.invested > 0 ? "已加碼(\(Int(trade.simInvestTimes - 1)))" : "+   ")\(trade.simInvestByUser > 0 ? "+" : (trade.simInvestByUser < 0 ? "-" : " "))")
                    }
                }
                .foregroundColor(self.ui.isRunning ? .gray : (trade.simInvestByUser != 0 || (trade.simInvestAdded != 0 && trade.simInvestTimes > trade.stock.simInvestAuto + 1) ? .red : .blue))
                .font(.callout)
                .frame(width: widthCG([15,15]), alignment: .leading)
                .onTapGesture {
                    if !self.ui.isRunning {
                        self.ui.addInvest(self.trade)
                    }
                }
            }   //HStack
            .font(.body)
            if ui.selected == trade.date {
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
                            if ui.widthClass(hClass) > .compact || (L.count <= 2 && H.count <= 2){
                                HStack {
                                    ForEach(L.indices, id:\.self) { i in
                                        Group {
                                            if i > 0 {
                                                Divider()
                                            }
                                            Text(L[i])
                                        }
                                    }
                                }
                                HStack {
                                    ForEach(H.indices, id:\.self) { i in
                                        Group {
                                            if i > 0 {
                                                Divider()
                                            }
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
                } //HStack
                Spacer()
                //== 模擬摘要 ==
                if ui.widthClass(hClass) == .compact {
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
                if ui.widthClass(hClass) > .widePhone {
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
                        Group {
                            Spacer()
                            VStack(alignment: .trailing,spacing: 2) {
                                Text("osc")
                                Text(String(format:"%.2f",trade.tOsc))
                                Text(String(format:"%.2f",trade.tOscMax9))
                                .foregroundColor(trade.tOscMax9 == trade.tOsc ? .red : .primary)
                                Text(String(format:"%.2f",trade.tOscMin9))
                                .foregroundColor(trade.tOscMin9 == trade.tOsc ? .green : .primary)
                                Text(String(format:"%.2f",trade.tOscZ125))
                                Text(String(format:"%.2f",trade.tOscZ250))
                            }
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
                        Group {
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
                                Text(String(format:"%.2f",trade.tPriceZ125))
                                Text(String(format:"%.2f",trade.tPriceZ250))
                            }
                            Spacer()
                            VStack(alignment: .trailing,spacing: 2) {
                                Text("volume")
                                Text(String(format:"%.0f",trade.priceVolume))
                                Text(String(format:"%.0f",trade.tVolMax9))
                                    .foregroundColor(trade.tVolMax9 == trade.priceVolume ? .red : .primary)
                                Text(String(format:"%.0f",trade.tVolMin9))
                                    .foregroundColor(trade.tVolMin9 == trade.priceVolume ? .green : .primary)
                                Text(String(format:"%.2f",trade.tVolZ125))
                                Text(String(format:"%.2f",trade.tVolZ250))
                            }
                        }
                        Spacer()
                    }   //HStack
                    .font(.custom("Courier", size: textSize(textStyle: .footnote)))
                    .frame(minHeight: 100, alignment: .top)
                }
            }   //If
        }   //VStack
        .lineLimit(1)
        .minimumScaleFactor(0.5)
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

