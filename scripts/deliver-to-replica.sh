#!/usr/bin/env bash
# deliver-to-replica.sh
#
# マイルストーン同期 フェーズ2。
# publish/<party> ブランチの内容を外部レプリカへ配送する。
# stage-publish.sh → GHE PR レビュー → マージ 後に実行する。
#
# Usage:
#   # PR として push（デフォルト）
#   ./scripts/deliver-to-replica.sh --party acme "sync: 2024-Q1"
#
#   # main へ直接 push
#   ./scripts/deliver-to-replica.sh --party acme --mode direct "sync: 2024-Q1"
#
#   # パッチセット出力（3rd party が PR を作成: デフォルト）
#   ./scripts/deliver-to-replica.sh --party acme --output patch "sync: 2024-Q1"
#
#   # パッチセット出力（3rd party が main へ直接適用）
#   ./scripts/deliver-to-replica.sh --party acme --output patch --mode direct "sync: 2024-Q1"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

[[ -f "$CONFIG_FILE" ]] || {
  echo "設定ファイルが見つかりません: $CONFIG_FILE"
  exit 1
}
# shellcheck source=../config/sync.conf.example
source "$CONFIG_FILE"

# オプショナルな設定値のデフォルト（未定義時に -u エラーを防ぐ）
: "${PUBLISH_BRANCH_PREFIX:=publish}"
: "${PATCH_OUTPUT_DIR:=./sync-patches}"

log() { echo -e "\033[1;34m[deliver]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok   ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err   ]\033[0m $*" >&2; exit 1; }

# ── 引数パース ─────────────────────────────────────────────────
OUTPUT_MODE="push"   # push | patch
MODE="pr"            # pr | direct
PARTY=""
COMMIT_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_MODE="$2"; shift 2 ;;
    --mode)   MODE="$2";        shift 2 ;;
    --party)  PARTY="$2";       shift 2 ;;
    --*)      die "不明なオプション: $1" ;;
    *)        COMMIT_MSG="$1"; shift ;;
  esac
done

[[ -n "$PARTY" ]] || die "--party でパーティ名を指定してください\n  例: $0 --party acme \"sync: 2024-Q1\""
COMMIT_MSG="${COMMIT_MSG:-"sync: $(date +%Y-%m-%d)"}"

case "$OUTPUT_MODE" in
  push|patch) ;;
  *) die "--output は push / patch のいずれかを指定してください" ;;
esac

case "$MODE" in
  pr|direct) ;;
  *) die "--mode は pr / direct のいずれかを指定してください" ;;
esac

PUBLISH_BRANCH="${PUBLISH_BRANCH_PREFIX}/${PARTY}"
PARTY_SYNC_TAG="replica/${PARTY}/last-sync"

log "パーティ          : $PARTY"
log "出力モード        : $OUTPUT_MODE"
log "適用方法          : $MODE"
log "コミットメッセージ: $COMMIT_MSG"

# ── ヘルパー ───────────────────────────────────────────────────

# publish/<party> のコミット一覧（last-sync 以降）
generate_deliver_summary() {
  cd "$INTERNAL_REPO"
  git log --oneline --no-merges "${PARTY_SYNC_TAG}..${PUBLISH_HEAD}" \
    | head -50
}

