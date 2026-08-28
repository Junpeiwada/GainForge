import SwiftUI
import GainForgeCore

/// 上部ツールバー：品質・サイズ・出力先・SDR画像を**フローレイアウト**で並べる。
/// ウィンドウ幅が広ければ 1 段に収め、狭ければ入り切らないセクション（SDR画像）が
/// 次の段へ自動的に折り返す。実行ボタン（変換 / クリア）は画面下部の FooterBarView へ分離。
///
/// **SDR 画像にしか効かない設定はボタン 1 つに畳んである**（`sdrSection`）。変換方法と
/// 「明部の色」はどちらもゲインマップ**無し**の入力にしか作用しないが、以前は品質・サイズ・
/// 出力先と対等に横並びしていたため、その作用範囲が `disabled` と help でしか伝わらなかった。
/// ポップオーバーの中へ入れ子にすることで、**従属関係を構造として示す**（枠で囲う案も試したが、
/// ツールバーが縦に伸びて他セクションと高さが揃わず、見た目が落ち着かなかった）。
struct ToolbarView: View {
    @EnvironmentObject var model: AppViewModel
    @State private var showSDRPopover = false

    var body: some View {
        FlowLayout(hSpacing: 16, vSpacing: 8) {
            qualitySection
            sizeSection
            outputSection
            sdrSection
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - セクション

    /// 品質スライダー。
    private var qualitySection: some View {
        HStack(spacing: 8) {
            Text("品質")
            Slider(value: $model.quality, in: 0.0...1.0)
                .frame(width: 140)
                .disabled(!model.canEditSettings)
            Text(String(format: "%.2f", model.quality))
                .monospacedDigit()
                .frame(width: 38, alignment: .leading)
        }
        .fixedSize()
    }

    /// 出力先（同じ / 指定フォルダ）。
    private var outputSection: some View {
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
                    .frame(width: 120, alignment: .leading)
            }
        }
        .fixedSize()
    }

    /// SDR 画像（ゲインマップ**無し**の入力）にだけ作用する設定を、ボタン 1 つへ畳んだセクション。
    ///
    /// 中身は「変換方法」と「明部の色」の 2 つ。どちらもゲインマップ付き（HDR）入力には一切
    /// 効かず（あちらは常に生転写）、さらに「明部の色」は HDR 補正を選んだときだけ効く従属設定。
    /// **入れ子にすることで従属関係を構造で示す**のがここの役目で、以前は 2 つが品質・サイズ・
    /// 出力先と対等に並んでいたため、明部の色ボタンが灰色である理由が help を読むまで分からなかった。
    ///
    /// 畳んだぶん現在の設定がツールバーから見えなくなるので、**ボタンのラベルに要約を出す**
    /// （`sdrButtonLabel`）。FlowLayout から見ても子は 1 つなので、折り返しで分断されない。
    private var sdrSection: some View {
        Button(sdrButtonLabel) { showSDRPopover = true }
            .disabled(!model.canEditSettings)
            .popover(isPresented: $showSDRPopover, arrowEdge: .bottom) { sdrPopover }
            .fixedSize()
            .help("ゲインマップの無い SDR 画像の変換方法と、HDR 補正で合成する明部の色を設定します。"
                + "いずれもゲインマップ付き画像（生転写）には作用しません。")
    }

    /// ツールバーボタンのラベル。**畳んだ設定の要約**なので、開かなくても現状が読めるようにする。
    /// 明部の色は「効いているときだけ」併記する（`SDRで保存` では無効なので出さない）。
    private var sdrButtonLabel: String {
        let mode: String
        switch model.sdrMode {
        case .sdr:      mode = "SDRで保存"
        case .hdrCurve: mode = "HDR補正（カーブ）"
        case .hdrML:    mode = "HDR補正（ML/LUT）"
        }
        let w = model.highlightWarmth, t = model.highlightTint
        guard model.sdrMode != .sdr, abs(w) > 0.0001 || abs(t) > 0.0001 else {
            return "SDR画像: \(mode)"
        }
        return String(format: "SDR画像: %@ (%+.2f / %+.2f)", mode, w, t)
    }

    /// ポップオーバーの中身：変換方法（ラジオ）と、その下に従属する「明部の色」の 2 軸。
    ///
    /// **明部の色は変換方法の下に置き、`SDRで保存` のときはまとめて無効化する**。並び順と
    /// 無効化がそのまま「HDR 補正を選んだときだけ効く」の説明になっている。
    private var sdrPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SDR画像（ゲインマップ無しの入力のみ）").font(.headline)

