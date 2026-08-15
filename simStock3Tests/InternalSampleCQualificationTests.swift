import XCTest
@testable import simStock3

#if DEBUG
final class InternalSampleCQualificationTests: XCTestCase {
    @MainActor
    func testQualifiesSustainedWowDrawdown() {
        let start = twDateTime.dateFromString("2023/07/24")!
        let observations = (0..<45).map { index in
            let close: Double
            if index <= 14 {
                close = 100
            } else if index <= 24 {
                close = 100 - Double(index - 14) * 2.1
            } else {
                close = 79
            }
            return observation(start: start, index: index, close: close, grade: .wow)
        }

        let result = InternalSampleCQualification.evaluate(
            id: "4562",
            name: "穎漢",
            observations: observations,
            moneyLacked: false
        )

        XCTAssertTrue(result.qualified)
        XCTAssertEqual(result.terminalGrade, "wow")
        XCTAssertNotNil(result.qualifyingPeakDate)
        XCTAssertGreaterThanOrEqual(result.qualifyingObservationGap ?? 0, 10)
    }

    @MainActor
    func testRejectsSingleDayJumpAndNonWowFollowThrough() {
        let start = twDateTime.dateFromString("2023/07/24")!
        var observations = (0..<45).map {
            observation(start: start, index: $0, close: $0 < 15 ? 100 : 75, grade: .wow)
        }
        observations[30] = observation(start: start, index: 30, close: 75, grade: .high)

        let result = InternalSampleCQualification.evaluate(
            id: "4562",
            name: "穎漢",
            observations: observations,
            moneyLacked: false
        )

        XCTAssertFalse(result.qualified)
        XCTAssertNil(result.qualifyingPeakDate)
    }

    @MainActor
    func testRejectsNonWowTerminalGrade() {
        let start = twDateTime.dateFromString("2023/07/24")!
        var observations = (0..<45).map { index in
            let close = index <= 14 ? 100 : (index <= 24 ? 79 : 79)
            return observation(start: start, index: index, close: Double(close), grade: .wow)
        }
        observations[44] = observation(start: start, index: 44, close: 79, grade: .fine)

        let result = InternalSampleCQualification.evaluate(
            id: "4562",
            name: "穎漢",
            observations: observations,
            moneyLacked: false
        )

        XCTAssertFalse(result.qualified)
        XCTAssertTrue(result.reasons.contains("期末 Grade 不是 wow"))
    }

    @MainActor
    private func observation(
        start: Date,
        index: Int,
        close: Double,
        grade: Trade.Grade
    ) -> InternalSampleCQualification.Observation {
        InternalSampleCQualification.Observation(
            date: Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: index,
                to: start
            )!,
            close: close,
            grade: grade,
            roi: 30,
            days: 30,
            rounds: 4
        )
    }
}
#endif
