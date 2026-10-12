#!/usr/bin/env bash
# apply-external-pr.sh
#
# Applies a patch from an external PR (on the github.com replica) to the
# internal repo and automatically opens an internal PR on GHE.
#
# Usage:
#   ./scripts/apply-external-pr.sh --party acme --patch pr.patch --meta pr-meta.json
#
#   # Branch from and target a specific internal branch
#   ./scripts/apply-external-pr.sh --party acme --base dev --patch pr.patch --meta pr-meta.json
#
# --party is required and must match config/party/<party>.conf.
# Base branch: --base, else INTERNAL_BRANCH from sync.conf, else main.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

[[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE"; exit 1; }
# shellcheck source=../config/sync.conf.example
source "$CONFIG_FILE"

log() { echo -e "\033[1;34m[apply]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────
PATCH_FILE=""
META_FILE=""
PARTY=""
BASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch)  PATCH_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
    --meta)   META_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")";  shift 2 ;;
    --party)  PARTY="$2"; shift 2 ;;
    --base)   BASE="$2";  shift 2 ;;
    *) die "Unknown option: $1\nUsage: $0 --party <name> [--base <branch>] --patch <file> --meta <file>" ;;
  esac
done

[[ -f "$PATCH_FILE" ]] || die "Patch file not found: $PATCH_FILE"
[[ -f "$META_FILE"  ]] || die "Meta file not found: $META_FILE"

# --party is required: it is the only thing that tells parties apart in the
# working branch name, so a shared default would let two parties' PRs with the
# same number reset and overwrite each other's branch.
[[ -n "$PARTY" ]] || die "Specify the party with --party <name>"
PARTY_CONFIG="${SCRIPT_DIR}/../config/party/${PARTY}.conf"
[[ -f "$PARTY_CONFIG" ]] \
  || die "Party config not found: $PARTY_CONFIG\n  Use the same name as config/party/<party>.conf"
PARTY_SLUG="$PARTY"

if [[ -n "$BASE" ]]; then
  BASE_SOURCE="--base"
elif [[ -n "${INTERNAL_BRANCH:-}" ]]; then
  BASE="$INTERNAL_BRANCH"; BASE_SOURCE="INTERNAL_BRANCH"
else
  BASE="main"; BASE_SOURCE="default"
fi

# ── Load metadata ─────────────────────────────────────────────
PR_NUMBER=$(jq -r '.pr_number' "$META_FILE")
PR_TITLE=$(jq  -r '.pr_title'  "$META_FILE")
PR_BODY=$(jq   -r '.pr_body'   "$META_FILE")
PR_AUTHOR=$(jq -r '.pr_author' "$META_FILE")
PR_URL=$(jq    -r '.pr_url'    "$META_FILE")

BRANCH="external/${PARTY_SLUG}-pr-${PR_NUMBER}"

log "PR       : #${PR_NUMBER} ${PR_TITLE}"
log "Author   : ${PR_AUTHOR}"
log "Party    : ${PARTY_SLUG}"
log "Branch   : ${BRANCH}"
log "Base     : ${BASE} (from ${BASE_SOURCE})"

# ── Step 1: Update internal repo ─────────────────────────────
cd "$INTERNAL_REPO"

git fetch "$INTERNAL_REMOTE"
git rev-parse --verify "refs/remotes/${INTERNAL_REMOTE}/${BASE}" >/dev/null 2>&1 \
  || die "Base branch '${BASE}' not found on ${INTERNAL_REMOTE} (from ${BASE_SOURCE})"
git checkout "$BASE"
git merge --ff-only "${INTERNAL_REMOTE}/${BASE}"

# ── Step 2: Create or reset working branch ────────────────────
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  # Branch already exists — the external PR was updated and re-sent
  log "Resetting existing branch: $BRANCH"
  git checkout "$BRANCH"
  git reset --hard "${INTERNAL_REMOTE}/${BASE}"
else
  git checkout -b "$BRANCH"
fi

# ── Step 3: Apply the patch ───────────────────────────────────
log "Applying patch..."

if ! git apply --3way --whitespace=nowarn "$PATCH_FILE"; then
  die "Patch apply failed.\n" \
      "Resolve conflicts manually, then run:\n" \
      "  git add -A && git commit ..."
fi

# ── Step 4: Commit ────────────────────────────────────────────
git add -A

if git diff --cached --quiet; then
  die "No diff after apply. The patch may already be incorporated."
fi

GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git commit \
  -m "external(${PARTY_SLUG}): ${PR_TITLE}" \
  -m "Forwarded from: ${PR_URL}
Original author: ${PR_AUTHOR}

${PR_BODY}"

ok "Commit: $(git rev-parse --short HEAD)"

# ── Step 5: Push to GHE ──────────────────────────────────────
log "Pushing to GHE..."
git push "$INTERNAL_REMOTE" "$BRANCH" --force-with-lease

# ── Step 6: Open internal PR (skip if already exists) ────────
log "Checking for existing internal PR..."

EXISTING=$(GH_HOST="$GH_HOST" gh pr list \
  --repo "${GH_ORG}/${GH_REPO}" \
  --head "$BRANCH" \
  --json number,baseRefName \
  --jq '.[0] | select(.) | "\(.number) \(.baseRefName)"')
read -r PR_EXISTS PR_EXISTING_BASE <<< "${EXISTING:-}"

if [[ -n "${PR_EXISTS:-}" ]]; then
  ok "Existing internal PR #${PR_EXISTS} updated (push complete)"
  if [[ "$PR_EXISTING_BASE" != "$BASE" ]]; then
    log "Warning: PR #${PR_EXISTS} targets '${PR_EXISTING_BASE}', but the branch was rebuilt on '${BASE}'."
    log "  Change the PR base on GHE (or close it) so its diff matches."
  fi
else
  # Ensure the label exists
  GH_HOST="$GH_HOST" gh label list --repo "${GH_ORG}/${GH_REPO}" --json name --jq '.[].name' \
    | grep -qx "external-contribution" \
    || GH_HOST="$GH_HOST" gh label create "external-contribution" \
         --repo "${GH_ORG}/${GH_REPO}" --color "e4e669" --description "forwarded from external replica"

  INTERNAL_PR_URL=$(GH_HOST="$GH_HOST" gh pr create \
    --repo "${GH_ORG}/${GH_REPO}" \
    --title "[External:${PARTY_SLUG}] ${PR_TITLE}" \
    --body "## Forwarded external PR

| Field          | Value |
|----------------|-------|
| Party          | ${PARTY_SLUG} |
| External PR    | ${PR_URL} |
| External author| ${PR_AUTHOR} |
| Base branch    | ${BASE} |

## Original PR description

${PR_BODY}

---
> This PR was auto-generated to review an external contribution internally.
> After approval and merge, close the external PR (do not merge it there)." \
    --base "$BASE" \
    --head "$BRANCH")

  GH_HOST="$GH_HOST" gh pr edit "$INTERNAL_PR_URL" \
    --add-label "external-contribution" \
    --repo "${GH_ORG}/${GH_REPO}" \
    || log "Warning: could not add label 'external-contribution' (non-fatal)"

  ok "Internal PR created: ${INTERNAL_PR_URL}"
fi
