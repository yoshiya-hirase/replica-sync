# Architecture

## System Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ GitHub Enterprise (internal)                                     │
│ github.your-company.com                                          │
│                                                                  │
│  org/internal-monorepo                                           │
│  ├── main                                                        │
│  │     └── replica/last-sync tag (sync origin)                  │
│  │     └── replica/sync-* tags (sync history, optional)         │
│  │                                                               │
│  └── external/3rdparty-pr-* branches (for incorporating         │
│                                        external PRs)            │
│                                                                  │
│  .github/workflows/sync-replica.yml                              │
│    └── triggered by milestone/* tags, runs sync-to-replica.sh   │
└────────────────────┬────────────────────────────────────────────┘
                     │
         [B] Milestone sync              [C] External PR incorporation
         squash + author=Bot             receive patch + meta
         (--mode pr/direct/patch)        apply-external-pr.sh
                     │                             ▲
                     ▼                             │
┌─────────────────────────────────────────────────────────────────┐
│ github.com (external replica)                                    │
│                                                                  │
│  your-org/replica                                                │
│  ├── main          ← updated only by internal sync              │
│  │                   (Branch Protection)                        │
│  └── 3rdparty/foo  ← 3rd party development branch               │
│          └── feature/xxx                                         │
│                  └── PR → main                                   │
│                                                                  │
│  .github/workflows/pr-to-internal.yml                            │
│    └── saves patch + meta as Artifact on PR open/update         │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow

### [B] Milestone Sync

```
Internal repo (GHE)                      Replica (github.com)
────────────────                         ──────────────────────
git diff
  replica/last-sync..HEAD
  (excluding excluded paths)
        │
        │ .patch file
        ▼
git apply --3way
        │
        │ squash commit
        │ author  = Platform Sync Bot
        │ message = "sync: milestone"
        ▼
[mode=pr]     sync/YYYYMMDD branch ──► PR → main
[mode=direct] ──────────────────────► push directly to main
[mode=patch]  output to sync-patches/  (apply manually)
        │
        ▼
git tag -f replica/last-sync HEAD
git tag    replica/sync-YYYYMMDD (optional)
```

### [C] External PR Incorporation

```
github.com                    Internal team              GHE
──────────                    ─────────────              ───
3rd party creates PR
        │
CI runs automatically
  pr-to-internal.yml
        │
Artifact generated
  pr-NNN.patch
  pr-NNN-meta.json
        │              Download Artifact
        │                      │
        │              apply-external-pr.sh
        │                --patch / --meta
        │                      │
        │              git apply --3way ──────────────► external/3rdparty-pr-NNN
        │                      │                        auto-create internal PR
        │                      │
        │              internal review & acceptance decision
        │                      │
        │              [accept all]    git cherry-pick
        │              [accept partial] cherry-pick-partial.sh
        │              [reject]        close internal PR
        │                      │
        │              notify-external-pr.sh
        │                --status accepted/partial/rejected
        ▼
Comment on external PR
[rejected] Close
[accepted] Close after next milestone sync
```

## Tag Design

| Tag Name | Location | Type | Purpose |
|--------|------|------|------|
| `replica/last-sync` | Internal GHE | Moving (overwritten with `-f`) | Origin for next diff. Advances to HEAD after sync completes |
| `replica/sync-YYYYMMDD-HHMMSS` | Internal GHE | Immutable | Record of each sync (optional) |
| `milestone/YYYY-QN` | Internal GHE | Immutable | Milestone anchor. Also used as CI trigger |

## Replica main Branch Protection

Set Branch Protection on `main` at github.com so that only the internal sync Bot can push.

```
Branch protection rules (main):
  ✓ Restrict who can push to matching branches
      → allow sync-bot only
  ✓ Require pull request reviews before merging
      → allow 3rd party to review sync PRs (optional)
```

3rd parties are prevented from pushing directly to `main`
and must create PRs from their own development branches.
