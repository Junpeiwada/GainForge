// cmpbase.swift — 入力画像と、出力 HEIC の「ベース画像（ゲインマップ非適用の主画像）」を
// 同じ sRGB で描画して画素を突き合わせる。SDR ベースが改変されていないか（Δ=0）の検証用。
//
// CIImage(contentsOf:) は auxiliaryHDRGainMap を付けなければベース(SDR 主画像)を返す。
//
// 使い方: swiftc cmpbase.swift -o cmpbase && ./cmpbase <input> <output.heic> [x y] [x y] ...
//   x,y = 画素座標（左上原点）。省略時は既定のグリッドをサンプル。
import Foundation
import CoreImage
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("使い方: ./cmpbase <input> <output.heic> [x y] ..."); exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

func sample(_ url: URL, _ pts: [(Int, Int)]) -> [(Int, Int, [UInt8])] {
    guard let img = CIImage(contentsOf: url) else { return [] }
    let ext = img.extent
    var out: [(Int, Int, [UInt8])] = []
    for (px, py) in pts {
        let rect = CGRect(x: CGFloat(px), y: ext.height - CGFloat(py) - 1, width: 1, height: 1)
        let crop = img.cropped(to: rect)
        var buf = [UInt8](repeating: 0, count: 4)
        buf.withUnsafeMutableBytes { raw in
            ctx.render(crop, toBitmap: raw.baseAddress!, rowBytes: 4,
                       bounds: rect, format: .RGBA8, colorSpace: srgb)
        }
        out.append((px, py, buf))
    }
    return out
}

var pts: [(Int, Int)] = []
if args.count >= 5 {
    var i = 3
    while i + 1 < args.count {
        guard let x = Int(args[i]), let y = Int(args[i + 1]) else {
            print("座標は整数で指定してください: \(args[i]) \(args[i + 1])"); exit(2)
        }
        pts.append((x, y)); i += 2
    }
} else {
    pts = [(10, 10), (400, 50), (200, 300), (400, 300), (700, 300)]
}

let a = sample(inURL, pts), b = sample(outURL, pts)
print("pt          入力(R,G,B)      出力ベース(R,G,B)   Δ")
for i in 0..<min(a.count, b.count) {
    let (x, y, ia) = a[i]; let (_, _, ib) = b[i]
    let d = (0..<3).map { abs(Int(ia[$0]) - Int(ib[$0])) }.max() ?? 0
    print(String(format: "(%3d,%3d)  (%3d,%3d,%3d)      (%3d,%3d,%3d)      %d",
                 x, y, ia[0], ia[1], ia[2], ib[0], ib[1], ib[2], d))
}
