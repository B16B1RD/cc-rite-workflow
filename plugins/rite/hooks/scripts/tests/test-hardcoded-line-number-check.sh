#!/usr/bin/env bash
# Smoke + validation tests for hardcoded-line-number-check.sh
#
# Validates against synthetic fixtures derived from PR #661 cycle 2/3 incident
# (Issue #666). The literals exercised here are taken from commit 6760cc5 and
# 03fe71f (cleanup.md:1674, create-interview.md:605) before they were
# replaced with structural references.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/rite/hooks/scripts/hardcoded-line-number-check.sh"

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

TMPDIR_ROOT=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# --- Test 1: usage / help works ----------------------------------------------
"$SCRIPT" --help >/dev/null 2>&1
rc=$?
assert "--help exits 0" "0" "$rc"

# --- Test 2: missing args returns error code 2 -------------------------------
"$SCRIPT" >/dev/null 2>&1
rc=$?
assert "no args exits 2" "2" "$rc"

# --- Test 3: P-A parenthesized form detected ----------------------------------
FIX_PA="$TMPDIR_ROOT/pa.md"
cat > "$FIX_PA" <<'EOF'
本ブロックは前 ANCHOR (line 1659, 1680) と pair で同期する。
修正対象は (line 588) のみ。
横展開対象は (line 588, 597, 605) の 3 site。
EOF
out=$("$SCRIPT" --target "$FIX_PA" --repo-root "$TMPDIR_ROOT" 2>&1)
rc=$?
count=$(grep -c '\[P-A\]' <<< "$out")
assert "P-A: exits 1 (drift detected)" "1" "$rc"
assert "P-A: 3 parenthesized findings" "3" "$count"

# --- Test 4: P-B prose form detected ------------------------------------------
# Fixture produces exactly 5 P-B matches (one per line):
#   line 1: 本セクション直前 + line 588 (greedy match consumes through `line 588`) = 1 match
#   line 2: 直後 + line 22 = 1 match
#   line 3: 上記 + line 605 = 1 match
#   line 4: 下記 + line 100 = 1 match
#   line 5: 上方 + ... line 50 と下方 line 200 (greedy `[^\n]{0,80}` consumes through `line 200`) = 1 match
# Strict assertion (=) enforces regex precision; loosening to assert_ge would let
# regex over-broadening go undetected.
# Note on greedy quantifier: awk's match() is leftmost-longest. The qualifier on
# line 5 (上方) starts a match that the greedy `[^\n]{0,80}` extends through to
# the LAST `line N` it can reach within 80 bytes — so "line 50 と下方 line 200"
# is consumed by a single match, yielding 1 finding for line 5 (not 2).
FIX_PB="$TMPDIR_ROOT/pb.md"
cat > "$FIX_PB" <<'EOF'
本セクション直前の line 588 / 597 caller HTML inline literal を参照。
直後の line 22 で同じ ANCHOR が定義される。
上記 line 605 の DRIFT-CHECK ANCHOR と pair 同期する。
下記 line 100 を参照。
上方 line 50 と下方 line 200 に同型 anchor。
EOF
out=$("$SCRIPT" --target "$FIX_PB" --repo-root "$TMPDIR_ROOT" 2>&1)
rc=$?
count=$(grep -c '\[P-B\]' <<< "$out")
assert "P-B: exits 1 (drift detected)" "1" "$rc"
assert "P-B: exactly 5 prose findings (strict, greedy quantifier consumes line 5)" "5" "$count"

# --- Test 5: P-C cross-file form detected -------------------------------------
FIX_PC="$TMPDIR_ROOT/pc.md"
cat > "$FIX_PC" <<'EOF'
create.md:580 / create-interview.md:22 の DRIFT-CHECK ANCHOR と pair 同期する。
see implementation in start.md:1234 for details.
EOF
out=$("$SCRIPT" --target "$FIX_PC" --repo-root "$TMPDIR_ROOT" 2>&1)
rc=$?
count=$(grep -c '\[P-C\]' <<< "$out")
assert "P-C: exits 1 (drift detected)" "1" "$rc"
assert "P-C: 3 cross-file findings" "3" "$count"

