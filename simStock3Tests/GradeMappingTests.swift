import XCTest
@testable import simStock3

@MainActor
final class GradeMappingTests: XCTestCase {
    private func makeTrade(grade: Trade.Grade) -> Trade {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stock = Stock(
            sId: "GRADE",
            sName: "Grade 映射測試",
            group: "測試",
            dateFirst: date,
            dateStart: date,
            simInvestAuto: 2,
            simMoneyBase: 100
        )
        let trade = Trade(stock: stock, dateTime: date)

        switch grade {
        case .none:
            break
        case .weak:
            trade.rollRounds = 3
            trade.rollDays = 30
        case .low:
            trade.rollRounds = 3
            trade.rollDays = 30
            trade.rollAmtRoi = -100
        case .damn:
            trade.rollRounds = 3
            trade.rollDays = 30
            trade.rollAmtRoi = -300
        case .fine:
            trade.rollRounds = 3
            trade.rollDays = 30
            trade.rollAmtRoi = 3
        case .high:
            trade.rollRounds = 3
            trade.rollDays = 30
            trade.rollAmtRoi = 4.2
        case .wow:
            trade.rollRounds = 3
            trade.rollDays = 30
            trade.rollAmtRoi = 5
        }

        XCTAssertEqual(trade.grade, grade)
        return trade
    }

    func testDefaultGradeMappingKeepsUnratedIndependent() {
        let expected: [Trade.Grade: Double] = [
            .damn: 10,
            .low: 10,
            .weak: 10,
            .none: 40,
            .fine: 20,
            .high: 30,
            .wow: 30,
        ]

        for (grade, value) in expected {
            XCTAssertEqual(
                makeTrade(grade: grade).byGrade(
                    lower: 10,
                    standard: 20,
                    upper: 30,
                    unrated: 40
                ),
                value,
                "Unexpected mapping for \(grade)"
            )
        }
    }

    func testCustomGradeBoundariesDoNotMoveUnrated() {
        let expected: [Trade.Grade: Double] = [
            .damn: 10,
            .low: 10,
            .weak: 20,
            .none: 40,
            .fine: 20,
            .high: 20,
            .wow: 30,
        ]

        for (grade, value) in expected {
            XCTAssertEqual(
                makeTrade(grade: grade).byGrade(
                    lower: 10,
                    standard: 20,
                    upper: 30,
                    unrated: 40,
                    lowerThrough: .low,
                    upperFrom: .wow
                ),
                value,
                "Unexpected mapping for \(grade)"
            )
        }
    }
}
