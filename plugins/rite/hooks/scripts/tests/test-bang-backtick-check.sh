#!/usr/bin/env bash
# Smoke + validation tests for bang-backtick-check.sh
#
# Requires bash 4.4+ for safe expansion of empty arrays under `set -u`
# (specifically, `"${ARRAY[@]}"` with an empty ARRAY must not trigger "unbound
# variable"). The explicit version guard below fails fast on older bash rather
# than producing cryptic errors mid-run.
#
# Validates:
#   1. --help exits 0
#   2. Missing args exits 2
#   3. Repo-wide --all scan is clean (AC-3: false positive zero)
#   4. P1 fixture with `if !` triggers detection (AC-4) AND bleed-check: P2 must be 0
#   5. P1 multi-trigger on a single line reports N findings (Issue #369 H-1 regression)
#   6. P2 fixture with `!foo` triggers detection (AC-4) AND bleed-check: P1 must be 0
#   7. P2 multi-trigger on a single line reports N findings (Issue #369 H-1 regression)
#   8. Boundary: tab+! is NOT matched (the P1 regex is literal space, not `[[:space:]]`)
#   9. Boundary: double-space+! IS matched (the P1 regex is `space+!`, which matches
#      the last space in " "+"!")
#  10. Innocent patterns stay clean: Rustdoc `//!`, Markdown image `![alt](url)`,
#      regex literal `!\[...\]`, bash negation `x != y`, `if ! cmd`, AND a fenced
#      code block containing `if !` (scanner is per-line, so block context does not
#      change semantics, but pinning the behavior prevents future regex widening)

set -uo pipefail

# --- bash version guard -----------------------------------------------------
# bash 4.4 introduced the fix for expanding empty arrays under `set -u`. We rely
# on `"${TMPFILES[@]}"` being safe even before any pushes have occurred, so hard-
# fail older bash to avoid surprising mid-run "unbound variable" errors.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "FAIL: bash 4.4+ required (detected ${BASH_VERSION})" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/rite/hooks/scripts/bang-backtick-check.sh"

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

# --- portable mktemp wrapper ------------------------------------------------
# GNU coreutils `mktemp --suffix=.md` is not portable to BSD mktemp (macOS).
# Fall back to plain `mktemp` + rename when the suffix form fails.
mktemp_md() {
  local base
  if base=$(mktemp --suffix=.md 2>/dev/null); then
    printf '%s' "$base"
    return 0
  fi
  base=$(mktemp)
  mv "$base" "${base}.md"
  printf '%s' "${base}.md"
}

TMPFILES=()
trap 'rm -rf "${TMPFILES[@]}"' EXIT

# --- Test 1: --help exits 0 --------------------------------------------------
"$SCRIPT" --help >/dev/null 2>&1
rc=$?
assert "--help exits 0" "0" "$rc"

# --- Test 2: no args exits 2 -------------------------------------------------
"$SCRIPT" >/dev/null 2>&1
rc=$?
assert "no args exits 2" "2" "$rc"

# --- Test 3: repo --all is clean (AC-3 false positive zero) ------------------
"$SCRIPT" --all --quiet >/dev/null 2>&1
rc=$?
assert "repo-wide --all exits 0 (no false positives)" "0" "$rc"

# --- Test 4: P1 fixture triggers P1 only (bleed-check) ----------------------
FIXTURE_P1=$(mktemp_md)
TMPFILES+=("$FIXTURE_P1")
cat > "$FIXTURE_P1" << 'EOF'
# Fixture: P1 pattern

This line contains `if !` which is the Issue #365 triggering pattern.
Another one: check `grep !` usage.
EOF

out=$("$SCRIPT" --target "$FIXTURE_P1" 2>&1)
rc=$?
assert "P1 fixture exits 1 (detected)" "1" "$rc"
# grep -c exits 1 when zero matches; under `set -uo pipefail` (no `-e`) that never
# aborts the script, so the previous `|| true` was pure noise. Remove it throughout
# to keep the test body signal-to-noise high (Issue #369 code-quality cycle 2 L-NEW2).
p1_count=$(grep -c '^\[bang-backtick\]\[P1\]' <<< "$out")
assert_ge "P1 fixture detects >=2 P1 findings" 2 "$p1_count"
p2_in_p1=$(grep -c '^\[bang-backtick\]\[P2\]' <<< "$out")
assert "P1 fixture does NOT bleed into P2 (p2_count == 0)" "0" "$p2_in_p1"

# --- Test 5: P1 multi-trigger on a single line (H-1 regression guard) --------
FIXTURE_P1_MULTI=$(mktemp_md)
TMPFILES+=("$FIXTURE_P1_MULTI")
cat > "$FIXTURE_P1_MULTI" << 'EOF'
# Fixture: three P1 hits on one line

Triple trigger: `if !` and `grep !` and `exit !` live together.
EOF

