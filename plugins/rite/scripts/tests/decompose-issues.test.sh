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
# - Fails (exit 1) when title == STUB_CREATE_FAIL_TITLE, or an attachment
#   matches STUB_UPLOAD_FAIL_PATH (simulated downstream upload failure).
# - Logs "title=<t> labels=<l>" to STUB_CREATE_LOG for label assertions.
cat > "$SANDBOX/scripts/create-issue-with-projects.sh" <<'STUB_CREATE'
#!/bin/bash
set -euo pipefail
payload="${1:-}"
[ -z "$payload" ] && payload="$(cat)"
title=$(printf '%s' "$payload" | jq -r '.issue.title')
labels=$(printf '%s' "$payload" | jq -rc '.issue.labels')
attachments=$(printf '%s' "$payload" | jq -c '.issue.attachments // []')
[ -n "${STUB_CREATE_LOG:-}" ] && printf 'title=%s labels=%s attachments=%s\n' "$title" "$labels" "$attachments" >> "$STUB_CREATE_LOG"
if [ -n "${STUB_CREATE_FAIL_TITLE:-}" ] && [ "$title" = "$STUB_CREATE_FAIL_TITLE" ]; then
  echo "stub: forced create failure for $title" >&2
  exit 1
fi
if [ -n "${STUB_CREATED_THEN_FAIL_TITLE:-}" ] && [ "$title" = "$STUB_CREATED_THEN_FAIL_TITLE" ]; then
  echo "stub: created, then failed for $title" >&2
  jq -n '{issue_number:0, issue_url:"https://example/created-then-failed", project_registration:"failed", warnings:["stub failure after create"]}'
  exit 1
fi
if [ -n "${STUB_UPLOAD_FAIL_PATH:-}" ] &&
   jq -e --arg path "$STUB_UPLOAD_FAIL_PATH" 'index($path) != null' <<<"$attachments" >/dev/null; then
  echo "stub: forced attachment upload failure for $title" >&2
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

# Stub: issue-create-gate.sh
# - Logs each subcommand to STUB_GATE_LOG; verify fails while STUB_GATE_CLOSED is set.
cat > "$SANDBOX/scripts/issue-create-gate.sh" <<'STUB_GATE'
#!/bin/bash
set -euo pipefail
[ -n "${STUB_GATE_LOG:-}" ] && printf '%s\n' "$1" >> "$STUB_GATE_LOG"
if [ "$1" = "verify" ] && [ -n "${STUB_GATE_CLOSED:-}" ]; then
  echo "stub: gate closed" >&2
  exit 1
fi
exit 0
STUB_GATE

chmod +x "$SANDBOX/scripts/create-issue-with-projects.sh" \
         "$SANDBOX/scripts/link-sub-issue.sh" \
         "$SANDBOX/scripts/issue-create-gate.sh" \
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
      projects:{enabled:true, project_number:6, owner:"B16B1RD", status:"todo", priority:"Medium"},
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
if grep -q '"epic"' "$STUB_CREATE_LOG" && _gq_out=$(head -1 "$STUB_CREATE_LOG") && grep -q 'title=Epic Parent' <<< "$_gq_out"; then
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
STUB_GATE_LOG="$TEST_DIR/gate5"; : > "$STUB_GATE_LOG"; export STUB_GATE_LOG
run_decompose "$spec5"
assert_rc 1 "exit 1 on parent create failure"
assert_err_contains "親 Issue 作成失敗" "parent create failure ERROR"
if grep -qx consume "$STUB_GATE_LOG"; then fail "gate consumed although no parent was created"; else pass "gate kept for the retry when no parent was created"; fi
unset STUB_CREATE_FAIL_TITLE STUB_GATE_LOG

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
if _gq_out=$(head -1 "$STUB_CREATE_LOG") && grep -q 'title=Epic8 labels=\["epic"\]' <<< "$_gq_out"; then
  pass "empty labels_csv: parent labels are [epic]"
else
  fail "empty labels_csv: parent labels are [epic]"; cat "$STUB_CREATE_LOG"
fi
unset STUB_CREATE_LOG

