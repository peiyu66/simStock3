import XCTest
@testable import simStock3

@MainActor
final class SE01ResearchTests: XCTestCase {
    func testFormalV41RejectsResearchOrRetiredIdentity() throws {
        let commit = String(repeating: "a", count: 40)
        XCTAssertNoThrow(try InternalBacktestReport.validateFormalUpdateCycleArguments(
            ["--formal-update-cycle-baseline-v41", "--record-decision-base"], ruleCommit: commit))
        for flag in ["--formal-resumable-update-baseline-v40", "--se01-e1-mode", "--update-cycle-diagnostic"] {
            XCTAssertThrowsError(try InternalBacktestReport.validateFormalUpdateCycleArguments([flag], ruleCommit: commit))
        }
        XCTAssertThrowsError(try InternalBacktestReport.validateFormalUpdateCycleArguments([], ruleCommit: nil))
        XCTAssertThrowsError(try InternalBacktestReport.validateFormalUpdateCycleArguments([], ruleCommit: "abcdef0"))
    }

    func testActivationIsExplicitAndRejectsMixedRuns() throws {
        XCTAssertNil(try InternalSE01Research.validate(arguments: [], diagnostic: true, maturity: false))
        for mode in ["control", "legacy", "unit"] {
            XCTAssertEqual(try InternalSE01Research.validate(arguments: ["--se01-e1-mode", mode], diagnostic: true, maturity: false)?.rawValue, mode)
        }
        for args in [["--se01-e1-mode"], ["--se01-e1-mode", "unknown"],
                     ["--se01-e1-mode", "unit", "--se01-e1-mode", "legacy"],
                     ["--se01-e1-mode", "unit", "--formal-baseline"]] {
            XCTAssertThrowsError(try InternalSE01Research.validate(arguments: args, diagnostic: true, maturity: false))
        }
        XCTAssertThrowsError(try InternalSE01Research.validate(arguments: ["--se01-e1-mode", "control"], diagnostic: false, maturity: false))
        XCTAssertThrowsError(try InternalSE01Research.validate(arguments: ["--se01-e1-mode", "control"], diagnostic: true, maturity: true))
    }

    func testControlAndLegacyUseUnchangedRuleForEveryBoundary() {
        for mode in [InternalSE01Research.Mode.control, .legacy] {
            for z in [-1.0, -0.97, -0.969, 0, 0.829, 0.83, 1, .nan, .infinity] {
                for osc in [-1.0, 0] { for delta in [0.219, 0.22] { for m in [-0.1, 0.0, 0.1] { for mature in [false, true] {
                    XCTAssertEqual(InternalSE01Research.technicalMatch(mode: mode, selectedZ: z,
                        oscMax9: osc, stockDelta: delta, marketDelta: m, mature: mature),
                        SellDelayF01Rule.matches(marketHighZ125: z, oscMax9: osc,
                            stockOscDelta: delta, marketOscDelta: m, mature: mature))
                } } } }
            }
        }
    }

    func testUnitChangesOnlyStrictMarketBand() {
        func matches(_ z: Double, _ mature: Bool = true, _ osc: Double = -1,
                     _ delta: Double = 0.2, _ market: Double = 0) -> Bool {
            InternalSE01Research.technicalMatch(mode: .unit, selectedZ: z, oscMax9: osc,
                stockDelta: delta, marketDelta: market, mature: mature)
        }
        for z in [-1.0, 1, .nan, .infinity] { XCTAssertFalse(matches(z)) }
        for z in [-0.999, -0.98, 0, 0.9, 0.999] { XCTAssertTrue(matches(z)) }
        XCTAssertFalse(matches(0, false)); XCTAssertFalse(matches(0, true, 0))
        XCTAssertFalse(matches(0, true, -1, 0.22, 0))
        XCTAssertTrue(matches(0, true, -1, 0.22, 0.01))
        XCTAssertFalse(matches(0, true, -1, .nan, 0.01))
    }
}
