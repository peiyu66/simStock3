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
        XCTAssertEqual(InternalBacktestDataset.Sample.c.members.count, 10)
    }

    func testLockedSampleCCannotPrepareOrDeleteDatasetBeforeFT7() async throws {
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
            XCTFail("Locked Sample C must stop before FT7 dataset preparation.")
        } catch InternalBacktestDataset.DatasetError.sampleCLockedUntilFinalValidation {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testSampleCEvaluationConfigurationIsIsolatedFromFormalSamples() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            ["id": "4562", "name": "穎漢"],
            ["id": "3593", "name": "力銘"]
        ])
        let configuration = try InternalBacktestDataset.evaluationConfiguration(
            arguments: [
                "app", "--evaluation-id", "ft4b-1a",
                "--evaluation-members-base64", payload.base64EncodedString()
            ]
        )

        XCTAssertEqual(configuration.id, "ft4b-1a")
        XCTAssertEqual(configuration.members.map(\.id), ["4562", "3593"])
        XCTAssertEqual(Set(configuration.members.map(\.group)), ["研究池"])
        XCTAssertEqual(configuration.directoryName, "sample-c-evaluation-ft4b-1a")
        XCTAssertEqual(configuration.qualificationID, "ft4b-1b")
        XCTAssertEqual(InternalBacktestDataset.Sample.c.members.count, 10)
    }

    func testSampleCEvaluationRejectsFormalSampleStock() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            ["id": "2330", "name": "台積電"]
        ])
        XCTAssertThrowsError(
            try InternalBacktestDataset.evaluationConfiguration(
                arguments: [
                    "app", "--evaluation-id", "ft4b-1a",
                    "--evaluation-members-base64", payload.base64EncodedString()
                ]
            )
        )
        XCTAssertEqual(InternalBacktestDataset.Sample.c.members.count, 10)
    }

    func testSampleCIsRandomlyLockedWithoutStrengthGroups() {
        let members = InternalBacktestDataset.Sample.c.members

        XCTAssertEqual(members.count, 10)
        XCTAssertEqual(Set(members.map(\.id)).count, 10)
        XCTAssertEqual(members.filter { $0.group == "較強股群" }.count, 4)
        XCTAssertEqual(members.filter { $0.group == "較弱股群" }.count, 6)
        XCTAssertFalse(InternalBacktestDataset.sampleCExecutionIsUnlocked(arguments: []))
        XCTAssertTrue(InternalBacktestDataset.sampleCExecutionIsUnlocked(
            arguments: ["app", "--unlock-sample-c-ft7"]
        ))
    }

    func testSampleBDefinitionUsesTwoRepresentativeGroups() {
        let members = InternalBacktestDataset.Sample.b.members

        XCTAssertEqual(members.count, 10)
        XCTAssertEqual(Set(members.map(\.id)).count, 10)
        XCTAssertEqual(members.filter { $0.group == "較強股群" }.count, 5)
        XCTAssertEqual(members.filter { $0.group == "較弱股群" }.count, 5)
        XCTAssertEqual(Set(members.map(\.group)), ["較強股群", "較弱股群"])
    }

    func testSampleEUsesAllReservedStocksAsTwoWeakStressGroups() {
        let sample = InternalBacktestDataset.Sample.from(
            arguments: ["app", "--sample-c", "--sample-e"]
        )
        let members = sample.members

        XCTAssertEqual(sample, .e)
        XCTAssertEqual(members.count, 10)
        XCTAssertEqual(Set(members.map(\.id)), [
            "8473", "4562", "2462", "2601", "2913",
            "8213", "8422", "2354", "9904", "1301"
        ])
        XCTAssertEqual(members.filter { $0.group == "弱勢壓力甲組" }.count, 5)
        XCTAssertEqual(members.filter { $0.group == "弱勢壓力乙組" }.count, 5)
        XCTAssertEqual(
            InternalBacktestDataset.Sample.e.nineYearBaselineDirectoryName,
            "sample-e-2017-07-22-t2-baseline-v2"
        )
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
