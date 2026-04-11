# レプリカ同期 テスト手順ガイド

このガイドは `test/` ディレクトリのスクリプトを使って、replica-sync のオペレーションをローカル環境で一通り検証する手順を示す。

---

## 元のシナリオ

テストシナリオの原案。実装仕様との差異は次節「元のシナリオからの変更点」に記載する。

1. Create a test repo with some test code in main branch → a script
2. Commit some code and files to make several commit histories. In this case, some files would be defined as "exclude contents" in sync.conf → would be a script
3. Create sync.conf defining "exclude contents" → could you create one that works for this test scenario
4. Create a dummy 3rd party repo → would be a script
5. Run `init-replica.sh` to create replica in `publish` branch, which is expected to make a PR on own internal repo
6. Review PR to check if commit records are squashed and "exclude contents" are excluded → I will merge PR once reviewed
7. Commit some code and files to simulate continuous development making commit histories and adding files to be excluded for "delivery" → would be a script that I can run multiple times to populate more commit histories and files as needed
8. Run `stage-publish.sh` to make a PR to update "publish branch"
9. Review PR to check → I will merge PR once reviewed
10. Create a 3rd party repo on GitHub as one of my repositories for this test. `pr-to-internal.yml` should be installed → script to do
11. (Delivery with git-push) Run `deliver-to-replica.sh` to push the current snapshot of "publish branch" to the 3rd party repo created in step 10
12. I review the content in the 3rd party repo → script to check if contents match with one on "publish branch" in own internal repo
13. I review tags for "publish branch" in own internal repo → nice if a script to show the records with gh command
14. Create another 3rd party repo on GitHub as one of my repositories for this test, which is separate from the one created in step 10. This repo will simulate "sync with files" method → the same script as step 10 with the repo name specified
14. (Delivery with files) Run `deliver-to-replica.sh` to create a set of "delivery" files
15. (On 3rd party repo) Apply the "delivery" files to the 3rd party repo created in step 14 and then I review main branch
16. I review tags for "publish branch" in own internal repo in the same way as step 13
17. (On 1st 3rd party repo) Create new development branch named "dev" branching off main branch that the published content is available → script to do this with the repo specified
18. (On 2nd 3rd party repo) Do the same thing for 2nd 3rd party → the same script to do with the repo specified
19. (On 1st 3rd party repo) Create some commits on the repo → script to do with the repo specified
20. (On 2nd 3rd party repo) Create some commits on the repo → script to do with the repo specified
21. (On 1st 3rd party repo) Create PR to main branch on the 3rd party repo → script with gh command or manual on GitHub console
22. (On 1st 3rd party repo) Check if artifact is created with `pr-to-internal.yml` on PR created
23. On own internal repo, the artifact generated in step 22 is converted to PR with `apply-external-pr.sh` and I review it
24. On own internal repo, cherry-pick of the 3rd party PR with `cherry-pick-partial.sh`
25. Create notification for external PR with `notify-external-pr.sh`

---

## 元のシナリオからの変更点

以下の点が元のシナリオと異なる（実装仕様に合わせて修正）:

| 元のシナリオ | 修正後 |
|---|---|
| Step 4「dummy 3rd party repo を作成」 | 削除。3rd party repo は Steps 10/14 で作成する |
| Step 5「`init-replica.sh` でレプリカ作成」 | `init-replica.sh` は publish ブランチ初期化のみ。3rd party への配送は `deliver-to-replica.sh` が担う |
| Step 14 が重複 | 2番目の Step 14 以降を繰り下げ（Step 15〜25 に再番号） |
| Steps 10/14 後に party.conf 作成が抜けていた | `04-create-party-repo.sh` が party.conf を自動生成する |
| Steps 22-23 の間に artifact ダウンロードが抜けていた | Step 22 として `10-download-artifact.sh` を追加 |
| 元 Step 15「patch モード配送後に last-sync タグを手動更新」 | patch モードでもパッチセット生成時に自動でタグを進めるよう変更。手動ステップを削除し Steps 16〜25 を 15〜24 に繰り上げ |

