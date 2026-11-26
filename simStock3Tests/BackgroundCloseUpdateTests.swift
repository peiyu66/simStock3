import Foundation
import SwiftData
import XCTest
@testable import simStock3

@MainActor final class BackgroundCloseUpdateTests: XCTestCase {
    private func date(_ value: String) -> Date { twDateTime.dateFromString(value, format: "yyyy/MM/dd HH:mm")! }
    private func snapshot(year: Int = 2026, entries: [TWSEHolidayEntry] = []) -> TWSETradingCalendarSnapshot {
        .init(version: 1, sourceURL: "fixture", fetchedAt: date("2026/11/20 09:00"), year: year, entries: entries)
    }
    private func journal() throws -> BackgroundCloseJournal {
        try BackgroundCloseJournal(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("evidence.json"))
    }
    private func complete(_ day: Date) -> BackgroundCloseEvidence {
        .init(tradingDay: day, officialStockIDs: ["TEST"], officialMarket: true,
              recalculationComplete: true, pipelineComplete: true)
    }
    func testScheduleUses1535TaipeiIncludingLateLaunchAndNextWeekday() async {
        let cases = [("2026/11/20 00:00", "2026/11/20 15:35"),
                     ("2026/11/20 13:35", "2026/11/20 15:35"),
                     ("2026/11/20 15:34", "2026/11/20 15:35"),
                     ("2026/11/20 15:35", "2026/11/20 15:35"),
                     ("2026/11/20 16:00", "2026/11/20 16:00"),
                     ("2026/11/21 00:00", "2026/11/23 15:35"),
                     ("2026/11/22 23:59", "2026/11/23 15:35")]
        for (now, expected) in cases {
            XCTAssertEqual(BackgroundCloseSchedule.next(after: date(now), snapshot: snapshot(), attemptedDay: nil), date(expected), now)
        }
        XCTAssertEqual(BackgroundCloseSchedule.next(after: date("2026/11/20 15:36"), snapshot: snapshot(), attemptedDay: date("2026/11/20 00:00")), date("2026/11/23 15:35"))
        XCTAssertEqual(date("2026/11/20 15:35").timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-11-20T07:35:00Z")!.timeIntervalSince1970)
    }
    func testKnownHolidayUnknownYearAndSettlementOnlyDays() async {
        let holidays = snapshot(year: 2027, entries: [
            .init(name: "元旦", date: "1160101", weekday: "", description: "休市"),
            .init(name: "無交易僅交割", date: "1160202", weekday: "", description: ""),
            .init(name: "無交易僅交割", date: "1160203", weekday: "", description: "")]
            + (4...10).map { .init(name: "農曆除夕及春節", date: String(format: "11602%02d", $0), weekday: "", description: "") })
        // Selected official 2027 date ranges, verified 2026-11-20; subject to revisions.
        // https://www.twse.com.tw/holidaySchedule/holidaySchedule?queryYear=116&response=html
        XCTAssertEqual(BackgroundCloseSchedule.next(after: date("2027/01/01 00:00"), snapshot: holidays, attemptedDay: nil), date("2027/01/04 15:35"))
        XCTAssertEqual(BackgroundCloseSchedule.next(after: date("2027/02/02 00:00"), snapshot: holidays, attemptedDay: nil), date("2027/02/11 15:35"))
        XCTAssertEqual(BackgroundCloseSchedule.next(after: date("2026/12/31 23:59"), snapshot: snapshot(), attemptedDay: date("2026/12/31 00:00")), date("2027/01/01 15:35"), "Unknown is eligible to request, never asserted closed")
    }
    func testKnownClosedAndBefore1535NeverExecute() async throws {
        for (time, status) in [("2026/11/20 15:35", TWSEMarketDayStatus.closed), ("2026/11/20 13:35", .tradingDay)] {
            let store = try journal(), now = date(time)
            defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
            var calls = 0
            let result = await BackgroundCloseJob(journal: store).run(at: now, status: status,
                targetDay: twDateTime.startOfDay(now), isBusy: false, clock: { now }) { _ in calls += 1; return self.complete(now) }
            XCTAssertFalse(result); XCTAssertEqual(calls, 0); XCTAssertFalse(store.state.requiresForeground)
        }
    }
    func testSuccessRequiresPriceAndRecalculationAndPersistsExactlyOnce() async throws {
        let store = try journal(), now = date("2026/11/20 15:35"), day = date("2026/11/20 00:00")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let job = BackgroundCloseJob(journal: store)
        let success = await job.run(at: now, status: .tradingDay, targetDay: day, isBusy: false, clock: { now }) { _ in self.complete(day) }
        XCTAssertTrue(success)
        let duplicate = await job.run(at: now, status: .tradingDay, targetDay: day, isBusy: false, clock: { now }) { _ in XCTFail("duplicate"); return self.complete(day) }
        XCTAssertFalse(duplicate)
        let reopened = try BackgroundCloseJournal(url: store.url)
        XCTAssertEqual(reopened.state.attempts.count, 1)
        XCTAssertEqual(reopened.state.attempts.first?.outcome, "success")
        XCTAssertTrue(reopened.state.attempts.first?.evidence.recalculationComplete == true)
    }
    func testSixMonthDeclineRunsTailAndRequiresForegroundAcrossRestart() async throws {
        let store = try journal(), now = date("2026/11/20 15:35"), day = date("2026/11/20 00:00")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var recalculated = false
        let success = await BackgroundCloseJob(journal: store).run(at: now, status: .tradingDay, targetDay: day,
            isBusy: false, clock: { now }) { decline in
                decline(); recalculated = true
                return self.complete(day)
            }
        XCTAssertFalse(success); XCTAssertTrue(recalculated)
        let reopened = try BackgroundCloseJournal(url: store.url)
        XCTAssertTrue(reopened.state.requiresForeground)
        let retry = await BackgroundCloseJob(journal: reopened).run(at: date("2026/11/23 15:35"), status: .tradingDay,
            targetDay: date("2026/11/23 00:00"), isBusy: false, clock: { now }) { _ in XCTFail("May not cross manual batch boundary"); return self.complete(day) }
        XCTAssertFalse(retry)
        try reopened.foreground(at: now, evidence: complete(day))
        XCTAssertFalse(reopened.state.requiresForeground)
        XCTAssertEqual(reopened.state.attempts.last?.origin, "foreground")
        XCTAssertEqual(reopened.state.attempts.first?.outcome, "awaitingForeground")
    }
    func testExpirationOverridesApparentSuccessAndPreservesRecovery() async throws {
        let store = try journal(), now = date("2026/11/20 15:35"), day = date("2026/11/20 00:00")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let expiration = PriceRequestCancellation()
        let success = await BackgroundCloseJob(journal: store).run(at: now, status: .tradingDay, targetDay: day,
            isBusy: false, expired: expiration, clock: { now }) { _ in expiration.cancel(); return self.complete(day) }
        XCTAssertFalse(success)
        XCTAssertEqual(store.state.attempts.last?.outcome, "expired")
        XCTAssertFalse(store.state.requiresForeground)
        XCTAssertEqual(store.nextRequest(now: now, snapshot: snapshot()), date("2026/11/20 15:55"))
    }
    func testPartialRecalculationAndProcessDeathCannotBecomeSuccess() async throws {
        let store = try journal(), now = date("2026/11/20 15:35"), day = date("2026/11/20 00:00")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var incomplete = complete(day); incomplete.recalculationComplete = false
        let success = await BackgroundCloseJob(journal: store).run(at: now, status: .tradingDay, targetDay: day,
            isBusy: false, clock: { now }) { _ in incomplete }
        XCTAssertFalse(success); XCTAssertEqual(store.state.attempts.last?.outcome, "partial")
        _ = try store.begin(at: date("2026/11/23 15:35"))
        let reopened = try BackgroundCloseJournal(url: store.url)
        XCTAssertEqual(reopened.state.attempts.last?.outcome, "interrupted")
        XCTAssertFalse(reopened.state.requiresForeground)
    }
    func testHardTerminationKeepsBackupWithoutOpeningForeground() async throws {
        let store = try journal(), now = date("2026/11/20 15:35")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let retry = date("2026/11/20 15:55"), day = twDateTime.startOfDay(now)
        _ = try store.begin(at: now)
        XCTAssertEqual(store.nextRequest(now: now, snapshot: snapshot()), retry)
        try store.scheduled(for: retry)
        let reopened = try BackgroundCloseJournal(url: store.url)
        XCTAssertEqual(reopened.state.attempts.last?.outcome, "interrupted")
        XCTAssertFalse(reopened.state.requiresForeground)
        var armedNext: Date?
        let succeeded = await BackgroundCloseJob(journal: reopened).run(at: retry, status: .tradingDay,
            targetDay: day, scheduledEarliest: reopened.state.scheduledEarliest, isBusy: false, clock: { retry },
            armBackup: { armedNext = reopened.nextRequest(now: retry, snapshot: self.snapshot()) }) { _ in
                XCTAssertNotNil(armedNext, "The backup is armed before transport/calculation")
                return self.complete(day)
            }
        XCTAssertTrue(succeeded)
        XCTAssertEqual(armedNext, date("2026/11/23 15:35"))
        XCTAssertEqual(reopened.state.attempts.map(\.outcome), ["interrupted", "success"])
    }

    func testRetryTurnsIntoNextTradingDayAfterAnotherFailureOrForegroundCompletion() async throws {
        let now = date("2026/11/20 15:35"), retry = date("2026/11/20 15:55"), day = twDateTime.startOfDay(now)
        for foregroundFinishes in [false, true] {
            let store = try journal()
            defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
            let id = try store.begin(at: now)
            try store.finish(id: id, at: now, outcome: "expired", evidence: .init(), needsForeground: false)
            if foregroundFinishes {
                try store.foreground(at: retry, evidence: complete(day))
            } else {
                let second = try store.begin(at: retry)
                try store.finish(id: second, at: retry, outcome: "partial", evidence: .init(), needsForeground: false)
            }
            XCTAssertFalse(store.permitsAttempt(on: day))
            XCTAssertEqual(store.nextRequest(now: retry, snapshot: snapshot()), date("2026/11/23 15:35"))
        }
    }

    func testInterruptedHistoricalWorkRetainsManualBoundary() async throws {
        let store = try journal(), now = date("2026/11/20 15:35")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        _ = try store.begin(at: now)
        XCTAssertTrue(store.protectHistoryBoundary())
        let reopened = try BackgroundCloseJournal(url: store.url)
        XCTAssertEqual(reopened.state.attempts.last?.outcome, "interrupted")
        XCTAssertTrue(reopened.state.requiresForeground)
        XCTAssertNil(reopened.nextRequest(now: now, snapshot: snapshot()))
    }

    func testBusyAndConcurrentForegroundLeaseDoNotStart() async throws {
        let store = try journal(), now = date("2026/11/20 15:35")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let ran = await BackgroundCloseJob(journal: store).run(at: now, status: .tradingDay,
            targetDay: twDateTime.startOfDay(now), isBusy: true, clock: { now }) { _ in XCTFail("busy"); return .init() }
        XCTAssertFalse(ran); XCTAssertEqual(store.state.attempts.last?.outcome, "foregroundBusy")
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        defer { withExtendedLifetime(container) {} }
        XCTAssertTrue(PriceUpdateLease.acquire(container.mainContext))
        defer { PriceUpdateLease.release(container.mainContext) }
        let sim = simObject(modelContext: container.mainContext)
        let result = await sim.updateDailyPrices(clock: { now })
        XCTAssertTrue(result.twse.wasInterrupted)
    }
}

nonisolated private final class HeldOfficialPriceProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = 0
    nonisolated(unsafe) private static var startSignal: XCTestExpectation?
    nonisolated(unsafe) private static var stopSignal: XCTestExpectation?
    static func prepare() -> (XCTestExpectation, XCTestExpectation) {
        lock.lock(); defer { lock.unlock() }
        started = 0
        startSignal = XCTestExpectation(description: "official request started")
        stopSignal = XCTestExpectation(description: "official request cancelled")
        return (startSignal!, stopSignal!)
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return started }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.started += 1; let signal = Self.startSignal; Self.lock.unlock()
        signal?.fulfill()
    }
    override func stopLoading() {
        Self.lock.lock(); let signal = Self.stopSignal; Self.lock.unlock()
        signal?.fulfill()
    }
}

