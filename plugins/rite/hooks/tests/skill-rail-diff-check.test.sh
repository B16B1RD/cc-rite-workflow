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
SKIP=0

cleanup() { rm -rf "$TEST_DIR"; }
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  ⏭️  SKIP: $1"; }

# GNU `sed -i` takes the expression where BSD sed expects a backup suffix, so
# the repo edits fixtures with awk read -> transform -> write -> mv instead.
awk_edit() {
  local file="$1" prog="$2"
  awk "$prog" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

echo "=== skill-rail-diff-check.sh tests ==="
echo ""

REL="plugins/rite/skills/fixture/SKILL.md"
F="$TEST_DIR/$REL"
mkdir -p "$(dirname "$F")"

# Fixture skill: a column-0 fenced block and table, an indented fenced block and
# table (the shape rite skills actually use under numbered list items), and
# prose around all of them.
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

1. A numbered step whose rail is indented:

   ```bash
   echo "[CONTEXT] INDENTED=1"
   ```

   | Marker | Branch |
   |---|---|
   | `indented-row` | continue |

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
# TC-001: No --skill → exit 2 (usage error)
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
write_base
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 0 ]; then pass "unchanged → exit 0"; else fail "expected rc=0, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-004: Prose-only deletion → exit 0 (this is what a diet is allowed to do)
# --------------------------------------------------------------------------
echo "TC-004: Prose-only edit → exit 0"
write_base
awk_edit "$F" '!/^More prose explaining/'
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 0 ]; then pass "prose deletion → exit 0"; else fail "expected rc=0, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-005: Fenced-block edit → exit 1 (drift)
# --------------------------------------------------------------------------
echo "TC-005: Bash block edit → exit 1"
write_base
awk_edit "$F" '{ gsub(/FIXTURE=1/, "FIXTURE=2"); print }'
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 1 ]; then pass "bash block edit → exit 1"; else fail "expected rc=1, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-006: Table row edit → exit 1 (sentinel/branch-table vocabulary is frozen)
# --------------------------------------------------------------------------
echo "TC-006: Table row edit → exit 1"
write_base
awk_edit "$F" '{ gsub(/fixture:done/, "fixture:finished"); print }'
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 1 ]; then pass "table row edit → exit 1"; else fail "expected rc=1, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-007: Comment inside a fenced block is part of the rail → exit 1
# --------------------------------------------------------------------------
echo "TC-007: In-fence comment edit → exit 1"
write_base
awk_edit "$F" '{ if ($0 ~ /echo "\[CONTEXT\] FIXTURE=1"/) print "# added comment"; print }'
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 1 ]; then pass "in-fence comment edit → exit 1"; else fail "expected rc=1, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-008: Indented fence and indented table row are part of the rail.
# rite skills put bash blocks and branch tables under numbered list items, so
# anchoring the extractor at column 0 would silently drop most of the rail in
# iterate / fix / pr-review.
# --------------------------------------------------------------------------
echo "TC-008: Indented fence edit → exit 1"
write_base
awk_edit "$F" '{ gsub(/INDENTED=1/, "INDENTED=2"); print }'
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 1 ]; then pass "indented bash block edit → exit 1"; else fail "expected rc=1, got rc=$rc: $output"; fi

echo "TC-008b: Indented table row edit → exit 1"
write_base
awk_edit "$F" '{ gsub(/indented-row/, "renamed-row"); print }'
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 1 ]; then pass "indented table row edit → exit 1"; else fail "expected rc=1, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-009: File absent at base ref → exit 0 (clean skip, new skill)
# --------------------------------------------------------------------------
echo "TC-009: Absent at base ref → exit 0"
write_base
NEW_REL="plugins/rite/skills/brandnew/SKILL.md"
mkdir -p "$TEST_DIR/$(dirname "$NEW_REL")"
cp "$F" "$TEST_DIR/$NEW_REL"
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$NEW_REL" --base-ref HEAD 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "not applicable"; then
  pass "absent at base → exit 0 with clean-skip notice"
else fail "expected rc=0 + 'not applicable', got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-010: --extract-only emits fence lines, in-fence content and table rows —
# and nothing else. The fence lines matter: dropping them would merge two
# adjacent blocks and hide a language-tag change, and TC-003..TC-008 cannot
# catch that because they apply the same extractor to both sides.
# --------------------------------------------------------------------------
echo "TC-010: --extract-only content"
write_base
output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$REL" --extract-only 2>/dev/null)
if echo "$output" | grep -q 'FIXTURE=1' \
  && echo "$output" | grep -q 'INDENTED=1' \
  && echo "$output" | grep -q 'fixture:done' \
  && echo "$output" | grep -q 'indented-row' \
  && [ "$(echo "$output" | grep -c '```')" -eq 4 ] \
  && ! echo "$output" | grep -q 'Long narration'; then
  pass "--extract-only keeps rail incl. fence lines, drops prose"
