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
            .alert(item: $ui.simulationMigrationAlert) { alert in
                switch alert.kind {
                case .warning:
                    return Alert(
                        title: Text("新版規則需要重算"),
                        message: Text(alert.message),
                        dismissButton: .default(Text("開始重算")) {
                            ui.confirmRequiredSimulationMigration()
                        }
                    )
                case .result:
                    return Alert(
                        title: Text("資料規則更新結果"),
                        message: Text(alert.message),
                        dismissButton: .default(Text("知道了"))
                    )
                }
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
            if ProcessInfo.processInfo.arguments.contains("--prepare-internal-backtest") {
                InternalBacktestRunnerView()
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
