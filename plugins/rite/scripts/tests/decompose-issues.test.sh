#!/bin/bash
# Tests for decompose-issues.sh
# Usage: bash plugins/rite/scripts/tests/decompose-issues.test.sh
#
# Strategy: decompose-issues.sh is an orchestrator over three sibling helpers
# (create-issue-with-projects.sh / link-sub-issue.sh / hooks/issue-body-safe-update.sh),
# each of which has its own correctness tests. Here we test the ORCHESTRATION
# contract — marker fidelity, created/failed/link_failures counting, the guards,
# fetch_output passthrough, workdir cleanup, and exit codes — by running the real
# script (symlinked into a sandbox) against deterministic STUB siblings. No gh
# dependency, fully hermetic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$(cd "$SCRIPT_DIR/.." && pwd)/decompose-issues.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# --- Build sandbox: real script (symlinked) + stub siblings ---
SANDBOX="$TEST_DIR/sandbox"
mkdir -p "$SANDBOX/scripts" "$SANDBOX/hooks"
ln -s "$TARGET" "$SANDBOX/scripts/decompose-issues.sh"
DECOMPOSE="$SANDBOX/scripts/decompose-issues.sh"

# Stub: create-issue-with-projects.sh
# - Emits a monotonically increasing issue_number from STUB_NUM_FILE.
# - Fails (exit 1) when title == STUB_CREATE_FAIL_TITLE.
# - Logs "title=<t> labels=<l>" to STUB_CREATE_LOG for label assertions.
cat > "$SANDBOX/scripts/create-issue-with-projects.sh" <<'STUB_CREATE'
#!/bin/bash
set -euo pipefail
payload="${1:-}"
[ -z "$payload" ] && payload="$(cat)"
title=$(printf '%s' "$payload" | jq -r '.issue.title')
labels=$(printf '%s' "$payload" | jq -rc '.issue.labels')
[ -n "${STUB_CREATE_LOG:-}" ] && printf 'title=%s labels=%s\n' "$title" "$labels" >> "$STUB_CREATE_LOG"
if [ -n "${STUB_CREATE_FAIL_TITLE:-}" ] && [ "$title" = "$STUB_CREATE_FAIL_TITLE" ]; then
  echo "stub: forced create failure for $title" >&2
  exit 1
fi
n=$(cat "$STUB_NUM_FILE")
echo "$((n + 1))" > "$STUB_NUM_FILE"
# Partial-Projects mode: emit `ERROR: ...` on stderr
# AND a valid JSON (with issue_number + warnings) on stdout, then exit 0. A caller
# that captures with `2>&1` would splice the ERROR ahead of the JSON and break the
# downstream `jq -r .issue_number`, miscounting this created sub as failed.
if [ -n "${STUB_CREATE_PARTIAL_TITLE:-}" ] && [ "$title" = "$STUB_CREATE_PARTIAL_TITLE" ]; then
  printf 'ERROR: Projects registration failed: stub partial for %s\n' "$title" >&2
  jq -n --argjson num "$n" '{issue_number:$num, issue_url:("https://example/\($num)"), project_registration:"failed", warnings:["stub partial projects warning"]}'
  exit 0
fi
jq -n --argjson num "$n" '{issue_number:$num, issue_url:("https://example/\($num)"), project_registration:"ok", warnings:[]}'
STUB_CREATE

# Stub: link-sub-issue.sh
# - Returns status="ok" normally; status="failed" (exit 0, non-blocking) when
#   child == STUB_LINK_FAIL_CHILD.
cat > "$SANDBOX/scripts/link-sub-issue.sh" <<'STUB_LINK'
#!/bin/bash
set -euo pipefail
owner="$1"; repo="$2"; parent="$3"; child="$4"
[ -n "${STUB_LINK_LOG:-}" ] && printf 'link %s/%s %s<-%s\n' "$owner" "$repo" "$parent" "$child" >> "$STUB_LINK_LOG"
if [ -n "${STUB_LINK_FAIL_CHILD:-}" ] && [ "$child" = "$STUB_LINK_FAIL_CHILD" ]; then
  jq -n --argjson p "$parent" --argjson c "$child" '{status:"failed", parent:$p, child:$c, message:"mock link fail", warnings:["mock link warning"]}'
  exit 0
