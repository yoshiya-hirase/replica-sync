#!/usr/bin/env bash
# stage-publish.sh
#
# マイルストーン同期 フェーズ1。
# internal/main の差分を squash して publish/<party> への PR を
# GHE 上に作成する。PR をレビュー・マージ後に
# deliver-to-replica.sh で外部レプリカへ配送する。
#
# Usage:
#   ./scripts/stage-publish.sh --party acme "sync: 2024-Q1"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

[[ -f "$CONFIG_FILE" ]] || {
  echo "設定ファイルが見つかりません: $CONFIG_FILE"
  echo "cp config/sync.conf.example config/sync.conf して編集してください"
  exit 1
}
# shellcheck source=../config/sync.conf.example
source "$CONFIG_FILE"

# オプショナルな設定値のデフォルト（未定義時に -u エラーを防ぐ）
[[ -v EXCLUDE_PATHS ]]      || EXCLUDE_PATHS=()
: "${PUBLISH_BRANCH_PREFIX:=publish}"

log() { echo -e "\033[1;34m[stage]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok  ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err  ]\033[0m $*" >&2; exit 1; }

# ── 引数パース ─────────────────────────────────────────────────
PARTY=""
COMMIT_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --party) PARTY="$2";      shift 2 ;;
    --*)     die "不明なオプション: $1" ;;
    *)       COMMIT_MSG="$1"; shift ;;
  esac
done

[[ -n "$PARTY" ]] || die "--party でパーティ名を指定してください\n  例: $0 --party acme \"sync: 2024-Q1\""
COMMIT_MSG="${COMMIT_MSG:-"sync: $(date +%Y-%m-%d)"}"

PUBLISH_BRANCH="${PUBLISH_BRANCH_PREFIX}/${PARTY}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SYNC_BRANCH="sync/${PARTY}/${TIMESTAMP}"

log "パーティ          : $PARTY"
log "コミットメッセージ: $COMMIT_MSG"
log "publish ブランチ  : $PUBLISH_BRANCH"
log "sync ブランチ     : $SYNC_BRANCH"

# ── ヘルパー ───────────────────────────────────────────────────
build_exclude_args() {
  EXCLUDE_ARGS=()
  for path in "${EXCLUDE_PATHS[@]}"; do
    EXCLUDE_ARGS+=(":!${path}")
  done
}

# ── Step 1: 事前確認 ──────────────────────────────────────────
cd "$INTERNAL_REPO"
build_exclude_args

git rev-parse --verify "refs/heads/${PUBLISH_BRANCH}" >/dev/null 2>&1 \
  || die "publish ブランチ '$PUBLISH_BRANCH' が見つかりません\n" \
         "初回セットアップを先に実行してください:\n" \
         "  ./scripts/init-replica.sh --party ${PARTY} <start-tag>"

PUBLISH_HEAD=$(git rev-parse "$PUBLISH_BRANCH")
INTERNAL_HEAD=$(git rev-parse HEAD)

if [[ "$PUBLISH_HEAD" == "$INTERNAL_HEAD" ]]; then
  ok "差分なし。publish ブランチは最新です。"
  exit 0
fi

log "差分範囲: ${PUBLISH_HEAD:0:8}..${INTERNAL_HEAD:0:8}"

# ── Step 2: 差分パッチ生成 ────────────────────────────────────
PATCH_FILE=$(mktemp /tmp/stage-publish-XXXXXX.patch)
WORK_DIR=$(mktemp -d /tmp/stage-publish-work-XXXXXX)
cleanup() {
  rm -f "$PATCH_FILE"
  git -C "$INTERNAL_REPO" worktree remove "$WORK_DIR" --force 2>/dev/null || true
}
trap cleanup EXIT

git diff "${PUBLISH_HEAD}..HEAD" -- . "${EXCLUDE_ARGS[@]}" > "$PATCH_FILE"

if [[ ! -s "$PATCH_FILE" ]]; then
  ok "除外パスを差し引くと差分なし。スキップ。"
  exit 0
fi

log "パッチサイズ: $(wc -l < "$PATCH_FILE") 行"

# ── Step 3: sync ブランチを publish/<party> ベースで作成 ───────
log "作業用 worktree を作成中..."
git worktree add "$WORK_DIR" -b "$SYNC_BRANCH" "$PUBLISH_BRANCH"

# ── Step 4: パッチ適用・squash コミット ───────────────────────
cd "$WORK_DIR"
log "パッチを適用中..."
git apply --3way --whitespace=nowarn "$PATCH_FILE" \
  || die "パッチ適用に失敗しました。競合を解消してから再実行してください。"

git add -A

if git diff --cached --quiet; then
  ok "ステージングに変更なし。コミットをスキップ。"
else
  SUMMARY=$(
    cd "$INTERNAL_REPO"
    git log --oneline --no-merges "${PUBLISH_HEAD}..${INTERNAL_HEAD}" \
      -- . "${EXCLUDE_ARGS[@]}" | head -50
  )

  GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
  GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
  GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
  GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
  git commit -m "$COMMIT_MSG" -m "$SUMMARY"

  ok "コミット完了: $(git rev-parse --short HEAD)"
fi

# ── Step 5: GHE へ push ───────────────────────────────────────
cd "$INTERNAL_REPO"
log "sync ブランチを GHE へ push 中..."
git push "$INTERNAL_REMOTE" "$SYNC_BRANCH"

# ── Step 6: GHE 上に PR 作成 (sync → publish/<party>) ─────────
SUMMARY_FOR_PR=$(
  git log --oneline --no-merges "${PUBLISH_HEAD}..${INTERNAL_HEAD}" \
    -- . "${EXCLUDE_ARGS[@]}" | head -50
)

PR_BODY="## ${COMMIT_MSG}

| 項目 | 内容 |
|---|---|
| 差分範囲 | \`${PUBLISH_HEAD:0:8}\`..\`${INTERNAL_HEAD:0:8}\` |
| publish ブランチ | \`${PUBLISH_BRANCH}\` |
| 作成日時 | $(date '+%Y-%m-%d %H:%M:%S') |

## 含まれる内部コミット

\`\`\`
${SUMMARY_FOR_PR}
\`\`\`

> このPRをレビュー後に \`${PUBLISH_BRANCH}\` へマージし、
> \`deliver-to-replica.sh\` で外部レプリカへ配送してください。"

GH_HOST="$GH_HOST" gh pr create \
  --repo  "${GH_ORG}/${GH_REPO}" \
  --title "$COMMIT_MSG" \
  --body  "$PR_BODY" \
  --base  "$PUBLISH_BRANCH" \
  --head  "$SYNC_BRANCH"

ok "GHE 上に PR を作成しました: ${SYNC_BRANCH} → ${PUBLISH_BRANCH}"
echo ""
echo "次のステップ:"
echo "  1. GHE 上の PR をレビューし、承認後に ${PUBLISH_BRANCH} へマージ"
echo "  2. 外部レプリカへの配送:"
echo "     ./scripts/deliver-to-replica.sh --party ${PARTY} \"${COMMIT_MSG}\""
