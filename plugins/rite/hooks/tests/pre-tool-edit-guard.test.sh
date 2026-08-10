#!/bin/bash
# Tests for pre-tool-edit-guard.sh (PreToolUse hook,)
# Usage: bash plugins/rite/hooks/tests/pre-tool-edit-guard.test.sh
#
# Verifies AC-1 (reviewer subagent Edit/Write/MultiEdit/NotebookEdit to the parent
# working tree is denied — including token-in-filename / `..` re-entry forgery of the
# isolation allowlist,  review cycle 1) and AC-4 (normal review and
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
rp_shimdir=""              # set by TC-SYMLINK-BSD-REALPATH; tracked separately for the same reason
rl_shimdir=""              # set by TC-SYMLINK-lf-target-bsd; tracked separately for the same reason

cleanup() {
  rm -f "$STDERR_FILE"
  ( cd "$TEST_REPO" 2>/dev/null && git worktree remove --force "$ISO_MUT_DIR" 2>/dev/null ) || true
  ( cd "$TEST_REPO" 2>/dev/null && git worktree remove --force "$ISO_REV_DIR" 2>/dev/null ) || true
  rm -rf "$TEST_REPO" "$ISO_MUT_DIR" "$ISO_REV_DIR" "$OUTSIDE_DIR" ${shimdir:+"$shimdir"} ${rp_shimdir:+"$rp_shimdir"} ${rl_shimdir:+"$rl_shimdir"}
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi
REAL_JQ=$(command -v jq)   # absolute path, captured before any PATH-shim test shadows `jq`
# Same reason for realpath: TC-SYMLINK-BSD-REALPATH shims it, and the shim itself
# execs the real binary. Empty when realpath is absent — that TC then skips.
REAL_REALPATH=$(command -v realpath 2>/dev/null) || REAL_REALPATH=""
# Same for readlink: TC-SYMLINK-lf-target-bsd shims it to the macOS-observed
# no-delimiter behaviour. Empty when readlink is absent — that TC then skips.
REAL_READLINK=$(command -v readlink 2>/dev/null) || REAL_READLINK=""

# _timeout <seconds> <command...> — portable timeout(1) for this test.
#
# Byte-identical copy of the reference definition in _test-helpers.sh. This file does not
# source _test-helpers.sh (it defines its own pass/fail/skip counters below), so the shim is
# inlined here. timeout-shim.test.sh TC-7 compares every discovered copy against that
# reference and TC-8 requires the fail-closed guard below, so edit the reference first and
# re-copy — do not hand-tune this block.
_timeout() {
  local _d="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_d" "$@"
  else
    perl -e '
      my $d = shift;
      # alarm truncates to an integer, so a fractional deadline silently becomes
      # alarm 0 — no timeout at all, and waitpid blocks until the CI job limit.
      # Reject rather than degrade, and exit 125 rather than die: die exits 255,
      # which every caller reads as "not 124, so no hang" — the same silent pass
      # the rejection exists to prevent. GNU timeout accepts fractions, so this
      # shim only claims the contract for integer seconds.
      if ($d !~ /^[0-9]+$/) {
        print STDERR "_timeout: fractional seconds are not supported by the perl fallback: $d\n";
        exit 125;
      }
      my $pid = fork;
      exit 127 unless defined $pid;
      # setpgrp puts the child in its own process group so the alarm handler can
      # signal the whole tree with a negative pid. GNU timeout does the same; without
      # it the deadline only reaches the direct child, and a grandchild holding the
      # captured stdout keeps the caller blocked long past the timeout (measured 30s
      # against a 1s deadline). The runners capture output with $( ), so that stall
      # would consume the CI job limit instead of failing at 124.
      if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", -$pid; waitpid($pid, 0); exit 124; };
      alarm $d; waitpid $pid, 0;
      my $st = $?; exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$_d" "$@"
  fi
}

# Fail closed when no backend exists. Every `_timeout` caller reads a non-124 rc
# as "no hang", so a missing backend would silently turn each hang assertion into
# a pass. Abort at source time rather than degrade.
if ! command -v timeout >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
  echo "ERROR: neither timeout(1) nor perl(1) is available — _timeout cannot detect" >&2
  echo "  hangs, and every hang assertion in this suite would silently pass." >&2
  echo "  Install GNU coreutils (timeout) or perl before running the test suite." >&2
  exit 1
fi


pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }
# Skips are counted so a platform-gated green states how many assertions never ran
# (review G-04). This file does not source _test-helpers.sh.
SKIP=0
skip() { SKIP=$((SKIP + 1)); echo "  ⏭️ SKIP: $1"; }

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
# BYPASS regression (review cycle 1) — forged isolation paths → deny
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
# .git-internal writes → deny (review cycle 2 — .git/hooks/pre-commit
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
# Final-element symlink resolution (AC-2): a symlink dropped INSIDE a
# sanctioned isolation worktree that points at the parent repo's .git / working tree
# is dereferenced BEFORE the isolation decision, so it can no longer dodge the guard
# by landing _tdir on the isolation root. AC-3 note: Claude Code's own Edit/Write
# tools already refuse symlink writes, so this is defense-in-depth.
# --------------------------------------------------------------------------
# These TCs used to be skipped wherever `realpath` could not resolve a dangling
# symlink, because the hook resolved the final element with `realpath` and that
# no-op'd on BSD/macOS — a production gap, not a test quirk (→ #2014).
# The hook now retargets ABS_PATH via bare `readlink` and lets the _tdir walk do the
# physical resolution, which needs no existence check and has no platform branch, so
# the skip is gone and these run everywhere. TC-SYMLINK-BSD-REALPATH below pins that
# platform-independence down by proving the chain still denies when `realpath` is
# shimmed to BSD semantics.
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

