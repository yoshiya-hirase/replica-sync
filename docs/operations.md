# Monorepo レプリカ管理 オペレーションガイド

## 全体構成

```
GitHub Enterprise (社内)                  github.com (社外レプリカ)
─────────────────────────                 ─────────────────────────
github.your-company.com                   github.com
  └── org/internal-monorepo                 └── your-org/replica
        │                                         │
        │  [A] 初回セットアップ                    ├── main        ← 同期先
        │  [B] マイルストーン同期  ──────────────► └── 3rdparty/  ← 3rd party 開発
        │                                               foo
        │  [C] 外部PR取り込み     ◄──────────────────────
        │
  replica/last-sync タグ
  replica/sync-YYYYMMDD タグ（任意）
```

---

## 登場スクリプト一覧

| スクリプト | 実行環境 | 用途 |
|---|---|---|
| `init-replica.sh` | 社内 | 初回レプリカ作成 |
| `sync-to-replica.sh` | 社内 | マイルストーン同期 |
| `pr-to-internal.yml` | github.com CI | 外部PR差分生成 |
| `apply-external-pr.sh` | 社内 | 外部PRの社内適用・PR作成 |
| `cherry-pick-partial.sh` | 社内 | 外部PR変更の部分採用 |
| `notify-external-pr.sh` | 社内 | 外部PRへの採否通知 |

---

## [A] 初回セットアップ

### 前提条件

- 社内 GHE に `org/internal-monorepo` が存在する
- github.com に空の `your-org/replica` リポジトリを作成済み
- SSH 設定で GHE / github.com を使い分けられる（後述）

### A-1. SSH 認証設定

```bash
# 鍵生成
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_ghe    -C "sync-bot@ghe"
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_github  -C "sync-bot@github"

# ~/.ssh/config
Host ghe
  HostName github.your-company.com
  User git
  IdentityFile ~/.ssh/id_ed25519_ghe

Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_github

# 疎通確認
ssh -T ghe
ssh -T github.com
```

各インスタンスに公開鍵を登録する。
github.com 側はレプリカへの書き込みのみを許可する Deploy Key として登録することを推奨する。

### A-2. 初回レプリカ作成

`git clone` は内部コミット履歴をそのまま複製するため使用しない。
`git archive` でファイルツリーのスナップショットのみを取り出し、履歴ゼロの新規リポジトリとして初期化する。

```bash
# init-replica.sh
INTERNAL_REPO="/path/to/internal-monorepo"
START_TAG="milestone/2024-Q1"   # 開始タグ（内部 repo に事前に作成）
REPLICA_DIR="/tmp/replica-init"
REPLICA_URL="git@github.com:your-org/replica.git"
SYNC_AUTHOR_NAME="Platform Sync Bot"
SYNC_AUTHOR_EMAIL="sync-bot@your-company.com"

# 1. タグ時点のファイルツリーのみを展開（コミット履歴を含まない）
rm -rf "$REPLICA_DIR" && mkdir -p "$REPLICA_DIR"
cd "$INTERNAL_REPO"
git archive "$START_TAG" | tar -x -C "$REPLICA_DIR"

# 2. 履歴ゼロの新規リポジトリとして初期コミット
cd "$REPLICA_DIR"
git init
git branch -m main
git add -A
GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git commit -m "initial: $START_TAG"

# 3. github.com へ push
git remote add origin "$REPLICA_URL"
git push -u origin main

# 4. 社内 repo に同期タグを設定（次回同期の起点）
cd "$INTERNAL_REPO"
git tag replica/last-sync "$START_TAG"
```

実行後の状態:

```
内部 monorepo
A - B - C - D - E        (main)
                ↑
          milestone/2024-Q1
          replica/last-sync   ← 同期起点

レプリカ (github.com)
X                        (main)
↑
履歴ゼロの初期コミット（ファイルツリーは E と同一、author=Bot）
```

---

## [B] マイルストーン同期

### 概要

