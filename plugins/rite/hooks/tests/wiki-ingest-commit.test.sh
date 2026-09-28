#!/bin/bash
# Tests for wiki-ingest-commit.sh
# Usage: bash plugins/rite/hooks/tests/wiki-ingest-commit.test.sh
#
# Coverage scope:
# - same_branch path: static pins on the `_sb_dump` stderr helper, and a failed
#   commit that unstages only the raw sources it added (or, when that unstage
#   fails, prints the pasteable command, which names the main checkout even
#   when run from a linked worktree).
# - separate_branch legacy path: a real git fixture drives the cleanup branch
#   where checkout-back fails, and pins the pasteable manual-recovery commands
#   (word splitting, line order, the stash step appearing only when a stash
#   exists, and that running them lets a re-run ingest the raw source). Every
#   pasted git command names the main checkout with -C, and the steps are run
#   from outside the repository to show they do not depend on the caller's cwd.
#   The stash hints pop only the entry this run pushed, found by its SHA, and another
#   entry pushed on top meanwhile stays in the shared stack.
#   The unstage, stash pop, untrack, push, fetch and detached HEAD hints are pinned
#   the same way, the unstage and detached HEAD hints also when the hook runs from a
#   linked worktree.
# - separate_branch wiki worktree path: a failed push from a linked worktree prints
#   a hint naming the wiki worktree by its absolute path.
# - separate_branch automatic restore after a failed wiki commit: the raw
#   sources come back unstaged without disturbing unrelated staged files, so a
#   re-run ingests them.
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

