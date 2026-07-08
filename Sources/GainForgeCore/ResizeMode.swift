import Foundation
import CoreGraphics

/// 書き出し時のリサイズ方式（アスペクト比は常に維持・**縮小のみ**）。
///
/// ゲインマップの有無・HDR/SDR に関わらず全書き出し経路（生転写 / SDR / 合成）へ共通に効く。
/// 原寸を超える指定は原寸のまま出力する（存在しない解像感を作らない）。
/// `.original` は現行挙動そのまま（再サンプルを一切かけない）。
///
/// - `.original`: リサイズしない。
/// - `.megapixels`: 総画素数（百万画素）を指定。`scale = sqrt(目標総画素 / 元総画素)`。
/// - `.fitWidth`: 横幅（px）を指定。縦は比率で追従。
/// - `.fitHeight`: 縦幅（px）を指定。横は比率で追従。
public enum ResizeMode: Sendable, Equatable {
    case original
    case megapixels(Double)
    case fitWidth(Int)
    case fitHeight(Int)
}

/// UI ポップアップの選択肢に対応する種別（値を持たない）。`ResizeMode` の各 case と 1:1。
/// GUI は本種別と各方式の数値を別々に永続化し、変換時に `ResizeMode` を組み立てる
/// （方式を切り替えても各方式の最後の値を覚えておくため）。
public enum ResizeKind: String, Sendable, CaseIterable {
    case original
    case megapixels
    case width
    case height
}

/// リサイズの目標サイズ／スケール率を求める純粋ロジック（UI 非依存・テスト可能）。
///
/// `OutputPlanner` と同じく副作用を持たず、Core・CLI・GUI から共通利用する。
public enum ResizePlanner {

    /// 元サイズと方式から縮小スケール率（0 < s ≤ 1.0）を返す。**縮小のみ**なので上限は 1.0。
    /// 元サイズが無効・目標値が非正のときは 1.0（等倍＝リサイズなし）。
    public static func scale(original: CGSize, mode: ResizeMode) -> CGFloat {
        let w = original.width, h = original.height
        guard w > 0, h > 0 else { return 1.0 }
        let s: CGFloat
        switch mode {
        case .original:
            return 1.0
        case .megapixels(let mp):
            guard mp > 0 else { return 1.0 }
            let target = CGFloat(mp) * 1_000_000
            s = (target / (w * h)).squareRoot()
        case .fitWidth(let px):
            guard px > 0 else { return 1.0 }
            s = CGFloat(px) / w
        case .fitHeight(let px):
            guard px > 0 else { return 1.0 }
            s = CGFloat(px) / h
        }
        return min(1.0, s)   // 拡大しない（縮小のみ）
    }

    /// 元サイズと方式から目標ピクセルサイズを返す。リサイズ不要（縮小にならない）なら nil。
    /// 呼び出し側は nil のとき現行の等倍経路をそのまま通す（再サンプルを避ける）。
    ///
    /// 出力寸法は **偶数** に丸める。HEIC（HEVC）は 4:2:0 クロマで偶数寸法を前提とし、
    /// 奇数だと端 1px にクロマ由来の微アーティファクトが出る余地があるため
    /// （合成経路の 10bit HEVC Main 10 で特に安全側に倒す）。1px 未満の縦横比ずれは許容。
    public static func targetSize(original: CGSize, mode: ResizeMode) -> CGSize? {
        let s = scale(original: original, mode: mode)
        guard s < 1.0 else { return nil }
        let nw = roundedEven(original.width * s)
        let nh = roundedEven(original.height * s)
        // 丸めで実質原寸になった場合はリサイズ不要とみなす。
        guard nw < original.width || nh < original.height else { return nil }
        return CGSize(width: nw, height: nh)
    }

    /// 最近傍の正の偶数へ丸める（下限 2）。
    private static func roundedEven(_ x: CGFloat) -> CGFloat {
        max(2, (x / 2).rounded() * 2)
    }
}
