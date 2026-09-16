import SwiftUI

/// Presentation-only copy: reads existing results without requesting replay.
struct IconExplanation: Equatable {
    var title: String
    var message: String
    var context: String? = nil
    var values: [String] = []
    var details: String? = nil
    var emphasizesLoss = false
    var contextValue: String? = nil

    static let selection = Self(title: "選取股票", message: "選取後可一起修改股群。")
    static let investment = Self(title: "手動加碼", message: "調整這一天的加碼設定。")
    static let technical = Self(title: "技術檢視", message: "查看這一天的行情、指標與模擬結果。")
    static let updateStock = Self(title: "更新此股", message: "檢查並更新這支股票的行情。")
    static let updateGroup = Self(title: "更新股價", message: "檢查並更新股群行情。")
    static let stockSettings = Self(title: "個股模擬設定", message: "調整這支股票的本金、期間與加碼。")
    static let groupSettings = Self(title: "模擬設定", message: "調整股群的本金、期間與加碼。")
    static let reference = Self(title: "參考訊息", message: "開啟小確幸網站或個股技術分析。")
    static let cleanup = Self(title: "清理歷史資料", message: "查看可清理的歷史資料範圍。")
    static let sidebar = Self(title: "股群清單", message: "顯示或收起左側股票清單。")
    static let removal = Self(title: "移出股群", message: "將股票移出目前股群。")
    static let snapshot = Self(title: "回測快照", message: "目前顯示保存的回測結果。")
    static let history = Self(title: "歷史待補齊", message: "所需歷史價格尚未下載完整。")

    static func reversal(isReversed: Bool) -> Self {
        Self(title: isReversed ? "已手動反轉" : "反轉買賣",
             message: isReversed ? "這一天已設定手動反轉。" : "調整這一天的買賣決定。")
    }
    static func filter(isOn: Bool) -> Self {
        Self(title: isOn ? "顯示重要紀錄" : "顯示全部日期",
             message: isOn ? "點按後，恢復全部日期。" : "點按後，只看交易及重要紀錄。")
    }
    static func diagnostic(unread: Int) -> Self {
        Self(title: unread > 0 ? "有新異常" : "更新診斷",
             message: unread > 0 ? "有 \(unread) 項尚未查看的更新異常。" : "查看資料更新與異常紀錄。")
    }
    static func limit(isUpper: Bool, context: String? = nil) -> Self {
        let name = isUpper ? "漲停" : "跌停"
        return Self(title: name, message: "這筆行情的價格已達\(name)。", context: context)
    }
    func dated(_ context: String) -> Self {
        var copy = self
        copy.context = context
        return copy
    }
}

struct IconExplanationView: View {
    let explanation: IconExplanation
    @ScaledMetric(relativeTo: .callout) private var width = 320.0
    @ScaledMetric(relativeTo: .callout) private var height = 300.0
    @State private var expanded = false
    @State private var contentHeight = 180.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(explanation.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if explanation.context != nil || explanation.contextValue != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            if let context = explanation.context {
                                Text(context).font(.footnote).foregroundStyle(.secondary)
                            }
                            if let value = explanation.contextValue {
                                Text(value).monospacedDigit()
                            }
                        }
                    }
                    Text(explanation.message)
                        .foregroundStyle(explanation.emphasizesLoss ? Color.orange : Color.primary)
                        .fontWeight(explanation.emphasizesLoss ? .semibold : .regular)
                    ForEach(Array(explanation.values.enumerated()), id: \.offset) { _, value in
                        Text(value).monospacedDigit()
                    }
                    if let details = explanation.details {
                        DisclosureGroup("判讀方式", isExpanded: $expanded) {
                            Text(details).foregroundStyle(.secondary).padding(.top, 8)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, min(height, 400)))
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollIndicatorsFlash(trigger: expanded)
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .lineLimit(nil)
        .minimumScaleFactor(1)
        .multilineTextAlignment(.leading)
        .frame(width: min(width, 400))
    }
}

private struct InformationExplanationModifier: ViewModifier {
    let explanation: IconExplanation?
    @State private var presented = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let explanation {
            Button { presented = true } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .accessibilityLabel(explanation.title)
                .accessibilityHint("點按查看說明")
                .popover(isPresented: $presented) {
                    IconExplanationView(explanation: explanation)
                        .presentationCompactAdaptation(.popover)
                }
        } else {
            content
        }
    }
}

extension View {
    func explainedAction(_ explanation: IconExplanation, enabled: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) { self }
            .buttonStyle(ExplainedOperationStyle(explanation: explanation))
            .disabled(!enabled)
    }

    func iconExplanation(_ explanation: IconExplanation?) -> some View {
        modifier(InformationExplanationModifier(explanation: explanation))
    }
}

/// Owns both gestures so release after a long press cannot execute the command.
struct ExplainedOperationStyle: PrimitiveButtonStyle {
    let explanation: IconExplanation

    func makeBody(configuration: Configuration) -> some View {
        ExplainedOperationBody(configuration: configuration, explanation: explanation)
    }
}

