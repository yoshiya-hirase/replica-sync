#!/usr/bin/env bash
# generate-upstream-setup.sh
#
# Builds the replica-sync tooling package and either:
#   (default)        generates a zip that includes install.sh
#   --install-to     installs directly into a target monorepo (fresh install or upgrade)
#
# Both paths use the same install logic (via the generated install.sh).
# On upgrade, scripts and templates are overwritten; sync.conf and party/*.conf
# are preserved.
#
# Usage:
#   # Generate zip (includes install.sh)
#   ./scripts/generate-upstream-setup.sh [--with-ci-workflow] [--output-dir DIR]
#
#   # Install / upgrade directly
#   ./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo
#   ./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo \
#     --with-ci-workflow
#
# Installing from the zip:
#   unzip upstream-setup-TIMESTAMP.zip
#   cd upstream-setup-TIMESTAMP
#   bash install.sh --target /path/to/internal-monorepo
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }
log() { echo -e "\033[1;34m[ pkg ]\033[0m $*"; }

usage() {
  cat << 'USAGE'
Usage: ./scripts/generate-upstream-setup.sh [options]

Builds the replica-sync tooling package and either generates a zip or installs directly.

Options:
  --with-ci-workflow     Include sync-replica.yml (GHE-side CI workflow)
  --output-dir <dir>     Output directory for the generated zip (default: ./upstream-packages)
  --install-to <dir>     Install directly into an existing monorepo (skips zip generation)
  -h, --help             Show this help message

The --install-to directory must already exist (a pre-existing monorepo clone).

Examples:
  # Generate a zip package
  ./scripts/generate-upstream-setup.sh
  ./scripts/generate-upstream-setup.sh --with-ci-workflow --output-dir ./outbox

  # Install directly into an existing monorepo
  ./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo
  ./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo --with-ci-workflow
USAGE
}

# ── Argument parsing ───────────────────────────────────────────
WITH_CI_WORKFLOW="false"
OUTPUT_DIR="./upstream-packages"
INSTALL_TO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-ci-workflow) WITH_CI_WORKFLOW="true"; shift ;;
    --output-dir)       OUTPUT_DIR="$2";         shift 2 ;;
    --install-to)       INSTALL_TO="$2";         shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) die "Unknown option: $1\nRun with --help to see usage." ;;
  esac
done

if [[ -n "$INSTALL_TO" ]]; then
  [[ -d "$INSTALL_TO" ]] || die "Target directory not found: $INSTALL_TO\n  The --install-to directory must already exist (this script installs into an existing monorepo).\n  Create the directory first, or check for a typo in the path."
  INSTALL_TO="$(cd "$INSTALL_TO" && pwd)"
fi

# ── Build assets into a temp work dir ─────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PACKAGE_NAME="upstream-setup-${TIMESTAMP}"
WORK_DIR="${OUTPUT_DIR}/${PACKAGE_NAME}"
RS_DIR="${WORK_DIR}/replica-sync"

mkdir -p \
  "${RS_DIR}/scripts" \
  "${RS_DIR}/config/party" \
  "${RS_DIR}/config/replica-bootstrap/.github/workflows"

# scripts
SCRIPTS=(
  init-replica.sh
  stage-publish.sh
  deliver-to-replica.sh
  apply-external-pr.sh
  cherry-pick-partial.sh
  notify-external-pr.sh
  generate-party-onboarding.sh
  setup-sync-conf.sh
)
for s in "${SCRIPTS[@]}"; do
  src="${REPO_ROOT}/scripts/${s}"
  [[ -f "$src" ]] || die "Script not found: $src"
  cp "$src" "${RS_DIR}/scripts/${s}"
done
log "Built ${#SCRIPTS[@]} scripts"

# config templates
cp "${REPO_ROOT}/config/sync.conf.example" \
   "${RS_DIR}/config/sync.conf.example"
cp "${REPO_ROOT}/config/party/party.conf.example" \
   "${RS_DIR}/config/party/party.conf.example"
cp "${REPO_ROOT}/config/replica-bootstrap/.github/workflows/pr-to-internal.yml" \
   "${RS_DIR}/config/replica-bootstrap/.github/workflows/pr-to-internal.yml"
