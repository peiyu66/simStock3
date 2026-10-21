import Foundation
import XCTest
@testable import simStock3

@MainActor
final class CalculationWindowTests: XCTestCase {
    private func day(_ value: String) -> Date {
        twDateTime.startOfDay(twDateTime.dateFromString(value)!)
    }

    private func price(_ value: String, close: Double = 100) -> (date: Date, close: Double) {
        (twDateTime.time1330(day(value)), close)
    }

    func testExactMidmonthBoundaryIncludesSameDayAndPreservesConfiguredTime() {
        let configured = twDateTime.time1330(day("2024/06/15"))
        let window = CalculationWindow(configuredStart: configured, prices: [
            price("2024/06/16"), price("2023/06/01"), price("2023/06/14"),
            (day("2023/06/15"), 100)
        ])

        XCTAssertEqual(window.configuredStart, configured)
        XCTAssertEqual(window.requestStart, day("2023/06/15"))
        XCTAssertEqual(window.firstPriceDate, day("2023/06/15"))
        XCTAssertEqual(window.simulationStart, day("2024/06/15"))
        XCTAssertEqual(window.lastPriceDate, day("2024/06/16"))
        XCTAssertTrue(window.hasSimulationDates)
    }

    func testSixMonthsKeepTechnicalPricesWithoutSimulationDates() {
        let window = CalculationWindow(configuredStart: day("2024/01/01"), prices: [
            price("2024/01/02"), price("2024/07/02")
        ])

        XCTAssertEqual(window.firstPriceDate, day("2024/01/02"))
        XCTAssertEqual(window.lastPriceDate, day("2024/07/02"))
        XCTAssertEqual(window.simulationStart, day("2025/01/02"))
        XCTAssertFalse(window.hasSimulationDates)
    }

    func testEmptyPricesHaveNoEffectiveStartOrEnd() {
        let window = CalculationWindow(configuredStart: day("2024/06/15"), prices: [])

        XCTAssertEqual(window.requestStart, day("2023/06/15"))
        XCTAssertNil(window.firstPriceDate)
        XCTAssertNil(window.simulationStart)
        XCTAssertNil(window.lastPriceDate)
        XCTAssertFalse(window.hasSimulationDates)
    }

    func testPricesOutsideWindowCannotSupplyAnEffectiveStartOrEnd() {
        let window = CalculationWindow(configuredStart: day("2024/06/15"), prices: [
            price("2020/01/02"), price("2023/06/14")
        ])

        XCTAssertNil(window.firstPriceDate)
        XCTAssertNil(window.simulationStart)
        XCTAssertNil(window.lastPriceDate)
        XCTAssertFalse(window.hasSimulationDates)
    }

    func testOnlyFinitePositivePricesDetermineBothBounds() {
        let window = CalculationWindow(configuredStart: day("2024/01/01"), prices: [
            price("2023/01/01", close: .nan), price("2023/01/02", close: -.infinity),
            price("2023/01/03", close: 0), price("2023/01/04", close: -100),
            price("2023/01/05", close: 0.01), price("2024/01/05"),
            price("2024/01/06", close: .infinity), price("2024/01/07", close: .nan)
        ])

        XCTAssertEqual(window.firstPriceDate, day("2023/01/05"))
        XCTAssertEqual(window.lastPriceDate, day("2024/01/05"))
        XCTAssertEqual(window.simulationStart, day("2024/01/05"))
        XCTAssertTrue(window.hasSimulationDates)
    }

    func testAllInvalidPricesBehaveLikeMissingPrices() {
        let window = CalculationWindow(configuredStart: day("2024/01/01"), prices: [
            price("2023/01/01", close: 0), price("2023/01/02", close: -1),
            price("2024/01/01", close: .nan), price("2024/01/02", close: .infinity)
        ])

        XCTAssertNil(window.firstPriceDate)
        XCTAssertNil(window.simulationStart)
        XCTAssertNil(window.lastPriceDate)
        XCTAssertFalse(window.hasSimulationDates)
    }

