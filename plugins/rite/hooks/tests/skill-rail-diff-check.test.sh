#!/bin/bash
# Tests for skill-rail-diff-check.sh
# Usage: bash plugins/rite/hooks/tests/skill-rail-diff-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../scripts/skill-rail-diff-check.sh"
PLUGIN_ROOT="$SCRIPT_DIR/../.."
TEST_DIR="$(mktemp -d)"
# Sibling of TEST_DIR, never `git init`-ed. It cannot live inside TEST_DIR:
# `git -C` walks up to the enclosing repo, so a subdirectory would resolve to
# TEST_DIR's own .git and the non-git case would never be exercised.
NONGIT_DIR="$(mktemp -d)"
PASS=0
FAIL=0
SKIP=0

cleanup() { rm -rf "$TEST_DIR" "$NONGIT_DIR"; }
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
# rite skills put bash blocks and branch tables under numbered list items;
# anchoring the extractor at column 0 misses about a tenth of the rail in fix
# and pr-review (iterate is unaffected), which is the shape this TC pins.
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
# TC-011: Empty --base-ref → exit 2, with the message that names the empty
# value. The ref check would stop it too, but under a message that reads as a
# typo — see the assertion below.
# --------------------------------------------------------------------------
echo "TC-011: Empty --base-ref → exit 2"
write_base
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$REL" --base-ref "" 2>&1) || rc=$?
# Message-matched, not exit-code-only: deleting the empty-value guard still
# yields rc=2 from the ref-resolution check below it, so rc alone cannot tell
# the two apart and the guard would be free to disappear.
if [ "$rc" -eq 2 ] && echo "$output" | grep -q "must not be empty"; then
  pass "empty --base-ref → exit 2 with the empty-value message"
else fail "expected rc=2 + 'must not be empty', got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-012: Unresolvable --base-ref → exit 2, not a clean skip. A typo'd ref must
# not be reported as a successful comparison.
# --------------------------------------------------------------------------
echo "TC-012: Unresolvable --base-ref → exit 2"
write_base
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$REL" --base-ref "no-such-ref" 2>&1) || rc=$?
# Two-part: the script's own line, plus git's. `-q` on the rev-parse would keep
# the former and silence the latter, leaving "See git's message above" pointing
# at nothing — for a typo'd ref, git's line is the only one naming the cause.
if [ "$rc" -eq 2 ] \
  && echo "$output" | grep -q "could not resolve --base-ref" \
  && echo "$output" | grep -q "Needed a single revision"; then
  pass "unresolvable --base-ref → exit 2 with git's own diagnosis"
