# Monorepo レプリカ管理 オペレーションガイド

## 全体構成

```
GitHub Enterprise (社内)                         github.com (社外レプリカ)
────────────────────────────────────             ─────────────────────────
github.your-company.com                          github.com
  └── org/internal-monorepo                        └── your-org/replica
        │                                                │
        │  [A] publish ブランチ初期化                     ├── main   ← 同期先
        │      init-replica.sh                           └── 3rdparty/foo  ← 3rd party 開発
        │        → GHE PR: init/TIMESTAMP → publish
        │        → [社内レビュー・マージ]
        │        → publish に初期スナップショット反映
        │
        │  [B] マイルストーン同期（2フェーズ）
        │
        │  フェーズ1: stage-publish.sh
        │    internal/main
        │      → squash + EXCLUDE_PATHS 除外
        │      → GHE PR: sync/TIMESTAMP → publish
        │      → [社内レビュー・マージ]
        │      → publish に反映
        │
        │  フェーズ2: deliver-to-replica.sh    ──────────────────────►
        │    publish                                  external/main に反映
        │      → push (pr/direct)
        │         または patch + apply.sh 出力
        │
        │  [C] 外部PR取り込み                  ◄──────────────────────
        │
  タグ (すべて internal-monorepo に保持)
    publish/init-TIMESTAMP              ← publish ブランチ初回作成の記録（party 非依存）
    replica/<party>/init-TIMESTAMP      ← 各 party への初回配送記録
    replica/<party>/last-sync           ← 最後に配送した publish HEAD（可動・party ごと）
    replica/<party>/sync-TIMESTAMP      ← 各配送の不変記録
    milestone/YYYY-QN                   ← マイルストーン基点
```

---

## 登場スクリプト一覧

| スクリプト | 実行環境 | 用途 |
|---|---|---|
| `init-replica.sh` | 社内 | publish ブランチ初期化（GHE PR フロー） |
| `stage-publish.sh` | 社内 | マイルストーン同期 フェーズ1: squash して GHE PR 作成 |
| `deliver-to-replica.sh` | 社内 | マイルストーン同期 フェーズ2: publish ブランチから外部へ配送 |
| `sync-to-replica.sh` | 社内 | マイルストーン同期（旧方式・後方互換用） |
| `pr-to-internal.yml` | github.com CI | 外部PR差分生成 |
| `apply-external-pr.sh` | 社内 | 外部PRの社内適用・PR作成 |
| `cherry-pick-partial.sh` | 社内 | 外部PR変更の部分採用 |
| `notify-external-pr.sh` | 社内 | 外部PRへの採否通知 |

---

## 設定ファイル

### `config/sync.conf`（共通設定）

全スクリプトは `config/sync.conf` を `source` して動作する。
`config/sync.conf.example` をコピーして環境に合わせて編集する。

```bash
cp config/sync.conf.example config/sync.conf
$EDITOR config/sync.conf
```

### `config/party/<party>.conf`（party ごとの設定）

レプリカへの接続情報（`REPLICA_*`）は party ごとに異なるため、
`config/party/<party>.conf` として分離する。

```bash
cp config/party/party.conf.example config/party/acme.conf
$EDITOR config/party/acme.conf
```

`deliver-to-replica.sh` は `--party acme` が渡されると `config/party/acme.conf` を自動的に `source` する。

`sync.conf` および `config/party/*.conf` は `.gitignore` 済みであり、リポジトリにはコミットされない。

### 設定項目一覧

列はオペレーションのフェーズに対応する。

| 凡例 | 意味 |
|---|---|
| **必須** | そのフェーズでスクリプトが参照する |
| 注記付き | 一部のモードまたは条件でのみ必要 |
| ― | そのフェーズでは参照しない |

列の対応スクリプト:

| 列 | スクリプト |
|---|---|
| `[A] init` | `init-replica.sh` |
| `[B-1] stage` | `stage-publish.sh` |
| `[B-2] deliver` | `deliver-to-replica.sh` |
| `[C] external` | `apply-external-pr.sh` / `cherry-pick-partial.sh` / `notify-external-pr.sh` |

