// gmsample.swift — ゲインマップを正規化座標でサンプルする（局所的なゲイン量の確認）。
//
// 値は 0（無ブースト）..1（GainMapMax 相当の最大ブースト）。色パッチごとの
// ブースト量比較（肌・白面が抑制され、鏡面・空・鮮やか色は維持されるか）に使う。
//
// 使い方: swiftc gmsample.swift -o gmsample && ./gmsample <file.heic> [nx ny] [nx ny] ...
//   nx,ny = 正規化座標 0..1（左上原点）。省略時は 中央＋四隅 をサンプル。
import Foundation
import CoreImage

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("使い方: ./gmsample <file.heic> [nx ny] ..."); exit(2)
}
let url = URL(fileURLWithPath: args[1])
let ctx = CIContext(options: [.workingColorSpace: NSNull()])
guard let g = CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true]) else { print("no gainmap"); exit(1) }
let ext = g.extent

var pts: [(Double, Double)] = []
if args.count >= 4 {
    var i = 2
    while i + 1 < args.count {
        guard let nx = Double(args[i]), let ny = Double(args[i + 1]) else {
            print("座標は数値（0..1）で指定してください: \(args[i]) \(args[i + 1])"); exit(2)
        }
        pts.append((nx, ny)); i += 2
    }
} else {
    pts = [(0.5, 0.5), (0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)]
}

print("gainmap extent=\(ext)  値: 0=無ブースト .. 1=最大")
for (nx, ny) in pts {
    let px = nx * Double(ext.width)
    let py = (1.0 - ny) * Double(ext.height)   // CI は下原点
    let crop = g.cropped(to: CGRect(x: px, y: py, width: 1, height: 1))
    var buf = [Float](repeating: 0, count: 4)
    buf.withUnsafeMutableBytes { raw in
        ctx.render(crop, toBitmap: raw.baseAddress!, rowBytes: 16,
                   bounds: CGRect(x: px, y: py, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
    }
    print(String(format: "(%.2f, %.2f)  %.3f", nx, ny, buf[0]))
}