private struct ExplainedOperationBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let explanation: IconExplanation
    @Environment(\.isEnabled) private var isEnabled
    @State private var presented = false

    var body: some View {
        configuration.label
            .foregroundStyle(.tint)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .exclusively(before: TapGesture())
                    .onEnded { result in
                        guard isEnabled else { return }
                        switch result {
                        case .first(true): presented = true
                        case .second: configuration.trigger()
                        default: break
                        }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("長按查看說明")
            .accessibilityAction {
                if isEnabled { configuration.trigger() }
            }
            .accessibilityAction(named: "顯示說明") { presented = true }
            .popover(isPresented: $presented) {
                IconExplanationView(explanation: explanation)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

@MainActor
extension Trade {
    var explanationContext: String {
        "\(stock.sName) · \(twDateTime.stringFromDate(dateTime))"
    }

    var gradeExplanation: IconExplanation {
        if isBeforeSimulationStart {
            return IconExplanation(title: "模擬前資料", message: "此日只用來準備技術值，尚未開始模擬。", context: explanationContext)
        }
        if stock.simMoneyLacked {
            return IconExplanation(title: "選股評等｜資金不足", message: "模擬曾無法買進一張，評等可能失真。", context: explanationContext)
        }
        let name: String
        let efficiency: String
        switch grade {
        case .wow: (name, efficiency) = ("紅星", "效率屬最高一級")
        case .high: (name, efficiency) = ("紅框 2", "效率高")
        case .fine: (name, efficiency) = ("紅框 1", "效率較佳")
        case .none: (name, efficiency) = ("尚未評等", "")
        case .weak: (name, efficiency) = ("綠框 1", "效率偏弱")
        case .low: (name, efficiency) = ("綠框 2", "效率低")
        case .damn: (name, efficiency) = ("綠框 3", "效率屬最低一級")
        }

        // Use this date's unrounded cumulative return, not the latest Stock summary
        // or a displayed annual rate that can round a small loss to -0.0%.
        let hasReturn = rollAmtRoi.isFinite
        let hasLoss = hasReturn && rollAmtRoi < 0
        let message: String
        let details: String
        if grade == .none {
            message = "買賣輪數與持股天數尚未達評等條件。"
            details = "完成至少 3 輪買賣，或平均持股超過 360 天後啟用。"
        } else if !hasReturn {
            message = "累計報酬資料不足。"
            details = "依實年報酬率與持股週期評等；目前無法解讀累計盈虧。"
        } else if hasLoss {
            message = "累計虧損，\(efficiency)。"
            details = "依實年報酬率與持股週期評等。虧損越深、持股越久，效率越差。"
        } else if rollAmtRoi > 0 {
            message = "累計獲利\(grade == .weak || grade == .low || grade == .damn ? "，但" : "，")\(efficiency)。"
            details = "依實年報酬率與持股週期評等。報酬越高、持股越短，效率越好。"
        } else {
            message = "累計損益持平，\(efficiency)。"
            details = "依實年報酬率與持股週期評等。目前累計損益為零。"
        }
        return IconExplanation(title: "選股評等｜\(name)", message: message, context: explanationContext,
                               values: grade == .none ? [] : [
                                roi.isFinite ? String(format: "實年報酬率 %.1f%%", roi) : "實年報酬率資料不足",
                                days.isFinite ? String(format: "平均持股 %.0f 天", days) : "持股天數資料不足"
                               ], details: details, emphasizesLoss: grade != .none && hasLoss)
    }

    var pricePathExplanation: IconExplanation {
        .pricePath(phase: pricePathPhase, context: explanationContext)
    }

    var gradeTrendExplanation: IconExplanation {
        let name: String
        let message: String
        let maturity = strategyFitTrendConfirmedMaturity
        let late = maturity == .late
        switch strategyFitTrendDisplayPhase {
        case .improvingWarning: (name, message) = ("改善預警", "近期效率開始轉強，尚未確認改善。")
        case .worseningWarning: (name, message) = ("惡化預警", "近期效率開始轉弱，尚未確認惡化。")
        case .improvingConfirmedSeekingPeak:
            name = maturity == nil ? "改善探頂" : (late ? "改善探頂後期" : "改善探頂前期")
            message = maturity == nil ? "效率已確認改善；前後期資料不足。" : (late ? "效率已確認改善，本段改善幅度已進入後段。" : "效率已確認改善，仍在前段。")
        case .worseningConfirmedSeekingBottom:
            name = maturity == nil ? "惡化探底" : (late ? "惡化探底後期" : "惡化探底前期")
            message = maturity == nil ? "效率已確認惡化；前後期資料不足。" : (late ? "效率已確認惡化，本段惡化幅度已進入後段。" : "效率已確認惡化，仍在前段。")
        case .improvingConfirmedPullingBack:
            (name, message) = ("改善拉回", "改善趨勢中的效率回落。")
        case .worseningConfirmedRebounding:
            (name, message) = ("惡化反彈", "惡化趨勢中的效率回升。")
        case .improvingConfirmed: (name, message) = ("改善確認", "效率已確認改善。")
        case .worseningConfirmed: (name, message) = ("惡化確認", "效率已確認惡化。")
        case .neutral: (name, message) = ("中性", "效率變化尚未達提示門檻。")
        case .improvingCooldown, .worseningCooldown: (name, message) = ("等待新趨勢", "前段確認已結束，等待重新形成趨勢。")
        case .unavailable: (name, message) = ("資料不足", "有效效率紀錄尚不足。")
        }
        let interpretation: String
        switch strategyFitTrendDisplayPhase {
        case .improvingWarning:
            interpretation = "近期效率高於長期，差距達預警門檻；擴大至確認門檻才確認改善。"
        case .worseningWarning:
            interpretation = "近期效率低於長期，差距達預警門檻；擴大至確認門檻才確認惡化。"
        case .improvingConfirmedSeekingPeak:
            interpretation = "近期效率明顯高於長期，確認改善；本段改善幅度達較高門檻時，進入探頂後期。"
        case .worseningConfirmedSeekingBottom:
            interpretation = "近期效率明顯低於長期，確認惡化；本段惡化幅度達較高門檻時，進入探底後期。"
        case .improvingConfirmedPullingBack:
            interpretation = "改善確認後，趨勢值由本段高點回落超過門檻，進入拉回。"
        case .worseningConfirmedRebounding:
            interpretation = "惡化確認後，趨勢值由本段低點回升超過門檻，進入反彈。"
        case .improvingConfirmed:
            interpretation = "近期效率高於長期，差距超過確認門檻，列為改善確認。"
        case .worseningConfirmed:
            interpretation = "近期效率低於長期，差距超過確認門檻，列為惡化確認。"
        case .neutral:
            interpretation = "短長期差距未達預警門檻，暫不提示方向。"
        case .improvingCooldown, .worseningCooldown:
            interpretation = "確認後，短長期差距已縮小，等待重新形成趨勢。"
        case .unavailable:
            interpretation = "有效效率紀錄不足，暫不判斷方向。"
        }
        let details = "比較近期與長期的平均模擬效率，形成趨勢值。" + interpretation
        return IconExplanation(title: "評等趨勢｜\(name)", message: message, context: explanationContext, details: details)
    }
}

extension IconExplanation {
    static func pricePath(phase: PricePathPhase, context: String, isMarket: Bool = false) -> Self {
        let noun = isMarket ? "指數" : "價格"
        let message: String
        switch phase {
        case .seekingPeakEarly: message = "\(noun)向上延伸，仍在前段。"
        case .seekingPeakLate: message = "\(noun)向上延伸已進入後段，未必到頂。"
        case .pullingBackEarly: message = "\(noun)由本段高點回落，仍在前段。"
        case .pullingBackLate: message = "\(noun)由本段高點回落，幅度已進入後段。"
        case .seekingBottomEarly: message = "\(noun)向下延伸，仍在前段。"
        case .seekingBottomLate: message = "\(noun)向下延伸已進入後段，未必到底。"
        case .reboundingEarly: message = "\(noun)由本段低點回升，仍在前段。"
        case .reboundingLate: message = "\(noun)由本段低點回升，幅度已進入後段。"
        case .sideways: message = "尚未形成明確方向。"
        case .unavailable: message = "有效價格資料尚不足。"
        }
        let calculation: String
        switch phase {
        case .seekingPeakEarly, .seekingPeakLate:
            calculation = "由本段起點累積上漲；漲幅達較高門檻時，進入探頂後期。"
        case .seekingBottomEarly, .seekingBottomLate:
            calculation = "由本段起點累積下跌；跌幅達較高門檻時，進入探底後期。"
        case .pullingBackEarly, .pullingBackLate:
            calculation = "由本段高點回落達門檻，進入拉回；回落幅度達較高門檻時，進入後期。"
        case .reboundingEarly, .reboundingLate:
            calculation = "由本段低點回升達門檻，進入反彈；回升幅度達較高門檻時，進入後期。"
        case .sideways:
            calculation = "漲跌幅尚未達門檻，或原趨勢一段時間未創新高／新低時，列為盤整。"
        case .unavailable:
            calculation = "需累積足夠的有效行情，才能開始判斷。"
        }
        let details = "依近期波動設定本段的判斷門檻。" + calculation
        return Self(title: "\(isMarket ? "加權指數" : "個股價格")｜\(phase.displayName)", message: message,
                    context: context, details: details)
    }

    @MainActor
    static func market(_ day: MarketDay) -> Self {
        let source: String
        if day.isOfficial {
            source = "TWSE"
        } else if day.dataSource.localizedCaseInsensitiveContains("yahoo"), let quote = day.quoteTime {
            source = twDateTime.inMarketingTime(quote) ? "Yahoo 盤中" : "Yahoo 收盤補查"
        } else {
            source = day.dataSource
        }
        var result = pricePath(phase: day.pricePathPhase,
                               context: "\(twDateTime.stringFromDate(day.dateTime)) · \(source)", isMarket: true)
        result.contextValue = day.indexClose.isFinite && day.indexClose > 0
            ? String(format: "指數 %.2f", day.indexClose) : "指數資料不足"
        return result
    }
}
