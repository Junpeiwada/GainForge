# HDRHEIF 色ずれ問題 — 調査結果と解法

## 変更履歴

- 2026-06-26: 初版。色ずれの原因特定、解法（ImageIO生転写）の実証まで完了。

---

## 目次

- [問題](#問題)
- [結論（先に要点）](#結論先に要点)
- [調査で確定した事実](#調査で確定した事実)
- [検証データ（正解HEICとの平均差分）](#検証データ正解heicとの平均差分)
- [なぜ現状ツールはずれるのか](#なぜ現状ツールはずれるのか)
- [解法（実証済み）](#解法実証済み)
- [今後のTODO](#今後のtodo)
- [作成した検証ツール](#作成した検証ツール)
- [参考資料](#参考資料)

---

## 問題

Lightroom等が書き出した **HDRゲインマップ付きJPEG** を、現状の `hdrheic.swift`
（Core Image `writeHEIFRepresentation(hdrImage:)` 方式）でHEIC化すると、
**HDRゲインマップが効くハイライト付近で色がずれる**。

一方、macOSの写真アプリに同じHDR JPGを読み込んでHEICで書き出すと色は変わらない。
→ Appleは正しい変換を持っている。これを再現したい。

## 結論（先に要点）

- **真因**: 現状の `hdrImage` 方式は、元のゲインマップを**捨てて HDR↔SDR 差分から作り直す**。
  その再計算が元のゲインマップと一致せず、ハイライトで色が転ぶ。
- **Appleの正解**: 元のゲインマップ補助データを**フォーマットごとそのまま転写**して見た目を保存。
- **解法**: Core Image の `writeHEIFRepresentation` を捨て、**ImageIO低レベル経路**で
  ゲインマップをカラー保持のまま生転写する。**実証済みで、正解HEICとほぼ完全一致**
  （平均差分 0.0227 → **0.0067** に改善）。

## 調査で確定した事実

1. **ゲインマップはカラー(3ch)**。元JPGのMPF2枚目は独立した普通のJPEG
   （8056×4531 / YCbCr 4:4:4 / 8bit / 3ch）。補助データのPixelFormat `f444` の
   `444` はこの 4:4:4 を指す。
2. **Appleはゲインマップをコピーしている**。正解HEICのゲインマップ画素は元JPGと
   小数3桁まで一致（中心 raw値 R0.2785 G0.2597 B0.2542 が完全一致）。再計算していない。
3. **現状ツールはゲインマップを別物に作り替える**。`hdrImage` 方式の出力ゲインマップ中心値は
   (0.269, 0.269, 0.269) のグレースケールで、元(カラー)と全く違う。
4. **Core Image API では解決不能**。`writeHEIFRepresentation` は `hdrImage` でも
   `hdrGainMapImage` でも、ゲインマップを内部で**再計算/グレー化**する
   （カラーで渡しても RGB差0.0000 に潰れる）。format/colorSpace を変えても最終ピクセルは不変。
5. **ゲインマップの色空間は Display P3 PQ（3ch）**。補助辞書の Metadata がこの空間での
   ゲイン変換係数を保持しており、**renderする色空間をこれに合わせないと二重変換でHDRが崩壊**する
   （sRGBで焼いた最初の試行は mean 0.278 に大破綻した）。
6. **ISO型ゲインマップの実Dataは `CGImageSourceCopyAuxiliaryDataInfoAtIndex` から取れない**
   （macOS 26 で Data=nil）。`CIImage(.auxiliaryHDRGainMap)` 経由でカラー取得し、
   BGRA8で焼き直して辞書を**再構成**する必要がある（juniperphoton方式）。
7. **外部ライブラリ libultrahdr は HEICゲインマップ未対応**（2026年対応予定）。今は使えない。

## 検証データ（正解HEICとの平均差分）

全画素を extended linear Display P3 でHDR展開し、RGB最大成分差を集計（長辺1536px）。

| 方式 | mean Δ | p95 Δ | 評価 |
|---|---|---|---|
| 元JPG vs 正解HEIC（理想の到達点） | 0.0122 | 0.042 | Appleの保存品質 |
| **現状ツール（hdrImage方式 = mode D）** | **0.0227** | 0.092 | 色ずれあり |
| hdrGainMapImageでカラー渡し（mode C/F） | 0.0235 | 0.13 | 改善せず(内部グレー化) |
| 生転写・sRGBで焼く（誤り） | 0.278 | 0.54 | 大破綻 |
| **生転写・Display P3 PQで焼く（解法 = exp4b）** | **0.0067** | **0.018** | ★正解とほぼ一致 |

## なぜ現状ツールはずれるのか

`hdrheic.swift:127-128`:
```swift
if gain, let hdr = CIImage(contentsOf: inURL, options: [.expandToHDR: true]) {
    opts[CIImageRepresentationOption.hdrImage] = hdr  // ← Core Imageが差分からゲインマップを再計算
}
```
- Core Image は base(SDR) と hdr の比のログをゲインマップとして**新規生成**する。
- 元のカラーゲインマップ（Display P3 PQ・3ch）は捨てられ、**1chグレーの近似**に置き換わる。
- 近似誤差がハイライト（ゲイン量大）で増幅され、Rが下がりG/Bが上がる＝彩度低下・色相シフトとして見える。

## 解法（実証済み）

**Core Image の `writeHEIFRepresentation` をやめ、ImageIO で生転写する**。
検証コードは `/tmp/exp4b.swift`（このリポジトリにも `exp4.swift` の改良版として取り込む予定）。

手順:
1. `CGImageSourceCopyAuxiliaryDataInfoAtIndex(.ISOGainMap)` で
   **Metadata と ColorSpace（Display P3 PQ）を取得**（Dataは入っていない）。
2. `CIImage(contentsOf:, options:[.auxiliaryHDRGainMap: true])` でゲインマップを**カラーCIImageとして読む**。
3. `CIContext(workingColorSpace: NSNull())` で、**手順1のColorSpace（Display P3 PQ）**を使い
   `render(format: .BGRA8)` でビットマップ化（bpr = width×4 を4の倍数に）。
4. 補助辞書を**再構成**:
   - `Data` = 焼いたBGRA8
   - `DataDescription` = `{PixelFormat: kCVPixelFormatType_32BGRA, BytesPerRow, Width, Height}`
   - `ColorSpace` = renderに使った Display P3 PQ（**必ず一致させる**）
   - `Metadata` = 元のものを保持
5. `CGImageDestinationCreateWithURL(.heic)` に
   ベースSDR（`CGImageSourceCreateImageAtIndex(src,0)`）を追加し、
   `CGImageDestinationAddAuxiliaryDataInfo(.ISOGainMap, aux)` でゲインマップを書き込み、`Finalize`。

**重要な落とし穴**:
- renderの色空間と辞書のColorSpaceを**Display P3 PQに揃える**こと。
  sRGB等で焼くと二重変換でHDRが大破綻する（mean 0.278）。
- DataDescription の PixelFormat は元の `f444`（非公開）を流用せず、**32BGRAに作り直す**。
  流用すると `Finalize` が "Unsupported AuxiliaryData format" でクラッシュ（SEGV）する。

## 今後のTODO

- [ ] **`hdrheic.swift` 本体を解法に書き換える**
  - `writeHEIFRepresentation(hdrImage:)` 経路を ImageIO 生転写に置換。
  - ゲインマップ無し画像（`-f` でSDR HEIC化）の既存挙動は維持。
  - HEVC品質 `-q` は `kCGImageDestinationLossyCompressionQuality` で従来どおり反映。
- [ ] **実機の写真アプリでHDR表示を確認**（Finder/プレビュー/写真アプリで元JPGと並べて目視）。
  数値一致（mean 0.0067）に加え、写真アプリがHDRバッジを出すか・HDR点灯するかを確認。
- [ ] **ゲインマップ縮小オプションの是非を検討**。Appleは撮影画像で1/2〜1/9に縮小するが、
  今回の入力は原寸ゲインマップ。原寸転写で一致しているので、サイズ削減目的の縮小は別途オプション化（任意）。
  - 縮小時は DataDescription の Width/Height/BytesPerRow を更新すること。
- [ ] **複数サンプルで再検証**。今回はDJIの1枚のみ。Lightroom書き出しや他機種のHDR JPGでも
  mean が十分小さいか確認（特にゲインマップのColorSpaceが sRGB / Rec.2100 PQ など異なるケース）。
  - ゲインマップColorSpaceは画像により異なりうるので、**ハードコードせず元辞書から取得**する設計にする（解法手順1を必須化）。
- [ ] **READMEを更新**。「方式C（hdrImage再計算）」の記述を「ImageIO生転写でゲインマップを保存」に改訂。
  「なぜ単純コピーではダメか」の節は、ISO型ではData非取得→CIImage経由で再構成、という最新事情に差し替え。
- [ ] **エラーハンドリング**: ゲインマップ無し・補助辞書欠損・render失敗時のフォールバック整理。
- [ ] 実験用スクリプト（`experiment.swift` / `exp2..4.swift` / `probe.swift` / `diffstat.swift`）は
  `.gitignore` 追加 or `analyze/` へ隔離して本体と分離。

## 作成した検証ツール

| ファイル | 役割 |
|---|---|
| `probe.swift` | 指定座標のピクセルをSDR/HDR両方でサンプリングし数値比較 |
| `diffstat.swift` | 2画像をHDR展開し全画素のRGB差分統計（mean/p95/p99/max） |
| `experiment.swift` | format/colorSpace/hdrImage vs hdrGainMapImage の切り替え実験（mode A〜E） |
| `exp2.swift` | hdrGainMapImageにカラーゲインマップを渡す検証（内部グレー化を確認） |
| `exp4.swift` | ImageIO生転写の初版（sRGBで焼く誤り版） |
| `/tmp/exp4b.swift` | **解法の実証版（Display P3 PQで焼く正解版・mean 0.0067）** |

※ テスト素材: `/Users/junpeiwada/Downloads/写真アプリ/`
（元JPG と 写真アプリ書き出しHEIC＝正解）

## 参考資料

- [Process Apple Gain Map: The ImageIO & the Core Image approaches](https://juniperphoton.substack.com/p/process-apple-gain-map-the-imageio)
- [Pitfalls and workarounds when dealing with RGB HDR Gain Map using ImageIO](https://juniperphoton.substack.com/p/pitfalls-and-workarounds-when-dealing) ← 解法の核
- [HDR Image Formats (VI): iPhone HEIC HDR | JacksBlog](https://jackchou00.com/en/posts/iphone-heic-hdr-format/)
- [Use HDR for dynamic image experiences in your app — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10177/)
- [ISO gain maps — Greg Benz Photography](https://gregbenzphotography.com/hdr-photos/iso-21496-1-gain-maps-share-hdr-photos/)
