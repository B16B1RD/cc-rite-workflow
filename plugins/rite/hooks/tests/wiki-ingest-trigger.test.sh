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
# TC-002: No arguments → exit 1
# --------------------------------------------------------------------------
echo "TC-002: No arguments → exit 1"
bash "$HOOK" >/dev/null 2>&1 && rc=0 || rc=$?
if [ $rc -eq 1 ]; then
  pass "No args → exit 1"
else
  fail "Expected exit 1 with no args, got rc=$rc"
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
     grep -q 'Review body content here' "$dir10/$target_path"; then
    pass "Happy path: file created with correct frontmatter and body"
  else
    fail "File created but frontmatter/body incorrect. File: $(cat "$dir10/$target_path")"
  fi
else
  fail "Expected file creation, got rc=$rc, target='$target_path', stderr=$(cat "$dir10/err.log" 2>/dev/null)"
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
