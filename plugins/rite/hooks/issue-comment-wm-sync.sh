#!/bin/bash
# rite workflow - Issue Comment Work Memory Sync
# Deterministic script for Issue comment work memory operations.
# Handles: comment creation (init), retrieval, transformation, safety checks, and PATCH.
# Text transformations are delegated to issue-comment-wm-update.py (stdin→stdout).
#
# Usage:
#   Init mode (create new work memory comment):
#     bash issue-comment-wm-sync.sh init --issue 42 --branch "feat/issue-42-test"
#
#   Update mode (transform and PATCH existing comment):
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform update-phase --phase "phase5_review" --phase-detail "レビュー中"
#
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform update-progress \
#       --impl-status "✅ 完了" --test-status "⬜ 未着手" --doc-status "⬜ 未着手" \
#       --changed-files-file /tmp/files.md
#
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform append-section --section "品質チェック履歴" --content-file /tmp/lint.md
#
# Options:
#   --issue          Issue number (required)
#   --branch         Branch name (init mode)
#   --transform      Python subcommand to apply (update mode, required)
#   (remaining args are passed through to the Python script)
#
# Exit codes:
#   0: Success or non-blocking skip (WARNING on stderr)
#   1: Argument error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/issue-comment-wm-update.py"

# Resolve repository root for .rite-flow-state access
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)" 2>/dev/null) || STATE_ROOT="$(pwd)"
FLOW_STATE="$STATE_ROOT/.rite-flow-state"

# --- Get owner/repo ---
get_owner_repo() {
  gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null || echo ""
}

# --- Get comment ID (with flow-state cache) ---
get_comment_id() {
  local issue="$1"
  local owner_repo="$2"

  # Try cache first
  if [ -f "$FLOW_STATE" ]; then
    local cached
    cached=$(jq -r '.wm_comment_id // empty' "$FLOW_STATE" 2>/dev/null) || cached=""
    if [ -n "$cached" ] && [ "$cached" != "null" ]; then
      # Verify cached ID is still valid
      local verify
      verify=$(gh api "repos/${owner_repo}/issues/comments/${cached}" --jq '.id // empty' 2>/dev/null) || verify=""
      if [ -n "$verify" ]; then
        echo "$cached"
        return 0
      fi
    fi
  fi

  # Search by marker
  local comment_id
  comment_id=$(gh api "repos/${owner_repo}/issues/${issue}/comments" \
    --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty' 2>/dev/null) || comment_id=""

  if [ -z "$comment_id" ]; then
    return 1
  fi

  # Cache the ID in flow-state
  if [ -f "$FLOW_STATE" ]; then
    local tmp
    tmp=$(mktemp)
    jq --arg cid "$comment_id" '. + {wm_comment_id: ($cid | tonumber)}' "$FLOW_STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$FLOW_STATE" || rm -f "$tmp"
  fi

  echo "$comment_id"
  return 0
}

# --- Safety checks ---
safety_check() {
  local updated_file="$1"
  local original_length="$2"
  local backup_file="$3"
  local transform="${4:-}"

  # Empty or too short
  if [ ! -s "$updated_file" ] || [[ "$(wc -c < "$updated_file")" -lt 10 ]]; then
    echo "WARNING: Updated body is empty or too short. Skipping PATCH. Backup: $backup_file" >&2
    return 1
  fi

  # Header validation
  if ! grep -q '📜 rite 作業メモリ' "$updated_file"; then
    echo "WARNING: Updated body missing work memory header. Skipping PATCH. Backup: $backup_file" >&2
    return 1
  fi

  # 50% rule (only for update-progress, update-phase, update-plan-status, update-checkboxes)
  # Skip for append-section and replace-section (content grows or changes size unpredictably)
  case "$transform" in
    append-section|replace-section)
      ;;
    *)
      local updated_length
      updated_length=$(wc -c < "$updated_file")
      if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
        echo "WARNING: Updated body < 50% of original (${updated_length}/${original_length}). Skipping PATCH. Backup: $backup_file" >&2
        return 1
      fi
      ;;
  esac

  return 0
}

# --- Argument parsing ---
MODE="${1:-}"
shift 2>/dev/null || true

ISSUE=""
BRANCH=""
TRANSFORM=""
TRANSFORM_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)     ISSUE="$2"; shift 2 ;;
    --branch)    BRANCH="$2"; shift 2 ;;
    --transform) TRANSFORM="$2"; shift 2 ;;
    *)
      # Pass remaining args to Python script
      TRANSFORM_ARGS+=("$1")
      shift
      ;;
  esac
done

# --- Validation ---
if [ -z "$ISSUE" ]; then
  echo "ERROR: --issue is required" >&2
  exit 1
fi

case "$MODE" in
  init)
    ;;
  update)
    if [ -z "$TRANSFORM" ]; then
      echo "ERROR: update mode requires --transform" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: Unknown mode: $MODE. Use 'init' or 'update'" >&2
    exit 1
    ;;
esac

# --- Get owner/repo ---
OWNER_REPO=$(get_owner_repo)
if [ -z "$OWNER_REPO" ]; then
  echo "WARNING: Could not determine owner/repo. Skipping." >&2
  exit 0
fi

