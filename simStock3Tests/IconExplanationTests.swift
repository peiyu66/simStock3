import XCTest
@testable import simStock3

@MainActor
final class IconExplanationTests: XCTestCase {
    private func fixture() -> Trade {
        let date = twDateTime.dateFromString("2026-10-06")!
        let stock = Stock(sId: "DEMO", sName: "示例股", group: "測試", dateFirst: date,
                          dateStart: date.addingTimeInterval(-200 * 86400), simInvestAuto: 2, simMoneyBase: 100)
        stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
        stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
        let trade = Trade(stock: stock, dateTime: date)
        trade.dataSource = "TWSE"
        trade.rollRounds = 4
        trade.rollDays = 200
        trade.rollAmtRoi = 20.5
        trade.rollAmtProfit = 1234567
        trade.priceClose = 111
        trade.priceHigh = 112
        trade.priceLow = 109
        return trade
    }

    func testWarningCopyKeepsPriorDateAndRecoveryMeaning() {
        var snapshot = TrueAnnualReturnWarning.Snapshot(status: .caution, priorAnnual: 2.4,
            recoveryFloor: 3, priceRecovered: false, recentReturnRecovered: false, gradeSeekingPeak: false)
        XCTAssertTrue(snapshot.explanationMessage.contains("先前"))
        XCTAssertTrue(snapshot.explanationValues.contains("前一交易日真年報酬率 2.40%"))
        XCTAssertTrue(snapshot.explanationValues.contains("完整恢復參考值 3.00%"))
        XCTAssertTrue(snapshot.explanationValues.contains("尚差 0.60 個百分點"))
        snapshot.breakoutReference = 123.456
        XCTAssertTrue(snapshot.explanationValues.contains("突破觀察參照 123.46 元"))
        for invalid in [Double.nan, Double.infinity, 0, -1] {
            snapshot.breakoutReference = invalid
            XCTAssertTrue(snapshot.explanationValues.contains("突破觀察參照 — · 目前沒有有效突破觀察"))
        }
        var prewarning = TrueAnnualReturnWarning.Snapshot(status: .normal, priorAnnual: 1,
            recoveryFloor: nil, priceRecovered: false, recentReturnRecovered: false, gradeSeekingPeak: false)
        prewarning.prewarningFailureDays = 0
        prewarning.prewarningReason = .returnWeakness
        XCTAssertTrue(prewarning.explanationValues.contains("突破觀察參照 — · 目前沒有有效突破觀察"))
        snapshot = .init(status: .recovering, priorAnnual: nil, recoveryFloor: nil,
            priceRecovered: true, recentReturnRecovered: true, gradeSeekingPeak: true)
        XCTAssertTrue(snapshot.explanationMessage.contains("仍在警戒內"))
        XCTAssertEqual(snapshot.explanationValues.filter { $0.contains("資料不足") }.count, 3)
        XCTAssertTrue(TrueAnnualReturnWarning.Snapshot.unavailable.explanationMessage.contains("不代表已解除"))
    }

    func testPrewarningReasonsAndGraceDoNotDescribeOldCauseAsCurrent() {
        for reason in [TrueAnnualReturnWarning.PrewarningReason.returnWeakness, .priceBottom, .both, .anchorWeakness, .returnAndAnchor, .bottomAndAnchor, .all] {
            var s = TrueAnnualReturnWarning.Snapshot(status: .released, priorAnnual: -2,
                recoveryFloor: -1, priceRecovered: false, recentReturnRecovered: false, gradeSeekingPeak: false)
            s.prewarningReason = reason; s.prewarningFailureDays = 0
            XCTAssertEqual(s.explanationMessage, s.prewarningMessage)
            XCTAssertFalse(s.explanationValues.contains { $0.contains("完整恢復參考值") })
            for day in 1...2 {
                s.prewarningFailureDays = day
                XCTAssertTrue(s.explanationMessage.contains("先前提示："))
                XCTAssertTrue(s.explanationMessage.contains("\(day) 個交易日不成立"))
            }
        }
    }

    func testGradeUsesHistoricalTradeAndDoesNotMutateIt() {
        let t = fixture()
        let original = t.rollAmtRoi
        XCTAssertTrue(t.gradeExplanation.values.contains("實年報酬率 20.5%"))
        XCTAssertTrue(t.gradeExplanation.values.contains("效率分數 41.00 分"))
        XCTAssertTrue(t.gradeExplanation.values.contains("累計損益 123.46 萬元"))
        t.rollAmtRoi = -2
        XCTAssertTrue(t.gradeExplanation.emphasizesLoss)
        XCTAssertTrue(t.gradeExplanation.values.contains("實年報酬率 -2.0%"))
        XCTAssertEqual(original, 20.5)
        XCTAssertEqual(t.rollAmtRoi, -2)
    }

