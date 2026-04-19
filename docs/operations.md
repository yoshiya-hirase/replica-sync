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

```bash
# In the replica-sync project:
./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo
# With GHE-side CI automation (milestone tag triggers stage-publish automatically):
./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo --with-ci-workflow

# In the monorepo:
cd /path/to/internal-monorepo
$EDITOR replica-sync/config/sync.conf       # set INTERNAL_REPO, GH_HOST, EXCLUDE_PATHS, etc.
git add replica-sync/ .gitignore
git commit -m "chore: add replica-sync tooling"
```

→ See [Pre-A] for detailed install and config options.

---

### Step 1 — Add a 3rd party (once per party)

```bash
# 1. Create the external replica repo on github.com (empty)

# 2. Create per-party config
cp replica-sync/config/party/party.conf.example replica-sync/config/party/acme.conf
$EDITOR replica-sync/config/party/acme.conf   # set REPLICA_REPO, REPLICA_GH_REPO, etc.

# 3. Generate and send onboarding package
./replica-sync/scripts/generate-party-onboarding.sh \
  --party acme \
  --repo your-org/replica-acme \
  --delivery-mode push   # or patch, or both
# → zip contains ONBOARDING.md, install.sh, and pr-to-internal.yml
# → 3rd party runs: bash install.sh --target /path/to/replica-acme

# 4. Set up branch protection on the external replica (github.com)
#    main branch: require PRs, only Bot can bypass
```

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
# Phase 1: Stage internal changes to publish branch
git tag -a milestone/2024-Q2 -m "Q2 milestone"
git push origin milestone/2024-Q2

./replica-sync/scripts/stage-publish.sh "sync: 2024-Q2"
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

---

## Config Files

### `config/sync.conf` (shared config)

All scripts operate by `source`-ing `config/sync.conf`.
Copy `config/sync.conf.example` and edit it for your environment.

