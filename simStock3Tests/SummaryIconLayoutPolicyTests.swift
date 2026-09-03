import XCTest
@testable import simStock3

final class SummaryIconLayoutPolicyTests: XCTestCase {
    func testPortraitAndWideSidebarKeepTrendIcons() {
        XCTAssertFalse(
            SummaryIconLayoutPolicy.hidesSidebarTrendIcons(
                usesCompactLandscape: false
            )
        )
    }

    func testCompactLandscapeSidebarHidesOnlyTrendIcons() {
        XCTAssertTrue(
            SummaryIconLayoutPolicy.hidesSidebarTrendIcons(
                usesCompactLandscape: true
            )
        )
    }

    func testTradeIconsRemainWithoutTechnicalSidebar() {
        XCTAssertFalse(
            SummaryIconLayoutPolicy.hidesTradeIcons(
                showsTechnicalSidebar: false,
                usesSpaciousTechnicalSidebar: false
            )
        )
    }

    func testCompactTechnicalSidebarHidesAllTradeIcons() {
        XCTAssertTrue(
            SummaryIconLayoutPolicy.hidesTradeIcons(
                showsTechnicalSidebar: true,
                usesSpaciousTechnicalSidebar: false
            )
        )
        XCTAssertFalse(
            SummaryIconLayoutPolicy.hidesTradeIcons(
                showsTechnicalSidebar: true,
                usesSpaciousTechnicalSidebar: true
            )
        )
    }
}