fi
jq -n --argjson p "$parent" --argjson c "$child" '{status:"ok", parent:$p, child:$c, message:("linked #\($c) -> #\($p)"), warnings:[]}'
STUB_LINK

# Stub: hooks/issue-body-safe-update.sh (only the `fetch` subcommand is used)
cat > "$SANDBOX/hooks/issue-body-safe-update.sh" <<'STUB_FETCH'
#!/bin/bash
set -euo pipefail
echo "original_length=128"
echo "tmpfile_read=/tmp/rite-issue-body-read-STUB"
echo "tmpfile_write=/tmp/rite-issue-body-write-STUB"
STUB_FETCH

chmod +x "$SANDBOX/scripts/create-issue-with-projects.sh" \
         "$SANDBOX/scripts/link-sub-issue.sh" \
         "$SANDBOX/hooks/issue-body-safe-update.sh"

# --- Test helpers ---
mk_body()       { local f="$TEST_DIR/body_$$_$RANDOM.md"; printf '%s' "$1" > "$f"; echo "$f"; }
mk_empty_body() { local f="$TEST_DIR/empty_$$_$RANDOM.md"; : > "$f"; echo "$f"; }

# run_decompose <spec_path> : runs the real script with current STUB_* env.
run_decompose() {
  local spec="$1" rc=0 out
  out=$(bash "$DECOMPOSE" --spec "$spec" 2>"$TEST_DIR/last_stderr") || rc=$?
  LAST_OUTPUT="$out"
  LAST_RC=$rc
  LAST_STDERR=$(cat "$TEST_DIR/last_stderr")
  return 0
}

assert_out_contains()    { case "$LAST_OUTPUT" in *"$1"*) pass "$2" ;; *) fail "$2 (stdout missing: $1)"; printf '    --- stdout ---\n%s\n' "$LAST_OUTPUT" ;; esac; }
assert_out_missing()     { case "$LAST_OUTPUT" in *"$1"*) fail "$2 (stdout unexpectedly contains: $1)" ;; *) pass "$2" ;; esac; }
assert_err_contains()    { case "$LAST_STDERR" in *"$1"*) pass "$2" ;; *) fail "$2 (stderr missing: $1)"; printf '    --- stderr ---\n%s\n' "$LAST_STDERR" ;; esac; }
assert_rc()              { if [ "$LAST_RC" = "$1" ]; then pass "$2"; else fail "$2 (rc=$LAST_RC, expected $1)"; fi; }

# build_spec writes spec.json (+ takes pre-made body file paths) and echoes its path.
# Args: <workdir> <parent_title> <parent_body_file> <labels_csv> then triples: <sub_title> <sub_body_file> <complexity> ...
build_spec() {
  local wd="$1" pt="$2" pf="$3" labels="$4"; shift 4
  local subs="[]"
  while [ $# -ge 3 ]; do
    subs=$(jq -c --arg t "$1" --arg f "$2" --arg c "$3" '. += [{title:$t, body_file:$f, complexity:$c}]' <<<"$subs")
    shift 3
  done
  local spec="$wd/spec.json"
  jq -n --arg pt "$pt" --arg pf "$pf" --arg labels "$labels" --argjson subs "$subs" --arg wd "$wd" \
    '{parent:{title:$pt, body_file:$pf}, sub_issues:$subs, labels_csv:$labels,
      projects:{enabled:true, project_number:6, owner:"B16B1RD", status:"Todo", priority:"Medium"},
      repo:"cc-rite-workflow", workdir:$wd}' > "$spec"
  echo "$spec"
}

echo "=== decompose-issues.sh tests ==="

