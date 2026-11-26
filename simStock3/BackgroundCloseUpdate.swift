import Foundation
import SwiftData
import BackgroundTasks
import UIKit

/// Cancellation can arrive off MainActor while a response is queued for saving.
nonisolated final class PriceRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var request: URLSessionDataTask?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func start(_ request: URLSessionDataTask) {
        lock.lock(); self.request = request
        if cancelled { request.cancel() }
        // A cancelled suspended task is resumed only to deliver its cancellation callback.
        // Starting transport and cancellation are serialized by this same lock.
        request.resume()
        lock.unlock()
    }
    @discardableResult func cancel() -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        cancelled = true; let request = request; lock.unlock()
        request?.cancel()
        return true
    }
    /// The completed pipeline owns its result; a later expiry must not turn it
    /// into a cancellation between the evidence commit and setTaskCompleted.
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        finished = true
        return !cancelled
    }
}

@MainActor enum PriceUpdateLease {
    private static var contexts: Set<ObjectIdentifier> = []
    static func acquire(_ context: ModelContext) -> Bool { contexts.insert(ObjectIdentifier(context)).inserted }
    static func release(_ context: ModelContext) { contexts.remove(ObjectIdentifier(context)) }
    static func isBusy(_ context: ModelContext) -> Bool { contexts.contains(ObjectIdentifier(context)) }
}

nonisolated enum BackgroundCloseSchedule {
    static func isWeekday(_ date: Date) -> Bool {
        let weekday = twDateTime.calendar.component(.weekday, from: date)
        return weekday != 1 && weekday != 7
    }
    static func cycleDay(at now: Date, earliest: Date) -> Date {
        let scheduledDay = twDateTime.startOfDay(earliest)
        return now >= twDateTime.time1535(now) ? max(scheduledDay, twDateTime.startOfDay(now)) : scheduledDay
    }
    /// Unknown dates may be scheduled. Only the standard download pipeline refreshes the calendar.
    static func next(after now: Date, snapshot: TWSETradingCalendarSnapshot?, attemptedDay: Date?) -> Date? {
        var day = twDateTime.startOfDay(now)
        for _ in 0..<370 {
            if isWeekday(day), TWSETradingCalendar.status(for: day, snapshot: snapshot) != .closed,
               attemptedDay.map({ day > twDateTime.startOfDay($0) }) ?? true {
                return max(now, twDateTime.time1535(day))
            }
            day = twDateTime.addDays(1, to: day)
        }
        return nil
    }
}

nonisolated struct BackgroundCloseEvidence: Codable, Equatable {
    var tradingDay: Date?
    var officialStockIDs: [String] = []
    var officialMarket = false
    var recalculationComplete = false
    var pipelineComplete = false
    var detail = ""
    var requiresForegroundAfterPartial: Bool?
    var isComplete: Bool {
        tradingDay != nil && !officialStockIDs.isEmpty && officialMarket
            && recalculationComplete && pipelineComplete
    }
}

nonisolated struct BackgroundCloseAttempt: Codable {
    var id = UUID()
    var origin: String
    var startedAt: Date
    var earliestBeginDate: Date?
    var endedAt: Date?
    var outcome: String
    var evidence = BackgroundCloseEvidence()
    var cycleDay: Date?
    // Absent in 113.1: the earlier version cannot prove that it did not
    // cross a history batch boundary before being interrupted.
    var automaticRecovery: Bool?
}

