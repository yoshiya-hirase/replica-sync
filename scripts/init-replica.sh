#!/usr/bin/env bash
# init-replica.sh
#
# Initial replica setup script.
# Extracts a file-tree snapshot via git archive (no history) and
# initializes a history-free repository. git clone is intentionally
# avoided because it would copy the internal commit history.
#
# Usage:
#   # Push directly to github.com (default)
#   ./scripts/init-replica.sh --party acme milestone/2024-Q1
#
#   # Export tar for the 3rd party to set up on their own GitHub account
#   ./scripts/init-replica.sh --party acme --output export milestone/2024-Q1
#
#   # Add a note to the tags
#   ./scripts/init-replica.sh --party acme --message "initial setup for acme collaboration" milestone/2024-Q1
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

: "${PUBLISH_BRANCH_PREFIX:=publish}"

log() { echo -e "\033[1;34m[init]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────
OUTPUT_MODE="push"
PARTY=""
MESSAGE=""
START_TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)  OUTPUT_MODE="$2"; shift 2 ;;
    --party)   PARTY="$2";       shift 2 ;;
    --message) MESSAGE="$2";     shift 2 ;;
    --*)       die "Unknown option: $1" ;;
    *)         START_TAG="$1";   shift ;;
  esac
done

[[ -n "$START_TAG" ]] || die "Specify a start tag\n  Usage: $0 [--party <name>] [--output push|export] [--message <text>] <start-tag>\n  Example: $0 --party acme milestone/2024-Q1"
[[ -n "$PARTY"     ]] || die "Specify a party name with --party\n  Example: $0 --party acme milestone/2024-Q1"

case "$OUTPUT_MODE" in
  push|export) ;;
  *) die "--output must be push or export" ;;
esac

# Party-scoped tag names
PARTY_SYNC_TAG="replica/${PARTY}/last-sync"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PARTY_INIT_TAG="replica/${PARTY}/init-${TIMESTAMP}"

# Build annotated tag message
TAG_MESSAGE="party: ${PARTY}
output: ${OUTPUT_MODE}
start_tag: ${START_TAG}
timestamp: ${TIMESTAMP}"
[[ -n "$MESSAGE" ]] && TAG_MESSAGE="${TAG_MESSAGE}
note: ${MESSAGE}"

# ── Pre-flight checks ─────────────────────────────────────────
cd "$INTERNAL_REPO"
git rev-parse --verify "$START_TAG" >/dev/null 2>&1 \
  || die "Tag '$START_TAG' not found in internal repo"

REPLICA_DIR=$(mktemp -d /tmp/replica-init-XXXXXX)
trap 'rm -rf "$REPLICA_DIR"' EXIT

log "Party       : $PARTY"
log "Output mode : $OUTPUT_MODE"
log "Start tag   : $START_TAG"
log "Work dir    : $REPLICA_DIR"
[[ "$OUTPUT_MODE" == "push" ]] && log "Replica     : $REPLICA_GH_REPO"

# ── Step 1: Extract file tree at the given tag ────────────────
log "Extracting snapshot via git archive..."
git archive "$START_TAG" | tar -x -C "$REPLICA_DIR"

# ── Step 2: Initialize a history-free repository ─────────────
log "Initializing history-free repository..."
cd "$REPLICA_DIR"
git init
git branch -m main
git add -A

GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git commit -m "initial: $START_TAG"

ok "Initial commit: $(git rev-parse --short HEAD)"

# ── Step 3: Deliver ───────────────────────────────────────────
if [[ "$OUTPUT_MODE" == "push" ]]; then
  log "Pushing to github.com..."
  git remote add origin "git@github.com:${REPLICA_GH_REPO}.git"
  git push -u origin main
  ok "Push complete: github.com/${REPLICA_GH_REPO}"

else  # export
  EXPORT_DIR="${SCRIPT_DIR}/../init-exports"
  mkdir -p "$EXPORT_DIR"
  EXPORT_TAR="${EXPORT_DIR}/${PARTY}-${TIMESTAMP}.tar.gz"
  EXPORT_INSTRUCTIONS="${EXPORT_DIR}/${PARTY}-${TIMESTAMP}-setup.txt"

  log "Generating tar archive..."
  # Exclude .git — deliver file tree only
  tar -czf "$EXPORT_TAR" -C "$REPLICA_DIR" --exclude='.git' .

  cat > "$EXPORT_INSTRUCTIONS" << EOF
# Replica Initial Setup Instructions
# Generated : ${TIMESTAMP}
# Provider  : ${SYNC_AUTHOR_NAME} <${SYNC_AUTHOR_EMAIL}>
# Start tag : ${START_TAG}

## Steps

1. Create an empty repository on GitHub (no README).

2. Extract the archive and initialize a git repository:

   mkdir replica
   tar -xzf ${PARTY}-${TIMESTAMP}.tar.gz -C replica
   cd replica
   git init
   git branch -m main
   git add -A
   git commit -m "initial: ${START_TAG}"

3. Push to the repository you created:

   git remote add origin git@github.com:<your-org>/replica.git
   git push -u origin main

4. Future syncs will be delivered to this repository as PRs or patch files.
   Please share the repository URL with the provider.
EOF

  ok "Export files generated:"
  echo "  tar          : $EXPORT_TAR"
  echo "  instructions : $EXPORT_INSTRUCTIONS"
  echo ""
  echo "Send the following files to the 3rd party:"
  echo "  $EXPORT_TAR"
  echo "  $EXPORT_INSTRUCTIONS"
fi

# ── Step 4: Set tags in the internal repo ────────────────────
log "Setting sync tags..."
cd "$INTERNAL_REPO"

# Immutable record of the initial cut
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git tag -a "$PARTY_INIT_TAG" "$START_TAG" -m "$TAG_MESSAGE"

# Movable pointer — updated on every subsequent sync
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git tag -a "$PARTY_SYNC_TAG" "$START_TAG" -m "$TAG_MESSAGE"

# ── Step 5: Create publish branch ────────────────────────────
PUBLISH_BRANCH="${PUBLISH_BRANCH_PREFIX}/${PARTY}"
log "Creating publish branch: $PUBLISH_BRANCH"
git branch "$PUBLISH_BRANCH" "$START_TAG"

ok "Init tag     : $PARTY_INIT_TAG"
ok "Sync tag     : $PARTY_SYNC_TAG -> $START_TAG"
ok "Publish branch: $PUBLISH_BRANCH -> $START_TAG"
ok "Initial setup complete"
echo ""
if [[ "$OUTPUT_MODE" == "push" ]]; then
  echo "Next steps:"
  echo "  1. Configure Branch Protection on the replica main (allow Bot push only)"
  echo "  2. Invite the 3rd party to the repository"
else
  echo "Next steps:"
  echo "  1. Receive the repository URL after the 3rd party sets it up"
  echo "  2. Set REPLICA_GH_REPO in config/sync.conf to that URL"
fi
echo "  Milestone sync (2-phase):"
echo "    Phase 1 (stage for internal review):"
echo "      ./scripts/stage-publish.sh --party ${PARTY} \"sync: <milestone>\""
echo "    Phase 2 (deliver to external replica):"
echo "      ./scripts/deliver-to-replica.sh --party ${PARTY} \"sync: <milestone>\""
