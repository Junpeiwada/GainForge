# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

GainForge は、HDR ゲインマップ付き JPEG を、ゲインマップを保持したまま HEIC に変換する macOS ツール。出力は「SDR ベース画像 + ISO ゲインマップ」で、写真アプリと同じ HDR 構造。元のカラーゲインマップを Display P3 PQ のまま **生転写** することで、写真アプリ書き出しと画素レベルでほぼ一致する。

要環境: macOS 15 以降（ISO ゲインマップ対応のため）、Swift 6 / Xcode 16 以降。追加ライブラリ不要（Apple フレームワークのみ）。

## アーキテクチャ（3層 / 2ビルドシステム）

変換ロジックは **GainForgeCore** に一元化され、CLI と GUI はそれを import するだけの薄い層。重要なのは、この 1 リポジトリが **2 つのビルドシステムで管理されている** こと:

- **SwiftPM**（[Package.swift](Package.swift)）— `GainForgeCore`（ライブラリ）と `gainforge`（CLI 実行ファイル）。`swift build` / `swift test` で完結。
- **Xcode**（[App/GainForge.xcodeproj](App/GainForge.xcodeproj)）— GUI アプリ。`GainForgeCore` を **ローカル Swift Package 依存** として参照（`App/project.yml` の `packages.GainForge.path: ..`）。

```
Sources/GainForgeCore/   変換ロジック（CLI / GUI から共通利用）
Sources/GainForgeCLI/    CLI 実行ターゲット（main.swift は引数パースのみ）
App/Sources/             GUI（SwiftUI / macOS）
Tests/GainForgeCoreTests/  Core のユニットテスト（SwiftPM、XCTest）
App/Tests/               GUI（AppViewModel）のテスト（Xcode、XCTest）
```

CLI と GUI に変換ロジックを **持たせない**。新しい変換挙動は必ず `GainForgeCore` に実装し、両 UI から呼ぶこと。

### Core の中核 API（[Sources/GainForgeCore/GainForge.swift](Sources/GainForgeCore/GainForge.swift)）

`enum GainForge` 名前空間の static メソッド群。`convert(input:output:quality:gainScale:force:overwrite:)` が起点で、ゲインマップ有無で `writeGainMapHEIC`（生転写）/ `writeSDRHEIC`（フォールバック）に分岐。エラーは型付き `GainForgeError`（`LocalizedError` 準拠で日本語メッセージ）。

### GUI の状態管理（[App/Sources/AppViewModel.swift](App/Sources/AppViewModel.swift)）

`@MainActor` な `AppViewModel` がドロップ受け入れ・probe（メタ取得）・バッチ変換を統括。設計上の要点:

- **並列変換** はスライディングウィンドウ方式（`maxConcurrent` ≈ コア数、上限 3）。1 件完了ごとに該当行をライブ更新。中止要求後は新規投入を止め、実行中の 1 件は完走させる。
- **出力先の事前計画** は純粋ロジック `OutputPlanner`（[App/Sources/Models.swift](App/Sources/Models.swift)）に分離。バッチ内衝突は連番で必ず回避し、ディスク上の既存ファイルは上書き確認ダイアログで解決する。`ExistingOutputFinder` も同様に UI 非依存でテスト可能。
- Task 境界を越える値は Sendable に限定（エラーは文字列に畳む `ConversionOutcome`、NSImage は生成直後の未共有インスタンスのみ `@unchecked Sendable` で一度だけ受け渡す）。
- 設定（品質・出力先）は `UserDefaults` に永続化（`didSet` 経由）。

## 変換ロジックの「落とし穴」（移植元で実証済み・必ず維持）

[Sources/GainForgeCore/GainForge.swift](Sources/GainForgeCore/GainForge.swift) の `writeGainMapHEIC` に実装されている。**触る前に必ず理解すること**:

1. ゲインマップは補助辞書（`kCGImageAuxiliaryDataTypeISOGainMap`）から **Metadata と ColorSpace を取得**（ISO 型では実ピクセルデータは辞書に含まれず、macOS では nil）。
2. ゲインマップ本体は `CIImage(.auxiliaryHDRGainMap)` で **カラー画像として読む**。
3. 焼き込みは **元の ColorSpace（典型: Display P3 PQ）のまま** `render(format: .BGRA8)`。`workingColorSpace` に `NSNull()` を渡して CoreImage の色変換をパススルーにする。sRGB 等で焼くと二重変換で HDR が破綻する。
4. 補助辞書再構成時の `PixelFormat` は **`32BGRA`** に作り直す（元の非公開フォーマット流用は `Finalize` クラッシュ）。
5. ゲインマップ ColorSpace は **ハードコードせず元辞書から取得**（機種ごとに異なる）。
6. 書き出し後に `hasGainMap` で **検算**（補助データ追加は戻り値を返さないため）。

Core Image の `writeHEIFRepresentation(hdrImage:)` は使わない（差分から再計算してハイライトで色がずれる）。

## コマンド

### CLI / Core（SwiftPM）

```sh
swift build -c release                 # ビルド
swift run gainforge <入力 ...>          # 変換（ファイル/フォルダ。フォルダは *.jpg/*.jpeg を再帰）
swift test                             # Core のユニットテスト
swift test --filter GainForgeCoreTests/<テストメソッド名>   # 単一テスト
```

CLI オプション: `-q 0.0-1.0`（品質、既定 0.6）/ `-o 出力先` / `-f`（ゲインマップ無しも SDR HEIC 化）/ `-y`（既存上書き）/ `-h`。

### GUI（Xcode）

```sh
open App/GainForge.xcodeproj           # Xcode で GainForge スキームを Run
xcodebuild -project App/GainForge.xcodeproj -scheme GainForge -destination 'platform=macOS' test   # GUI テスト
```

### XcodeGen（重要）

`App/GainForge.xcodeproj` は **XcodeGen 管理** で、`App/project.yml` が真実のソース。プロジェクト設定（ターゲット・ビルド設定・依存・ファイル構成）を変える場合は **`project.yml` を編集して再生成** すること。`.xcodeproj` を直接 Xcode で編集しても次回再生成で失われる:

```sh
cd App && xcodegen generate
```

`App/Sources/` 配下にファイルを追加するだけなら（`sources: - path: Sources` でフォルダ参照しているため）再生成は基本不要だが、設定変更時は必ず `project.yml` 側で行う。

## ドキュメント

- 仕様・アーキテクチャ: [Docs/仕様.md](Docs/仕様.md)
- 画面仕様: [Docs/画面仕様.md](Docs/画面仕様.md)

移植元: AISandbox リポジトリ `HDRHEIF/`（実証・検証済み）。