#### `config/sync.conf` — 社内リポジトリ (GHE)

| 変数 | 説明 | `[A] init` | `[B-1] stage` | `[B-2] deliver` | `[C] external` | 例 |
|---|---|:---:|:---:|:---:|:---:|---|
| `INTERNAL_REPO` | 社内 monorepo のローカルパス（絶対パス） | **必須** | **必須** | **必須** | apply/cherry-pick のみ | `/path/to/internal-monorepo` |
| `INTERNAL_REMOTE` | GHE の remote 名 | **必須** | **必須** | ― | apply/cherry-pick のみ | `origin` |
| `GH_HOST` | GHE のホスト名（`gh` CLI の `GH_HOST` に使用） | **必須** | **必須** | ― | apply のみ | `github.your-company.com` |
| `GH_ORG` | GHE の Organization 名 | **必須** | **必須** | ― | apply のみ | `org` |
| `GH_REPO` | GHE のリポジトリ名 | **必須** | **必須** | ― | apply のみ | `internal` |

#### `config/sync.conf` — 同期設定

| 変数 | 説明 | `[A] init` | `[B-1] stage` | `[B-2] deliver` | `[C] external` | 備考 |
|---|---|:---:|:---:|:---:|:---:|---|
| `SYNC_AUTHOR_NAME` | コミット・タグの author 名 | **必須** | **必須** | push のみ | apply/cherry-pick のみ | 社内開発者名を外部に出さないための Bot 名 |
| `SYNC_AUTHOR_EMAIL` | コミット・タグの author メールアドレス | **必須** | **必須** | push のみ | apply/cherry-pick のみ | 同上 |
| `EXCLUDE_PATHS` | レプリカへの同期から除外するパスの配列 | **必須** | **必須** | ― | ― | `init` / `stage-publish` で適用済みのため deliver では不要 |
| `PATCH_OUTPUT_DIR` | `--output patch` 時の出力先ディレクトリ | ― | ― | patch のみ | ― | 未設定時は `./sync-patches` |

`EXCLUDE_PATHS` の設定例:

```bash
EXCLUDE_PATHS=(
  "services/internal-only/"   # 社内のみのサービス
  ".internal/"                # 社内設定ファイル
  "scripts/internal/"         # 社内用スクリプト
)
```

#### `config/party/<party>.conf` — レプリカリポジトリ (github.com)

| 変数 | 説明 | `[A] init` | `[B-1] stage` | `[B-2] deliver` | `[C] external` | 例 |
|---|---|:---:|:---:|:---:|:---:|---|
| `REPLICA_REPO` | レプリカのローカルパス（絶対パス） | ― | ― | push のみ | ― | `/path/to/replica-acme` |
| `REPLICA_REMOTE` | レプリカの remote 名 | ― | ― | push のみ | ― | `origin` |
| `REPLICA_BRANCH` | レプリカの同期先ブランチ | ― | ― | push のみ | ― | `main` |
| `REPLICA_GH_REPO` | github.com の `組織名/リポジトリ名` | ― | ― | push かつ pr mode のみ | notify のみ | `your-org/replica-acme` |

---

## [A] publish ブランチ初期化

### 前提条件

- 社内 GHE に `org/internal-monorepo` が存在する
- SSH 設定で GHE を使える（後述）
- 開始タグ（`milestone/2024-Q1` など）が作成済み

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

### A-2. publish ブランチ作成

`init-replica.sh` は `git archive` でファイルツリーのスナップショットを取り出し（`EXCLUDE_PATHS` 適用済み）、
GHE 上に PR を作成する。PR をレビュー・マージすることで `publish` ブランチが初期化される。

```bash
./scripts/init-replica.sh milestone/2024-Q1

# タグにメモを付与する場合
./scripts/init-replica.sh --message "3rd party 協業開始" milestone/2024-Q1
```

**引数 `START_TAG` はタグ名でなければならない。** ブランチ名を渡すとエラーになる。

```
[ err ] 'main' is not a tag. Specify a tag (e.g. milestone/v1), not a branch.
```