# stash_pop_cmd <root> <sha>: the pasteable command that pops only the stash entry <sha>.
stash_pop_cmd() {
  printf 'git -C %q stash pop "$(git -C %q stash list --format='"'"'%%gd %%H'"'"' | awk -v s=%s '"'"'$2 == s {print $1}'"'"')"' \
    "$1" "$1" "$2"
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
  local base repo root stub marker tmpdir err rc n p q line path cmd1 cmd2 cmd3 cmd4 cmd5 words ok=1
  make_fixture "$branch" "$stash"
  root=$(cd "$repo" && pwd -P)
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
    "$(grep -c ' stash pop' "$err" || true)"
  eq "$label: no hint pops the top entry" "0" "$(grep -cE ' stash pop( #|$)|stash@\{0\}' "$err" || true)"

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
    q=$((q + 1)); line=$(err_line "$q"); cmd3=${line#" 3) restore stashed changes: "}
    eq "$label: stash step follows the unstage step" " 3) restore stashed changes: $cmd3" "$line"
    own_sha=$(git -C "$repo" stash list --format=%H | head -1)
    eq "$label: stash step pops our entry by its SHA" "$(stash_pop_cmd "$root" "$own_sha")" "$cmd3"
  else
    eq "$label: no stash step without a stash" "0" "$(grep -c 'restore stashed changes' "$err" || true)"
  fi
  q=$((q + 1)); line=$(err_line "$q"); cmd4=${line#" $((q - p - 2))) copy staged raw sources back: "}
  eq "$label: copy step line shape" " $((q - p - 2))) copy staged raw sources back: $cmd4" "$line"
  q=$((q + 1)); line=$(err_line "$q"); cmd5=${line#" $((q - p - 2))) clean up: "}
  eq "$label: clean-up step line shape" " $((q - p - 2))) clean up: $cmd5" "$line"
  eq "$label: clean-up step is the last recovery line" "" "$(err_line $((q + 1)))"

  check_words "step 1" "$cmd1" git -C "$root" checkout "$branch"
  check_words "step 2" "$cmd2" git -C "$root" reset -q -- .rite/wiki/raw
  check_words "copy step" "$cmd4" cp -r "$path/." "$root/.rite/wiki/raw/"
  check_words "clean-up step" "$cmd5" rm -rf "$path"

  # Run the pasted steps only once every word matched, so a regression cannot
  # hand a split path to rm -rf. They run from outside the repository, where a
  # step that relies on the caller's cwd fails.
  if [ "$ok" -eq 1 ]; then
    rc=0
    ( cd "$base" && eval "$cmd1" ) >/dev/null 2>&1 || rc=$?
    (
      git -C "$repo" rm -q --cached -- .rite/wiki/raw/reviews/pr-test.md &&
        rm -f "$repo/.rite/wiki/raw/reviews/pr-test.md"
    ) || rc=$?
    eq "$label: negative control removes raw source from the working tree" "0" \
      "$([ -e "$repo/.rite/wiki/raw/reviews/pr-test.md" ] && echo 1 || echo 0)"
    eq "$label: negative control removes raw source from the index" "" \
      "$(git -C "$repo" diff --cached --name-only -- .rite/wiki/raw/reviews/pr-test.md)"

    ( cd "$base" && eval "$cmd2" ) >/dev/null 2>&1 || rc=$?
    other_sha=""
    if [ "$stash" = yes ]; then
      # Another session pushes on top of the shared stack before the stash step is pasted.
      printf 'other session\n' > "$repo/other.txt"
      git -C "$repo" stash push -q -u -m other -- other.txt || rc=$?
      other_sha=$(git -C "$repo" rev-parse -q --verify refs/stash || true)
      ( cd "$base" && eval "$cmd3" ) >/dev/null 2>&1 || rc=$?
    fi
    eq "$label: raw source is absent immediately before the copy step" "0" \
      "$([ -e "$repo/.rite/wiki/raw/reviews/pr-test.md" ] && echo 1 || echo 0)"
    eq "$label: raw source remains absent from the index before the copy step" "" \
      "$(git -C "$repo" diff --cached --name-only -- .rite/wiki/raw/reviews/pr-test.md)"

    ( cd "$base" && eval "$cmd4" ) >/dev/null 2>&1 || rc=$?
    eq "$label: copy step restores the raw source" "raw source" \
      "$(cat "$repo/.rite/wiki/raw/reviews/pr-test.md" 2>/dev/null || true)"
    ( cd "$base" && eval "$cmd5" ) >/dev/null 2>&1 || rc=$?
    eq "$label: pasted steps succeed" "0" "$rc"
    eq "$label: back on the working branch" "$branch" "$(git -C "$repo" branch --show-current)"
    eq "$label: no raw source left staged" "" "$(git -C "$repo" diff --cached --name-only)"
    eq "$label: only the other session's entry is left" "$other_sha" "$(git -C "$repo" stash list --format=%H)"
    if [ "$stash" = yes ]; then
      eq "$label: our stashed file is back" "1" "$([ -f "$repo/rite-config.yml" ] && echo 1 || echo 0)"
      eq "$label: the other entry was not applied" "0" "$([ -e "$repo/other.txt" ] && echo 1 || echo 0)"
    fi
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
  local base repo root tmpdir err rc=0 n line back words ok=1 stash_tail
  make_fixture "$branch" "$stash"
  root=$(cd "$repo" && pwd -P)
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
    stash_tail=" && $(stash_pop_cmd "$root" "$(git -C "$repo" stash list --format=%H | head -1)")"
    eq "$label: hint ends with the SHA-based stash pop" "$stash_tail" "${back: -${#stash_tail}}"
    eq "$label: stash-left-intact note follows the hint" \
      " (stash is intentionally left intact to avoid cross-branch pop)" "$(sed -n "$((${n:-0} + 2))p" "$err")"
    back=${back%"$stash_tail"}
  else
    eq "$label: no stash pop without a stash" "0" "$(grep -c ' stash pop' "$err" || true)"
  fi
  check_words "checkout hint" "$back" git -C "$root" checkout "$branch"
}

# run_auto_restore_case: checkout-back succeeds after the failed wiki commit, so
# cleanup_body restores the raw source itself and must not leave it staged.
run_auto_restore_case() {
  local label="$1" branch="$2" stash="$3"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0
  make_fixture "$branch" "$stash"
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  if [ "$stash" = yes ]; then
    printf 'user work\n' > "$repo/user.txt"
    git -C "$repo" add user.txt
  fi

  ( cd "$repo" && TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 3" "3" "$rc"
  eq "$label: wiki commit failed once" "1" "$(grep -cxF "ERROR: git commit failed on 'wiki'" "$err" || true)"
  eq "$label: raw source restored in place" "1" "$(grep -cxF 'INFO: restored 1/1 raw source(s) back to the dev branch working tree after failure (rc=3)' "$err" || true)"
  eq "$label: no cleanup WARNING" "0" "$(grep -c '^WARNING: ' "$err" || true)"
  eq "$label: back on the working branch" "$branch" "$(git -C "$repo" branch --show-current)"
  if [ "$stash" = yes ]; then
    eq "$label: unrelated user file stays staged" "user.txt" \
      "$(git -C "$repo" diff --cached --name-only)"
    git -C "$repo" reset -q -- user.txt
  else
    eq "$label: no raw source left staged" "" "$(git -C "$repo" diff --cached --name-only)"
  fi
  eq "$label: raw source is untracked on the working branch" ".rite/wiki/raw/reviews/pr-test.md" \
    "$(git -C "$repo" ls-files --others --exclude-standard -- .rite/wiki/raw)"
  eq "$label: raw source content kept" "raw source" "$(cat "$repo/.rite/wiki/raw/reviews/pr-test.md" 2>/dev/null || true)"
  eq "$label: stash popped" "0" "$(git -C "$repo" stash list | wc -l | tr -d ' ')"
  eq "$label: rite-config.yml present" "1" "$([ -f "$repo/rite-config.yml" ] && echo 1 || echo 0)"
  rerun_ingest "$label" "$branch"
}

# A raw source that was already ingested is not part of pending_files, but it
# can still be staged by the user before the run.  Failure cleanup must unstage
# wiki-carried entries before stash pop so the user's original index is restored.
run_auto_restore_preserves_staged_raw_case() {
  local label="$1"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 staged_raw
  make_fixture dev yes
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  staged_raw=".rite/wiki/raw/reviews/old.md"
  printf '%s\n' '---' 'ingested: true' '---' 'old raw source' > "$repo/$staged_raw"
  git -C "$repo" add "$staged_raw"

  ( cd "$repo" && TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 3" "3" "$rc"
  eq "$label: user-staged raw stays staged" "$staged_raw" \
    "$(git -C "$repo" diff --cached --name-only -- "$staged_raw")"
  eq "$label: user-staged raw content kept" "old raw source" \
    "$(tail -1 "$repo/$staged_raw" 2>/dev/null || true)"
  eq "$label: pending raw is restored untracked" ".rite/wiki/raw/reviews/pr-test.md" \
    "$(git -C "$repo" ls-files --others --exclude-standard -- .rite/wiki/raw/reviews/pr-test.md)"
  eq "$label: pending raw is not staged" "" \
    "$(git -C "$repo" diff --cached --name-only -- .rite/wiki/raw/reviews/pr-test.md)"
  eq "$label: no cleanup WARNING" "0" "$(grep -c '^WARNING: ' "$err" || true)"
}

# run_unstage_failure_case <label> [<from>]: when the unstage itself fails, cleanup says so
# and prints the command to run by hand. <from>=worktree runs the hook from a linked worktree.
run_unstage_failure_case() {
  local label="$1" from="${2:-main}"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 n line cmd words ok=1 run_dir
  make_fixture dev no
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  write_stub "$base/stub" '[ "$1" = reset ]'
  run_dir="$repo"
  if [ "$from" = worktree ]; then
    git -C "$repo" worktree add -q --detach "$base/wt"
    run_dir="$base/wt"
  fi

  ( cd "$run_dir" && PATH="$base/stub:$PATH" TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 3" "3" "$rc"
  eq "$label: unstage WARNING appears once" "1" \
    "$(grep -cxF "WARNING: cleanup failed to unstage raw sources carried back from 'wiki'" "$err" || true)"
  n=$(grep -nxF "WARNING: cleanup failed to unstage raw sources carried back from 'wiki'" "$err" | head -1 | cut -d: -f1 || true)
  line=$(sed -n "$((${n:-0} + 1))p" "$err")
  cmd=${line#" manual recovery: "}
  eq "$label: unstage hint follows the WARNING" " manual recovery: $cmd" "$line"
  check_words "unstage hint" "$cmd" git -C "$(cd "$repo" && pwd -P)" reset -q -- .rite/wiki/raw
  if [ "$from" = worktree ]; then
    eq "$label: unstage hint does not name the calling worktree" "different" \
      "$([ "${words[3]:-}" != "$(cd "$run_dir" && pwd -P)" ] && echo different || echo same)"
  fi
  eq "$label: raw source is still staged as reported" ".rite/wiki/raw/reviews/pr-test.md" \
    "$(git -C "$repo" diff --cached --name-only)"
  eq "$label: raw source restoration continues after unstage failure" "1" \
    "$(grep -cxF 'INFO: restored 1/1 raw source(s) back to the dev branch working tree after failure (rc=3)' "$err" || true)"
}

# run_pre_checkout_failure_case: a failure before the wiki checkout (a raw source staged on
# the working branch) must leave the index alone so the invariant ERROR's hint still applies.
# <raw> (default pr-test.md) is the raw source file name; its `git rm --cached` hint must
# split back into that one path even when the name contains an apostrophe.
run_pre_checkout_failure_case() {
  local label="$1" raw="${2:-pr-test.md}"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 line cmd words ok=1
  make_fixture dev no
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  if [ "$raw" != pr-test.md ]; then
    mv "$repo/.rite/wiki/raw/reviews/pr-test.md" "$repo/.rite/wiki/raw/reviews/$raw"
  fi
  git -C "$repo" add ".rite/wiki/raw/reviews/$raw"

  ( cd "$repo" && TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 3" "3" "$rc"
  eq "$label: invariant violation reported once" "1" "$(grep -c "is tracked on 'dev' — invariant violation" "$err" || true)"
  eq "$label: raw source stays staged" ".rite/wiki/raw/reviews/$raw" "$(git -C "$repo" diff --cached --name-only)"
  eq "$label: git rm --cached hint printed once" "1" "$(grep -c '^ 1) git -C .* rm --cached ' "$err" || true)"
  line=$(grep '^ 1) git -C .* rm --cached ' "$err" || true)
  cmd=${line#" 1) "}
  check_words "untrack hint" "$cmd" git -C "$(cd "$repo" && pwd -P)" rm --cached ".rite/wiki/raw/reviews/$raw"
}

# run_concurrent_stash_case: another session pushes a stash entry while the wiki commit runs.
# cleanup must pop the entry this run pushed (by SHA), not the other one on top.
run_concurrent_stash_case() {
  local label="$1"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 other_sha
  make_fixture dev yes
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  mkdir -p "$base/stub"
  {
    printf '%s\n' '#!/bin/bash'
    printf 'if [ "$1" = commit ] && [ ! -e %q ]; then\n' "$base/pushed"
    printf '  : > %q\n' "$base/pushed"
    printf '  printf "other session\\n" > %q\n' "$repo/other.txt"
    printf '  %q -C %q stash push -q -u -m other -- other.txt\n' "$real_git" "$repo"
    printf '  %q -C %q rev-parse refs/stash > %q\n' "$real_git" "$repo" "$base/other_sha"
    printf 'fi\n'
    printf 'exec %q "$@"\n' "$real_git"
  } > "$base/stub/git"
  chmod +x "$base/stub/git"

  ( cd "$repo" && PATH="$base/stub:$PATH" TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  other_sha=$(cat "$base/other_sha" 2>/dev/null || true)
  eq "$label: exits 3" "3" "$rc"
  eq "$label: another entry was pushed during the run" "1" "$([ -n "$other_sha" ] && echo 1 || echo 0)"
  eq "$label: no cleanup WARNING" "0" "$(grep -c '^WARNING: ' "$err" || true)"
  eq "$label: only the other session's entry is left" "$other_sha" "$(git -C "$repo" stash list --format=%H)"
  eq "$label: our stashed file is back" "1" "$([ -f "$repo/rite-config.yml" ] && echo 1 || echo 0)"
  eq "$label: the other entry was not applied" "0" "$([ -e "$repo/other.txt" ] && echo 1 || echo 0)"
}

# run_noop_stash_push_case: git stash push exits 0 without saving anything while another
# entry is on the stack. The run must stop before it could pop that entry as its own.
run_noop_stash_push_case() {
  local label="$1"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 other_sha
  make_fixture dev yes
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  printf 'other session\n' > "$repo/other.txt"
  git -C "$repo" stash push -q -u -m other -- other.txt
  other_sha=$(git -C "$repo" rev-parse refs/stash)
  mkdir -p "$base/stub"
  {
    printf '%s\n' '#!/bin/bash'
    printf 'if [ "$1" = stash ] && [ "$2" = push ]; then exit 0; fi\n'
    printf 'exec %q "$@"\n' "$real_git"
  } > "$base/stub/git"
  chmod +x "$base/stub/git"

  ( cd "$repo" && PATH="$base/stub:$PATH" TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 3" "3" "$rc"
  eq "$label: reports the missing entry" "1" \
    "$(grep -cxF 'ERROR: git stash push did not create a new entry; refusing to continue without our own stash' "$err" || true)"
  eq "$label: the other entry stays on the stack" "$other_sha" "$(git -C "$repo" stash list --format=%H)"
  eq "$label: the other entry was not applied" "0" "$([ -e "$repo/other.txt" ] && echo 1 || echo 0)"
}

# run_submodule_change_case <label> <mode>: the only change is inside a submodule — dirty
# content (dirty), a gitlink moved by a commit inside it (moved), or both (moved_dirty).
# git stash push -u saves none of these, so the run must not treat them as work to stash; it
# commits the raw source, leaves the stash stack alone and keeps the submodule state.
# A moved gitlink that is staged (staged) cannot be carried across the wiki checkout: the run
# stops there with git's own reason, restores the raw source and leaves the index as it was.
run_submodule_change_case() {
  local label="$1" mode="$2"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0
  make_fixture dev no
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  rm -f "$repo/.git/hooks/pre-commit"
  git init -q "$base/sub"
  git -C "$base/sub" -c user.email=t@e -c user.name=t commit -q --allow-empty -m s
  printf 'x\n' > "$base/sub/f"
  git -C "$base/sub" add f
  git -C "$base/sub" -c user.email=t@e -c user.name=t commit -q -m f
  git -C "$repo" -c protocol.file.allow=always submodule add -q "$base/sub" sub
  git -C "$repo" commit -q -m addsub
  local moved_head=""
  case "$mode" in moved|moved_dirty|staged)
    git -C "$repo/sub" -c user.email=t@e -c user.name=t commit -q --allow-empty -m moved
    moved_head=$(git -C "$repo/sub" rev-parse HEAD) ;;
  esac
  case "$mode" in dirty|moved_dirty) printf 'dirty\n' >> "$repo/sub/f" ;; esac
  [ "$mode" = staged ] && git -C "$repo" add sub

  ( cd "$repo" && TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >"$base/out" 2>"$err" || rc=$?
  if [ "$mode" = staged ]; then
    eq "$label: exits 3" "3" "$rc"
    eq "$label: stops at the wiki checkout" "1" "$(grep -cxF "ERROR: git checkout 'wiki' failed" "$err" || true)"
    eq "$label: git names the submodule" "1" "$(grep -c 'overwritten by checkout' "$err" || true)"
    eq "$label: no new-entry ERROR" "0" "$(grep -c 'did not create a new entry' "$err" || true)"
    eq "$label: raw source is back untracked" ".rite/wiki/raw/reviews/pr-test.md" \
      "$(git -C "$repo" ls-files --others --exclude-standard -- .rite/wiki/raw)"
    eq "$label: staged gitlink still points at the moved commit" "$moved_head" \
      "$(git -C "$repo" ls-files -s sub | awk '{print $2}')"
    eq "$label: stash stack untouched" "0" "$(git -C "$repo" stash list | wc -l | tr -d ' ')"
    return
  fi
  eq "$label: exits 0" "0" "$rc"
  eq "$label: commits the raw source" "1" "$(grep -c 'committed=1' "$base/out" || true)"
  eq "$label: no new-entry ERROR" "0" "$(grep -c 'did not create a new entry' "$err" || true)"
  eq "$label: stash stack untouched" "0" "$(git -C "$repo" stash list | wc -l | tr -d ' ')"
  case "$mode" in dirty|moved_dirty)
    eq "$label: submodule content still dirty" "1" "$(grep -c '^dirty$' "$repo/sub/f" || true)" ;;
  esac
  if [ -n "$moved_head" ]; then
    eq "$label: submodule stays on its moved commit" "$moved_head" "$(git -C "$repo/sub" rev-parse HEAD)"
  fi
}

# run_stash_pop_failure_case: the wiki commit fails and the stash pop in cleanup fails too,
# so the WARNING carries the stash commands to run by hand.
run_stash_pop_failure_case() {
  local label="$1"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo root tmpdir err rc=0 n own_sha
  make_fixture dev yes
  root=$(cd "$repo" && pwd -P)
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  write_stub "$base/stub" '[ "$1" = stash ] && [ "$2" = pop ]'

  ( cd "$repo" && PATH="$base/stub:$PATH" TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 3" "3" "$rc"
  eq "$label: stash pop WARNING appears once" "1" "$(grep -cxF 'WARNING: cleanup failed to pop stash' "$err" || true)"
  n=$(grep -nxF 'WARNING: cleanup failed to pop stash' "$err" | head -1 | cut -d: -f1 || true)
  eq "$label: manual recovery heading follows" " manual recovery:" "$(sed -n "$((${n:-0} + 1))p" "$err")"
  own_sha=$(git -C "$repo" stash list --format=%H | head -1)
  eq "$label: stash list hint names our entry" " git -C $root stash list --format='%gd %H' | grep $own_sha" \
    "$(sed -n "$((${n:-0} + 2))p" "$err")"
  eq "$label: stash pop hint pops our entry by its SHA" " $(stash_pop_cmd "$root" "$own_sha") # resolve conflicts if any" \
    "$(sed -n "$((${n:-0} + 3))p" "$err")"
}

# run_push_failure_case: the wiki commit lands but the push fails, so the WARNING carries the push command.
run_push_failure_case() {
  local label="$1"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 line cmd words ok=1
  make_fixture dev no
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  rm -f "$repo/.git/hooks/pre-commit"
  git -C "$repo" remote set-url origin "$base/missing.git"

  ( cd "$repo" && TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 4" "4" "$rc"
  eq "$label: push hint printed once" "1" "$(grep -c '^ manual recovery: git -C ' "$err" || true)"
  line=$(grep '^ manual recovery: git -C ' "$err" || true)
  cmd=${line#" manual recovery: "}
  check_words "push hint" "$cmd" git -C "$(cd "$repo" && pwd -P)" push origin wiki
}

# run_missing_wiki_branch_case: without a local wiki branch the hook stops and prints the fetch command.
run_missing_wiki_branch_case() {
  local label="$1"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 line cmd words ok=1
  make_fixture dev no
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  git -C "$repo" branch -q -D wiki

  ( cd "$repo" && TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 2" "2" "$rc"
  eq "$label: fetch hint printed once" "1" "$(grep -c '^ 1) git -C .* # fresh clone' "$err" || true)"
  line=$(grep '^ 1) git -C .* # fresh clone' "$err" || true)
  cmd=${line#" 1) "}
  cmd=${cmd%% # fresh clone*}
  check_words "fetch hint" "$cmd" git -C "$(cd "$repo" && pwd -P)" fetch origin wiki:wiki
}

# run_detached_head_case: the main checkout is on a detached HEAD and the hook runs from a
# linked worktree, so the hint must switch the main checkout rather than the calling worktree.
run_detached_head_case() {
  local label="$1"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 line cmd words ok=1
  make_fixture dev no
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  git -C "$repo" worktree add -q --detach "$base/wt"
  git -C "$repo" switch -q --detach

  ( cd "$base/wt" && TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 1" "1" "$rc"
  eq "$label: detached HEAD hint printed once" "1" "$(grep -c '^ hint: checkout a named branch first (e.g. ' "$err" || true)"
  line=$(grep '^ hint: checkout a named branch first (e.g. ' "$err" || true)
  cmd=${line#" hint: checkout a named branch first (e.g. "}
  cmd=${cmd%)}
  check_words "detached HEAD hint" "$cmd" git -C "$(cd "$repo" && pwd -P)" checkout develop
  eq "$label: detached HEAD hint does not name the calling worktree" "different" \
    "$([ "${words[3]:-}" != "$(cd "$base/wt" && pwd -P)" ] && echo different || echo same)"
}

# run_fast_path_push_failure_case: with the wiki worktree in place the hook commits there, and a
# failed push prints a hint whose -C is the absolute wiki worktree path even from a linked worktree.
run_fast_path_push_failure_case() {
  local label="$1"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo tmpdir err rc=0 line cmd words ok=1
  make_fixture dev no
  tmpdir="$base/tmp"; err="$base/err"; mkdir "$tmpdir"
  rm -f "$repo/.git/hooks/pre-commit"
  printf '.rite/wiki-worktree/\n' >> "$repo/.git/info/exclude"
  git -C "$repo" worktree add -q "$repo/.rite/wiki-worktree" wiki
  git -C "$repo" remote set-url origin "$base/missing.git"
  git -C "$repo" worktree add -q --detach "$base/wt"

  ( cd "$base/wt" && TMPDIR="$tmpdir" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 4" "4" "$rc"
  eq "$label: raw source is committed in the wiki worktree" "raw source" \
    "$(git -C "$repo" show wiki:.rite/wiki/raw/reviews/pr-test.md 2>/dev/null || true)"
  eq "$label: push hint printed once" "1" "$(grep -c '^ manual recovery: git -C .* push origin wiki$' "$err" || true)"
  line=$(grep '^ manual recovery: git -C .* push origin wiki$' "$err" || true)
  cmd=${line#" manual recovery: "}
  check_words "push hint" "$cmd" git -C "$(cd "$repo" && pwd -P)/.rite/wiki-worktree" push origin wiki
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
run_auto_restore_preserves_staged_raw_case "auto restore preserves user staging"
run_unstage_failure_case "unstage failure"
run_unstage_failure_case "unstage failure from a linked worktree" worktree
run_stash_pop_failure_case "stash pop failure"
run_concurrent_stash_case "concurrent stash"
run_noop_stash_push_case "no-op stash push"
run_submodule_change_case "dirty submodule" dirty
run_submodule_change_case "moved submodule" moved
run_submodule_change_case "moved and dirty submodule" moved_dirty
run_submodule_change_case "staged submodule" staged
run_push_failure_case "push failure"
run_missing_wiki_branch_case "missing wiki branch"
run_detached_head_case "detached main checkout from a linked worktree"
run_fast_path_push_failure_case "wiki worktree push failure from a linked worktree"
run_pre_checkout_failure_case "pre-checkout failure"
run_pre_checkout_failure_case "pre-checkout failure (apostrophe raw name)" "it's pr-test.md"
echo ""

echo "TC-MESSAGE: same_branch default / --message-file / convention fail-loud"
# make_same_branch_msg_fixture: sets base / repo for a same_branch repo with one pending raw source.
# Call it directly, not via $(...): a subshell would drop the fixture_dirs entry and leak $base.
make_same_branch_msg_fixture() {
  base=$(mktemp -d); fixture_dirs+=("$base")
  repo="$base/repo"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm seed
  git -C "$repo" branch -M develop
  printf '%s\n' 'wiki:' '  enabled: true' '  branch_strategy: same_branch' '  branch_name: wiki' > "$repo/rite-config.yml"
  git -C "$repo" add rite-config.yml
  git -C "$repo" commit -qm config
  mkdir -p "$repo/.rite/wiki/raw/reviews"
  printf '%s\n' '---' 'ingested: false' '---' 'raw' > "$repo/.rite/wiki/raw/reviews/pr-test.md"
}

run_same_branch_message_cases() {
  local base repo rc out err msg n_dirs
  n_dirs=${#fixture_dirs[@]}
  make_same_branch_msg_fixture
  eq "same_branch fixture registers one dir for cleanup" "$((n_dirs + 1))" "${#fixture_dirs[@]}"
  eq "same_branch fixture registers its base for cleanup" "$base" "${fixture_dirs[n_dirs]:-}"
  eq "same_branch fixture repo lives under its base" "$base/repo" "$repo"
  eq "same_branch fixture repo is a git repository" "1" "$([ -d "$repo/.git" ] && echo 1 || echo 0)"
  rc=0
  out=$(cd "$repo" && bash "$HOOK_SRC" 2>/dev/null) || rc=$?
  eq "same_branch default exits 0" "0" "$rc"
  eq "same_branch default subject" "chore(wiki): ingest 1 raw source(s)" "$(git -C "$repo" log -1 --format=%s)"

  make_same_branch_msg_fixture
  printf 'English only.\n' > "$repo/CLAUDE.md"
  rc=0
  err=$(cd "$repo" && bash "$HOOK_SRC" 2>&1) || rc=$?
  eq "CLAUDE.md without --message-file exits 1" "1" "$rc"
  eq "fail-loud names --message-file" "1" "$(printf '%s' "$err" | grep -c -- '--message-file' || true)"
  eq "fail-loud leaves no staged raw" "" "$(git -C "$repo" diff --cached --name-only)"
  eq "fail-loud leaves working tree on develop" "develop" "$(git -C "$repo" branch --show-current)"

  make_same_branch_msg_fixture
  printf 'English only.\n' > "$repo/CLAUDE.md"
  msg=$(mktemp)
  printf 'docs(wiki): ingest with `tick`\n\n$(whoami) stays literal\n' > "$msg"
  rc=0
  (cd "$repo" && bash "$HOOK_SRC" --message-file "$msg") >/dev/null || rc=$?
  eq "--message-file with CLAUDE.md exits 0" "0" "$rc"
  eq "--message-file subject" "docs(wiki): ingest with \`tick\`" "$(git -C "$repo" log -1 --format=%s)"
  eq "--message-file keeps command-like body" "1" \
    "$(git -C "$repo" log -1 --format=%b | grep -cF '$(whoami) stays literal' || true)"
  rm -f "$msg"

  # Empty and missing values must fail at parse time. Folding either into
  # "unspecified" would commit the default subject when no convention file
  # exists, and would take the convention fail-loud path only when one does.
  reject_message_file() {
    local label="$1" repo="$2"
    shift 2
    local rc=0 err head_before
    head_before=$(git -C "$repo" rev-parse HEAD)
    err=$(cd "$repo" && bash "$HOOK_SRC" "$@" 2>&1) || rc=$?
    eq "$label exits 1" "1" "$rc"
    eq "$label names required value" "1" \
      "$(printf '%s' "$err" | grep -cF -- '--message-file requires a value' || true)"
    eq "$label does not move HEAD" "$head_before" "$(git -C "$repo" rev-parse HEAD)"
    eq "$label stays on develop" "develop" "$(git -C "$repo" branch --show-current)"
    eq "$label does not commit the default subject" "0" \
      "$(git -C "$repo" log --format=%s | grep -cF 'chore(wiki): ingest 1 raw source(s)' || true)"
  }

  make_same_branch_msg_fixture
  reject_message_file "no convention empty --message-file" "$repo" --message-file ""
  make_same_branch_msg_fixture
  reject_message_file "no convention missing --message-file value" "$repo" --message-file
  make_same_branch_msg_fixture
  printf 'English only.\n' > "$repo/CLAUDE.md"
  reject_message_file "CLAUDE.md empty --message-file" "$repo" --message-file ""
  make_same_branch_msg_fixture
  printf 'English only.\n' > "$repo/CLAUDE.md"
  reject_message_file "CLAUDE.md missing --message-file value" "$repo" --message-file
}
run_same_branch_message_cases

echo ""

echo "TC-SB-RESTORE: a failed same_branch commit leaves the raw sources unstaged"
# run_same_branch_failure_case <label> <reset> [<from>]: the commit fails (pre-commit hook).
# <reset>=ok: only the added raw source is unstaged; a raw source the user staged stays.
# <reset>=fail: the unstage fails too, and the WARNING carries the pasteable command.
# <from>=worktree: the hook runs from a linked worktree, whose index is not the one staged.
run_same_branch_failure_case() {
  local label="$1" reset="$2" from="${3:-main}"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo err rc=0 n line cmd words ok=1 path_prefix="" run_dir
  make_same_branch_msg_fixture
  err="$base/err"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"
  printf '%s\n' '---' 'ingested: true' '---' 'done' > "$repo/.rite/wiki/raw/reviews/done.md"
  git -C "$repo" add .rite/wiki/raw/reviews/done.md
  if [ "$reset" = fail ]; then
    write_stub "$base/stub" "[ \"\$1\" = reset ] && echo 'fatal: stub reset' >&2"
    path_prefix="$base/stub:"
  fi
  run_dir="$repo"
  if [ "$from" = worktree ]; then
    git -C "$repo" worktree add -q --detach "$base/wt"
    run_dir="$base/wt"
  fi
  ( cd "$run_dir" && PATH="$path_prefix$PATH" bash "$HOOK_SRC" ) >/dev/null 2>"$err" || rc=$?
  eq "$label: exits 3" "3" "$rc"
  eq "$label: HEAD is unchanged" "config" "$(git -C "$repo" log -1 --format=%s)"
  if [ "$reset" = ok ]; then
    eq "$label: only the user's raw source stays staged" ".rite/wiki/raw/reviews/done.md" \
      "$(git -C "$repo" diff --cached --name-only)"
    eq "$label: pending raw source is back in the working tree untracked" ".rite/wiki/raw/reviews/pr-test.md" \
      "$(git -C "$repo" ls-files --others --exclude-standard -- .rite/wiki/raw)"
    eq "$label: no unstage WARNING" "0" "$(grep -c '^WARNING: ' "$err" || true)"
    return
  fi
  eq "$label: unstage WARNING appears once" "1" \
    "$(grep -cxF 'WARNING: failed to unstage the raw sources after the failed commit' "$err" || true)"
  n=$(grep -nxF 'WARNING: failed to unstage the raw sources after the failed commit' "$err" | head -1 | cut -d: -f1 || true)
  line=$(sed -n "$((${n:-0} + 1))p" "$err")
  cmd=${line#" manual recovery: "}
  eq "$label: unstage hint follows the WARNING" " manual recovery: $cmd" "$line"
  check_words "unstage hint" "$cmd" git -C "$(cd "$repo" && pwd -P)" reset -q -- .rite/wiki/raw/reviews/pr-test.md
  if [ "$from" = worktree ]; then
    eq "$label: unstage hint does not name the calling worktree" "different" \
      "$([ "${words[3]:-}" != "$(cd "$run_dir" && pwd -P)" ] && echo different || echo same)"
  fi
  eq "$label: the reset stderr follows the hint" "  git (reset): fatal: stub reset" \
    "$(sed -n "$((${n:-0} + 2))p" "$err")"
  eq "$label: raw sources are still staged as reported" \
    "$(printf '%s\n' .rite/wiki/raw/reviews/done.md .rite/wiki/raw/reviews/pr-test.md)" \
    "$(git -C "$repo" diff --cached --name-only)"
}
run_same_branch_failure_case "same_branch restore" ok
run_same_branch_failure_case "same_branch unstage failure" fail
run_same_branch_failure_case "same_branch unstage failure from a linked worktree" fail worktree

echo ""

echo "TC-MESSAGE: separate_branch legacy resolves before wiki checkout"
run_legacy_convention_fail_loud() {
  local base repo rc=0 err wiki_before
  base=$(mktemp -d); fixture_dirs+=("$base")
  repo="$base/repo"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm seed
  git -C "$repo" branch -M develop
  git -C "$repo" switch -qc wiki
  printf 'wiki seed\n' > "$repo/wiki.md"
  git -C "$repo" add wiki.md
  git -C "$repo" commit -qm 'wiki seed'
  git -C "$repo" switch -q develop
  printf '%s\n' 'wiki:' '  enabled: true' '  branch_strategy: separate_branch' '  branch_name: wiki' > "$repo/rite-config.yml"
  git -C "$repo" add rite-config.yml
  git -C "$repo" commit -qm config
  printf 'English only.\n' > "$repo/CLAUDE.md"
  git -C "$repo" add CLAUDE.md
  git -C "$repo" commit -qm claude
  mkdir -p "$repo/.rite/wiki/raw/reviews"
  printf '%s\n' '---' 'ingested: false' '---' 'raw' > "$repo/.rite/wiki/raw/reviews/pr-test.md"
  git init -q --bare "$base/origin.git"
  git -C "$repo" remote add origin "$base/origin.git"
  git -C "$repo" push -q origin wiki
  wiki_before=$(git -C "$repo" rev-parse wiki)
  err=$(cd "$repo" && bash "$HOOK_SRC" 2>&1) || rc=$?
  eq "legacy CLAUDE.md without --message-file exits 1" "1" "$rc"
  eq "legacy fail-loud names --message-file" "1" "$(printf '%s' "$err" | grep -c -- '--message-file' || true)"
  eq "legacy fail-loud ends on develop" "develop" "$(git -C "$repo" branch --show-current)"
  eq "legacy fail-loud does not move wiki HEAD" "$wiki_before" "$(git -C "$repo" rev-parse wiki)"
  eq "legacy fail-loud leaves no wiki worktree residue" "0" \
    "$([ -d "$repo/.rite/wiki-worktree" ] && echo 1 || echo 0)"
}
run_legacy_convention_fail_loud

echo ""

echo "TC-MESSAGE: leftover tempfile pins"
leftover_wic() {
  find "$1" -name 'rite-wic-*' 2>/dev/null | wc -l | tr -d '[:space:]'
}

run_same_branch_fail_loud_leftover() {
  local base repo tmp rc=0
  make_same_branch_msg_fixture
  printf 'English only.\n' > "$repo/CLAUDE.md"
  tmp=$(mktemp -d); fixture_dirs+=("$tmp")
  ( cd "$repo" && TMPDIR="$tmp" bash "$HOOK_SRC" ) >/dev/null 2>&1 || rc=$?
  eq "same_branch fail-loud leftover exits 1" "1" "$rc"
  eq "same_branch fail-loud leftover rite-wic count" "0" "$(leftover_wic "$tmp")"
}
run_same_branch_fail_loud_leftover

run_legacy_fail_loud_leftover() {
  local base repo tmp rc=0
  base=$(mktemp -d); fixture_dirs+=("$base")
  repo="$base/repo"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm seed
  git -C "$repo" branch -M develop
  git -C "$repo" switch -qc wiki
  printf 'wiki seed\n' > "$repo/wiki.md"
  git -C "$repo" add wiki.md
  git -C "$repo" commit -qm 'wiki seed'
  git -C "$repo" switch -q develop
  printf '%s\n' 'wiki:' '  enabled: true' '  branch_strategy: separate_branch' '  branch_name: wiki' > "$repo/rite-config.yml"
  git -C "$repo" add rite-config.yml
  git -C "$repo" commit -qm config
  printf 'English only.\n' > "$repo/CLAUDE.md"
  git -C "$repo" add CLAUDE.md
  git -C "$repo" commit -qm claude
  mkdir -p "$repo/.rite/wiki/raw/reviews"
  printf '%s\n' '---' 'ingested: false' '---' 'raw' > "$repo/.rite/wiki/raw/reviews/pr-test.md"
  tmp=$(mktemp -d); fixture_dirs+=("$tmp")
  ( cd "$repo" && TMPDIR="$tmp" bash "$HOOK_SRC" ) >/dev/null 2>&1 || rc=$?
  eq "legacy fail-loud leftover exits 1" "1" "$rc"
  eq "legacy fail-loud leftover rite-wic count" "0" "$(leftover_wic "$tmp")"
}
run_legacy_fail_loud_leftover

run_missing_branch_leftover() {
  local repo tmp msg rc=0
  repo=$(mktemp -d); fixture_dirs+=("$repo")
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm seed
  git -C "$repo" branch -M develop
  printf '%s\n' 'wiki:' '  enabled: true' '  branch_strategy: separate_branch' '  branch_name: wiki' > "$repo/rite-config.yml"
  git -C "$repo" add rite-config.yml
  git -C "$repo" commit -qm config
  mkdir -p "$repo/.rite/wiki/raw/reviews"
  printf '%s\n' '---' 'ingested: false' '---' 'raw' > "$repo/.rite/wiki/raw/reviews/pr-test.md"
  msg=$(mktemp)
  printf 'docs(wiki): leftover fixture\n' > "$msg"
  tmp=$(mktemp -d); fixture_dirs+=("$tmp")
  ( cd "$repo" && TMPDIR="$tmp" bash "$HOOK_SRC" --message-file "$msg" ) >/dev/null 2>&1 || rc=$?
  eq "missing wiki branch leftover exits 2" "2" "$rc"
  eq "missing wiki branch leftover rite-wic count" "0" "$(leftover_wic "$tmp")"
  rm -f "$msg"
}
run_missing_branch_leftover

echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
