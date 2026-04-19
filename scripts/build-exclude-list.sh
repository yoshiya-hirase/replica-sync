#!/usr/bin/env bash
# build-exclude-list.sh
#
# Scans the repository and generates an EXCLUDE_PATHS list for sync.conf.
# Resolves "exclude a pattern but keep specific files" without relying on
# git pathspec re-inclusion (which is not supported).
#
# How it works:
#   1. Run `git ls-files` to enumerate all tracked files in the repo
#   2. Apply --exclude glob patterns to build the candidate exclusion list
#   3. Remove any files matched by --include from that list
#   4. Output the result as an EXCLUDE_PATHS=(...) block
#
# Usage:
#   ./replica-sync/scripts/build-exclude-list.sh \
#     --exclude ".github/workflows/**" \
#     --include ".github/workflows/sync-to-wiki-main.yml"
#
#   # Multiple patterns
#   ./replica-sync/scripts/build-exclude-list.sh \
#     --exclude ".github/workflows/**" \
#     --exclude "services/internal-*/" \
#     --include ".github/workflows/sync-to-wiki-main.yml"
#
#   # Apply directly to sync.conf (replaces EXCLUDE_PATHS block)
#   ./replica-sync/scripts/build-exclude-list.sh \
#     --exclude ".github/workflows/**" \
#     --include ".github/workflows/sync-to-wiki-main.yml" \
#     --apply
#
#   # Preview without modifying sync.conf
#   ./replica-sync/scripts/build-exclude-list.sh \
#     --exclude ".github/workflows/**" \
#     --include ".github/workflows/sync-to-wiki-main.yml" \
#     --dry-run
#
# Run from the internal monorepo root.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

ok()   { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }
log()  { echo -e "\033[1;34m[excl ]\033[0m $*"; }
warn() { echo -e "\033[1;33m[ warn]\033[0m $*" >&2; }

usage() {
  cat << 'USAGE'
Usage: ./replica-sync/scripts/build-exclude-list.sh [options]

Generates an EXCLUDE_PATHS list by scanning tracked files in the repository.

Options:
  --exclude <pattern>   Glob pattern to exclude (repeatable)
  --include <pattern>   Glob pattern to re-include (exempt from exclusion) (repeatable)
  --apply               Write the result directly into sync.conf
  --dry-run             Print what would change without modifying sync.conf
  -h, --help            Show this help message

Patterns use fnmatch-style globs (same as shell glob):
  .github/workflows/**          all files under .github/workflows/
  services/internal-*/          directories matching the prefix
  **/*.secret                   all *.secret files anywhere in the tree

Run from the internal monorepo root.

Examples:
  # Exclude all workflow files except one
  ./replica-sync/scripts/build-exclude-list.sh \
    --exclude ".github/workflows/**" \
    --include ".github/workflows/sync-to-wiki-main.yml"

  # Exclude multiple patterns, apply to sync.conf
  ./replica-sync/scripts/build-exclude-list.sh \
    --exclude ".github/workflows/**" \
    --exclude "services/internal-*/**" \
    --include ".github/workflows/sync-to-wiki-main.yml" \
    --apply
USAGE
}

# ── Argument parsing ───────────────────────────────────────────
EXCLUDE_PATTERNS=()
INCLUDE_PATTERNS=()
APPLY="false"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude)   EXCLUDE_PATTERNS+=("$2"); shift 2 ;;
    --include)   INCLUDE_PATTERNS+=("$2"); shift 2 ;;
    --apply)     APPLY="true";             shift ;;
    --dry-run)   DRY_RUN="true";           shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "Unknown option: $1\nRun with --help to see usage." ;;
  esac
done

[[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]] \
  || die "Specify at least one --exclude pattern.\nRun with --help to see usage."

if [[ "$APPLY" == "true" || "$DRY_RUN" == "true" ]]; then
  [[ -f "$CONFIG_FILE" ]] \
    || die "sync.conf not found: $CONFIG_FILE\n  Run setup-sync-conf.sh first, or omit --apply/--dry-run to just print the list."
fi

# ── Must be run from a git repo ────────────────────────────────
git rev-parse --show-toplevel >/dev/null 2>&1 \
  || die "Not inside a git repository. Run this script from the internal monorepo root."

REPO_ROOT="$(git rev-parse --show-toplevel)"

