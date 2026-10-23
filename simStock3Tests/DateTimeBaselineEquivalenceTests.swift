import Foundation
import XCTest
@testable import simStock3

/// Formula equivalence over every calendar date in v41's raw-history span,
/// including its three fixed windows (2017/07/22, 2020/07/22, 2023/07/22).
/// The independent reference retains the pre-refactor Taiwan formulas. These
/// deterministic tests require no private store and do not replace the actual
/// fixed-window replay and all-persisted-field comparison against v41.
@MainActor
final class DateTimeBaselineEquivalenceTests: XCTestCase {
    private var referenceCalendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "zh_Hant_TW")
        value.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return value
    }

    private func referenceDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        referenceCalendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private var historyDays: [Date] {
        let calendar = referenceCalendar
        let end = referenceDate(2026, 7, 22)
        var date = referenceDate(2016, 7, 22)
        var result: [Date] = []
        while date <= end {
            result.append(date)
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        return result
    }

    func testEveryFormalHistoryDayMatchesOldDayAndYearFormulasAcrossDeviceZones() {
        let previous = NSTimeZone.default
        defer { NSTimeZone.default = previous }
        let dates = historyDays
        XCTAssertEqual(dates.count, 3653)
        let starts = [referenceDate(2017, 7, 22), referenceDate(2020, 7, 22), referenceDate(2023, 7, 22)]
        for zone in ["Asia/Taipei", "UTC", "America/Los_Angeles"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            for (index, date) in dates.enumerated() {
                // Adjacent rows, weekends, holidays, leap-year and long-cycle
                // gaps all remain calendar-day counts, not trading-row counts.
                for gap in [0, 1, 3, 10, 60, 365, 366, 1095] {
                    let from = dates[max(0, index - gap)]
                    let old = Int(round(date.timeIntervalSince(from) / 86400.0))
                    XCTAssertEqual(twDateTime.calendarDays(from: from, to: date), old,
                                   "\(zone), history day \(index), gap \(gap)")
                    XCTAssertEqual(twDateTime.calendarDays(from: date, to: from), -old)
                }
                for start in starts {
                    let old = max(1.0, date.timeIntervalSince(start) / 86400.0 / 365.0)
                    XCTAssertEqual(twDateTime.annualizationYears(from: start, to: date), old,
                                   "\(zone), history day \(index)")
                }
            }
        }
    }

    func testEveryFormalHistoryDayKeepsEffectivePreparationAndLeapYearBounds() {
        let calendar = referenceCalendar
        for (index, day) in historyDays.enumerated() {
            // The old Stock accessor kept the configured time, but its fetch
            // boundary normalized to Taiwan midnight. Compare that effective
            // boundary, not the intentionally removed unused time component.
            for hour in [0, 13, 23] {
                let configured = calendar.date(bySettingHour: hour, minute: 30, second: 0, of: day)!
                let oldRawRequest = calendar.date(byAdding: .year, value: -1, to: configured)!
                let oldFetchBoundary = calendar.startOfDay(for: oldRawRequest)
                XCTAssertEqual(twDateTime.requestStart(for: configured), oldFetchBoundary,
                               "history day \(index), hour \(hour)")
                let window = CalculationWindow(configuredStart: configured,
                    prices: [(date: oldFetchBoundary, close: 100), (date: configured, close: 100)])
                let oldSimulationStart = max(calendar.startOfDay(for: configured),
                    calendar.date(byAdding: .year, value: 1, to: oldFetchBoundary)!)
                XCTAssertEqual(window.requestStart, oldFetchBoundary)
                XCTAssertEqual(window.simulationStart, oldSimulationStart)
                XCTAssertEqual(window.configuredStart, configured)
            }
        }
    }

    func testAllSeasonalBoundariesMatchOriginalPaddedTextAcrossFormalHistory() {
        let formatter = DateFormatter()
        formatter.calendar = referenceCalendar
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.timeZone = referenceCalendar.timeZone
        formatter.dateFormat = "MMdd"
        // Includes both Grade branches and the retained DEBUG early-start
        // variants, plus every overlap/late boundary in H-C01 through H-C04.
        let boundaries = ["0216", "0221", "0226", "0301", "0305", "0306", "0331",
                          "0726", "0801", "0810", "0811", "0831"]
        let intervals = [("0726", "0810"), ("0801", "0810"),
                         ("0216", "0305"), ("0221", "0305"), ("0226", "0305"),
                         ("0801", "0831"), ("0301", "0331")]
        for date in historyDays {
            let old = formatter.string(from: date)
            let current = twDateTime.monthDay(date)
            XCTAssertEqual(current, Int(old))
            for boundary in boundaries {
                XCTAssertEqual(current >= Int(boundary)!, old >= boundary)
                XCTAssertEqual(current <= Int(boundary)!, old <= boundary)
            }
            for (lower, upper) in intervals {
                XCTAssertEqual((Int(lower)!...Int(upper)!).contains(current), old >= lower && old <= upper)
            }
        }
    }
}