log "Built config templates"

# .gitignore-fragment
cat > "${RS_DIR}/.gitignore-fragment" << 'EOF'
# replica-sync: local config (contain paths and credentials — do not commit)
replica-sync/config/sync.conf
replica-sync/config/party/*.conf

# replica-sync: generated output directories
replica-sync/party-packages/
replica-sync/upstream-packages/
replica-sync/sync-patches/
replica-sync/test-patches/
replica-sync/test-artifacts/
EOF
log "Built .gitignore-fragment"

# CI workflow (optional)
if [[ "$WITH_CI_WORKFLOW" == "true" ]]; then
  mkdir -p "${WORK_DIR}/.github/workflows"
  cat > "${WORK_DIR}/.github/workflows/sync-replica.yml" << 'CIEOF'
name: Sync to Replica

# GHE-side GitHub Actions.
# Automatically runs stage-publish.sh when a milestone/* tag is pushed
# (e.g. milestone/2024-Q1), creating a GHE PR to update the publish branch.
#
# Register the following in Secrets:
#   GHE_TOKEN : GHE Personal Access Token (contents: read, pull-requests: write)
#
# Register the following in Variables (Settings → Secrets and variables → Actions → Variables):
#   GH_HOST   : GHE hostname            (e.g. github.your-company.com)
#   GH_ORG    : GHE organization name   (e.g. your-org)
#   GH_REPO   : GHE repository name     (e.g. internal-monorepo)

on:
  push:
    tags:
      - 'milestone/*'   # triggered by tags like milestone/2024-Q1

jobs:
  stage-publish:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout internal monorepo
        uses: actions/checkout@v4
        with:
          fetch-depth: 0   # full history and tags required
          token: ${{ secrets.GHE_TOKEN }}

      - name: Setup config
        run: |
          cp replica-sync/config/sync.conf.example replica-sync/config/sync.conf
          sed -i "s|/path/to/internal-monorepo|${GITHUB_WORKSPACE}|g" \
            replica-sync/config/sync.conf
          sed -i "s|github.your-company.com|${{ vars.GH_HOST }}|g" \
            replica-sync/config/sync.conf
          sed -i "s|^GH_ORG=.*|GH_ORG=\"${{ vars.GH_ORG }}\"|g" \
            replica-sync/config/sync.conf
          sed -i "s|^GH_REPO=.*|GH_REPO=\"${{ vars.GH_REPO }}\"|g" \
            replica-sync/config/sync.conf

      - name: Make scripts executable
        run: chmod +x replica-sync/scripts/*.sh

      - name: Run stage-publish
        env:
          GH_TOKEN: ${{ secrets.GHE_TOKEN }}
        run: |
          ./replica-sync/scripts/stage-publish.sh \
            "sync: ${{ github.ref_name }}"
CIEOF
  log "Built .github/workflows/sync-replica.yml"
fi

# SETUP.md
cat > "${RS_DIR}/SETUP.md" << SETUPEOF
# Upstream Sync Setup Guide

This package installs the replica-sync tooling into this monorepo.
After setup, you can synchronize a curated snapshot of this codebase to
an external replica on github.com and collaborate with 3rd parties.

---

## What This Installs

\`\`\`
replica-sync/
├── SETUP.md                                    ← this file
├── scripts/                                    ← sync scripts (run from monorepo root)
│   ├── setup-sync-conf.sh                      ← interactive wizard to create sync.conf
│   ├── init-replica.sh                         ← [A] initialize publish branch
│   ├── stage-publish.sh                        ← [B-1] squash and create GHE PR
│   ├── deliver-to-replica.sh                   ← [B-2] deliver to external replica
│   ├── apply-external-pr.sh                    ← [C] apply external PR internally
│   ├── cherry-pick-partial.sh                  ← [C] partial acceptance
│   ├── notify-external-pr.sh                   ← [C] notify external PR of decision
│   └── generate-party-onboarding.sh            ← generate 3rd party onboarding package
├── config/
│   ├── sync.conf.example                       ← shared config template
│   ├── party/
│   │   └── party.conf.example                  ← per-party config template
│   └── replica-bootstrap/
│       └── .github/workflows/
│           └── pr-to-internal.yml              ← CI workflow for the external replica
└── .gitignore-fragment                         ← patterns to add to .gitignore
\`\`\`
$(if [[ "$WITH_CI_WORKFLOW" == "true" ]]; then
cat << 'CIBLOCK'

Also included at repo root:
\`\`\`
.github/workflows/sync-replica.yml    ← GHE-side CI: milestone tag → stage-publish auto-run
\`\`\`
CIBLOCK
fi)

---

## Installation

\`\`\`bash
# From the extracted package directory:
bash install.sh --target /path/to/internal-monorepo
\`\`\`

The install script handles both fresh installs and upgrades:
- Scripts and templates are always overwritten
- \`sync.conf\` and \`config/party/*.conf\` are preserved on upgrade

---

## Upgrading

To upgrade replica-sync tooling to a newer version, generate a new package
and run its \`install.sh\` against the same monorepo:

\`\`\`bash
# In the replica-sync project:
./scripts/generate-upstream-setup.sh --output-dir ./outbox

# Extract and install:
unzip outbox/upstream-setup-TIMESTAMP.zip -d /tmp/
bash /tmp/upstream-setup-TIMESTAMP/install.sh --target /path/to/internal-monorepo

# In the monorepo:
cd /path/to/internal-monorepo
git diff replica-sync/   # review what changed
git add replica-sync/ && git commit -m "chore: upgrade replica-sync tooling"
\`\`\`

---

## Configuration

### Shared config (\`replica-sync/config/sync.conf\`)

Use the interactive setup wizard to create \`sync.conf\` automatically:

\`\`\`bash
./replica-sync/scripts/setup-sync-conf.sh
\`\`\`

The wizard auto-detects \`INTERNAL_REPO\`, \`INTERNAL_REMOTE\`, \`GH_HOST\`, \`GH_ORG\`,
and \`GH_REPO\` from the current git repository, and prompts for the remaining values.

Alternatively, copy and edit the example manually:

\`\`\`bash
cp replica-sync/config/sync.conf.example replica-sync/config/sync.conf
\$EDITOR replica-sync/config/sync.conf
\`\`\`

Key variables to set:

| Variable | Description | Example |
|---|---|---|
| \`INTERNAL_REPO\` | Absolute path to this monorepo | \`/path/to/internal-monorepo\` |
| \`INTERNAL_REMOTE\` | Git remote name for GHE | \`origin\` |
| \`GH_HOST\` | GHE hostname | \`github.your-company.com\` |
| \`GH_ORG\` | GHE organization | \`your-org\` |
| \`GH_REPO\` | GHE repository name | \`internal-monorepo\` |
| \`SYNC_AUTHOR_NAME\` | Bot name for sync commits | \`Platform Sync Bot\` |
| \`SYNC_AUTHOR_EMAIL\` | Bot email for sync commits | \`sync-bot@your-company.com\` |
| \`EXCLUDE_PATHS\` | Paths to exclude from the replica | See example file |

\`sync.conf\` is .gitignored and must not be committed (it contains local paths).

### Per-party config (\`replica-sync/config/party/<party>.conf\`)

Create one file per 3rd party:

\`\`\`bash
cp replica-sync/config/party/party.conf.example replica-sync/config/party/acme.conf
\$EDITOR replica-sync/config/party/acme.conf
\`\`\`

| Variable | Description | Example |
|---|---|---|
| \`REPLICA_REPO\` | Local clone path of the external replica | \`/path/to/replica-acme\` |
| \`REPLICA_REMOTE\` | Remote name in the replica clone | \`origin\` |
| \`REPLICA_BRANCH\` | Branch that receives synced content | \`main\` |
| \`REPLICA_GH_REPO\` | github.com org/repo slug | \`your-org/replica-acme\` |

Per-party configs are .gitignored and must not be committed.

---

## Prerequisites

\`\`\`bash
git --version   # 2.35 or later
gh --version    # GitHub CLI (authenticated against GHE and github.com)
jq --version
zip --version
\`\`\`

Verify GitHub CLI authentication:
\`\`\`bash
gh auth status                               # github.com
GH_HOST=github.your-company.com gh auth status  # GHE
\`\`\`

### SSH key setup

\`\`\`bash
# Generate keys
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_ghe    -C "sync-bot@ghe"
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_github  -C "sync-bot@github"

# ~/.ssh/config
Host ghe
  HostName github.your-company.com
  User git
  IdentityFile ~/.ssh/id_ed25519_ghe

Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_github

# Verify
ssh -T ghe
ssh -T github.com
\`\`\`

Register the public keys: GHE key as a user SSH key; github.com key as a
Deploy Key (write access) on each external replica repo.

---

## [A] First-Time Setup: Initialize publish Branch

Run once per project. Creates the \`publish\` branch on GHE with a clean snapshot
(no internal commit history, no excluded paths).

### 1. Create a start tag

\`\`\`bash
git tag -a milestone/2024-Q1 -m "Start of 3rd party collaboration"
git push origin milestone/2024-Q1
\`\`\`

### 2. Run init-replica.sh

\`\`\`bash
./replica-sync/scripts/init-replica.sh milestone/2024-Q1
\`\`\`

This creates a PR on GHE: \`init/TIMESTAMP → publish\`.

### 3. Review and merge the PR

Check that:
- Excluded paths (\`EXCLUDE_PATHS\`) are absent from the diff
- The commit history is a single squashed snapshot
- Author is the Bot, not an internal developer

Merge the PR to finalize the \`publish\` branch.

---

## [B] Adding a 3rd Party

### 1. Create the external replica repo on github.com

Create an empty repository (e.g. \`your-org/replica-acme\`).

### 2. Create per-party config

\`\`\`bash
cp replica-sync/config/party/party.conf.example replica-sync/config/party/acme.conf
\$EDITOR replica-sync/config/party/acme.conf
\`\`\`

Clone the empty replica locally (required for push mode):
\`\`\`bash
git clone https://github.com/your-org/replica-acme.git /path/to/replica-acme
\`\`\`

### 3. Generate and send the onboarding package

\`\`\`bash
./replica-sync/scripts/generate-party-onboarding.sh \
  --party acme \
  --repo your-org/replica-acme \
  --delivery-mode push   # or patch, or both
\`\`\`

Output: \`replica-sync/party-packages/acme-onboarding-TIMESTAMP.zip\`

Send this zip to the 3rd party. It contains:
- \`ONBOARDING.md\` — their complete collaboration guide
- \`.github/workflows/pr-to-internal.yml\` — CI workflow to install in their replica

### 4. Set up Branch Protection on the external replica

On github.com, configure the \`main\` branch so that only the Bot can push:
- **Settings → Branches → Add protection rule** for \`main\`:
  - Require a pull request before merging: ✅
  - Required approvals: 2 or more (makes merging impossible without Bot bypass)
  - Do not allow bypassing: ✅
- Add the Bot's GitHub account to the Bypass list, **or** use Rulesets for
  finer-grained control (see \`docs/operations.md\` in the replica-sync repo).

### 5. Deliver the first snapshot

\`\`\`bash
# Push mode (direct git push)
./replica-sync/scripts/deliver-to-replica.sh --party acme "initial: 2024-Q1"

# Patch mode (generate files for manual delivery)
./replica-sync/scripts/deliver-to-replica.sh --party acme --output patch "initial: 2024-Q1"
\`\`\`

For push mode: a sync PR is created on the external replica. Merge it (or have the
3rd party merge it) to update their \`main\`.

---

## [B] Ongoing Sync Loop

Run for every milestone after the first.

### Phase 1: Stage internal changes to publish branch

\`\`\`bash
# Create a milestone tag
git tag -a milestone/2024-Q2 -m "Q2 milestone"
git push origin milestone/2024-Q2

# Stage changes to publish (creates a GHE PR)
./replica-sync/scripts/stage-publish.sh "sync: 2024-Q2"
\`\`\`

Review and merge the GHE PR (\`sync/TIMESTAMP → publish\`). Verify that:
- Excluded paths are absent
- Author is the Bot
- The diff looks correct

### Phase 2: Deliver to external replica (per party)

\`\`\`bash
# Push mode
./replica-sync/scripts/deliver-to-replica.sh --party acme "sync: 2024-Q2"

# Patch mode
./replica-sync/scripts/deliver-to-replica.sh --party acme --output patch "sync: 2024-Q2"
\`\`\`

Repeat for each 3rd party.

---

## [C] Handling External PRs

When a 3rd party creates a PR on their external replica:

### 1. Download the CI artifact

After the \`pr-to-internal.yml\` workflow completes on the external replica:

\`\`\`bash
# From the external replica's GitHub Actions
gh run list --repo your-org/replica-acme --workflow pr-to-internal.yml
gh run download <run-id> --repo your-org/replica-acme --dir ./artifacts/
\`\`\`

### 2. Apply the PR to an internal branch

\`\`\`bash
./replica-sync/scripts/apply-external-pr.sh \
  --party acme \
  --patch artifacts/pr.patch \
  --meta  artifacts/pr-meta.json
\`\`\`

This creates \`external/acme-pr-N\` on GHE and opens an internal PR automatically.

### 3. Review and decide

Review the internal PR. Choose one:

\`\`\`bash
# Accept all changes
git checkout main
git cherry-pick external/acme-pr-N

# Accept specific paths only
./replica-sync/scripts/cherry-pick-partial.sh \
  --patch artifacts/pr.patch \
  --meta  artifacts/pr-meta.json \
  --paths "services/api/" \
  --message "Accept acme API changes"

# Reject: close the internal PR on GHE (no cherry-pick)
\`\`\`

### 4. Notify the 3rd party

\`\`\`bash
# push mode (direct comment on external PR)
./replica-sync/scripts/notify-external-pr.sh \
  --party acme \
  --meta  artifacts/pr-meta.json \
  --status accepted   # accepted | partial | rejected
  # --reason "..." for rejected

# patch mode (generate notification package for 3rd party to run)
./replica-sync/scripts/notify-external-pr.sh \
  --party acme \
  --meta  artifacts/pr-meta.json \
  --status accepted \
  --output patch
\`\`\`

---
$(if [[ "$WITH_CI_WORKFLOW" == "true" ]]; then
cat << 'CIGUIDE'
## CI Automation (sync-replica.yml)

The included `.github/workflows/sync-replica.yml` automates Phase 1 of the sync loop.
When you push a `milestone/*` tag, it automatically runs `stage-publish.sh` and
creates the GHE PR.

**Required setup:**

1. Register in **Secrets** (`Settings → Secrets and variables → Actions → Secrets`):
   - `GHE_TOKEN`: GHE Personal Access Token with `contents: read` and `pull-requests: write`

2. Register in **Variables** (`Settings → Secrets and variables → Actions → Variables`):
   - `GH_HOST`: GHE hostname (e.g. `github.your-company.com`)
   - `GH_ORG`: GHE organization name
   - `GH_REPO`: GHE repository name

After setup, pushing a milestone tag is all that is needed to trigger Phase 1:
```bash
git tag -a milestone/2024-Q2 -m "Q2 milestone"
git push origin milestone/2024-Q2
```

The workflow creates the GHE PR automatically. Review and merge it, then run
Phase 2 (`deliver-to-replica.sh`) manually for each party.

---
CIGUIDE
fi)
## Quick Reference

| Operation | Command |
|---|---|
| Initialize publish branch | \`./replica-sync/scripts/init-replica.sh <start-tag>\` |
| Stage sync to publish | \`./replica-sync/scripts/stage-publish.sh "sync: YYYY-QN"\` |
| Deliver to 3rd party | \`./replica-sync/scripts/deliver-to-replica.sh --party <name> "sync: YYYY-QN"\` |
| Apply external PR | \`./replica-sync/scripts/apply-external-pr.sh --party <name> --patch <file> --meta <file>\` |
| Partial acceptance | \`./replica-sync/scripts/cherry-pick-partial.sh --patch <file> --meta <file> --paths <paths>\` |
| Notify external PR | \`./replica-sync/scripts/notify-external-pr.sh --party <name> --meta <file> --status <decision>\` |
| Generate party onboarding | \`./replica-sync/scripts/generate-party-onboarding.sh --party <name> --repo <org/repo>\` |

All scripts load \`replica-sync/config/sync.conf\` automatically.
Run all scripts from the **monorepo root**.
SETUPEOF

log "Built SETUP.md"

# ── Generate install.sh ────────────────────────────────────────
# HAS_CI is baked in at generation time; no placeholder substitution needed.
HAS_CI="$WITH_CI_WORKFLOW"

cat > "${WORK_DIR}/install.sh" << INSTALLEOF
#!/usr/bin/env bash
# install.sh — generated by generate-upstream-setup.sh
#
# Installs or upgrades replica-sync tooling into a target monorepo.
# Run from the directory where you extracted the package.
#
# Usage:
#   bash install.sh --target /path/to/internal-monorepo
#
# What is overwritten vs preserved on upgrade:
#   Overwritten : scripts, config templates, SETUP.md, .gitignore-fragment
#   Preserved   : config/sync.conf, config/party/*.conf
#   .gitignore  : fragment appended only if not already present
#
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
HAS_CI_WORKFLOW="${HAS_CI}"

ok()   { echo -e "\033[1;32m[  ok ]\033[0m \$*"; }
skip() { echo -e "\033[1;33m[ skip]\033[0m \$*"; }
die()  { echo -e "\033[1;31m[ err ]\033[0m \$*" >&2; exit 1; }
log()  { echo -e "\033[1;34m[inst ]\033[0m \$*"; }

usage() {
  cat << 'USAGE'
Usage: bash install.sh --target <monorepo-dir>

Installs or upgrades replica-sync tooling into an existing monorepo directory.

Options:
  --target <dir>   Path to the target monorepo (must already exist)
  -h, --help       Show this help message

The target directory must be an existing directory (a pre-existing monorepo clone).
This script will NOT create a new directory.

What is overwritten vs preserved on upgrade:
  Overwritten : scripts, config templates, SETUP.md, .gitignore-fragment
  Preserved   : config/sync.conf, config/party/*.conf
  .gitignore  : fragment appended only if not already present

Examples:
  bash install.sh --target /path/to/internal-monorepo
USAGE
}

TARGET=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --target)    TARGET="\$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) die "Unknown option: \$1\nRun with --help to see usage." ;;
  esac
done

[[ -n "\$TARGET" ]] || { usage; exit 1; }
[[ -d "\$TARGET" ]] || die "Target directory not found: \$TARGET\n  The --target directory must already exist (this script installs into an existing monorepo).\n  Create the directory first, or check for a typo in the path."
TARGET="\$(cd "\$TARGET" && pwd)"

RS_SRC="\${SCRIPT_DIR}/replica-sync"
RS_TARGET="\${TARGET}/replica-sync"

IS_UPGRADE="false"
[[ -d "\$RS_TARGET" ]] && IS_UPGRADE="true"

if [[ "\$IS_UPGRADE" == "true" ]]; then
  echo ""
  echo "Upgrading existing installation at: \${TARGET}"
else
  echo ""
  echo "Installing into: \${TARGET}"
  mkdir -p "\${RS_TARGET}/config/party"
fi

UPDATED=0
SKIPPED=0

install_file() {
  local src="\$1" dst="\$2"
  mkdir -p "\$(dirname "\$dst")"
  cp "\$src" "\$dst"
  UPDATED=\$(( UPDATED + 1 ))
}

install_new_only() {
  local src="\$1" dst="\$2" label="\$3"
  if [[ -f "\$dst" ]]; then
    skip "Preserved user config: \${label}"
    SKIPPED=\$(( SKIPPED + 1 ))
  else
    mkdir -p "\$(dirname "\$dst")"
    cp "\$src" "\$dst"
    log "Created: \${label}"
    UPDATED=\$(( UPDATED + 1 ))
  fi
}

# Always overwrite: scripts
for s in "\${RS_SRC}/scripts/"*.sh; do
  install_file "\$s" "\${RS_TARGET}/scripts/\$(basename "\$s")"
done
chmod +x "\${RS_TARGET}/scripts/"*.sh
log "Installed scripts"

# Always overwrite: config templates, bootstrap workflow, docs
install_file "\${RS_SRC}/config/sync.conf.example" \
             "\${RS_TARGET}/config/sync.conf.example"
install_file "\${RS_SRC}/config/party/party.conf.example" \
             "\${RS_TARGET}/config/party/party.conf.example"
install_file "\${RS_SRC}/config/replica-bootstrap/.github/workflows/pr-to-internal.yml" \
             "\${RS_TARGET}/config/replica-bootstrap/.github/workflows/pr-to-internal.yml"
install_file "\${RS_SRC}/SETUP.md" \
             "\${RS_TARGET}/SETUP.md"
install_file "\${RS_SRC}/.gitignore-fragment" \
             "\${RS_TARGET}/.gitignore-fragment"
log "Installed config templates, bootstrap workflow, SETUP.md"

# Preserve on upgrade: sync.conf (copy example as starting point on fresh install)
install_new_only "\${RS_SRC}/config/sync.conf.example" \
                 "\${RS_TARGET}/config/sync.conf" \
                 "replica-sync/config/sync.conf"

# Optional: CI workflow
if [[ "\$HAS_CI_WORKFLOW" == "true" ]]; then
  install_file "\${SCRIPT_DIR}/.github/workflows/sync-replica.yml" \
               "\${TARGET}/.github/workflows/sync-replica.yml"
  log "Installed .github/workflows/sync-replica.yml"
fi

# .gitignore: append fragment only if not already present
GITIGNORE="\${TARGET}/.gitignore"
if [[ -f "\$GITIGNORE" ]] && grep -qF "replica-sync/config/sync.conf" "\$GITIGNORE"; then
  skip "Preserved .gitignore (fragment already present)"
  SKIPPED=\$(( SKIPPED + 1 ))
else
  cat "\${RS_SRC}/.gitignore-fragment" >> "\$GITIGNORE"
  log "Updated .gitignore"
  UPDATED=\$(( UPDATED + 1 ))
fi

echo ""
if [[ "\$IS_UPGRADE" == "true" ]]; then
  ok "Upgrade complete: \${UPDATED} files updated, \${SKIPPED} preserved"
  echo ""
  echo "Review changes before committing:"
  echo "  cd \${TARGET}"
  echo "  git diff replica-sync/"
  echo "  git add replica-sync/"
  [[ "\$HAS_CI_WORKFLOW" == "true" ]] && \
    echo "  git add .github/workflows/sync-replica.yml"
  echo "  git commit -m \"chore: upgrade replica-sync tooling\""
else
  ok "Install complete: \${UPDATED} files installed, \${SKIPPED} already existed"
  echo ""
  echo "Next steps:"
  echo "  cd \${TARGET}"
  echo "  \\\$EDITOR replica-sync/config/sync.conf"
  echo "  git add replica-sync/ .gitignore"
  [[ "\$HAS_CI_WORKFLOW" == "true" ]] && \
    echo "  git add .github/workflows/sync-replica.yml"
  echo "  git commit -m \"chore: add replica-sync tooling\""
fi
INSTALLEOF

chmod +x "${WORK_DIR}/install.sh"
log "Built install.sh"

# ── Install directly or package as zip ────────────────────────
if [[ -n "$INSTALL_TO" ]]; then
  bash "${WORK_DIR}/install.sh" --target "$INSTALL_TO"
  rm -rf "$WORK_DIR"
else
  mkdir -p "$OUTPUT_DIR"
  ZIP_FILE="${OUTPUT_DIR}/${PACKAGE_NAME}.zip"
  (cd "$OUTPUT_DIR" && zip -r "${PACKAGE_NAME}.zip" "${PACKAGE_NAME}" -x "*.DS_Store")
  rm -rf "$WORK_DIR"

  ok "Package created: ${ZIP_FILE}"
  echo ""
  echo "To install:"
  echo "  unzip ${ZIP_FILE} -d /tmp/"
  echo "  bash /tmp/${PACKAGE_NAME}/install.sh --target /path/to/internal-monorepo"
fi
