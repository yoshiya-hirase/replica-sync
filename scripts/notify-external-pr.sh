#!/usr/bin/env bash
# notify-external-pr.sh
#
# 外部 PR への採否結果通知スクリプト。
# 社内レビュー結果を github.com の外部 PR にコメントし、
# 却下の場合は外部 PR を Close する。
#
# Usage:
#   # 全部採用
#   ./scripts/notify-external-pr.sh --meta pr-meta.json --status accepted
#
#   # 一部採用
#   ./scripts/notify-external-pr.sh --meta pr-meta.json --status partial
#
#   # 却下
#   ./scripts/notify-external-pr.sh --meta pr-meta.json \
#     --status rejected --reason "設計方針と不一致"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

[[ -f "$CONFIG_FILE" ]] || { echo "設定ファイルが見つかりません: $CONFIG_FILE"; exit 1; }
# shellcheck source=../config/sync.conf.example
source "$CONFIG_FILE"

ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

# ── 引数パース ─────────────────────────────────────────────────
META_FILE=""
STATUS=""
REASON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --meta)   META_FILE="$2"; shift 2 ;;
    --status) STATUS="$2";    shift 2 ;;
    --reason) REASON="$2";    shift 2 ;;
    *) die "不明なオプション: $1" ;;
  esac
done

[[ -f "$META_FILE" ]] || die "meta ファイルが見つかりません: $META_FILE"
[[ -n "$STATUS"    ]] || die "--status accepted / partial / rejected を指定してください"

case "$STATUS" in
  accepted|partial|rejected) ;;
  *) die "--status は accepted / partial / rejected のいずれかを指定してください" ;;
esac

PR_NUMBER=$(jq -r '.pr_number' "$META_FILE")

# ── コメント本文 ───────────────────────────────────────────────
case "$STATUS" in
  accepted)
    COMMENT="✅ この変更は社内でレビューされ、採用されました。
次回 milestone sync でこのブランチに反映されます。
反映後にこの PR を Close します。"
    ;;
  partial)
    COMMENT="⚠️ この変更は社内でレビューされ、一部が採用されました。
次回 milestone sync でこのブランチに反映されます。
反映後にこの PR を Close します。"
    ;;
  rejected)
    COMMENT="❌ この変更は社内でレビューされましたが、採用されませんでした。
理由: ${REASON:-"（理由未記載）"}"
    ;;
esac

# ── github.com の外部 PR にコメント ───────────────────────────
gh pr comment "$PR_NUMBER" \
  --repo "$REPLICA_GH_REPO" \
  --body "$COMMENT"

ok "PR #${PR_NUMBER} にコメントしました（status: ${STATUS}）"

# ── 却下の場合は外部 PR を Close ─────────────────────────────
if [[ "$STATUS" == "rejected" ]]; then
  gh pr close "$PR_NUMBER" \
    --repo "$REPLICA_GH_REPO"

  ok "PR #${PR_NUMBER} を Close しました"
fi
