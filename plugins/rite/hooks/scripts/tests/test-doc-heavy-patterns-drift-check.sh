#!/usr/bin/env bash
# Smoke + validation tests for doc-heavy-patterns-drift-check.sh
#
# Requires bash 4.4+ for safe expansion of empty arrays under `set -u`.
#
# Portability note: this test uses `awk` for in-place edits (via the
# read→transform→write→mv pattern) instead of `sed -i`. BSD sed (macOS)
# requires a mandatory backup suffix for `-i`, so `sed -i '<regex>'` syntax
# that works on GNU sed fails with "extra characters at the end of d command"
# on macOS. The `awk` pattern is identical on GNU and BSD and matches the
# sibling `test-bang-backtick-check.sh` portability convention.
#
# Validates:
#   1. --help exits 0
#   2. No --all exits 2 (invocation error)
#   3. Unknown argument exits 2
#   4. Repo-wide --all is clean on the real 3 files (AC: no false positives)
#   5. Drift by removal: tokens removed from tech-writer.md are reported as
#      "only in review.md" AND "only in SKILL.md", and NOT "only in
#      tech-writer.md" (direction-symmetry regression guard)
#   6. Drift by addition: a token added to review.md is reported as
#      "only in review.md" AND NOT "only in tech-writer.md" / "only in SKILL.md"
#   7. Header-token locality: the removed tokens appear under the correct
#      section header (label/token pairing regression guard)
#   8. Missing-file fixture: --repo-root pointing to a tree without the
#      required files exits 2 with a clear diagnostic
#   9. Broken-section fixture: empty Activation section trips the
#      "expected >= 10" guard and exits 2
#  10. Drift-by-removal fixture injection is non-trivial (sed/awk sanity
#      check): the removed line must actually be absent from the mutated file
#      so the test cannot silently no-op on future format changes

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "FAIL: bash 4.4+ required (detected ${BASH_VERSION})" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected output to contain: $needle" >&2
    echo "  actual: $haystack" >&2
    FAIL=$((FAIL + 1))
  fi
}

# Assert that `needle` appears within `window` lines after `header` in
# `haystack`. This pins label/token pairing so a future change to
# `report_diff` that swaps section labels cannot silently pass the test.
assert_contains_near() {
  local desc="$1" header="$2" needle="$3" window="$4" haystack="$5"
  local slice
  slice=$(printf '%s' "$haystack" | grep -F -A "$window" -- "$header" || true)
  if printf '%s' "$slice" | grep -qF -- "$needle"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected '$needle' within $window lines after '$header'" >&2
    echo "  slice: $slice" >&2
    FAIL=$((FAIL + 1))
  fi
}

