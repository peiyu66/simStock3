import SwiftUI

enum SummaryIconLayoutPolicy {
    static func hidesSidebarTrendIcons(usesCompactLandscape: Bool) -> Bool {
        usesCompactLandscape
    }

    static func hidesTradeIcons(
        isSplitDetail: Bool,
        showsTechnicalSidebar: Bool,
        usesSpaciousTechnicalSidebar: Bool
    ) -> Bool {
        isSplitDetail && showsTechnicalSidebar && !usesSpaciousTechnicalSidebar
    }
}

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
    var colorOpacity = 1.0

    var body: some View {
        Group {
            if let systemName = phase.displayIconSystemName {
                Image(systemName: systemName)
                    .foregroundStyle(iconColor.opacity(colorOpacity))
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
        StrategyFitTrendIcon(
            phase: phase.strategyFitIconPhase,
            gray: gray,
            size: size,
            showsContrastBackground: showsContrastBackground,
            colorOpacity: phase.iconColorOpacity
        )
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("價格趨勢，\(phase.displayName)")
        .accessibilityHidden(phase.strategyFitIconPhase.displayIconSystemName == nil)
        .help("價格趨勢：\(phase.displayName)")
    }
}
