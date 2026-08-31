import SwiftUI

#if DEBUG
struct InternalBacktestReportRunnerView: View {
    @State private var status = "準備第一份正式版回測…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 正式版回測").font(.title2)
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
        do {
            let result = try InternalBacktestReport.run { status = $0 }
            status = "完成：\(result.baseline.periodStarts.count) 個期間，H+L \(result.baseline.combinedScore.map { String(format: "%.2f", $0) } ?? "—")"
            isFinished = true
        } catch {
            status = "回測失敗：\(error.localizedDescription)"
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
