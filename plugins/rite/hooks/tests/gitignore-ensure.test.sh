#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
source "$SCRIPT_DIR/../gitignore-ensure.sh"

SBX=$(make_plain_sandbox)
GITSBX=$(make_sandbox)
trap 'rm -rf -- "$SBX" "$GITSBX"' EXIT
target="$SBX/runtime"; mkdir -p "$target"

_ensure_dir_gitignore "$target"
assert "missing exclusion is created" "*" "$(cat "$target/.gitignore")"

: > "$target/.gitignore"
_ensure_dir_gitignore "$target"
assert "empty exclusion is repaired" "*" "$(cat "$target/.gitignore")"

printf '%s\n' '!keep' > "$target/.gitignore"
_ensure_dir_gitignore "$target"
assert "non-empty caller policy is preserved" "!keep" "$(cat "$target/.gitignore")"

mkdir -p "$SBX/not-a-dir"
printf '%s' occupied > "$SBX/not-a-dir/.gitignore"
_ensure_dir_gitignore "$SBX/not-a-dir/.gitignore" >/dev/null 2>&1; rc=$?
assert "write failure is returned" "1" "$rc"
assert "write failure exposes a cause" "0" "$([ -n "$_RITE_GITIGNORE_ERROR" ]; echo $?)"

_ensure_dir_gitignore "$SBX/not-a-dir/.gitignore" '!wiki/' '!wiki/**' >/dev/null 2>&1; extra_fail_rc=$?
assert "T-07 extra-args write failure is returned" "1" "$extra_fail_rc"
assert "T-07 extra-args write failure exposes a cause" "0" "$([ -n "$_RITE_GITIGNORE_ERROR" ]; echo $?)"

HOOKS_DIR="$SCRIPT_DIR/.."
star_only_callers=(
  "$HOOKS_DIR/review-result-save.sh"
  "$HOOKS_DIR/scripts/review-results-archive-or-rm.sh"
  "$HOOKS_DIR/release-promotion-verify.sh"
)
generation_callers=(
  "$HOOKS_DIR/session-start.sh"
  "$HOOKS_DIR/flow-state.sh"
)
for caller in "${star_only_callers[@]}"; do
  assert "$(basename "$caller") uses the shared primitive exactly once" "1" \
    "$(grep -c '_ensure_dir_gitignore ' "$caller" || true)"
done
for caller in "${generation_callers[@]}"; do
  assert "$(basename "$caller") uses the shared primitive twice (star-only + .rite/ extra-args)" "2" \
    "$(grep -c '_ensure_dir_gitignore ' "$caller" || true)"
  extra_args_hits=$(grep -cF "_ensure_dir_gitignore \"\$STATE_ROOT/.rite\" '!wiki/' '!wiki/**'" "$caller" || true)
  assert "$(basename "$caller") .rite/ generation point passes wiki extra-args" "1" "$extra_args_hits"
done
mkdir_else=$(grep -c 'nested gitignore not written' "$HOOKS_DIR/session-start.sh" || true)
assert "session-start warns when .rite mkdir fails" "1" "$mkdir_else"
raw_writers=$(LC_ALL=C grep -nF "printf '*\\n'" "${star_only_callers[@]}" "${generation_callers[@]}" 2>/dev/null || true)
assert "production callers contain no private star-only writer" "" "$raw_writers"

# T-01: extra-args write is exactly `*\n!wiki/\n!wiki/**\n` (order + trailing newline)
rite_dir="$SBX/rite-root"; mkdir -p "$rite_dir"
_ensure_dir_gitignore "$rite_dir" '!wiki/' '!wiki/**'
t01_rc=$?
assert "T-01 extra-args success rc" "0" "$t01_rc"
assert "T-01 extra-args error is empty" "" "$_RITE_GITIGNORE_ERROR"
printf '*\n!wiki/\n!wiki/**\n' > "$SBX/expected-rite-gitignore"
cmp -s "$rite_dir/.gitignore" "$SBX/expected-rite-gitignore"
assert "T-01 nested gitignore is star then wiki negations with trailing newline" "0" "$?"