# ============================================================
# INIT MODE
# ============================================================
if [ "$MODE" = "init" ]; then
  TIMESTAMP=$(date +'%Y-%m-%dT%H:%M:%S+09:00')

  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT

  cat <<INIT_EOF > "$tmpfile"
## 📜 rite 作業メモリ

### セッション情報
- **Issue**: #${ISSUE}
- **開始**: ${TIMESTAMP}
- **ブランチ**: ${BRANCH}
- **最終更新**: ${TIMESTAMP}
- **コマンド**: rite:issue:start
- **フェーズ**: phase2
- **フェーズ詳細**: ブランチ作成・準備

### 進捗サマリー

| 項目 | 状態 | 備考 |
|------|------|------|
| 実装 | ⬜ 未着手 | - |
| テスト | ⬜ 未着手 | - |
| ドキュメント | ⬜ 未着手 | - |

### 要確認事項
<!-- 作業中に発生した確認事項を蓄積。セッション終了時にまとめて確認 -->
_確認事項はありません_

### 変更ファイル
<!-- 自動更新 -->
_まだ変更はありません_

### 決定事項・メモ
<!-- 重要な判断や発見 -->

### 計画逸脱ログ
<!-- 実装中に計画から逸脱した場合に記録 -->
_計画逸脱はありません_

### ボトルネック検出ログ
<!-- ボトルネック検出 → Oracle 発見 → 再分解の履歴 -->
_ボトルネック検出はありません_

### レビュー対応履歴
<!-- レビュー対応時に自動記録 -->
_レビュー対応はありません_

### 次のステップ
1. Issue の内容を確認
2. 実装を開始
INIT_EOF

  # Create comment
  result=$(gh issue comment "$ISSUE" --body-file "$tmpfile" 2>&1) || {
    echo "WARNING: Failed to create work memory comment: $result" >&2
    exit 0
  }

  # Validate creation
  sleep 1
  created_id=$(gh api "repos/${OWNER_REPO}/issues/${ISSUE}/comments" \
    --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty' 2>/dev/null) || created_id=""

  if [ -n "$created_id" ]; then
    # Cache comment ID
    if [ -f "$FLOW_STATE" ]; then
      local_tmp=$(mktemp)
      jq --arg cid "$created_id" '. + {wm_comment_id: ($cid | tonumber)}' "$FLOW_STATE" > "$local_tmp" 2>/dev/null && mv "$local_tmp" "$FLOW_STATE" || rm -f "$local_tmp"
    fi
    echo "status=success"
  else
    echo "WARNING: Could not verify work memory comment creation." >&2
    echo "status=unverified"
  fi

  exit 0
fi

# ============================================================
# UPDATE MODE
# ============================================================

# Step 1: Get comment ID
COMMENT_ID=$(get_comment_id "$ISSUE" "$OWNER_REPO") || {
  echo "WARNING: Work memory comment not found for Issue #${ISSUE}. Skipping update." >&2
  echo "status=skipped"
  exit 0
}

# Step 2: Get current body
body_tmp=$(mktemp)
updated_tmp=$(mktemp)
py_err_tmp=$(mktemp)
backup_file="/tmp/rite-wm-backup-${ISSUE}-$(date +%s).md"
trap 'rm -f "$body_tmp" "$updated_tmp" "$py_err_tmp"' EXIT

current_body=$(gh api "repos/${OWNER_REPO}/issues/comments/${COMMENT_ID}" --jq '.body // empty' 2>/dev/null) || current_body=""

if [ -z "$current_body" ]; then
  echo "WARNING: Could not retrieve comment body. Skipping update." >&2
  echo "status=skipped"
  exit 0
fi

# Step 3: Backup
printf '%s' "$current_body" > "$backup_file"
printf '%s' "$current_body" > "$body_tmp"
original_length=$(printf '%s' "$current_body" | wc -c)

# Step 4: Apply Python transformation
cat "$body_tmp" | python3 "$PYTHON_SCRIPT" "$TRANSFORM" "${TRANSFORM_ARGS[@]}" > "$updated_tmp" 2>"$py_err_tmp"
transform_status=$?

if [ "$transform_status" -ne 0 ]; then
  py_err=$(cat "$py_err_tmp" 2>/dev/null)
  echo "WARNING: Python transform failed (exit $transform_status). Skipping PATCH. Backup: $backup_file" >&2
  [ -n "$py_err" ] && echo "  Detail: $py_err" >&2
  echo "status=error"
  exit 0
fi

# Step 5: Safety checks
if ! safety_check "$updated_tmp" "$original_length" "$backup_file" "$TRANSFORM"; then
  echo "status=skipped"
  exit 0
fi

# Step 6: PATCH
jq -n --rawfile body "$updated_tmp" '{"body": $body}' | \
  gh api "repos/${OWNER_REPO}/issues/comments/${COMMENT_ID}" -X PATCH --input - > /dev/null 2>&1
patch_status=$?

if [ "$patch_status" -ne 0 ]; then
  echo "WARNING: PATCH failed (exit $patch_status). Backup: $backup_file" >&2
  echo "status=error"
  exit 0
fi

# Clean up backup on success (only needed on failure for post-mortem)
rm -f "$backup_file"
echo "status=success"
exit 0
