import XCTest
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import GainForgeCore

final class GainForgeCoreTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("GainForgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func touch(_ name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? tmp).appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    // MARK: - collectInputImages

    func testCollectInputImagesFindsJpgJpegPngRecursively() throws {
        _ = try touch("a.jpg")
        _ = try touch("b.JPEG")
        _ = try touch("c.png")
        _ = try touch("d.gif")   // 非対応拡張子は拾わない
        let sub = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try touch("e.jpeg", in: sub)
        _ = try touch("f.PNG", in: sub)

        let found = GainForge.collectInputImages(tmp).map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(found, ["a.jpg", "b.JPEG", "c.png", "e.jpeg", "f.PNG"])
    }

    func testCollectInputImagesOnSingleFile() throws {
        let jpg = try touch("only.jpg")
        XCTAssertEqual(GainForge.collectInputImages(jpg), [jpg])
        let png = try touch("only.png")
        XCTAssertEqual(GainForge.collectInputImages(png), [png])
        let gif = try touch("only.gif")
        XCTAssertEqual(GainForge.collectInputImages(gif), [])
    }

    func testCollectInputImagesOnMissingPath() {
        let missing = tmp.appendingPathComponent("nope.jpg")
        XCTAssertEqual(GainForge.collectInputImages(missing), [])
    }

    // MARK: - uniqueOutputURL（連番付与・上書き回避）

    func testUniqueOutputURLWhenFree() {
        let url = GainForge.uniqueOutputURL(directory: tmp, stem: "DSC001")
        XCTAssertEqual(url.lastPathComponent, "DSC001.heic")
    }

    func testUniqueOutputURLAddsSuffixOnCollision() throws {
        _ = try touch("DSC001.heic")
        let url1 = GainForge.uniqueOutputURL(directory: tmp, stem: "DSC001")
        XCTAssertEqual(url1.lastPathComponent, "DSC001_1.heic")

        _ = try touch("DSC001_1.heic")
        let url2 = GainForge.uniqueOutputURL(directory: tmp, stem: "DSC001")
        XCTAssertEqual(url2.lastPathComponent, "DSC001_2.heic")
    }

    // MARK: - hasGainMap（非画像は false）

    func testHasGainMapOnNonImage() throws {
        let txt = try touch("note.txt")
        XCTAssertFalse(GainForge.hasGainMap(txt))
    }

    // MARK: - ConversionResult

    func testSizeRatio() {
        let r = ConversionResult(outputURL: tmp, inputBytes: 1000, outputBytes: 600, isHDR: true)
        XCTAssertEqual(r.sizeRatio ?? 0, 0.6, accuracy: 0.0001)
    }

    func testSizeRatioZeroInput() {
        let r = ConversionResult(outputURL: tmp, inputBytes: 0, outputBytes: 600, isHDR: false)
        XCTAssertNil(r.sizeRatio)
    }

    // MARK: - convert（ゲインマップ無しは noGainMap を投げる）

    func testConvertThrowsNoGainMapWhenNotForcedOnNonImage() throws {
        let fake = try touch("fake.jpg")
        let out = tmp.appendingPathComponent("fake.heic")
        XCTAssertThrowsError(try GainForge.convert(input: fake, output: out, force: false)) { error in
            guard case GainForgeError.noGainMap = error else {
                return XCTFail("noGainMap を期待: \(error)")
            }
        }
    }

    // MARK: - 実画像での E2E（フィクスチャがある場合のみ）

    /// 環境変数 GAINFORGE_TEST_JPEG にゲインマップ付き JPEG パスを指定すると
    /// 実変換と検算まで通す。未設定時はスキップ。
    func testEndToEndConversionIfFixtureProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["GAINFORGE_TEST_JPEG"] else {
            throw XCTSkip("GAINFORGE_TEST_JPEG 未設定のためスキップ")
        }
        let input = URL(fileURLWithPath: path)
        XCTAssertTrue(GainForge.hasGainMap(input), "フィクスチャはゲインマップ付きであること")
        let out = tmp.appendingPathComponent("e2e.heic")
        let result = try GainForge.convert(input: input, output: out, quality: 0.6)
        XCTAssertTrue(result.isHDR)
        XCTAssertGreaterThan(result.outputBytes, 0)
        XCTAssertTrue(GainForge.hasGainMap(out), "出力にゲインマップが埋め込まれていること")

        // メタデータ（EXIF/TIFF/GPS/Orientation）が元画像から引き継がれていること。
        let inProps = imageProperties(input)
        let outProps = imageProperties(out)
        for dictKey in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyGPSDictionary] as [CFString] {
            let key = dictKey as String
            if let inDict = inProps[key] as? [String: Any], !inDict.isEmpty {
                let outDict = outProps[key] as? [String: Any] ?? [:]
                XCTAssertFalse(outDict.isEmpty, "出力に \(key) が引き継がれていること")
            }
        }
        if let inOri = inProps[kCGImagePropertyOrientation as String] {
            XCTAssertEqual("\(inOri)", "\(outProps[kCGImagePropertyOrientation as String] ?? "")",
                           "Orientation が保持されていること")
        }
    }

    /// 画像ファイルの先頭イメージのプロパティ辞書を取得する（テスト用ヘルパ）。
    private func imageProperties(_ url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            return [:]
        }
        return props
    }

    /// 画像ファイルの先頭イメージの 1 チャンネルあたりビット数を返す（取得不能時は nil）。
    private func imageDepth(_ url: URL) -> Int? {
        imageProperties(url)[kCGImagePropertyDepth as String] as? Int
    }

    // MARK: - SDR→HDR 合成（明部加重カーブ）

    /// 明るいハイライトと（JPEG のみ）EXIF/Orientation を持つ合成 SDR 画像を作る（フィクスチャ不要）。
    /// `utType` に `UTType.jpeg` / `UTType.png` を渡して形式を選ぶ。
    private func makeSDRImage(_ name: String, type utType: UTType = .jpeg,
                             orientation: Int = 6) throws -> URL {
        let w = 256, h = 192
        let cs = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw XCTSkip("CGContext を作成できません")
        }
        // 中間調の背景 + 明るいハイライト（白い円 = 太陽/鏡面反射相当）。
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
            kCGImagePropertyOrientation as String: orientation,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:07:04 12:00:00",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "GainForgeTest",
            ],
        ]
        if utType == .jpeg { props[kCGImageDestinationLossyCompressionQuality as String] = 0.9 }
        CGImageDestinationAddImage(dst, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw XCTSkip("画像を書き出せません") }
        return url
    }

    /// SDR→HDR カーブ変換でゲインマップが埋め込まれ、EXIF/Orientation が保持されること。
    func testSDRtoHDRCurveEmbedsGainMapAndPreservesMetadata() throws {
        let input = try makeSDRImage("sdr.jpg", type: .jpeg, orientation: 6)
        XCTAssertFalse(GainForge.hasGainMap(input), "入力はゲインマップ無しであること")

        let out = tmp.appendingPathComponent("sdr_hdr.heic")
        let result = try GainForge.convert(input: input, output: out, quality: 0.7,
                                           force: true, sdrMode: .hdrCurve)

        XCTAssertTrue(result.isHDR, "合成出力は HDR 扱いであること")
        XCTAssertGreaterThan(result.outputBytes, 0)
        XCTAssertTrue(GainForge.hasGainMap(out), "SDR→HDR 合成でゲインマップが埋め込まれること")
        XCTAssertEqual(imageDepth(out), 10, "HDR 合成出力は 10bit（HEVC Main 10）で書き出されること")

        let inP = imageProperties(input)
        let outP = imageProperties(out)
        XCTAssertEqual("\(outP[kCGImagePropertyOrientation as String] ?? "")",
                       "\(inP[kCGImagePropertyOrientation as String] ?? "")",
                       "Orientation が保持されていること")
        XCTAssertNotNil(outP[kCGImagePropertyExifDictionary as String], "EXIF が保持されていること")
    }

    /// `.sdr` 指定ではゲインマップを生成しない（従来の SDR HEIC 経路）。
    func testSDRModeKeepsSDR() throws {
        let input = try makeSDRImage("plain.jpg", type: .jpeg, orientation: 1)
        let out = tmp.appendingPathComponent("plain.heic")
        let result = try GainForge.convert(input: input, output: out, quality: 0.7,
                                           force: true, sdrMode: .sdr)
        XCTAssertFalse(result.isHDR)
        XCTAssertFalse(GainForge.hasGainMap(out), "SDR 指定ではゲインマップを付けないこと")
        XCTAssertEqual(imageDepth(out), 8, "SDR 保存は従来どおり 8bit のままであること")
    }

    /// PNG 入力でも SDR→HDR カーブ変換でゲインマップが埋め込まれること。
    /// PNG はゲインマップ非対応の素 SDR 画像で、この機能の自然な入力。
    func testPNGInputToHDRCurveEmbedsGainMap() throws {
        let input = try makeSDRImage("sdr.png", type: .png, orientation: 1)
        XCTAssertFalse(GainForge.hasGainMap(input), "PNG 入力はゲインマップ無し")

        let out = tmp.appendingPathComponent("sdr_png.heic")
        let result = try GainForge.convert(input: input, output: out, quality: 0.7,
                                           force: true, sdrMode: .hdrCurve)
        XCTAssertTrue(result.isHDR)
        XCTAssertTrue(GainForge.hasGainMap(out), "PNG からの SDR→HDR 合成でもゲインマップが埋め込まれること")
    }

    // MARK: - SDR→HDR 合成（Apple 学習 LUT / .hdrML）

    /// 同梱の学習 LUT が SwiftPM リソース（`Bundle.module`）として解決・検証できること。
    /// これが false だと `.hdrML` はカーブ法へ降格する（`writeMLExpandedHDRHEIC`）。
    func testMLGainLUTIsBundledAndValid() {
        XCTAssertTrue(GainForge.isMLGainLUTAvailable,
                      "同梱 LUT が Bundle.module から解決でき、サイズ・値の検証を通ること")
    }

    /// `.hdrML`（Apple 学習 LUT 方式）でもゲインマップが埋め込まれ、10bit で書き出され、
    /// EXIF/Orientation が保持されること。第3の変換経路の回帰を固定する。
    func testSDRtoHDRMLEmbedsGainMapAndIs10bit() throws {
        try XCTSkipUnless(GainForge.isMLGainLUTAvailable, "LUT 未同梱の環境では ML 経路を検証できない")

        let input = try makeSDRImage("sdr_ml.jpg", type: .jpeg, orientation: 6)
        XCTAssertFalse(GainForge.hasGainMap(input), "入力はゲインマップ無しであること")

        let out = tmp.appendingPathComponent("sdr_ml.heic")
        let result = try GainForge.convert(input: input, output: out, quality: 0.7,
                                           force: true, sdrMode: .hdrML)

        XCTAssertTrue(result.isHDR, "ML/LUT 合成出力は HDR 扱いであること")
        XCTAssertTrue(GainForge.hasGainMap(out), "ML/LUT 合成でゲインマップが埋め込まれること")
        XCTAssertEqual(imageDepth(out), 10, "ML/LUT 合成出力も 10bit（HEVC Main 10）で書き出されること")

        let inP = imageProperties(input)
        let outP = imageProperties(out)
        XCTAssertEqual("\(outP[kCGImagePropertyOrientation as String] ?? "")",
                       "\(inP[kCGImagePropertyOrientation as String] ?? "")",
                       "Orientation が保持されていること")
        XCTAssertNotNil(outP[kCGImagePropertyExifDictionary as String], "EXIF が保持されていること")
    }

    // MARK: - リサイズ（縮小のみ・全経路）

    /// 画像の実ピクセル寸法を返す（テスト用）。
    private func pixelDimensions(_ url: URL) -> (w: Int, h: Int)? {
        let p = imageProperties(url)
        guard let w = p[kCGImagePropertyPixelWidth as String] as? Int,
              let h = p[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        return (w, h)
    }

    /// SDR 保存経路（`.sdr`）で横幅指定リサイズが効き、アスペクト比を維持すること。
    func testResizeSDRPathFitWidth() throws {
        let input = try makeSDRImage("resize_sdr.jpg", type: .jpeg, orientation: 1)  // 256x192
        let out = tmp.appendingPathComponent("resize_sdr.heic")
        try GainForge.convert(input: input, output: out, quality: 0.7,
                              force: true, sdrMode: .sdr, resize: .fitWidth(128))
        let dim = pixelDimensions(out)
        XCTAssertEqual(dim?.w, 128, "横幅が指定どおり縮小されること")
        XCTAssertEqual(dim?.h, 96, "アスペクト比（4:3）が維持されること")
    }

    /// SDR→HDR 合成経路（`.hdrCurve`）でもリサイズが効き、ゲインマップと 10bit が維持されること。
    func testResizeSynthesizedHDRPathKeepsGainMap() throws {
        let input = try makeSDRImage("resize_hdr.jpg", type: .jpeg, orientation: 1)  // 256x192
        let out = tmp.appendingPathComponent("resize_hdr.heic")
        let result = try GainForge.convert(input: input, output: out, quality: 0.7,
                                           force: true, sdrMode: .hdrCurve, resize: .fitHeight(96))
        let dim = pixelDimensions(out)
        XCTAssertEqual(dim?.w, 128, "アスペクト比が維持されること")
        XCTAssertEqual(dim?.h, 96, "縦幅が指定どおり縮小されること")
        XCTAssertTrue(result.isHDR)
        XCTAssertTrue(GainForge.hasGainMap(out), "縮小してもゲインマップが埋め込まれること")
        XCTAssertEqual(imageDepth(out), 10, "縮小しても 10bit で書き出されること")
    }

    /// 原寸超えの指定は縮小にならず原寸のまま出力すること（拡大しない）。
    func testResizeDoesNotUpscale() throws {
        let input = try makeSDRImage("resize_noup.jpg", type: .jpeg, orientation: 1)  // 256x192
        let out = tmp.appendingPathComponent("resize_noup.heic")
        try GainForge.convert(input: input, output: out, quality: 0.7,
                              force: true, sdrMode: .sdr, resize: .fitWidth(4000))
        let dim = pixelDimensions(out)
        XCTAssertEqual(dim?.w, 256, "原寸を超える指定でも拡大しないこと")
        XCTAssertEqual(dim?.h, 192)
    }

    /// 生転写経路（ゲインマップ付き）でも縮小が効き、ベースとゲインマップの両方が縮小され、
    /// ゲインマップが保持されること。フィクスチャ（GAINFORGE_TEST_JPEG）がある場合のみ。
    func testResizeGainMapTransferIfFixtureProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["GAINFORGE_TEST_JPEG"] else {
            throw XCTSkip("GAINFORGE_TEST_JPEG 未設定のためスキップ")
        }
        let input = URL(fileURLWithPath: path)
        let orig = try XCTUnwrap(pixelDimensions(input), "入力寸法を取得できること")
        let out = tmp.appendingPathComponent("resize_transfer.heic")
        try GainForge.convert(input: input, output: out, quality: 0.6,
                              resize: .fitWidth(orig.w / 2))
        let dim = try XCTUnwrap(pixelDimensions(out))
        XCTAssertLessThan(dim.w, orig.w, "ベースが縮小されること")
        XCTAssertTrue(GainForge.hasGainMap(out), "縮小してもゲインマップが保持されること")
    }

    /// 総画素数（`.megapixels`）指定でも実変換で縮小されること（SDR 経路）。
    func testResizeMegapixelsEndToEnd() throws {
        let input = try makeSDRImage("resize_mp.jpg", type: .jpeg, orientation: 1)  // 256x192 ≈ 0.049Mpix
        let out = tmp.appendingPathComponent("resize_mp.heic")
        try GainForge.convert(input: input, output: out, quality: 0.7,
                              force: true, sdrMode: .sdr, resize: .megapixels(0.02))  // 2万画素へ
        let dim = try XCTUnwrap(pixelDimensions(out))
        XCTAssertLessThan(dim.w, 256, "総画素数指定でも縮小されること")
        XCTAssertLessThanOrEqual(dim.w * dim.h, 30_000, "目標総画素の近傍に収まること")
        // アスペクト比（4:3）がおおむね維持されること（偶数丸めの ±1px を許容）。
        XCTAssertEqual(Double(dim.w) / Double(dim.h), 4.0 / 3.0, accuracy: 0.05)
    }

    /// 出力寸法は偶数へ丸められること（HEVC 4:2:0 の奇数寸法アーティファクト回避）。
    func testResizeProducesEvenDimensions() throws {
        let input = try makeSDRImage("resize_even.jpg", type: .jpeg, orientation: 1)  // 256x192
        let out = tmp.appendingPathComponent("resize_even.heic")
        // 127 は奇数。偶数へスナップされることを確認する。
        try GainForge.convert(input: input, output: out, quality: 0.7,
                              force: true, sdrMode: .sdr, resize: .fitWidth(127))
        let dim = try XCTUnwrap(pixelDimensions(out))
        XCTAssertEqual(dim.w % 2, 0, "幅が偶数であること")
        XCTAssertEqual(dim.h % 2, 0, "高さが偶数であること")
    }

    /// 縮小時、出力の EXIF PixelXDimension が旧寸法のまま残らないこと（陳腐化除去の検証）。
    func testResizeDoesNotLeaveStaleExifPixelDimension() throws {
        let input = try makeSDRImage("resize_exif.jpg", type: .jpeg, orientation: 1)  // 256x192
        let out = tmp.appendingPathComponent("resize_exif.heic")
        try GainForge.convert(input: input, output: out, quality: 0.7,
                              force: true, sdrMode: .sdr, resize: .fitWidth(128))
        let dim = try XCTUnwrap(pixelDimensions(out))
        let exif = imageProperties(out)[kCGImagePropertyExifDictionary as String] as? [String: Any]
        if let xDim = exif?[kCGImagePropertyExifPixelXDimension as String] as? Int {
            XCTAssertNotEqual(xDim, 256, "EXIF に旧幅（256）が残っていないこと")
            XCTAssertEqual(xDim, dim.w, "EXIF PixelXDimension が実出力幅と一致すること")
        }
    }
}
