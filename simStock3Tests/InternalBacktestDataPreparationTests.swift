import Foundation
import XCTest
@testable import simStock3

@MainActor
final class InternalBacktestDataPreparationTests: XCTestCase {
    func testPrepareBaselineDataset() async throws {
        guard ProcessInfo.processInfo.environment["RUN_INTERNAL_BACKTEST_DATASET"] == "1" else {
            throw XCTSkip("Internal network-backed dataset preparation runs only when explicitly requested.")
        }
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let directory = documents.appendingPathComponent(
            "InternalBacktest/2019-01-02-baseline",
            isDirectory: true
        )

        let result = try await InternalBacktestDataset.prepare(
            in: directory,
            reset: false
        ) { message in
            print("BACKTEST \(message)")
        }

        XCTAssertEqual(result.manifest.stocks.count, 10)
        XCTAssertTrue(result.manifest.failedRequests.isEmpty)
        for stock in result.manifest.stocks {
            XCTAssertEqual(stock.firstTrade, "2018/01/02", stock.id)
            XCTAssertEqual(stock.lastTrade, "2026/07/22", stock.id)
            XCTAssertGreaterThan(stock.tradeCount, 1_900, stock.id)
            XCTAssertGreaterThan(stock.technicalCount, 1_600, stock.id)
            XCTAssertGreaterThan(stock.simulationCount, 1_500, stock.id)
            XCTAssertEqual(stock.invalidPriceCount, 0, stock.id)
            XCTAssertEqual(stock.invalidTechnicalCount, 0, stock.id)
            XCTAssertEqual(stock.invalidSimulationCount, 0, stock.id)
        }

        print("BACKTEST_STORE \(result.storeURL.path)")
        print("BACKTEST_MANIFEST \(result.manifestURL.path)")
    }
}
