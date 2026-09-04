#!/bin/bash
# Static + offline tests for projects-board-drift-check.sh
#
# Verifies:
#   T-1: script exists and is executable
#   T-2: script syntax is valid (bash -n)
#   T-3: --help prints usage without error
#   T-4: --limit rejects non-numeric / zero (exit 2)
#   T-5: documented flags + detection logic present in source
#   T-6: config-aware no-op (projects disabled / rite-config absent) exits 0 with a
#        0-findings summary line — exercised offline, no gh required (AC-4)
#   T-7: behavioral fixture — the jq detection pipeline (extracted from source, not a
#        copy) classifies all eight cases correctly (COMPLETED drift / NOT_PLANNED drift /
#        Done / Cancelled / not-on-board / other-project / <no-status> / null reason),
#        catching semantic breaks that preserve jq literals but flip scoping
#        (offline, jq-only, no gh)
#   T-9: behavioral — --reconcile drives the Status update helper to "Done" for a
#        COMPLETED closure (offline, gh shim records the item-edit)
#  T-10: behavioral — a failing GraphQL scan exits 2 with a diagnostic, so lint never
#        misreads an invocation/API error as "drift detected" (exit 1)
#  T-11: behavioral — a failed reconcile surfaces the Status-update helper's warnings on
#        stderr (the helper puts them only in its stdout JSON), exercising the non-quiet path
#  T-12: behavioral — a NOT_PLANNED closure on a non-terminal board reconciles to
#        "Cancelled", not "Done" (the terminal-status split, end to end)
#  T-13: behavioral — an unclassified closure reason reconciles to "Done" AND emits
#        exactly one WARNING, so the fallback is never silent
# T-13b: behavioral — DUPLICATE reconciles to "Cancelled" with no unmapped-reason WARNING
# T-13d: behavioral — a fictional enum reaches the catch-all (Done + WARNING naming it)
# T-13c: behavioral — COMPLETED stays on the silent Done arm (negative control for T-13b/d)
#  T-14: behavioral — a board already on "Cancelled" is not drift at all (0 findings,
#        exit 0), so --reconcile can never overwrite a deliberate cancellation
#  T-15: static — every consumer of the terminal Status set points at its source of truth
#        by section name, with no line-number anchor
#
# This suite is named for projects-board-drift-check.sh but also pins the cross-file
# terminal-status contract (T-15), because that contract is what the drift check's
# reconcile destinations are derived from.
#
# Usage: bash plugins/rite/hooks/tests/projects-board-drift-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DRIFT_SH="$REPO_ROOT/plugins/rite/hooks/scripts/projects-board-drift-check.sh"

# Terminal Status names and the unclassified-reason sentinel are read back out of the
# script rather than restated here, so a rename in the source travels into the fixtures
# instead of leaving the suite asserting against values nothing produces any more.
TERM_DONE=$(sed -n 's/^TERMINAL_STATUS_DONE="\(.*\)"$/\1/p' "$DRIFT_SH" | head -1)
TERM_CANCELLED=$(sed -n 's/^TERMINAL_STATUS_CANCELLED="\(.*\)"$/\1/p' "$DRIFT_SH" | head -1)
NO_REASON=$(sed -n 's/^NO_CLOSURE_REASON="\(.*\)"$/\1/p' "$DRIFT_SH" | head -1)

PASS=0
FAIL=0
FAILURES=()

assert_file_contains() {
  local file="$1" pattern="$2" description="$3"
  if grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1)); echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1)); FAILURES+=("$description (pattern: $pattern)"); echo "  ✗ $description" >&2
  fi
}

# Assert a fixed string is present / absent in a captured multi-line value (used by the
# T-7 behavioral fixture, where the value is the jq pipeline's TSV output).
assert_present() {
  local haystack="$1" needle="$2" description="$3"
  if printf '%s\n' "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1)); FAILURES+=("$description"); echo "  ✗ $description" >&2
  fi
}

assert_absent() {
  local haystack="$1" needle="$2" description="$3"
  if printf '%s\n' "$haystack" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1)); FAILURES+=("$description"); echo "  ✗ $description" >&2
  else
    PASS=$((PASS + 1)); echo "  ✓ $description"
  fi
}

# Inverse of assert_file_contains: the pattern must NOT appear anywhere in the file.
assert_file_lacks() {
  local file="$1" pattern="$2" description="$3"
  if grep -qE -e "$pattern" "$file"; then
    FAIL=$((FAIL + 1)); FAILURES+=("$description (pattern: $pattern)"); echo "  ✗ $description" >&2
  else
    PASS=$((PASS + 1)); echo "  ✓ $description"
  fi
}

echo "=== T: projects-board-drift-check.sh ==="

echo ""
echo "[T-1] Script exists and is executable"
if [ ! -f "$DRIFT_SH" ]; then
  echo "ERROR: $DRIFT_SH not found" >&2
  exit 1
fi
if [ -x "$DRIFT_SH" ]; then
  PASS=$((PASS + 1)); echo "  ✓ projects-board-drift-check.sh is executable"
else
  FAIL=$((FAIL + 1)); FAILURES+=("script is not executable"); echo "  ✗ script is not executable" >&2
fi

echo ""
echo "[T-2] Script syntax is valid"
if bash -n "$DRIFT_SH" 2>/dev/null; then
  PASS=$((PASS + 1)); echo "  ✓ bash -n passes"
else
  FAIL=$((FAIL + 1)); FAILURES+=("bash -n failed"); echo "  ✗ bash -n failed" >&2
fi

echo ""
echo "[T-3] --help prints usage"
help_output=$(bash "$DRIFT_SH" --help 2>&1) || true
if printf '%s' "$help_output" | grep -q 'projects-board-drift-check.sh'; then
  PASS=$((PASS + 1)); echo "  ✓ --help prints usage including script name"
else
  FAIL=$((FAIL + 1)); FAILURES+=("--help output missing script name"); echo "  ✗ --help output missing script name" >&2
fi
if printf '%s' "$help_output" | grep -q 'NOT_PLANNED or DUPLICATE' \
  && printf '%s' "$help_output" | grep -q 'Cancelled'; then
  PASS=$((PASS + 1)); echo "  ✓ --help maps DUPLICATE to Cancelled"
else
  FAIL=$((FAIL + 1)); FAILURES+=("--help does not map DUPLICATE to Cancelled"); echo "  ✗ --help does not map DUPLICATE to Cancelled" >&2
fi
if printf '%s' "$help_output" | grep -qi 'unmapped'; then
  FAIL=$((FAIL + 1)); FAILURES+=("--help still calls a mapped reason unmapped"); echo "  ✗ --help still says unmapped" >&2
else
  PASS=$((PASS + 1)); echo "  ✓ --help does not call a mapped reason unmapped"
fi

