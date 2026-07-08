import XCTest
import CoreGraphics
@testable import GainForgeCore

/// リサイズ計画（縮小のみ・アスペクト維持）の純粋ロジック検証。
final class ResizePlannerTests: XCTestCase {

    private let fourK = CGSize(width: 4000, height: 3000)   // 1200 万画素・4:3

    // MARK: - .original

    func testOriginalNeverResizes() {
        XCTAssertNil(ResizePlanner.targetSize(original: fourK, mode: .original))
        XCTAssertEqual(ResizePlanner.scale(original: fourK, mode: .original), 1.0)
    }

    // MARK: - .megapixels

    func testMegapixelsDownscalesKeepingAspect() {
        // 1200 万画素 → 300 万画素は 1/4 面積 = 1/2 スケール。
        let t = ResizePlanner.targetSize(original: fourK, mode: .megapixels(3.0))
        XCTAssertEqual(t?.width, 2000)
        XCTAssertEqual(t?.height, 1500)
    }

    func testMegapixelsLargerThanOriginalDoesNotUpscale() {
        // 原寸 1200 万画素より大きい 24Mpix 指定は縮小にならず nil（拡大しない）。
        XCTAssertNil(ResizePlanner.targetSize(original: fourK, mode: .megapixels(24.0)))
    }

    func testMegapixelsNonPositiveIsNoop() {
        XCTAssertNil(ResizePlanner.targetSize(original: fourK, mode: .megapixels(0)))
        XCTAssertNil(ResizePlanner.targetSize(original: fourK, mode: .megapixels(-5)))
    }

    // MARK: - .fitWidth / .fitHeight

    func testFitWidthDownscalesKeepingAspect() {
        let t = ResizePlanner.targetSize(original: fourK, mode: .fitWidth(2000))
        XCTAssertEqual(t?.width, 2000)
        XCTAssertEqual(t?.height, 1500)   // 4:3 維持
    }

    func testFitHeightDownscalesKeepingAspect() {
        let t = ResizePlanner.targetSize(original: fourK, mode: .fitHeight(1500))
        XCTAssertEqual(t?.width, 2000)
        XCTAssertEqual(t?.height, 1500)
    }

    func testFitWidthLargerThanOriginalDoesNotUpscale() {
        XCTAssertNil(ResizePlanner.targetSize(original: fourK, mode: .fitWidth(8000)))
    }

    func testFitWidthEqualToOriginalIsNoop() {
        XCTAssertNil(ResizePlanner.targetSize(original: fourK, mode: .fitWidth(4000)))
    }

    // MARK: - 端値

    func testZeroSizedOriginalIsSafe() {
        XCTAssertNil(ResizePlanner.targetSize(original: .zero, mode: .fitWidth(1000)))
        XCTAssertEqual(ResizePlanner.scale(original: .zero, mode: .fitWidth(1000)), 1.0)
    }

    func testScaleClampsToOne() {
        // 縮小のみなのでスケール上限は 1.0。
        XCTAssertLessThanOrEqual(ResizePlanner.scale(original: fourK, mode: .fitWidth(9999)), 1.0)
        XCTAssertEqual(ResizePlanner.scale(original: fourK, mode: .fitWidth(2000)), 0.5, accuracy: 1e-6)
    }
}
