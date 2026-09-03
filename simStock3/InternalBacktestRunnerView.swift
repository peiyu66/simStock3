import SwiftUI

#if DEBUG
struct InternalDocumentationScreenshotSeedRunnerView: View {
    @State private var status = "準備建立文件截圖資料庫…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 文件截圖資料")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { prepare() }
    }

    @MainActor
    private func prepare() {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let source = documents.appendingPathComponent(
                "InternalBacktest/central-pool-2016-07-22-working-v1/pool.store"
            )
            let destination = documents.appendingPathComponent(
                "DocumentationScreenshotSeed/default.store"
            )
            let count = try InternalBacktestDataset.prepareDocumentationScreenshotStore(
                sourceStoreURL: source,
                destinationStoreURL: destination
            )
            status = "完成：\(count) 檔行情與 T2 已建立，等待 App 重播 S21"
            print("DOCUMENTATION_SCREENSHOT_SEED_COMPLETE count=\(count) path=\(destination.path)")
            isFinished = true
        } catch {
            status = "建立失敗：\(error.localizedDescription)"
            print("DOCUMENTATION_SCREENSHOT_SEED_FAILED \(String(reflecting: error))")
            isFinished = true
        }
    }
}

struct InternalTWSEDiagnosticRunnerView: View {
    @State private var status = "診斷台泥當月 TWSE 下載…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 TWSE 診斷")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { await diagnose() }
    }

    @MainActor
    private func diagnose() async {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let result = try await InternalBacktestDataset.diagnoseCurrentTWSE1101(rootURL: root)
            status = result.technicalSucceeded
                ? "台泥 \(result.month) TWSE 下載成功"
                : "台泥 \(result.month) TWSE 下載失敗"
            print(
                "TWSE_DIAGNOSTIC_COMPLETE stock=\(result.stockID) month=\(result.month) "
                + "technical=\(result.technicalSucceeded) status=\(result.httpStatus.map(String.init) ?? "nil") "
                + "mime=\(result.mimeType ?? "nil") bytes=\(result.byteCount) "
                + "error=\(result.transportError ?? "nil") prefix=\(result.responsePrefix)"
            )
            isFinished = true
        } catch {
            status = "診斷失敗：\(error.localizedDescription)"
            print("TWSE_DIAGNOSTIC_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }
}

struct InternalABPoolBackfillRunnerView: View {
    @State private var status = "準備補齊 A／B 九年資料…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 A／B 九年資料池")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { await backfill() }
    }

    @MainActor
    private func backfill() async {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let result = try await InternalBacktestDataset.backfillABPool(rootURL: root) {
                status = $0
                print("AB_POOL_BACKFILL \($0)")
            }
            if result.completed {
                status = "完成：20 檔九年資料與 T2 已建立"
                print("AB_POOL_BACKFILL_COMPLETE \(result.manifestURL?.path ?? "")")
            } else {
                status = "暫停：仍有 \(result.failedRequests.count) 個月份待補"
                print("AB_POOL_BACKFILL_INCOMPLETE \(result.failedRequests.joined(separator: ","))")
            }
            isFinished = true
        } catch {
            status = "補齊失敗：\(error.localizedDescription)"
            print("AB_POOL_BACKFILL_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }
}

struct InternalABPoolMigrationRunnerView: View {
    @State private var status = "準備建立 A／B 集中資料池…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 A／B 集中資料池")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { migrate() }
    }

    @MainActor
    private func migrate() {
        do {
            let fileManager = FileManager.default
            let documents = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let sources = try [
                poolSource(for: .a, root: root),
                poolSource(for: .b, root: root)
            ]
            let destination = root.appendingPathComponent(
                InternalBacktestDataset.abPoolDirectoryName,
                isDirectory: true
            )
            let historyStart = InternalBacktestDataset.abPoolHistoryStart
            let simulationStart = InternalBacktestDataset.abPoolSimulationStart
            let through = InternalBacktestDataset.snapshotThrough
            let technicalRuleVersion = Technical.technicalRuleVersion
            let result = try InternalBacktestDataset.migrateABPool(
                in: destination,
                sources: sources,
                historyStart: historyStart,
                simulationStart: simulationStart,
                through: through,
                technicalRuleVersion: technicalRuleVersion
            )
            status = "完成：\(result.manifest.stocks.count) 檔已搬入，等待補齊九年資料"
            print("AB_POOL_MIGRATION_COMPLETE \(result.manifestURL.path)")
            isFinished = true
        } catch {
            status = "搬移失敗：\(error.localizedDescription)"
            print("AB_POOL_MIGRATION_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }

    private func poolSource(
        for sample: InternalBacktestDataset.Sample,
        root: URL
    ) throws -> InternalBacktestDataset.PoolSource {
        let fileManager = FileManager.default
        let baselineURL = root
            .appendingPathComponent(sample.baselineDirectoryName, isDirectory: true)
            .appendingPathComponent("baseline.store")
        if fileManager.fileExists(atPath: baselineURL.path) {
            return .init(sample: sample, storeURL: baselineURL, members: sample.members)
        }
        let browseURL = root
            .appendingPathComponent(sample.browseDirectoryName, isDirectory: true)
            .appendingPathComponent("browse.store")
        if fileManager.fileExists(atPath: browseURL.path) {
            return .init(sample: sample, storeURL: browseURL, members: sample.members)
        }
        throw InternalBacktestDataset.DatasetError.missingPoolSource(baselineURL.path)
    }
}

struct InternalABNineYearShardRunnerView: View {
    @State private var status = "準備建立 A／B／C／D 九年樣本分片…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 A／B／C／D 九年樣本")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { createShards() }
    }

    @MainActor
    private func createShards() {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let results = try InternalBacktestDataset.createABNineYearShards(rootURL: root)
            status = "完成：A、B、C、D 各 10 檔九年 T2 分片已建立"
            for result in results {
                print("AB_NINE_YEAR_SHARD_COMPLETE \(result.manifestURL.path)")
            }
            isFinished = true
        } catch {
            let detail = String(reflecting: error)
            status = "分片失敗：\(detail)"
            print("AB_NINE_YEAR_SHARD_FAILED \(detail)")
            isFinished = true
        }
    }
}

