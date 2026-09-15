#!/bin/bash
# Tests for wiki-ingest-commit.sh
# Usage: bash plugins/rite/hooks/tests/wiki-ingest-commit.test.sh
#
# Coverage scope:
# - same_branch path: static pins on the `_sb_dump` stderr helper.
# - separate_branch legacy path: a real git fixture drives the cleanup branch
#   where checkout-back fails, and pins the pasteable manual-recovery commands
#   (word splitting, line order, the stash step appearing only when a stash
#   exists, and that running them lets a re-run ingest the raw source).
# - separate_branch automatic restore after a failed wiki commit: the raw
#   sources come back unstaged, so a re-run ingests them.
#   The separate_branch `dump_git_err` invocations stay out of scope.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/../scripts/wiki-ingest-commit.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

echo "=== wiki-ingest-commit.sh tests ==="
echo ""

if [ ! -f "$HOOK_SRC" ]; then
  echo "ERROR: $HOOK_SRC not found" >&2
  exit 1
fi

# --- TC-SB-DUMP: same_branch strategy ships a _sb_dump stderr helper ---
# The shared dump_git_err helper is declared further down in the file under
# the separate_branch block, so the same_branch path needs its own local
# helper to surface git stderr. Without it, git add / commit failures
# collapse into an opaque "ERROR" line with no root cause.
echo "TC-SB-DUMP: same_branch defines and uses _sb_dump helper"
if grep -qE '^[[:space:]]*_sb_dump\(\)' "$HOOK_SRC"; then
  pass "_sb_dump function is defined"
else
  fail "_sb_dump function missing — same_branch git failures lose stderr context"
fi
echo ""

# --- TC-SB-CALL: _sb_dump is invoked on both git add and git commit failure ---
echo "TC-SB-CALL: _sb_dump is called from both git failure branches"
add_calls=$(grep -cE '_sb_dump "add"' "$HOOK_SRC" || true)
commit_calls=$(grep -cE '_sb_dump "commit"' "$HOOK_SRC" || true)
if [ "$add_calls" -ge 1 ] && [ "$commit_calls" -ge 1 ]; then
  pass "_sb_dump invoked from both git add and git commit failure paths"
else
  fail "_sb_dump call missing (add=$add_calls, commit=$commit_calls) — silent failure regression possible"
fi
echo ""

# --- TC-RECOVERY-PASTE: checkout-back failure prints pasteable recovery commands ---
# The legacy separate_branch path fails its wiki commit (pre-commit hook), then
# a git stub fails only the checkout back to the working branch. cleanup_body
# must keep the staging dir and print commands whose values survive shell
# word splitting even when the branch name and TMPDIR contain apostrophes.
real_git=$(command -v git)
fixture_dirs=()
trap 'rm -rf ${fixture_dirs[@]+"${fixture_dirs[@]}"}' EXIT

eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected='$2' actual='$3')"; fi; }

# split_words <cmd>: word count, then one word per line; non-zero if <cmd> does not parse.
# Runs outside any repository so a regressed hint chaining a git command cannot touch one.
split_words() { ( cd "$base" && export GIT_DIR=/nonexistent && eval "set -- $1" && printf '%s\n' "$#" "$@" ) 2>/dev/null; }

