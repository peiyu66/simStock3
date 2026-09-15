import SwiftUI

extension TrueAnnualReturnWarning.Snapshot {
    var title: String {
        switch status {
        case .caution: "警戒中"
        case .recovering: "恢復觀察"
        case .unavailable: "警示資料不足"
        case .normal: "未觸發警示"
        case .released: "近期解除"
        }
    }
    var symbol: String {
        status == .recovering ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill"
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
                .accessibilityLabel("真年報酬率：\(snapshot.title)")
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

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Label(snapshot.title, systemImage: snapshot.symbol)
                .font(.headline).foregroundStyle(.orange)
            if snapshot.status == .recovering {
                Text("價格、近期真年報酬率與評等趨勢出現改善，仍未解除警戒。")
            } else {
                Text("整體報酬尚未符合完整恢復條件，留意反覆投入的風險。")
            }
            if let annual = snapshot.priorAnnual, let floor = snapshot.recoveryFloor {
                Text(String(format: "前一交易日真年報酬率 %.2f%%\n報酬恢復參照 %.2f%%", annual, floor))
                    .monospacedDigit()
                if let gap = snapshot.recoveryGap, gap > 0 {
                    Text(gap < 0.005 ? "距報酬參照尚差不到0.01個百分點" :
                         String(format: "距報酬參照尚差 %.2f 個百分點", gap))
                }
            }
            if let high = snapshot.warningPriceHigh {
                Text(String(format: "警戒期間價格高點 %.2f", high)).monospacedDigit()
            }
            if !snapshot.priceRecovered { Text("價格或60日均線尚未恢復。") }
            if !snapshot.recentReturnRecovered { Text("真年報酬率尚未高於20個交易日前。") }
            if !snapshot.gradeSeekingPeak { Text("前一交易日評等趨勢未處於改善探頂，不列恢復觀察。") }
            Text("價格與60日均線恢復，真年報酬率回到凍結參照且高於20個交易日前，即完整解除。恢復觀察中，價格突破警戒前60日至今高點、前日真年報酬率突破此前60日高點，也可近期解除；仍保留參照，跌破20日均線、近期報酬轉弱且評等離開改善探頂時再警戒。警示不改變模擬買賣。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(20)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320, height: 420)
    }
}
