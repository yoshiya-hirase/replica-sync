# Replica Sync — Test Procedure Guide

This guide walks through the steps to verify replica-sync operations end-to-end using the scripts in the `test/` directory.

---

## Original Scenario

The original test scenario. Differences from the implemented spec are noted in the next section "Changes from Original Scenario".

1. Create a test repo with some test code in main branch → a script
2. Commit some code and files to make several commit histories. In this case, some files would be defined as "exclude contents" in sync.conf → would be a script
3. Create sync.conf defining "exclude contents" → could you create one that works for this test scenario
4. Create a dummy 3rd party repo → would be a script
5. Run `init-replica.sh` to create replica in `publish` branch, which is expected to make a PR on own internal repo
6. Review PR to check if commit records are squashed and "exclude contents" are excluded → I will merge PR once reviewed
7. Commit some code and files to simulate continuous development making commit histories and adding files to be excluded for "delivery" → would be a script that I can run multiple times to populate more commit histories and files as needed
8. Run `stage-publish.sh` to make a PR to update "publish branch"
9. Review PR to check → I will merge PR once reviewed
10. Create a 3rd party repo on GitHub as one of my repositories for this test. `pr-to-internal.yml` should be installed → script to do
11. (Delivery with git-push) Run `deliver-to-replica.sh` to push the current snapshot of "publish branch" to the 3rd party repo created in step 10
12. I review the content in the 3rd party repo → script to check if contents match with one on "publish branch" in own internal repo
13. I review tags for "publish branch" in own internal repo → nice if a script to show the records with gh command
14. Create another 3rd party repo on GitHub as one of my repositories for this test, which is separate from the one created in step 10. This repo will simulate "sync with files" method → the same script as step 10 with the repo name specified
14. (Delivery with files) Run `deliver-to-replica.sh` to create a set of "delivery" files
15. (On 3rd party repo) Apply the "delivery" files to the 3rd party repo created in step 14 and then I review main branch
16. I review tags for "publish branch" in own internal repo in the same way as step 13
17. (On 1st 3rd party repo) Create new development branch named "dev" branching off main branch that the published content is available → script to do this with the repo specified
18. (On 2nd 3rd party repo) Do the same thing for 2nd 3rd party → the same script to do with the repo specified
19. (On 1st 3rd party repo) Create some commits on the repo → script to do with the repo specified
20. (On 2nd 3rd party repo) Create some commits on the repo → script to do with the repo specified
21. (On 1st 3rd party repo) Create PR to main branch on the 3rd party repo → script with gh command or manual on GitHub console
22. (On 1st 3rd party repo) Check if artifact is created with `pr-to-internal.yml` on PR created
23. On own internal repo, the artifact generated in step 22 is converted to PR with `apply-external-pr.sh` and I review it
24. On own internal repo, cherry-pick of the 3rd party PR with `cherry-pick-partial.sh`
25. Create notification for external PR with `notify-external-pr.sh`

---

## Changes from Original Scenario

The following points differ from the original scenario (adjusted to match the implemented spec):

| Original scenario | Updated |
|---|---|
| Step 4 "Create dummy 3rd party repo" | Removed. 3rd party repos are created in Steps 10/14 |
| Step 5 "Create replica with `init-replica.sh`" | `init-replica.sh` only initializes the publish branch. Delivery to 3rd parties is handled by `deliver-to-replica.sh` |
| Step 14 was duplicated | Second Step 14 onward renumbered (Steps 15–25 → renumbered) |
| party.conf creation was missing after Steps 10/14 | `04-create-party-repo.sh` auto-generates party.conf |
| Artifact download step was missing between Steps 22–23 | Added as Step 22: `10-download-artifact.sh` |
| Original Step 15 "manually update last-sync tag after patch mode delivery" | Tags are now automatically advanced at patch set generation time in patch mode. Manual step removed; Steps 16–25 renumbered to 15–24 |

---

## Prerequisites

```bash
git --version    # 2.35 or later
gh --version     # GitHub CLI (authenticated)
jq --version
```

Verify GitHub CLI authentication:
```bash
gh auth status
```

---

## Test Environment Setup

```bash
# Create test config file
cp test/test.conf.example test/test.conf
$EDITOR test/test.conf  # Set GITHUB_USER and TEST_DIR

# Make scripts executable
chmod +x scripts/*.sh test/*.sh
```

---

## Test Scenario

### Phase 1: Internal Repository Setup

#### Step 1: Create Internal Repository

```bash
./test/01-setup-internal.sh
```

**What is created:**
- GitHub repo: `<GITHUB_USER>/test-internal-monorepo` (private)
- Local clone: `<TEST_DIR>/internal/`
- Initial commit structure (public files + excluded files)
- Excluded targets: `internal-only/` and `.secrets/`
- Milestone tag: `milestone/v1`

**Verification points:** The following should exist in `<TEST_DIR>/internal/`
```
services/api/         ← included in publish branch
services/common/
services/auth/
services/users/
internal-only/        ← excluded from publish branch by EXCLUDE_PATHS
.secrets/             ← same
```

#### Step 2: Generate sync.conf

