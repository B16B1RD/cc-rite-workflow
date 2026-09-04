#!/bin/bash
# Tests for number-reference-check.sh
# Usage: bash plugins/rite/hooks/tests/number-reference-check.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
TARGET="$PLUGIN_ROOT/hooks/scripts/number-reference-check.sh"
LINT_SKILL="$PLUGIN_ROOT/skills/lint/SKILL.md"
PR_REVIEW_SKILL="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
FIX_SKILL="$PLUGIN_ROOT/skills/fix/SKILL.md"
IMPLEMENT_SKILL="$PLUGIN_ROOT/skills/issue-implement/SKILL.md"
ISSUE_CLOSE_SKILL="$PLUGIN_ROOT/skills/issue-close/SKILL.md"

if [ ! -x "$TARGET" ] && [ ! -f "$TARGET" ]; then
  echo "ERROR: helper not found: $TARGET" >&2
  exit 1
fi

cleanup_dirs=()
cleanup() {
  local p
  for p in "${cleanup_dirs[@]:-}"; do [ -n "$p" ] && rm -rf "$p"; done
}
trap cleanup EXIT

init_git_sb() {
  local sb="$1"
  git -C "$sb" init -q
  git -C "$sb" config user.email test@example.com
  git -C "$sb" config user.name test
}

commit_all() {
  local sb="$1" msg="$2"
  git -C "$sb" add -A
  git -C "$sb" commit -qm "$msg"
}

run_all() {
  local sb="$1"
  shift
  bash "$TARGET" --all --repo-root "$sb" "$@"
}

run_diff() {
  local sb="$1" base="$2"
  shift 2
  bash "$TARGET" --diff "$base" --repo-root "$sb" "$@"
}

echo "=== number-reference-check.sh ==="

# --------------------------------------------------------------------------
# CLI contract
# --------------------------------------------------------------------------
sb=$(make_plain_sandbox) && cleanup_dirs+=("$sb") || { echo "ERROR: sandbox" >&2; exit 1; }
init_git_sb "$sb"

rc=0; bash "$TARGET" --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "no mode → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --target foo.md --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "unknown --target → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --bogus --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "unknown argument → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --diff --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "--diff without base → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --stdin >/dev/null 2>&1 || rc=$?
assert "--stdin without --label → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --all --label x --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "--label without --stdin → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --all --diff HEAD --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "exclusive --all and --diff → exit 2" "2" "$rc"