---

## 前提条件

```bash
git --version    # 2.35 以上
gh --version     # GitHub CLI（認証済み）
jq --version
```

GitHub CLI 認証確認:
```bash
gh auth status
```

---

## テスト環境セットアップ

```bash
# テスト設定ファイルを作成
cp test/test.conf.example test/test.conf
$EDITOR test/test.conf  # GITHUB_USER と TEST_DIR を設定

# スクリプトに実行権限を付与
chmod +x scripts/*.sh test/*.sh
```

---

## テストシナリオ

### Phase 1: 内部リポジトリのセットアップ

#### Step 1: 内部リポジトリ作成

```bash
./test/01-setup-internal.sh
```

**作成されるもの:**
- GitHub repo: `<GITHUB_USER>/test-internal-monorepo` (private)
- ローカルクローン: `<TEST_DIR>/internal/`
- 初期コミット構造（公開ファイル + 除外ファイル）
- 除外対象: `internal-only/` と `.secrets/`
- マイルストーンタグ: `milestone/v1`

**確認ポイント:** `<TEST_DIR>/internal/` に以下が存在すること
```
services/api/         ← publish ブランチに含まれる
services/common/
services/auth/
services/users/
internal-only/        ← EXCLUDE_PATHS により publish ブランチから除外される
.secrets/             ← 同上
```

#### Step 2: sync.conf 生成

```bash
./test/03-generate-sync-conf.sh
```

`config/sync.conf` が生成される。内容を確認:
```bash
cat config/sync.conf
```

---

### Phase 2: publish ブランチ初期化

#### Step 3: init-replica.sh を実行

```bash
./scripts/init-replica.sh milestone/v1
```

**確認ポイント:**
- GHE（GitHub）上に PR が作成される: `init/TIMESTAMP → publish`
- PR の差分に `internal-only/` と `.secrets/` が含まれていないこと
- PR の差分がスナップショット（コミット履歴なし）であること

#### Step 4 (手動): PR をレビューしてマージ

ブラウザで PR を開き、内容を確認してマージする。

```bash
# PR URL を確認
gh pr list --repo <GITHUB_USER>/test-internal-monorepo \
  --json number,title,headRefName \
  --jq '.[] | select(.headRefName | startswith("init/")) | "#\(.number) \(.headRefName) — \(.title)"'
```

**確認ポイント:**
- `publish` ブランチに `internal-only/` が含まれていないこと
- `publish` ブランチのコミットが1つ（squash された初期スナップショット）であること

---

### Phase 3: 継続的開発のシミュレーション

#### Step 5: 開発コミットを追加

```bash
# 最初の追加（マイルストーンタグあり）
./test/02-add-commits.sh milestone/v2

# 必要に応じて繰り返し実行（タグなし）
./test/02-add-commits.sh
./test/02-add-commits.sh
```

各実行で追加される:
- `services/feature-N/FeatureService.kt` — publish ブランチに含まれる
- `internal-only/FeatureNConfig.kt` — 除外される

#### Step 6: stage-publish.sh を実行

```bash
./scripts/stage-publish.sh "sync: v2"
```

**確認ポイント:**
- GHE 上に PR が作成される: `sync/TIMESTAMP → publish`
- PR の差分に `internal-only/` の変更が含まれていないこと
- PR 本文に内部コミット一覧が記載されていること

#### Step 7 (手動): PR をレビューしてマージ

```bash
gh pr list --repo <GITHUB_USER>/test-internal-monorepo \
  --json number,title,headRefName \
  --jq '.[] | select(.headRefName | startswith("sync/")) | "#\(.number) \(.headRefName) — \(.title)"'
```

---

### Phase 4: 3rd party への配送（push モード）

