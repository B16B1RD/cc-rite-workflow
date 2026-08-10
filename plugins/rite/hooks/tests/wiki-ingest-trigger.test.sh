#!/bin/bash
# Tests for wiki-ingest-trigger.sh
# Usage: bash plugins/rite/hooks/tests/wiki-ingest-trigger.test.sh
set -euo pipefail

pr_text() { printf 'PR #%s' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../wiki-ingest-trigger.sh"
# Canonicalize the sandbox root. wiki-ingest-trigger.sh's --content-file guard
# compares realpath(content-file) against $PWD; on macOS $TMPDIR is under
# /var/folders (symlinked to /private/var), so a raw mktemp path makes every
# `cd "$TEST_DIR/tcN" && ... --content-file body.md` case fail the $PWD-arm match
# ("must be under $PWD"). pwd -P aligns the fixture with the canonical form the
# guard resolves to; the guard's own $PWD-arm symlink handling is
# tracked separately in #2012).
#
# Two steps, not `$(cd "$(mktemp -d)" && pwd -P)`: bash `cd ""` returns 0 without
# changing directory, so a failed mktemp inside that nesting would yield the
# current directory (the repository checkout under CI) with a zero exit status,
# and the `rm -rf "$TEST_DIR"` in the EXIT trap below would delete it.
TEST_DIR="$(mktemp -d)" || exit 1
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)" || exit 1
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

# Skips are counted so a platform-gated green states how many assertions never ran
# (review I-03). Same shape as _test-helpers.sh skip.
SKIP=0
skip() {
  SKIP=$((SKIP + 1))
  echo "  ⏭️ SKIP: $1"
}

echo "=== wiki-ingest-trigger.sh tests ==="
echo ""

# ==========================================================================
# Phase: 引数バリデーション (TC-001 〜 TC-008)
# ==========================================================================

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
dir8="$TEST_DIR/tc8"
mkdir -p "$dir8"
: > "$dir8/empty.md"
( cd "$dir8" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file empty.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'is empty' "$dir8/err.log"; then
  pass "Empty content file → exit 1"
else
  fail "Expected exit 1, got rc=$rc, stderr=$(cat "$dir8/err.log")"
fi
echo ""

# ==========================================================================
# Phase: Wiki 有効/無効判定 (TC-009, TC-020 〜 TC-025, TC-029 〜 TC-036)
# ==========================================================================

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

# ==========================================================================
# Phase: Happy path + ファイル生成検証 (TC-010 〜 TC-014)
# ==========================================================================

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
  --title "Code review for $(pr_text 123)" > out.log 2>err.log) && rc=0 || rc=$?

target_path="$(cat "$dir10/out.log" 2>/dev/null || true)"
if [ $rc -eq 0 ] && [ -n "$target_path" ] && [ -f "$dir10/$target_path" ]; then
  if grep -q '^type: reviews$' "$dir10/$target_path" && \
     grep -q '^source_ref: "pr-123"$' "$dir10/$target_path" && \
     grep -q '^pr_number: 123$' "$dir10/$target_path" && \
     grep -q '^ingested: false$' "$dir10/$target_path" && \
     grep -q "^title: \"Code review for $(pr_text 123)\"$" "$dir10/$target_path" && \
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

# ==========================================================================
# Phase: セキュリティ (TC-015 〜 TC-019, TC-026)
# ==========================================================================

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
if [ $rc -eq 1 ] && grep -q 'control characters' "$dir17/err.log"; then
  pass "Newline in source-ref → exit 1 (YAML injection blocked)"
else
  fail "Expected exit 1 'control characters', got rc=$rc, stderr=$(cat "$dir17/err.log")"
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
if [ $rc -eq 1 ] && grep -q 'control characters' "$dir18/err.log"; then
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
# TC-023: wiki.enabled: yes / 1 → accepted as enabled
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
  else
    # cycle 6 fix: exit code だけでなくファイル存在も検証 (false positive 防止)
    target_path=$(cat "$d/out.log" | tr -d '[:space:]')
    if [ -n "$target_path" ] && [ -f "$d/$target_path" ]; then
      pass "wiki.enabled: $variant accepted + file exists"
    else
      fail "wiki.enabled=$variant rc=0 but output file not found (path='$target_path')"
    fi
  fi
done
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
  # cycle 7 fix: exit code だけでなくファイル存在も検証 (TC-023/TC-028 と同パターン)
  target_path25=$(cat "$d/out.log" | tr -d '[:space:]')
  if [ -n "$target_path25" ] && [ -f "$d/$target_path25" ]; then
    pass "Missing wiki: section → lenient pass (rc=0 + file exists)"
  else
    fail "Missing wiki: section → rc=0 but output file not found (path='$target_path25')"
  fi
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
target_path="$(cat "$dir11/out.log" 2>/dev/null | tr -d '[:space:]' || true)"
if [ $rc -eq 0 ] && echo "$target_path" | grep -q '^\.rite/wiki/raw/fixes/' && \
   [ -f "$dir11/$target_path" ] && \
   grep -q '^type: fixes$' "$dir11/$target_path" && \
   grep -q 'Fix details' "$dir11/$target_path"; then
  pass "type=fixes → file written to .rite/wiki/raw/fixes/ + frontmatter + body verified"