generate_pr_body() {
  cat << EOF
## ${COMMIT_MSG}

| 項目     | 内容 |
|----------|------|
| 配送範囲 | \`${LAST_SYNC_SHA:0:8}\`..\`${PUBLISH_HEAD:0:8}\` |
| 配送日時 | $(date '+%Y-%m-%d %H:%M:%S') |

## 変更サマリー

\`\`\`
$(generate_deliver_summary)
\`\`\`

> このPRは社内同期botにより自動生成されました。
> レビュー後にマージしてください。
EOF
}

# apply.sh を生成する（3rd party がレプリカへ適用するスタンドアロンスクリプト）
generate_apply_sh() {
  local output_file="$1"
  local ts="$TIMESTAMP"
  local msg="$COMMIT_MSG"
  local default_mode="$MODE"
  local script_name="sync-${ts}-apply.sh"

  sed \
    -e "s|%%TIMESTAMP%%|${ts}|g" \
    -e "s|%%COMMIT_MSG%%|${msg}|g" \
    -e "s|%%DEFAULT_MODE%%|${default_mode}|g" \
    -e "s|%%SCRIPT_NAME%%|${script_name}|g" \
    << 'APPLY_TEMPLATE' > "$output_file"
#!/usr/bin/env bash
# sync 適用スクリプト (生成: %%TIMESTAMP%%)
# 同期メッセージ: %%COMMIT_MSG%%
#
# Usage:
#   # デフォルト (%%DEFAULT_MODE%%) で適用
#   ./%%SCRIPT_NAME%%
#
#   # モードを指定して適用
#   ./%%SCRIPT_NAME%% --mode pr      # sync ブランチを push して PR を作成
#   ./%%SCRIPT_NAME%% --mode direct  # main へ直接適用
#
# 前提条件:
#   - レプリカリポジトリのルートディレクトリで実行すること
#   - jq, gh CLI がインストールされていること（pr モードのみ gh が必要）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/sync-%%TIMESTAMP%%.patch"
META_FILE="${SCRIPT_DIR}/sync-%%TIMESTAMP%%-meta.json"
SYNC_BRANCH="sync/%%TIMESTAMP%%"
REPLICA_BRANCH="main"
DEFAULT_MODE="%%DEFAULT_MODE%%"

log() { echo -e "\033[1;34m[apply]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok  ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err  ]\033[0m $*" >&2; exit 1; }

MODE="${DEFAULT_MODE}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --*)    die "不明なオプション: $1" ;;
    *) break ;;
  esac
done

[[ -f "$PATCH_FILE" ]] || die "パッチファイルが見つかりません: $PATCH_FILE"
[[ -f "$META_FILE"  ]] || die "メタファイルが見つかりません: $META_FILE"
command -v jq >/dev/null 2>&1 || die "jq がインストールされていません"
[[ "$MODE" == "pr" ]] && { command -v gh >/dev/null 2>&1 || die "gh CLI がインストールされていません"; }

PR_TITLE=$(jq -r '.pr_title' "$META_FILE")
PR_BODY=$(jq  -r '.pr_body'  "$META_FILE")

log "適用モード: $MODE"

if [[ "$MODE" == "pr" ]]; then
  log "ブランチ作成: $SYNC_BRANCH"
  git checkout -b "$SYNC_BRANCH"

  log "パッチ適用中..."
  git apply --3way --whitespace=nowarn "$PATCH_FILE" \
    || die "パッチ適用に失敗しました。競合を解消してから再実行してください。"

  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "$PR_TITLE"
    ok "コミット完了: $(git rev-parse --short HEAD)"
  else
    ok "変更なし。コミットをスキップ。"
  fi

  git push origin "$SYNC_BRANCH"

  gh pr create \
    --title "$PR_TITLE" \
    --body  "$PR_BODY"  \
    --base  "$REPLICA_BRANCH" \
    --head  "$SYNC_BRANCH"

  ok "PR を作成しました"

elif [[ "$MODE" == "direct" ]]; then
  log "main へ直接適用中..."
  git checkout "$REPLICA_BRANCH"

  log "パッチ適用中..."
  git apply --3way --whitespace=nowarn "$PATCH_FILE" \
    || die "パッチ適用に失敗しました。競合を解消してから再実行してください。"

  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "$PR_TITLE"
    ok "コミット完了: $(git rev-parse --short HEAD)"
  else
    ok "変更なし。コミットをスキップ。"
  fi

  git push origin "$REPLICA_BRANCH"
  ok "main へ直接適用しました"

else
  die "--mode は pr / direct のいずれかを指定してください"
fi
APPLY_TEMPLATE
  chmod +x "$output_file"
}

# ── Step 1: 事前確認 ──────────────────────────────────────────
cd "$INTERNAL_REPO"

git rev-parse --verify "refs/heads/${PUBLISH_BRANCH}" >/dev/null 2>&1 \
  || die "publish ブランチ '$PUBLISH_BRANCH' が見つかりません\n" \
         "初回セットアップを先に実行してください:\n" \
         "  ./scripts/init-replica.sh --party ${PARTY} <start-tag>"

git rev-parse --verify "$PARTY_SYNC_TAG" >/dev/null 2>&1 \
  || die "同期タグ '$PARTY_SYNC_TAG' が見つかりません\n" \
         "初回セットアップを先に実行してください:\n" \
         "  ./scripts/init-replica.sh --party ${PARTY} <start-tag>"

PUBLISH_HEAD=$(git rev-parse "$PUBLISH_BRANCH")
LAST_SYNC_SHA=$(git rev-parse "$PARTY_SYNC_TAG")

if [[ "$PUBLISH_HEAD" == "$LAST_SYNC_SHA" ]]; then
  ok "配送済み。publish ブランチに未配送の変更はありません。"
  exit 0
fi

log "配送範囲: ${LAST_SYNC_SHA:0:8}..${PUBLISH_HEAD:0:8}"

# ── Step 2: 差分パッチ生成 ────────────────────────────────────
# publish/<party> は stage-publish.sh で EXCLUDE_PATHS 適用済みのため再除外不要
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PATCH_FILE=$(mktemp /tmp/deliver-XXXXXX.patch)
trap 'rm -f "$PATCH_FILE"' EXIT

git diff "${PARTY_SYNC_TAG}..${PUBLISH_BRANCH}" > "$PATCH_FILE"

if [[ ! -s "$PATCH_FILE" ]]; then
  ok "差分なし。スキップ。"
  exit 0
fi

log "パッチサイズ: $(wc -l < "$PATCH_FILE") 行"

# ── patch モード: ファイル出力して終了 ─────────────────────────
if [[ "$OUTPUT_MODE" == "patch" ]]; then
  mkdir -p "$PATCH_OUTPUT_DIR"

  DEST_PATCH="${PATCH_OUTPUT_DIR}/sync-${TIMESTAMP}.patch"
  DEST_META="${PATCH_OUTPUT_DIR}/sync-${TIMESTAMP}-meta.json"
  DEST_SUMMARY="${PATCH_OUTPUT_DIR}/sync-${TIMESTAMP}-summary.txt"
  DEST_APPLY="${PATCH_OUTPUT_DIR}/sync-${TIMESTAMP}-apply.sh"

  cp "$PATCH_FILE" "$DEST_PATCH"

  PR_BODY_VAL="$(generate_pr_body)"

  cat > "$DEST_META" << EOF
{
  "commit_msg":     "${COMMIT_MSG}",
  "publish_head":   "${PUBLISH_HEAD}",
  "last_sync_sha":  "${LAST_SYNC_SHA}",
  "timestamp":      "${TIMESTAMP}",
  "party":          "${PARTY}",
  "sync_branch":    "sync/${TIMESTAMP}",
  "pr_title":       "${COMMIT_MSG}",
  "pr_body":        $(echo "$PR_BODY_VAL" | jq -Rs .),
  "default_mode":   "${MODE}"
}
EOF

  generate_deliver_summary > "$DEST_SUMMARY"
  generate_apply_sh "$DEST_APPLY"

  ok "パッチセットを生成しました:"
  echo "  patch   : $DEST_PATCH"
  echo "  meta    : $DEST_META"
  echo "  summary : $DEST_SUMMARY"
  echo "  apply   : $DEST_APPLY"
  echo ""
  echo "3rd party に以下のファイルを送付してください:"
  echo "  $DEST_PATCH"
  echo "  $DEST_META"
  echo "  $DEST_APPLY"
  echo ""
  echo "レプリカへの適用確認後、以下で sync タグを更新してください:"
  echo "  cd $INTERNAL_REPO && git tag -a -f $PARTY_SYNC_TAG $PUBLISH_HEAD -m \"delivered: ${TIMESTAMP}\""
  exit 0
fi

# ── push モード: レプリカへ適用 ───────────────────────────────
cd "$REPLICA_REPO"

log "レプリカを最新化中..."
git fetch "$REPLICA_REMOTE"
git checkout "$REPLICA_BRANCH"
git merge --ff-only "${REPLICA_REMOTE}/${REPLICA_BRANCH}"

if [[ "$MODE" == "pr" ]]; then
  SYNC_BRANCH="sync/${TIMESTAMP}"
  git checkout -b "$SYNC_BRANCH"
  log "同期ブランチ: $SYNC_BRANCH"
fi

log "パッチを適用中..."
git apply --3way --whitespace=nowarn "$PATCH_FILE" \
  || die "パッチ適用に失敗しました。競合を解消してから再実行してください。"

git add -A

if git diff --cached --quiet; then
  ok "ステージングに変更なし。コミットをスキップ。"
else
  GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
  GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
  GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
  GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
  git commit \
    -m "$COMMIT_MSG" \
    -m "$(generate_deliver_summary)"

  ok "コミット完了: $(git rev-parse --short HEAD)"
fi

if [[ "$MODE" == "pr" ]]; then
  git push "$REPLICA_REMOTE" "$SYNC_BRANCH"

  gh pr create \
    --repo  "$REPLICA_GH_REPO" \
    --title "$COMMIT_MSG" \
    --body  "$(generate_pr_body)" \
    --base  "$REPLICA_BRANCH" \
    --head  "$SYNC_BRANCH" \
    --label "sync"

  ok "PR を作成しました"

elif [[ "$MODE" == "direct" ]]; then
  git push "$REPLICA_REMOTE" "$REPLICA_BRANCH"
  ok "main へ直接 push しました"
fi

# ── Step 3: 内部 sync タグを更新 ─────────────────────────────
cd "$INTERNAL_REPO"

SYNC_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TAG_MESSAGE="party: ${PARTY}
output: ${OUTPUT_MODE}
mode: ${MODE}
commit_msg: ${COMMIT_MSG}
publish_head: ${PUBLISH_HEAD}
timestamp: ${SYNC_TIMESTAMP}"

GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git tag -a -f "$PARTY_SYNC_TAG" "$PUBLISH_HEAD" -m "$TAG_MESSAGE"

GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git tag -a "replica/${PARTY}/sync-${SYNC_TIMESTAMP}" "$PUBLISH_HEAD" -m "$TAG_MESSAGE"

ok "同期タグを更新: $PARTY_SYNC_TAG → ${PUBLISH_HEAD:0:8}"
ok "配送完了"
