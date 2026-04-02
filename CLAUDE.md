# Claude Code ハンドオーバードキュメント

このファイルは Claude Code がプロジェクトを理解するためのコンテキストを提供する。

---

## プロジェクトの目的

社内 GitHub Enterprise (GHE) 上の Kotlin ベース monorepo を、
3rd party と協働するために github.com 上のレプリカ monorepo へ安全に同期する仕組み。

### 解決している問題

- 社内コミット履歴・author 情報を外部に漏洩させたくない
- 3rd party が外部レプリカ上で開発・コミットを継続できるようにしたい
- 社内開発もマイルストーンごとに外部へ反映したい
- 外部からの変更を社内でレビュー・選択的に取り込みたい

---

## リポジトリ構成

```
replica-sync/
├── CLAUDE.md                       # このファイル（Claude Code 向けコンテキスト）
├── README.md                       # プロジェクト概要
├── config/
│   └── sync.conf.example           # 設定ファイルテンプレート
├── docs/
│   ├── architecture.md             # システム構成・データフロー
│   ├── decisions.md                # 設計決定記録 (ADR)
│   └── operations.md               # オペレーションガイド（詳細手順）
├── scripts/
│   ├── init-replica.sh             # [A] 初回レプリカ作成
│   ├── sync-to-replica.sh          # [B] マイルストーン同期（3モード）
│   ├── apply-external-pr.sh        # [C] 外部PRの社内適用
│   ├── cherry-pick-partial.sh      # [C] 外部PR変更の部分採用
│   └── notify-external-pr.sh       # [C] 外部PRへの採否通知
└── .github/
    └── workflows/
        ├── sync-replica.yml        # GHE 側: マイルストーン sync CI
        └── pr-to-internal.yml      # github.com 側: 外部PR差分生成 CI
```

---

## 3つのオペレーション

### [A] 初回セットアップ（一度だけ実行）

```
init-replica.sh
  └── git archive <START_TAG>       # ファイルツリーのみ取得（履歴なし）
  └── git init + commit             # 履歴ゼロで初期コミット（author=Bot）
  └── git push → github.com/replica
  └── git tag replica/last-sync     # 同期起点タグを設定
```

### [B] マイルストーン同期（繰り返し実行）

```
sync-to-replica.sh [--mode pr|direct|patch] "<message>"
  └── git diff replica/last-sync..HEAD  # 前回同期からの差分
  └── git apply --3way              # レプリカへ適用
  └── squash commit (author=Bot)
  └── push / PR作成 / patch出力    # モードに応じて分岐
  └── git tag -f replica/last-sync # 同期タグを前進
```

`replica/last-sync` タグが同期起点の可動ポインタ。sync のたびに HEAD へ前進する。

### [C] 外部PR取り込み（外部からPRが来るたびに実行）

```
[github.com CI]
pr-to-internal.yml
  └── gh pr diff --patch            # 差分を patch ファイルに出力
  └── upload-artifact               # patch + meta.json を保存

[社内で手動実行]
apply-external-pr.sh --patch --meta
  └── git apply --3way              # 社内ブランチへ適用
  └── commit (author=Bot)
  └── gh pr create → GHE           # 内部PRを自動作成

cherry-pick-partial.sh              # 部分採用が必要な場合
notify-external-pr.sh --status     # 採否を外部PRへ通知
```

---

## 重要な設計決定

### なぜ `git clone` ではなく `git archive` を使うか
`git clone` は内部コミット履歴をそのまま複製する。
`git archive` はファイルツリーのスナップショットのみを出力するため、
初回セットアップ時に内部履歴をレプリカへ渡さずに済む。

### なぜ squash するか
マイルストーン単位で「1差分 = 1コミット」にすることで、
外部から内部の開発粒度・ブランチ構成・コミットメッセージが見えない。

### なぜ外部PRをレプリカ main にマージしないか
レプリカの `main` は社内同期でのみ更新するという原則を維持するため。
外部からの変更は必ず社内でレビュー・cherry-pick を経て内部 repo に取り込み、
次回 milestone sync でレプリカへ反映されるというフローを守る。

### なぜ author を Bot に差し替えるか
社内開発者の名前・メールアドレスを外部に漏洩させないため。
`GIT_AUTHOR_*` / `GIT_COMMITTER_*` 環境変数で完全に差し替える。

---

## 設定ファイル

全スクリプトは `config/sync.conf` を `source` して動作する。
`config/sync.conf.example` をコピーして環境に合わせて編集する。

```bash
cp config/sync.conf.example config/sync.conf
# sync.conf は .gitignore 済み（パスや認証情報を含むため）
```

---

## 既知の課題・今後の検討事項

- `git apply --3way` で競合が発生した場合の半自動解消フローが未実装
- 複数の 3rd party（会社）がいる場合のレプリカ分離（1レプリカ vs 複数レプリカ）は未決定
- GHE → github.com へのインバウンド通信が不可な環境での CI 自動化フローは `patch` モードを使った手動運用が前提
- `cherry-pick-partial.sh` の `--include` pathspec 形式が git バージョンによって挙動が異なる可能性がある

---

## 開発・テスト環境セットアップ

```bash
# 依存ツール確認
git --version        # 2.35 以上推奨
gh --version         # GitHub CLI
jq --version         # JSON 処理

# 設定ファイルをコピーして編集
cp config/sync.conf.example config/sync.conf
$EDITOR config/sync.conf

# スクリプトに実行権限を付与
chmod +x scripts/*.sh
```
