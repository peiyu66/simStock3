import SwiftUI
import Darwin

#if DEBUG
struct InternalBacktestReportRunnerView: View {
    @State private var status = InternalBacktestReport.isUpdateCycleDiagnostic
        ? "準備更新週期候選診斷…" : "準備第一份正式版回測…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text(InternalBacktestReport.isUpdateCycleDiagnostic
                ? "simStock3 更新週期候選診斷（非正式策略）" : "simStock3 正式版回測").font(.title2)
            Text(status).multilineTextAlignment(.center).font(.body.monospacedDigit())
        }
        .padding(32)
        .task { run() }
    }

    @MainActor
    private func run() {
        let failureMarkerURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("InternalBacktest", isDirectory: true)
        .appendingPathComponent(".last-run-failure.txt")
        try? FileManager.default.removeItem(at: failureMarkerURL)
        let runID = InternalBacktestReport.runID
        let safeID = runID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        let progressURL = InternalBacktestReport.isUpdateCycleDiagnostic && safeID
            ? failureMarkerURL.deletingLastPathComponent()
                .appendingPathComponent("Diagnostics", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
                .appendingPathComponent("progress.log") : nil
        func record(_ message: String) {
            guard let progressURL else { return }
            var usage = rusage()
            let hasUsage = getrusage(RUSAGE_SELF, &usage) == 0
            let resource = hasUsage ? " peakRSSBytes=\(usage.ru_maxrss)" : " peakRSSBytes=unavailable"
            let line = "\(ISO8601DateFormatter().string(from: Date()))\(resource) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                try FileManager.default.createDirectory(at: progressURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: progressURL.path) {
                    let handle = try FileHandle(forWritingTo: progressURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: data)
                } else { try data.write(to: progressURL, options: .atomic) }
            } catch { print("DIAGNOSTIC_PROGRESS_SAVE_FAILED \(error)") }
        }
        record("START \(runID)")
        do {
            let result = try InternalBacktestReport.run { status = $0; record($0) }
            status = "完成：\(result.baseline.periodStarts.count) 個期間，H+L \(result.baseline.combinedScore.map { String(format: "%.2f", $0) } ?? "—")"
            record("COMPLETE \(result.baseline.runID)")
            isFinished = true
        } catch {
            status = "回測失敗：\(error.localizedDescription)"
            record(status)
            try? FileManager.default.createDirectory(
                at: failureMarkerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? status.write(to: failureMarkerURL, atomically: true, encoding: .utf8)
            isFinished = true
        }
    }
}
#endif
