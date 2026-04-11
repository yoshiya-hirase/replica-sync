#!/usr/bin/env bash
# 07-setup-3rdparty-branch.sh
#
# Creates a development branch on a 3rd party repo, branching off main.
# Simulates a 3rd party starting development on top of the synced content.
#
# Usage:
#   ./test/07-setup-3rdparty-branch.sh --party acme
#   ./test/07-setup-3rdparty-branch.sh --party acme --branch feature/my-feature
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

log() { echo -e "\033[1;34m[branch]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok  ]\033[0m $*"; }
die() { echo -e "\033[1;31m[  err ]\033[0m $*" >&2; exit 1; }

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
[[ -f "$PARTY_CONF" ]] || die "Party config not found: ${PARTY_CONF}. Run 04-create-party-repo.sh first."
source "$PARTY_CONF"

[[ -d "$REPLICA_REPO" ]] || die "Party repo not found at ${REPLICA_REPO}. Run 04-create-party-repo.sh first."

cd "$REPLICA_REPO"

log "Updating main branch..."
git fetch origin
git checkout main
git merge --ff-only origin/main

log "Creating branch: ${BRANCH}"
if git rev-parse --verify "refs/heads/${BRANCH}" >/dev/null 2>&1; then
  log "Branch '${BRANCH}' already exists locally, checking out"
  git checkout "$BRANCH"
elif git rev-parse --verify "refs/remotes/origin/${BRANCH}" >/dev/null 2>&1; then
  log "Branch '${BRANCH}' exists on remote, checking out"
  git checkout -b "$BRANCH" "origin/${BRANCH}"
else
  git checkout -b "$BRANCH"
  git push -u origin "$BRANCH"
  ok "Branch '${BRANCH}' created and pushed"
fi

ok "Party '${PARTY}' is on branch '${BRANCH}'"
ok "  Local: ${REPLICA_REPO}"
ok "  GitHub: https://github.com/${REPLICA_GH_REPO}/tree/${BRANCH}"
echo ""
echo "Next: add commits to this branch"
echo "  ./test/08-add-3rdparty-commits.sh --party ${PARTY} --branch ${BRANCH}"