    func testLeapDayFirstPriceUsesCalendarYearInsteadOfFixedDayCount() {
        let window = CalculationWindow(configuredStart: day("2025/02/28"), prices: [
            price("2024/02/29"), price("2025/02/28")
        ])

        XCTAssertEqual(window.requestStart, day("2024/02/28"))
        XCTAssertEqual(window.firstPriceDate, day("2024/02/29"))
        XCTAssertEqual(window.simulationStart, day("2025/02/28"))
        XCTAssertTrue(window.hasSimulationDates)
    }

    func testLeapDayConfigurationKeepsEffectiveStartWithinConfiguredPeriod() {
        let configured = day("2024/02/29")
        let window = CalculationWindow(configuredStart: configured, prices: [
            price("2023/02/28"), price("2024/02/28")
        ])

        XCTAssertEqual(window.configuredStart, configured)
        XCTAssertEqual(window.requestStart, day("2023/02/28"))
        // Calendar arithmetic yields Feb 28, so the configured lower bound
        // prevents beginning a day early without shortening the warmup.
        XCTAssertEqual(window.simulationStart, day("2024/02/29"))
        XCTAssertFalse(window.hasSimulationDates)
    }

    func testChangingExistingInvalidCloseToValidRecomputesFirstPrice() {
        let configured = day("2024/01/01")
        let invalid = CalculationWindow(configuredStart: configured, prices: [
            price("2023/01/02", close: 0), price("2023/07/02"), price("2024/01/02")
        ])
        let valid = CalculationWindow(configuredStart: configured, prices: [
            price("2023/01/02", close: 100), price("2023/07/02"), price("2024/01/02")
        ])

        XCTAssertEqual(invalid.firstPriceDate, day("2023/07/02"))
        XCTAssertEqual(valid.firstPriceDate, day("2023/01/02"))
        XCTAssertEqual(valid.simulationStart, day("2024/01/02"))
        XCTAssertEqual(invalid.lastPriceDate, valid.lastPriceDate)
        XCTAssertFalse(invalid.hasSimulationDates)
        XCTAssertTrue(valid.hasSimulationDates)
        XCTAssertNotEqual(invalid, valid)
    }

    func testOlderPricesOutsideWindowCannotChangeDerivedWindow() {
        let configured = day("2024/06/15")
        let prices = [price("2023/07/03"), price("2024/07/03")]
        let original = CalculationWindow(configuredStart: configured, prices: prices)
        let backfilled = CalculationWindow(configuredStart: configured, prices:
            [price("2020/01/02"), price("2023/06/14")] + prices)

        XCTAssertEqual(backfilled, original)
    }

    func testEarlierBackfillInsideWindowMovesEffectiveStartWithoutChangingSetting() {
        let configured = twDateTime.time1330(day("2024/01/01"))
        let prices = [price("2023/07/03"), price("2024/04/02")]
        let original = CalculationWindow(configuredStart: configured, prices: prices)
        let backfilled = CalculationWindow(configuredStart: configured, prices:
            prices + [price("2023/04/03")])

        XCTAssertEqual(original.simulationStart, day("2024/07/03"))
        XCTAssertEqual(backfilled.firstPriceDate, day("2023/04/03"))
        XCTAssertEqual(backfilled.simulationStart, day("2024/04/03"))
        XCTAssertEqual(backfilled.configuredStart, configured)
        XCTAssertEqual(backfilled.requestStart, original.requestStart)
        XCTAssertEqual(backfilled.lastPriceDate, original.lastPriceDate)
        XCTAssertFalse(backfilled.hasSimulationDates)
    }

    func testSuppliedHistoricalCutoffControlsCompletionWithoutUsingToday() {
        let configured = day("2018/01/01")
        let prices = [price("2017/01/02"), price("2018/01/01")]
        let beforeStart = CalculationWindow(configuredStart: configured, prices: prices)
        let atStart = CalculationWindow(configuredStart: configured, prices:
            prices + [price("2018/01/02")])

        XCTAssertEqual(beforeStart.lastPriceDate, day("2018/01/01"))
        XCTAssertEqual(beforeStart.simulationStart, day("2018/01/02"))
        XCTAssertFalse(beforeStart.hasSimulationDates)
        XCTAssertEqual(atStart.lastPriceDate, day("2018/01/02"))
        XCTAssertTrue(atStart.hasSimulationDates)
    }
}
