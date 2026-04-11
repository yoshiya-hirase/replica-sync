#!/usr/bin/env bash
# notify-external-pr.sh
#
# Posts the internal review decision to the external PR on github.com.
# Closes the external PR when the decision is rejected.
#
# Usage:
#   # Accepted
#   ./scripts/notify-external-pr.sh --party acme --meta pr-meta.json --status accepted
#
#   # Partially accepted
#   ./scripts/notify-external-pr.sh --party acme --meta pr-meta.json --status partial
#
#   # Rejected
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

# ── Argument parsing ───────────────────────────────────────────
PARTY=""
META_FILE=""
STATUS=""
REASON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --party)  PARTY="$2";     shift 2 ;;
    --meta)   META_FILE="$2"; shift 2 ;;
    --status) STATUS="$2";    shift 2 ;;
    --reason) REASON="$2";    shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$PARTY"     ]] || die "Specify a party name with --party\n  Example: $0 --party acme --meta pr-meta.json --status accepted"
[[ -f "$META_FILE" ]] || die "Meta file not found: $META_FILE"
[[ -n "$STATUS"    ]] || die "Specify --status accepted / partial / rejected"

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

# ── Post comment to external PR on github.com ────────────────
gh pr comment "$PR_NUMBER" \
  --repo "$REPLICA_GH_REPO" \
  --body "$COMMENT"

ok "Comment posted on PR #${PR_NUMBER} (status: ${STATUS})"

# ── Close external PR if rejected ────────────────────────────
if [[ "$STATUS" == "rejected" ]]; then
  gh pr close "$PR_NUMBER" \
    --repo "$REPLICA_GH_REPO"

  ok "PR #${PR_NUMBER} closed"
fi