extension BackgroundCloseUpdateTests {
    func testInFlightOfficialRequestCancellationStopsTransportAndCannotWrite() async throws {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        defer { withExtendedLifetime(container) {} }
        let stock = Stock(sId: "TEST", sName: "取消測試", group: "A", dateFirst: date("2025/11/01 00:00"), dateStart: date("2026/11/01 00:00"))
        container.mainContext.insert(stock); try container.mainContext.save()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HeldOfficialPriceProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let tech = Technical(modelContext: container.mainContext, priceSession: session)
        let (started, stopped) = HeldOfficialPriceProtocol.prepare()
        let request = Task { await tech.twseRequestAsync(stock: stock, dateStart: self.date("2026/11/01 00:00"), recalculate: false) }
        await fulfillment(of: [started], timeout: 3)
        request.cancel()
        let success = await request.value
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertFalse(success)
        XCTAssertEqual(HeldOfficialPriceProtocol.count, 1)
        XCTAssertTrue(try Trade.fetch(in: container.mainContext, for: stock).isEmpty)
        XCTAssertTrue(stock.confirmedHistory.months.isEmpty)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await tech.twseRequestAsync(stock: stock, dateStart: self.date("2026/11/01 00:00"))
        }
        let second = await cancelled.value
        XCTAssertFalse(second)
        XCTAssertEqual(HeldOfficialPriceProtocol.count, 1, "Cancelled tasks must not send their next request")
    }

    func testTaskCancellationAndOverlappingWakeDoNotPublishSuccess() async throws {
        let store = try journal(), now = date("2026/11/20 15:35"), day = date("2026/11/20 00:00")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let job = BackgroundCloseJob(journal: store)
        var continuation: CheckedContinuation<Void, Never>?
        let started = XCTestExpectation(description: "pipeline entered")
        let first = Task { @MainActor in
            await job.run(at: now, status: .tradingDay, targetDay: day, isBusy: false, clock: { now }) { _ in
                await withCheckedContinuation { continuation = $0; started.fulfill() }
                return self.complete(day)
            }
        }
        await fulfillment(of: [started], timeout: 3)
        let duplicate = await job.run(at: now, status: .tradingDay, targetDay: day, isBusy: false, clock: { now }) { _ in
            XCTFail("Overlapping background operation"); return self.complete(day)
        }
        XCTAssertFalse(duplicate)
        first.cancel(); continuation?.resume()
        let success = await first.value
        XCTAssertFalse(success)
        XCTAssertEqual(store.state.attempts.count, 1)
        XCTAssertEqual(store.state.attempts.last?.outcome, "cancelled")
        XCTAssertFalse(store.state.requiresForeground)
        XCTAssertEqual(store.nextRequest(now: now, snapshot: snapshot()), date("2026/11/20 15:55"))
    }
}


