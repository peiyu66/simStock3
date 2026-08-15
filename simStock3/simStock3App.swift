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

    init(modelContainer: ModelContainer, isReadOnlySnapshot: Bool = false) {
        self.modelContainer = modelContainer
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
                ui.startRequiredDataRuleMigrationIfNeeded()
            }
    }
}

// Ensure there is no other @main or @UIApplicationMain in the project (e.g., AppDelegate) to avoid multiple entry points.
@main
struct simStock3App: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Stock.self,Trade.self
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
            if ProcessInfo.processInfo.arguments.contains("--qualify-internal-sample-c-evaluation") {
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
