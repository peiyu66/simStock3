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
        XCTAssertEqual(trade.simFitTrendPhaseRaw, StrategyFitTrendPhase.unavailable.rawValue)
        XCTAssertEqual(trade.strategyFitTrendClassification, .unavailable)
        XCTAssertEqual(trade.strategyFitTrendDisplayClassification, .unavailable)
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

    func testStrategyFitTrendPhaseTransitionsThroughWarningConfirmationAndCooldown() {
        let confirmed = StrategyFitTrendClassifier.displayThreshold + 0.000_001

        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(fitTrend: 0.31, previousPhase: .neutral),
            .improvingWarning
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(fitTrend: confirmed, previousPhase: .improvingWarning),
            .improvingConfirmed
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(fitTrend: 0.5, previousPhase: .improvingConfirmed),
            .improvingCooldown
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(fitTrend: 0.5, previousPhase: .improvingCooldown),
            .improvingCooldown
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(fitTrend: 0.2, previousPhase: .improvingCooldown),
            .neutral
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(fitTrend: 0.31, previousPhase: .neutral),
            .improvingWarning
        )

        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(fitTrend: -0.31, previousPhase: .neutral),
            .worseningWarning
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(fitTrend: -confirmed, previousPhase: .worseningWarning),
            .worseningConfirmed
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(fitTrend: -0.5, previousPhase: .worseningConfirmed),
            .worseningCooldown
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(fitTrend: -0.2, previousPhase: .worseningCooldown),
            .neutral
        )
    }

    func testStrategyFitTrendDisplayHidesCooldownAndWarmup() {
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
        trade.simFitTrendPhaseRaw = StrategyFitTrendPhase.improvingWarning.rawValue
        trade.simFitObservationCount = 124
        XCTAssertEqual(trade.strategyFitTrendDisplayClassification, .unavailable)

        trade.simFitObservationCount = 125
        XCTAssertEqual(trade.strategyFitTrendDisplayClassification, .improvingWarning)

        trade.simFitTrendPhaseRaw = StrategyFitTrendPhase.improvingCooldown.rawValue
        XCTAssertEqual(trade.strategyFitTrendDisplayClassification, .stable)
    }
}
