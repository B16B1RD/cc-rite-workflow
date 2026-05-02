#!/bin/bash
# bang-backtick-pr-create-pre-check.test.sh
#
# Regression tests for the Phase 1.0 Pre-PR Gate added to
# `commands/pr/create.md` and `commands/pr/ready.md` by Issue #691.
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
#   3. The non-regression of `/rite:lint` Phase 3.6 — lint.md must
#      still invoke `bang-backtick-check.sh --all` AND treat its exit
#      code as a warning rather than an error (AC-4).
#
# Issue #691 — 経路 D (pre-PR hard gate).
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
CREATE_MD="$PLUGIN_ROOT/commands/pr/create.md"
READY_MD="$PLUGIN_ROOT/commands/pr/ready.md"
LINT_MD="$PLUGIN_ROOT/commands/lint.md"
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
echo "TC-2: AC-2 — seeded dirt in plugins/rite/commands/ produces exit 1"
seed_dir=$(mktemp -d)
trap 'rm -rf "$seed_dir"' EXIT
# Recreate a minimal rite plugin layout so the scanner's --all has a tree to walk.
mkdir -p "$seed_dir/plugins/rite/commands/pr"
mkdir -p "$seed_dir/plugins/rite/skills"
mkdir -p "$seed_dir/plugins/rite/agents"
mkdir -p "$seed_dir/plugins/rite/references"
# Inject a P1 pattern: backtick + space + bang + closing backtick adjacency.
printf '%s\n' "Bad: \` !\` adjacency must trigger." > "$seed_dir/plugins/rite/commands/pr/dirty.md"
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

# ----- TC-4: §7 MUST — create.md/ready.md DRIFT-CHECK ANCHOR ---------------
# The Phase 1.0 bash block invocation literal MUST be byte-for-byte identical
# between create.md and ready.md (Wiki 経験則「Asymmetric Fix Transcription」).
# We pin three sentinels: the scanner invocation, the sentinel emit literal,
# and the sub-section header.
echo "TC-4: §7 MUST — DRIFT-CHECK ANCHOR between create.md and ready.md"
inv_create=$(grep -c 'bash "$plugin_root/hooks/scripts/bang-backtick-check.sh" --all 2>&1' "$CREATE_MD" || true)
inv_ready=$(grep -c 'bash "$plugin_root/hooks/scripts/bang-backtick-check.sh" --all 2>&1' "$READY_MD" || true)
if [ "$inv_create" -ge 1 ] && [ "$inv_ready" -ge 1 ]; then
  pass "TC-4 scanner invocation literal present in BOTH create.md and ready.md"
else
  fail "TC-4 scanner invocation literal mismatch (create=$inv_create, ready=$inv_ready)"
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

# ----- TC-5: AC-4 — /rite:lint Phase 3.6 still invokes the same scanner ----
echo "TC-5: AC-4 — /rite:lint Phase 3.6 unchanged (non-regression)"
lint_inv=$(grep -c 'bang-backtick-check.sh --all' "$LINT_MD" || true)
if [ "$lint_inv" -ge 1 ]; then
  pass "TC-5 lint.md still invokes 'bang-backtick-check.sh --all'"
else
  fail "TC-5 lint.md missing scanner invocation (regression)"
fi
# Lint must keep treating findings as warnings (Phase 3.6 contract: exit 1
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

# ----- Summary --------------------------------------------------------------
echo ""
echo "==> $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