#### Step 8: 3rd party repo 1 を作成（push モード用）

```bash
./test/04-create-party-repo.sh --party acme --repo test-replica-acme
```

**作成されるもの:**
- GitHub repo: `<GITHUB_USER>/test-replica-acme`
- ローカルクローン: `<TEST_DIR>/acme/`
- `config/party/acme.conf`
- `.github/workflows/pr-to-internal.yml`（外部PR受付用）

#### Step 9: deliver-to-replica.sh を実行（push モード）

```bash
./scripts/deliver-to-replica.sh --party acme "initial: v1"
```

初回配送のため `last-sync` タグは存在しない → publish の先頭から全量を配送する。

**確認ポイント:**
- GitHub 上に sync PR が作成される（`--mode pr` デフォルト）
- acme repo の main が更新されること（PR マージ後）

PR をマージ後:

#### Step 10: 配送内容を検証

```bash
./test/05-verify-delivery.sh --party acme
```

**期待結果:**
```
[  ok  ] File lists match
[  ok  ] File contents match
[  ok  ] Excluded path absent: internal-only
[  ok  ] Excluded path absent: .secrets
```

#### Step 11: タグを確認

```bash
./test/06-show-tags.sh --party acme
```

**確認ポイント:**
- `replica/acme/init-TIMESTAMP` タグが存在する（初回配送記録）
- `replica/acme/last-sync` タグが publish HEAD を指している
- `replica/acme/sync-TIMESTAMP` タグが存在する

---

### Phase 5: 3rd party への配送（patch モード）

#### Step 12: 3rd party repo 2 を作成（patch モード用）

```bash
./test/04-create-party-repo.sh --party beta --repo test-replica-beta
```

#### Step 13: deliver-to-replica.sh を実行（patch モード）

```bash
./scripts/deliver-to-replica.sh --party beta --output patch "initial: v1"
```

`test-patches/` ディレクトリにファイルが生成される:
```
test-patches/
├── sync-TIMESTAMP.patch
├── sync-TIMESTAMP-meta.json
├── sync-TIMESTAMP-summary.txt
└── sync-TIMESTAMP-apply.sh
```

#### Step 14: 3rd party 側でパッチを適用

生成された `apply.sh` を beta レポで実行する:

```bash
cd <TEST_DIR>/beta
bash <path-to-apply.sh>
```

PR モードの場合、GitHub 上に PR が作成される。マージ後に続ける。

#### Step 15: 配送内容を検証 & タグ確認

galaxy レポの sync PR を GitHub 上でマージしてから実行する（`05-verify-delivery.sh` は party repo の `main` と比較するため）。

```bash
./test/05-verify-delivery.sh --party galaxy
./test/06-show-tags.sh --party galaxy
```

---

### Phase 6: 外部 PR フロー

#### Step 16: 3rd party dev ブランチを作成

```bash
# acme party の dev ブランチを作成
./test/07-setup-3rdparty-branch.sh --party acme --branch dev
```

#### Step 17: 3rd party に開発コミットを追加

```bash
./test/08-add-3rdparty-commits.sh --party acme --branch dev
```

追加されるファイル（cherry-pick-partial.sh のテスト用に複数パスに分散）:
- `services/api/ExternalFeatureN.kt` — 採用しやすい変更
- `services/common/Utils.kt` — 部分的に採用しやすい変更
- `services/acme-extensions/` — 採用しにくい party 固有の変更

#### Step 18: 3rd party から PR を作成

```bash
./test/09-create-3rdparty-pr.sh --party acme --branch dev
```

PR 作成後、`pr-to-internal.yml` CI が自動実行される。

#### Step 19 (手動): CI の完了を確認

```bash
gh run list --repo <GITHUB_USER>/test-replica-acme --workflow pr-to-internal.yml
```

ステータスが `completed / success` になるまで待つ（通常 1〜2 分）。

