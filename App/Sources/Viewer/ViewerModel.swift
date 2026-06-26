import SwiftUI
import AppKit

/// 比較ビューワの共有状態。別ウィンドウ（シングルインスタンス）で 1 つだけ生きる。
/// 変換済み行は「変換前 / 変換後」の 2 ペイン、未変換行は「元画像のみ」の 1 ペインを映す。
/// 複数ペインのときは zoom / center を共有し、常に同じ箇所・同じ倍率を映す。
@MainActor
final class ViewerModel: ObservableObject {

    /// 1 ペイン分の表示メタ情報（画像の実体は `images` 側に別管理）。
    struct Pane: Equatable {
        let url: URL
        let name: String
        let label: String       // 「変換前 (SDR)」「変換後 (HDR)」「元画像」など
        let isHDR: Bool         // 変換後 HEIC のみ HDR（EDR）描画を要求する
        let bytes: Int?
        let showGainMap: Bool   // キャプションにゲインマップ有無チップを出すか
        let hasGainMap: Bool
    }

    /// 表示対象（1 行ぶん）。変換済みなら 2 ペイン、未変換なら 1 ペイン。
    struct Source: Equatable {
        let id: FileItem.ID     // 元の行 ID（一覧から消えたら閉じる判定に使う）
        let panes: [Pane]       // 1 または 2 要素
    }

    @Published private(set) var source: Source?
    /// `source.panes` と同じ並びの画像実体（遅延デコード）。
    @Published private(set) var images: [NSImage?] = []
    /// `source.panes` と同じ並びの各画像ピクセル寸法（キャプション表示用）。
    @Published private(set) var paneSizes: [CGSize] = []
    /// ズーム計算の基準寸法（先頭ペイン基準。ペア表示では前後で一致する前提）。
    @Published private(set) var pixelSize: CGSize = CGSize(width: 1, height: 1)

    /// ビューワウィンドウが現在開いているか。選択追従はこのフラグが true のときだけ行う。
    @Published var isPresented = false

    /// 原寸画像をバックグラウンドで読み込み中か。true の間、画像が未到着のペインに
    /// ローディング表示（スピナー）を出す。読み込み失敗時もスピナーが残らないよう、
    /// 反映（applyDecoded）/ クリア時に必ず false へ戻す。
    @Published private(set) var isLoading = false

    /// 原寸画像の読み込み／デコードは重いので必ずバックグラウンドで行う。
    /// 連続選択時は前回の読み込みを破棄し、最新の結果だけを反映する。
    private var loadTask: Task<Void, Never>?
    /// 反映時に「まだ最新の選択か」を判定する世代カウンタ。display 毎に進める。
    private var loadGeneration = 0

    /// バックグラウンドで生成した NSImage をアクター境界へ渡すための箱。
    /// NSImage は Sendable でないが、生成直後で未共有のインスタンスのみを
    /// MainActor へ一度だけ受け渡す用途に限定するため安全に扱える。
    private struct DecodedPanes: @unchecked Sendable {
        let images: [NSImage?]
        let sizes: [CGSize]
    }

    // MARK: - 共有ズーム / パン状態（複数ペインで共有）

    /// 表示倍率。1 画像ピクセル = `zoom` 表示ポイント（100% = 1.0）。
    @Published var zoom: Double = 1.0
    /// アスペクトフィット中か。true の間はペインが実効倍率を `zoom` へ書き戻す。
    @Published var isFit: Bool = true
    /// ペイン中央に写す画像ピクセル座標（top-left 原点）。
    @Published var center: CGPoint = .zero

    static let minZoom = 0.1   // 10%
    static let maxZoom = 8.0   // 800%

    var currentID: FileItem.ID? { source?.id }
    var hasContent: Bool { source != nil }

    // MARK: - 読み込み / クリア

