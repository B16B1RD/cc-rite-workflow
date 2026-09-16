#!/bin/bash
# post-compact-classification-regex.test.sh
#
# Pin the gh-output classification regex in post-compact.sh that distinguishes
# `pr_deleted_or_inaccessible` (a legitimate end-state, should NOT produce an
# incident) from `gh_api_failure_*` (a real auth/network/permission failure).
#
#   regex: `could not resolve.*pull\s*request|no.*pull\s*request found`
#
# Weakening, removing, or making this regex case-sensitive lets every closed
# or merged PR trigger a false reconciliation incident — historically a high-
# volume noise source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
POST_COMPACT="$PLUGIN_ROOT/hooks/post-compact.sh"

[ -f "$POST_COMPACT" ] || { echo "ERROR: $POST_COMPACT not found" >&2; exit 1; }

# Extract the regex from post-compact.sh and run fixtures against the literal —
# hard-coding it in the test would let post-compact.sh's regex drift silently
# without breaking the assertion. Pull the pattern from the production
# `grep -qiE '<regex>'` line by capturing the single-quoted contents.
REGEX=$(grep -oE "grep -qiE '[^']+'" "$POST_COMPACT" | head -1 | sed -E "s/^grep -qiE '//; s/'\$//")
if [ -z "$REGEX" ]; then
  echo "ERROR: could not extract classification regex from $POST_COMPACT" >&2
  exit 1
fi

echo "=== Phase 1: post-compact.sh defines the canonical regex ==="
assert_grep "post-compact.sh contains canonical regex (could not resolve...pull request)" "$POST_COMPACT" "could not resolve.*pull"
assert_grep "post-compact.sh uses pr_deleted_or_inaccessible classification" "$POST_COMPACT" "pr_deleted_or_inaccessible"
assert_grep "post-compact.sh uses case-insensitive grep (-i flag for the regex)" "$POST_COMPACT" "grep -qiE"

echo "=== Phase 2: positive fixtures (must classify as pr_deleted_or_inaccessible) ==="
positive_fixtures=(
  "Could not resolve to a PullRequest with the number of 999999999."
  "could not resolve to a pull request with the number of 1234"
  "Could NOT Resolve to a PULLREQUEST"
  "No pull request found for branch foo"
  "no pull request found"
  "Could not resolve to a PullRequest"
  "GraphQL: Could not resolve to a PullRequest"
  "Error: could not resolve to a pull   request (multiple spaces)"
  "could not resolve to a PullRequest with extra trailing"
  "NO PULL REQUEST FOUND"
)
for fixture in "${positive_fixtures[@]}"; do
  # $REGEX (production から抽出) と hard-code regex の両方を確認することで、
  # post-compact.sh 側で regex を変更した時にこの test も同期更新する必要があることを明示する。
  if printf '%s' "$fixture" | grep -qiE "$REGEX"; then
    pass "positive (production regex): classify '$fixture'"
  else
    fail "positive (production regex): '$fixture' did NOT match (regex drift suspected: $REGEX)"
  fi
done

echo "=== Phase 3: negative fixtures (must NOT classify as pr_deleted_or_inaccessible) ==="
negative_fixtures=(
  "unable to access pull request: network timeout"
  "HTTP 403: rate limit exceeded"
  ""
  "permission denied"
  "ssl handshake failed"
  "could not write to file"  # contains "could not" but no "resolve...pull request"
)
for fixture in "${negative_fixtures[@]}"; do
  if printf '%s' "$fixture" | grep -qiE "$REGEX"; then
    fail "negative (production regex): '$fixture' falsely classified"
  else
    pass "negative (production regex): '$fixture' correctly NOT classified"
  fi
done

echo ""
echo "=== Phase 4: reconciliation invocation structure ==="
# Pin the structural features of the reconciliation block. If the block is
# accidentally deleted, the arguments drift, or the mismatch log line is
# removed, CI would otherwise stay green while the PR Ready/Status safety
# net silently goes missing.
assert_grep "reconciliation invokes projects-status-update.sh" "$POST_COMPACT" "projects-status-update\.sh"
assert_grep "reconciliation passes status_role:\$role via jq -n" "$POST_COMPACT" 'status_role:\$role'
assert_grep "reconciliation specifies 'in_review' as target role" "$POST_COMPACT" '\--arg role "in_review"'
assert_grep "reconciliation failure emits post_compact_reconciliation_failed root-cause hint" "$POST_COMPACT" "post_compact_reconciliation_failed"
assert_grep "post-compact mismatch detected log literal exists" "$POST_COMPACT" "post-compact mismatch detected"

# A bare grep would still pass when literals migrate into a comment or a dead
# branch. Extract the reconciliation block (from its anchor comment to the
# end of post-compact.sh) and assert every literal appears inside the
# extracted region. The anchor `--- PR Ready/Status mismatch reconciliation`
# is present in the production file's section header.
recon_block=$(awk '
  /PR Ready\/Status mismatch reconciliation/ { capturing = 1 }
  capturing { print }
' "$POST_COMPACT" 2>/dev/null)
if [ -n "$recon_block" ]; then
  missing_in_block=""
  for literal in "projects-status-update.sh" 'status_role:$role' '"in_review"' \
                 "post_compact_reconciliation_failed" "post-compact mismatch detected"; do
    if ! printf '%s' "$recon_block" | grep -qF "$literal"; then
      missing_in_block="${missing_in_block} ${literal}"
    fi
  done
  if [ -z "$missing_in_block" ]; then
    pass "reconciliation block contains all 5 structural literals together"
  else
    fail "reconciliation block missing literal(s):${missing_in_block} (possible refactor into comment / dead branch)"
  fi
else
  fail "could not extract reconciliation block from post-compact.sh (anchor literal missing)"
fi

# jq -n payload schema: confirm the jq expression for projects-status-update.sh
# uses the keys the consumer expects so a future schema change breaks here
# instead of at runtime. The reconciliation block uses multi-line jq -n with
# args spread across continuation lines; grep individually rather than as one regex.
if grep -qE 'jq -n' "$POST_COMPACT" && \
   grep -qE '\--arg[[:space:]]+role' "$POST_COMPACT" && \
   grep -qE 'status_role:\$role' "$POST_COMPACT"; then
  pass "jq -n payload includes --arg role and status_role field"
else
  fail "jq -n payload schema drift: --arg role or status_role field missing"
fi

# bash -n syntax check catches quote/heredoc breakage at test time, before it
# surfaces as a runtime session-start failure.
if bash -n "$POST_COMPACT" 2>/dev/null; then
  pass "post-compact.sh passes bash -n syntax check"
else
  fail "post-compact.sh has syntax errors (bash -n failed)"
fi

print_summary "$(basename "$0")" "If you change the classification regex in post-compact.sh, update both the fixtures here and the regex literal. Weakening it (removing \\s* / requiring literal space / dropping -i) re-opens the false-positive incident flood for close/merge-deleted PRs."
