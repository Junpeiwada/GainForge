# HDR 診断ツール

SDR→HDR 合成（`.hdrCurve` / `.hdrML`）の検証に使った単体スクリプト群。
SwiftPM のターゲット外なので `swift build` / `swift test` には影響しない（`swiftc` で個別にコンパイルして使う）。

背景と設計は [../../Docs/SDRのHDR化手法の研究.md](../../Docs/SDRのHDR化手法の研究.md) を参照。

## ツール一覧

| ファイル | 用途 |
|---|---|
| [edr.swift](edr.swift) | 現在のディスプレイの EDR ヘッドルーム（maxEDR / maxPotential）を表示。`maxEDR=1.0` だと HDR の明部拡張は見えない |
| [inspect.swift](inspect.swift) | 出力 HEIC のゲインマップ metadata（`AlternateHeadroom` 等、stops 単位）と画素統計（min/max/avg） |
| [gmsample.swift](gmsample.swift) | ゲインマップを正規化座標でサンプル（色パッチごとのブースト量 0..1 を比較） |
| [cmpbase.swift](cmpbase.swift) | 入力と出力 HEIC のベース画像（ゲインマップ非適用）を画素比較。SDR ベース不変（Δ=0）の検証 |

## ビルドと実行

各スクリプトは単体でコンパイルできる:

```sh
cd Tools/hdr-diagnostics
swiftc edr.swift      -o edr      && ./edr
swiftc inspect.swift  -o inspect  && ./inspect  <file.heic>
swiftc gmsample.swift -o gmsample && ./gmsample <file.heic> [nx ny] ...
swiftc cmpbase.swift  -o cmpbase  && ./cmpbase  <input> <output.heic> [x y] ...
```

## 典型的な使い方（効果が弱い/おかしい時の切り分け）

1. `./edr` — 画面にヘッドルームがあるか。`maxEDR=1.0` なら**輝度を下げてから**再確認。
2. `.build/release/gainforge -x -y <画像.jpg>` で変換。
3. `./inspect <出力.heic>` — `AlternateHeadroom`（stops）で合成強度を確認。
4. `./cmpbase <入力> <出力.heic>` — SDR ベースが改変されていない（Δ=0）ことを確認。
5. `./gmsample <出力.heic> ...` — 肌/白面が抑制され、鏡面/空/鮮やか色が維持されているかを座標指定で確認。
