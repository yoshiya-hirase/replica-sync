#!/usr/bin/env bash
# setup-sync-conf.sh
#
# Interactive wizard to create replica-sync/config/sync.conf.
# Auto-detects repository settings from git and prompts for the rest.
#
# Run from the root of the internal monorepo (after replica-sync is installed):
#
#   ./replica-sync/scripts/setup-sync-conf.sh
#
# What is auto-detected:
#   INTERNAL_REPO    — absolute path of the current directory
#   INTERNAL_REMOTE  — from `git remote` (prompted if multiple)
#   GH_HOST          — parsed from the remote URL
#   GH_ORG           — parsed from the remote URL
#   GH_REPO          — parsed from the remote URL
#
# What is prompted (with defaults):
#   SYNC_AUTHOR_NAME   (default: Platform Sync Bot)
#   SYNC_AUTHOR_EMAIL  (default: sync-bot@<GH_HOST>)
#   PATCH_OUTPUT_DIR   (default: ./sync-patches)
#
# EXCLUDE_PATHS is prompted as free-form input (blank = empty array).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
CONF_FILE="${CONFIG_DIR}/sync.conf"

# ── Color helpers ──────────────────────────────────────────────
bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
info()  { echo -e "\033[1;34m[ info]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[ warn]\033[0m $*" >&2; }
die()   { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }
header(){ echo ""; bold "── $* ──────────────────────────────────────"; }

# ── Prompt helper ─────────────────────────────────────────────
# prompt <variable_name> <label> <default>
# Reads user input; uses default if empty.
prompt() {
  local var="$1" label="$2" default="$3"
  local value=""
  if [[ -n "$default" ]]; then
    printf "  %s [%s]: " "$label" "$default"
  else
    printf "  %s: " "$label"
  fi
  read -r value
  value="${value:-$default}"
  printf -v "$var" '%s' "$value"
}

# ── Check we're inside a git repo ─────────────────────────────
git rev-parse --show-toplevel >/dev/null 2>&1 \
  || die "Not inside a git repository. Run this script from the internal monorepo root."

REPO_ROOT="$(git rev-parse --show-toplevel)"

# ── Check for existing sync.conf ──────────────────────────────
if [[ -f "$CONF_FILE" ]]; then
  warn "sync.conf already exists: $CONF_FILE"
  printf "  Overwrite? [y/N]: "
  read -r answer
  [[ "${answer,,}" == "y" ]] || { echo "Aborted."; exit 0; }
  echo ""
fi

echo ""
bold "replica-sync config setup wizard"
echo "Detected repository: $REPO_ROOT"
echo ""

# ══════════════════════════════════════════════════════════════
# Step 1: Auto-detect git values
# ══════════════════════════════════════════════════════════════
header "Step 1: Auto-detecting repository settings"

# INTERNAL_REPO
INTERNAL_REPO="$REPO_ROOT"
info "INTERNAL_REPO = $INTERNAL_REPO"

