import XCTest
import Foundation
import ImageIO
import CoreImage
import CoreGraphics
import UniformTypeIdentifiers
@testable import GainForgeCore

/// 明部だけの色温度調整（`highlightWarmth`）と、それを保存する 3ch カラーゲインマップ経路のテスト。
///
/// 最重要の回帰は「強度 0（既定）のとき出力が従来と完全に一致すること」。
/// 強度 0 では CoreImage 自動生成（1ch）の従来経路をそのまま通ることで担保する。
final class HighlightWarmthTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("GainForgeWarmth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 純粋ロジック

    func testWarmthCoefficientClampsAndScales() {
        XCTAssertEqual(HighlightWarmth.coefficient(0), 0, accuracy: 1e-12)
        XCTAssertEqual(HighlightWarmth.coefficient(1.0), HighlightWarmth.maxCoefficient, accuracy: 1e-12)
        XCTAssertEqual(HighlightWarmth.coefficient(-1.0), -HighlightWarmth.maxCoefficient, accuracy: 1e-12)
        XCTAssertEqual(HighlightWarmth.coefficient(5.0), HighlightWarmth.maxCoefficient, accuracy: 1e-12,
                       "範囲外は 1.0 相当にクランプされること")
        XCTAssertEqual(HighlightWarmth.coefficient(-5.0), -HighlightWarmth.maxCoefficient, accuracy: 1e-12)
    }

    func testWarmthNeutralDetection() {
        XCTAssertTrue(HighlightWarmth.isNeutral(0))
        XCTAssertTrue(HighlightWarmth.isNeutral(1e-9))
        XCTAssertFalse(HighlightWarmth.isNeutral(0.01))
        XCTAssertFalse(HighlightWarmth.isNeutral(-0.01))
    }

    func testTintCoefficientClampsAndScales() {
        XCTAssertEqual(HighlightTint.coefficient(0), 0, accuracy: 1e-12)
        XCTAssertEqual(HighlightTint.coefficient(1.0), HighlightTint.maxCoefficient, accuracy: 1e-12)
        XCTAssertEqual(HighlightTint.coefficient(-1.0), -HighlightTint.maxCoefficient, accuracy: 1e-12)
        XCTAssertEqual(HighlightTint.coefficient(9.0), HighlightTint.maxCoefficient, accuracy: 1e-12)
        XCTAssertTrue(HighlightTint.isNeutral(0))
        XCTAssertFalse(HighlightTint.isNeutral(0.01))
    }

    /// 輝度中立の係数が「G を下げた分を R/B で取り戻す」比になっていること。
    func testTintLuminanceNeutralRatio() {
        let r = HighlightTint.luminanceNeutralRatio
        // 輝度 = 0.2126R + 0.7152G + 0.0722B。G を -m、R/B を +r·m 動かしたとき合計 0 になる。
        let delta = 0.2126 * r + 0.7152 * (-1.0) + 0.0722 * r
        XCTAssertEqual(delta, 0, accuracy: 1e-9, "輝度変化が打ち消し合うこと")
    }

    /// 正規化ゲインが ISO ゲインマップの復元式と往復で一致すること。
    func testNormalizedGainRoundTrip() {
        let maxLog2 = ColorGainMap.maxLog2
        for (base, gain) in [(0.2, 2.0), (0.5, 4.0), (0.8, 1.5), (0.05, 8.0)] {
            let alt = base * gain
            let v = ColorGainMap.normalizedGain(base: base, alternate: alt)
            // 復元: alt = (base + offset) * 2^(v * maxLog2) - offset
            let restored = (base + ColorGainMap.offset) * pow(2.0, v * maxLog2) - ColorGainMap.offset
            XCTAssertEqual(restored, alt, accuracy: alt * 0.01,
                           "base=\(base) gain=\(gain) の往復が 1% 以内で一致すること")
        }
    }

    func testNormalizedGainClamps() {
        XCTAssertEqual(ColorGainMap.normalizedGain(base: 0.5, alternate: 0.25), 0,
                       "ゲインが 1 未満（暗くなる）ときは 0 に潰れること")
        XCTAssertEqual(ColorGainMap.normalizedGain(base: 0.01, alternate: 100.0), 1,
                       "上限を超えるゲインは 1 にクランプされること")
    }

    /// 公開 API で色温度調整の可否を確認できること（false のときは 1ch 経路へ自動降格する）。
    func testHighlightWarmthAvailabilityIsExposed() {
        XCTAssertEqual(GainForge.isHighlightColorShiftAvailable, ColorGainMap.template != nil,
                       "公開 API が借用テンプレートの可否をそのまま反映すること")
        XCTAssertTrue(GainForge.isHighlightColorShiftAvailable,
                      "通常の macOS 環境では色温度調整が利用できること")
    }

    /// 借用テンプレート（CoreImage 生成 metadata）が解決できること。
    /// これが nil だとカラーゲインマップ経路は成立しない。
    func testColorGainMapTemplateIsAvailable() {
        XCTAssertNotNil(ColorGainMap.template, "ダミー書き出しから metadata と ColorSpace を借用できること")
        XCTAssertNotNil(ColorGainMap.makeMetadata(maxLog2: ColorGainMap.maxLog2),
                        "ChannelMetadata を差し替えた metadata を組み立てられること")
    }

    // MARK: - テスト用ヘルパー

    /// 中間調の背景（青寄り）と明るいハイライト（白円）を持つ SDR 画像を作る。
    private func makeSDRImage(_ name: String, type utType: UTType = .jpeg) throws -> URL {
        let w = 256, h = 192
        let cs = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw XCTSkip("CGContext を作成できません")
        }
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.35, 0.40, 0.45, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1.0, 1.0, 0.98, 1.0])!)
        ctx.fillEllipse(in: CGRect(x: 180, y: 120, width: 56, height: 56))
        guard let cg = ctx.makeImage() else { throw XCTSkip("CGImage を生成できません") }

        let url = tmp.appendingPathComponent(name)
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
            throw XCTSkip("画像出力先を作成できません")
        }
        var props: [String: Any] = [
            kCGImagePropertyOrientation as String: 1,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:07:04 12:00:00",
            ],
        ]
        if utType == .jpeg { props[kCGImageDestinationLossyCompressionQuality as String] = 0.9 }
        CGImageDestinationAddImage(dst, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw XCTSkip("画像を書き出せません") }
        return url
    }

    private func imageDepth(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        return props[kCGImagePropertyDepth as String] as? Int
    }

    /// HEIC を HDR として展開し、指定座標（左上原点）のリニア RGB を返す。
    private func hdrPixel(_ url: URL, x: Int, y: Int) throws -> (r: Float, g: Float, b: Float) {
        guard let image = CIImage(contentsOf: url, options: [.expandToHDR: true]),
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw XCTSkip("HDR として展開できません")
        }
        let w = Int(image.extent.width.rounded()), h = Int(image.extent.height.rounded())
        guard w > 0, h > 0, x < w, y < h else { throw XCTSkip("展開結果の寸法が不正です") }
        let ctx = CIContext(options: [.workingColorSpace: linear])
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress else { return }
            ctx.render(image, toBitmap: p, rowBytes: w * 16, bounds: image.extent,
                       format: .RGBAf, colorSpace: linear)
        }
        let i = (y * w + x) * 4
        return (buf[i], buf[i + 1], buf[i + 2])
    }

    // 画像内のサンプル座標（左上原点）。makeSDRImage の白円は CGContext 座標で
    // x:180 y:120 w:56 h:56 → 中心 (208, 148) は左上原点で (208, 192-148=44)。
    private let highlight = (x: 208, y: 44)
    private let midtone = (x: 30, y: 30)

    // MARK: - 強度 0（既定）は従来経路のまま

    /// 強度 0 では 3ch 経路に入らず、従来どおり CoreImage 自動生成の 1ch ゲインマップになること。
    func testNeutralWarmthKeepsMonochromeGainMapPath() throws {
        let input = try makeSDRImage("neutral.jpg")
        let out = tmp.appendingPathComponent("neutral.heic")
        _ = try GainForge.convert(input: input, output: out, quality: 0.7,
                                  force: true, sdrMode: .hdrCurve, highlightWarmth: 0.0)

        XCTAssertTrue(GainForge.hasGainMap(out))
        XCTAssertEqual(imageDepth(out), 10, "従来どおり 10bit であること")
        XCTAssertFalse(ColorGainMap.isColorGainMap(out),
                       "強度 0 では従来の 1ch（モノクロ）ゲインマップ経路を通ること")
    }

    /// 強度を省略した場合と 0 を明示した場合で、出力がバイト単位で一致すること。
    func testOmittedWarmthMatchesExplicitZeroByteForByte() throws {
        let input = try makeSDRImage("same.jpg")
        let a = tmp.appendingPathComponent("omitted.heic")
        let b = tmp.appendingPathComponent("explicit_zero.heic")
        _ = try GainForge.convert(input: input, output: a, quality: 0.7, force: true, sdrMode: .hdrCurve)
        _ = try GainForge.convert(input: input, output: b, quality: 0.7, force: true,
                                  sdrMode: .hdrCurve, highlightWarmth: 0.0)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b),
                       "省略時と 0 明示で出力が完全一致すること（既定挙動の不変性）")
    }

    /// `.sdr` では強度を与えても無視され、従来の 8bit SDR 保存のままであること。
    func testWarmthIsIgnoredInSDRMode() throws {
        let input = try makeSDRImage("sdr_mode.jpg")
        let out = tmp.appendingPathComponent("sdr_mode.heic")
        let result = try GainForge.convert(input: input, output: out, quality: 0.7,
                                           force: true, sdrMode: .sdr, highlightWarmth: 1.0)
        XCTAssertFalse(result.isHDR)
        XCTAssertFalse(GainForge.hasGainMap(out), "SDR 保存ではゲインマップを付けないこと")
        XCTAssertEqual(imageDepth(out), 8, "SDR 保存は 8bit のままであること")
    }

    /// ゲインマップの `AlternateHeadroom` を読む（取得できなければ nil）。
    private func alternateHeadroom(_ url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any],
              let meta = aux[kCGImageAuxiliaryDataInfoMetadata as String] else { return nil }
        let value = CGImageMetadataCopyStringValueWithPath(meta as! CGImageMetadata, nil,
                                                           "HDRToneMap:AlternateHeadroom" as CFString) as String?
        return value.flatMap(Double.init)
    }

    /// ゲイン上限を画像ごとに実測していること（固定値にすると表示時のゲインが丸ごと弱まる）。
    ///
    /// 回帰の対象: `AlternateHeadroom` を `maxLog2Ceiling` 固定にしていたため、実表示で
    /// 効果が約 1/3 に薄まっていた不具合（Docs/検証_明部の色調整.md）。
    func testGainMapHeadroomFollowsActualGainInsteadOfFixedCeiling() throws {
        let input = try makeSDRImage("headroom.jpg")
        let neutral = tmp.appendingPathComponent("hr_neutral.heic")
        let warm = tmp.appendingPathComponent("hr_warm.heic")
        _ = try GainForge.convert(input: input, output: neutral, quality: 0.8,
                                  force: true, sdrMode: .hdrCurve, highlightWarmth: 0.0)
        _ = try GainForge.convert(input: input, output: warm, quality: 0.8,
                                  force: true, sdrMode: .hdrCurve, highlightWarmth: 1.0)

        guard let hrNeutral = alternateHeadroom(neutral), let hrWarm = alternateHeadroom(warm) else {
            return XCTFail("AlternateHeadroom を読み取れません")
        }
        XCTAssertLessThan(hrWarm, ColorGainMap.maxLog2Ceiling * 0.95,
                          "上限値に張り付いていないこと（実測 \(hrWarm) / 上限 \(ColorGainMap.maxLog2Ceiling)）")
        XCTAssertGreaterThan(hrWarm, hrNeutral * 0.5,
                             "自動生成（\(hrNeutral)）と同程度のオーダーであること（実測 \(hrWarm)）")
        XCTAssertLessThan(hrWarm, hrNeutral * 2.0,
                          "自動生成（\(hrNeutral)）より極端に大きくないこと（実測 \(hrWarm)）")
    }

    /// 実測したゲイン上限がクランプ範囲に収まること。
    func testMeasuredMaxLog2StaysWithinBounds() throws {
        let input = try makeSDRImage("bounds.jpg")
        let out = tmp.appendingPathComponent("bounds.heic")
        _ = try GainForge.convert(input: input, output: out, quality: 0.8,
                                  force: true, sdrMode: .hdrCurve, highlightWarmth: 0.5)
        guard let hr = alternateHeadroom(out) else { return XCTFail("読み取れません") }
        XCTAssertGreaterThanOrEqual(hr, ColorGainMap.maxLog2Floor)
        XCTAssertLessThanOrEqual(hr, ColorGainMap.maxLog2Ceiling)
    }

    // MARK: - 強度あり（カラーゲインマップ経路）

    /// 強度を与えると 3ch カラーゲインマップになり、10bit とメタデータ引き継ぎを維持すること。
    func testWarmthProducesColorGainMapAndKeeps10bitAndMetadata() throws {
        let input = try makeSDRImage("warm.jpg")
        let out = tmp.appendingPathComponent("warm.heic")
        let result = try GainForge.convert(input: input, output: out, quality: 0.7,
                                           force: true, sdrMode: .hdrCurve, highlightWarmth: 1.0)

        XCTAssertTrue(result.isHDR)
        XCTAssertTrue(GainForge.hasGainMap(out), "自前添付でもゲインマップ検算を通ること")
        XCTAssertTrue(ColorGainMap.isColorGainMap(out), "ゲインマップがカラーのまま保存されること")
        XCTAssertEqual(imageDepth(out), 10, "ImageIO 経路でも 10bit（HEVC Main 10）を維持すること")

        guard let src = CGImageSourceCreateWithURL(out as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            return XCTFail("出力プロパティを取得できません")
        }
        XCTAssertNotNil(props[kCGImagePropertyExifDictionary as String], "EXIF が保持されていること")
    }

    /// 明部だけが暖色に振れ、中間調の色比はほとんど動かないこと（本機能の核心）。
    func testWarmthShiftsHighlightsOnly() throws {
        let input = try makeSDRImage("shift.jpg")
        let neutral = tmp.appendingPathComponent("shift_neutral.heic")
        let warm = tmp.appendingPathComponent("shift_warm.heic")
        _ = try GainForge.convert(input: input, output: neutral, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve, highlightWarmth: 0.0)
        _ = try GainForge.convert(input: input, output: warm, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve, highlightWarmth: 1.0)

        let hn = try hdrPixel(neutral, x: highlight.x, y: highlight.y)
        let hw = try hdrPixel(warm, x: highlight.x, y: highlight.y)
        let ratioN = Double(hn.r / max(hn.b, 1e-6))
        let ratioW = Double(hw.r / max(hw.b, 1e-6))
        XCTAssertGreaterThan(ratioW, ratioN * 1.05,
                             "明部の R/B 比が暖色側へ有意に増えること（\(ratioN) → \(ratioW)）")

        let mn = try hdrPixel(neutral, x: midtone.x, y: midtone.y)
        let mw = try hdrPixel(warm, x: midtone.x, y: midtone.y)
        let midN = Double(mn.r / max(mn.b, 1e-6))
        let midW = Double(mw.r / max(mw.b, 1e-6))
        XCTAssertEqual(midW, midN, accuracy: midN * 0.05,
                       "中間調の色比はほぼ変わらないこと（\(midN) → \(midW)）")
    }

    /// 負の強度では逆方向（寒色寄り）に振れること。
    func testNegativeWarmthShiftsCooler() throws {
        let input = try makeSDRImage("cool.jpg")
        let neutral = tmp.appendingPathComponent("cool_neutral.heic")
        let cool = tmp.appendingPathComponent("cool_cool.heic")
        _ = try GainForge.convert(input: input, output: neutral, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve, highlightWarmth: 0.0)
        _ = try GainForge.convert(input: input, output: cool, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve, highlightWarmth: -1.0)

        let hn = try hdrPixel(neutral, x: highlight.x, y: highlight.y)
        let hc = try hdrPixel(cool, x: highlight.x, y: highlight.y)
        XCTAssertLessThan(Double(hc.r / max(hc.b, 1e-6)), Double(hn.r / max(hn.b, 1e-6)),
                          "負の強度では明部の R/B 比が下がること")
    }

    // MARK: - ティント軸（マゼンタ⇔グリーン）

    /// 正のティントで明部がマゼンタ側（R,B 上昇・G 低下）へ寄ること。
    func testTintShiftsHighlightsTowardMagenta() throws {
        let input = try makeSDRImage("tint.jpg")
        let neutral = tmp.appendingPathComponent("tint_neutral.heic")
        let magenta = tmp.appendingPathComponent("tint_magenta.heic")
        _ = try GainForge.convert(input: input, output: neutral, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve, highlightTint: 0.0)
        _ = try GainForge.convert(input: input, output: magenta, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve, highlightTint: 1.0)

        XCTAssertTrue(ColorGainMap.isColorGainMap(magenta), "ティント指定でもカラーゲインマップになること")
        let n = try hdrPixel(neutral, x: highlight.x, y: highlight.y)
        let m = try hdrPixel(magenta, x: highlight.x, y: highlight.y)
        // マゼンタ = G に対する R,B の比が上がる
        XCTAssertGreaterThan(Double(m.r / max(m.g, 1e-6)), Double(n.r / max(n.g, 1e-6)) * 1.02,
                             "R/G 比が上がること（\(n.r/n.g) → \(m.r/m.g)）")
        XCTAssertGreaterThan(Double(m.b / max(m.g, 1e-6)), Double(n.b / max(n.g, 1e-6)) * 1.02,
                             "B/G 比が上がること（\(n.b/n.g) → \(m.b/m.g)）")
    }

    /// 負のティントでは逆（グリーン側）へ寄ること。
    func testNegativeTintShiftsTowardGreen() throws {
        let input = try makeSDRImage("green.jpg")
        let neutral = tmp.appendingPathComponent("green_neutral.heic")
        let green = tmp.appendingPathComponent("green_green.heic")
        _ = try GainForge.convert(input: input, output: neutral, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve, highlightTint: 0.0)
        _ = try GainForge.convert(input: input, output: green, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve, highlightTint: -1.0)
        let n = try hdrPixel(neutral, x: highlight.x, y: highlight.y)
        let g = try hdrPixel(green, x: highlight.x, y: highlight.y)
        XCTAssertLessThan(Double(g.r / max(g.g, 1e-6)), Double(n.r / max(n.g, 1e-6)),
                          "R/G 比が下がること")
    }

    /// ティントが輝度中立であること（明部の明るさが変わらない）。
    func testTintKeepsHighlightLuminance() throws {
        let input = try makeSDRImage("lumi.jpg")
        let neutral = tmp.appendingPathComponent("lumi_neutral.heic")
        let magenta = tmp.appendingPathComponent("lumi_magenta.heic")
        _ = try GainForge.convert(input: input, output: neutral, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve, highlightTint: 0.0)
        _ = try GainForge.convert(input: input, output: magenta, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve, highlightTint: 1.0)
        func luma(_ p: (r: Float, g: Float, b: Float)) -> Double {
            Double(0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b)
        }
        let ln = luma(try hdrPixel(neutral, x: highlight.x, y: highlight.y))
        let lm = luma(try hdrPixel(magenta, x: highlight.x, y: highlight.y))
        XCTAssertEqual(lm, ln, accuracy: ln * 0.03,
                       "明部の輝度が 3% 以内で保たれること（\(ln) → \(lm)）")
    }

    /// 色温度とティントを同時に指定でき、両方の効果が乗ること。
    func testWarmthAndTintCombine() throws {
        let input = try makeSDRImage("both.jpg")
        let neutral = tmp.appendingPathComponent("both_neutral.heic")
        let both = tmp.appendingPathComponent("both_shift.heic")
        _ = try GainForge.convert(input: input, output: neutral, quality: 0.9,
                                  force: true, sdrMode: .hdrCurve)
        _ = try GainForge.convert(input: input, output: both, quality: 0.9, force: true,
                                  sdrMode: .hdrCurve, highlightWarmth: 1.0, highlightTint: 1.0)
        let n = try hdrPixel(neutral, x: highlight.x, y: highlight.y)
        let b = try hdrPixel(both, x: highlight.x, y: highlight.y)
        XCTAssertGreaterThan(Double(b.r / max(b.b, 1e-6)), Double(n.r / max(n.b, 1e-6)) * 1.05,
                             "色温度軸が効いていること（R/B 比の上昇）")
        XCTAssertGreaterThan(Double(b.b / max(b.g, 1e-6)), Double(n.b / max(n.g, 1e-6)) * 1.02,
                             "ティント軸が効いていること（B/G 比の上昇）")
    }

    /// ティントだけ 0 でない場合も従来経路には入らないこと（分岐条件の回帰）。
    func testTintAloneSwitchesToColorGainMapPath() throws {
        let input = try makeSDRImage("tint_only.jpg")
        let out = tmp.appendingPathComponent("tint_only.heic")
        _ = try GainForge.convert(input: input, output: out, quality: 0.8, force: true,
                                  sdrMode: .hdrCurve, highlightWarmth: 0.0, highlightTint: 0.5)
        XCTAssertTrue(ColorGainMap.isColorGainMap(out),
                      "ティントだけ指定してもカラーゲインマップ経路に入ること")
    }

    /// 両方 0 のときは従来どおり 1ch 経路（既定挙動の不変性）。
    func testBothZeroKeepsLegacyPath() throws {
        let input = try makeSDRImage("both_zero.jpg")
        let a = tmp.appendingPathComponent("bz_omitted.heic")
        let b = tmp.appendingPathComponent("bz_explicit.heic")
        _ = try GainForge.convert(input: input, output: a, quality: 0.7, force: true, sdrMode: .hdrCurve)
        _ = try GainForge.convert(input: input, output: b, quality: 0.7, force: true, sdrMode: .hdrCurve,
                                  highlightWarmth: 0.0, highlightTint: 0.0)
        XCTAssertFalse(ColorGainMap.isColorGainMap(b), "両方 0 なら 1ch 経路のままであること")
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b), "出力が完全一致すること")
    }

    /// `.hdrML`（LUT 方式）でも強度が効き、カラーゲインマップ経路を通ること。
    func testWarmthWorksInMLMode() throws {
        try XCTSkipUnless(GainForge.isMLGainLUTAvailable, "LUT 未同梱の環境では ML 経路を検証できない")
        let input = try makeSDRImage("ml_warm.jpg")
        let out = tmp.appendingPathComponent("ml_warm.heic")
        let result = try GainForge.convert(input: input, output: out, quality: 0.7,
                                           force: true, sdrMode: .hdrML, highlightWarmth: 1.0)
        XCTAssertTrue(result.isHDR)
        XCTAssertTrue(ColorGainMap.isColorGainMap(out), "ML 方式でもカラーゲインマップになること")
        XCTAssertEqual(imageDepth(out), 10)
    }

    /// リサイズ指定と併用してもカラーゲインマップ経路が成立すること。
    func testWarmthWithResize() throws {
        let input = try makeSDRImage("warm_resize.jpg")   // 256x192
        let out = tmp.appendingPathComponent("warm_resize.heic")
        _ = try GainForge.convert(input: input, output: out, quality: 0.7, force: true,
                                  sdrMode: .hdrCurve, resize: .fitWidth(128), highlightWarmth: 1.0)
        XCTAssertTrue(ColorGainMap.isColorGainMap(out))
        guard let src = CGImageSourceCreateWithURL(out as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int else {
            return XCTFail("出力寸法を取得できません")
        }
        XCTAssertEqual(w, 128, "リサイズ指定が効くこと")
    }
}
