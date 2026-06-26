import Foundation
import AppKit

/// ゲインマップ有無の判定状態。
enum GainMapState: Equatable {
    case checking   // 判定中
    case present    // あり
    case absent     // なし
}

/// ファイル行の処理状態（画面仕様の状態遷移に対応）。
enum RowStatus: Equatable {
    case waiting      // 待機
    case converting   // 変換中
    case done         // 完了
    case existing     // 既存（変換前から対応 HEIC があり、変換せずプレビュー可能）
    case error        // エラー
    case skipped      // スキップ
}

/// 一覧の 1 行 = 1 入力ファイル。変換キュー兼結果一覧。
struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let inputURL: URL

    var thumbnail: NSImage?
    var gainMap: GainMapState = .checking
    var status: RowStatus = .waiting

    var inputBytes: Int?
    var outputBytes: Int?
    var outputURL: URL?
    var errorMessage: String?

    var displayName: String { inputURL.lastPathComponent }

    /// 出力 HEIC を保持し、比較ビューワを開ける行か（変換完了 or 既存検出）。
    var hasComparableOutput: Bool {
        outputURL != nil && (status == .done || status == .existing)
    }

    // 表示に関わる全フィールドを比較する。`id` だけで比較すると SwiftUI の Table が
    // 「中身が変わっていない」と誤判定して、ゲインマップ判定や変換結果のセルを再描画しない。
    // thumbnail は NSImage（クラス）なので参照同一性（===）で比較する。
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.status == rhs.status &&
        lhs.gainMap == rhs.gainMap &&
        lhs.inputBytes == rhs.inputBytes &&
        lhs.outputBytes == rhs.outputBytes &&
        lhs.outputURL == rhs.outputURL &&
        lhs.errorMessage == rhs.errorMessage &&
        lhs.thumbnail === rhs.thumbnail
    }
}

/// 出力先モード。
enum OutputMode: Equatable {
    case sameFolder         // 入力と同じフォルダ
    case customFolder       // 指定フォルダ
}

/// 画面全体の状態。
enum AppPhase: Equatable {
    case empty        // 一覧なし
    case ready        // 待機行あり
    case converting   // バッチ実行中
    case finished     // 全行が完了/エラー/スキップ
}

// MARK: - 出力計画（上書き判定）

/// 1 入力に対する出力先の計画。
struct OutputPlan: Equatable {
    let id: FileItem.ID
    let input: URL
    let output: URL
    /// 出力先に既存ファイルがあり、上書きになるか。
    let willOverwrite: Bool
}

/// 既存ファイルの上書き確認ダイアログでの選択。
enum OverwriteResolution {
    case overwrite   // 既存を上書きして続行
    case rename      // 既存を残し、別名（連番）で保存
    case cancel      // 変換しない
}

/// 出力先を事前に決める純粋ロジック（UI 非依存・テスト可能）。
///
/// - バッチ内で出力先が衝突する行は必ず連番でずらし、片方が他方を消さないようにする
///   （並列変換時の取り違え・上書き事故を設計段階で排除する）。
/// - ディスク上の既存ファイルは `allowOverwriteExisting` に従う:
///   true ならそのまま使い `willOverwrite = true`（上書き予定）、
///   false なら連番でずらして既存を温存する。
enum OutputPlanner {

    /// 出力先を計画する。`fileExists` は既存判定の注入点（テストでは仮想ファイル系を渡す）。
    static func plan(
        targets: [(id: FileItem.ID, input: URL)],
        outputMode: OutputMode,
        customFolder: URL?,
        allowOverwriteExisting: Bool,
        fileExists: (URL) -> Bool
    ) -> [OutputPlan] {
        var reserved = Set<String>()   // このバッチで確保済みの出力パス
        var plans: [OutputPlan] = []
        for t in targets {
            let dir: URL = {
                switch outputMode {
                case .sameFolder:   return t.input.deletingLastPathComponent()
                case .customFolder: return customFolder ?? t.input.deletingLastPathComponent()
                }
            }()
            let stem = t.input.deletingPathExtension().lastPathComponent

            var index = 0
            var url = candidate(dir: dir, stem: stem, index: index)
            var willOverwrite = false
            while true {
                let key = url.standardizedFileURL.path
                if reserved.contains(key) {                 // バッチ内衝突 → 必ずずらす
                    index += 1; url = candidate(dir: dir, stem: stem, index: index); continue
                }
                let exists = fileExists(url)
                if exists && !allowOverwriteExisting {       // 既存温存 → ずらす
                    index += 1; url = candidate(dir: dir, stem: stem, index: index); continue
                }
                willOverwrite = exists                       // 既存をそのまま使うなら上書き
                break
            }
            reserved.insert(url.standardizedFileURL.path)
            plans.append(OutputPlan(id: t.id, input: t.input, output: url, willOverwrite: willOverwrite))
        }
        return plans
    }

    /// `stem.heic` / `stem_N.heic` の候補 URL を作る。
    static func candidate(dir: URL, stem: String, index: Int) -> URL {
        let name = index <= 0 ? "\(stem).heic" : "\(stem)_\(index).heic"
        return dir.appendingPathComponent(name)
    }
}

// MARK: - 既存出力（変換前から存在する HEIC）の検出

/// 入力 JPEG に対応する既存 HEIC を探す純粋ロジック（UI 非依存・テスト可能）。
///
/// 「変換しなくても変換済み（既存）として扱い、プレビューできる」ようにするための検出。
/// 入力と同じフォルダと、指定フォルダ出力時はその出力先フォルダの双方で `stem.heic` を確認する。
/// 連番（`stem_N.heic`）は対象にしない（「この入力の変換結果」と明確に言えるのは同名のみ）。
enum ExistingOutputFinder {

    /// 既存 HEIC があればその URL を、無ければ nil を返す。`fileExists` は既存判定の注入点。
    static func find(
        input: URL,
        outputMode: OutputMode,
        customFolder: URL?,
        fileExists: (URL) -> Bool
    ) -> URL? {
        let stem = input.deletingPathExtension().lastPathComponent
        var dirs: [URL] = [input.deletingLastPathComponent()]
        if outputMode == .customFolder, let customFolder { dirs.append(customFolder) }
        for dir in dirs {
            let url = dir.appendingPathComponent(stem + ".heic")
            if fileExists(url) { return url }
        }
        return nil
    }
}