ブランチ名を拒否する理由: ブランチは可動なため、同じコマンドを翌日実行すると別のスナップショットが取られてしまう。
`publish/init-TIMESTAMP` タグに「どの時点のスナップショットか」を確定的に記録するためには、
不変のタグを指定する必要がある。

スクリプトが行うこと:

```
1. git archive で START_TAG 時点のファイルツリーを展開（コミット履歴を含まない）
2. EXCLUDE_PATHS を除外
3. publish ブランチを空のベースコミットで作成
4. init/TIMESTAMP ブランチにスナップショット内容をコミット（author=Bot）
5. GHE に push し PR 作成: init/TIMESTAMP → publish
6. publish/init-TIMESTAMP タグを START_TAG に設定
```

**git の hint メッセージについて:**

実行時に以下の hint が表示されることがある:

```
hint: You have created a nested tag. The object referred to by your new tag is
hint: already a tag. If you meant to tag the object that it points to, use:
hint:   git tag -f publish/init-TIMESTAMP milestone/v1^{}
```

これはエラーでも警告でもなく、動作に問題はない。

発生する理由: `publish/init-TIMESTAMP` タグが `milestone/v1` という別のタグオブジェクトを指す
（タグがタグを指す = nested tag）ため、git が「コミットを直接指すつもりなら `^{}` を使え」と
アドバイスしている。今回は「どのマイルストーンタグから開始したか」を記録する意図があるため、
タグオブジェクトを指すのは正しい設計であり、hint は無視してよい。

気になる場合は以下で抑制できる:

```bash
git config set advice.nestedTag false
```

実行後の状態:

```
内部 monorepo
A - B - C - D - E        (main)
                ↑
          milestone/2024-Q1
          publish/init-TIMESTAMP   ← スナップショット元の記録

publish: [empty] ← init/TIMESTAMP (PR レビュー待ち)
```

PR をマージすると:

```
publish: [empty base] ─ [snapshot commit]
                                ↑ HEAD
```

### A-3. 3rd party への初回配送

PR マージ後、3rd party ごとに `deliver-to-replica.sh` を実行する。
初回配送時は `last-sync` タグがないため、`publish` の最初のコミットから全量を配送する。

```bash
# push モード（直接 git push）
./scripts/deliver-to-replica.sh --party acme "initial: 2024-Q1"

# patch モード（ファイルで受け渡し）
./scripts/deliver-to-replica.sh --party acme --output patch "initial: 2024-Q1"
```

初回配送完了後に以下のタグが作成される:

```
replica/acme/init-TIMESTAMP  ← この party への初回配送記録（不変）
replica/acme/last-sync       ← 配送完了点（可動）
replica/acme/sync-TIMESTAMP  ← 配送の不変記録
```

---

## [B] マイルストーン同期

### 概要

マイルストーン同期は2フェーズで行う。

```
[フェーズ1: stage-publish.sh]
  internal/main
    → squash + EXCLUDE_PATHS 除外
    → GHE PR: sync/TIMESTAMP → publish
    → [社内レビュー・承認・マージ]
    → publish に squash コミットが積まれる

[フェーズ2: deliver-to-replica.sh]
  publish
    → push (--mode pr/direct)
       または
       patch + apply.sh 出力
    → external/main に反映
    → replica/<party>/last-sync タグを publish HEAD に更新
```

`publish` ブランチは社内 GHE にのみ存在し、外部には push しない。
全 party に共通の「社外に送った内容」の正本として機能する。
各 party の配送完了位置は `replica/<party>/last-sync` タグで独立して管理する。

### B-1. ブランチとタグの役割

```
内部 monorepo (GHE)

main:     A - B - C - D - E - F - G
                                   ↑ INTERNAL_HEAD

publish:  P1 ── P2 ── P3
          ↑            ↑
    (START_TAG)   squash コミット（Bot author）
                       ↑
              replica/acme/last-sync  ← acme の配送完了点（可動）
              replica/beta/last-sync  ← beta の配送完了点（可動・別 party の例）

sync/TIMESTAMP: P3 ─ (マージ前の PR ブランチ)
```