# Intermediate directory names ending in LF must survive the ancestor split
# byte-for-byte. A command substitution around dirname strips that LF and scopes
# the isolation worktree instead of the parent tree reached by the symlink.
echo "TC-SYMLINK-lf-intermediate: LF directory symlink into parent tree → deny"
lf_intermediate=$'dir-link\n'
mkdir -p "$TEST_REPO/lf-target-dir"
ln -s "$TEST_REPO/lf-target-dir" "$ISO_MUT_DIR/$lf_intermediate"
ln -s "$ISO_MUT_DIR/$lf_intermediate/newfile.py" "$ISO_MUT_DIR/evil-lf-intermediate"
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/evil-lf-intermediate" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "LF-terminated intermediate directory is preserved and blocked" "$out"
rm -f "$ISO_MUT_DIR/evil-lf-intermediate" "$ISO_MUT_DIR/$lf_intermediate"
rmdir "$TEST_REPO/lf-target-dir" || fail "LF intermediate fixture cleanup failed"
echo ""

# Write-style lexical normalization removes these spellings before opening the
# path. The hook must make the same decision before testing the final symlink,
# or it scopes the isolation tree while the normalized write reaches .git.
echo "TC-SYMLINK-lexical-spellings: trailing /, /. and missing/../ forms → deny"
ln -s "$TEST_REPO/.git/hooks/pre-commit" "$ISO_MUT_DIR/evil-lexical"
for lexical_path in \
  "$ISO_MUT_DIR/evil-lexical/" \
  "$ISO_MUT_DIR/evil-lexical/." \
  "$ISO_MUT_DIR/missing/../evil-lexical"