    func testDirtyBoundaryAndSimulationOnlyInvalidation() {
        let t = fixture()
        t.stock.simulationDirtyFrom = t.dateTime.addingTimeInterval(86400)
        XCTAssertFalse(t.explanationSimulationPending)
        t.stock.simulationDirtyFrom = t.dateTime
        XCTAssertTrue(t.explanationSimulationPending)
        XCTAssertTrue(t.gradeExplanation.values.isEmpty)
        XCTAssertFalse(t.explanationTechnicalPending)
        t.stock.simulationDirtyFrom = .distantPast
        XCTAssertFalse(t.explanationTechnicalPending)
        t.stock.technicalDirtyFrom = t.dateTime
        XCTAssertTrue(t.explanationTechnicalPending)
        XCTAssertEqual(t.pricePathExplanation.title, "個股價格")
    }

    func testUnratedAndPreparationDoNotInventGrade() {
        let t = fixture()
        t.rollRounds = 1; t.rollDays = 20
        XCTAssertTrue(t.gradeExplanation.values.contains("累計輪數（含進行中） 1 輪"))
        t.stock.dateStart = t.dateTime.addingTimeInterval(86400)
        XCTAssertEqual(t.gradeExplanation.title, "模擬前資料")
        XCTAssertEqual(t.gradeExplanation.values.count, 1)
    }

    func testPeakUsesExtremeNotCurrentClose() {
        let state = PricePathStoredState(phase: .seekingPeakLate, barrier: 0.1,
                                        anchorClose: 100, extremeClose: 116, daysSinceExtreme: 1)
        let values = IconExplanation.pricePathValues(state: state, close: 113, unit: "元")
        XCTAssertTrue(values.contains("本段最大漲幅 16.00%"))
        XCTAssertTrue(values.contains("進入後期門檻 15.00%"))
    }

    func testPullbackAndReboundUseExtremeDenominator() {
        var state = PricePathStoredState(phase: .pullingBackLate, barrier: 0.08,
                                        anchorClose: 100, extremeClose: 120, daysSinceExtreme: 2)
        XCTAssertTrue(IconExplanation.pricePathValues(state: state, close: 111, unit: "元").contains("由高點回落 7.50%"))
        state.phase = .reboundingLate; state.extremeClose = 80
        XCTAssertTrue(IconExplanation.pricePathValues(state: state, close: 86, unit: "點").contains("由低點回升 7.50%"))
        XCTAssertTrue(IconExplanation.pricePathValues(state: state, close: 86, unit: "點").contains("本段低點 80.00 點"))
    }

    func testMissingAndNonfiniteNeverFormatAsZero() {
        XCTAssertEqual(IconExplanation.number("趨勢值", .nan, unit: "分"), "趨勢值 — · 資料不足")
        XCTAssertEqual(IconExplanation.pricePathValues(state: nil, close: 100, unit: "元"), ["價格路徑數值 — · 資料不足"])
        let t = fixture()
        t.simFitFast = 42; t.simFitSlow = 41; t.simFitTrend = 1
        t.simFitObservationCount = 125
        t.simFitTrendPhaseRaw = StrategyFitTrendPhase.improvingConfirmedSeekingPeak.rawValue
        t.simFitTrendPhaseExtreme = 1.1
        XCTAssertTrue(t.gradeTrendExplanation.values.contains("趨勢值 1.00 分"))
        XCTAssertFalse(t.gradeTrendExplanation.values.joined().contains("%"))
    }

    func testMarketDateSourceAndVersionAreIndependentOfStock() {
        let date = twDateTime.dateFromString("2024-01-02")!
        let m = MarketDay(dateTime: date, indexOpen: 100, indexHigh: 120, indexLow: 100, indexClose: 111)
        m.technicalStateVersion = MarketDataStore.technicalStateVersion
        m.applyPricePathState(.init(phase: .pullingBackLate, barrier: 0.08, anchorClose: 100, extremeClose: 120, daysSinceExtreme: 2))
        XCTAssertTrue(IconExplanation.market(m).context!.contains(twDateTime.stringFromDate(m.dateTime)))
        XCTAssertEqual(IconExplanation.market(m).contextValue, "指數 111.00 點")
        XCTAssertTrue(IconExplanation.market(m).values.contains("由高點回落 7.50%"))
        m.technicalStateVersion = 0
        XCTAssertTrue(IconExplanation.market(m).message.contains("待重算"))
        XCTAssertEqual(IconExplanation.market(m).title, "加權指數")
        XCTAssertTrue(IconExplanation.market(m).values.isEmpty)
    }

    func testManualCancellationAndPrincipalRecoveryAreNotNegativeCounts() {
        let t = fixture()
        t.simInvestByUser = -1; t.simInvestAdded = 1; t.simInvestTimes = 2
        XCTAssertTrue(t.investmentExplanation.values.contains("當日手動設定 取消自動加碼"))
        t.simInvestAdded = -2
        XCTAssertTrue(t.investmentExplanation.values.contains("當日回收加碼本金 2 倍"))
        XCTAssertTrue(t.reversalExplanation.values.contains("當日結果 無交易／無持股"))
    }
}