# INTERNAL_REMOTE — pick from available remotes
mapfile -t REMOTES < <(git -C "$REPO_ROOT" remote)
if [[ ${#REMOTES[@]} -eq 0 ]]; then
  warn "No git remotes found. You will need to set INTERNAL_REMOTE manually."
  INTERNAL_REMOTE="origin"
elif [[ ${#REMOTES[@]} -eq 1 ]]; then
  INTERNAL_REMOTE="${REMOTES[0]}"
  info "INTERNAL_REMOTE = $INTERNAL_REMOTE"
else
  echo ""
  echo "  Multiple remotes found:"
  for i in "${!REMOTES[@]}"; do
    printf "    [%d] %s\n" "$((i+1))" "${REMOTES[$i]}"
  done
  printf "  Select remote [1]: "
  read -r sel
  sel="${sel:-1}"
  INTERNAL_REMOTE="${REMOTES[$((sel-1))]}"
  info "INTERNAL_REMOTE = $INTERNAL_REMOTE"
fi

# Parse GH_HOST, GH_ORG, GH_REPO from remote URL
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url "$INTERNAL_REMOTE" 2>/dev/null || true)"

GH_HOST=""
GH_ORG=""
GH_REPO=""

if [[ -n "$REMOTE_URL" ]]; then
  # SSH: git@hostname:org/repo.git
  if [[ "$REMOTE_URL" =~ ^git@([^:]+):([^/]+)/(.+)\.git$ ]]; then
    GH_HOST="${BASH_REMATCH[1]}"
    GH_ORG="${BASH_REMATCH[2]}"
    GH_REPO="${BASH_REMATCH[3]}"
  # SSH without .git: git@hostname:org/repo
  elif [[ "$REMOTE_URL" =~ ^git@([^:]+):([^/]+)/(.+)$ ]]; then
    GH_HOST="${BASH_REMATCH[1]}"
    GH_ORG="${BASH_REMATCH[2]}"
    GH_REPO="${BASH_REMATCH[3]}"
  # HTTPS: https://hostname/org/repo.git
  elif [[ "$REMOTE_URL" =~ ^https?://([^/]+)/([^/]+)/(.+)\.git$ ]]; then
    GH_HOST="${BASH_REMATCH[1]}"
    GH_ORG="${BASH_REMATCH[2]}"
    GH_REPO="${BASH_REMATCH[3]}"
  # HTTPS without .git: https://hostname/org/repo
  elif [[ "$REMOTE_URL" =~ ^https?://([^/]+)/([^/]+)/(.+)$ ]]; then
    GH_HOST="${BASH_REMATCH[1]}"
    GH_ORG="${BASH_REMATCH[2]}"
    GH_REPO="${BASH_REMATCH[3]}"
  else
    warn "Could not parse remote URL: $REMOTE_URL"
    warn "GH_HOST, GH_ORG, GH_REPO will use placeholder defaults."
  fi
fi

GH_HOST="${GH_HOST:-"github.your-company.com"}"
GH_ORG="${GH_ORG:-"your-org"}"
GH_REPO="${GH_REPO:-"internal-monorepo"}"

info "GH_HOST          = $GH_HOST"
info "GH_ORG           = $GH_ORG"
info "GH_REPO          = $GH_REPO"

# ══════════════════════════════════════════════════════════════
# Step 2: Confirm or override auto-detected values
# ══════════════════════════════════════════════════════════════
header "Step 2: Confirm repository settings (press Enter to accept)"

prompt INTERNAL_REPO   "INTERNAL_REPO"   "$INTERNAL_REPO"
prompt INTERNAL_REMOTE "INTERNAL_REMOTE" "$INTERNAL_REMOTE"
prompt GH_HOST         "GH_HOST"         "$GH_HOST"
prompt GH_ORG          "GH_ORG"          "$GH_ORG"
prompt GH_REPO         "GH_REPO"         "$GH_REPO"

# ══════════════════════════════════════════════════════════════
# Step 3: Sync author identity
# ══════════════════════════════════════════════════════════════
header "Step 3: Sync commit author (replaces internal developer info externally)"

DEFAULT_AUTHOR_EMAIL="sync-bot@${GH_HOST}"
prompt SYNC_AUTHOR_NAME  "SYNC_AUTHOR_NAME"  "Platform Sync Bot"
prompt SYNC_AUTHOR_EMAIL "SYNC_AUTHOR_EMAIL" "$DEFAULT_AUTHOR_EMAIL"

# ══════════════════════════════════════════════════════════════
# Step 4: EXCLUDE_PATHS
# ══════════════════════════════════════════════════════════════
header "Step 4: Excluded paths (paths to omit from the external replica)"

echo ""
echo "  Enter paths to exclude from the external replica, one per line."
echo "  These are git pathspec patterns (NOT .gitignore patterns):"
echo "    services/internal-only/   — exclude a directory"
echo "    **/*.secret               — glob pattern"
echo "  Leave blank and press Enter when done (you can edit sync.conf later)."
echo ""

EXCLUDE_PATHS=()
while true; do
  printf "  Path (or Enter to finish): "
  read -r entry
  [[ -n "$entry" ]] || break
  EXCLUDE_PATHS+=("$entry")
done

# ══════════════════════════════════════════════════════════════
# Step 5: Patch output dir
# ══════════════════════════════════════════════════════════════
header "Step 5: Patch mode output directory"

prompt PATCH_OUTPUT_DIR "PATCH_OUTPUT_DIR" "./sync-patches"

# ══════════════════════════════════════════════════════════════
# Step 6: Write sync.conf
# ══════════════════════════════════════════════════════════════
header "Step 6: Writing sync.conf"

# Build EXCLUDE_PATHS bash array literal
if [[ ${#EXCLUDE_PATHS[@]} -eq 0 ]]; then
  EXCLUDE_PATHS_CONTENT="  # No paths excluded. Add entries here if needed, e.g.:\n  #   \"services/internal-only/\"\n  #   \".internal/\""
  EXCLUDE_PATHS_BLOCK="(\n${EXCLUDE_PATHS_CONTENT}\n)"
else
  EXCLUDE_PATHS_BLOCK="("
  for p in "${EXCLUDE_PATHS[@]}"; do
    EXCLUDE_PATHS_BLOCK+=$'\n'"  \"${p}\""
  done
  EXCLUDE_PATHS_BLOCK+=$'\n'")"
fi

mkdir -p "$CONFIG_DIR"

cat > "$CONF_FILE" << CONFEOF
# replica-sync configuration file
# Generated by setup-sync-conf.sh — edit as needed.
# sync.conf is listed in .gitignore (may contain sensitive paths — do not commit).

# ── Internal repository (GHE) ────────────────────────────────

# Local path to the internal monorepo (absolute path)
INTERNAL_REPO="${INTERNAL_REPO}"

# Remote name on GHE
INTERNAL_REMOTE="${INTERNAL_REMOTE}"

# GHE hostname (used as GH_HOST for the gh CLI)
GH_HOST="${GH_HOST}"

# GHE Organization / Repo
GH_ORG="${GH_ORG}"
GH_REPO="${GH_REPO}"

# ── Sync settings ─────────────────────────────────────────────

# Squash commit author identity (replaces internal developer info externally)
SYNC_AUTHOR_NAME="${SYNC_AUTHOR_NAME}"
SYNC_AUTHOR_EMAIL="${SYNC_AUTHOR_EMAIL}"

# Paths excluded from replica sync (internal-only services, etc.)
#
# These are git pathspec patterns — NOT .gitignore patterns.
# They are passed to \`git archive\` and \`git diff\` as \`:!<pattern>\`.
#
# Pattern rules:
#   services/internal-only/   — exclude a directory and everything under it
#   .internal/                — exclude a top-level directory
#   "**/*.secret"             — glob: exclude all *.secret files anywhere in the tree
#
# Unlike .gitignore, these patterns are repository-root-anchored and
# do not support negation (! prefix) or comment lines (# prefix).
EXCLUDE_PATHS=$(echo -e "$EXCLUDE_PATHS_BLOCK")

# ── Patch mode settings ───────────────────────────────────────

# Output directory for patch sets generated in patch mode
PATCH_OUTPUT_DIR="${PATCH_OUTPUT_DIR}"

# ── Per-party replica settings ────────────────────────────────
# Replica-specific settings (REPLICA_REPO, REPLICA_REMOTE, REPLICA_BRANCH,
# REPLICA_GH_REPO) are defined per party in config/party/<party>.conf.
# Copy config/party/party.conf.example to config/party/<party>.conf and edit it.
CONFEOF

ok "Written: $CONF_FILE"

echo ""
echo "Next steps:"
echo "  1. Review the generated file:"
echo "     \$EDITOR ${CONF_FILE}"
echo "  2. Create per-party config for each 3rd party:"
echo "     cp ${CONFIG_DIR}/party/party.conf.example ${CONFIG_DIR}/party/<party>.conf"
echo "  3. Verify gh CLI authentication:"
echo "     GH_HOST=${GH_HOST} gh auth status"
