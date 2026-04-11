#!/usr/bin/env bash
# init-replica.sh
#
# Initializes the publish branch for milestone sync.
# Extracts a file-tree snapshot via git archive (no history, EXCLUDE_PATHS applied)
# and opens a GHE PR targeting the publish branch for internal review.
#
# After the PR is merged, run deliver-to-replica.sh for each 3rd party
# to push the content to their external replica.
#
# Usage:
#   ./scripts/init-replica.sh milestone/2024-Q1
#
#   # Add a note to the init tag
#   ./scripts/init-replica.sh --message "initial setup for 3rd party collaboration" \
#     milestone/2024-Q1
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
declare -p EXCLUDE_PATHS >/dev/null 2>&1 || EXCLUDE_PATHS=()

log() { echo -e "\033[1;34m[init]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────
MESSAGE=""
START_TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) MESSAGE="$2"; shift 2 ;;
    --*)       die "Unknown option: $1" ;;
    *)         START_TAG="$1"; shift ;;
  esac
done

[[ -n "$START_TAG" ]] || die "Specify a start tag\n  Usage: $0 [--message <text>] <start-tag>\n  Example: $0 milestone/2024-Q1"

# ── Helpers ────────────────────────────────────────────────────
build_exclude_args() {
  EXCLUDE_ARGS=()
  for path in "${EXCLUDE_PATHS[@]}"; do
    EXCLUDE_ARGS+=(":!${path}")
  done
}

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
INIT_BRANCH="init/${TIMESTAMP}"
PUBLISH_BRANCH="publish"

INIT_TAG="publish/init-${TIMESTAMP}"
TAG_MESSAGE="start_tag: ${START_TAG}
timestamp: ${TIMESTAMP}"
[[ -n "$MESSAGE" ]] && TAG_MESSAGE="${TAG_MESSAGE}
note: ${MESSAGE}"

# ── Pre-flight checks ─────────────────────────────────────────
cd "$INTERNAL_REPO"
build_exclude_args

git rev-parse --verify "refs/tags/${START_TAG}" >/dev/null 2>&1 \
  || die "'${START_TAG}' is not a tag. Specify a tag (e.g. milestone/v1), not a branch."

git rev-parse --verify "refs/heads/${PUBLISH_BRANCH}" >/dev/null 2>&1 \
  && die "Publish branch '${PUBLISH_BRANCH}' already exists.\n" \
         "Use stage-publish.sh to update it."

REPLICA_DIR=$(mktemp -d /tmp/replica-init-XXXXXX)
WORK_DIR=$(mktemp -d /tmp/init-work-XXXXXX)
cleanup() {
  rm -rf "$REPLICA_DIR"
  git -C "$INTERNAL_REPO" worktree remove "$WORK_DIR" --force 2>/dev/null || true
}
trap cleanup EXIT

log "Start tag  : $START_TAG"
log "Init branch: $INIT_BRANCH"

# ── Step 1: Extract file tree (EXCLUDE_PATHS applied) ────────
log "Extracting snapshot via git archive..."
git archive "$START_TAG" -- . "${EXCLUDE_ARGS[@]}" | tar -x -C "$REPLICA_DIR"

# ── Step 2: Create publish branch with empty base commit ─────
log "Creating publish branch with empty base commit..."
EMPTY_TREE=$(git hash-object -t tree /dev/null)
EMPTY_COMMIT=$(
  GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
  GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
  GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
  GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
  git commit-tree "$EMPTY_TREE" -m "publish: initial empty base"
)
git branch "$PUBLISH_BRANCH" "$EMPTY_COMMIT"

# ── Step 3: Create init branch and apply snapshot ─────────────
log "Creating init branch from publish..."
git worktree add "$WORK_DIR" -b "$INIT_BRANCH" "$PUBLISH_BRANCH"

cd "$WORK_DIR"
log "Applying snapshot..."
cp -r "$REPLICA_DIR"/. .
git add -A

if git diff --cached --quiet; then
  die "No content after applying EXCLUDE_PATHS. Check the start tag and EXCLUDE_PATHS."
fi

GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git commit -m "initial: ${START_TAG}"

ok "Commit: $(git rev-parse --short HEAD)"

# ── Step 4: Push to GHE and open PR ──────────────────────────
cd "$INTERNAL_REPO"
log "Pushing to GHE..."
git push "$INTERNAL_REMOTE" "$PUBLISH_BRANCH"
git push "$INTERNAL_REMOTE" "$INIT_BRANCH"

EXCLUDED_LIST="${EXCLUDE_PATHS[*]:-(none)}"

PR_BODY="## initial: ${START_TAG}

| Field | Value |
|---|---|
| Start tag | \`${START_TAG}\` |
| Created at | $(date '+%Y-%m-%d %H:%M:%S') |

## Excluded paths (EXCLUDE_PATHS)

\`\`\`
${EXCLUDED_LIST}
\`\`\`

> Review the snapshot content and merge into \`${PUBLISH_BRANCH}\`.
> After merge, run \`deliver-to-replica.sh --party <name>\` to push to each external replica."

GH_HOST="$GH_HOST" gh pr create \
  --repo  "${GH_ORG}/${GH_REPO}" \
  --title "initial: ${START_TAG}" \
  --body  "$PR_BODY" \
  --base  "$PUBLISH_BRANCH" \
  --head  "$INIT_BRANCH"

ok "PR created on GHE: ${INIT_BRANCH} -> ${PUBLISH_BRANCH}"

# ── Step 5: Set init tag ──────────────────────────────────────
log "Setting init tag..."
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git tag -a "$INIT_TAG" "$START_TAG" -m "$TAG_MESSAGE"

ok "Init tag: $INIT_TAG -> $START_TAG"
echo ""
echo "Next steps:"
echo "  1. Review and merge the PR on GHE into ${PUBLISH_BRANCH}"
echo "  2. For each 3rd party, run deliver-to-replica.sh:"
echo "     ./scripts/deliver-to-replica.sh --party <name> \"initial: ${START_TAG}\""
