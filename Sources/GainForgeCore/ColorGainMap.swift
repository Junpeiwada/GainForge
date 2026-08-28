// ColorGainMap.swift
// SDR→HDR 合成で「3ch カラーゲインマップ」を自前で作り、ISO ゲインマップとして添付する。
//
// なぜ必要か:
//   CoreImage の `writeHEIF10Representation(of:options:[.hdrImage:])` が生成するゲインマップは
//   **1ch モノクロ**（PixelFormat 'L008' / ChannelMetadata 1要素）で、チャンネルごとの差は輝度に
//   平均化されて消える。つまり「明部だけ色温度を下げる」ような per-channel の色シフトは
//   自動生成経路では一切保存できない（実測確認済み）。
//   ISO ゲインマップ自体はカラーを扱えるため、生転写と同じ ImageIO 低レベル経路
//   （`CGImageDestinationAddAuxiliaryDataInfo`）で 3ch(32BGRA) を自前添付する。
//
// metadata の扱い（ここが最大の落とし穴）:
//   ゲインマップ metadata を**ゼロから自作すると `CGImageDestinationFinalize` が false になる**。
//   そのため CoreImage に一度だけ小さなダミーを書かせて正規の metadata を借り、
//   `ChannelMetadata` を配列タグごと差し替えて `GainMapMin/Max` を任意値に設定する
//   （個別タグへの `CGImageMetadataSetValueWithPath` は構造体配列内では効かない。これも実測）。

import Foundation
import CoreImage
import ImageIO
import CoreVideo

/// 明部の色温度調整（暖色シフト）の強度。
///
/// UI / CLI が扱う -1.0…1.0（正で色温度を下げる＝暖色）を、カーネルへ渡す内部係数に変換する。
/// 内部係数 k は `tint = vec3(1 + k*t, 1, 1 - k*t)`（t は明部加重）として per-channel に掛かる。
enum HighlightWarmth {

    /// 強度 1.0 のときの内部係数。実測では k=0.25 で明部の R:B が約 2 倍差となり強すぎたため、
    /// 「少し暖色に寄せる」範囲に収まるよう控えめに取る。
    static let maxCoefficient: Double = 0.15

    /// 強度が実質ゼロか（この場合は従来の CoreImage 自動生成経路をそのまま通す）。
    static func isNeutral(_ warmth: Double) -> Bool { abs(warmth) < 1.0e-6 }

    /// 強度（-1.0…1.0 にクランプ）を内部係数へ変換する。
    static func coefficient(_ warmth: Double) -> Double {
        min(max(warmth, -1.0), 1.0) * maxCoefficient
    }
}

/// 明部のティント調整（マゼンタ⇔グリーン）の強度。
///
/// UI / CLI が扱う -1.0…1.0（正でマゼンタ、負でグリーン）を、カーネルへ渡す内部係数に変換する。
/// 内部係数 m は `tint = vec3(1 + r·m·t, 1 − m·t, 1 + r·m·t)`（t は明部加重）として per-channel に掛かる。
/// 色温度軸（[HighlightWarmth]）とは独立した 2 軸目で、両者の tint は掛け合わせる。
enum HighlightTint {

    /// 輝度中立のための R/B 係数。G を `m` 下げた分の輝度を R と B で取り戻す倍率で、
    /// `0.7152 / (0.2126 + 0.0722)` = G の輝度加重 ÷ (R+B) の輝度加重。
    /// これにより明部の**明るさは変えずに色だけ**マゼンタ／グリーンへ寄せられる。
    static let luminanceNeutralRatio: Double = 0.7152 / (0.2126 + 0.0722)

    /// 強度 1.0 のときの内部係数（G を 6% 下げ、R/B を約 15% 上げる）。
    /// 色温度軸（`HighlightWarmth.maxCoefficient` = 0.15 で R/B を ±15%）と効きの強さを揃えている。
    static let maxCoefficient: Double = 0.06

    /// 強度が実質ゼロか。
    static func isNeutral(_ tint: Double) -> Bool { abs(tint) < 1.0e-6 }

    /// 強度（-1.0…1.0 にクランプ）を内部係数へ変換する。
    static func coefficient(_ tint: Double) -> Double {
        min(max(tint, -1.0), 1.0) * maxCoefficient
    }
}