| 名前 | 種別 | 役割 |
|---|---|---|
| `publish` | ブランチ | squash 済みの配送正本（全 party 共有）。社内でレビュー可能 |
| `replica/<party>/last-sync` | 可動タグ | `publish` ブランチ上の最後に配送したコミットを指す（party ごと独立） |
| `publish/init-TIMESTAMP` | 不変タグ | publish ブランチ初回作成の記録（party 非依存） |
| `replica/<party>/init-TIMESTAMP` | 不変タグ | 各 party への初回配送記録 |
| `replica/<party>/sync-TIMESTAMP` | 不変タグ | 各配送の不変記録 |

### B-2. フェーズ1: publish ブランチへのステージ (`stage-publish.sh`)

`internal/main` の差分を squash して `publish` への PR を GHE 上に作成する。
`--party` 引数は不要。publish ブランチは party 非依存。

```bash
./scripts/stage-publish.sh "sync: 2024-Q1"
```

内部フロー:

```
1. publish HEAD と internal/main HEAD の差分を取得
2. EXCLUDE_PATHS を除外したパッチを生成
3. worktree で sync/TIMESTAMP ブランチを publish から作成
4. パッチを適用・squash commit (author=Bot)
5. sync ブランチを GHE へ push
6. GHE 上に PR 作成: sync/TIMESTAMP → publish
   （PR 本文に含まれる内部コミット一覧を記載）
```

PR をレビュー・承認後に `publish` へマージする。
**このフェーズでは `replica/<party>/last-sync` タグを更新しない。**

### B-3. フェーズ2: 外部レプリカへの配送 (`deliver-to-replica.sh`)

`publish` ブランチの内容を外部レプリカへ配送する。
配送元は `replica/<party>/last-sync` から `publish` HEAD までの差分。
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
├── sync-20240401-120000.patch       # 差分 patch（publish ブランチベース）
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

`EXCLUDE_PATHS` は `init-replica.sh`（初期化）と `stage-publish.sh`（フェーズ1）でのみ適用される。
`publish` ブランチは除外済みのクリーンな状態になるため、
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
        │                              → external/<party>-pr-N ブランチ
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
3rd party が `main` へ PR を作成・更新した際に patch と meta を Artifact として保存する。
Artifact を社内担当者がダウンロードし、次の apply スクリプトに渡す。

#### トリガー設計: `pull_request_target`

`pull_request` イベントでは `GITHUB_TOKEN` が PR API へのアクセス権を持たず、
`gh pr diff` / `gh pr view` が HTTP 403 になる。
そのため `pull_request_target` を使用する。

| 項目 | `pull_request` | `pull_request_target` |
|---|---|---|
| 実行コンテキスト | PR ヘッドのコード | ベースリポジトリ（`main`）のコード |
| `GITHUB_TOKEN` の PR API アクセス | 不可（HTTP 403） | 可能 |
| セキュリティリスク | 低い | PR ヘッドのコードを checkout すると高い |

**本ワークフローは PR ヘッドを checkout しない**（diff は API 経由で取得）ため、
`pull_request_target` を安全に使用できる。

#### `sync/*` ブランチのスキップ

`deliver-to-replica.sh` が作成するデリバリー PR のヘッドブランチは `sync/TIMESTAMP` 形式。
これは社内からの同期配送であり、3rd party の開発変更ではないため、ジョブレベルの `if` 条件でスキップする。

```yaml
if: ${{ !startsWith(github.head_ref, 'sync/') }}
```

ワークフロー自体はトリガーされるが、ジョブが "skipped" となる。

#### 生成される Artifact

| ファイル | 内容 |
|---|---|
| `pr.patch` | PR の差分（`git apply` で適用可能な形式） |
| `pr-meta.json` | PR 番号・タイトル・本文・author・URL・head SHA |

Artifact 名: `pr-{PR番号}-{head SHA}`（保持期間: 30日）

#### 複数回トリガーの動作（`synchronize` イベント）