# -----------------------------------------------------------------
echo "--- Test 9: parent.attachments propagate to parent payload only (T-03) ---"
wd9="$TEST_DIR/wd9"; mkdir -p "$wd9"
printf '%s' "Parent" > "$wd9/parent.md"; printf '%s' "Sub 1" > "$wd9/s1.md"
svg9="$wd9/diagram.svg"; printf '<svg/>\n' > "$svg9"
spec9=$(build_spec "$wd9" "Epic9" "$wd9/parent.md" "refactor" "Sub One" "$wd9/s1.md" "M")
jq --arg a "$svg9" '.parent.attachments = [$a]' "$spec9" > "$spec9.tmp" && mv "$spec9.tmp" "$spec9"
STUB_NUM_FILE="$TEST_DIR/num9"; echo 900 > "$STUB_NUM_FILE"
STUB_CREATE_LOG="$TEST_DIR/clog9"; : > "$STUB_CREATE_LOG"
export STUB_NUM_FILE STUB_CREATE_LOG
unset STUB_CREATE_FAIL_TITLE STUB_LINK_FAIL_CHILD STUB_CREATE_PARTIAL_TITLE 2>/dev/null || true
run_decompose "$spec9"
assert_rc 0 "exit 0 with parent.attachments"
parent_att=$(grep '^title=Epic9 ' "$STUB_CREATE_LOG" | sed -n 's/.*attachments=//p')
sub_att=$(grep '^title=Sub One ' "$STUB_CREATE_LOG" | sed -n 's/.*attachments=//p')
expected9=$(jq -cn --arg a "$svg9" '[$a]')
if [ "$parent_att" = "$expected9" ]; then
  pass "T-03: parent issue.attachments is the spec path array"
else
  fail "T-03: parent issue.attachments is the spec path array (got: $parent_att)"; cat "$STUB_CREATE_LOG"
fi
if [ "$sub_att" = '[]' ]; then
  pass "T-03: Sub issue.attachments is []"
else
  fail "T-03: Sub issue.attachments is [] (got: $sub_att)"; cat "$STUB_CREATE_LOG"
fi
unset STUB_CREATE_LOG

# -----------------------------------------------------------------
echo "--- Test 10: omitted parent.attachments -> [] on parent and sub (T-04) ---"
wd10="$TEST_DIR/wd10"; mkdir -p "$wd10"
printf '%s' "Parent" > "$wd10/parent.md"; printf '%s' "Sub 1" > "$wd10/s1.md"
spec10=$(build_spec "$wd10" "Epic10" "$wd10/parent.md" "refactor" "Sub One" "$wd10/s1.md" "M")
STUB_NUM_FILE="$TEST_DIR/num10"; echo 1000 > "$STUB_NUM_FILE"
STUB_CREATE_LOG="$TEST_DIR/clog10"; : > "$STUB_CREATE_LOG"
export STUB_NUM_FILE STUB_CREATE_LOG
unset STUB_CREATE_FAIL_TITLE STUB_LINK_FAIL_CHILD STUB_CREATE_PARTIAL_TITLE 2>/dev/null || true
run_decompose "$spec10"
assert_rc 0 "exit 0 with omitted parent.attachments"
parent_att=$(grep '^title=Epic10 ' "$STUB_CREATE_LOG" | sed -n 's/.*attachments=//p')
sub_att=$(grep '^title=Sub One ' "$STUB_CREATE_LOG" | sed -n 's/.*attachments=//p')
if [ "$parent_att" = '[]' ]; then
  pass "T-04: omitted attachments -> parent []"
else
  fail "T-04: omitted attachments -> parent [] (got: $parent_att)"; cat "$STUB_CREATE_LOG"
fi
if [ "$sub_att" = '[]' ]; then
  pass "T-04: omitted attachments -> sub []"
else
  fail "T-04: omitted attachments -> sub [] (got: $sub_att)"; cat "$STUB_CREATE_LOG"
fi
unset STUB_CREATE_LOG