# ── Helper: match a file path against a glob pattern ──────────
# Uses bash's case statement for fnmatch-style glob matching.
# Handles ** by treating it as a multi-segment wildcard.
matches_pattern() {
  local file="$1" pattern="$2"
  # Normalize: strip trailing slash from pattern (for directory patterns)
  pattern="${pattern%/}"
  case "$file" in
    $pattern)   return 0 ;;   # exact or glob match
    $pattern/*) return 0 ;;   # file is under a matched directory
    *)          return 1 ;;
  esac
}

# ── Step 1: Get all tracked files ─────────────────────────────
log "Scanning tracked files in: $REPO_ROOT"
ALL_FILES=()
while IFS= read -r f; do
  ALL_FILES+=("$f")
done < <(git -C "$REPO_ROOT" ls-files)

log "Total tracked files: ${#ALL_FILES[@]}"

# ── Step 2: Apply exclude patterns ────────────────────────────
CANDIDATES=()
for f in ${ALL_FILES[@]+"${ALL_FILES[@]}"}; do
  for pattern in ${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}; do
    if matches_pattern "$f" "$pattern"; then
      CANDIDATES+=("$f")
      break
    fi
  done
done

log "Files matching exclude patterns: ${#CANDIDATES[@]}"

# ── Step 3: Remove include exemptions ─────────────────────────
RESULT=()
for f in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
  exempt="false"
  for pattern in ${INCLUDE_PATTERNS[@]+"${INCLUDE_PATTERNS[@]}"}; do
    if matches_pattern "$f" "$pattern"; then
      exempt="true"
      break
    fi
  done
  [[ "$exempt" == "false" ]] && RESULT+=("$f")
done

EXEMPTED=$(( ${#CANDIDATES[@]} - ${#RESULT[@]} ))
log "Exempted by --include: ${EXEMPTED}"
log "Final EXCLUDE_PATHS entries: ${#RESULT[@]}"

if [[ ${#RESULT[@]} -eq 0 ]]; then
  warn "No files matched the exclude patterns (after exemptions). EXCLUDE_PATHS will be empty."
fi

# ── Step 4: Build output block ────────────────────────────────
# Header comment recording the patterns used to generate this list
HEADER="# Generated by build-exclude-list.sh"
for p in ${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}; do
  HEADER="${HEADER}
# exclude: ${p}"
done
for p in ${INCLUDE_PATTERNS[@]+"${INCLUDE_PATTERNS[@]}"}; do
  HEADER="${HEADER}
# include: ${p}"
done

# Build the array body
ARRAY_BODY=""
for f in ${RESULT[@]+"${RESULT[@]}"}; do
  ARRAY_BODY="${ARRAY_BODY}
  \"${f}\""
done

NEW_BLOCK="${HEADER}
EXCLUDE_PATHS=(${ARRAY_BODY}
)"

# ── Step 5: Output or apply ────────────────────────────────────
if [[ "$APPLY" == "false" && "$DRY_RUN" == "false" ]]; then
  # Print only — user pastes into sync.conf manually
  echo ""
  echo "─── EXCLUDE_PATHS block (paste into sync.conf) ───────────────"
  echo "$NEW_BLOCK"
  echo "───────────────────────────────────────────────────────────────"
  echo ""
  ok "${#RESULT[@]} entries generated"
  exit 0
fi

# For --apply and --dry-run: replace the EXCLUDE_PATHS block in sync.conf
# The block is everything from the first line matching EXCLUDE_PATHS=( to
# the closing ) on its own line.

CONF_CONTENT="$(cat "$CONFIG_FILE")"

# Check if EXCLUDE_PATHS block exists in sync.conf
if ! echo "$CONF_CONTENT" | grep -q "^EXCLUDE_PATHS=("; then
  die "EXCLUDE_PATHS block not found in sync.conf.\n  Cannot apply automatically. Paste the output manually."
fi

# Build new sync.conf by replacing the EXCLUDE_PATHS block.
# NEW_BLOCK contains newlines so it cannot be passed via awk -v.
# Write it to a temp file and read it inside awk with getline instead.
BLOCK_FILE=$(mktemp /tmp/exclude-block-XXXXXX)
printf '%s\n' "$NEW_BLOCK" > "$BLOCK_FILE"
trap 'rm -f "$BLOCK_FILE"' EXIT

NEW_CONF=$(awk -v block_file="$BLOCK_FILE" '
  /^# .*build-exclude-list/ { next }
  /^# exclude:/ { next }
  /^# include:/ { next }
  /^EXCLUDE_PATHS=\(/ {
    in_block=1
    while ((getline line < block_file) > 0) { print line }
    close(block_file)
    next
  }
  in_block {
    if (/^\)/) { in_block=0 }
    next
  }
  { print }
' "$CONFIG_FILE")

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "─── Preview: sync.conf after apply ───────────────────────────"
  echo "$NEW_CONF"
  echo "───────────────────────────────────────────────────────────────"
  echo ""
  ok "Dry run complete — sync.conf was not modified"
else
  echo "$NEW_CONF" > "$CONFIG_FILE"
  ok "Updated EXCLUDE_PATHS in: $CONFIG_FILE"
  echo ""
  echo "Review the change:"
  echo "  \$EDITOR ${CONFIG_FILE}"
fi