# -----------------------------------------------------------------
echo "--- Test 1: happy path (parent + 2 subs, all ok) ---"
wd1="$TEST_DIR/wd1"; mkdir -p "$wd1"
pb=$(mk_body "Parent design spec"); s1=$(mk_body "Sub 1"); s2=$(mk_body "Sub 2")
# place bodies inside workdir to also exercise cleanup
cp "$pb" "$wd1/parent.md"; cp "$s1" "$wd1/s1.md"; cp "$s2" "$wd1/s2.md"
spec1=$(build_spec "$wd1" "Epic Parent" "$wd1/parent.md" "refactor,chore" \
  "Sub One" "$wd1/s1.md" "M" "Sub Two" "$wd1/s2.md" "S")
STUB_NUM_FILE="$TEST_DIR/num1"; echo 100 > "$STUB_NUM_FILE"
STUB_CREATE_LOG="$TEST_DIR/clog1"; : > "$STUB_CREATE_LOG"
export STUB_NUM_FILE STUB_CREATE_LOG
unset STUB_CREATE_FAIL_TITLE STUB_LINK_FAIL_CHILD 2>/dev/null || true
run_decompose "$spec1"
assert_rc 0 "exit 0 on happy path"
assert_out_contains "[CONTEXT] PARENT_ISSUE_NUMBER=100" "PARENT_ISSUE_NUMBER marker"
assert_out_contains "[CONTEXT] SUB_ISSUE_RESULT created=2 failed=0 link_failures=0" "SUB_ISSUE_RESULT marker"
assert_out_contains "[CONTEXT] SUB_ISSUE_NUMBERS=101 102" "SUB_ISSUE_NUMBERS marker"
assert_out_contains "original_length=128" "fetch_output original_length passthrough"
assert_out_contains "tmpfile_read=/tmp/rite-issue-body-read-STUB" "fetch_output tmpfile_read passthrough"
assert_out_contains "tmpfile_write=/tmp/rite-issue-body-write-STUB" "fetch_output tmpfile_write passthrough"
if grep -q '"epic"' "$STUB_CREATE_LOG" && head -1 "$STUB_CREATE_LOG" | grep -q 'title=Epic Parent'; then
  pass "parent labels include epic"
else
  fail "parent labels include epic"; cat "$STUB_CREATE_LOG"
fi
if [ ! -d "$wd1" ]; then pass "workdir cleaned up via trap"; else fail "workdir cleaned up via trap (still exists: $wd1)"; fi

# -----------------------------------------------------------------
echo "--- Test 2: empty sub body counts as failed, not created ---"
wd2="$TEST_DIR/wd2"; mkdir -p "$wd2"
printf '%s' "Parent" > "$wd2/parent.md"; printf '%s' "Sub 1" > "$wd2/s1.md"; : > "$wd2/s2_empty.md"
spec2=$(build_spec "$wd2" "Epic2" "$wd2/parent.md" "refactor" \
  "Sub One" "$wd2/s1.md" "M" "Sub Empty" "$wd2/s2_empty.md" "S")
STUB_NUM_FILE="$TEST_DIR/num2"; echo 200 > "$STUB_NUM_FILE"; export STUB_NUM_FILE
unset STUB_CREATE_LOG STUB_CREATE_FAIL_TITLE STUB_LINK_FAIL_CHILD 2>/dev/null || true
run_decompose "$spec2"
assert_rc 0 "exit 0 with one empty sub body"
assert_out_contains "[CONTEXT] SUB_ISSUE_RESULT created=1 failed=1 link_failures=0" "created=1 failed=1 for empty body"
assert_out_contains "[CONTEXT] SUB_ISSUE_NUMBERS=201" "only the created sub number listed"
assert_err_contains "body が空、skip" "empty body WARNING on stderr"

