import XCTest
import Foundation
import ImageIO
@testable import GainForgeCore

/// PNG テキストチャンク（tEXt / iTXt）の読み取りと EXIF UserComment への引き継ぎのテスト。
/// 実 PNG を用意せず、チャンクバイト列を合成してパーサ単体を検証する（CRC は検証しないため
/// ダミーで可）。ImageIO が拾わない AI 生成タグを保存する経路の要となる部分。
final class PNGTextMetadataTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PNGTextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - チャンク合成ヘルパ

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// length(4 BE) + type(4) + data + crc(4 ダミー) の 1 チャンクを組み立てる。
    private func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let len = data.count
        var out: [UInt8] = [
            UInt8((len >> 24) & 0xff), UInt8((len >> 16) & 0xff),
            UInt8((len >> 8) & 0xff), UInt8(len & 0xff),
        ]
        out += Array(type.utf8)
        out += data
        out += [0, 0, 0, 0] // CRC はパーサが無視するのでダミー
        return out
    }

    private func tEXt(keyword: String, text: String) -> [UInt8] {
        Array(keyword.utf8) + [0] + Array(text.utf8)
    }

    private func iTXt(keyword: String, text: String, lang: String = "", trans: String = "") -> [UInt8] {
        Array(keyword.utf8) + [0]
            + [0, 0]                      // compFlag=0, compMethod=0
            + Array(lang.utf8) + [0]      // languageTag
            + Array(trans.utf8) + [0]     // translatedKeyword
            + Array(text.utf8)
    }

    /// tEXt("prompt") + iTXt("animeforge") を持つ最小 PNG バイト列をファイルへ書く。
    private func writeSyntheticPNG(prompt: String, animeforge: String) throws -> URL {
        var bytes = Self.signature
        bytes += chunk("IHDR", Array(repeating: 0, count: 13))
        bytes += chunk("tEXt", tEXt(keyword: "prompt", text: prompt))
        bytes += chunk("IDAT", [0x00])
        bytes += chunk("iTXt", iTXt(keyword: "animeforge", text: animeforge))
        bytes += chunk("IEND", [])
        let url = tmp.appendingPathComponent("synthetic.png")
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - readTextChunks

    func testReadsTEXtAndITXtChunks() throws {
        let url = try writeSyntheticPNG(prompt: #"{"ckpt":"wai_v17"}"#,
                                        animeforge: #"{"v":1,"seed":123}"#)
        let chunks = PNGTextMetadata.readTextChunks(url)
        XCTAssertEqual(chunks["prompt"], #"{"ckpt":"wai_v17"}"#)
        XCTAssertEqual(chunks["animeforge"], #"{"v":1,"seed":123}"#)
    }

    func testReadsUTF8InITXt() throws {
        let url = try writeSyntheticPNG(prompt: "p", animeforge: #"{"subject":"猫と桜"}"#)
        let chunks = PNGTextMetadata.readTextChunks(url)
        XCTAssertEqual(chunks["animeforge"], #"{"subject":"猫と桜"}"#)
    }

    func testNonPNGReturnsEmpty() throws {
        let url = tmp.appendingPathComponent("notpng.bin")
        try Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09]).write(to: url)
        XCTAssertTrue(PNGTextMetadata.readTextChunks(url).isEmpty)
    }

    func testPNGWithoutTextChunksReturnsEmpty() throws {
        var bytes = Self.signature
        bytes += chunk("IHDR", Array(repeating: 0, count: 13))
        bytes += chunk("IDAT", [0x00])
        bytes += chunk("IEND", [])
        let url = tmp.appendingPathComponent("plain.png")
        try Data(bytes).write(to: url)
        XCTAssertTrue(PNGTextMetadata.readTextChunks(url).isEmpty)
    }

    // MARK: - userCommentPayload / merging

    func testPayloadIsRecoverableJSON() throws {
        let url = try writeSyntheticPNG(prompt: "PROMPT", animeforge: "AF")
        let payload = try XCTUnwrap(PNGTextMetadata.userCommentPayload(for: url))
        let obj = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String]
        XCTAssertEqual(obj?["prompt"], "PROMPT")
        XCTAssertEqual(obj?["animeforge"], "AF")
    }

    func testMergingAddsUserCommentWhenChunksPresent() throws {
        let url = try writeSyntheticPNG(prompt: "P", animeforge: "A")
        let merged = PNGTextMetadata.merging([:], from: url)
        let exif = merged[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let comment = exif?[kCGImagePropertyExifUserComment as String] as? String
        XCTAssertNotNil(comment)
        XCTAssertTrue(comment!.contains("prompt"))
    }

    func testMergingIsNoOpWithoutChunks() throws {
        var bytes = Self.signature
        bytes += chunk("IHDR", Array(repeating: 0, count: 13))
        bytes += chunk("IEND", [])
        let url = tmp.appendingPathComponent("empty.png")
        try Data(bytes).write(to: url)
        let merged = PNGTextMetadata.merging([:], from: url)
        XCTAssertTrue(merged.isEmpty)
    }

    func testMergingDoesNotClobberExistingUserComment() throws {
        let url = try writeSyntheticPNG(prompt: "P", animeforge: "A")
        let existing: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifUserComment as String: "original",
            ],
        ]
        let merged = PNGTextMetadata.merging(existing, from: url)
        let exif = merged[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifUserComment as String] as? String, "original")
    }
}
