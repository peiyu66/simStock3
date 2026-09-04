import Foundation

#if DEBUG
@MainActor
enum InternalMarketPricePathSellCandidate {
    enum Mode {
        case s01
        case s02

        var candidateID: String {
            switch self {
            case .s01: "MKT-PP-S01"
            case .s02: "MKT-PP-S02"
            }
        }

        var minimumGrade: Trade.Grade? {
            switch self {
            case .s01: nil
            case .s02: .high
            }
        }
    }

    static let mode: Mode? = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--candidate-mkt-pp-s01") { return .s01 }
        if arguments.contains("--candidate-mkt-pp-s02") { return .s02 }
        return nil
    }()
    static var candidateID: String { mode?.candidateID ?? "MKT-PP-S" }
    static var ruleID: String { candidateID }
    static let sourceArtifactID = "mkt-pp-p1-taiex-price-path-f712b360c322"
    static let sourceSnapshotID = "taiex-market-mt1-20260722-a00beac8d4af"
    static var isEnabled: Bool { mode != nil }

    struct MarketObservation: Equatable {
        let date: String
        let phaseRaw: Int
    }

    enum CandidateError: LocalizedError {
        case missingSource(String)
        case invalidSource(String)

        var errorDescription: String? {
            switch self {
            case .missingSource(let path):
                return "大盤價格路徑候選快照不存在：\(path)"
            case .invalidSource(let detail):
                return "大盤價格路徑候選快照無效：\(detail)"
            }
        }
    }

    private static var observations: [MarketObservation] = []
    private(set) static var marketPricePathLookup = MarketPricePathLookup()
    private static var sellEvaluations = 0
    private static var priorMarketObservationsFound = 0
    private static var missingPriorMarketObservations = 0
    private static var marketMatches = 0
    private static var jointMatches = 0

    static func prepare() throws {
        observations.removeAll(keepingCapacity: true)
        sellEvaluations = 0
        priorMarketObservationsFound = 0
        missingPriorMarketObservations = 0
        marketMatches = 0
        jointMatches = 0

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents
            .appendingPathComponent("InternalBacktest/Research/Market", isDirectory: true)
            .appendingPathComponent("market-price-path.csv")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CandidateError.missingSource(url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { throw CandidateError.invalidSource("空白 CSV") }
        let header = String(lines.removeFirst()).split(separator: ",").map(String.init)
        guard let dateIndex = header.firstIndex(of: "date"),
              let phaseIndex = header.firstIndex(of: "phase_raw") else {
            throw CandidateError.invalidSource("缺少 date 或 phase_raw 欄位")
        }

        var previousDate = ""
        for (offset, line) in lines.enumerated() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.indices.contains(dateIndex), columns.indices.contains(phaseIndex),
                  let phaseRaw = Int(columns[phaseIndex]) else {
                throw CandidateError.invalidSource("第 \(offset + 2) 列欄位無效")
            }
            let date = String(columns[dateIndex])
            guard date.count == 10, date > previousDate,
                  PricePathPhase(rawValue: phaseRaw) != nil else {
                throw CandidateError.invalidSource("日期或階段無效：\(date)／\(phaseRaw)")
            }
            observations.append(.init(date: date, phaseRaw: phaseRaw))
            previousDate = date
        }
        guard observations.count == 2_569, previousDate == "2026-07-22" else {
            throw CandidateError.invalidSource(
                "快照身分不符（rows=\(observations.count), through=\(previousDate)）"
            )
        }
        marketPricePathLookup = MarketPricePathLookup(
            observations: observations.compactMap { observation in
                guard let date = twDateTime.dateFromString(observation.date) else { return nil }
                return .init(
                    date: twDateTime.time1330(date),
                    phase: PricePathPhase(rawValue: observation.phaseRaw) ?? .unavailable
                )
            }
        )
    }

    static func priorMarketPhaseRaw(
        before decisionDate: String,
        observations: [MarketObservation]
    ) -> Int? {
        var lower = 0
        var upper = observations.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if observations[middle].date < decisionDate {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        return observations[lower - 1].phaseRaw
    }

    static func contribution(
        priorMarketIsSeekingPeakLate: Bool,
        stockPhase: PricePathPhase,
        grade: Trade.Grade,
        minimumGrade: Trade.Grade?
    ) -> Double? {
        guard priorMarketIsSeekingPeakLate, stockPhase == .seekingPeakLate else { return nil }
        if let minimumGrade, grade < minimumGrade { return nil }
        return 1
    }

    static func contribution(
        date: Date,
        stockPhase: PricePathPhase,
        grade: Trade.Grade
    ) -> Double? {
        guard let mode else { return nil }
        sellEvaluations += 1
        let decisionDate = twDateTime.stringFromDate(date, format: "yyyy-MM-dd")
        guard let marketPhaseRaw = priorMarketPhaseRaw(before: decisionDate, observations: observations) else {
            missingPriorMarketObservations += 1
            return nil
        }
        priorMarketObservationsFound += 1
        let marketMatchesCandidate = marketPhaseRaw == PricePathPhase.seekingPeakLate.rawValue
        if marketMatchesCandidate { marketMatches += 1 }
        let value = contribution(
            priorMarketIsSeekingPeakLate: marketMatchesCandidate,
            stockPhase: stockPhase,
            grade: grade,
            minimumGrade: mode.minimumGrade
        )
        if value != nil { jointMatches += 1 }
        return value
    }

    static func recordFormalEvaluation(
        date: Date,
        stockPhase: PricePathPhase,
        grade: Trade.Grade
    ) {
        guard isEnabled else { return }
        _ = contribution(date: date, stockPhase: stockPhase, grade: grade)
    }

    static func writeDiagnostics(to outputURL: URL) throws {
        guard isEnabled else { return }
        let payload = Diagnostics(
            candidateID: candidateID,
            contribution: 1,
            marketAlignment: "strictly-before-decision-date",
            marketPhaseRaw: PricePathPhase.seekingPeakLate.rawValue,
            stockPhaseRaw: PricePathPhase.seekingPeakLate.rawValue,
            minimumGradeRaw: mode?.minimumGrade?.rawValue,
            sellEvaluations: sellEvaluations,
            priorMarketObservationsFound: priorMarketObservationsFound,
            missingPriorMarketObservations: missingPriorMarketObservations,
            marketMatches: marketMatches,
            jointMatches: jointMatches,
            qualifyingMarketDateCount: observations.filter {
                $0.phaseRaw == PricePathPhase.seekingPeakLate.rawValue
            }.count,
            sourceArtifactID: sourceArtifactID,
            sourceSnapshotID: sourceSnapshotID,
            sourceFile: "market-price-path.csv",
            sourceRowCount: observations.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(
            to: outputURL.appendingPathComponent("market-price-path-sell-candidate-diagnostics.json"),
            options: .atomic
        )
    }

    private struct Diagnostics: Codable {
        let candidateID: String
        let contribution: Int
        let marketAlignment: String
        let marketPhaseRaw: Int
        let stockPhaseRaw: Int
        let minimumGradeRaw: Int?
        let sellEvaluations: Int
        let priorMarketObservationsFound: Int
        let missingPriorMarketObservations: Int
        let marketMatches: Int
        let jointMatches: Int
        let qualifyingMarketDateCount: Int
        let sourceArtifactID: String
        let sourceSnapshotID: String
        let sourceFile: String
        let sourceRowCount: Int
    }
}
#endif