    /// 行の状態に応じて表示内容を組み立てて差し替える。
    /// - 出力 HEIC を持つ（done / existing かつ outputURL あり）: 変換前 / 変換後の 2 ペイン
    /// - それ以外: 元画像のみの 1 ペイン
    func display(_ item: FileItem) {
        // 入力ファイル自体がゲインマップ（＝HDR表示可能）を持つか。
        // ラベルの SDR/HDR 表記・HDR(EDR)描画・チップ表示をこの実態に合わせる。
        let inputHasGainMap = item.gainMap == .present
        let panes: [Pane]
        if item.hasComparableOutput, let output = item.outputURL {
            // 既存検出（変換せずに見つけた HEIC）も、変換完了と同じく前後 2 ペインで比較する。
            let afterLabel = item.status == .existing ? "既存 HEIC (HDR)" : "変換後 (HDR)"
            panes = [
                Pane(url: item.inputURL, name: item.inputURL.lastPathComponent,
                     label: inputHasGainMap ? "変換前 (HDR)" : "変換前 (SDR)",
                     isHDR: inputHasGainMap, bytes: item.inputBytes,
                     showGainMap: true, hasGainMap: inputHasGainMap),
                Pane(url: output, name: output.lastPathComponent,
                     label: afterLabel, isHDR: true, bytes: item.outputBytes,
                     showGainMap: true, hasGainMap: item.gainMap == .present),
            ]
        } else {
            panes = [
                Pane(url: item.inputURL, name: item.inputURL.lastPathComponent,
                     label: inputHasGainMap ? "元画像 (HDR)" : "元画像 (SDR)",
                     isHDR: inputHasGainMap, bytes: item.inputBytes,
                     showGainMap: true, hasGainMap: inputHasGainMap),
            ]
        }
        let src = Source(id: item.id, panes: panes)
        guard source != src else { return }   // 同じ内容なら据え置き

        // メタ情報（ラベル・キャプション）は即座に切り替える。読み込み中はペインを空（黒）にし、
        // スピナーを出す。画像が届いた時点で applyDecoded が isLoading を下ろす。
        source = src
        images = Array(repeating: nil, count: panes.count)
        isLoading = true
        isFit = true

        // 進行中の旧読み込みを破棄し、最新世代だけを採用する。
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        // detached へ渡すのは Sendable な値のみ（URL と HDR フラグ）。
        let requests = panes.map { (url: $0.url, hdr: $0.isHDR) }

        // 原寸読み込み・デコード・寸法取得はすべてバックグラウンドで行い、選択時の UI を止めない。
        // 複数ペイン（JPEG + HEIC）は withTaskGroup で並列デコードし、合計時間を max(各ペイン) に短縮する。
        // HDR/EXIF 回転を現状どおり正しく扱うため、描画は従来の NSImage(contentsOf:) 経路を維持する。
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            if Task.isCancelled { return }
            let t0 = Date()

            // index 付きで並列デコードし、順序を保って結果を集める。
            typealias PaneResult = (index: Int, image: NSImage?, size: CGSize)
            var results: [PaneResult] = await withTaskGroup(of: PaneResult.self) { group in
                for (i, req) in requests.enumerated() {
                    group.addTask(priority: .userInitiated) {
                        let tImg = Date()
                        let image = NSImage(contentsOf: req.url)
                        let tSize = Date()
                        let size = ImageProbe.pixelSize(for: req.url) ?? CGSize(width: 1, height: 1)
                        let tDone = Date()
                        print("[Viewer] pane[\(i)] \(req.url.lastPathComponent)"
                            + "  NSImage: \(String(format: "%.3f", tSize.timeIntervalSince(tImg)))s"
                            + "  pixelSize: \(String(format: "%.3f", tDone.timeIntervalSince(tSize)))s")
                        return (i, image, size)
                    }
                }
                var collected: [PaneResult] = []
                for await r in group { collected.append(r) }
                return collected
            }
            results.sort { $0.index < $1.index }

            print("[Viewer] total load: \(String(format: "%.3f", Date().timeIntervalSince(t0)))s")
            if Task.isCancelled { return }
            let payload = DecodedPanes(images: results.map { $0.image }, sizes: results.map { $0.size })
            await self?.applyDecoded(payload, generation: generation)
        }
    }

    /// バックグラウンドで読み込んだ結果を反映する。世代が古ければ（既に次の選択へ移っていれば）破棄する。
    private func applyDecoded(_ payload: DecodedPanes, generation: Int) {
        guard generation == loadGeneration else { return }
        print("[Viewer] applyDecoded → MainActor reached")
        images = payload.images
        paneSizes = payload.sizes
        let size = payload.sizes.first ?? CGSize(width: 1, height: 1)
        pixelSize = size
        isFit = true
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        isLoading = false
    }

    /// 表示中の行が一覧から消えていたら閉じる（空表示にする）。
    func closeIfRemoved(existingIDs: Set<FileItem.ID>) {
        if let id = source?.id, !existingIDs.contains(id) { clear() }
    }

    func clear() {
        // 進行中の読み込みを破棄し、遅れて届く結果も世代不一致で無視させる。
        loadTask?.cancel()
        loadGeneration += 1
        source = nil
        images = []
        paneSizes = []
        isLoading = false
    }

    // MARK: - ズーム操作

    /// プリセット / スライダーからの倍率指定。フィットは解除される。
    func apply(zoom z: Double) {
        isFit = false
        zoom = min(Self.maxZoom, max(Self.minZoom, z))
    }

    func applyFit() {
        isFit = true
        // フィットは全体表示なので中心を画像中央へ戻す。
        center = CGPoint(x: pixelSize.width / 2, y: pixelSize.height / 2)
    }

    /// ピンチ操作などで、指定ビュー座標 `point`（ペインサイズ `size`）の画像ピクセルを
    /// 画面上で固定したまま倍率を `z` へ変更する。フィットは解除される。
    func zoomAt(point: CGPoint, in size: CGSize, to z: Double) {
        let newZoom = min(Self.maxZoom, max(Self.minZoom, z))
        let oldZoom = zoom
        isFit = false
        guard oldZoom > 0, newZoom > 0 else { zoom = newZoom; return }
        // カーソル下に写る画像ピクセルが動かないよう center を補正する。
        center.x += (point.x - size.width / 2) * (1 / oldZoom - 1 / newZoom)
        center.y += (point.y - size.height / 2) * (1 / oldZoom - 1 / newZoom)
        zoom = newZoom
        clampCenter()
    }

    /// フィット中にペインが算出した実効倍率を反映する（isFit は維持）。
    func reflectFitZoom(_ z: Double) {
        guard isFit else { return }
        let clamped = min(Self.maxZoom, max(Self.minZoom, z))
        if abs(clamped - zoom) > 0.0001 { zoom = clamped }
    }

    /// パン後に中心を画像範囲へクランプする。
    func clampCenter() {
        center.x = min(max(center.x, 0), pixelSize.width)
        center.y = min(max(center.y, 0), pixelSize.height)
    }

    // MARK: - スライダー（対数スケール）

    /// スライダーは log(zoom) を線形に動かす（100% を中心に拡大・縮小が対称）。
    static let sliderRange: ClosedRange<Double> = Foundation.log(minZoom)...Foundation.log(maxZoom)

    var sliderValue: Double {
        get { Foundation.log(zoom) }
        set { apply(zoom: Foundation.exp(newValue)) }
    }

    /// 現在倍率の表示用パーセント（例 150）。
    var zoomPercent: Int { Int((zoom * 100).rounded()) }
}
