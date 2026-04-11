# Claude Code Handover Document

This file provides context for Claude Code to understand the project.

---

## Project Purpose

A system for safely syncing a Kotlin-based monorepo on an internal GitHub Enterprise (GHE)
to a replica monorepo on github.com for collaboration with 3rd parties.

### Problems Solved

- Prevent internal commit history and author information from leaking externally
- Allow 3rd parties to continue development and commits on the external replica
- Reflect internal development to the external replica on a per-milestone basis
- Review external changes internally and selectively incorporate them

---

## Repository Structure

```
replica-sync/
├── CLAUDE.md                       # This file (context for Claude Code)
├── README.md                       # Project overview
├── config/
│   └── sync.conf.example           # Config file template
├── docs/
│   ├── architecture.md             # System architecture and data flow
│   ├── decisions.md                # Architecture Decision Records (ADR)
│   └── operations.md               # Operations guide (detailed procedures)
├── scripts/
│   ├── init-replica.sh             # [A] Initial replica creation
│   ├── sync-to-replica.sh          # [B] Milestone sync (3 modes)
│   ├── apply-external-pr.sh        # [C] Apply external PR to internal repo
│   ├── cherry-pick-partial.sh      # [C] Selectively incorporate external PR changes
│   └── notify-external-pr.sh       # [C] Notify external PR of acceptance decision
└── .github/
    └── workflows/
        ├── sync-replica.yml        # GHE side: milestone sync CI
        └── pr-to-internal.yml      # github.com side: external PR diff generation CI
```

---

## Three Operations

### [A] Initial Setup (run once only)

```
init-replica.sh
  └── git archive <START_TAG>       # Extract file tree only (no history)
  └── git init + commit             # Initial commit with zero history (author=Bot)
  └── git push → github.com/replica
  └── git tag replica/last-sync     # Set sync origin tag
```

### [B] Milestone Sync (run repeatedly)

```
sync-to-replica.sh [--mode pr|direct|patch] "<message>"
  └── git diff replica/last-sync..HEAD  # Diff from last sync
  └── git apply --3way              # Apply to replica
  └── squash commit (author=Bot)
  └── push / create PR / output patch  # Branch based on mode
  └── git tag -f replica/last-sync # Advance sync tag
```

The `replica/last-sync` tag is a moving pointer for the sync origin. It advances to HEAD on each sync.

### [C] External PR Incorporation (run each time an external PR arrives)

```
[github.com CI]
pr-to-internal.yml
  └── gh pr diff --patch            # Output diff as patch file
  └── upload-artifact               # Save patch + meta.json

[Run manually internally]
apply-external-pr.sh --patch --meta
  └── git apply --3way              # Apply to internal branch
  └── commit (author=Bot)
  └── gh pr create → GHE           # Auto-create internal PR

cherry-pick-partial.sh              # When partial incorporation is needed
notify-external-pr.sh --status     # Notify external PR of acceptance decision
```

---

## Key Design Decisions

### Why use `git archive` instead of `git clone`
`git clone` copies the internal commit history as-is.
`git archive` outputs only a snapshot of the file tree,
so internal history is not passed to the replica during initial setup.

### Why squash
By making "1 diff = 1 commit" per milestone,
the internal development granularity, branch structure, and commit messages are not visible externally.

### Why not merge external PRs into the replica main
To maintain the principle that the replica's `main` is updated only by internal sync.
External changes must go through internal review and cherry-pick before being incorporated into the internal repo,
then reflected to the replica on the next milestone sync.

### Why replace the author with Bot
To prevent internal developer names and email addresses from leaking externally.
Completely replaced via `GIT_AUTHOR_*` / `GIT_COMMITTER_*` environment variables.

---

## Config File

All scripts operate by `source`-ing `config/sync.conf`.
Copy `config/sync.conf.example` and edit it for your environment.

```bash
cp config/sync.conf.example config/sync.conf
# sync.conf is .gitignored (contains paths and credentials)
```

---

## Known Issues / Future Considerations

- Semi-automatic conflict resolution flow for `git apply --3way` conflicts is not yet implemented
- Replica isolation strategy for multiple 3rd parties (1 replica vs multiple replicas) is undecided
- CI automation flow for environments where GHE → github.com inbound communication is blocked assumes manual operation using `patch` mode
- `cherry-pick-partial.sh` `--include` pathspec behavior may differ across git versions