```bash
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

`deliver-to-replica.sh` automatically `source`s `config/party/acme.conf` when `--party acme` is passed.

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
| `GH_HOST` | GHE hostname (used as `GH_HOST` for `gh` CLI) | **Required** | **Required** | ― | apply only | `github.your-company.com` |
| `GH_ORG` | GHE organization name | **Required** | **Required** | ― | apply only | `org` |
| `GH_REPO` | GHE repository name | **Required** | **Required** | ― | apply only | `internal` |

#### `config/sync.conf` — Sync Settings

| Variable | Description | `[A] init` | `[B-1] stage` | `[B-2] deliver` | `[C] external` | Notes |
|---|---|:---:|:---:|:---:|:---:|---|
| `SYNC_AUTHOR_NAME` | Author name for commits and tags | **Required** | **Required** | push only | apply/cherry-pick only | Bot name to avoid exposing internal developer names externally |
| `SYNC_AUTHOR_EMAIL` | Author email for commits and tags | **Required** | **Required** | push only | apply/cherry-pick only | Same as above |
| `EXCLUDE_PATHS` | Array of paths to exclude from replica sync | **Required** | **Required** | ― | ― | Not needed for deliver since `init` / `stage-publish` already applied exclusions |
| `PATCH_OUTPUT_DIR` | Output directory when `--output patch` | ― | ― | patch only | ― | Defaults to `./sync-patches` if unset |

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
| `REPLICA_REPO` | Local path to replica (absolute) | ― | ― | push only | ― | `/path/to/replica-acme` |
| `REPLICA_REMOTE` | Replica remote name | ― | ― | push only | ― | `origin` |
| `REPLICA_BRANCH` | Replica sync target branch | ― | ― | push only | ― | `main` |
| `REPLICA_GH_REPO` | github.com `org/repo` | ― | ― | push + pr mode only | notify only | `your-org/replica-acme` |

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
│   ├── SETUP.md                                    ← full guide
│   ├── scripts/                                    ← all 7 sync scripts
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
| Scripts, config templates, SETUP.md | Always overwritten |
| `config/sync.conf` | **Preserved** — contains local paths |
| `config/party/*.conf` | **Preserved** — contains per-party credentials |
| `.gitignore` | Appended only if fragment not already present |

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
replica-sync/sync-patches/             ← patch mode delivery output
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
# push mode (direct git push)
./scripts/deliver-to-replica.sh --party acme "initial: 2024-Q1"

# patch mode (file-based handoff)
./scripts/deliver-to-replica.sh --party acme --output patch "initial: 2024-Q1"
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

Squash the diff from `internal/main` and create a PR to `publish` on GHE.
No `--party` argument needed — the publish branch is party-independent.

```bash
./scripts/stage-publish.sh "sync: 2024-Q1"
```

Internal flow:

```
1. Get diff between publish HEAD and internal/main HEAD
2. Generate patch with EXCLUDE_PATHS filtered out
3. Create sync/TIMESTAMP branch from publish in a worktree
4. Apply patch and squash commit (author=Bot)
5. Push sync branch to GHE
6. Create PR on GHE: sync/TIMESTAMP → publish
   (PR body includes list of internal commits)
```

Review and approve the PR, then merge to `publish`.
**This phase does not update the `replica/<party>/last-sync` tag.**

### B-3. Phase 2: Deliver to External Replica (`deliver-to-replica.sh`)

Deliver the content of the `publish` branch to the external replica.
The source is the diff from `replica/<party>/last-sync` to `publish` HEAD.
Specify the delivery method with `--output` and the application method with `--mode`.

| `--output` | `--mode` | Behavior | last-sync update |
|---|---|---|---|
| `push` (default) | `pr` (default) | Push sync branch and create PR | Immediate |
| `push` | `direct` | Push directly to external `main` | Immediate |
| `patch` | `pr` (default) | Output patch set and apply.sh. 3rd party creates PR | Automatic at patch generation time |
| `patch` | `direct` | Output patch set and apply.sh. 3rd party applies directly | Automatic at patch generation time |

```bash
# Push as PR (default)
./scripts/deliver-to-replica.sh --party acme "sync: 2024-Q1"

# Push directly to main
./scripts/deliver-to-replica.sh --party acme --mode direct "sync: 2024-Q1"

# Output patch set (3rd party creates PR)
./scripts/deliver-to-replica.sh --party acme --output patch "sync: 2024-Q1"

# Output patch set (3rd party applies directly to main)
./scripts/deliver-to-replica.sh --party acme --output patch --mode direct "sync: 2024-Q1"
```

Files generated by `--output patch`:

```
sync-patches/
├── sync-20240401-120000.patch       # diff patch (publish branch-based)
├── sync-20240401-120000-meta.json   # metadata (PR title, body, delivery range, etc.)
├── sync-20240401-120000-summary.txt # publish commit list
└── sync-20240401-120000-apply.sh    # standalone apply script for 3rd party to run
```

With `--output patch`, the last-sync tag is automatically updated at patch generation time.

### B-4. Managing Excluded Paths

`EXCLUDE_PATHS` is applied only in `init-replica.sh` (initialization) and `stage-publish.sh` (Phase 1).
Since the `publish` branch is already in a clean state with exclusions applied,
`deliver-to-replica.sh` (Phase 2) does not re-apply exclusions.

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
- [ ] For `--output push --mode pr`: 3rd party reviews and merges sync PR
- [ ] For `--output push --mode direct`: complete on push
- [ ] For `--output patch`: send patch / meta.json / apply.sh to 3rd party
- [ ] For `--output patch`: tags are automatically updated at patch generation time

### External PR Incorporation

- [ ] Download Artifact (patch + meta) from the PR on github.com
- [ ] Run `apply-external-pr.sh`
- [ ] Review internal PR
- [ ] Determine acceptance scope and run `cherry-pick` or `cherry-pick-partial.sh`
- [ ] Notify external PR of result via `notify-external-pr.sh`
- [ ] For accepted: close external PR after next milestone sync
- [ ] For rejected: external PR is already auto-closed
