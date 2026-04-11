#!/usr/bin/env bash
# generate-party-onboarding.sh
#
# Generates an onboarding package to send to a 3rd party.
# The package contains everything they need to set up their replica repo,
# start developing, submit PRs upstream, and handle sync deliveries.
#
# Package contents:
#   ONBOARDING.md                           — Setup and collaboration guide
#   .github/workflows/pr-to-internal.yml    — CI workflow (must be in their repo)
#
# Usage:
#   # Minimal — party name only
#   ./scripts/generate-party-onboarding.sh --party acme
#
#   # With known replica repo slug
#   ./scripts/generate-party-onboarding.sh --party acme --repo your-org/replica-acme
#
#   # Specify delivery mode explicitly
#   ./scripts/generate-party-onboarding.sh --party acme --repo your-org/replica-acme \
#     --delivery-mode push
#
#   # Custom output directory
#   ./scripts/generate-party-onboarding.sh --party acme --output-dir ./outbox
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP_DIR="${SCRIPT_DIR}/../config/replica-bootstrap"
PARTY_BOOTSTRAP_BASE="${SCRIPT_DIR}/../config/replica-bootstrap"

ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }
log() { echo -e "\033[1;34m[ pkg ]\033[0m $*"; }

# ── Argument parsing ───────────────────────────────────────────
PARTY=""
REPLICA_REPO_SLUG=""    # e.g. your-org/replica-acme
DELIVERY_MODE="both"    # push | patch | both
OUTPUT_DIR="./party-packages"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --party)         PARTY="$2";             shift 2 ;;
    --repo)          REPLICA_REPO_SLUG="$2"; shift 2 ;;
    --delivery-mode) DELIVERY_MODE="$2";     shift 2 ;;
    --output-dir)    OUTPUT_DIR="$2";        shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$PARTY" ]] || die "Specify a party name with --party\n  Example: $0 --party acme"

case "$DELIVERY_MODE" in
  push|patch|both) ;;
  *) die "--delivery-mode must be push, patch, or both" ;;
esac

# ── Derived values ─────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PACKAGE_NAME="${PARTY}-onboarding-${TIMESTAMP}"
WORK_DIR="${OUTPUT_DIR}/${PACKAGE_NAME}"
REPO_DISPLAY="${REPLICA_REPO_SLUG:-"your-org/replica-${PARTY}"}"
REPO_NAME="${REPLICA_REPO_SLUG##*/}"
REPO_NAME="${REPO_NAME:-"replica-${PARTY}"}"

CLONE_URL="https://github.com/${REPO_DISPLAY}.git"

# ── Build package directory ────────────────────────────────────
log "Creating package: ${PACKAGE_NAME}"
mkdir -p "${WORK_DIR}/.github/workflows"

# Copy pr-to-internal.yml
PR_WORKFLOW_SRC="${BOOTSTRAP_DIR}/.github/workflows/pr-to-internal.yml"
[[ -f "$PR_WORKFLOW_SRC" ]] || die "Source workflow not found: $PR_WORKFLOW_SRC"
cp "$PR_WORKFLOW_SRC" "${WORK_DIR}/.github/workflows/pr-to-internal.yml"
log "Copied: .github/workflows/pr-to-internal.yml"

# ── Build delivery-mode section ────────────────────────────────
# Construct the sync delivery section based on the requested delivery mode.

SYNC_PUSH_SECTION='### Push mode — receiving sync as a PR

The upstream Bot will open a PR on this repository with a title like `sync: YYYY-QN`.

1. Review the PR to understand what upstream changed
2. **Merge the PR** — this updates `main` with the latest upstream content
3. Rebase your development branches onto the updated `main` as needed:
   ```bash
   git checkout your-feature-branch
   git rebase main
   ```'

SYNC_PATCH_SECTION='### Patch mode — receiving sync as files

You will receive a set of files from the upstream team:

```
sync-TIMESTAMP.patch
sync-TIMESTAMP-meta.json
sync-TIMESTAMP-summary.txt
sync-TIMESTAMP-apply.sh
```

Run the apply script from your local clone of this repository:

```bash
cd /path/to/'"${REPO_NAME}"'
bash /path/to/sync-TIMESTAMP-apply.sh
```

This creates a PR on this repository (or pushes directly to `main`, depending on
configuration). Review and merge the resulting PR as appropriate.

After applying, rebase your development branches onto the updated `main` as needed:
```bash
git checkout your-feature-branch
git rebase main
```'

case "$DELIVERY_MODE" in
  push)
    SYNC_SECTION="$SYNC_PUSH_SECTION"
    ;;
  patch)
    SYNC_SECTION="$SYNC_PATCH_SECTION"
    ;;
  both)
    SYNC_SECTION="${SYNC_PUSH_SECTION}

${SYNC_PATCH_SECTION}"
    ;;
esac

# ── Generate ONBOARDING.md ─────────────────────────────────────
cat > "${WORK_DIR}/ONBOARDING.md" << ONBOARDING
# Onboarding Guide — ${PARTY}

## Overview

This repository is a replica of an upstream monorepo, synchronized on a milestone basis.
It contains a curated snapshot of the upstream codebase — internal history and
author information are not included.

