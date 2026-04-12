# replica-sync

Scripts for safely syncing an internal GitHub Enterprise monorepo to a replica on github.com.

## Features

- Internal commit history and author information never leak externally (squash + Bot author)
- 3rd parties can maintain their own branches on the replica and continue development
- Milestone-based diff sync (3 modes: PR / direct push / patch file)
- External changes can be reviewed internally and selectively incorporated

## Quick Start

```bash
# 1. Prepare the config file
cp config/sync.conf.example config/sync.conf
$EDITOR config/sync.conf

# 2. Make scripts executable
chmod +x scripts/*.sh

# 3. Initialize replica (once only)
./scripts/init-replica.sh

# 4. Milestone sync
./scripts/sync-to-replica.sh "sync: 2024-Q1"
```

## Documentation

| Document | Contents |
|---|---|
| [docs/operations.md](docs/operations.md) | Detailed procedures and checklists for all operations |
| [docs/architecture.md](docs/architecture.md) | System architecture and data flow |
| [docs/decisions.md](docs/decisions.md) | Architecture Decision Records (ADR) |
| [CLAUDE.md](CLAUDE.md) | Context for Claude Code |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/init-replica.sh` | Initialize replica (first-time setup) |
| `scripts/sync-to-replica.sh` | Milestone sync |
| `scripts/apply-external-pr.sh` | Apply external PR to internal repo |
| `scripts/cherry-pick-partial.sh` | Selectively incorporate external PR changes |
| `scripts/notify-external-pr.sh` | Notify external PR of acceptance decision |
| `scripts/generate-party-onboarding.sh` | Generate onboarding package for a 3rd party |
| `scripts/generate-upstream-setup.sh` | Generate setup package for the upstream monorepo |

## Dependencies

- `git` 2.35 or later
- `gh` (GitHub CLI)
- `jq`
