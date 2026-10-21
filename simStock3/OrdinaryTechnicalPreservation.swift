import Foundation

/// The pre-T3 preservation boundary, inclusive. This is a maturity contract,
/// not a claim that all recursive ordinary indicators have finite memory.
@MainActor
enum OrdinaryTechnicalPreservation {
    static func eligibleVolume(_ trade: Trade) -> Bool {
        trade.dataSource == "TWSE" && trade.volumeClose.isFinite && trade.volumeClose >= 0
    }

    static func stopIndex(in trades: [Trade]) -> Int? {
        guard !trades.isEmpty else { return nil }
        guard let priorStable = trades.firstIndex(where: \.tUpdated) else { return trades.count - 1 }
        var volumeCount = 0
        let volumeStable = trades.indices.first { index in
            let trade = trades[index]
            guard eligibleVolume(trade) else { return false }
            volumeCount += 1
            return volumeCount >= 250
        }
        return max(priorStable, volumeStable ?? trades.count - 1)
    }
}
