#!/bin/bash
# Tests for worktree-git.sh non-fast-forward push retry (§9).
#
# Verifies:
#   AC-1: a push whose remote branch was advanced concurrently succeeds via
#         fetch + rebase + push retry (rc 0).
#   AC-2: a rebase-unmergeable conflict aborts and returns the existing rc=4.
#   non-NFF (auth/network-shaped) failure fails immediately with rc=4 (1 attempt,
#         no retry) — the prior behavior is preserved.
#   Each push failure prints a copy-paste `manual recovery:` command, and
#   verify_worktree_branch prints one on a broken or mis-branched worktree. Those
#   commands must split back into the exact worktree path and branch even when both
#   contain an apostrophe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
# shellcheck source=../scripts/lib/worktree-git.sh
source "$SCRIPT_DIR/../scripts/lib/worktree-git.sh"

GIT="git -c user.email=t@test.local -c user.name=test -c commit.gpgsign=false"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

# Build: a bare remote with branch $1 (default `wiki`), plus two clones (under-test + rival).
setup_remote() {
  local branch="${1:-wiki}"
  local base; base=$(make_plain_sandbox)
  cleanup_dirs+=("$base")
  $GIT init -q --bare "$base/remote.git"
  $GIT init -q -b "$branch" "$base/seed"
  ( cd "$base/seed" && echo "line1" > shared.txt && $GIT add shared.txt && $GIT commit -qm seed && $GIT push -q "$base/remote.git" "$branch" ) >/dev/null 2>&1
  $GIT clone -q -b "$branch" "$base/remote.git" "$base/under_test" >/dev/null 2>&1
  $GIT clone -q -b "$branch" "$base/remote.git" "$base/rival" >/dev/null 2>&1
  # worktree_commit_push commits via plain `git commit` (no -c flags), so the
  # under-test clone needs a persistent identity — CI runners have no global
  # git user.name/email. (rival/seed use the $GIT alias and don't need it.)
  for clone in under_test rival; do
    git -C "$base/$clone" config user.email t@test.local
    git -C "$base/$clone" config user.name test
    git -C "$base/$clone" config commit.gpgsign false
  done
  printf '%s' "$base"
}

# Advance origin/<branch> (default `wiki`) from the rival clone (simulates a concurrent session push).
rival_push() {
  local base="$1" file="$2" content="$3" branch="${4:-wiki}"
  ( cd "$base/rival" && $GIT pull -q --ff-only origin "$branch" && printf '%s\n' "$content" >> "$file" \
      && $GIT add "$file" && $GIT commit -qm "rival $file" && $GIT push -q origin "$branch" ) >/dev/null 2>&1
}

# $1 = label, $2 = stderr file. Pins that exactly one `manual recovery:` line was
# printed and sets RECOVERY_CMD to its command (a global, so the assert counts
# are not lost in a command substitution).
recovery_cmd() {
  local label="$1" err="$2" line
  assert "$label exactly one manual recovery line" "1" "$(grep -c '^ manual recovery: ' "$err" || true)"
  line=$(grep '^ manual recovery: ' "$err" || true)
  RECOVERY_CMD=${line#" manual recovery: "}
}

# $1 = label, $2 = command chain, $3 = expected number of ` && ` joins.
assert_join_count() {
  assert "$1 joins" "$3" "$(printf '%s\n' "$2" | grep -o ' && ' | wc -l | tr -d ' ')"
}

echo "=== TC-1 (AC-1): NFF push succeeds via fetch+rebase+retry (rc 0) ==="
BASE=$(setup_remote)
rival_push "$BASE" rival.txt "rival-change"          # origin/wiki now ahead
# under_test adds a NON-conflicting new file and pushes via the helper.
echo "ut-content" > "$BASE/under_test/ut.txt"
rc=0
out=$(worktree_commit_push "$BASE/under_test" wiki "ut commit" ut.txt 2>"${TMPDIR:-/tmp}/wtg1.err") || rc=$?
assert "TC-1 rc 0 (NFF resolved)" "0" "$rc"
case "$out" in *"push=ok"*) pass "TC-1 push=ok" ;; *) fail "TC-1 status line: $out" ;; esac
# The rival's file must be present (rebase pulled it in) along with ours.
assert "TC-1 rival change rebased in" "1" "$( [ -f "$BASE/under_test/rival.txt" ] && echo 1 || echo 0 )"
if grep -qiE 'non-fast-forward|rejected' "${TMPDIR:-/tmp}/wtg1.err"; then pass "TC-1 NFF retry path exercised (WARNING emitted)"; else fail "TC-1 expected NFF WARNING"; fi