#### Step 20: artifact をダウンロード

```bash
./test/10-download-artifact.sh --party acme --pr <PR_NUMBER>
```

`test-artifacts/acme/pr-<N>/` に `pr.patch` と `pr-meta.json` が保存される。

#### Step 21: 内部リポジトリに PR を作成

```bash
./scripts/apply-external-pr.sh \
  --party acme \
  --patch test-artifacts/acme/pr-<N>/pr.patch \
  --meta  test-artifacts/acme/pr-<N>/pr-meta.json
```

**確認ポイント:**
- 内部 repo に `external/acme-pr-N` ブランチが作成される
- GHE（GitHub）上に内部 PR が作成される
- PR に外部 PR URL・外部 author が記録されていること

#### Step 22 (手動): 内部 PR をレビュー

内部 PR を確認し、採用するパスを決める。

#### Step 23: cherry-pick-partial.sh で部分採用

```bash
cd <TEST_DIR>/internal
git checkout main

# services/api/ のみ採用する例
./scripts/cherry-pick-partial.sh \
  --patch test-artifacts/acme/pr-<N>/pr.patch \
  --meta  test-artifacts/acme/pr-<N>/pr-meta.json \
  --paths "services/api/" \
  --message "Accept acme API feature only"
```

**確認ポイント:**
- `services/api/ExternalFeatureN.kt` のみ main に取り込まれていること
- `services/acme-extensions/` は含まれていないこと

#### Step 24: 外部 PR に通知

```bash
# 部分採用の場合
./scripts/notify-external-pr.sh \
  --party acme \
  --meta  test-artifacts/acme/pr-<N>/pr-meta.json \
  --status partial

# 却下の場合
./scripts/notify-external-pr.sh \
  --party acme \
  --meta  test-artifacts/acme/pr-<N>/pr-meta.json \
  --status rejected \
  --reason "acme-extensions does not fit the design direction"
```

**確認ポイント:**
- 外部 PR にコメントが投稿されていること
- `rejected` の場合、外部 PR が自動 Close されること

---

## テスト後のクリーンアップ

```bash
# ローカルクローンを削除
rm -rf <TEST_DIR>/internal <TEST_DIR>/acme <TEST_DIR>/beta

# GitHub repos を削除
gh repo delete <GITHUB_USER>/test-internal-monorepo --yes
gh repo delete <GITHUB_USER>/test-replica-acme --yes
gh repo delete <GITHUB_USER>/test-replica-beta --yes

# 生成された設定ファイルを削除
rm -f config/sync.conf
rm -f config/party/acme.conf config/party/beta.conf

# テスト成果物を削除
rm -rf test-patches/ test-artifacts/
```

---

## テストスクリプト一覧

| スクリプト | 用途 | 引数 |
|---|---|---|
| `test/01-setup-internal.sh` | 内部リポジトリ作成・初期コミット | なし |
| `test/02-add-commits.sh` | 開発コミット追加（繰り返し可） | `[milestone-tag]` |
| `test/03-generate-sync-conf.sh` | `config/sync.conf` 生成 | なし |
| `test/04-create-party-repo.sh` | 3rd party repo 作成・party.conf 生成 | `--party <name> --repo <repo-name>` |
| `test/05-verify-delivery.sh` | 配送内容の検証 | `--party <name>` |
| `test/06-show-tags.sh` | タグ一覧表示 | `[--party <name>]` |
| `test/07-setup-3rdparty-branch.sh` | 3rd party dev ブランチ作成 | `--party <name> [--branch <name>]` |
| `test/08-add-3rdparty-commits.sh` | 3rd party コミット追加 | `--party <name> [--branch <name>]` |
| `test/09-create-3rdparty-pr.sh` | 3rd party PR 作成 | `--party <name> [--branch <name>]` |
| `test/10-download-artifact.sh` | CI artifact ダウンロード | `--party <name> --pr <number>` |
