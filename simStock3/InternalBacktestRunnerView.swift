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
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let directory = documents.appendingPathComponent(
                "InternalBacktest/2019-01-02-baseline",
                isDirectory: true
            )
            let result = try await InternalBacktestDataset.prepare(
                in: directory,
                reset: false
            ) { message in
                status = message
            }
            status = result.manifest.failedRequests.isEmpty
                ? "十股下載與重算完成"
                : "本次完成，仍有 \(result.manifest.failedRequests.count) 個月份待補"
            isFinished = true
        } catch {
            status = "執行失敗：\(error.localizedDescription)"
            isFinished = true
        }
    }
}
#endif
