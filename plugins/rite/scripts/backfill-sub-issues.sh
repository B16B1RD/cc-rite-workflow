#!/bin/bash
# rite workflow - Backfill Sub-Issues API Linkage
# Scans existing child Issues whose body contains `Parent Issue: #N`
# meta but are NOT yet linked via the Sub-issues API, and retroactively
# establishes the API relation using `link-sub-issue.sh`.
#
# Intended for one-shot remediation of pre-existing Issues created
# before the mandatory linkage was wired into create-decompose / parent-routing
# (Issue #514).
#
# Usage:
#   bash backfill-sub-issues.sh <owner> <repo> [child_number ...]
#
# Examples:
#   # Specific Issues
#   bash backfill-sub-issues.sh B16B1RD cc-rite-workflow 503 504 505 506
#
#   # Auto-discover all open Issues with `Parent Issue: #` body meta
#   bash backfill-sub-issues.sh B16B1RD cc-rite-workflow
#
# Output:
#   Per-child summary lines on stdout. A final tally is printed at exit.
#
# Exit codes:
#   0 = scan completed (regardless of per-child failures)
#   1 = invalid arguments
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: backfill-sub-issues.sh <owner> <repo> [child_number ...]" >&2
  exit 1
fi

OWNER="$1"
REPO="$2"
shift 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK_SCRIPT="$SCRIPT_DIR/link-sub-issue.sh"

if [ ! -x "$LINK_SCRIPT" ]; then
  echo "ERROR: link-sub-issue.sh not found or not executable at $LINK_SCRIPT" >&2
  exit 1
fi

# --- Step 1: Resolve target child Issue numbers ---
declare -a TARGET_CHILDREN
if [ $# -gt 0 ]; then
  TARGET_CHILDREN=("$@")
else
  echo "🔎 Discovering open Issues with 'Parent Issue: #' body meta..."
  # Search open Issues whose body contains the Parent Issue meta marker.
  # Note: the search API does not parse arbitrary body patterns reliably,
  # so we list open Issues and inspect bodies locally.
  # Limit raised to 1000 (from 200) to cover larger backlogs. Override via
  # BACKFILL_LIMIT env var if needed.
  DISCOVER_LIMIT="${BACKFILL_LIMIT:-1000}"
  mapfile -t TARGET_CHILDREN < <(
    gh issue list --repo "$OWNER/$REPO" --state open --limit "$DISCOVER_LIMIT" \
      --json number,body \
      --jq '.[] | select(.body != null and (.body | test("Parent Issue:\\s*#[0-9]+"))) | .number'
  )
  # Detect potential truncation: if hit count meets the cap, the discovery
  # may be incomplete. Warn explicitly so silent under-coverage is impossible.
  if [ "${#TARGET_CHILDREN[@]}" -ge "$DISCOVER_LIMIT" ]; then
    echo "⚠️ ヒット件数が discovery limit (${DISCOVER_LIMIT}) に達しました。" >&2
    echo "   未補修の Issue が残っている可能性があります。BACKFILL_LIMIT 環境変数で上限を" >&2
    echo "   引き上げるか、対象を個別指定して再実行してください。" >&2
  fi
fi

if [ "${#TARGET_CHILDREN[@]}" -eq 0 ]; then
  echo "対象なし: 'Parent Issue: #' を含む open Issue が見つかりませんでした"
  exit 0
fi

echo "対象: ${#TARGET_CHILDREN[@]} 件の Issue を補修確認します"

# --- Step 2: For each target, extract parent number and check linkage ---
ok_count=0
already_count=0
failed_count=0
skipped_count=0
api_error_count=0

# extract_parent_number: child Issue から `Parent Issue: #N` メタを抽出する。
#
# Return codes (silent skip 禁止のため、API 失敗と良性 "メタなし" を厳密に区別する):
#   0  - body 取得成功 + meta 抽出成功 (stdout に親番号を出力)
#   1  - body 取得成功 + meta なし (legitimate "no parent meta")
#   2  - gh issue view が失敗 (API エラー / auth / network / rate limit / 5xx 等)
#
# stderr suppression (`2>/dev/null`) は使用せず、エラー出力を一時ファイルに捕捉して
# 呼び出し元に warning + 詳細メッセージを surface する。これにより MUST「silent skip 禁止」
# (Issue #514) と CLAUDE.md feedback `feedback_e2e_no_stop_before_review` の精神を遵守する。
extract_parent_number() {
  local child_num="$1"
  local body err_file
  err_file=$(mktemp)
  if ! body=$(gh issue view "$child_num" --repo "$OWNER/$REPO" --json body --jq '.body' 2>"$err_file"); then
    local err_msg
    err_msg=$(cat "$err_file")
    rm -f "$err_file"
    echo "⚠️ #$child_num: gh issue view に失敗しました: ${err_msg:-(no stderr output)}" >&2
    return 2
  fi
  rm -f "$err_file"
  if [ -z "$body" ]; then
    return 1
  fi
  # Extract the first `Parent Issue: #N` reference
  printf '%s' "$body" | grep -oE 'Parent Issue:[[:space:]]*#[0-9]+' | head -1 \
    | grep -oE '[0-9]+' | head -1
}

is_already_subissue() {
  # Pre-flight check to skip already-linked children and avoid an
  # unnecessary `link-sub-issue.sh` invocation.
  #
  # Limitation: only the first 100 sub-issues are inspected. If the parent
  # has more than 100 sub-issues and the target child sits beyond the
  # window, this returns "not linked" (false negative). That is safe
  # because the subsequent `link-sub-issue.sh` call is idempotent — it will
  # detect the existing relation via GitHub's "already" error message and
  # report `already-linked`, so the final result remains correct. The only
  # cost is one extra API round-trip per false negative.
  #
  # If `pageInfo.hasNextPage` is true, emit a one-line warning so operators
  # are aware that the local short-circuit was not authoritative.
  local parent_num="$1"
  local child_num="$2"
  local resp
  resp=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $parent: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $parent) {
          subIssues(first: 100) {
            nodes { number }
            pageInfo { hasNextPage }
          }
        }
      }
    }' \
    -f owner="$OWNER" -f repo="$REPO" -F parent="$parent_num" 2>/dev/null) || return 1

  local has_next
  has_next=$(printf '%s' "$resp" | jq -r '.data.repository.issue.subIssues.pageInfo.hasNextPage // false' 2>/dev/null)
  if [ "$has_next" = "true" ]; then
    echo "   ℹ️  #$parent_num has >100 sub-issues; pre-flight check is non-authoritative (will rely on link-sub-issue.sh idempotency)" >&2
  fi

  printf '%s' "$resp" \
    | jq -r ".data.repository.issue.subIssues.nodes[]?.number" 2>/dev/null \
    | grep -q "^${child_num}$"
}

