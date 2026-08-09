#!/bin/bash
# bang-backtick-pr-create-pre-check.test.sh
#
# Regression tests for the Phase 1.0 Pre-PR Gate added to
# `skills/pr-create/SKILL.md` and `skills/ready/SKILL.md`.
# The gate invokes `bang-backtick-check.sh --all` and exits non-zero on
# detection or invocation failure.
#
# This test pins three things:
#   1. The underlying scanner's behavior on the present repository
#      (clean develop must remain exit 0; deliberately seeded dirt must
#      produce exit 1) — this is the runtime AC-2 / AC-3 evidence.
#   2. The DRIFT-CHECK ANCHOR between create.md §1.0 and ready.md §1.0
#      (the bash literal MUST be byte-for-byte identical between the
#      two files — Wiki 経験則「Asymmetric Fix Transcription」予防).
#   3. The non-regression of `/rite:lint` Phase 3.5 (generic loop) — lint.md must
#      still invoke `bang-backtick-check.sh --all` AND treat its exit
#      code as a warning rather than an error (AC-4).
#
# 経路 D (pre-PR hard gate).
#
# Pinned acceptance criteria:
#   AC-2 (Happy path: 経路 D PR 提出前 block) — TC-2
#   AC-3 (Boundary: false positive なし)        — TC-1
#   AC-4 (Non-regression: /rite:lint 経路)       — TC-5
#   §4.5 sentinel emit (script 不在 / rc=2)       — TC-3
#   §7 MUST DRIFT-CHECK ANCHOR (create/ready)    — TC-4
#
# Usage: bash plugins/rite/hooks/tests/bang-backtick-pr-create-pre-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_DIR="$SCRIPT_DIR/.."
PLUGIN_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
CHECK_SCRIPT="$HOOK_DIR/scripts/bang-backtick-check.sh"
CREATE_MD="$PLUGIN_ROOT/skills/pr-create/SKILL.md"
READY_MD="$PLUGIN_ROOT/skills/ready/SKILL.md"
LINT_MD="$PLUGIN_ROOT/skills/lint/SKILL.md"
PASS=0
FAIL=0

[ -f "$CHECK_SCRIPT" ] || { echo "ERROR: $CHECK_SCRIPT not found" >&2; exit 1; }
[ -f "$CREATE_MD" ] || { echo "ERROR: $CREATE_MD not found" >&2; exit 1; }
[ -f "$READY_MD" ] || { echo "ERROR: $READY_MD not found" >&2; exit 1; }
[ -f "$LINT_MD" ] || { echo "ERROR: $LINT_MD not found" >&2; exit 1; }

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# ----- TC-1: AC-3 — clean repo state, --all exits 0 -------------------------
echo "TC-1: AC-3 — current repo HEAD has no bang-backtick adjacency (clean state)"
clean_rc=0
clean_output=$(bash "$CHECK_SCRIPT" --repo-root "$REPO_ROOT" --all --quiet 2>&1) || clean_rc=$?
if [ "$clean_rc" -eq 0 ]; then
  pass "TC-1 --all exit 0 on clean repo"
else
  fail "TC-1 --all expected exit 0, got $clean_rc"
  printf '%s\n' "$clean_output" | head -20 >&2
fi

# ----- TC-2: AC-2 — seeded dirt produces exit 1 ----------------------------
echo "TC-2: AC-2 — seeded dirt in plugins/rite/skills/ produces exit 1"
seed_dir=$(mktemp -d)
trap 'rm -rf "$seed_dir"' EXIT
# Recreate a minimal rite plugin layout so the scanner's --all has a tree to walk.
mkdir -p "$seed_dir/plugins/rite/skills/pr"
mkdir -p "$seed_dir/plugins/rite/skills"
mkdir -p "$seed_dir/plugins/rite/agents"
mkdir -p "$seed_dir/plugins/rite/references"
# Inject a P1 pattern: backtick + space + bang + closing backtick adjacency.
printf '%s\n' "Bad: \` !\` adjacency must trigger." > "$seed_dir/plugins/rite/skills/pr/dirty.md"
seed_rc=0
seed_output=$(bash "$CHECK_SCRIPT" --repo-root "$seed_dir" --all --quiet 2>&1) || seed_rc=$?
if [ "$seed_rc" -eq 1 ]; then
  pass "TC-2 --all exit 1 on seeded dirt"
