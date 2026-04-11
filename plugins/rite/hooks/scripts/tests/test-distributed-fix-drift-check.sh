#!/usr/bin/env bash
# Smoke + validation tests for distributed-fix-drift-check.sh
#
# Validates against PR #350 baseline commit cec0140 (which contains the
# 5 known drift categories that motivated Issue #361) and ensures the
# checker reports drift findings on that commit.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/rite/hooks/scripts/distributed-fix-drift-check.sh"
BASELINE_COMMIT="cec0140"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 1
fi

PASS=0
FAIL=0

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected=$expected actual=$actual" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_ge() {
  local desc="$1" min="$2" actual="$3"
  if [ "$actual" -ge "$min" ]; then
    echo "PASS: $desc ($actual >= $min)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected>=$min actual=$actual" >&2
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 1: usage / help works ----------------------------------------------
"$SCRIPT" --help >/dev/null 2>&1
rc=$?
assert "--help exits 0" "0" "$rc"

# --- Test 2: missing args returns error code 2 -------------------------------
"$SCRIPT" >/dev/null 2>&1
rc=$?
assert "no args exits 2" "2" "$rc"

# Accumulating tempfile manager (trap is set once, list grows as tests add files)
TMPFILES=()
trap 'rm -rf "${TMPFILES[@]}"' EXIT

# --- Test 3: cec0140 fix.md baseline detects drift ---------------------------
TMP_FIX=$(mktemp)
TMPFILES+=("$TMP_FIX")

# Verify baseline commit is reachable before running Test 3. On shallow clones
# (typical CI setup), silently SKIP-ing would produce a false green. Fail the
# suite instead so the problem is visible.
if ! git cat-file -e "${BASELINE_COMMIT}^{commit}" 2>/dev/null; then
  echo "FAIL: baseline commit ${BASELINE_COMMIT} is not reachable" >&2
  echo "  Hint: run 'git fetch --depth=1 origin ${BASELINE_COMMIT}' or unshallow the repo" >&2
  FAIL=$((FAIL + 1))
elif git show "${BASELINE_COMMIT}:plugins/rite/commands/pr/fix.md" > "$TMP_FIX" 2>/dev/null; then
  out=$("$SCRIPT" --target "$TMP_FIX" 2>&1)
  rc=$?
  count=$(grep -c '^\[drift\]' <<< "$out")
  assert_ge "cec0140 fix.md detects drift findings" 5 "$count"
  assert "cec0140 fix.md exits 1 (drift detected)" "1" "$rc"

  # Pattern-3: at least one if-wrap drift in cec0140 fix.md
  p3_count=$(grep -c '^\[drift\]\[P3\]' <<< "$out")
  assert_ge "cec0140 fix.md Pattern-3 (if-wrap drift) detects >=1" 1 "$p3_count"

  # Pattern-2: reason-table drift detected
  p2_count=$(grep -c '^\[drift\]\[P2\]' <<< "$out")
  assert_ge "cec0140 fix.md Pattern-2 (reason-table drift) detects >=1" 1 "$p2_count"
else
  echo "FAIL: git show failed for ${BASELINE_COMMIT}:plugins/rite/commands/pr/fix.md" >&2
  FAIL=$((FAIL + 1))
fi

# --- Test 4: synthetic clean file produces no drift --------------------------
CLEAN=$(mktemp)
TMPFILES+=("$CLEAN")
cat > "$CLEAN" <<'EOF'
# Clean test fixture

This file contains no drift patterns.

Some prose explaining behavior.
EOF
"$SCRIPT" --target "$CLEAN" >/dev/null 2>&1
rc=$?
assert "synthetic clean file exits 0" "0" "$rc"

# --- Test 5: CJK anchors resolve correctly (Pattern 4 end-to-end) ------------
# Use a temp directory so reference files can use relative paths for Pattern 4.
CJK_DIR=$(mktemp -d)
TMPFILES+=("$CJK_DIR")
CJK_TARGET="$CJK_DIR/target.md"
CJK_REF="$CJK_DIR/ref.md"

cat > "$CJK_TARGET" <<'EOF'
# Top heading

## Inconclusive 集計 と META 行への反映

Some content.

## 3 つの failure mode

More content.

## Simple ASCII heading

Even more content.
EOF

# References with correct CJK anchors using relative path (should produce 0 P4 drift)
cat > "$CJK_REF" <<'EOF'
# Referencing file

