# Tools/ — 共通ツール置き場

---

## 共通 venv 方針

ツールが増えても依存管理を分散させないため、Python 依存は **`Tools/.venv` に一括** で持つ。
ツールごとに個別 venv は作らず、この共通 venv を全ツールで共有する。

```bash
# 初回セットアップ（.venv は Git 管理外なのでマシンごとに作成する）
python3 -m venv Tools/.venv
# 共通依存が必要になったら requirements.txt にまとめて一括インストール
# Tools/.venv/bin/pip install -r Tools/requirements.txt
```

- `Tools/.venv` は `.gitignore`（`.venv/` パターン）で除外済み。コミットしない
- 標準ライブラリのみで動くツールは venv 不要だが、システム Python の差異を避けたい場合は共通 venv の Python で実行してよい
- 共通で必要な依存パッケージが出てきたら `Tools/requirements.txt` を作って追記し、上記コマンドでインストールする


## 現在のツール

| ツール | 内容 | venv |
|---|---|---|
| `GenDocsToc/` | Markdown の「## 変更履歴」直後（無ければ「# タイトル」直後）に目次（## 目次）を生成・更新 | 不要（標準ライブラリのみ） |

### GenDocsToc の使い方

```bash
python3 Tools/GenDocsToc/gen_toc.py <target.md>            # 目次を生成・更新
python3 Tools/GenDocsToc/gen_toc.py --dry-run <target.md>  # 差分確認（書き込まない）
```

AgentNest の Docs は変更履歴を持たないため、目次は「# タイトル」直後に挿入される。詳細は [GenDocsToc/README.md](GenDocsToc/README.md) を参照。
