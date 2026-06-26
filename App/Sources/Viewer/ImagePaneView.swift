import SwiftUI
import AppKit

/// 1 ペイン分の画像表示。ViewerModel の zoom / center を共有し、ドラッグで center を更新する。
/// 左右ペインが同じ model を観測するため、片方のドラッグでもう片方が同期して動く。
struct ImagePane: NSViewRepresentable {
    @ObservedObject var model: ViewerModel
    let image: NSImage?
    /// 変換後ペインは HDR（EDR）描画を要求する。
    let isHDR: Bool

    func makeNSView(context: Context) -> PaneNSView {
        let v = PaneNSView()
        v.configure(image: image, isHDR: isHDR, model: model)
        return v
    }

    func updateNSView(_ nsView: PaneNSView, context: Context) {
        if nsView.imageView.image !== image {
            nsView.configure(image: image, isHDR: isHDR, model: model)
        } else {
            nsView.model = model
            nsView.relayout()
        }
        // NSView 内のスピナーを isLoading の変化に追従させる。
        nsView.setLoading(image == nil && model.isLoading)
    }
}

/// 画像を zoom / center に従って配置する自前ビュー。HDR は内包する NSImageView に委ねる。
final class PaneNSView: NSView {
    let imageView = NSImageView()
    private let spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .large
        s.appearance = NSAppearance(named: .vibrantDark)
        s.isDisplayedWhenStopped = false
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()
    weak var model: ViewerModel?
    private var lastDrag: CGPoint?

    // center を top-left 原点で扱うため flipped にする。
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageView.imageScaling = .scaleAxesIndependently   // 計算した枠ぴったりに描く（縦横比は枠側で維持）
        imageView.animates = false
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        addSubview(imageView)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLoading(_ loading: Bool) {
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func configure(image: NSImage?, isHDR: Bool, model: ViewerModel) {
        self.model = model
        imageView.image = image
        // 変換後 HEIC は HDR、変換前 JPEG は SDR。非対応ディスプレイでは自動的に SDR へフォールバック。
        imageView.preferredImageDynamicRange = isHDR ? .high : .standard
        setLoading(image == nil && model.isLoading)
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    /// zoom / center から画像枠を算出して配置する。フィット中は実効倍率を model へ反映。
    func relayout() {
        guard let model, imageView.image != nil else { imageView.frame = .zero; return }
        let img = model.pixelSize
        let W = bounds.width, H = bounds.height
        guard img.width > 0, img.height > 0, W > 0, H > 0 else { return }

        // フィット中は枠計算にローカル fitZoom を使う（model.zoom には依存しない）。
        // これにより「実効倍率の書き戻し → 再レイアウト」のフィードバックが断ち切られ、
        // フィット時のチカチカ（letterbox の縁のちらつき）が起きなくなる。
        let z: Double
        let c: CGPoint
        if model.isFit {
            z = min(W / img.width, H / img.height)
            c = CGPoint(x: img.width / 2, y: img.height / 2)   // フィットは常に中央
            // ラベル表示用に実効倍率だけ反映する（枠計算には使わないのでループしない）。
            if abs(z - model.zoom) > 0.0001 {
                DispatchQueue.main.async { [weak model] in model?.reflectFitZoom(z) }
            }
        } else {
            z = model.zoom
            c = model.center
        }

        // ペイン中央に画像ピクセル c が来るよう原点を決める（flipped 座標）。
        let originX = W / 2 - c.x * z
        let originY = H / 2 - c.y * z
        imageView.frame = CGRect(x: originX, y: originY, width: img.width * z, height: img.height * z)
    }

    // MARK: - パン（フィット中は無効）

    override func mouseDown(with event: NSEvent) {
        lastDrag = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, !model.isFit else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let last = lastDrag else { lastDrag = p; return }
        lastDrag = p
        let z = model.zoom
        guard z > 0 else { return }
        // コンテンツがカーソルに追従する向き → 中央に写る画像ピクセルは逆方向へ動く。
        model.center.x -= (p.x - last.x) / z
        model.center.y -= (p.y - last.y) / z
        model.clampCenter()
    }

    override func mouseUp(with event: NSEvent) { lastDrag = nil }

    // MARK: - ピンチ拡大 / 二本指スクロール（Magic Trackpad）

    /// トラックパッドのピンチ。カーソル位置を基準に倍率を増減する（フィットは解除）。
    override func magnify(with event: NSEvent) {
        guard let model else { return }
        let newZoom = model.zoom * (1 + event.magnification)
        let p = convert(event.locationInWindow, from: nil)
        model.zoomAt(point: p, in: bounds.size, to: newZoom)
    }

    /// 二本指スクロールでパンする（フィット中は全体表示なので無効）。
    override func scrollWheel(with event: NSEvent) {
        guard let model, !model.isFit else { return }
        let z = model.zoom
        guard z > 0 else { return }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard dx != 0 || dy != 0 else { return }
        // コンテンツが指の動きに追従する向き（ドラッグと同じ符号）。
        model.center.x -= dx / z
        model.center.y -= dy / z
        model.clampCenter()
    }
}