# --- Test 6: fenced code block exclusion --------------------------------------
FIX_FENCE="$TMPDIR_ROOT/fence.md"
cat > "$FIX_FENCE" <<'EOF'
# Fenced code block exclusion test

Outside fence: this should be flagged → (line 100, 200)

```bash
# Inside fence: should NOT be flagged
echo "(line 300, 400)"
echo "本セクション直前の line 500"
echo "foo.md:42"
```

After fence: this should be flagged → (line 700, 800)
EOF
out=$("$SCRIPT" --target "$FIX_FENCE" --repo-root "$TMPDIR_ROOT" 2>&1)
rc=$?
total_count=$(grep -c '^\[hardcoded' <<< "$out")
assert "fence: exits 1" "1" "$rc"
assert "fence: only 2 findings (outside fence)" "2" "$total_count"

# --- Test 7: range form exclusion (Location: format) --------------------------
FIX_LOC="$TMPDIR_ROOT/location.md"
cat > "$FIX_LOC" <<'EOF'
Review findings:
- Location: docs/overview.md:12-20
- Location: lib/util.sh:100-110
- Location: src/core.md:55-60

Single-line ref (should be flagged):
- See bug.md:42
EOF
out=$("$SCRIPT" --target "$FIX_LOC" --repo-root "$TMPDIR_ROOT" 2>&1)
rc=$?
pc_count=$(grep -c '\[P-C\]' <<< "$out")
assert "range: exits 1" "1" "$rc"
assert "range: only 1 P-C finding (single-line, not range)" "1" "$pc_count"

# --- Test 8: backtick inline code exclusion -----------------------------------
FIX_BT="$TMPDIR_ROOT/backtick.md"
cat > "$FIX_BT" <<'EOF'
The `(line N, M)` pattern is documented as a literal placeholder.
The `本セクション直前の line N` form is example syntax.
The `foo.md:NN` notation is a placeholder.

But this should be flagged: (line 100, 200) is a real hardcoded reference.
EOF
out=$("$SCRIPT" --target "$FIX_BT" --repo-root "$TMPDIR_ROOT" 2>&1)
rc=$?
total_count=$(grep -c '^\[hardcoded' <<< "$out")
assert "backtick: exits 1" "1" "$rc"
assert "backtick: only 1 finding (outside backticks)" "1" "$total_count"

# --- Test 9: structural reference (no line numbers) - clean case --------------
FIX_CLEAN="$TMPDIR_ROOT/clean.md"
cat > "$FIX_CLEAN" <<'EOF'
# Clean structural references (no line numbers, no findings)