echo "=== TC-2 (AC-2): rebase conflict aborts → rc 4 ==="
BASE=$(setup_remote)
rival_push "$BASE" shared.txt "rival-conflicting-line"   # rival changes shared.txt
# under_test changes the SAME file → rebase will conflict.
echo "ut-conflicting-line" >> "$BASE/under_test/shared.txt"
rc=0
worktree_commit_push "$BASE/under_test" wiki "ut conflict" shared.txt >"${TMPDIR:-/tmp}/wtg2.out" 2>"${TMPDIR:-/tmp}/wtg2.err" || rc=$?
assert "TC-2 rc 4 (rebase conflict → existing contract)" "4" "$rc"
if grep -qiE 'rebase.*(failed|conflict)|aborted' "${TMPDIR:-/tmp}/wtg2.err"; then pass "TC-2 rebase-abort WARNING emitted"; else fail "TC-2 expected rebase-abort WARNING: $(cat "${TMPDIR:-/tmp}/wtg2.err")"; fi
# After abort the worktree must NOT be left mid-rebase.
assert "TC-2 no rebase in progress left" "0" "$( [ -d "$BASE/under_test/.git/rebase-merge" ] || [ -d "$BASE/under_test/.git/rebase-apply" ] && echo 1 || echo 0 )"

echo "=== TC-3: non-NFF failure fails immediately with rc 4 (no retry) ==="
BASE=$(setup_remote)
# Point origin at a non-existent path → push fails for a non-NFF reason.
( cd "$BASE/under_test" && $GIT remote set-url origin "$BASE/does-not-exist.git" ) >/dev/null 2>&1
echo "x" > "$BASE/under_test/ut2.txt"
rc=0
worktree_commit_push "$BASE/under_test" wiki "ut nonnff" ut2.txt >"${TMPDIR:-/tmp}/wtg3.out" 2>"${TMPDIR:-/tmp}/wtg3.err" || rc=$?
assert "TC-3 rc 4 (non-NFF)" "4" "$rc"
if grep -qiE 'non-fast-forward' "${TMPDIR:-/tmp}/wtg3.err"; then fail "TC-3 must NOT take NFF retry path"; else pass "TC-3 no NFF retry (immediate fail)"; fi

# Paths and branch names below carry an apostrophe, which a hand-written '...'
# around the value would split into other arguments. Created after TC-1: its
# `$(worktree_commit_push ...)` subshell runs the EXIT cleanup trap, which would
# delete a directory registered in cleanup_dirs before it.
APOS_ROOT=$(make_plain_sandbox); cleanup_dirs+=("$APOS_ROOT")
mkdir "$APOS_ROOT/it's"
APOS_BRANCH="it's-wiki"

echo "=== TC-2b: rebase conflict under an apostrophe path + branch → fetch/rebase hint keeps each value one argument ==="
BASE=$(TMPDIR="$APOS_ROOT/it's" setup_remote "$APOS_BRANCH")
ut="$BASE/under_test"
rival_push "$BASE" shared.txt "rival-conflicting-line" "$APOS_BRANCH"
echo "ut-conflicting-line" >> "$ut/shared.txt"
rc=0
worktree_commit_push "$ut" "$APOS_BRANCH" "ut conflict" shared.txt >"$BASE/wtg2b.out" 2>"$BASE/wtg2b.err" || rc=$?
assert "TC-2b rc 4 (rebase conflict)" "4" "$rc"
recovery_cmd "TC-2b" "$BASE/wtg2b.err"; cmd=$RECOVERY_CMD
assert_join_count "TC-2b" "$cmd" 1
assert_shell_words "TC-2b fetch command" "${cmd%% && *}" git -C "$ut" fetch origin "$APOS_BRANCH"
assert_shell_words "TC-2b rebase command" "${cmd#* && }" git -C "$ut" rebase "origin/$APOS_BRANCH"

echo "=== TC-3b: non-NFF failure under an apostrophe path + branch → push hint keeps each value one argument ==="
BASE=$(TMPDIR="$APOS_ROOT/it's" setup_remote "$APOS_BRANCH")
ut="$BASE/under_test"
( cd "$ut" && $GIT remote set-url origin "$BASE/does-not-exist.git" ) >/dev/null 2>&1
echo "x" > "$ut/ut2.txt"
rc=0
worktree_commit_push "$ut" "$APOS_BRANCH" "ut nonnff" ut2.txt >"$BASE/wtg3b.out" 2>"$BASE/wtg3b.err" || rc=$?
assert "TC-3b rc 4 (non-NFF)" "4" "$rc"
recovery_cmd "TC-3b" "$BASE/wtg3b.err"; cmd=$RECOVERY_CMD
assert_join_count "TC-3b" "$cmd" 0
assert_shell_words "TC-3b push command" "$cmd" git -C "$ut" push origin "$APOS_BRANCH"