TMPDIRS=()
cleanup() {
  local d
  for d in "${TMPDIRS[@]}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# Build a minimal repo-root layout containing all 3 required files, copied
# from the real source tree. Callers then mutate one of the copies to inject
# drift and invoke the script with --repo-root pointing at the fake tree.
build_fake_tree() {
  local dest
  # Fail fast on mktemp error so callers cannot silently continue with an
  # empty `dest` (which would cause mkdir/cp to error out in confusing ways).
  dest=$(mktemp -d) || {
    echo "FAIL: build_fake_tree mktemp -d failed" >&2
    exit 2
  }
  TMPDIRS+=("$dest")
  mkdir -p \
    "$dest/plugins/rite/skills/reviewers" \
    "$dest/plugins/rite/commands/pr"
  cp "$REPO_ROOT/plugins/rite/skills/reviewers/tech-writer.md" \
     "$dest/plugins/rite/skills/reviewers/tech-writer.md"
  cp "$REPO_ROOT/plugins/rite/skills/reviewers/SKILL.md" \
     "$dest/plugins/rite/skills/reviewers/SKILL.md"
  cp "$REPO_ROOT/plugins/rite/commands/pr/review.md" \
     "$dest/plugins/rite/commands/pr/review.md"
  printf '%s' "$dest"
}

# Delete the Activation list item for `*.rst` / `*.adoc` from tech-writer.md.
# Uses awk (GNU/BSD-portable) rather than `sed -i` which requires a mandatory
# backup suffix on BSD and breaks the macOS developer path.
#
# We match the line by its full literal content (including the backticks
# around the globs). This is a literal-text match performed by awk's `$0 ==`
# operator, NOT a regex — no metacharacter escaping is needed.
remove_rst_adoc_line() {
  local file="$1"
  local literal='- `*.rst`, `*.adoc`'
  local tmp="${file}.tmp"
  awk -v literal="$literal" '$0 != literal' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Append an extra glob token (`**/*.bogus,`) as a new line right after the
# `doc_file_patterns = [` opener in review.md. Also uses awk for portability.
append_bogus_pattern() {
  local file="$1"
  local tmp="${file}.tmp"
  awk '
    { print }
    /^doc_file_patterns = \[/ { print "  **/*.bogus," }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Blank out the entire Activation body (drop every line between
# `## Activation` and `### Conditional Activation`, exclusive). Used by
# Test 9 (broken-section guard). Replaces the earlier python3 heredoc so the
# test has no python3 preflight requirement.
blank_activation_body() {
  local file="$1"
  local tmp="${file}.tmp"
  awk '
    /^## Activation/ { print; in_sec = 1; next }
    /^### Conditional Activation/ { in_sec = 0 }
    !in_sec { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# --- Test 1: --help exits 0 --------------------------------------------------
"$SCRIPT" --help >/dev/null 2>&1
rc=$?
assert "--help exits 0" "0" "$rc"

# --- Test 2: no --all exits 2 ------------------------------------------------
"$SCRIPT" >/dev/null 2>&1
rc=$?
assert "no --all exits 2" "2" "$rc"

# --- Test 3: unknown argument exits 2 ---------------------------------------
"$SCRIPT" --all --bogus >/dev/null 2>&1
rc=$?
assert "unknown argument exits 2" "2" "$rc"

# --- Test 4: repo-wide --all is clean (dogfood AC) ---------------------------
# Use --repo-root explicitly so the test is independent of the working
# directory from which it was invoked.
"$SCRIPT" --all --quiet --repo-root "$REPO_ROOT" >/dev/null 2>&1
rc=$?
assert "repo-wide --all exits 0 on real 3 files (no false positives)" "0" "$rc"

# --- Test 5: drift by removal ------------------------------------------------
# Delete the `*.rst` / `*.adoc` line from tech-writer.md inside a fake tree.
# The removed tokens should be reported as "only in review.md" AND
# "only in SKILL.md", and NOT reported as "only in tech-writer.md"
# (direction-symmetry regression guard).
FAKE_REMOVED=$(build_fake_tree)
TW_FIXTURE="$FAKE_REMOVED/plugins/rite/skills/reviewers/tech-writer.md"
remove_rst_adoc_line "$TW_FIXTURE"

# Sanity check: the line must be gone from the fixture. Without this, a
# future format change that makes `remove_rst_adoc_line` a silent no-op would
# let the test pass for the wrong reason (exit-code assertion alone can fire
# from a different drift source).
if grep -qF -- '- `*.rst`, `*.adoc`' "$TW_FIXTURE"; then
  echo "FAIL: Test 5 fixture injection did not remove the target line" >&2
  echo "  file: $TW_FIXTURE" >&2
  FAIL=$((FAIL + 1))
fi

out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_REMOVED" 2>&1)
rc=$?
assert "drift-by-removal fixture exits 1" "1" "$rc"
assert_contains "drift-by-removal reports *.rst as missing from tech-writer.md" \
  "*.rst" "$out"
assert_contains "drift-by-removal reports *.adoc as missing from tech-writer.md" \
  "*.adoc" "$out"
assert_contains "drift-by-removal names review.md as the source of the extra token" \
  "only in review.md" "$out"
assert_contains "drift-by-removal names SKILL.md as the source of the extra token" \
  "only in SKILL.md" "$out"

# Bleed-check: tech-writer.md must NEVER be reported as a source of an extra
# token when drift is injected by removing from tech-writer.md. A direction
# regression in `report_diff` that swapped its comm arguments would make
# `only in tech-writer.md Activation` appear instead — this assertion pins
# the expected direction.
tw_source_hits=$(printf '%s' "$out" | grep -c "only in tech-writer.md Activation" || true)
assert "drift-by-removal does NOT falsely report tech-writer.md as source" "0" "$tw_source_hits"

# Header-token locality: the removed tokens must appear under the correct
# section header (not elsewhere in the output). `assert_contains_near`
# greps `-A 5` after the header label and confirms the token is present in
# that window, pinning the label/token pairing.
assert_contains_near \
  "drift-by-removal pins *.rst under 'only in review.md' header" \
  "only in review.md" \
  "*.rst" \
  5 \
  "$out"
assert_contains_near \
  "drift-by-removal pins *.adoc under 'only in SKILL.md' header" \
  "only in SKILL.md" \
  "*.adoc" \
  5 \
  "$out"

# --- Test 6: drift by addition ----------------------------------------------
# Insert an extra glob token into review.md's doc_file_patterns block. The
# new token should be reported as "only in review.md" AND NOT as
# "only in tech-writer.md" / "only in SKILL.md" (direction-symmetry).
FAKE_ADDED=$(build_fake_tree)
REVIEW_FIXTURE="$FAKE_ADDED/plugins/rite/commands/pr/review.md"
append_bogus_pattern "$REVIEW_FIXTURE"

if ! grep -qF -- '**/*.bogus' "$REVIEW_FIXTURE"; then
  echo "FAIL: Test 6 fixture injection did not insert **/*.bogus" >&2
  echo "  file: $REVIEW_FIXTURE" >&2
  FAIL=$((FAIL + 1))
fi

out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_ADDED" 2>&1)
rc=$?
assert "drift-by-addition fixture exits 1" "1" "$rc"
assert_contains "drift-by-addition reports **/*.bogus only in review.md" \
  "**/*.bogus" "$out"
assert_contains "drift-by-addition names review.md as the source of the extra token" \
  "only in review.md" "$out"

# Bleed-check: the other two files must NEVER be reported as a source when
# the drift comes from review.md only.
tw_source_hits=$(printf '%s' "$out" | grep -c "only in tech-writer.md Activation" || true)
skill_source_hits=$(printf '%s' "$out" | grep -c "only in SKILL.md Technical Writer row" || true)
assert "drift-by-addition does NOT falsely report tech-writer.md as source" "0" "$tw_source_hits"
assert "drift-by-addition does NOT falsely report SKILL.md as source" "0" "$skill_source_hits"

# Header-token locality for drift-by-addition.
assert_contains_near \
  "drift-by-addition pins **/*.bogus under 'only in review.md' header" \
  "only in review.md" \
  "**/*.bogus" \
  5 \
  "$out"

# --- Test 7: missing-file fixture -------------------------------------------
# A fake repo root with none of the required files should exit 2 with a
# clear diagnostic.
FAKE_MISSING=$(mktemp -d) || {
  echo "FAIL: Test 7 mktemp -d failed" >&2
  exit 2
}
TMPDIRS+=("$FAKE_MISSING")
mkdir -p "$FAKE_MISSING/plugins/rite"
out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_MISSING" 2>&1)
rc=$?
assert "missing-file fixture exits 2" "2" "$rc"
assert_contains "missing-file fixture names the missing file" \
  "tech-writer.md" "$out"

# --- Test 8: broken-section guard --------------------------------------------
# Blank out tech-writer.md's Activation body. The extractor should find zero
# list items, fall through the >= 10 guard, and exit 2 with a diagnostic
# rather than falsely reporting drift.
FAKE_BROKEN=$(build_fake_tree)
blank_activation_body "$FAKE_BROKEN/plugins/rite/skills/reviewers/tech-writer.md"

out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_BROKEN" 2>&1)
rc=$?
assert "broken-section fixture exits 2 (guard trips)" "2" "$rc"
assert_contains "broken-section fixture names tech-writer.md in the error" \
  "tech-writer.md" "$out"

# --- Summary -----------------------------------------------------------------
echo ""
echo "==> PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
