import SwiftUI

struct GradeTrendIcons: View {
    let trade: Trade
    var gray = false
    var spacing: CGFloat = 3
    var showsValues = false

    var body: some View {
        HStack(spacing: spacing) {
            trade.gradeIcon(gray: gray)
            if showsValues {
                Text(String(format: "%.2f", trade.gradeEfficiencyScore))
                    .monospacedDigit()
            }
            StrategyFitTrendIcon(
                classification: trade.strategyFitTrendDisplayClassification,
                gray: gray
            )
            if showsValues {
                Text(trade.simFitTrend.map { String(format: "%.2f", $0) } ?? "--")
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let trend = trade.strategyFitTrendAccessibilityText else {
            return "選股評等"
        }
        return "選股評等，\(trend)"
    }
}

private struct StrategyFitTrendIcon: View {
    let classification: StrategyFitTrendDisplayClassification
    let gray: Bool

    var body: some View {
        Group {
            switch classification {
            case .improvingWarning:
                Image(systemName: "arrow.up.right.circle.fill")
                    .foregroundStyle(gray ? Color.gray : Color.orange)
            case .worseningWarning:
                Image(systemName: "arrow.down.right.circle.fill")
                    .foregroundStyle(
                        gray
                            ? Color.gray
                            : Color(red: 0.60, green: 0.67, blue: 0.20)
                    )
            case .improvingConfirmed:
                Image(systemName: "arrow.up.right.circle.fill")
                    .foregroundStyle(gray ? Color.gray : Color.red)
            case .worseningConfirmed:
                Image(systemName: "arrow.down.right.circle.fill")
                    .foregroundStyle(gray ? Color.gray : Color.green)
            case .stable, .unavailable:
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .font(.caption2.weight(.bold))
        .frame(width: 15, height: 15, alignment: .center)
    }
}
