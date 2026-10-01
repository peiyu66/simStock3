import XCTest
@testable import simStock3

final class SellDelayF03Tests: XCTestCase {
    func testStrictBoundariesAndFiniteInputs() {
        func hit(_ ma: Double = 1.19, _ phase: Int = 2, _ high: Double = 99,
                 _ maximum: Double = 100, _ lowZ: Double = 0, _ mature: Bool = true) -> Bool {
            SellDelayF03Rule.matches(ma20Max9: ma, marketPhase: phase, stockHigh: high,
                                    stockMax9: maximum, lowZ125: lowZ, mature: mature)
        }
        XCTAssertTrue(hit())
        XCTAssertTrue(hit(1.2.nextDown, 3, 100, 100, 0.0.nextDown))
        XCTAssertFalse(hit(1.2))
        XCTAssertFalse(hit(1.2.nextUp))
        XCTAssertFalse(hit(1, 2, 100, 100, 0))
        XCTAssertFalse(hit(1, 2, 100, 100, 0.0.nextUp))
        XCTAssertFalse(hit(1, 2, 99, 100, -1, false))
        for phase in [0,1,4,5,6,7,8] { XCTAssertFalse(hit(1, phase)) }
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertFalse(hit(invalid))
            XCTAssertFalse(hit(1,2,invalid))
            XCTAssertFalse(hit(1,2,99,invalid))
            XCTAssertFalse(hit(1,2,99,100,invalid))
        }
    }
}