/// Separate atomic evidence file; the existing SwiftData schema and user data are unchanged.
@MainActor final class BackgroundCloseJournal {
    struct State: Codable {
        var attempts: [BackgroundCloseAttempt] = []
        var requiresForeground = false
        var lastBackgroundDay: Date?
        var scheduledEarliest: Date?
    }
    let url: URL
    private(set) var state: State
    init(url: URL) throws {
        self.url = url
        state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
        // A process death cannot convert a submitted source write into success.
        if let index = state.attempts.lastIndex(where: { $0.outcome == "running" }) {
            state.attempts[index].outcome = "interrupted"
            state.attempts[index].evidence.detail = "上次背景工作未正常結束"
            state.requiresForeground = state.attempts[index].automaticRecovery != true
            try save()
        }
    }
    private func save() throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            state.requiresForeground = true
            if !state.attempts.isEmpty { state.attempts[state.attempts.count - 1].outcome = "evidenceSaveFailed" }
            throw error
        }
    }
    func scheduled(for date: Date) throws {
        state.scheduledEarliest = date
        try save()
    }
    func skip(at now: Date, outcome: String, consumesDay: Bool = true) throws {
        state.attempts.append(.init(origin: "background", startedAt: now, earliestBeginDate: state.scheduledEarliest, endedAt: now, outcome: outcome))
        state.attempts = Array(state.attempts.suffix(60))
        if consumesDay {
            state.lastBackgroundDay = BackgroundCloseSchedule.cycleDay(at: now,
                earliest: state.scheduledEarliest ?? twDateTime.time1535(now))
        }
        try save()
    }
    func begin(at now: Date, tradingDay: Date? = nil, earliest: Date? = nil) throws -> UUID {
        let day = twDateTime.startOfDay(tradingDay ?? now)
        let entry = BackgroundCloseAttempt(origin: "background", startedAt: now, earliestBeginDate: earliest,
            outcome: "running", cycleDay: day, automaticRecovery: true)
        state.attempts.append(entry)
        state.attempts = Array(state.attempts.suffix(60))
        state.lastBackgroundDay = day
        try save()
        return entry.id
    }
    func protectHistoryBoundary() -> Bool {
        guard let last = state.attempts.indices.last, state.attempts[last].outcome == "running" else { return false }
        if state.attempts[last].automaticRecovery == false { return state.requiresForeground }
        state.attempts[last].automaticRecovery = false
        state.requiresForeground = true
        do { try save(); return true } catch { return false }
    }
    private func attempts(on day: Date) -> [BackgroundCloseAttempt] {
        state.attempts.filter {
            $0.origin == "background" && $0.cycleDay == day
        }
    }
    func permitsAttempt(on day: Date) -> Bool {
        guard !state.requiresForeground else { return false }
        let attempts = attempts(on: day)
        guard let last = attempts.last else { return state.lastBackgroundDay.map { $0 < day } ?? true }
        return attempts.count < 2 && !foregroundCompleted(day, after: last.startedAt)
            && ["interrupted", "expired", "cancelled", "partial"].contains(last.outcome)
    }
    private func foregroundCompleted(_ day: Date, after started: Date) -> Bool {
        state.attempts.contains {
            $0.origin == "foreground" && $0.outcome == "success" && $0.startedAt >= started
                && ($0.evidence.tradingDay ?? .distantPast) >= day
        }
    }
    func nextRequest(now: Date, snapshot: TWSETradingCalendarSnapshot?) -> Date? {
        guard !state.requiresForeground else { return nil }
        if let last = state.attempts.last(where: { $0.origin == "background" }), let cycle = last.cycleDay,
           last.automaticRecovery == true,
           !foregroundCompleted(cycle, after: last.startedAt),
           ["running", "interrupted", "expired", "cancelled", "partial"].contains(last.outcome),
           attempts(on: cycle).count == 1,
           BackgroundCloseSchedule.isWeekday(now),
           TWSETradingCalendar.status(for: now, snapshot: snapshot) != .closed {
            let retry = max(now, last.startedAt.addingTimeInterval(20 * 60))
            if twDateTime.startOfDay(retry) == cycle { return retry }
        }
        return BackgroundCloseSchedule.next(after: now, snapshot: snapshot, attemptedDay: state.lastBackgroundDay)
    }
    func finish(id: UUID, at now: Date, outcome: String, evidence: BackgroundCloseEvidence, needsForeground: Bool) throws {
        guard let index = state.attempts.firstIndex(where: { $0.id == id }) else { return }
        state.attempts[index].endedAt = now
        state.attempts[index].outcome = outcome
        state.attempts[index].evidence = evidence
        if let tradingDay = evidence.tradingDay {
            state.lastBackgroundDay = max(state.lastBackgroundDay ?? tradingDay, twDateTime.startOfDay(tradingDay))
        }
        state.requiresForeground = needsForeground
        try save()
    }
    func foreground(at now: Date, evidence: BackgroundCloseEvidence) throws {
        state.attempts.append(.init(origin: "foreground", startedAt: now, endedAt: now,
            outcome: evidence.isComplete ? "success" : "partial", evidence: evidence))
        state.attempts = Array(state.attempts.suffix(60))
        if evidence.isComplete {
            state.requiresForeground = false
            if let day = evidence.tradingDay {
                state.lastBackgroundDay = max(state.lastBackgroundDay ?? day, twDateTime.startOfDay(day))
            }
        }
        try save()
    }
}

/// This runner is independent of BGTaskScheduler, so expiration/partial results can be tested deterministically.
@MainActor final class BackgroundCloseJob {
    let journal: BackgroundCloseJournal
    private(set) var isRunning = false
    init(journal: BackgroundCloseJournal) { self.journal = journal }