echo ""
echo "[T-4] --limit input validation (must exit exactly 2 = invocation error)"
# exit 2 = invocation error; exit 1 = "drift detected" (lint Phase 3.18). A bad --limit arg
# must exit exactly 2, never 1, or lint would misread a usage error as drift. Capture the exact
# code (not just non-zero). set +e around the capture so set -euo pipefail does not abort the
# harness on the script's intentional non-zero exit.
set +e; bash "$DRIFT_SH" --limit abc --quiet >/dev/null 2>&1; rc=$?; set -e
if [ "$rc" -eq 2 ]; then
  PASS=$((PASS + 1)); echo "  ✓ --limit non-numeric exits 2"
else
  FAIL=$((FAIL + 1)); FAILURES+=("--limit abc should exit 2 (got $rc)"); echo "  ✗ --limit abc should exit 2 (got $rc)" >&2
fi
set +e; bash "$DRIFT_SH" --limit 0 --quiet >/dev/null 2>&1; rc=$?; set -e
if [ "$rc" -eq 2 ]; then
  PASS=$((PASS + 1)); echo "  ✓ --limit 0 exits 2"
else
  FAIL=$((FAIL + 1)); FAILURES+=("--limit 0 should exit 2 (got $rc)"); echo "  ✗ --limit 0 should exit 2 (got $rc)" >&2
fi
# Bare trailing --limit (missing value) must exit 2 — directly guards the exit-code contract:
# without the value-presence gate, `shift 2` under set -e aborts with exit 1 (= drift warning).
set +e; bash "$DRIFT_SH" --limit >/dev/null 2>&1; rc=$?; set -e
if [ "$rc" -eq 2 ]; then
  PASS=$((PASS + 1)); echo "  ✓ bare --limit (missing value) exits 2"
else
  FAIL=$((FAIL + 1)); FAILURES+=("bare --limit should exit 2 (got $rc)"); echo "  ✗ bare --limit should exit 2 (got $rc)" >&2
fi

echo ""
echo "[T-5] Documented flags + detection logic present in source"
assert_file_contains "$DRIFT_SH" '\-\-dry-run\)' "case clause handles --dry-run flag"
assert_file_contains "$DRIFT_SH" '\-\-reconcile\)' "case clause handles --reconcile flag"
assert_file_contains "$DRIFT_SH" '\-\-limit\)' "case clause handles --limit flag"
assert_file_contains "$DRIFT_SH" '\-\-quiet\)' "case clause handles --quiet flag"
assert_file_contains "$DRIFT_SH" 'Reconciliation drift-guard' "header documents drift-guard purpose"
# Detection: anchor asserts to the load-bearing shell constants and jq predicates, NOT to the
# header comments (which spell the status names as prose), so deleting the detection logic
# actually fails the suite. Board membership is the inclusion gate, so pin its exact form.
assert_file_contains "$DRIFT_SH" 'select\(\$pitem != null\)' "board 掲載のみで絞る"
# The terminal Status set is the whole point of the filter, so pin both members at their
# definitions. A drift back to a Done-only filter deletes one of these and fails here.
assert_file_contains "$DRIFT_SH" '^TERMINAL_STATUS_DONE="Done"$' "終端 Status 集合に Done を持つ"
assert_file_contains "$DRIFT_SH" '^TERMINAL_STATUS_CANCELLED="Cancelled"$' "終端 Status 集合に Cancelled を持つ"
# Pin the predicate by its exact two-member form. A one-sided `!= $terminal_done` would still
# match a looser pattern while silently reporting every Cancelled row as drift again.
assert_file_contains "$DRIFT_SH" 'select\(\$st != \$terminal_done and \$st != \$terminal_cancelled\)' \
  "AC-1: drift は終端 Status 集合のいずれでもない行に限る"
# The closure reason is now load-bearing on both ends: selected by the query, carried by jq.
assert_file_contains "$DRIFT_SH" '^ *stateReason$' "GraphQL query が stateReason を取得する"
assert_file_contains "$DRIFT_SH" '\$i\.stateReason // \$no_reason' "jq が stateReason を TSV へ載せる"
# AC-2/AC-3: the reconcile destination is chosen from the closure reason, not fixed to Done.
assert_file_contains "$DRIFT_SH" 'NOT_PLANNED\) target_status="\$TERMINAL_STATUS_CANCELLED"' \
  "AC-2: NOT_PLANNED の reconcile 先は Cancelled"
assert_file_contains "$DRIFT_SH" 'DUPLICATE\) *target_status="\$TERMINAL_STATUS_CANCELLED"' \
  "AC-2: DUPLICATE の reconcile 先は Cancelled"
# COMPLETED gets its own silent arm so the catch-all means "unmapped", not "everything
# else". This pin is static: it sees the arm's existence and destination, not its silence
# and not its position relative to the catch-all. Both of those are T-13c's job — keep the
# label narrow so a failure here points at the assignment, not at the WARNING.
assert_file_contains "$DRIFT_SH" 'COMPLETED\) *target_status="\$TERMINAL_STATUS_DONE"' \
  "AC-3: COMPLETED が独立した明示アームを持つ"
assert_file_contains "$DRIFT_SH" '--arg status "\$target_status"' \
  "reconcile が固定 Done ではなく target_status を渡す"
assert_file_contains "$DRIFT_SH" 'projectItems' "queries projectItems for board membership"
# AC-4: projects-enabled gate
assert_file_contains "$DRIFT_SH" 'PROJECTS_ENABLED' "gates on github.projects.enabled (AC-4)"
# Reconcile path reuses the shared helper (AC-3)
assert_file_contains "$DRIFT_SH" 'projects-status-update\.sh' "reconcile path reuses projects-status-update.sh (AC-3)"
# Summary line consumed by lint Phase 3.18
assert_file_contains "$DRIFT_SH" 'Total projects-board-drift findings:' "emits lint-consumable summary line"

echo ""
echo "[T-6] Config-aware no-op exits 0 with 0-findings summary (AC-4, offline)"
tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT
# projects disabled
mkdir -p "$tmpd/disabled"
cat > "$tmpd/disabled/rite-config.yml" <<'CFG'
github:
  projects:
    enabled: false
    project_number: 6
CFG
# set +e around the assignment so a script regression (non-zero exit) does not abort
# the harness at the command-substitution line under `set -euo pipefail` — otherwise the
# `[ "$noop_rc" -eq 0 ]` failure branch below becomes dead code and failure attribution is lost.
set +e; noop_out=$( (cd "$tmpd/disabled" && bash "$DRIFT_SH" --quiet) 2>/dev/null ); noop_rc=$?; set -e
if [ "$noop_rc" -eq 0 ] && printf '%s' "$noop_out" | grep -q '==> Total projects-board-drift findings: 0'; then
  PASS=$((PASS + 1)); echo "  ✓ projects disabled → exit 0, 0 findings"
else
  FAIL=$((FAIL + 1)); FAILURES+=("projects disabled no-op (rc=$noop_rc)"); echo "  ✗ projects disabled no-op (rc=$noop_rc)" >&2
