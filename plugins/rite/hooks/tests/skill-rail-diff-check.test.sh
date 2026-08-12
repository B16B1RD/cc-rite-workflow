#!/bin/bash
# Tests for skill-rail-diff-check.sh
# Usage: bash plugins/rite/hooks/tests/skill-rail-diff-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../scripts/skill-rail-diff-check.sh"
PLUGIN_ROOT="$SCRIPT_DIR/../.."
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

echo "=== skill-rail-diff-check.sh tests ==="
echo ""

REL="plugins/rite/skills/fixture/SKILL.md"
F="$TEST_DIR/$REL"
mkdir -p "$(dirname "$F")"

# Fixture skill: one fenced block, one table, prose around both. Written once
# and committed; each test case then edits the working-tree copy.
write_base() {
  cat > "$F" <<'EOF'
# /rite:fixture

Long narration that a description diet is expected to compress away.

```bash
echo "[CONTEXT] FIXTURE=1"
```

| Sentinel | Action |
|---------|--------|
| `[fixture:done]` | proceed |

More prose explaining why the above exists, at length.
EOF
}

write_base
(
  cd "$TEST_DIR"
  git init -q
  git config user.email t@example.com
  git config user.name t
  git add -A
  git commit -qm base
)

run() { bash "$TARGET" --repo-root "$TEST_DIR" --skill "$REL" --base-ref HEAD 2>&1; }

# --------------------------------------------------------------------------
# TC-001: No arguments → exit 2 (usage error)
# --------------------------------------------------------------------------
echo "TC-001: No --skill → exit 2"
rc=0; output=$(bash "$TARGET" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "no args → exit 2"; else fail "expected rc=2, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-002: Unreadable --skill → exit 2
# --------------------------------------------------------------------------
echo "TC-002: Missing skill file → exit 2"
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "plugins/rite/skills/nope/SKILL.md" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "missing skill → exit 2"; else fail "expected rc=2, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-003: Unchanged file → exit 0
# --------------------------------------------------------------------------
echo "TC-003: Unchanged file → exit 0"
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 0 ]; then pass "unchanged → exit 0"; else fail "expected rc=0, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-004: Prose-only deletion → exit 0 (this is what a diet is allowed to do)
# --------------------------------------------------------------------------
echo "TC-004: Prose-only edit → exit 0"
write_base
grep -v '^More prose explaining' "$F" > "$F.tmp" && mv "$F.tmp" "$F"
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 0 ]; then pass "prose deletion → exit 0"; else fail "expected rc=0, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-005: Fenced-block edit → exit 1 (drift)
# --------------------------------------------------------------------------
echo "TC-005: Bash block edit → exit 1"
write_base
sed -i 's/FIXTURE=1/FIXTURE=2/' "$F"
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 1 ]; then pass "bash block edit → exit 1"; else fail "expected rc=1, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-006: Table row edit → exit 1 (sentinel/branch-table vocabulary is frozen)
# --------------------------------------------------------------------------
echo "TC-006: Table row edit → exit 1"
write_base
sed -i 's/\[fixture:done\]/[fixture:finished]/' "$F"
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 1 ]; then pass "table row edit → exit 1"; else fail "expected rc=1, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-007: Comment inside a fenced block is part of the rail → exit 1
# --------------------------------------------------------------------------
echo "TC-007: In-fence comment edit → exit 1"
write_base
sed -i 's|echo "\[CONTEXT\] FIXTURE=1"|# added comment\necho "[CONTEXT] FIXTURE=1"|' "$F"
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 1 ]; then pass "in-fence comment edit → exit 1"; else fail "expected rc=1, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-008: File absent at base ref → exit 0 (clean skip, new skill)
# --------------------------------------------------------------------------
echo "TC-008: Absent at base ref → exit 0"
write_base
NEW_REL="plugins/rite/skills/brandnew/SKILL.md"
mkdir -p "$TEST_DIR/$(dirname "$NEW_REL")"
cp "$F" "$TEST_DIR/$NEW_REL"
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$NEW_REL" --base-ref HEAD 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "not applicable"; then
  pass "absent at base → exit 0 with clean-skip notice"
else fail "expected rc=0 + 'not applicable', got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-009: --extract-only emits fences + table rows and nothing else
# --------------------------------------------------------------------------
echo "TC-009: --extract-only content"
write_base
output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$REL" --extract-only 2>&1)
if echo "$output" | grep -q 'FIXTURE=1' \
  && echo "$output" | grep -q 'fixture:done' \
  && ! echo "$output" | grep -q 'Long narration'; then
  pass "--extract-only keeps rail, drops prose"
else fail "unexpected --extract-only output: $output"; fi

# --------------------------------------------------------------------------
# TC-010: The diet target itself — open/SKILL.md keeps its rail across this PR.
# This is the standing pin: any future PR that rewrites open's prose must leave
# every bash block, sentinel literal, and branch-table row byte-identical.
# Skipped cleanly when the base ref is unavailable (shallow / detached checkout).
# --------------------------------------------------------------------------
echo "TC-010: open/SKILL.md rail unchanged vs origin/develop"
if git -C "$PLUGIN_ROOT" rev-parse --verify -q origin/develop >/dev/null 2>&1; then
  rc=0; output=$(bash "$TARGET" --skill "plugins/rite/skills/open/SKILL.md" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then pass "open/SKILL.md rail identical to origin/develop"
  else fail "open/SKILL.md rail drifted: $output"; fi
else
  echo "  ⏭️  SKIP: origin/develop not available"
fi

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
