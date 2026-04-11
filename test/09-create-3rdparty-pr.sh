#!/usr/bin/env bash
# 09-create-3rdparty-pr.sh
#
# Creates a PR from the 3rd party dev branch to main on the party repo.
# After creation, the pr-to-internal.yml CI workflow will generate
# a patch artifact automatically.
#
# Usage:
#   ./test/09-create-3rdparty-pr.sh --party acme
#   ./test/09-create-3rdparty-pr.sh --party acme --branch feature/my-feature
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_CONF="${SCRIPT_DIR}/test.conf"

[[ -f "$TEST_CONF" ]] || { echo "test.conf not found."; exit 1; }
source "$TEST_CONF"

SYNC_CONF="${REPO_ROOT}/config/sync.conf"
[[ -f "$SYNC_CONF" ]] || { echo "config/sync.conf not found."; exit 1; }
source "$SYNC_CONF"

log() { echo -e "\033[1;34m[pr]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[ ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[err ]\033[0m $*" >&2; exit 1; }

PARTY=""
BRANCH="dev"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --party)  PARTY="$2";  shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ -n "$PARTY" ]] || die "Specify --party <name>"

PARTY_CONF="${REPO_ROOT}/config/party/${PARTY}.conf"
[[ -f "$PARTY_CONF" ]] || die "Party config not found: ${PARTY_CONF}"
source "$PARTY_CONF"

# Check if PR already exists
EXISTING_PR=$(gh pr list \
  --repo "$REPLICA_GH_REPO" \
  --head "$BRANCH" \
  --base main \
  --json number \
  --jq '.[0].number // empty')

if [[ -n "$EXISTING_PR" ]]; then
  ok "PR already exists: #${EXISTING_PR}"
  ok "  https://github.com/${REPLICA_GH_REPO}/pull/${EXISTING_PR}"
  echo ""
  echo "CI should have run pr-to-internal.yml. Check status:"
  echo "  gh run list --repo ${REPLICA_GH_REPO} --workflow pr-to-internal.yml"
  echo ""
  echo "Once CI completes, download the artifact:"
  echo "  ./test/10-download-artifact.sh --party ${PARTY} --pr ${EXISTING_PR}"
  exit 0
fi

log "Creating PR on ${REPLICA_GH_REPO}: ${BRANCH} -> main..."

PR_BODY="## Changes from ${PARTY}

This PR contains contributions from the ${PARTY} team.

### Changes included

- \`services/api/\` — New external feature
- \`services/common/Utils.kt\` — Extended utility function
- \`services/${PARTY}-extensions/\` — Party-specific extension

### Review notes

Please review each change independently.
Partial cherry-pick (some paths only) is acceptable."

PR_URL=$(gh pr create \
  --repo "$REPLICA_GH_REPO" \
  --title "feat(${PARTY}): external contributions from ${BRANCH}" \
  --body "$PR_BODY" \
  --base main \
  --head "$BRANCH")

PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')

ok "PR created: #${PR_NUMBER}"
ok "  ${PR_URL}"
echo ""
echo "The pr-to-internal.yml CI workflow is now running."
echo "Monitor CI:"
echo "  gh run list --repo ${REPLICA_GH_REPO} --workflow pr-to-internal.yml"
echo ""
echo "Once CI completes (usually ~1 min), download the artifact:"
echo "  ./test/10-download-artifact.sh --party ${PARTY} --pr ${PR_NUMBER}"