do
  out=$(run_edit_guard "Write" "$lexical_path" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
  assert_deny_gitdir "lexically normalized symlink spelling blocked: $lexical_path" "$out"
done
rm -f "$ISO_MUT_DIR/evil-lexical"
echo ""

# A two-link chain: resolving only ONE hop would leave ABS_PATH at `$ISO_MUT_DIR/hop`,
# landing _tdir back on the isolation root → allow. Pins the loop against a future
# "just dereference once" simplification.
echo "TC-SYMLINK-chain: isolation symlink → symlink → parent .git → deny (git-dir)"
ln -s "$TEST_REPO/.git/hooks/pre-commit" "$ISO_MUT_DIR/hop"
ln -s "$ISO_MUT_DIR/hop" "$ISO_MUT_DIR/evil-chain"
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/evil-chain" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
assert_deny_gitdir "multi-hop symlink chain into parent .git resolved & blocked" "$out"
rm -f "$ISO_MUT_DIR/evil-chain" "$ISO_MUT_DIR/hop"
echo ""

# The target's PARENT does not exist either, so any fix that canonicalizes the link
# target's parent dir (the shape first proposed in) still no-ops here and
# falls through to allow. Handing the raw target to the _tdir walk denies, because the
# walk climbs to the nearest EXISTING ancestor ($TEST_REPO/src) before asking git.
echo "TC-SYMLINK-missing-parent: isolation symlink → not-yet-created dir in parent tree → deny (parent-tree)"
mkdir -p "$TEST_REPO/src"
ln -s "$TEST_REPO/src/newdir/newfile.py" "$ISO_MUT_DIR/evil-missing-parent"
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/evil-missing-parent" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "symlink to a not-yet-created parent-tree path resolved & blocked" "$out"
rm -f "$ISO_MUT_DIR/evil-missing-parent"
# Roll the fixture back so no later TC silently depends on $TEST_REPO/src existing (several
# earlier TCs exercise the walk-up branch precisely because it does NOT). Best-effort: the
# directory is inside $TEST_REPO, which cleanup() removes wholesale either way.
rmdir "$TEST_REPO/src" 2>/dev/null || true
echo ""

# Every TC above uses an ABSOLUTE link target, so none of them execute the relative-target
# branch (`*) _lt="${ABS_PATH%/*}/$_lt"`). That branch is load-bearing — stubbing it out to
# `: ;` leaves the whole suite green while a relative `../<repo>/.git/hooks/pre-commit` link
# walks straight into the parent .git. Assert the deny KIND, not just "deny": with the branch
# stubbed the target can still deny as parent-tree, so only the git-dir kind tells a working
# branch from a stubbed one.
#
# Run the hook from `/` rather than inheriting the caller's cwd. With the branch stubbed,
# ABS_PATH stays the RELATIVE `../<repo>/.git/hooks/pre-commit`, which the _tdir walk resolves
# against the hook process's own cwd — so a caller sitting one level under $TMPDIR (exactly
# where agents/_reviewer-base.md tells reviewers to run their mutation experiments) makes the
# stubbed branch resolve correctly by accident and the TC pass. `/` has no such sibling.
echo "TC-SYMLINK-relative: isolation symlink with a RELATIVE target → parent .git → deny (git-dir)"
ln -s "../$(basename "$TEST_REPO")/.git/hooks/pre-commit" "$ISO_MUT_DIR/evil-rel"
out=$(cd / && run_edit_guard "Write" "$ISO_MUT_DIR/evil-rel" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
assert_deny_gitdir "relative symlink target into parent .git resolved & blocked" "$out"
rm -f "$ISO_MUT_DIR/evil-rel"

# Pair the deny case with an allow case, or "make the relative branch always deny" would pass.
: > "$ISO_MUT_DIR/rel-target.txt"
ln -s "rel-target.txt" "$ISO_MUT_DIR/rel-local"
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/rel-local" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") && rc=0 || rc=$?
assert_allow "isolation-internal relative symlink still allowed" "$out" "$rc"
rm -f "$ISO_MUT_DIR/rel-local" "$ISO_MUT_DIR/rel-target.txt"
echo ""

# The hop cap is what makes a symlink CYCLE terminate. Without it this PreToolUse hook spins
# until the harness 10s timeout on every Edit/Write — invisible to CI, fatal in production.
# Asserting "allow" alone would be vacuous (deleting the whole deref block also allows), so
# assert TERMINATION: run under the portable `_timeout` shim and treat rc=124 as the failure.
# Bare `timeout(1)` must not be used — it is absent on macOS (the CI leg deliberately omits
# coreutils), where the call would exit 127 and this pin would silently stop testing anything.
echo "TC-SYMLINK-cycle: symlink cycle → terminates via hop cap (no hang) → allow"
ln -s "$ISO_MUT_DIR/cyc2" "$ISO_MUT_DIR/cyc1"
ln -s "$ISO_MUT_DIR/cyc1" "$ISO_MUT_DIR/cyc2"
rc=0
out=$(jq -n --arg p "$ISO_MUT_DIR/cyc1" --arg cwd "$ISO_MUT_DIR" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Write", tool_input: {file_path: $p}, cwd: $cwd, transcript_path: $tp}' \
  | _timeout 10 bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
if [ "$rc" = "124" ]; then
  fail "symlink cycle did not terminate within 10s (hop cap missing?)"
else
  assert_allow "symlink cycle terminates and falls through to allow" "$out" "$rc"
fi
rm -f "$ISO_MUT_DIR/cyc1" "$ISO_MUT_DIR/cyc2"
echo ""

# TC-SYMLINK-cycle above pins that a cap EXISTS; it does not pin its VALUE. Lowering the cap
# to anything >= 2 leaves the whole suite green, yet a cap below the kernel's own limit
# reopens the multi-hop bypass: for chain lengths between cap+1 and the kernel limit the hook
# gives up (leaving ABS_PATH a link inside the isolation worktree → allow) while the kernel
# happily follows the rest of the chain into the parent .git. Pin the LOWER bound only — a
# larger cap is equally safe, so asserting the upper side would over-pin the implementation.
echo "TC-SYMLINK-hop-cap-value: a chain exactly at the cap still resolves → deny (git-dir)"
ln -s "$TEST_REPO/.git/hooks/pre-commit" "$ISO_MUT_DIR/hopchain-0"
for _i in $(seq 1 39); do
  ln -s "$ISO_MUT_DIR/hopchain-$((_i - 1))" "$ISO_MUT_DIR/hopchain-$_i"
done
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/hopchain-39" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
assert_deny_gitdir "40-hop chain into parent .git resolved & blocked (cap must be >= 40)" "$out"
for _i in $(seq 0 39); do rm -f "$ISO_MUT_DIR/hopchain-$_i"; done
echo ""

# A link target that ends in LF is where a command-substitution capture silently truncates:
# `$(readlink …)` strips every trailing newline, so the hook would scope `<iso>/lf-mid`
# (inside the isolation worktree → allow) while the kernel follows `<iso>/lf-mid<LF>` into the
# parent tree. Both shapes below deny only when the capture is byte-exact.
echo "TC-SYMLINK-lf-target: link target ending in LF → parent .git → deny (git-dir)"
lf_name=$'lf-mid\n'
ln -s "$TEST_REPO/.git/hooks/pre-commit" "$ISO_MUT_DIR/$lf_name"
ln -s "$lf_name" "$ISO_MUT_DIR/evil-lf"
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/evil-lf" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
assert_deny_gitdir "LF-terminated link target resolved & blocked" "$out"

# The assertion above passes on GNU even when the capture is NOT byte-exact, because GNU
# readlink appends a newline that a "strip one trailing LF" step happens to undo. macOS
# readlink appends nothing, so the same step eats a GENUINE trailing LF and the deref lands on
# a nonexistent path → allow. That divergence reached CI as a macOS-only failure of this very
# TC while Linux stayed green, i.e. exactly the platform-gap shape #2014 exists to close.
# Shim readlink to the macOS-observed behaviour (no trailing delimiter) so the blocking gate
# sees it too. perl reads the link raw and prints it without a delimiter; `$(…)` cannot be used
# inside the shim because it would strip the very byte under test.
if [ -n "$REAL_READLINK" ] && command -v perl >/dev/null 2>&1; then
  echo "TC-SYMLINK-lf-target-bsd: LF-terminated target under a no-delimiter readlink → deny (git-dir)"
  rl_shimdir=$(mktemp -d)
  cat > "$rl_shimdir/readlink" <<'SHIM'
#!/bin/bash
_t=""
for a in "$@"; do case "$a" in -*) continue ;; *) _t=$a ;; esac; done
exec perl -e 'my $l = readlink($ARGV[0]); exit 1 unless defined $l; print $l;' "$_t"
SHIM
  chmod +x "$rl_shimdir/readlink"

  # Floor: a shim that never gets picked up would make the assertion below a duplicate of the
  # GNU one above rather than a BSD-parity check. Probe with a target that does NOT end in LF
  # and capture through a sentinel, so the comparison sees the delimiter byte itself rather
  # than losing it to `$( )` — the exact trap this whole TC exists to pin.
  ln -s "rl-probe-target" "$ISO_MUT_DIR/rl-probe"
  _rl_probe=$(PATH="$rl_shimdir:$PATH" readlink "$ISO_MUT_DIR/rl-probe"; printf 'X')
  if [ "${_rl_probe%X}" = "rl-probe-target" ]; then
    pass "no-delimiter readlink shim is in effect (emits no trailing newline)"
  else
    fail "TC-SYMLINK-lf-target-bsd: the no-delimiter readlink shim did not take effect — the BSD-parity assertion below would be vacuous"
  fi
  rm -f "$ISO_MUT_DIR/rl-probe"

  out=$(PATH="$rl_shimdir:$PATH" jq -n --arg p "$ISO_MUT_DIR/evil-lf" --arg cwd "$ISO_MUT_DIR" \
    --arg tp "$SUBAGENT_TRANSCRIPT" \
    '{tool_name: "Write", tool_input: {file_path: $p}, cwd: $cwd, transcript_path: $tp}' \
    | PATH="$rl_shimdir:$PATH" bash "$HOOK" 2>"$STDERR_FILE") || true
  assert_deny_gitdir "LF-terminated target blocked under a no-delimiter readlink" "$out"

  rm -rf "$rl_shimdir"; rl_shimdir=""
