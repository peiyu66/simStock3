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
        let high: Double
        let high9: Double
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
              daily[0][0] == "date", daily[0][3] == "low", daily[0][2] == "high",
              extrema[0][0] == "date", extrema[0][3] == "index_low_min9",
              extrema[0][2] == "index_high_max9" else {
            throw InternalMarketPricePathSellCandidate.CandidateError.invalidSource("L9 欄位／列數")
        }
        for index in 1..<daily.count {
            let d = daily[index], e = extrema[index]
            guard d[0] == e[0], let low = Double(d[3]), let low9 = Double(e[3]),
                  let high = Double(d[2]), let high9 = Double(e[2]),
                  high.isFinite, high9.isFinite, high > 0, high9 >= high,
                  low.isFinite, low9.isFinite, low9 > 0, low9 <= low,
                  observations.last.map({ $0.date < d[0] }) ?? true else {
                throw InternalMarketPricePathSellCandidate.CandidateError.invalidSource("L9 日期／數值")
            }
            // Independently check the inclusive nine-market-session window.
            let expected = daily[max(1, index - 8)...index].compactMap { Double($0[3]) }.min()
            let expectedHigh = daily[max(1, index - 8)...index].compactMap { Double($0[2]) }.max()
            guard low9 == expected, high9 == expectedHigh else {
                throw InternalMarketPricePathSellCandidate.CandidateError.invalidSource("L9 滾動值不符")
            }
            observations.append(.init(date: d[0], low: low, low9: low9, high: high, high9: high9))
        }
        guard observations.first?.date == "2016-01-04", observations.last?.date == "2026-07-22" else {
            throw InternalMarketPricePathSellCandidate.CandidateError.invalidSource("L9 截止日")
        }
        return Dictionary(uniqueKeysWithValues: observations.map { ($0.date, $0) })
    }
}

/// HP04-H9 research: suppress the existing H-P04 vote, not an extra negative vote.
@MainActor
enum InternalHP04High9Candidate {
    static let excludeNeutral = CommandLine.arguments.contains("--candidate-hp04-h9-s4")
    static let excludeEarlyPeak = CommandLine.arguments.contains("--candidate-hp04-h9-s3") || excludeNeutral
    static let upperOnly = CommandLine.arguments.contains("--candidate-hp04-h9-s2") || excludeEarlyPeak
    static let enabled = CommandLine.arguments.contains("--candidate-hp04-h9-s1") || upperOnly
    private static var observations: [InternalMarketLow9Input.Observation] = []

    static func prepare() throws {
        guard enabled else { return }
        observations = try InternalMarketLow9Input.load().values.sorted { $0.date < $1.date }
    }

    static func allowsSuppression(grade: Trade.Grade, upperOnly: Bool) -> Bool {
        !upperOnly || grade >= .fine
    }

    static func allowsMarketPhase(_ phase: PricePathPhase?, excludeEarlyPeak: Bool) -> Bool {
        !excludeEarlyPeak || (phase != nil && phase != .seekingPeakEarly)
    }

    static func allowsGradePhase(_ phase: StrategyFitTrendPhase, excludeNeutral: Bool) -> Bool {
        !excludeNeutral || phase != .neutral
    }

    static func suppressesVote(on date: Date, grade: Trade.Grade, priorMarketPhase: PricePathPhase?,
                               decisionGradePhase: StrategyFitTrendPhase) -> Bool {
        guard enabled, allowsSuppression(grade: grade, upperOnly: upperOnly),
              allowsGradePhase(decisionGradePhase, excludeNeutral: excludeNeutral),
              allowsMarketPhase(priorMarketPhase, excludeEarlyPeak: excludeEarlyPeak) else { return false }
        precondition(!observations.isEmpty, "HP04-H9 input was not prepared")
        return suppressesVote(before: twDateTime.stringFromDate(date, format: "yyyy-MM-dd"),
                              observations: observations)
    }

    static func suppressesVote(before day: String,
                               observations: [InternalMarketLow9Input.Observation]) -> Bool {
        var lower = 0
        var upper = observations.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if observations[middle].date < day { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0 else { return false }
        let prior = observations[lower - 1]
        return prior.high.isFinite && prior.high > 0 && prior.high == prior.high9
    }
}
#endif
