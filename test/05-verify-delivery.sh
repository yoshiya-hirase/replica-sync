#!/usr/bin/env bash
# 05-verify-delivery.sh
#
# Verifies that the party repo's main branch content matches the publish branch.
# Compares file lists and content checksums (excluding .git).
#
# Usage:
#   ./test/05-verify-delivery.sh --party acme
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_CONF="${SCRIPT_DIR}/test.conf"

[[ -f "$TEST_CONF" ]] || { echo "test.conf not found."; exit 1; }
source "$TEST_CONF"

SYNC_CONF="${REPO_ROOT}/config/sync.conf"
[[ -f "$SYNC_CONF" ]] || { echo "config/sync.conf not found. Run 03-generate-sync-conf.sh first."; exit 1; }
source "$SYNC_CONF"

ok()   { echo -e "\033[1;32m[  ok  ]\033[0m $*"; }
fail() { echo -e "\033[1;31m[ FAIL ]\033[0m $*"; }
log()  { echo -e "\033[1;34m[verify]\033[0m $*"; }
die()  { echo -e "\033[1;31m[  err ]\033[0m $*" >&2; exit 1; }

PARTY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --party) PARTY="$2"; shift 2 ;;
    *) die "Unknown option: $1\nUsage: $0 --party <name>" ;;
  esac
done
[[ -n "$PARTY" ]] || die "Specify --party <name>"

PARTY_CONF="${REPO_ROOT}/config/party/${PARTY}.conf"
[[ -f "$PARTY_CONF" ]] || die "Party config not found: ${PARTY_CONF}"
source "$PARTY_CONF"

# ── Pull latest from party repo ───────────────────────────────
log "Updating party repo (${PARTY})..."
cd "$REPLICA_REPO"
git fetch origin
git merge --ff-only "origin/${REPLICA_BRANCH}"

# ── Export publish branch to temp dir ────────────────────────
PUBLISH_EXPORT=$(mktemp -d /tmp/verify-publish-XXXXXX)
PARTY_EXPORT=$(mktemp -d /tmp/verify-party-XXXXXX)
trap 'rm -rf "$PUBLISH_EXPORT" "$PARTY_EXPORT"' EXIT

log "Exporting publish branch content..."
cd "$INTERNAL_REPO"
git archive publish | tar -x -C "$PUBLISH_EXPORT"

log "Exporting party repo content..."
cd "$REPLICA_REPO"
git archive HEAD | tar -x -C "$PARTY_EXPORT"

# Remove .github/workflows from party export (not in publish branch)
rm -rf "${PARTY_EXPORT}/.github"

# ── Compare file lists ────────────────────────────────────────
log "Comparing file lists..."
PUBLISH_FILES=$(find "$PUBLISH_EXPORT" -type f | sed "s|${PUBLISH_EXPORT}/||" | sort)
PARTY_FILES=$(find "$PARTY_EXPORT"   -type f | sed "s|${PARTY_EXPORT}/||"   | sort)

DIFF_FILES=$(diff <(echo "$PUBLISH_FILES") <(echo "$PARTY_FILES") || true)

ERRORS=0

if [[ -n "$DIFF_FILES" ]]; then
  fail "File list mismatch:"
  echo "$DIFF_FILES" | sed 's/^/  /'
  ERRORS=$(( ERRORS + 1 ))
else
  ok "File lists match"
fi

# ── Compare content checksums ─────────────────────────────────
log "Comparing file contents..."
PUBLISH_CHECKSUMS=$(find "$PUBLISH_EXPORT" -type f \
  | sort | xargs shasum 2>/dev/null | sed "s|  ${PUBLISH_EXPORT}/|  |")
PARTY_CHECKSUMS=$(find "$PARTY_EXPORT" -type f \
  | sort | xargs shasum 2>/dev/null | sed "s|  ${PARTY_EXPORT}/|  |")

DIFF_CHECKSUMS=$(diff <(echo "$PUBLISH_CHECKSUMS") <(echo "$PARTY_CHECKSUMS") || true)

if [[ -n "$DIFF_CHECKSUMS" ]]; then
  fail "Content mismatch:"
  echo "$DIFF_CHECKSUMS" | sed 's/^/  /'
  ERRORS=$(( ERRORS + 1 ))
else
  ok "File contents match"
fi

# ── Check excluded paths are NOT in party repo ────────────────
log "Checking excluded paths are absent from party repo..."
for excluded in "${EXCLUDE_PATHS[@]:-}"; do
  [[ -z "$excluded" ]] && continue
  excluded="${excluded%/}"
  if [[ -e "${PARTY_EXPORT}/${excluded}" ]]; then
    fail "Excluded path found in party repo: ${excluded}"
    ERRORS=$(( ERRORS + 1 ))
  else
    ok "Excluded path absent: ${excluded}"
  fi
done

# ── Summary ───────────────────────────────────────────────────
echo ""
if [[ $ERRORS -eq 0 ]]; then
  ok "Verification passed: publish branch == ${PARTY} repo main"
else
  fail "Verification FAILED: ${ERRORS} issue(s) found"
  exit 1
fi