# -----------------------------------------------------------------
echo "--- Test 11: missing attachment path fails before parent create (T-05) ---"
wd11="$TEST_DIR/wd11"; mkdir -p "$wd11"
printf '%s' "Parent" > "$wd11/parent.md"; printf '%s' "Sub 1" > "$wd11/s1.md"
spec11=$(build_spec "$wd11" "Epic11" "$wd11/parent.md" "refactor" "Sub One" "$wd11/s1.md" "M")
missing11="$wd11/no-such-diagram.svg"
jq --arg a "$missing11" '.parent.attachments = [$a]' "$spec11" > "$spec11.tmp" && mv "$spec11.tmp" "$spec11"
REAL_CREATE="$(cd "$SCRIPT_DIR/.." && pwd)/create-issue-with-projects.sh"
cp "$SANDBOX/scripts/create-issue-with-projects.sh" "$TEST_DIR/stub_create.bak"
cat > "$SANDBOX/scripts/create-issue-with-projects.sh" <<WRAP
#!/bin/bash
exec bash "$REAL_CREATE" "\$@"
WRAP
chmod +x "$SANDBOX/scripts/create-issue-with-projects.sh"
STUB_NUM_FILE="$TEST_DIR/num11"; echo 1100 > "$STUB_NUM_FILE"
export STUB_NUM_FILE
unset STUB_CREATE_LOG STUB_CREATE_FAIL_TITLE STUB_LINK_FAIL_CHILD STUB_CREATE_PARTIAL_TITLE 2>/dev/null || true
run_decompose "$spec11"
assert_rc 1 "T-05: missing attachment exits 1"
assert_err_contains "ERROR: attachment not found:" "T-05: real helper stderr"
assert_out_missing "PARENT_ISSUE_NUMBER" "T-05: no PARENT_ISSUE_NUMBER before failure"
assert_out_missing '"issue_number"' "T-05: no parent success JSON"
mv "$TEST_DIR/stub_create.bak" "$SANDBOX/scripts/create-issue-with-projects.sh"
chmod +x "$SANDBOX/scripts/create-issue-with-projects.sh"

# -----------------------------------------------------------------
echo "--- Test 12: parent and two children receive their own attachment arrays ---"
wd12="$TEST_DIR/wd12"; mkdir -p "$wd12"
printf '%s' "Parent" > "$wd12/parent.md"; printf '%s' "Sub 1" > "$wd12/s1.md"; printf '%s' "Sub 2" > "$wd12/s2.md"
parent_svg12="$wd12/parent diagram.svg"
sub1_svg12="$wd12/first child diagram.svg"; sub1_extra12="$wd12/first child detail.svg"
sub2_svg12="$wd12/second child diagram.svg"
for svg in "$parent_svg12" "$sub1_svg12" "$sub1_extra12" "$sub2_svg12"; do printf '<svg/>\n' > "$svg"; done
spec12=$(build_spec "$wd12" "Epic12" "$wd12/parent.md" "refactor" \
  "Sub One" "$wd12/s1.md" "M" "Sub Two" "$wd12/s2.md" "S")
parent_expected12=$(jq -cn --arg p "$parent_svg12" '[$p]')
sub1_expected12=$(jq -cn --arg a "$sub1_svg12" --arg b "$sub1_extra12" '[$a,$b]')
sub2_expected12=$(jq -cn --arg p "$sub2_svg12" '[$p]')
jq --argjson p "$parent_expected12" --argjson a "$sub1_expected12" --argjson b "$sub2_expected12" \
  '.parent.attachments = $p | .sub_issues[0].attachments = $a | .sub_issues[1].attachments = $b' \
  "$spec12" > "$spec12.tmp" && mv "$spec12.tmp" "$spec12"
STUB_NUM_FILE="$TEST_DIR/num12"; echo 1200 > "$STUB_NUM_FILE"
STUB_CREATE_LOG="$TEST_DIR/clog12"; : > "$STUB_CREATE_LOG"
export STUB_NUM_FILE STUB_CREATE_LOG
unset STUB_CREATE_FAIL_TITLE STUB_UPLOAD_FAIL_PATH STUB_LINK_FAIL_CHILD STUB_CREATE_PARTIAL_TITLE 2>/dev/null || true
run_decompose "$spec12"
assert_rc 0 "exit 0 with separate parent and child attachments"
assert_out_contains "[CONTEXT] SUB_ISSUE_RESULT created=2 failed=0 link_failures=0" "both attached children counted as created"
assert_out_contains "[CONTEXT] SUB_ISSUE_NUMBERS=1201 1202" "both attached child numbers listed"
for title in "Epic12" "Sub One" "Sub Two"; do
  case "$title" in
    Epic12) expected="$parent_expected12" ;;
    'Sub One') expected="$sub1_expected12" ;;
    'Sub Two') expected="$sub2_expected12" ;;
  esac
  actual=$(grep "^title=$title " "$STUB_CREATE_LOG" | sed -n 's/.*attachments=//p')
  if [ "$actual" = "$expected" ]; then
    pass "$title receives its exact attachment array, preserving spaces and order"
  else
    fail "$title receives its exact attachment array (got: $actual)"; cat "$STUB_CREATE_LOG"
  fi