out=$("$SCRIPT" --target "$FIXTURE_P1_MULTI" 2>&1)
rc=$?
assert "P1 multi-trigger fixture exits 1" "1" "$rc"
p1_multi=$(grep -c '^\[bang-backtick\]\[P1\]' <<< "$out")
# Strict equality (not `-ge 3`) so over-counting regressions — e.g. a scanner rewrite
# that accidentally double-emits the same match, or widens P1 to fire on overlapping
# substrings — are caught as well (Issue #369 test cycle 2 L-NEW3).
assert "P1 multi-trigger reports exactly 3 hits" "3" "$p1_multi"
# Bleed-check: P2 must not fire on P1-only input, even on multi-trigger lines.
# This pins the regex's class isolation against future widening (L-NEW4).
p2_in_p1_multi=$(grep -c '^\[bang-backtick\]\[P2\]' <<< "$out")
assert "P1 multi-trigger does NOT bleed into P2" "0" "$p2_in_p1_multi"

# --- Test 6: P2 fixture triggers P2 only (bleed-check) ----------------------
FIXTURE_P2=$(mktemp_md)
TMPFILES+=("$FIXTURE_P2")
cat > "$FIXTURE_P2" << 'EOF'
# Fixture: P2 pattern

Use `!foo` history expansion.
Or `! cmd` negated.
EOF

out=$("$SCRIPT" --target "$FIXTURE_P2" 2>&1)
rc=$?
assert "P2 fixture exits 1 (detected)" "1" "$rc"
p2_count=$(grep -c '^\[bang-backtick\]\[P2\]' <<< "$out")
assert_ge "P2 fixture detects >=2 P2 findings" 2 "$p2_count"
p1_in_p2=$(grep -c '^\[bang-backtick\]\[P1\]' <<< "$out")
assert "P2 fixture does NOT bleed into P1 (p1_count == 0)" "0" "$p1_in_p2"

# --- Test 7: P2 multi-trigger on a single line (H-1 regression guard) --------
FIXTURE_P2_MULTI=$(mktemp_md)
TMPFILES+=("$FIXTURE_P2_MULTI")
cat > "$FIXTURE_P2_MULTI" << 'EOF'
# Fixture: three P2 hits on one line

Triple trigger: `!foo` and `!bar` and `!baz` all on one line.
EOF

out=$("$SCRIPT" --target "$FIXTURE_P2_MULTI" 2>&1)
rc=$?
assert "P2 multi-trigger fixture exits 1" "1" "$rc"
p2_multi=$(grep -c '^\[bang-backtick\]\[P2\]' <<< "$out")
assert "P2 multi-trigger reports exactly 3 hits" "3" "$p2_multi"
p1_in_p2_multi=$(grep -c '^\[bang-backtick\]\[P1\]' <<< "$out")
assert "P2 multi-trigger does NOT bleed into P1" "0" "$p1_in_p2_multi"

# --- Test 8: tab+! is NOT matched (pins the "space-only" semantics) ----------
# Pinning this intentionally excluded boundary prevents future regex widening
# (e.g. changing space to `[[:space:]]`) from silently bleeding detection into
# tab-delimited inline code.
FIXTURE_TAB=$(mktemp_md)
TMPFILES+=("$FIXTURE_TAB")
printf '# Fixture: tab before bang\n\nThis line has `if\t!` with a tab, not a space.\n' > "$FIXTURE_TAB"

out=$("$SCRIPT" --target "$FIXTURE_TAB" 2>&1)
rc=$?
assert "tab+! fixture exits 0 (tab is NOT treated as space)" "0" "$rc"

# --- Test 9: double-space+! IS matched (the last space satisfies "space+!") --
FIXTURE_DOUBLE_SPACE=$(mktemp_md)
TMPFILES+=("$FIXTURE_DOUBLE_SPACE")
cat > "$FIXTURE_DOUBLE_SPACE" << 'EOF'
# Fixture: double space before bang

This line has `if  !` with two spaces before the bang.
EOF

out=$("$SCRIPT" --target "$FIXTURE_DOUBLE_SPACE" 2>&1)
rc=$?
assert "double-space+! fixture exits 1 (last space matches)" "1" "$rc"

# --- Test 10: innocent patterns remain clean (includes fenced code block) ----
FIXTURE_CLEAN=$(mktemp_md)
TMPFILES+=("$FIXTURE_CLEAN")
cat > "$FIXTURE_CLEAN" << 'EOF'
# Fixture: innocent patterns (should NOT trigger)

Rustdoc inner: `//!` comment.
Markdown image: `![alt](url)`.
Regex literal: `!\[[^\]]*\]`.
Negation in code: `x != y`.
Trailing bang with content: `if ! cmd`.

Next, a fenced code block containing a bash negation (scanner runs per-line,
so the block is NOT re-entered into inline-code semantics):

```bash
if ! cmd
then
  echo "fallback"
fi
```

The fenced block above contains bash negation but does not match the scanner
regex because it is outside inline-code context (no opening/closing backtick
on the same line). Pinning this confirms future regex tweaks do not start
silently flagging fenced code blocks.
EOF

out=$("$SCRIPT" --target "$FIXTURE_CLEAN" 2>&1)
rc=$?
assert "innocent fixture (including fenced block) exits 0" "0" "$rc"

# --- Summary -----------------------------------------------------------------
echo ""
echo "==> PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
