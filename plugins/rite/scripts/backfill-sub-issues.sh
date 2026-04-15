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
  mapfile -t TARGET_CHILDREN < <(
    gh issue list --repo "$OWNER/$REPO" --state open --limit 200 \
      --json number,body \
      --jq '.[] | select(.body != null and (.body | test("Parent Issue:\\s*#[0-9]+"))) | .number'
  )
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

extract_parent_number() {
  local child_num="$1"
  local body
  body=$(gh issue view "$child_num" --repo "$OWNER/$REPO" --json body --jq '.body' 2>/dev/null || echo "")
  if [ -z "$body" ]; then
    return 1
  fi
  # Extract the first `Parent Issue: #N` reference
  printf '%s' "$body" | grep -oE 'Parent Issue:[[:space:]]*#[0-9]+' | head -1 \
    | grep -oE '[0-9]+' | head -1
}

is_already_subissue() {
  local parent_num="$1"
  local child_num="$2"
  gh api graphql -f query='
    query($owner: String!, $repo: String!, $parent: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $parent) {
          subIssues(first: 100) { nodes { number } }
        }
      }
    }' \
    -f owner="$OWNER" -f repo="$REPO" -F parent="$parent_num" \
    --jq ".data.repository.issue.subIssues.nodes[] | select(.number == $child_num) | .number" 2>/dev/null \
    | grep -q "^${child_num}$"
}

for child in "${TARGET_CHILDREN[@]}"; do
  parent=$(extract_parent_number "$child" || true)
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
  esac
done

echo
echo "=== Backfill サマリー ==="
echo "新規紐付け成功: $ok_count"
echo "既に登録済み:   $already_count"
echo "失敗:           $failed_count"
echo "スキップ:       $skipped_count"
echo "合計:           ${#TARGET_CHILDREN[@]}"
