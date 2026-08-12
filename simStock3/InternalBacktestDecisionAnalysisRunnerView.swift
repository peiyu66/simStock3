import SwiftUI

#if DEBUG
struct InternalBacktestDecisionAnalysisRunnerView: View {
    @State private var status = "準備 P4a 決策差異分析…"
    @State private var isFinished = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().opacity(isFinished ? 0 : 1)
            Text("simStock3 P4a 決策分析").font(.title2)
            Text(status).multilineTextAlignment(.center).font(.body.monospacedDigit())
        }
        .padding(32)
        .task { run() }
    }

    @MainActor
    private func run() {
        do {
            let result = try InternalBacktestDecisionAnalyzer.runFromArguments { status = $0 }
            status = "完成：\(result.firstDivergenceCount) 個第一次分歧，\(result.outcomeDifferenceCount) 個結果差異"
            isFinished = true
        } catch {
            status = "分析失敗：\(error.localizedDescription)"
            isFinished = true
        }
    }
}
#endif