/// SDR ベースと合成 HDR の差分から 3ch カラーゲインマップを作る（`.hdrCurve` / `.hdrML` 共用）。
enum ColorGainMap {

    /// ゲイン上限（log2）の**上限クランプ**。
    ///
    /// 実際に使う値は画像ごとに `measureMaxLog2` で実測する（下記）。これはその安全上限で、
    /// 合成側が出し得る最大ゲイン（LUT 法の `gainLUTMax` = 8x）に暖色シフト分
    /// （`1 + HighlightWarmth.maxCoefficient`）を掛けた `log2(9.2) ≈ 3.20` を切り上げた値。
    static let maxLog2Ceiling: Double = 3.25

    /// ゲイン上限の下限クランプ。ゲインがほぼ無い画像で 0 除算・過大な量子化誤差を避ける。
    static let maxLog2Floor: Double = 0.25

    /// 実測に失敗したときのフォールバック上限。
    static let maxLog2: Double = 3.25

    /// `measureMaxLog2` が使う内部スケール。`CIAreaMaximum` の出力が [0,1] にクランプされても
    /// 値を失わないよう、log2 ゲインをこの値で割ってから最大を取り、後で掛け戻す。
    private static let measureScale: Double = 8.0

    /// ISO ゲインマップの base/alternate オフセット。CoreImage が生成する metadata と同じ値を使い、
    /// ゲイン計算式（`log2((alt+offset)/(base+offset))`）を復元側と一致させる。
    static let offset: Double = 1.0e-5

    // MARK: - 純粋ロジック（UI 非依存・テスト可能）

    /// ベース値と HDR 値から、ゲインマップに格納する正規化ゲイン（0…1）を求める。
    ///
    /// ISO ゲインマップの復元式 `alt = (base + offset) * 2^(min + (max-min)*v) - offset` の逆。
    /// `min = 0` 固定なので `v = log2((alt+offset)/(base+offset)) / max` になる。
    /// 暗部で分母が 0 に潰れないよう `offset` を足し、範囲外は 0…1 にクランプする。
    static func normalizedGain(base: Double, alternate: Double, maxLog2: Double = maxLog2) -> Double {
        guard maxLog2 > 0 else { return 0 }
        let b = max(base, 0) + offset
        let a = max(alternate, 0) + offset
        let g = log2(a / b) / maxLog2
        return min(max(g, 0), 1)
    }

    // MARK: - metadata

