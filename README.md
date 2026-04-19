# replica-sync

Scripts for safely syncing an internal GitHub Enterprise monorepo to a replica on github.com.

## Features

- Internal commit history and author information never leak externally (squash + Bot author)
- 3rd parties can maintain their own branches on the replica and continue development
- Milestone-based diff sync (3 modes: PR / direct push / patch file)
- External changes can be reviewed internally and selectively incorporated

## Quick Start

```bash
# 1. Install tooling into your monorepo
./scripts/generate-upstream-setup.sh --install-to /path/to/internal-monorepo

# 2. Create config (interactive wizard)
cd /path/to/internal-monorepo
./replica-sync/scripts/setup-sync-conf.sh

# 3. Initialize publish branch (once)
./replica-sync/scripts/init-replica.sh milestone/2024-Q1

# 4. Milestone sync
./replica-sync/scripts/stage-publish.sh "sync: 2024-Q1"
# → review & merge the GHE PR, then:
./replica-sync/scripts/deliver-to-replica.sh --party acme "sync: 2024-Q1"
```

See [docs/operations.md](docs/operations.md) for the full workflow.

## Documentation

| Document | Contents |
|---|---|
| [docs/scripts.md](docs/scripts.md) | Script reference — all options and usage examples |
| [docs/operations.md](docs/operations.md) | Detailed procedures and checklists for all operations |
| [docs/architecture.md](docs/architecture.md) | System architecture and data flow |
| [docs/decisions.md](docs/decisions.md) | Architecture Decision Records (ADR) |
| [CLAUDE.md](CLAUDE.md) | Context for Claude Code |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/init-replica.sh` | [A] Initialize publish branch (first-time setup) |
| `scripts/stage-publish.sh` | [B-1] Squash internal changes and create a GHE review PR |
| `scripts/deliver-to-replica.sh` | [B-2] Deliver publish branch to the external replica |
| `scripts/apply-external-pr.sh` | [C] Apply external PR patch to internal repo |
| `scripts/cherry-pick-partial.sh` | [C] Selectively incorporate parts of an external PR |
| `scripts/notify-external-pr.sh` | [C] Post review decision to external PR |
| `scripts/generate-party-onboarding.sh` | Generate onboarding package for a 3rd party |
| `scripts/generate-upstream-setup.sh` | Generate or install replica-sync tooling into upstream monorepo |
| `scripts/setup-sync-conf.sh` | Interactive wizard to create `sync.conf` |
| `scripts/build-exclude-list.sh` | Generate `EXCLUDE_PATHS` list from exclude/include patterns |

See [docs/scripts.md](docs/scripts.md) for full option reference.

## Dependencies

- `git` 2.35 or later
- `gh` (GitHub CLI)
- `jq`
