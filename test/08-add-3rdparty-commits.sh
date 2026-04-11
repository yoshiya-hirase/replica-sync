#!/usr/bin/env bash
# 08-add-3rdparty-commits.sh
#
# Adds commits to a 3rd party development branch.
# Creates changes in multiple service paths so cherry-pick-partial.sh can be tested.
#
# Usage:
#   ./test/08-add-3rdparty-commits.sh --party acme
#   ./test/08-add-3rdparty-commits.sh --party acme --branch feature/my-feature
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

log() { echo -e "\033[1;34m[3rdparty]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[   ok  ]\033[0m $*"; }
die() { echo -e "\033[1;31m[  err  ]\033[0m $*" >&2; exit 1; }

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

cd "$REPLICA_REPO"

# Ensure we're on the right branch
git fetch origin
git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/${BRANCH}"
git merge --ff-only "origin/${BRANCH}" 2>/dev/null || true

COUNT=$(git rev-list --count HEAD)
TS=$(date +%Y%m%d-%H%M%S)

log "Adding 3rd party commits on branch '${BRANCH}' (iteration ${COUNT})..."

# ── Change 1: new feature in services/api (likely to be accepted) ──
mkdir -p services/api

cat > "services/api/ExternalFeature${COUNT}.kt" << EOF
// ExternalFeature${COUNT}.kt
// Contributed by: ${PARTY}
// This is a new feature added by the 3rd party.
class ExternalFeature${COUNT} {
    fun process(input: String): String =
        "${PARTY}-feature-${COUNT}: processed \$input at ${TS}"

    fun validate(input: String): Boolean = input.isNotBlank()
}
EOF

git add -A
git commit -m "feat(${PARTY}): add external feature ${COUNT} in services/api"

# ── Change 2: update common utils (partially acceptable) ──────
cat >> services/common/Utils.kt << EOF

// Added by ${PARTY} (iteration ${COUNT})
fun formatExternal(value: Any, prefix: String = "${PARTY}"): String =
    "[\$prefix] \${value}"
EOF

git add -A
git commit -m "feat(${PARTY}): extend Utils with formatExternal"

# ── Change 3: new directory (may or may not be accepted) ──────
mkdir -p "services/${PARTY}-extensions"

cat > "services/${PARTY}-extensions/Extension${COUNT}.kt" << EOF
// Extension${COUNT}.kt - ${PARTY} specific extension
// This is a party-specific service that may not fit the internal design.
object ${PARTY^}Extension${COUNT} {
    const val PARTY_NAME = "${PARTY}"
    fun describe(): String = "${PARTY} extension v${COUNT}"
}
EOF

git add -A
git commit -m "feat(${PARTY}): add ${PARTY}-specific extension service"

# ── Push ─────────────────────────────────────────────────────
git push origin "$BRANCH"

ok "Added 3 commits to ${PARTY}/${BRANCH}:"
ok "  1. services/api/ExternalFeature${COUNT}.kt      (new feature — likely accepted)"
ok "  2. services/common/Utils.kt                     (extension — partially acceptable)"
ok "  3. services/${PARTY}-extensions/Extension${COUNT}.kt (party-specific — test rejection)"
echo ""
echo "Next: create PR to main"
echo "  ./test/09-create-3rdparty-pr.sh --party ${PARTY} --branch ${BRANCH}"