echo "=== TC-4: push rejected as non-fast-forward on every attempt → after 3 attempts, fetch/rebase/push hint ==="
# A pre-push hook that always reports a non-fast-forward rejection keeps the
# retry loop going (fetch + rebase succeed with nothing to rebase) until the cap.
BASE=$(TMPDIR="$APOS_ROOT/it's" setup_remote "$APOS_BRANCH")
ut="$BASE/under_test"
printf '#!/bin/sh\necho " ! [rejected]        HEAD -> branch (non-fast-forward)" >&2\nexit 1\n' > "$ut/.git/hooks/pre-push"
chmod +x "$ut/.git/hooks/pre-push"
echo "x" > "$ut/ut4.txt"
rc=0
worktree_commit_push "$ut" "$APOS_BRANCH" "ut always rejected" ut4.txt >"$BASE/wtg4.out" 2>"$BASE/wtg4.err" || rc=$?
assert "TC-4 rc 4 (push never accepted)" "4" "$rc"
assert_grep "TC-4 retry cap reached" "$BASE/wtg4.err" "rejected \(non-fast-forward\) after 3 attempts"
recovery_cmd "TC-4" "$BASE/wtg4.err"; cmd=$RECOVERY_CMD
assert_join_count "TC-4" "$cmd" 2
rest=${cmd#* && }
assert_shell_words "TC-4 fetch command" "${cmd%% && *}" git -C "$ut" fetch origin "$APOS_BRANCH"
assert_shell_words "TC-4 rebase command" "${rest%% && *}" git -C "$ut" rebase "origin/$APOS_BRANCH"
assert_shell_words "TC-4 push command" "${rest#* && }" git -C "$ut" push origin "$APOS_BRANCH"

echo "=== TC-5: verify_worktree_branch on a missing worktree → remove + setup hint keeps the path one argument ==="
missing="$APOS_ROOT/it's/missing-worktree"
rc=0
verify_worktree_branch "$missing" "$APOS_BRANCH" >/dev/null 2>"$APOS_ROOT/vwb5.err" || rc=$?
assert "TC-5 rc 2 (HEAD unreadable)" "2" "$rc"
assert "TC-5 exactly one 対処 line" "1" "$(grep -c '^ 対処: ' "$APOS_ROOT/vwb5.err" || true)"
line=$(grep '^ 対処: ' "$APOS_ROOT/vwb5.err" || true)
cmd=${line#" 対処: "}
setup_tail=" && bash plugins/rite/hooks/scripts/wiki-worktree-setup.sh"
assert "TC-5 hint ends with the setup step" "$setup_tail" "${cmd: -${#setup_tail}}"
assert_shell_words "TC-5 remove command" "${cmd%"$setup_tail"}" git worktree remove "$missing"

echo "=== TC-6: verify_worktree_branch on the wrong branch → checkout hint keeps path and branch one argument each ==="
BASE=$(TMPDIR="$APOS_ROOT/it's" setup_remote "$APOS_BRANCH")
ut="$BASE/under_test"
expected_branch="expected-it's"
rc=0
verify_worktree_branch "$ut" "$expected_branch" >/dev/null 2>"$BASE/vwb6.err" || rc=$?
assert "TC-6 rc 3 (branch mismatch)" "3" "$rc"
assert "TC-6 exactly one hint line" "1" "$(grep -c '^ hint: ' "$BASE/vwb6.err" || true)"
line=$(grep '^ hint: ' "$BASE/vwb6.err" || true)
assert_shell_words "TC-6 checkout command" "${line#" hint: "}" git -C "$ut" checkout "$expected_branch"

rm -f "${TMPDIR:-/tmp}/wtg1.err" "${TMPDIR:-/tmp}/wtg2.out" "${TMPDIR:-/tmp}/wtg2.err" "${TMPDIR:-/tmp}/wtg3.out" "${TMPDIR:-/tmp}/wtg3.err" 2>/dev/null || true
print_summary "$(basename "$0")" \
  "Drift hint: worktree-git.sh §9 — NFF push retry (fetch+rebase+push x3); rebase conflict → rc4; non-NFF → immediate rc4; 0/3/4/5 contract unchanged."
