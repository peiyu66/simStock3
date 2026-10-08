import SwiftUI

extension TrueAnnualReturnWarning.Snapshot {
    var prewarningMessage: String {
        switch prewarningReason {
        case .priceBottom: "警戒先行解除後，價格再次進入探底。"
        case .both: "價格再次探底，模擬報酬也轉弱。"
        case .returnWeakness: "模擬報酬轉弱，價格相對均線也偏弱。"
        case nil: "近期出現轉弱訊號。"
        }
    }

    var explanationMessage: String {
        if isPrewarning {
            if let days = prewarningFailureDays, days > 0 {
                return "預警條件已連續 \(days) 個交易日不成立，滿 3 日移除預警。\n先前提示：" + prewarningMessage
            }
            return prewarningMessage
        }
        return switch status {
        case .caution: "先前模擬報酬與價格同步轉弱，尚未符合解除條件。短暫反彈不代表已恢復。"
        case .recovering: "價格與近期模擬報酬已改善，評等趨勢也在改善探頂；目前仍在警戒內。"
        case .unavailable: "資料不足或尚待重算，暫時無法判讀；不代表已解除警示。"
        case .normal: "目前未觸發警戒，不代表未來不會虧損。"
        case .released: "已符合先行解除條件，仍保留原完整恢復參考值。"
        }
    }

    var explanationValues: [String] {
        var values = [IconExplanation.number("前一交易日真年報酬率", priorAnnual, unit: "%")]
        if !isPrewarning && (status == .caution || status == .recovering) {
            values.append(IconExplanation.number("完整恢復參考值", recoveryFloor, unit: "%"))
            if let gap = recoveryGap, gap.isFinite {
                values.append(gap == 0 ? "報酬已達參考值，仍須符合其他解除條件" :
                    gap < 0.005 ? "尚差不到 0.01 個百分點" : String(format: "尚差 %.2f 個百分點", gap))
            } else {
                values.append("距完整恢復參考值 — · 資料不足")
            }
        }
        if warningPriceHigh == nil && status == .normal {
            values.append("價格突破參照 — · 尚未建立警戒參照")
        } else {
            values.append(IconExplanation.number("價格突破參照",
                warningPriceHigh.flatMap { $0 > 0 ? $0 : nil }, unit: "元"))
        }
        return values
    }

    var title: String {
        if isPrewarning { return "預警" }
        return switch status {
        case .caution: "警戒中"
        case .recovering: "恢復觀察"
        case .unavailable: "警示資料不足"
        case .normal: "未觸發警示"
        case .released: "近期解除"
        }
    }
    var symbol: String {
        if isPrewarning { return "exclamationmark.triangle" }
        return status == .recovering ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill"
    }
}

struct TrueAnnualReturnWarningIcon: View {
    let snapshot: TrueAnnualReturnWarning.Snapshot
    let trade: Trade
    var size: CGFloat = 12
    var showsExplanation = false
    @State private var showsDetails = false

    var body: some View {
        Group {
            if snapshot.isWarning {
                if showsExplanation {
                    Button { showsDetails = true } label: {
                        Image(systemName: snapshot.symbol)
                            .font(.system(size: size, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(width: size + 2, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("趨勢與報酬：\(snapshot.title)")
                    .accessibilityHint("查看警示與解除條件；恢復觀察仍在警戒內")
                    .popover(isPresented: $showsDetails) {
                        TrueAnnualReturnWarningDetails(snapshot: snapshot, trade: trade)
                            .presentationCompactAdaptation(.popover)
                    }
                } else {
                    Image(systemName: snapshot.symbol)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: size + 2, height: 30)
                        .accessibilityLabel("趨勢與報酬：\(snapshot.title)")
                }
            } else {
                Color.clear.frame(width: size + 2, height: 30).accessibilityHidden(true)
            }
        }
    }
}

struct TrueAnnualReturnWarningDetails: View {
    let snapshot: TrueAnnualReturnWarning.Snapshot
    let trade: Trade
    @ScaledMetric(relativeTo: .callout) private var preferredWidth = 320.0
    @ScaledMetric(relativeTo: .callout) private var preferredHeight = 340.0
    @State private var showsConditions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(snapshot.title, systemImage: snapshot.symbol)
                .font(.headline)
                .foregroundStyle(.orange)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(trade.explanationContext).font(.footnote).foregroundStyle(.secondary)
                    Text(snapshot.explanationMessage)
                    ForEach(snapshot.explanationValues, id: \.self) { value in
                        Text(value).monospacedDigit()
                    }
                    Text("價格突破參照是先行解除條件之一，取初次警戒前60筆至前一交易日的最高收盤價，隨新高更新，並非固定的初次高點；突破不代表立即解除。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if snapshot.isPrewarning && !trade.explanationTechnicalPending {
                        Text("當日價格階段 \(trade.pricePathPhase.displayName)")
                    }
                    if !trade.explanationTechnicalPending {
                        Text(IconExplanation.number("當日60日均線", trade.tMa60 > 0 ? trade.tMa60 : nil, unit: "元")).monospacedDigit()
                    } else {
                        Text("當日技術值待重算").foregroundStyle(.secondary)
                    }
                    DisclosureGroup("判讀與解除條件", isExpanded: $showsConditions) {
                        conditions
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollIndicatorsFlash(trigger: showsConditions)
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .lineLimit(nil)
        .minimumScaleFactor(1)
        .multilineTextAlignment(.leading)
        .frame(width: min(preferredWidth, 400))
        .frame(minHeight: 0, idealHeight: min(preferredHeight, 480), maxHeight: min(preferredHeight, 480))
    }

    @ViewBuilder
    private var conditions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.isPrewarning {
                Text("有效資料下，連續 3 個交易日不符合預警條件即移除預警；若轉入警戒，由警戒提示取代。")
                Text("預警須有成熟有效的 Z125 資料。先行解除後，價格轉入探底前期或後期，可觸發預警。")
                Text("報酬預警：前日真年報酬率不高於其20個交易日前、低於其60個交易日前，且兩條均線乖離的 Z125 都小於 0。")
            } else {
                Text("完整解除：價格不低於60日均線，該均線不低於20個交易日前；前日真年報酬率達完整恢復參考值，且高於其20個交易日前。")
                Text("未達完整恢復參考值，也可能先行解除，方式如下：")
                Text("近期穩定：前日評等分數比其20、60個交易日前退步皆不超過10%，累計損益距前日及此前60筆觀察的高點回落不超過10%；價格站上20日、60日均線，兩線均向上延續。")
                Text("創高恢復：價格與60日均線恢復、近期報酬回升，且評等或均線確認轉強；價格突破初次警戒前60筆至前一交易日的最高收盤價，前日報酬也高於其前60筆觀察。")
                Text("轉強確認：前日評等改善探頂；或價格站上20日與60日均線，兩條均線的向上延續計數都超過20。")
                Text("先行解除仍保留原參考值，不代表已獲利或不會虧損；價格轉入探底可先預警。")
                Text("價格跌破20日均線、報酬轉弱且評等離開改善探頂，或原警戒條件再成立，就恢復警戒。")
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
