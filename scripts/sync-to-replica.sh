#!/usr/bin/env bash
# sync-to-replica.sh
#
# マイルストーン同期スクリプト。
# 前回同期タグ (replica/<party>/last-sync) からの差分を squash して
# レプリカへ送る。コミット author は Bot に差し替える。
#
# Usage:
#   # PR として push（デフォルト）
#   ./scripts/sync-to-replica.sh --party acme "sync: 2024-Q1"
#
#   # 直接 main へ push
#   ./scripts/sync-to-replica.sh --party acme --mode direct "sync: 2024-Q1"
#
#   # パッチセットのみ生成（レプリカへは自動適用しない）
#   ./scripts/sync-to-replica.sh --party acme --mode patch "sync: 2024-Q1"
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

log() { echo -e "\033[1;34m[sync]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

# ── 引数パース ─────────────────────────────────────────────────
MODE="pr"
PARTY=""
COMMIT_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)  MODE="$2";  shift 2 ;;
    --party) PARTY="$2"; shift 2 ;;
    --*)     die "不明なオプション: $1" ;;
    *)       COMMIT_MSG="$1"; shift ;;
  esac
done

[[ -n "$PARTY" ]] || die "--party でパーティ名を指定してください\n  例: $0 --party acme \"sync: 2024-Q1\""

COMMIT_MSG="${COMMIT_MSG:-"sync: $(date +%Y-%m-%d)"}"

case "$MODE" in
  pr|patch|direct) ;;
  *) die "--mode は pr / patch / direct のいずれかを指定してください" ;;
esac

# パーティ別の同期タグ名
PARTY_SYNC_TAG="replica/${PARTY}/last-sync"

log "パーティ          : $PARTY"
log "実行モード        : $MODE"
log "コミットメッセージ: $COMMIT_MSG"

# ── ヘルパー ───────────────────────────────────────────────────
build_exclude_args() {
  EXCLUDE_ARGS=()
  for path in "${EXCLUDE_PATHS[@]}"; do
    EXCLUDE_ARGS+=(":!${path}")
  done
}

generate_sync_summary() {
  cd "$INTERNAL_REPO"
  git log --oneline --no-merges "${PARTY_SYNC_TAG}..${INTERNAL_HEAD}" \
    -- . "${EXCLUDE_ARGS[@]}" \
    | head -50
}

generate_pr_body() {
  cat << EOF
## ${COMMIT_MSG}

| 項目     | 内容 |
|----------|------|
| 同期範囲 | \`${SYNC_BASE:0:8}\`..\`${INTERNAL_HEAD:0:8}\` |
| 同期日時 | $(date '+%Y-%m-%d %H:%M:%S') |

## 変更サマリー

\`\`\`
$(generate_sync_summary)
\`\`\`

> このPRは社内同期botにより自動生成されました。
> レビュー後にマージしてください。
EOF
}

# ── Step 1: 前回同期タグの確認 ────────────────────────────────
cd "$INTERNAL_REPO"
build_exclude_args

git rev-parse --verify "$PARTY_SYNC_TAG" >/dev/null 2>&1 \
  || die "同期タグ '$PARTY_SYNC_TAG' が見つかりません\n" \
         "初回セットアップを先に実行してください:\n" \
         "  ./scripts/init-replica.sh --party ${PARTY} <start-tag>"

SYNC_BASE=$(git rev-parse "$PARTY_SYNC_TAG")
INTERNAL_HEAD=$(git rev-parse HEAD)

if [[ "$SYNC_BASE" == "$INTERNAL_HEAD" ]]; then
  ok "同期済み。差分なし。"
  exit 0
fi

log "同期範囲: ${SYNC_BASE:0:8}..${INTERNAL_HEAD:0:8}"

# ── Step 2: 差分パッチ生成 ────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PATCH_FILE=$(mktemp /tmp/replica-sync-XXXXXX.patch)
trap 'rm -f "$PATCH_FILE"' EXIT

git diff "${PARTY_SYNC_TAG}..HEAD" -- . "${EXCLUDE_ARGS[@]}" > "$PATCH_FILE"

if [[ ! -s "$PATCH_FILE" ]]; then
  ok "除外パスを差し引くと差分なし。スキップ。"
  exit 0
fi

log "パッチサイズ: $(wc -l < "$PATCH_FILE") 行"

# ── patch モード: ファイル出力して終了 ─────────────────────────
if [[ "$MODE" == "patch" ]]; then
  mkdir -p "$PATCH_OUTPUT_DIR"

  DEST_PATCH="${PATCH_OUTPUT_DIR}/sync-${TIMESTAMP}.patch"
  DEST_META="${PATCH_OUTPUT_DIR}/sync-${TIMESTAMP}-meta.json"
  DEST_SUMMARY="${PATCH_OUTPUT_DIR}/sync-${TIMESTAMP}-summary.txt"

  cp "$PATCH_FILE" "$DEST_PATCH"

  cat > "$DEST_META" << EOF
{
  "commit_msg":    "${COMMIT_MSG}",
  "sync_base":     "${SYNC_BASE}",
  "internal_head": "${INTERNAL_HEAD}",
  "timestamp":     "${TIMESTAMP}",
  "exclude_paths": $(printf '%s\n' "${EXCLUDE_PATHS[@]}" | jq -R . | jq -s .)
}
EOF

  generate_sync_summary > "$DEST_SUMMARY"

  ok "パッチセットを生成しました:"
  echo "  patch   : $DEST_PATCH"
  echo "  meta    : $DEST_META"
  echo "  summary : $DEST_SUMMARY"
  echo ""
  echo "レプリカへの適用後、以下で sync タグを更新してください:"
  echo "  cd $INTERNAL_REPO && git tag -f $PARTY_SYNC_TAG $INTERNAL_HEAD"
  exit 0
fi

# ── pr / direct モード: レプリカへ適用 ────────────────────────
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
    -m "$(generate_sync_summary)"

  ok "コミット完了: $(git rev-parse --short HEAD)"
fi

# ── push と PR 作成 ───────────────────────────────────────────
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

# ── Step 6: 内部 sync タグを更新 ─────────────────────────────
cd "$INTERNAL_REPO"

SYNC_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TAG_MESSAGE="party: ${PARTY}
mode: ${MODE}
commit_msg: ${COMMIT_MSG}
timestamp: ${SYNC_TIMESTAMP}"

GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git tag -a -f "$PARTY_SYNC_TAG" "$INTERNAL_HEAD" -m "$TAG_MESSAGE"

GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git tag -a "replica/${PARTY}/sync-${SYNC_TIMESTAMP}" "$INTERNAL_HEAD" -m "$TAG_MESSAGE"

ok "同期タグを更新: $PARTY_SYNC_TAG → ${INTERNAL_HEAD:0:8}"
ok "同期完了"
