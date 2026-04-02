# アーキテクチャ

## システム構成図

```
┌─────────────────────────────────────────────────────────────────┐
│ GitHub Enterprise (社内)                                         │
│ github.your-company.com                                          │
│                                                                  │
│  org/internal-monorepo                                           │
│  ├── main                                                        │
│  │     └── replica/last-sync タグ（同期起点）                     │
│  │     └── replica/sync-* タグ（同期履歴、任意）                  │
│  │                                                               │
│  └── external/3rdparty-pr-* ブランチ（外部PR取り込み用）          │
│                                                                  │
│  .github/workflows/sync-replica.yml                              │
│    └── milestone/* タグをトリガーに sync-to-replica.sh を実行    │
└────────────────────┬────────────────────────────────────────────┘
                     │
         [B] マイルストーン同期          [C] 外部PR取り込み
         squash + author=Bot             patch + meta を受け取り
         (--mode pr/direct/patch)        apply-external-pr.sh
                     │                             ▲
                     ▼                             │
┌─────────────────────────────────────────────────────────────────┐
│ github.com (社外レプリカ)                                         │
│                                                                  │
│  your-org/replica                                                │
│  ├── main          ← 社内同期でのみ更新（Branch Protection）      │
│  │                                                               │
│  └── 3rdparty/foo  ← 3rd party の開発ブランチ                    │
│          └── feature/xxx                                         │
│                  └── PR → main                                   │
│                                                                  │
│  .github/workflows/pr-to-internal.yml                            │
│    └── PR 作成・更新時に patch + meta を Artifact として保存      │
└─────────────────────────────────────────────────────────────────┘
```

## データフロー

### [B] マイルストーン同期

```
内部 repo (GHE)                          レプリカ (github.com)
────────────────                         ──────────────────────
git diff
  replica/last-sync..HEAD
  （除外パスを除く）
        │
        │ .patch ファイル
        ▼
git apply --3way
        │
        │ squash commit
        │ author  = Platform Sync Bot
        │ message = "sync: milestone"
        ▼
[mode=pr]     sync/YYYYMMDD ブランチ ──► PR → main
[mode=direct] ─────────────────────────► main へ直接 push
[mode=patch]  sync-patches/ に出力        （手動で apply）
        │
        ▼
git tag -f replica/last-sync HEAD
git tag    replica/sync-YYYYMMDD（任意）
```

### [C] 外部PR取り込み

```
github.com                      社内担当者              GHE
──────────                      ──────────              ───
3rd party が PR 作成
        │
CI が自動実行
  pr-to-internal.yml
        │
Artifact 生成
  pr-NNN.patch
  pr-NNN-meta.json
        │                Artifact をダウンロード
        │                        │
        │                apply-external-pr.sh
        │                  --patch / --meta
        │                        │
        │                git apply --3way ──────────────► external/3rdparty-pr-NNN
        │                        │                        内部 PR 自動作成
        │                        │
        │                内部でレビュー・採用判断
        │                        │
        │                [全部採用] git cherry-pick
        │                [部分採用] cherry-pick-partial.sh
        │                [却下]    内部 PR Close
        │                        │
        │                notify-external-pr.sh
        │                  --status accepted/partial/rejected
        ▼
外部 PR にコメント
[却下] Close
[採用] 次回 milestone sync 後に Close
```

## タグ設計

| タグ名 | 場所 | 種別 | 役割 |
|--------|------|------|------|
| `replica/last-sync` | 内部 GHE | 可動 (`-f` で上書き) | 次回 diff の起点。sync 完了後に HEAD へ前進 |
| `replica/sync-YYYYMMDD-HHMMSS` | 内部 GHE | 不変 | 各同期の記録（任意作成） |
| `milestone/YYYY-QN` | 内部 GHE | 不変 | マイルストーク基点。CI のトリガーにも使用 |

## レプリカの main ブランチ保護

github.com の `main` は社内同期 Bot のみが push できるよう Branch Protection を設定する。

```
Branch protection rules (main):
  ✓ Restrict who can push to matching branches
      → sync-bot のみ許可
  ✓ Require pull request reviews before merging
      → sync PR を 3rd party がレビュー可能にする（任意）
```

3rd party は `main` への直接 push を禁止され、
自分の開発ブランチから PR を作成する形になる。
