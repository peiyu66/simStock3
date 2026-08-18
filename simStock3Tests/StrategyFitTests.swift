import XCTest
@testable import simStock3

final class StrategyFitTests: XCTestCase {
    func testTradeStrategyFitFieldsStartUnavailable() {
        let stock = Stock(
            sId: "TEST",
            sName: "測試股",
            group: "測試",
            dateFirst: Date(),
            dateStart: Date(),
            simInvestAuto: 2,
            simMoneyBase: 100
        )
        let trade = Trade(stock: stock, dateTime: Date())

        XCTAssertNil(trade.simFitFast)
        XCTAssertNil(trade.simFitSlow)
        XCTAssertNil(trade.simFitTrend)
        XCTAssertEqual(trade.simFitObservationCount, 0)
        XCTAssertEqual(trade.strategyFitTrendClassification, .unavailable)
    }

    func testStrategyFitStateUsesTwentyAndOneHundredTwentyFiveDayEMA() {
        var state = StrategyFitState()

        XCTAssertTrue(state.update(fitLevel: 10, roi: 4, days: 30))
        XCTAssertEqual(state.fitFast, 10)
        XCTAssertEqual(state.fitSlow, 10)
        XCTAssertEqual(state.fitTrend, 0)
        XCTAssertEqual(state.observationCount, 1)

        XCTAssertTrue(state.update(fitLevel: 20, roi: 14, days: 40))
        XCTAssertEqual(state.fitFast!, 10 + 20.0 / 21.0, accuracy: 0.000_000_1)
        XCTAssertEqual(state.fitSlow!, 10 + 20.0 / 126.0, accuracy: 0.000_000_1)
        XCTAssertEqual(
            state.fitTrend!,
            (10 + 20.0 / 21.0) - (10 + 20.0 / 126.0),
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(state.observationCount, 2)
    }

    func testStrategyFitStateIgnoresInvalidInputs() {
        var state = StrategyFitState()

        XCTAssertFalse(state.update(fitLevel: .infinity, roi: 0, days: 30))
        XCTAssertFalse(state.update(fitLevel: 10, roi: .nan, days: 30))
        XCTAssertFalse(state.update(fitLevel: 10, roi: 0, days: 0))
        XCTAssertEqual(state, StrategyFitState())
    }

    func testStrategyFitClassificationRequiresWarmupAndCrossesThreshold() {
        let threshold = StrategyFitTrendClassifier.displayThreshold

        XCTAssertEqual(
            StrategyFitTrendClassifier.classify(
                fitTrend: threshold + 0.000_001,
                observationCount: 124
            ),
            .unavailable
        )
        XCTAssertEqual(
            StrategyFitTrendClassifier.classify(
                fitTrend: threshold,
                observationCount: 125
            ),
            .stable
        )
        XCTAssertEqual(
            StrategyFitTrendClassifier.classify(
                fitTrend: threshold + 0.000_001,
                observationCount: 125
            ),
            .improving
        )
        XCTAssertEqual(
            StrategyFitTrendClassifier.classify(
                fitTrend: -threshold - 0.000_001,
                observationCount: 125
            ),
            .worsening
        )
    }
}