else
  fail "TC-2 --all expected exit 1, got $seed_rc"
  printf '%s\n' "$seed_output" | head -10 >&2
fi
if printf '%s\n' "$seed_output" | grep -q '\[bang-backtick\]'; then
  pass "TC-2 finding line includes [bang-backtick] tag"
else
  fail "TC-2 finding line missing [bang-backtick] tag"
fi

# ----- TC-3: §4.5 — script-missing sentinel emit pattern ----------------
# Simulate the Phase 1.0 bash block's missing-script branch by sourcing the
# same logic in isolation: with a non-existent CHECK path, the case branch
# must (a) emit the BANG_BACKTICK_CHECK_INVOCATION_FAILED=1 sentinel, and
# (b) exit 1.
echo "TC-3: §4.5 — script-missing emits sentinel and exits 1"
fake_root="$seed_dir/no-such-plugin-root"
sentinel_rc=0
sentinel_stderr=$(mktemp)
{
  bash -c '
    plugin_root="$1"
    if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/scripts/bang-backtick-check.sh" ]; then
      echo "[CONTEXT] BANG_BACKTICK_CHECK_INVOCATION_FAILED=1; reason=script_missing; resolved_root=${plugin_root:-<empty>}" >&2
      echo "ERROR: bang-backtick-check.sh not found." >&2
      exit 1
    fi
  ' _ "$fake_root" 2>"$sentinel_stderr"
} || sentinel_rc=$?
if [ "$sentinel_rc" -eq 1 ]; then
  pass "TC-3 missing-script branch exits 1"
else
  fail "TC-3 missing-script branch expected exit 1, got $sentinel_rc"
fi
if grep -q 'BANG_BACKTICK_CHECK_INVOCATION_FAILED=1; reason=script_missing' "$sentinel_stderr"; then
  pass "TC-3 sentinel emitted with reason=script_missing"
else
  fail "TC-3 sentinel missing"
  cat "$sentinel_stderr" >&2
fi
rm -f "$sentinel_stderr"

# ----- TC-4: shared scanner core and ready-only PR-head resolution ----------
echo "TC-4: shared scanner core and ready-only PR-head resolution"
inv_create=$(grep -c 'bash "$plugin_root/hooks/scripts/bang-backtick-check.sh" --all --skip-if-no-target 2>&1' "$CREATE_MD" || true)
inv_ready=$(grep -c 'bash "$plugin_root/hooks/scripts/bang-backtick-check.sh" --all --skip-if-no-target --repo-root "$scan_root" 2>&1' "$READY_MD" || true)
if [ "$inv_create" -ge 1 ] && [ "$inv_ready" -ge 1 ]; then
  pass "TC-4 scanner core present with ready-specific --repo-root"
else
  fail "TC-4 scanner invocation missing (create=$inv_create, ready=$inv_ready)"
fi

sentinel_create=$(grep -c 'BANG_BACKTICK_CHECK_INVOCATION_FAILED=1' "$CREATE_MD" || true)
sentinel_ready=$(grep -c 'BANG_BACKTICK_CHECK_INVOCATION_FAILED=1' "$READY_MD" || true)
if [ "$sentinel_create" -ge 2 ] && [ "$sentinel_ready" -ge 2 ]; then
  # ≥2 because the literal appears in both the script_missing branch and
  # the rc=invocation_error branch.
  pass "TC-4 sentinel literal present (≥2x) in BOTH create.md and ready.md"
