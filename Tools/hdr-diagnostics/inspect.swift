// inspect.swift — HEIC のゲインマップ metadata と画素統計を表示する。
//
// AlternateHeadroom / GainMapMax（いずれも stops = log2）や、ゲインマップの
// min/max/avg（0..1 正規化、モノクロなら R=G=B）を確認できる。
//
// 使い方: swiftc inspect.swift -o inspect && ./inspect <file.heic>
import Foundation
import CoreImage
import ImageIO
import CoreVideo

guard CommandLine.arguments.count >= 2 else {
    print("使い方: ./inspect <file.heic>"); exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { print("!! cannot open"); exit(1) }

// 補助辞書（ISO ゲインマップ）の metadata を列挙。
if let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any] {
    print("=== ISO gain map aux keys:", aux.keys.sorted())
    if let desc = aux[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any] {
        print("   DataDescription:", desc)
    }
    if let meta = aux[kCGImageAuxiliaryDataInfoMetadata as String] {
        let cf = meta as! CGImageMetadata
        if let tags = CGImageMetadataCopyTags(cf) as? [CGImageMetadataTag] {
            for t in tags {
                let name = CGImageMetadataTagCopyName(t) as String? ?? "?"
                let val = CGImageMetadataTagCopyValue(t)
                print("   meta[\(name)] =", val ?? "nil")
            }
        }
    }
} else {
    print("!! ISO gain map aux info nil（Apple 旧 HDRGainMap かゲインマップ無しの可能性）")
}

// ゲインマップをカラー画像として読み、min/max/avg をリニアで測る。
let ctx = CIContext(options: [.workingColorSpace: NSNull()])
if let g = CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true]) {
    let ext = g.extent
    print("=== gain map extent:", ext)
    for (name, fname) in [("min", "CIAreaMinimum"), ("max", "CIAreaMaximum"), ("avg", "CIAreaAverage")] {
        let f = CIFilter(name: fname, parameters: [kCIInputImageKey: g, kCIInputExtentKey: CIVector(cgRect: ext)])!
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            ctx.render(f.outputImage!, toBitmap: raw.baseAddress!, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        print("   gainmap \(name): R=\(px[0]) G=\(px[1]) B=\(px[2])")
    }
} else {
    print("!! could not read gain map image")
}
