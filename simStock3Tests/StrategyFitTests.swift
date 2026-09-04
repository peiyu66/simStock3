import XCTest
@testable import simStock3

final class StrategyFitTests: XCTestCase {
    @MainActor
    func testTradeStrategyFitFieldsStartUnavailable() async {
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

    func testWorseningConfirmationSplitsAtStrictTurnAndReturnsToSeekingOnNewBottomOrDailyDrop() {
        XCTAssertEqual(StrategyFitTrendPhaseUpdater.confirmedTurnThreshold, 0.3)
        let turnBoundary = -1.0 + StrategyFitTrendPhaseUpdater.confirmedTurnThreshold
        let boundary = StrategyFitTrendPhaseUpdater.next(
            fitTrend: turnBoundary,
            previousPhase: .worseningConfirmedSeekingBottom,
            previousExtreme: -1.0
        )
        XCTAssertEqual(boundary.phase, .worseningConfirmedSeekingBottom)
        XCTAssertEqual(boundary.extreme, -1.0)

        let rebound = StrategyFitTrendPhaseUpdater.next(
            fitTrend: turnBoundary + 0.000_001,
            previousPhase: .worseningConfirmedSeekingBottom,
            previousExtreme: -1.0
        )
        XCTAssertEqual(rebound.phase, .worseningConfirmedRebounding)
        XCTAssertEqual(rebound.extreme, -1.0)

        let previousTrend = -0.8
        let exactDailyDropBoundary = previousTrend
            - StrategyFitTrendPhaseUpdater.worseningReboundResetThreshold
        let boundaryStillRebounding = StrategyFitTrendPhaseUpdater.next(
            fitTrend: exactDailyDropBoundary,
            previousPhase: rebound.phase,
            previousExtreme: -1.5,
            previousFitTrend: previousTrend
        )
        XCTAssertEqual(boundaryStillRebounding.phase, .worseningConfirmedRebounding)
        XCTAssertEqual(boundaryStillRebounding.extreme, -1.5)

        let dailyDropTrend = exactDailyDropBoundary - 0.000_001
        let dailyDrop = StrategyFitTrendPhaseUpdater.next(
            fitTrend: dailyDropTrend,
            previousPhase: rebound.phase,
            previousExtreme: -1.5,
            previousFitTrend: previousTrend
        )
        XCTAssertEqual(dailyDrop.phase, .worseningConfirmedSeekingBottom)
        XCTAssertEqual(dailyDrop.extreme, dailyDropTrend)

        let newBottom = StrategyFitTrendPhaseUpdater.next(
            fitTrend: -1.1,
            previousPhase: rebound.phase,
            previousExtreme: rebound.extreme
        )
        XCTAssertEqual(newBottom.phase, .worseningConfirmedSeekingBottom)
        XCTAssertEqual(newBottom.extreme, -1.1)
    }

    func testImprovingConfirmationSplitsAtStrictTurnAndReturnsToSeekingOnNewPeak() {
        let turnBoundary = 1.0 - StrategyFitTrendPhaseUpdater.confirmedTurnThreshold
        let boundary = StrategyFitTrendPhaseUpdater.next(
            fitTrend: turnBoundary,
            previousPhase: .improvingConfirmedSeekingPeak,
            previousExtreme: 1.0
        )
        XCTAssertEqual(boundary.phase, .improvingConfirmedSeekingPeak)
        XCTAssertEqual(boundary.extreme, 1.0)

        let pullback = StrategyFitTrendPhaseUpdater.next(
            fitTrend: turnBoundary - 0.000_001,
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

    @MainActor
    func testConfirmedSeekingMaturityUsesExistingConfirmationAndTurnThresholds() async {
        XCTAssertEqual(StrategyFitTrendPhaseUpdater.confirmedLateThreshold, 0.911888)

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

        trade.simFitTrendPhaseRaw = StrategyFitTrendPhase.improvingConfirmedSeekingPeak.rawValue
        trade.simFitTrendPhaseExtreme = StrategyFitTrendPhaseUpdater.confirmedLateThreshold - 0.000_001
        XCTAssertEqual(trade.strategyFitTrendConfirmedMaturity, .early)
        XCTAssertEqual(trade.strategyFitTrendIconColorOpacity, 0.58)
        trade.simFitTrendPhaseExtreme = StrategyFitTrendPhaseUpdater.confirmedLateThreshold
        XCTAssertEqual(trade.strategyFitTrendConfirmedMaturity, .late)
        XCTAssertEqual(trade.strategyFitTrendIconColorOpacity, 1.0)

        trade.simFitTrendPhaseRaw = StrategyFitTrendPhase.worseningConfirmedSeekingBottom.rawValue
        trade.simFitTrendPhaseExtreme = -StrategyFitTrendPhaseUpdater.confirmedLateThreshold + 0.000_001
        XCTAssertEqual(trade.strategyFitTrendConfirmedMaturity, .early)
        XCTAssertEqual(trade.strategyFitTrendIconColorOpacity, 0.58)
        trade.simFitTrendPhaseExtreme = -StrategyFitTrendPhaseUpdater.confirmedLateThreshold
        XCTAssertEqual(trade.strategyFitTrendConfirmedMaturity, .late)
        XCTAssertEqual(trade.strategyFitTrendIconColorOpacity, 1.0)
    }

    func testSameDayPreviewsAlwaysStartFromPreviousOfficialExtreme() {
        let morning = StrategyFitTrendPhaseUpdater.next(
            fitTrend: -1.2,
            previousPhase: .worseningConfirmedSeekingBottom,
            previousExtreme: -1.0
        )
        XCTAssertEqual(morning.extreme, -1.2)

        let afternoon = StrategyFitTrendPhaseUpdater.next(
            fitTrend: -1.0 + StrategyFitTrendPhaseUpdater.confirmedTurnThreshold + 0.000_001,
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

    @MainActor
    func testStrategyFitTrendDisplayHidesCooldownAndWarmup() async {
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

    @MainActor
    func testSplitConfirmationPhasesProvideDistinctIconsAndAccessibilityText() async {
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

        let expectations: [(StrategyFitTrendPhase, Double?, Double, String, String)] = [
            (.improvingConfirmedSeekingPeak, 0.8, 0.58, "arrow.up.right.circle.fill", "適配趨勢改善確認，探頂前期"),
            (.improvingConfirmedSeekingPeak, 1.0, 1.0, "arrow.up.right.circle.fill", "適配趨勢改善確認，探頂後期"),
            (.improvingConfirmedPullingBack, 1.0, 1.0, "arrow.down.right.circle", "適配趨勢改善確認，拉回段"),
            (.worseningConfirmedSeekingBottom, -0.8, 0.58, "arrow.down.right.circle.fill", "適配趨勢惡化確認，探底前期"),
            (.worseningConfirmedSeekingBottom, -1.0, 1.0, "arrow.down.right.circle.fill", "適配趨勢惡化確認，探底後期"),
            (.worseningConfirmedRebounding, -1.0, 1.0, "arrow.up.right.circle", "適配趨勢惡化確認，反彈段")
        ]
        for (phase, extreme, opacity, icon, accessibilityText) in expectations {
            trade.simFitTrendPhaseRaw = phase.rawValue
            trade.simFitTrendPhaseExtreme = extreme
            XCTAssertEqual(trade.strategyFitTrendDisplayPhase, phase)
            XCTAssertEqual(phase.displayIconSystemName, icon)
            XCTAssertEqual(trade.strategyFitTrendIconColorOpacity, opacity)
            XCTAssertEqual(trade.strategyFitTrendAccessibilityText, accessibilityText)
        }
    }
}
