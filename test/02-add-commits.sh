#!/usr/bin/env bash
# 02-add-commits.sh
#
# Adds more commits to the test internal repo to simulate ongoing development.
# Can be run multiple times. Each run adds a new feature with public + excluded files.
#
# Usage:
#   ./test/02-add-commits.sh                   # no milestone tag
#   ./test/02-add-commits.sh milestone/v2      # create milestone tag at HEAD
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CONF="${SCRIPT_DIR}/test.conf"
[[ -f "$TEST_CONF" ]] || { echo "test.conf not found."; exit 1; }
source "$TEST_CONF"

log() { echo -e "\033[1;34m[commits]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[   ok  ]\033[0m $*"; }
die() { echo -e "\033[1;31m[  err  ]\033[0m $*" >&2; exit 1; }

MILESTONE="${1:-}"
INTERNAL_LOCAL="${TEST_DIR}/internal"

[[ -d "$INTERNAL_LOCAL" ]] || die "Internal repo not found at ${INTERNAL_LOCAL}. Run 01-setup-internal.sh first."

cd "$INTERNAL_LOCAL"
git fetch origin
git merge --ff-only origin/main

# Use commit count to generate unique names per run
COUNT=$(git rev-list --count HEAD)
TS=$(date +%Y%m%d-%H%M%S)

log "Adding feature-${COUNT} commits (${TS})..."

# ── Public service (will appear in publish branch) ────────────
mkdir -p "services/feature-${COUNT}"

cat > "services/feature-${COUNT}/FeatureService.kt" << EOF
// FeatureService${COUNT}.kt - Feature service
class FeatureService${COUNT} {
    fun execute(input: String): String = "feature-${COUNT}: processed \$input"
    fun status(): String = "feature-${COUNT} active since ${TS}"
}
EOF

cat > "services/feature-${COUNT}/FeatureHandler.kt" << EOF
// FeatureHandler${COUNT}.kt - Feature HTTP handler
class FeatureHandler${COUNT}(private val svc: FeatureService${COUNT}) {
    fun handle(input: String): Map<String, String> =
        mapOf("result" to svc.execute(input), "status" to svc.status())
}
EOF

git add -A
git commit -m "feat: add feature-${COUNT} service"

# ── Public update to existing service ─────────────────────────
cat >> services/api/ApiRouter.kt << EOF

// Route added for feature-${COUNT}
fun routeFeature${COUNT}(input: String): String =
    FeatureService${COUNT}().execute(input)
EOF

# ── Excluded file (should NOT appear in publish branch) ───────
mkdir -p internal-only
cat > "internal-only/Feature${COUNT}Config.kt" << EOF
// Feature${COUNT}Config.kt - INTERNAL ONLY
object Feature${COUNT}Config {
    const val INTERNAL_FLAG_${COUNT} = true
    const val ROLLOUT_PERCENT_${COUNT} = 20
    const val INTERNAL_ENDPOINT_${COUNT} = "http://internal-feature-${COUNT}.svc"
}
EOF

git add -A
git commit -m "feat: add feature-${COUNT} routing and internal config"

# ── Create milestone tag if requested ────────────────────────
if [[ -n "$MILESTONE" ]]; then
  if git rev-parse --verify "refs/tags/${MILESTONE}" >/dev/null 2>&1; then
    log "Tag '${MILESTONE}' already exists, skipping"
  else
    git tag -a "$MILESTONE" -m "milestone: ${MILESTONE}"
    git push origin "$MILESTONE"
    ok "Milestone tag created: ${MILESTONE}"
  fi
fi

git push origin main

ok "Added 2 commits (feature-${COUNT})"
ok "  Public files : services/feature-${COUNT}/"
ok "  Excluded     : internal-only/Feature${COUNT}Config.kt"
[[ -n "$MILESTONE" ]] && ok "  Milestone    : ${MILESTONE}"
