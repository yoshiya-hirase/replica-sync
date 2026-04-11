#!/usr/bin/env bash
# 03-generate-sync-conf.sh
#
# Generates config/sync.conf from test.conf values.
# Run once after 01-setup-internal.sh.
#
# Usage:
#   ./test/03-generate-sync-conf.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_CONF="${SCRIPT_DIR}/test.conf"

[[ -f "$TEST_CONF" ]] || { echo "test.conf not found. Run: cp test/test.conf.example test/test.conf and edit it"; exit 1; }
source "$TEST_CONF"

ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

SYNC_CONF="${REPO_ROOT}/config/sync.conf"
INTERNAL_LOCAL="${TEST_DIR}/internal"

if [[ -f "$SYNC_CONF" ]]; then
  echo "config/sync.conf already exists."
  read -r -p "Overwrite? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Skipped."; exit 0; }
fi

mkdir -p "${REPO_ROOT}/config/party"

cat > "$SYNC_CONF" << EOF
# replica-sync configuration (generated for test scenario)
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# ── Internal repository (GitHub, acting as GHE for test) ─────

INTERNAL_REPO="${INTERNAL_LOCAL}"
INTERNAL_REMOTE="origin"

GH_HOST="github.com"
GH_ORG="${GITHUB_USER}"
GH_REPO="${INTERNAL_REPO_NAME}"

# ── Sync settings ─────────────────────────────────────────────

SYNC_AUTHOR_NAME="Sync Test Bot"
SYNC_AUTHOR_EMAIL="sync-test@example.com"

EXCLUDE_PATHS=(
  "internal-only/"
  ".secrets/"
)

PATCH_OUTPUT_DIR="${REPO_ROOT}/test-patches"
EOF

ok "Generated: config/sync.conf"
ok "  INTERNAL_REPO : ${INTERNAL_LOCAL}"
ok "  GH_HOST       : github.com"
ok "  GH_ORG        : ${GITHUB_USER}"
ok "  GH_REPO       : ${INTERNAL_REPO_NAME}"
ok "  EXCLUDE_PATHS : internal-only/ .secrets/"
echo ""
echo "Next: run init-replica.sh"
echo "  ./scripts/init-replica.sh milestone/v1"