extension BackgroundCloseUpdateTests {
    func testDelayedWeekdayWakeUsesPriorScheduledWindowAndKeepsTodays1535() async throws {
        let store = try journal(), now = date("2026/11/24 01:00"), day = date("2026/11/23 00:00")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try store.scheduled(for: date("2026/11/23 15:35"))
        let reloaded = try BackgroundCloseJournal(url: store.url)
        let success = await BackgroundCloseJob(journal: reloaded).run(at: now, status: .tradingDay, targetDay: day,
            scheduledEarliest: reloaded.state.scheduledEarliest, isBusy: false, clock: { now }) { _ in self.complete(day) }
        XCTAssertTrue(success)
        XCTAssertEqual(reloaded.state.attempts.last?.evidence.tradingDay, day)
        XCTAssertEqual(reloaded.state.attempts.last?.earliestBeginDate, date("2026/11/23 15:35"))
        XCTAssertEqual(BackgroundCloseSchedule.next(after: now, snapshot: snapshot(), attemptedDay: reloaded.state.lastBackgroundDay), date("2026/11/24 15:35"))
    }
    func testEvidenceWriteFailurePreventsNetworkAndRemainsPending() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("blocking parent".utf8).write(to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try BackgroundCloseJournal(url: folder.appendingPathComponent("evidence.json"))
        let now = date("2026/11/20 15:35")
        let success = await BackgroundCloseJob(journal: store).run(at: now, status: .tradingDay,
            targetDay: date("2026/11/20 00:00"), isBusy: false, clock: { now }) { _ in XCTFail("No writes without durable attempt marker"); return .init() }
        XCTAssertFalse(success); XCTAssertTrue(store.state.requiresForeground)
    }
}


