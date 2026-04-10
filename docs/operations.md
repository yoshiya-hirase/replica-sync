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
| `init-replica.sh` | 社内 | 初回レプリカ作成・publish ブランチ初期化 |
| `stage-publish.sh` | 社内 | マイルストーン同期 フェーズ1: squash して GHE PR 作成 |
| `deliver-to-replica.sh` | 社内 | マイルストーン同期 フェーズ2: publish ブランチから外部へ配送 |
| `sync-to-replica.sh` | 社内 | マイルストーン同期（旧方式・後方互換用） |
| `pr-to-internal.yml` | github.com CI | 外部PR差分生成 |
| `apply-external-pr.sh` | 社内 | 外部PRの社内適用・PR作成 |
| `cherry-pick-partial.sh` | 社内 | 外部PR変更の部分採用 |
| `notify-external-pr.sh` | 社内 | 外部PRへの採否通知 |

---

## 設定ファイル (`config/sync.conf`)

全スクリプトは `config/sync.conf` を `source` して動作する。
`config/sync.conf.example` をコピーして環境に合わせて編集する。

```bash
cp config/sync.conf.example config/sync.conf
$EDITOR config/sync.conf
```

`sync.conf` は `.gitignore` 済みであり、リポジトリにはコミットされない。

### 設定項目一覧

凡例: **必須** = スクリプトが参照する / **―** = そのスクリプトでは参照しない

#### 社内リポジトリ (GHE)

| 変数 | 説明 | init `push` | init `export` | sync | 例 |
|---|---|:---:|:---:|:---:|---|
| `INTERNAL_REPO` | 社内 monorepo のローカルパス（絶対パス） | **必須** | **必須** | **必須** | `/path/to/internal-monorepo` |
| `INTERNAL_REMOTE` | GHE の remote 名 | ― | ― | **必須** | `origin` |
| `GH_HOST` | GHE のホスト名（`gh` CLI の `GH_HOST` に使用） | ― | ― | **必須** | `github.your-company.com` |
| `GH_ORG` | GHE の Organization 名 | ― | ― | **必須** | `org` |
| `GH_REPO` | GHE のリポジトリ名 | ― | ― | **必須** | `internal` |

#### レプリカリポジトリ (github.com)

| 変数 | 説明 | init `push` | init `export` | sync | 例 |
|---|---|:---:|:---:|:---:|---|
| `REPLICA_REPO` | レプリカのローカルパス（絶対パス） | ― | ― | **必須** | `/path/to/replica` |
| `REPLICA_REMOTE` | レプリカの remote 名 | ― | ― | **必須** | `origin` |
| `REPLICA_BRANCH` | レプリカの同期先ブランチ | ― | ― | **必須** | `main` |
| `REPLICA_GH_REPO` | github.com の `組織名/リポジトリ名`（push 先・`gh pr create` に使用） | **必須** | ― | **必須** | `your-org/replica` |

`export` モードでは 3rd party がリポジトリを作成した後に `REPLICA_GH_REPO` を設定する。

#### 同期設定

凡例の `sync` 列は `stage-publish.sh` / `deliver-to-replica.sh` の両方を指す。

| 変数 | 説明 | init `push` | init `export` | sync | 備考 |
|---|---|:---:|:---:|:---:|---|
| `PUBLISH_BRANCH_PREFIX` | publish ブランチ名のプレフィックス | **必須** | **必須** | **必須** | 未設定時は `publish`。ブランチ名は `<prefix>/<party>` |
| `SYNC_AUTHOR_NAME` | コミット・タグの author 名 | **必須** | **必須** | **必須** | 社内開発者名を外部に出さないための Bot 名 |
| `SYNC_AUTHOR_EMAIL` | コミット・タグの author メールアドレス | **必須** | **必須** | **必須** | 同上 |
| `EXCLUDE_PATHS` | レプリカへの同期から除外するパスの配列 | ― | ― | `stage` のみ | `stage-publish.sh` で適用。`deliver-to-replica.sh` では不要 |

