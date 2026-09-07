#if DEBUG
import Foundation
import CryptoKit

/// Verified frozen input for formal S-N01c replay; production uses MarketDay.
@MainActor
enum InternalMarketLow9Input {
    static let dailySHA = "558883f85355b49c1c4402b4346d9a4939411bea69d405275c2b42aa55bb8da4"
    static let extremaSHA = "6d5519a63bba5dfabab243d7ce35d37a8a8c007ecd0b0ac3703b2fa14922861e"

    struct Observation: Equatable {
        let date: String
        let low: Double
        let low9: Double
    }

    static func load() throws -> [String: Observation] {
        var observations: [Observation] = []
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InternalBacktest/Research/Market")
        func read(_ name: String, sha: String) throws -> [[String]] {
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == sha, let text = String(data: data, encoding: .utf8) else {
                throw InternalMarketPricePathSellCandidate.CandidateError.invalidSource(name + " SHA-256")
            }
            return text.split(whereSeparator: \.isNewline).map {
                $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            }
        }
        let daily = try read("market-daily.csv", sha: dailySHA)
        let extrema = try read("market-index-extrema9.csv", sha: extremaSHA)
        guard daily.count == 2570, extrema.count == daily.count,
              daily[0][0] == "date", daily[0][3] == "low",
              extrema[0][0] == "date", extrema[0][3] == "index_low_min9" else {
            throw InternalMarketPricePathSellCandidate.CandidateError.invalidSource("L9 欄位／列數")
        }
        for index in 1..<daily.count {
            let d = daily[index], e = extrema[index]
            guard d[0] == e[0], let low = Double(d[3]), let low9 = Double(e[3]),
                  low.isFinite, low9.isFinite, low9 > 0, low9 <= low,
                  observations.last.map({ $0.date < d[0] }) ?? true else {
                throw InternalMarketPricePathSellCandidate.CandidateError.invalidSource("L9 日期／數值")
            }
            // Independently check the inclusive nine-market-session window.
            let expected = daily[max(1, index - 8)...index].compactMap { Double($0[3]) }.min()
            guard low9 == expected else {
                throw InternalMarketPricePathSellCandidate.CandidateError.invalidSource("L9 滾動值不符")
            }
            observations.append(.init(date: d[0], low: low, low9: low9))
        }
        guard observations.first?.date == "2016-01-04", observations.last?.date == "2026-07-22" else {
            throw InternalMarketPricePathSellCandidate.CandidateError.invalidSource("L9 截止日")
        }
        return Dictionary(uniqueKeysWithValues: observations.map { ($0.date, $0) })
    }
}
#endif
