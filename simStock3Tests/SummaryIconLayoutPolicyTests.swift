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

    func testTradeIconsRemainInPortraitAndTwoColumnLayouts() {
        XCTAssertFalse(
            SummaryIconLayoutPolicy.hidesTradeIcons(
                isSplitDetail: false,
                showsTechnicalSidebar: false,
                usesSpaciousTechnicalSidebar: false
            )
        )
        XCTAssertFalse(
            SummaryIconLayoutPolicy.hidesTradeIcons(
                isSplitDetail: true,
                showsTechnicalSidebar: false,
                usesSpaciousTechnicalSidebar: false
            )
        )
    }

    func testOnlyCompactThreeColumnLayoutHidesAllTradeIcons() {
        XCTAssertTrue(
            SummaryIconLayoutPolicy.hidesTradeIcons(
                isSplitDetail: true,
                showsTechnicalSidebar: true,
                usesSpaciousTechnicalSidebar: false
            )
        )
        XCTAssertFalse(
            SummaryIconLayoutPolicy.hidesTradeIcons(
                isSplitDetail: true,
                showsTechnicalSidebar: true,
                usesSpaciousTechnicalSidebar: true
            )
        )
    }
}