fi
# rite-config absent (walks up to a .git boundary with no config)
mkdir -p "$tmpd/noconfig/.git"
set +e; noop2_out=$( (cd "$tmpd/noconfig" && bash "$DRIFT_SH" --quiet) 2>/dev/null ); noop2_rc=$?; set -e
if [ "$noop2_rc" -eq 0 ] && printf '%s' "$noop2_out" | grep -q '==> Total projects-board-drift findings: 0'; then
  PASS=$((PASS + 1)); echo "  ✓ rite-config absent → exit 0, 0 findings"
else
  FAIL=$((FAIL + 1)); FAILURES+=("rite-config absent no-op (rc=$noop2_rc)"); echo "  ✗ rite-config absent no-op (rc=$noop2_rc)" >&2
fi

echo ""
echo "[T-7] Behavioral fixture: jq detection pipeline classifies all eight cases (semantic-break guard)"
# Extract the EXACT jq detection program from the source so this exercises the real
# pipeline, not a copy. A semantic break that T-5's literal grep cannot see — e.g.
# $pitem != null -> == null, dropping one member of the terminal Status set, or dropping
# the `.project.number == $pn` board scoping — changes the classification below and fails
# here. The invocation spans several lines (`jq -r --argjson pn` plus the --arg
# continuations), so capture from the LAST continuation, which is the line that opens the
# program's quote, through its `2>"${jq_err...}"` redirect.
jq_prog=$(awk '
  /--arg no_reason/ { capturing=1; next }
  capturing && /jq_err/ { capturing=0; next }
  capturing { print }
' "$DRIFT_SH")

if [ -z "$jq_prog" ]; then
  FAIL=$((FAIL + 1)); FAILURES+=("could not extract jq detection program from source")
  echo "  ✗ could not extract jq detection program from source" >&2
else
  PASS=$((PASS + 1)); echo "  ✓ extracted jq detection program from source"
  # GraphQL-shaped fixture (models `gh api graphql` output) covering all eight cases.
  # project_number ($pn) = 6. Titles are unique so present/absent asserts key on them.
  # / / / are drift; / / / must be excluded.
  # The bare {} node in mirrors GraphQL emitting non-single-select fieldValues as
  # empty objects. omits stateReason entirely, which is how a null closure reason
  # reaches jq — the row must still be emitted, carrying the sentinel.
  fixture=$(cat <<'JSON'
{ "data": { "repository": { "issues": { "nodes": [
  { "number": 101, "title": "drift case", "stateReason": "COMPLETED",
    "projectItems": { "nodes": [ { "project": { "number": 6 },
      "fieldValues": { "nodes": [ {}, { "field": { "name": "Status" }, "name": "In Review" } ] } } ] } },
  { "number": 102, "title": "done excluded", "stateReason": "COMPLETED",
    "projectItems": { "nodes": [ { "project": { "number": 6 },
      "fieldValues": { "nodes": [ { "field": { "name": "Status" }, "name": "Done" } ] } } ] } },
  { "number": 103, "title": "not_planned drift", "stateReason": "NOT_PLANNED",
    "projectItems": { "nodes": [ { "project": { "number": 6 },
      "fieldValues": { "nodes": [ { "field": { "name": "Status" }, "name": "Todo" } ] } } ] } },
  { "number": 104, "title": "not on board", "stateReason": "COMPLETED",
    "projectItems": { "nodes": [] } },
  { "number": 105, "title": "other project", "stateReason": "COMPLETED",
    "projectItems": { "nodes": [ { "project": { "number": 99 },
      "fieldValues": { "nodes": [ { "field": { "name": "Status" }, "name": "Todo" } ] } } ] } },
  { "number": 106, "title": "no-status boundary", "stateReason": "COMPLETED",
    "projectItems": { "nodes": [ { "project": { "number": 6 },
      "fieldValues": { "nodes": [ { "field": { "name": "Iteration" }, "name": "Sprint 1" } ] } } ] } },
  { "number": 107, "title": "cancelled excluded", "stateReason": "NOT_PLANNED",
    "projectItems": { "nodes": [ { "project": { "number": 6 },
      "fieldValues": { "nodes": [ { "field": { "name": "Status" }, "name": "Cancelled" } ] } } ] } },
  { "number": 108, "title": "null reason drift",
    "projectItems": { "nodes": [ { "project": { "number": 6 },
      "fieldValues": { "nodes": [ { "field": { "name": "Status" }, "name": "Todo" } ] } } ] } }
] } } } }
JSON
)
  set +e
  actual=$(printf '%s' "$fixture" | jq -r --argjson pn 6 \
    --arg terminal_done "$TERM_DONE" --arg terminal_cancelled "$TERM_CANCELLED" \
    --arg no_reason "$NO_REASON" "$jq_prog" 2>/dev/null); jq_rc=$?
  set -e
  if [ "$jq_rc" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  ✓ jq pipeline runs without error"
  else
    FAIL=$((FAIL + 1)); FAILURES+=("jq pipeline errored (rc=$jq_rc)"); echo "  ✗ jq pipeline errored (rc=$jq_rc)" >&2
  fi
  # Exactly four drift rows — guards over-detection (e.g. a broken on-board scope letting
  # not-on-board / other-project issues through, or a Done-only filter re-admitting the
  # Cancelled row). Count lines carrying a TAB separator.
  line_count=$(printf '%s\n' "$actual" | grep -c $'\t' || true)
  if [ "$line_count" -eq 4 ]; then
    PASS=$((PASS + 1)); echo "  ✓ exactly 4 drift rows emitted"
  else
    FAIL=$((FAIL + 1)); FAILURES+=("expected 4 drift rows, got $line_count"); echo "  ✗ expected 4 drift rows, got $line_count" >&2
  fi
  # Each present-assert pins the WHOLE row, so the four-column order
  # (number / status / stateReason / title) is fixed here and not just the field values —
  # a transposition that keeps every value would still fail.
  # Case 1: COMPLETED + on-board(6) + Status="In Review" -> drift, status carried through.
  assert_present "$actual" "$(printf '101\tIn Review\tCOMPLETED\tdrift case')" "case1: COMPLETED on-board 非終端 -> drift row"
  # Case 6: COMPLETED + on-board(6) + no Status field -> drift as <no-status> (boundary).
  assert_present "$actual" "$(printf '106\t<no-status>\tCOMPLETED\tno-status boundary')" "case6: on-board without Status field -> <no-status> drift"
  # Case 2: Status already Done -> excluded.
  assert_absent "$actual" "done excluded" "case2: Status=Done excluded (AC-1)"
  # Case 3: NOT_PLANNED closure on a non-terminal board row -> drift, same as COMPLETED.
  assert_present "$actual" "$(printf '103\tTodo\tNOT_PLANNED\tnot_planned drift')" "case3: NOT_PLANNED on-board 非終端 -> drift row"
  # Case 4: not on the board (empty projectItems) -> excluded.
  assert_absent "$actual" "not on board" "case4: not-on-board excluded"
  # Case 5: on a different project (number != pn) -> excluded.
  assert_absent "$actual" "other project" "case5: other-project excluded"
  # Case 7: Status already Cancelled -> excluded, the other half of the terminal set (AC-1).
  assert_absent "$actual" "cancelled excluded" "case7: Status=Cancelled excluded (AC-1)"
  # Case 8: absent stateReason -> still drift, and the sentinel (not a bare `null` string
  # or an empty field) is what crosses the TSV boundary into the reconcile branch (AC-4).
  assert_present "$actual" "$(printf '108\tTodo\t%s\tnull reason drift' "$NO_REASON")" "case8: stateReason null -> sentinel を載せた drift row"
fi

# GraphQL-level board-membership scope: the projectItems page size must be positive. The
# jq fixture above cannot reach a `projectItems(first: 10)` -> `first: 0` break (that
# empties the GraphQL result before jq runs), so guard that literal statically here.
assert_file_contains "$DRIFT_SH" 'projectItems\(first: [1-9]' "GraphQL projectItems page size is positive (guards first: 0 break)"

echo ""
echo "[T-8] Behavioral: git-remote fast path resolves SSH alias origin, owner/repo threaded into graphql"
# Real git repo + SSH Host alias origin + deliberately-broken `gh repo view` +
# enabled:true config (bypassing the T-6 no-op gates so the repo-resolution
# block is actually reached). The graphql shim requires the exact resolved
# owner/repo — a regression to the gh repo view shorthand or a wrong-repo
# resolution fails loudly instead of passing silently.
T8_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-board-drift-t8-XXXXXX")
# T-7 の trap を上書きするため、その cleanup 対象 ($tmpd) も引き継ぐ
trap 'rm -rf "${tmpd:-}" "$T8_DIR"' EXIT
mkdir -p "$T8_DIR/repo/bin"
( cd "$T8_DIR/repo" && git init -q && git remote add origin "git@github.com-work:o/r.git" ) >/dev/null 2>&1
cat > "$T8_DIR/repo/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML
cat > "$T8_DIR/repo/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view")
    echo "should not be called - git-remote fast path must resolve first" >&2
    exit 1 ;;
  "api graphql")
    if ! { printf '%s\n' "$*" | grep -qE -- ' owner=o( |$)' && printf '%s\n' "$*" | grep -qE -- ' repo=r( |$)'; }; then
      echo "MOCK ASSERTION FAILED: expected -f owner=o -f repo=r, got: $*" >&2
      exit 1
    fi
    echo '{"data":{"repository":{"issues":{"nodes":[]}}}}' ;;
  *) exit 0 ;;
