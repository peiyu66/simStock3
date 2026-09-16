import SwiftUI

extension TrueAnnualReturnWarning.Snapshot {
    var prewarningMessage: String {
        switch prewarningReason {
        case .priceBottom: "近期解除後，價格轉入探底。"
        case .both: "價格轉入探底，報酬也走弱。"
        case .returnWeakness: "報酬走弱，價格相對偏弱。"
        case nil: "近期出現轉弱訊號。"
        }
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
    var size: CGFloat = 12
    @State private var showsDetails = false

    var body: some View {
        Group {
            if snapshot.isWarning {
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
                    TrueAnnualReturnWarningDetails(snapshot: snapshot)
                        .presentationCompactAdaptation(.popover)
                }
            } else {
                Color.clear.frame(width: size + 2, height: 30).accessibilityHidden(true)
            }
        }
    }
}

struct TrueAnnualReturnWarningDetails: View {
    let snapshot: TrueAnnualReturnWarning.Snapshot
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
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    DisclosureGroup("解除條件", isExpanded: $showsConditions) {
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
        .frame(width: min(preferredWidth, 400), height: min(preferredHeight, 480))
    }

    @ViewBuilder
    private var summary: some View {
        if snapshot.isPrewarning {
            if let failed = snapshot.prewarningFailureDays, failed > 0 {
                Text("條件已連續 \(failed) 日不成立，滿 3 日解除。")
                Text("先前提示：" + snapshot.prewarningMessage)
                    .foregroundStyle(.secondary)
            } else {
                Text(snapshot.prewarningMessage)
            }
        } else {
            if snapshot.status == .recovering {
                Text("近期改善，尚未解除警戒。")
            }
            if let annual = snapshot.priorAnnual, let floor = snapshot.recoveryFloor {
                Text(String(format: "前日真年報酬率 %.2f%%", annual))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "恢復目標 %.2f%%", floor))
                        .monospacedDigit()
                    if let gap = snapshot.recoveryGap, gap > 0 {
                        Text(gap < 0.005 ? "尚差不到 0.01 個百分點" :
                             String(format: "尚差 %.2f 個百分點", gap))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if !snapshot.priceRecovered { Text("價格／60日均線未恢復") }
                if !snapshot.recentReturnRecovered { Text("報酬未高於20日前") }
                if !snapshot.gradeSeekingPeak && !snapshot.maRecoveryConfirmed {
                    Text("評等／均線尚未確認轉強")
                }
            }
        }
    }

    @ViewBuilder
    private var conditions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.isPrewarning {
                Text("連續 3 日不符合預警條件即解除。")
                Text("近期解除後，價格轉入探底前期或後期，即先預警。")
                Text("報酬預警：前日真年報酬率不高於其20日前、低於其60日前，且兩條均線乖離的 Z125 都小於 0。")
            } else {
                Text("完整解除：價格與60日均線恢復，前日真年報酬率達恢復目標，且高於其20日前。")
                Text("近期解除：價格與60日均線恢復、近期報酬回升，且評等或均線確認轉強；價格突破警戒前60日至昨日高點，前日報酬也創此前60日新高。")
                Text("轉強確認：前日評等改善探頂；或價格站上20日與60日均線，兩條均線的向上延續計數都超過20。")
                if let high = snapshot.warningPriceHigh {
                    Text(String(format: "價格突破參照 %.2f", high)).monospacedDigit()
                }
                Text("近期解除後，價格轉入探底先預警。")
                Text("價格跌破20日均線、報酬轉弱且評等離開改善探頂，或原警戒條件再成立，就恢復警戒。")
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