```bash
./test/03-generate-sync-conf.sh
```

`config/sync.conf` is generated. Review the contents:
```bash
cat config/sync.conf
```

---

### Phase 2: Initialize publish Branch

#### Step 3: Run init-replica.sh

```bash
./scripts/init-replica.sh milestone/v1
```

**Verification points:**
- A PR is created on GHE (GitHub): `init/TIMESTAMP → publish`
- `internal-only/` and `.secrets/` are not included in the PR diff
- The PR diff is a snapshot (no commit history)

#### Step 4 (manual): Review and merge PR

Open the PR in a browser, review the contents, and merge.

```bash
# Check PR URL
gh pr list --repo <GITHUB_USER>/test-internal-monorepo \
  --json number,title,headRefName \
  --jq '.[] | select(.headRefName | startswith("init/")) | "#\(.number) \(.headRefName) — \(.title)"'
```

**Verification points:**
- `internal-only/` is not included in the `publish` branch
- The `publish` branch has exactly 1 commit (the squashed initial snapshot)

---

### Phase 3: Simulating Continuous Development

#### Step 5: Add Development Commits

```bash
# First addition (with milestone tag)
./test/02-add-commits.sh milestone/v2

# Repeat as needed (without tag)
./test/02-add-commits.sh
./test/02-add-commits.sh
```

Each run adds:
- `services/feature-N/FeatureService.kt` — included in publish branch
- `internal-only/FeatureNConfig.kt` — excluded

#### Step 6: Run stage-publish.sh

```bash
./scripts/stage-publish.sh "sync: v2"
```

**Verification points:**
- A PR is created on GHE: `sync/TIMESTAMP → publish`
- `internal-only/` changes are not included in the PR diff
- The PR body lists internal commits

#### Step 7 (manual): Review and merge PR

```bash
gh pr list --repo <GITHUB_USER>/test-internal-monorepo \
  --json number,title,headRefName \
  --jq '.[] | select(.headRefName | startswith("sync/")) | "#\(.number) \(.headRefName) — \(.title)"'
```

---

### Phase 4: Deliver to 3rd Party (push mode)

#### Step 8: Create 3rd Party Repo 1 (for push mode)

```bash
./test/04-create-party-repo.sh --party acme --repo test-replica-acme
```

**What is created:**
- GitHub repo: `<GITHUB_USER>/test-replica-acme`
- Local clone: `<TEST_DIR>/acme/`
- `config/party/acme.conf`
- `.github/workflows/pr-to-internal.yml` (for receiving external PRs)

#### Step 9: Run deliver-to-replica.sh (push mode)

```bash
./scripts/deliver-to-replica.sh --party acme "initial: v1"
```

First delivery — no `last-sync` tag exists yet → delivers the full content from the first commit of publish.

**Verification points:**
- A sync PR is created on GitHub (`--mode pr` default)
- acme repo main is updated (after PR merge)

After merging the PR:

#### Step 10: Verify Delivery

```bash
./test/05-verify-delivery.sh --party acme
```

**Expected result:**
```
[  ok  ] File lists match
[  ok  ] File contents match
[  ok  ] Excluded path absent: internal-only
[  ok  ] Excluded path absent: .secrets
```

#### Step 11: Check Tags

```bash
./test/06-show-tags.sh --party acme
```

**Verification points:**
- `replica/acme/init-TIMESTAMP` tag exists (first delivery record)
- `replica/acme/last-sync` tag points to publish HEAD
- `replica/acme/sync-TIMESTAMP` tag exists

---

### Phase 5: Deliver to 3rd Party (patch mode)

#### Step 12: Create 3rd Party Repo 2 (for patch mode)

```bash
./test/04-create-party-repo.sh --party beta --repo test-replica-beta
```

#### Step 13: Run deliver-to-replica.sh (patch mode)

```bash
./scripts/deliver-to-replica.sh --party beta --output patch "initial: v1"
```

Files are generated in the `test-patches/` directory:
```
test-patches/
├── sync-TIMESTAMP.patch
├── sync-TIMESTAMP-meta.json
├── sync-TIMESTAMP-summary.txt
└── sync-TIMESTAMP-apply.sh
```

#### Step 14: Apply Patch on 3rd Party Side

Run the generated `apply.sh` in the beta repo:

```bash
cd <TEST_DIR>/beta
bash <path-to-apply.sh>
```

For PR mode, a PR is created on GitHub. Merge it before continuing.

#### Step 15: Verify Delivery & Check Tags