`EXCLUDE_PATHS` の設定例:

```bash
EXCLUDE_PATHS=(
  "services/internal-only/"   # 社内のみのサービス
  ".internal/"                # 社内設定ファイル
  "scripts/internal/"         # 社内用スクリプト
)
```

#### patch モード設定

| 変数 | 説明 | init `push` | init `export` | sync | 例 |
|---|---|:---:|:---:|:---:|---|
| `PATCH_OUTPUT_DIR` | `sync --output patch` 時の出力先ディレクトリ（未設定時は `./sync-patches`） | ― | ― | 省略可 | `./sync-patches` |

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

マイルストーン同期は2フェーズで行う。

```
[フェーズ1: stage-publish.sh]
  internal/main
    → squash + EXCLUDE_PATHS 除外
    → sync/<party>/TIMESTAMP ブランチ（GHE）
    → GHE PR: sync/<party>/... → publish/<party>
    → [社内レビュー・承認・マージ]
    → publish/<party> に squash コミットが積まれる

[フェーズ2: deliver-to-replica.sh]
  publish/<party>
    → push (--mode pr/direct)
       または
       patch + apply.sh 出力
    → external/main に反映
    → replica/<party>/last-sync タグを publish/<party> HEAD に更新
```

`publish/<party>` ブランチは社内 GHE にのみ存在し、外部には push しない。
「社外に送った内容」の正本として機能する。

### B-1. ブランチとタグの役割

```
内部 monorepo (GHE)

main:     A - B - C - D - E - F - G
                                   ↑ INTERNAL_HEAD

publish/acme:  P1 ── P2 ── P3
               ↑            ↑
         (START_TAG)   squash コミット（Bot author）
                            ↑
                   replica/acme/last-sync  ← 配送完了点（可動）

sync/acme/TIMESTAMP: P3 ─ (マージ前の PR ブランチ)
```

| 名前 | 種別 | 役割 |
|---|---|---|
| `publish/<party>` | ブランチ | squash 済みの配送正本。社内でレビュー可能 |
| `replica/<party>/last-sync` | 可動タグ | `publish/<party>` 上の最後に配送したコミットを指す |
| `replica/<party>/init-TIMESTAMP` | 不変タグ | 初回切り出しの記録 |
| `replica/<party>/sync-TIMESTAMP` | 不変タグ | 各配送の不変記録 |

### B-2. フェーズ1: publish ブランチへのステージ (`stage-publish.sh`)

`internal/main` の差分を squash して `publish/<party>` への PR を GHE 上に作成する。

```bash
./scripts/stage-publish.sh --party acme "sync: 2024-Q1"
```

内部フロー:

```
1. publish/<party> HEAD と internal/main HEAD の差分を取得
2. EXCLUDE_PATHS を除外したパッチを生成
3. worktree で sync/<party>/TIMESTAMP ブランチを publish/<party> から作成
4. パッチを適用・squash commit (author=Bot)
5. sync ブランチを GHE へ push
6. GHE 上に PR 作成: sync/<party>/TIMESTAMP → publish/<party>
   （PR 本文に含まれる内部コミット一覧を記載）
```

PR をレビュー・承認後に `publish/<party>` へマージする。
**このフェーズでは `replica/<party>/last-sync` タグを更新しない。**

### B-3. フェーズ2: 外部レプリカへの配送 (`deliver-to-replica.sh`)

`publish/<party>` の内容を外部レプリカへ配送する。
`--output` で配送方法を、`--mode` で適用方法を指定する。

| `--output` | `--mode` | 動作 | last-sync 更新 |
|---|---|---|---|
| `push`（デフォルト） | `pr`（デフォルト） | sync ブランチを push して PR 作成 | 即時 |
| `push` | `direct` | external `main` へ直接 push | 即時 |
| `patch` | `pr`（デフォルト） | パッチセットと apply.sh を出力。3rd party が PR 作成 | 手動（適用確認後） |
| `patch` | `direct` | パッチセットと apply.sh を出力。3rd party が直接適用 | 手動（適用確認後） |

