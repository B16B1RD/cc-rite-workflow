#!/bin/bash
# Tests for wiki-ingest-commit.sh
# Usage: bash plugins/rite/hooks/tests/wiki-ingest-commit.test.sh
#
# Coverage scope:
# - same_branch path: static pins on the `_sb_dump` stderr helper.
# - separate_branch legacy path: a real git fixture drives the cleanup branch
#   where checkout-back fails, and pins the pasteable manual-recovery commands
#   (word splitting, line order, and that running them restores the raw source).
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
split_words() { ( eval "set -- $1" && printf '%s\n' "$#" "$@" ) 2>/dev/null; }

run_recovery_case() {
  local label="$1" branch="$2" tmp_name="$3"
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local base repo stub marker tmpdir err rc n p line path cmd1 cmd2 cmd3 back words ok=1
  local stash_tail=" && git stash pop"
  base=$(mktemp -d); fixture_dirs+=("$base")
  repo="$base/repo"; stub="$base/stub"; marker="$base/checkout-failures"; err="$base/err"
  tmpdir="$base/$tmp_name"; mkdir "$tmpdir" "$stub"

  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
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
  mkdir -p "$repo/.rite/wiki/raw/reviews"
  printf 'raw source\n' > "$repo/.rite/wiki/raw/reviews/pr-test.md"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"
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
  line=$(err_line $((n + 1)))
  back=${line#" manual recovery: "}
  eq "$label: stash recovery hint follows the WARNING" " manual recovery: $back" "$line"
  eq "$label: stash recovery hint ends with stash pop" "$stash_tail" "${back: -${#stash_tail}}"
  eq "$label: stash-left-intact note follows the hint" \
    " (stash is intentionally left intact to avoid cross-branch pop)" "$(err_line $((n + 2)))"
  back=${back%"$stash_tail"}

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
  line=$(err_line $((p + 3))); cmd1=${line#" 1) resolve the branch state: "}
  eq "$label: step 1 line shape" " 1) resolve the branch state: $cmd1" "$line"
  line=$(err_line $((p + 4))); cmd2=${line#" 2) copy staged raw sources back: "}
  eq "$label: step 2 line shape" " 2) copy staged raw sources back: $cmd2" "$line"
  line=$(err_line $((p + 5))); cmd3=${line#" 3) clean up: "}
  eq "$label: step 3 line shape" " 3) clean up: $cmd3" "$line"

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
  check_words "stash recovery checkout" "$back" git checkout "$branch"
  check_words "step 1" "$cmd1" git checkout "$branch"
  check_words "step 2" "$cmd2" cp -r "$path/." .rite/wiki/raw/
  check_words "step 3" "$cmd3" rm -rf "$path"

  # Run the pasted steps only once every word matched, so a regression cannot
  # hand a split path to rm -rf.
  if [ "$ok" -eq 1 ]; then
    rc=0
    ( cd "$repo" && eval "$cmd1" && eval "$cmd2" && eval "$cmd3" ) >/dev/null 2>&1 || rc=$?
    eq "$label: pasted steps 1-3 succeed" "0" "$rc"
    eq "$label: back on the working branch" "$branch" "$(git -C "$repo" branch --show-current)"
    eq "$label: raw source restored" "raw source" "$(cat "$repo/.rite/wiki/raw/reviews/pr-test.md" 2>/dev/null || true)"
    eq "$label: staging dir removed" "0" "$([ -e "$path" ] && echo 1 || echo 0)"
  else
    fail "$label: pasted steps not run because the command words did not match"
  fi
}

echo "TC-RECOVERY-PASTE: checkout-back failure prints pasteable recovery commands"
run_recovery_case "apostrophe" "it's-dev" "it's tmp"
run_recovery_case "plain" "dev" "tmp"
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
