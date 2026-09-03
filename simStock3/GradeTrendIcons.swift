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

struct StrategyFitTrendIcon: View {
    let phase: StrategyFitTrendPhase
    let gray: Bool
    var size: CGFloat = 15
    var showsContrastBackground = false

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
        .frame(width: size, height: size, alignment: .center)
        .background {
            if showsContrastBackground, phase.displayIconSystemName != nil {
                Circle()
                    .fill(.white.opacity(0.94))
                    .frame(width: size + 2, height: size + 2)
            }
        }
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

struct PricePathTrendIcon: View {
    let phase: PricePathPhase
    let gray: Bool
    var size: CGFloat = 15
    var showsContrastBackground = false

    var body: some View {
        ZStack {
            StrategyFitTrendIcon(
                phase: phase.strategyFitIconPhase,
                gray: gray,
                size: size,
                showsContrastBackground: showsContrastBackground
            )

            if phase.stageLine != .none {
                Capsule()
                    .fill(stageLineColor)
                    .frame(
                        width: max(size * 0.55, 6),
                        height: max(size * 0.11, 1.5)
                    )
                    .frame(
                        width: size,
                        height: size,
                        alignment: phase.stageLine == .top ? .top : .bottom
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("價格趨勢，\(phase.displayName)")
        .accessibilityHidden(phase.stageLine == .none)
        .help("價格趨勢：\(phase.displayName)")
    }

    private var stageLineColor: Color {
        guard !gray else { return .gray }
        switch phase {
        case .seekingPeakEarly, .seekingPeakLate,
             .pullingBackEarly, .pullingBackLate:
            return .red
        case .seekingBottomEarly, .seekingBottomLate,
             .reboundingEarly, .reboundingLate:
            return .green
        case .unavailable, .sideways:
            return .clear
        }
    }
}
