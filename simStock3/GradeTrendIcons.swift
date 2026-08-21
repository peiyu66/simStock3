import SwiftUI

struct GradeTrendIcons: View {
    let trade: Trade
    var gray = false
    var spacing: CGFloat = 3

    var body: some View {
        HStack(spacing: spacing) {
            trade.gradeIcon(gray: gray)
            StrategyFitTrendIcon(
                classification: trade.strategyFitTrendClassification,
                gray: gray
            )
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
    let classification: StrategyFitTrendClassification
    let gray: Bool

    var body: some View {
        Group {
            switch classification {
            case .improving:
                Image(systemName: "arrow.up.right.circle.fill")
                    .foregroundStyle(gray ? Color.gray : Color.blue)
            case .worsening:
                Image(systemName: "arrow.down.right.circle.fill")
                    .foregroundStyle(gray ? Color.gray : Color.orange)
            case .stable, .unavailable:
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .font(.caption2.weight(.bold))
        .frame(width: 15, height: 15, alignment: .center)
    }
}
