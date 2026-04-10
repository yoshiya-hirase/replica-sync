#!/usr/bin/env bash
# stage-publish.sh
#
# Milestone sync - Phase 1.
# Squashes changes from internal/main (EXCLUDE_PATHS applied) and opens a PR
# on GHE targeting the publish branch for internal review.
# After review and merge, run deliver-to-replica.sh to push to external replicas.
#
# Usage:
#   ./scripts/stage-publish.sh "sync: 2024-Q1"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

[[ -f "$CONFIG_FILE" ]] || {
  echo "Config file not found: $CONFIG_FILE"
  echo "Run: cp config/sync.conf.example config/sync.conf and edit it"
  exit 1
}
# shellcheck source=../config/sync.conf.example
source "$CONFIG_FILE"

# Defaults for optional config values (prevents -u errors when unset)
[[ -v EXCLUDE_PATHS ]] || EXCLUDE_PATHS=()

log() { echo -e "\033[1;34m[stage]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok  ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err  ]\033[0m $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────
COMMIT_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --*) die "Unknown option: $1" ;;
    *)   COMMIT_MSG="$1"; shift ;;
  esac
done

COMMIT_MSG="${COMMIT_MSG:-"sync: $(date +%Y-%m-%d)"}"

PUBLISH_BRANCH="publish"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SYNC_BRANCH="sync/${TIMESTAMP}"

log "Commit message: $COMMIT_MSG"
log "Publish branch: $PUBLISH_BRANCH"
log "Sync branch   : $SYNC_BRANCH"

# ── Helpers ────────────────────────────────────────────────────
build_exclude_args() {
  EXCLUDE_ARGS=()
  for path in "${EXCLUDE_PATHS[@]}"; do
    EXCLUDE_ARGS+=(":!${path}")
  done
}

# ── Step 1: Pre-flight checks ─────────────────────────────────
cd "$INTERNAL_REPO"
build_exclude_args

git rev-parse --verify "refs/heads/${PUBLISH_BRANCH}" >/dev/null 2>&1 \
  || die "Publish branch '$PUBLISH_BRANCH' not found.\n" \
         "Run initial setup first:\n" \
         "  ./scripts/init-replica.sh <start-tag>"

PUBLISH_HEAD=$(git rev-parse "$PUBLISH_BRANCH")
INTERNAL_HEAD=$(git rev-parse HEAD)

if [[ "$PUBLISH_HEAD" == "$INTERNAL_HEAD" ]]; then
  ok "No diff. Publish branch is up to date."
  exit 0
fi

log "Diff range: ${PUBLISH_HEAD:0:8}..${INTERNAL_HEAD:0:8}"

# ── Step 2: Generate diff patch ───────────────────────────────
PATCH_FILE=$(mktemp /tmp/stage-publish-XXXXXX.patch)
WORK_DIR=$(mktemp -d /tmp/stage-publish-work-XXXXXX)
cleanup() {
  rm -f "$PATCH_FILE"
  git -C "$INTERNAL_REPO" worktree remove "$WORK_DIR" --force 2>/dev/null || true
}
trap cleanup EXIT

git diff "${PUBLISH_HEAD}..HEAD" -- . "${EXCLUDE_ARGS[@]}" > "$PATCH_FILE"

if [[ ! -s "$PATCH_FILE" ]]; then
  ok "No diff after applying exclude paths. Skipping."
  exit 0
fi

log "Patch size: $(wc -l < "$PATCH_FILE") lines"

# ── Step 3: Create sync branch based on publish ───────────────
log "Creating temporary worktree..."
git worktree add "$WORK_DIR" -b "$SYNC_BRANCH" "$PUBLISH_BRANCH"

# ── Step 4: Apply patch and create squash commit ──────────────
cd "$WORK_DIR"
log "Applying patch..."
git apply --3way --whitespace=nowarn "$PATCH_FILE" \
  || die "Patch apply failed. Resolve conflicts and re-run."

git add -A

if git diff --cached --quiet; then
  ok "Nothing to commit after staging."
else
  SUMMARY=$(
    cd "$INTERNAL_REPO"
    git log --oneline --no-merges "${PUBLISH_HEAD}..${INTERNAL_HEAD}" \
      -- . "${EXCLUDE_ARGS[@]}" | head -50
  )

  GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
  GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
  GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
  GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
  git commit -m "$COMMIT_MSG" -m "$SUMMARY"

  ok "Commit: $(git rev-parse --short HEAD)"
fi

# ── Step 5: Push sync branch to GHE ──────────────────────────
cd "$INTERNAL_REPO"
log "Pushing sync branch to GHE..."
git push "$INTERNAL_REMOTE" "$SYNC_BRANCH"

# ── Step 6: Open PR on GHE (sync/TIMESTAMP -> publish) ───────
SUMMARY_FOR_PR=$(
  git log --oneline --no-merges "${PUBLISH_HEAD}..${INTERNAL_HEAD}" \
    -- . "${EXCLUDE_ARGS[@]}" | head -50
)

PR_BODY="## ${COMMIT_MSG}

| Field | Value |
|---|---|
| Diff range | \`${PUBLISH_HEAD:0:8}\`..\`${INTERNAL_HEAD:0:8}\` |
| Target branch | \`${PUBLISH_BRANCH}\` |
| Created at | $(date '+%Y-%m-%d %H:%M:%S') |

## Included internal commits

\`\`\`
${SUMMARY_FOR_PR}
\`\`\`

> After review, merge this PR into \`${PUBLISH_BRANCH}\`, then run
> \`deliver-to-replica.sh --party <name>\` to push to each external replica."

GH_HOST="$GH_HOST" gh pr create \
  --repo  "${GH_ORG}/${GH_REPO}" \
  --title "$COMMIT_MSG" \
  --body  "$PR_BODY" \
  --base  "$PUBLISH_BRANCH" \
  --head  "$SYNC_BRANCH"

ok "PR created on GHE: ${SYNC_BRANCH} -> ${PUBLISH_BRANCH}"
echo ""
echo "Next steps:"
echo "  1. Review and merge the PR on GHE into ${PUBLISH_BRANCH}"
echo "  2. For each 3rd party, run deliver-to-replica.sh:"
echo "     ./scripts/deliver-to-replica.sh --party <name> \"${COMMIT_MSG}\""