# -----------------------------------------------------------------
echo "--- Test 3: link failure increments link_failures (non-blocking) ---"
wd3="$TEST_DIR/wd3"; mkdir -p "$wd3"
printf '%s' "Parent" > "$wd3/parent.md"; printf '%s' "Sub 1" > "$wd3/s1.md"
spec3=$(build_spec "$wd3" "Epic3" "$wd3/parent.md" "refactor" "Sub One" "$wd3/s1.md" "M")
STUB_NUM_FILE="$TEST_DIR/num3"; echo 300 > "$STUB_NUM_FILE"; export STUB_NUM_FILE
STUB_LINK_FAIL_CHILD=301; export STUB_LINK_FAIL_CHILD   # parent=300, sub=301
unset STUB_CREATE_LOG STUB_CREATE_FAIL_TITLE 2>/dev/null || true
run_decompose "$spec3"
assert_rc 0 "exit 0 on non-blocking link failure"
assert_out_contains "[CONTEXT] SUB_ISSUE_RESULT created=1 failed=0 link_failures=1" "link_failures=1, created unaffected"
assert_out_contains "[CONTEXT] SUB_ISSUE_NUMBERS=301" "sub still created despite link failure"
assert_err_contains "linkage failed for #301" "link failure WARNING on stderr" # drift-check-ignore
assert_err_contains "mock link warning" "link warnings surfaced on stderr"
unset STUB_LINK_FAIL_CHILD

# -----------------------------------------------------------------
echo "--- Test 4: empty parent body -> fatal exit 1 ---"
wd4="$TEST_DIR/wd4"; mkdir -p "$wd4"
: > "$wd4/parent.md"; printf '%s' "Sub 1" > "$wd4/s1.md"
spec4=$(build_spec "$wd4" "Epic4" "$wd4/parent.md" "refactor" "Sub One" "$wd4/s1.md" "M")
STUB_NUM_FILE="$TEST_DIR/num4"; echo 400 > "$STUB_NUM_FILE"; export STUB_NUM_FILE
run_decompose "$spec4"
assert_rc 1 "exit 1 on empty parent body"
assert_err_contains "parent Issue body is empty" "empty parent body ERROR"
assert_out_missing "[CONTEXT] PARENT_ISSUE_NUMBER" "no markers emitted on early fatal"

# -----------------------------------------------------------------
echo "--- Test 5: parent create failure -> fatal exit 1 ---"
wd5="$TEST_DIR/wd5"; mkdir -p "$wd5"
printf '%s' "Parent" > "$wd5/parent.md"; printf '%s' "Sub 1" > "$wd5/s1.md"
spec5=$(build_spec "$wd5" "EpicFail" "$wd5/parent.md" "refactor" "Sub One" "$wd5/s1.md" "M")
STUB_NUM_FILE="$TEST_DIR/num5"; echo 500 > "$STUB_NUM_FILE"; export STUB_NUM_FILE
STUB_CREATE_FAIL_TITLE="EpicFail"; export STUB_CREATE_FAIL_TITLE
run_decompose "$spec5"
assert_rc 1 "exit 1 on parent create failure"
assert_err_contains "親 Issue 作成失敗" "parent create failure ERROR"
unset STUB_CREATE_FAIL_TITLE

# -----------------------------------------------------------------
echo "--- Test 7: partial-Projects (stderr ERROR + stdout JSON + exit 0) counts as created, not failed ---"
wd7="$TEST_DIR/wd7"; mkdir -p "$wd7"
printf '%s' "Parent" > "$wd7/parent.md"; printf '%s' "Sub 1" > "$wd7/s1.md"; printf '%s' "Sub 2" > "$wd7/s2.md"
spec7=$(build_spec "$wd7" "Epic7" "$wd7/parent.md" "refactor" \
  "Sub One" "$wd7/s1.md" "M" "Sub Partial" "$wd7/s2.md" "S")
STUB_NUM_FILE="$TEST_DIR/num7"; echo 700 > "$STUB_NUM_FILE"; export STUB_NUM_FILE
STUB_CREATE_PARTIAL_TITLE="Sub Partial"; export STUB_CREATE_PARTIAL_TITLE
unset STUB_CREATE_LOG STUB_CREATE_FAIL_TITLE STUB_LINK_FAIL_CHILD 2>/dev/null || true
run_decompose "$spec7"
# parent=700, Sub One=701, Sub Partial=702 → both subs created (partial-Projects is exit 0), none failed
assert_rc 0 "exit 0 on partial-Projects sub"
assert_out_contains "[CONTEXT] SUB_ISSUE_RESULT created=2 failed=0 link_failures=0" "partial-Projects sub counted as created, not failed"
assert_out_contains "[CONTEXT] SUB_ISSUE_NUMBERS=701 702" "partial-Projects sub present in SUB_ISSUE_NUMBERS (no silent drop)"
assert_err_contains "stub partial projects warning" "partial-Projects warning surfaced on stderr (selective surface, not silent)"
# The create stderr ERROR must NOT corrupt stdout (no jq parse-error leakage into markers)
assert_out_missing "parse error" "no jq parse error leaked into stdout markers"
unset STUB_CREATE_PARTIAL_TITLE