マイルストーンごとに社内 monorepo の差分を squash して 1 commit としてレプリカへ送る。
コミット author は社内開発者ではなく Bot に差し替える。

### B-1. 同期タグの役割

```
内部 monorepo

A - B - C - D - E - F - G  (main)
                ↑           ↑
         replica/last-sync  HEAD
         （前回同期完了点）

sync 実行時の差分: git diff replica/last-sync..HEAD

sync 完了後:
A - B - C - D - E - F - G  (main)
                            ↑
                     replica/last-sync  ← git tag -f で前進
```

`replica/last-sync` タグは常に「前回の同期完了時点」を指す可動ポインタである。
各同期のスナップショットを不変の記録として残したい場合は、追加で固有タグを打つ。

```bash
# 同期完了時に任意で実行
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
git tag "replica/sync-${TIMESTAMP}"        # 不変の同期履歴タグ
git tag -f "replica/last-sync" "$HEAD"    # 可動ポインタを前進
```

固有タグを使った差分確認:

```bash
# 第1回と第2回の同期間の差分
git diff replica/sync-20240101-120000..replica/sync-20240201-153000

# 特定時点のファイルを参照
git show replica/sync-20240201-153000:services/api/src/main.kt
```

### B-2. 同期スクリプト (`sync-to-replica.sh`)

3つのモードをサポートする。

| モード | 動作 | sync タグ更新 |
|---|---|---|
| `pr`（デフォルト） | 同期ブランチを作成し PR として push | 即時 |
| `direct` | レプリカ `main` へ直接 push | 即時 |
| `patch` | パッチセットをファイルに出力して終了 | 手動（適用確認後） |

```bash
# PR として push（デフォルト）
./sync-to-replica.sh "sync: 2024-Q1"

# 直接 push
./sync-to-replica.sh --mode direct "sync: 2024-Q1"

# パッチセット生成のみ（レプリカ側に自動適用しない）
./sync-to-replica.sh --mode patch "sync: 2024-Q1"
```

`patch` モードで生成されるファイル:

```
sync-patches/
├── sync-20240401-120000.patch       # 差分 patch
├── sync-20240401-120000-meta.json   # メタ情報（commit範囲、除外パス等）
└── sync-20240401-120000-summary.txt # 含まれる内部コミット一覧
```

`patch` モードでは sync タグを即時更新しない。
レプリカへの適用確認後に以下を手動実行する。

```bash
cd /path/to/internal-monorepo
git tag -f replica/last-sync <INTERNAL_HEAD>
```

### B-3. 除外パスの管理

社内専用サービスや内部スクリプトなどレプリカに含めたくないパスを設定する。

```bash
EXCLUDE_PATHS=(
  "services/internal-only/"
  ".internal/"
  "scripts/internal/"
)
```

`git diff` の pathspec `:!path` 形式で差分生成時に除外される。

### B-4. PR モードのフロー

```
内部 repo (GHE)                       レプリカ (github.com)
─────────────────                     ─────────────────────
1. git diff で差分 patch 生成
2. replica を fetch・最新化
3. sync/YYYYMMDD-HHMMSS ブランチ作成
4. patch を適用
5. squash commit (author=Bot)
6. sync ブランチを push             ──► sync/20240401-120000
7. PR を作成                        ──► PR: sync/... → main
8. replica/last-sync タグを更新
```

3rd party は sync PR をレビューし、問題なければ `main` へマージする。

### B-5. モード選択の指針

| | `pr` | `direct` | `patch` |
|---|---|---|---|
| 3rd party によるレビュー | 可能 | 不可 | 不可（手動受け渡し後に可） |
| 適用タイミングの制御 | 3rd party 側 | 社内側 | 社内側 |
| GHE → github.com の疎通 | 必要 | 必要 | 不要 |
| 適したケース | 協調度が高い | 迅速に反映したい | セキュリティ要件が厳しい |

---

## [C] 外部PR取り込み

### 概要