esac
GH_SHIM
chmod +x "$T8_DIR/repo/bin/gh"
set +e
t8_out=$(cd "$T8_DIR/repo" && PATH="$T8_DIR/repo/bin:$PATH" bash "$DRIFT_SH" --quiet 2>"$T8_DIR/stderr.txt")
t8_rc=$?
set -e
if [ "$t8_rc" -eq 0 ] && printf '%s' "$t8_out" | grep -q 'Total projects-board-drift findings: 0'; then
  PASS=$((PASS + 1)); echo "  ✓ run succeeds via git-remote fast path (exit 0, 0 findings)"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-8: expected exit 0 + 0-findings summary, got rc=$t8_rc; stderr: $(head -c 300 "$T8_DIR/stderr.txt" | tr '\n' ' ')")
  echo "  ✗ run failed (exit $t8_rc)" >&2
fi
if grep -qE 'MOCK ASSERTION FAILED|gh repo view failed' "$T8_DIR/stderr.txt" 2>/dev/null; then
  FAIL=$((FAIL + 1)); FAILURES+=("T-8: wrong owner/repo value or fallback to gh repo view: $(head -c 300 "$T8_DIR/stderr.txt" | tr '\n' ' ')")
  echo "  ✗ wrong owner/repo value or gh repo view fallback was hit" >&2
else
  PASS=$((PASS + 1)); echo "  ✓ exact owner=o repo=r threaded to graphql, gh repo view never consulted"
fi

