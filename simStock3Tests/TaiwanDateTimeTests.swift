import Foundation
import XCTest
@testable import simStock3

@MainActor
final class TaiwanDateTimeTests: XCTestCase {
    private func date(_ text: String) -> Date {
        twDateTime.strictDateFromString(text, format: "yyyy/MM/dd HH:mm:ss")!
    }

    func testWallClockPreservesAbsoluteInstant() {
        let before = Date()
        let actual = twDateTime.now()
        let after = Date()
        XCTAssertGreaterThanOrEqual(actual, before)
        XCTAssertLessThanOrEqual(actual, after)
    }

    func testInjectedTodayIncludesFractionalLastSecondAndExcludesNextMidnight() {
        let now = date("2026/10/23 12:00:00")
        let start = date("2026/10/23 00:00:00")
        let next = date("2026/10/24 00:00:00")
        let range = twDateTime.dayRange(containing: now)
        XCTAssertEqual(range.lowerBound, start)
        XCTAssertEqual(range.upperBound, next)
        XCTAssertTrue(twDateTime.isDateInToday(start, asOf: now))
        XCTAssertTrue(twDateTime.isDateInToday(next.addingTimeInterval(-0.5), asOf: now))
        XCTAssertFalse(twDateTime.isDateInToday(next, asOf: now))
        XCTAssertFalse(twDateTime.isDateInToday(start.addingTimeInterval(-0.5), asOf: now))
    }

    func testTaiwanDayChangesAtSixteenUTCNotDeviceMidnight() {
        let before = twDateTime.dateFromInternetTimestamp("2026-12-31T15:59:59.500Z")!
        let after = twDateTime.dateFromInternetTimestamp("2026-12-31T16:00:00Z")!
        XCTAssertEqual(twDateTime.stringFromDate(before), "2026/12/31")
        XCTAssertEqual(twDateTime.stringFromDate(after), "2027/01/01")
        XCTAssertFalse(twDateTime.isSameDay(before, after))
        XCTAssertTrue(twDateTime.isSameDay(before, before.addingTimeInterval(-3600)))
    }

    func testCalendarAndDisplayDoNotFollowDeviceTimezone() {
        let previous = NSTimeZone.default
        defer { NSTimeZone.default = previous }
        let instant = Date(timeIntervalSince1970: 1792684800) // 2026-10-23 00:00 Taipei
        for identifier in ["Asia/Taipei", "UTC", "America/Los_Angeles", "America/New_York", "Asia/Tokyo"] {
            NSTimeZone.default = TimeZone(identifier: identifier)!
            XCTAssertEqual(twDateTime.calendar.identifier, .gregorian, identifier)
            XCTAssertEqual(twDateTime.calendar.timeZone.identifier, "Asia/Taipei", identifier)
            XCTAssertEqual(twDateTime.formatter().calendar.identifier, .gregorian, identifier)
            XCTAssertEqual(twDateTime.formatter().timeZone.identifier, "Asia/Taipei", identifier)
            XCTAssertEqual(twDateTime.stringFromDate(instant), "2026/10/23", identifier)
            XCTAssertEqual(twDateTime.startOfDay(instant), instant, identifier)
            XCTAssertEqual(twDateTime.strictDateFromString("2026/10/23"), instant, identifier)
            XCTAssertEqual(twDateTime.monthDay(instant), 1023, identifier)
        }
    }

    func testLeapMonthRangeContainsEntireLastDay() {
        let range = twDateTime.monthRange(containing: date("2024/02/15 12:00:00"))
        XCTAssertEqual(range.lowerBound, date("2024/02/01 00:00:00"))
        XCTAssertEqual(range.upperBound, date("2024/03/01 00:00:00"))
        XCTAssertTrue(range.contains(date("2024/02/29 23:59:59").addingTimeInterval(0.75)))
        XCTAssertFalse(range.contains(range.upperBound))
        XCTAssertEqual(twDateTime.endOfMonth(range.lowerBound), date("2024/02/29 00:00:00"))
    }

    func testMonthRangeCrossesYearAndCalendarArithmeticClampsLeapDay() {
        let range = twDateTime.monthRange(containing: date("2026/12/31 23:59:59"))
        XCTAssertEqual(range.upperBound, date("2027/01/01 00:00:00"))
        XCTAssertEqual(twDateTime.addDays(1, to: date("2024/02/28 13:30:00")), date("2024/02/29 13:30:00"))
        XCTAssertEqual(twDateTime.addMonths(1, to: date("2024/01/31 13:30:00")), date("2024/02/29 13:30:00"))
        XCTAssertEqual(twDateTime.addYears(1, to: date("2024/02/29 13:30:00")), date("2025/02/28 13:30:00"))
    }