done
unset STUB_CREATE_LOG

# -----------------------------------------------------------------
echo "--- Test 13: empty and omitted child attachments do not inherit parent attachments ---"
wd13="$TEST_DIR/wd13"; mkdir -p "$wd13"
printf '%s' "Parent" > "$wd13/parent.md"; printf '%s' "Sub 1" > "$wd13/s1.md"; printf '%s' "Sub 2" > "$wd13/s2.md"
parent_svg13="$wd13/parent diagram.svg"; printf '<svg/>\n' > "$parent_svg13"
spec13=$(build_spec "$wd13" "Epic13" "$wd13/parent.md" "refactor" \
  "Sub Empty Attachments" "$wd13/s1.md" "M" "Sub Omitted Attachments" "$wd13/s2.md" "S")
jq --arg p "$parent_svg13" '.parent.attachments = [$p] | .sub_issues[0].attachments = []' \
  "$spec13" > "$spec13.tmp" && mv "$spec13.tmp" "$spec13"
STUB_NUM_FILE="$TEST_DIR/num13"; echo 1300 > "$STUB_NUM_FILE"
STUB_CREATE_LOG="$TEST_DIR/clog13"; : > "$STUB_CREATE_LOG"
export STUB_NUM_FILE STUB_CREATE_LOG
run_decompose "$spec13"
assert_rc 0 "exit 0 with empty and omitted child attachments"
assert_out_contains "[CONTEXT] SUB_ISSUE_RESULT created=2 failed=0 link_failures=0" "empty and omitted attachment children both created"
for title in "Sub Empty Attachments" "Sub Omitted Attachments"; do
  actual=$(grep "^title=$title " "$STUB_CREATE_LOG" | sed -n 's/.*attachments=//p')
  if [ "$actual" = '[]' ]; then
    pass "$title receives [] with a nonempty parent array"
  else
    fail "$title receives [] (got: $actual)"; cat "$STUB_CREATE_LOG"
  fi
done
unset STUB_CREATE_LOG

# -----------------------------------------------------------------
echo "--- Test 14: child upload and create failures count as failed and processing continues ---"
wd14="$TEST_DIR/wd14"; mkdir -p "$wd14"
printf '%s' "Parent" > "$wd14/parent.md"
for child in upload create success; do
  printf '%s' "Child body" > "$wd14/$child.md"
  printf '<svg/>\n' > "$wd14/$child diagram.svg"
done
spec14=$(build_spec "$wd14" "Epic14" "$wd14/parent.md" "refactor" \
  "Sub Upload Fails" "$wd14/upload.md" "M" "Sub Create Fails" "$wd14/create.md" "S" \
  "Sub Success" "$wd14/success.md" "S")
jq --arg u "$wd14/upload diagram.svg" --arg c "$wd14/create diagram.svg" --arg s "$wd14/success diagram.svg" \
  '.sub_issues[0].attachments = [$u] | .sub_issues[1].attachments = [$c] | .sub_issues[2].attachments = [$s]' \
  "$spec14" > "$spec14.tmp" && mv "$spec14.tmp" "$spec14"
STUB_NUM_FILE="$TEST_DIR/num14"; echo 1400 > "$STUB_NUM_FILE"
STUB_LINK_LOG="$TEST_DIR/llog14"; : > "$STUB_LINK_LOG"
STUB_UPLOAD_FAIL_PATH="$wd14/upload diagram.svg"; STUB_CREATE_FAIL_TITLE="Sub Create Fails"
export STUB_NUM_FILE STUB_LINK_LOG STUB_UPLOAD_FAIL_PATH STUB_CREATE_FAIL_TITLE
run_decompose "$spec14"
assert_rc 0 "child upload/create failures remain non-blocking"
assert_out_contains "[CONTEXT] PARENT_ISSUE_NUMBER=1400" "parent remains created despite child failures"
assert_out_contains "[CONTEXT] SUB_ISSUE_RESULT created=1 failed=2 link_failures=0" "upload and create failures each increment failed count"
assert_out_contains "[CONTEXT] SUB_ISSUE_NUMBERS=1401" "only later successful child is listed"
assert_err_contains "stub: forced attachment upload failure for Sub Upload Fails" "downstream child upload diagnostic surfaced"
assert_err_contains "stub: forced create failure for Sub Create Fails" "downstream child create diagnostic surfaced"
if [ "$(cat "$STUB_LINK_LOG")" = 'link B16B1RD/cc-rite-workflow 1400<-1401' ]; then
  pass "only successful child is linked"
