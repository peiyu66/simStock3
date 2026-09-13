//
//  simStock3App.swift
//  simStock3
//
//  Created by peiyu on 2025/12/14.
//

import SwiftUI
import SwiftData

struct SimStockRootView: View {
    @StateObject private var ui: uiObject
    private let modelContainer: ModelContainer
    private var previewsTWSEBatch = false

    init(modelContainer: ModelContainer, isReadOnlySnapshot: Bool = false, previewsTWSEBatch: Bool = false) {
        self.modelContainer = modelContainer
        self.previewsTWSEBatch = previewsTWSEBatch
        _ui = StateObject(
            wrappedValue: uiObject(
                modelContext: modelContainer.mainContext,
                isReadOnlySnapshot: isReadOnlySnapshot
            )
        )
    }

    var body: some View {
        viewList()
            .environmentObject(ui)
            .modelContainer(modelContainer)
            .task {
                // This local version check must run even when SwiftUI reports
                // an initial inactive scene and never emits the expected
                // transition to this view.
#if DEBUG
                if previewsTWSEBatch {
                    // In-memory UI fixture: uses the same alert and continuation
                    // as real downloads, without network or normal-store writes.
                    ui.isUpdatingPrices = true
                    var remaining = 13
                    while remaining > 0 {
                        let progress = TWSEBatchProgress(stockHistoryMonths: remaining,
                                                         stockRecentMonths: 0, marketMonths: 0)
                        guard let months = await ui.requestTWSEBatchContinuation(progress, stocks: []) else {
                            ui.priceUpdateMessage = "已取消接續，已下載資料保留"
                            ui.isUpdatingPrices = false
                            return
                        }
                        remaining -= months
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                    ui.priceUpdateMessage = "歷史資料已全部補齊"
                    ui.isUpdatingPrices = false
                    return
                }
#endif
                ui.startRequiredDataRuleMigrationIfNeeded()
            }
    }
}

// Ensure there is no other @main or @UIApplicationMain in the project (e.g., AppDelegate) to avoid multiple entry points.
@main
struct simStock3App: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Stock.self, Trade.self, MarketDay.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-twse-download-continuation") {
                SimStockRootView(
                    modelContainer: try! ModelContainer(for: Stock.self, Trade.self, MarketDay.self,
                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)),
                    isReadOnlySnapshot: true, previewsTWSEBatch: true
                )
            } else if ProcessInfo.processInfo.arguments.contains("--prepare-documentation-screenshot-store") {
                InternalDocumentationScreenshotSeedRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--diagnose-internal-twse-1101") {
                InternalTWSEDiagnosticRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--backfill-internal-ab-pool") {
                InternalABPoolBackfillRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--migrate-internal-ab-pool") {
                InternalABPoolMigrationRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--prepare-internal-ab-nine-year-samples") {
                InternalABNineYearShardRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--prepare-internal-sample-e-nine-year") {
                InternalSampleENineYearShardRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--prepare-internal-40-stock-pool") {
                InternalFortyStockPoolPreparationRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--backfill-internal-40-stock-pool") {
                InternalFortyStockPoolBackfillRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--expand-internal-central-stock-pool") {
                InternalCentralStockPoolExpansionRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--run-internal-40-stock-pool-t2") {
                InternalFortyStockPoolT2RunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--run-internal-40-stock-pool-s20") {
                InternalFortyStockPoolS20RunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--migrate-internal-central-pool-current") {
                InternalCurrentCentralStockPoolMigrationRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--qualify-internal-sample-c-evaluation") {
                InternalSampleCQualificationRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--prepare-internal-sample-c-evaluation") {
                InternalSampleCEvaluationRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--prepare-internal-backtest") {
                InternalBacktestRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--profile-internal-backtest-decision-base") {
                InternalBacktestDecisionBaseProfilerRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--analyze-internal-backtest-decisions") {
                InternalBacktestDecisionAnalysisRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--run-internal-backtest-report") {
                InternalBacktestReportRunnerView()
            } else if ProcessInfo.processInfo.arguments.contains("--browse-internal-backtest") {
                InternalBacktestBrowserView()
            } else {
                SimStockRootView(modelContainer: sharedModelContainer)
            }
#else
            SimStockRootView(modelContainer: sharedModelContainer)
#endif
        }
    }
}