for child in "${TARGET_CHILDREN[@]}"; do
  # extract_parent_number の return code を区別:
  #   0 → parent 番号取得成功
  #   1 → メタなし (良性スキップ)
  #   2 → API 失敗 (api_error_count に計上、silent skip しない)
  set +e
  parent=$(extract_parent_number "$child")
  ext_rc=$?
  set -e
  if [ "$ext_rc" -eq 2 ]; then
    echo "❌ #$child: parent 番号の抽出に失敗 (API エラー) — 後続 linkage をスキップ" >&2
    api_error_count=$((api_error_count + 1))
    continue
  fi
  if [ -z "$parent" ]; then
    echo "⏭️  #$child: parent meta なし — スキップ"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  if is_already_subissue "$parent" "$child"; then
    echo "✅ #$child: 既に #$parent の sub-issue として登録済み"
    already_count=$((already_count + 1))
    continue
  fi

  result=$(bash "$LINK_SCRIPT" "$OWNER" "$REPO" "$parent" "$child")
  status=$(printf '%s' "$result" | jq -r '.status')
  message=$(printf '%s' "$result" | jq -r '.message')
  case "$status" in
    ok)
      echo "✅ #$child: $message"
      ok_count=$((ok_count + 1))
      ;;
    already-linked)
      echo "✅ #$child: $message"
      already_count=$((already_count + 1))
      ;;
    failed)
      printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null \
        | while read -r w; do echo "   ⚠️ $w" >&2; done
      echo "❌ #$child: linkage failed (parent #$parent)"
      failed_count=$((failed_count + 1))
      ;;
    *)
      # 未知 status を silent 通過させない (Issue #514 MUST NOT)
      # JSON parse 失敗や link-sub-issue.sh の将来拡張で空文字/未知値が
      # 返った場合、サイレントロスを起こさず failed として計上する。
      echo "❌ #$child: unexpected link status '$status' (msg: $message)" >&2
      failed_count=$((failed_count + 1))
      ;;
  esac
done

echo
echo "=== Backfill サマリー ==="
echo "新規紐付け成功:        $ok_count"
echo "既に登録済み:          $already_count"
echo "失敗 (linkage):        $failed_count"
echo "失敗 (API エラー):     $api_error_count"
echo "スキップ (meta なし):  $skipped_count"
echo "合計:                  ${#TARGET_CHILDREN[@]}"
if [ "$api_error_count" -gt 0 ]; then
  echo
  echo "⚠️ $api_error_count 件で gh issue view が失敗しました。" >&2
  echo "   auth (gh auth status) / network / rate limit / API 5xx を確認してください。" >&2
fi