**Key principles:**
- \`main\` is updated **only** by upstream syncs — do not push to it directly
- Develop on feature branches and submit PRs targeting \`main\`
- Your PRs are forwarded to the upstream team for review via CI
- Upstream changes are delivered to you periodically as syncs

---

## Getting Started

### 1. Clone the repository

\`\`\`bash
git clone ${CLONE_URL}
cd ${REPO_NAME}
\`\`\`

### 2. Verify the CI workflow is in place

The file \`.github/workflows/pr-to-internal.yml\` must be present in the repository.
It is included in this onboarding package — add and commit it if it is not already there:

\`\`\`bash
mkdir -p .github/workflows
cp /path/to/this-package/.github/workflows/pr-to-internal.yml \
   .github/workflows/pr-to-internal.yml
git add .github/workflows/pr-to-internal.yml
git commit -m "ci: add pr-to-internal workflow"
git push
\`\`\`

This workflow automatically generates a patch of your PR changes and forwards them
to the upstream team whenever you open or update a PR targeting \`main\`.

---

## Development Workflow

### 1. Always start from the latest \`main\`

\`\`\`bash
git checkout main
git pull
\`\`\`

### 2. Create a feature branch

\`\`\`bash
git checkout -b ${PARTY}/your-feature-name
\`\`\`

Recommended branch naming: \`${PARTY}/feature-name\`
(e.g. \`${PARTY}/new-auth-flow\`, \`${PARTY}/fix-api-timeout\`)

### 3. Develop and commit

Work as you normally would. Commit with clear messages:

\`\`\`bash
git add .
git commit -m "feat: description of your change"
git push origin ${PARTY}/your-feature-name
\`\`\`

### 4. Open a PR targeting \`main\`

\`\`\`bash
gh pr create --base main --title "Your change title"
\`\`\`

Or open it from the GitHub web UI.

**What happens automatically when you open the PR:**

1. The \`pr-to-internal.yml\` workflow runs
2. It generates a patch of your changes and uploads it as a CI artifact
3. It posts a comment on your PR confirming the forwarding:

   > **This PR is for upstream patch generation only — do not merge.**
   > The diff has been forwarded to the upstream team for review.
   > This PR will be closed after the upstream review process is complete.

4. The upstream team downloads the patch and reviews it internally

**Keep your PR open** — the upstream team will respond via a comment on it.

---

## Receiving Upstream Syncs

The upstream team periodically syncs their internal codebase to this repository.
How you receive these syncs depends on the agreed delivery method.

${SYNC_SECTION}

---

## PR Review Notifications

After the upstream team reviews your PR, they will post a comment on it:

| Decision | Comment posted | Your action |
|---|---|---|
| **Accepted ✅** | "This change has been reviewed internally and accepted. It will be reflected in this branch on the next milestone sync. This PR will be closed after the sync completes." | Wait for the next sync. The PR will be closed automatically after the sync |
| **Partially accepted ⚠️** | "This change has been reviewed internally and partially accepted. The accepted portions will be reflected on the next milestone sync. This PR will be closed after the sync completes." | Wait for the next sync. Ask upstream which parts were accepted if unclear |
| **Rejected ❌** | "This change has been reviewed internally but was not accepted. Reason: ..." | The PR will be automatically closed. Consider the feedback and open a new PR if appropriate |

**Important:** Even when accepted, your changes arrive in \`main\` via the next
milestone sync — not by merging your PR directly. The PR serves as the submission
mechanism; the actual merge happens on the upstream side.

---

## Branch Protection

The \`main\` branch is protected. The following restrictions are in place:

- Direct pushes to \`main\` are not allowed
- PRs targeting \`main\` require upstream approval before merging
- Only the upstream Bot can merge sync PRs into \`main\`

This ensures that \`main\` always reflects only upstream-reviewed and synced content.

---

## About the CI Workflow (\`pr-to-internal.yml\`)

This workflow must remain in the repository at \`.github/workflows/pr-to-internal.yml\`.

**What it does:**
- Triggers on PR open and update (targeting \`main\`)
- Skips \`sync/*\` branches (these are upstream delivery PRs, not 3rd party contributions)
- Generates a \`pr.patch\` file and \`pr-meta.json\` (PR metadata)
- Uploads both as a GitHub Actions artifact (retained for 30 days)
- Posts a comment on the PR to confirm forwarding

**What it does NOT do:**
- It does not check out or execute your branch code
- It does not push anything to any repository
- It does not merge or close any PR

If the workflow is removed or disabled, your PRs will not reach the upstream team.

---

## Contact

If you have questions about this setup or the collaboration process,
contact the upstream team.
ONBOARDING

log "Generated: ONBOARDING.md"

# ── Create zip archive ─────────────────────────────────────────
ZIP_FILE="${OUTPUT_DIR}/${PACKAGE_NAME}.zip"
(cd "$OUTPUT_DIR" && zip -r "${PACKAGE_NAME}.zip" "${PACKAGE_NAME}" -x "*.DS_Store")
rm -rf "$WORK_DIR"

ok "Package created: ${ZIP_FILE}"
echo ""
echo "Contents:"
unzip -l "$ZIP_FILE" | awk 'NR>3 && /\S/ && !/^-/ && !/files/ {print "  " $NF}'
echo ""
echo "Send this file to ${PARTY} and ask them to:"
echo "  1. Extract the zip"
echo "  2. Read ONBOARDING.md"
echo "  3. Add .github/workflows/pr-to-internal.yml to their replica repo"
