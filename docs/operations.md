# Monorepo Replica Management — Operations Guide

## System Overview

```
GitHub Enterprise (internal)                     github.com (external replica)
────────────────────────────────────             ─────────────────────────
github.your-company.com                          github.com
  └── org/internal-monorepo                        └── your-org/replica
        │                                                │
        │  [A] publish branch initialization             ├── main   ← sync target
        │      init-replica.sh                           └── 3rdparty/foo  ← 3rd party dev
        │        → GHE PR: init/TIMESTAMP → publish
        │        → [internal review & merge]
        │        → initial snapshot reflected to publish
        │
        │  [B] Milestone sync (2 phases)
        │
        │  Phase 1: stage-publish.sh
        │    internal/main
        │      → squash + EXCLUDE_PATHS filter
        │      → GHE PR: sync/TIMESTAMP → publish
        │      → [internal review & merge]
        │      → reflected to publish
        │
        │  Phase 2: deliver-to-replica.sh    ──────────────────────►
        │    publish                                  reflected to external/main
        │      → push (pr/direct)
        │         or patch + apply.sh output
        │
        │  [C] External PR incorporation     ◄──────────────────────
        │
  Tags (all kept in internal-monorepo)
    publish/init-TIMESTAMP              ← record of publish branch first creation (party-independent)
    replica/<party>/init-TIMESTAMP      ← record of first delivery to each party
    replica/<party>/last-sync           ← last delivered publish HEAD (moving, per-party)
    replica/<party>/sync-TIMESTAMP      ← immutable record of each delivery
    milestone/YYYY-QN                   ← milestone anchor
```

---

## Quick Start (Internal Monorepo Owner)

This section covers the complete lifecycle for an internal team that owns the monorepo
and is setting up 3rd party collaboration for the first time.

### Step 0 — Install replica-sync tooling (once)

**Path A — Direct install** (when you have local access to the monorepo):

```bash
# In the replica-sync project:
./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo
# With GHE-side CI automation (milestone tag triggers stage-publish automatically):
./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo --with-ci-workflow
```

**Path B — Zip package** (when the monorepo is owned by someone else):

```bash
# In the replica-sync project — generate the zip:
./scripts/generate-upstream-setup.sh --output-dir ./outbox
# With GHE-side CI automation:
./scripts/generate-upstream-setup.sh --with-ci-workflow --output-dir ./outbox
# → outbox/upstream-setup-TIMESTAMP.zip

# Send the zip to the monorepo owner. They run:
unzip upstream-setup-TIMESTAMP.zip -d /tmp/
bash /tmp/upstream-setup-TIMESTAMP/install.sh --target /path/to/internal-monorepo
```

**After install (both paths) — create sync.conf and commit:**

```bash
cd /path/to/internal-monorepo
./replica-sync/scripts/setup-sync-conf.sh
# The wizard auto-detects git settings and prompts for the rest.
git add replica-sync/ .gitignore
git commit -m "chore: add replica-sync tooling"
```