else fail "expected rc=2 + both messages, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-012b: The same passthrough for a non-git --repo-root, where git's line is
# what separates "unfetched ref" from "this is not a repository" — the latter
# is not fixed by any amount of fetching.
# --------------------------------------------------------------------------
echo "TC-012b: Non-git --repo-root surfaces git's own message"
write_base
mkdir -p "$NONGIT_DIR/$(dirname "$REL")"
cp "$F" "$NONGIT_DIR/$REL"
rc=0; output=$(bash "$TARGET" --repo-root "$NONGIT_DIR" --skill "$REL" --base-ref HEAD 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && echo "$output" | grep -q "not a git repository"; then
  pass "non-git --repo-root → exit 2 with git's own diagnosis"
else fail "expected rc=2 + 'not a git repository', got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-013: A file with no rail → exit 2. Both sides extract to empty and compare
# equal, so without a floor check an empty proof reports the same success as a
# real one.
# --------------------------------------------------------------------------
echo "TC-013: Empty rail → exit 2"
NORAIL_REL="plugins/rite/skills/norail/SKILL.md"
mkdir -p "$TEST_DIR/$(dirname "$NORAIL_REL")"
printf '# prose only\n\nNo fences, no tables.\n' > "$TEST_DIR/$NORAIL_REL"
# Stage only this fixture. `git add -A` would also commit the untracked file
# TC-009 relies on being absent from the base ref, silently dissolving its
# premise for any test added after this point.
(cd "$TEST_DIR" && git add "$NORAIL_REL" && git commit -qm norail)
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$NORAIL_REL" --base-ref HEAD 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && echo "$output" | grep -q "empty machine rail"; then
  pass "empty rail → exit 2"
else fail "expected rc=2 + 'empty machine rail', got rc=$rc: $output"; fi

echo "TC-013b: Empty rail → exit 2 on --extract-only too"
# The floor sits ahead of the --extract-only branch on purpose: a measurement
# that silently reports zero lines is the same vacuous proof. Moving the floor
# back behind the branch passes every other TC, so this one pins the order.
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$NORAIL_REL" --extract-only 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && echo "$output" | grep -q "empty machine rail"; then
  pass "empty rail on --extract-only → exit 2"
else fail "expected rc=2 + 'empty machine rail', got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-014: A one-line rail must be counted as one line, not zero. TC-013 cannot
# pin the count at all — its input hits the empty-rail floor and exits before
# the count is ever evaluated — so this is the only case that holds the count
# expression in place. It kills a revert to the pre-restructure form
# (`printf '%s'` feeding a counter that ignores an unterminated final line).
# --------------------------------------------------------------------------
echo "TC-014: One-line rail counts as 1, not 0"
ONE_REL="plugins/rite/skills/oneline/SKILL.md"
mkdir -p "$TEST_DIR/$(dirname "$ONE_REL")"
printf '# t\n\nprose\n\n| a | b |\n\nmore prose\n' > "$TEST_DIR/$ONE_REL"
(cd "$TEST_DIR" && git add "$ONE_REL" && git commit -qm oneline)
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --skill "$ONE_REL" --base-ref HEAD 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "(1 rail lines)"; then
  pass "one-line rail → exit 0 with count 1"
else fail "expected rc=0 + '(1 rail lines)', got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-015: open/SKILL.md keeps every *existing* rail against the base branch.
# A description diet must not alter or delete fenced blocks / table rows.
# Additive rails (new step, new table) are allowed — subsequence preservation,
# not byte-identity — so a feature that inserts 3.3.1 does not have to freeze
# the diet pin. Mutation or deletion of a base rail line still fails.
#
# Identity remains the fast path: when rails are byte-identical the checker
# already reports "machine rail identical" and we accept that.
# --------------------------------------------------------------------------
echo "TC-015: open/SKILL.md existing rails preserved vs origin/develop"
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
    1)
      extract_rail() {
        awk '/^[[:space:]]*(```|~~~)/ { inb = !inb; print; next } inb { print; next } /^[[:space:]]*\|/ { print }'
      }
      head_rail=$(bash "$TARGET" --repo-root "$REPO_ROOT_REAL" --skill "plugins/rite/skills/open/SKILL.md" --extract-only 2>/dev/null) || head_rail=""
      base_blob=$(git -C "$REPO_ROOT_REAL" show origin/develop:plugins/rite/skills/open/SKILL.md 2>/dev/null) || base_blob=""
      base_rail=$(printf '%s\n' "$base_blob" | extract_rail)
      # The worktree plugin-root copy rail was relocated (one bash line
      # replaced by new-path-first dual-read). Drop that superseded line from
      # the subsequence pin so the rest of the rail still has to survive.
      base_rail=$(printf '%s\n' "$base_rail" | grep -Fv '.rite-plugin-root' || true)
      # number-citation comments removed from the number-free surface; drop the
      # superseded GUARD line from the subsequence pin (same pattern as above).
      base_rail=$(printf '%s\n' "$base_rail" | grep -Fv 'GUARD (#1595)' || true) # drift-check-ignore
      printf '%s\n' "$base_rail" > "$TEST_DIR/base-rail"
      printf '%s\n' "$head_rail" > "$TEST_DIR/head-rail"
      if [ -z "$base_rail" ] || [ -z "$head_rail" ]; then
        fail "open/SKILL.md rail drifted and subsequence check could not extract rails: $output"
      elif awk '
          NR==FNR { base[++n]=$0; next }
          { head[++m]=$0 }
          END {
            i=1
            for (j=1; j<=m && i<=n; j++) if (head[j]==base[i]) i++
            exit (i>n ? 0 : 1)
          }' "$TEST_DIR/base-rail" "$TEST_DIR/head-rail"; then
        pass "open/SKILL.md existing rails preserved (additive rails OK)"
      else
        fail "open/SKILL.md existing rail mutated or deleted: $output"
      fi
      ;;
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
