#!/usr/bin/env bash
# Smoke + validation tests for doc-heavy-patterns-drift-check.sh
#
# Requires bash 4.4+ for safe expansion of empty arrays under `set -u`.
#
# Validates:
#   1. --help exits 0
#   2. No --all exits 2 (invocation error)
#   3. Unknown argument exits 2
#   4. Repo-wide --all is clean on the real 3 files (AC: no false positives)
#   5. Drift fixture: token removed from a copy of tech-writer.md triggers
#      a "only in review.md / only in SKILL.md" finding pair (exit 1)
#   6. Drift fixture: token added to a copy of review.md triggers a
#      "only in review.md" finding (exit 1)
#   7. Missing-file fixture: --repo-root pointing to a tree without the
#      required files exits 2
#   8. Broken-section fixture: empty Activation section trips the
#      "expected >= 10" guard and exits 2

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
  dest=$(mktemp -d)
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

# --- Test 1: --help exits 0 --------------------------------------------------
"$SCRIPT" --help >/dev/null 2>&1
rc=$?
assert "--help exits 0" "0" "$rc"

# --- Test 2: no --all exits 2 ------------------------------------------------
"$SCRIPT" >/dev/null 2>&1
rc=$?
assert "no --all exits 2" "2" "$rc"

# --- Test 3: unknown argument exits 2 ---------------------------------------
"$SCRIPT" --all --bogus 2>/dev/null
rc=$?
assert "unknown argument exits 2" "2" "$rc"

# --- Test 4: repo-wide --all is clean (dogfood AC) ---------------------------
# Use --repo-root explicitly so the test is independent of the working
# directory from which it was invoked.
"$SCRIPT" --all --quiet --repo-root "$REPO_ROOT" >/dev/null 2>&1
rc=$?
assert "repo-wide --all exits 0 on real 3 files (no false positives)" "0" "$rc"

# --- Test 5: drift by removal ------------------------------------------------
# Delete an Activation list item from tech-writer.md inside a fake tree. The
# removed tokens should be reported as "only in review.md" and "only in
# SKILL.md".
FAKE_REMOVED=$(build_fake_tree)
# Remove the line containing `*.rst`, `*.adoc` from the Activation section.
# sed's `/pattern/d` matches the literal substring; the two tokens on that line
# will disappear from tech-writer.md's extracted set.
sed -i '/- `\*\.rst`, `\*\.adoc`/d' \
  "$FAKE_REMOVED/plugins/rite/skills/reviewers/tech-writer.md"

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

# --- Test 6: drift by addition ----------------------------------------------
# Insert an extra glob token into review.md's doc_file_patterns block. The
# new token should be reported as "only in review.md".
FAKE_ADDED=$(build_fake_tree)
sed -i '/^doc_file_patterns = \[/a\  **/*.bogus,' \
  "$FAKE_ADDED/plugins/rite/commands/pr/review.md"

out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_ADDED" 2>&1)
rc=$?
assert "drift-by-addition fixture exits 1" "1" "$rc"
assert_contains "drift-by-addition reports **/*.bogus only in review.md" \
  "**/*.bogus" "$out"
assert_contains "drift-by-addition names review.md as the source of the extra token" \
  "only in review.md" "$out"

# --- Test 7: missing-file fixture -------------------------------------------
# A fake repo root with none of the required files should exit 2 with a
# clear diagnostic.
FAKE_MISSING=$(mktemp -d)
TMPDIRS+=("$FAKE_MISSING")
mkdir -p "$FAKE_MISSING/plugins/rite"
out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_MISSING" 2>&1)
rc=$?
assert "missing-file fixture exits 2" "2" "$rc"
assert_contains "missing-file fixture names the missing file" \
  "tech-writer.md" "$out"

# --- Test 8: broken-section guard --------------------------------------------
# Truncate tech-writer.md's Activation section to empty. The extractor should
# find zero list items, fall through the >= 10 guard, and exit 2 with a
# diagnostic rather than falsely reporting drift.
FAKE_BROKEN=$(build_fake_tree)
python3 - "$FAKE_BROKEN/plugins/rite/skills/reviewers/tech-writer.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
out = []
in_sec = False
for line in lines:
    if line.startswith('## Activation'):
        out.append(line)
        in_sec = True
        continue
    if in_sec and line.startswith('### Conditional Activation'):
        in_sec = False
        out.append(line)
        continue
    if in_sec:
        # Drop the entire Activation body.
        continue
    out.append(line)
path.write_text(''.join(out))
PY

out=$("$SCRIPT" --all --quiet --repo-root "$FAKE_BROKEN" 2>&1)
rc=$?
assert "broken-section fixture exits 2 (guard trips)" "2" "$rc"
assert_contains "broken-section fixture names tech-writer.md in the error" \
  "tech-writer.md" "$out"

# --- Summary -----------------------------------------------------------------
echo ""
echo "==> PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
