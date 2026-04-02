# replica-sync

社内 GitHub Enterprise monorepo を github.com 上のレプリカへ安全に同期するためのスクリプト集。

## 特徴

- 社内コミット履歴・author 情報を外部へ漏洩しない（squash + Bot author）
- 3rd party はレプリカ上で独自ブランチを持ち開発を継続できる
- マイルストーン単位での差分同期（PR / 直接 push / patch ファイルの3モード）
- 外部からの変更を社内でレビューし選択的に取り込める

## クイックスタート

```bash
# 1. 設定ファイルを準備
cp config/sync.conf.example config/sync.conf
$EDITOR config/sync.conf

# 2. スクリプトに実行権限を付与
chmod +x scripts/*.sh

# 3. 初回レプリカ作成（一度だけ）
./scripts/init-replica.sh

# 4. マイルストーン同期
./scripts/sync-to-replica.sh "sync: 2024-Q1"
```

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [docs/operations.md](docs/operations.md) | 全オペレーションの詳細手順・チェックリスト |
| [docs/architecture.md](docs/architecture.md) | システム構成・データフロー |
| [docs/decisions.md](docs/decisions.md) | 設計決定記録 (ADR) |
| [CLAUDE.md](CLAUDE.md) | Claude Code 向けコンテキスト |

## スクリプト一覧

| スクリプト | 用途 |
|---|---|
| `scripts/init-replica.sh` | 初回レプリカ作成 |
| `scripts/sync-to-replica.sh` | マイルストーン同期 |
| `scripts/apply-external-pr.sh` | 外部PRの社内適用 |
| `scripts/cherry-pick-partial.sh` | 外部PR変更の部分採用 |
| `scripts/notify-external-pr.sh` | 外部PRへの採否通知 |

## 依存ツール

- `git` 2.35 以上
- `gh` (GitHub CLI)
- `jq`
