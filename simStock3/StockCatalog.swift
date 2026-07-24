//
//  StockCatalog.swift
//  simStock3
//
//  Synchronizes the searchable TWSE listed-company catalog.
//

import Foundation
import SwiftData

nonisolated struct TWSEStockCatalogEntry: Decodable, Equatable, Sendable {
    let code: String
    let shortName: String

    private enum CodingKeys: String, CodingKey {
        case code = "公司代號"
        case shortName = "公司簡稱"
    }
}

nonisolated enum TWSEStockCatalogParser {
    static func decode(_ data: Data, minimumCount: Int = 500) throws -> [TWSEStockCatalogEntry] {
        let decoded = try JSONDecoder().decode([TWSEStockCatalogEntry].self, from: data)
        let normalized = decoded.compactMap { entry -> TWSEStockCatalogEntry? in
            let code = entry.code.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = entry.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, !name.isEmpty else { return nil }
            return TWSEStockCatalogEntry(code: code, shortName: name)
        }

        let entriesByCode = Dictionary(normalized.map { ($0.code, $0) }) { first, _ in first }
        guard entriesByCode.count >= minimumCount else {
            throw StockCatalogError.incompleteCatalog(
                expectedAtLeast: minimumCount,
                received: entriesByCode.count
            )
        }
        return entriesByCode.values.sorted { $0.code < $1.code }
    }
}

nonisolated enum StockCatalogSearch {
    static func keywords(from text: String) -> [String] {
        text.split { character in
            character.isWhitespace || character == "," || character == "，"
        }
        .map(String.init)
    }

    static func matches(code: String, name: String, keywords: [String]) -> Bool {
        guard !keywords.isEmpty else { return false }
        return keywords.allSatisfy { keyword in
            code.localizedStandardContains(keyword)
                || name.localizedStandardContains(keyword)
        }
    }
}

struct StockCatalogUpdateSummary: Equatable {
    let total: Int
    let inserted: Int
    let renamed: Int
    let markedUnlisted: Int
}

@MainActor
final class StockCatalogUpdater {
    static let endpoint = URL(
        string: "https://openapi.twse.com.tw/v1/opendata/t187ap03_L"
    )!
    nonisolated static let refreshInterval: TimeInterval = 10 * 24 * 60 * 60

    private let context: ModelContext
    private let session: URLSession

    init(modelContext: ModelContext, session: URLSession = .shared) {
        context = modelContext
        self.session = session
    }

    static func needsRefresh(
        lastSuccess: Date?,
        now: Date = Date(),
        refreshInterval: TimeInterval = refreshInterval
    ) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= refreshInterval
    }

    func refreshIfNeeded(force: Bool = false, now: Date = Date()) async throws -> StockCatalogUpdateSummary? {
        guard force || Self.needsRefresh(
            lastSuccess: defaults.stockCatalogLastUpdated,
            now: now
        ) else {
            return nil
        }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw StockCatalogError.invalidResponse
        }

        let entries = try TWSEStockCatalogParser.decode(data)
        return try apply(entries, updatedAt: now)
    }

    func apply(
        _ entries: [TWSEStockCatalogEntry],
        updatedAt: Date = Date()
    ) throws -> StockCatalogUpdateSummary {
        let allStocks = try Stock.fetchAll(in: context)
        var stocksByID = Dictionary(uniqueKeysWithValues: allStocks.map { ($0.sId, $0) })
        let listedIDs = Set(entries.map(\.code))
        var inserted = 0
        var renamed = 0
        var markedUnlisted = 0

        for entry in entries {
            if let stock = stocksByID[entry.code] {
                if stock.sName != entry.shortName {
                    stock.sName = entry.shortName
                    renamed += 1
                }
                stock.isListed = true
            } else {
                let stock = Stock(
                    sId: entry.code,
                    sName: entry.shortName,
                    group: "",
                    dateFirst: .distantFuture,
                    dateStart: .distantFuture,
                    simInvestAuto: 0,
                    simMoneyBase: 0
                )
                stock.isListed = true
                context.insert(stock)
                stocksByID[entry.code] = stock
                inserted += 1
            }
        }

        for stock in allStocks where !listedIDs.contains(stock.sId) && stock.isListed {
            stock.isListed = false
            markedUnlisted += 1
        }

        try context.save()
        defaults.setStockCatalogLastUpdated(updatedAt)
        return StockCatalogUpdateSummary(
            total: entries.count,
            inserted: inserted,
            renamed: renamed,
            markedUnlisted: markedUnlisted
        )
    }
}

nonisolated enum StockCatalogError: LocalizedError {
    case invalidResponse
    case incompleteCatalog(expectedAtLeast: Int, received: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "TWSE 股票名錄回應無效"
        case let .incompleteCatalog(expectedAtLeast, received):
            return "TWSE 股票名錄不完整，至少應有 \(expectedAtLeast) 筆，實收 \(received) 筆"
        }
    }
}
