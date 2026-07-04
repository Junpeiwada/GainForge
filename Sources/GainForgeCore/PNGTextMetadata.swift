// PNGTextMetadata.swift
// PNG の tEXt / iTXt テキストチャンクを読み取り、HEIC 出力へ引き継ぐためのユーティリティ。
//
// なぜ必要か: ComfyUI の "prompt"（ワークフロー JSON）や AnimeForgeStudio の "animeforge"
// （生成レシピ JSON）といった AI 生成タグは PNG 固有のテキストチャンクに埋まっている。
// ImageIO（CGImageSourceCopyPropertiesAtIndex）はこれら非標準キーワードを一切拾わないため、
// GainForge の通常のプロパティ引き継ぎ（EXIF/GPS/Orientation）では失われる。
// HEIC には PNG テキストチャンク相当のコンテナが無いので、拾ったチャンクを JSON にまとめて
// EXIF UserComment に格納する（CoreImage の HDR 書き出し経路でも残ることを実測で確認済み。
// ゲインマップも非破壊）。チャンクが無ければ何も足さない。

import Foundation
import ImageIO

/// PNG のテキストチャンク（tEXt / 非圧縮 iTXt）を keyword→text で読み取り、
/// HEIC の EXIF UserComment 用ペイロードへ変換する。PNG 以外・チャンク無しは無変換。
public enum PNGTextMetadata {

    /// PNG シグネチャ（8 バイト）。
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// PNG の tEXt / 非圧縮 iTXt チャンクを keyword→text で返す。
    /// PNG でない・読み取れない・テキストチャンクが無い場合は空辞書。
    /// CRC は検証しない（生成物の読取専用途で、内容の忠実な引き写しが目的）。
    public static func readTextChunks(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url), data.count > 8,
              Array(data.prefix(8)) == signature else { return [:] }
        let bytes = [UInt8](data)
        func be32(_ o: Int) -> Int {
            (Int(bytes[o]) << 24) | (Int(bytes[o + 1]) << 16) | (Int(bytes[o + 2]) << 8) | Int(bytes[o + 3])
        }
        var result: [String: String] = [:]
        var i = 8
        // 各チャンク = length(4) + type(4) + data(length) + crc(4)
        while i + 12 <= bytes.count {
            let len = be32(i)
            guard len >= 0, i + 12 + len <= bytes.count else { break }
            let type = String(bytes: bytes[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
            let body = Array(bytes[(i + 8)..<(i + 8 + len)])
            switch type {
            case "tEXt":
                if let (kw, text) = parseTEXt(body) { result[kw] = text }
            case "iTXt":
                if let (kw, text) = parseITXt(body) { result[kw] = text }
            default:
                break
            }
            if type == "IEND" { break }
            i += 12 + len
        }
        return result
    }

    /// 引き継ぐべきテキストチャンクがあれば、それらを keyword→text の JSON にまとめた
    /// 文字列（EXIF UserComment に入れる想定）を返す。無ければ nil。
    /// キーは PNG チャンクのキーワードをそのまま使う（例: "prompt" / "animeforge"）。
    public static func userCommentPayload(for url: URL) -> String? {
        let chunks = readTextChunks(url)
        guard !chunks.isEmpty else { return nil }
        guard let json = try? JSONSerialization.data(withJSONObject: chunks, options: [.sortedKeys]),
              let str = String(data: json, encoding: .utf8) else { return nil }
        return str
    }

    /// PNG のテキストチャンクを EXIF UserComment として `props` にマージした辞書を返す。
    /// 引き継ぐチャンクが無ければ `props` をそのまま返す。既存の UserComment は上書きしない
    /// （元画像が本来持つコメントを尊重する）。
    public static func merging(_ props: [String: Any], from input: URL) -> [String: Any] {
        guard let payload = userCommentPayload(for: input) else { return props }
        var merged = props
        var exif = (merged[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        if exif[kCGImagePropertyExifUserComment as String] == nil {
            exif[kCGImagePropertyExifUserComment as String] = payload
        }
        merged[kCGImagePropertyExifDictionary as String] = exif
        return merged
    }

    // MARK: - チャンク解析

    /// tEXt: keyword(Latin-1) \0 text。text は PNG 仕様上 Latin-1 だが、ComfyUI 等は UTF-8 を
    /// 書き込むため UTF-8 優先で復号し、失敗時に Latin-1 へフォールバックする。
    private static func parseTEXt(_ body: [UInt8]) -> (String, String)? {
        guard let nul = body.firstIndex(of: 0) else { return nil }
        let kw = String(bytes: body[0..<nul], encoding: .isoLatin1) ?? ""
        guard !kw.isEmpty else { return nil }
        let textBytes = Array(body[(nul + 1)...])
        let text = String(bytes: textBytes, encoding: .utf8)
            ?? String(bytes: textBytes, encoding: .isoLatin1) ?? ""
        return (kw, text)
    }

    /// iTXt: keyword(Latin-1) \0 compFlag(1) compMethod(1) langTag \0 transKeyword \0 text(UTF-8)。
    /// 圧縮フラグ付き（compFlag==1）は v1 では対象外（AI 生成ツールは非圧縮で書く）。
    private static func parseITXt(_ body: [UInt8]) -> (String, String)? {
        guard let k0 = body.firstIndex(of: 0) else { return nil }
        let kw = String(bytes: body[0..<k0], encoding: .isoLatin1) ?? ""
        guard !kw.isEmpty else { return nil }
        var p = k0 + 1
        guard p + 2 <= body.count else { return nil }
        let compFlag = body[p]
        p += 2 // compFlag + compMethod をスキップ
        guard compFlag == 0 else { return nil } // 圧縮 iTXt は非対応
        guard let l0 = body[p...].firstIndex(of: 0) else { return nil } // langTag 終端
        p = l0 + 1
        guard let t0 = body[p...].firstIndex(of: 0) else { return nil }  // transKeyword 終端
        p = t0 + 1
        guard p <= body.count else { return nil }
        let text = String(bytes: body[p...], encoding: .utf8) ?? ""
        return (kw, text)
    }
}