# T-05: one-argument call still writes `*` only and returns success
one_arg="$SBX/one-arg"; mkdir -p "$one_arg"
_ensure_dir_gitignore "$one_arg"
t05_rc=$?
assert "T-05 one-arg success rc" "0" "$t05_rc"
assert "T-05 one-arg error is empty" "" "$_RITE_GITIGNORE_ERROR"
printf '*\n' > "$SBX/expected-star"
cmp -s "$one_arg/.gitignore" "$SBX/expected-star"
assert "T-05 one-argument call writes a single star line" "0" "$?"

# T-06: extra-args do not overwrite a non-empty file
printf '%s\n' '!keep' > "$rite_dir/.gitignore"
_ensure_dir_gitignore "$rite_dir" '!wiki/' '!wiki/**'
assert "T-06 non-empty file is preserved under extra-args" "!keep" "$(cat "$rite_dir/.gitignore")"

# T-02 / T-03 / T-04: git-backed sandbox. Probe files must exist before git add
# (missing pathspec is rc=128 on git 2.43+). wiki-worktree is ignored by `*`
# (the `!wiki/` negation does not re-include the adjacent name).
mkdir -p "$GITSBX/.rite/wiki/raw" "$GITSBX/.rite/state" "$GITSBX/.rite/wiki-worktree"
printf 'page\n' > "$GITSBX/.rite/wiki/raw/page.md"
printf 'lock\n' > "$GITSBX/.rite/state/lock"
printf 'tmp\n' > "$GITSBX/.rite/tmp-artifacts.tsv"
printf 'wt\n' > "$GITSBX/.rite/wiki-worktree/x"
_ensure_dir_gitignore "$GITSBX/.rite" '!wiki/' '!wiki/**'

t02_out=$(git -C "$GITSBX" add --dry-run .rite/wiki/raw/page.md 2>&1); t02_rc=$?
assert "T-02 git add --dry-run wiki page rc=0 (empty repo, nested only)" "0" "$t02_rc"
case "$t02_out" in
  *"add '.rite/wiki/raw/page.md'"*) pass "T-02 stdout contains add of wiki page" ;;
  *) fail "T-02 stdout contains add of wiki page (actual='$t02_out')" ;;
esac

git -C "$GITSBX" check-ignore -q .rite/state/lock; t03_lock=$?
git -C "$GITSBX" check-ignore -q .rite/tmp-artifacts.tsv; t03_tmp=$?
git -C "$GITSBX" check-ignore -q .rite/wiki-worktree/; t03_wt=$?
assert "T-03 .rite/state/lock is ignored" "0" "$t03_lock"
assert "T-03 .rite/tmp-artifacts.tsv is ignored" "0" "$t03_tmp"
assert "T-03 .rite/wiki-worktree/ is ignored (adjacent name is not re-included by !wiki/)" "0" "$t03_wt"

git -C "$GITSBX" check-ignore -q .rite/.gitignore; t04_rc=$?
assert "T-04 .rite/.gitignore itself is ignored" "0" "$t04_rc"

# Composition: nested !wiki/** last-matches over a root `.rite/wiki/` exclusion
# (Sub-1 SoT; Sub-3 owns health-check/setup). Pin the measured override, do not
# restore the root exclusion.
printf '.rite/wiki/\n' > "$GITSBX/.gitignore"
t02b_out=$(git -C "$GITSBX" add --dry-run .rite/wiki/raw/page.md 2>&1); t02b_rc=$?
assert "T-02 composition nested wins over root .rite/wiki/ (rc=0)" "0" "$t02b_rc"
case "$t02b_out" in
  *"add '.rite/wiki/raw/page.md'"*) pass "T-02 composition stdout contains add of wiki page" ;;
  *) fail "T-02 composition stdout contains add of wiki page (actual='$t02b_out')" ;;
esac
t02b_ignore=$(git -C "$GITSBX" check-ignore -v .rite/wiki/raw/page.md 2>&1 || true)
case "$t02b_ignore" in
  *'!wiki/**'*) pass "T-02 composition last match is nested !wiki/**" ;;
  *) fail "T-02 composition last match is nested !wiki/** (actual='$t02b_ignore')" ;;
esac

print_summary "gitignore-ensure.sh"