    func run(at now: Date, status: TWSEMarketDayStatus, targetDay: Date?, scheduledEarliest: Date? = nil, isBusy: Bool,
             expired: PriceRequestCancellation = PriceRequestCancellation(), clock: () -> Date,
             armBackup: () -> Void = {},
             operation: (_ declineBatch: @escaping () -> Void) async -> BackgroundCloseEvidence) async -> Bool {
        let earliest = scheduledEarliest ?? twDateTime.time1535(now)
        let cycleDay = BackgroundCloseSchedule.cycleDay(at: now, earliest: earliest)
        guard !isRunning, journal.permitsAttempt(on: cycleDay) else { return false }
        if isBusy {
            do { try journal.skip(at: now, outcome: "foregroundBusy") }
            catch { simLog.addLog("背景收盤略過證據保存失敗：\(error)") }
            return false
        }
        isRunning = true
        defer { isRunning = false }
        do {
            guard BackgroundCloseSchedule.isWeekday(now), now >= earliest,
                  earliest >= twDateTime.time1535(earliest) else {
                try journal.skip(at: now, outcome: "outsideWindow", consumesDay: false)
                return false
            }
            let id = try journal.begin(at: now, tradingDay: cycleDay, earliest: earliest)
            guard status != .closed else {
                try journal.finish(id: id, at: clock(), outcome: "closed",
                    evidence: .init(tradingDay: targetDay), needsForeground: false)
                return false
            }
            guard !Task.isCancelled, !expired.isCancelled else {
                try journal.finish(id: id, at: clock(), outcome: "cancelled", evidence: .init(tradingDay: targetDay), needsForeground: false)
                return false
            }
            armBackup()
            var declined = false
            let evidence = await operation { declined = true }
            let didExpire = !expired.finish()
            let outcome = didExpire ? "expired" : Task.isCancelled ? "cancelled"
                : declined ? "awaitingForeground" : evidence.isComplete ? "success" : "partial"
            let needsForeground = declined || ((didExpire || Task.isCancelled) && journal.state.requiresForeground)
                || (outcome != "success" && evidence.requiresForegroundAfterPartial == true)
            try journal.finish(id: id, at: clock(), outcome: outcome, evidence: evidence, needsForeground: needsForeground)
            simLog.addLog("背景收盤 \(outcome)：\(evidence.detail)")
            return outcome == "success"
        } catch {
            simLog.addLog("背景收盤證據保存失敗：\(error)")
            return false
        }
    }
}

@MainActor final class BackgroundCloseRuntime {
    static let shared = BackgroundCloseRuntime()
    static let identifier = "com.peiyou.simStock3.official-close"
    static let stateChanged = Notification.Name("BackgroundCloseStateChanged")
    private(set) var enabled = false
    private(set) var isRunning = false
    private var container: ModelContainer?
    private var job: BackgroundCloseJob?
    private var task: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private class WeakUI { weak var value: uiObject?; init(_ value: uiObject) { self.value = value } }
    private var interfaces: [WeakUI] = []

