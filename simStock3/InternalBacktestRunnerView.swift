import SwiftUI

#if DEBUG
struct InternalBacktestRunnerView: View {
    @State private var status = "準備內部回測資料…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .opacity(isFinished ? 0 : 1)
            Text("simStock3 內部回測")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task {
            await prepare()
        }
    }

    @MainActor
    private func prepare() async {
        do {
            let sample: InternalBacktestDataset.Sample = ProcessInfo.processInfo.arguments.contains("--sample-b")
                ? .b
                : .a
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let directory = documents.appendingPathComponent(
                "InternalBacktest/\(sample.baselineDirectoryName)",
                isDirectory: true
            )
            let result = try await InternalBacktestDataset.prepare(
                in: directory,
                reset: false,
                sample: sample,
                through: InternalBacktestDataset.snapshotThrough
            ) { message in
                status = message
                print("BACKTEST \(message)")
            }
            if result.manifest.failedRequests.isEmpty {
                try publishBrowseSnapshot(
                    from: result.storeURL,
                    in: documents,
                    sample: sample
                )
                status = "Sample \(sample.rawValue) 十股下載、重算與瀏覽快照完成"
                print("BACKTEST_COMPLETE \(result.manifestURL.path)")
            } else {
                status = "本次完成，仍有 \(result.manifest.failedRequests.count) 個月份待補"
                print("BACKTEST_INCOMPLETE \(result.manifest.failedRequests.count)")
            }
            isFinished = true
        } catch {
            status = "執行失敗：\(error.localizedDescription)"
            print("BACKTEST_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }

    private func publishBrowseSnapshot(
        from sourceURL: URL,
        in documentsURL: URL,
        sample: InternalBacktestDataset.Sample
    ) throws {
        let fileManager = FileManager.default
        let directory = documentsURL.appendingPathComponent(
            "InternalBacktest/\(sample.browseDirectoryName)",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationURL = directory.appendingPathComponent("browse.store")
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        for suffix in ["-wal", "-shm"] where fileManager.fileExists(atPath: sourceURL.path + suffix) {
            try fileManager.copyItem(
                atPath: sourceURL.path + suffix,
                toPath: destinationURL.path + suffix
            )
        }
    }
}
#endif