3rd party が github.com レプリカ上で `feature → main` の PR を作成する。
この PR を社内でレビューし、必要なものだけ採用して GHE の内部 repo に取り込む。
外部レプリカの `main` には直接マージしない。

```
github.com (レプリカ)                GHE (内部)
─────────────────────                ──────────
3rd party が PR 作成
  feature/foo → main
        │
        │ CI が patch と meta を生成
        │ （Artifact としてアップロード）
        │
        │ ファイルを社内に受け渡し
        │                            apply-external-pr.sh を実行
        │                              → external/3rdparty-pr-N ブランチ
        │                              → 内部 PR を自動作成
        │                              → 内部でレビュー
        │
        │                            採用判断
        │                              → cherry-pick で main に取り込み
        │
        │                            notify-external-pr.sh で結果通知
        ▼
  外部 PR を Close（マージしない）
        ↓
  次回 milestone sync で変更が反映される
```

### C-1. 外部PR差分生成 (`pr-to-internal.yml`)

github.com レプリカ側の GitHub Actions。
PR 作成・更新時に patch と meta を Artifact として保存する。

```yaml
# .github/workflows/pr-to-internal.yml
on:
  pull_request:
    types: [opened, synchronize]
    branches: [main]

jobs:
  generate-patch:
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Generate patch and meta
        run: |
          gh pr diff ${{ github.event.pull_request.number }} \
            --patch > pr.patch

          cat > pr-meta.json << EOF
          {
            "pr_number": ${{ github.event.pull_request.number }},
            "pr_title":  "${{ github.event.pull_request.title }}",
            "pr_body":   "${{ github.event.pull_request.body }}",
            "pr_author": "${{ github.event.pull_request.user.login }}",
            "pr_url":    "${{ github.event.pull_request.html_url }}",
            "head_sha":  "${{ github.event.pull_request.head.sha }}"
          }
          EOF

      - uses: actions/upload-artifact@v4
        with:
          name: pr-${{ github.event.pull_request.number }}
          path: |
            pr.patch
            pr-meta.json
```

Artifact を社内担当者がダウンロードし、次の apply スクリプトに渡す。

### C-2. 社内への適用 (`apply-external-pr.sh`)

```bash
./apply-external-pr.sh --patch pr.patch --meta pr-meta.json
```

内部処理フロー:

```
1. meta.json からPR情報を読み込み
2. 内部 repo を最新化（git fetch + merge --ff-only）
3. external/3rdparty-pr-{N} ブランチを作成
   （同PR再送時は既存ブランチを --force-with-lease で更新）
4. git apply --3way でパッチ適用
   失敗時: 競合箇所を表示して終了（手動解消を促す）
5. author=Bot でコミット
   コミットメッセージに元PR URL・外部作者を記録
6. GHE へ push（--force-with-lease）
7. 内部 PR を作成
   既存 PR がある場合は作成をスキップ（push 済みで更新される）
```

### C-3. 変更の部分採用 (`cherry-pick-partial.sh`)

外部 PR をまるごと採用する場合:

```bash
git checkout main
git cherry-pick external/3rdparty-pr-123
```

特定パスの変更のみ採用する場合:

```bash
git checkout main
git checkout external/3rdparty-pr-123 -- \
  services/api/src/Foo.kt \
  services/api/src/Bar.kt
git commit -m "external(partial): FooBar の変更のみ採用"
```

patch ファイルからパス指定で適用する場合:

```bash
./cherry-pick-partial.sh \
  --patch pr-123.patch \
  --meta  pr-123-meta.json \
  --paths "services/api/" "services/common/" \
  --message "API 変更のみ採用"
```

### C-4. 採否通知 (`notify-external-pr.sh`)

```bash
# 全部採用
./notify-external-pr.sh --meta pr-123-meta.json --status accepted

# 一部採用
./notify-external-pr.sh --meta pr-123-meta.json --status partial

# 却下
./notify-external-pr.sh --meta pr-123-meta.json \
  --status rejected \
  --reason "設計方針と不一致"
```

