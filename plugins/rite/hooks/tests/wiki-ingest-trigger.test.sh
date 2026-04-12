#!/bin/bash
# Tests for wiki-ingest-trigger.sh
# Usage: bash plugins/rite/hooks/tests/wiki-ingest-trigger.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../wiki-ingest-trigger.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  cd /
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

# Helper: run trigger in isolated tmp dir, capture stdout + stderr separately
run_trigger() {
  local subdir="$1"
  shift
  local target="$TEST_DIR/$subdir"
  mkdir -p "$target"
  cd "$target"
  bash "$HOOK" "$@" 2>"$target/stderr.log"
}

echo "=== wiki-ingest-trigger.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: --help → exit 0 with usage text
# --------------------------------------------------------------------------
echo "TC-001: --help → exit 0 with usage"
output=$(bash "$HOOK" --help 2>&1) && rc=0 || rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "Usage: wiki-ingest-trigger.sh"; then
  pass "--help prints usage and exits 0"
else
  fail "Expected usage output and rc=0, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-002: No arguments → exit 1 + Usage shown on stderr (F-22)
# --------------------------------------------------------------------------
echo "TC-002: No arguments → exit 1 + Usage on stderr"
bash "$HOOK" >/dev/null 2>"$TEST_DIR/err2.log" && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q '^Usage: wiki-ingest-trigger.sh' "$TEST_DIR/err2.log"; then
  pass "No args → exit 1 + Usage printed on stderr"
else
  fail "Expected exit 1 with Usage on stderr, got rc=$rc, stderr=$(cat "$TEST_DIR/err2.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-003: Missing --type → exit 1
# --------------------------------------------------------------------------
echo "TC-003: Missing --type → exit 1"
echo "body" > "$TEST_DIR/body3.md"
bash "$HOOK" --source-ref pr-1 --content-file "$TEST_DIR/body3.md" >/dev/null 2>"$TEST_DIR/err3.log" && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q '\-\-type is required' "$TEST_DIR/err3.log"; then
  pass "Missing --type → exit 1 with correct error"
else
  fail "Expected exit 1 with '--type is required', got rc=$rc, stderr=$(cat "$TEST_DIR/err3.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: Invalid type → exit 1
# --------------------------------------------------------------------------
echo "TC-004: Invalid --type value → exit 1"
echo "body" > "$TEST_DIR/body4.md"
bash "$HOOK" --type bogus --source-ref pr-1 --content-file "$TEST_DIR/body4.md" >/dev/null 2>"$TEST_DIR/err4.log" && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q "must be one of" "$TEST_DIR/err4.log"; then
  pass "Invalid type → exit 1 with allowed list"
else
  fail "Expected exit 1 with 'must be one of', got rc=$rc, stderr=$(cat "$TEST_DIR/err4.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: Missing --source-ref → exit 1
# --------------------------------------------------------------------------
echo "TC-005: Missing --source-ref → exit 1"
echo "body" > "$TEST_DIR/body5.md"
bash "$HOOK" --type reviews --content-file "$TEST_DIR/body5.md" >/dev/null 2>"$TEST_DIR/err5.log" && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q '\-\-source-ref is required' "$TEST_DIR/err5.log"; then
  pass "Missing --source-ref → exit 1"
else
  fail "Expected exit 1, got rc=$rc, stderr=$(cat "$TEST_DIR/err5.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: Missing --content-file → exit 1
# --------------------------------------------------------------------------
echo "TC-006: Missing --content-file → exit 1"
bash "$HOOK" --type reviews --source-ref pr-1 >/dev/null 2>"$TEST_DIR/err6.log" && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q '\-\-content-file is required' "$TEST_DIR/err6.log"; then
  pass "Missing --content-file → exit 1"
else
  fail "Expected exit 1, got rc=$rc, stderr=$(cat "$TEST_DIR/err6.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: Nonexistent --content-file → exit 1
# --------------------------------------------------------------------------
echo "TC-007: Nonexistent --content-file → exit 1"
bash "$HOOK" --type reviews --source-ref pr-1 --content-file /nonexistent/path.md >/dev/null 2>"$TEST_DIR/err7.log" && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'does not exist' "$TEST_DIR/err7.log"; then
  pass "Nonexistent content file → exit 1"
else
  fail "Expected exit 1, got rc=$rc, stderr=$(cat "$TEST_DIR/err7.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: Empty content file → exit 1
