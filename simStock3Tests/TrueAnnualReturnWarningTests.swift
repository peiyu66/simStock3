import XCTest
import SwiftData
@testable import simStock3

final class TrueAnnualReturnWarningTests: XCTestCase {
    func testPrewarningThreeDayClearanceResetAndPriority() {
        func advance(_ state: inout TrueAnnualReturnWarning, z: Double = -1,
                     close: Double = 100, ma60: Double = 100, mature: Bool = true)
            -> TrueAnnualReturnWarning.Snapshot {
            state.advance(annual: -100, close: close, ma20: 100, ma60: ma60,
                          gradeSeekingPeak: false, ma20DiffZ125: z,
                          ma60DiffZ125: -1, hasMatureZ125: mature)
        }
        var state = seeded()
        XCTAssertNil(advance(&state, mature: false).prewarningFailureDays)
        let first = advance(&state)
        XCTAssertEqual(first.status, .normal)
        XCTAssertEqual(first.prewarningFailureDays, 0)
        XCTAssertEqual(first.symbol, "exclamationmark.triangle")
        XCTAssertEqual(advance(&state, z: 0).prewarningFailureDays, 1)
        XCTAssertEqual(advance(&state, z: 1).prewarningFailureDays, 2)
        var branch = state
        XCTAssertNil(advance(&branch, z: 1).prewarningFailureDays)
        XCTAssertEqual(advance(&state).prewarningFailureDays, 0) // Requalification resets.
        XCTAssertEqual(advance(&state, z: 0).prewarningFailureDays, 1)
        XCTAssertEqual(advance(&state, z: 0).prewarningFailureDays, 2)
        XCTAssertFalse(advance(&state, z: 0).isWarning) // Third failure clears today.
        XCTAssertEqual(advance(&state).prewarningFailureDays, 0)
        let caution = advance(&state, close: 80, ma60: 90)
        XCTAssertEqual(caution.status, .caution)
        XCTAssertNil(caution.prewarningFailureDays)
        XCTAssertEqual(caution.symbol, "exclamationmark.triangle.fill")
        var missing = seeded()
        XCTAssertTrue(advance(&missing).isPrewarning)
        XCTAssertNil(advance(&missing, z: .nan).prewarningFailureDays)
    }

