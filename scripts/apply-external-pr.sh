#!/usr/bin/env bash
# apply-external-pr.sh
#
# 外部PR（github.com レプリカ上の PR）の差分を社内 repo に適用し、
# 内部 PR を自動作成するスクリプト。
#
# Usage:
#   ./scripts/apply-external-pr.sh --patch pr.patch --meta pr-meta.json
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

[[ -f "$CONFIG_FILE" ]] || { echo "設定ファイルが見つかりません: $CONFIG_FILE"; exit 1; }
# shellcheck source=../config/sync.conf.example
source "$CONFIG_FILE"

log() { echo -e "\033[1;34m[apply]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

# ── 引数パース ─────────────────────────────────────────────────
PATCH_FILE=""
META_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch) PATCH_FILE="$2"; shift 2 ;;
    --meta)  META_FILE="$2";  shift 2 ;;
    *) die "不明なオプション: $1\nUsage: $0 --patch <file> --meta <file>" ;;
  esac
done

[[ -f "$PATCH_FILE" ]] || die "patch ファイルが見つかりません: $PATCH_FILE"
[[ -f "$META_FILE"  ]] || die "meta ファイルが見つかりません: $META_FILE"

# ── メタ情報の読み込み ─────────────────────────────────────────
PR_NUMBER=$(jq -r '.pr_number' "$META_FILE")
PR_TITLE=$(jq  -r '.pr_title'  "$META_FILE")
PR_BODY=$(jq   -r '.pr_body'   "$META_FILE")
PR_AUTHOR=$(jq -r '.pr_author' "$META_FILE")
PR_URL=$(jq    -r '.pr_url'    "$META_FILE")

BRANCH="external/3rdparty-pr-${PR_NUMBER}"

log "対象 PR : #${PR_NUMBER} ${PR_TITLE}"
log "外部作者: ${PR_AUTHOR}"
log "内部ブランチ: ${BRANCH}"

# ── Step 1: 内部 repo を最新化 ────────────────────────────────
cd "$INTERNAL_REPO"

git fetch "$INTERNAL_REMOTE"
git checkout main
git merge --ff-only "${INTERNAL_REMOTE}/main"

# ── Step 2: 作業ブランチを作成 ────────────────────────────────
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  # 同じ PR が更新されて再送された場合は既存ブランチをリセット
  log "既存ブランチを更新: $BRANCH"
  git checkout "$BRANCH"
  git reset --hard "${INTERNAL_REMOTE}/main"
else
  git checkout -b "$BRANCH"
fi

# ── Step 3: patch を適用 ──────────────────────────────────────
log "patch を適用中..."

if ! git apply --3way --whitespace=nowarn "$PATCH_FILE"; then
  die "patch の適用に失敗しました。\n" \
      "競合を手動で解消してから以下を実行してください:\n" \
      "  git add -A && git commit ..."
fi

# ── Step 4: コミット ──────────────────────────────────────────
git add -A

if git diff --cached --quiet; then
  die "適用後の差分がありません。patch が既に取り込まれている可能性があります。"
fi

GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git commit \
  -m "external(3rdparty): ${PR_TITLE}" \
  -m "Forwarded from: ${PR_URL}
Original author: ${PR_AUTHOR}

${PR_BODY}"

ok "コミット完了: $(git rev-parse --short HEAD)"

# ── Step 5: GHE へ push ───────────────────────────────────────
log "GHE へ push 中..."
git push "$INTERNAL_REMOTE" "$BRANCH" --force-with-lease

# ── Step 6: 内部 PR を作成（既存なら更新済みなのでスキップ） ───
log "内部 PR を確認中..."

PR_EXISTS=$(GH_HOST="$GH_HOST" gh pr list \
  --repo "${GH_ORG}/${GH_REPO}" \
  --head "$BRANCH" \
  --json number \
  --jq '.[0].number // empty')

if [[ -n "$PR_EXISTS" ]]; then
  ok "既存の内部 PR #${PR_EXISTS} を更新しました（push 済み）"
else
  INTERNAL_PR_URL=$(GH_HOST="$GH_HOST" gh pr create \
    --repo "${GH_ORG}/${GH_REPO}" \
    --title "[External] ${PR_TITLE}" \
    --body "## 外部 PR の転送

| 項目       | 内容 |
|------------|------|
| 外部 PR    | ${PR_URL} |
| 外部作者   | ${PR_AUTHOR} |

## 元の PR 説明

${PR_BODY}

---
> この PR は外部レプリカからの変更を社内でレビューするために自動生成されました。
> 承認・マージ後、外部 PR を Close してください（マージしないこと）。" \
    --base main \
    --head "$BRANCH" \
    --label "external-contribution")

  ok "内部 PR を作成しました: ${INTERNAL_PR_URL}"
fi