    func testRequestStartAndPickerLimitsUseOneTaiwanDay() {
        let now = date("2024/02/29 23:59:59").addingTimeInterval(0.5)
        XCTAssertEqual(twDateTime.requestStart(for: now), date("2023/02/28 00:00:00"))
        let range = twDateTime.simulationStartRange(asOf: now)
        XCTAssertEqual(range.lowerBound, date("2009/02/28 00:00:00"))
        XCTAssertEqual(range.upperBound, date("2023/02/28 00:00:00"))
        XCTAssertEqual(twDateTime.simulationStartRange(asOf: now.addingTimeInterval(0.5)).upperBound,
                       date("2023/03/01 00:00:00"))
    }

    func testStrictGregorianParserRejectsRolloverPartialAndNonCanonicalDates() {
        XCTAssertNotNil(twDateTime.strictDateFromString("2024/02/29"))
        for text in ["2023/02/29", "2024/02/30", "2024/13/01", "2024/00/10", "2024/02/00",
                     "2024/2/29", "2024/02/29 extra", "2024/02", " 2024/02/29", "2024/02/29 "] {
            XCTAssertNil(twDateTime.strictDateFromString(text), text)
        }
        XCTAssertEqual(twDateTime.strictDateFromString("20240229", format: "yyyyMMdd"), date("2024/02/29 00:00:00"))
    }

    func testStrictROCParserAcceptsValidWidthsAndRejectsInvalidDates() {
        XCTAssertEqual(twDateTime.dateFromROCString("113/02/29"), date("2024/02/29 00:00:00"))
        XCTAssertEqual(twDateTime.dateFromROCString("113/2/9"), date("2024/02/09 00:00:00"))
        XCTAssertEqual(twDateTime.dateFromROCString("1/1/1"), date("1912/01/01 00:00:00"))
        for text in ["112/02/29", "113/02/30", "0/01/01", "8089/01/01", "-1/01/01",
                     "113/13/01", "113/01/00", "113/2", "113/02/29junk", "１１３/02/29"] {
            XCTAssertNil(twDateTime.dateFromROCString(text), text)
        }
    }

    func testROCDateKeyRoundTripsStrictSevenDigitProtocol() {
        let date = date("2024/02/29 13:30:00")
        XCTAssertEqual(twDateTime.rocDateKey(date), "1130229")
        XCTAssertEqual(twDateTime.dateFromROCKey("1130229"), twDateTime.startOfDay(date))
        for text in ["1120229", "1130230", "0000101", "113229", "11302290", "113/02/29"] {
            XCTAssertNil(twDateTime.dateFromROCKey(text), text)
        }
    }

    func testOffsetInputRetainsInstantBeforeTaiwanDisplay() {
        let expected = date("2026/10/23 00:00:00")
        let format = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        for text in ["2026-10-22T16:00:00+00:00", "2026-10-22T09:00:00-07:00", "2026-10-23T00:00:00+08:00"] {
            XCTAssertEqual(twDateTime.dateFromString(text, format: format), expected, text)
            XCTAssertEqual(twDateTime.dateFromInternetTimestamp(text), expected, text)
            XCTAssertEqual(twDateTime.stringFromDate(twDateTime.dateFromInternetTimestamp(text)!, format: "yyyy/MM/dd HH:mm:ss"),
                           "2026/10/23 00:00:00", text)
        }
        XCTAssertEqual(twDateTime.dateFromInternetTimestamp("2026-10-22T16:00:00.125Z"), expected.addingTimeInterval(0.125))
        XCTAssertEqual(twDateTime.dateFromInternetTimestamp("2026-10-22T09:00:00.125000000-07:00"), expected.addingTimeInterval(0.125))
        XCTAssertEqual(twDateTime.dateFromInternetTimestamp("2024-02-29T23:30:00-07:00"), date("2024/03/01 14:30:00"))
        XCTAssertEqual(twDateTime.dateFromInternetTimestamp("2024-03-01T00:00:00+14:00"), date("2024/02/29 18:00:00"))
        XCTAssertEqual(twDateTime.dateFromInternetTimestamp("2026-10-22T21:45:00+05:45"), expected)
        XCTAssertEqual(twDateTime.dateFromInternetTimestamp("2026-10-22T12:30:00-03:30"), expected)
    }

    func testInternetTimestampRejectsRolloverAndTrailingText() {
        let invalid = [
            "2026-02-30T03:00:00Z", "2023-02-29T03:00:00+08:00", "2026-04-31T03:00:00-07:00",
            "2026-09-15T03:55:00Zjunk", "2026-09-15T03:55:00Z\n", "2026-09-15T03:55:00Z ",
            "2026-09-15T24:00:00Z", "2026-09-15T03:60:00Z", "2026-09-15T03:55:60Z",
            "0000-01-01T00:00:00Z", "2026-00-01T00:00:00Z", "2026-01-00T00:00:00Z",
            "2026-09-15T03:55:00+24:00", "2026-09-15T03:55:00+08:60",
            "2026-09-15T03:55:00+0800", "2026-09-15T03:55:00", "2026-9-15T03:55:00Z",
            "2026-09-15T03:55:00.Z", "2026-09-15T03:55:00.1234567890Z",
            " 2026-09-15T03:55:00Z", "2026-09-15 03:55:00Z"
        ]
        for text in invalid { XCTAssertNil(twDateTime.dateFromInternetTimestamp(text), text) }
    }

