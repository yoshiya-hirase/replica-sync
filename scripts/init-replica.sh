#!/usr/bin/env bash
# init-replica.sh
#
# 初回レプリカ作成スクリプト。
# git archive でファイルツリーのスナップショットのみを取り出し、
# 履歴ゼロの新規リポジトリとして初期化する。
# （git clone は内部コミット履歴をそのまま複製するため使用しない）
#
# Usage:
#   # github.com へ直接 push（デフォルト）
#   ./scripts/init-replica.sh --party acme milestone/2024-Q1
#
#   # tar を出力し、3rd party が自分の github アカウントへ展開する
#   ./scripts/init-replica.sh --party acme --output export milestone/2024-Q1
#
#   # タグにコメントを付与する
#   ./scripts/init-replica.sh --party acme --message "acme社との協業開始用" milestone/2024-Q1
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

# ── 引数パース ─────────────────────────────────────────────────
OUTPUT_MODE="push"
PARTY=""
MESSAGE=""
START_TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)  OUTPUT_MODE="$2"; shift 2 ;;
    --party)   PARTY="$2";       shift 2 ;;
    --message) MESSAGE="$2";     shift 2 ;;
    --*)       die "不明なオプション: $1" ;;
    *)         START_TAG="$1";   shift ;;
  esac
done

[[ -n "$START_TAG" ]] || die "開始タグを指定してください\n  Usage: $0 [--party <name>] [--output push|export] [--message <text>] <start-tag>\n  例:    $0 --party acme milestone/2024-Q1"
[[ -n "$PARTY"     ]] || die "--party でパーティ名を指定してください\n  例:    $0 --party acme milestone/2024-Q1"

case "$OUTPUT_MODE" in
  push|export) ;;
  *) die "--output は push / export のいずれかを指定してください" ;;
esac

# パーティ別の同期タグ名
PARTY_SYNC_TAG="replica/${PARTY}/last-sync"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PARTY_INIT_TAG="replica/${PARTY}/init-${TIMESTAMP}"

# タグのアノテーションメッセージを構築
TAG_MESSAGE="party: ${PARTY}
output: ${OUTPUT_MODE}
start_tag: ${START_TAG}
timestamp: ${TIMESTAMP}"
[[ -n "$MESSAGE" ]] && TAG_MESSAGE="${TAG_MESSAGE}
note: ${MESSAGE}"

# ── 事前確認 ───────────────────────────────────────────────────
cd "$INTERNAL_REPO"
git rev-parse --verify "$START_TAG" >/dev/null 2>&1 \
  || die "タグ '$START_TAG' が内部 repo に存在しません"

REPLICA_DIR=$(mktemp -d /tmp/replica-init-XXXXXX)
trap 'rm -rf "$REPLICA_DIR"' EXIT

log "パーティ    : $PARTY"
log "出力モード  : $OUTPUT_MODE"
log "開始タグ    : $START_TAG"
log "展開先    : $REPLICA_DIR"
[[ "$OUTPUT_MODE" == "push" ]] && log "レプリカ  : $REPLICA_GH_REPO"

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

# ── Step 3: 配送 ──────────────────────────────────────────────
if [[ "$OUTPUT_MODE" == "push" ]]; then
  log "github.com へ push 中..."
  git remote add origin "git@github.com:${REPLICA_GH_REPO}.git"
  git push -u origin main
  ok "push 完了: github.com/${REPLICA_GH_REPO}"

else  # export
  EXPORT_DIR="${SCRIPT_DIR}/../init-exports"
  mkdir -p "$EXPORT_DIR"
  EXPORT_TAR="${EXPORT_DIR}/${PARTY}-${TIMESTAMP}.tar.gz"
  EXPORT_INSTRUCTIONS="${EXPORT_DIR}/${PARTY}-${TIMESTAMP}-setup.txt"

  log "tar を生成中..."
  # .git を除いたファイルツリーのみを出力
  tar -czf "$EXPORT_TAR" -C "$REPLICA_DIR" --exclude='.git' .

  cat > "$EXPORT_INSTRUCTIONS" << EOF
# レプリカ初期セットアップ手順
# 生成日時: ${TIMESTAMP}
# 提供元:   ${SYNC_AUTHOR_NAME} <${SYNC_AUTHOR_EMAIL}>
# 開始タグ: ${START_TAG}

## 手順

1. GitHub 上に空のリポジトリを作成する（README なし）

2. tar を展開して git リポジトリを初期化する

   mkdir replica
   tar -xzf ${PARTY}-${TIMESTAMP}.tar.gz -C replica
   cd replica
   git init
   git branch -m main
   git add -A
   git commit -m "initial: ${START_TAG}"

3. 作成したリポジトリへ push する

   git remote add origin git@github.com:<your-org>/replica.git
   git push -u origin main

4. 以降の同期は提供元がこのリポジトリへ PR または patch を送ります。
   リポジトリの URL を提供元に連絡してください。
EOF

  ok "export ファイルを生成しました:"
  echo "  tar          : $EXPORT_TAR"
  echo "  instructions : $EXPORT_INSTRUCTIONS"
  echo ""
  echo "3rd party に以下のファイルを送付してください:"
  echo "  $EXPORT_TAR"
  echo "  $EXPORT_INSTRUCTIONS"
fi

# ── Step 4: 内部 repo にタグを設定 ──────────────────────────
log "同期起点タグを設定中..."
cd "$INTERNAL_REPO"

# 初回切り出しの不変記録タグ
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git tag -a "$PARTY_INIT_TAG" "$START_TAG" -m "$TAG_MESSAGE"

# 同期起点の可動ポインタタグ
GIT_COMMITTER_NAME="$SYNC_AUTHOR_NAME" \
GIT_COMMITTER_EMAIL="$SYNC_AUTHOR_EMAIL" \
git tag -a "$PARTY_SYNC_TAG" "$START_TAG" -m "$TAG_MESSAGE"

ok "初回切り出しタグ: $PARTY_INIT_TAG"
ok "同期起点タグ    : $PARTY_SYNC_TAG → $START_TAG"
ok "初回セットアップ完了"
echo ""
if [[ "$OUTPUT_MODE" == "push" ]]; then
  echo "次のステップ:"
  echo "  1. github.com のレプリカ main に Branch Protection を設定"
  echo "     （Bot のみ push 許可）"
  echo "  2. 3rd party にリポジトリへの招待を送付"
else
  echo "次のステップ:"
  echo "  1. 3rd party がリポジトリをセットアップ後、URL を受け取る"
  echo "  2. config/sync.conf の REPLICA_GH_REPO にその URL を設定する"
fi
echo "  マイルストーン同期は以下で実行:"
echo "     ./scripts/sync-to-replica.sh --party ${PARTY} \"sync: <milestone>\""
