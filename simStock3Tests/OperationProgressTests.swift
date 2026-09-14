import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class OperationProgressTests: XCTestCase {
    private func date(_ value: String) -> Date { twDateTime.dateFromString(value)! }

    private func fixture() throws -> (ModelContainer, simObject, [Stock]) {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var stocks: [Stock] = []
        for id in ["A", "B"] {
            let stock = Stock(sId: id, sName: id, group: "測試",
                dateFirst: date("2023/01/01"), dateStart: date("2024/01/01"))
            context.insert(stock)
            for day in ["2023/01/01", "2024/01/01"] {
                let trade = Trade(stock: stock, dateTime: twDateTime.time1330(date(day)))
                trade.priceClose = 100
                context.insert(trade)
            }
            stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
            stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
            stocks.append(stock)
        }
        for day in ["2023/01/01", "2024/01/01"] {
            context.insert(MarketDay(dateTime: date(day), indexOpen: 100, indexHigh: 101,
                indexLow: 99, indexClose: 100))
        }
        try context.save()
        try MarketDataStore(modelContext: context).rebuildPricePath()
        return (container, simObject(modelContext: context), stocks)
    }

    func testSingleSubjectOmitsCounterForEveryPhaseAndMonthsHaveUnits() async {
        let plan = OperationProgress(subjects: [.stock("A")])
        for phase in ["補齊歷史股價", "正在重算模擬", "查詢 Yahoo", "正在清理歷史資料"] {
            XCTAssertEqual(plan.message(for: .stock("A"), phase), phase)
        }
        XCTAssertEqual(OperationProgress.monthDetail(position: 1, total: 1), "")
        XCTAssertEqual(OperationProgress.monthDetail(position: 1, total: 2), "（本批第 1/2 個月）")
    }

    func testSingleChangedStockExcludesCurrentMarketAndOtherStock() async throws {
        let (container, sim, stocks) = try fixture()
        stocks[1].simulationDirtyFrom = .distantPast
        let plan = sim.officialUpdateProgress(stocks: stocks, allGroupedStocks: stocks,
                                              through: date("2024/01/01"))
        XCTAssertEqual(plan.subjects, [.stock("B")])
        XCTAssertEqual(plan.message(for: .stock("B"), "B 正在重算模擬"), "B 正在重算模擬")
        _ = container // Keep the in-memory store alive for the complete test.
    }

    func testEarlierStartSharesMarketAndStockNumbersThroughReplay() async throws {
        let (container, sim, stocks) = try fixture()
        try StockHistory.changeStart(stocks[0], to: date("2023/12/01"), in: container.mainContext)
        let plan = sim.officialUpdateProgress(stocks: stocks, allGroupedStocks: stocks,
                                              through: date("2024/01/01"))
        XCTAssertEqual(plan.subjects, [.market, .stock("A")])
        XCTAssertEqual(plan.message(for: .market, "大盤 補齊歷史指數"), "1/2 大盤 補齊歷史指數")
        for phase in ["補齊歷史股價", "正在完整重算技術值與模擬", "重算恢復失敗"] {
            XCTAssertEqual(plan.message(for: .stock("A"), "A " + phase), "2/2 A " + phase)
        }
        // Completion doesn't shrink the already-created operation's denominator.
        stocks[0].technicalDirtyFrom = nil
        stocks[0].simulationDirtyFrom = nil
        XCTAssertEqual(plan.message(for: .market, "大盤 正在重算技術數值"), "1/2 大盤 正在重算技術數值")
        XCTAssertEqual(plan.subjects.count, 2)
    }

    func testMarketOnlyAndNoWorkHaveNoStockCounter() async throws {
        let (container, sim, stocks) = try fixture()
        XCTAssertTrue(sim.officialUpdateProgress(stocks: stocks, allGroupedStocks: stocks,
            through: date("2024/01/01")).subjects.isEmpty)
        let market = try MarketDay.fetchAll(in: container.mainContext)
        market[0].technicalStateVersion = 0
        let plan = sim.officialUpdateProgress(stocks: stocks, allGroupedStocks: stocks,
            through: date("2024/01/01"))
        XCTAssertEqual(plan.subjects, [.market])
        XCTAssertEqual(plan.message(for: .market, "大盤 正在重算技術數值"), "大盤 正在重算技術數值")
    }

    func testMultipleStocksKeepTheirPositionsAndDeduplicateSubjects() async throws {
        let (container, sim, stocks) = try fixture()
        for stock in stocks { stock.simulationDirtyFrom = .distantPast }
        let plan = sim.officialUpdateProgress(stocks: stocks, allGroupedStocks: stocks,
            through: date("2024/01/01"))
        XCTAssertEqual(plan.message(for: .stock("A"), "重算"), "1/2 重算")
        XCTAssertEqual(plan.message(for: .stock("B"), "重算"), "2/2 重算")
        XCTAssertEqual(OperationProgress(subjects: [.market, .stock("A"), .stock("A")]).subjects,
                       [.market, .stock("A")])
        _ = container
    }

    func testLocalRecalculationPublishesCurrentSubjectBeforeWork() async throws {
        let (container, sim, stocks) = try fixture()
        // Observe actual notifications produced by the capital/manual replay worker.
        var messages: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("requestRunning"),
            object: nil, queue: nil) { notification in
                MainActor.assumeIsolated {
                    if let message = notification.userInfo?["msg"] as? String { messages.append(message) }
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        await sim.tech.recalculateExistingStocks([stocks[0]], action: .simUpdateAll)
        XCTAssertEqual(messages, ["A A 正在重算模擬"])
        messages.removeAll()
        await sim.tech.recalculateExistingStocks(stocks, action: .tUpdateAll)
        XCTAssertEqual(messages, ["1/2 A A 正在重算技術值與模擬", "2/2 B B 正在重算技術值與模擬"])
        XCTAssertEqual(stocks.map(\.simulationStateVersion), [51, 51])
        _ = container
    }
}
