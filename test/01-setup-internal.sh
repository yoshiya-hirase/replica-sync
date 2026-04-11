#!/usr/bin/env bash
# 01-setup-internal.sh
#
# Creates the test internal repository on GitHub and populates it with
# initial commits. Run once at the start of the test scenario.
#
# Creates:
#   - GitHub repo: <GITHUB_USER>/<INTERNAL_REPO_NAME> (private)
#   - Local clone: <TEST_DIR>/internal/
#   - Initial commits with public services and excluded files
#   - Milestone tag: milestone/v1
#
# Usage:
#   ./test/01-setup-internal.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CONF="${SCRIPT_DIR}/test.conf"
[[ -f "$TEST_CONF" ]] || { echo "test.conf not found. Run: cp test/test.conf.example test/test.conf and edit it"; exit 1; }
source "$TEST_CONF"

log() { echo -e "\033[1;34m[setup]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

INTERNAL_LOCAL="${TEST_DIR}/internal"

command -v gh  >/dev/null 2>&1 || die "gh CLI is not installed"
command -v git >/dev/null 2>&1 || die "git is not installed"

# ── Create GitHub repo ────────────────────────────────────────
log "Creating GitHub repo: ${GITHUB_USER}/${INTERNAL_REPO_NAME}..."
if gh repo view "${GITHUB_USER}/${INTERNAL_REPO_NAME}" >/dev/null 2>&1; then
  log "Repo already exists, skipping creation"
else
  gh repo create "${GITHUB_USER}/${INTERNAL_REPO_NAME}" \
    --private \
    --description "replica-sync test: internal monorepo"
  ok "Created: https://github.com/${GITHUB_USER}/${INTERNAL_REPO_NAME}"
fi

# ── Clone locally ─────────────────────────────────────────────
mkdir -p "$TEST_DIR"
if [[ -d "$INTERNAL_LOCAL" ]]; then
  log "Local clone already exists at ${INTERNAL_LOCAL}, skipping clone"
else
  git clone "git@github.com:${GITHUB_USER}/${INTERNAL_REPO_NAME}.git" "$INTERNAL_LOCAL"
fi

cd "$INTERNAL_LOCAL"

# ── Commit 1: initial project structure ───────────────────────
log "Creating initial file structure..."

mkdir -p services/api services/common services/auth
mkdir -p internal-only .secrets

cat > services/api/ApiHandler.kt << 'EOF'
// ApiHandler.kt - Public API handler
class ApiHandler {
    fun handleRequest(path: String): String = "200 OK: $path"
}
EOF

cat > services/api/ApiRouter.kt << 'EOF'
// ApiRouter.kt - Request router
class ApiRouter(private val handler: ApiHandler) {
    fun route(path: String): String = handler.handleRequest(path)
}
EOF

cat > services/common/Utils.kt << 'EOF'
// Utils.kt - Shared utilities
object Utils {
    fun format(value: Any): String = value.toString()
    fun log(msg: String) = println("[LOG] $msg")
}
EOF

cat > services/auth/AuthService.kt << 'EOF'
// AuthService.kt - Authentication
class AuthService {
    fun authenticate(token: String): Boolean = token.isNotEmpty()
    fun authorize(userId: String, role: String): Boolean = userId.isNotEmpty()
}
EOF

# Excluded files (should never appear in publish branch)
cat > internal-only/InternalConfig.kt << 'EOF'
// InternalConfig.kt - INTERNAL USE ONLY - excluded from replica sync
object InternalConfig {
    const val INTERNAL_API_KEY   = "int-key-abc123"
    const val INTERNAL_DB_HOST   = "db.internal.company"
    const val INTERNAL_METRICS   = "metrics.internal.company"
}
EOF

cat > .secrets/credentials.properties << 'EOF'
# INTERNAL CREDENTIALS - EXCLUDED FROM REPLICA SYNC
db.password=super-secret-password
api.signing.key=signing-key-xyz789
EOF

cat > README.md << 'EOF'
# Test Internal Monorepo

Test repository for replica-sync scenario testing.

## Structure
- `services/api/`    — Public API service
- `services/common/` — Shared utilities
- `services/auth/`   — Authentication service
- `internal-only/`   — EXCLUDED from replica (internal configs)
- `.secrets/`        — EXCLUDED from replica (credentials)
EOF

git add -A
git commit -m "feat: initial project structure

Add API, common, and auth services.
internal-only/ and .secrets/ are excluded from replica sync."

# ── Commit 2: add token service ───────────────────────────────
mkdir -p services/auth

cat > services/auth/TokenService.kt << 'EOF'
// TokenService.kt - Token management
class TokenService {
    fun generate(userId: String): String = "tok-$userId-${System.currentTimeMillis()}"
    fun validate(token: String): Boolean = token.startsWith("tok-")
    fun revoke(token: String): Boolean   = token.isNotEmpty()
}
EOF

cat >> internal-only/InternalConfig.kt << 'EOF'

object InternalTokenConfig {
    const val TOKEN_SECRET = "token-secret-key-do-not-share"
    const val TOKEN_TTL_SECONDS = 3600
}
EOF

git add -A
git commit -m "feat: add token service with internal token config"

# ── Commit 3: add user service ────────────────────────────────
mkdir -p services/users

cat > services/users/UserService.kt << 'EOF'
// UserService.kt - User management
data class User(val id: String, val name: String, val email: String)

class UserService {
    private val users = mutableMapOf<String, User>()

    fun create(id: String, name: String, email: String): User =
        User(id, name, email).also { users[id] = it }

    fun find(id: String): User? = users[id]
    fun list(): List<User>     = users.values.toList()
}
EOF

git add -A
git commit -m "feat: add user service"

# ── Create milestone tag ──────────────────────────────────────
git tag -a milestone/v1 -m "milestone: v1 - initial services"

# ── Push ─────────────────────────────────────────────────────
log "Pushing to GitHub..."
git push origin main
git push origin milestone/v1

ok "Internal repo ready"
ok "  Local path : ${INTERNAL_LOCAL}"
ok "  GitHub     : https://github.com/${GITHUB_USER}/${INTERNAL_REPO_NAME}"
ok "  Milestone  : milestone/v1"
echo ""
echo "Next: generate sync.conf"
echo "  ./test/03-generate-sync-conf.sh"
