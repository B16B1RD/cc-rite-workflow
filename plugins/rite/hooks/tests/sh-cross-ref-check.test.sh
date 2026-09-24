#!/bin/bash
# Tests for sh-cross-ref-check.sh
# Usage: bash plugins/rite/hooks/tests/sh-cross-ref-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../scripts/sh-cross-ref-check.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

echo "=== sh-cross-ref-check.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# Synthetic repo: a Phase-style file (skills/issue-close/SKILL.md) and a ステップ-style file
# (skills/pr-review/SKILL.md), each carrying a bare-number sub-step heading (no keyword), which
# mirrors the real heading convention discovered in production.
# --------------------------------------------------------------------------
mkdir -p "$TEST_DIR/plugins/rite/skills/issue-close"
mkdir -p "$TEST_DIR/plugins/rite/skills/pr-review"
mkdir -p "$TEST_DIR/plugins/rite/skills/issue-create"
mkdir -p "$TEST_DIR/plugins/rite/skills/pr-create"
mkdir -p "$TEST_DIR/plugins/rite/hooks/scripts"
mkdir -p "$TEST_DIR/plugins/rite/hooks/tests"
(cd "$TEST_DIR" && git init -q 2>/dev/null || true)

cat > "$TEST_DIR/plugins/rite/skills/issue-close/SKILL.md" <<'MD'
# /rite:issue-close
## Phase 4: Completion Report
### 4.4.W Wiki Ingest Trigger (Conditional)
### 4.4.W.2 Wiki Raw Commit
MD

cat > "$TEST_DIR/plugins/rite/skills/pr-review/SKILL.md" <<'MD'
# /rite:pr-review
## ステップ 6: 完了
### 6.5 Completion Report
#### 6.5.W.2 Wiki Raw Commit (Shell — deterministic path)
MD

# skills/issue-create/SKILL.md split: issue/ is ステップ-style, pr/ is Phase-style (bare-name union)
cat > "$TEST_DIR/plugins/rite/skills/issue-create/SKILL.md" <<'MD'
# /rite:issue-create
## ステップ 2: 起票
### 2.1 Body 生成
MD
cat > "$TEST_DIR/plugins/rite/skills/pr-create/SKILL.md" <<'MD'
# /rite:pr-create
## Phase 3: PR 本文生成
MD

run() { bash "$TARGET" --repo-root "$TEST_DIR" --target "$1" 2>&1; }