extension BackgroundCloseUpdateTests {
    func testExpiryAfterCompletedPipelineDoesNotRewriteItsResult() async throws {
        let store = try journal(), now = date("2026/11/20 15:35"), day = date("2026/11/20 00:00")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let token = PriceRequestCancellation()
        let success = await BackgroundCloseJob(journal: store).run(at: now, status: .tradingDay, targetDay: day,
            isBusy: false, expired: token, clock: { now }) { _ in self.complete(day) }
        XCTAssertTrue(success)
        XCTAssertFalse(token.cancel())
        XCTAssertEqual(store.state.attempts.last?.outcome, "success")
    }
}


extension BackgroundCloseUpdateTests {
    func testUnknownCalendarEntersStandardPipelineInsteadOfPreemptiveSkip() async throws {
        let store = try journal(), now = date("2026/11/20 15:35"), day = date("2026/11/20 00:00")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var calls = 0
        let success = await BackgroundCloseJob(journal: store).run(at: now, status: .unknown, targetDay: nil,
            isBusy: false, clock: { now }) { _ in calls += 1; return self.complete(day) }
        XCTAssertEqual(calls, 1); XCTAssertTrue(success)
        XCTAssertEqual(store.state.attempts.last?.evidence.tradingDay, day)
    }
}


extension BackgroundCloseUpdateTests {
    func testHeadlessMigrationUsesExistingUserActionWarningBoundary() async throws {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        defer { withExtendedLifetime(container) {} }
        let stock = Stock(sId: "TEST", sName: "遷移", group: "A", dateFirst: date("2025/11/01 00:00"), dateStart: date("2026/11/01 00:00"))
        container.mainContext.insert(stock)
        let trade = Trade(stock: stock, dateTime: date("2026/11/20 13:30"))
        container.mainContext.insert(trade)
        try container.mainContext.save()
        let sim = simObject(modelContext: container.mainContext)
        XCTAssertFalse(BackgroundCloseRuntime.requiresForegroundMigrationConfirmation(sim: sim))
        trade.simInvestByUser = 1; try container.mainContext.save()
        XCTAssertTrue(BackgroundCloseRuntime.requiresForegroundMigrationConfirmation(sim: sim))
        stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
        stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
        try container.mainContext.save()
        XCTAssertFalse(BackgroundCloseRuntime.requiresForegroundMigrationConfirmation(sim: sim))
        XCTAssertEqual(trade.simInvestByUser, 1)
    }
}