`pull_request_target` のトリガー条件は `opened` と `synchronize`。
3rd party が PR をオープンしたままブランチに追加コミットをプッシュするたびに
`synchronize` イベントが発火し、ワークフローが再実行される。

このとき:
- 新しい Artifact が `pr-{PR番号}-{新 head SHA}` という名前で生成される
- 古い Artifact（前回の head SHA 付き）は残ったまま
- 社内担当者は**最新の head SHA に対応する Artifact のみを使用**すればよい

これにより 3rd party が PR のレビュー中にコードを修正しても、
社内は常に最新の差分で内部 PR を作成できる。

#### PR へのコメント

ワークフロー完了時に PR へ自動コメントを投稿して、社内への転送を通知する。
PR に複数回プッシュがあった場合、コメントもその都度追加される。

### C-2. 社内への適用 (`apply-external-pr.sh`)

```bash
./apply-external-pr.sh --party acme --patch pr.patch --meta pr-meta.json
```

`--party` は省略可能（省略時は `3rdparty` をブランチ名プレフィックスに使用）。

内部処理フロー:

```
1. meta.json からPR情報を読み込み
2. 内部 repo を最新化（git fetch + merge --ff-only）
3. external/<party>-pr-{N} ブランチを作成
   （同PR再送時は既存ブランチを --force-with-lease で更新）
4. git apply --3way でパッチ適用
   失敗時: 競合箇所を表示して終了（手動解消を促す）
5. author=Bot でコミット
   コミットメッセージに元PR URL・外部作者を記録
6. GHE へ push（--force-with-lease）
7. 内部 PR を作成（ラベル: external-contribution）
   既存 PR がある場合は作成をスキップ（push 済みで更新される）
```

### C-3. 変更の部分採用 (`cherry-pick-partial.sh`)

外部 PR をまるごと採用する場合:

```bash
git checkout main
git cherry-pick external/acme-pr-123
```

特定パスの変更のみ採用する場合:

```bash
git checkout main
git checkout external/acme-pr-123 -- \
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

採否結果を外部 PR にコメントで通知する。配送方法に応じて 2 つの出力モードがある。

#### push モード（デフォルト）

社内から直接 `gh pr comment` を実行する。`REPLICA_GH_REPO` へのアクセス権が必要。

```bash
# 全部採用
./scripts/notify-external-pr.sh --party acme --meta pr-123-meta.json --status accepted

# 一部採用
./scripts/notify-external-pr.sh --party acme --meta pr-123-meta.json --status partial

# 却下
./scripts/notify-external-pr.sh --party acme --meta pr-123-meta.json \
  --status rejected \
  --reason "設計方針と不一致"
```

#### patch モード（レプリカリポジトリへの直接アクセスが不可の場合）

通知パッケージ（スクリプト + メタ）を生成して 3rd party に送付する。
3rd party が自分のマシンで実行することで PR にコメントが投稿される。

```bash
./scripts/notify-external-pr.sh --party galaxy --meta pr-123-meta.json \
  --status accepted \
  --output patch
```

生成されるファイル:

| ファイル | 内容 |
|---|---|
| `notify-TIMESTAMP-meta.json` | PR 番号・コメント本文・close フラグ・リポジトリ名 |
| `notify-TIMESTAMP.sh` | 3rd party が実行するスタンドアロンスクリプト |

3rd party 側の実行コマンド（`gh` CLI と `jq` が必要）:

```bash
./notify-TIMESTAMP.sh
```

出力先ディレクトリは `sync.conf` の `NOTIFY_OUTPUT_DIR`（デフォルト: `./sync-patches`）で設定できる。

#### 共通の動作

`rejected` の場合は外部 PR を自動的に Close する。
`accepted` / `partial` の場合は次回 milestone sync まで外部 PR をオープンのまま維持し、sync 後に手動で Close する。

### C-5. 外部PR運用状態遷移

```
外部 PR の状態        内部での対応
────────────────      ──────────────────────────────────────────
opened              → apply-external-pr.sh を実行
                      内部 PR (external/<party>-pr-N) が作成される

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
タグはすべてアノテーションタグ（`git tag -a`）で作成し、party・output・timestamp 等のメタ情報をメッセージに記録する。