else fail "unexpected --extract-only output: $output"; fi

echo "TC-010b: fence language tag is part of the rail"
write_base
awk_edit "$F" '{ if ($0 == "```bash") print "```sh"; else print }'
rc=0; output=$(run) || rc=$?
if [ "$rc" -eq 1 ]; then pass "fence language tag change → exit 1"; else fail "expected rc=1, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-011: Empty --base-ref → exit 2. An empty ref makes `git show ":path"` read
# the index, which succeeds and compares the working tree against the caller's
# own staged copy — a proof that always passes.
# --------------------------------------------------------------------------
echo "TC-011: Empty --base-ref → exit 2"
write_base
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$REL" --base-ref "" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "empty --base-ref → exit 2"; else fail "expected rc=2, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-012: Unresolvable --base-ref → exit 2, not a clean skip. A typo'd ref must
# not be reported as a successful comparison.
# --------------------------------------------------------------------------
echo "TC-012: Unresolvable --base-ref → exit 2"
write_base
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$REL" --base-ref "no-such-ref" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && echo "$output" | grep -q "does not resolve"; then
  pass "unresolvable --base-ref → exit 2"
else fail "expected rc=2 + 'does not resolve', got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-013: A file with no rail → exit 2. Both sides extract to empty and compare
# equal, so without a floor check an empty proof reports the same success as a
# real one.
# --------------------------------------------------------------------------
echo "TC-013: Empty rail → exit 2"
NORAIL_REL="plugins/rite/skills/norail/SKILL.md"
mkdir -p "$TEST_DIR/$(dirname "$NORAIL_REL")"
printf '# prose only\n\nNo fences, no tables.\n' > "$TEST_DIR/$NORAIL_REL"
(cd "$TEST_DIR" && git add -A && git commit -qm norail)
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$NORAIL_REL" --base-ref HEAD 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && echo "$output" | grep -q "empty machine rail"; then
  pass "empty rail → exit 2"
else fail "expected rc=2 + 'empty machine rail', got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-014: A trailing valueless flag must reach the exit-2 contract instead of
# spinning. `shift 2` with one argument left fails and, without `set -e`, the
# loop never terminates.
# --------------------------------------------------------------------------
echo "TC-014: Trailing valueless flag → exit 2, no hang"
rc=0; output=$(timeout 5 bash "$TARGET" --repo-root "$TEST_DIR" --skill 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "trailing valueless flag → exit 2"
elif [ "$rc" -eq 124 ]; then fail "timed out — argument loop spins on a valueless flag"
else fail "expected rc=2, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-015: The diet target itself — open/SKILL.md keeps its rail against the base
# branch. This is the standing pin: any future PR that rewrites open's prose
# must leave every bash block and table row byte-identical.
#
# The assertion is two-stage on purpose. exit 0 alone also covers "not
# applicable", so an exit-code-only check would report "rail identical" for a
# comparison that never ran. rc=2 is reported as an invocation error rather than
# drift so the message does not send the reader hunting for a rail change that
# is not there.
# --------------------------------------------------------------------------
echo "TC-015: open/SKILL.md rail unchanged vs origin/develop"
REPO_ROOT_REAL=$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "$REPO_ROOT_REAL" ] && git -C "$PLUGIN_ROOT" rev-parse --verify -q origin/develop >/dev/null 2>&1; then
  rc=0
  output=$(bash "$TARGET" --repo-root "$REPO_ROOT_REAL" --skill "plugins/rite/skills/open/SKILL.md" 2>&1) || rc=$?
  case "$rc" in
    0)
      if echo "$output" | grep -q "machine rail identical"; then
        pass "open/SKILL.md rail identical to origin/develop"
      else
        fail "rc=0 but no 'machine rail identical' — comparison did not run: $output"
      fi
      ;;
    1) fail "open/SKILL.md rail drifted: $output" ;;
    *) fail "invocation error (rc=$rc), not drift: $output" ;;
  esac
else
  skip "origin/develop or repo root not available"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Test Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "SKIP: $SKIP"
echo "TOTAL: $((PASS + FAIL + SKIP))"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
