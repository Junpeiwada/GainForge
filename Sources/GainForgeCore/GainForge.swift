// GainForge.swift
// HDR ゲインマップ付き JPEG を、ゲインマップを保持したまま HEIC に変換する中核 API。
//
// 方式: ImageIO 低レベル経路で「SDR ベース + 元のカラーゲインマップ」を生転写する。
// Core Image の writeHEIFRepresentation(hdrImage:) はゲインマップを差分から再計算して
// ハイライトで色がずれるため使わない。詳細は Docs/調査_色ずれ原因と解法.md を参照。
//
// 移植元: AISandbox/HDRHEIF/hdrheic.swift（実証・検証済み）。

import Foundation
import CoreImage
import ImageIO
import CoreVideo
import UniformTypeIdentifiers

/// GainForge の公開 API 名前空間。
public enum GainForge {

    // MARK: - ゲインマップ検出

    /// 入力がゲインマップ（ISO / HDR いずれか）を持つかを判定する。
    public static func hasGainMap(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        for type in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type) != nil { return true }
        }
        return false
    }

    // MARK: - 変換

    /// ゲインマップ付き JPEG を HDR HEIC に変換（生転写方式）。
    ///
    /// ゲインマップが無い入力は `force` が true のときのみ SDR HEIC として書き出し、
    /// false のときは `.noGainMap` を投げる（CLI の `-f` 既定挙動に相当）。
    ///
    /// - Important: `output` の親ディレクトリは呼び出し側で事前に用意すること。
    ///   存在しないと `CGImageDestinationCreateWithURL` が nil を返し `.destinationCreateFailed` になる。
    ///
    /// - Parameters:
    ///   - input: 入力 JPEG の URL。
    ///   - output: 出力 HEIC の URL。
    ///   - quality: HEVC 品質（0.0–1.0、内部でクランプ）。SDR ベース画像の圧縮率に作用。
    ///   - gainScale: ゲインマップの縮小率（1.0 で原寸、<1.0 でサイズ削減・任意）。
    ///   - force: ゲインマップ無し画像も SDR HEIC として変換するか。
    ///   - overwrite: 出力先に既存ファイルがある場合に上書きするか。false のときに既存が
    ///     あれば `.outputExists` を投げる（事前計画外の予期せぬ上書きを防ぐ安全弁）。
    /// - Returns: 変換結果（サイズ・HDR 種別）。
    @discardableResult
    public static func convert(
        input: URL,
        output: URL,
        quality: Double = 0.6,
        gainScale: Double = 1.0,
        force: Bool = false,
        overwrite: Bool = false
    ) throws -> ConversionResult {
        let q = max(0.0, min(1.0, quality))
        let isHDR = hasGainMap(input)

        if isHDR {
            try ensureWritable(output, overwrite: overwrite)
            try writeGainMapHEIC(input: input, output: output, quality: q, gainScale: gainScale)
        } else {
            guard force else { throw GainForgeError.noGainMap(input) }
            try ensureWritable(output, overwrite: overwrite)
            try writeSDRHEIC(input: input, output: output, quality: q)
        }

        return ConversionResult(
            outputURL: output,
            inputBytes: fileSize(input),
            outputBytes: fileSize(output),
            isHDR: isHDR
        )
    }

    // MARK: - HDR 生転写

    /// ゲインマップ付き HEIC を ImageIO 生転写で書き出す。
    ///
    /// 移植元で実証済みの「落とし穴」を維持している（仕様.md「変換ロジックの要点」）。
    private static func writeGainMapHEIC(
        input: URL,
        output: URL,
        quality: Double,
        gainScale: Double
    ) throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw GainForgeError.cannotReadSource(input)
        }

        // 1. 元のゲインマップ補助辞書から Metadata と ColorSpace を取得する。
        //    ISO 型では実ピクセルデータはこの辞書に含まれない（macOS で Data は nil）。
        guard let origAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any],
              let gainCSValue = origAux[kCGImageAuxiliaryDataInfoColorSpace as String],
              CFGetTypeID(gainCSValue as CFTypeRef) == CGColorSpace.typeID else {
            throw GainForgeError.gainMapColorSpaceMissing
        }
        // 5. ゲインマップ ColorSpace はハードコードせず元辞書から取得（機種ごとに異なる）。
        let gainCS = gainCSValue as! CGColorSpace
        let origMeta = origAux[kCGImageAuxiliaryDataInfoMetadata as String]

        // 2. ゲインマップをカラー CIImage として読む。
        guard var gainCI = CIImage(contentsOf: input, options: [.auxiliaryHDRGainMap: true]) else {
            throw GainForgeError.gainMapImageUnreadable
        }
        if gainScale != 1.0 {
            gainCI = gainCI.transformed(by: CGAffineTransform(scaleX: gainScale, y: gainScale))
        }

        // 3. ゲインマップ本来の ColorSpace（典型: Display P3 PQ）で BGRA8 に焼く。
        //    workingColorSpace に NSNull() を渡し CoreImage の色変換をパススルーにする。
        //    sRGB 等で焼くと二重変換で HDR が破綻するため、必ず元の ColorSpace を使う。
        let rawCtx = CIContext(options: [.workingColorSpace: NSNull()])
        let gw = Int(gainCI.extent.width.rounded())
        let gh = Int(gainCI.extent.height.rounded())
        guard gw > 0, gh > 0 else { throw GainForgeError.gainMapEmpty }
        let gbpr = gw * 4   // BGRA8 は 1 画素 4 バイト。gw*4 は常に 4 の倍数で追加パディング不要。
        var gainData = Data(count: gbpr * gh)
        gainData.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            rawCtx.render(gainCI, toBitmap: base, rowBytes: gbpr,
                          bounds: gainCI.extent, format: .BGRA8, colorSpace: gainCS)
        }

        // 4. 補助辞書を再構成。PixelFormat は標準の 32BGRA に作り直す
        //    （元の非公開フォーマット流用は Finalize クラッシュ）。
        var aux: [String: Any] = [
            kCGImageAuxiliaryDataInfoData as String: gainData as CFData,
            kCGImageAuxiliaryDataInfoDataDescription as String: [
                "PixelFormat": Int(kCVPixelFormatType_32BGRA),
                "BytesPerRow": gbpr,
                "Width": gw,
                "Height": gh,
            ],
            kCGImageAuxiliaryDataInfoColorSpace as String: gainCS,
        ]
        if let meta = origMeta { aux[kCGImageAuxiliaryDataInfoMetadata as String] = meta }

        // 5. ベース SDR + ゲインマップを HEIC として書き出す。
        guard let baseCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw GainForgeError.baseImageUnreadable
        }
        guard let dst = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw GainForgeError.destinationCreateFailed(output)
        }
        CGImageDestinationAddImage(dst, baseCG, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(dst, kCGImageAuxiliaryDataTypeISOGainMap, aux as CFDictionary)
        guard CGImageDestinationFinalize(dst) else {
            throw GainForgeError.finalizeFailed(output)
        }

        // 6. 検算: 補助データ追加は戻り値を返さないため、書き出し後に確認する（落とし穴6）。
        guard hasGainMap(output) else {
            throw GainForgeError.gainMapVerificationFailed(output)
        }
    }

    // MARK: - SDR フォールバック

    /// ゲインマップ無し画像を SDR HEIC として書き出す（CLI の `-f` 相当）。
    private static func writeSDRHEIC(input: URL, output: URL, quality: Double) throws {
        guard let sdr = CIImage(contentsOf: input) else {
            throw GainForgeError.cannotReadSource(input)
        }
        let ctx = CIContext()
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let opts: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality
        ]
        do {
            try ctx.writeHEIFRepresentation(of: sdr, to: output, format: .RGBA8, colorSpace: p3, options: opts)
        } catch {
            throw GainForgeError.sdrWriteFailed(underlying: error)
        }
    }

    // MARK: - ユーティリティ

    /// 出力先が書き込み可能か確認する。上書き不許可で既存ファイルがあれば `.outputExists` を投げる。
    /// 書き込み直前に判定して、事前計画の後に外部で現れた予期せぬ既存ファイルを弾く。
    private static func ensureWritable(_ output: URL, overwrite: Bool) throws {
        if !overwrite, FileManager.default.fileExists(atPath: output.path) {
            throw GainForgeError.outputExists(output)
        }
    }

    /// ファイルのバイト数を返す（取得不能時は 0）。
    public static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// フォルダを再帰探索し `*.jpg` / `*.jpeg` の URL 一覧を返す。
    /// ファイル URL はそのまま 1 件返す。結果はパス順にソートする。
    public static func collectJPEGs(_ url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return isJPEG(url) ? [url] : []
        }
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        var result: [URL] = []
        for case let f as URL in en where isJPEG(f) {
            result.append(f)
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func isJPEG(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg"
    }

    /// 出力先に同名 HEIC があれば連番（`_1`, `_2`, …）を付けた未使用 URL を返す（上書き回避）。
    public static func uniqueOutputURL(directory: URL, stem: String) -> URL {
        let fm = FileManager.default
        let base = directory.appendingPathComponent(stem + ".heic")
        if !fm.fileExists(atPath: base.path) { return base }
        var n = 1
        while true {
            let candidate = directory.appendingPathComponent("\(stem)_\(n).heic")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