extension BackgroundCloseUpdateTests {
    func testOrdinaryFailureRetriesNextEligibleDayWithoutCrossingManualBatchHold() async throws {
        let store = try journal(), now = date("2026/11/20 15:35"), day = date("2026/11/20 00:00")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let job = BackgroundCloseJob(journal: store)
        let first = await job.run(at: now, status: .unknown, targetDay: nil, isBusy: false, clock: { now }) { _ in
            .init(detail: "日曆刷新失敗，保持既有重試規則", requiresForegroundAfterPartial: false)
        }
        XCTAssertFalse(first); XCTAssertFalse(store.state.requiresForeground)
        let monday = date("2026/11/23 15:35")
        XCTAssertEqual(BackgroundCloseSchedule.next(after: now, snapshot: snapshot(), attemptedDay: store.state.lastBackgroundDay), monday)
        let second = await job.run(at: monday, status: .tradingDay, targetDay: twDateTime.startOfDay(monday), isBusy: false, clock: { monday }) { _ in
            self.complete(twDateTime.startOfDay(monday))
        }
        XCTAssertTrue(second)
        XCTAssertEqual(store.state.attempts.map(\.outcome), ["partial", "success"])
        XCTAssertNotEqual(store.state.attempts.first?.evidence.tradingDay, day, "Failed calendar cannot manufacture a trading day")
    }
}


