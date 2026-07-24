#!/bin/bash
# Tests for pre-tool-edit-guard.sh (PreToolUse hook, Issue #1860)
# Usage: bash plugins/rite/hooks/tests/pre-tool-edit-guard.test.sh
#
# Verifies AC-1 (reviewer subagent Edit/Write/MultiEdit/NotebookEdit to the parent
# working tree is denied — including token-in-filename / `..` re-entry forgery of the
# isolation allowlist, Issue #1860 review cycle 1) and AC-4 (normal review and
# isolated-worktree mutation testing are NOT false-denied).
set -euo pipefail

# Neutralize env that would perturb detection / double-exec guards:
# - CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE (Tier 3): a host value would make the
#   main-session allow tests deny via Tier 3 and flake.
# - _RITE_HOOK_RUNNING_PRETOOL_EDIT (double-exec guard): a host value would make every
#   hook invocation exit 0 immediately, silently turning deny tests into false allows.
unset CLAUDE_SUBAGENT_TYPE CLAUDE_AGENT_TYPE _RITE_HOOK_RUNNING_PRETOOL_EDIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../pre-tool-edit-guard.sh"
PASS=0
FAIL=0
STDERR_FILE=$(mktemp)

# A real git repo so `git -C ... rev-parse --show-toplevel` resolves the target's
# worktree. Isolation dirs are REAL detached worktrees (not bare `mktemp -d`) so the
# hook's isolation branch — which matches on the target's *worktree root* — is actually
# exercised. A bare mktemp -d would resolve to "no repo" → allow via a different (fail-open)
# path, giving a false-positive that survives even if the allowlist is deleted.
TEST_REPO=$(mktemp -d)
( cd "$TEST_REPO" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init )
# Detached worktrees whose ROOT dir carries the sanctioned isolation prefixes.
ISO_MUT_DIR=$(mktemp -u -t rite-review-mutation-XXXXXX)
ISO_REV_DIR=$(mktemp -u -t rite-revert-test-XXXXXX)
( cd "$TEST_REPO" && git worktree add --detach -q "$ISO_MUT_DIR" HEAD )
( cd "$TEST_REPO" && git worktree add --detach -q "$ISO_REV_DIR" HEAD )
OUTSIDE_DIR=$(mktemp -d)   # a plain, non-repo scratch dir
shimdir=""                 # set by TC-FAILCLOSED; cleaned here so an interrupt leaves no residue