| タグ名 | 種別 | 作成スクリプト | 役割 |
|---|---|---|---|
| `publish/init-TIMESTAMP` | 不変 | `init-replica.sh` | publish ブランチ初回作成の記録（party 非依存） |
| `replica/<party>/init-TIMESTAMP` | 不変 | `deliver-to-replica.sh`（初回配送時） | 各 party への初回配送記録 |
| `replica/<party>/last-sync` | 可動（`-f` で上書き） | `deliver-to-replica.sh` 配送完了時 | 最後に配送した `publish` HEAD を指す（party ごと独立） |
| `replica/<party>/sync-TIMESTAMP` | 不変 | `deliver-to-replica.sh` 配送完了時 | 各配送の不変記録 |
| `milestone/YYYY-QN` | 不変 | 手動 | マイルストーン基点。init の `START_TAG` にも使用 |

タグに記録されるメタ情報の例（`git show replica/acme/last-sync`）:

```
tag replica/acme/last-sync
Tagger: Platform Sync Bot <sync-bot@your-company.com>
Date:   Mon Apr 1 12:00:00 2024 +0900

party: acme
output: push
mode: pr
commit_msg: sync: 2024-Q1
publish_head: a1b2c3d4...
timestamp: 20240401-120000
```

---

## CI 自動化（任意）

2フェーズ構成のうちフェーズ1（`stage-publish.sh`）はマイルストーンタグをトリガーに自動実行できる。
フェーズ2（`deliver-to-replica.sh`）は publish PR のマージをトリガーにするか、手動実行する。

### フェーズ1 CI（マイルストーンタグ → GHE PR 作成）

```yaml
# .github/workflows/sync-replica.yml (GHE 側)
on:
  push:
    tags:
      - 'milestone/*'   # milestone/2024-Q1 をトリガーに

jobs:
  stage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GHE_TOKEN }}

      - name: Stage publish PR
        env:
          GH_TOKEN: ${{ secrets.GHE_TOKEN }}
        run: |
          ./scripts/stage-publish.sh \
            "sync: ${{ github.ref_name }}"
```

### フェーズ2 CI（publish PR マージ → 外部レプリカへ配送）

publish ブランチは全 party 共有のため、PR のラベルで配送先 party を特定する。

```yaml
# .github/workflows/deliver-replica.yml (GHE 側)
on:
  pull_request:
    types: [closed]
    branches:
      - 'publish'   # publish へのマージをトリガーに

jobs:
  deliver:
    if: github.event.pull_request.merged == true
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

      - name: Determine party from PR labels
        id: party
        run: |
          # PR に "party:acme" 形式のラベルを付与する運用を想定
          PARTY=$(echo '${{ toJSON(github.event.pull_request.labels) }}' \
            | jq -r '.[] | select(.name | startswith("party:")) | .name | ltrimstr("party:")')
          [[ -n "$PARTY" ]] || { echo "No party: label found on PR"; exit 1; }
          echo "name=$PARTY" >> "$GITHUB_OUTPUT"

      - name: Clone replica
        run: git clone "${{ secrets.REPLICA_CLONE_URL }}" /tmp/replica

      - name: Deliver to replica
        env:
          GH_TOKEN: ${{ secrets.GITHUB_COM_TOKEN }}
        run: |
          ./scripts/deliver-to-replica.sh \
            --party "${{ steps.party.outputs.name }}" \
            "${{ github.event.pull_request.title }}"
```

---

## オペレーションチェックリスト

### publish ブランチ初期化

- [ ] Bot 用 SSH 鍵を生成し GHE・github.com に登録
- [ ] `~/.ssh/config` を設定
- [ ] 内部 repo に開始タグ `milestone/YYYY-QN` を作成
- [ ] `config/sync.conf` を設定（`EXCLUDE_PATHS` を確認）
- [ ] `init-replica.sh milestone/YYYY-QN` を実行
- [ ] GHE 上の PR（init/... → publish）をレビュー・承認・マージ