- 本セクション直前の Output format example sections (`[interview:skipped]` / `[interview:completed]`) 内の caller HTML inline literal を参照。
- create.md 🚨 Mandatory After Interview Step 0 直後の DRIFT-CHECK ANCHOR と pair 同期する。
- See [link](path/file.md#some-anchor) for the canonical reference.

Edge cases:
- "create.md" alone (no colon-line) is fine.
- File path docs/overview.md without :NN is fine.
EOF
out=$("$SCRIPT" --target "$FIX_CLEAN" --repo-root "$TMPDIR_ROOT" 2>&1)
rc=$?
assert "clean: exits 0 (no drift)" "0" "$rc"

# --- Test 10: --pattern filter -----------------------------------------------
FIX_MIX="$TMPDIR_ROOT/mix.md"
cat > "$FIX_MIX" <<'EOF'
P-A: (line 100, 200)
P-B: 直前の line 50
P-C: foo.md:42
EOF
out_a=$("$SCRIPT" --target "$FIX_MIX" --pattern A --repo-root "$TMPDIR_ROOT" 2>&1)
a_count=$(grep -c '\[P-A\]' <<< "$out_a")
b_count=$(grep -c '\[P-B\]' <<< "$out_a")
c_count=$(grep -c '\[P-C\]' <<< "$out_a")
assert "filter A: only P-A reported" "1" "$a_count"
assert "filter A: P-B suppressed" "0" "$b_count"
assert "filter A: P-C suppressed" "0" "$c_count"

# --- Filter B/C symmetric tests (cycle 2 review recommendation) -------------
out_b=$("$SCRIPT" --target "$FIX_MIX" --pattern B --repo-root "$TMPDIR_ROOT" 2>&1)
b_a_count=$(grep -c '\[P-A\]' <<< "$out_b" || true)
b_b_count=$(grep -c '\[P-B\]' <<< "$out_b" || true)
b_c_count=$(grep -c '\[P-C\]' <<< "$out_b" || true)
assert "filter B: only P-B reported" "1" "$b_b_count"
assert "filter B: P-A suppressed" "0" "$b_a_count"
assert "filter B: P-C suppressed" "0" "$b_c_count"

out_c=$("$SCRIPT" --target "$FIX_MIX" --pattern C --repo-root "$TMPDIR_ROOT" 2>&1)
c_a_count=$(grep -c '\[P-A\]' <<< "$out_c" || true)
c_b_count=$(grep -c '\[P-B\]' <<< "$out_c" || true)
c_c_count=$(grep -c '\[P-C\]' <<< "$out_c" || true)
assert "filter C: only P-C reported" "1" "$c_c_count"
assert "filter C: P-A suppressed" "0" "$c_a_count"
assert "filter C: P-B suppressed" "0" "$c_b_count"

# --- Test 11: --all on real plugins/rite/commands (current state should be clean) ---
out=$("$SCRIPT" --all --quiet 2>&1)
rc=$?
assert "current commands/ tree exits 0 (clean baseline)" "0" "$rc"

# --- Test 12: tilde fence (~~~) exclusion ------------------------------------
FIX_TILDE="$TMPDIR_ROOT/tilde.md"
cat > "$FIX_TILDE" <<'EOF'
# Tilde fence exclusion test (CommonMark / GFM `~~~` form)

Outside fence: this should be flagged → (line 100, 200)

~~~bash
# Inside tilde fence: should NOT be flagged
echo "(line 300, 400)"
echo "本セクション直前の line 500"
echo "foo.md:42"
~~~

After tilde fence: this should be flagged → (line 700, 800)
EOF
out=$("$SCRIPT" --target "$FIX_TILDE" --repo-root "$TMPDIR_ROOT" 2>&1)
rc=$?
total_count=$(grep -c '^\[hardcoded' <<< "$out")
assert "tilde fence: exits 1" "1" "$rc"
assert "tilde fence: only 2 findings (outside fence)" "2" "$total_count"

# --- Test 13: P-C word-boundary edge cases -----------------------------------
# With uppercase support (`[A-Za-z][A-Za-z0-9_.-]*\.md:[0-9]+`), filenames like
# `barFoo.md`, `README.md`, `CHANGELOG.md` are valid full matches.
# Word-boundary check still suppresses substring extraction when prev char is alnum/underscore
# (e.g. `12barFoo.md:42` would attempt match at `b` but prev='2' makes is_continuation=true → skip).
FIX_WB="$TMPDIR_ROOT/word_boundary.md"
cat > "$FIX_WB" <<'EOF'
Mixed-case file name barFoo.md:42 here (now matches as full identifier).
Path with dot: foo.bar.md:42 references implementation.
Normal kebab name: bug-fix.md:99 in the comment.
Range form bug.md:42-50 should NOT trigger.
README.md:10 uppercase markdown filename should match.
Continuation suppression test: prefix12barFoo.md:42 should NOT add another finding.
EOF
out=$("$SCRIPT" --target "$FIX_WB" --repo-root "$TMPDIR_ROOT" 2>&1)
rc=$?
pc_count=$(grep -c '\[P-C\]' <<< "$out")
assert "word-boundary: exits 1" "1" "$rc"
# Expected matches: barFoo.md:42, foo.bar.md:42, bug-fix.md:99, README.md:10 = 4
# bug.md:42-50 must NOT match (range exclusion)
# prefix12barFoo.md:42 → start at 'p' of "prefix" matches whole "prefix12barFoo.md:42" as one finding,
#   not as separate barFoo.md:42 substring (word-boundary suppresses substring re-extraction)
assert_ge "word-boundary: at least 4 findings (uppercase support enabled)" 4 "$pc_count"
# Verify range form is suppressed
range_false_positive=$(grep -c 'cross-file line reference: bug\.md:42$' <<< "$out" || true)
assert "word-boundary: bug.md:42-50 range NOT flagged" "0" "$range_false_positive"

# --- Summary -----------------------------------------------------------------
echo ""
echo "==================================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