    func attach(_ ui: uiObject) { if enabled { interfaces.append(WeakUI(ui)) } }
    func configure(container: ModelContainer) {
        guard !enabled else { return }
        self.container = container
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            job = BackgroundCloseJob(journal: try BackgroundCloseJournal(url: folder.appendingPathComponent("background-close-evidence.json")))
        } catch { simLog.addLog("背景收盤暫停：無法讀取完成證據 \(error)") }
        enabled = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            MainActor.assumeIsolated { Self.shared.launch(task) }
        }
        guard enabled else { return }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { _ in MainActor.assumeIsolated { Self.shared.schedule() } })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { _ in MainActor.assumeIsolated { Self.shared.cancelForForeground(); Self.shared.schedule() } })
        if UIApplication.shared.applicationState == .active { schedule() }
    }
    func schedule() {
        guard enabled, let job else { return }
        scheduleTask?.cancel()
        if job.journal.state.requiresForeground {
            if !isRunning { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier) }
            return
        }
        scheduleTask = Task { @MainActor in
            let snapshot = await TWSETradingCalendar.shared.cachedSnapshot()
            guard !Task.isCancelled else { return }
            self.submitNext(job: job, snapshot: snapshot)
        }
    }
    private func submitNext(job: BackgroundCloseJob, snapshot: TWSETradingCalendarSnapshot?) {
        guard let next = job.journal.nextRequest(now: twDateTime.now(), snapshot: snapshot) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = next
        do {
            // A successful submit replaces the pending request for this identifier.
            try BGTaskScheduler.shared.submit(request)
            try job.journal.scheduled(for: next)
        } catch {
            // Don't cancel: a previously accepted backup may still be pending.
            simLog.addLog("背景收盤排程未保存或未獲系統接受：\(error)")
        }
    }
    func cancelForForeground() { task?.cancel() }

    private func launch(_ systemTask: BGTask) {
        guard let container, let job, !isRunning,
              UIApplication.shared.applicationState != .active,
              !interfaces.contains(where: { $0.value?.blocksBackgroundCloseUpdate == true }),
              !PriceUpdateLease.isBusy(container.mainContext) else {
            if !isRunning {
                do { try job?.journal.skip(at: twDateTime.now(), outcome: "foregroundBusy") }
                catch { simLog.addLog("背景收盤略過證據保存失敗：\(error)") }
            }
            systemTask.setTaskCompleted(success: false); schedule(); return
        }
        isRunning = true
        NotificationCenter.default.post(name: Self.stateChanged, object: nil)
        let expired = PriceRequestCancellation()
        task = Task { @MainActor in
            let now = twDateTime.now()
            let calendar = TWSETradingCalendar.shared
            let snapshot = await calendar.cachedSnapshot()
            let status = TWSETradingCalendar.status(for: now, snapshot: snapshot)
            let target = TWSETradingCalendar.latestCompletedTradingDay(asOf: now, snapshot: snapshot)
            var simulation: simObject?
            let success = await job.run(at: now, status: status, targetDay: target,
                scheduledEarliest: job.journal.state.scheduledEarliest, isBusy: false, expired: expired, clock: twDateTime.now,
                armBackup: { self.submitNext(job: job, snapshot: snapshot) }) { decline in
                do { simulation = try Self.simulationForBackground(context: container.mainContext) }
                catch { return .init(detail: "讀取股群失敗：\(error)", requiresForegroundAfterPartial: true) }
                guard let sim = simulation else { return .init(detail: "沒有既有股群，背景未新增資料") }
                // Match the foreground warning: only migrations involving saved user actions need confirmation.
                guard !Self.requiresForegroundMigrationConfirmation(sim: sim) else {
                    return .init(tradingDay: target, detail: "資料規則遷移待前景確認", requiresForegroundAfterPartial: true)
                }
                let summary = await sim.updateDailyPrices(clock: twDateTime.now,
                    onBatchCompletion: { _ in decline(); return nil },
                    protectBackgroundHistory: { job.journal.protectHistoryBoundary() })
                return Self.evidence(summary: summary, sim: sim, context: container.mainContext)
            }
            simulation?.tech.invalidateTimer()
            self.isRunning = false
            self.task = nil
            systemTask.expirationHandler = nil
            systemTask.setTaskCompleted(success: success)
            NotificationCenter.default.post(name: Self.stateChanged, object: nil)
            self.schedule()
        }
        let activeTask = task
        systemTask.expirationHandler = { if expired.cancel() { activeTask?.cancel() } }
    }

    static func simulationForBackground(context: ModelContext) throws -> simObject? {
        // simObject's normal first-launch initializer seeds default groups. Headless work must not do that.
        guard !(try Stock.fetchGrouped(in: context)).isEmpty else { return nil }
        let sim = simObject(modelContext: context)
        sim.tech.yahooSchedulingIsForeground = false
        return sim
    }

    static func requiresForegroundMigrationConfirmation(sim: simObject) -> Bool {
        sim.tech.pendingMigrationUserActions(in: sim.getStocks()).actions > 0
    }

    static func evidence(summary: simObject.DailyPriceUpdateSummary, sim: simObject, context: ModelContext) -> BackgroundCloseEvidence {
        var result = BackgroundCloseEvidence(tradingDay: summary.twse.expectedCompletedTradingDay,
            pipelineComplete: !summary.hasIncompleteWork, detail: summary.statusText,
            requiresForegroundAfterPartial: summary.twse.reachedBatchLimit || summary.twse.market.reachedBatchLimit
                || summary.twse.historyCoverageSaveFailed)
        guard let day = result.tradingDay else { return result }
        let stocks = sim.getStocks()
        do {
            for stock in stocks {
                if let trade = try Trade.fetch(in: context, for: stock, on: day),
                   trade.dataSource == "TWSE", trade.hasUsableOfficialPrice { result.officialStockIDs.append(stock.sId) }
            }
            let market = try MarketDay.fetchSameDay(as: day, in: context)
            result.officialMarket = market?.isOfficial == true && market?.hasUsableRawValues == true
            result.recalculationComplete = !stocks.isEmpty && !sim.tech.hasPendingDataRecalculation(in: stocks)
                && market?.hasCurrentTechnicalValues == true
            result.pipelineComplete = result.pipelineComplete && result.officialStockIDs.count == stocks.count
            try context.save()
        } catch { result.pipelineComplete = false; result.requiresForegroundAfterPartial = true; result.detail = "完成證據讀取／保存失敗：\(error)" }
        return result
    }
    func recordForeground(_ summary: simObject.DailyPriceUpdateSummary, sim: simObject, context: ModelContext) {
        guard enabled else { return }
        do { try job?.journal.foreground(at: twDateTime.now(), evidence: Self.evidence(summary: summary, sim: sim, context: context)) }
        catch { simLog.addLog("前景完成證據保存失敗：\(error)") }
        schedule()
    }
}
