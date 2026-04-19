# Script Reference

All scripts live in `scripts/` and load `config/sync.conf` (and `config/party/<party>.conf`
where applicable) automatically. Run them from the **repository root** unless noted otherwise.

---

## setup-sync-conf.sh

**Interactive wizard to create `sync.conf`**

Auto-detects `INTERNAL_REPO`, `INTERNAL_REMOTE`, `GH_HOST`, `GH_ORG`, and `GH_REPO`
from the current git repository (remote URL parsing), then prompts for `SYNC_AUTHOR_NAME`,
`SYNC_AUTHOR_EMAIL`, `EXCLUDE_PATHS`, and `PATCH_OUTPUT_DIR`. Writes the result to
`replica-sync/config/sync.conf`.

Run this instead of manually copying `sync.conf.example` — it saves time and reduces
the risk of misconfiguration.

```
./replica-sync/scripts/setup-sync-conf.sh
```

No options. Run from the **monorepo root** (not the replica-sync directory).

If `sync.conf` already exists, the wizard prompts for confirmation before overwriting.

**Auto-detected values:**

| Variable | Source |
|---|---|
| `INTERNAL_REPO` | Absolute path of the current directory (`git rev-parse --show-toplevel`) |
| `INTERNAL_REMOTE` | From `git remote`; prompted if multiple remotes exist |
| `GH_HOST` | Parsed from the remote URL (SSH or HTTPS) |
| `GH_ORG` | Parsed from the remote URL |
| `GH_REPO` | Parsed from the remote URL |

**Prompted values (with defaults):**

| Variable | Default |
|---|---|
| `SYNC_AUTHOR_NAME` | `Platform Sync Bot` |
| `SYNC_AUTHOR_EMAIL` | `sync-bot@<GH_HOST>` |
| `PATCH_OUTPUT_DIR` | `./sync-patches` |
| `EXCLUDE_PATHS` | Empty (enter paths one per line; blank line to finish) |

**Example session:**
```
── Step 1: Auto-detecting repository settings ──
[ info] INTERNAL_REPO   = /path/to/internal-monorepo
[ info] INTERNAL_REMOTE = origin
[ info] GH_HOST         = github.your-company.com
[ info] GH_ORG          = your-org
[ info] GH_REPO         = internal-monorepo

── Step 2: Confirm repository settings (press Enter to accept) ──
  INTERNAL_REPO   [/path/to/internal-monorepo]:
  INTERNAL_REMOTE [origin]:
  GH_HOST         [github.your-company.com]:
  GH_ORG          [your-org]:
  GH_REPO         [internal-monorepo]:

── Step 3: Sync commit author ──
  SYNC_AUTHOR_NAME  [Platform Sync Bot]:
  SYNC_AUTHOR_EMAIL [sync-bot@github.your-company.com]:

── Step 4: Excluded paths ──
  Path (or Enter to finish): services/internal-only/
  Path (or Enter to finish): .internal/
  Path (or Enter to finish):

── Step 5: Patch mode output directory ──
  PATCH_OUTPUT_DIR [./sync-patches]:

[  ok ] Written: replica-sync/config/sync.conf
```

---

## init-replica.sh

**Operation [A] — Initialize publish branch (run once per project)**

Extracts a file-tree snapshot of the internal monorepo at the given start tag using
`git archive` (no commit history, `EXCLUDE_PATHS` applied), and opens a GHE PR
targeting the `publish` branch for internal review. After the PR is merged, run
`deliver-to-replica.sh` for each 3rd party to push the initial snapshot externally.

```
./scripts/init-replica.sh [--message <text>] <start-tag>
```

| Argument | Required | Description |
|---|:---:|---|
| `<start-tag>` | Yes | Git tag to use as the snapshot base (e.g. `milestone/2024-Q1`) |
| `--message <text>` | No | Additional note appended to the init tag annotation |

**Examples:**
```bash
./scripts/init-replica.sh milestone/2024-Q1

./scripts/init-replica.sh --message "initial setup for acme collaboration" \
  milestone/2024-Q1
```

---

## stage-publish.sh

**Operation [B-1] — Stage internal changes to publish branch**

Squashes all changes since the last sync from `internal/main` (with `EXCLUDE_PATHS`
applied) and opens a GHE PR (`sync/TIMESTAMP → publish`) for internal review.
After the PR is reviewed and merged, run `deliver-to-replica.sh` to push to external replicas.

```
./scripts/stage-publish.sh [<commit-message>]
```

