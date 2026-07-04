import Foundation

/// GainForge の変換処理で発生し得るエラー。
///
/// 移植元 `hdrheic.swift` は Bool 返却だったが、GUI でのメッセージ表示のため
/// Core では型付きエラーにする（仕様.md「GainForgeCore」節）。
public enum GainForgeError: Error, Sendable {
    /// 入力画像ソースを開けなかった。
    case cannotReadSource(URL)
    /// ゲインマップが無い入力を、強制変換指定なしで変換しようとした（スキップ相当）。
    case noGainMap(URL)
    /// ゲインマップ補助辞書から ColorSpace を取得できなかった。
    case gainMapColorSpaceMissing
    /// ゲインマップ本体をカラー画像として読み込めなかった。
    case gainMapImageUnreadable
    /// ゲインマップのサイズが不正（幅・高さが 0 以下）。
    case gainMapEmpty
    /// ベース SDR 画像を取得できなかった。
    case baseImageUnreadable
    /// HEIC 出力先を生成できなかった。
    case destinationCreateFailed(URL)
    /// HEIC のファイナライズに失敗した。
    case finalizeFailed(URL)
    /// 書き出し後の検算でゲインマップが埋め込まれていなかった（落とし穴6）。
    case gainMapVerificationFailed(URL)
    /// 出力先に既存ファイルがあり、上書き許可なしで変換しようとした。
    case outputExists(URL)
    /// SDR→HDR 合成（明部加重ゲイン等）に失敗した。
    case hdrSynthesisFailed(URL)
}

extension GainForgeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotReadSource(let url):
            return "入力画像を読み込めませんでした: \(url.lastPathComponent)"
        case .noGainMap(let url):
            return "ゲインマップがありません: \(url.lastPathComponent)"
        case .gainMapColorSpaceMissing:
            return "ゲインマップの ColorSpace を取得できませんでした"
        case .gainMapImageUnreadable:
            return "ゲインマップ本体を読み込めませんでした"
        case .gainMapEmpty:
            return "ゲインマップのサイズが不正です"
        case .baseImageUnreadable:
            return "ベース画像を取得できませんでした"
        case .destinationCreateFailed(let url):
            return "出力先を作成できませんでした: \(url.lastPathComponent)"
        case .finalizeFailed(let url):
            return "HEIC の書き出しに失敗しました: \(url.lastPathComponent)"
        case .gainMapVerificationFailed(let url):
            return "ゲインマップの埋め込み検算に失敗しました: \(url.lastPathComponent)"
        case .outputExists(let url):
            return "出力先に既存ファイルがあります: \(url.lastPathComponent)"
        case .hdrSynthesisFailed(let url):
            return "SDR から HDR への合成に失敗しました: \(url.lastPathComponent)"
        }
    }
}
