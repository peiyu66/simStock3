import SwiftUI
import UIKit
import SwiftData
import XCTest
@testable import simStock3

@MainActor
final class IntentPresentationTests: XCTestCase {
    func testUpgradedProvisionalIntentWithoutEffectiveValueIsNotClaimedExecutedOrInvalid() throws {
        let stock = Stock(sId: "LEGACY", sName: "舊資料測試", group: "測試", dateFirst: .distantPast, dateStart: .distantPast)
        let row = Trade(stock: stock, dateTime: Date())
        row.simReversed = "B+"; row.simMarketIsProvisional = true
        XCTAssertNil(row.simProvisionalEffectiveReversal)
        XCTAssertEqual(row.reversalSymbol, "clock")
        XCTAssertEqual(row.reversalExplanation.title, "反轉待確認")
        XCTAssertFalse(row.reversalExplanation.values.contains { $0.contains("未生效") })
        row.simProvisionalEffectiveReversal = ""
        XCTAssertEqual(row.reversalExplanation.title, "反轉待命")
        row.simProvisionalEffectiveReversal = "B+"
        XCTAssertEqual(row.reversalSymbol, "circle.fill")
        row.simReversed = ""
        XCTAssertEqual(row.reversalSymbol, "circle")
    }

    func testPendingIntentRowsAndExplanationsRenderAtNarrowAndWideWidths() async throws {
        let container = try ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let c = container.mainContext
        let now = twDateTime.dateFromString("2026/10/30")!
        let stock = Stock(sId: "TEST", sName: "待命顯示測試", group: "測試",
            dateFirst: twDateTime.dateFromString("2024/01/01")!, dateStart: twDateTime.dateFromString("2025/01/01")!,
            simInvestAuto: 2, simMoneyBase: 180)
        c.insert(stock)
        stock.technicalStateVersion = Int(Technical.technicalRuleVersion.dropFirst())!
        stock.simulationStateVersion = Int(Technical.simulationRuleVersion.dropFirst())!
        let preparation = Trade(stock: stock, dateTime: stock.dateFirst)
        preparation.priceClose = 100; c.insert(preparation)
        let row = Trade(stock: stock, dateTime: now)
        row.priceClose = 102; row.dataSource = "yahoo"; row.tUpdated = true
        row.simReversed = "B+"; row.simMarketIsProvisional = true; row.simProvisionalEffectiveReversal = ""
        row.simInvestByUser = 1; row.simProvisionalEffectiveInvestment = 0
        row.simQtyInventory = 1; row.simDays = 12; row.simUnitCost = 100
        c.insert(row); try c.save()
        let ui = uiObject(modelContext: c)
        XCTAssertTrue(ui.canEditTrade(row))
        XCTAssertEqual(row.reversalSymbol, "clock")
        XCTAssertTrue(row.investmentIsPending)
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("IntentVisual")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func capture<V: View>(_ content: V, width: Double, height: Double, name: String) async throws {
            let host = UIHostingController(rootView: content.environmentObject(ui).modelContainer(container))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent(name + ".png"))
            XCTAssertGreaterThan(image.size.height, 100)
        }
        for width in [350.0, 1000.0] {
            let content = GeometryReader { g in
                tradeCell(stock: .constant(stock), trade: row, annualWarning: row.storedAnnualWarning,
                    technicalSelected: false, hidesSummaryIcons: false, hidesTrendIcons: false,
                    onTechnicalSelect: {}, geometry: g)
            }.background(Color.white)
                .environment(\.horizontalSizeClass, width < 620 ? .compact : .regular)
                .environment(\.dynamicTypeSize, width < 620 ? .xxxLarge : .large)
                .environment(\.legibilityWeight, .bold)
            // Geometry must describe the column, not the enclosing iPad scene.
            let renderer = ImageRenderer(content: content.frame(width: width, height: 160)
                .environmentObject(ui).modelContainer(container))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage)
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("pending-\(Int(width)).png"))
        }
        for (name, explanation) in [("reversal", row.reversalExplanation), ("investment", row.investmentExplanation)] {
            try await capture(IconExplanationView(explanation: explanation)
                .environment(\.dynamicTypeSize, .xxxLarge).environment(\.legibilityWeight, .bold)
                .background(Color.white), width: 400, height: 550, name: name)
        }
        ui.sim.tech.invalidateTimer()
    }
}