struct InternalSampleENineYearShardRunnerView: View {
    @State private var status = "準備建立 Sample E 九年固定輸入分片…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 Sample E 弱勢壓力樣本")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { createShard() }
    }

    @MainActor
    private func createShard() {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let result = try InternalBacktestDataset.createSampleENineYearShard(rootURL: root)
            status = "完成：Sample E 10 檔九年 T2 固定輸入分片已建立"
            print("SAMPLE_E_NINE_YEAR_SHARD_COMPLETE \(result.manifestURL.path)")
            isFinished = true
        } catch {
            let detail = String(reflecting: error)
            status = "Sample E 分片失敗：\(detail)"
            print("SAMPLE_E_NINE_YEAR_SHARD_FAILED \(detail)")
            isFinished = true
        }
    }
}

struct InternalFortyStockPoolPreparationRunnerView: View {
    @State private var status = "準備建立 40 檔工作資料池…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 40 檔資料池")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { prepare() }
    }

    @MainActor
    private func prepare() {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let result = try InternalBacktestDataset.prepareFortyStockPool(rootURL: root)
            status = "完成：既有 20 檔保留，新增 20 檔等待分批下載"
            print("FORTY_STOCK_POOL_PREPARED \(result.manifestURL.path)")
            isFinished = true
        } catch {
            status = "建立失敗：\(error.localizedDescription)"
            print("FORTY_STOCK_POOL_PREPARE_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }
}

struct InternalFortyStockPoolBackfillRunnerView: View {
    @State private var status = "準備下載新增候選的缺少月份…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 40 檔資料池下載")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { await backfill() }
    }

    @MainActor
    private func backfill() async {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let result = try await InternalBacktestDataset.backfillFortyStockPoolBatch(
                rootURL: root
            ) {
                status = $0
                print("FORTY_STOCK_POOL_BACKFILL \($0)")
            }
            status = result.completed
                ? "新增 20 檔行情下載完成，等待 T2"
                : "本批完成：尚缺 \(result.pendingMonthCount) 個月份"
            print(
                "FORTY_STOCK_POOL_BACKFILL_BATCH_COMPLETE "
                + "attempted=\(result.attemptedRequests) pending=\(result.pendingMonthCount)"
            )
            isFinished = true
        } catch {
            status = "下載失敗：\(error.localizedDescription)"
            print("FORTY_STOCK_POOL_BACKFILL_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }
}

struct InternalCentralStockPoolExpansionRunnerView: View {
    @State private var status = "準備擴充集中資料池…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 集中資料池擴充")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { expand() }
    }

    @MainActor
    private func expand() {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let result = try InternalBacktestDataset.expandCentralStockPool(rootURL: root)
            status = "完成：集中資料池共 \(result.manifest.stocks.count) 檔"
            print("CENTRAL_STOCK_POOL_EXPANDED count=\(result.manifest.stocks.count)")
            isFinished = true
        } catch {
            status = "擴充失敗：\(error.localizedDescription)"
            print("CENTRAL_STOCK_POOL_EXPANSION_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }
}

struct InternalFortyStockPoolT2RunnerView: View {
    @State private var status = "準備計算 40 檔完整 T2…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 40 檔資料池 T2")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { runT2() }
    }

    @MainActor
    private func runT2() {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let manifest = try InternalBacktestDataset.runFortyStockPoolT2(rootURL: root) {
                status = $0
                print("FORTY_STOCK_POOL_T2 \($0)")
            }
            status = "完成：\(manifest.completedStockCount) 檔 T2 已建立，等待 S20"
            print("FORTY_STOCK_POOL_T2_COMPLETE count=\(manifest.completedStockCount)")
            isFinished = true
        } catch {
            status = "T2 失敗：\(error.localizedDescription)"
            print("FORTY_STOCK_POOL_T2_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }
}

struct InternalFortyStockPoolS20RunnerView: View {
    @State private var status = "準備計算 40 檔完整 S20…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 40 檔資料池 S20")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { runS20() }
    }

    @MainActor
    private func runS20() {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let manifest = try InternalBacktestDataset.runFortyStockPoolS20(rootURL: root) {
                status = $0
                print("FORTY_STOCK_POOL_S20 \($0)")
            }
            status = "完成：\(manifest.completedStockCount) 檔 S20 已建立"
            print("FORTY_STOCK_POOL_S20_COMPLETE count=\(manifest.completedStockCount)")
            isFinished = true
        } catch {
            status = "S20 失敗：\(error.localizedDescription)"
            print("FORTY_STOCK_POOL_S20_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }
}

struct InternalCurrentCentralStockPoolMigrationRunnerView: View {
    @State private var status = "準備建立目前版本的 50 檔集中資料池…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 集中資料池 \(Technical.dataRuleVersion)")
                .font(.title2)
            Text(status)
                .multilineTextAlignment(.center)
                .font(.body.monospacedDigit())
        }
        .padding(32)
        .task { migrate() }
    }

    @MainActor
    private func migrate() {
        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let root = documents.appendingPathComponent("InternalBacktest", isDirectory: true)
            let manifest = try InternalBacktestDataset.migrateFortyStockPoolToCurrent(
                rootURL: root
            ) {
                status = $0
                print("CURRENT_CENTRAL_POOL \($0)")
            }
            status = "完成：\(manifest.completedStockCount) 檔已套用 \(Technical.dataRuleVersion)"
            print(
                "CURRENT_CENTRAL_POOL_COMPLETE count=\(manifest.completedStockCount) "
                    + "version=\(Technical.dataRuleVersion)"
            )
            isFinished = true
        } catch {
            status = "集中資料池遷移失敗：\(error.localizedDescription)"
            print("CURRENT_CENTRAL_POOL_FAILED \(error.localizedDescription)")
            isFinished = true
        }
    }
}

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