else
  fail "only successful child is linked"; cat "$STUB_LINK_LOG"
fi
unset STUB_LINK_LOG STUB_UPLOAD_FAIL_PATH STUB_CREATE_FAIL_TITLE

# -----------------------------------------------------------------
echo "--- Test 15: without the issue-create gate nothing is created ---"
wd15="$TEST_DIR/wd15"; mkdir -p "$wd15"
printf '%s' "Parent" > "$wd15/parent.md"; printf '%s' "Sub 1" > "$wd15/s1.md"
spec15=$(build_spec "$wd15" "Epic15" "$wd15/parent.md" "refactor" "Sub One" "$wd15/s1.md" "M")
STUB_NUM_FILE="$TEST_DIR/num15"; echo 1500 > "$STUB_NUM_FILE"; export STUB_NUM_FILE
STUB_CREATE_LOG="$TEST_DIR/create15.log"; : > "$STUB_CREATE_LOG"; export STUB_CREATE_LOG
STUB_GATE_CLOSED=1; export STUB_GATE_CLOSED
run_decompose "$spec15"
assert_rc 1 "exit 1 without the gate"
assert_err_contains "/rite:issue-create を起動して" "guidance to start /rite:issue-create"
if [ ! -s "$STUB_CREATE_LOG" ]; then pass "no Issue create call without the gate"; else fail "create called without the gate"; cat "$STUB_CREATE_LOG"; fi
unset STUB_GATE_CLOSED STUB_CREATE_LOG

# -----------------------------------------------------------------
echo "--- Test 16: one gate record covers the parent and every child, then is consumed ---"
wd16="$TEST_DIR/wd16"; mkdir -p "$wd16"
printf '%s' "Parent" > "$wd16/parent.md"; printf '%s' "Sub 1" > "$wd16/s1.md"; printf '%s' "Sub 2" > "$wd16/s2.md"; printf '%s' "Sub 3" > "$wd16/s3.md"
spec16=$(build_spec "$wd16" "Epic16" "$wd16/parent.md" "refactor" \
  "Sub One" "$wd16/s1.md" "S" "Sub Two" "$wd16/s2.md" "S" "Sub Three" "$wd16/s3.md" "S")
STUB_NUM_FILE="$TEST_DIR/num16"; echo 1600 > "$STUB_NUM_FILE"; export STUB_NUM_FILE
STUB_GATE_LOG="$TEST_DIR/gate16"; : > "$STUB_GATE_LOG"; export STUB_GATE_LOG
run_decompose "$spec16"
assert_rc 0 "exit 0 with the gate"
assert_out_contains "SUB_ISSUE_RESULT created=3 failed=0" "all children created with one gate record"
if [ "$(tr '\n' ' ' < "$STUB_GATE_LOG")" = "verify consume " ]; then
  pass "gate verified once and consumed once at exit"
else
  fail "unexpected gate calls: $(tr '\n' ' ' < "$STUB_GATE_LOG")"
fi

# -----------------------------------------------------------------
echo "--- Test 17: a parent created before a failure still consumes the gate ---"
wd17="$TEST_DIR/wd17"; mkdir -p "$wd17"
printf '%s' "Parent" > "$wd17/parent.md"; printf '%s' "Sub 1" > "$wd17/s1.md"
spec17=$(build_spec "$wd17" "Epic17" "$wd17/parent.md" "refactor" "Sub One" "$wd17/s1.md" "M")
STUB_NUM_FILE="$TEST_DIR/num17"; echo 1700 > "$STUB_NUM_FILE"; export STUB_NUM_FILE
: > "$STUB_GATE_LOG"
STUB_CREATED_THEN_FAIL_TITLE="Epic17"; export STUB_CREATED_THEN_FAIL_TITLE
run_decompose "$spec17"
assert_rc 1 "exit 1 when the parent helper fails after creating"
if grep -qx consume "$STUB_GATE_LOG"; then pass "gate consumed on the failure exit"; else fail "gate left open after the parent was created"; fi
unset STUB_CREATED_THEN_FAIL_TITLE STUB_GATE_LOG

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
