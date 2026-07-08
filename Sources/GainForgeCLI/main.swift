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
var sdrMode: SDRConversion = .sdr
var resize: ResizeMode = .original
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
    case "-x", "--hdr":
        // ゲインマップ無し画像を SDR→HDR 補正（明部加重カーブ）で変換。指定時は force 相当。
        sdrMode = .hdrCurve
        forceNonHDR = true
    case "-m", "--hdr-ml":
        // ゲインマップ無し画像を SDR→HDR 補正（Apple 学習の色→ゲイン統計 LUT）で変換。指定時は force 相当。
        sdrMode = .hdrML
        forceNonHDR = true
    case "-y", "--overwrite":
        allowOverwrite = true
    case "--mpix":
        // アスペクト維持で総画素数（百万画素）を指定。縮小のみ。
        argi += 1
        if argi < argv.count, let mp = Double(argv[argi]), mp > 0 { resize = .megapixels(mp) }
    case "-w", "--width":
        // アスペクト維持で横幅（px）を指定。縮小のみ。
        argi += 1
        if argi < argv.count, let px = Int(argv[argi]), px > 0 { resize = .fitWidth(px) }
    case "--height":
        // アスペクト維持で縦幅（px）を指定。縮小のみ。
        argi += 1
        if argi < argv.count, let px = Int(argv[argi]), px > 0 { resize = .fitHeight(px) }
    case "-h", "--help":
        print("使い方: gainforge [-q 0.0-1.0] [-o 出力先] [-f] [-x] [-m] [-y] [--mpix N | -w px | --height px] <入力ファイル/フォルダ ...>")
        print("  -q       HEVC 品質（既定 0.6）")
        print("  -o       出力フォルダ（省略時は入力と同じ場所に .heic）")
        print("  -f       ゲインマップ無し画像も SDR HEIC として変換")
        print("  -x, --hdr     ゲインマップ無し画像を HDR 自動補正（明部加重カーブ）して変換")
        print("  -m, --hdr-ml  ゲインマップ無し画像を HDR 自動補正（Apple 学習の色→ゲイン LUT）して変換")
        print("  -y       既存の出力ファイルを上書き（既定はスキップ）")
        print("  --mpix N      アスペクト維持で総画素数(百万画素)へ縮小（例 --mpix 8）")
        print("  -w, --width px   アスペクト維持で横幅(px)へ縮小")
        print("  --height px      アスペクト維持で縦幅(px)へ縮小")
        print("  ※ リサイズは縮小のみ（原寸超え指定は原寸のまま）。3方式は最後の指定が有効。")
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

// ---- 入力を画像ファイル一覧に展開（JPEG / PNG。フォルダは再帰）----
let files = inputs.flatMap { GainForge.collectInputImages(URL(fileURLWithPath: $0)) }
if files.isEmpty {
    errPrint("変換対象の画像（JPEG / PNG）が見つかりません。")
    exit(1)
}

// 出力先フォルダの用意
if let od = outDir {
    try? FileManager.default.createDirectory(atPath: od, withIntermediateDirectories: true)
}

// ML/LUT 方式（-m）を選んでも学習 LUT を読めない場合はカーブ法（-x 相当）へ降格する。
// 開始前に一度だけ通知する（降格は全ファイル共通のため 1 回で足りる）。
if sdrMode == .hdrML, !GainForge.isMLGainLUTAvailable {
    errPrint("⚠️  ML/LUT 用の学習データを読み込めないため、HDR 補正は明部加重カーブ（-x 相当）で行います。")
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
            input: inURL, output: outURL, quality: quality, force: forceNonHDR,
            overwrite: allowOverwrite, sdrMode: sdrMode, resize: resize
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