| Argument | Required | Description |
|---|:---:|---|
| `<commit-message>` | No | Commit message for the squash commit (default: `sync: YYYY-MM-DD`) |

**Examples:**
```bash
./scripts/stage-publish.sh "sync: 2024-Q2"

./scripts/stage-publish.sh   # uses today's date as message
```

---

## deliver-to-replica.sh

**Operation [B-2] — Deliver publish branch to external replica**

Delivers the current `publish` branch content to the external replica for the given party.
Supports two output modes (push or patch) and two delivery modes (PR or direct push).

Run after `init-replica.sh` or after a `stage-publish.sh` PR has been merged.

```
./scripts/deliver-to-replica.sh --party <name> [--output push|patch] [--mode pr|direct] [<commit-message>]
```

| Option | Default | Description |
|---|---|---|
| `--party <name>` | — | Party name (loads `config/party/<name>.conf`) |
| `--output push` | `push` | Push directly to the external replica via git |
| `--output patch` | | Generate a patch set for manual delivery |
| `--mode pr` | `pr` | Create a PR on the external replica (push output only) |
| `--mode direct` | | Push directly to `main` without a PR |
| `<commit-message>` | `sync: YYYY-MM-DD` | Commit message for the sync commit |

**Examples:**
```bash
# Push as a PR (default)
./scripts/deliver-to-replica.sh --party acme "sync: 2024-Q2"

# Push directly to main
./scripts/deliver-to-replica.sh --party acme --mode direct "sync: 2024-Q2"

# Generate patch set for manual delivery
./scripts/deliver-to-replica.sh --party acme --output patch "sync: 2024-Q2"

# Generate patch set, recipient applies directly to main
./scripts/deliver-to-replica.sh --party acme --output patch --mode direct "sync: 2024-Q2"
```

---

## apply-external-pr.sh

**Operation [C] — Apply external PR to internal repo**

Applies a patch generated by the `pr-to-internal.yml` CI workflow on the external
replica to the internal repo and automatically opens a GHE PR for review.

```
./scripts/apply-external-pr.sh --patch <file> --meta <file> [--party <name>]
```

| Option | Required | Description |
|---|:---:|---|
| `--patch <file>` | Yes | Path to the `pr.patch` artifact |
| `--meta <file>` | Yes | Path to the `pr-meta.json` artifact |
| `--party <name>` | No | Party name used as the branch prefix (default: `3rdparty`) |

**Examples:**
```bash
./scripts/apply-external-pr.sh \
  --party acme \
  --patch artifacts/pr.patch \
  --meta  artifacts/pr-meta.json

# Without --party (uses "3rdparty" as branch prefix)
./scripts/apply-external-pr.sh \
  --patch artifacts/pr.patch \
  --meta  artifacts/pr-meta.json
```

---

## cherry-pick-partial.sh

**Operation [C] — Selectively incorporate parts of an external PR**

Applies only the hunks matching the specified paths from an external PR patch.
Use when the upstream team accepts only a subset of the external PR's changes.

```
./scripts/cherry-pick-partial.sh --patch <file> --meta <file> --paths <path>... [--message <text>]
```

| Option | Required | Description |
|---|:---:|---|
| `--patch <file>` | Yes | Path to the `pr.patch` artifact |
| `--meta <file>` | Yes | Path to the `pr-meta.json` artifact |
| `--paths <path>...` | Yes | One or more paths to include (space-separated, up to the next `--` option) |
| `--message <text>` | No | Commit message override |

**Examples:**
```bash
./scripts/cherry-pick-partial.sh \
  --patch artifacts/pr.patch \
  --meta  artifacts/pr-meta.json \
  --paths "services/api/" "services/common/" \
  --message "Accept API changes from acme PR #42"
```

---

## notify-external-pr.sh

**Operation [C] — Post review decision to external PR**

Posts the upstream team's review decision as a comment on the external PR.
Closes the PR automatically when the decision is `rejected`.

Supports two output modes: post directly via `gh` CLI (`push`) or generate a
notification package for the 3rd party to run themselves (`patch`).

```
./scripts/notify-external-pr.sh --party <name> --meta <file> --status <decision> [--reason <text>] [--output push|patch]
```

| Option | Required | Description |
|---|:---:|---|
| `--party <name>` | Yes | Party name (loads `config/party/<name>.conf`) |
| `--meta <file>` | Yes | Path to the `pr-meta.json` artifact |
| `--status <decision>` | Yes | `accepted`, `partial`, or `rejected` |
| `--reason <text>` | No | Reason for rejection (shown in the comment) |
| `--output push` | No | Post directly via `gh` CLI (default) |
| `--output patch` | No | Generate a notification package for the 3rd party to run |