    /// CoreImage に小さなダミーを書かせて、正規のゲインマップ metadata と ColorSpace を借りる。
    ///
    /// バッチで毎回書き出さないよう一度だけ評価する。ダミーは 32×32 のグレーグラデで、
    /// 暗部は等倍・明部だけ伸ばしてある。**得られた値そのものは使わず** `makeMetadata` で
    /// 画像ごとの実測値へ差し替えるので、ここでは「正規の器」が手に入ればよい。
    /// 保持するのは読み取り専用の借用元。使うときは必ず `CGImageMetadataCreateMutableCopy` して
    /// コピーを書き換えるため、共有インスタンスが変更されることはない（並列変換でも安全）。
    nonisolated(unsafe) static let template: (metadata: CGImageMetadata, colorSpace: CGColorSpace)? = {
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let v = UInt8(Double(x) / Double(n - 1) * 255)
                let i = (y * n + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let provider = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: n * 4, space: p3,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent),
              let kernel = CIColorKernel(source: """
              kernel vec4 gainforgeTemplate(__sample s, float m) {
                  float l = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
                  return vec4(s.rgb * (1.0 + (m - 1.0) * smoothstep(0.05, 0.20, l)), s.a);
              }
              """)
        else { return nil }

        let sdr = CIImage(cgImage: cg)
        guard let hdr = kernel.apply(extent: sdr.extent, arguments: [sdr, Float(pow(2.0, maxLog2))]) else {
            return nil
        }
        let ctx = CIContext(options: [.workingColorSpace: linear])
        guard let data = try? ctx.heif10Representation(of: sdr, colorSpace: p3, options: [.hdrImage: hdr]),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any],
              let meta = aux[kCGImageAuxiliaryDataInfoMetadata as String],
              let csValue = aux[kCGImageAuxiliaryDataInfoColorSpace as String],
              CFGetTypeID(csValue as CFTypeRef) == CGColorSpace.typeID
        else { return nil }
        return (meta as! CGImageMetadata, csValue as! CGColorSpace)
    }()

    /// 借用 metadata の `ChannelMetadata` を差し替え、ゲイン範囲を `0…maxLog2` に設定した metadata を作る。
    ///
    /// `ChannelMetadata` は1要素のままでよい（3ch データを添付しても全チャンネル共通のパラメータとして
    /// 解釈され、色は保持される。実測確認済み）。`AlternateHeadroom` も同じ値へ合わせる。
    static func makeMetadata(maxLog2: Double) -> CGImageMetadata? {
        guard let base = template?.metadata,
              let md = CGImageMetadataCreateMutableCopy(base) else { return nil }

        let ns = "http://ns.apple.com/HDRToneMap/1.0/" as CFString
        let prefix = "HDRToneMap" as CFString
        func tag(_ name: String, _ type: CGImageMetadataType, _ value: Any) -> CGImageMetadataTag? {
            CGImageMetadataTagCreate(ns, prefix, name as CFString, type, value as CFTypeRef)
        }
        guard let minTag = tag("GainMapMin", .default, "0.000000"),
              let maxTag = tag("GainMapMax", .default, String(format: "%f", maxLog2)),
              let gammaTag = tag("Gamma", .default, "1.000000"),
              let baseOffsetTag = tag("BaseOffset", .default, String(format: "%f", offset)),
              let altOffsetTag = tag("AlternateOffset", .default, String(format: "%f", offset)),
              let channel = tag("[0]", .structure, [
                  "GainMapMin": minTag,
                  "GainMapMax": maxTag,
                  "Gamma": gammaTag,
                  "BaseOffset": baseOffsetTag,
                  "AlternateOffset": altOffsetTag,
              ] as [String: Any]),
              let array = tag("ChannelMetadata", .arrayOrdered, [channel] as CFArray),
              CGImageMetadataSetTagWithPath(md, nil, "HDRToneMap:ChannelMetadata" as CFString, array)
        else { return nil }

        // ゲインマップを完全適用したときのヘッドルーム。ゲイン上限に合わせておく。
        guard CGImageMetadataSetValueWithPath(md, nil, "HDRToneMap:AlternateHeadroom" as CFString,
                                              String(format: "%f", maxLog2) as CFString) else {
            return nil
        }
        return md
    }

    // MARK: - ゲインマップ本体

    /// log2 ゲインを `measureScale` で割って [0,1] に収めるカーネル（最大値の実測用）。
    /// `CIAreaMaximum` は出力を [0,1] にクランプし得るため、スケールしてから最大を取る。
    private static let logGainKernel: CIColorKernel? = CIColorKernel(source: """
    kernel vec4 gainforgeLogGain(__sample b, __sample a, float offset, float invScale) {
        vec3 base = max(b.rgb, 0.0) + vec3(offset);
        vec3 alt  = max(a.rgb, 0.0) + vec3(offset);
        vec3 g = max(log2(alt / base), vec3(0.0)) * invScale;
        return vec4(clamp(g, 0.0, 1.0), 1.0);
    }
    """)

    /// この画像で実際に必要なゲイン上限（log2）を測る。
    ///
    /// **これを固定値にしてはいけない**。ISO ゲインマップの適用重みは
    /// `w = log2(表示ヘッドルーム) / AlternateHeadroom` で決まるため、実際の最大ゲインより
    /// 大きな上限を宣言すると、その比の分だけ**表示時のゲインが丸ごと弱まる**
    /// （実測: 上限 3.25 固定にしたところ、本来 1.10 で足りる画像で効果が約 1/3 に薄まった）。
    /// CoreImage の自動生成も画像ごとに実測した値を入れている。
    static func measureMaxLog2(base: CIImage, hdr: CIImage, context: CIContext) -> Double {
        guard let kernel = logGainKernel,
              let logGain = kernel.apply(extent: base.extent,
                                         arguments: [base, hdr, Float(offset), Float(1.0 / measureScale)]),
              let maxFilter = CIFilter(name: "CIAreaMaximum", parameters: [
                  kCIInputImageKey: logGain,
                  kCIInputExtentKey: CIVector(cgRect: base.extent),
              ]),
              let reduced = maxFilter.outputImage
        else { return maxLog2 }

        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress else { return }
            context.render(reduced, toBitmap: p, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        let peak = Double(max(px[0], max(px[1], px[2]))) * measureScale
        guard peak.isFinite else { return maxLog2 }
        return min(max(peak, maxLog2Floor), maxLog2Ceiling)
    }

    /// ベースと HDR の比を正規化ゲインへ変換するカーネル。
    /// 作業空間（拡張リニア Display P3）で走らせ、出力は色変換せずそのまま量子化する。
    private static let gainMapKernel: CIColorKernel? = CIColorKernel(source: """
    kernel vec4 gainforgeGainMap(__sample b, __sample a, float invMax, float offset) {
        vec3 base = max(b.rgb, 0.0) + vec3(offset);
        vec3 alt  = max(a.rgb, 0.0) + vec3(offset);
        vec3 g = log2(alt / base) * invMax;
        return vec4(clamp(g, 0.0, 1.0), 1.0);
    }
    """)

    /// SDR ベースと合成 HDR から、HEIC に添付する ISO ゲインマップ補助辞書を組み立てる。
    ///
    /// - Parameters:
    ///   - base: SDR ベース（作業空間のリニア値としてカーネルに入る）。
    ///   - hdr: 合成した拡張レンジ HDR。`base` と同じ extent であること。
    ///   - context: 作業空間が拡張リニア Display P3 の `CIContext`。
    /// - Returns: `CGImageDestinationAddAuxiliaryDataInfo` にそのまま渡せる辞書。
    static func auxiliaryInfo(base: CIImage, hdr: CIImage, context: CIContext) throws -> [String: Any] {
        let extent = base.extent
        let w = Int(extent.width.rounded())
        let h = Int(extent.height.rounded())
        guard w > 0, h > 0 else { throw GainForgeError.gainMapEmpty }

        // ゲイン上限はこの画像の実測値を使う（固定値だと表示時のゲインが丸ごと弱まる）。
        let peakLog2 = measureMaxLog2(base: base, hdr: hdr, context: context)

        guard let kernel = gainMapKernel,
              let gainCI = kernel.apply(extent: extent,
                                        arguments: [base, hdr, Float(1.0 / peakLog2), Float(offset)]),
              let metadata = makeMetadata(maxLog2: peakLog2),
              let colorSpace = template?.colorSpace
        else { throw GainForgeError.colorGainMapFailed }

        // BGRA8 は 1 画素 4 バイトなので rowBytes は常に 4 の倍数（パディング不要）。
        // colorSpace に nil を渡し、作業空間で計算した正規化ゲインを色変換せずそのまま量子化する。
        let bytesPerRow = w * 4
        var data = Data(count: bytesPerRow * h)
        data.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            context.render(gainCI, toBitmap: ptr, rowBytes: bytesPerRow,
                           bounds: extent, format: .BGRA8, colorSpace: nil)
        }

        return [
            kCGImageAuxiliaryDataInfoData as String: data as CFData,
            kCGImageAuxiliaryDataInfoDataDescription as String: [
                "PixelFormat": Int(kCVPixelFormatType_32BGRA),
                "BytesPerRow": bytesPerRow,
                "Width": w,
                "Height": h,
            ],
            kCGImageAuxiliaryDataInfoMetadata as String: metadata,
            kCGImageAuxiliaryDataInfoColorSpace as String: colorSpace,
        ]
    }

    /// 書き出した HEIC のゲインマップがカラー（モノクロでない）であることを検算する。
    ///
    /// 添付は成功しても保存段で 1ch へ落とされていないかを確認する（落とし穴6 と同趣旨）。
    /// ImageIO は 3ch を 4:2:0 YCbCr（`'420f'` 等）へ変換して保存するため、
    /// 輝度のみの `'L008'` でないことをもって判定する。
    static func isColorGainMap(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any],
              let desc = aux[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any],
              let format = desc["PixelFormat"] as? Int
        else { return false }
        // 'L008'（8bit Luminance）= モノクロ。それ以外（4:2:0 等）はクロマを持つ。
        let monochrome = Int(0x4C303038)
        return format != monochrome
    }
}