elif [ -d /proc ]; then
  fail "TC-SYMLINK-lf-target-bsd floor: readlink or perl unavailable on Linux — the BSD readlink-parity pin must never be skipped on the blocking gate"
else
  skip "TC-SYMLINK-lf-target-bsd skipped (readlink or perl unavailable, so the no-delimiter behaviour cannot be shimmed)"
fi

rm -f "$ISO_MUT_DIR/evil-lf" "$ISO_MUT_DIR/$lf_name"
echo ""

# Same truncation, but via the DIRECTORY component: `$(dirname …)` on `<iso>/lf-dir<LF>/rel`
# returns `<iso>/lf-dir` once the trailing LF is stripped. Only a parameter-expansion split
# keeps the byte. Uses a relative target so the dirname branch is the one under test.
echo "TC-SYMLINK-lf-dirname: link inside an LF-terminated directory → parent tree → deny (parent-tree)"
lf_dir=$'lf-dir\n'
mkdir -p "$ISO_MUT_DIR/$lf_dir"
ln -s "../../$(basename "$TEST_REPO")/tracked.py" "$ISO_MUT_DIR/$lf_dir/rel"
ln -s "$ISO_MUT_DIR/$lf_dir/rel" "$ISO_MUT_DIR/evil-lf-dir"
out=$(run_edit_guard "Write" "$ISO_MUT_DIR/evil-lf-dir" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") || true
assert_deny "LF-terminated directory component preserved & blocked" "$out"
# The resolved ABS_PATH here carries a raw LF, which is exactly what would split the
# single-line `edit-guard: BLOCKED … path="…"` audit record in two and let a reviewer forge a
# second record. `grep -c 'edit-guard: BLOCKED'` cannot see that — the split happens INSIDE
# path="…", so the count stays 1 either way. Requiring the closing quote AND the neutralized
# `lf-dir?` on the same line distinguishes a neutralized record from a split one, and it stays
# robust when hook-preamble or other callers add unrelated stderr lines.
#
# The hook only reports ${ABS_PATH:0:120}, so this pin can only observe a split while the LF
# lands inside that window. Under a long $TMPDIR the truncation drops the LF and the record
# stays one line even with the neutralization removed — the pin would silently stop testing
# anything. Floor it the same two-tier way the rest of this file does: hard-fail on the
# blocking gate, skip elsewhere so a long-$TMPDIR workstation is not spuriously red.
#
# `[^"]*` relies on this fixture's path containing no `"` — the hook escapes an embedded quote
# to `\"` (pre-tool-edit-guard.sh), which would stop the class short of the closing quote and
# fail even with the defense intact. Keep quotes out of the names used here.
_lf_off=$(( ${#ISO_MUT_DIR} + ${#lf_dir} ))   # byte offset of the LF within "<iso>/lf-dir<LF>"
if [ "$_lf_off" -ge 120 ]; then
  if [ -d /proc ]; then
    fail "TC-SYMLINK-lf-dirname floor: the LF sits at byte $_lf_off, outside the hook's 120-byte path summary window (\$TMPDIR too long) — the log-injection pin below would be vacuous"
  else
    skip "TC-SYMLINK-lf-dirname log-injection pin (LF at byte $_lf_off is outside the hook's 120-byte window; \$TMPDIR is ${#TMPDIR} chars)"
  fi
elif grep -q 'edit-guard: BLOCKED .*path="[^"]*lf-dir?[^"]*"$' "$STDERR_FILE"; then
  pass "BLOCKED audit record stays one physical line with the LF neutralized"
else
  fail "BLOCKED audit record was split by a raw LF (log-injection defense missing): $(cat -e "$STDERR_FILE" | head -3)"
fi
# Remove the exact entries rather than `rm -rf` the directory: an empty $ISO_MUT_DIR would
# make a recursive delete target the filesystem root (SC2115). `|| fail` rather than a bare
# rmdir: under `set -e` a leftover entry would abort the suite before the `=== Results ===`
# summary, hiding how many assertions ran (the honesty the SKIP counter exists to protect).
rm -f "$ISO_MUT_DIR/evil-lf-dir" "$ISO_MUT_DIR/$lf_dir/rel"
rmdir "$ISO_MUT_DIR/$lf_dir" || fail "TC-SYMLINK-lf-dirname cleanup: $ISO_MUT_DIR/\$lf_dir not empty"
echo ""

# --------------------------------------------------------------------------
# BSD/macOS realpath parity. The gitdir TC above passes on Linux even
# with a realpath-based resolution, so it alone cannot catch a regression back to one
# that needs `realpath` to tolerate a dangling final component. Shim `realpath` to BSD
# semantics — every component INCLUDING the last must exist — and re-run the two attack
# shapes. `[ -e ]` follows symlinks, so a dangling link fails the shim exactly as BSD
# realpath does, while an existing dir passes straight through to the real binary (which
# keeps hook-preamble.sh's own realpath call working).
# --------------------------------------------------------------------------
# Linux is the blocking gate, so a security TC must never skip there. The old
# RESOLVES_DANGLING_SYMLINK floor guarded the AC-2 TCs; those now run unconditionally, but this
# gate introduces a NEW skip path (`realpath` missing or shadowed on PATH) that would silently
# drop the only regression pin against going back to a realpath-dependent resolution. Same
# floor shape as wiki-lint-broken-refs.test.sh — `[ -d /proc ]` rather than `uname -s` because
# the threat is a tampered PATH and `uname` is looked up on that same PATH.
if [ -d /proc ] && [ -z "$REAL_REALPATH" ]; then
  fail "TC-SYMLINK-BSD-REALPATH floor: realpath unavailable on Linux (missing or shadowed on PATH?) — the BSD-parity regression pin must never be skipped on the blocking gate"
fi

if [ -n "$REAL_REALPATH" ]; then
  echo "TC-SYMLINK-BSD-REALPATH: AC-2 resolution does not depend on GNU realpath"
  rp_shimdir=$(mktemp -d)
  cat > "$rp_shimdir/realpath" <<SHIM
#!/bin/bash
for a in "\$@"; do
  case "\$a" in -*) continue ;; esac
  [ -e "\$a" ] || exit 1
done
exec "$REAL_REALPATH" "\$@"
SHIM
  chmod +x "$rp_shimdir/realpath"

  # Floor: a shim that never gets picked up would turn this whole TC into a false green.
  # The probe target must be a name `git init` can never materialise — pointing it at
  # .git/hooks/pre-commit would spuriously fail this floor on a host whose
  # init.templateDir ships a real pre-commit hook (husky-style templates do).
  ln -s "$TEST_REPO/.git/hooks/rite-2014-no-such-hook" "$ISO_MUT_DIR/shim-probe"
  if PATH="$rp_shimdir:$PATH" realpath "$ISO_MUT_DIR/shim-probe" >/dev/null 2>&1; then
    fail "TC-SYMLINK-BSD-REALPATH: the BSD realpath shim did not take effect (still resolving a dangling symlink) — the GNU-independence assertions below would be vacuous"
  else
    pass "BSD realpath shim is in effect (dangling symlink errors, as on macOS)"
  fi
  rm -f "$ISO_MUT_DIR/shim-probe"

  ln -s "$TEST_REPO/.git/hooks/pre-commit" "$ISO_MUT_DIR/bsd-into-gitdir"
  out=$(PATH="$rp_shimdir:$PATH" jq -n --arg p "$ISO_MUT_DIR/bsd-into-gitdir" --arg cwd "$ISO_MUT_DIR" \
    --arg tp "$SUBAGENT_TRANSCRIPT" \
    '{tool_name: "Write", tool_input: {file_path: $p}, cwd: $cwd, transcript_path: $tp}' \
    | PATH="$rp_shimdir:$PATH" bash "$HOOK" 2>"$STDERR_FILE") || true
  assert_deny_gitdir "isolation symlink into parent .git blocked under BSD realpath" "$out"
  rm -f "$ISO_MUT_DIR/bsd-into-gitdir"

  ln -s "$TEST_REPO/tracked.py" "$ISO_MUT_DIR/bsd-into-tree"
  out=$(PATH="$rp_shimdir:$PATH" jq -n --arg p "$ISO_MUT_DIR/bsd-into-tree" --arg cwd "$ISO_MUT_DIR" \
    --arg tp "$SUBAGENT_TRANSCRIPT" \
    '{tool_name: "Write", tool_input: {file_path: $p}, cwd: $cwd, transcript_path: $tp}' \
    | PATH="$rp_shimdir:$PATH" bash "$HOOK" 2>"$STDERR_FILE") || true
  assert_deny "isolation symlink into parent working tree blocked under BSD realpath" "$out"
  rm -f "$ISO_MUT_DIR/bsd-into-tree"

  rm -rf "$rp_shimdir"; rp_shimdir=""
  echo ""
else
  skip "TC-SYMLINK-BSD-REALPATH skipped (no realpath on PATH, so BSD semantics cannot be shimmed; the TCs above already cover the resolution itself)"
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
echo "=== Results: $PASS passed, $FAIL failed$( [ "$SKIP" -gt 0 ] && printf ", %s skipped" "$SKIP" ) ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