    @MainActor
    func testPrewarningMaturityPersistencePartialRepairAndDateSeed() async throws {
        let container = try ModelContainer(for: Stock.self, Trade.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let db = ModelContext(container)
        let first = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1609459200))
        let stock = Stock(sId: "PRE", sName: "預警", group: "測試", dateFirst: first,
            dateStart: first.addingTimeInterval(100 * 86400), simInvestAuto: 2, simMoneyBase: 100)
        stock.technicalStateVersion = 3; stock.simulationStateVersion = 54
        db.insert(stock)
        let trades = (0..<200).map { i -> Trade in
            let t = Trade(stock: stock, dateTime: first.addingTimeInterval(Double(i) * 86400 + 48600))
            t.priceClose = 100; t.tMa60 = 100; t.tMa20 = 100
            t.rollAmtProfit = Double(1000 - i) * 100 // Positive ROI can deteriorate too.
            t.tMa20DiffZ125 = [184, 185, 187, 188, 189].contains(i) ? 0 : -1
            t.tMa60DiffZ125 = -1
            db.insert(t)
            return t
        }
        var full = SimulationRollingContext()
        for t in trades { full.update(after: t) }
        try db.save()
        XCTAssertFalse(trades[182].storedAnnualWarning.isPrewarning)
        XCTAssertEqual(trades[183].storedAnnualWarning.prewarningFailureDays, 0)
        XCTAssertEqual(trades[184].storedAnnualWarning.prewarningFailureDays, 1)
        XCTAssertEqual(trades[185].storedAnnualWarning.prewarningFailureDays, 2)
        XCTAssertEqual(trades[186].storedAnnualWarning.prewarningFailureDays, 0)
        XCTAssertFalse(trades[189].storedAnnualWarning.isPrewarning)
        XCTAssertEqual(trades[190].storedAnnualWarning.prewarningFailureDays, 0)
        let bytes = trades.map(\.simAnnualWarningData)
        for i in 180..<200 {
            var partial = SimulationRollingContext.seeded(before: i, in: trades)
            partial.update(after: trades[i])
            XCTAssertEqual(trades[i].simAnnualWarningData, bytes[i], "Array seed \(i)")
            var dated = try SimulationRollingContext.seeded(before: trades[i].dateTime, for: stock, in: db)
            dated.update(after: trades[i])
            XCTAssertEqual(trades[i].simAnnualWarningData, bytes[i], "Date seed \(i)")
        }
        // A broken checkpoint must rebuild the same counter, including pre-start maturity.
        trades[185].simAnnualWarningData = nil
        var repaired = try SimulationRollingContext.seeded(before: trades[186].dateTime, for: stock, in: db)
        repaired.update(after: trades[186])
        XCTAssertEqual(trades[186].simAnnualWarningData, bytes[186])
    }

    func testStrictLocalReleaseRearmsWithoutLoweringReferences() {
        var state = seeded()
        _ = state.advance(annual: 2, close: 89, ma20: 90, ma60: 90, gradeSeekingPeak: true)
        for _ in 0..<61 {
            _ = state.advance(annual: 2, close: 60, ma20: 70, ma60: 70, gradeSeekingPeak: true)
        }
        XCTAssertEqual(state.warningPriceHigh, 100) // Old high never ages out.
        _ = state.advance(annual: 8, close: 100, ma20: 70, ma60: 70, gradeSeekingPeak: true)
        XCTAssertEqual(state.advance(annual: 8, close: 100, ma20: 70, ma60: 70,
                                     gradeSeekingPeak: true).status, .recovering) // Equality is not a breakout.
        _ = state.advance(annual: 9, close: 100, ma20: 70, ma60: 70, gradeSeekingPeak: true)
        let release = state.advance(annual: 9, close: 101, ma20: 70, ma60: 70, gradeSeekingPeak: true)
        XCTAssertEqual(release.status, .released)
        XCTAssertFalse(release.isWarning)
        XCTAssertEqual(state.recoveryFloor, 10)
        XCTAssertEqual(state.warningPriceHigh, 101)
        _ = state.advance(annual: 1, close: 90, ma20: 95, ma60: 70, gradeSeekingPeak: false)
        XCTAssertEqual(state.advance(annual: 1, close: 89, ma20: 95, ma60: 70,
                                     gradeSeekingPeak: false).status, .caution)
        XCTAssertFalse(state.locallyReleased)
        XCTAssertEqual(state.recoveryFloor, 10)
        XCTAssertEqual(state.warningPriceHigh, 101)
        _ = state.advance(annual: .nan, close: 110, ma20: 95, ma60: 70, gradeSeekingPeak: false)
        XCTAssertEqual(state.warningPriceHigh, 110) // Valid price retained through ROI gap.
    }

    private func seeded(last: Double = 5, older: Double = 10, near: Double = 6,
                        grade: Bool = true) -> TrueAnnualReturnWarning {
        var state = TrueAnnualReturnWarning()
        for i in 0..<61 {
            XCTAssertEqual(state.advance(annual: i == 0 ? older : i == 40 ? near : last,
                close: 100, ma20: 70, ma60: 100, gradeSeekingPeak: grade).status, .unavailable)
        }
        return state
    }

    func testActivationEqualityAndFrozenRecovery() {
        var state = seeded()
        XCTAssertEqual(state.advance(annual: 2, close: 89, ma20: 70, ma60: 90, gradeSeekingPeak: true).status, .caution)
        for _ in 0..<61 { _ = state.advance(annual: 2, close: 60, ma20: 70, ma60: 70, gradeSeekingPeak: true) }
        XCTAssertEqual(state.recoveryFloor, 10)
        _ = state.advance(annual: 8, close: 70, ma20: 70, ma60: 70, gradeSeekingPeak: true)
        let recovering = state.advance(annual: 10, close: 70, ma20: 70, ma60: 70, gradeSeekingPeak: false)
        XCTAssertEqual(recovering.status, .recovering) // Prior Grade, not today's.
        XCTAssertEqual(recovering.recoveryGap, 2)
        XCTAssertEqual(state.advance(annual: 10, close: 70, ma20: 70, ma60: 70, gradeSeekingPeak: false).status, .normal)
        var equalLong = seeded(last: 5, older: 5)
        XCTAssertEqual(equalLong.advance(annual: 5, close: 89, ma20: 70, ma60: 90, gradeSeekingPeak: true).status, .normal)
        var equalShort = seeded(near: 5)
        XCTAssertEqual(equalShort.advance(annual: 5, close: 89, ma20: 70, ma60: 90, gradeSeekingPeak: true).status, .caution)
    }

    func testGradeGateOnlyNarrowsObservationAndInvalidDataNeverReleases() {
        var state = seeded(grade: false)
        _ = state.advance(annual: 2, close: 89, ma20: 70, ma60: 90, gradeSeekingPeak: false)
        for _ in 0..<61 { _ = state.advance(annual: 2, close: 60, ma20: 70, ma60: 70, gradeSeekingPeak: false) }
        _ = state.advance(annual: 8, close: 70, ma20: 70, ma60: 70, gradeSeekingPeak: false)
        XCTAssertEqual(state.advance(annual: 8, close: 70, ma20: 70, ma60: 70, gradeSeekingPeak: true).status, .caution)
        XCTAssertEqual(state.advance(annual: 8, close: 70, ma20: 70, ma60: 70, gradeSeekingPeak: false).status, .recovering)
        XCTAssertEqual(state.advance(annual: .nan, close: 70, ma20: 70, ma60: 70, gradeSeekingPeak: true).status, .unavailable)
        XCTAssertEqual(state.recoveryFloor, 10)
        XCTAssertEqual(state.advance(annual: 8, close: 70, ma20: 70, ma60: 70, gradeSeekingPeak: true).status, .unavailable)
        let separateStock = TrueAnnualReturnWarning()
        XCTAssertNil(separateStock.recoveryFloor)
    }

    @MainActor
    func testPersistedResultsMatchOriginalAndResumeAtEveryBoundary() async throws {
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1609459200))
        let stock = Stock(sId: "TEST", sName: "測試", group: "測試", dateFirst: start,
                          dateStart: start, simInvestAuto: 2, simMoneyBase: 100)
        stock.technicalStateVersion = 3
        stock.simulationStateVersion = 54
        let trades = (0..<180).map { i -> Trade in
            let t = Trade(stock: stock, dateTime: start.addingTimeInterval(Double(i) * 86400 + 48600))
            t.priceClose = i < 61 ? 100 : i < 130 ? 89 : Double(100 + i - 130)
            t.tMa60 = i < 61 ? 100 : 90
            t.tMa20 = 70
            t.rollAmtProfit = i == 0 ? 300000 : i < 130 ? 150000 : i < 160 ? Double(240000 + (i - 130) * 600) : 360000
            t.simFitTrendPhaseRaw = 8
            return t
        }
        var oracle = TrueAnnualReturnWarning()
        var context = SimulationRollingContext()
        var expected: [TrueAnnualReturnWarning.Snapshot] = []
        for t in trades {
            expected.append(oracle.advance(annual: t.baseRoi, close: t.priceClose, ma20: t.tMa20, ma60: t.tMa60, gradeSeekingPeak: true))
            context.update(after: t)
            XCTAssertEqual(t.storedAnnualWarning, expected.last)
        }
        XCTAssertEqual(expected[61].status, .caution)
        XCTAssertEqual(expected[131].status, .released)
        XCTAssertEqual(expected.last?.status, .normal)
        let bytes = trades.map(\.simAnnualWarningData)
        for index in 1..<trades.count {
            var partial = SimulationRollingContext.seeded(before: index, in: trades)
            partial.update(after: trades[index])
            XCTAssertEqual(trades[index].simAnnualWarningData, bytes[index], "Resume at \(index)")
        }
        stock.simInvestAuto = 10
        XCTAssertEqual(trades[100].storedAnnualWarning.status, .unavailable)
        stock.simInvestAuto = 2
        stock.dateStart = trades[30].date
        XCTAssertEqual(trades[100].storedAnnualWarning.status, .unavailable)
        var rebuilt = SimulationRollingContext()
        for t in trades { rebuilt.update(after: t) }
        XCTAssertNil(trades[0].simAnnualWarningData)
        XCTAssertEqual(trades[62].storedAnnualWarning.status, .unavailable)
    }

    @MainActor
    func testColdReadAndVersionedPayloadDoNotRebuildHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        let schema = Schema([Stock.self, Trade.self])
        let config = ModelConfiguration(schema: schema, url: url)
        let snapshot = TrueAnnualReturnWarning.Snapshot(status: .released, priorAnnual: 5,
            recoveryFloor: 10, priceRecovered: false, recentReturnRecovered: false, gradeSeekingPeak: true,
            prewarningFailureDays: 2)
        func save() throws {
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let date = Calendar.current.startOfDay(for: Date())
            let stock = Stock(sId: "COLD", sName: "冷啟", group: "測試", dateFirst: date,
                dateStart: date, simInvestAuto: 2, simMoneyBase: 100)
            stock.technicalStateVersion = 3; stock.simulationStateVersion = 54
            context.insert(stock)
            let trade = Trade(stock: stock, dateTime: date)
            context.insert(trade)
            AnnualWarningPersistence.write(snapshot, continuationFloor: 10, continuationPriceHigh: 100, locallyReleased: true, to: trade)
            try context.save()
        }
        try save()
        let reopened = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(reopened)
        let trade = try XCTUnwrap(context.fetch(FetchDescriptor<Trade>()).first)
        // Only one row exists: no 61-day history is available to rebuild this result.
        XCTAssertEqual(trade.storedAnnualWarning, snapshot)
        XCTAssertFalse(context.hasChanges)
        trade.stock.simulationStateVersion = 52
        XCTAssertEqual(trade.storedAnnualWarning.status, .unavailable)
        trade.stock.simulationStateVersion = 54
        trade.stock.simulationDirtyFrom = trade.dateTime
        XCTAssertEqual(trade.storedAnnualWarning.status, .unavailable)
        trade.stock.simulationDirtyFrom = nil
        let data = try XCTUnwrap(trade.simAnnualWarningData)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["formatVersion"] = 999
        trade.simAnnualWarningData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(trade.storedAnnualWarning.status, .unavailable)
        trade.simAnnualWarningData = Data("corrupt".utf8)
        XCTAssertEqual(trade.storedAnnualWarning.status, .unavailable)
    }

    func testCheckpointPreservesLongReferenceAcrossGapAndBranchCopies() {
        var original = seeded()
        _ = original.advance(annual: 2, close: 89, ma20: 70, ma60: 90, gradeSeekingPeak: true)
        let history = Array(repeating: (annual: 2.0, close: 60.0, ma60: 70.0, grade: true), count: 61)
        var resumed = TrueAnnualReturnWarning.seeded(recoveryFloor: original.recoveryFloor, warningPriceHigh: original.warningPriceHigh, locallyReleased: false, observations: history)
        var branch = resumed
        _ = branch.advance(annual: .nan, close: 60, ma20: 70, ma60: 70, gradeSeekingPeak: true)
        XCTAssertEqual(branch.recoveryFloor, 10)
        XCTAssertEqual(resumed.advance(annual: 2, close: 60, ma20: 70, ma60: 70, gradeSeekingPeak: true).status, .caution)
        let invalidHistory = history + [(annual: Double.nan, close: 60, ma60: 70, grade: true)]
        var gap = TrueAnnualReturnWarning.seeded(recoveryFloor: 10, warningPriceHigh: 100, locallyReleased: false, observations: invalidHistory)
        XCTAssertEqual(gap.advance(annual: 20, close: 100, ma20: 70, ma60: 70, gradeSeekingPeak: true).status, .unavailable)
        XCTAssertEqual(gap.recoveryFloor, 10)
    }
}