rc=0; out=$(bash "$TARGET" --repo-root /nonexistent/rite-xyz --all 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'repo-root not a directory'; then
  pass "bad --repo-root → exit 2"
else
  fail "bad --repo-root expected rc=2 with ERROR, got rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# T-12: unresolved --diff base
# --------------------------------------------------------------------------
printf 'clean\n' > "$sb/README.md"
commit_all "$sb" init
rc=0; out=$(run_diff "$sb" does-not-exist 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'ERROR'; then
  pass "T-12 unresolved base → exit 2 + ERROR"
else
  fail "T-12 expected rc=2 + ERROR, got rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# T-01 --diff: pre-existing / added / uncommitted / deletion
# --------------------------------------------------------------------------
mkdir -p "$sb/plugins/rite/skills/x"
printf 'pre-existing token (#1500)\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" base
base=$(git -C "$sb" rev-parse HEAD)

printf 'clean addition\n' >> "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" clean
rc=0; out=$(run_diff "$sb" "$base" --quiet 2>&1) || rc=$?
assert "T-01(a) pre-existing on base is not prosecuted" "0" "$rc"

printf 'added token (#1600)\n' >> "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" added
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE '^plugins/rite/skills/x/SKILL.md:[0-9]+: added token \(#1600\)$' \
   && printf '%s' "$out" | grep -q 'Total number-ref findings: 1'; then
  pass "T-01(b) added + line → exit 1 + file:line: matched line + summary"
else
  fail "T-01(b) expected rc=1 with stdout format, got rc=$rc: $out"
fi

printf 'uncommitted token (#1700)\n' >> "$sb/plugins/rite/skills/x/SKILL.md"
rc=0; out=$(run_diff "$sb" HEAD --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '#1700' \
   && printf '%s' "$out" | grep -q 'Total number-ref findings:'; then
  pass "T-01(c) uncommitted + line is detected"
else
  fail "T-01(c) expected rc=1 with uncommitted hit, got rc=$rc: $out"
fi
git -C "$sb" checkout -- plugins/rite/skills/x/SKILL.md

# deletion of a numbered line must not hit
printf 'keep\nnumbered (#1800)\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" before-del
printf 'keep\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" after-del
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
assert "T-01(d) deleted numbered line is not a hit" "0" "$rc"

# --------------------------------------------------------------------------
# T-02 Issue #N / PR #N share the same grammar
# --------------------------------------------------------------------------
issue_label=Issue
pr_label=PR
number_mark='#'
printf '%s %s1234 rationale\n%s %s367 loader\n' \
  "$issue_label" "$number_mark" "$pr_label" "$number_mark" \
  > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" prose-forms
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '#1234' && printf '%s' "$out" | grep -q '#367'; then
  pass "T-02 Issue/PR prose forms detected"
else
  fail "T-02 expected both prose forms, got rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# T-03 anchors / placeholder / ignore
# --------------------------------------------------------------------------
printf '#100-letter heading\nplaceholder #123 stays\nhistorical (#1900) drift-check-ignore\n' \
  > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" exclusions
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
assert "T-03 anchor / #123 / ignore → hit 0" "0" "$rc"

# adjacent pin: #123 excluded, #1234 detected
printf 'skip #123 and catch #1234 here\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" adjacent
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '#1234' \
   && [ "$(printf '%s' "$out" | grep -c 'Total number-ref findings: 1' || true)" -eq 1 ]; then
  pass "T-03 adjacent #123 skip / #1234 hit"
else
  fail "T-03 adjacent pin failed rc=$rc: $out"
fi

# hyphen + digit is not an anchor
printf 'not-anchor (#200-1)\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" hyphen-digit
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
assert "T-03 hyphen+digit is not an anchor" "1" "$rc"

# word-char after 3-4 digits is not a bare number (heading id / hex color)
hex_color='161B22'
heading_id='530c'
bare_token='2045'
printf 'link to assessment-rules.md#%s-class\ncolor #%s\nreal token (#%s)\n' \
  "$heading_id" "$hex_color" "$bare_token" \
  > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" word-char
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE "real token \\(#${bare_token}\\)" \
   && ! printf '%s' "$out" | grep -q "${heading_id}-class" \
   && ! printf '%s' "$out" | grep -q "$hex_color"; then
  pass "word-char after digits miss; bare token hit (--diff)"
else
  fail "word-char skip failed rc=$rc: $out"
fi

rc=0; out=$(printf 'link to assessment-rules.md#%s-class\ncolor #%s\nreal token (#%s)\n' \
  "$heading_id" "$hex_color" "$bare_token" \
  | bash "$TARGET" --stdin --label probe.md --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE "^probe.md:3: real token \\(#${bare_token}\\)$" \
   && ! printf '%s' "$out" | grep -q 'probe.md:1:' \
   && ! printf '%s' "$out" | grep -q 'probe.md:2:'; then
  pass "word-char after digits miss; bare token hit (--stdin)"
else
  fail "word-char --stdin failed rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# Band: #100 / #9999 hit, #99 / #12345 miss
# --------------------------------------------------------------------------
printf 'lower (#100)\nupper (#9999)\nbelow #99\nabove #12345\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" band
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE '\(#100\)' \
   && printf '%s' "$out" | grep -qE '\(#9999\)' \
   && ! printf '%s' "$out" | grep -qE 'below #99' \
   && ! printf '%s' "$out" | grep -qE 'above #12345'; then
  pass "band #100/#9999 hit, #99/#12345 miss"
else
  fail "band boundaries failed rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# T-04 path exclusions — only the three contracted paths
# --------------------------------------------------------------------------
mkdir -p "$sb/.rite/wiki/raw" \
  "$sb/plugins/rite/scripts/tests/fixtures" \
  "$sb/plugins/rite/hooks/tests"
printf 'raw (#2100)\n' > "$sb/.rite/wiki/raw/note.md"
printf 'fixture (#2101)\n' > "$sb/plugins/rite/scripts/tests/fixtures/x.md"
printf 'self (#2102)\n' > "$sb/plugins/rite/hooks/tests/number-reference-check.test.sh"
printf 'cjc (#2103)\n' > "$sb/plugins/rite/hooks/tests/comment-journal-check.test.sh"
printf 'wiki (#2104)\n' > "$sb/plugins/rite/hooks/tests/wiki-lint-descriptive-refs.test.sh"
printf 'other (#2105)\n' > "$sb/plugins/rite/hooks/tests/other.test.sh"
printf 'clean surface\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" path-excl

rc=0; out=$(run_all "$sb" --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -q 'hooks/tests/other.test.sh' \
   && ! printf '%s' "$out" | grep -q 'wiki/raw/' \
   && ! printf '%s' "$out" | grep -q 'scripts/tests/fixtures/' \
   && ! printf '%s' "$out" | grep -q 'number-reference-check.test.sh' \
   && ! printf '%s' "$out" | grep -q 'comment-journal-check.test.sh' \
   && ! printf '%s' "$out" | grep -q 'wiki-lint-descriptive-refs.test.sh'; then
  pass "T-04 excluded 3 paths miss; other hooks/tests hit"
else
  fail "T-04 path exclusions failed rc=$rc: $out"
fi

rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -q 'hooks/tests/other.test.sh' \
   && ! printf '%s' "$out" | grep -q 'wiki/raw/' \
   && ! printf '%s' "$out" | grep -q 'scripts/tests/fixtures/' \
   && ! printf '%s' "$out" | grep -q 'number-reference-check.test.sh' \
   && ! printf '%s' "$out" | grep -q 'comment-journal-check.test.sh' \
   && ! printf '%s' "$out" | grep -q 'wiki-lint-descriptive-refs.test.sh'; then
  pass "T-04 --diff excluded 3 paths miss; other hooks/tests hit"
else
  fail "T-04 --diff path exclusions failed rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# T-05 --all detects newly tracked files without a target list
# --------------------------------------------------------------------------
mkdir -p "$sb/docs"
printf 'new tracked (#2200)\n' > "$sb/docs/new.md"
commit_all "$sb" new-tracked
rc=0; out=$(run_all "$sb" --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'docs/new.md' && printf '%s' "$out" | grep -q '#2200'; then
  pass "T-05 --all detects newly tracked file"
else
  fail "T-05 expected docs/new.md hit, got rc=$rc: $out"
fi

# CHANGELOG is in scope for --all
printf 'history (#2300)\n' > "$sb/CHANGELOG.md"
commit_all "$sb" changelog
rc=0; out=$(run_all "$sb" --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'CHANGELOG.md'; then
  pass "--all scans CHANGELOG"
else
  fail "--all should scan CHANGELOG, got rc=$rc: $out"
fi

# --quiet suppresses Scanning but not the summary
rc=0; err=$(run_all "$sb" --quiet 2>&1 >/dev/null) || rc=$?
if printf '%s' "$err" | grep -q 'Total number-ref findings:' \
   && ! printf '%s' "$err" | grep -q 'Scanning'; then
  pass "--quiet suppresses Scanning, keeps summary"
else
  fail "--quiet contract failed: $err"
fi

# --------------------------------------------------------------------------
# --stdin --label
# --------------------------------------------------------------------------
rc=0; out=$(printf 'stdin token (#2400)\n' | bash "$TARGET" --stdin --label docs/in.md --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE '^docs/in.md:1: stdin token \(#2400\)$' \
   && printf '%s' "$out" | grep -q 'Total number-ref findings: 1'; then
  pass "--stdin --label reports with label"
else
  fail "--stdin expected labeled finding, got rc=$rc: $out"
fi

rc=0; out=$(printf 'raw (#2500)\n' | bash "$TARGET" --stdin --label .rite/wiki/raw/x.md --quiet 2>&1) || rc=$?
assert "--stdin excluded label is not scanned" "0" "$rc"

rc=0; out=$(printf 'placeholder #123 only\n' | bash "$TARGET" --stdin --label docs/p.md --quiet 2>&1) || rc=$?
assert "--stdin #123 placeholder is excluded" "0" "$rc"

# --------------------------------------------------------------------------
# T-06 / T-09 / T-11 static pins (SKILL wiring)
# --------------------------------------------------------------------------
assert_grep "T-06 lint Phase 3.5 preamble calls --diff" "$LINT_SKILL" \
  'number-reference-check\.sh --diff'
assert_grep "T-06 lint rc 1|2 routes through error_count" "$LINT_SKILL" \
  'error_count=\$\(\(error_count \+ 1\)\)'
assert_not_grep "T-06 lint no longer invokes retired gate" "$LINT_SKILL" \
  'descriptive-number-diff-gate\.sh'
assert_grep "T-06 pr-review rail calls --diff" "$PR_REVIEW_SKILL" \
  'number-reference-check\.sh --diff'
assert_grep "T-06 pr-review finding uses Verification: canonical form" "$PR_REVIEW_SKILL" \
  'Verification:'
assert_grep "T-06 pr-review orchestrator reviewer id" "$PR_REVIEW_SKILL" \
  'reviewer: "pr-review"'
assert_not_grep "T-06 pr-review does not skip on cycle-scope" "$PR_REVIEW_SKILL" \
  'number-reference-check.*cycle-scope'
assert_grep "T-06 fix 3.1 self-check calls --diff" "$FIX_SKILL" \
  'number-reference-check\.sh --diff'
assert_grep "T-11 issue-implement forbids number/AC tokens in generated prose" "$IMPLEMENT_SKILL" \
  '番号・AC番号を書かない'
assert_grep "T-11 issue-implement commit body Why is required" "$IMPLEMENT_SKILL" \
  'body は why を自由形式'
assert_not_grep "T-11 issue-implement trivial body omit withdrawn" "$IMPLEMENT_SKILL" \
  'trivial は省略可'

# T-09: --title arguments must not contain #{
title_hits=$(grep -nE -- '--title[[:space:]]+"[^"]*#\{' \
  "$PR_REVIEW_SKILL" "$FIX_SKILL" "$ISSUE_CLOSE_SKILL" 2>/dev/null || true)
if [ -z "$title_hits" ]; then
  pass "T-09 --title arguments contain no #{ }"
else
  fail "T-09 --title still contains #{ }: $title_hits"
fi

# T-10: retired gate name gone from the tree (tests/ of this detector excluded by design)
if ! git -C "$REPO_ROOT" grep -l 'descriptive-number-diff-gate' -- \
  ':!plugins/rite/hooks/tests/number-reference-check.test.sh' >/dev/null 2>&1; then
  pass "T-10 descriptive-number-diff-gate grep is 0"
else
  fail "T-10 descriptive-number-diff-gate still referenced"
fi

# --------------------------------------------------------------------------
# TC-013 / TC-014 preserved
# --------------------------------------------------------------------------
echo "TC-013: generic rationale placeholders are absent"
placeholder_pattern='the governing'' rationale|The observed'' review run|the contract''[.]s'
if ! grep -ERn "$placeholder_pattern" \
  "$REPO_ROOT/plugins/rite" "$REPO_ROOT/docs" >/dev/null; then
  pass "generic rationale placeholders are absent"
else
  fail "generic rationale placeholder residue found under plugins/rite or docs"
fi

echo "TC-014: deletion-damage residue is absent"
deletion_residue_patterns=(
  '[(（]で '
  '[(（]の '
  'machine-gated since[)]'
  'stdout emit、[)）:]'
  'tracked by[[:space:]]*[.]'
  'approved by[[:space:]]*[.]'
  "of 's"
  'pattern[.]POSIX'
  '、）'
  ',[)]'
  '[[:lower:]][.][(][[:upper:]]'
  '構築。[^|]*と対称[)][[:space:]]*[|]'
  'emit、[[:space:]]+で'
  '。[[:space:]]+以降'
  '[(（]の[^[:space:]]'
  'emit[*]*、[[:space:]]+で'
  '[.] D-[0-9]+'
  'frozen[.][)]'
  'AC-[0-9]+[.][)]'
  '[[:alpha:]][,][[:space:]]*[;]'
  'Static contract( tests)? for[[:space:]]*:'
  '。[[:space:]]+D-[0-9]+'
  '。[[:space:]]+で(は|本体|log)'
  '（で(機械|配線|skip)'
  '[(（][。．]'
  '、[。．]'
  '`[^`]+` は[[:space:]]+[、）]'
  '[[:space:]]{2,}で修正'
  '[(（][[:space:]]*:[[:space:]]'
  '[[:space:]]{2,}では'
  '、[[:space:]]+がまさに'
  '、[[:space:]]+と同じ'
  '、[[:space:]]+が消した'
)
deletion_residue_samples=(
  'context (で rationale'
  'context (の rationale'
  'machine-gated since)'
  'stdout emit、):'
  'tracked by .'
  'approved by .'
  "half of 's contract"
  'pattern.POSIX'
  '理由、）'
  'reason,)'
  'silently.(The next sentence)'
  '集合を構築。helper と対称) |'
  'helper が emit、 で LLM'
  '完了。 以降'
  '(の実測必須ゲート'
  'helper が emit**、 で LLM'
  '. D-01 requirement'
  'intentionally frozen.)'
  'AC-1.)'
  'other, ; next'
  'Static contract tests for : workflow'
  '。 D-01 requirement'
  '。 で本体'
  '（で機械比率計算'
  '(。TMPDIR'
  '環境制約、。'
  '`updated_at` は 、'
  '点を  で修正'
  '(: missing rationale'
  'run —  では nine cycles'
  '完了してしまい、 がまさに'
  '環境制約、 と同じ扱い'
  '拒否され、 が消した'
)
deletion_residue_pattern=$(IFS='|'; printf '%s' "${deletion_residue_patterns[*]}")
scan_deletion_residue() {
  local manifest
  manifest=$(mktemp)
  local file grep_rc grep_bin="${DELETION_GREP_BIN:-grep}"
  if ! find "$@" -type f ! -path '*/fixtures/*' \
    ! -name 'number-reference-check.test.sh' -print0 > "$manifest"; then
    rm -f "$manifest"
    return 2
  fi
  while IFS= read -r -d '' file; do
    grep_rc=0
    "$grep_bin" -En "$deletion_residue_pattern" "$file" >/dev/null || grep_rc=$?
    case "$grep_rc" in
      0) rm -f "$manifest"; return 0 ;;
      1) ;;
      *) rm -f "$manifest"; return 2 ;;
    esac
  done < "$manifest"
  rm -f "$manifest"
  return 1
}
for i in "${!deletion_residue_patterns[@]}"; do
  if printf '%s\n' "${deletion_residue_samples[$i]}" | grep -Eq "${deletion_residue_patterns[$i]}"; then
    pass "deletion-damage matcher arm $((i + 1)) has a positive control"
  else
    fail "deletion-damage matcher arm $((i + 1)) missed its positive control"
  fi
done
if ! printf '%s\n' 'context with durable rationale' | grep -Eq "$deletion_residue_pattern"; then
  pass "deletion-damage matcher accepts valid prose"
else
  fail "deletion-damage matcher rejected valid prose"
fi
scan_rc=0
scan_deletion_residue "$REPO_ROOT/plugins/rite" "$REPO_ROOT/docs" || scan_rc=$?
case "$scan_rc" in
  1) pass "deletion-damage residue is absent" ;;
  0) fail "deletion-damage residue found under plugins/rite or docs" ;;
  *) fail "deletion-damage residue scan failed operationally" ;;
esac
scan_rc=0
scan_deletion_residue "$sb/definitely-missing-root" 2>/dev/null || scan_rc=$?
if [ "$scan_rc" -eq 2 ]; then
  pass "deletion-damage scan fails closed when a scan root is unavailable"
else
  fail "deletion-damage scan did not distinguish an unavailable root (rc=$scan_rc)"
fi
scan_fixture="$sb/deletion-scan-fixture"
mkdir -p "$scan_fixture"
printf '%s\n' "${deletion_residue_samples[0]}" > "$scan_fixture/residue.md"
scan_rc=0
scan_deletion_residue "$scan_fixture" || scan_rc=$?
if [ "$scan_rc" -eq 0 ]; then
  pass "deletion-damage scan reports residue found through the scan helper"
else
  fail "deletion-damage scan missed helper-level residue (rc=$scan_rc)"
fi
grep_fail_shim="$sb/grep-fail"
printf '%s\n' '#!/bin/bash' 'exit 2' > "$grep_fail_shim"
chmod +x "$grep_fail_shim"
scan_rc=0
DELETION_GREP_BIN="$grep_fail_shim" scan_deletion_residue "$scan_fixture" || scan_rc=$?
if [ "$scan_rc" -eq 2 ]; then
  pass "deletion-damage scan fails closed on grep operational errors"
else
  fail "deletion-damage scan misclassified a grep operational error (rc=$scan_rc)"
fi

if ! print_summary "$(basename "$0")" \
  "drift: number-reference-check.sh CLI / grammar / path exclusions / SKILL wiring"; then
  exit 1
fi