    func testMarketSessionEndpointAndPolicyMilestones() {
        let cases: [(String, Bool)] = [
            ("08:59:59", false), ("09:00:00", true), ("09:05:00", true),
            ("13:29:59", true), ("13:30:00", false), ("15:34:59", false), ("15:35:00", false)
        ]
        for (time, expected) in cases {
            XCTAssertEqual(twDateTime.isInSession(date("2026/10/23 " + time)), expected, time)
        }
        let day = date("2026/10/23 00:00:00")
        XCTAssertEqual(twDateTime.time0905(day), date("2026/10/23 09:05:00"))
        XCTAssertEqual(twDateTime.time1535(day), date("2026/10/23 15:35:00"))
    }

    func testSessionDelayPreservesBothEndpointsAndInjectedToday() {
        let now = date("2026/10/23 09:00:00")
        XCTAssertTrue(twDateTime.isInSession(date("2026/10/23 08:58:00"), delayMinutes: 2))
        XCTAssertFalse(twDateTime.isInSession(date("2026/10/23 13:32:00"), delayMinutes: 2))
        XCTAssertTrue(twDateTime.inMarketingTime(now, forToday: true, asOf: now))
        XCTAssertFalse(twDateTime.inMarketingTime(now, forToday: true, asOf: twDateTime.addDays(1, to: now)))
        XCTAssertTrue(twDateTime.inMarketingTime(now, forToday: false, asOf: twDateTime.addDays(1, to: now)))
        XCTAssertEqual(twDateTime.time0900(now, delayMinutes: -61), date("2026/10/23 07:59:00"))
        XCTAssertEqual(twDateTime.time1330(now, delayMinutes: 61), date("2026/10/23 14:31:00"))
    }

    func testCalendarDaysIncludeWeekendLeapDayAndIgnoreClockTime() {
        XCTAssertEqual(twDateTime.calendarDays(from: date("2026/10/23 13:30:00"), to: date("2026/10/26 09:00:00")), 3)
        XCTAssertEqual(twDateTime.calendarDays(from: date("2024/02/28 23:59:59"), to: date("2024/03/01 00:00:00")), 2)
        XCTAssertEqual(twDateTime.calendarDays(from: date("2024/03/01 00:00:00"), to: date("2024/02/28 23:59:59")), -2)
    }

    func testCalendarDayDifferenceMatchesOriginalTaiwanFormulaAcrossFormalYears() {
        let start = date("2015/01/01 00:00:00")
        for offset in stride(from: 0, through: 4500, by: 7) {
            let end = twDateTime.addDays(offset, to: start)
            let old = Int(round(end.timeIntervalSince(start) / 86400.0))
            XCTAssertEqual(twDateTime.calendarDays(from: start, to: end), old, "day \(offset)")
        }
    }

    func testAnnualizationPreservesExact365DayFormulaAndFloor() {
        let start = date("2020/01/01 00:00:00")
        for days in [-1.0, 0, 1, 364, 365, 366, 1095, 3287.5] {
            let end = start.addingTimeInterval(days * 86400)
            let old = max(1.0, end.timeIntervalSince(start) / 86400.0 / 365.0)
            XCTAssertEqual(twDateTime.annualizationYears(from: start, to: end), old)
        }
        XCTAssertEqual(twDateTime.annualizationYears(from: start, to: date("2021/01/01 00:00:00")), 366.0 / 365.0)
    }

    func testMonthDayMatchesExistingZeroPaddedSeasonalComparison() {
        let start = date("2024/01/01 00:00:00")
        for offset in 0..<366 {
            let date = twDateTime.addDays(offset, to: start)
            let old = twDateTime.stringFromDate(date, format: "MMdd")
            XCTAssertEqual(twDateTime.monthDay(date), Int(old))
            XCTAssertEqual((301...531).contains(twDateTime.monthDay(date)), old >= "0301" && old <= "0531")
        }
    }

    func testElapsedFreshnessRejectsClockRollbackAndPreservesDurationBoundary() {
        let now = date("2026/10/23 12:00:00")
        XCTAssertTrue(twDateTime.isFresh(now, asOf: now, maxAge: 3600))
        XCTAssertTrue(twDateTime.isFresh(now.addingTimeInterval(-3599.9), asOf: now, maxAge: 3600))
        XCTAssertFalse(twDateTime.isFresh(now.addingTimeInterval(-3600), asOf: now, maxAge: 3600))
        XCTAssertFalse(twDateTime.isFresh(now.addingTimeInterval(1), asOf: now, maxAge: 3600))
        XCTAssertFalse(twDateTime.isFresh(now, asOf: now, maxAge: 0))
        XCTAssertEqual(twDateTime.quoteFutureTolerance, 300)
    }
}
