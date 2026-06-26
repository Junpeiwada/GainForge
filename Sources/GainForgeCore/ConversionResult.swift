import Foundation

/// 1 ファイルの変換結果。
public struct ConversionResult: Sendable, Equatable {
    /// 出力された HEIC の URL。
    public let outputURL: URL
    /// 変換前のバイト数。
    public let inputBytes: Int
    /// 変換後のバイト数。
    public let outputBytes: Int
    /// ゲインマップを保持した HDR HEIC かどうか（false は SDR HEIC）。
    public let isHDR: Bool

    public init(outputURL: URL, inputBytes: Int, outputBytes: Int, isHDR: Bool) {
        self.outputURL = outputURL
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.isHDR = isHDR
    }

    /// 出力 / 入力のサイズ比（0.0–1.0）。入力サイズ不明時は nil。
    public var sizeRatio: Double? {
        guard inputBytes > 0 else { return nil }
        return Double(outputBytes) / Double(inputBytes)
    }
}
