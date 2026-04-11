#!/usr/bin/env bash
# notify-external-pr.sh
#
# Posts the upstream review decision to the external PR on github.com.
# Closes the external PR when the decision is rejected.
#
# Two output modes:
#
#   push (default): post directly via gh CLI (requires access to REPLICA_GH_REPO)
#   patch:          generate a notification package (notify script + meta) to send
#                   to the 3rd party, who runs it on their own machine
#
# Usage:
#   # Push mode (default) — post directly
#   ./scripts/notify-external-pr.sh --party acme --meta pr-meta.json --status accepted
#
#   # Patch mode — generate notification package for 3rd party
#   ./scripts/notify-external-pr.sh --party acme --meta pr-meta.json \
#     --status partial --output patch
#
#   # With reason (rejected)
#   ./scripts/notify-external-pr.sh --party acme --meta pr-meta.json \
#     --status rejected --reason "Conflicts with design direction"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

[[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE"; exit 1; }
# shellcheck source=../config/sync.conf.example
source "$CONFIG_FILE"

ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

# Defaults for optional config values (prevents -u errors when unset)
: "${NOTIFY_OUTPUT_DIR:=./sync-patches}"

# ── Argument parsing ───────────────────────────────────────────
PARTY=""
META_FILE=""
STATUS=""
REASON=""
OUTPUT_MODE="push"   # push | patch

while [[ $# -gt 0 ]]; do
  case "$1" in
    --party)   PARTY="$2";       shift 2 ;;
    --meta)    META_FILE="$2";   shift 2 ;;
    --status)  STATUS="$2";      shift 2 ;;
    --reason)  REASON="$2";      shift 2 ;;
    --output)  OUTPUT_MODE="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$PARTY"     ]] || die "Specify a party name with --party\n  Example: $0 --party acme --meta pr-meta.json --status accepted"
[[ -f "$META_FILE" ]] || die "Meta file not found: $META_FILE"
[[ -n "$STATUS"    ]] || die "Specify --status accepted / partial / rejected"

case "$OUTPUT_MODE" in
  push|patch) ;;
  *) die "--output must be push or patch" ;;
esac

case "$STATUS" in
  accepted|partial|rejected) ;;
  *) die "--status must be accepted, partial, or rejected" ;;
esac

# Load per-party config (provides REPLICA_GH_REPO)
PARTY_CONFIG="${SCRIPT_DIR}/../config/party/${PARTY}.conf"
[[ -f "$PARTY_CONFIG" ]] || die "Party config not found: $PARTY_CONFIG\n  Run: cp config/party/party.conf.example config/party/${PARTY}.conf and edit it"
# shellcheck source=../config/party/party.conf.example
source "$PARTY_CONFIG"

PR_NUMBER=$(jq -r '.pr_number' "$META_FILE")

# ── Build comment body ────────────────────────────────────────
case "$STATUS" in
  accepted)
    COMMENT="✅ This change has been reviewed internally and accepted.
It will be reflected in this branch on the next milestone sync.
This PR will be closed after the sync completes."
    ;;
  partial)
    COMMENT="⚠️ This change has been reviewed internally and partially accepted.
The accepted portions will be reflected on the next milestone sync.
This PR will be closed after the sync completes."
    ;;
  rejected)
    COMMENT="❌ This change has been reviewed internally but was not accepted.
Reason: ${REASON:-"(no reason provided)"}"
    ;;
esac

CLOSE_PR="false"
[[ "$STATUS" == "rejected" ]] && CLOSE_PR="true"

# ── patch mode: generate notification package ─────────────────
if [[ "$OUTPUT_MODE" == "patch" ]]; then
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$NOTIFY_OUTPUT_DIR"

  DEST_META="${NOTIFY_OUTPUT_DIR}/notify-${TIMESTAMP}-meta.json"
  DEST_SCRIPT="${NOTIFY_OUTPUT_DIR}/notify-${TIMESTAMP}.sh"

  # Write meta
  cat > "$DEST_META" << EOF
{
  "pr_number":   ${PR_NUMBER},
  "repo":        "${REPLICA_GH_REPO}",
  "status":      "${STATUS}",
  "close_pr":    ${CLOSE_PR},
  "comment":     $(echo "$COMMENT" | jq -Rs .)
}
EOF

  # Write standalone notify script
  cat > "$DEST_SCRIPT" << 'NOTIFY_TEMPLATE'
#!/usr/bin/env bash
# Upstream review notification script (generated)
#
# Usage:
#   # Run from any directory on the 3rd party's machine
#   ./notify-TIMESTAMP.sh
#
# Prerequisites: gh CLI (authenticated), jq
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_FILE="${SCRIPT_DIR}/notify-TIMESTAMP-meta.json"

[[ -f "$META_FILE" ]] || { echo "Meta file not found: $META_FILE"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is not installed"; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "gh CLI is not installed"; exit 1; }

PR_NUMBER=$(jq -r '.pr_number' "$META_FILE")
REPO=$(jq     -r '.repo'       "$META_FILE")
COMMENT=$(jq  -r '.comment'    "$META_FILE")
CLOSE_PR=$(jq -r '.close_pr'   "$META_FILE")

gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$COMMENT"
echo "Comment posted on PR #${PR_NUMBER}"

if [[ "$CLOSE_PR" == "true" ]]; then
  gh pr close "$PR_NUMBER" --repo "$REPO"
  echo "PR #${PR_NUMBER} closed"
fi
NOTIFY_TEMPLATE

  # Replace TIMESTAMP placeholder in script
  sed -i '' "s/notify-TIMESTAMP-meta/notify-${TIMESTAMP}-meta/g" "$DEST_SCRIPT"
  chmod +x "$DEST_SCRIPT"

  ok "Notification package generated:"
  echo "  meta  : $DEST_META"
  echo "  script: $DEST_SCRIPT"
  echo ""
  echo "Send the following files to the 3rd party and ask them to run the script:"
  echo "  $DEST_META"
  echo "  $DEST_SCRIPT"
  exit 0
fi

# ── push mode: post directly via gh CLI ──────────────────────
gh pr comment "$PR_NUMBER" \
  --repo "$REPLICA_GH_REPO" \
  --body "$COMMENT"

ok "Comment posted on PR #${PR_NUMBER} (status: ${STATUS})"

if [[ "$CLOSE_PR" == "true" ]]; then
  gh pr close "$PR_NUMBER" \
    --repo "$REPLICA_GH_REPO"

  ok "PR #${PR_NUMBER} closed"
fi