            Picker("", selection: $model.sdrMode) {
                Text("SDRで保存").tag(SDRConversion.sdr)
                Text("HDR補正（カーブ）").tag(SDRConversion.hdrCurve)
                Text("HDR補正（ML/LUT）").tag(SDRConversion.hdrML)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!model.canEditSettings)
            .help("HDR 補正は明部だけを HDR 領域へ拡張します（ベースの見た目は維持）。カーブは手書きの明部加重、ML/LUT は Apple 写真の実 HDR から学習した色ごとのゲインを使います。")

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("明部の色").font(.headline)
                highlightAxisSlider(title: "色温度", value: $model.highlightWarmth,
                                    leftLabel: "寒色", rightLabel: "暖色")
                highlightAxisSlider(title: "ティント", value: $model.highlightTint,
                                    leftLabel: "グリーン", rightLabel: "マゼンタ")
                Button("リセット") {
                    model.highlightWarmth = 0.0
                    model.highlightTint = 0.0
                }
            }
            // HDR 補正時のみ有効。カラーゲインマップを作れない環境でも丸ごと無効化する
            // （その旨は変換開始時に一度だけ通知される）。
            .disabled(!model.canEditSettings || model.sdrMode == .sdr
                      || !GainForge.isHighlightColorShiftAvailable)
        }
        .padding(14)
        .frame(width: 260)
    }

    /// 色軸 1 本分（ラベル・数値・スライダー・左右端の説明）。色温度／ティントで共用する。
    @ViewBuilder
    private func highlightAxisSlider(title: String, value: Binding<Double>,
                                     leftLabel: String, rightLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // step を刻んでおくと「0（無効）に戻す」がマウス操作で確実にできる。
            Slider(value: value, in: -1.0...1.0, step: 0.05)
                .disabled(!model.canEditSettings)
            HStack {
                Text(leftLabel)
                Spacer()
                Text(rightLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - サイズ（書き出し時のリサイズ。全経路で縮小のみ・アスペクト比維持）

    private var sizeSection: some View {
        HStack(spacing: 8) {
            Text("サイズ")
            Picker("", selection: $model.resizeKind) {
                Text("元のサイズ").tag(ResizeKind.original)
                Text("総画素数").tag(ResizeKind.megapixels)
                Text("横幅").tag(ResizeKind.width)
                Text("縦幅").tag(ResizeKind.height)
            }
            .labelsHidden()
            .frame(width: 100)
            .disabled(!model.canEditSettings)
            .help("書き出し時に縮小します（拡大はしません・アスペクト比は維持）。総画素数は 8=約800万画素の目安。ゲインマップ付き HDR も同率で縮小します。")

            switch model.resizeKind {
            case .original:
                EmptyView()
            case .megapixels:
                mpixField()
            case .width:
                pixelField(value: $model.resizeWidth, presets: [1280, 1920, 2560, 3840, 4096])
            case .height:
                pixelField(value: $model.resizeHeight, presets: [720, 1080, 1440, 2160])
            }
        }
        .fixedSize()
    }

    /// 総画素数（Mpix, Double）用の数値フィールド＋プリセット。自由入力とプリセットを両立する。
    @ViewBuilder
    private func mpixField() -> some View {
        HStack(spacing: 4) {
            TextField("", value: $model.resizeMegapixels, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .disabled(!model.canEditSettings)
            presetMenu(presets: [2.0, 4.0, 8.0, 12.0, 16.0, 24.0],
                       label: { "\(Int($0)) Mpix" }) { model.resizeMegapixels = $0 }
            Text("Mpix").foregroundStyle(.secondary)
        }
    }

    /// 幅/高さ（px, Int）用の数値フィールド＋プリセット。
    @ViewBuilder
    private func pixelField(value: Binding<Int>, presets: [Int]) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .disabled(!model.canEditSettings)
            presetMenu(presets: presets, label: { "\($0) px" }) { value.wrappedValue = $0 }
            Text("px").foregroundStyle(.secondary)
        }
    }

    /// プリセット値を並べる小さなドロップダウン（⌄）。選ぶと数値フィールドへ反映する。
    @ViewBuilder
    private func presetMenu<V>(presets: [V], label: @escaping (V) -> String,
                               apply: @escaping (V) -> Void) -> some View {
        Menu {
            ForEach(Array(presets.enumerated()), id: \.offset) { _, v in
                Button(label(v)) { apply(v) }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)   // 自前の chevron を出すので組み込みインジケータは隠す（二重表示防止）
        .frame(width: 24)
        .disabled(!model.canEditSettings)
        .help("よく使うサイズを選ぶ")
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

/// 左→右に子ビューを並べ、行に入り切らない子を次の行へ折り返す簡易フローレイアウト。
/// 各子はそれぞれの固有サイズ（`.fixedSize()` 済みの各セクション）で配置する。
/// ウィンドウ幅に応じてツールバーの段数が 1〜N に伸縮する。
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 16   // 同一行内の水平間隔
    var vSpacing: CGFloat = 8    // 折り返した行間の垂直間隔

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        // 前提: 有限幅が提案される文脈（VStack 直下など）で使う。提案幅が nil のときは
        // 単一行として高さを申告する（実配置で折り返すとクリップし得るので無限幅では使わない）。
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0, totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + hSpacing + size.width > maxWidth {
                // この子は入り切らない → 改行
                totalHeight += rowHeight + vSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? hSpacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                // 行末を超える → 改行
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