Merge the galaxy repo sync PR on GitHub first (since `05-verify-delivery.sh` compares against the party repo's `main`).

```bash
./test/05-verify-delivery.sh --party galaxy
./test/06-show-tags.sh --party galaxy
```

---

### Phase 6: External PR Flow

#### Step 16: Create 3rd Party dev Branch

```bash
# Create dev branch for acme party
./test/07-setup-3rdparty-branch.sh --party acme --branch dev
```

#### Step 17: Add Development Commits on 3rd Party

```bash
./test/08-add-3rdparty-commits.sh --party acme --branch dev
```

Files added (spread across multiple paths to test cherry-pick-partial.sh):
- `services/api/ExternalFeatureN.kt` — easy to accept change
- `services/common/Utils.kt` — partially acceptable change
- `services/acme-extensions/` — party-specific change that is hard to accept

#### Step 18: Create PR from 3rd Party

```bash
./test/09-create-3rdparty-pr.sh --party acme --branch dev
```

After the PR is created, the `pr-to-internal.yml` CI runs automatically.

#### Step 19 (manual): Confirm CI Completion

```bash
gh run list --repo <GITHUB_USER>/test-replica-acme --workflow pr-to-internal.yml
```

Wait until the status shows `completed / success` (typically 1–2 minutes).

#### Step 20: Download Artifact

```bash
./test/10-download-artifact.sh --party acme --pr <PR_NUMBER>
```

`pr.patch` and `pr-meta.json` are saved to `test-artifacts/acme/pr-<N>/`.

#### Step 21: Create PR in Internal Repository

```bash
./scripts/apply-external-pr.sh \
  --party acme \
  --patch test-artifacts/acme/pr-<N>/pr.patch \
  --meta  test-artifacts/acme/pr-<N>/pr-meta.json
```

**Verification points:**
- `external/acme-pr-N` branch is created in the internal repo
- An internal PR is created on GHE (GitHub)
- The external PR URL and external author are recorded in the PR

#### Step 22 (manual): Review Internal PR

Review the internal PR and decide which paths to accept.

#### Step 23: Partial Acceptance with cherry-pick-partial.sh

```bash
cd <TEST_DIR>/internal
git checkout main

# Example: accept only services/api/
./scripts/cherry-pick-partial.sh \
  --patch test-artifacts/acme/pr-<N>/pr.patch \
  --meta  test-artifacts/acme/pr-<N>/pr-meta.json \
  --paths "services/api/" \
  --message "Accept acme API feature only"
```

**Verification points:**
- Only `services/api/ExternalFeatureN.kt` is incorporated into main
- `services/acme-extensions/` is not included

#### Step 24: Notify External PR

**push mode (acme: party using push sync):**

```bash
# Partially accepted
./scripts/notify-external-pr.sh \
  --party acme \
  --meta  test-artifacts/acme/pr-<N>/pr-meta.json \
  --status partial

# Rejected
./scripts/notify-external-pr.sh \
  --party acme \
  --meta  test-artifacts/acme/pr-<N>/pr-meta.json \
  --status rejected \
  --reason "acme-extensions does not fit the design direction"
```

**patch mode (galaxy: party using patch sync):**

```bash
./scripts/notify-external-pr.sh \
  --party galaxy \
  --meta  test-artifacts/galaxy/pr-<N>/pr-meta.json \
  --status accepted \
  --output patch
```

`notify-TIMESTAMP.sh` and `notify-TIMESTAMP-meta.json` are generated in `sync-patches/`.
Send these 2 files to galaxy and have them run `./notify-TIMESTAMP.sh`.

**Verification points:**
- push mode: comment is posted directly on the external PR
- patch mode: notification package is generated / running it on the 3rd party side posts the comment
- For `rejected`: external PR is automatically closed

---

## Post-Test Cleanup

```bash
# Remove local clones
rm -rf <TEST_DIR>/internal <TEST_DIR>/acme <TEST_DIR>/beta

# Delete GitHub repos
gh repo delete <GITHUB_USER>/test-internal-monorepo --yes
gh repo delete <GITHUB_USER>/test-replica-acme --yes
gh repo delete <GITHUB_USER>/test-replica-beta --yes
```

> **If `gh repo delete` returns HTTP 403:**
> The `gh` token does not have the `delete_repo` scope. Run the following to add the scope and re-authenticate:
> ```bash
> gh auth refresh -h github.com -s delete_repo
> ```
> Complete authentication in the browser, then re-run `gh repo delete`.

```bash
# Remove generated config files
rm -f config/sync.conf
rm -f config/party/acme.conf config/party/beta.conf

# Remove test artifacts
rm -rf test-patches/ test-artifacts/
```

---

## Test Scripts Reference

| Script | Purpose | Arguments |
|---|---|---|
| `test/01-setup-internal.sh` | Create internal repository with initial commits | none |
| `test/02-add-commits.sh` | Add development commits (repeatable) | `[milestone-tag]` |
| `test/03-generate-sync-conf.sh` | Generate `config/sync.conf` | none |
| `test/04-create-party-repo.sh` | Create 3rd party repo and generate party.conf | `--party <name> --repo <repo-name>` |
| `test/05-verify-delivery.sh` | Verify delivery contents | `--party <name>` |
| `test/06-show-tags.sh` | Display tag list | `[--party <name>]` |
| `test/07-setup-3rdparty-branch.sh` | Create 3rd party dev branch | `--party <name> [--branch <name>]` |
| `test/08-add-3rdparty-commits.sh` | Add 3rd party commits | `--party <name> [--branch <name>]` |
| `test/09-create-3rdparty-pr.sh` | Create 3rd party PR | `--party <name> [--branch <name>]` |
| `test/10-download-artifact.sh` | Download CI artifact | `--party <name> --pr <number>` |
