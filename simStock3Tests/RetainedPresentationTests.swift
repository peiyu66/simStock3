import SwiftUI
import UIKit
import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class RetainedPresentationTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, uiObject, [Stock], [Trade]) {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let start = twDateTime.dateFromString("2025/01/01")!
        var stocks: [Stock] = []
        var rows: [Trade] = []
        for id in ["A", "B"] {
            let stock = Stock(sId: id, sName: id, group: "測試", dateFirst: start,
                              dateStart: twDateTime.addYears(1, to: start), simMoneyBase: 100)
            stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
            stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
            container.mainContext.insert(stock)
            for date in [start, twDateTime.addYears(1, to: start)] {
                let row = Trade(stock: stock, dateTime: date)
                row.priceClose = 100; row.priceHigh = 101; row.priceLow = 99
                row.simQtyBuy = 3; row.simQtyInventory = 3; row.simRule = "L"
                row.simUpdated = true; row.tUpdated = true
                container.mainContext.insert(row)
                rows.append(row)
            }
            stock.p10Action = "買"; stock.p10L = "99.00買3"; stock.p10Date = rows.last?.date
            stocks.append(stock)
        }
        try container.mainContext.save()
        let ui = uiObject(modelContext: container.mainContext)
        NotificationCenter.default.removeObserver(ui)
        return (container, ui, stocks, rows)
    }

    func testKeepsPriceActionAndSuggestionsUntilSavedSuccessfulReplacement() async throws {
        let (container, ui, stocks, rows) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let stock = stocks[0], row = rows[1]
        ui.retainPriceUpdatePresentation(generation: 1)
        row.priceClose = 90; row.simQtyBuy = 0; row.simRule = ""
        stock.p10Reset(); stock.simulationDirtyFrom = row.date
        let displayed = try XCTUnwrap(ui.latestVisibleTrade(for: stock))
        XCTAssertEqual(displayed.priceClose, 100)
        XCTAssertEqual(displayed.simQtyBuy, 3)
        XCTAssertEqual(displayed.stock.p10L, "99.00買3")
        XCTAssertFalse(displayed.simulationResultPending)
        XCTAssertTrue(ui.hasPendingResults(for: stock))
        XCTAssertFalse(ui.hasPendingDisplayedResults(for: stock))
        XCTAssertFalse(ui.canEditTrade(displayed))
        XCTAssertNil(displayed.modelContext)
        XCTAssertEqual(ui.visibleTrades(rows, for: stock).count, 2)
        stock.simulationDirtyFrom = nil
        ui.publishPriceUpdatePresentation(generation: 1, interrupted: false, failedStockIDs: [])
        XCTAssertTrue(ui.hasRetainedPresentation(for: stock), "Unsaved result cannot publish")
        try container.mainContext.save()
        ui.publishPriceUpdatePresentation(generation: 1, interrupted: false, failedStockIDs: [])
        XCTAssertFalse(ui.hasRetainedPresentation(for: stock))
        XCTAssertTrue(ui.latestVisibleTrade(for: stock) === row)
        XCTAssertEqual(ui.latestVisibleTrade(for: stock)?.simQtyBuy, 0,
                       "A successful no-trade result must remove the old buy marker")
        XCTAssertEqual(stock.p10L, "")
    }

    func testFailureCancellationRepeatAndStaleGenerationPreserveOriginal() async throws {
        let (container, ui, stocks, rows) = try fixture()
        defer { withExtendedLifetime(container) {} }
        ui.retainPriceUpdatePresentation(generation: 1)
        rows[1].simQtyBuy = 0
        try container.mainContext.save()
        ui.publishPriceUpdatePresentation(generation: 1, interrupted: true, failedStockIDs: [])
        XCTAssertEqual(ui.latestVisibleTrade(for: stocks[0])?.simQtyBuy, 3)
        ui.retainPriceUpdatePresentation(generation: 2)
        ui.publishPriceUpdatePresentation(generation: 1, interrupted: false, failedStockIDs: [])
        XCTAssertTrue(ui.hasRetainedPresentation(for: stocks[0]))
        ui.publishPriceUpdatePresentation(generation: 2, interrupted: false, failedStockIDs: ["A"])
        XCTAssertTrue(ui.hasRetainedPresentation(for: stocks[0]))
        XCTAssertFalse(ui.hasRetainedPresentation(for: stocks[1]))
        XCTAssertEqual(ui.latestVisibleTrade(for: stocks[0])?.simQtyBuy, 3)
        XCTAssertTrue(ui.latestVisibleTrade(for: stocks[1]) === rows[3], "Stock switching must remain isolated")
    }

    func testAlreadyPendingStockIsNotPromotedAndSnapshotCannotMutateLiveState() async throws {
        let (container, ui, stocks, rows) = try fixture()
        defer { withExtendedLifetime(container) {} }
        stocks[1].simulationDirtyFrom = rows[3].date
        ui.retainPriceUpdatePresentation(generation: 1)
        XCTAssertFalse(ui.hasRetainedPresentation(for: stocks[1]))
        let displayed = try XCTUnwrap(ui.latestVisibleTrade(for: stocks[0]))
        displayed.simQtyBuy = 99
        XCTAssertEqual(rows[1].simQtyBuy, 3)
        XCTAssertFalse(ui.canEditTrade(displayed))
        XCTAssertEqual(try Trade.fetch(in: container.mainContext, for: stocks[0]).count, 2)
    }
    func testCaptureIsLazyAndProtectsHistoricalMutationBeforeFirstRender() async throws {
        let (container, ui, stocks, rows) = try fixture()
        defer { withExtendedLifetime(container) {} }
        ui.retainPriceUpdatePresentation(generation: 1)
        XCTAssertEqual(ui.retainedPresentations["A"]?.capturedRowCount, 1)
        XCTAssertEqual(ui.retainedPresentations["B"]?.capturedRowCount, 1)
        // Simulate a row materialized from a store, whose transient initializer
        // tracking flag can be false. Preserve before the first scalar write.
        rows[0].rawInputTrackingReady = false
        rows[0].simQtyBuy = 0
        rows[0].priceClose = 80
        let displayed = ui.visibleTrades([rows[0], rows[1]], for: stocks[0])
        XCTAssertEqual(displayed.last?.simQtyBuy, 3)
        XCTAssertEqual(displayed.last?.priceClose, 100)
        XCTAssertEqual(ui.retainedPresentations["A"]?.capturedRowCount, 2)
        XCTAssertEqual(ui.retainedPresentations["B"]?.capturedRowCount, 1)
        XCTAssertEqual(rows[0].priceClose, 80, "Presentation never rolls back live inputs")
    }

    func testFrozenMarketAndMissingMarketAreNotChangedByNewInputs() async throws {
        let (container, ui, stocks, rows) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let day = MarketDay(dateTime: rows[1].date, indexOpen: 100,
                            indexHigh: 101, indexLow: 99, indexClose: 100)
        container.mainContext.insert(day)
        try container.mainContext.save()
        ui.retainPriceUpdatePresentation(generation: 1)
        day.indexClose = 90
        XCTAssertEqual(ui.presentationMarketDay(for: rows[1])?.indexClose, 100)
        XCTAssertNil(ui.presentationMarketDay(for: rows[0]))
        container.mainContext.insert(MarketDay(dateTime: rows[0].date, indexOpen: 100,
            indexHigh: 101, indexLow: 99, indexClose: 100))
        XCTAssertNil(ui.presentationMarketDay(for: rows[0]))
        XCTAssertTrue(ui.hasRetainedPresentation(for: stocks[0]))
    }

    func testRenderedTradeKeepsSignalsAtCompactAndWideWidths() async throws {
        let (container, ui, stocks, rows) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let stock = stocks[0], row = rows[1]
        row.simRuleBuy = "L"; row.rollRounds = 2; row.rollDays = 30; row.rollAmtRoi = 10
        try container.mainContext.save()
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RetainedVisual")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func render(_ width: Double, name: String) throws -> Data {
            let trade = try XCTUnwrap(ui.latestVisibleTrade(for: stock))
            let content = GeometryReader { g in
                tradeCell(stock: .constant(stock), trade: trade,
                    annualWarning: trade.storedAnnualWarning, technicalSelected: false,
                    hidesSummaryIcons: false, hidesTrendIcons: false,
                    onTechnicalSelect: {}, geometry: g)
            }.background(Color.white)
                .environment(\.horizontalSizeClass, width < 620 ? .compact : .regular)
                .environment(\.dynamicTypeSize, width < 620 ? .xxxLarge : .large)
                .environment(\.legibilityWeight, .bold)
            let renderer = ImageRenderer(content: content.frame(width: width, height: 160)
                .environmentObject(ui).modelContainer(container))
            renderer.scale = 1
            let data = try XCTUnwrap(renderer.uiImage?.pngData())
            try data.write(to: output.appendingPathComponent(name + ".png"))
            return data
        }
        let before = try [350.0, 1000.0].map { try render($0, name: "before-\(Int($0))") }
        ui.retainPriceUpdatePresentation(generation: 1)
        stock.simulationDirtyFrom = row.date
        row.simQtyBuy = 0; row.simRuleBuy = ""; row.simRule = ""; row.priceClose = 80
        stock.p10Reset()
        for (index, width) in [350.0, 1000.0].enumerated() {
            XCTAssertEqual(try render(width, name: "during-\(Int(width))"), before[index],
                           "The complete rendered row must retain colors, bubbles and controls")
        }
    }

}