else
  fail "Expected path under raw/fixes/ with type: fixes frontmatter and body, got '$target_path' (rc=$rc)"
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
# TC-026: Body containing markdown horizontal rule (---) → integrity check passes (cycle 2 H1)
# --------------------------------------------------------------------------
echo "TC-026: Body with markdown horizontal rule → integrity check passes"
dir26="$TEST_DIR/tc26"
mkdir -p "$dir26"
printf '%s\n' '## Section A' '' '---' '' '## Section B' > "$dir26/body.md"
( cd "$dir26" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
target_path="$(cat "$dir26/out.log" 2>/dev/null || true)"
if [ $rc -eq 0 ] && [ -n "$target_path" ] && [ -f "$dir26/$target_path" ]; then
  pass "Body containing '---' horizontal rule → file created (no false-positive integrity error)"
else
  fail "Expected file creation, got rc=$rc, stderr=$(cat "$dir26/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-029: Non-numeric --issue-number → exit 1 (cycle 3 F-09)
# --------------------------------------------------------------------------
echo "TC-029: Non-numeric --issue-number → exit 1"
dir29="$TEST_DIR/tc29"
mkdir -p "$dir29"
echo "x" > "$dir29/body.md"
( cd "$dir29" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md --issue-number "1abc" >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'must be a positive integer' "$dir29/err.log"; then
  pass "Non-numeric issue-number → exit 1"
else
  fail "Expected exit 1, got rc=$rc, stderr=$(cat "$dir29/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-030: --issue-number with newline injection → exit 1 (cycle 3 F-09)
# --------------------------------------------------------------------------
echo "TC-030: --issue-number with embedded newline → exit 1"
dir30="$TEST_DIR/tc30"
mkdir -p "$dir30"
echo "x" > "$dir30/body.md"
( cd "$dir30" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md --issue-number $'1\ningested: true' >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'must be a positive integer' "$dir30/err.log"; then
  pass "Newline in issue-number → exit 1 (injection blocked)"
else
  fail "Expected exit 1, got rc=$rc, stderr=$(cat "$dir30/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-031: wiki.enabled: 0 → exit 2 (cycle 3 F-10)
# --------------------------------------------------------------------------
echo "TC-031: wiki.enabled: 0 → exit 2"
dir31="$TEST_DIR/tc31"
mkdir -p "$dir31"
cat > "$dir31/rite-config.yml" <<'EOF'
wiki:
  enabled: 0
EOF
echo "x" > "$dir31/body.md"
( cd "$dir31" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 2 ] && grep -q 'wiki.enabled is false' "$dir31/err.log"; then
  pass "wiki.enabled: 0 → exit 2"
else
  fail "Expected exit 2, got rc=$rc, stderr=$(cat "$dir31/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-032: wiki.enabled: "false" (quoted) → exit 2 (cycle 3 F-11)
# --------------------------------------------------------------------------
echo "TC-032: wiki.enabled: \"false\" (quoted) → exit 2"
dir32="$TEST_DIR/tc32"
mkdir -p "$dir32"
cat > "$dir32/rite-config.yml" <<'EOF'
wiki:
  enabled: "false"
EOF
echo "x" > "$dir32/body.md"
( cd "$dir32" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 2 ] && grep -q 'wiki.enabled is false' "$dir32/err.log"; then
  pass "wiki.enabled: \"false\" (quoted) → exit 2"
else
  fail "Expected exit 2, got rc=$rc, stderr=$(cat "$dir32/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-027: Truncated file (frontmatter only, body missing) → integrity check exit 3
# F-10 fix: スクリプト経由テストに変更 (awk ロジック複製を廃止)
# --------------------------------------------------------------------------
echo "TC-027: Whitespace-only body → exit 3 via script (integrity check detects no body)"
dir27="$TEST_DIR/tc27"
mkdir -p "$dir27"
cat > "$dir27/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
# Whitespace-only content: trigger.sh の -s check は通るが、
# 書き込み後の awk integrity check では NF>0 の行がないため body_seen=0 → exit 3
printf '\n \n\n' > "$dir27/whitespace-only.md"
( cd "$dir27" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file whitespace-only.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 3 ] && grep -q 'integrity check failed' "$dir27/err.log"; then
  pass "Whitespace-only body → exit 3 via script integrity check"
else
  fail "Expected exit 3 with 'integrity check failed', got rc=$rc, stderr=$(cat "$dir27/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-028: Valid file with body → exit 0 (integrity check passes via script)
# F-10 fix: スクリプト経由テストに変更
# --------------------------------------------------------------------------
echo "TC-028: Valid file → exit 0 via script (integrity check passes)"
dir28="$TEST_DIR/tc28"
mkdir -p "$dir28"
cat > "$dir28/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
printf 'Body content here\n' > "$dir28/body.md"
( cd "$dir28" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
# cycle 6 fix: exit code だけでなくファイル存在も検証 (integrity check 専用テストの深度改善)
target_path28=$(cat "$dir28/out.log" 2>/dev/null | tr -d '[:space:]' || true)
if [ $rc -eq 0 ] && [ -n "$target_path28" ] && [ -f "$dir28/$target_path28" ]; then
  pass "Valid file (body present) → exit 0 + file exists (integrity check passed)"
else
  fail "Expected exit 0 + file exists, got rc=$rc, path='$target_path28', stderr=$(cat "$dir28/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-033: Symlink content-file → exit 1 (F-07/F-16 security)
# --------------------------------------------------------------------------
echo "TC-033: Symlink --content-file → exit 1"
dir33="$TEST_DIR/tc33"
mkdir -p "$dir33"
cat > "$dir33/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
echo "real content" > "$dir33/real.md"
ln -s "$dir33/real.md" "$dir33/link.md"
( cd "$dir33" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file link.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'is a symlink' "$dir33/err.log"; then
  pass "Symlink content-file → exit 1 (rejected for security)"
else
  fail "Expected exit 1 with 'is a symlink', got rc=$rc, stderr=$(cat "$dir33/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-034: Content-file outside $PWD → exit 1 (F-08/F-16 path containment)
# --------------------------------------------------------------------------
echo "TC-034: Content-file outside \$PWD → exit 1"
dir34="$TEST_DIR/tc34"
mkdir -p "$dir34"
cat > "$dir34/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
# Create a file outside $PWD (in a sibling temp dir)
outside_dir=$(mktemp -d)
echo "outside content" > "$outside_dir/outside.md"
( cd "$dir34" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file "$outside_dir/outside.md" >/dev/null 2>err.log ) && rc=0 || rc=$?
rm -rf "$outside_dir"
if [ $rc -eq 1 ] && grep -qE 'must be under.*rite' "$dir34/err.log"; then
  pass "Content-file outside \$PWD → exit 1 (path containment enforced)"
else
  fail "Expected exit 1 with 'must be under', got rc=$rc, stderr=$(cat "$dir34/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-034b: symlink component in $PWD + regular content-file → exit 0 (#2012)
# --------------------------------------------------------------------------
echo "TC-034b: symlink component in \$PWD + regular content-file → exit 0"
dir34b_real="$TEST_DIR/tc34b-real"
dir34b_link="$TEST_DIR/tc34b-link"
mkdir -p "$dir34b_real"
ln -s "$dir34b_real" "$dir34b_link"
cat > "$dir34b_real/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
echo "content below logical cwd" > "$dir34b_real/body.md"
( cd -L "$dir34b_link" && bash "$HOOK" --type reviews --source-ref pr-2012 --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 0 ]; then
  target_path34b=$(tr -d '[:space:]' < "$dir34b_real/out.log")
  if [ -n "$target_path34b" ] && [ -f "$dir34b_real/$target_path34b" ]; then
    pass "Canonical content path is accepted below symlinked \$PWD"
  else
    fail "Symlinked \$PWD → rc=0 but output file not found (path='$target_path34b')"
  fi
else
  fail "Expected rc=0 below symlinked \$PWD, got rc=$rc, stderr=$(cat "$dir34b_real/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-035: Control character in --source-ref → exit 1 (F-14)
# --------------------------------------------------------------------------
echo "TC-035: Control character in --source-ref → exit 1"
dir35="$TEST_DIR/tc35"
mkdir -p "$dir35"
echo "x" > "$dir35/body.md"
( cd "$dir35" && bash "$HOOK" --type reviews --source-ref $'pr-1\x01injected' --content-file body.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'control characters' "$dir35/err.log"; then
  pass "Control character in source-ref → exit 1"
else
  fail "Expected exit 1 with 'control characters', got rc=$rc, stderr=$(cat "$dir35/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-036: No rite-config.yml → lenient pass (F-04 config absent test)
# --------------------------------------------------------------------------
echo "TC-036: No rite-config.yml → lenient pass (rc=0)"
dir36="$TEST_DIR/tc36"
mkdir -p "$dir36"
echo "body" > "$dir36/body.md"
# Deliberately do NOT create rite-config.yml
( cd "$dir36" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 0 ]; then
  # cycle 7 fix: exit code だけでなくファイル存在も検証 (TC-023/TC-025/TC-028 と同パターン)
  target_path36=$(cat "$dir36/out.log" | tr -d '[:space:]')
  if [ -n "$target_path36" ] && [ -f "$dir36/$target_path36" ]; then
    pass "No rite-config.yml → lenient pass (rc=0 + file exists)"
  else
    fail "No rite-config.yml → rc=0 but output file not found (path='$target_path36')"
  fi
else
  fail "Expected rc=0 (lenient), got rc=$rc, stderr=$(cat "$dir36/err.log")"
fi
echo ""

# ==========================================================================
# Phase: regression — /tmp/rite-* prefix と mktemp デフォルト pitfall
#        + $TMPDIR/rite-* arm (sandbox 対応)
# ==========================================================================

# /tmp 外ファイルの明示 cleanup (review F-04: TEST_DIR 外は main cleanup() の対象外)
# TC-036a/b は wiki-ingest-trigger.sh のパス検証が /tmp/rite-* prefix と mktemp デフォルトを
# 正しく区別することを test するため、$TEST_DIR 内ではなく /tmp 直下にファイルを作る必要がある。
# main trap cleanup は $TEST_DIR しか掃除しないため、個別 trap で追跡する。
_rite_issue518_tmps=()
_rite_issue518_cleanup() {
  if [ ${#_rite_issue518_tmps[@]} -gt 0 ]; then
    rm -f "${_rite_issue518_tmps[@]}"
  fi
}
# main cleanup に chain する (既存 trap は cleanup() を呼ぶので、本 trap は issue518 専用ファイルのみ削除)
trap '_rite_issue518_cleanup; cleanup' EXIT

# --------------------------------------------------------------------------
# TC-036a: Content-file in /tmp/rite-* prefix → exit 0 (正常系 / fix)
# --------------------------------------------------------------------------
# pr/pr-review.md / pr/fix.md / issue/close.md は wiki-ingest-trigger.sh を
# 呼ぶときに tmpfile=$(mktemp /tmp/rite-wiki-content-XXXXXX) でファイル生成する必要がある。
# この TC は /tmp/rite-* prefix でのファイルが正常に受容され、fix が正しく動作することを保証する。
# NOTE: content-file の /tmp/rite-* literal は被テスト hook の path-containment allowlist
# ($PWD/* | /tmp/rite-* | /private/tmp/rite-*) に一致させる load-bearing fixture であり、
# ${TMPDIR:-/tmp} 化してはならない (TMPDIR≠/tmp の環境で hook が正しく拒否し偽 FAIL する)。
# /tmp 直下が書込不可な環境では本 TC は検証不能。CI (blocking gate) では floor として
# fail し、それ以外の環境では明示 skip する。
echo "TC-036a: Content-file in /tmp/rite-* prefix → exit 0 (regression)"
if _probe36a=$(mktemp /tmp/rite-probe-XXXXXX 2>/dev/null); then
  rm -f "$_probe36a"
  dir36a="$TEST_DIR/tc36a"
  mkdir -p "$dir36a"
  cat > "$dir36a/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
  # Create content-file using /tmp/rite-* prefix (pr-review.md / fix.md / close.md と同パターン)
  tmp_in_rite=$(mktemp /tmp/rite-wiki-content-XXXXXX)
  _rite_issue518_tmps+=("$tmp_in_rite")
  echo "review body" > "$tmp_in_rite"
  ( cd "$dir36a" && bash "$HOOK" --type reviews --source-ref pr-518 --content-file "$tmp_in_rite" > out.log 2>err.log ) && rc=0 || rc=$?
  if [ $rc -eq 0 ]; then
    # review F-06: tr -d [:space:] は stdout 多行時に path を連結してしまう。先頭行のみ取る
    target_path36a=$(head -1 "$dir36a/out.log" | tr -d '[:space:]')
    if [ -n "$target_path36a" ] && [ -f "$dir36a/$target_path36a" ]; then
      pass "/tmp/rite-* prefix content-file → exit 0 + raw file created"
    else
      fail "/tmp/rite-* prefix → rc=0 but output file not found (path='$target_path36a')"
    fi
  else
    fail "Expected rc=0 for /tmp/rite-* prefix, got rc=$rc, stderr=$(cat "$dir36a/err.log")"
  fi
elif [ -n "${CI:-}" ] && [ -d /proc ]; then
  # Floor: writability of /tmp is a capability probe, not a platform fact, so the
  # gate has to name the environment where that capability is actually guaranteed
  # — the Linux CI leg, which ci.yml designates the blocking gate (macOS runs
  # informational). "Any Linux" is too wide a stand-in: a developer machine whose
  # sandbox mounts /tmp read-only is Linux too, and a permanent red there is noise
  # that masks real regressions rather than signal. On the blocking gate a
  # non-writable /tmp does mean the environment was constrained, not that the
  # platform cannot do this — skipping there would drop the only coverage of the
  # hook's /tmp/rite-* allowlist arm while the run stays green. `$CI` is what
  # GitHub Actions sets; `[ -d /proc ]` rather than `uname -s`, which resolves
  # through the same PATH.
  fail "TC-036a floor: /tmp is not writable on the Linux blocking gate (CI) — the /tmp/rite-* prefix acceptance must never be skipped there"
else
  skip "TC-036a — /tmp 直下が書込不可 (sandbox 環境等) のため /tmp/rite-* prefix 受容を検証できません (CI では floor として fail する)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-036b: Content-file from mktemp default → exit 1 (pitfall lock)
# --------------------------------------------------------------------------
# 根本原因の再現テスト: `mktemp` をデフォルト引数で呼ぶと /tmp/tmp.XXXXXXX が
# 生成され、wiki-ingest-trigger.sh のパス検証 ($PWD 配下 or /tmp/rite-* prefix) で拒否される。
# 本 TC は、将来 commands/*.md が mktemp デフォルトに戻った場合に fix ループの回帰テストとして
# exit code で pitfall を検出する。
#
# review F-03: `grep -qE 'must be under.*rite'` でエラー文言の literal に依存すると、
# 文言を i18n / reword した瞬間に silent fail する設計欠陥が生じる。assertion を 2 段階にし、
# exit code (1) を必須 pass 条件とし、文言 grep は OR パターンで緩和する (defense-in-depth)。
echo "TC-036b: Content-file from mktemp default → exit 1 (pitfall)"
dir36b="$TEST_DIR/tc36b"
mkdir -p "$dir36b"
cat > "$dir36b/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
tmp_default=$(mktemp)
_rite_issue518_tmps+=("$tmp_default")
echo "x" > "$tmp_default"
( cd "$dir36b" && bash "$HOOK" --type reviews --source-ref pr-518 --content-file "$tmp_default" >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ]; then
  # 補助 grep は dead assertion を避けるため、else 分岐を fail にする (F-08 対応)。
  # OR pattern は rite-ingest-trigger.sh の実エラー文言 (`--content-file must be under $PWD or /tmp/rite-*`)
  # に固有な substring のみに絞る (F-10 対応: 旧 `rite` 単独 token は path 混入で誤 match しやすい)。
  if grep -qiE 'must be under|/tmp/rite-' "$dir36b/err.log"; then
    pass "mktemp default (/tmp/tmp.*) → exit 1 + pitfall エラー文言検出"
  else
    fail "exit 1 は正しいが pitfall 拒否文言が stderr にない: $(cat "$dir36b/err.log")"
  fi
else
  fail "Expected exit 1 for mktemp default, got rc=$rc, stderr=$(cat "$dir36b/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-036c: Content-file in $TMPDIR/rite-* → exit 0 (sandbox arm)
# --------------------------------------------------------------------------
# sandbox 有効環境では /tmp 直下が読み込み専用のため、caller は
# mktemp "${TMPDIR:-/tmp}/rite-...-XXXXXX" で $TMPDIR 配下に content-file を作る。
# 本 TC は realpath 解決後の $TMPDIR/rite-* 受理 arm (正例) を pin する。
# content-file は $PWD 外・/tmp/rite-* 外に置き、新 arm だけが受理経路になるようにする。
echo "TC-036c: Content-file in \$TMPDIR/rite-* → exit 0 (sandbox arm)"
dir36c="$TEST_DIR/tc36c"
mkdir -p "$dir36c"
cat > "$dir36c/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
tmpdir36c=$(mktemp -d)
echo "review body" > "$tmpdir36c/rite-content-1904.md"
( cd "$dir36c" && TMPDIR="$tmpdir36c" bash "$HOOK" --type reviews --source-ref pr-1904 --content-file "$tmpdir36c/rite-content-1904.md" > out.log 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 0 ]; then
  target_path36c=$(head -1 "$dir36c/out.log" | tr -d '[:space:]')
  if [ -n "$target_path36c" ] && [ -f "$dir36c/$target_path36c" ]; then
    pass "\$TMPDIR/rite-* content-file → exit 0 + raw file created"
  else
    fail "\$TMPDIR/rite-* → rc=0 but output file not found (path='$target_path36c')"
  fi
else
  fail "Expected rc=0 for \$TMPDIR/rite-* arm, got rc=$rc, stderr=$(cat "$dir36c/err.log")"
fi
rm -rf "$tmpdir36c"
echo ""

# --------------------------------------------------------------------------
# TC-036d: Content-file in $TMPDIR but not rite-* prefix → exit 1 (負例)
# --------------------------------------------------------------------------
# 新 arm は $TMPDIR 全体を開けるのではなく rite-* namespace に限定する。
# prefix 制約が落ちると任意の $TMPDIR ファイルが wiki 公開経路に乗るため、
# 負例で prefix-glob (`${resolved_tmpdir%/}"/rite-*`) の縮小を pin する。
echo "TC-036d: Content-file in \$TMPDIR without rite-* prefix → exit 1"
dir36d="$TEST_DIR/tc36d"
mkdir -p "$dir36d"
cat > "$dir36d/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
tmpdir36d=$(mktemp -d)
echo "x" > "$tmpdir36d/other-content.md"
( cd "$dir36d" && TMPDIR="$tmpdir36d" bash "$HOOK" --type reviews --source-ref pr-1904 --content-file "$tmpdir36d/other-content.md" >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'must be under' "$dir36d/err.log"; then
  pass "\$TMPDIR non-rite file → exit 1 (prefix constraint enforced)"
else
  fail "Expected exit 1 with 'must be under', got rc=$rc, stderr=$(cat "$dir36d/err.log")"
fi
rm -rf "$tmpdir36d"
echo ""

# --------------------------------------------------------------------------
# TC-036e: TMPDIR realpath 失敗 → arm 無効化 (fail-closed) + WARNING + exit 1
# --------------------------------------------------------------------------
# TMPDIR が解決不能なとき arm は silent に開かず縮小方向に倒れる (fail-closed)。
# 同時に診断 WARNING (`$TMPDIR/rite-* arm disabled`) を stderr へ残す契約を pin する
# (WARNING が消えると rejection message の「$TMPDIR/rite-* も受容」が誤誘導になる)。
echo "TC-036e: TMPDIR realpath failure → arm disabled + WARNING + exit 1"
dir36e="$TEST_DIR/tc36e"
mkdir -p "$dir36e"
cat > "$dir36e/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
tmpdir36e=$(mktemp -d)
echo "x" > "$tmpdir36e/rite-content-1904.md"
( cd "$dir36e" && TMPDIR="/nonexistent/rite-tmpdir-1904" bash "$HOOK" --type reviews --source-ref pr-1904 --content-file "$tmpdir36e/rite-content-1904.md" >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] \
   && grep -q 'arm disabled' "$dir36e/err.log" \
   && grep -q 'must be under' "$dir36e/err.log"; then
  pass "unresolvable TMPDIR → fail-closed reject + diagnostic WARNING"
else
  fail "Expected exit 1 with 'arm disabled' WARNING + rejection, got rc=$rc, stderr=$(cat "$dir36e/err.log")"
fi
rm -rf "$tmpdir36e"
echo ""

# ==========================================================================
# Phase: オプション値なし末尾テスト (TC-037 〜 TC-039)
# cycle 8 F-06 fix: $# -ge 2 ガードの検証
# ==========================================================================

# --------------------------------------------------------------------------
# TC-037: --type without value at end → exit 1 + "requires a value"
# --------------------------------------------------------------------------
echo "TC-037: --type without value at end → exit 1"
output=$(bash "$HOOK" --type 2>&1) && rc=0 || rc=$?
if [ $rc -eq 1 ] && echo "$output" | grep -q "requires a value"; then
  pass "--type without value exits 1 with requires a value"
else
  fail "Expected exit 1 + 'requires a value', got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-038: --source-ref without value at end → exit 1 + "requires a value"
# --------------------------------------------------------------------------
echo "TC-038: --source-ref without value at end → exit 1"
output=$(bash "$HOOK" --source-ref 2>&1) && rc=0 || rc=$?
if [ $rc -eq 1 ] && echo "$output" | grep -q "requires a value"; then
  pass "--source-ref without value exits 1 with requires a value"
else
  fail "Expected exit 1 + 'requires a value', got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-039: --content-file without value at end → exit 1 + "requires a value"
# --------------------------------------------------------------------------
echo "TC-039: --content-file without value at end → exit 1"
output=$(bash "$HOOK" --content-file 2>&1) && rc=0 || rc=$?
if [ $rc -eq 1 ] && echo "$output" | grep -q "requires a value"; then
  pass "--content-file without value exits 1 with requires a value"
else
  fail "Expected exit 1 + 'requires a value', got rc=$rc output=$output"
fi
echo ""

# ==========================================================================
# Phase: filesystem write failure テスト (TC-040 〜 TC-041)
# cycle 8 F-07 fix: exit 3 パスの検証
# ==========================================================================

# --------------------------------------------------------------------------
# TC-040: mkdir -p failure (read-only directory) → exit 3
# --------------------------------------------------------------------------
echo "TC-040: mkdir failure (read-only .rite/wiki/raw) → exit 3"
dir40="$TEST_DIR/tc040"
mkdir -p "$dir40"
git -C "$dir40" init -q
echo "body content" > "$dir40/body.md"
cat > "$dir40/rite-config.yml" << 'EOF'
wiki:
  enabled: true
EOF
# Create .rite but make it read-only so mkdir -p for raw/reviews fails
mkdir -p "$dir40/.rite"
chmod 444 "$dir40/.rite"
( cd "$dir40" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
chmod 755 "$dir40/.rite"  # restore for cleanup
if [ $rc -eq 3 ]; then
  pass "Read-only .rite directory → exit 3"
else
  fail "Expected exit 3 for mkdir failure, got rc=$rc, stderr=$(cat "$dir40/err.log" 2>/dev/null)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-041: cat write failure (read-only target dir) → exit 3
# --------------------------------------------------------------------------
echo "TC-041: cat write failure (read-only target dir) → exit 3"
dir41="$TEST_DIR/tc041"
mkdir -p "$dir41"
git -C "$dir41" init -q
echo "body content" > "$dir41/body.md"
cat > "$dir41/rite-config.yml" << 'EOF'
wiki:
  enabled: true
EOF
# Create the target directory but make it read-only
mkdir -p "$dir41/.rite/wiki/raw/reviews"
chmod 444 "$dir41/.rite/wiki/raw/reviews"
( cd "$dir41" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
chmod 755 "$dir41/.rite/wiki/raw/reviews"  # restore for cleanup
if [ $rc -eq 3 ]; then
  pass "Read-only target dir → exit 3 (cat write failure)"
else
  fail "Expected exit 3 for cat write failure, got rc=$rc, stderr=$(cat "$dir41/err.log" 2>/dev/null)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-042: Partial-write rollback verification (cycle 10 CRITICAL-3 fix)
# Verifies that after integrity check exit 3, target_file is auto-removed
# by the rollback trap (no orphan truncated file left for next ingest cycle).
# --------------------------------------------------------------------------
echo "TC-042: Partial-write rollback trap auto-removes target_file on exit 3"
dir42="$TEST_DIR/tc42"
mkdir -p "$dir42"
cat > "$dir42/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
# Reuse TC-027 trigger: whitespace-only body fires integrity check exit 3 after
# target_file has been created (body truncated). Without rollback the file persists.
printf '\n \n\n' > "$dir42/whitespace-only.md"
( cd "$dir42" && bash "$HOOK" --type reviews --source-ref pr-rollback --content-file whitespace-only.md >/dev/null 2>err.log ) && rc=0 || rc=$?
# Assert exit 3 (integrity check failure path)
if [ $rc -ne 3 ]; then
  fail "Expected exit 3 (integrity check), got rc=$rc, stderr=$(cat "$dir42/err.log")"
else
  # Post-condition: target_file must be removed by rollback trap
  remaining_count=$(find "$dir42/.rite/wiki/raw/reviews" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "${remaining_count:-0}" -ne 0 ]; then
    fail "Rollback trap did not remove target_file: found $remaining_count residual .md file(s) in raw/reviews/"
  elif ! grep -q 'partial-write rollback' "$dir42/err.log"; then
    fail "Rollback trap fired but INFO message 'partial-write rollback により' is missing from stderr"
  else
    pass "exit 3 + rollback removed target_file + INFO message emitted"
  fi
fi
echo ""

# --------------------------------------------------------------------------
# Safe-default exit 2 on config parse failure (chmod 000 / awk error). A lenient
# fallback here would silently treat the user's `wiki.enabled: false` as enabled
# and leak raw sources — the whole reason for the strict exit 2 contract.
# --------------------------------------------------------------------------

echo "[TC-043] chmod 000 rite-config.yml → sed extraction fail → exit 2"
dir43=$(mktemp -d "${TMPDIR:-/tmp}/rite-wiki-test-tc043-XXXXXX")
cat > "$dir43/rite-config.yml" <<EOF
wiki:
  enabled: true
EOF
chmod 000 "$dir43/rite-config.yml"
echo "content for tc043" > "$dir43/content.md"
( cd "$dir43" && bash "$HOOK" --type reviews --source-ref pr-tc043 --content-file content.md >/dev/null 2>err.log ) && rc=0 || rc=$?
chmod 644 "$dir43/rite-config.yml" 2>/dev/null || true
if [ "$rc" -ne 2 ]; then
  fail "TC-043 expected exit 2 (safe-default), got rc=$rc, stderr=$(cat "$dir43/err.log" 2>/dev/null)"
elif ! grep -qE 'sed|ERROR|safe-default' "$dir43/err.log" 2>/dev/null; then
  fail "TC-043 exit 2 returned but ERROR/safe-default message missing from stderr"
elif [ -d "$dir43/.rite/wiki/raw/reviews" ] && [ "$(find "$dir43/.rite/wiki/raw/reviews" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')" -ne 0 ]; then
  fail "TC-043 raw source created despite safe-default exit (silent policy violation)"
else
  pass "TC-043 chmod 000 → exit 2 + ERROR message + raw not created"
fi
rm -rf "$dir43"
echo ""

echo "[TC-044] binary garbage in wiki section → awk fail → exit 2"
dir44=$(mktemp -d "${TMPDIR:-/tmp}/rite-wiki-test-tc044-XXXXXX")
# NUL byte handling differs by platform, so this case may pass-through the
# tr/sed pipeline. Either outcome is acceptable as long as raw is not silently
# created when the parser bails: that is the invariant the assertion enforces.
printf 'wiki:\n  enabled: \x00bogus\n' > "$dir44/rite-config.yml"
echo "content for tc044" > "$dir44/content.md"
( cd "$dir44" && bash "$HOOK" --type reviews --source-ref pr-tc044 --content-file content.md >/dev/null 2>err.log ) && rc=0 || rc=$?
# Acceptable outcomes:
#   - exit 2 (parse failure detected → safe-default)
#   - exit 0 (NUL stripped successfully and enabled resolved to non-false)
# Unacceptable: silent staging of raw under partial parse failure with no ERROR.
if [ "$rc" -eq 2 ]; then
  pass "TC-044 NUL-injected wiki section → exit 2 (safe-default)"
elif [ "$rc" -eq 0 ]; then
  # Confirm raw was actually created and not silently dropped
  if [ "$(find "$dir44/.rite/wiki/raw/reviews" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ]; then
    pass "TC-044 NUL stripped by tr / sed; raw created normally (exit 0)"
  else
    fail "TC-044 exit 0 but no raw created — silent drop suspected"
  fi
else
  fail "TC-044 unexpected rc=$rc, stderr=$(cat "$dir44/err.log" 2>/dev/null)"
fi
rm -rf "$dir44"
echo ""

echo "[TC-045] wiki.enabled normalization happy path (negative control)"
dir45=$(mktemp -d "${TMPDIR:-/tmp}/rite-wiki-test-tc045-XXXXXX")
# Negative control: ensure the strict guards above don't accidentally break
# the success path. A regression here would mean the safe-default became
# fail-closed for valid configs too.
cat > "$dir45/rite-config.yml" <<EOF
wiki:
  enabled: true
EOF
echo "content for tc045" > "$dir45/content.md"
( cd "$dir45" && bash "$HOOK" --type reviews --source-ref pr-tc045 --content-file content.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "TC-045 happy path failed (rc=$rc) — wiki.enabled: true should succeed"
elif [ "$(find "$dir45/.rite/wiki/raw/reviews" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')" -lt 1 ]; then
  fail "TC-045 happy path succeeded but no raw was created"
else
  pass "TC-045 happy path (wiki.enabled: true) creates raw normally — negative control for #2 guard"
fi
rm -rf "$dir45"
echo ""

echo "[TC-046] wiki.enabled: TRUE (uppercase) → normalize lowercase → exit 0"
# Without `tr '[:upper:]' '[:lower:]'` the uppercase value would land in the
# typo-reject arm and exit 2; the TC pins that the normalization step survives
# future refactors.
dir46=$(mktemp -d "${TMPDIR:-/tmp}/rite-wiki-test-tc046-XXXXXX")
cat > "$dir46/rite-config.yml" <<EOF
wiki:
  enabled: TRUE
EOF
echo "content for tc046" > "$dir46/content.md"
( cd "$dir46" && bash "$HOOK" --type reviews --source-ref pr-tc046 --content-file content.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$(find "$dir46/.rite/wiki/raw/reviews" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ]; then
  pass "TC-046 wiki.enabled: TRUE (uppercase) normalized to lowercase and accepted"
else
  fail "TC-046 uppercase TRUE rejected (rc=$rc) — case normalization broken: $(cat "$dir46/err.log" 2>/dev/null)"
fi
rm -rf "$dir46"
echo ""

echo "[TC-047] wiki.enabled: False (MixedCase) → normalize lowercase → exit 2"
# Symmetric to TC-046 for the false path. A regression that drops the
# normalize step would let MixedCase typos bypass the disable guard.
dir47=$(mktemp -d "${TMPDIR:-/tmp}/rite-wiki-test-tc047-XXXXXX")
cat > "$dir47/rite-config.yml" <<EOF
wiki:
  enabled: False
EOF
echo "content for tc047" > "$dir47/content.md"
( cd "$dir47" && bash "$HOOK" --type reviews --source-ref pr-tc047 --content-file content.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ "$rc" -eq 2 ] && grep -q 'wiki.enabled is false' "$dir47/err.log"; then
  pass "TC-047 wiki.enabled: False (MixedCase) correctly rejected with exit 2"
else
  fail "TC-047 expected exit 2 with 'wiki.enabled is false', got rc=$rc: $(cat "$dir47/err.log" 2>/dev/null)"
fi
rm -rf "$dir47"
echo ""

echo "[TC-048] wiki.enabled: tru (typo) → exit 2 + recognised-boolean WARNING"
# The typo-reject arm (`*)` in the case statement) is the security-net for
# silent typo-induced enable. Without this TC, future refactors could weaken
# the arm to no-op and the safety net would vanish silently.
dir48=$(mktemp -d "${TMPDIR:-/tmp}/rite-wiki-test-tc048-XXXXXX")
cat > "$dir48/rite-config.yml" <<EOF
wiki:
  enabled: tru
EOF
echo "content for tc048" > "$dir48/content.md"
( cd "$dir48" && bash "$HOOK" --type reviews --source-ref pr-tc048 --content-file content.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ "$rc" -eq 2 ] && grep -q 'not a recognised boolean' "$dir48/err.log"; then
  pass "TC-048 typo 'tru' rejected with 'not a recognised boolean' WARNING"
else
  fail "TC-048 expected exit 2 with typo warning, got rc=$rc: $(cat "$dir48/err.log" 2>/dev/null)"
fi
rm -rf "$dir48"
echo ""

# --------------------------------------------------------------------------
# TC-049: C1 8-bit byte (0x9b CSI) in --source-ref → exit 1
# --------------------------------------------------------------------------
# 旧 `=~ [[:cntrl:]]` は glibc が C1 (0x80-0x9f) を cntrl と分類しないため
# 0x9b 入り SOURCE_REF が validation を素通りしていた (TC-017 の newline pin と
# 対になる C1 側 pin)。contains_ctrl (control-char-neutralize.sh) への置換で
# reject されることを確認する。
echo "TC-049: C1 0x9b in --source-ref → exit 1"
dir49="$TEST_DIR/tc49"
mkdir -p "$dir49"
echo "x" > "$dir49/body.md"
( cd "$dir49" && bash "$HOOK" --type reviews --source-ref $'pr-1\x9bcsi' --content-file body.md >/dev/null 2>err.log ) && rc=0 || rc=$?
if [ $rc -eq 1 ] && grep -q 'control characters' "$dir49/err.log"; then
  pass "C1 0x9b in source-ref → exit 1 (formerly slipped through [[:cntrl:]])"
else
  fail "Expected exit 1 'control characters', got rc=$rc, stderr=$(cat "$dir49/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-050: Japanese UTF-8 title whose continuation bytes overlap C1 → exit 0
# --------------------------------------------------------------------------
# 静 (E9 9D 99) / 的 (E7 9A 84) の UTF-8 継続バイトは 0x80-0x9f と
# 重なる。TITLE は human-readable text なので C0 + DEL だけを拒否する。
echo "TC-050: Japanese UTF-8 in --title → exit 0"
dir50="$TEST_DIR/tc50"
mkdir -p "$dir50"
echo "x" > "$dir50/body.md"
( cd "$dir50" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md --title '静的 pin' >out.log 2>err.log ) && rc=0 || rc=$?
target_path50=$(cat "$dir50/out.log" 2>/dev/null || true)
if [ $rc -eq 0 ] && [ -f "$dir50/$target_path50" ] && grep -q '^title: "静的 pin"$' "$dir50/$target_path50"; then
  pass "Japanese UTF-8 title → exit 0 + title preserved"
else
  fail "Expected Japanese title to succeed and be preserved, got rc=$rc, stderr=$(cat "$dir50/err.log")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-050b: C0 controls in --title remain rejected
# --------------------------------------------------------------------------
echo "TC-050b: C0 controls in --title → exit 1"
for control_name in tab soh; do
  dir50b="$TEST_DIR/tc50b-$control_name"
  mkdir -p "$dir50b"
  echo "x" > "$dir50b/body.md"
  if [ "$control_name" = tab ]; then bad_title=$'foo\tbar'; else bad_title=$'foo\x01bar'; fi
  ( cd "$dir50b" && bash "$HOOK" --type reviews --source-ref pr-1 --content-file body.md --title "$bad_title" >/dev/null 2>err.log ) && rc=0 || rc=$?
  if [ $rc -eq 1 ] && grep -q 'control characters' "$dir50b/err.log"; then
    pass "$control_name in title → exit 1"
  else
    fail "Expected $control_name in title to be rejected, got rc=$rc, stderr=$(cat "$dir50b/err.log")"
  fi
done
echo ""

# ==========================================================================
# Phase: STATE_ROOT write anchoring — TC-051 〜 TC-053
# trigger は raw を state-path-resolve ルート (linked worktree では main
# checkout) 配下へ書く。wiki-ingest-commit.sh の scan ルートと一致させ、
# multi-session worktree からの起動で raw が silent に取りこぼされる回帰を防ぐ。
# ==========================================================================

# --------------------------------------------------------------------------
# TC-051: linked worktree から起動 → raw は main checkout 配下へ着地 (AC-1)
#         かつ redirect の検知可能シグナル (NOTE) を stderr に emit する
# --------------------------------------------------------------------------
echo "TC-051: linked worktree 起動 → raw は main checkout の .rite/wiki/raw/ へ + NOTE"
dir51="$TEST_DIR/tc51"
mkdir -p "$dir51"
git -C "$dir51" init -q
# linked worktree add には最低 1 commit が必要 (unborn branch からは add 不可)
git -C "$dir51" -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init
cat > "$dir51/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
wt51="$dir51/session-wt"
# worktree add の失敗は握り潰さない (set -euo pipefail 下で 2>&1 抑制すると、add 失敗時に
# 原因不明のままスイート全体が silent abort する)。stderr を log に退避し if で明示判定する。
if git -C "$dir51" worktree add -q "$wt51" -b wt-issue-1664 2>"$dir51/wt-add-err.log"; then
  echo "Review body in worktree" > "$wt51/body.md"
  ( cd "$wt51" && bash "$HOOK" \
    --type reviews \
    --source-ref pr-1664 \
    --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
  target_path="$(cat "$wt51/out.log" 2>/dev/null | tr -d '[:space:]' || true)"
  # 期待: rc=0、相対パスのまま、main checkout 側に着地 + body 内容が捕捉されている、
  # worktree 側には未着地、NOTE 出力。body grep は本バグの本質 (content の silent drop) を
  # 直接検証する — cd リダイレクト後も worktree の content が正しく書かれたことを確認する
  # (TC-010/TC-011 の body grep 規約に揃える)。
  if [ $rc -eq 0 ] && \
     echo "$target_path" | grep -q '^\.rite/wiki/raw/reviews/' && \
     [ -f "$dir51/$target_path" ] && \
     grep -q 'Review body in worktree' "$dir51/$target_path" && \
     [ ! -e "$wt51/.rite/wiki/raw" ] && \
     grep -q 'NOTE:' "$wt51/err.log"; then
    pass "linked worktree 起動 → raw が main checkout へ着地 + body 内容捕捉 + 相対パス維持 + NOTE シグナル"
  else
    fail "Expected raw under main checkout ($dir51) not worktree ($wt51) with body content and NOTE, got path='$target_path' rc=$rc; worktree raw exists=$([ -e "$wt51/.rite/wiki/raw" ] && echo yes || echo no); stderr=$(cat "$wt51/err.log" 2>/dev/null)"
  fi
  # cleanup worktree registration (TEST_DIR rm でも消えるが prune しておく)
  git -C "$dir51" worktree remove --force "$wt51" >/dev/null 2>&1 || true
else
  fail "TC-051 setup: git worktree add が失敗しました: $(head -3 "$dir51/wt-add-err.log" 2>/dev/null)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-052: git root から起動 (単一セッション) → 挙動不変・NOTE なし (AC-2)
# --------------------------------------------------------------------------
echo "TC-052: git root 起動 → 相対パス維持・NOTE 非出力 (非回帰)"
dir52="$TEST_DIR/tc52"
mkdir -p "$dir52"
git -C "$dir52" init -q
cat > "$dir52/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
echo "Review body at root" > "$dir52/body.md"
( cd "$dir52" && bash "$HOOK" \
  --type reviews \
  --source-ref pr-root \
  --content-file body.md > out.log 2>err.log ) && rc=0 || rc=$?
target_path="$(cat "$dir52/out.log" 2>/dev/null | tr -d '[:space:]' || true)"
# STATE_ROOT == $PWD == git root → cd は no-op、NOTE は出さない。body grep で
# 単一セッション時も content が正しく書かれることを確認 (TC-051 と対称)。
if [ $rc -eq 0 ] && \
   echo "$target_path" | grep -q '^\.rite/wiki/raw/reviews/' && \
   [ -f "$dir52/$target_path" ] && \
   grep -q 'Review body at root' "$dir52/$target_path" && \
   ! grep -q 'NOTE:' "$dir52/err.log"; then
  pass "git root 起動 → raw が root へ着地 + body 内容捕捉 + 相対パス維持 + NOTE 非出力 (AC-2 非回帰)"
else
  fail "Expected raw at root with body content, relative path and NO NOTE, got path='$target_path' rc=$rc; stderr=$(cat "$dir52/err.log" 2>/dev/null)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-053: linked worktree から起動しても path containment ガードが維持される (AC-3)
#         worktree 起動 (STATE_ROOT != $PWD で cd が実走) の経路でも、ガードは cd の
#         前に元 $PWD 基準で評価されるため、$PWD 外 / 非 /tmp-rite の content-file は
#         従来どおり reject される。既存 TC-033/034/036 は git root (非 worktree) 起動
#         The previous fixture covered only the repository-root path, so、worktree 起動経路の AC-3 を本 TC で pin する。
# --------------------------------------------------------------------------
echo "TC-053: linked worktree 起動 + content-file が \$PWD 外 → exit 1 (AC-3 path containment 維持)"
dir53="$TEST_DIR/tc53"
mkdir -p "$dir53"
git -C "$dir53" init -q
git -C "$dir53" -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init
cat > "$dir53/rite-config.yml" <<'EOF'
wiki:
  enabled: true
EOF
# worktree の外 (main checkout 直下) に content-file を置く。worktree から見ると $PWD 外。
echo "outside worktree pwd" > "$dir53/outside-body.md"
wt53="$dir53/session-wt"
if git -C "$dir53" worktree add -q "$wt53" -b wt-issue-1664-ac3 2>"$dir53/wt-add-err.log"; then
  # worktree ($wt53) から、$PWD 外かつ非 /tmp-rite の content-file を相対パスで渡す。
  ( cd "$wt53" && bash "$HOOK" \
    --type reviews \
    --source-ref pr-ac3 \
    --content-file ../outside-body.md > out.log 2>err.log ) && rc=0 || rc=$?
  # 期待: exit 1 (path containment reject)、main checkout 側にも worktree 側にも raw 未生成
  if [ "$rc" -eq 1 ] && \
     grep -q 'must be under' "$wt53/err.log" && \
     [ ! -e "$dir53/.rite/wiki/raw" ] && \
     [ ! -e "$wt53/.rite/wiki/raw" ]; then
    pass "worktree 起動 + \$PWD 外 content-file → exit 1 + raw 未生成 (AC-3 ガード維持)"
  else
    fail "Expected exit 1 with containment rejection and no raw written, got rc=$rc; stderr=$(cat "$wt53/err.log" 2>/dev/null)"
  fi
  git -C "$dir53" worktree remove --force "$wt53" >/dev/null 2>&1 || true
else
  fail "TC-053 setup: git worktree add が失敗しました: $(head -3 "$dir53/wt-add-err.log" 2>/dev/null)"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed$( [ "$SKIP" -gt 0 ] && printf ", %s skipped" "$SKIP" ) ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
