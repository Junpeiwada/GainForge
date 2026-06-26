import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 読み込み時の軽量な画像メタ取得（サムネ・サイズ・ゲインマップ判定）。
/// すべて Sendable な値を返し、バックグラウンドで安全に実行できる。
enum ImageProbe {

    /// 入力 JPEG の縮小サムネイルを PNG データとして生成する（最大 `maxPixel` px）。
    /// NSImage は非 Sendable のため、ここでは Data（Sendable）を返して呼び出し側で復元する。
    static func thumbnailPNG(for url: URL, maxPixel: Int = 96) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dst, cg, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return data as Data
    }

    /// 画像のピクセル寸法を取得する（デコードせずプロパティのみ参照）。
    /// 比較ビューワのズーム計算（1 画像ピクセル基準）に使う。
    static func pixelSize(for url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }
}
