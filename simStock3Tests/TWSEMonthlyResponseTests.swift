import XCTest
@testable import simStock3

final class TWSEMonthlyResponseTests: XCTestCase {
    private func date(_ value: String) -> Date { twDateTime.dateFromString(value)! }
    private let priced = ["112/01/03", "1,000", "100,000", "100", "101", "99", "100", "0", "1"]
    private let absent = ["112/01/04", "139", "17,570", "--", "--", "--", "--", " 0.00", "8"]

    func testZeroAndOddLotStatsAreEvidenceWithoutSyntheticPrice() throws {
        var zero = absent; zero[0] = "112/01/05"; zero[1] = "0"; zero[2] = "0"; zero[8] = "0"
        let result = try TWSEMonthlyResponse(rows: [zero, absent, priced], month: date("2023/01/01"))
        XCTAssertEqual(result.prices.count, 1)
        XCTAssertEqual(result.prices[0].volume, 1)
        XCTAssertEqual(result.noPriceDays.map(\.shares), [139, 0])
        XCTAssertEqual(result.noPriceDays.map(\.amount), [17570, 0])
        XCTAssertEqual(result.noPriceDays.map(\.transactions), [8, 0])
        XCTAssertEqual(result.lastDate, date("2023/01/05"))
        let onlyAbsent = try TWSEMonthlyResponse(rows: [absent], month: date("2023/01/01"))
        XCTAssertTrue(onlyAbsent.prices.isEmpty)
        XCTAssertEqual(onlyAbsent.noPriceDays.count, 1)
    }

    func testPartialMissingAndUnrecognizedMissingTokensAreRejected() {
        for index in 3...6 {
            var row = priced; row[index] = "--"
            XCTAssertThrowsError(try TWSEMonthlyResponse(rows: [row], month: date("2023/01/01")))
            for token in ["", "-", "null", "NaN", "inf", "0", "-2", "1,,000", "12--3"] {
                row = absent; row[index] = token
                XCTAssertThrowsError(try TWSEMonthlyResponse(rows: [row], month: date("2023/01/01")), "\(index):\(token)")
            }
        }
    }

    func testBadStatsDatesDuplicateOrMixedBadRowsCannotCertifyMonth() {
        for index in [1, 2, 8] {
            for token in ["--", "-1", "nan", "inf", "1.5", "1,,000", "9223372036854775808"] {
                var row = absent; row[index] = token
                XCTAssertThrowsError(try TWSEMonthlyResponse(rows: [priced, row], month: date("2023/01/01")))
            }
        }
        for value in ["112/02/01", "112/01/32", "112/00/03", "9223372036854775807/01/03", "112/4294967297/03", "112/01/4294967297", "bad", "112//04"] {
            var row = absent; row[0] = value
            XCTAssertThrowsError(try TWSEMonthlyResponse(rows: [row], month: date("2023/01/01")))
        }
        XCTAssertThrowsError(try TWSEMonthlyResponse(rows: [], month: date("2023/01/01")))
        XCTAssertThrowsError(try TWSEMonthlyResponse(rows: [absent, absent], month: date("2023/01/01")))
        XCTAssertThrowsError(try TWSEMonthlyResponse(rows: [priced, Array(absent.prefix(8))], month: date("2023/01/01")))
        var inverted = priced; inverted[4] = "98"
        XCTAssertThrowsError(try TWSEMonthlyResponse(rows: [inverted], month: date("2023/01/01")))
    }

    func testFiveOfficialResponsesKeep99PricesAndFiveNoPriceRows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/TWSEAbsentOHLC")
        var priceCount = 0; var absentCount = 0
        for name in ["2201-202003", "2317-202507", "2449-202404", "8467-202606", "8467-202302"] {
            let data = try Data(contentsOf: root.appendingPathComponent(name + ".json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let month = String(name.suffix(6)); let start = date("\(month.prefix(4))/\(month.suffix(2))/01")
            let result = try TWSEMonthlyResponse(rows: try XCTUnwrap(json["data"] as? [[String]]), month: start)
            XCTAssertEqual(result.noPriceDays.count, 1)
            priceCount += result.prices.count; absentCount += result.noPriceDays.count
            if name == "8467-202606" {
                XCTAssertEqual(result.noPriceDays[0].shares, 139)
                XCTAssertEqual(result.noPriceDays[0].amount, 17570)
                XCTAssertEqual(result.noPriceDays[0].transactions, 8)
            }
        }
        XCTAssertEqual(priceCount, 99)
        XCTAssertEqual(absentCount, 5)
    }

    func testLegacyCoverageDecodesAndNoPriceEvidenceRoundTripsAndDeletes() throws {
        var coverage = try JSONDecoder().decode(TWSEHistoryCoverage.self, from: Data(#"{"months":{}}"#.utf8))
        XCTAssertNil(coverage.noPriceDays)
        let result = try TWSEMonthlyResponse(rows: [absent], month: date("2023/01/01"))
        coverage.confirm(month: date("2023/01/01"), through: date("2023/01/31"), noPriceDays: result.noPriceDays)
        XCTAssertEqual(try JSONDecoder().decode(TWSEHistoryCoverage.self, from: JSONEncoder().encode(coverage)), coverage)
        coverage.confirm(month: date("2023/01/01"), through: date("2023/01/31"), noPriceDays: [])
        XCTAssertNil(coverage.noPriceDays?["202301"])
    }
}
