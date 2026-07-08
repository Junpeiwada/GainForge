// GainForge.swift
// HDR ゲインマップ付き JPEG を、ゲインマップを保持したまま HEIC に変換する中核 API。
//
// 方式: ImageIO 低レベル経路で「SDR ベース + 元のカラーゲインマップ」を生転写する。
// Core Image の writeHEIFRepresentation(hdrImage:) はゲインマップを差分から再計算して
// ハイライトで色がずれるため使わない。詳細は Docs/Archive/調査_色ずれ原因と解法.md を参照。
//
// 移植元: AISandbox/HDRHEIF/hdrheic.swift（実証・検証済み）。

import Foundation
import CoreImage
import ImageIO
import CoreVideo
import UniformTypeIdentifiers

/// GainForge の公開 API 名前空間。
public enum GainForge {

    // MARK: - ゲインマップ検出

    /// 入力がゲインマップ（ISO / HDR いずれか）を持つかを判定する。
    public static func hasGainMap(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        for type in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type) != nil { return true }
        }
        return false
    }

    // MARK: - 変換

    /// ゲインマップ付き JPEG を HDR HEIC に変換（生転写方式）。
    ///
    /// ゲインマップが無い入力は `force` が true のときのみ SDR HEIC として書き出し、
    /// false のときは `.noGainMap` を投げる（CLI の `-f` 既定挙動に相当）。
    ///
    /// - Important: `output` の親ディレクトリは呼び出し側で事前に用意すること。
    ///   存在しないと `CGImageDestinationCreateWithURL` が nil を返し `.destinationCreateFailed` になる。
    ///
    /// - Parameters:
    ///   - input: 入力 JPEG の URL。
    ///   - output: 出力 HEIC の URL。
    ///   - quality: HEVC 品質（0.0–1.0、内部でクランプ）。SDR ベース画像の圧縮率に作用。
    ///   - gainScale: ゲインマップの縮小率（1.0 で原寸、<1.0 でサイズ削減・任意）。
    ///   - force: ゲインマップ無し画像も変換するか（false かつゲインマップ無しは `.noGainMap`）。
    ///   - overwrite: 出力先に既存ファイルがある場合に上書きするか。false のときに既存が
    ///     あれば `.outputExists` を投げる（事前計画外の予期せぬ上書きを防ぐ安全弁）。
    ///   - sdrMode: ゲインマップ無し（SDR）入力の変換方式。`.sdr` は従来通り SDR HEIC（8bit）、
    ///     `.hdrCurve` は明部加重の逆トーンマッピング、`.hdrML` は Apple 学習の色→ゲイン統計 LUT で
    ///     HDR ゲインマップを合成する（`.hdrCurve` / `.hdrML` の合成出力は 10bit HEIC）。`.hdrML` は
    ///     同梱 LUT を読めないとき `.hdrCurve` へ自動降格する（可否は `isMLGainLUTAvailable`）。
    ///     ゲインマップ付き入力（HDR）はこの設定に関わらず常に生転写される。
    ///   - resize: 書き出し時のリサイズ方式（既定 `.original` はリサイズなし）。アスペクト比を維持し
    ///     **縮小のみ**行う（原寸超えは原寸のまま）。全経路（生転写 / SDR / 合成）へ共通に効き、
    ///     再サンプルは `CILanczosScaleTransform`（最高品質）で行う。生転写ではゲインマップも同率で縮小。
    /// - Returns: 変換結果（サイズ・HDR 種別）。`isHDR` は「出力がゲインマップを持つか」を表す
    ///   （`.hdrCurve` / `.hdrML` で合成した出力も true）。
    @discardableResult
    public static func convert(
        input: URL,
        output: URL,
        quality: Double = 0.6,
        gainScale: Double = 1.0,
        force: Bool = false,
        overwrite: Bool = false,
        sdrMode: SDRConversion = .sdr,
        resize: ResizeMode = .original
    ) throws -> ConversionResult {
        let q = max(0.0, min(1.0, quality))
        let inputHasGainMap = hasGainMap(input)
        // 出力がゲインマップを持つ HDR HEIC になるか。生転写、または SDR からの合成で true。
        var outputIsHDR = inputHasGainMap

        if inputHasGainMap {
            try ensureWritable(output, overwrite: overwrite)
            try writeGainMapHEIC(input: input, output: output, quality: q, gainScale: gainScale, resize: resize)
        } else {
            guard force else { throw GainForgeError.noGainMap(input) }
            try ensureWritable(output, overwrite: overwrite)
            switch sdrMode {
            case .sdr:
                try writeSDRHEIC(input: input, output: output, quality: q, resize: resize)
            case .hdrCurve:
                try writeExpandedHDRHEIC(input: input, output: output, quality: q, resize: resize)
                outputIsHDR = true
            case .hdrML:
                try writeMLExpandedHDRHEIC(input: input, output: output, quality: q, resize: resize)
                outputIsHDR = true
            }
        }

        return ConversionResult(
            outputURL: output,
            inputBytes: fileSize(input),
            outputBytes: fileSize(output),
            isHDR: outputIsHDR
        )
    }

    // MARK: - HDR 生転写

    /// ゲインマップ付き HEIC を ImageIO 生転写で書き出す。
    ///
    /// 移植元で実証済みの「落とし穴」を維持している（仕様.md「変換ロジックの要点」）。
    private static func writeGainMapHEIC(
        input: URL,
        output: URL,
        quality: Double,
        gainScale: Double,
        resize: ResizeMode
    ) throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw GainForgeError.cannotReadSource(input)
        }

        // 1. 元のゲインマップ補助辞書から Metadata と ColorSpace を取得する。
        //    ISO 型では実ピクセルデータはこの辞書に含まれない（macOS で Data は nil）。
        guard let origAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any],
              let gainCSValue = origAux[kCGImageAuxiliaryDataInfoColorSpace as String],
              CFGetTypeID(gainCSValue as CFTypeRef) == CGColorSpace.typeID else {
            throw GainForgeError.gainMapColorSpaceMissing
        }
        // 5. ゲインマップ ColorSpace はハードコードせず元辞書から取得（機種ごとに異なる）。
        let gainCS = gainCSValue as! CGColorSpace
        let origMeta = origAux[kCGImageAuxiliaryDataInfoMetadata as String]

        // ベース SDR 画像を先にデコードする（寸法をリサイズ計画の基準に使うため）。
        guard let baseCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw GainForgeError.baseImageUnreadable
        }

        // リサイズ計画（縮小のみ）。ベースを縮小するとき、ゲインマップも同率で縮小して
        // ベースとの相対比を保つ（ISO ゲインマップは相対寸法でベースに対応するため）。
        // 基準寸法は baseCG の実ピクセル寸法（プロパティ辞書に依存せず確実に取れる）。
        let baseSize = CGSize(width: baseCG.width, height: baseCG.height)
        let resizeTarget = ResizePlanner.targetSize(original: baseSize, mode: resize)
        let baseScale: CGFloat = resizeTarget.map { $0.width / baseSize.width } ?? 1.0

        // 2. ゲインマップをカラー CIImage として読む。
        guard var gainCI = CIImage(contentsOf: input, options: [.auxiliaryHDRGainMap: true]) else {
            throw GainForgeError.gainMapImageUnreadable
        }
        // 明示 gainScale（ゲインマップ寸法の任意縮小・CLI/GUI 非公開で現状 1.0）× リサイズによる
        // 同率縮小 baseScale。ゲインマップもベースと同じ Lanczos で縮小し、リサンプル品質を揃える
        // （アフィン変換のバイリニアだと明部にジャギー/ハローが乗るため）。両者を掛けて 1 度で適用する。
        let effectiveGainScale = gainScale * Double(baseScale)
        if effectiveGainScale != 1.0 {
            gainCI = lanczosResized(gainCI, scale: CGFloat(effectiveGainScale))
        }

        // 3. ゲインマップ本来の ColorSpace（典型: Display P3 PQ）で BGRA8 に焼く。
        //    workingColorSpace に NSNull() を渡し CoreImage の色変換をパススルーにする。
        //    sRGB 等で焼くと二重変換で HDR が破綻するため、必ず元の ColorSpace を使う。
        let rawCtx = CIContext(options: [.workingColorSpace: NSNull()])
        let gw = Int(gainCI.extent.width.rounded())
        let gh = Int(gainCI.extent.height.rounded())
        guard gw > 0, gh > 0 else { throw GainForgeError.gainMapEmpty }
        let gbpr = gw * 4   // BGRA8 は 1 画素 4 バイト。gw*4 は常に 4 の倍数で追加パディング不要。
        var gainData = Data(count: gbpr * gh)
        gainData.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            rawCtx.render(gainCI, toBitmap: base, rowBytes: gbpr,
                          bounds: gainCI.extent, format: .BGRA8, colorSpace: gainCS)
        }

        // 4. 補助辞書を再構成。PixelFormat は標準の 32BGRA に作り直す
        //    （元の非公開フォーマット流用は Finalize クラッシュ）。
        var aux: [String: Any] = [
            kCGImageAuxiliaryDataInfoData as String: gainData as CFData,
            kCGImageAuxiliaryDataInfoDataDescription as String: [
                "PixelFormat": Int(kCVPixelFormatType_32BGRA),
                "BytesPerRow": gbpr,
                "Width": gw,
                "Height": gh,
            ],
            kCGImageAuxiliaryDataInfoColorSpace as String: gainCS,
        ]
        if let meta = origMeta { aux[kCGImageAuxiliaryDataInfoMetadata as String] = meta }

        // 5. ベース SDR + ゲインマップを HEIC として書き出す。
        //    リサイズ指定があればベースを Lanczos で縮小する（ゲインマップは上で同率縮小済み）。
        let baseImage = resizeTarget != nil ? try resizedCGImage(baseCG, target: resizeTarget!) : baseCG
        guard let dst = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw GainForgeError.destinationCreateFailed(output)
        }
        // 元画像の EXIF/GPS/TIFF/IPTC/Orientation 等のメタデータを引き継ぐ。
        // CGImage 単体はピクセルのみで属性を持たないため、ここでプロパティ辞書を
        // 明示的に渡さないと全メタデータが失われる（Orientation も失われ表示が回転し得る）。
        var baseProps = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        // 縮小時は EXIF 等に残る旧ピクセル寸法を除去する（実寸と食い違わせない）。
        if resizeTarget != nil { baseProps = strippingPixelDimensions(baseProps) }
        baseProps[kCGImageDestinationLossyCompressionQuality as String] = quality
        CGImageDestinationAddImage(dst, baseImage, baseProps as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(dst, kCGImageAuxiliaryDataTypeISOGainMap, aux as CFDictionary)
        guard CGImageDestinationFinalize(dst) else {
            throw GainForgeError.finalizeFailed(output)
        }

        // 6. 検算: 補助データ追加は戻り値を返さないため、書き出し後に確認する（落とし穴6）。
        guard hasGainMap(output) else {
            throw GainForgeError.gainMapVerificationFailed(output)
        }
    }

    // MARK: - SDR フォールバック

    /// ゲインマップ無し画像を SDR HEIC として書き出す（CLI の `-f` 相当）。
    ///
    /// 元画像の EXIF/GPS/TIFF/IPTC/Orientation 等を引き継ぐため、ImageIO 経路で
    /// プロパティ辞書を明示的に渡す（gain-map 経路と挙動を揃える）。
    private static func writeSDRHEIC(input: URL, output: URL, quality: Double, resize: ResizeMode) throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
              var sdr = CIImage(contentsOf: input) else {
            throw GainForgeError.cannotReadSource(input)
        }
        // リサイズ指定があれば Lanczos で縮小する（縮小のみ・アスペクト維持）。
        let resizeTarget = ResizePlanner.targetSize(original: sdr.extent.size, mode: resize)
        if let resizeTarget {
            sdr = lanczosResized(sdr, scale: resizeTarget.width / sdr.extent.width)
        }
        let ctx = CIContext(options: nil)
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let cg = ctx.createCGImage(sdr, from: sdr.extent, format: .RGBA8, colorSpace: p3) else {
            throw GainForgeError.baseImageUnreadable
        }
        guard let dst = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw GainForgeError.destinationCreateFailed(output)
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        // PNG 入力の AI 生成タグ（ComfyUI "prompt" / AnimeForge "animeforge" 等）を
        // EXIF UserComment として引き継ぐ（無ければ無変換）。
        props = PNGTextMetadata.merging(props, from: input)
        // 縮小時は EXIF 等に残る旧ピクセル寸法を除去する（実寸と食い違わせない）。
        if resizeTarget != nil { props = strippingPixelDimensions(props) }
        props[kCGImageDestinationLossyCompressionQuality as String] = quality
        CGImageDestinationAddImage(dst, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else {
            throw GainForgeError.finalizeFailed(output)
        }
    }

    // MARK: - SDR→HDR 合成（明部加重の逆トーンマッピング）

    /// ゲインマップ無し SDR 画像を「ベースは維持し、明部だけを HDR ヘッドルームへ拡張した」
    /// HDR HEIC として書き出す共通経路。ゲイン合成の方式だけを `synthesize` で差し替える
    /// （`.hdrCurve` = 明部加重カーブ / `.hdrML` = Apple 学習の色→ゲイン統計 LUT）。
    ///
    /// 方式:
    /// 1. `synthesize` で拡張レンジの HDR 版を合成する。中間調・暗部は等倍（gain≈1）、
    ///    明部だけを持ち上げるため SDR 表示の見た目は変えず、空・光源・鏡面反射だけが伸びる。
    /// 2. CoreImage の `writeHEIF10Representation(of:options:[.hdrImage:])` に
    ///    「元 SDR（ベース）」と「合成 HDR」を渡すと、両者の差分から ISO ゲインマップを
    ///    生成して埋め込んでくれる（写真アプリと同じ構造）。生転写経路が避けている
    ///    「差分からの再計算」は、ここでは合成なので元ゲインマップとの不一致が起きず問題ない。
    ///    出力は 10bit HEIC（HEVC Main 10）。8bit の `writeHEIFRepresentation(format: .RGBA8)`
    ///    と違い、16bit PNG 等の高精度入力の階調を保持し、空などのバンディングを抑える
    ///    （ベース CIImage は float 精度のまま渡るので、量子化は 10bit 出力時の一度だけ）。
    /// 3. EXIF/GPS/TIFF/Orientation は `settingProperties` で元画像から引き継ぐ
    ///    （落とし穴7: メタデータ欠落と回転を防ぐ）。ベースの色は Display P3（PQ ではない）。
    /// 4. 書き出し後に `hasGainMap` で検算する（落とし穴6）。
    private static func writeSynthesizedHDRHEIC(
        input: URL, output: URL, quality: Double, resize: ResizeMode,
        synthesize: (_ sdr: CIImage, _ context: CIContext, _ input: URL) throws -> CIImage
    ) throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
              var sdr = CIImage(contentsOf: input) else {
            throw GainForgeError.cannotReadSource(input)
        }
        var origProps = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        // PNG 入力の AI 生成タグ（ComfyUI "prompt" / AnimeForge "animeforge" 等）を
        // EXIF UserComment として引き継ぐ（無ければ無変換）。
        origProps = PNGTextMetadata.merging(origProps, from: input)

        // リサイズ指定があれば合成前に SDR を Lanczos で縮小する。合成 HDR もベースも
        // 縮小後の SDR から作られるため、ゲインマップとベースは自動的に整合する。
        let resizeTarget = ResizePlanner.targetSize(original: sdr.extent.size, mode: resize)
        if let resizeTarget {
            sdr = lanczosResized(sdr, scale: resizeTarget.width / sdr.extent.width)
            // 縮小時は EXIF 等に残る旧ピクセル寸法を除去する（実寸と食い違わせない）。
            origProps = strippingPixelDimensions(origProps)
        }

        // リニア（拡張）Display P3 を作業空間にし、明部ゲインをリニア光で計算する。
        let workingCS = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let ctx = CIContext(options: [.workingColorSpace: workingCS])

        let hdr = try synthesize(sdr, ctx, input)

        // ベースには元画像のプロパティ（EXIF/GPS/TIFF/Orientation）を持たせる。
        let base = sdr.settingProperties(origProps)

        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
            .hdrImage: hdr,
        ]
        // 10bit HEIC（HEVC Main 10）で書き出す。8bit の writeHEIFRepresentation(format:.RGBA8)
        // と違い高精度入力（16bit PNG 等）の階調を保持する。SDR ベースの見た目は不変。
        do {
            try ctx.writeHEIF10Representation(of: base, to: output,
                                             colorSpace: p3, options: opts)
        } catch {
            throw GainForgeError.finalizeFailed(output)
        }

        guard hasGainMap(output) else {
            throw GainForgeError.gainMapVerificationFailed(output)
        }
    }

    /// `.hdrCurve`: 明部加重の逆トーンマッピング（手書きカーブ）でゲインを合成して書き出す。
    private static func writeExpandedHDRHEIC(input: URL, output: URL, quality: Double, resize: ResizeMode) throws {
        try writeSynthesizedHDRHEIC(input: input, output: output, quality: quality, resize: resize,
                                    synthesize: makeHighlightExpandedHDR)
    }

    /// `.hdrML`: Apple 写真ライブラリから学習した色→ゲイン統計 LUT でゲインを合成して書き出す。
    ///
    /// LUT がロード/検証できないとき（リソース同梱ミス・破損など）は `.hdrCurve`（明部加重カーブ）
    /// へ自動降格する。環境依存の失敗でバッチ全体をエラーにしないための安全弁
    /// （[Docs/SDRのHDR化手法の研究.md] §7 の降格方針に一致）。降格しても出力はゲインマップ付き HDR。
    private static func writeMLExpandedHDRHEIC(input: URL, output: URL, quality: Double, resize: ResizeMode) throws {
        try writeSynthesizedHDRHEIC(input: input, output: output, quality: quality, resize: resize) { sdr, context, input in
            guard let lutData = gainLUTData else {
                return try makeHighlightExpandedHDR(sdr, context: context, input: input)
            }
            return try makeLUTExpandedHDR(sdr, lutData: lutData, input: input)
        }
    }

    /// 明部加重ゲインを掛けるカーネル。__sample はリニア（作業空間）で渡る前提。
    /// stock フィルタの multiply は拡張レンジ（>1.0）でクランプし得るため、ハイライトを 1.0 超へ
    /// 確実に伸ばすには自前カーネルで s.rgb*gain を直接計算する。CIColorKernel(source:) は
    /// macOS 10.14 で非推奨だが現在も動作し、SwiftPM ライブラリに Metal カーネル（-fcikernel 等）を
    /// 組み込むビルド構成を避けるため v1 では意図的に採用する。ソースは定数なので変換ごとに
    /// 再コンパイルせず一度だけ生成する（バッチで枚数分の無駄を避ける）。
    /// ゲイン量を色分布で変調する（肌・白い面の不自然な持ち上げを抑える）:
    ///  (1) 低彩度保護 … 白壁・雪・紙・淡い肌など彩度の低い明部ほど抑制。
    ///  (2) 肌色保護   … 暖色 (R>=G>=B) かつ中程度彩度（鮮やか色は除外）を抑制。
    ///  (3) クリップ近傍(鏡面・光源) … 保護を解除して伸ばす。
    /// per-pixel のスカラーゲインなので色相・彩度は不変。色は「どれだけ伸ばすか」だけを決める。
    private static let expandHighlightsKernel: CIColorKernel? = CIColorKernel(source: """
    kernel vec4 gainforgeExpandHighlights(__sample s, float knee, float headroom) {
        vec3 c = s.rgb;
        float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
        float tl = smoothstep(knee, 1.0, l);           // 従来の明部加重カーブ

        float mx = max(c.r, max(c.g, c.b));
        float mn = min(c.r, min(c.g, c.b));
        float sat = (mx - mn) / max(mx, 1.0e-4);

        float lowChroma = 1.0 - smoothstep(0.15, 0.45, sat);        // (1)
        float redMax = step(c.g, c.r) * step(c.b, c.r);
        float warm   = step(c.b, c.g);
        float skinSat = smoothstep(0.12, 0.22, sat) * (1.0 - smoothstep(0.55, 0.80, sat));
        float skin = redMax * warm * skinSat;                       // (2)

        float diffuse = max(lowChroma, skin);
        float spec = smoothstep(0.92, 1.0, l);                      // (3)
        float protect = clamp(diffuse * (1.0 - spec), 0.0, 1.0);

        float gain = 1.0 + (headroom - 1.0) * tl * (1.0 - 0.85 * protect);
        return vec4(c * gain, s.a);
    }
    """)

    /// SDR CIImage から「明部加重ゲイン」を掛けた拡張レンジ HDR CIImage を合成する。
    ///
    /// - 中間調・暗部は等倍、閾値 `knee`（リニア）以上を smoothstep で滑らかに `headroom` 倍まで拡張。
    ///   `knee` を明部寄り（0.5）に取り、暗部〜中間調を持ち上げずコントラスト過多を避ける。
    ///   SDR ベース画像は改変されず（実測で入力と画素一致）、HDR ヘッドルームのある画面でのみ
    ///   明部が伸びる。輝度を絞った画面では相対コントラストが上がって見える点に注意。
    /// - ゲインは輝度から算出した無彩スカラーを RGB へ一律に掛けるため、色相・彩度は動かない。
    /// - ゲイン量は色分布で変調する: 低彩度（白壁・雪・紙・淡い肌）と肌色（暖色・中彩度）の拡散明部は
    ///   最大 85% 抑制し、空・光源・鮮やかな色や、クリップ近傍の鏡面は抑制しない。肌や白い面が
    ///   不自然に光るのを防ぐ（抑制するのは「どれだけ伸ばすか」だけで、色相・彩度は不変のまま）。
    /// - `headroom` は画像の平均輝度から自動決定する（暗い画像ほど拡張余地が大きく強め、
    ///   既に明るい画像は眩しさを避けて控えめ）。ユーザー操作は不要（完全自動）。
    private static func makeHighlightExpandedHDR(_ sdr: CIImage, context: CIContext, input: URL) throws -> CIImage {
        // 平均輝度（リニア）からヘッドルームを自動決定。暗い→強め / 明るい→控えめ。
        // 上限 4x=2stop / 下限 2x≈1.17stop。明部だけを控えめに伸ばす自然な強度に確定。
        let mean = meanLinearLuma(sdr, context: context)
        let maxHeadroom = 4.0   // 約 2 stop（暗い画像）
        let minHeadroom = 2.0   // 約 1 stop（明るい画像）
        let t = smoothstepScalar(0.1, 0.5, mean)
        let headroom = maxHeadroom + (minHeadroom - maxHeadroom) * t
        let knee = 0.5          // 拡張を始めるリニア輝度（明部に限定しコントラスト過多を避ける）

        guard let kernel = expandHighlightsKernel,
              let out = kernel.apply(extent: sdr.extent,
                                     arguments: [sdr, Float(knee), Float(headroom)]) else {
            throw GainForgeError.hdrSynthesisFailed(input)
        }
        return out
    }

    // MARK: - SDR→HDR 合成（Apple 学習の色→ゲイン統計 LUT）

    /// Apple 学習ゲイン LUT のパラメータ。LUT は各格子点に per-channel の正規化ゲイン g'（0..1）を
    /// 持ち、適用時に
    ///   out_ch = sdr_ch * (1 + g'_ch * (gainLUTMax - 1))
    /// で拡張レンジへ復元する。CIColorCube は出力を [0,1] にクランプするため、HDR 値そのもの
    /// ではなく正規化ゲインを格納し、乗算はカーネルで行う。
    ///
    /// LUT バイナリ（`Resources/apple-gainlut-17-perchan.bin`）は Apple 写真ライブラリの実 HDR 写真
    /// から「色 → 平均ゲイン」を集計し、拡張リニア Display P3・gainLUTGridN³ 格子・per-channel の
    /// 正規化ゲインとして焼き込んだもの。生成スクリプトは集計元の写真データに依存するオフライン処理
    /// のため本リポジトリには同梱していない。差し替える場合は下記フォーマットを厳守すること:
    /// `gainLUTGridN³ × 4ch × Float32` のリトルエンディアン連続配列、各値 0..1、拡張リニア Display P3。
    private static let gainLUTResourceName = "apple-gainlut-17-perchan"
    private static let gainLUTGridN = 17
    private static let gainLUTMax: Double = 8.0

    /// バンドル同梱の LUT を一度だけロード・検証して保持する（変換ごとの再読込を避ける）。
    /// 検証: バイト数が `gainLUTGridN³ × 4 × Float32`、かつ全要素が有限で正規化ゲインの範囲
    /// [0,1]（微小許容）に収まること（NaN/Inf・異常値の混入を弾く）。いずれか失敗なら nil を返し、
    /// `.hdrML` は呼び出し側（`writeMLExpandedHDRHEIC`）で `.hdrCurve` へ自動降格する。
    private static let gainLUTData: Data? = {
        let n = gainLUTGridN
        guard let url = Bundle.module.url(forResource: gainLUTResourceName, withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              data.count == n * n * n * 4 * MemoryLayout<Float>.size else {
            return nil
        }
        let healthy = data.withUnsafeBytes { raw -> Bool in
            for v in raw.bindMemory(to: Float.self) where !v.isFinite || v < -0.01 || v > 1.01 {
                return false
            }
            return true
        }
        return healthy ? data : nil
    }()

    /// `.hdrML`（ML/LUT 方式）の LUT が利用可能か。false のとき `.hdrML` は `.hdrCurve` へ降格する。
    /// UI が「ML/LUT を選んだが実際にはカーブ法で処理する」旨を事前にユーザーへ通知するために公開する。
    public static var isMLGainLUTAvailable: Bool { gainLUTData != nil }

    /// 正規化ゲイン g' を拡張レンジへ復元して乗算するカーネル。stock の multiply は >1.0 を
    /// クランプし得るため自前で `out = sdr * (1 + g' * (gmax-1))` を直接計算する。ソースは定数なので
    /// 変換ごとに再コンパイルせず一度だけ生成する（CIColorKernel(source:) の非推奨警告は既知・許容）。
    private static let expandLUTKernel: CIColorKernel? = CIColorKernel(source: """
    kernel vec4 gainforgeExpandLUT(__sample s, __sample g, float gmaxMinus1) {
        vec3 gain = vec3(1.0) + g.rgb * gmaxMinus1;
        return vec4(s.rgb * gain, s.a);
    }
    """)

    /// 統計 LUT を使って SDR CIImage から拡張レンジ HDR CIImage を合成する。
    ///
    /// - `CIColorCube` で「色 → 正規化ゲイン g'」を引く（検証済みの同梱 LUT データ）。
    /// - 自前カーネルで `out = sdr * (1 + g' * (gainLUTMax - 1))` を計算し 1.0 超へ伸ばす。
    /// - 暗部のゲインは LUT 構築時に輝度で減衰させてあり、黒浮きを避けている。
    /// - 作業空間は呼び出し元（`writeSynthesizedHDRHEIC`）の拡張リニア Display P3。LUT も同じ
    ///   空間で構築しているため色が整合する。ゲインは輝度でなく色そのもので引くため、
    ///   Apple の「色ごとの伸ばし方」を再現する（肌は控えめ、空・鮮やか色は伸びる）。
    private static func makeLUTExpandedHDR(_ sdr: CIImage, lutData: Data, input: URL) throws -> CIImage {
        guard let cubeFilter = CIFilter(name: "CIColorCube") else {
            throw GainForgeError.hdrSynthesisFailed(input)
        }
        cubeFilter.setValue(gainLUTGridN, forKey: "inputCubeDimension")
        cubeFilter.setValue(lutData, forKey: "inputCubeData")
        cubeFilter.setValue(sdr, forKey: kCIInputImageKey)
        guard let gPrime = cubeFilter.outputImage else {
            throw GainForgeError.hdrSynthesisFailed(input)
        }
        guard let kernel = expandLUTKernel,
              let out = kernel.apply(extent: sdr.extent,
                                     arguments: [sdr, gPrime, Float(gainLUTMax - 1.0)]) else {
            throw GainForgeError.hdrSynthesisFailed(input)
        }
        return out
    }

    /// 画像の平均輝度をリニア（拡張 Display P3）で 1x1 に縮約して返す（0.0–1.0 目安）。
    private static func meanLinearLuma(_ image: CIImage, context: CIContext) -> Double {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return 0.5 }
        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: extent),
        ])?.outputImage else { return 0.5 }

        var px = [Float](repeating: 0, count: 4)
        let linCS = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        px.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(avg, toBitmap: base, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: linCS)
        }
        let luma = 0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])
        return max(0.0, min(1.5, luma))
    }

    /// スカラー版 smoothstep（GLSL 準拠）。
    private static func smoothstepScalar(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }

    // MARK: - リサイズ（高品質リサンプル）

    /// CIImage をリサンプルする際の共有コンテキスト（色管理は既定＝リニア空間で高品質に補間）。
    /// 変換ごとに CIContext を作らず一度だけ生成する（バッチで枚数分の無駄を避ける）。
    private static let resizeContext = CIContext(options: nil)

    /// `CILanczosScaleTransform`（Core Image 最高品質のリサンプラ）で等方スケールした CIImage を返す。
    /// アスペクト比は変えない（`inputAspectRatio` = 1.0）。フィルタ生成に失敗したときはアフィン変換で代替。
    private static func lanczosResized(_ image: CIImage, scale: CGFloat) -> CIImage {
        guard scale != 1.0, let f = CIFilter(name: "CILanczosScaleTransform") else {
            return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(scale, forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return f.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// CGImage を Lanczos で目標サイズへ縮小した CGImage を返す（色空間は元画像のまま維持）。
    /// 生転写のベース画像用。ImageIO の 8bit ベースなので `.RGBA8` で描画する。
    ///
    /// 描画範囲は `target` 矩形ではなく **Lanczos 出力の実 extent** を使う。幅由来のスカラーで
    /// 縮小した像を、高さを独立に丸めた `target` で切り出すと 1px 未満のクロップ/パッドで
    /// SDR・合成経路（`sdr.extent` から描画）と挙動がずれるため、スケール後の実寸で揃える。
    private static func resizedCGImage(_ cg: CGImage, target: CGSize) throws -> CGImage {
        let ci = CIImage(cgImage: cg)
        let scaled = lanczosResized(ci, scale: target.width / CGFloat(cg.width))
        let cs = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let rect = scaled.extent.integral
        guard !rect.isEmpty, !rect.isInfinite,
              let out = resizeContext.createCGImage(scaled, from: rect, format: .RGBA8, colorSpace: cs) else {
            throw GainForgeError.baseImageUnreadable
        }
        return out
    }

    /// メタデータ辞書から旧ピクセル寸法キー（トップレベル + EXIF PixelX/YDimension）を除去する。
    /// リサイズ後に旧寸法が EXIF へ残ると一部ビューアが誤った寸法を表示するため、縮小時のみ通す。
    private static func strippingPixelDimensions(_ props: [String: Any]) -> [String: Any] {
        var p = props
        p.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        p.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            p[kCGImagePropertyExifDictionary as String] = exif
        }
        return p
    }

    // MARK: - ユーティリティ

    /// 出力先が書き込み可能か確認する。上書き不許可で既存ファイルがあれば `.outputExists` を投げる。
    /// 書き込み直前に判定して、事前計画の後に外部で現れた予期せぬ既存ファイルを弾く。
    private static func ensureWritable(_ output: URL, overwrite: Bool) throws {
        if !overwrite, FileManager.default.fileExists(atPath: output.path) {
            throw GainForgeError.outputExists(output)
        }
    }

    /// ファイルのバイト数を返す（取得不能時は 0）。
    public static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// 入力として受け付ける画像拡張子（小文字）。
    /// JPEG は生転写 / SDR 化の主対象、PNG はゲインマップ非対応の素 SDR 画像として SDR→HDR 補正で活きる。
    public static let supportedInputExtensions: Set<String> = ["jpg", "jpeg", "png"]

    /// フォルダを再帰探索し、対応拡張子（`*.jpg` / `*.jpeg` / `*.png`）の URL 一覧を返す。
    /// ファイル URL はそのまま 1 件返す。結果はパス順にソートする。
    public static func collectInputImages(_ url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return isSupportedImage(url) ? [url] : []
        }
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        var result: [URL] = []
        for case let f as URL in en where isSupportedImage(f) {
            result.append(f)
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func isSupportedImage(_ url: URL) -> Bool {
        supportedInputExtensions.contains(url.pathExtension.lowercased())
    }

    /// 出力先に同名 HEIC があれば連番（`_1`, `_2`, …）を付けた未使用 URL を返す（上書き回避）。
    public static func uniqueOutputURL(directory: URL, stem: String) -> URL {
        let fm = FileManager.default
        let base = directory.appendingPathComponent(stem + ".heic")
        if !fm.fileExists(atPath: base.path) { return base }
        var n = 1
        while true {
            let candidate = directory.appendingPathComponent("\(stem)_\(n).heic")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