### 3rd party の追加（初回配送）

- [ ] `config/party/<party>.conf` を作成
- [ ] github.com に空のレプリカ repo を作成（push モードの場合）
- [ ] `deliver-to-replica.sh --party <name> "initial: YYYY-QN"` を実行
- [ ] レプリカの `main` に Branch Protection または Ruleset を設定（下記参照）
- [ ] 3rd party に招待を送付

#### レプリカ `main` ブランチの保護設定

3rd party が `main` へ直接 push したり、PR をマージしてしまわないようにするための設定。
2 つの方法がある。

---

##### 方法 1: Branch Protection Rules（簡易）

GitHub リポジトリの `Settings` → `Branches` → `Add branch protection rule` で `main` を対象に設定する。

| 設定項目 | 推奨値 | 目的 |
|---|---|---|
| Require a pull request before merging | ✅ オン | 直接 push を禁止 |
| Required number of approvals | 2 以上（承認者が揃わない値） | 事実上マージ不能にする |
| Do not allow bypassing the above settings | ✅ オン | 管理者もルールに従う |

**制限**: Branch Protection Rules はブランチ名パターンで適用対象を分けられないため、
`sync/*` ブランチ（`deliver-to-replica.sh` が作成するデリバリー PR）にも同じルールが適用される。
デリバリー PR は Bot が push するため、Bot アカウントを `Bypass list` に追加するか、
方法 2 の Ruleset を使う。

---

##### 方法 2: Rulesets（推奨・より厳密）

GitHub リポジトリの `Settings` → `Rules` → `Rulesets` → `New branch ruleset` で設定する。

**Ruleset 1: `main` 直接 push 禁止**

| 項目 | 設定値 |
|---|---|
| Name | `protect-main` |
| Enforcement | Active |
| Target branches | `main` |
| Restrict creations | ✅ |
| Restrict deletions | ✅ |
| Require a pull request before merging | ✅、required approvals: 2 以上 |
| Block force pushes | ✅ |
| Bypass list | Bot アカウント（`deliver-to-replica.sh` が使う GitHub ユーザー）を追加 |

**Ruleset 2: `sync/*` PR のマージ許可（Bypass 不要の場合は省略可）**

Ruleset の `Bypass list` に Bot アカウントを追加することで、
`deliver-to-replica.sh` による `sync/*` → `main` のマージは Bot が行えるようになる。
3rd party ユーザーは `main` への直接 push もマージもできない。

**Rulesets の利点**:
- ブランチパターン・actor（ユーザー/チーム）単位で細かく制御できる
- 複数 Ruleset の組み合わせが可能
- Organization レベルでの一括適用もできる（Organization Rulesets）

### マイルストーン同期

**フェーズ1（ステージ）**
- [ ] 内部 repo で `milestone/YYYY-QN` タグを作成
- [ ] `stage-publish.sh "sync: YYYY-QN"` を実行
- [ ] GHE 上の PR（sync/... → publish）をレビュー・承認・マージ

**フェーズ2（配送）**
- [ ] `deliver-to-replica.sh --party <name>` を実行（3rd party ごとに繰り返す）
- [ ] `--output push --mode pr` の場合: 3rd party が sync PR をレビュー・マージ
- [ ] `--output push --mode direct` の場合: push 完了で完了
- [ ] `--output patch` の場合: patch / meta.json / apply.sh を 3rd party へ送付
- [ ] `--output patch` の場合: タグはパッチセット生成時に自動更新される

### 外部PR取り込み

- [ ] github.com の PR から Artifact (patch + meta) をダウンロード
- [ ] `apply-external-pr.sh` を実行
- [ ] 内部 PR をレビュー
- [ ] 採用範囲を決定し `cherry-pick` または `cherry-pick-partial.sh` を実行
- [ ] `notify-external-pr.sh` で外部 PR に採否を通知
- [ ] 採用の場合: 次回 milestone sync 後に外部 PR を Close
- [ ] 却下の場合: 外部 PR は自動 Close 済み