echo ""
echo "[T-9] Behavioral: --reconcile drives Status -> Done for a COMPLETED closure"
# The reconcile path hands off to scripts/projects-status-update.sh, which is invoked by
# absolute path and cannot be shimmed — so the assertion is made at the gh boundary that
# helper drives. The shim answers both graphql shapes (the drift scan is the one carrying
# `states: CLOSED`), serves the Status field options, and records the item-edit arguments.
# Helper re-query ITEM must include fieldValues (object + nodes array): a missing key is
# unreadable and the helper refuses to write (AC-4). Empty / Status-less nodes stay unset.
T9_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-board-drift-t9-XXXXXX")
trap 'rm -rf "${tmpd:-}" "$T8_DIR" "$T9_DIR"' EXIT
mkdir -p "$T9_DIR/repo/bin"
( cd "$T9_DIR/repo" && git init -q && git remote add origin "git@github.com:o/r.git" ) >/dev/null 2>&1
cat > "$T9_DIR/repo/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML
cat > "$T9_DIR/repo/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "api graphql")
    if printf '%s\n' "$*" | grep -q 'states: CLOSED'; then
      cat <<'SCAN'
{"data":{"repository":{"issues":{"nodes":[
  {"number":103,"title":"closed as completed","stateReason":"COMPLETED",
   "projectItems":{"nodes":[{"project":{"number":1},
     "fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}
]}}}}
SCAN
    else
      cat <<'ITEM'
{"data":{"repository":{"issue":{"url":"https://github.com/o/r/issues/103","projectItems":{"nodes":[{"id":"ITEM_103","project":{"id":"PROJ_1","number":1},"fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}}}}
ITEM
    fi ;;
  "project field-list")
    echo '{"fields":[{"id":"FIELD_STATUS","name":"Status","options":[{"id":"OPT_TODO","name":"Todo"},{"id":"OPT_DONE","name":"Done"}]}]}' ;;
  "project item-edit")
    printf '%s\n' "$*" > "$GH_ITEM_EDIT_LOG" ;;
  *) exit 0 ;;
esac
GH_SHIM
chmod +x "$T9_DIR/repo/bin/gh"
set +e
t9_out=$(cd "$T9_DIR/repo" && PATH="$T9_DIR/repo/bin:$PATH" GH_ITEM_EDIT_LOG="$T9_DIR/item-edit.args" \
  bash "$DRIFT_SH" --reconcile --quiet 2>"$T9_DIR/stderr.txt")
t9_rc=$?
set -e
# exit 1 = drift detected (reconcile does not clear the finding); the summary proves the
# helper reported success rather than a swallowed failure.
if [ "$t9_rc" -eq 1 ] && printf '%s' "$t9_out" | grep -q 'reconcile summary: 1 updated, 0 failed'; then
  PASS=$((PASS + 1)); echo "  ✓ reconcile reports 1 updated, 0 failed (exit 1 = drift detected)"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-9: expected exit 1 + '1 updated, 0 failed', got rc=$t9_rc; stdout: $(printf '%s' "$t9_out" | tr '\n' ' ' | head -c 300)")
  echo "  ✗ reconcile summary wrong (exit $t9_rc)" >&2
fi
# findings 行は行まるごと固定する。部分一致だけだと script の findings 行を emit する echo
# (`[projects-board-drift] #N ...`) の書式が壊れても通ってしまい、契約が「現行のまま維持する」と
# 規定した唯一の出力を誰も守らなくなる。
assert_present "$t9_out" "$(printf '[projects-board-drift] #103 "closed as completed" status="Todo" (expected Done) -> reconciled to Done')" "T-9: findings 行形式が維持されている" # drift-check-ignore
# lint Phase 3.18 が機械読みする件数 sentinel。0 固定などの退行は exit 1 と矛盾したまま
# 「drift なし」と読ませるため、実件数まで含めて固定する。
assert_present "$t9_out" '==> Total projects-board-drift findings: 1' \
  "T-9: 件数 sentinel が実件数を報告する"
if [ -f "$T9_DIR/item-edit.args" ] && grep -q -- '--single-select-option-id OPT_DONE' "$T9_DIR/item-edit.args"; then
  PASS=$((PASS + 1)); echo "  ✓ item-edit called with the Done option id"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-9: item-edit not called with Done option id (args: $(cat "$T9_DIR/item-edit.args" 2>/dev/null | head -c 300))")
  echo "  ✗ item-edit not called with the Done option id" >&2
fi

echo ""
echo "[T-10] Behavioral: a failing scan exits 2 with a diagnostic (never 1 = 'drift detected')"
# lint Phase 3.18 reads exit 1 as a drift warning, so an API/pipeline failure must not
# borrow that code — it exits 2 and says why.
T10_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-board-drift-t10-XXXXXX")
trap 'rm -rf "${tmpd:-}" "$T8_DIR" "$T9_DIR" "$T10_DIR"' EXIT
mkdir -p "$T10_DIR/repo/bin"
( cd "$T10_DIR/repo" && git init -q && git remote add origin "git@github.com:o/r.git" ) >/dev/null 2>&1
cat > "$T10_DIR/repo/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML
cat > "$T10_DIR/repo/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "api graphql")
    echo "HTTP 502: Bad gateway" >&2
    exit 1 ;;
  *) exit 0 ;;
esac
GH_SHIM
chmod +x "$T10_DIR/repo/bin/gh"
set +e
(cd "$T10_DIR/repo" && PATH="$T10_DIR/repo/bin:$PATH" bash "$DRIFT_SH" --quiet >"$T10_DIR/stdout.txt" 2>"$T10_DIR/stderr.txt")
t10_rc=$?
set -e
if [ "$t10_rc" -eq 2 ]; then
  PASS=$((PASS + 1)); echo "  ✓ graphql failure exits 2 (invocation error, not drift)"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-10: expected exit 2, got $t10_rc"); echo "  ✗ expected exit 2, got $t10_rc" >&2
fi
if grep -q 'ERROR: gh api graphql or jq pipeline failed' "$T10_DIR/stderr.txt" && \
   grep -q 'gh: HTTP 502' "$T10_DIR/stderr.txt"; then
  PASS=$((PASS + 1)); echo "  ✓ stderr carries the ERROR line and the captured gh diagnostic"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-10: missing ERROR line or gh diagnostic: $(head -c 300 "$T10_DIR/stderr.txt" | tr '\n' ' ')")
  echo "  ✗ stderr missing the ERROR line or the gh diagnostic" >&2
fi

echo ""
echo "[T-11] Behavioral: a failed reconcile surfaces the helper's warnings on stderr"
# projects-status-update.sh は non_blocking の handled failure で自身の stderr へ何も書かず、
# 診断を stdout JSON の .warnings[] にのみ載せる。呼び出し側が .result しか読まないと失敗理由が
# 全出力から消えるため、その転記経路を pin する。--quiet を付けずに走らせるのは、非 quiet の
# stderr 経路がどのテストからも踏まれていなかったため。
T11_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-board-drift-t11-XXXXXX")
trap 'rm -rf "${tmpd:-}" "$T8_DIR" "$T9_DIR" "$T10_DIR" "$T11_DIR"' EXIT
mkdir -p "$T11_DIR/repo/bin"
( cd "$T11_DIR/repo" && git init -q && git remote add origin "git@github.com:o/r.git" ) >/dev/null 2>&1
cat > "$T11_DIR/repo/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML
cat > "$T11_DIR/repo/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "api graphql")
    if printf '%s\n' "$*" | grep -q 'states: CLOSED'; then
      cat <<'SCAN'
{"data":{"repository":{"issues":{"nodes":[
  {"number":103,"title":"closed as completed","stateReason":"COMPLETED",
   "projectItems":{"nodes":[{"project":{"number":1},
     "fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}
]}}}}
SCAN
    else
      cat <<'ITEM'
{"data":{"repository":{"issue":{"url":"https://github.com/o/r/issues/103","projectItems":{"nodes":[{"id":"ITEM_103","project":{"id":"PROJ_1","number":1},"fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}}}}
ITEM
    fi ;;
  "project field-list")
    echo '{"fields":[{"id":"FIELD_STATUS","name":"Status","options":[{"id":"OPT_TODO","name":"Todo"},{"id":"OPT_DONE","name":"Done"}]}]}' ;;
  "project item-edit")
    echo "HTTP 403: Resource not accessible by integration" >&2
    exit 1 ;;
  *) exit 0 ;;
esac
GH_SHIM
chmod +x "$T11_DIR/repo/bin/gh"
set +e
t11_out=$(cd "$T11_DIR/repo" && PATH="$T11_DIR/repo/bin:$PATH" bash "$DRIFT_SH" --reconcile 2>"$T11_DIR/stderr.txt")
t11_rc=$?
set -e
if [ "$t11_rc" -eq 1 ] && printf '%s' "$t11_out" | grep -q 'reconcile summary: 0 updated, 1 failed'; then
  PASS=$((PASS + 1)); echo "  ✓ failed reconcile is counted (0 updated, 1 failed) and still exits 1"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-11: expected exit 1 + '0 updated, 1 failed', got rc=$t11_rc; stdout: $(printf '%s' "$t11_out" | tr '\n' ' ' | head -c 300)")
  echo "  ✗ reconcile failure summary wrong (exit $t11_rc)" >&2
fi
if grep -q 'projects-board-drift: reconcile #103:' "$T11_DIR/stderr.txt" && grep -q 'HTTP 403' "$T11_DIR/stderr.txt"; then # drift-check-ignore
  PASS=$((PASS + 1)); echo "  ✓ helper warnings (with the underlying gh error) reach stderr"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-11: helper warnings missing from stderr: $(head -c 300 "$T11_DIR/stderr.txt" | tr '\n' ' ')")
  echo "  ✗ helper warnings did not reach stderr" >&2
fi

echo ""
echo "[T-12/T-13/T-14] Behavioral: the terminal-status split end to end"
# The three cases differ only in the CLOSED-scan payload, so the repo, config and gh shim
# are built once and the scan JSON is injected through a file the shim cats. The shim's
# Status field carries a Cancelled option, which is what lets the reconcile destination be
# read back from the recorded item-edit rather than inferred from the summary line.
T12_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-board-drift-t12-XXXXXX")
trap 'rm -rf "${tmpd:-}" "$T8_DIR" "$T9_DIR" "$T10_DIR" "$T11_DIR" "$T12_DIR"' EXIT

_setup_terminal_repo() {
  local dir="$1"
  mkdir -p "$dir/bin"
  ( cd "$dir" && git init -q && git remote add origin "git@github.com:o/r.git" ) >/dev/null 2>&1
  cat > "$dir/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML
  cat > "$dir/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "api graphql")
    if printf '%s\n' "$*" | grep -q 'states: CLOSED'; then
      cat "$GH_SCAN_FILE"
    else
      cat <<'ITEM'
{"data":{"repository":{"issue":{"url":"https://github.com/o/r/issues/203","projectItems":{"nodes":[{"id":"ITEM_203","project":{"id":"PROJ_1","number":1},"fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}}}}
ITEM
    fi ;;
  "project field-list")
    echo '{"fields":[{"id":"FIELD_STATUS","name":"Status","options":[{"id":"OPT_TODO","name":"Todo"},{"id":"OPT_DONE","name":"Done"},{"id":"OPT_CANCELLED","name":"Cancelled"}]}]}' ;;
  "project item-edit")
    printf '%s\n' "$*" > "$GH_ITEM_EDIT_LOG" ;;
  *) exit 0 ;;
esac
GH_SHIM
  chmod +x "$dir/bin/gh"
}

# T-12: NOT_PLANNED on a non-terminal board row -> Cancelled (AC-2).
t12_repo="$T12_DIR/not-planned"; _setup_terminal_repo "$t12_repo"
cat > "$T12_DIR/scan-not-planned.json" <<'SCAN'
{"data":{"repository":{"issues":{"nodes":[
  {"number":203,"title":"closed as not planned","stateReason":"NOT_PLANNED",
   "projectItems":{"nodes":[{"project":{"number":1},
     "fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}
]}}}}
SCAN
set +e
t12_out=$(cd "$t12_repo" && PATH="$t12_repo/bin:$PATH" \
  GH_SCAN_FILE="$T12_DIR/scan-not-planned.json" GH_ITEM_EDIT_LOG="$T12_DIR/t12-item-edit.args" \
  bash "$DRIFT_SH" --reconcile --quiet 2>"$T12_DIR/t12-stderr.txt")
t12_rc=$?
set -e
if [ "$t12_rc" -eq 1 ] && printf '%s' "$t12_out" | grep -q 'reconcile summary: 1 updated, 0 failed'; then
  PASS=$((PASS + 1)); echo "  ✓ T-12: NOT_PLANNED row reconciles successfully (exit 1 = drift detected)"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-12: expected exit 1 + '1 updated, 0 failed', got rc=$t12_rc; stdout: $(printf '%s' "$t12_out" | tr '\n' ' ' | head -c 300)")
  echo "  ✗ T-12: reconcile summary wrong (exit $t12_rc)" >&2
fi
# The destination is asserted at the gh boundary, not from the summary line: only the
# recorded option id distinguishes a real Cancelled update from a Done update mislabelled
# in the report text.
if [ -f "$T12_DIR/t12-item-edit.args" ] && grep -q -- '--single-select-option-id OPT_CANCELLED' "$T12_DIR/t12-item-edit.args"; then
  PASS=$((PASS + 1)); echo "  ✓ T-12 (AC-2): item-edit called with the Cancelled option id"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-12: item-edit not called with Cancelled option id (args: $(head -c 300 "$T12_DIR/t12-item-edit.args" 2>/dev/null))")
  echo "  ✗ T-12: item-edit not called with the Cancelled option id" >&2
fi
# The report line and the count sentinel are pinned whole: the destination now varies, so
# the one place a reader sees it must keep saying which terminal Status was chosen.
assert_present "$t12_out" "$(printf '[projects-board-drift] #203 "closed as not planned" status="Todo" (expected Cancelled) -> reconciled to Cancelled')" "T-12: findings 行が reconcile 先 Cancelled を示す" # drift-check-ignore
assert_present "$t12_out" '==> Total projects-board-drift findings: 1' \
  "T-12: 件数 sentinel が実件数を報告する"

# T-13: an unclassified closure reason -> Done, with exactly one WARNING (AC-4).
# Run WITHOUT --quiet: the WARNING is the whole point, and --quiet suppresses it.
t13_repo="$T12_DIR/null-reason"; _setup_terminal_repo "$t13_repo"
cat > "$T12_DIR/scan-null-reason.json" <<'SCAN'
{"data":{"repository":{"issues":{"nodes":[
  {"number":203,"title":"closed without a reason","stateReason":null,
   "projectItems":{"nodes":[{"project":{"number":1},
     "fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}
]}}}}
SCAN
set +e
t13_out=$(cd "$t13_repo" && PATH="$t13_repo/bin:$PATH" \
  GH_SCAN_FILE="$T12_DIR/scan-null-reason.json" GH_ITEM_EDIT_LOG="$T12_DIR/t13-item-edit.args" \
  bash "$DRIFT_SH" --reconcile 2>"$T12_DIR/t13-stderr.txt")
t13_rc=$?
set -e
if [ "$t13_rc" -eq 1 ] && printf '%s' "$t13_out" | grep -q 'reconcile summary: 1 updated, 0 failed'; then
  PASS=$((PASS + 1)); echo "  ✓ T-13: unclassified reason still reconciles (not left behind)"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-13: expected exit 1 + '1 updated, 0 failed', got rc=$t13_rc; stdout: $(printf '%s' "$t13_out" | tr '\n' ' ' | head -c 300)")
  echo "  ✗ T-13: reconcile summary wrong (exit $t13_rc)" >&2
fi
if [ -f "$T12_DIR/t13-item-edit.args" ] && grep -q -- '--single-select-option-id OPT_DONE' "$T12_DIR/t13-item-edit.args"; then
  PASS=$((PASS + 1)); echo "  ✓ T-13 (AC-4): item-edit called with the Done option id"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-13: item-edit not called with Done option id (args: $(head -c 300 "$T12_DIR/t13-item-edit.args" 2>/dev/null))")
  echo "  ✗ T-13: item-edit not called with the Done option id" >&2
fi
# Exactly one: a silent fallback (0) and a per-retry storm (>1) are both regressions.
t13_warn_count=$(grep -c 'closure reason is unavailable' "$T12_DIR/t13-stderr.txt" || true)
if [ "$t13_warn_count" -eq 1 ]; then
  PASS=$((PASS + 1)); echo "  ✓ T-13 (AC-4): exactly one WARNING names the unclassified reason"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-13: expected exactly 1 unclassified-reason WARNING, got $t13_warn_count: $(head -c 300 "$T12_DIR/t13-stderr.txt" | tr '\n' ' ')")
  echo "  ✗ T-13: expected exactly 1 unclassified-reason WARNING, got $t13_warn_count" >&2
fi

# T-13b: DUPLICATE is a mapped reason. Without --quiet, one run must show destination,
# silence of the unmapped-reason WARNING, and the findings line together — --quiet would
# make "no WARNING" a vacuous pass.
t13b_repo="$T12_DIR/duplicate-reason"; _setup_terminal_repo "$t13b_repo"
cat > "$T12_DIR/scan-duplicate.json" <<'SCAN'
{"data":{"repository":{"issues":{"nodes":[
  {"number":203,"title":"closed as duplicate","stateReason":"DUPLICATE",
   "projectItems":{"nodes":[{"project":{"number":1},
     "fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}
]}}}}
SCAN
set +e
t13b_out=$(cd "$t13b_repo" && PATH="$t13b_repo/bin:$PATH" \
  GH_SCAN_FILE="$T12_DIR/scan-duplicate.json" GH_ITEM_EDIT_LOG="$T12_DIR/t13b-item-edit.args" \
  bash "$DRIFT_SH" --reconcile 2>"$T12_DIR/t13b-stderr.txt")
t13b_rc=$?
set -e
if [ "$t13b_rc" -eq 1 ] && printf '%s' "$t13b_out" | grep -q 'reconcile summary: 1 updated, 0 failed'; then
  PASS=$((PASS + 1)); echo "  ✓ T-13b: DUPLICATE still reconciles (not left behind)"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-13b: expected exit 1 + '1 updated, 0 failed', got rc=$t13b_rc; stdout: $(printf '%s' "$t13b_out" | tr '\n' ' ' | head -c 300)")
  echo "  ✗ T-13b: reconcile summary wrong (exit $t13b_rc)" >&2
fi
if [ -f "$T12_DIR/t13b-item-edit.args" ] && grep -q -- '--single-select-option-id OPT_CANCELLED' "$T12_DIR/t13b-item-edit.args"; then
  PASS=$((PASS + 1)); echo "  ✓ T-13b: item-edit called with the Cancelled option id"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-13b: item-edit not called with Cancelled option id (args: $(head -c 300 "$T12_DIR/t13b-item-edit.args" 2>/dev/null))")
  echo "  ✗ T-13b: item-edit not called with the Cancelled option id" >&2
fi
assert_present "$t13b_out" "$(printf '[projects-board-drift] #203 "closed as duplicate" status="Todo" (expected Cancelled) -> reconciled to Cancelled')" "T-13b: findings 行が reconcile 先 Cancelled を示す" # drift-check-ignore
t13b_unmapped_count=$(grep -c 'has no mapped terminal Status' "$T12_DIR/t13b-stderr.txt" || true)
if [ "$t13b_unmapped_count" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "  ✓ T-13b: no unmapped-reason WARNING on DUPLICATE"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-13b: expected 0 unmapped-reason WARNING, got $t13b_unmapped_count: $(head -c 300 "$T12_DIR/t13b-stderr.txt" | tr '\n' ' ')")
  echo "  ✗ T-13b: expected 0 unmapped-reason WARNING, got $t13b_unmapped_count" >&2
fi

# T-13d: a fictional enum keeps the catch-all alive, separate from T-13's null path
# (`closure reason is unavailable`). WARNING must name the observed value on that line.
t13d_repo="$T12_DIR/future-reason"; _setup_terminal_repo "$t13d_repo"
cat > "$T12_DIR/scan-future.json" <<'SCAN'
{"data":{"repository":{"issues":{"nodes":[
  {"number":203,"title":"closed for a future reason","stateReason":"SOME_FUTURE_REASON",
   "projectItems":{"nodes":[{"project":{"number":1},
     "fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}
]}}}}
SCAN
set +e
t13d_out=$(cd "$t13d_repo" && PATH="$t13d_repo/bin:$PATH" \
  GH_SCAN_FILE="$T12_DIR/scan-future.json" GH_ITEM_EDIT_LOG="$T12_DIR/t13d-item-edit.args" \
  bash "$DRIFT_SH" --reconcile 2>"$T12_DIR/t13d-stderr.txt")
t13d_rc=$?
set -e
if [ "$t13d_rc" -eq 1 ] && printf '%s' "$t13d_out" | grep -q 'reconcile summary: 1 updated, 0 failed'; then
  PASS=$((PASS + 1)); echo "  ✓ T-13d: unknown enum still reconciles (not left behind)"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-13d: expected exit 1 + '1 updated, 0 failed', got rc=$t13d_rc; stdout: $(printf '%s' "$t13d_out" | tr '\n' ' ' | head -c 300)")
  echo "  ✗ T-13d: reconcile summary wrong (exit $t13d_rc)" >&2
fi
if [ -f "$T12_DIR/t13d-item-edit.args" ] && grep -q -- '--single-select-option-id OPT_DONE' "$T12_DIR/t13d-item-edit.args"; then
  PASS=$((PASS + 1)); echo "  ✓ T-13d: item-edit called with the Done option id"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-13d: item-edit not called with Done option id (args: $(head -c 300 "$T12_DIR/t13d-item-edit.args" 2>/dev/null))")
  echo "  ✗ T-13d: item-edit not called with the Done option id" >&2
fi
assert_present "$t13d_out" "$(printf '[projects-board-drift] #203 "closed for a future reason" status="Todo" (expected Done) -> reconciled to Done')" "T-13d: findings 行が reconcile 先 Done を示す" # drift-check-ignore
t13d_warn_count=$(grep -c 'has no mapped terminal Status' "$T12_DIR/t13d-stderr.txt" || true)
if [ "$t13d_warn_count" -eq 1 ] && grep -q 'SOME_FUTURE_REASON.*has no mapped terminal Status' "$T12_DIR/t13d-stderr.txt"; then
  PASS=$((PASS + 1)); echo "  ✓ T-13d: exactly one WARNING names the unknown enum"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-13d: expected exactly 1 WARNING naming SOME_FUTURE_REASON, got $t13d_warn_count: $(head -c 300 "$T12_DIR/t13d-stderr.txt" | tr '\n' ' ')")
  echo "  ✗ T-13d: expected exactly 1 WARNING naming SOME_FUTURE_REASON, got $t13d_warn_count" >&2
fi
if grep -q 'closure reason is unavailable' "$T12_DIR/t13d-stderr.txt"; then
  FAIL=$((FAIL + 1)); FAILURES+=("T-13d: unknown enum took the null-reason WARNING path")
  echo "  ✗ T-13d: unknown enum must not use the null-reason WARNING" >&2
else
  PASS=$((PASS + 1)); echo "  ✓ T-13d: unknown enum is not the null-reason path"
fi
# COMPLETED must NOT take that path — otherwise the catch-all warns on every normal row and
# the signal is worthless. T-9 pins COMPLETED's destination but runs --quiet, so it cannot
# observe stderr; this runs the same reason without --quiet to pin its silence.
t13c_repo="$T12_DIR/completed-reason"; _setup_terminal_repo "$t13c_repo"
cat > "$T12_DIR/scan-completed.json" <<'SCAN'
{"data":{"repository":{"issues":{"nodes":[
  {"number":203,"title":"closed as completed","stateReason":"COMPLETED",
   "projectItems":{"nodes":[{"project":{"number":1},
     "fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}
]}}}}
SCAN
set +e
( cd "$t13c_repo" && PATH="$t13c_repo/bin:$PATH" \
  GH_SCAN_FILE="$T12_DIR/scan-completed.json" GH_ITEM_EDIT_LOG="$T12_DIR/t13c-item-edit.args" \
  bash "$DRIFT_SH" --reconcile >/dev/null 2>"$T12_DIR/t13c-stderr.txt" )
t13c_rc=$?
set -e
# "no WARNING" alone would also pass when the run never reached the arm at all — a typo in
# the scan fixture path makes the shim's cat fail, the script exits 2, and stderr is simply
# missing the string. Pair the absence with a positive control: the run must have found the
# drift row (exit 1) and reconciled it to Done, so silence means "took the silent arm", not
# "took no arm".
if [ "$t13c_rc" -eq 1 ] \
  && grep -q -- '--single-select-option-id OPT_DONE' "$T12_DIR/t13c-item-edit.args" 2>/dev/null \
  && ! grep -q 'has no mapped terminal Status' "$T12_DIR/t13c-stderr.txt"; then
  PASS=$((PASS + 1)); echo "  ✓ T-13b: COMPLETED reconciles to Done and stays on the silent arm"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-13b: COMPLETED negative control failed (rc=$t13c_rc; item-edit: $(head -c 200 "$T12_DIR/t13c-item-edit.args" 2>/dev/null); stderr: $(head -c 300 "$T12_DIR/t13c-stderr.txt" | tr '\n' ' '))")
  echo "  ✗ T-13b: COMPLETED negative control failed (rc=$t13c_rc)" >&2
fi

# T-14: a board already on Cancelled is not drift, so --reconcile cannot touch it (AC-1).
# Run with --reconcile (not --dry-run): the stronger claim is that the destructive mode
# leaves the row alone, which a dry run could not show.
t14_repo="$T12_DIR/already-cancelled"; _setup_terminal_repo "$t14_repo"
cat > "$T12_DIR/scan-cancelled.json" <<'SCAN'
{"data":{"repository":{"issues":{"nodes":[
  {"number":203,"title":"already cancelled","stateReason":"NOT_PLANNED",
   "projectItems":{"nodes":[{"project":{"number":1},
     "fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Cancelled"}]}}]}}
]}}}}
SCAN
set +e
t14_out=$(cd "$t14_repo" && PATH="$t14_repo/bin:$PATH" \
  GH_SCAN_FILE="$T12_DIR/scan-cancelled.json" GH_ITEM_EDIT_LOG="$T12_DIR/t14-item-edit.args" \
  bash "$DRIFT_SH" --reconcile --quiet 2>"$T12_DIR/t14-stderr.txt")
t14_rc=$?
set -e
if [ "$t14_rc" -eq 0 ] && printf '%s' "$t14_out" | grep -q '==> Total projects-board-drift findings: 0'; then
  PASS=$((PASS + 1)); echo "  ✓ T-14 (AC-1): Cancelled row reports 0 findings and exits 0"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-14: expected exit 0 + 0 findings, got rc=$t14_rc; stdout: $(printf '%s' "$t14_out" | tr '\n' ' ' | head -c 300)")
  echo "  ✗ T-14: expected exit 0 + 0 findings (exit $t14_rc)" >&2
fi
if [ -f "$T12_DIR/t14-item-edit.args" ]; then
  FAIL=$((FAIL + 1)); FAILURES+=("T-14: item-edit was called on an already-terminal row (args: $(head -c 300 "$T12_DIR/t14-item-edit.args"))")
  echo "  ✗ T-14: item-edit was called on an already-terminal row" >&2
else
  PASS=$((PASS + 1)); echo "  ✓ T-14 (AC-1): no item-edit issued — the cancellation is left intact"
fi

echo ""
echo "[T-15] Static: terminal Status consumers cite the SoT by section name, never by line"
# AC-7. Each consumer must reach the definition through a name that survives edits to the
# reference file. A line-number anchor (`#L225`, `:225`) is the failure this pins against:
# it silently rots into pointing at unrelated prose. The pattern is deliberately narrow —
# a section anchor like `#248-terminal-status-set` also begins with digits, and it is the
# repo's normal link form, so a looser pattern would reject the very convention AC-7 asks
# for.
TERMINAL_SOT="$REPO_ROOT/plugins/rite/references/projects-integration.md"
assert_file_contains "$TERMINAL_SOT" '^### 2\.4\.8 Terminal Status Set$' "SoT 節が projects-integration.md に存在する"
for consumer in \
  "plugins/rite/hooks/scripts/projects-board-drift-check.sh" \
  "plugins/rite/hooks/post-compact.sh" \
  "plugins/rite/hooks/scripts/projects-status-gate.sh" \
  "plugins/rite/skills/lint/references/plugin-checks-rationale.md" ; do
  assert_file_contains "$REPO_ROOT/$consumer" 'Terminal Status Set' \
    "$consumer が終端 Status 集合を semantic name で参照する"
  assert_file_lacks "$REPO_ROOT/$consumer" 'projects-integration\.md(:[0-9]+|#L[0-9]+)' \
    "$consumer が SoT を行番号で参照していない"
done
# Mapping contents, not just the heading: a "未決" / open-question leftover in rule 2
# would still cite the section name and pass the loop above.
sot_248=$(awk '/^### 2\.4\.8 Terminal Status Set$/,/^## 2\.5 /' "$TERMINAL_SOT")
assert_present "$sot_248" "$(printf '| `Cancelled` | Work abandoned — closed as not planned (wontfix, superseded) or as duplicate | `NOT_PLANNED`, `DUPLICATE` |')" \
  "§2.4.8 Cancelled 行の closure reason 列に DUPLICATE が載る"
assert_absent "$sot_248" "open question" \
  "§2.4.8 rule 2 から open question が消えている"
assert_absent "$sot_248" "this mapping does not claim" \
  "§2.4.8 rule 2 から this mapping does not claim が消えている"
RATIONALE="$REPO_ROOT/plugins/rite/skills/lint/references/plugin-checks-rationale.md"
assert_file_contains "$RATIONALE" '`NOT_PLANNED` / `DUPLICATE` → `Cancelled`' \
  "plugin-checks-rationale が NOT_PLANNED/DUPLICATE → Cancelled 無警告を述べる"
assert_file_contains "$RATIONALE" '`COMPLETED` → `Done`' \
  "plugin-checks-rationale が COMPLETED → Done 無警告を述べる"

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for msg in "${FAILURES[@]}"; do echo "  - $msg"; done
  exit 1
fi
echo "All projects-board-drift-check checks passed."
