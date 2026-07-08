# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

GainForge は、HDR ゲインマップ付き JPEG を、ゲインマップを保持したまま HEIC に変換する macOS ツール。出力は「SDR ベース画像 + ISO ゲインマップ」で、写真アプリと同じ HDR 構造。元のカラーゲインマップを Display P3 PQ のまま **生転写** することで、写真アプリ書き出しと画素レベルでほぼ一致する。

加えて、**ゲインマップを持たない SDR 画像を HDR 化する SDR→HDR 自動補正モード**を持つ。明部だけを HDR ヘッドルームへ拡張し、ベース（SDR 表示の見た目）は維持したまま「SDR ベース + 合成ゲインマップ」を書き出す。方式は `SDRConversion`（`.sdr` / `.hdrCurve` / `.hdrML`）で切り替え、既定は従来どおり SDR 保存。合成した HDR は **10bit HEIC（HEVC Main 10）** で書き出す（`.sdr` は従来どおり 8bit）。**HDR 入力（ゲインマップ付き）の生転写挙動には一切影響しない**。

要環境: macOS 15 以降（ISO ゲインマップ対応のため）、Swift 6 / Xcode 16 以降。追加ライブラリ不要（Apple フレームワークのみ）。

## アーキテクチャ（3層 / 2ビルドシステム）

変換ロジックは **GainForgeCore** に一元化され、CLI と GUI はそれを import するだけの薄い層。重要なのは、この 1 リポジトリが **2 つのビルドシステムで管理されている** こと:

- **SwiftPM**（[Package.swift](Package.swift)）— `GainForgeCore`（ライブラリ）と `gainforge`（CLI 実行ファイル）。`swift build` / `swift test` で完結。
- **Xcode**（[App/GainForge.xcodeproj](App/GainForge.xcodeproj)）— GUI アプリ。`GainForgeCore` を **ローカル Swift Package 依存** として参照（`App/project.yml` の `packages.GainForge.path: ..`）。

```
Sources/GainForgeCore/   変換ロジック（CLI / GUI から共通利用。SDRConversion.swift に SDR 方式 enum）
Sources/GainForgeCLI/    CLI 実行ターゲット（main.swift は引数パースのみ）
App/Sources/             GUI（SwiftUI / macOS）
Tests/GainForgeCoreTests/  Core のユニットテスト（SwiftPM、XCTest）
App/Tests/               GUI（AppViewModel）のテスト（Xcode、XCTest）
```

CLI と GUI に変換ロジックを **持たせない**。新しい変換挙動は必ず `GainForgeCore` に実装し、両 UI から呼ぶこと。

### Core の中核 API（[Sources/GainForgeCore/GainForge.swift](Sources/GainForgeCore/GainForge.swift)）

`enum GainForge` 名前空間の static メソッド群。`convert(input:output:quality:gainScale:force:overwrite:sdrMode:resize:)` が起点で、ゲインマップ**有り**は常に `writeGainMapHEIC`（生転写）。ゲインマップ**無し**は `sdrMode` で分岐: `.sdr` → `writeSDRHEIC`（従来 8bit）/ `.hdrCurve` → `writeExpandedHDRHEIC`（明部加重の逆トーンマッピングで合成）/ `.hdrML` → `writeMLExpandedHDRHEIC`（Apple 学習の色→ゲイン統計 LUT で合成。同梱 LUT を読めないときは `.hdrCurve` へ自動降格し、CLI/GUI がその旨をユーザーへ通知する）。`.hdrCurve` / `.hdrML` の合成出力は 10bit HEIC。`isMLGainLUTAvailable` で LUT の可否を公開する。エラーは型付き `GainForgeError`（`LocalizedError` 準拠で日本語メッセージ）。

**リサイズ（`resize:` / [ResizeMode.swift](Sources/GainForgeCore/ResizeMode.swift)）**: 書き出し時に全経路共通で縮小できる。`ResizeMode` は `.original`（既定・リサイズなし）/ `.megapixels(Double)`（総画素数）/ `.fitWidth(Int)` / `.fitHeight(Int)`。**アスペクト比は常に維持・縮小のみ**（原寸超え指定は原寸のまま）。目標寸法／スケール率は純粋ロジック `ResizePlanner`（UI 非依存・テスト可能）が計算し、`.original`（または縮小にならないとき）は `nil` を返して現行の等倍経路をそのまま通す（生転写の画素一致保証を壊さない）。再サンプルは `CILanczosScaleTransform`（最高品質）で統一。**生転写ではベースとゲインマップをともに Lanczos で同率縮小**して相対比を保つ（`gainScale × baseScale`。基準寸法は `baseCG` の実ピクセル寸法）。合成経路は合成前に SDR を縮小するのでベースとゲインマップが自動整合。出力寸法は HEVC 4:2:0 の奇数アーティファクト回避のため**偶数へ丸める**。縮小時は EXIF 等の旧ピクセル寸法キーを除去する。UI は種別 `ResizeKind`（値なし・`ResizeMode` と 1:1）と各数値を別々に永続化して組み立てる。

