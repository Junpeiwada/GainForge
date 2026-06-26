// GainForgeCLI / main.swift
// 移植元 hdrheic.swift の CLI 仕様を踏襲した薄いラッパ。
// 変換ロジックは持たず、すべて GainForgeCore に委譲する。

import Foundation
import GainForgeCore

func errPrint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func mb(_ bytes: Int) -> String { String(format: "%.1fMB", Double(bytes) / 1_048_576.0) }

// ---- 引数パース ----
var quality = 0.6
var outDir: String? = nil
var forceNonHDR = false
var allowOverwrite = false
var inputs: [String] = []

let argv = CommandLine.arguments
var argi = 1
while argi < argv.count {
    let a = argv[argi]
    switch a {
    case "-q":
        argi += 1
        if argi < argv.count, let q = Double(argv[argi]) { quality = max(0.0, min(1.0, q)) }
    case "-o":
        argi += 1
        if argi < argv.count { outDir = argv[argi] }
    case "-f":
        forceNonHDR = true
    case "-y", "--overwrite":
        allowOverwrite = true
    case "-h", "--help":
        print("使い方: gainforge [-q 0.0-1.0] [-o 出力先] [-f] [-y] <入力ファイル/フォルダ ...>")
        print("  -q  HEVC 品質（既定 0.6）")
        print("  -o  出力フォルダ（省略時は入力と同じ場所に .heic）")
        print("  -f  ゲインマップ無し画像も SDR HEIC として変換")
        print("  -y  既存の出力ファイルを上書き（既定はスキップ）")
        exit(0)
    default:
        inputs.append(a)
    }
    argi += 1
}

if inputs.isEmpty {
    errPrint("入力がありません。-h でヘルプ。")
    exit(1)
}

// ---- 入力を JPEG ファイル一覧に展開（フォルダは再帰）----
let files = inputs.flatMap { GainForge.collectJPEGs(URL(fileURLWithPath: $0)) }
if files.isEmpty {
    errPrint("変換対象の JPEG が見つかりません。")
    exit(1)
}

// 出力先フォルダの用意
if let od = outDir {
    try? FileManager.default.createDirectory(atPath: od, withIntermediateDirectories: true)
}

// ---- 変換ループ ----
var ok = 0, skipped = 0, failed = 0
for inURL in files {
    let base = inURL.lastPathComponent
    let stem = inURL.deletingPathExtension().lastPathComponent
    let outURL: URL = {
        if let od = outDir {
            return URL(fileURLWithPath: od).appendingPathComponent(stem + ".heic")
        }
        return inURL.deletingPathExtension().appendingPathExtension("heic")
    }()

    do {
        let result = try GainForge.convert(
            input: inURL, output: outURL, quality: quality, force: forceNonHDR, overwrite: allowOverwrite
        )
        let ratio = result.sizeRatio.map { Int(100.0 * $0) } ?? 0
        let tag = result.isHDR ? "HDR" : "SDR"
        print("✓  \(base) [\(tag)]: \(mb(result.inputBytes)) → \(mb(result.outputBytes)) (\(ratio)%)  q=\(quality)")
        ok += 1
    } catch GainForgeError.noGainMap {
        print("⏭  \(base): ゲインマップ無し → スキップ（-f で強制変換可）")
        skipped += 1
    } catch GainForgeError.outputExists(let out) {
        print("⏭  \(base): 既存ファイルあり（\(out.lastPathComponent)）→ スキップ（-y で上書き）")
        skipped += 1
    } catch {
        print("✗  \(base): \(error.localizedDescription)")
        failed += 1
    }
}
print("---")
print("完了: 成功 \(ok) / スキップ \(skipped) / 失敗 \(failed)")
exit(failed > 0 ? 1 : 0)
