#!/usr/bin/env bash
# cherry-pick-partial.sh
#
# Selectively applies changes from an external PR patch.
# Only hunks matching the specified paths are applied.
#
# Usage:
#   # Cherry-pick the entire commit
#   git cherry-pick external/3rdparty-pr-123
#
#   # Apply only specific paths from a patch file
#   ./scripts/cherry-pick-partial.sh \
#     --patch pr-123.patch \
#     --meta  pr-123-meta.json \
#     --paths "services/api/" "services/common/" \
#     --message "Accept API changes only"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

[[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE"; exit 1; }
# shellcheck source=../config/sync.conf.example
source "$CONFIG_FILE"

log() { echo -e "\033[1;34m[partial]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[   ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[  err ]\033[0m $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────
PATCH_FILE=""
META_FILE=""
PATHS=()
COMMIT_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch)   PATCH_FILE="$2"; shift 2 ;;
    --meta)    META_FILE="$2";  shift 2 ;;
    --message) COMMIT_MSG="$2"; shift 2 ;;
    --paths)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        PATHS+=("$1"); shift
      done
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -f "$PATCH_FILE" ]] || die "Patch file not found: $PATCH_FILE"
[[ -f "$META_FILE"  ]] || die "Meta file not found: $META_FILE"
[[ ${#PATHS[@]} -gt 0 ]] || die "Specify at least one path with --paths"

PR_NUMBER=$(jq -r '.pr_number' "$META_FILE")
PR_TITLE=$(jq  -r '.pr_title'  "$META_FILE")
PR_URL=$(jq    -r '.pr_url'    "$META_FILE")
PR_AUTHOR=$(jq -r '.pr_author' "$META_FILE")

COMMIT_MSG="${COMMIT_MSG:-"external(partial): ${PR_TITLE}"}"

log "PR      : #${PR_NUMBER} ${PR_TITLE}"
log "Paths   : ${PATHS[*]}"
log "Message : $COMMIT_MSG"

# ── Update internal repo ──────────────────────────────────────
cd "$INTERNAL_REPO"
git fetch "$INTERNAL_REMOTE"
git checkout main
git merge --ff-only "${INTERNAL_REMOTE}/main"

# ── Apply only hunks matching the specified paths ─────────────
INCLUDE_ARGS=()
for path in "${PATHS[@]}"; do
  INCLUDE_ARGS+=(--include="$path")
done

log "Applying patch (path-filtered)..."
if ! git apply --3way --whitespace=nowarn "${INCLUDE_ARGS[@]}" "$PATCH_FILE"; then
  die "Patch apply failed. Resolve conflicts manually."
fi

git add -A

if git diff --cached --quiet; then
  die "No diff for the specified paths. Check the path list."
fi

# ── Commit ────────────────────────────────────────────────────
GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git commit \
  -m "$COMMIT_MSG" \
  -m "Source PR : ${PR_URL}
External author: ${PR_AUTHOR}
Accepted paths : ${PATHS[*]}"

ok "Commit: $(git rev-parse --short HEAD)"