# --------------------------------------------------------------------------
# TC-001: No arguments → exit 2 (usage error)
# --------------------------------------------------------------------------
echo "TC-001: No arguments → exit 2"
rc=0; output=$(bash "$TARGET" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "no args → exit 2"; else fail "expected rc=2, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-002: non-existent --repo-root → exit 2
# --------------------------------------------------------------------------
echo "TC-002: non-existent repo-root → exit 2"
rc=0; output=$(bash "$TARGET" --all --repo-root "$TEST_DIR/nope" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && grep -q "repo-root not a directory" <<< "$output"; then
  pass "bad repo-root → exit 2"
else fail "expected rc=2 + message, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-003: cycle-4 fixture — skills/issue-close/SKILL.md (Phase-style) referenced with ステップ
#         keyword. Number exists, keyword wrong → keyword mismatch. (AC-3)
# --------------------------------------------------------------------------
echo "TC-003: cycle-4 fixture (skills/issue-close/SKILL.md ステップ 4.4.W.2) → keyword mismatch"
f="$TEST_DIR/plugins/rite/hooks/scripts/fixture.sh"
echo 'echo "Verify skills/issue-close/SKILL.md ステップ 4.4.W.2 execution."' > "$f"
rc=0; output=$(run "plugins/rite/hooks/scripts/fixture.sh") || rc=$?
if [ "$rc" -eq 1 ] && grep -q "keyword mismatch" <<< "$output" \
   && grep -q "skills/issue-close/SKILL.md ステップ 4.4.W.2" <<< "$output"; then
  pass "cycle-4 overshoot detected as keyword mismatch"
else fail "expected rc=1 + keyword mismatch, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-004: correct references (both conventions) → exit 0, no findings
# --------------------------------------------------------------------------
echo "TC-004: correct refs (ステップ + Phase) → exit 0"
echo 'echo "Verify skills/pr-review/SKILL.md ステップ 6.5.W.2 / skills/issue-close/SKILL.md Phase 4.4.W.2."' > "$f"
rc=0; output=$(run "plugins/rite/hooks/scripts/fixture.sh") || rc=$?
if [ "$rc" -eq 0 ] && grep -q "Total sh-cross-ref findings: 0" <<< "$output"; then
  pass "correct refs not flagged → exit 0"
else fail "expected rc=0 + 0 findings, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-005: dangling number (number not present as heading) → exit 1
# --------------------------------------------------------------------------
echo "TC-005: dangling number (skills/issue-close/SKILL.md Phase 9.9.9) → exit 1"
echo 'echo "See skills/issue-close/SKILL.md Phase 9.9.9 for nothing."' > "$f"
rc=0; output=$(run "plugins/rite/hooks/scripts/fixture.sh") || rc=$?
if [ "$rc" -eq 1 ] && grep -q "dangling number" <<< "$output"; then
  pass "dangling number detected → exit 1"
else fail "expected rc=1 + dangling number, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-006: whitelist marker exempts the line → exit 0
# --------------------------------------------------------------------------
echo "TC-006: drift-check-ignore marker exempts → exit 0"
echo 'echo "Legacy skills/issue-close/SKILL.md ステップ 4.4.W.2 note."  # drift-check-ignore' > "$f"
rc=0; output=$(run "plugins/rite/hooks/scripts/fixture.sh") || rc=$?
if [ "$rc" -eq 0 ]; then pass "whitelisted line skipped → exit 0"
else fail "expected rc=0 (whitelisted), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-007: references in COMMENTS are scanned too (not only echo strings)
# --------------------------------------------------------------------------
echo "TC-007: comment-line reference is scanned"
echo '# skills/issue-close/SKILL.md ステップ 4.4.W.2 runs the commit' > "$f"
rc=0; output=$(run "plugins/rite/hooks/scripts/fixture.sh") || rc=$?
if [ "$rc" -eq 1 ] && grep -q "keyword mismatch" <<< "$output"; then
  pass "comment reference scanned → keyword mismatch"
else fail "expected rc=1 from comment ref, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-008: inverse mismatch — ステップ-style file referenced with Phase keyword
# --------------------------------------------------------------------------
echo "TC-008: inverse mismatch (skills/pr-review/SKILL.md Phase 6.5.W.2)"
echo 'echo "Verify skills/pr-review/SKILL.md Phase 6.5.W.2 path."' > "$f"
rc=0; output=$(run "plugins/rite/hooks/scripts/fixture.sh") || rc=$?
if [ "$rc" -eq 1 ] && grep -q "keyword mismatch" <<< "$output"; then
  pass "Phase-on-ステップ-file detected"
else fail "expected rc=1 keyword mismatch, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-009: unresolvable file reference → skipped (out of scope) → exit 0
# --------------------------------------------------------------------------
echo "TC-009: unresolvable file ref → exit 0"
echo 'echo "Verify nonexistent-file.md Phase 1.2 path."' > "$f"
rc=0; output=$(run "plugins/rite/hooks/scripts/fixture.sh") || rc=$?
if [ "$rc" -eq 0 ]; then pass "unresolvable ref skipped → exit 0"
else fail "expected rc=0, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-010: bare-name union — skills/issue-create/SKILL.md exists in issue/ (ステップ) and pr/ (Phase).
#         `skills/issue-create/SKILL.md ステップ 2.1` matches issue/skills/issue-create/SKILL.md → no finding.
# --------------------------------------------------------------------------
echo "TC-010: bare-name union (skills/issue-create/SKILL.md ステップ 2.1) → exit 0"
echo 'echo "Run skills/issue-create/SKILL.md ステップ 2.1 then continue."' > "$f"
rc=0; output=$(run "plugins/rite/hooks/scripts/fixture.sh") || rc=$?
if [ "$rc" -eq 0 ]; then pass "union charitable match → exit 0"
else fail "expected rc=0 (union match), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-011: --all skips hooks/tests/ (fixtures legitimately hold bad refs).
#         A clean script under hooks/scripts/ keeps --all non-empty so the
#         exclusion (not the empty-target guard) is what's exercised.
# --------------------------------------------------------------------------
echo "TC-011: --all excludes hooks/tests/"
echo 'echo "skills/issue-close/SKILL.md ステップ 4.4.W.2"' > "$TEST_DIR/plugins/rite/hooks/tests/bad-fixture.sh"
echo 'echo "clean: skills/pr-review/SKILL.md ステップ 6.5.W.2"' > "$f"
rc=0; output=$(bash "$TARGET" --all --repo-root "$TEST_DIR" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "bad-fixture.sh" <<< "$output"; then
  pass "tests/ fixtures excluded from --all → exit 0"
else fail "expected rc=0 with no tests/ finding, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Test Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "TOTAL: $((PASS + FAIL))"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
