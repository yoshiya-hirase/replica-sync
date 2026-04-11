#!/usr/bin/env bash
# 06-show-tags.sh
#
# Displays all replica-related tags in the internal repo with full metadata.
#
# Usage:
#   ./test/06-show-tags.sh
#   ./test/06-show-tags.sh --party acme   # filter by party
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

PARTY_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --party) PARTY_FILTER="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

cd "$INTERNAL_REPO"

# ── Publish init tags (party-independent) ────────────────────
echo ""
echo "══════════════════════════════════════════════"
echo "  publish/ tags  (publish branch init records)"
echo "══════════════════════════════════════════════"
git tag -l "publish/init-*" | sort | while read -r tag; do
  echo ""
  echo "  Tag: ${tag}"
  git tag -v "$tag" 2>/dev/null | grep -E "^(object|tag|tagger|    )" \
    | sed 's/^/  /' || git show "$tag" --no-patch --format="  %H" 2>/dev/null
  echo "  Points to: $(git rev-parse --short "${tag}^{}")"
done

# ── Per-party tags ────────────────────────────────────────────
if [[ -n "$PARTY_FILTER" ]]; then
  PARTIES=("$PARTY_FILTER")
else
  # Collect all known parties from tag names
  mapfile -t PARTIES < <(git tag -l "replica/*/last-sync" \
    | sed 's|replica/||;s|/last-sync||' | sort -u)
fi

for party in "${PARTIES[@]:-}"; do
  [[ -z "$party" ]] && continue
  echo ""
  echo "══════════════════════════════════════════════"
  echo "  Party: ${party}"
  echo "══════════════════════════════════════════════"

  # init tag
  INIT_TAG=$(git tag -l "replica/${party}/init-*" | sort | tail -1)
  if [[ -n "$INIT_TAG" ]]; then
    echo ""
    echo "  [init] ${INIT_TAG}"
    git for-each-ref --format="  %(taggerdate:short)  %(contents)" \
      "refs/tags/${INIT_TAG}" | head -8
    echo "  Points to: $(git rev-parse --short "${INIT_TAG}^{}")"
  else
    echo "  [init] (none)"
  fi

  # last-sync tag
  LAST_SYNC_TAG="replica/${party}/last-sync"
  if git rev-parse --verify "$LAST_SYNC_TAG" >/dev/null 2>&1; then
    echo ""
    echo "  [last-sync] ${LAST_SYNC_TAG}"
    git for-each-ref --format="  %(taggerdate:short)  %(contents)" \
      "refs/tags/${LAST_SYNC_TAG}" | head -8
    echo "  Points to: $(git rev-parse --short "${LAST_SYNC_TAG}^{}")"
  else
    echo "  [last-sync] (none — not yet delivered)"
  fi

  # sync history tags
  SYNC_TAGS=$(git tag -l "replica/${party}/sync-*" | sort)
  if [[ -n "$SYNC_TAGS" ]]; then
    echo ""
    echo "  [sync history]"
    echo "$SYNC_TAGS" | while read -r tag; do
      TS=$(git for-each-ref --format="%(taggerdate:short)" "refs/tags/${tag}")
      SHA=$(git rev-parse --short "${tag}^{}")
      echo "    ${tag}  (${TS})  -> ${SHA}"
    done
  else
    echo "  [sync history] (none)"
  fi
done

# ── Milestone tags ────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════"
echo "  milestone/ tags"
echo "══════════════════════════════════════════════"
git tag -l "milestone/*" | sort | while read -r tag; do
  SHA=$(git rev-parse --short "${tag}^{}")
  DATE=$(git for-each-ref --format="%(taggerdate:short)" "refs/tags/${tag}" 2>/dev/null || git log -1 --format="%ad" --date=short "$tag")
  echo "  ${tag}  (${DATE})  -> ${SHA}"
done

echo ""