extension BackgroundCloseUpdateTests {
    func testBackgroundHonorsForegroundSettingsCleanupAndSearchDeferrals() async throws {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        defer { withExtendedLifetime(container) {} }
        let ui = uiObject(modelContext: container.mainContext, isReadOnlySnapshot: true)
        XCTAssertFalse(ui.blocksBackgroundCloseUpdate)
        ui.simulationSettingsWillPresent(); XCTAssertTrue(ui.blocksBackgroundCloseUpdate)
        ui.simulationSettingsDidDismiss(); XCTAssertFalse(ui.blocksBackgroundCloseUpdate)
        ui.historyCleanupWillPresent(); XCTAssertTrue(ui.blocksBackgroundCloseUpdate)
        ui.historyCleanupDidDismiss(); XCTAssertFalse(ui.blocksBackgroundCloseUpdate)
        ui.catalogSearchDidBegin(); XCTAssertTrue(ui.blocksBackgroundCloseUpdate)
        ui.catalogSearchDidEnd(); XCTAssertFalse(ui.blocksBackgroundCloseUpdate)
        ui.sim.tech.invalidateTimer()
    }
}


extension BackgroundCloseUpdateTests {
    func testDelayedFailureAfterTodays1535DoesNotRequeueImmediately() async throws {
        let store = try journal(), now = date("2026/11/24 16:00")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let success = await BackgroundCloseJob(journal: store).run(at: now, status: .unknown, targetDay: nil,
            scheduledEarliest: date("2026/11/23 15:35"), isBusy: false, clock: { now }) { _ in .init() }
        XCTAssertFalse(success); XCTAssertFalse(store.state.requiresForeground)
        XCTAssertEqual(BackgroundCloseSchedule.next(after: now, snapshot: snapshot(), attemptedDay: store.state.lastBackgroundDay), date("2026/11/25 15:35"))
    }
    func testPrematureDeliveryDoesNotConsumeTodaysEligibleWindow() async throws {
        let store = try journal(), early = date("2026/11/20 13:35"), due = date("2026/11/20 15:35")
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let job = BackgroundCloseJob(journal: store)
        let first = await job.run(at: early, status: .tradingDay, targetDay: nil, isBusy: false, clock: { early }) { _ in XCTFail("Before 15:35"); return .init() }
        XCTAssertFalse(first); XCTAssertNil(store.state.lastBackgroundDay)
        XCTAssertEqual(BackgroundCloseSchedule.next(after: early, snapshot: snapshot(), attemptedDay: store.state.lastBackgroundDay), due)
        let second = await job.run(at: due, status: .tradingDay, targetDay: twDateTime.startOfDay(due), isBusy: false, clock: { due }) { _ in self.complete(twDateTime.startOfDay(due)) }
        XCTAssertTrue(second)
    }
}


extension BackgroundCloseUpdateTests {
    func testHeadlessUpdateDoesNotSeedEmptyOrUngroupedStore() async throws {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        defer { withExtendedLifetime(container) {} }
        XCTAssertNil(try BackgroundCloseRuntime.simulationForBackground(context: container.mainContext))
        XCTAssertTrue(try Stock.fetchAll(in: container.mainContext).isEmpty)
        let stock = Stock(sId: "TEST", sName: "保留", group: "", dateFirst: date("2025/11/01 00:00"), dateStart: date("2026/11/01 00:00"))
        container.mainContext.insert(stock); try container.mainContext.save()
        XCTAssertNil(try BackgroundCloseRuntime.simulationForBackground(context: container.mainContext))
        XCTAssertEqual(try Stock.fetchAll(in: container.mainContext).map(\.sId), ["TEST"])
        stock.group = "A"; try container.mainContext.save()
        let sim = try XCTUnwrap(BackgroundCloseRuntime.simulationForBackground(context: container.mainContext))
        XCTAssertFalse(sim.tech.yahooSchedulingIsForeground)
        XCTAssertEqual(sim.getStocks().map(\.sId), ["TEST"])
    }
}