→ See [Pre-A] for detailed install and config options.
→ See [setup-sync-conf.sh](scripts.md#setup-sync-confsh) for wizard details.

---

### Step 1 — Add a 3rd party (once per party)

```bash
# 1. Create the external replica repo on github.com (empty)

# 2. Create per-party config (required for all parties, regardless of delivery mode)
cp replica-sync/config/party/party.conf.example replica-sync/config/party/acme.conf
$EDITOR replica-sync/config/party/acme.conf   # set REPLICA_REPO, REPLICA_GH_REPO, etc.

# 3. Generate and send onboarding package
./replica-sync/scripts/generate-party-onboarding.sh \
  --party acme \
  --delivery-mode push   # or patch, or both
# → zip contains ONBOARDING.md, install.sh, and pr-to-internal.yml
# → 3rd party runs: bash install.sh --target /path/to/replica-acme

# 4. Set up branch protection on the external replica (github.com)
#    main branch: require PRs, only Bot can bypass
```

> **Note — `<party>.conf` is required even in patch mode.**
> `deliver-to-replica.sh` and `generate-party-onboarding.sh` both require
> `config/party/<party>.conf` to exist, regardless of delivery mode.
> The file serves as the **registry of active 3rd parties** — its presence is how you
> track which parties are receiving replica content.
> If you are using patch mode and do not yet have a local clone of the replica,
> the push-specific variables (`REPLICA_REPO`, `REPLICA_REMOTE`, `REPLICA_BRANCH`)
> can be left at their placeholder values; only `REPLICA_GH_REPO` needs to be set.

→ See [A-1] for publish branch setup and branch protection details.

---

### Step 2 — Initialize the publish branch (once per project)

```bash
# 1. Create a start tag in the internal monorepo
git tag -a milestone/2024-Q1 -m "Start of 3rd party collaboration"
git push origin milestone/2024-Q1

# 2. Create the publish branch snapshot (GHE PR flow)
./replica-sync/scripts/init-replica.sh milestone/2024-Q1
# → opens GHE PR: init/TIMESTAMP → publish
# → review: verify EXCLUDE_PATHS applied, author is Bot, single commit
# → merge the PR

# 3. Deliver the initial snapshot to each 3rd party
./replica-sync/scripts/deliver-to-replica.sh --party acme "initial: 2024-Q1"
# → opens a sync PR on the external replica; 3rd party reviews and merges
```

→ See [A-2] and [A-3] for detailed procedures.

---

### Step 3 — Milestone sync loop (repeat each milestone)

```bash
# Phase 1: Tag the snapshot you want to publish, then stage it
git tag -a milestone/2024-Q2 -m "Q2 milestone"
git push origin milestone/2024-Q2

# Recommended: pass --tag to pin the diff to the tagged snapshot.
# Without --tag, the diff goes up to HEAD at run time, which may
# include commits added after the tag was created.
./replica-sync/scripts/stage-publish.sh --tag milestone/2024-Q2 "sync: 2024-Q2"
# → opens GHE PR: sync/TIMESTAMP → publish
# → review: verify diff, EXCLUDE_PATHS, Bot author
# → merge the PR

# Phase 2: Deliver to each 3rd party
./replica-sync/scripts/deliver-to-replica.sh --party acme "sync: 2024-Q2"
# repeat for each party
```

→ See [B] for full sync loop procedures including patch mode.

---

### Step 4 — Handle an incoming 3rd party PR

```bash
# 1. Download CI artifact from the external replica
gh run list --repo your-org/replica-acme --workflow pr-to-internal.yml
gh run download <run-id> --repo your-org/replica-acme --dir ./artifacts/

# 2. Apply to internal branch
./replica-sync/scripts/apply-external-pr.sh \
  --party acme \
  --patch artifacts/pr.patch \
  --meta  artifacts/pr-meta.json
# → opens internal PR on GHE for review

# 3a. Accept all — cherry-pick after internal review
git checkout main && git cherry-pick external/acme-pr-N

# 3b. Accept partial — cherry-pick specific paths only
./replica-sync/scripts/cherry-pick-partial.sh \
  --patch artifacts/pr.patch \
  --meta  artifacts/pr-meta.json \
  --paths "services/api/"

# 4. Notify the 3rd party of the decision
./replica-sync/scripts/notify-external-pr.sh \
  --party acme \
  --meta  artifacts/pr-meta.json \
  --status accepted   # accepted | partial | rejected
```

→ See [C] for full external PR procedures including patch mode and rejection flow.

---

## Quick Start (3rd Party Collaborator)

This section covers the complete lifecycle from the perspective of a 3rd party
that has received a replica and wants to contribute changes back upstream.

### Step 0 — Initial setup (once)

You will receive an onboarding package zip from the upstream team.

```bash
# 1. Clone the replica repository
git clone https://github.com/your-org/replica-acme.git
cd replica-acme

# 2. Install the CI workflow from the onboarding package
unzip acme-onboarding-TIMESTAMP.zip
bash acme-onboarding-TIMESTAMP/install.sh --target /path/to/replica-acme
# → prints git add / commit / push commands; follow them to activate the workflow

# 3. Verify the workflow is active
#    Open a test PR on github.com and confirm the pr-to-internal workflow runs
```

Read `ONBOARDING.md` (included in the package) for a full guide to the collaboration process.

---

### Step 1 — Develop and submit a PR (repeat as needed)

```bash
# 1. Always start from the latest main
git checkout main
git pull

# 2. Create a feature branch
git checkout -b acme/your-feature-name

# 3. Make changes, commit, and push
git add .
git commit -m "feat: description of your change"
git push origin acme/your-feature-name

# 4. Open a PR targeting main
gh pr create --base main --title "Your change title"
# → pr-to-internal.yml runs automatically and forwards the diff to the upstream team
# → A comment is posted on your PR confirming forwarding; keep the PR open
```

**What happens next:** The upstream team reviews the diff internally and posts a comment
on your PR with one of: `accepted`, `partially accepted`, or `rejected`.
Your changes will arrive in `main` via the next milestone sync — not by merging your PR directly.

---

### Step 2 — Receive an upstream sync (repeat each milestone)

The upstream team delivers changes periodically. How you receive them depends on the
agreed delivery method.

**Patch mode** (you receive a zip file):

```bash
# Extract and apply in one step
# (run from any branch — the script switches to main automatically)
unzip sync-TIMESTAMP-acme.zip
cd sync-TIMESTAMP-acme/
bash sync-TIMESTAMP-apply.sh          # creates a PR on this repo by default
# → review and merge the resulting PR

# Or apply directly to main (if agreed with upstream)
bash sync-TIMESTAMP-apply.sh --mode direct
```

**Push mode** (upstream opens a PR directly on this repo):

```bash
# A PR titled "sync: YYYY-QN" will appear on the repository
# Review and merge it — this updates main with the latest upstream content
```

**After merging the sync PR**, rebase your development branches:

```bash
git checkout acme/your-feature-name
git rebase main
```

---

### Step 3 — Upgrade the CI workflow (when upstream sends a new package)

```bash
unzip acme-onboarding-TIMESTAMP.zip
bash acme-onboarding-TIMESTAMP/install.sh --target /path/to/replica-acme
# → detects the existing workflow and upgrades it
# → prints git add / commit / push commands; follow them to activate
```

→ See [A-1] for branch protection requirements on the replica.
→ See [C] for how the upstream team processes your PRs.

---

## Scripts Reference

| Script | Environment | Purpose |
|---|---|---|
| `init-replica.sh` | Internal | Initialize publish branch (GHE PR flow) |
| `stage-publish.sh` | Internal | Milestone sync Phase 1: squash and create GHE PR |
| `deliver-to-replica.sh` | Internal | Milestone sync Phase 2: deliver from publish branch to external |
| `sync-to-replica.sh` | Internal | Milestone sync (legacy; for backward compatibility) |
| `pr-to-internal.yml` | github.com CI | Generate external PR diff |
| `apply-external-pr.sh` | Internal | Apply external PR and create internal PR |
| `cherry-pick-partial.sh` | Internal | Selectively incorporate external PR changes |
| `notify-external-pr.sh` | Internal | Notify external PR of acceptance decision |
| `generate-party-onboarding.sh` | Internal | Generate onboarding package (zip) for a 3rd party |
| `generate-upstream-setup.sh` | Standalone | Generate setup package (zip) to install replica-sync into an upstream monorepo |
| `setup-sync-conf.sh` | Internal | Interactive wizard to create `sync.conf` from git auto-detection |
| `build-exclude-list.sh` | Internal | Generate `EXCLUDE_PATHS` list from exclude/include glob patterns |

---

## Config Files

### `config/sync.conf` (shared config)

All scripts operate by `source`-ing `config/sync.conf`.
Use the setup wizard to create it interactively, or copy the example manually:

```bash
# Recommended: interactive wizard (auto-detects git settings)
./replica-sync/scripts/setup-sync-conf.sh

# Alternative: manual copy and edit
cp config/sync.conf.example config/sync.conf
$EDITOR config/sync.conf
```

### `config/party/<party>.conf` (per-party config)

Replica connection details (`REPLICA_*`) differ per party,
so they are separated into `config/party/<party>.conf`.

```bash
cp config/party/party.conf.example config/party/acme.conf
$EDITOR config/party/acme.conf
```

`deliver-to-replica.sh` and `generate-party-onboarding.sh` automatically `source` `config/party/acme.conf`
when `--party acme` is passed. Both scripts error clearly if the file does not exist.

`sync.conf` and `config/party/*.conf` are `.gitignore`d and are not committed to the repository.

### Config Variables Reference

Columns correspond to operation phases.

| Legend | Meaning |
|---|---|
| **Required** | The script references this variable in that phase |
| With note | Required only in certain modes or conditions |
| ― | Not referenced in that phase |

Column-to-script mapping:

| Column | Script |
|---|---|
| `[A] init` | `init-replica.sh` |
| `[B-1] stage` | `stage-publish.sh` |
| `[B-2] deliver` | `deliver-to-replica.sh` |
| `[C] external` | `apply-external-pr.sh` / `cherry-pick-partial.sh` / `notify-external-pr.sh` |

#### `config/sync.conf` — Internal Repository (GHE)

| Variable | Description | `[A] init` | `[B-1] stage` | `[B-2] deliver` | `[C] external` | Example |
|---|---|:---:|:---:|:---:|:---:|---|
| `INTERNAL_REPO` | Local path to internal monorepo (absolute) | **Required** | **Required** | **Required** | apply/cherry-pick only | `/path/to/internal-monorepo` |
| `INTERNAL_REMOTE` | GHE remote name | **Required** | **Required** | ― | apply/cherry-pick only | `origin` |
| `INTERNAL_BRANCH` | Primary development branch name | ― | **Required** | ― | ― | `main` (default); set to `dev` etc. if your repo uses a different primary branch |
| `GH_HOST` | GHE hostname (used as `GH_HOST` for `gh` CLI) | **Required** | **Required** | ― | apply only | `github.your-company.com` |
| `GH_ORG` | GHE organization name | **Required** | **Required** | ― | apply only | `org` |
| `GH_REPO` | GHE repository name | **Required** | **Required** | ― | apply only | `internal` |

#### `config/sync.conf` — Sync Settings

| Variable | Description | `[A] init` | `[B-1] stage` | `[B-2] deliver` | `[C] external` | Notes |
|---|---|:---:|:---:|:---:|:---:|---|
| `SYNC_AUTHOR_NAME` | Author name for commits and tags | **Required** | **Required** | push only | apply/cherry-pick only | Bot name to avoid exposing internal developer names externally |
| `SYNC_AUTHOR_EMAIL` | Author email for commits and tags | **Required** | **Required** | push only | apply/cherry-pick only | Same as above |
| `EXCLUDE_PATHS` | Array of paths to exclude from replica sync | **Required** | **Required** | ― | ― | Not needed for deliver since `init` / `stage-publish` already applied exclusions |
| `PATCH_OUTPUT_DIR` | Root output directory for patch mode; each delivery creates a `sync-TIMESTAMP-PARTY/` subdirectory inside | ― | ― | patch only | ― | Defaults to `./sync-patches` if unset |

Example `EXCLUDE_PATHS` config:

```bash
EXCLUDE_PATHS=(
  "services/internal-only/"   # internal-only services
  ".internal/"                # internal config files
  "scripts/internal/"         # internal-only scripts
)
```

These are **git pathspec patterns** (`:!<pattern>` notation) — not `.gitignore` patterns.
See [B-4. Managing Excluded Paths](#b-4-managing-excluded-paths) for pattern rules.

#### `config/party/<party>.conf` — Replica Repository (github.com)

| Variable | Description | `[A] init` | `[B-1] stage` | `[B-2] deliver` | `[C] external` | Example |
|---|---|:---:|:---:|:---:|:---:|---|
| `REPLICA_REPO` | Absolute local path to the replica git clone on your machine — used by `deliver-to-replica.sh` (push mode) to run `git push` directly | ― | ― | push only | ― | `/path/to/replica-acme` |
| `REPLICA_REMOTE` | Git remote name inside `REPLICA_REPO` that points to github.com | ― | ― | push only | ― | `origin` |
| `REPLICA_BRANCH` | Branch on the replica that receives synced content | ― | ― | push only | ― | `main` |
| `REPLICA_GH_REPO` | github.com `org/repo` slug — used by `deliver-to-replica.sh` (PR mode) for `gh pr create --repo` and by `generate-party-onboarding.sh` as the default repo slug when `--repo` is not specified | ― | ― | pr mode only | notify only | `your-org/replica-acme` |

---

## [Pre-A] Installing replica-sync into the Upstream Monorepo

`generate-upstream-setup.sh` prepares the replica-sync tooling and either installs it
directly into a target monorepo (`--install-to`) or packages it into a zip for manual
distribution. Both paths use the same generated `install.sh` for consistent behavior.

### Options

| Option | Description | Default |
|---|---|---|
| `--install-to <dir>` | Install/upgrade directly into the target monorepo | — (zip mode) |
| `--with-ci-workflow` | Include `sync-replica.yml` GHE-side CI workflow | not included |
| `--output-dir <dir>` | Where to write the zip (zip mode only) | `./upstream-packages` |

### What gets installed where

`install.sh` copies files into the following locations in the target monorepo:

| Source (in package) | Destination (in monorepo) | Notes |
|---|---|---|
| `replica-sync/VERSION` | `replica-sync/VERSION` | Always overwritten |
| `replica-sync/scripts/*.sh` | `replica-sync/scripts/` | Executable; always overwritten |
| `replica-sync/config/sync.conf.example` | `replica-sync/config/` | Always overwritten |
| `replica-sync/config/party/party.conf.example` | `replica-sync/config/party/` | Always overwritten |
| `replica-sync/config/replica-bootstrap/…/pr-to-internal.yml` | `replica-sync/config/replica-bootstrap/…/` | Always overwritten |
| `replica-sync/SETUP.md` | `replica-sync/` | Always overwritten |
| `replica-sync/.gitignore-fragment` | `replica-sync/` | Always overwritten |
| `replica-sync/config/sync.conf.example` | `replica-sync/config/sync.conf` | **Created once; preserved on upgrade** |
| `.github/workflows/sync-replica.yml` | `.github/workflows/sync-replica.yml` | `--with-ci-workflow` only; always overwritten |
| — | `.gitignore` | Fragment appended only if not already present |

`sync-replica.yml` is the only file that lands outside `replica-sync/` — it goes directly
into the monorepo's `.github/workflows/` so GitHub Actions picks it up automatically.

### Path 1: Direct install / upgrade via `--install-to`

Use this when you have local access to the target monorepo (e.g. you maintain both repos).

```bash
# Fresh install
./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo

# With GHE-side CI workflow
./scripts/generate-upstream-setup.sh \
  --install-to /path/to/internal-monorepo \
  --with-ci-workflow

# Upgrade (same command — detects existing installation automatically)
./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo
```

After install, the script prints the next steps. After upgrade:
```bash
cd /path/to/internal-monorepo
git diff replica-sync/                        # review what changed
git add replica-sync/ .github/workflows/      # stage everything
git commit -m "chore: upgrade replica-sync tooling"
```

### Path 2: Zip + install.sh for remote distribution

Use this when someone else owns the target monorepo and will perform the install.

```bash
# Generate zip
./scripts/generate-upstream-setup.sh --with-ci-workflow --output-dir ./outbox
# → outbox/upstream-setup-TIMESTAMP.zip
```

**Zip contents:**
```
upstream-setup-TIMESTAMP/
├── install.sh                                      ← run this with --target
├── replica-sync/
│   ├── VERSION                                     ← version of this package
│   ├── SETUP.md                                    ← full guide
│   ├── scripts/                                    ← all sync scripts
│   ├── config/
│   │   ├── sync.conf.example
│   │   ├── party/party.conf.example
│   │   └── replica-bootstrap/.github/workflows/
│   │       └── pr-to-internal.yml                  ← CI template for external replicas
│   └── .gitignore-fragment
└── .github/workflows/
    └── sync-replica.yml                            ← (--with-ci-workflow only)
```

Send the zip to the upstream team. They run:

```bash
unzip upstream-setup-TIMESTAMP.zip
cd upstream-setup-TIMESTAMP
bash install.sh --target /path/to/internal-monorepo
```

`install.sh` handles both fresh installs and upgrades with the same command.
The `--with-ci-workflow` flag is baked in at generation time — if it was set when
the zip was created, `install.sh` will install `sync-replica.yml` automatically;
if not, it will be skipped.

### Upgrade behavior summary

| File type | Behavior on upgrade |
|---|---|
| `VERSION`, scripts, config templates, SETUP.md | Always overwritten |
| `config/sync.conf` | **Preserved** — contains local paths |
| `config/party/*.conf` | **Preserved** — contains per-party credentials |
| `.gitignore` | Appended only if fragment not already present |

#### Version display

`install.sh` reads the version from the package and from the installed `VERSION` file.
The output header and summary both show the version transition:

```
Upgrading replica-sync 1.0.0 → 1.1.0 in: /path/to/internal-monorepo
...
[  ok ] Upgraded replica-sync 1.0.0 → 1.1.0 (16 files updated, 1 preserved)

Review changes before committing:
  cd /path/to/internal-monorepo
  git diff replica-sync/
  git add replica-sync/
  git commit -m "chore: upgrade replica-sync to 1.1.0"
```

To check the currently installed version at any time:

```bash
cat replica-sync/VERSION
```

#### New config parameters after upgrade

When a new version adds a parameter to `sync.conf.example` that is absent from your
`sync.conf`, `install.sh` automatically detects it and:

1. **Prints a warning** listing the missing parameters with their example values:

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  New config parameters — action may be required                  │
  └──────────────────────────────────────────────────────────────────┘
  The following keys are in sync.conf.example but missing from your
  sync.conf. They have been appended as comments — uncomment and set
  as needed, then re-run the script that needs them.

      INTERNAL_BRANCH="main"

  Appended to: /path/to/replica-sync/config/sync.conf
  Open and review: vi /path/to/replica-sync/config/sync.conf
```

2. **Appends them as commented-out lines** to the bottom of your `sync.conf`:

```bash
# ── New parameters added by replica-sync upgrade (2026-05-07) ──────
# These parameters are in sync.conf.example but were not in your
# sync.conf. Uncomment and edit each one as needed.
# See sync.conf.example for full descriptions and defaults.
#
# INTERNAL_BRANCH="main"
#
```

To activate a new parameter, open `sync.conf`, find the appended block at the bottom,
uncomment the line, and set the value for your environment.

This check is automatic — no version bookkeeping required. Any variable added to
`sync.conf.example` in future versions will be detected on the next upgrade.

**Resulting directory structure in the upstream monorepo after installation:**

```
internal-monorepo/                     ← monorepo root
├── .github/
│   └── workflows/
│       └── sync-replica.yml           ← (--with-ci-workflow only)
├── replica-sync/                      ← all tooling lives here
│   ├── SETUP.md
│   ├── .gitignore-fragment
│   ├── scripts/
│   │   ├── setup-sync-conf.sh
│   │   ├── init-replica.sh
│   │   ├── stage-publish.sh
│   │   ├── deliver-to-replica.sh
│   │   ├── apply-external-pr.sh
│   │   ├── cherry-pick-partial.sh
│   │   ├── notify-external-pr.sh
│   │   └── generate-party-onboarding.sh
│   └── config/
│       ├── sync.conf.example
│       ├── sync.conf                  ← created manually (gitignored)
│       ├── party/
│       │   ├── party.conf.example
│       │   └── acme.conf              ← created manually per party (gitignored)
│       └── replica-bootstrap/
│           └── .github/workflows/
│               └── pr-to-internal.yml ← template deployed to external replicas
├── services/                          ← monorepo source code (unchanged)
└── .gitignore                         ← appended with .gitignore-fragment
```

Output directories created at runtime (gitignored, not committed):
```
replica-sync/sync-patches/             ← patch mode delivery output (one zip per delivery: sync-TIMESTAMP-PARTY.zip)
replica-sync/party-packages/           ← onboarding packages for 3rd parties
```

All scripts are self-contained under `replica-sync/` and are invoked from any
working directory using the `replica-sync/scripts/` prefix
(e.g. `./replica-sync/scripts/stage-publish.sh`). Scripts locate their config
via `SCRIPT_DIR/../config/` (script-relative), not the caller's working directory.
The `SETUP.md` inside the package contains the complete guide from configuration
through the full sync loop.

---

## [A] publish Branch Initialization

### Prerequisites

- `org/internal-monorepo` exists on internal GHE
- GHE accessible via SSH (see below)
- Start tag (e.g. `milestone/2024-Q1`) has been created

### A-1. SSH Authentication Setup

```bash
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

# Verify connectivity
ssh -T ghe
ssh -T github.com
```

Register the public keys to each instance.
For github.com, it is recommended to register as a Deploy Key with write-only access to the replica.

### A-2. Create publish Branch

`init-replica.sh` extracts a file tree snapshot using `git archive` (with `EXCLUDE_PATHS` applied)
and creates a PR on GHE. Review and merge the PR to initialize the `publish` branch.

```bash
./scripts/init-replica.sh milestone/2024-Q1

# With a tag message
./scripts/init-replica.sh --message "Start 3rd party collaboration" milestone/2024-Q1
```

**The `START_TAG` argument must be a tag name.** Passing a branch name will cause an error:

```
[ err ] 'main' is not a tag. Specify a tag (e.g. milestone/v1), not a branch.
```

Why branch names are rejected: branches are moving, so running the same command the next day would capture a different snapshot.
An immutable tag must be specified to definitively record "which point in time the snapshot was taken"
in the `publish/init-TIMESTAMP` tag.

What the script does:

```
1. Expand file tree at START_TAG using git archive (no commit history)
2. Filter out EXCLUDE_PATHS
3. Create publish branch with an empty base commit
4. Commit snapshot content to init/TIMESTAMP branch (author=Bot)
5. Push to GHE and create PR: init/TIMESTAMP → publish
6. Set publish/init-TIMESTAMP tag to START_TAG
```

**Re-running init-replica.sh (iterative sync.conf tuning):**

It is common to run `init-replica.sh` multiple times while refining `sync.conf` settings
(e.g. adjusting `EXCLUDE_PATHS`). The script handles this with a two-step prompt:

```
[ warn] Publish branch 'publish' already exists.
  This is normal when re-running init-replica.sh to test different sync.conf settings.
  Re-initializing will delete:
    - local and remote 'publish' branch
    - all 'publish/init-*' tags (local and remote)
    - all remote 'init/*' branches

  Re-initialize? [y/N]: y

  The following open GHE PRs target 'publish':
    #12 initial: milestone/2024-Q1

  Close these PRs automatically? [y/N]: y
[init] Closed PR #12

[init] Deleted 'publish' branch
[init] Deleted tag: publish/init-20260419-114237
[init] Deleted remote branch: init/20260419-114237
[init] Re-initializing...
```

- **First prompt** — lists all objects to be deleted and confirms
  - local and remote `publish` branch
  - all `publish/init-*` tags (local and remote)
  - all remote `init/*` branches
- **Second prompt** — shown only if open PRs exist; lists them by number and title before asking
- If you decline to close the PRs, a warning is shown that they will lose their base branch

**About git hint messages:**

The following hint may appear during execution:

```
hint: You have created a nested tag. The object referred to by your new tag is
hint: already a tag. If you meant to tag the object that it points to, use:
hint:   git tag -f publish/init-TIMESTAMP milestone/v1^{}
```

This is not an error or warning; it does not affect operation.

Why it occurs: the `publish/init-TIMESTAMP` tag points to another tag object `milestone/v1`
(tag pointing to tag = nested tag), so git advises "use `^{}` if you want to point to the commit directly".
In this case, the intent is to record "which milestone tag we started from",
so pointing to the tag object is the correct design — the hint can be ignored.

To suppress it if desired:

```bash
git config set advice.nestedTag false
```

State after execution:

```
Internal monorepo
A - B - C - D - E        (main)
                ↑
          milestone/2024-Q1
          publish/init-TIMESTAMP   ← record of snapshot source

publish: [empty] ← init/TIMESTAMP (awaiting PR review)
```

After merging the PR:

```
publish: [empty base] ─ [snapshot commit]
                                ↑ HEAD
```

### A-3. Generate Onboarding Package

Before or alongside the first delivery, generate an onboarding package and send it to the 3rd party.
The package contains a complete guide (`ONBOARDING.md`) and the CI workflow they need to install.

```bash
# Minimal
./scripts/generate-party-onboarding.sh --party acme

# With repo slug and delivery mode
./scripts/generate-party-onboarding.sh \
  --party acme \
  --repo your-org/replica-acme \
  --delivery-mode push
```

Options:

| Option | Description | Default |
|---|---|---|
| `--party <name>` | Party name (required) | — |
| `--repo <org/repo>` | github.com repo slug for clone URL in docs | `your-org/replica-<party>` |
| `--delivery-mode push\|patch\|both` | Which sync delivery section to include | `both` |
| `--output-dir <dir>` | Where to write the zip | `./party-packages` |

Output: `party-packages/<party>-onboarding-TIMESTAMP.zip`

Package contents:
```
<party>-onboarding-TIMESTAMP/
├── ONBOARDING.md                          ← complete collaboration guide
├── install.sh                             ← installs / upgrades pr-to-internal.yml
└── .github/workflows/pr-to-internal.yml  ← CI workflow to install in replica repo
```

Send the zip to the 3rd party with the following instructions:
1. Extract the zip
2. Run `bash install.sh --target /path/to/replica-clone` and follow the printed git instructions
3. Read `ONBOARDING.md` for the full collaboration guide

To upgrade the CI workflow later, generate a new package and ask the 3rd party to run
`install.sh` again — it detects the existing installation and upgrades it automatically.

### A-4. First Delivery to 3rd Party

After the publish PR is merged, run `deliver-to-replica.sh` for each 3rd party.
On first delivery, there is no `last-sync` tag, so the entire content from the first commit of `publish` is delivered.

```bash
# patch mode (default — file-based handoff)
./scripts/deliver-to-replica.sh --party acme "initial: 2024-Q1"

# push mode (direct git push)
./scripts/deliver-to-replica.sh --party acme --output push "initial: 2024-Q1"
```

After the first delivery completes, the following tags are created:

```
replica/acme/init-TIMESTAMP  ← record of first delivery to this party (immutable)
replica/acme/last-sync       ← delivery completion point (moving)
replica/acme/sync-TIMESTAMP  ← immutable record of the delivery
```

---

## [B] Milestone Sync

### Overview

Milestone sync is performed in 2 phases.

```
[Phase 1: stage-publish.sh]
  internal/main
    → squash + EXCLUDE_PATHS filter
    → GHE PR: sync/TIMESTAMP → publish
    → [internal review & approval & merge]
    → squash commit accumulated on publish

[Phase 2: deliver-to-replica.sh]
  publish
    → push (--mode pr/direct)
       or
       patch + apply.sh output
    → reflected to external/main
    → replica/<party>/last-sync tag updated to publish HEAD
```

The `publish` branch exists only on internal GHE and is never pushed externally.
It serves as the authoritative record of "what was sent externally", shared across all parties.

Each party's delivery completion position is managed independently via the `replica/<party>/last-sync` tag.

### B-1. Branch and Tag Roles

```
Internal monorepo (GHE)

main:     A - B - C - D - E - F - G
                                   ↑ INTERNAL_HEAD

publish:  P1 ── P2 ── P3
          ↑            ↑
    (START_TAG)   squash commit (Bot author)
                       ↑
              replica/acme/last-sync  ← acme delivery completion point (moving)
              replica/beta/last-sync  ← beta delivery completion point (moving, separate party)

sync/TIMESTAMP: P3 ─ (PR branch before merge)
```

| Name | Type | Role |
|---|---|---|
| `publish` | Branch | Authoritative squashed content for delivery (shared across all parties). Reviewable internally |
| `replica/<party>/last-sync` | Moving tag | Points to the last delivered commit on the `publish` branch (independent per party) |
| `publish/init-TIMESTAMP` | Immutable tag | Record of publish branch first creation (party-independent) |
| `replica/<party>/init-TIMESTAMP` | Immutable tag | Record of first delivery to each party |
| `replica/<party>/sync-TIMESTAMP` | Immutable tag | Immutable record of each delivery |

### B-2. Phase 1: Stage to publish branch (`stage-publish.sh`)

Squash the diff from `internal/<INTERNAL_BRANCH>` and create a PR to `publish` on GHE.
No `--party` argument needed — the publish branch is party-independent.

```bash
# Recommended: pin the diff to a milestone tag
./scripts/stage-publish.sh --tag milestone/v2 "sync: 2024-Q1"

# Without --tag: diff goes up to HEAD at the time of the run
./scripts/stage-publish.sh "sync: 2024-Q1"
```

**`--tag` option:** Passing `--tag <tag>` sets the upper bound of the diff to the tagged
commit rather than `HEAD`. This prevents commits added between tagging and running the
script from slipping into the PR. The tag is also shown in the PR body for traceability.

Internal flow:

```
1. Resolve diff upper bound: --tag commit (if given) or HEAD
2. Get diff between publish HEAD and upper bound, with EXCLUDE_PATHS filtered out
3. Create sync/TIMESTAMP branch from publish in a worktree
4. Apply patch and squash commit (author=Bot)
5. Push sync branch to GHE
6. Create PR on GHE: sync/TIMESTAMP → publish
   (PR body includes commit range, tag name if used, and list of internal commits)
```

Review and approve the PR, then merge to `publish`.
**This phase does not update the `replica/<party>/last-sync` tag.**

#### Changing the source branch (e.g. syncing a code-freeze snapshot)

The diff `stage-publish.sh` produces is a plain commit-range diff
(`origin/publish..<upper-bound>`); it does **not** depend on branch identity or on the two
sides sharing history. So you can change which internal branch (or snapshot) a sync is
based on — for example, to stop syncing from `dev` and instead sync a **code-frozen
snapshot** that you keep on its own branch/tag for the record — and delivery continues
normally.

**What each variable actually controls**

| | Role in `stage-publish.sh` | Effect of the source branch |
|---|---|---|
| `origin/publish` | Diff **lower** bound (always) | unchanged |
| `--tag <tag>` | Diff **upper** bound = the tagged commit | this is what selects the snapshot |
| `INTERNAL_BRANCH` (`sync.conf`) | Used **only** for the `git merge --ff-only` check, and **only when `--tag` is omitted** | irrelevant when you pass `--tag` |

**Recommended: pin with `--tag`, and you do not need to touch `INTERNAL_BRANCH`.** Because
`--tag` resolves the upper bound from the tag, `INTERNAL_BRANCH` plays no part in the diff
and the ff-only check is skipped entirely. The command is identical to a normal milestone
sync — only the tag's target changes:

```bash
cd "$INTERNAL_REPO"
git fetch origin

# Record the code freeze on its own branch + tag
git checkout -b release/2026-Q3-freeze <freeze-commit>
git push origin release/2026-Q3-freeze
git tag -a milestone/2026-Q3 -m "Q3 code freeze" <freeze-commit>
git push origin milestone/2026-Q3

# Same command/args as before — no sync.conf change needed
./replica-sync/scripts/stage-publish.sh --tag milestone/2026-Q3 "sync: 2026-Q3"
```

**Correctness condition — the new source must be a *forward* of `publish`.** The delivered
diff is `origin/publish..<new-source>`. If the new source contains everything already
synced (i.e. it builds on top of what is in `publish`), the diff is forward-only and safe.
If it was branched from a point *before* the last sync, or otherwise omits already-synced
commits, the diff will contain **reversions** and the replica would regress. Verify before
staging:

```bash
git fetch origin
git log --oneline origin/publish ^<new-source>   # empty output → new source includes all of publish (safe)
git diff --stat origin/publish..<new-source>      # eyeball the actual delivered change
```

**If you run without `--tag`** (not recommended for this case): the upper bound becomes the
`HEAD` of your local checkout, and the ff-only check runs against `origin/<INTERNAL_BRANCH>`
**without checking that branch out first**. To use branch-based (no-tag) staging on a new
source branch you must update `INTERNAL_BRANCH` in `sync.conf` *and* `git checkout` that
branch locally beforehand. Passing `--tag` avoids both requirements.

Note: `deliver-to-replica.sh` never reads `INTERNAL_BRANCH` — it works from `origin/publish`
and the party tags — so Phase 2 is unaffected by any source-branch change.

### B-3. Phase 2: Deliver to External Replica (`deliver-to-replica.sh`)

Deliver the content of the `publish` branch to the external replica.
The source is the diff from `replica/<party>/last-sync` to `publish` HEAD.
Specify the delivery method with `--output` and the application method with `--mode`.

| `--output` | `--mode` | Behavior | last-sync update |
|---|---|---|---|
| `patch` **(default)** | `pr` (default) | Output patch set and apply.sh. 3rd party creates PR | Automatic at patch generation time |
| `patch` | `direct` | Output patch set and apply.sh. 3rd party applies directly | Automatic at patch generation time |
| `push` | `pr` (default) | Push sync branch and create PR | Immediate |
| `push` | `direct` | Push directly to external `main` | Immediate |

```bash
# Output patch set — 3rd party creates PR (default)
./scripts/deliver-to-replica.sh --party acme "sync: 2024-Q1"

# Output patch set — 3rd party applies directly to main
./scripts/deliver-to-replica.sh --party acme --mode direct "sync: 2024-Q1"

# Re-generate patch without advancing sync tags (e.g. to resend lost files)
./scripts/deliver-to-replica.sh --party acme --resend "sync: 2024-Q1"

# Push as PR to the replica
./scripts/deliver-to-replica.sh --party acme --output push "sync: 2024-Q1"

# Push directly to main on the replica
./scripts/deliver-to-replica.sh --party acme --output push --mode direct "sync: 2024-Q1"
```

Files generated by `--output patch`:

```
sync-patches/
└── sync-20240401-120000-acme.zip        # one zip per delivery; send this file to the 3rd party
    ├── README.md                        # human-readable guide: package contents and apply instructions
    ├── sync-20240401-120000.patch       # diff patch (publish branch-based)
    ├── sync-20240401-120000-meta.json   # metadata (PR title, body, delivery range, etc.)
    ├── sync-20240401-120000-summary.txt # publish commit list
    └── sync-20240401-120000-apply.sh    # standalone apply script for 3rd party to run
```

The 3rd party extracts and applies the zip:

```bash
unzip sync-20240401-120000-acme.zip
cd sync-20240401-120000-acme/
bash sync-20240401-120000-apply.sh   # any branch is fine — the script switches to main automatically
```

With `--output patch`, the last-sync tag is automatically updated at patch generation time.
With `--resend`, the last-sync tag is **not** updated — the patch is regenerated from the
previous sync base (useful for resending lost files without changing the delivery state).

### B-4. Managing Excluded Paths

`EXCLUDE_PATHS` is applied only in `init-replica.sh` (initialization) and `stage-publish.sh` (Phase 1).
Since the `publish` branch is already in a clean state with exclusions applied,
`deliver-to-replica.sh` (Phase 2) does not re-apply exclusions.

> **Important — `EXCLUDE_PATHS` does not remove files already in the publish branch.**
>
> Adding a path to `EXCLUDE_PATHS` means "do not include changes to this path in
> future diffs." It does **not** delete files that were synced to the `publish`
> branch in a previous run. If a path was included in an earlier sync and you now
> want it gone, you must explicitly remove it from the `publish` branch via a
> manual cleanup commit. See [Troubleshooting — Removing a file from the publish branch](#removing-a-file-from-the-publish-branch).

```bash
EXCLUDE_PATHS=(
  "services/internal-only/"
  ".internal/"
  "scripts/internal/"
)
```

#### Pattern Rules

Entries are **git pathspec patterns** — passed to `git archive` and `git diff` as `:!<pattern>`.
These are **not** `.gitignore` patterns.

| Pattern | Effect |
|---|---|
| `services/internal-only/` | Exclude directory and all its contents (trailing `/` matches directories) |
| `.internal/` | Exclude a top-level directory |
| `scripts/internal/` | Exclude a subdirectory |
| `**/*.secret` | Glob: exclude all files with `.secret` extension anywhere in the tree |
| `docs/INTERNAL_*.md` | Glob: exclude files matching a prefix pattern in a specific directory |

**Key differences from `.gitignore`:**
- Patterns are repository-root-anchored by default
- Negation (`!` prefix) is not supported
- Comment lines (`#` prefix) are not supported — use shell comments outside the array

#### Examples

**Exclude entire directories:**
```bash
EXCLUDE_PATHS=(
  "services/internal-only/"   # all files under this directory
  ".internal/"                # top-level hidden directory
)
```

**Exclude specific files:**
```bash
EXCLUDE_PATHS=(
  "docs/INTERNAL_DESIGN.md"
  "config/secrets.yml"
)
```

**Selectively expose one file from a directory — list everything else explicitly:**

Because negation (`!`) is not supported, you cannot say "exclude this directory except
for one file." Instead, list each file to exclude individually:

```bash
# Scenario: .github/workflows/ contains several files, but only
# sync-to-wiki-main.yml should be included in the replica.
EXCLUDE_PATHS=(
  ".github/workflows/_deploy-docs.yml"
  ".github/workflows/_deploy-service.yml"
  ".github/workflows/dev-release.yml"
  ".github/workflows/sync-replica.yml"
  ".github/workflows/sync-to-wiki.yml"
  # sync-to-wiki-main.yml is NOT listed → it is included in the replica
)
```

You can use globs to reduce repetition, but be careful — globs do not automatically
cover files added in the future:

```bash
EXCLUDE_PATHS=(
  ".github/workflows/_*.yml"           # matches _deploy-docs.yml, _deploy-service.yml
  ".github/workflows/dev-*.yml"        # matches dev-release.yml
  ".github/workflows/sync-replica.yml"
  ".github/workflows/sync-to-wiki.yml" # explicit — avoids matching sync-to-wiki-main.yml
)
```

> **Tip:** When using globs in a directory where new files may be added later, prefer
> explicit listing over globs. A newly added internal workflow file would be
> accidentally included in the next sync if the glob does not cover it.

#### Generating EXCLUDE_PATHS with build-exclude-list.sh

When you want to exclude many files matching a pattern but keep specific ones,
use `build-exclude-list.sh` to generate the list automatically instead of
writing each entry by hand:

```bash
# Exclude all workflow files except sync-to-wiki-main.yml
./replica-sync/scripts/build-exclude-list.sh \
  --exclude ".github/workflows/**" \
  --include ".github/workflows/sync-to-wiki-main.yml" \
  --apply   # writes directly into sync.conf
```

The script scans `git ls-files`, applies the exclude/include patterns, and
outputs a ready-to-use `EXCLUDE_PATHS=(...)` block. Re-run it whenever new
files are added to the repo to keep the list up to date.

See [build-exclude-list.sh](scripts.md#build-exclude-listsh) for full option reference.

#### Limits on the Number of EXCLUDE_PATHS Entries

Git itself has no limit on the number of pathspec entries. The practical limit comes
from the OS argument buffer (ARG_MAX), since all entries are passed as individual
command-line arguments to `git archive` and `git diff`:

| OS | ARG_MAX |
|---|---|
| macOS | ~1 MB |
| Linux | ~2 MB |

Each entry expands to a string like `:!.github/workflows/_deploy-docs.yml` (tens of
bytes). You would need **well over 1,000 entries** before approaching the limit.

For typical projects — even those with hundreds of individually listed files — this
is not a concern. If the number of entries ever grows to that scale, the appropriate
response is to restructure the exclusions (e.g. exclude a broader directory) rather
than work around ARG_MAX.

#### Removing a Path from EXCLUDE_PATHS (exposing previously excluded files)

If a path was excluded in a previous sync (or during `init-replica.sh`) and you want
to include it in future deliveries, simply remove it from `EXCLUDE_PATHS` in `sync.conf`.

**What happens on the next `stage-publish.sh` run:**

The `publish` branch has never contained the previously excluded files.
`stage-publish.sh` diffs `publish HEAD..internal/main HEAD` with the updated
(smaller) exclusion list — so the previously excluded files appear in the diff
**as new additions**, and are included in the patch delivered to the replica.

> **Note for 3rd parties:** From the replica's perspective, these files appear
> for the first time in that sync — as if they were newly created. There is no
> indication that they existed in the internal repo before. If the sudden addition
> of a large set of files might surprise the 3rd party, notify them in advance
> that the next sync will include previously withheld content.

### B-5. Delivery Method Selection Guide

| | `push --mode pr` | `push --mode direct` | `patch --mode pr` | `patch --mode direct` |
|---|---|---|---|---|
| Internal review (publish PR) | Available in both flows | ← | ← | ← |
| 3rd party review | Available | Not available | Available | Not available |
| GHE → github.com connectivity | Required | Required | Not required | Not required |
| 3rd party needs gh CLI | Not required | Not required | Required | Not required |
| Best for | High-collaboration | Fast delivery | No connectivity + review | No connectivity + direct apply |

---

## [C] External PR Incorporation

### Overview

A 3rd party creates a `feature → main` PR on the github.com replica.
Review this PR internally and incorporate only what is needed into the internal repo on GHE.
Do not merge directly into the external replica's `main`.

```
github.com (replica)                 GHE (internal)
─────────────────────                ──────────────
3rd party creates PR
  feature/foo → main
        │
        │ CI generates patch and meta
        │ (uploaded as Artifact)
        │
        │ Hand files to internal team
        │                            run apply-external-pr.sh
        │                              → external/<party>-pr-N branch
        │                              → auto-create internal PR
        │                              → internal review
        │
        │                            acceptance decision
        │                              → cherry-pick into main
        │
        │                            notify result via notify-external-pr.sh
        ▼
Close external PR (do not merge)
        ↓
Changes reflected on next milestone sync
```

### C-1. External PR Diff Generation (`pr-to-internal.yml`)

GitHub Actions on the github.com replica side.
Saves patch and meta as Artifacts when a 3rd party creates or updates a PR targeting `main`.
Internal team members download the Artifact and pass it to the apply script.

#### Trigger Design: `pull_request_target`

With the `pull_request` event, `GITHUB_TOKEN` does not have access to the PR API,
causing `gh pr diff` / `gh pr view` to return HTTP 403.
Therefore `pull_request_target` is used.

| Item | `pull_request` | `pull_request_target` |
|---|---|---|
| Execution context | PR head code | Base repository (`main`) code |
| `GITHUB_TOKEN` PR API access | Not available (HTTP 403) | Available |
| Security risk | Low | High if PR head code is checked out |

**This workflow does not check out the PR head** (diff is fetched via API),
so `pull_request_target` can be used safely.

#### Skipping `sync/*` Branches

The delivery PR head branch created by `deliver-to-replica.sh` follows the `sync/TIMESTAMP` format.
This is an internal sync delivery, not a 3rd party development change, so it is skipped via a job-level `if` condition.

```yaml
if: ${{ !startsWith(github.head_ref, 'sync/') }}
```

The workflow is triggered, but the job status becomes "skipped".

#### Generated Artifact Contents

| File | Contents |
|---|---|
| `pr.patch` | PR diff (applicable via `git apply`) |
| `pr-meta.json` | PR number, title, body, author, URL, head SHA |

Artifact name: `pr-{PR number}-{head SHA}` (retention: 30 days)

#### Behavior on Multiple Triggers (`synchronize` event)

The trigger conditions for `pull_request_target` are `opened` and `synchronize`.
Each time a 3rd party pushes additional commits to an open PR branch,
a `synchronize` event fires and the workflow re-runs.

In this case:
- A new Artifact is generated with the name `pr-{PR number}-{new head SHA}`
- The old Artifact (with the previous head SHA) remains
- Internal team members need only use **the Artifact corresponding to the latest head SHA**

This allows internal teams to always work with the latest diff even when
3rd parties modify code during PR review.

#### PR Comment

An automatic comment is posted on the PR when the workflow completes, notifying the 3rd party of forwarding to the internal team.
If there are multiple pushes to the PR, a comment is added each time.

### C-2. Applying to Internal Repo (`apply-external-pr.sh`)

```bash
./apply-external-pr.sh --party acme --patch pr.patch --meta pr-meta.json
```

`--party` is optional (omitting it uses `3rdparty` as the branch name prefix).

Internal processing flow:

```
1. Read PR info from meta.json
2. Update internal repo (git fetch + merge --ff-only)
3. Create external/<party>-pr-{N} branch
   (On re-submission of same PR: update existing branch with --force-with-lease)
4. Apply patch with git apply --3way
   On failure: display conflict locations and exit (prompt for manual resolution)
5. Commit with author=Bot
   Record original PR URL and external author in commit message
6. Push to GHE (--force-with-lease)
7. Create internal PR (label: external-contribution)
   Skip creation if PR already exists (already updated via push)
```

### C-3. Partial Incorporation of Changes (`cherry-pick-partial.sh`)

To accept the entire external PR:

```bash
git checkout main
git cherry-pick external/acme-pr-123
```

To accept changes only for specific paths:

```bash
git checkout main
git checkout external/acme-pr-123 -- \
  services/api/src/Foo.kt \
  services/api/src/Bar.kt
git commit -m "external(partial): accept only FooBar changes"
```

To apply from a patch file with path filtering:

```bash
./cherry-pick-partial.sh \
  --patch pr-123.patch \
  --meta  pr-123-meta.json \
  --paths "services/api/" "services/common/" \
  --message "Accept API changes only"
```

### C-4. Acceptance Notification (`notify-external-pr.sh`)

Notify the external PR of the acceptance decision via comment.
Two output modes are available depending on the delivery method.

#### push mode (default)

Run `gh pr comment` directly from internal. Requires access to `REPLICA_GH_REPO`.

```bash
# Fully accepted
./scripts/notify-external-pr.sh --party acme --meta pr-123-meta.json --status accepted

# Partially accepted
./scripts/notify-external-pr.sh --party acme --meta pr-123-meta.json --status partial

# Rejected
./scripts/notify-external-pr.sh --party acme --meta pr-123-meta.json \
  --status rejected \
  --reason "Does not align with design direction"
```

#### patch mode (when direct access to the replica repository is not available)

Generate a notification package (script + meta) and send it to the 3rd party.
The 3rd party runs it on their own machine to post a comment on the PR.

```bash
./scripts/notify-external-pr.sh --party galaxy --meta pr-123-meta.json \
  --status accepted \
  --output patch
```

Generated files:

| File | Contents |
|---|---|
| `notify-TIMESTAMP-meta.json` | PR number, comment body, close flag, repository name |
| `notify-TIMESTAMP.sh` | Standalone script for the 3rd party to run |

Command for the 3rd party to run (requires `gh` CLI and `jq`):

```bash
./notify-TIMESTAMP.sh
```

The output directory can be configured via `NOTIFY_OUTPUT_DIR` in `sync.conf` (default: `./sync-patches`).

#### Common Behavior

For `rejected`, the external PR is automatically closed.
For `accepted` / `partial`, the external PR remains open until the next milestone sync, then is manually closed after sync.

### C-5. External PR State Transitions

```
External PR state     Internal action
────────────────      ──────────────────────────────────────────
opened              → run apply-external-pr.sh
                      internal PR (external/<party>-pr-N) is created

synchronize         → re-download Artifact and re-run
(3rd party updates)   overwrite existing branch with --force-with-lease

During internal      → determine acceptance scope
PR review
  → accept all      → cherry-pick
  → accept partial  → cherry-pick-partial.sh
  → reject          → close internal PR

After acceptance     → notify-external-pr.sh --status accepted
                      reflected to external main on next milestone sync
                      close external PR after sync (do not merge)

After rejection      → notify-external-pr.sh --status rejected
                      external PR is closed
```

---

## Tag Management Summary

All tags are kept on the `internal-monorepo` side in the internal GHE.
All tags are created as annotated tags (`git tag -a`), recording metadata such as party, output, and timestamp in the message.

| Tag Name | Type | Created by | Role |
|---|---|---|---|
| `publish/init-TIMESTAMP` | Immutable | `init-replica.sh` | Record of publish branch first creation (party-independent) |
| `replica/<party>/init-TIMESTAMP` | Immutable | `deliver-to-replica.sh` (on first delivery) | Record of first delivery to each party |
| `replica/<party>/last-sync` | Moving (overwritten with `-f`) | `deliver-to-replica.sh` on delivery complete | Points to last delivered `publish` HEAD (independent per party) |
| `replica/<party>/sync-TIMESTAMP` | Immutable | `deliver-to-replica.sh` on delivery complete | Immutable record of each delivery |
| `milestone/YYYY-QN` | Immutable | Manual | Milestone anchor. Also used as `START_TAG` for init |

Example metadata recorded in a tag (`git show replica/acme/last-sync`):

```
tag replica/acme/last-sync
Tagger: Platform Sync Bot <sync-bot@your-company.com>
Date:   Mon Apr 1 12:00:00 2024 +0900

party: acme
output: push
mode: pr
commit_msg: sync: 2024-Q1
publish_head: a1b2c3d4...
timestamp: 20240401-120000
```

---

## CI Automation (Optional)

Of the 2-phase structure, Phase 1 (`stage-publish.sh`) can be triggered automatically by milestone tags.
Phase 2 (`deliver-to-replica.sh`) can be triggered by merging the publish PR, or run manually.

### Phase 1 CI (milestone tag → GHE PR creation)

```yaml
# .github/workflows/sync-replica.yml (GHE side)
on:
  push:
    tags:
      - 'milestone/*'   # triggered by milestone/2024-Q1

jobs:
  stage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GHE_TOKEN }}

      - name: Stage publish PR
        env:
          GH_TOKEN: ${{ secrets.GHE_TOKEN }}
        run: |
          ./scripts/stage-publish.sh \
            "sync: ${{ github.ref_name }}"
```

### Phase 2 CI (publish PR merge → deliver to external replica)

Since the publish branch is shared across all parties, the target party is identified by PR labels.

```yaml
# .github/workflows/deliver-replica.yml (GHE side)
on:
  pull_request:
    types: [closed]
    branches:
      - 'publish'   # triggered by merge to publish

jobs:
  deliver:
    if: github.event.pull_request.merged == true
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GHE_TOKEN }}

      - name: Setup github.com Deploy Key
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.GITHUB_COM_DEPLOY_KEY }}" \
            > ~/.ssh/id_ed25519_github
          chmod 600 ~/.ssh/id_ed25519_github
          cat >> ~/.ssh/config << EOF
          Host github.com
            HostName github.com
            User git
            IdentityFile ~/.ssh/id_ed25519_github
          EOF

      - name: Determine party from PR labels
        id: party
        run: |
          # Assumes labels in "party:acme" format are applied to the PR
          PARTY=$(echo '${{ toJSON(github.event.pull_request.labels) }}' \
            | jq -r '.[] | select(.name | startswith("party:")) | .name | ltrimstr("party:")')
          [[ -n "$PARTY" ]] || { echo "No party: label found on PR"; exit 1; }
          echo "name=$PARTY" >> "$GITHUB_OUTPUT"

      - name: Clone replica
        run: git clone "${{ secrets.REPLICA_CLONE_URL }}" /tmp/replica

      - name: Deliver to replica
        env:
          GH_TOKEN: ${{ secrets.GITHUB_COM_TOKEN }}
        run: |
          ./scripts/deliver-to-replica.sh \
            --party "${{ steps.party.outputs.name }}" \
            "${{ github.event.pull_request.title }}"
```

---

## Operations Checklists

### publish Branch Initialization

- [ ] Generate Bot SSH keys and register them on GHE and github.com
- [ ] Configure `~/.ssh/config`
- [ ] Create start tag `milestone/YYYY-QN` in internal repo
- [ ] Configure `config/sync.conf` (verify `EXCLUDE_PATHS`)
- [ ] Run `init-replica.sh milestone/YYYY-QN`
- [ ] Review, approve, and merge the GHE PR (init/... → publish)

### Adding a 3rd Party (First Delivery)

- [ ] Create `config/party/<party>.conf`
- [ ] Create an empty replica repo on github.com (for push mode)
- [ ] Generate and send onboarding package to 3rd party (see below)
- [ ] Run `deliver-to-replica.sh --party <name> "initial: YYYY-QN"`
- [ ] Configure Branch Protection or Ruleset on replica `main` (see below)
- [ ] Send invitation to 3rd party

#### Replica `main` Branch Protection

Settings to prevent 3rd parties from pushing directly to `main` or merging PRs.
Two methods are available.

---

##### Method 1: Branch Protection Rules (simple)

Configure in the GitHub repository under `Settings` → `Branches` → `Add branch protection rule` targeting `main`.

| Setting | Recommended value | Purpose |
|---|---|---|
| Require a pull request before merging | ✅ On | Prevent direct push |
| Required number of approvals | 2 or more (a value that can't be satisfied) | Make merging effectively impossible |
| Do not allow bypassing the above settings | ✅ On | Admins must also follow the rules |

**Limitation**: Branch Protection Rules cannot differentiate by branch name pattern,
so the same rules apply to `sync/*` branches (delivery PRs created by `deliver-to-replica.sh`).
Since delivery PRs are pushed by Bot, either add the Bot account to the `Bypass list`,
or use Method 2 Rulesets.

---

##### Method 2: Rulesets (recommended — more precise)

Configure in the GitHub repository under `Settings` → `Rules` → `Rulesets` → `New branch ruleset`.

**Ruleset 1: Block direct push to `main`**

| Item | Value |
|---|---|
| Name | `protect-main` |
| Enforcement | Active |
| Target branches | `main` |
| Restrict creations | ✅ |
| Restrict deletions | ✅ |
| Require a pull request before merging | ✅, required approvals: 2 or more |
| Block force pushes | ✅ |
| Bypass list | Add Bot account (the GitHub user used by `deliver-to-replica.sh`) |

**Ruleset 2: Allow merging of `sync/*` PRs (can be omitted if Bypass is unnecessary)**

Adding the Bot account to the Ruleset's `Bypass list` allows
`deliver-to-replica.sh` to merge `sync/*` → `main` via the Bot.
3rd party users cannot push directly to `main` or merge PRs.

**Advantages of Rulesets**:
- Fine-grained control by branch pattern and actor (user/team)
- Multiple Rulesets can be combined
- Organization-level bulk application is possible (Organization Rulesets)

### Milestone Sync

**Phase 1 (stage)**
- [ ] Create `milestone/YYYY-QN` tag in internal repo
- [ ] Run `stage-publish.sh "sync: YYYY-QN"`
- [ ] Review, approve, and merge the GHE PR (sync/... → publish)

**Phase 2 (deliver)**
- [ ] Run `deliver-to-replica.sh --party <name>` (repeat for each 3rd party)
- [ ] For `patch` (default): send `sync-TIMESTAMP-PARTY.zip` to 3rd party; tags updated automatically
- [ ] For `patch --resend`: re-send lost patch files; tags **not** updated
- [ ] For `--output push --mode pr`: 3rd party reviews and merges sync PR
- [ ] For `--output push --mode direct`: complete on push

### Pre-flight Verification (before running `stage-publish.sh` / `deliver-to-replica.sh`)

Both scripts `cd` into `INTERNAL_REPO` and read the publish branch from the
**remote-tracking ref** `origin/publish` (each script runs its own `git fetch` first),
**not** from your working tree or local `publish` branch. Confirming a few things up front
prevents the most common failure modes: wrong diff boundary, full re-send, and applying on
the wrong filesystem.

**Where to run**

| Script | Reads | Which clone to run in |
|---|---|---|
| `stage-publish.sh` | lower bound `origin/publish`; upper bound = your local branch (or `--tag`) | Any clone whose `origin` is GHE and whose branch/tag is the snapshot to ship. On macOS with case-only renames, point the worktree at a case-sensitive volume via `STAGE_TMPDIR` (see Troubleshooting / Incident History). |
| `deliver-to-replica.sh` | base = local tag `replica/<party>/last-sync`; target = `origin/publish` | The **persistent clone that holds the party's `replica/<party>/last-sync` tag**. These tags are **local-only (never pushed)**, so a subsequent delivery run in a different/throwaway clone would be treated as a first delivery and re-send the full snapshot. |

**Before Phase 1 — `stage-publish.sh`**

```bash
cd "$INTERNAL_REPO"
git checkout <internal-branch>                 # e.g. dev
git fetch origin
git pull --ff-only origin <internal-branch>    # advance the branch you will tag (upper bound)
git rev-parse origin/publish                    # lower bound exists
git log --oneline -3                            # HEAD is the snapshot you intend to publish
```

- [ ] On the branch/tag representing the snapshot to publish, and it is up to date
- [ ] `origin/publish` is present after fetch (diff lower bound)
- [ ] Passing `--tag <milestone>` to pin the upper bound (recommended)
- [ ] macOS + case-only renames only: `export STAGE_TMPDIR=<case-sensitive volume>`

**Before Phase 2 — `deliver-to-replica.sh`**

```bash
cd "$INTERNAL_REPO"                             # the persistent delivery clone
git fetch origin
git log --oneline origin/publish -3            # the merged milestone snapshot is present
git show replica/<party>/last-sync | head -3   # previous delivery position exists (subsequent delivery)
```

- [ ] The Phase 1 PR (`sync/... → publish`) is **merged on GHE** (otherwise `origin/publish` lacks the snapshot)
- [ ] Running in the clone that owns `replica/<party>/last-sync` (tags are local-only)
- [ ] `origin/publish` includes the new snapshot after fetch
- [ ] Mode chosen: `patch` (no local checkout/apply → no case-sensitivity issue on your machine) vs `push` (applies to `REPLICA_REPO`; needs a case-sensitive FS if the diff has case-only renames)

> **`git pull` is not required** in either phase. Each script runs its own `git fetch` and
> uses `origin/publish` (a remote-tracking ref), so the local working tree / local `publish`
> branch state does not affect the result. What matters is that `git fetch` can reach the
> remote and that the required tags exist **locally** in `INTERNAL_REPO`.

### External PR Incorporation

- [ ] Download Artifact (patch + meta) from the PR on github.com
- [ ] Run `apply-external-pr.sh`
- [ ] Review internal PR
- [ ] Determine acceptance scope and run `cherry-pick` or `cherry-pick-partial.sh`
- [ ] Notify external PR of result via `notify-external-pr.sh`
- [ ] For accepted: close external PR after next milestone sync
- [ ] For rejected: external PR is already auto-closed

---

## Filesystem Case-Sensitivity (Operational Assumption)

The sync tooling applies patches into a working tree. On a **case-insensitive**
filesystem, a patch that carries a **case-only rename** (`Foo/` → `foo/`, or two paths
that differ only in case) **cannot be applied** — the filesystem cannot hold both casings
at once. This is a silent assumption that is easy to miss, so it is documented here in one
place.

### Which filesystems are case-sensitive?

| Platform / filesystem | Default | Notes |
|---|---|---|
| **macOS** (APFS, and older HFS+) | **case-INsensitive**, case-preserving | The default for the boot/home volume. `ls`/Finder show the exact case you typed (case-preserving), which makes it *look* case-sensitive, but `MyFile` and `myfile` are the same file. Apple discourages case-sensitive boot volumes for app compatibility. |
| **Linux** (ext4, xfs, btrfs, …) | case-sensitive | This is why the Linux CI runners are unaffected. |
| **Windows** (NTFS) | case-insensitive, case-preserving | Same class as macOS. |

Check any directory:

```bash
# git's own assumption
git config core.ignorecase          # true → git treats the FS as case-insensitive

# functional proof (run inside the directory in question)
d=$(mktemp -d); ( cd "$d"; : > Aa; : > aA; ls | wc -l )   # 1 = case-insensitive, 2 = case-sensitive

# a specific volume's personality (macOS)
diskutil info /Volumes/<name> | grep -i Personality        # "APFS (Case-sensitive)" when sensitive
```

### Where case-sensitivity actually matters

Only the step that **checks out files and applies a patch** is affected — and only when the
diff contains a case-only rename. Pure `git diff` / object operations are always safe.

| Operation | Applies to a working tree? | Needs a case-sensitive FS? |
|---|---|---|
| `stage-publish.sh` | Yes — a temporary **worktree** (`git apply --3way`) | Only the **worktree**. Point it at a case-sensitive volume via `STAGE_TMPDIR`; the internal repo itself can stay on the normal volume. The built-in guard aborts early if a collision is detected on a case-insensitive FS. |
| `deliver-to-replica.sh` **patch mode** (default) | No — only `git diff … > patch.zip` | **No.** Nothing is checked out on your machine. |
| `deliver-to-replica.sh` **push mode** | Yes — applies to `REPLICA_REPO` | The **replica clone** must be on a case-sensitive FS (when a case-only rename is present). |
| `sync-<ts>-apply.sh` (run by the 3rd party) | Yes — applies to the replica working tree | The **replica clone** must be on a case-sensitive FS (when a case-only rename is present). |
| `init-replica.sh` | Single-snapshot extract | Normally no — a single tree has one casing per path. |

**You do NOT need to place your whole internal repo or the replica repo on a case-sensitive
volume.** Only the *apply location* matters, and only for diffs that carry a case-only
rename. Moving a live monorepo onto a case-sensitive volume can break build tools and
dependencies that assume case-insensitivity — avoid it.

### Recommended setup (macOS)

1. Keep your main repos on the normal (case-insensitive) volume.
2. Create one small **case-sensitive APFS volume** once, and make it your worktree base:

   ```bash
   diskutil apfs addVolume disk3 "Case-sensitive APFS" CaseSync   # → /Volumes/CaseSync
   ```

   Then persist `export STAGE_TMPDIR=/Volumes/CaseSync/tmp` in your shell profile. It is
   harmless when there is no collision (the worktree just lives there).
3. Prefer **patch mode** for delivery — your machine then does no checkout/apply at all.
4. When you must apply to a replica (push mode, or applying yourself), use a clone on the
   case-sensitive volume and dry-run first: `git apply --check --whitespace=nowarn <patch>`.
5. Tell 3rd parties to apply on a case-sensitive FS (or Linux) **for any sync that contains a
   case-only rename**.

### Root-cause fix (removes the requirement entirely)

The requirement only exists because a diff carries a case-only rename. Keep casing
consistent in the internal repo:

- Avoid renames that change only case. When unavoidable, do a **two-step** rename so both
  casings never appear in one diff: `Foo` → `Foo_tmp` (commit) → `foo` (commit).
- After one clean sync, `publish` converges to a single casing and subsequent diffs no
  longer carry the collision — until the next case-only rename.

See also: Troubleshooting → "patch does not apply on macOS", and the Incident History
entries for 2026-07-19 (case-only rename) and 2026-07-20 (IDE config base mismatch).

---

## Troubleshooting

### Removing a file from the publish branch

**Symptom**: A path (e.g. `replica-sync/`) that you now want to exclude is still present in
the `publish` branch even after adding it to `EXCLUDE_PATHS` and running `stage-publish.sh`.

**Why this happens**: `EXCLUDE_PATHS` tells `stage-publish.sh` "do not include changes to
this path in future diffs."  It does **not** retroactively delete anything that was already
committed to the `publish` branch in a previous run.  The path lives in the `publish` branch
history and will remain there until explicitly removed with a cleanup commit.

**Procedure**:

1. **Create a cleanup branch from `publish`**

   ```bash
   cd "$INTERNAL_REPO"
   git fetch "$INTERNAL_REMOTE"
   git checkout -b cleanup/remove-replica-sync "${INTERNAL_REMOTE}/publish"
   ```

2. **Delete the path and commit**

   ```bash
   git rm -rf replica-sync/       # replace with the path you want to remove
   git commit -m "chore: remove replica-sync/ from publish branch"
   git push "$INTERNAL_REMOTE" cleanup/remove-replica-sync
   ```

3. **Open a PR on GHE: `cleanup/...` → `publish` and merge it**

   After the PR is merged the `publish` branch no longer contains the path.

4. **Run the next delivery as usual**

   ```bash
   ./scripts/deliver-to-replica.sh --party <name> "chore: remove replica-sync/"
   ```

   The diff between the previous `replica/<party>/last-sync` tag and the new `publish` HEAD
   will include the deletion, so the path will be removed from the external replica on the
   next delivery.

> **Note**: If you need to rebuild a party's repo from scratch (e.g. the replica was
> re-initialized on GitHub), use the `--rebuild` flag instead of the normal flow.
> See [B-5. Delivery Method Selection Guide](#b-5-delivery-method-selection-guide) and
> the `--rebuild` option in [scripts.md](scripts.md).

---

### `stage-publish.sh` exits silently — no PR created, no error message

**Symptom**: `stage-publish.sh` runs to completion with no error message, but no sync
branch is pushed to GHE and no PR is created.  The last visible line of output is
`[stage] Applying patch...`.

**Why this happens**: When there are more than 50 commits in the sync range, the old
`git log ... | head -50` pipeline caused a SIGPIPE: `head` exits after reading 50 lines,
which sends SIGPIPE to `git log`, causing the pipeline to return non-zero.  With
`set -o pipefail` active, this non-zero status caused `bash` to abort the script silently
(no message is printed because the failure is at the shell level, not from the script's
own error-handling code).

**Fix (already applied in `scripts/stage-publish.sh`)**: The `| head -50` pipe was
replaced with a `-50` flag passed directly to `git log`, so the process never spawns
`head` and SIGPIPE cannot occur.

**If you hit this on an older copy of the script**, apply the fix manually:

```diff
-    git log --oneline --no-merges "${PUBLISH_HEAD}..${INTERNAL_HEAD}" \
-      -- . ${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"} | head -50
+    git log --oneline --no-merges -50 "${PUBLISH_HEAD}..${INTERNAL_HEAD}" \
+      -- . ${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"}
```

(The same change applies to both the commit-summary block and the PR-body block.)

---

### `stage-publish.sh` fails with "Not possible to fast-forward"

**Symptom**:

```
fatal: Not possible to fast-forward, aborting.
```

The script aborts immediately after printing the four `[stage]` header lines.

**Why this happens**: When called **without `--tag`**, the script runs
`git merge --ff-only origin/<INTERNAL_BRANCH>` to ensure the local branch is up to date
before using `HEAD` as the diff upper bound.  This fails when the local branch has
diverged from the remote — the most common causes are:

- `INTERNAL_REPO` in `sync.conf` points to a stale local clone (e.g. an old `.new` copy
  instead of the actively-used working directory).
- The remote branch was force-pushed and the local branch has commits that are no longer
  in the remote history.
- A teammate pushed new commits to the remote branch between the `git fetch` and the
  `git merge` (this can happen when the remote advances while the script is running).

> **Note (fix already applied)**: When `--tag` is given, `INTERNAL_HEAD` is resolved
> from the tag rather than `HEAD`, so the local branch state has no effect on the diff
> range.  The script now **skips** the `git merge --ff-only` entirely for the `--tag`
> case.  If you hit this error, always prefer passing `--tag <milestone-tag>` for
> milestone syncs.

**Diagnosis** (no-tag case):

```bash
cd "$INTERNAL_REPO"
git fetch origin
git status          # look for "have diverged" or "behind"
git log --oneline -5
git log --oneline origin/<INTERNAL_BRANCH> -5
```

**Fix**:

1. **Prefer `--tag`** — if you have a milestone tag, use it:

   ```bash
   ./scripts/stage-publish.sh --tag <milestone-tag> "<message>"
   ```

   This bypasses the ff-only check entirely.

2. **Wrong `INTERNAL_REPO` path** — update `INTERNAL_REPO` in `config/sync.conf` to
   point to the correct working directory, then re-run the script.

3. **Local branch diverged from remote** (remote was force-pushed, or local has stray
   commits) — reset after confirming there is nothing to keep:

   ```bash
   cd "$INTERNAL_REPO"
   git fetch origin
   git reset --hard origin/<INTERNAL_BRANCH>
   ```

   Then re-run `stage-publish.sh`.

---

### `stage-publish.sh` fails with "patch does not apply" on macOS (case-only renames)

**Symptom**: `stage-publish.sh` reaches `[stage] Applying patch...` and then fails with a
mix of messages like:

```
error: web/.../PageNavigationHeader/PageNavigationHeader.stories.tsx: patch does not apply
error: web/.../pageNavigationHeader/__mock.ts: does not exist in index
[ err  ] Patch apply failed. Review the errors above.
```

Note the same directory appearing under **two different casings** (`PageNavigationHeader`
vs `pageNavigationHeader`).

**Why this happens**: The internal history contains a **case-only rename** of a directory
or file (`Foo/` → `foo/`). The generated patch therefore references both casings. The
patch is applied inside a temporary worktree, and on a **case-insensitive filesystem**
(macOS default APFS/HFS+) the two casings collide — the filesystem cannot hold both
`Foo/` and `foo/` at once — so `git apply` cannot reconcile them.

**Important**: `stage-publish.sh` creates its worktree with `mktemp -d`. On macOS,
`mktemp -d` **ignores `$TMPDIR`** (it uses the per-user `/var/folders/.../T`, which is on
the case-insensitive Data volume). So `export TMPDIR=...` does **not** move the worktree.
Use the dedicated `STAGE_TMPDIR` variable instead.

> **Guard (already applied in `scripts/stage-publish.sh`)**: The script now probes the
> worktree filesystem and scans the patch for case-only collisions. If it detects one on
> a case-insensitive filesystem, it aborts early with the colliding paths and the
> `STAGE_TMPDIR` instructions below — instead of the confusing `git apply` failure.

**Fix**:

1. **Create a case-sensitive volume** (one-time, macOS):

   ```bash
   diskutil apfs addVolume disk3 "Case-sensitive APFS" CaseSync
   #   → mounts at /Volumes/CaseSync
   # Verify it really is case-sensitive:
   diskutil info /Volumes/CaseSync | grep -i Personality   # expect "APFS (Case-sensitive)"
   ```

   Replace `disk3` with your APFS container from `diskutil list`.

2. **Point the worktree at the case-sensitive volume via `STAGE_TMPDIR` and re-run**:

   ```bash
   export STAGE_TMPDIR=/Volumes/CaseSync/tmp
   ./replica-sync/scripts/stage-publish.sh --tag <milestone-tag> "<message>"
   ```

   `STAGE_TMPDIR` overrides the worktree/patch temp base (the script passes an explicit
   `mktemp` template so it is honored). The internal repo itself can stay on its normal
   volume; only the worktree needs to be case-sensitive.

**Alternative**: Run Phase 1 on a case-sensitive filesystem to begin with — the CI
workflow (`sync-replica.yml`) runs on Linux runners, which are case-sensitive, so a
milestone-tag push there is not affected by this issue.

**Longer-term**: Consider cleaning up the case-only naming inconsistency in the internal
repository so the `publish` branch converges to a single casing; after one clean sync the
collision no longer appears in subsequent diffs.

---

## Incident History

A dated record of real incidents: the symptoms seen in the logs, the root cause, and how
it was resolved. Kept for pattern-matching if a similar symptom appears again, even when
the tooling has since been hardened against it.

### 2026-07-19 — `stage-publish.sh` "patch does not apply" (case-only rename on a case-insensitive filesystem)

**Log symptoms** (during `[stage] Applying patch...`):

```
Applied patch to '.../pageNavigationHeader/PageNavigationHeader.cy.tsx' cleanly.
error: web/.../PageNavigationHeader/PageNavigationHeader.stories.tsx: patch does not apply
Performing three-way merge...
Applied patch to '.../pageNavigationHeader/PageNavigationHeader.tsx' cleanly.
error: web/.../pageNavigationHeader/__mock.ts: does not exist in index
error: cannot read the current contents of '.../pageNavigationHeader/__mock.ts'
error: web/.../pageNavigationHeader/__mock.ts: patch does not apply
...
Patch file kept for inspection: /var/folders/.../T/tmp.XXXX/stage-publish-TIMESTAMP.patch
[ err  ] Patch apply failed. Review the errors above.
```

Tell-tale sign: **the same directory appears under two casings** (`PageNavigationHeader`
and `pageNavigationHeader`). The many `Falling back to direct application...` lines are
benign (normal for newly-added files) and are not the cause.

**Root cause chain**:

1. The internal history contained a **case-only rename** of a directory
   (`PageNavigationHeader/` → `pageNavigationHeader/`).
2. `git diff origin/publish..<tag>` therefore referenced **both** casings.
3. The patch is applied inside a worktree created by `mktemp -d`. On macOS, `mktemp -d`
   **ignores `$TMPDIR`** and uses the per-user `/var/folders/.../T`, which lives on the
   **case-insensitive** Data volume.
4. A case-insensitive filesystem cannot hold `PageNavigationHeader/` and
   `pageNavigationHeader/` simultaneously, so `git apply` could not reconcile them.

**What did NOT work**:

- `export TMPDIR=<case-sensitive path>` — macOS `mktemp -d` ignores it; the worktree still
  landed in `/var/folders` (confirmed by the `Patch file kept for inspection:` path).
- Cloning the repo onto a case-sensitive volume **alone** — the worktree temp dir is chosen
  independently of the repo's location.

**Resolution (operational)**:

1. Created a case-sensitive APFS volume (`diskutil apfs addVolume ... "Case-sensitive APFS" CaseSync`).
2. Pointed the worktree at it: `export STAGE_TMPDIR=/Volumes/CaseSync/tmp`.
3. Re-ran `stage-publish.sh --tag <milestone> "<message>"`; the patch applied cleanly and
   the GHE PR was created.

**Fix landed in the tooling** (so it should not recur):

- `stage-publish.sh` now passes an explicit `mktemp` template and honors a `STAGE_TMPDIR`
  override, so the worktree can be placed on a case-sensitive volume.
- It probes the worktree filesystem and, on a case-insensitive FS, scans the patch for
  case-only collisions at every path component; if found, it **aborts up front** with the
  colliding paths and `STAGE_TMPDIR` guidance instead of the confusing `git apply` failure.
- Documented in Troubleshooting → "patch does not apply on macOS" and `docs/scripts.md`
  (`STAGE_TMPDIR`).

**Phase 2 relevance**: In `patch` mode `deliver-to-replica.sh` does not check out files, so
the operator's machine is unaffected — but the generated patch still contains the case-only
rename, so a 3rd party applying it on macOS may hit the same symptom (apply on a
case-sensitive volume or Linux). `push` mode applies to `REPLICA_REPO` locally and needs a
case-sensitive filesystem.

**Longer-term**: normalize the case-only naming in the internal repo so `publish` converges
to a single casing; after one clean sync the collision disappears from subsequent diffs.

### 2026-07-20 — delivery patch fails with "No such file or directory" (IDE config tracked in publish)

**Log symptoms** (during `git apply --check` of a delivery patch on the replica, on a
case-sensitive filesystem so the case-only-rename issue was already ruled out):

```
error: services/rule-engine/.idea/vcs.xml: No such file or directory
```

**Investigation**:

- The patch entry for the file was a **modification** (`--- a/...` and `+++ b/...`, no
  `new file`/`deleted file` line) → the `publish` branch tracks `.idea/vcs.xml` at both the
  base and the head of the delivery range.
- `git ls-files | grep 'rule-engine/.idea'` on the replica returned **nothing** → the
  replica does not have the file at all.
- It was the **only** `.idea` path in the patch and the **only** remaining `--check` error,
  so everything else applied cleanly.

**Root cause**: `services/rule-engine/.idea/vcs.xml` (JetBrains IDE config) is tracked in the
`publish` branch but absent from the replica — a **per-file base divergence**. The
underlying mistake is that an IDE settings file was carried into `publish` at all; it should
have been excluded from the sync. An incremental patch that modifies (or deletes) a file the
replica lacks cannot apply.

**Why an incremental re-deliver alone does not fix it**: If you remove `.idea/` from
`publish` and re-deliver incrementally, the new diff then contains a **deletion** of
`.idea/vcs.xml`, which also fails on the replica (deleting a file it does not have). The
per-file base divergence has to be escaped, not patched around.

**Resolution**:

1. Exclude IDE settings going forward — add glob patterns to `EXCLUDE_PATHS` in `sync.conf`:
   `**/.idea/**`, `**/*.iml`, `**/.vscode/**`.
   (`build_exclude_args` applies `:(exclude,glob)` magic to wildcard patterns so `**`
   matches across directories; plain paths keep the simple `:!` exclude.)
2. Remove the already-committed `.idea/` from the `publish` branch with a cleanup PR — see
   "Removing a file from the publish branch" above.
3. Re-deliver to the party with **`--rebuild`** (full clean snapshot via `git archive`),
   which resets the replica to an exact copy of the cleaned `publish` tree and sidesteps the
   per-file base divergence entirely.

**Prevention**: `config/sync.conf.example` now ships with the IDE exclusion patterns in
`EXCLUDE_PATHS`. When onboarding a new monorepo, confirm IDE/editor artifacts
(`.idea/`, `.vscode/`, `*.iml`) are excluded before the first `init-replica.sh`, so they
never enter `publish`.
