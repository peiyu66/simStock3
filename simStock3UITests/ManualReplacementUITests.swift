import XCTest

final class ManualReplacementUITests: XCTestCase {
    @MainActor
    private func launch(fails: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-manual-replacement"] + (fails ? ["--manual-save-failure"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["manualProbe"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func open(_ app: XCUIApplication, investment: Bool) {
        let button = investment
            ? app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "加碼 ")).firstMatch
            : app.buttons["反轉買賣"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(app.alerts["從這一天重新模擬？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format:
            "label CONTAINS %@ AND label CONTAINS %@", "隔離操作測試", "清除後無法復原")).firstMatch.exists)
    }

    @MainActor
    func testReversalCancelThenConfirm() {
        let app = launch()
        open(app, investment: false)
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(app.staticTexts["manualProbe"].label, "attempts=0;saved=false;later=1")
        open(app, investment: false)
        app.alerts.buttons["清除舊操作並重算"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "identifier == %@ AND label == %@", "manualProbe", "attempts=1;saved=true;later=0"))
            .firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testInvestmentCancelThenConfirm() {
        let app = launch()
        open(app, investment: true)
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(app.staticTexts["manualProbe"].label, "attempts=0;saved=false;later=1")
        open(app, investment: true)
        app.alerts.buttons["清除舊操作並重算"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "identifier == %@ AND label == %@", "manualProbe", "attempts=1;saved=true;later=0"))
            .firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testConfirmSaveFailureReportsNoReplay() {
        let app = launch(fails: true)
        open(app, investment: true)
        app.alerts.buttons["清除舊操作並重算"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "identifier == %@ AND label CONTAINS %@", "manualStatus", "保存失敗，未啟動重算"))
            .firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["manualProbe"].label, "attempts=1;saved=false;later=0")
    }
}
