#!/usr/bin/env bash
# 04-create-party-repo.sh
#
# Creates a 3rd party replica repository on GitHub, clones it locally,
# installs the pr-to-internal.yml workflow, and generates config/party/<party>.conf.
#
# Usage:
#   ./test/04-create-party-repo.sh --party acme --repo test-replica-acme
#   ./test/04-create-party-repo.sh --party beta --repo test-replica-beta
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_CONF="${SCRIPT_DIR}/test.conf"

[[ -f "$TEST_CONF" ]] || { echo "test.conf not found."; exit 1; }
source "$TEST_CONF"

log() { echo -e "\033[1;34m[party]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────
PARTY=""
REPO_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --party) PARTY="$2";     shift 2 ;;
    --repo)  REPO_NAME="$2"; shift 2 ;;
    *) die "Unknown option: $1\nUsage: $0 --party <name> --repo <repo-name>" ;;
  esac
done

[[ -n "$PARTY"     ]] || die "Specify --party <name>"
[[ -n "$REPO_NAME" ]] || die "Specify --repo <repo-name>"

PARTY_LOCAL="${TEST_DIR}/${PARTY}"
PARTY_CONF="${REPO_ROOT}/config/party/${PARTY}.conf"
WORKFLOW_SRC="${REPO_ROOT}/.github/workflows/pr-to-internal.yml"

[[ -f "$WORKFLOW_SRC" ]] || die "pr-to-internal.yml not found at ${WORKFLOW_SRC}"

# ── Create GitHub repo ────────────────────────────────────────
log "Creating GitHub repo: ${GITHUB_USER}/${REPO_NAME}..."
if gh repo view "${GITHUB_USER}/${REPO_NAME}" >/dev/null 2>&1; then
  log "Repo already exists, skipping creation"
else
  gh repo create "${GITHUB_USER}/${REPO_NAME}" \
    --private \
    --description "replica-sync test: ${PARTY} replica"
  ok "Created: https://github.com/${GITHUB_USER}/${REPO_NAME}"
fi

# ── Initialize repo with empty main branch ────────────────────
# deliver-to-replica.sh expects a repo with a main branch to merge into.
# We initialize it with a minimal commit so git operations work.
INIT_DIR=$(mktemp -d /tmp/party-init-XXXXXX)
trap 'rm -rf "$INIT_DIR"' EXIT

cd "$INIT_DIR"
git init
git branch -m main

cat > README.md << EOF
# ${PARTY} Replica

Replica repository for ${PARTY}.
This repository is managed by the internal sync bot.
EOF

git add -A
git commit -m "initial: empty replica base"
git remote add origin "git@github.com:${GITHUB_USER}/${REPO_NAME}.git"

# Push only if remote main is empty
if gh api "repos/${GITHUB_USER}/${REPO_NAME}/git/refs/heads/main" >/dev/null 2>&1; then
  log "Remote main already exists, skipping initial push"
else
  git push -u origin main
  ok "Pushed initial commit to main"
fi

# ── Install pr-to-internal.yml workflow ───────────────────────
log "Installing pr-to-internal.yml workflow..."

# Clone or update the party repo locally for workflow installation
if [[ -d "$PARTY_LOCAL" ]]; then
  cd "$PARTY_LOCAL"
  git fetch origin
  git merge --ff-only origin/main
else
  git clone "git@github.com:${GITHUB_USER}/${REPO_NAME}.git" "$PARTY_LOCAL"
  cd "$PARTY_LOCAL"
fi

mkdir -p .github/workflows
cp "$WORKFLOW_SRC" .github/workflows/pr-to-internal.yml

if git diff --quiet && git diff --cached --quiet; then
  log "Workflow already installed, skipping commit"
else
  git add .github/workflows/pr-to-internal.yml
  git commit -m "ci: install pr-to-internal workflow"
  git push origin main
  ok "Workflow installed and pushed"
fi

# ── Generate party config ─────────────────────────────────────
log "Generating config/party/${PARTY}.conf..."

mkdir -p "${REPO_ROOT}/config/party"

if [[ -f "$PARTY_CONF" ]]; then
  echo "config/party/${PARTY}.conf already exists."
  read -r -p "Overwrite? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Skipped party conf generation."; }
fi

if [[ ! -f "$PARTY_CONF" ]] || [[ "${ans:-n}" =~ ^[Yy]$ ]]; then
  cat > "$PARTY_CONF" << EOF
# Party config for: ${PARTY}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

REPLICA_REPO="${PARTY_LOCAL}"
REPLICA_REMOTE="origin"
REPLICA_BRANCH="main"
REPLICA_GH_REPO="${GITHUB_USER}/${REPO_NAME}"
EOF
  ok "Generated: config/party/${PARTY}.conf"
fi

ok "Party '${PARTY}' setup complete"
ok "  Local path    : ${PARTY_LOCAL}"
ok "  GitHub        : https://github.com/${GITHUB_USER}/${REPO_NAME}"
ok "  Party conf    : config/party/${PARTY}.conf"
ok "  Workflow      : .github/workflows/pr-to-internal.yml"
echo ""
echo "Next: deliver to this party"
echo "  Patch mode (default): ./scripts/deliver-to-replica.sh --party ${PARTY} \"initial: v1\""
echo "  Push mode:            ./scripts/deliver-to-replica.sh --party ${PARTY} --output push \"initial: v1\""
