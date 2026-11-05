import XCTest

final class ManualReplacementUITests: XCTestCase {
    @MainActor
    private func launch(fails: Bool = false, compact: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-manual-replacement"]
            + (fails ? ["--manual-save-failure"] : [])
            + (compact ? ["--manual-compact"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["manualProbe"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func tap(_ app: XCUIApplication, investment: Bool) {
        let button = app.buttons[investment ? "manual-investment" : "manual-reversal"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertFalse(app.alerts["從這一天重新模擬？"].exists)
    }

    @MainActor
    private func verifyDirectSave(investment: Bool) {
        for compact in [false, true] {
            let app = launch(compact: compact)
            XCTAssertEqual(app.staticTexts["manualProbe"].label, "attempts=0;saved=false;later=1")
            tap(app, investment: investment)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
                "identifier == %@ AND label == %@", "manualProbe", "attempts=1;saved=true;later=0"))
                .firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(app.alerts["從這一天重新模擬？"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testReversalDirectTapInBothLayouts() { verifyDirectSave(investment: false) }

    @MainActor
    func testInvestmentDirectTapInBothLayouts() { verifyDirectSave(investment: true) }

    @MainActor
    func testDirectSaveFailureReportsNoReplay() {
        let app = launch(fails: true)
        tap(app, investment: true)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "identifier == %@ AND label CONTAINS %@", "manualStatus", "保存失敗，未啟動重算"))
            .firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["manualProbe"].label, "attempts=1;saved=false;later=0")
        XCTAssertFalse(app.alerts["從這一天重新模擬？"].exists)
    }
}
