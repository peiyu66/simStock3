import SwiftUI

extension TrueAnnualReturnWarning.Snapshot {
    var prewarningMessage: String {
        switch prewarningReason {
        case .priceBottom: "警戒先行解除後，價格再次進入探底。"
        case .both: "價格再次探底，模擬報酬也轉弱。"
        case .returnWeakness: "模擬報酬轉弱，價格相對均線也偏弱。"
        case .anchorWeakness: "突破解除後，價格、真年報酬及評等或損益共同轉弱。"
        case .returnAndAnchor: "模擬報酬與價格偏弱，突破解除時的效能也未能維持。"
        case .bottomAndAnchor: "價格再次探底，突破解除時的報酬及效能也轉弱。"
        case .all: "價格探底與報酬轉弱，突破解除時的效能也未能維持。"
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
        if let reference = breakoutReference, reference.isFinite, reference > 0 {
            values.append(IconExplanation.number("突破觀察參照", reference, unit: "元"))
            if let days = breakoutConfirmationDays {
                values.append("已連續站穩 \(days) 個交易日，仍須通過報酬與效能確認")
            }
        } else {
            values.append(status == .unavailable ? "突破觀察參照 — · 資料不足" : "突破觀察參照 — · 目前沒有有效突破觀察")
        }
        if anchorFailureDays == 1 {
            values.append("解除後複合轉弱第 1 日；連續第 2 日成立時恢復警戒")
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
                    Text("突破觀察在價格突破此前20筆最高收盤、恢復條件成立時開始，參照價在這次觀察內固定。至少連續3筆站在參照價及20日均線上，且報酬與效能確認改善，才可能先行解除；突破本身不代表立即解除。")
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
                Text("突破解除後，價格低於20日均線且低於解除價或突破參照、前日真年報酬低於解除時，並且評等分數或累計損益也低於解除時：首日預警，連續第2日恢復警戒。單獨跌破一個價位不成立。")
                Text("有效資料下，連續 3 個交易日不符合預警條件即移除預警；若轉入警戒，由警戒提示取代。")
                Text("預警須有成熟有效的 Z125 資料。先行解除後，價格轉入探底前期或後期，可觸發預警。")
                Text("報酬預警：前日真年報酬率不高於其20個交易日前、低於其60個交易日前，且兩條均線乖離的 Z125 都小於 0。")
            } else {
                Text("完整解除：價格不低於60日均線，該均線不低於20個交易日前；前日真年報酬率達完整恢復參考值，且高於其20個交易日前。")
                Text("未達完整恢復參考值，也可能先行解除，方式如下：")
                Text("近期穩定：前日評等分數比其20、60個交易日前退步皆不超過10%，累計損益距前日及此前60筆觀察的高點回落不超過10%；價格站上20日、60日均線，兩線均向上延續。")
                Text("突破解除：價格與60日均線恢復、近期報酬回升，且評等或均線確認轉強。突破此前20筆最高收盤後，連續至少3筆站穩參照價及20日均線；前日真年報酬高於觀察起點，累計損益不低於起點，評等分數不低於起點及其20、60筆前。")
                Text("突破觀察最長20筆；收盤回到參照價或20日均線以下（含相等）即結束這次觀察。之後須重新符合突破條件。")
                Text("轉強確認：前日評等改善探頂；或價格站上20日與60日均線，兩條均線的向上延續計數都超過20。")
                Text("先行解除仍保留原參考值，不代表已獲利或不會虧損；價格轉入探底可先預警。")
                Text("價格跌破20日均線、報酬轉弱且評等離開改善探頂，或原警戒條件再成立，就恢復警戒。")
                Text("突破解除另檢查價格、真年報酬與評等或損益是否共同低於解除時；首日預警、連續第2日再警戒，並非只看跌破突破價。完整解除優先。")
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
