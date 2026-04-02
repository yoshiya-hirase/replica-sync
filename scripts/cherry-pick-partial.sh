#!/usr/bin/env bash
# cherry-pick-partial.sh
#
# 外部PR変更の部分採用スクリプト。
# patch ファイルから指定パスに関係する hunks のみを適用する。
#
# Usage:
#   # コミットまるごと cherry-pick
#   git cherry-pick external/3rdparty-pr-123
#
#   # 特定ファイルのみ採用
#   ./scripts/cherry-pick-partial.sh \
#     --patch pr-123.patch \
#     --meta  pr-123-meta.json \
#     --paths "services/api/" "services/common/" \
#     --message "API 変更のみ採用"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

[[ -f "$CONFIG_FILE" ]] || { echo "設定ファイルが見つかりません: $CONFIG_FILE"; exit 1; }
# shellcheck source=../config/sync.conf.example
source "$CONFIG_FILE"

log() { echo -e "\033[1;34m[partial]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[   ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[  err ]\033[0m $*" >&2; exit 1; }

# ── 引数パース ─────────────────────────────────────────────────
PATCH_FILE=""
META_FILE=""
PATHS=()
COMMIT_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch)   PATCH_FILE="$2"; shift 2 ;;
    --meta)    META_FILE="$2";  shift 2 ;;
    --message) COMMIT_MSG="$2"; shift 2 ;;
    --paths)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        PATHS+=("$1"); shift
      done
      ;;
    *) die "不明なオプション: $1" ;;
  esac
done

[[ -f "$PATCH_FILE" ]] || die "patch ファイルが見つかりません: $PATCH_FILE"
[[ -f "$META_FILE"  ]] || die "meta ファイルが見つかりません: $META_FILE"
[[ ${#PATHS[@]} -gt 0 ]] || die "--paths にパスを1つ以上指定してください"

PR_NUMBER=$(jq -r '.pr_number' "$META_FILE")
PR_TITLE=$(jq  -r '.pr_title'  "$META_FILE")
PR_URL=$(jq    -r '.pr_url'    "$META_FILE")
PR_AUTHOR=$(jq -r '.pr_author' "$META_FILE")

COMMIT_MSG="${COMMIT_MSG:-"external(partial): ${PR_TITLE}"}"

log "対象 PR   : #${PR_NUMBER} ${PR_TITLE}"
log "採用パス  : ${PATHS[*]}"
log "メッセージ: $COMMIT_MSG"

# ── 内部 repo を最新化 ────────────────────────────────────────
cd "$INTERNAL_REPO"
git fetch "$INTERNAL_REMOTE"
git checkout main
git merge --ff-only "${INTERNAL_REMOTE}/main"

# ── 指定パスの hunks のみを apply ────────────────────────────
INCLUDE_ARGS=()
for path in "${PATHS[@]}"; do
  INCLUDE_ARGS+=(--include="$path")
done

log "パッチを適用中（パス指定）..."
if ! git apply --3way --whitespace=nowarn "${INCLUDE_ARGS[@]}" "$PATCH_FILE"; then
  die "パッチの適用に失敗しました。競合を手動で解消してください。"
fi

git add -A

if git diff --cached --quiet; then
  die "指定パスに対応する差分がありませんでした。パスを確認してください。"
fi

# ── コミット ──────────────────────────────────────────────────
GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git commit \
  -m "$COMMIT_MSG" \
  -m "元 PR   : ${PR_URL}
外部作者: ${PR_AUTHOR}
採用パス: ${PATHS[*]}"

ok "コミット完了: $(git rev-parse --short HEAD)"
