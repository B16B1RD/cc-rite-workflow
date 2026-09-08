#!/bin/bash
# Tests for ensure_session_worktree (lib/worktree-git.sh) — the shared
# bash-side gate that detects + reconstructs a missing session worktree at a
# flow ENTRY path so review/iterate/fix never silently degrade onto develop.
#
#   T-01 / AC-1: branch local ∧ worktree absent → reconstructed (worktree added)
#   T-04 / AC-4: git worktree add fails → failed (rc 1, NO silent fallback, no residue)
#   T-05 / AC-5: branch absent everywhere → branch_absent (no reconstruction)
#   Plus: disabled / already_in / reenter / residue / branch_other_worktree /
#         remote-only reconstruct / explicit --branch path / marker path=/other=
#         fields / arg error / stdout discipline.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

HELPER="$SCRIPT_DIR/../scripts/lib/worktree-git.sh"

# Sandbox cleanup (suite convention — see worktree-foreign-cwd.test.sh).
cleanup_dirs=()
cleanup() { for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# Build a bare "remote" + a main clone with multi_session enabled. Sets the
# global REPO_MAIN to the main checkout path and registers the sandbox root in
# cleanup_dirs. Run in PARENT scope (NOT `$(setup_repo)`) so cleanup_dirs+= and
# REPO_MAIN propagate. Creates: develop (pushed), local branch fix/issue-42-foo,
# remote-only branch feat/issue-77-bar.
REPO_MAIN=""
setup_repo() {
  local root
  root=$(make_plain_sandbox) || return 1
  cleanup_dirs+=("$root")
  git init -q --bare "$root/remote.git"
  git init -q "$root/main"
  (
    cd "$root/main" || exit 1
    git config user.email t@t; git config user.name t
    git remote add origin ../remote.git
    printf 'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n' > rite-config.yml
    git add -A; git commit -qm init
    git branch -m develop
    git push -q -u origin develop
    git branch fix/issue-42-foo develop            # local-only feature branch
    git checkout -q -b feat/issue-77-bar develop
    echo x > x.txt; git add -A; git commit -qm work
    git push -q -u origin feat/issue-77-bar
    git checkout -q develop
    git branch -D feat/issue-77-bar                # issue-77 now remote-only
  ) >/dev/null 2>&1 || return 1
  REPO_MAIN="$root/main"
}

# Run the helper from <dir> and print the bare WT_ENSURE case token.
ens_case() {
  local dir="$1"; shift
  ( cd "$dir" && bash "$HELPER" ensure-session-worktree "$@" 2>/dev/null ) \
    | sed -n 's/.*WT_ENSURE=\([a-z_]*\).*/\1/p'
}
# Run the helper from <dir> and print the value of a marker field (e.g. path, other).
ens_field() {
  local dir="$1" field="$2"; shift 2
  ( cd "$dir" && bash "$HELPER" ensure-session-worktree "$@" 2>/dev/null ) \
    | sed -n "s/.*; ${field}=\([^;]*\).*/\1/p" | head -1
}
# Run the helper from <dir> and print its exit code.
ens_rc() {
  local dir="$1"; shift
  ( cd "$dir" && bash "$HELPER" ensure-session-worktree "$@" >/dev/null 2>&1 ); echo $?
}
# "yes"/"no": is a worktree for issue-<N> registered in <main>?
wt_registered() {
  git -C "$1" worktree list --porcelain 2>/dev/null | grep -qE "/issue-$2($|/| )" && echo yes || echo no
}
# Run the helper once, capturing stdout and stderr into the given files, and echo the exit code.
# Used when a test needs both the WT_ENSURE token AND stderr content from the SAME invocation
# (ens_case/ens_rc each re-run the helper, which would double-register the worktree).
ens_run_capture() {
  local dir="$1" out="$2" err="$3"; shift 3
  local rc
  ( cd "$dir" && bash "$HELPER" ensure-session-worktree "$@" ) >"$out" 2>"$err"
  rc=$?
  echo "$rc"
}

# --- TC-1: disabled (multi_session.enabled: false) ---
echo "=== TC-1: enabled:false → disabled (legacy single-tree, unchanged) ==="
setup_repo; M="$REPO_MAIN"
printf 'multi_session:\n  enabled: false\n  worktree_base: ".rite/worktrees"\n' > "$M/rite-config.yml"
assert "TC-1 disabled token" "disabled" "$(ens_case "$M" --issue 42)"
assert "TC-1 rc=0" "0" "$(ens_rc "$M" --issue 42)"

# --- TC-2 (T-05 / AC-5): branch absent → branch_absent, no reconstruction ---
echo "=== TC-2 (T-05/AC-5): branch nowhere → branch_absent, no worktree created ==="
setup_repo; M="$REPO_MAIN"
assert "TC-2 branch_absent token" "branch_absent" "$(ens_case "$M" --issue 99)"
assert "TC-2 no worktree created" "no" "$(wt_registered "$M" 99)"

# --- TC-3 (T-01 / AC-1): local branch ∧ worktree absent → reconstructed ---
echo "=== TC-3 (T-01/AC-1): local branch, worktree absent → reconstructed ==="
setup_repo; M="$REPO_MAIN"
assert "TC-3 reconstructed token" "reconstructed" "$(ens_case "$M" --issue 42)"
assert "TC-3 worktree registered" "yes" "$(wt_registered "$M" 42)"

# --- TC-3b: explicit --branch (the form pr-review.md / fix.md actually use) ---
echo "=== TC-3b: explicit --branch reconstructed (caller invocation form) ==="
setup_repo; M="$REPO_MAIN"
assert "TC-3b reconstructed token (explicit branch)" "reconstructed" \
  "$(ens_case "$M" --issue 42 --branch fix/issue-42-foo)"
assert "TC-3b worktree registered" "yes" "$(wt_registered "$M" 42)"

# --- TC-4: remote-only branch → reconstructed (fetch + add --track) ---
echo "=== TC-4: remote-only branch → reconstructed ==="
setup_repo; M="$REPO_MAIN"
assert "TC-4 reconstructed token" "reconstructed" "$(ens_case "$M" --issue 77)"
assert "TC-4 worktree registered" "yes" "$(wt_registered "$M" 77)"

# --- TC-5: already_in (run from inside the worktree) ---
echo "=== TC-5: cwd inside worktree → already_in ==="
setup_repo; M="$REPO_MAIN"
ens_case "$M" --issue 42 >/dev/null   # create+register it first
assert "TC-5 already_in token" "already_in" "$(ens_case "$M/.rite/worktrees/issue-42" --issue 42)"

# --- TC-6: reenter (registered, cwd elsewhere) + path= field is load-bearing ---
echo "=== TC-6: registered, cwd=main → reenter, path= points at the worktree ==="
setup_repo; M="$REPO_MAIN"
ens_case "$M" --issue 42 >/dev/null
assert "TC-6 reenter token" "reenter" "$(ens_case "$M" --issue 42)"
# path= is the value the caller feeds to EnterWorktree — assert it resolves to the issue worktree.
assert "TC-6 path= ends with .rite/worktrees/issue-42" "yes" \
  "$(case "$(ens_field "$M" path --issue 42)" in */.rite/worktrees/issue-42) echo yes ;; *) echo no ;; esac)"

# --- TC-7: residue (dir exists at path, not a registered worktree) ---
echo "=== TC-7: stale dir at path, not registered → residue ==="
setup_repo; M="$REPO_MAIN"
mkdir -p "$M/.rite/worktrees/issue-42"; echo junk > "$M/.rite/worktrees/issue-42/junk"
assert "TC-7 residue token" "residue" "$(ens_case "$M" --issue 42)"

# --- TC-8: branch checked out in ANOTHER worktree → branch_other_worktree (+ other=, no new wt) ---
echo "=== TC-8: branch in a different worktree → branch_other_worktree ==="
setup_repo; M="$REPO_MAIN"
git -C "$M" worktree add -q "$M/elsewhere-42" fix/issue-42-foo >/dev/null 2>&1
assert "TC-8 branch_other_worktree token" "branch_other_worktree" "$(ens_case "$M" --issue 42)"
# other= must surface the conflicting worktree path (recover.md table 「other= のパスを表示」契約).
assert "TC-8 other= ends with elsewhere-42" "yes" \
  "$(case "$(ens_field "$M" other --issue 42)" in */elsewhere-42) echo yes ;; *) echo no ;; esac)"
# Must NOT create the canonical issue-42 worktree (no silent reconstruction over a conflict).
assert "TC-8 canonical issue-42 worktree not created" "no" \
  "$(git -C "$M" worktree list --porcelain | grep -qE '/\.rite/worktrees/issue-42($|/| )' && echo yes || echo no)"

# --- TC-9 (T-04 / AC-4): git worktree add fails → failed (rc 1, NO fallback, no residue) ---
echo "=== TC-9 (T-04/AC-4): reconstruction fails → failed, rc=1, no partial worktree ==="
setup_repo; M="$REPO_MAIN"
rm -rf "$M/.rite"; mkdir -p "$M/.rite"; printf 'blocker' > "$M/.rite/worktrees"  # base is a FILE
assert "TC-9 failed token" "failed" "$(ens_case "$M" --issue 42)"
assert "TC-9 rc=1" "1" "$(ens_rc "$M" --issue 42)"
# AC-4 core: no silent fallback means no half-built worktree is registered.
assert "TC-9 no worktree registered after failure" "no" "$(wt_registered "$M" 42)"

# --- TC-10: argument error (missing / non-numeric --issue) → rc 2 ---
echo "=== TC-10: missing / non-numeric --issue → rc 2 ==="
setup_repo; M="$REPO_MAIN"
assert "TC-10 rc=2 (missing --issue)" "2" "$(ens_rc "$M")"
assert "TC-10 rc=2 (non-numeric --issue)" "2" "$(ens_rc "$M" --issue abc)"

# --- TC-11: stdout discipline — exactly ONE line, the marker (git chatter to stderr) ---
echo "=== TC-11: stdout is exactly one WT_ENSURE marker line on reconstruct ==="
setup_repo; M="$REPO_MAIN"
stdout_lines=$( ( cd "$M" && bash "$HELPER" ensure-session-worktree --issue 42 2>/dev/null ) | grep -c .)
assert "TC-11 single stdout line" "1" "$stdout_lines"

# --- TC-12 (T-01/AC-1): settings.local.json present → copied into reconstructed worktree ---
echo "=== TC-12 (T-01/AC-1): settings.local.json present → copied to worktree ==="
setup_repo; M="$REPO_MAIN"
mkdir -p "$M/.claude"; echo '{"enabledPlugins":{"rite@rite-marketplace":false}}' > "$M/.claude/settings.local.json"
ens_case "$M" --issue 42 >/dev/null
assert "TC-12 settings.local.json copied" "yes" \
  "$([ -f "$M/.rite/worktrees/issue-42/.claude/settings.local.json" ] && echo yes || echo no)"
assert "TC-12 copied content matches" "yes" \
  "$(diff -q "$M/.claude/settings.local.json" "$M/.rite/worktrees/issue-42/.claude/settings.local.json" >/dev/null 2>&1 && echo yes || echo no)"

# --- TC-13 (T-02/AC-2): settings.local.json absent → nothing extra created ---
echo "=== TC-13 (T-02/AC-2): settings.local.json absent → no file/dir created in worktree ==="
setup_repo; M="$REPO_MAIN"
ens_case "$M" --issue 42 >/dev/null
assert "TC-13 no settings.local.json created" "no" \
  "$([ -e "$M/.rite/worktrees/issue-42/.claude/settings.local.json" ] && echo yes || echo no)"
assert "TC-13 no .claude dir created" "no" \
  "$([ -e "$M/.rite/worktrees/issue-42/.claude" ] && echo yes || echo no)"

# --- TC-14 (T-01/AC-1, review F-02): settings.local.json present → copied via branch_remote reconstruction ---
echo "=== TC-14 (T-01/AC-1): settings.local.json present → copied to worktree (branch_remote path) ==="
setup_repo; M="$REPO_MAIN"
mkdir -p "$M/.claude"; echo '{"enabledPlugins":{"rite@rite-marketplace":false}}' > "$M/.claude/settings.local.json"
ens_case "$M" --issue 77 >/dev/null
assert "TC-14 settings.local.json copied (branch_remote)" "yes" \
  "$([ -f "$M/.rite/worktrees/issue-77/.claude/settings.local.json" ] && echo yes || echo no)"
assert "TC-14 copied content matches (branch_remote)" "yes" \
  "$(diff -q "$M/.claude/settings.local.json" "$M/.rite/worktrees/issue-77/.claude/settings.local.json" >/dev/null 2>&1 && echo yes || echo no)"

# --- TC-15 (review cycle2 F-01): settings.local.json copy failure → WARNING emitted, non-fatal ---
echo "=== TC-15 (review cycle2 F-01): copy failure (mkdir blocked by existing file) → WARNING + non-fatal ==="
setup_repo; M="$REPO_MAIN"
# fix/issue-88-foo は develop から分岐した local-only branch で、.claude を「通常ファイル」として
# track する。worktree checkout 時に $wt_path/.claude がファイルになるため、複製ロジックの
# `mkdir -p "$wt_path/.claude"` が決定論的に失敗する（symlink/権限操作より移植性が高い）。
# main の .claude/settings.local.json 作成より **先に** branch を作る（develop 上に .claude/ を
# ディレクトリとして先置きすると、後続の `echo blocker > .claude` がディレクトリ相手に失敗するため）。
(
  cd "$M" && git checkout -q -b fix/issue-88-foo develop
  echo blocker > .claude
  git add -A; git commit -qm "add blocker .claude file"
  git checkout -q develop
) >/dev/null 2>&1
mkdir -p "$M/.claude"; echo '{"enabledPlugins":{"rite@rite-marketplace":false}}' > "$M/.claude/settings.local.json"
out_tmp=$(mktemp); err_tmp=$(mktemp)
rc=$(ens_run_capture "$M" "$out_tmp" "$err_tmp" --issue 88)
case_token=$(sed -n 's/.*WT_ENSURE=\([a-z_]*\).*/\1/p' "$out_tmp")
assert "TC-15 WARNING emitted on copy failure" "yes" \
  "$(grep -qF 'コピーに失敗' "$err_tmp" && echo yes || echo no)"
assert "TC-15 still reconstructed (non-fatal)" "reconstructed" "$case_token"
assert "TC-15 rc=0 (non-fatal)" "0" "$rc"
rm -f "$out_tmp" "$err_tmp"

# --- TC-16 (follow-up to cycle3 test-reviewer): copy failure on the
#     branch_remote reconstruction path → WARNING emitted, non-fatal ---
# TC-15 covers the branch_local WARNING path (695/696行目); this covers the
# verbatim-duplicate branch_remote WARNING path (723/724行目) so a future
# regression to `|| true` on either copy is independently caught.
echo "=== TC-16: copy failure (mkdir blocked by existing file) → WARNING + non-fatal (branch_remote path) ==="
setup_repo; M="$REPO_MAIN"
# feat/issue-77-bar is already remote-only from setup_repo(). Re-check it out,
# add a blocker ".claude" regular file, and push the update — same technique as
# TC-15's fix/issue-88-foo but on the remote-only branch so reconstruction goes
# through the branch_remote (--track) path instead of branch_local.
# main の .claude/settings.local.json 作成より **先に** ブランチを更新する（TC-15 と同じ
# 理由: develop 上に .claude/ をディレクトリとして先置きすると checkout が汚染される）。
(
  cd "$M" && git checkout -q -b feat/issue-77-bar origin/feat/issue-77-bar
  echo blocker > .claude
  git add -A; git commit -qm "add blocker .claude file"
  git push -q origin feat/issue-77-bar
  git checkout -q develop
  git branch -D feat/issue-77-bar
) >/dev/null 2>&1
mkdir -p "$M/.claude"; echo '{"enabledPlugins":{"rite@rite-marketplace":false}}' > "$M/.claude/settings.local.json"
out_tmp=$(mktemp); err_tmp=$(mktemp)
rc=$(ens_run_capture "$M" "$out_tmp" "$err_tmp" --issue 77)
case_token=$(sed -n 's/.*WT_ENSURE=\([a-z_]*\).*/\1/p' "$out_tmp")
assert "TC-16 WARNING emitted on copy failure (branch_remote)" "yes" \
  "$(grep -qF 'コピーに失敗' "$err_tmp" && echo yes || echo no)"
assert "TC-16 still reconstructed (non-fatal, branch_remote)" "reconstructed" "$case_token"
assert "TC-16 rc=0 (non-fatal, branch_remote)" "0" "$rc"
rm -f "$out_tmp" "$err_tmp"

# --- Host-independent worktree contract: execute the documented guard itself. ---
# These are shell/workdir fixtures, not evidence of native host tool availability.
echo "=== host worktree execution: isolation, saved state, rejection ==="
plugin_root=$(_helpers_resolve_plugin_root "$SCRIPT_DIR")
contract="$plugin_root/references/git-worktree-patterns.md"
setup_repo; M="$REPO_MAIN"
wt="$M/.rite/worktrees/issue-42"
guard="$(dirname "$M")/execution-check.sh"
awk '/^# worktree-execution-check$/ { copy=1; next } copy && /^```$/ { exit } copy { print }' "$contract" > "$guard"
assert "documented execution guard exists" "yes" "$(test -s "$guard" && echo yes || echo no)"
git -C "$M" worktree add -q "$wt" fix/issue-42-foo
printf '.rite/\n' >> "$M/.git/info/exclude"
# Explicit fixture-only session ownership; never inherit the runner's state root.
fixture_sid=550e8400-e29b-41d4-a716-446655440042
other_sid=550e8400-e29b-41d4-a716-446655440043
host_fixture() (
  unset RITE_STATE_ROOT CLAUDE_SESSION_ID
  export CLAUDE_CODE_SESSION_ID="$fixture_sid"
  cd "$wt" || exit 1
  "$@"
)
host_fixture bash "$plugin_root/hooks/flow-state.sh" set --phase branch --issue 42 \
  --branch fix/issue-42-foo --worktree "$wt" --pr 0 --next test >/dev/null
host_fixture bash "$plugin_root/hooks/issue-claim.sh" claim --issue 42 --worktree "$wt" >/dev/null
saved_state=$(host_fixture bash "$plugin_root/hooks/flow-state.sh" path)
cp "$saved_state" "$guard.state"
# Each invocation is a fresh shell and explicitly selects its cwd. A trailing
# mutation proves a rejected guard cannot fall through to the next operation.
run_host_guard() {
  local selected_cwd="$1" expected_branch="${2:-fix/issue-42-foo}"
  host_fixture bash -c '
    cd "$1" || exit 1
    plugin_root=$2 wt_path=$3 branch_name=$4 issue_number=42 entry_phase=pr pr_number=0
    source "$5"
    printf changed > "$wt_path/guard-mutation.txt"
  ' _ "$selected_cwd" "$plugin_root" "$wt" "$expected_branch" "$guard"
}
printf '# existing dirty work\n' >> "$M/rite-config.yml"
printf 'keep\n' > "$M/user-untracked.txt"
main_head=$(git -C "$M" rev-parse HEAD)
main_branch=$(git -C "$M" branch --show-current)
main_status=$(git -C "$M" status --porcelain)
main_dirty=$(cat "$M/rite-config.yml")
run_host_guard "$wt" > "$guard.out" 2>&1; rc=$?
assert "explicit cwd entry succeeds without native tool" "0" "$rc"
# Commit only inside the isolated fixture worktree.
(host_fixture git add guard-mutation.txt && host_fixture git commit -qm 'isolated edit') >/dev/null 2>&1; rc=$?
assert "isolated fixture commit succeeds" "0" "$rc"
assert "commit advances only worktree branch" "yes" "$(test "$(git -C "$wt" rev-parse HEAD)" != "$main_head" && echo yes || echo no)"
assert "isolated commit leaves main HEAD" "$main_head" "$(git -C "$M" rev-parse HEAD)"
assert "isolated commit leaves main branch" "$main_branch" "$(git -C "$M" branch --show-current)"
assert "isolated edit leaves main dirty status" "$main_status" "$(git -C "$M" status --porcelain)"
assert "isolated edit preserves main dirty content" "$main_dirty" "$(cat "$M/rite-config.yml")"
assert "isolated edit preserves main untracked content" "keep" "$(cat "$M/user-untracked.txt")"
run_host_guard "$wt" > "$guard.out" 2>&1; rc=$?
assert "fresh shell resumes saved session state and claim" "0" "$rc"
assert "entry check does not rewrite saved state" "yes" "$(cmp -s "$saved_state" "$guard.state" && echo yes || echo no)"
# Run open's actual initialization against completed state from a previous Issue.
# flow-state set preserves omitted fields; direct jq edits would hide that bug.
initial_guard="$guard.init"
awk -v root="$plugin_root" '
  /^# open-initial-state$/ { copy=1; next }
  copy && /^```$/ { exit }
  copy { gsub(/\{plugin_root\}/, root); gsub(/\{issue_number\}/, "42");
         gsub(/\{branch_name\}/, "fix/issue-42-foo"); print }
' "$plugin_root/skills/open/SKILL.md" > "$initial_guard"
assert "documented initial state block exists" "yes" "$(test -s "$initial_guard" && echo yes || echo no)"
host_fixture bash "$plugin_root/hooks/flow-state.sh" set --phase completed --issue 41 \
  --branch fix/issue-41-old --worktree "$M/.rite/worktrees/issue-41" --pr 41 --next done >/dev/null
assert "completed fixture retains previous branch and worktree" "true" \
  "$(jq --arg wt "$M/.rite/worktrees/issue-41" '.phase == "completed" and .issue_number == 41 and .branch == "fix/issue-41-old" and .worktree == $wt' "$saved_state")"
host_fixture bash "$initial_guard" > "$guard.out" 2>&1; rc=$?
assert "open initializes next Issue using real helper" "0" "$rc"
assert "new Issue init clears old worktree and sets new branch" "true" \
  "$(jq '.phase == "init" and .issue_number == 42 and .branch == "fix/issue-42-foo" and (.worktree // "") == ""' "$saved_state")"
host_fixture bash "$plugin_root/hooks/issue-claim.sh" claim --issue 42 --worktree "" >/dev/null
run_host_guard "$wt" > "$guard.out" 2>&1; rc=$?
assert "initial entry permits unrecorded paths for owned init state" "0" "$rc"
# All mismatch cases must stop before the mutation, including ownership data
# that is internally consistent but belongs to a different worktree/session.
for mismatch in root branch state_branch state_worktree state_issue state_session claim_worktree other_claim; do
  cp "$guard.state" "$saved_state"
  host_fixture bash "$plugin_root/hooks/issue-claim.sh" claim --issue 42 --worktree "$wt" >/dev/null
  selected_cwd=$wt; expected_branch=fix/issue-42-foo
  claim_file="$M/.rite/state/issue-claims/issue-42.json"
  case "$mismatch" in
    root) selected_cwd=$M ;;
    branch) expected_branch=develop ;;
    state_branch) jq '.branch = "develop"' "$saved_state" > "$guard.json"; cp "$guard.json" "$saved_state" ;;
    state_worktree) jq --arg p "$M" '.worktree = $p' "$saved_state" > "$guard.json"; cp "$guard.json" "$saved_state" ;;
    state_issue) jq '.issue_number = 99' "$saved_state" > "$guard.json"; cp "$guard.json" "$saved_state" ;;
    state_session) jq --arg sid "$other_sid" '.session_id = $sid' "$saved_state" > "$guard.json"; cp "$guard.json" "$saved_state" ;;
    claim_worktree) host_fixture bash "$plugin_root/hooks/issue-claim.sh" claim --issue 42 --worktree "$M" >/dev/null ;;
    other_claim)
      host_fixture bash "$plugin_root/hooks/issue-claim.sh" release --issue 42 >/dev/null
      host_fixture env CLAUDE_CODE_SESSION_ID="$other_sid" bash "$plugin_root/hooks/flow-state.sh" set \
        --phase branch --issue 42 --branch fix/issue-42-foo --worktree "$wt" --pr 0 --next test >/dev/null
      host_fixture env CLAUDE_CODE_SESSION_ID="$other_sid" bash "$plugin_root/hooks/issue-claim.sh" claim --issue 42 --worktree "$wt" >/dev/null
      cp "$claim_file" "$guard.claim"
      host_fixture bash "$plugin_root/hooks/issue-claim.sh" claim --issue 42 --worktree "$wt" > "$guard.out" 2>&1; rc=$?
      assert "other live claim acquisition is refused" "10" "$rc"
      ;;
  esac
  rm -f "$wt/guard-mutation.txt"
  run_host_guard "$selected_cwd" "$expected_branch" > "$guard.out" 2>&1; rc=$?
  assert "$mismatch rejects before mutation" "yes" "$(test "$rc" -ne 0 && test ! -e "$wt/guard-mutation.txt" && echo yes || echo no)"
  if [ "$mismatch" = other_claim ]; then
    assert "other live claim is unchanged" "yes" "$(cmp -s "$claim_file" "$guard.claim" && echo yes || echo no)"
  fi
done
# A standalone entry owns its claim before any state exists for its fresh UUID.
host_fixture env CLAUDE_CODE_SESSION_ID="$other_sid" bash "$plugin_root/hooks/issue-claim.sh" release --issue 42 >/dev/null
fixture_sid=550e8400-e29b-41d4-a716-446655440044
fresh_state=$(host_fixture bash "$plugin_root/hooks/flow-state.sh" path)
host_fixture bash "$plugin_root/hooks/issue-claim.sh" claim --issue 42 --worktree "$wt" >/dev/null
assert "fresh standalone session has own claim" own "$(host_fixture bash "$plugin_root/hooks/issue-claim.sh" check --issue 42)"
assert "fresh standalone session has no state" "yes" "$(test ! -e "$fresh_state" && echo yes || echo no)"
run_host_guard "$M" > "$guard.out" 2>&1; rc=$?
assert "wrong root cannot initialize fresh state" "yes" "$(test "$rc" -ne 0 && test ! -e "$fresh_state" && echo yes || echo no)"
run_host_guard "$wt" > "$guard.out" 2>&1; rc=$?
assert "fresh standalone guard initializes state" "0" "$rc"
assert "standalone state records current session, worktree, branch and phase" "true" \
  "$(jq --arg sid "$fixture_sid" --arg wt "$wt" '.session_id == $sid and .issue_number == 42 and .branch == "fix/issue-42-foo" and .worktree == $wt and .phase == "pr" and .pr_number == 0' "$fresh_state")"
# Only verify instruction wiring here: no mock result is presented as a real
# EnterWorktree/permission probe. Native-denial handling belongs to the host.
assert_grep "native absence permits explicit workdir" "$contract" 'native 不在、各 shell の `workdir`'
assert_grep "native denial stops without fallback" "$contract" 'native が権限拒否 .*代替経路を試さず停止'

print_summary "ensure-session-worktree.test.sh" \
  "ensure_session_worktree contract changed — sync lib/worktree-git.sh and the recover.md WT_ENSURE table"
