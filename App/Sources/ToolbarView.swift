import SwiftUI

/// 上部ツールバー：品質スライダー、出力先、変換 / 中止、クリア。
struct ToolbarView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        HStack(spacing: 16) {
            // 品質スライダー
            HStack(spacing: 8) {
                Text("品質")
                Slider(value: $model.quality, in: 0.0...1.0)
                    .frame(width: 140)
                    .disabled(!model.canEditSettings)
                Text(String(format: "%.2f", model.quality))
                    .monospacedDigit()
                    .frame(width: 38, alignment: .leading)
            }

            Divider().frame(height: 22)

            // 出力先
            HStack(spacing: 8) {
                Text("出力先")
                Picker("", selection: $model.outputMode) {
                    Text("同じフォルダ").tag(OutputMode.sameFolder)
                    Text("指定フォルダ").tag(OutputMode.customFolder)
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(!model.canEditSettings)

                if model.outputMode == .customFolder {
                    Button("選択…", action: chooseFolder)
                        .disabled(!model.canEditSettings)
                    Text(model.customFolder?.lastPathComponent ?? "未選択")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(model.customFolder?.path ?? "未選択")
                        .frame(maxWidth: 120, alignment: .leading)
                }
            }

            Spacer()

            // 変換 / 中止
            // 選択があれば「選択を変換 (件数)」、なければ「変換」を表示し、対象を常に可視化する。
            Button(action: model.convertOrCancel) {
                Text(convertButtonTitle)
                    .frame(minWidth: 56)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canConvert)

            // クリア
            Button("クリア", action: model.clear)
                .disabled(!model.canClear)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 変換ボタンのラベル。変換中は「中止」、選択された待機行があれば対象件数つきで表示する。
    private var convertButtonTitle: String {
        if model.isConverting { return "中止" }
        if model.hasConvertibleSelection { return "選択を変換 (\(model.conversionTargetCount))" }
        return "すべて変換"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        if panel.runModal() == .OK { model.customFolder = panel.url }
    }
}