### GUI の状態管理（[App/Sources/AppViewModel.swift](App/Sources/AppViewModel.swift)）

`@MainActor` な `AppViewModel` がドロップ受け入れ・probe（メタ取得）・バッチ変換を統括。設計上の要点:

- **並列変換** はスライディングウィンドウ方式（`maxConcurrent` ≈ コア数、上限 3）。1 件完了ごとに該当行をライブ更新。中止要求後は新規投入を止め、実行中の 1 件は完走させる。
- **出力先の事前計画** は純粋ロジック `OutputPlanner`（[App/Sources/Models.swift](App/Sources/Models.swift)）に分離。バッチ内衝突は連番で必ず回避し、ディスク上の既存ファイルは上書き確認ダイアログで解決する。`ExistingOutputFinder` も同様に UI 非依存でテスト可能。
- Task 境界を越える値は Sendable に限定（エラーは文字列に畳む `ConversionOutcome`、NSImage は生成直後の未共有インスタンスのみ `@unchecked Sendable` で一度だけ受け渡す）。
- 設定（品質・出力先・SDR画像の扱い `sdrMode`・リサイズ）は `UserDefaults` に永続化（`didSet` 経由）。ツールバーの「SDR画像」ポップアップが `sdrMode` を束縛する。リサイズは種別 `resizeKind` と各方式の数値（`resizeMegapixels` / `resizeWidth` / `resizeHeight`）を別々に持ち、`resizeMode` computed が `ResizeMode` を組み立てる（方式を切り替えても各値を保持）。ツールバーの「サイズ」ポップアップ＋数値フィールド（プリセット⌄付き）が束縛する。

## 変換ロジックの「落とし穴」（移植元で実証済み・必ず維持）

[Sources/GainForgeCore/GainForge.swift](Sources/GainForgeCore/GainForge.swift) の `writeGainMapHEIC` に実装されている。**触る前に必ず理解すること**:

1. ゲインマップは補助辞書（`kCGImageAuxiliaryDataTypeISOGainMap`）から **Metadata と ColorSpace を取得**（ISO 型では実ピクセルデータは辞書に含まれず、macOS では nil）。
2. ゲインマップ本体は `CIImage(.auxiliaryHDRGainMap)` で **カラー画像として読む**。
3. 焼き込みは **元の ColorSpace（典型: Display P3 PQ）のまま** `render(format: .BGRA8)`。`workingColorSpace` に `NSNull()` を渡して CoreImage の色変換をパススルーにする。sRGB 等で焼くと二重変換で HDR が破綻する。
4. 補助辞書再構成時の `PixelFormat` は **`32BGRA`** に作り直す（元の非公開フォーマット流用は `Finalize` クラッシュ）。
5. ゲインマップ ColorSpace は **ハードコードせず元辞書から取得**（機種ごとに異なる）。
6. 書き出し後に `hasGainMap` で **検算**（補助データ追加は戻り値を返さないため）。
7. ベース画像を `CGImageDestinationAddImage` に渡す際は **元画像のプロパティ辞書（`CGImageSourceCopyPropertiesAtIndex`）を必ずマージして渡す**。`CGImage` 単体はピクセルのみで EXIF/GPS/TIFF/Orientation を持たず、品質オプションだけ渡すと **全メタデータが失われ、Orientation 欠落で表示が回転し得る**。SDR フォールバック（`writeSDRHEIC`）も同様に ImageIO 経路でプロパティを引き継ぐ。

**生転写経路では** Core Image の `writeHEIFRepresentation(hdrImage:)` は使わない（元ゲインマップを捨て差分から再計算してハイライトで色がずれる）。

### SDR→HDR 合成（`writeExpandedHDRHEIC` / `.hdrCurve`）— 生転写とは前提が違う

保存すべき元ゲインマップが**無く新規に合成する**経路なので、生転写のルールとは別扱い。ここでは逆に CoreImage のゲインマップ生成を使う。要点:

