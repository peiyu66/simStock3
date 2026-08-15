import SwiftUI
import SwiftData

#if DEBUG
struct InternalBacktestBrowserView: View {
    private let container: ModelContainer?
    private let openingError: String?

    init() {
        do {
            let sample = InternalBacktestDataset.Sample.from()
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let storeURL = documents
                .appendingPathComponent(
                    "InternalBacktest/\(sample.browseDirectoryName)",
                    isDirectory: true
                )
                .appendingPathComponent("browse.store")
            guard FileManager.default.fileExists(atPath: storeURL.path) else {
                throw CocoaError(.fileNoSuchFile)
            }

            let schema = Schema([Stock.self, Trade.self])
            let configuration = ModelConfiguration(
                "InternalBacktestBrowse",
                schema: schema,
                url: storeURL,
                // This is already an expendable copy. SwiftData needs a
                // writable SQLite connection to open stores produced after a
                // full simulation recalculation; UI and service guards still
                // prevent every user-initiated update in snapshot mode.
                allowsSave: true,
                cloudKitDatabase: .none
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
            openingError = nil
        } catch {
            container = nil
            openingError = error.localizedDescription
        }
    }

    var body: some View {
        if let container {
            SimStockRootView(
                modelContainer: container,
                isReadOnlySnapshot: true
            )
            .modelContainer(container)
        } else {
            ContentUnavailableView(
                "無法開啟回測快照",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(openingError ?? "找不到瀏覽副本。")
            )
        }
    }
}
#endif
