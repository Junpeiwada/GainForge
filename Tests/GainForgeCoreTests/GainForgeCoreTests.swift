import XCTest
import Foundation
import ImageIO
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

    // MARK: - collectJPEGs

    func testCollectJPEGsFindsJpgAndJpegRecursively() throws {
        _ = try touch("a.jpg")
        _ = try touch("b.JPEG")
        _ = try touch("c.png")
        let sub = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try touch("d.jpeg", in: sub)

        let found = GainForge.collectJPEGs(tmp).map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(found, ["a.jpg", "b.JPEG", "d.jpeg"])
    }

    func testCollectJPEGsOnSingleFile() throws {
        let jpg = try touch("only.jpg")
        XCTAssertEqual(GainForge.collectJPEGs(jpg), [jpg])
        let png = try touch("only.png")
        XCTAssertEqual(GainForge.collectJPEGs(png), [])
    }

    func testCollectJPEGsOnMissingPath() {
        let missing = tmp.appendingPathComponent("nope.jpg")
        XCTAssertEqual(GainForge.collectJPEGs(missing), [])
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
}