- **明部加重ゲインをリニア光で計算**。作業空間 = 拡張リニア Display P3。輝度から無彩スカラー `gain = 1 + (headroom−1)·smoothstep(knee, 1, L)` を RGB に一律乗算（色相・彩度不変）。中間調・暗部は等倍で明部だけ伸びる。ヘッドルームは平均輝度から自動決定（つまみ無し・完全自動）。
- **ゲイン量を色分布で変調**（肌・白い面が不自然に光るのを防ぐ）。カーネル内で per-pixel に判定: (1) 低彩度（白壁・雪・紙・淡い肌）と (2) 肌色（暖色 R≥G≥B かつ中彩度、鮮やか色は除外）の拡散明部は最大 85% 抑制、(3) クリップ近傍の鏡面・光源は保護解除。空・光源・鮮やかな色・鏡面は従来通り伸びる。抑制するのは「どれだけ伸ばすか」だけで色相・彩度は不変。肌色相の当て物は使わず彩度＋チャンネル順序で頑健に判定。
- 書き出しは **`writeHEIF10Representation(of: SDR, options: [.hdrImage: 合成HDR])`**。SDR ベースと合成 HDR の差分から CoreImage が ISO ゲインマップを生成。ベース色は Display P3（PQ ではない）。**ベースは元 SDR のまま維持**（SDR 表示の見た目は不変）。出力は **10bit HEIC（HEVC Main 10）** で、16bit PNG 等の高精度入力の階調を保ちバンディングを抑える（ベース CIImage は float 精度のまま渡り量子化は 10bit 出力時の一度だけ）。**SDR 保存（`.sdr` / `writeSDRHEIC`）は従来どおり 8bit**。
- **EXIF/GPS/Orientation は `sdr.settingProperties(元props)` で引き継ぐ**（落とし穴7と同趣旨）。書き出し後 `hasGainMap` で検算（落とし穴6）。
- **PNG の AI 生成タグ（tEXt/iTXt）を引き継ぐ**（[PNGTextMetadata.swift](Sources/GainForgeCore/PNGTextMetadata.swift)）。ComfyUI の `prompt`・AnimeForgeStudio の `animeforge` 等は PNG 固有テキストチャンクに埋まり、ImageIO（`CopyPropertiesAtIndex`）は非標準キーワードを一切拾わないため通常のプロパティ引き継ぎでは失われる。HEIC にチャンク相当の器が無いので、拾ったチャンクを keyword→text の **JSON にまとめて EXIF UserComment** へ格納する（CoreImage の HDR 書き出し経路でも残りゲインマップも非破壊なことを実測確認済み）。**チャンクが無ければ何も足さない**。`.sdr`（`writeSDRHEIC`）と `.hdrCurve`/`.hdrML`（`writeSynthesizedHDRHEIC`）の両方で `PNGTextMetadata.merging(_:from:)` を通す。圧縮 iTXt/zTXt は v1 対象外。
- ゲインは自前 `CIColorKernel(source:)`（stock の multiply は拡張レンジ >1.0 をクランプし得るため）。文字列カーネル API は macOS 10.14 非推奨だが現行動作。SwiftPM ライブラリに Metal カーネル（`-fcikernel` 等）を組み込むビルド構成を避けるため v1 は意図的に採用（deprecation warning が 1 件出るのは既知）。
### SDR→HDR 合成（`writeMLExpandedHDRHEIC` / `.hdrML`）— Apple 学習の色→ゲイン LUT

カーブ法（`.hdrCurve`）が手書きの明部加重＋色保護なのに対し、`.hdrML` は Apple 写真ライブラリの実 HDR から集計した「色 → 平均ゲイン」の統計 3D LUT でゲインを決める。書き出し経路（`writeSynthesizedHDRHEIC`、10bit）は `.hdrCurve` と共通で、合成方式（`makeLUTExpandedHDR`）だけを差し替える。要点:

- LUT（`Sources/GainForgeCore/Resources/apple-gainlut-17-perchan.bin`、17³×4ch×Float32・拡張リニア Display P3・正規化ゲイン 0..1）を `Bundle.module` から一度だけロード・検証（サイズ＋NaN/Inf・範囲）して `gainLUTData` に保持。`CIColorCube` で色→ゲイン g' を引き、自前カーネルで `out = sdr * (1 + g'·(gainLUTMax−1))` を計算して拡張レンジへ伸ばす。
- **LUT を読めない/壊れているときは `.hdrCurve` へ自動降格**する（`writeMLExpandedHDRHEIC` 冒頭の `gainLUTData` nil 分岐）。環境依存の失敗でバッチを全滅させない安全弁。降格は全ファイル共通なので、CLI は開始前に stderr へ一度、GUI は `presentMLFallbackNotice` で起動中一度だけユーザーへ通知する（可否は `isMLGainLUTAvailable`）。
- LUT 生成スクリプトは集計元の写真データに依存するオフライン処理のため**リポジトリには同梱しない**。差し替え時はフォーマット厳守（`GainForge.swift` の該当コメント参照）。
- さらなる将来案として、ExpandNet 等の学習モデルを CoreML 化して同じ書き出し経路に合流させる余地がある（LUT 法・カーブ法と選択制のまま拡張）。

## コマンド

### CLI / Core（SwiftPM）

```sh
swift build -c release                 # ビルド
swift run gainforge <入力 ...>          # 変換（ファイル/フォルダ。フォルダは *.jpg/*.jpeg/*.png を再帰）
swift test                             # Core のユニットテスト
swift test --filter GainForgeCoreTests/<テストメソッド名>   # 単一テスト
```

CLI オプション: `-q 0.0-1.0`（品質、既定 0.6）/ `-o 出力先` / `-f`（ゲインマップ無しも SDR HEIC 化）/ `-y`（既存上書き）/ `--mpix N`・`-w px`・`--height px`（アスペクト維持で縮小、最後の指定が有効）/ `-h`。

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