`rejected` の場合は外部 PR を自動的に Close する。
`accepted` / `partial` の場合は次回 milestone sync まで外部 PR をオープンのまま維持し、sync 後に手動で Close する。

### C-5. 外部PR運用状態遷移

```
外部 PR の状態        内部での対応
────────────────      ──────────────────────────────────────────
opened              → apply-external-pr.sh を実行
                      内部 PR (external/3rdparty-pr-N) が作成される

synchronize         → Artifact を再ダウンロードして再実行
（3rd party が更新）   既存ブランチを --force-with-lease で上書き

内部 PR レビュー中    → 採用範囲を決定
  → 全部採用         → cherry-pick
  → 一部採用         → cherry-pick-partial.sh
  → 却下             → 内部 PR を Close

採用後               → notify-external-pr.sh --status accepted
                      次回 milestone sync で外部 main に反映
                      sync 完了後に外部 PR を Close（マージしない）

却下後               → notify-external-pr.sh --status rejected
                      外部 PR を Close
```

---

## タグ管理まとめ

すべてのタグは社内 GHE の `internal-monorepo` 側に保持する。

| タグ名 | 種別 | 役割 |
|---|---|---|
| `replica/last-sync` | 可動（`-f` で上書き） | 次回 diff の起点。sync 完了後に HEAD へ前進 |
| `replica/sync-YYYYMMDD-HHMMSS` | 不変 | 各同期の記録。任意で作成 |
| `milestone/YYYY-QN` | 不変 | マイルストーク基点。初回セットアップの `START_TAG` にも使用 |

---

## CI 自動化（任意）

マイルストーンタグをトリガーに同期を自動実行する場合の GHE Actions 構成:

```yaml
# .github/workflows/sync-replica.yml (GHE 側)
on:
  push:
    tags:
      - 'milestone/*'   # milestone/2024-Q1 をトリガーに

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GHE_TOKEN }}

      - name: Setup github.com Deploy Key
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.GITHUB_COM_DEPLOY_KEY }}" \
            > ~/.ssh/id_ed25519_github
          chmod 600 ~/.ssh/id_ed25519_github
          cat >> ~/.ssh/config << EOF
          Host github.com
            HostName github.com
            User git
            IdentityFile ~/.ssh/id_ed25519_github
          EOF

      - name: Clone replica
        run: git clone git@github.com:your-org/replica.git /tmp/replica

      - name: Run sync
        run: |
          ./scripts/sync-to-replica.sh \
            --mode pr \
            "sync: ${{ github.ref_name }}"
```

---

## オペレーションチェックリスト

### 初回セットアップ

- [ ] github.com に空のレプリカ repo を作成
- [ ] Bot 用 SSH 鍵を生成し GHE・github.com に登録
- [ ] `~/.ssh/config` を設定
- [ ] 内部 repo に開始タグ `milestone/YYYY-QN` を作成
- [ ] `init-replica.sh` を実行
- [ ] レプリカの `main` に Branch Protection を設定（Bot のみ push 許可）
- [ ] 3rd party に招待を送付

### マイルストーン同期

- [ ] 内部 repo で `milestone/YYYY-QN` タグを作成
- [ ] `sync-to-replica.sh` を実行（または CI が自動実行）
- [ ] `pr` モードの場合: 3rd party が sync PR をレビュー・マージ
- [ ] `patch` モードの場合: パッチ適用確認後に `replica/last-sync` を手動更新
- [ ] 任意: `replica/sync-TIMESTAMP` タグで同期履歴を記録

### 外部PR取り込み

- [ ] github.com の PR から Artifact (patch + meta) をダウンロード
- [ ] `apply-external-pr.sh` を実行
- [ ] 内部 PR をレビュー
- [ ] 採用範囲を決定し `cherry-pick` または `cherry-pick-partial.sh` を実行
- [ ] `notify-external-pr.sh` で外部 PR に採否を通知
- [ ] 採用の場合: 次回 milestone sync 後に外部 PR を Close
- [ ] 却下の場合: 外部 PR は自動 Close 済み
