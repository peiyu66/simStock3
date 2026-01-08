//
//  simStock3App.swift
//  simStock3
//
//  Created by peiyu on 2025/12/14.
//

import SwiftUI
import SwiftData

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
            viewList()
        }
        .modelContainer(sharedModelContainer)
    }
}