# --------------------------------------------------------------------------
echo "TC-008: Empty --content-file → exit 1"
: > "$TEST_DIR/empty.md"
bash "$HOOK" --type reviews --source-ref pr-1 --content-file "$TEST_DIR/empty.md" >/dev/null 2>"$TEST_DIR/err8.log" && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'is empty' "$TEST_DIR/err8.log"; then
  pass "Empty content file → exit 1"
else
  fail "Expected exit 1, got rc=$rc, stderr=$(cat "$TEST_DIR/err8.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: wiki.enabled: false in rite-config.yml → exit 2
# --------------------------------------------------------------------------
echo "TC-009: wiki.enabled: false → exit 2"
dir9="$TEST_DIR/tc9"
mkdir -p "$dir9"
cat > "$dir9/rite-config.yml" <<'EOF'
wiki:
  enabled: false
EOF
echo "body" > "$dir9/body.md"
( cd "$dir9" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 2 ] && grep -q 'wiki.enabled is false' "$dir9/err.log"; then
  pass "wiki.enabled: false → exit 2"
else
  fail "Expected exit 2 with 'wiki.enabled is false', got rc=$rc, stderr=$(cat "$dir9/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: Happy path — reviews type, file created with correct frontmatter
# --------------------------------------------------------------------------
echo "TC-010: Happy path (reviews) → file created with frontmatter"
dir10="$TEST_DIR/tc10"
mkdir -p "$dir10"
cat > "$dir10/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
echo "Review body content here" > "$dir10/body.md"
( cd "$dir10" && bash "$HOOK" \
  --type reviews \
  --source-ref pr-123 \
  --content-file body.md \
  --pr-number 123 \
  --title "Code review for PR #123" > out.log 2>err.log ) && rc=0 || rc=$?

target_path="$(cat "$dir10/out.log" 2>/dev/null || true)"
if [ $rc -eq 0 ] && [ -n "$target_path" ] && [ -f "$dir10/$target_path" ]; then
  if grep -q '^type: reviews$' "$dir10/$target_path" && \
     grep -q '^source_ref: pr-123$' "$dir10/$target_path" && \
     grep -q '^pr_number: 123$' "$dir10/$target_path" && \
     grep -q '^ingested: false$' "$dir10/$target_path" && \
     grep -q '^title: "Code review for PR #123"$' "$dir10/$target_path" && \
     grep -qE '^captured_at: "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00"$' "$dir10/$target_path" && \
     grep -q 'Review body content here' "$dir10/$target_path"; then
    pass "Happy path: file created with correct frontmatter (incl. captured_at ISO8601) and body"
  else
    fail "File created but frontmatter/body incorrect. File: $(cat "$dir10/$target_path")"
  fi
else
  fail "Expected file creation, got rc=$rc, target='$target_path', stderr=$(cat "$dir10/err.log" 2>/dev/null)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-015: Empty slug after sanitization → exit 1 (F-23)
