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
            let sample = InternalBacktestDataset.Sample.from()
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

struct InternalSampleCEvaluationRunnerView: View {
    @State private var status = "準備 Sample C 研究池資料…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 Sample C 研究池")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { await prepare() }
    }

    @MainActor
    private func prepare() async {
        do {
            let configuration = try InternalBacktestDataset.evaluationConfiguration()
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let directory = documents.appendingPathComponent(
                "InternalBacktest/SampleCEvaluations/\(configuration.directoryName)",
                isDirectory: true
            )
            let result = try await InternalBacktestDataset.prepareEvaluation(
                in: directory,
                reset: false,
                configuration: configuration,
                through: InternalBacktestDataset.snapshotThrough
            ) { message in
                status = message
                print("SAMPLE_C_EVALUATION \(message)")
            }
            if result.manifest.failedRequests.isEmpty {
                status = "研究池 \(configuration.id) 下載與重算完成"
                print("SAMPLE_C_EVALUATION_COMPLETE \(result.manifestURL.path)")
            } else {
                status = "本次完成，仍有 \(result.manifest.failedRequests.count) 個月份待補"
                print("SAMPLE_C_EVALUATION_INCOMPLETE \(result.manifest.failedRequests.count)")
            }
            isFinished = true
        } catch {
            status = "執行失敗：\(error.localizedDescription)"
            print("SAMPLE_C_EVALUATION_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }
}

struct InternalSampleCQualificationRunnerView: View {
    @State private var status = "準備 Sample C 最近窗口資格分析…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 Sample C 資格分析")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { qualify() }
    }

    @MainActor
    private func qualify() {
        do {
            let configuration = try InternalBacktestDataset.evaluationConfiguration()
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let result = try InternalSampleCQualification.run(
                configuration: configuration,
                documents: documents
            ) { message in
                status = message
                print("SAMPLE_C_QUALIFICATION \(message)")
            }
            status = "完成：\(result.manifest.qualifiedCount)/\(result.manifest.stocks.count) 檔合格"
            print("SAMPLE_C_QUALIFICATION_COMPLETE \(result.manifestURL.path)")
            isFinished = true
        } catch {
            status = "資格分析失敗：\(error.localizedDescription)"
            print("SAMPLE_C_QUALIFICATION_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }
}
#endif
