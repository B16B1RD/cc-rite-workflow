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
#        copy) classifies all six cases correctly (COMPLETED drift / NOT_PLANNED drift /
#        Done / not-on-board / other-project / <no-status>), catching semantic breaks
#        that preserve jq literals but flip scoping (offline, jq-only, no gh)
#   T-9: behavioral — --reconcile drives the Status update helper to "Done" for a
#        closure reason that used to be excluded (offline, gh shim records the item-edit)
#  T-10: behavioral — a failing GraphQL scan exits 2 with a diagnostic, so lint never
#        misreads an invocation/API error as "drift detected" (exit 1)
#  T-11: behavioral — a failed reconcile surfaces the Status-update helper's warnings on
#        stderr (the helper puts them only in its stdout JSON), exercising the non-quiet path
#
# Usage: bash plugins/rite/hooks/tests/projects-board-drift-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DRIFT_SH="$REPO_ROOT/plugins/rite/hooks/scripts/projects-board-drift-check.sh"

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
# Detection: anchor asserts to the load-bearing jq predicates (with quotes), NOT to the header
# comments (which spell Done without the jq quoting), so deleting the detection logic actually
# fails the suite. Board membership is the only remaining inclusion gate, so pin its exact form;
# the companion absence assert keeps a closure-reason filter from creeping back into the source
# (the board has no terminal Status other than Done, so no closure reason may be filtered out).
assert_file_contains "$DRIFT_SH" 'select\(\$pitem != null\)' "board 掲載のみで絞る (closure reason 非依存)"
assert_file_lacks "$DRIFT_SH" 'stateReason' "closure reason への依存が残っていない"
assert_file_contains "$DRIFT_SH" 'select.*\$st.*!= "Done"' "AC-1: drift when board Status != Done"
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
echo "[T-7] Behavioral fixture: jq detection pipeline classifies all six cases (semantic-break guard)"
# Extract the EXACT jq detection program from the source so this exercises the real
# pipeline, not a copy. A semantic break that T-5's literal grep cannot see — e.g.
# $pitem != null -> == null, select($st != "Done") -> == "Done", or dropping the
# `.project.number == $pn` board scoping — changes the classification below and fails
# here. Capture the lines between the `jq -r --argjson pn` invocation and its
# `2>"${jq_err...}"` redirect (the only post-marker line containing `jq_err`).
jq_prog=$(awk '
  /jq -r --argjson pn/ { capturing=1; next }
  capturing && /jq_err/ { capturing=0; next }
  capturing { print }
' "$DRIFT_SH")

if [ -z "$jq_prog" ]; then
  FAIL=$((FAIL + 1)); FAILURES+=("could not extract jq detection program from source")
  echo "  ✗ could not extract jq detection program from source" >&2
else
  PASS=$((PASS + 1)); echo "  ✓ extracted jq detection program from source"
  # GraphQL-shaped fixture (models `gh api graphql` output) covering all six cases.
  # project_number ($pn) = 6. Titles are unique so present/absent asserts key on them.
  # #101 / #103 / #106 are drift; #102 / #104 / #105 must be excluded. The stateReason
  # values are retained (the query no longer selects the field) so the two closure reasons
  # sit side by side and a reintroduced closure-reason filter drops #103 and fails here.
  # The bare {} node in #101 mirrors GraphQL emitting non-single-select fieldValues as
  # empty objects.
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
      "fieldValues": { "nodes": [ { "field": { "name": "Iteration" }, "name": "Sprint 1" } ] } } ] } }
] } } } }
JSON
)
  set +e
  actual=$(printf '%s' "$fixture" | jq -r --argjson pn 6 "$jq_prog" 2>/dev/null); jq_rc=$?
  set -e
  if [ "$jq_rc" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  ✓ jq pipeline runs without error"
  else
    FAIL=$((FAIL + 1)); FAILURES+=("jq pipeline errored (rc=$jq_rc)"); echo "  ✗ jq pipeline errored (rc=$jq_rc)" >&2
  fi
  # Exactly three drift rows — guards over-detection (e.g. a broken on-board scope letting
  # not-on-board / other-project issues through). Count lines carrying a TAB separator.
  line_count=$(printf '%s\n' "$actual" | grep -c $'\t' || true)
  if [ "$line_count" -eq 3 ]; then
    PASS=$((PASS + 1)); echo "  ✓ exactly 3 drift rows emitted"
  else
    FAIL=$((FAIL + 1)); FAILURES+=("expected 3 drift rows, got $line_count"); echo "  ✗ expected 3 drift rows, got $line_count" >&2
  fi
  # Case 1: COMPLETED + on-board(6) + Status="In Review" -> drift, status carried through.
  assert_present "$actual" "$(printf '101\tIn Review\tdrift case')" "case1: COMPLETED on-board non-Done -> drift row"
  # Case 6: COMPLETED + on-board(6) + no Status field -> drift as <no-status> (boundary).
  assert_present "$actual" "$(printf '106\t<no-status>\tno-status boundary')" "case6: on-board without Status field -> <no-status> drift"
  # Case 2: Status already Done -> excluded.
  assert_absent "$actual" "done excluded" "case2: Status=Done excluded (AC-1)"
  # Case 3: NOT_PLANNED closure on a non-Done board row -> drift, same as COMPLETED.
  assert_present "$actual" "$(printf '103\tTodo\tnot_planned drift')" "case3: NOT_PLANNED on-board non-Done -> drift row"
  # Case 4: not on the board (empty projectItems) -> excluded.
  assert_absent "$actual" "not on board" "case4: not-on-board excluded"
  # Case 5: on a different project (number != pn) -> excluded.
  assert_absent "$actual" "other project" "case5: other-project excluded"
fi

# GraphQL-level board-membership scope: the projectItems page size must be positive. The
# jq fixture above cannot reach a `projectItems(first: 10)` -> `first: 0` break (that
# empties the GraphQL result before jq runs), so guard that literal statically here.
assert_file_contains "$DRIFT_SH" 'projectItems\(first: [1-9]' "GraphQL projectItems page size is positive (guards first: 0 break)"

echo ""
echo "[T-8] Behavioral: git-remote fast path resolves SSH alias origin, owner/repo threaded into graphql (#1899)"
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
echo "[T-9] Behavioral: --reconcile drives Status -> Done for a wontfix/duplicate closure"
# The reconcile path hands off to scripts/projects-status-update.sh, which is invoked by
# absolute path and cannot be shimmed — so the assertion is made at the gh boundary that
# helper drives. The shim answers both graphql shapes (the drift scan is the one carrying
# `states: CLOSED`), serves the Status field options, and records the item-edit arguments.
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
  {"number":103,"title":"closed as duplicate",
   "projectItems":{"nodes":[{"project":{"number":1},
     "fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}
]}}}}
SCAN
    else
      cat <<'ITEM'
{"data":{"repository":{"issue":{"url":"https://github.com/o/r/issues/103",
  "projectItems":{"nodes":[{"id":"ITEM_103","project":{"id":"PROJ_1","number":1}}]}}}}}
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
# findings 行は行まるごと固定する。部分一致だけだと script L270 の書式が壊れても通ってしまい、
# 契約が「現行のまま維持する」と規定した唯一の出力を誰も守らなくなる。
assert_present "$t9_out" "$(printf '[projects-board-drift] #103 "closed as duplicate" status="Todo" (expected Done) -> reconciled to Done')" \
  "T-9: findings 行形式が維持されている"
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
  {"number":103,"title":"closed as duplicate",
   "projectItems":{"nodes":[{"project":{"number":1},
     "fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}
]}}}}
SCAN
    else
      cat <<'ITEM'
{"data":{"repository":{"issue":{"url":"https://github.com/o/r/issues/103",
  "projectItems":{"nodes":[{"id":"ITEM_103","project":{"id":"PROJ_1","number":1}}]}}}}}
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
if grep -q 'projects-board-drift: reconcile #103:' "$T11_DIR/stderr.txt" && \
   grep -q 'HTTP 403' "$T11_DIR/stderr.txt"; then
  PASS=$((PASS + 1)); echo "  ✓ helper warnings (with the underlying gh error) reach stderr"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-11: helper warnings missing from stderr: $(head -c 300 "$T11_DIR/stderr.txt" | tr '\n' ' ')")
  echo "  ✗ helper warnings did not reach stderr" >&2
fi

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