else
  fail "TC-4 sentinel literal mismatch (create=$sentinel_create, ready=$sentinel_ready)"
fi

header_create=$(grep -c '^### 1.0 Bang-Backtick Adjacency Pre-Check (Pre-PR Gate)$' "$CREATE_MD" || true)
header_ready=$(grep -c '^### 1.0 Bang-Backtick Adjacency Pre-Check (Pre-PR Gate)$' "$READY_MD" || true)
if [ "$header_create" -eq 1 ] && [ "$header_ready" -eq 1 ]; then
  pass "TC-4 sub-section header '### 1.0 Bang-Backtick Adjacency Pre-Check (Pre-PR Gate)' present in BOTH"
else
  fail "TC-4 sub-section header mismatch (create=$header_create, ready=$header_ready)"
fi

# DRIFT-CHECK ANCHOR comment itself MUST appear in both files so future edits
# see the synchronization requirement.
anchor_create=$(grep -c 'DRIFT-CHECK ANCHOR' "$CREATE_MD" || true)
anchor_ready=$(grep -c 'DRIFT-CHECK ANCHOR' "$READY_MD" || true)
if [ "$anchor_create" -ge 1 ] && [ "$anchor_ready" -ge 1 ]; then
  pass "TC-4 DRIFT-CHECK ANCHOR comment present in BOTH"
else
  fail "TC-4 DRIFT-CHECK ANCHOR comment missing (create=$anchor_create, ready=$anchor_ready)"
fi

# The not-applicable skip-note handling added to the 0) case (Issue #1550) MUST
# also be symmetric between create.md and ready.md. Pin the skip-note's
# user-facing echo message ("...self-host していないため N/A..."), which is
# unique to the 0)-case skip-note block. The bare substring "not applicable"
# is NOT used: it also appears in unrelated review-scope prose elsewhere in
# create.md, so it would pass even if the real skip-note line were deleted.
skipnote_create=$(grep -cF 'self-host していないため N/A' "$CREATE_MD" || true)
skipnote_ready=$(grep -cF 'self-host していないため N/A' "$READY_MD" || true)
if [ "$skipnote_create" -ge 1 ] && [ "$skipnote_ready" -ge 1 ]; then
  pass "TC-4 not-applicable skip-note present in BOTH create.md and ready.md"
else
  fail "TC-4 skip-note mismatch (create=$skipnote_create, ready=$skipnote_ready)"
fi

# ----- TC-5: AC-4 — /rite:lint Phase 3.5 generic loop still invokes the same scanner ----
echo "TC-5: AC-4 — /rite:lint Phase 3.5 generic loop unchanged (non-regression)"
lint_inv=$(grep -c 'bang-backtick-check.sh --all' "$LINT_MD" || true)
if [ "$lint_inv" -ge 1 ]; then
  pass "TC-5 lint.md still invokes 'bang-backtick-check.sh --all'"
else
  fail "TC-5 lint.md missing scanner invocation (regression)"
fi
# Lint must keep treating findings as warnings (Phase 3.5 generic loop contract: exit 1
# yields `bang_backtick_status: warning`, not error).
if grep -q 'bang_backtick_status' "$LINT_MD"; then
  pass "TC-5 lint.md retains bang_backtick_status warning record"
else
  fail "TC-5 lint.md missing bang_backtick_status record"
fi

