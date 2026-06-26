import SwiftUI

/// 下部ステータスバー：進捗、件数、合計サイズ・削減率。
struct StatusBarView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            // 進捗
            HStack(spacing: 6) {
                if model.isConverting {
                    ProgressView().controlSize(.small)
                }
                Text("\(model.completedCount)/\(model.totalCount) 完了")
                    .monospacedDigit()
            }

            // エラー / スキップ
            if model.errorCount > 0 || model.skippedCount > 0 {
                Text("エラー \(model.errorCount) / スキップ \(model.skippedCount)")
                    .foregroundStyle(model.errorCount > 0 ? .red : .secondary)
            }

            Spacer()

            // 合計サイズ・削減率
            if model.sizeTotals.input > 0 {
                let totals = model.sizeTotals
                Text("合計 \(SizeFormat.mb(totals.input)) → \(SizeFormat.mb(totals.output)) (\(SizeFormat.reductionLabel(input: totals.input, output: totals.output)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