cleanup() {
  rm -f "$STDERR_FILE"
  ( cd "$TEST_REPO" 2>/dev/null && git worktree remove --force "$ISO_MUT_DIR" 2>/dev/null ) || true
  ( cd "$TEST_REPO" 2>/dev/null && git worktree remove --force "$ISO_REV_DIR" 2>/dev/null ) || true
  rm -rf "$TEST_REPO" "$ISO_MUT_DIR" "$ISO_REV_DIR" "$OUTSIDE_DIR" ${shimdir:+"$shimdir"}
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi
REAL_JQ=$(command -v jq)   # absolute path, captured before any PATH-shim test shadows `jq`

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

SUBAGENT_TRANSCRIPT="/home/user/.claude/projects/proj/session-id/subagents/agent-abc123.jsonl"
MAIN_TRANSCRIPT="/home/user/.claude/projects/proj/session-id/main.jsonl"

# Build a PreToolUse envelope and pipe it to the hook.
#   $1 tool_name  $2 file/notebook path  $3 cwd  $4 transcript_path
# NotebookEdit populates tool_input.notebook_path; the rest use file_path.
run_edit_guard() {
  local tool_name="$1" path="$2" cwd="$3" transcript="$4"
  local field="file_path"
  [ "$tool_name" = "NotebookEdit" ] && field="notebook_path"
  local rc=0 output
  output=$(jq -n --arg tn "$tool_name" --arg p "$path" --arg cwd "$cwd" \
    --arg tp "$transcript" --arg field "$field" \
    '{tool_name: $tn, tool_input: {($field): $p}, cwd: $cwd, transcript_path: $tp}' \
    | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

decision_of() { echo "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason_of()   { echo "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

# Assert deny with the expected pattern-name marker in the reason.
assert_deny() {
  local label="$1" out="$2"
  if [ "$(decision_of "$out")" = "deny" ] && [[ "$(reason_of "$out")" == *"reviewer-edit-parent-tree"* ]]; then
    pass "$label"
  else
    fail "$label — expected deny, got decision=$(decision_of "$out") reason=$(reason_of "$out")"
  fi
}
# Assert allow (exit 0, no stdout).
assert_allow() {
  local label="$1" out="$2" rc="$3"
  if [ "$rc" = "0" ] && [ -z "$out" ]; then
    pass "$label"
  else
    fail "$label — expected allow (exit 0, empty), got rc=$rc out=$out"
  fi
}

echo "=== pre-tool-edit-guard.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# (a) subagent Edit to a parent-working-tree file → deny
# --------------------------------------------------------------------------
echo "TC-A: subagent Edit to parent working tree → deny"
out=$(run_edit_guard "Edit" "$TEST_REPO/src/bets.py" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "subagent Edit to repo file blocked" "$out"
if grep -q "edit-guard: BLOCKED" "$STDERR_FILE"; then pass "stderr contains block log"; else fail "stderr block log missing: $(cat "$STDERR_FILE")"; fi
echo ""

# (a2) subagent Edit with RELATIVE path (cwd=repo) → deny (relative join)
echo "TC-A2: subagent Edit relative path under repo → deny"
out=$(run_edit_guard "Edit" "src/bets.py" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "subagent Edit (relative) to repo file blocked" "$out"
echo ""

# --------------------------------------------------------------------------
# BYPASS regression (Issue #1860 review cycle 1) — forged isolation paths → deny
# --------------------------------------------------------------------------
echo "TC-BYPASS-A: token embedded in a repo filename → deny"
out=$(run_edit_guard "Edit" "$TEST_REPO/src/rite-review-mutation-hack.py" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "token-in-filename does NOT grant isolation" "$out"
echo ""

echo "TC-BYPASS-B: '..' re-entry to a tracked repo file → deny"
out=$(run_edit_guard "Edit" "$TEST_REPO/rite-review-mutation-x/../src/tracked.py" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "dotdot re-entry does NOT grant isolation" "$out"
echo ""

echo "TC-BYPASS-B2: '..' via NON-existent segment → deny (physical resolution to real repo)"
out=$(run_edit_guard "Edit" "$TEST_REPO/nonexistent-rite-review-mutation-x/../src/tracked.py" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "nonexistent-segment dotdot resolves to real repo → deny" "$out"
echo ""

echo "TC-BYPASS-C: revert-test token substring in a repo path → deny"
out=$(run_edit_guard "Edit" "$TEST_REPO/plugins/rite-revert-test-anything.md" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "revert-test substring does NOT grant isolation" "$out"
echo ""

echo "TC-NEWDIR: subagent Edit to a brand-new dir inside repo → deny (walk-up to repo)"
out=$(run_edit_guard "Write" "$TEST_REPO/brand-new-dir/evil.py" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "new dir/file inside repo blocked" "$out"
echo ""

# --------------------------------------------------------------------------
# (b) subagent Edit inside a REAL rite-review-mutation-* worktree → allow
# --------------------------------------------------------------------------
echo "TC-B: subagent Edit inside real rite-review-mutation-* worktree → allow"
out=$(run_edit_guard "Edit" "some-file.sh" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") && rc=0 || rc=$?
assert_allow "isolated mutation-worktree edit allowed (AC-4)" "$out" "$rc"
echo ""

# (e) subagent Edit inside a REAL rite-revert-test-* worktree → allow
echo "TC-E: subagent Edit inside real rite-revert-test-* worktree → allow"
out=$(run_edit_guard "Write" "$ISO_REV_DIR/probe.txt" "$ISO_REV_DIR" "$SUBAGENT_TRANSCRIPT") && rc=0 || rc=$?
assert_allow "isolated revert-test-worktree edit allowed (AC-4)" "$out" "$rc"
echo ""

# (residual) reviewer cd'd into isolation worktree but targets parent repo by abs path → deny
echo "TC-RESIDUAL: cwd=isolation worktree, abs path INTO parent repo → deny"
out=$(run_edit_guard "Edit" "$TEST_REPO/src/tracked.py" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "abs path escaping isolation into parent repo blocked" "$out"
echo ""

# --------------------------------------------------------------------------
# (c) main-session Edit to parent tree → allow (primary AC-4 guarantee)
# --------------------------------------------------------------------------
echo "TC-C: main-session Edit to parent working tree → allow"
out=$(run_edit_guard "Edit" "$TEST_REPO/src/bets.py" "$TEST_REPO" "$MAIN_TRANSCRIPT") && rc=0 || rc=$?
assert_allow "main-session edit not blocked (implement.md Edit/Write unaffected)" "$out" "$rc"
echo ""

# --------------------------------------------------------------------------
# (d) tool parity: subagent Write / MultiEdit / NotebookEdit to parent tree → deny
# --------------------------------------------------------------------------
for tool in Write MultiEdit NotebookEdit; do
  echo "TC-D-$tool: subagent $tool to parent working tree → deny"
  path="$TEST_REPO/src/mod.py"
  [ "$tool" = "NotebookEdit" ] && path="$TEST_REPO/nb.ipynb"
  out=$(run_edit_guard "$tool" "$path" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
  assert_deny "$tool to repo file blocked" "$out"
  echo ""
done

# --------------------------------------------------------------------------
# (f) subagent Edit outside any repo → allow (target not in a repo)
# --------------------------------------------------------------------------
echo "TC-F: subagent Edit to /tmp scratch outside any repo → allow"
out=$(run_edit_guard "Edit" "$OUTSIDE_DIR/scratch.txt" "$OUTSIDE_DIR" "$SUBAGENT_TRANSCRIPT") && rc=0 || rc=$?
assert_allow "non-repo scratch edit allowed" "$out" "$rc"
echo ""

# (f2) cwd=repo but absolute target OUTSIDE the repo → allow (target not in repo)
echo "TC-F2: cwd=repo, abs target outside repo → allow"
out=$(run_edit_guard "Edit" "$OUTSIDE_DIR/scratch.txt" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") && rc=0 || rc=$?
assert_allow "abs target outside repo allowed" "$out" "$rc"
echo ""

# --------------------------------------------------------------------------
# (g) non-matching tool (Bash) → allow (defense-in-depth against matcher drift)
# --------------------------------------------------------------------------
echo "TC-G: non-Edit tool (Bash) → allow (exit 0, no output)"
out=$(jq -n --arg tp "$SUBAGENT_TRANSCRIPT" --arg cwd "$TEST_REPO" \
  '{tool_name: "Bash", tool_input: {command: "git status"}, cwd: $cwd, transcript_path: $tp}' \
  | bash "$HOOK" 2>"$STDERR_FILE") && rc=0 || rc=$?
assert_allow "Bash tool ignored by edit-guard" "$out" "$rc"
echo ""

# --------------------------------------------------------------------------
# Tier 2 detection (JSON subagent_type / agent_type) — main transcript, no env
# --------------------------------------------------------------------------
echo "TC-T2a: Tier 2 subagent_type field → deny parent-tree edit"
out=$(jq -n --arg p "$TEST_REPO/src/x.py" --arg cwd "$TEST_REPO" --arg tp "$MAIN_TRANSCRIPT" \
  '{tool_name: "Edit", tool_input: {file_path: $p}, cwd: $cwd, transcript_path: $tp, subagent_type: "code-quality-reviewer"}' \
  | bash "$HOOK" 2>"$STDERR_FILE") || true
assert_deny "Tier 2 subagent_type blocks parent-tree edit" "$out"
echo ""

echo "TC-T2b: Tier 2 agent_type field → deny parent-tree edit"
out=$(jq -n --arg p "$TEST_REPO/src/x.py" --arg cwd "$TEST_REPO" --arg tp "$MAIN_TRANSCRIPT" \
  '{tool_name: "Edit", tool_input: {file_path: $p}, cwd: $cwd, transcript_path: $tp, agent_type: "security-reviewer"}' \
  | bash "$HOOK" 2>"$STDERR_FILE") || true
assert_deny "Tier 2 agent_type blocks parent-tree edit" "$out"
echo ""

echo "TC-T2c: Tier 2 NON-string subagent_type (number) → does NOT fire (| strings), main-session → allow"
out=$(jq -n --arg p "$TEST_REPO/src/x.py" --arg cwd "$TEST_REPO" --arg tp "$MAIN_TRANSCRIPT" \
  '{tool_name: "Edit", tool_input: {file_path: $p}, cwd: $cwd, transcript_path: $tp, subagent_type: 123}' \
  | bash "$HOOK" 2>"$STDERR_FILE") && rc=0 || rc=$?
assert_allow "non-string subagent_type rejected via | strings (main-session allow)" "$out" "$rc"
echo ""

# --------------------------------------------------------------------------
# (h) Tier 3 env-var subagent detection: main transcript but env set → deny
# --------------------------------------------------------------------------
echo "TC-H: env-var (Tier 3) subagent detection to parent tree → deny"
out=$(jq -n --arg p "$TEST_REPO/src/x.py" --arg cwd "$TEST_REPO" --arg tp "$MAIN_TRANSCRIPT" \
  '{tool_name: "Edit", tool_input: {file_path: $p}, cwd: $cwd, transcript_path: $tp}' \
  | CLAUDE_SUBAGENT_TYPE="code-quality-reviewer" bash "$HOOK" 2>"$STDERR_FILE") || true
assert_deny "Tier 3 env-var subagent detection blocks parent-tree edit" "$out"
echo ""

# --------------------------------------------------------------------------
# Malformed / missing input → fail-open (allow), never a spurious deny
# --------------------------------------------------------------------------
echo "TC-MALFORMED: non-JSON input → fail-open (allow)"
out=$(printf 'not json at all' | bash "$HOOK" 2>"$STDERR_FILE") && rc=0 || rc=$?
assert_allow "malformed input fails open" "$out" "$rc"
echo ""

echo "TC-NOPATH: Edit envelope with no file_path → fail-open (allow)"
out=$(jq -n --arg tp "$SUBAGENT_TRANSCRIPT" --arg cwd "$TEST_REPO" \
  '{tool_name: "Edit", tool_input: {}, cwd: $cwd, transcript_path: $tp}' \
  | bash "$HOOK" 2>"$STDERR_FILE") && rc=0 || rc=$?
assert_allow "missing file_path fails open (cannot scope)" "$out" "$rc"
echo ""

# --------------------------------------------------------------------------
# .git-internal writes → deny (Issue #1860 review cycle 2 — .git/hooks/pre-commit
# etc. would give main-session code execution; git rev-parse --show-toplevel is empty
# inside .git so the naive "empty → allow" branch used to let these through).
# --------------------------------------------------------------------------
assert_deny_gitdir() {
  local label="$1" out="$2"
  if [ "$(decision_of "$out")" = "deny" ] && [[ "$(reason_of "$out")" == *"reviewer-edit-git-dir"* ]]; then
    pass "$label"
  else
    fail "$label — expected git-dir deny, got decision=$(decision_of "$out") reason=$(reason_of "$out")"
  fi
}

echo "TC-GITDIR-hooks: subagent Write into .git/hooks/pre-commit → deny"
out=$(run_edit_guard "Write" "$TEST_REPO/.git/hooks/pre-commit" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
assert_deny_gitdir "write into .git/hooks blocked (RCE vector)" "$out"
echo ""

echo "TC-GITDIR-config: subagent Edit to .git/config → deny"
out=$(run_edit_guard "Edit" "$TEST_REPO/.git/config" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
assert_deny_gitdir "write into .git/config blocked" "$out"
echo ""

# --------------------------------------------------------------------------
# Final-element symlink resolution (Issue #1864 AC-2): a symlink dropped INSIDE a
# sanctioned isolation worktree that points at the parent repo's .git / working tree
# is physically resolved (realpath) BEFORE the isolation decision, so it can no longer
# dodge the guard by landing _tdir on the isolation root. AC-3 note: Claude Code's own
# Edit/Write tools already refuse symlink writes, so this is defense-in-depth.
# --------------------------------------------------------------------------
# The AC-2 resolution relies on `realpath` resolving a symlink whose target does
# not yet exist (the symlink targets below are never created). GNU realpath does;
# BSD/macOS realpath errors, so the final-element resolution no-ops there — the
# hook comment above already notes this fallthrough is "no worse than before", and
# AC-3 (Claude Code Edit/Write refuse symlink writes) is the backstop. Probe the
# exact behavior and skip these two TCs where realpath can't resolve a dangling
# symlink (Issue #2008; documented BSD limitation, not a regression).
_sym_probe=$(mktemp -d); ln -s "$_sym_probe/no-such-target" "$_sym_probe/lnk"
if realpath "$_sym_probe/lnk" >/dev/null 2>&1; then RESOLVES_DANGLING_SYMLINK=1; else RESOLVES_DANGLING_SYMLINK=0; fi
rm -rf "$_sym_probe"

if [ "$RESOLVES_DANGLING_SYMLINK" = 1 ]; then
echo "TC-SYMLINK-gitdir: isolation symlink → parent .git → deny (git-dir)"
ln -s "$TEST_REPO/.git/hooks/pre-commit" "$ISO_MUT_DIR/evil-into-gitdir"
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/evil-into-gitdir" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
assert_deny_gitdir "isolation symlink into parent .git resolved & blocked" "$out"
rm -f "$ISO_MUT_DIR/evil-into-gitdir"
echo ""

echo "TC-SYMLINK-tree: isolation symlink → parent working tree → deny (parent-tree)"
ln -s "$TEST_REPO/tracked.py" "$ISO_MUT_DIR/evil-into-tree"
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/evil-into-tree" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "isolation symlink into parent working tree resolved & blocked" "$out"
rm -f "$ISO_MUT_DIR/evil-into-tree"
echo ""
else
  echo "  ⏭️  TC-SYMLINK-gitdir/tree skipped (realpath can't resolve a dangling symlink here; AC-2 final-element resolution no-ops on BSD/macOS — AC-3 Edit/Write symlink refusal is the backstop, Issue #2008)"
fi

echo "TC-SYMLINK-local: isolation-internal symlink → allow (no regression)"
: > "$ISO_MUT_DIR/realfile.txt"
ln -s "$ISO_MUT_DIR/realfile.txt" "$ISO_MUT_DIR/local-link"
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/local-link" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") && rc=0 || rc=$?
assert_allow "isolation-internal symlink still allowed" "$out" "$rc"
rm -f "$ISO_MUT_DIR/local-link" "$ISO_MUT_DIR/realfile.txt"
echo ""

echo "TC-SYMLINK-main: MAIN-session write to symlink into parent .git → allow (IS_SUBAGENT=0)"
ln -s "$TEST_REPO/.git/hooks/pre-commit" "$ISO_MUT_DIR/main-link"
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/main-link" "$ISO_MUT_DIR" "$MAIN_TRANSCRIPT") && rc=0 || rc=$?
assert_allow "main-session symlink write not blocked" "$out" "$rc"
rm -f "$ISO_MUT_DIR/main-link"
echo ""

# --------------------------------------------------------------------------
# fail-closed: a crash in the deny-emit (jq -n) still DENIES (exit 2), never allows.
# A PATH shim fails only `jq -n` (the deny payload) and passes every INPUT-parsing jq
# through to the real jq, so scope is confirmed and only the final emit crashes.
# --------------------------------------------------------------------------
echo "TC-FAILCLOSED: deny-emit jq crash → fail-closed (deny + exit 2)"
shimdir=$(mktemp -d)
cat > "$shimdir/jq" <<SHIM
#!/bin/bash
for a in "\$@"; do [ "\$a" = "-n" ] && exit 1; done
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$shimdir/jq"
rc=0
out=$(jq -n --arg p "$TEST_REPO/src/x.py" --arg cwd "$TEST_REPO" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Edit", tool_input: {file_path: $p}, cwd: $cwd, transcript_path: $tp}' \
  | PATH="$shimdir:$PATH" bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
if [ "$(decision_of "$out")" = "deny" ] && [ "$rc" = "2" ]; then
  pass "deny-emit crash denies fail-closed (exit 2)"
else
  fail "expected deny + exit 2, got decision=$(decision_of "$out") rc=$rc"
fi
rm -rf "$shimdir"
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