# check_words <what> <cmd> <expected word>...: pins every word of <cmd>; clears the caller's ok on mismatch.
check_words() {
  local what="$1" cmd="$2"; shift 2
  local out i
  if ! out=$(split_words "$cmd"); then
    fail "$label: $what parses as shell words (cmd=$cmd)"; ok=0; return
  fi
  mapfile -t words <<<"$out"
  eq "$label: $what word count" "$#" "${words[0]:-}"
  [ "${words[0]:-}" = "$#" ] || ok=0
  for ((i = 1; i <= $#; i++)); do
    eq "$label: $what word $i" "${!i}" "${words[$i]:-}"
    [ "${words[$i]:-}" = "${!i}" ] || ok=0
  done
}

# make_fixture <branch> <stash>: sets base / repo / tmpdir for a separate_branch repo whose
# wiki commit fails. <stash>=no commits rite-config.yml so the run has nothing to stash.
make_fixture() {
  local branch="$1" stash="$2"
  base=$(mktemp -d); fixture_dirs+=("$base")
  repo="$base/repo"

  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  printf '.rite/state/\n' >> "$repo/.git/info/exclude"
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm seed
  git -C "$repo" branch -M "$branch"
  git -C "$repo" switch -qc wiki
  printf 'wiki seed\n' > "$repo/wiki.md"
  git -C "$repo" add wiki.md
  git -C "$repo" commit -qm 'wiki seed'
  git -C "$repo" switch -q "$branch"
  printf '%s\n' 'wiki:' '  enabled: true' '  branch_strategy: separate_branch' '  branch_name: wiki' > "$repo/rite-config.yml"
  if [ "$stash" = no ]; then
    git -C "$repo" add rite-config.yml
    git -C "$repo" commit -qm config
  fi
  mkdir -p "$repo/.rite/wiki/raw/reviews"
  printf 'raw source\n' > "$repo/.rite/wiki/raw/reviews/pr-test.md"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"
  git init -q --bare "$base/origin.git"
  git -C "$repo" remote add origin "$base/origin.git"
}

# rerun_ingest <label> <branch>: with the pre-commit failure removed, the hook must ingest
# the raw source instead of stopping on a leftover index entry.
rerun_ingest() {
  local label="$1" branch="$2" out rc=0
  rm -f "$repo/.git/hooks/pre-commit"
  out=$(cd "$repo" && TMPDIR="$tmpdir" bash "$HOOK_SRC" 2>"$base/rerun-err") || rc=$?
  eq "$label: re-run exits 0" "0" "$rc"
  eq "$label: re-run reports no invariant violation" "0" "$(grep -c 'invariant violation' "$base/rerun-err" || true)"
  eq "$label: re-run commits one raw source" "1" \
    "$(printf '%s\n' "$out" | grep -c '^\[wiki-ingest-commit\] committed=1; branch=wiki; ' || true)"
  eq "$label: raw source is committed on the wiki branch" "raw source" \
    "$(git -C "$repo" show wiki:.rite/wiki/raw/reviews/pr-test.md 2>/dev/null || true)"
  eq "$label: re-run returns to the working branch" "$branch" "$(git -C "$repo" branch --show-current)"
  eq "$label: re-run leaves no raw source on the working branch" "" \
    "$(git -C "$repo" status --porcelain -- .rite/wiki/raw)"
}

run_recovery_case() {
  local label="$1" branch="$2" tmp_name="$3" stash="$4"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo stub marker tmpdir err rc n p q line path cmd1 cmd2 cmd4 cmd5 words ok=1
  make_fixture "$branch" "$stash"
  stub="$base/stub"; marker="$base/checkout-failures"; err="$base/err"
  tmpdir="$base/$tmp_name"; mkdir "$tmpdir" "$stub"
  {
    printf '%s\n' '#!/bin/bash'
    printf 'if [ "$#" -eq 2 ] && [ "$1" = checkout ] && [ "$2" = %q ]; then\n' "$branch"
    printf '  printf "%%s\\n" "$2" >> %q\n' "$marker"
    printf '%s\n' '  exit 1' 'fi'
    printf 'exec %q "$@"\n' "$real_git"
  } > "$stub/git"
  chmod +x "$stub/git"

  rc=0
  ( cd "$repo" && PATH="$stub:$PATH" TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?

  eq "$label: fixture has no wiki worktree" "0" "$([ -d "$repo/.rite/wiki-worktree" ] && echo 1 || echo 0)"
  eq "$label: exits 3" "3" "$rc"
  eq "$label: wiki commit failed once" "1" "$(grep -cxF "ERROR: git commit failed on 'wiki'" "$err" || true)"
  eq "$label: stub failed only the checkout back to the working branch" "$branch" "$(cat "$marker" 2>/dev/null || true)"
  eq "$label: raw sources were not restored in place" "0" "$(grep -c '^INFO: restored' "$err" || true)"

  # err_line <n>: line n of stderr, empty when n is not a positive line number.
  err_line() { case "$1" in ''|0|*[!0-9]*) ;; *) sed -n "$1p" "$err" ;; esac; }

  eq "$label: checkout-back WARNING appears once with literal quoting" "1" \
    "$(grep -cxF "WARNING: cleanup failed to return to '$branch'" "$err" || true)"
  n=$(grep -nxF "WARNING: cleanup failed to return to '$branch'" "$err" | head -1 | cut -d: -f1 || true)
  n=${n:-0}
  # The numbered steps below are the single recovery procedure, so the stash is popped once.
  eq "$label: checkout-back WARNING points at the numbered steps" \
    " manual recovery: follow the numbered steps after the staging directory WARNING below" "$(err_line $((n + 1)))"
  if [ "$stash" = yes ]; then
    eq "$label: stash-left-intact note follows the pointer" \
      " (stash is intentionally left intact to avoid cross-branch pop)" "$(err_line $((n + 2)))"
  else
    eq "$label: no stash-left-intact note without a stash" "0" \
      "$(grep -c '^ (stash is intentionally left intact' "$err" || true)"
  fi
  eq "$label: stash pop is printed only in the numbered steps" "$([ "$stash" = yes ] && echo 1 || echo 0)" \
    "$(grep -c 'git stash pop' "$err" || true)"

  eq "$label: staging-preserved WARNING appears once" "1" \
    "$(grep -c '^WARNING: staging directory preserved at ' "$err" || true)"
  p=$(grep -n '^WARNING: staging directory preserved at ' "$err" | head -1 | cut -d: -f1 || true)
  p=${p:-0}
  line=$(err_line "$p")
  path=${line#WARNING: staging directory preserved at }
  path=${path% (raw sources not restored)}
  eq "$label: WARNING names the preserved staging dir under TMPDIR" "1" \
    "$([[ "$path" == "$tmpdir"/rite-wiki-stage-* ]] && [ -d "$path" ] && echo 1 || echo 0)"
  eq "$label: checkout-back reason line keeps literal quoting" \
    " (checkout-back to '$branch' failed earlier; copying now would write onto the wiki branch)" "$(err_line $((p + 1)))"
  eq "$label: manual recovery heading follows" " manual recovery:" "$(err_line $((p + 2)))"
  # Steps in order: checkout, unstage, [stash pop], copy back, clean up.
  q=$((p + 3))
  line=$(err_line "$q"); cmd1=${line#" 1) resolve the branch state: "}
  eq "$label: step 1 line shape" " 1) resolve the branch state: $cmd1" "$line"
  q=$((q + 1)); line=$(err_line "$q"); cmd2=${line#" 2) unstage raw sources carried over from the wiki branch: "}
  eq "$label: step 2 line shape" " 2) unstage raw sources carried over from the wiki branch: $cmd2" "$line"
  if [ "$stash" = yes ]; then
    q=$((q + 1)); line=$(err_line "$q")
    eq "$label: stash step follows the unstage step" " 3) restore stashed changes: git stash pop" "$line"
  else
    eq "$label: no stash step without a stash" "0" "$(grep -c 'restore stashed changes' "$err" || true)"
  fi
  q=$((q + 1)); line=$(err_line "$q"); cmd4=${line#" $((q - p - 2))) copy staged raw sources back: "}
  eq "$label: copy step line shape" " $((q - p - 2))) copy staged raw sources back: $cmd4" "$line"
  q=$((q + 1)); line=$(err_line "$q"); cmd5=${line#" $((q - p - 2))) clean up: "}
  eq "$label: clean-up step line shape" " $((q - p - 2))) clean up: $cmd5" "$line"
  eq "$label: clean-up step is the last recovery line" "" "$(err_line $((q + 1)))"

  check_words "step 1" "$cmd1" git checkout "$branch"
  check_words "step 2" "$cmd2" git reset -q -- .rite/wiki/raw
  check_words "copy step" "$cmd4" cp -r "$path/." .rite/wiki/raw/
  check_words "clean-up step" "$cmd5" rm -rf "$path"

  # Run the pasted steps only once every word matched, so a regression cannot
  # hand a split path to rm -rf.
  if [ "$ok" -eq 1 ]; then
    rc=0
    (
      cd "$repo" && eval "$cmd1" && eval "$cmd2" &&
        { [ "$stash" = no ] || git stash pop; } && eval "$cmd4" && eval "$cmd5"
    ) >/dev/null 2>&1 || rc=$?
    eq "$label: pasted steps succeed" "0" "$rc"
    eq "$label: back on the working branch" "$branch" "$(git -C "$repo" branch --show-current)"
    eq "$label: no raw source left staged" "" "$(git -C "$repo" diff --cached --name-only)"
    eq "$label: stash restored" "0" "$(git -C "$repo" stash list | wc -l | tr -d ' ')"
    eq "$label: raw source restored" "raw source" "$(cat "$repo/.rite/wiki/raw/reviews/pr-test.md" 2>/dev/null || true)"
    eq "$label: staging dir removed" "0" "$([ -e "$path" ] && echo 1 || echo 0)"
    rerun_ingest "$label" "$branch"
  else
    fail "$label: pasted steps not run because the command words did not match"
  fi
}

# write_stub <stub dir> <condition>: a git wrapper that exits 1 when <condition> holds.
write_stub() {
  mkdir -p "$1"
  {
    printf '%s\n' '#!/bin/bash'
    printf 'if %s; then exit 1; fi\n' "$2"
    printf 'exec %q "$@"\n' "$real_git"
  } > "$1/git"
  chmod +x "$1/git"
}

# run_checkout_hint_case: the wiki commit and push succeed but checkout-back fails, so no
# staging dir is preserved and the checkout-back WARNING carries the pasteable command.
run_checkout_hint_case() {
  local label="$1" branch="$2" stash="$3"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 n line back words ok=1
  local stash_tail=" && git stash pop"
  make_fixture "$branch" "$stash"
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  rm -f "$repo/.git/hooks/pre-commit"
  write_stub "$base/stub" "[ \"\$#\" -eq 2 ] && [ \"\$1\" = checkout ] && [ \"\$2\" = $(printf '%q' "$branch") ]"

  ( cd "$repo" && PATH="$base/stub:$PATH" TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 0" "0" "$rc"
  eq "$label: no staging dir preserved" "0" "$(grep -c '^WARNING: staging directory preserved' "$err" || true)"
  eq "$label: checkout-back WARNING appears once" "1" \
    "$(grep -cxF "WARNING: cleanup failed to return to '$branch'" "$err" || true)"
  n=$(grep -nxF "WARNING: cleanup failed to return to '$branch'" "$err" | head -1 | cut -d: -f1 || true)
  line=$(sed -n "$((${n:-0} + 1))p" "$err")
  back=${line#" manual recovery: "}
  eq "$label: checkout recovery hint follows the WARNING" " manual recovery: $back" "$line"
  if [ "$stash" = yes ]; then
    eq "$label: hint ends with stash pop" "$stash_tail" "${back: -${#stash_tail}}"
    eq "$label: stash-left-intact note follows the hint" \
      " (stash is intentionally left intact to avoid cross-branch pop)" "$(sed -n "$((${n:-0} + 2))p" "$err")"
    back=${back%"$stash_tail"}
  else
    eq "$label: no stash pop without a stash" "0" "$(grep -c 'git stash pop' "$err" || true)"
  fi
  check_words "checkout hint" "$back" git checkout "$branch"
}

# run_auto_restore_case: checkout-back succeeds after the failed wiki commit, so
# cleanup_body restores the raw source itself and must not leave it staged.
run_auto_restore_case() {
  local label="$1" branch="$2" stash="$3"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0
  make_fixture "$branch" "$stash"
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"

  ( cd "$repo" && TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 3" "3" "$rc"
  eq "$label: wiki commit failed once" "1" "$(grep -cxF "ERROR: git commit failed on 'wiki'" "$err" || true)"
  eq "$label: raw source restored in place" "1" "$(grep -cxF 'INFO: restored 1/1 raw source(s) back to the dev branch working tree after failure (rc=3)' "$err" || true)"
  eq "$label: no cleanup WARNING" "0" "$(grep -c '^WARNING: ' "$err" || true)"
  eq "$label: back on the working branch" "$branch" "$(git -C "$repo" branch --show-current)"
  eq "$label: no raw source left staged" "" "$(git -C "$repo" diff --cached --name-only)"
  eq "$label: raw source is untracked on the working branch" ".rite/wiki/raw/reviews/pr-test.md" \
    "$(git -C "$repo" ls-files --others --exclude-standard -- .rite/wiki/raw)"
  eq "$label: raw source content kept" "raw source" "$(cat "$repo/.rite/wiki/raw/reviews/pr-test.md" 2>/dev/null || true)"
  eq "$label: stash popped" "0" "$(git -C "$repo" stash list | wc -l | tr -d ' ')"
  eq "$label: rite-config.yml present" "1" "$([ -f "$repo/rite-config.yml" ] && echo 1 || echo 0)"
  rerun_ingest "$label" "$branch"
}

# run_unstage_failure_case: when the unstage itself fails, cleanup says so and prints
# the command to run by hand.
run_unstage_failure_case() {
  local label="$1"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 n line cmd words ok=1
  make_fixture dev no
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  write_stub "$base/stub" '[ "$1" = reset ]'

  ( cd "$repo" && PATH="$base/stub:$PATH" TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 3" "3" "$rc"
  eq "$label: unstage WARNING appears once" "1" \
    "$(grep -cxF "WARNING: cleanup failed to unstage raw sources carried back from 'wiki'" "$err" || true)"
  n=$(grep -nxF "WARNING: cleanup failed to unstage raw sources carried back from 'wiki'" "$err" | head -1 | cut -d: -f1 || true)
  line=$(sed -n "$((${n:-0} + 1))p" "$err")
  cmd=${line#" manual recovery: "}
  eq "$label: unstage hint follows the WARNING" " manual recovery: $cmd" "$line"
  check_words "unstage hint" "$cmd" git reset -q -- .rite/wiki/raw
  eq "$label: raw source is still staged as reported" ".rite/wiki/raw/reviews/pr-test.md" \
    "$(git -C "$repo" diff --cached --name-only)"
}

# run_pre_checkout_failure_case: a failure before the wiki checkout (a raw source staged on
# the working branch) must leave the index alone so the invariant ERROR's hint still applies.
run_pre_checkout_failure_case() {
  local label="$1"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0
  make_fixture dev no
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  git -C "$repo" add .rite/wiki/raw/reviews/pr-test.md

  ( cd "$repo" && TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 3" "3" "$rc"
  eq "$label: invariant violation reported once" "1" "$(grep -c "is tracked on 'dev' — invariant violation" "$err" || true)"
  eq "$label: raw source stays staged" ".rite/wiki/raw/reviews/pr-test.md" "$(git -C "$repo" diff --cached --name-only)"
}

echo "TC-RECOVERY-PASTE: checkout-back failure prints pasteable recovery commands"
run_recovery_case "apostrophe" "it's-dev" "it's tmp" yes
run_recovery_case "plain" "dev" "tmp" yes
run_recovery_case "no stash" "dev" "tmp" no
run_checkout_hint_case "hint apostrophe" "it's-dev" yes
run_checkout_hint_case "hint no stash" "dev" no
echo ""

echo "TC-AUTO-RESTORE: failed wiki commit restores the raw source unstaged"
run_auto_restore_case "auto restore" "dev" yes
run_auto_restore_case "auto restore no stash" "dev" no
run_unstage_failure_case "unstage failure"
run_pre_checkout_failure_case "pre-checkout failure"
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