**Examples:**
```bash
# Accept
./scripts/notify-external-pr.sh \
  --party acme --meta artifacts/pr-meta.json --status accepted

# Partial acceptance
./scripts/notify-external-pr.sh \
  --party acme --meta artifacts/pr-meta.json --status partial

# Reject with reason
./scripts/notify-external-pr.sh \
  --party acme --meta artifacts/pr-meta.json \
  --status rejected --reason "Conflicts with internal design direction"

# Patch mode (generate notification package for 3rd party)
./scripts/notify-external-pr.sh \
  --party acme --meta artifacts/pr-meta.json \
  --status accepted --output patch
```

---

## generate-party-onboarding.sh

**Generates an onboarding package to send to a 3rd party**

Creates a zip archive containing:
- `ONBOARDING.md` — complete collaboration guide (setup, development workflow, sync delivery, PR process)
- `install.sh` — installs or upgrades `pr-to-internal.yml` into the 3rd party's replica clone
- `.github/workflows/pr-to-internal.yml` — CI workflow to install in the external replica

The 3rd party runs `install.sh --target /path/to/replica-clone` to install the workflow.
The same command detects an existing installation and upgrades it. When the upstream team
sends a new onboarding package (e.g. after a workflow update), the 3rd party runs
`install.sh` again to upgrade.

```
./scripts/generate-party-onboarding.sh --party <name> [--repo <org/repo>] [--delivery-mode push|patch|both] [--output-dir <dir>]
```

| Option | Required | Description |
|---|:---:|---|
| `--party <name>` | Yes | Party name (used in branch naming conventions and headings) |
| `--repo <org/repo>` | No | github.com repo slug (e.g. `your-org/replica-acme`); shown as placeholder if omitted |
| `--delivery-mode push\|patch\|both` | No | Which sync delivery section(s) to include in `ONBOARDING.md` (default: `both`) |
| `--output-dir <dir>` | No | Output directory for the zip (default: `./party-packages`) |
| `-h`, `--help` | No | Show usage and exit |

**Examples:**
```bash
# Minimal
./scripts/generate-party-onboarding.sh --party acme

# With repo slug and push-only delivery docs
./scripts/generate-party-onboarding.sh \
  --party acme \
  --repo your-org/replica-acme \
  --delivery-mode push

# Custom output directory
./scripts/generate-party-onboarding.sh \
  --party acme --repo your-org/replica-acme \
  --output-dir ./outbox
```

Output: `<output-dir>/acme-onboarding-TIMESTAMP.zip`

**The 3rd party installs from the zip:**
```bash
unzip acme-onboarding-TIMESTAMP.zip
bash acme-onboarding-TIMESTAMP/install.sh --target /path/to/replica-acme
# follow the printed git instructions
```

---

## generate-upstream-setup.sh

**Generates or installs replica-sync tooling into an upstream monorepo**

Packages all scripts, config templates, and a `SETUP.md` guide into a zip archive
(with an `install.sh` for easy installation), or installs directly into an existing
monorepo. On upgrade, scripts and templates are overwritten while user configs
(`sync.conf`, `party/*.conf`) are preserved.

```
./scripts/generate-upstream-setup.sh [--with-ci-workflow] [--output-dir <dir>] [--install-to <dir>] [-h|--help]
```

| Option | Description |
|---|---|
| `--with-ci-workflow` | Include `sync-replica.yml` (GHE-side CI: milestone tag → stage-publish) |
| `--output-dir <dir>` | Output directory for the zip (default: `./upstream-packages`) |
| `--install-to <dir>` | Install directly into an existing monorepo (must already exist) |
| `-h`, `--help` | Show usage and exit |

**Examples:**
```bash
# Generate zip package
./scripts/generate-upstream-setup.sh
./scripts/generate-upstream-setup.sh --with-ci-workflow --output-dir ./outbox

# Install directly into an existing monorepo
./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo
./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo --with-ci-workflow
```

**Installing from the zip:**
```bash
unzip upstream-setup-TIMESTAMP.zip -d /tmp/
bash /tmp/upstream-setup-TIMESTAMP/install.sh --target /path/to/internal-monorepo
```

Output: `<output-dir>/upstream-setup-TIMESTAMP.zip`
