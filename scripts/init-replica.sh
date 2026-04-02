#!/usr/bin/env bash
# init-replica.sh
#
# 初回レプリカ作成スクリプト。
# git archive でファイルツリーのスナップショットのみを取り出し、
# 履歴ゼロの新規リポジトリとして初期化する。
# （git clone は内部コミット履歴をそのまま複製するため使用しない）
#
# Usage:
#   ./scripts/init-replica.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sync.conf"

[[ -f "$CONFIG_FILE" ]] || {
  echo "設定ファイルが見つかりません: $CONFIG_FILE"
  echo "cp config/sync.conf.example config/sync.conf して編集してください"
  exit 1
}
# shellcheck source=../config/sync.conf.example
source "$CONFIG_FILE"

log() { echo -e "\033[1;34m[init]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[  ok ]\033[0m $*"; }
die() { echo -e "\033[1;31m[ err ]\033[0m $*" >&2; exit 1; }

# ── 引数: 開始タグ ─────────────────────────────────────────────
START_TAG="${1:-}"
[[ -n "$START_TAG" ]] || die "開始タグを指定してください\n  Usage: $0 <start-tag>\n  例:    $0 milestone/2024-Q1"

# ── 事前確認 ───────────────────────────────────────────────────
cd "$INTERNAL_REPO"
git rev-parse --verify "$START_TAG" >/dev/null 2>&1 \
  || die "タグ '$START_TAG' が内部 repo に存在しません"

REPLICA_DIR=$(mktemp -d /tmp/replica-init-XXXXXX)
trap 'rm -rf "$REPLICA_DIR"' EXIT

log "開始タグ  : $START_TAG"
log "展開先    : $REPLICA_DIR"
log "レプリカ  : $REPLICA_GH_REPO"

# ── Step 1: タグ時点のファイルツリーのみを展開 ────────────────
log "git archive でスナップショットを取得中..."
git archive "$START_TAG" | tar -x -C "$REPLICA_DIR"

# ── Step 2: 履歴ゼロの新規リポジトリとして初期コミット ────────
log "履歴ゼロのリポジトリを初期化中..."
cd "$REPLICA_DIR"
git init
git branch -m main
git add -A

GIT_AUTHOR_NAME="$SYNC_AUTHOR_NAME" \
GIT_AUTHOR_EMAIL="$SYNC_AUTHOR_EMAIL" \
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git commit -m "initial: $START_TAG"

ok "初期コミット: $(git rev-parse --short HEAD)"

# ── Step 3: github.com へ push ────────────────────────────────
log "github.com へ push 中..."
git remote add origin "git@github.com:${REPLICA_GH_REPO}.git"
git push -u origin main

# ── Step 4: 内部 repo に sync タグを設定 ─────────────────────
log "同期起点タグを設定中..."
cd "$INTERNAL_REPO"
git tag "$SYNC_TAG" "$START_TAG"

ok "同期起点タグを設定: $SYNC_TAG → $START_TAG"
ok "初回セットアップ完了 🎉"
echo ""
echo "次のステップ:"
echo "  1. github.com のレプリカ main に Branch Protection を設定"
echo "     （Bot のみ push 許可）"
echo "  2. 3rd party にリポジトリへの招待を送付"
echo "  3. マイルストーン同期は以下で実行:"
echo "     ./scripts/sync-to-replica.sh \"sync: <milestone>\""
