# GainForge

HDR ゲインマップ付き JPEG を、ゲインマップを保持したまま HEIC に変換する macOS ツール。

- **GainForgeCore**: 変換ロジック（Swift Package ライブラリ）
- **CLI** (`gainforge`): コマンドライン変換ツール
- **GUI**: macOS アプリ（SwiftUI、Core を参照）

出力は「SDR ベース画像 + ISO ゲインマップ」で、写真アプリと同じ HDR 構造。
元のカラーゲインマップを Display P3 PQ のまま生転写するため、写真アプリ書き出しと
画素レベルでほぼ一致する。

![GainForge アプリ画面](Docs/assets/GainForge.png)

## ダウンロード / インストール

最新版は [Releases](https://github.com/Junpeiwada/GainForge/releases) から `.zip` を入手できる。

1. `GainForge-x.y.z.zip` を展開し、`GainForge.app` を `アプリケーション` フォルダへ移動。
2. ダブルクリックで起動（Apple の公証済みのため Gatekeeper 警告は出ない）。

### 自動更新

アプリは [Sparkle](https://sparkle-project.org/) による自動更新に対応する。メニュー
**「GainForge について」**で開く About 画面の「更新を確認」から手動確認でき、
「起動時に自動で更新を確認」を有効にすると新版を定期検知して更新する
（ダウンロード→インストール→再起動まで自動）。

リリース手順・配布の仕組みは [Docs/リリース手順.md](Docs/リリース手順.md) を参照。

## 必要環境

- macOS 15 以降（ISO ゲインマップ対応のため）
- Swift 6 / Xcode 16 以降

## CLI

```sh
# ビルド
swift build -c release

# 変換（ファイル / フォルダを指定。フォルダは *.jpg / *.jpeg を再帰探索）
swift run gainforge <入力ファイル/フォルダ ...>
```

オプション:

| オプション | 説明 |
| --- | --- |
| `-q 0.0-1.0` | HEVC 品質（既定 0.6） |
| `-o 出力先` | 出力フォルダ（省略時は入力と同じ場所に `.heic`） |
| `-f` | ゲインマップ無し画像も SDR HEIC として変換 |
| `-h`, `--help` | ヘルプ |

ゲインマップ無しの画像は `-f` を付けない限りスキップする。

## GUI

JPEG / フォルダをドラッグ&ドロップして一括変換する SwiftUI アプリ。

主な機能:

- ドロップした JPEG / フォルダ（再帰）を一覧に追加、重複は自動排除
- 各行にサムネ・ゲインマップ有無・状態・サイズ（変換前 → 変換後）を表示
- **並列変換**: コア数に応じて複数枚を同時変換（上限あり）。1 件完了するたびに該当行をライブ更新する
- 出力先は「入力と同じフォルダ」/「指定フォルダ」を選択（品質・出力先は永続化）
- 変換中の中止（実行中の 1 件は完走させ、未処理行は待機のまま残す）

#### 比較ビューワ

変換前後を並べて確認できる比較ビューワを内蔵する。

![比較ビューワ](Docs/assets/%E6%AF%94%E8%BC%83%E3%83%93%E3%83%A5%E3%83%BC%E3%83%AF.png)

### ビルド / 実行

Xcode プロジェクトは [App/](App/) 配下にある（`App/GainForge.xcodeproj`）。

```sh
open App/GainForge.xcodeproj
# Xcode で GainForge スキームを Run

# プロジェクトファイルは XcodeGen 管理（App/project.yml）。再生成する場合:
cd App && xcodegen generate
```

## テスト

```sh
# Core / CLI のロジックテスト
swift test

# GUI（AppViewModel）のテスト
xcodebuild -project App/GainForge.xcodeproj -scheme GainForge -destination 'platform=macOS' test
```

## ドキュメント

- 仕様・アーキテクチャ: [Docs/仕様.md](Docs/仕様.md)
- 画面仕様: [Docs/画面仕様.md](Docs/画面仕様.md)

移植元: AISandbox リポジトリ `HDRHEIF/`（実証・検証済み）。