# --------------------------------------------------------------------------
echo "TC-015: Special-chars-only --source-ref → exit 1 (empty slug)"
dir15="$TEST_DIR/tc15"
mkdir -p "$dir15"
echo "x" > "$dir15/body.md"
( cd "$dir15" && bash "$HOOK" --type reviews --source-ref "///@@@" --content-file body.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'produced an empty slug' "$dir15/err.log"; then
  pass "Special-chars-only source-ref → exit 1 with 'empty slug' message"
else
  fail "Expected exit 1 with 'empty slug', got rc=$rc, stderr=$(cat "$dir15/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-016: Long source-ref → slug truncated to 60 chars (F-24)
# --------------------------------------------------------------------------
echo "TC-016: 70-char source-ref → slug truncated to 60 chars"
dir16="$TEST_DIR/tc16"
mkdir -p "$dir16"
echo "x" > "$dir16/body.md"
long_ref="aaaaaaaaaa-bbbbbbbbbb-cccccccccc-dddddddddd-eeeeeeeeee-ffffffffff-gggggg"
( cd "$dir16" && bash "$HOOK" --type reviews --source-ref "$long_ref" --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
target_path="$(cat "$dir16/out.log" 2>/dev/null || true)"
filename="$(basename "$target_path" 2>/dev/null || true)"
slug_part="${filename#*-}"
slug_part="${slug_part%.md}"
if [ $rc -eq 0 ] && [ "${#slug_part}" -eq 60 ]; then
  pass "Slug truncated to exactly 60 chars (got: ${#slug_part})"
else
  fail "Expected slug length 60, got '${#slug_part}' (slug='$slug_part', filename='$filename')"
fi
echo ""

# --------------------------------------------------------------------------
# TC-017: Newline in --source-ref → exit 1 (F-07 YAML injection)
# --------------------------------------------------------------------------
echo "TC-017: Newline in --source-ref → exit 1"
dir17="$TEST_DIR/tc17"
mkdir -p "$dir17"
echo "x" > "$dir17/body.md"
( cd "$dir17" && bash "$HOOK" --type reviews --source-ref $'pr-1\n---\n# Malicious' --content-file body.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'must not contain newlines' "$dir17/err.log"; then
  pass "Newline in source-ref → exit 1 (YAML injection blocked)"
else
  fail "Expected exit 1 'must not contain newlines', got rc=$rc, stderr=$(cat "$dir17/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-018: Newline in --title → exit 1 (F-08 YAML injection)
# --------------------------------------------------------------------------
echo "TC-018: Newline in --title → exit 1"
dir18="$TEST_DIR/tc18"
mkdir -p "$dir18"
echo "x" > "$dir18/body.md"
( cd "$dir18" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md --title $'foo\nbar' >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'must not contain newlines' "$dir18/err.log"; then
  pass "Newline in title → exit 1"
else
  fail "Expected exit 1, got rc=$rc, stderr=$(cat "$dir18/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-019: Title with embedded double quote → properly escaped (F-08)
# --------------------------------------------------------------------------
echo "TC-019: Title with embedded double quote → escaped to \\\""
dir19="$TEST_DIR/tc19"
mkdir -p "$dir19"
echo "x" > "$dir19/body.md"
( cd "$dir19" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md --title 'He said "hi"' > out.log 2>err.log ) && rc=0 || rc=$?
target_path="$(cat "$dir19/out.log" 2>/dev/null || true)"
if [ $rc -eq 0 ] && [ -f "$dir19/$target_path" ] && \
   grep -q '^title: "He said \\"hi\\""$' "$dir19/$target_path"; then
  pass "Double-quote in title → escaped as \\\" in YAML"
else
  fail "Expected escaped quote, got rc=$rc, file content: $(cat "$dir19/$target_path" 2>/dev/null)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-020: Title ending with odd backslashes → exit 1 (F-08)
# --------------------------------------------------------------------------
echo "TC-020: Title ending with single backslash → exit 1"
dir20="$TEST_DIR/tc20"
mkdir -p "$dir20"
echo "x" > "$dir20/body.md"
( cd "$dir20" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md --title 'foo\' >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'odd number of backslashes' "$dir20/err.log"; then
  pass "Odd trailing backslash in title → exit 1"
else
  fail "Expected exit 1 'odd number of backslashes', got rc=$rc, stderr=$(cat "$dir20/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-021: Non-numeric --pr-number → exit 1 (F-09)
# --------------------------------------------------------------------------
echo "TC-021: Non-numeric --pr-number → exit 1"
dir21="$TEST_DIR/tc21"
mkdir -p "$dir21"
echo "x" > "$dir21/body.md"
( cd "$dir21" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md --pr-number "1abc" >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'must be a positive integer' "$dir21/err.log"; then
  pass "Non-numeric pr-number → exit 1"
else
  fail "Expected exit 1, got rc=$rc, stderr=$(cat "$dir21/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-022: --pr-number with newline injection → exit 1 (F-09)
# --------------------------------------------------------------------------
echo "TC-022: --pr-number with embedded newline → exit 1"
dir22="$TEST_DIR/tc22"
mkdir -p "$dir22"
echo "x" > "$dir22/body.md"
( cd "$dir22" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md --pr-number $'1\ningested: true' >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'must be a positive integer' "$dir22/err.log"; then
  pass "Newline in pr-number → exit 1 (injection blocked)"
else
  fail "Expected exit 1, got rc=$rc, stderr=$(cat "$dir22/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-023: wiki.enabled: yes → accepted as enabled
# --------------------------------------------------------------------------
echo "TC-023: wiki.enabled: yes / 1 → accepted"
for variant in yes 1; do
  d="$TEST_DIR/tc23_$variant"
  mkdir -p "$d"
  cat > "$d/rite-config.yml" <<EOF
wiki:
  enabled: $variant
EOF
  echo "x" > "$d/body.md"
  ( cd "$d" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
  if [ $rc -ne 0 ]; then
    fail "wiki.enabled=$variant should be accepted, got rc=$rc, stderr=$(cat "$d/err.log")"
  fi
done
pass "wiki.enabled: yes / 1 both accepted"
echo ""

# --------------------------------------------------------------------------
# TC-024: wiki.enabled: no → exit 2 (F-01 lenient parser variant)
# --------------------------------------------------------------------------
echo "TC-024: wiki.enabled: no → exit 2"
d="$TEST_DIR/tc24"
mkdir -p "$d"
cat > "$d/rite-config.yml" <<'EOF'
wiki:
  enabled: no
EOF
echo "x" > "$d/body.md"
( cd "$d" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 2 ] && grep -q 'wiki.enabled is false' "$d/err.log"; then
  pass "wiki.enabled: no → exit 2"
else
  fail "Expected exit 2, got rc=$rc, stderr=$(cat "$d/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-025: rite-config.yml without wiki: section → lenient pass (F-01)
# --------------------------------------------------------------------------
echo "TC-025: rite-config.yml without wiki: section → lenient pass (no abort)"
d="$TEST_DIR/tc25"
mkdir -p "$d"
cat > "$d/rite-config.yml" <<'EOF'
project:
  type: generic
EOF
echo "x" > "$d/body.md"
( cd "$d" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 0 ]; then
  pass "Missing wiki: section → lenient pass (rc=0, no silent abort from pipefail × grep)"
else
  fail "Expected rc=0 (lenient), got rc=$rc, stderr=$(cat "$d/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: Happy path — fixes type, target dir matches type
# --------------------------------------------------------------------------
echo "TC-011: type=fixes → target dir is .rite/wiki/raw/fixes/"
dir11="$TEST_DIR/tc11"
mkdir -p "$dir11"
echo "Fix details" > "$dir11/body.md"
( cd "$dir11" && bash "$HOOK" \
  --type fixes \
  --source-ref pr-456 \
  --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
target_path="$(cat "$dir11/out.log" 2>/dev/null || true)"
if [ $rc -eq 0 ] && echo "$target_path" | grep -q '^\.rite/wiki/raw/fixes/'; then
  pass "type=fixes → file written to .rite/wiki/raw/fixes/"
else
  fail "Expected path under raw/fixes/, got '$target_path' (rc=$rc)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-012: Happy path — retrospectives type, with issue-number, no title
# --------------------------------------------------------------------------
echo "TC-012: type=retrospectives without --title"
dir12="$TEST_DIR/tc12"
mkdir -p "$dir12"
echo "Retrospective body" > "$dir12/body.md"
( cd "$dir12" && bash "$HOOK" \
  --type retrospectives \
  --source-ref issue-469 \
  --content-file body.md \
  --issue-number 469 > out.log 2>err.log ) && rc=0 || rc=$?
target_path="$(cat "$dir12/out.log" 2>/dev/null || true)"
if [ $rc -eq 0 ] && [ -f "$dir12/$target_path" ] && \
   grep -q '^issue_number: 469$' "$dir12/$target_path" && \
   ! grep -q '^title:' "$dir12/$target_path"; then
  pass "type=retrospectives, --title omitted → frontmatter correct"
else
  fail "Expected issue_number set and no title, rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-013: Slug sanitization — special chars stripped
# --------------------------------------------------------------------------
echo "TC-013: Special characters in --source-ref are slugified"
dir13="$TEST_DIR/tc13"
mkdir -p "$dir13"
echo "x" > "$dir13/body.md"
( cd "$dir13" && bash "$HOOK" \
  --type reviews \
  --source-ref "PR/#123 :: Review" \
  --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
target_path="$(cat "$dir13/out.log" 2>/dev/null || true)"
filename="$(basename "$target_path" 2>/dev/null || true)"
# Filename should have only [a-z0-9-] after the timestamp prefix
if [ $rc -eq 0 ] && echo "$filename" | grep -qE '^[0-9]+T[0-9]+Z-pr-123-review\.md$'; then
  pass "Slug sanitization works (PR/#123 :: Review → pr-123-review)"
else
  fail "Slug sanitization failed: filename='$filename'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-014: Unknown option → exit 1
# --------------------------------------------------------------------------
echo "TC-014: Unknown option → exit 1"
echo "x" > "$TEST_DIR/body14.md"
bash "$HOOK" --type reviews --source-ref pr-1 --content-file "$TEST_DIR/body14.md" --bogus-flag >/dev/null 2>"$TEST_DIR/err14.log" && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'Unknown option' "$TEST_DIR/err14.log"; then
  pass "Unknown option → exit 1"
else
  fail "Expected exit 1, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