```bash
# PR として push（デフォルト）
./scripts/deliver-to-replica.sh --party acme "sync: 2024-Q1"

# main へ直接 push
./scripts/deliver-to-replica.sh --party acme --mode direct "sync: 2024-Q1"

# パッチセット出力（3rd party が PR を作成）
./scripts/deliver-to-replica.sh --party acme --output patch "sync: 2024-Q1"

# パッチセット出力（3rd party が main へ直接適用）
./scripts/deliver-to-replica.sh --party acme --output patch --mode direct "sync: 2024-Q1"
```

`--output patch` で生成されるファイル:

```
sync-patches/
├── sync-20240401-120000.patch       # 差分 patch（publish/<party> ベース）
├── sync-20240401-120000-meta.json   # メタ情報（PR タイトル・本文・配送範囲等）
├── sync-20240401-120000-summary.txt # publish コミット一覧
└── sync-20240401-120000-apply.sh    # 3rd party が実行するスタンドアロン適用スクリプト
```

`--output patch` では last-sync タグを即時更新しない。
3rd party による適用確認後に以下を手動実行する。

```bash
cd /path/to/internal-monorepo
git tag -a -f replica/<party>/last-sync <PUBLISH_HEAD> -m "delivered: TIMESTAMP"
```

### B-4. 除外パスの管理

`EXCLUDE_PATHS` は `stage-publish.sh`（フェーズ1）でのみ適用される。
`publish/<party>` は除外済みのクリーンな状態になるため、
`deliver-to-replica.sh`（フェーズ2）では再除外しない。

```bash
EXCLUDE_PATHS=(
  "services/internal-only/"
  ".internal/"
  "scripts/internal/"
)
```

### B-5. 配送方法選択の指針

| | `push --mode pr` | `push --mode direct` | `patch --mode pr` | `patch --mode direct` |
|---|---|---|---|---|
| 社内レビュー（publish PR） | 両フローとも共通で可能 | ← | ← | ← |
| 3rd party によるレビュー | 可能 | 不可 | 可能 | 不可 |
| GHE → github.com の疎通 | 必要 | 必要 | 不要 | 不要 |
| 3rd party に gh CLI が必要 | 不要 | 不要 | 必要 | 不要 |
| 適したケース | 協調度が高い | 迅速に反映したい | 疎通不可・レビューあり | 疎通不可・直接適用 |

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

**フェーズ1（ステージ）**
- [ ] 内部 repo で `milestone/YYYY-QN` タグを作成
- [ ] `stage-publish.sh --party <name>` を実行
- [ ] GHE 上の PR（sync/... → publish/...）をレビュー・承認・マージ

**フェーズ2（配送）**
- [ ] `deliver-to-replica.sh --party <name>` を実行
- [ ] `--output push --mode pr` の場合: 3rd party が sync PR をレビュー・マージ
- [ ] `--output push --mode direct` の場合: push 完了で完了
- [ ] `--output patch` の場合: patch / meta.json / apply.sh を 3rd party へ送付
- [ ] `--output patch` の場合: 適用確認後に `replica/<party>/last-sync` を手動更新

### 外部PR取り込み

- [ ] github.com の PR から Artifact (patch + meta) をダウンロード
- [ ] `apply-external-pr.sh` を実行
- [ ] 内部 PR をレビュー
- [ ] 採用範囲を決定し `cherry-pick` または `cherry-pick-partial.sh` を実行
- [ ] `notify-external-pr.sh` で外部 PR に採否を通知
- [ ] 採用の場合: 次回 milestone sync 後に外部 PR を Close
- [ ] 却下の場合: 外部 PR は自動 Close 済み
