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
        XCTAssertNil(trade.simFitTrendPhaseExtreme)
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
            StrategyFitTrendPhaseUpdater.next(
                fitTrend: 0.31,
                previousPhase: .neutral,
                previousExtreme: nil
            ).phase,
            .improvingWarning
        )
        let improvingConfirmed = StrategyFitTrendPhaseUpdater.next(
            fitTrend: confirmed,
            previousPhase: .improvingWarning,
            previousExtreme: nil
        )
        XCTAssertEqual(
            improvingConfirmed,
            StrategyFitTrendPhaseState(phase: .improvingConfirmedSeekingPeak, extreme: confirmed)
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(
                fitTrend: 0.5,
                previousPhase: improvingConfirmed.phase,
                previousExtreme: improvingConfirmed.extreme
            ).phase,
            .improvingCooldown
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(
                fitTrend: 0.5,
                previousPhase: .improvingCooldown,
                previousExtreme: nil
            ).phase,
            .improvingCooldown
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(
                fitTrend: 0.2,
                previousPhase: .improvingCooldown,
                previousExtreme: nil
            ).phase,
            .neutral
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(
                fitTrend: 0.31,
                previousPhase: .neutral,
                previousExtreme: nil
            ).phase,
            .improvingWarning
        )

        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(
                fitTrend: -0.31,
                previousPhase: .neutral,
                previousExtreme: nil
            ).phase,
            .worseningWarning
        )
        let worseningConfirmed = StrategyFitTrendPhaseUpdater.next(
            fitTrend: -confirmed,
            previousPhase: .worseningWarning,
            previousExtreme: nil
        )
        XCTAssertEqual(
            worseningConfirmed,
            StrategyFitTrendPhaseState(phase: .worseningConfirmedSeekingBottom, extreme: -confirmed)
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(
                fitTrend: -0.5,
                previousPhase: worseningConfirmed.phase,
                previousExtreme: worseningConfirmed.extreme
            ).phase,
            .worseningCooldown
        )
        XCTAssertEqual(
            StrategyFitTrendPhaseUpdater.next(
                fitTrend: -0.2,
                previousPhase: .worseningCooldown,
                previousExtreme: nil
            ).phase,
            .neutral
        )
    }

    func testWorseningConfirmationSplitsAtStrictTurnAndReturnsToSeekingOnNewBottom() {
        let boundary = StrategyFitTrendPhaseUpdater.next(
            fitTrend: -0.9,
            previousPhase: .worseningConfirmedSeekingBottom,
            previousExtreme: -1.0
        )
        XCTAssertEqual(boundary.phase, .worseningConfirmedSeekingBottom)
        XCTAssertEqual(boundary.extreme, -1.0)

        let rebound = StrategyFitTrendPhaseUpdater.next(
            fitTrend: -0.899_999,
            previousPhase: .worseningConfirmedSeekingBottom,
            previousExtreme: -1.0
        )
        XCTAssertEqual(rebound.phase, .worseningConfirmedRebounding)
        XCTAssertEqual(rebound.extreme, -1.0)

        let newBottom = StrategyFitTrendPhaseUpdater.next(
            fitTrend: -1.1,
            previousPhase: rebound.phase,
            previousExtreme: rebound.extreme
        )
        XCTAssertEqual(newBottom.phase, .worseningConfirmedSeekingBottom)
        XCTAssertEqual(newBottom.extreme, -1.1)
    }

    func testImprovingConfirmationSplitsAtStrictTurnAndReturnsToSeekingOnNewPeak() {
        let boundary = StrategyFitTrendPhaseUpdater.next(
            fitTrend: 0.9,
            previousPhase: .improvingConfirmedSeekingPeak,
            previousExtreme: 1.0
        )
        XCTAssertEqual(boundary.phase, .improvingConfirmedSeekingPeak)
        XCTAssertEqual(boundary.extreme, 1.0)

        let pullback = StrategyFitTrendPhaseUpdater.next(
            fitTrend: 0.899_999,
            previousPhase: .improvingConfirmedSeekingPeak,
            previousExtreme: 1.0
        )
        XCTAssertEqual(pullback.phase, .improvingConfirmedPullingBack)
        XCTAssertEqual(pullback.extreme, 1.0)

        let newPeak = StrategyFitTrendPhaseUpdater.next(
            fitTrend: 1.1,
            previousPhase: pullback.phase,
            previousExtreme: pullback.extreme
        )
        XCTAssertEqual(newPeak.phase, .improvingConfirmedSeekingPeak)
        XCTAssertEqual(newPeak.extreme, 1.1)
    }

    func testSameDayPreviewsAlwaysStartFromPreviousOfficialExtreme() {
        let morning = StrategyFitTrendPhaseUpdater.next(
            fitTrend: -1.2,
            previousPhase: .worseningConfirmedSeekingBottom,
            previousExtreme: -1.0
        )
        XCTAssertEqual(morning.extreme, -1.2)

        let afternoon = StrategyFitTrendPhaseUpdater.next(
            fitTrend: -0.85,
            previousPhase: .worseningConfirmedSeekingBottom,
            previousExtreme: -1.0
        )
        XCTAssertEqual(afternoon.phase, .worseningConfirmedRebounding)
        XCTAssertEqual(afternoon.extreme, -1.0)
    }

    func testSplitConfirmationPhasesPreserveLegacyConfirmationUnion() {
        XCTAssertTrue(StrategyFitTrendPhase.worseningConfirmed.isWorseningConfirmed)
        XCTAssertTrue(StrategyFitTrendPhase.worseningConfirmedSeekingBottom.isWorseningConfirmed)
        XCTAssertTrue(StrategyFitTrendPhase.worseningConfirmedRebounding.isWorseningConfirmed)
        XCTAssertFalse(StrategyFitTrendPhase.worseningWarning.isWorseningConfirmed)

        XCTAssertTrue(StrategyFitTrendPhase.improvingConfirmed.isImprovingConfirmed)
        XCTAssertTrue(StrategyFitTrendPhase.improvingConfirmedSeekingPeak.isImprovingConfirmed)
        XCTAssertTrue(StrategyFitTrendPhase.improvingConfirmedPullingBack.isImprovingConfirmed)
        XCTAssertFalse(StrategyFitTrendPhase.improvingWarning.isImprovingConfirmed)
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

    func testSplitConfirmationPhasesProvideDistinctIconsAndAccessibilityText() {
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
        trade.simFitObservationCount = StrategyFitTrendClassifier.minimumObservationCount

        let expectations: [(StrategyFitTrendPhase, String, String)] = [
            (.improvingConfirmedSeekingPeak, "arrow.up.right.circle.fill", "適配趨勢改善確認，探頂段"),
            (.improvingConfirmedPullingBack, "arrow.down.right.circle", "適配趨勢改善確認，拉回段"),
            (.worseningConfirmedSeekingBottom, "arrow.down.right.circle.fill", "適配趨勢惡化確認，探底段"),
            (.worseningConfirmedRebounding, "arrow.up.right.circle", "適配趨勢惡化確認，反彈段")
        ]
        for (phase, icon, accessibilityText) in expectations {
            trade.simFitTrendPhaseRaw = phase.rawValue
            XCTAssertEqual(trade.strategyFitTrendDisplayPhase, phase)
            XCTAssertEqual(phase.displayIconSystemName, icon)
            XCTAssertEqual(trade.strategyFitTrendAccessibilityText, accessibilityText)
        }
    }
}
