# GainForge

HDR ゲインマップ付き JPEG を、ゲインマップを保持したまま HEIC に変換する macOS ツール。

- **GainForgeCore**: 変換ロジック（Swift Package ライブラリ）
- **CLI**: コマンドライン変換ツール
- **GUI**: macOS アプリ（SwiftUI、Core を参照）

出力は「SDR ベース画像 + ISO ゲインマップ」で、写真アプリと同じ HDR 構造。
元のカラーゲインマップを Display P3 PQ のまま生転写するため、写真アプリ書き出しと
画素レベルでほぼ一致する。

仕様・アーキテクチャは [Docs/仕様.md](Docs/仕様.md) を参照（たたき台）。

移植元: AISandbox リポジトリ `HDRHEIF/`（実証・検証済み）。
