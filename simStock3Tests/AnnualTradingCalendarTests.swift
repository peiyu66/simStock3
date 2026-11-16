import Foundation
import XCTest
@testable import simStock3

nonisolated private final class AnnualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; value = date }
}

nonisolated private final class AnnualProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var urls: [URL] = []
    static func configure(_ responses: [String: (Int, Data)]) {
        lock.lock(); defer { lock.unlock() }; self.responses = responses; urls = []
    }
    static var requests: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let year = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "date" }?.value ?? ""
        Self.lock.lock(); Self.urls.append(url); let response = Self.responses[year]; Self.lock.unlock()
        guard let response else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class AnnualTradingCalendarTests: XCTestCase {
    private func date(_ value: String) -> Date { twDateTime.strictDateFromString(value, format: "yyyy/MM/dd HH:mm")! }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnnualProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func payload(_ year: Int = 2026) -> Data { Data((year == 2026 ? captured2026 : captured2027).utf8) }
    private func snapshot(_ now: Date) throws -> TWSETradingCalendarSnapshot {
        .init(version: 1, sourceURL: TWSETradingCalendar.sourceURL.absoluteString, fetchedAt: now, year: 2026,
              entries: try TWSETradingCalendar.parseAnnualSchedule(payload(), expectedYear: 2026))
    }

    func testCapturedAnnualCalendarPreservesTradingAndClosedMarkersAndPublicationBoundary() async throws {
        let now = date("2026/11/16 09:14"), snapshot = try snapshot(date("2026/11/16 09:14"))
        XCTAssertEqual(snapshot.entries.count, 27)
        for day in ["2026/11/16 09:14", "2026/02/11 10:00", "2026/02/23 10:00"] {
            XCTAssertEqual(TWSETradingCalendar.status(for: date(day), snapshot: snapshot), .tradingDay)
        }
        for day in ["2026/11/15 10:00", "2026/02/12 10:00", "2026/12/25 10:00"] {
            XCTAssertEqual(TWSETradingCalendar.status(for: date(day), snapshot: snapshot), .closed)
        }
        XCTAssertEqual(TWSETradingCalendar.latestCompletedTradingDay(asOf: now, snapshot: snapshot), date("2026/11/13 00:00"))
        XCTAssertEqual(TWSETradingCalendar.latestCompletedTradingDay(asOf: date("2026/11/16 15:35").addingTimeInterval(-0.001), snapshot: snapshot), date("2026/11/13 00:00"))
        XCTAssertEqual(TWSETradingCalendar.latestCompletedTradingDay(asOf: date("2026/11/16 15:35"), snapshot: snapshot), date("2026/11/16 00:00"))
    }

    func testAnnualPayloadRejectsWrongYearIncompleteMalformedAndMixedYearResponses() async throws {
        XCTAssertThrowsError(try TWSETradingCalendar.parseAnnualSchedule(payload(2027), expectedYear: 2026))
        let base = try JSONSerialization.jsonObject(with: payload()) as! [String: Any]
        let mutations: [[String: Any]] = [
            ["data": []], ["stat": "not ready"], ["fields": ["changed", "名稱", "說明"]],
            ["data": [["2026-02-30", "壞日期", ""]]], ["data": [["2026-01-01"]]],
            ["data": [["2027-01-01", "錯年度", ""]]], ["data": [["2026-01-01", "", ""]]]
        ]
        for mutation in mutations {
            let changed = base.merging(mutation) { _, new in new }
            XCTAssertThrowsError(try TWSETradingCalendar.parseAnnualSchedule(JSONSerialization.data(withJSONObject: changed), expectedYear: 2026))
        }
        XCTAssertThrowsError(try TWSETradingCalendar.parseAnnualSchedule(Data("<html>unavailable</html>".utf8), expectedYear: 2026))
    }

    func testExpiredLegacyCacheRefreshesRequestedYearAndColdReopensWithoutNetwork() async throws {
        let now = date("2026/11/16 09:14"), session = session()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        let old = TWSETradingCalendarSnapshot(version: 1, sourceURL: "https://openapi.twse.com.tw/v1/holidaySchedule/holidaySchedule", fetchedAt: date("2026/11/13 09:08"), year: 2026, entries: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(old).write(to: file)
        AnnualProtocol.configure(["20260101": (200, payload())])
        let calendar = TWSETradingCalendar(fileURL: file, session: session, clock: { now })
        let result = await calendar.decision(for: now)
        XCTAssertEqual(result.status, .tradingDay); XCTAssertEqual(result.requestCount, 1)
        XCTAssertEqual(AnnualProtocol.requests, [TWSETradingCalendar.sourceURL(forYear: 2026)])
        let saved = await calendar.cachedSnapshot()
        XCTAssertEqual(saved?.sourceURL, TWSETradingCalendar.sourceURL(forYear: 2026).absoluteString)
        let reopened = TWSETradingCalendar(fileURL: file, session: session, clock: { now })
        let cold = await reopened.decision(for: now)
        XCTAssertEqual(cold.status, .tradingDay); XCTAssertEqual(cold.requestCount, 0)
        XCTAssertEqual(AnnualProtocol.requests.count, 1)
    }

    func testWrongYearHTTPAndNetworkFailuresRetainCacheAndRecoverAfterBackoff() async throws {
        for failure in [0, 1, 2] {
            let now = date("2026/11/16 09:14"), clock = AnnualClock(date("2026/11/16 09:14")), session = session()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let saved = try encoder.encode(snapshot(now.addingTimeInterval(-86401)))
            try saved.write(to: file)
            AnnualProtocol.configure(failure == 2 ? [:] : ["20260101": (failure == 1 ? 503 : 200, payload(2027))])
            let calendar = TWSETradingCalendar(fileURL: file, session: session, clock: { clock.now() })
            let failed = await calendar.decision()
            XCTAssertEqual(failed.status, .unknown); XCTAssertNotNil(failed.refreshError)
            XCTAssertEqual(try Data(contentsOf: file), saved)
            let immediate = await calendar.decision()
            XCTAssertEqual(immediate.status, .unknown); XCTAssertEqual(immediate.requestCount, 0)
            XCTAssertEqual(AnnualProtocol.requests.count, 1)
            clock.set(now.addingTimeInterval(3600))
            AnnualProtocol.configure(["20260101": (200, payload())])
            let recovered = await calendar.decision()
            XCTAssertEqual(recovered.status, .tradingDay); XCTAssertEqual(recovered.requestCount, 1)
        }
    }

    func testCrossYearRequestsNewCalendarAndMissingPreviousYearRemainsConservative() async throws {
        let clock = AnnualClock(date("2026/12/31 16:00")), session = session()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
        AnnualProtocol.configure(["20260101": (200, payload()), "20270101": (200, payload(2027))])
        let calendar = TWSETradingCalendar(fileURL: file, session: session, clock: { clock.now() })
        let december = await calendar.decision()
        XCTAssertEqual(december.status, .tradingDay)
        clock.set(date("2027/01/01 09:14"))
        let january = await calendar.decision()
        XCTAssertEqual(january.status, .closed); XCTAssertEqual(january.requestCount, 1)
        let newYearSnapshot = await calendar.cachedSnapshot()
        for day in ["2027/01/01 09:14", "2027/02/02 10:00", "2027/02/03 10:00"] {
            XCTAssertEqual(TWSETradingCalendar.status(for: date(day), snapshot: newYearSnapshot), .closed,
                           "Official holidays and settlement-only days are not trading days: \(day)")
        }
        for day in ["2027/01/04 09:14", "2027/02/01 10:00", "2027/02/11 10:00"] {
            XCTAssertEqual(TWSETradingCalendar.status(for: date(day), snapshot: newYearSnapshot), .tradingDay)
        }
        XCTAssertEqual(AnnualProtocol.requests.map { $0.query! }, ["response=json&date=20260101", "response=json&date=20270101"])
        let beforeFirstClose = await calendar.latestCompletedTradingDay(asOf: date("2027/01/04 09:14"))
        XCTAssertNil(beforeFirstClose, "Do not invent a prior-year close from a single-year calendar")
        // Refresh at Jan 4, after Jan 1 cache expires, then confirm first published close.
        clock.set(date("2027/01/04 15:35"))
        _ = await calendar.decision()
        let afterFirstClose = await calendar.latestCompletedTradingDay()
        XCTAssertEqual(afterFirstClose, date("2027/01/04 00:00"))
    }

    func testUnknownCalendarStatusDoesNotClaimYahooWasUnnecessary() async {
        var unknown = simObject.TWSEUpdateSummary(); unknown.marketDayStatus = .unknown
        let summary = simObject.DailyPriceUpdateSummary(twse: unknown, yahoo: .init())
        XCTAssertTrue(summary.statusText.contains("Yahoo 尚未查詢（交易日待確認）"))
        XCTAssertFalse(summary.statusText.contains("Yahoo 無需查詢"))
        unknown.marketDayStatus = .closed
        XCTAssertTrue(simObject.DailyPriceUpdateSummary(twse: unknown, yahoo: .init()).statusText.contains("Yahoo 無需查詢"))
        unknown.marketDayStatus = .tradingDay
        XCTAssertTrue(simObject.DailyPriceUpdateSummary(twse: unknown, yahoo: .init()).statusText.contains("Yahoo 無需查詢"))
    }
}

// Captured public TWSE annual JSON on 2026-11-16; schedules may later be revised.
// https://www.twse.com.tw/holidaySchedule/holidaySchedule?response=json&date=20260101
// https://www.twse.com.tw/holidaySchedule/holidaySchedule?response=json&date=20270101
// These are calendar fixtures, not evidence of the user device state; no prices or personal data.
private let captured2026 = #"""
{"stat":"ok","date":"20260101","title":"115 年市場開休市日期","fields":["日期","名稱","說明"],"data":[["2026-01-01","中華民國開國紀念日","依規定放假1日。"],["2026-01-02","國曆新年開始交易日","國曆新年開始交易。"],["2026-02-11","農曆春節前最後交易日","農曆春節前最後交易。\r\n"],["2026-02-12","市場無交易，僅辦理結算交割作業",""],["2026-02-13","市場無交易，僅辦理結算交割作業",""],["2026-02-15","農曆除夕及春節","依規定於2月15日至2月19日放假5日。2月15日適逢星期日，於2月20日（星期五）補假。"],["2026-02-16","農曆除夕及春節","依規定於2月15日至2月19日放假5日。2月15日適逢星期日，於2月20日（星期五）補假。"],["2026-02-17","農曆除夕及春節","依規定於2月15日至2月19日放假5日。2月15日適逢星期日，於2月20日（星期五）補假。\r\n\r\n\r\n"],["2026-02-18","農曆除夕及春節","依規定於2月15日至2月19日放假5日。2月15日適逢星期日，於2月20日（星期五）補假。"],["2026-02-19","農曆除夕及春節","依規定於2月15日至2月19日放假5日。2月15日適逢星期日，於2月20日（星期五）補假。"],["2026-02-20","農曆除夕及春節","依規定於2月15日至2月19日放假5日。2月15日適逢星期日，於2月20日（星期五）補假。"],["2026-02-23","農曆春節後開始交易日","農曆春節後開始交易。"],["2026-02-27","和平紀念日","和平紀念日為2月28日適逢星期六，於2月27日（星期五）補假。"],["2026-02-28","和平紀念日","依規定放假1日。"],["2026-04-03","兒童節及民族掃墓節","兒童節為4月4日適逢星期六，於4月3日（星期五）補假。"],["2026-04-04","兒童節及民族掃墓節","依規定放假1日。"],["2026-04-05","兒童節及民族掃墓節","依規定放假1日。"],["2026-04-06","兒童節及民族掃墓節","民族掃墓節為4月5日適逢星期日，於4月6日（星期一）補假。"],["2026-05-01","勞動節","依規定放假1日。"],["2026-06-19","端午節","依規定放假1日。"],["2026-09-25","中秋節","依規定放假1日。"],["2026-09-28","孔子誕辰紀念日/ 教師節","依規定放假1日。"],["2026-10-09","國慶日","國慶日為10月10日適逢星期六，於10月9日（星期五）補假。"],["2026-10-10","國慶日","依規定放假1日。"],["2026-10-25","臺灣光復暨金門古寧頭大捷紀念日","依規定放假1日。"],["2026-10-26","臺灣光復暨金門古寧頭大捷紀念日","臺灣光復暨金門古寧頭大捷紀念日為10月25日適逢星期日，於10月26日（星期一）補假。"],["2026-12-25","行憲紀念日","依規定放假1日。"]],"queryYear":2026,"total":27}
"""#
private let captured2027 = #"""
{"stat":"ok","date":"20270101","title":"116 年市場開休市日期","fields":["日期","名稱","說明"],"data":[["2027-01-01","中華民國開國紀念日","依規定放假1日。"],["2027-01-04","國曆新年開始交易日","國曆新年開始交易。"],["2027-02-01","農曆春節前最後交易日","農曆春節前最後交易。\r\n2月2日及2月3日市場無交易，僅辦理結算交割作業。\r\n"],["2027-02-02","市場無交易，僅辦理結算交割作業。",""],["2027-02-03","市場無交易，僅辦理結算交割作業。",""],["2027-02-04","農曆除夕及春節","依規定於2月4日至2月10日放假7日。2月6日及2月7日(初一及初二)適逢例假日，於2月9日（星期二）及2月10日（星期三）補假。"],["2027-02-05","農曆除夕及春節","依規定於2月4日至2月10日放假7日。2月6日及2月7日(初一及初二)適逢例假日，於2月9日（星期二）及2月10日（星期三）補假。"],["2027-02-06","農曆除夕及春節","依規定於2月4日至2月10日放假7日。2月6日及2月7日(初一及初二)適逢例假日，於2月9日（星期二）及2月10日（星期三）補假。"],["2027-02-07","農曆除夕及春節","依規定於2月4日至2月10日放假7日。2月6日及2月7日(初一及初二)適逢例假日，於2月9日（星期二）及2月10日（星期三）補假。"],["2027-02-08","農曆除夕及春節","依規定於2月4日至2月10日放假7日。2月6日及2月7日(初一及初二)適逢例假日，於2月9日（星期二）及2月10日（星期三）補假。"],["2027-02-09","農曆除夕及春節","依規定於2月4日至2月10日放假7日。2月6日及2月7日(初一及初二)適逢例假日，於2月9日（星期二）及2月10日（星期三）補假。"],["2027-02-10","農曆除夕及春節","依規定於2月4日至2月10日放假7日。2月6日及2月7日(初一及初二)適逢例假日，於2月9日（星期二）及2月10日（星期三）補假。"],["2027-02-11","農曆春節後開始交易日","農曆春節後開始交易。"],["2027-02-28","和平紀念日","依規定放假1日。"],["2027-03-01","和平紀念日","和平紀念日為2月28日適逢星期日，於3月1日（星期一）補假1日。"],["2027-04-04","兒童節及民族掃墓節","依規定放假1日。"],["2027-04-05","兒童節及民族掃墓節","依規定放假1日。"],["2027-04-06","兒童節及民族掃墓節","兒童節為4月4日適逢星期日，於4月6日（星期二）補假1日。"],["2027-04-30","勞動節","勞動節為5月1日適逢星期六，於4月30日（星期五）補假1日。"],["2027-05-01","勞動節","依規定放假1日。"],["2027-06-09","端午節","依規定放假1日。"],["2027-09-15","中秋節","依規定放假1日。"],["2027-09-28","孔子誕辰紀念日/ 教師節","依規定放假1日。"],["2027-10-10","國慶日","依規定放假1日。"],["2027-10-11","國慶日","國慶日為10月10日適逢星期日，於10月11日（星期一）補假1日。"],["2027-10-25","臺灣光復暨金門古寧頭大捷紀念日","依規定放假1日。"],["2027-12-24","行憲紀念日","行憲紀念日為12月25日適逢星期六，於12月24日（星期五）補假1日。"],["2027-12-25","行憲紀念日","依規定放假1日。"],["2027-12-31","117年中華民國開國紀念日","中華民國開國紀念日為117年1月1日適逢星期六，於116年12月31日（星期五）補假1日。"]],"queryYear":2027,"total":29}
"""#