See [link1](target.md#inconclusive-集計-と-meta-行への反映) for details.
See [link2](target.md#3-つの-failure-mode) for modes.
See [link3](target.md#simple-ascii-heading) for ASCII.
EOF

out=$("$SCRIPT" --target "$CJK_REF" 2>&1)
p4_count=$(grep -c '^\[drift\]\[P4\]' <<< "$out")
assert "CJK anchors resolve correctly (0 P4 drift)" "0" "$p4_count"

# --- Test 6: broken CJK anchor detected (Pattern 4 negative case) -----------
CJK_BROKEN="$CJK_DIR/broken.md"

cat > "$CJK_BROKEN" <<'EOF'
# File with broken anchor

See [link](target.md#nonexistent-集計-heading) for details.
EOF

out=$("$SCRIPT" --target "$CJK_BROKEN" 2>&1)
p4_count=$(grep -c '^\[drift\]\[P4\]' <<< "$out")
assert_ge "broken CJK anchor detected as drift" 1 "$p4_count"

# --- Test 7: --pattern 2 filter outputs only P2 ------------------------------
# Build a fixture that triggers BOTH Pattern-2 (reason-table drift) and
# Pattern-3 (if-wrap drift). Without --pattern, the script would emit both
# findings; with --pattern 2, only P2 lines must appear.
P2_FIXTURE=$(mktemp)
TMPFILES+=("$P2_FIXTURE")
cat > "$P2_FIXTURE" <<'EOF'
# Pattern-2 + Pattern-3 mixed fixture

## Reason table

| reason | description |
|--------|-------------|
| `table_only_reason` | listed in table but never emitted |

Some narrative referencing reason=emit_only_reason for the P2 emit-side detector.

## Code block (Pattern-3 candidate)

cat <<'INNER_EOF' > "$tmpfile"
content
INNER_EOF
EOF

out=$("$SCRIPT" --pattern 2 --target "$P2_FIXTURE" 2>&1)
p2_only_count=$(grep -c '^\[drift\]\[P2\]' <<< "$out")
# Use the same `grep -c PATTERN <<< "$out"` shape as every other count site in
# this file (avoids the `grep | wc -l` pipe). The `[^2]` character class is
# valid in BRE so plain `grep -c` is sufficient — no `-E` needed.
non_p2_count=$(grep -c '^\[drift\]\[P[^2]\]' <<< "$out")
assert_ge "--pattern 2 outputs >=1 P2 finding" 1 "$p2_only_count"
assert "--pattern 2 outputs no non-P2 findings" "0" "$non_p2_count"

# --- Test 8: --all + --repo-root smoke ---------------------------------------
# Build a synthetic repo root containing one of the default --all targets
# (plugins/rite/commands/pr/fix.md) seeded with a Pattern-3 drift. The other
# default targets are absent and silently skipped by the per-pattern
# `[ -f "$file" ] || return 0` guard, so this single-file fixture exercises
# both --all expansion AND --repo-root chdir in one assertion.
ALL_DIR=$(mktemp -d)
TMPFILES+=("$ALL_DIR")
mkdir -p "$ALL_DIR/plugins/rite/commands/pr"
cat > "$ALL_DIR/plugins/rite/commands/pr/fix.md" <<'EOF'
# Synthetic fix.md for --all + --repo-root smoke test

cat <<'INNER_EOF' > "$tmpfile"
content
INNER_EOF
EOF

out=$("$SCRIPT" --repo-root "$ALL_DIR" --all 2>&1)
rc=$?
assert "--all + --repo-root exits 1 (drift detected in default target)" "1" "$rc"
all_p3_count=$(grep -c '^\[drift\]\[P3\]' <<< "$out")
# Discriminator: the synthetic fix.md contains EXACTLY 1 P3 trigger (the
# heredoc fixture above). If `--repo-root` silently no-op'd, the script would
# fall back to the real repo cwd and scan the real
# `plugins/rite/commands/pr/fix.md`, which would yield a different P3 count
# (currently 0 — a clean codebase — but this assertion is robust regardless of
# whether the real file has 0 or many P3 findings, because the count would
# almost certainly not be exactly 1). Asserting "exactly 1" therefore catches
# chdir regression in either direction.
assert "--all + --repo-root: exactly 1 P3 from synthetic target (chdir guard)" "1" "$all_p3_count"
# Path discriminator: the [drift] line should reference fix.md as a relative
# path (the script chdirs to --repo-root before checking). Both synthetic and
# real targets share the same relative path, so this asserts the broad shape
# rather than the absolute location.
all_p3_path_count=$(grep -c '^\[drift\]\[P3\] plugins/rite/commands/pr/fix.md:' <<< "$out")
assert_ge "--all + --repo-root: drift line references fix.md by relative path" 1 "$all_p3_path_count"

# --- Summary -----------------------------------------------------------------
echo
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
