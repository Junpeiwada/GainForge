import SwiftUI

/// 画面下部（ステータスバーの直上）のアクションバー。
/// - 左端: クリア
/// - 右端: すべて変換 / 中止
/// ツールバーから実行ボタンを分離し、常に画面下端の一定位置で押せるようにする。
struct FooterBarView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        HStack(spacing: 16) {
            // クリア（左端アンカー）
            Button("クリア", action: model.clear)
                .disabled(!model.canClear)

            Spacer()

            // 変換 / 中止（右端アンカー）
            // 選択があれば「選択を変換 (件数)」、なければ「すべて変換」を表示し、対象を常に可視化する。
            Button(action: model.convertOrCancel) {
                Text(convertButtonTitle)
                    .frame(minWidth: 56)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canConvert)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 変換ボタンのラベル。変換中は「中止」、選択された再変換対象があれば件数つきで表示する。
    private var convertButtonTitle: String {
        if model.isConverting { return "中止" }
        if model.hasConvertibleSelection { return "選択を変換 (\(model.conversionTargetCount))" }
        return "すべて変換"
    }
}
