# Architecture Decision Records

---

## ADR-001: Use `git archive` for initial replica creation

**Status**: Accepted

**Context**:
The replica shared with 3rd parties must not contain internal commit history, author information, or branch structure.

**Options considered**:
- `git clone`: Copies internal commit history as-is. Rejected.
- `git clone --depth 1`: Only the latest commit, but commit author remains. Rejected.
- `git archive | tar`: Outputs only a file tree snapshot. No history. ✅

**Decision**:
Use `git archive <START_TAG>` to extract only the file tree,
then create a new repository with `git init` and an initial commit with zero history.

---

## ADR-002: Sync as squash (1 diff = 1 commit)

**Status**: Accepted

**Context**:
If internal development granularity, branch structure, and commit messages are visible externally,
there is a risk of leaking internal development rhythm and design intent.

**Decision**:
Consolidate all diffs into a single patch with `git diff replica/last-sync..HEAD`
and apply as a single commit (squash).

---

## ADR-003: Replace commit author with Bot

**Status**: Accepted

**Context**:
Internal developer names and email addresses must not leak externally.

**Decision**:
Completely replace via `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_NAME` / `GIT_COMMITTER_EMAIL`
environment variables.

---

## ADR-004: Use a moving tag (`replica/last-sync`) to track the sync origin

**Status**: Accepted

**Context**:
We need to record "how far we synced last time".
This information could be managed in a branch, a file, or a tag,
but a tag pointing directly to a specific commit in the internal repo is the most intuitive.

**Decision**:
Advance the `replica/last-sync` tag with `git tag -f` after each sync completes.
For immutable records, additionally create a `replica/sync-YYYYMMDD` tag.

---

## ADR-005: Do not merge external PRs into the replica main

**Status**: Accepted

**Context**:
If external PRs are merged directly into the replica `main`,
conflicts with external changes become complex when updating the replica via internal sync.
We also want to prevent unreviewed changes from entering the external `main`.

**Decision**:
Bring external PRs into the internal repo as patches, review and cherry-pick internally,
then reflect them to the replica on the next milestone sync.
Close external PRs without merging.

---

## ADR-006: Support 3 modes in the sync script

**Status**: Accepted

**Context**:
- Some environments cannot guarantee network connectivity from GHE to github.com
- Some cases require 3rd party review; others require immediate delivery

**Decision**:
Support switching between 3 modes via the `--mode` option.

| Mode | Use case |
|--------|------|
| `pr` (default) | Flow where 3rd party reviews and merges |
| `direct` | Immediate delivery (internally driven) |
| `patch` | No-network environments / manual handoff flow |

---

## ADR-007: Save external PR diffs as Artifacts via github.com CI

**Status**: Accepted

**Context**:
Assuming inbound communication from GHE to github.com would not work
in environments with strict security requirements.

**Decision**:
The github.com CI saves patch + meta.json as Artifacts.
The default flow has internal team members download the Artifact and pass it to `apply-external-pr.sh` manually.
In environments where network connectivity is guaranteed, migration to remote triggering via `workflow_dispatch` is also possible.

---

## ADR-008: EXCLUDE_PATHS uses explicit enumeration — no re-inclusion support

**Status**: Accepted

**Context**:
A common need is to exclude an entire directory from the replica but include one or
two specific files within it. For example: exclude all of `.github/workflows/` except
`sync-to-wiki-main.yml`.

**Options considered**:

**Option A — Explicit enumeration (current approach):**
List each file to exclude individually. The files not listed are included by default.

```bash
EXCLUDE_PATHS=(
  ".github/workflows/_deploy-docs.yml"
  ".github/workflows/dev-release.yml"
  ".github/workflows/sync-replica.yml"
  # sync-to-wiki-main.yml is omitted → included in the replica
)
```

Drawback: requires updating the list whenever a new internal-only file is added.

**Option B — Add `INCLUDE_PATHS` for re-inclusion:**
Exclude the directory, then re-include specific files via a separate `INCLUDE_PATHS`
array. The script would apply exclusions first, then copy back the included files.

```bash
EXCLUDE_PATHS=(".github/workflows/")
INCLUDE_PATHS=(".github/workflows/sync-to-wiki-main.yml")
```

**Why Option B was rejected:**

Git pathspec (`:!<pattern>`) does not support re-inclusion after exclusion.
Once a path is matched by an exclusion pattern in `git archive` or `git diff`,
it cannot be un-excluded by adding it as a positive pathspec in the same command.
Implementing Option B would require post-processing outside of git (e.g. extracting
the archive, deleting excluded files, then copying back included files from a second
`git archive` call). This approach:
- Is significantly more complex to implement and test reliably
- Risks subtle inconsistencies between `git archive` and `git diff` processing
- Provides marginal value over explicit enumeration for typical use cases

Furthermore, `EXCLUDE_PATHS` patterns are glob-based, not regular expressions.
Negative lookahead (e.g. `(?!sync-to-wiki-main).*\.yml`) is not available.

**Decision**:
Retain Option A. Users must list each file to exclude explicitly.
This constraint is documented in `config/sync.conf.example`.

---

## Open Issues

| # | Issue | Priority |
|---|------|--------|
| 1 | Semi-automatic conflict resolution flow when `git apply --3way` fails | Medium |
| 2 | Replica isolation strategy for multiple 3rd parties (1 replica vs multiple) | High |
| 3 | Finer-grained control of excluded paths — see ADR-008 for analysis | Closed (won't fix) |
| 4 | Git version compatibility of `cherry-pick-partial.sh` `--include` pathspec | Medium |
