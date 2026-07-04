import Foundation

/// ゲインマップ無し（SDR）入力をどう変換するかの方式。
///
/// ゲインマップ付き入力（HDR）はこの設定に関わらず常に生転写される。
/// 本 enum は「ゲインマップが無い入力」に対してのみ効く。
///
/// - `.sdr`: SDR HEIC としてそのまま保存（従来挙動、CLI の `-f` 相当）。
/// - `.hdrCurve`: 明部加重の逆トーンマッピングで HDR ゲインマップを合成し、
///   HDR HEIC として保存する。ベース画像は元 SDR のまま維持し、明部だけを
///   HDR ヘッドルームへ拡張する（SDR 表示の見た目は変えない）。
/// - `.hdrML`: Apple 写真ライブラリの実 HDR から学習した「色 → ゲイン」統計 3D LUT で
///   ゲインを決めて合成する。カーブ法（`.hdrCurve`）が手書きの明部加重＋色保護なのに対し、
///   こちらは Apple の実データに基づく色ごとの伸ばし方を再現する。書き出し経路は
///   `.hdrCurve` と共通で、ベース画像は元 SDR のまま維持する。
public enum SDRConversion: String, Sendable, CaseIterable {
    case sdr
    case hdrCurve
    case hdrML
}
