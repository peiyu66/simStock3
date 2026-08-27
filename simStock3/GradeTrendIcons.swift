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
                phase: trade.strategyFitTrendDisplayPhase,
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
    let phase: StrategyFitTrendPhase
    let gray: Bool

    var body: some View {
        Group {
            if let systemName = phase.displayIconSystemName {
                Image(systemName: systemName)
                    .foregroundStyle(iconColor)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .font(.caption2.weight(.bold))
        .frame(width: 15, height: 15, alignment: .center)
    }

    private var iconColor: Color {
        guard !gray else { return .gray }
        switch phase {
        case .improvingWarning:
            return .orange
        case .worseningWarning:
            return Color(red: 0.60, green: 0.67, blue: 0.20)
        case .improvingConfirmed, .improvingConfirmedSeekingPeak,
             .improvingConfirmedPullingBack:
            return .red
        case .worseningConfirmed, .worseningConfirmedSeekingBottom,
             .worseningConfirmedRebounding:
            return .green
        case .unavailable, .neutral, .improvingCooldown, .worseningCooldown:
            return .clear
        }
    }
}
