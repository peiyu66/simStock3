import Foundation
import XCTest
@testable import simStock3

@MainActor
final class InternalBacktestDataPreparationTests: XCTestCase {
    func testSampleSelectionPrefersExplicitSampleC() {
        XCTAssertEqual(
            InternalBacktestDataset.Sample.from(arguments: ["app", "--sample-b", "--sample-c"]),
            .c
        )
        XCTAssertTrue(InternalBacktestDataset.Sample.c.members.isEmpty)
    }

    func testWithdrawnSampleCCannotPrepareOrDeleteDataset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            _ = try await InternalBacktestDataset.prepare(
                in: directory,
                reset: true,
                sample: .c,
                through: InternalBacktestDataset.snapshotThrough,
                requestDelay: .zero
            )
            XCTFail("Withdrawn Sample C must stop before dataset preparation.")
        } catch InternalBacktestDataset.DatasetError.sampleCNotConfigured {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testSampleBDefinitionUsesTwoRepresentativeGroups() {
        let members = InternalBacktestDataset.Sample.b.members

        XCTAssertEqual(members.count, 10)
        XCTAssertEqual(Set(members.map(\.id)).count, 10)
        XCTAssertEqual(members.filter { $0.group == "第 1 股群" }.count, 5)
        XCTAssertEqual(members.filter { $0.group == "第 2 股群" }.count, 5)
        XCTAssertEqual(Set(members.map(\.group)), ["第 1 股群", "第 2 股群"])
    }

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
            reset: false,
            through: InternalBacktestDataset.snapshotThrough
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