# -----------------------------------------------------------------
# Regression: a decomposition with NO shared labels (labels_csv="") must still
# create every sub. The old `printf '%s' "$labels_csv" | jq -R` idiom returned
# empty output + exit 0 for empty stdin, leaving sub_labels_json="" so the
# downstream `--argjson labels ""` died with invalid JSON and EVERY sub failed
# (the `|| "[]"` guard never fired on exit 0). The parent still succeeded because
# it prepends "epic,". This test runs the real script with empty labels_csv and
# asserts the subs are created (not failed) with an empty `[]` label array. Revert
# the fix (back to `jq -R`) and this test flips to created=0 failed=2.
echo "--- Test 8: empty labels_csv -> subs still created with [] labels (regression) ---"
wd8="$TEST_DIR/wd8"; mkdir -p "$wd8"
printf '%s' "Parent" > "$wd8/parent.md"; printf '%s' "Sub 1" > "$wd8/s1.md"; printf '%s' "Sub 2" > "$wd8/s2.md"
spec8=$(build_spec "$wd8" "Epic8" "$wd8/parent.md" "" \
  "Sub One" "$wd8/s1.md" "M" "Sub Two" "$wd8/s2.md" "S")
STUB_NUM_FILE="$TEST_DIR/num8"; echo 800 > "$STUB_NUM_FILE"
STUB_CREATE_LOG="$TEST_DIR/clog8"; : > "$STUB_CREATE_LOG"
export STUB_NUM_FILE STUB_CREATE_LOG
unset STUB_CREATE_FAIL_TITLE STUB_LINK_FAIL_CHILD STUB_CREATE_PARTIAL_TITLE 2>/dev/null || true
run_decompose "$spec8"
assert_rc 0 "exit 0 with empty labels_csv"
assert_out_contains "[CONTEXT] SUB_ISSUE_RESULT created=2 failed=0 link_failures=0" "empty labels_csv: both subs created (regression: old jq -R idiom failed every sub)"
assert_out_contains "[CONTEXT] SUB_ISSUE_NUMBERS=801 802" "empty labels_csv: both sub numbers listed"
# Sub label array must be the empty [] (not "" / null / missing); parent still gets ["epic"].
if grep -q 'title=Sub One labels=\[\]' "$STUB_CREATE_LOG"; then
  pass "empty labels_csv: sub labels are []"
else
  fail "empty labels_csv: sub labels are []"; cat "$STUB_CREATE_LOG"
fi
if head -1 "$STUB_CREATE_LOG" | grep -q 'title=Epic8 labels=\["epic"\]'; then
  pass "empty labels_csv: parent labels are [epic]"
else
  fail "empty labels_csv: parent labels are [epic]"; cat "$STUB_CREATE_LOG"
fi
unset STUB_CREATE_LOG

# -----------------------------------------------------------------
echo "--- Test 6: usage / spec validation errors ---"
rc=0; bash "$DECOMPOSE" >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] && pass "no --spec -> exit 2" || fail "no --spec -> exit 2 (rc=$rc)"
rc=0; bash "$DECOMPOSE" --bogus x >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] && pass "unknown arg -> exit 2" || fail "unknown arg -> exit 2 (rc=$rc)"
rc=0; bash "$DECOMPOSE" --spec /no/such/file.json >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] && pass "missing spec file -> exit 1" || fail "missing spec file -> exit 1 (rc=$rc)"
badspec="$TEST_DIR/bad.json"; printf 'not json{' > "$badspec"
rc=0; bash "$DECOMPOSE" --spec "$badspec" >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] && pass "invalid JSON spec -> exit 1" || fail "invalid JSON spec -> exit 1 (rc=$rc)"

# -----------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
