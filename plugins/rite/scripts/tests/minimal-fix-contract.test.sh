#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
fix_skill="$ROOT/plugins/rite/skills/fix/SKILL.md"
reviewer="$ROOT/plugins/rite/agents/_reviewer-base.md"
failures=0

assert_grep() {
  local label=$1 file=$2 pattern=$3
  if grep -Fq -- "$pattern" "$file"; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

# Keep the three fix-side mandates independent: removing or weakening any one
# must fail this contract even when the surrounding section remains present.
assert_grep 'fix stays within the finding named scope' "$fix_skill" \
  'finding が名指しした範囲の最小差分'
assert_grep 'fix prefers deletion when deletion resolves the finding' "$fix_skill" \
  '削除で解消できる finding は削除で直す'
assert_grep 'fix limits additive defenses and explanation' "$fix_skill" \
  '新 guard / fallback / 説明コメントの追加は finding が新挙動・新契約を要求する場合のみ'

# Pin the complete fix-cycle range and its numeric persistence. In particular,
# HEAD~1 would silently shrink a multi-commit cycle to its final commit.
assert_grep 'fix records the pre-commit cycle baseline' "$fix_skill" \
  'FIX_CYCLE_BASE_SHA=%s'
assert_grep 'fix consumes the retained cycle baseline' "$fix_skill" \
  'commit_sha_before="{fix_cycle_base_sha_from_context}"'
assert_grep 'fix rejects an invalid or unexpanded baseline' "$fix_skill" \
  'git cat-file -e "${commit_sha_before}^{commit}"'
assert_grep 'fix uses the cycle baseline for numstat' "$fix_skill" \
  'git diff --numstat "$commit_sha_before"..HEAD'
assert_grep 'fix excludes binary additions from line totals' "$fix_skill" \
  '$1 ~ /^[0-9]+$/ { added += $1 }'
assert_grep 'fix excludes binary deletions from line totals' "$fix_skill" \
  '$2 ~ /^[0-9]+$/ { deleted += $2 }'
assert_grep 'fix persists additions as a JSON number' "$fix_skill" \
  '--argjson added "$lines_added"'
assert_grep 'fix persists deletions as a JSON number' "$fix_skill" \
  '--argjson deleted "$lines_deleted"'
assert_grep 'fix maps the numeric additions into the cycle entry' "$fix_skill" \
  '"lines_added": $added'
assert_grep 'fix maps the numeric deletions into the cycle entry' "$fix_skill" \
  '"lines_deleted": $deleted'

assert_grep 'reviewer defines over-fix' "$reviewer" \
  '**over-fix** is a change that exceeds the finding'
assert_grep 'over-fix covers net surface area' "$reviewer" \
  'surface area (code, guards, fallbacks, or explanatory comments)'
assert_grep 'reviewer checks deletion as the smaller fix' "$reviewer" \
  'removing the excessive structure would resolve the finding with less surface'
assert_grep 'over-fix can be reported as non-blocking' "$reviewer" \
  'Report demonstrable over-fix as at least non-blocking'
assert_grep 'blocking still requires a concrete defect' "$reviewer" \
  'blocking only when the added surface creates a concrete current-PR defect'

if [ "$failures" -ne 0 ]; then
  printf '%s contract assertion(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All minimal-fix contract assertions passed.\n'
