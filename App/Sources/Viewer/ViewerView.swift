import SwiftUI
import AppKit

/// 比較ビューワ本体（別ウィンドウ）。上部にズーム操作、下に 1〜2 ペインの画像。
/// 変換済み行は「変換前 / 変換後」、未変換行は「元画像のみ」を映す。
struct ViewerView: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        Group {
            if let src = model.source {
                content(src)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        // ウィンドウの開閉に追従して isPresented を更新する（選択追従の可否判定に使う）。
        // onDisappear は Window シーンを閉じても発火しないことがあるため、NSWindow の
        // willClose 通知で確実に false へ戻す。閉じている間は一覧選択追従を完全に止める。
        .background(ViewerWindowTracker { model.isPresented = $0 })
    }

    // MARK: - 本体

    private func content(_ src: ViewerModel.Source) -> some View {
        VStack(spacing: 0) {
            topBar(src)
            Divider()
            HSplitView {
                ForEach(Array(src.panes.enumerated()), id: \.offset) { idx, pane in
                    paneView(pane,
                             image: model.images.indices.contains(idx) ? model.images[idx] : nil,
                             size: model.paneSizes.indices.contains(idx) ? model.paneSizes[idx] : model.pixelSize)
                }
                // HEIC なし（単ペイン）でも全幅にせず、右半分は空きペインで埋めて 50/50 を保つ。
                // 常に 2 スロット構成にすることで HSplitView の分割位置がリセットされず、
                // デバイダーはユーザーがドラッグしたときだけ動く。
                if src.panes.count == 1 {
                    emptyPane
                }
            }
        }
    }

    /// 単ペイン表示時に右半分を埋める空きペイン（黒）。
    private var emptyPane: some View {
        Rectangle()
            .fill(Color.black)
            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 上部バー

    private func topBar(_ src: ViewerModel.Source) -> some View {
        HStack(spacing: 14) {
            Text(src.panes.map { $0.name }.joined(separator: " → "))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            // プリセット（フィット / 100% / 200%）
            HStack(spacing: 4) {
                presetButton("フィット", active: model.isFit) { model.applyFit() }
                presetButton("100%", active: isActive(1.0)) { model.apply(zoom: 1.0) }
                presetButton("200%", active: isActive(2.0)) { model.apply(zoom: 2.0) }
            }

            // 任意倍率スライダー（対数スケール 10%〜800%）
            Slider(value: $model.sliderValue, in: ViewerModel.sliderRange)
                .frame(width: 150)
            Text("\(model.zoomPercent)%")
                .font(.callout)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func presetButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(active ? .accentColor : nil)
    }

    /// フィット解除中で、現在倍率が指定プリセットと一致するか。
    private func isActive(_ z: Double) -> Bool {
        !model.isFit && abs(model.zoom - z) < 0.01
    }

    // MARK: - ペイン

    private func paneView(_ pane: ViewerModel.Pane, image: NSImage?, size: CGSize) -> some View {
        VStack(spacing: 0) {
            ImagePane(model: model, image: image, isHDR: pane.isHDR)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            captionBar(pane, size: size)
        }
        .frame(minWidth: 220)
    }

    private func captionBar(_ pane: ViewerModel.Pane, size: CGSize) -> some View {
        HStack(spacing: 8) {
            Text(pane.label).font(.caption).foregroundStyle(.secondary)
            Text(pane.name).font(.caption).lineLimit(1).truncationMode(.middle)
            // ファイル名に並べて、その画像のピクセル寸法を表示する。
            Text("\(Int(size.width))×\(Int(size.height)) px")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if let bytes = pane.bytes {
                Text(SizeFormat.mb(bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            if pane.showGainMap {
                (pane.hasGainMap ? GainMapState.present : GainMapState.absent).chip
            } else {
                // チップ無しのペインでも同じ高さを確保し、左右ペインのステータス高さを揃える。
                GainMapState.absent.chip.hidden()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - 空表示

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("一覧の行をダブルクリックすると表示します")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 比較ビューワウィンドウの実際の開閉を NSWindow 通知で確実に追跡する橋渡し。
/// SwiftUI の onDisappear は Window シーンを閉じても発火しないことがあり、
/// それに頼ると「閉じたのに isPresented が true のまま」になり、一覧選択のたびに
/// 裏で原寸画像を読み込んで遅くなる。willClose を直接拾って閉鎖を取りこぼさない。
struct ViewerWindowTracker: NSViewRepresentable {
    /// 開いたら true / 閉じたら false を通知する。
    /// 通知先は ViewerModel（@MainActor）の状態更新なので MainActor 隔離クロージャにする。
    /// これにより Sendable となり、willClose の @Sendable な通知クロージャへ安全にキャプチャできる。
    let onChange: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // makeNSView の時点では view.window が未確定なため、次のランループで結びつける。
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        private let onChange: @MainActor (Bool) -> Void
        private var token: NSObjectProtocol?

        init(onChange: @escaping @MainActor (Bool) -> Void) { self.onChange = onChange }

        func attach(to window: NSWindow) {
            // self.onChange をローカル値（@MainActor かつ Sendable）へ退避してからキャプチャする。
            // 直接プロパティをキャプチャすると nonisolated な self ごとクロージャへ送られ、
            // 「Sending 'self' risks data races」になるため、値だけを渡す。
            let notify = onChange
            // attach は makeNSView の DispatchQueue.main.async から呼ばれ、実体は main で動く。
            MainActor.assumeIsolated { notify(true) }
            // 同じウィンドウへ二重登録しないよう、既存の購読を解除してから貼り直す。
            if let token { NotificationCenter.default.removeObserver(token) }
            // willClose の通知ブロックは nonisolated だが queue: .main で必ず main 実行される。
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [notify] _ in MainActor.assumeIsolated { notify(false) } }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