# ----- TC-12: CRITICAL regression guard — Style B example must use single-quotes -
# 旧コミット e50d08e で create.md / ready.md / hook script に backtick 囲みの literal
# `if ! cmd; then` が混入し、bash double-quoted echo 内で command substitution が発火する
# CRITICAL bug が発生 (3 site 同形 transcription、Wiki 経験則「Asymmetric Fix Transcription」の
# inverse failure)。byte 比較で single-quote 囲みであることを pin する。
echo "TC-12: CRITICAL regression — Style B 'if ! cmd; then' literal must use single-quotes (not backticks)"
for f in "$CREATE_MD" "$READY_MD"; do
  fname=$(basename "$f")
  if grep -qF "expand 'if ! cmd; then'" "$f"; then
    pass "TC-12 $fname uses single-quoted Style B example"
  else
    fail "TC-12 $fname does NOT use single-quoted Style B example (backtick regression?)"
  fi
  if grep -qF 'expand `if ! cmd; then`' "$f"; then
    fail "TC-12 $fname STILL contains backtick-quoted Style B example (CRITICAL regression!)"
  else
    pass "TC-12 $fname free of backtick-quoted 'if ! cmd; then' literal"
  fi
done

# ----- TC-6: AC-1/AC-2 — consumer repo (no plugins/rite) skips the gate ------
# A repo that uses rite as a marketplace plugin only (no plugins/rite/ in the
# working tree) must NOT hard-error the gate. With --skip-if-no-target — which
# the Phase 1.0 blocks now pass — --all exits 0 (not-applicable clean skip) and
# emits an informational note; without the flag the exit-2 diagnostic is still
# preserved (MUST NOT drop it unconditionally). (Issue #1550)
echo "TC-6: AC-1/AC-2 — consumer repo (no plugins/rite) gate skip"
consumer_root=$(mktemp -d)
skip_rc=0
skip_output=$(bash "$CHECK_SCRIPT" --repo-root "$consumer_root" --all --skip-if-no-target 2>&1) || skip_rc=$?
if [ "$skip_rc" -eq 0 ]; then
  pass "TC-6 --all --skip-if-no-target exits 0 on consumer repo"
else
  fail "TC-6 expected exit 0 with --skip-if-no-target, got $skip_rc"
  printf '%s\n' "$skip_output" | head -5 >&2
fi
if printf '%s\n' "$skip_output" | grep -q 'not applicable'; then
  pass "TC-6 skip emits 'not applicable' informational note"
else
  fail "TC-6 skip note missing"
fi
diag_rc=0
bash "$CHECK_SCRIPT" --repo-root "$consumer_root" --all --quiet >/dev/null 2>&1 || diag_rc=$?
if [ "$diag_rc" -eq 2 ]; then
  pass "TC-6 without flag, consumer repo still exits 2 (diagnostic preserved)"
else
  fail "TC-6 expected exit 2 without flag, got $diag_rc"
fi
rm -rf "$consumer_root"

# ----- TC-13: Issue #2147 — ready gate is bound to the PR head -------------
echo "TC-13: ready gate resolves and scans the PR head"
for needle in \
  'gh pr view {pr_number} -R {owner_repo} --json headRefOid' \
  'git worktree add --detach "$ready_gate_tmp" "$pr_head_oid"' \
  'READY_GATE_PR_HEAD_RESOLVED=1; head_oid=$pr_head_oid' \
  '--repo-root "$scan_root"' \
  "trap 'cleanup_ready_gate_worktree; trap - INT; kill -INT \$\$' INT"
do
  if grep -qF -- "$needle" "$READY_MD"; then
    pass "TC-13 contract present: $needle"
  else
    fail "TC-13 contract missing: $needle"
  fi
done

# ----- TC-14: Issue #2147 — no fallback and PR-head work-memory values ------
echo "TC-14: resolution failures stop and work memory records PR head"
for needle in \
  'PR #{pr_number} の headRefOid を解決できません' \
  'PR head $pr_head_oid の fetch に失敗しました' \
  'PR head $pr_head_oid の一時 worktree 作成に失敗しました' \
  '--json headRefName,headRefOid' \
  'branch: \"" branch "\"' \
  'last_commit: \"" oid "\"'
do
  if grep -qF -- "$needle" "$READY_MD"; then
    pass "TC-14 contract present: $needle"
  else
    fail "TC-14 contract missing: $needle"
  fi
done

# ----- Summary --------------------------------------------------------------
echo ""
echo "==> $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
