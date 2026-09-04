#!/bin/bash
# Static tests for watchdog-status-mismatch.sh
#
# Verifies:
#   T-9a: script exists and is executable
#   T-9b: script syntax is valid (bash -n)
#   T-9c: --help / -h prints usage without error
#   T-9d: --limit accepts numeric, rejects non-numeric
#   T-9e: required script flags are documented
#
# Usage: bash plugins/rite/hooks/tests/watchdog-status-mismatch.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WATCHDOG_SH="$REPO_ROOT/plugins/rite/scripts/watchdog-status-mismatch.sh"

PASS=0
FAIL=0
FAILURES=()

assert_cmd() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (cmd: $*)")
    echo "  ✗ $description" >&2
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (pattern: $pattern)")
    echo "  ✗ $description" >&2
  fi
}

echo "=== T-9: watchdog-status-mismatch.sh ==="

echo ""
echo "[T-9a] Script exists and is executable"
if [ ! -f "$WATCHDOG_SH" ]; then
  echo "ERROR: $WATCHDOG_SH not found" >&2
  exit 1
fi
if [ -x "$WATCHDOG_SH" ]; then
  PASS=$((PASS + 1))
  echo "  ✓ watchdog-status-mismatch.sh is executable"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("watchdog-status-mismatch.sh is not executable")
  echo "  ✗ watchdog-status-mismatch.sh is not executable" >&2
fi

echo ""
echo "[T-9b] Script syntax is valid"
if bash -n "$WATCHDOG_SH" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo "  ✓ bash -n passes"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("bash -n failed")
  echo "  ✗ bash -n failed" >&2
fi

echo ""
echo "[T-9c] --help prints usage"
help_output=$(bash "$WATCHDOG_SH" --help 2>&1) || true
if printf '%s' "$help_output" | grep -q 'watchdog-status-mismatch.sh'; then
  PASS=$((PASS + 1))
  echo "  ✓ --help prints usage including script name"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("--help output missing script name")
  echo "  ✗ --help output missing script name" >&2
fi

echo ""
echo "[T-9d] --limit input validation"
# Non-numeric should fail
if bash "$WATCHDOG_SH" --limit abc --dry-run --quiet >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  FAILURES+=("--limit abc should fail")
  echo "  ✗ --limit abc should fail" >&2
else
  PASS=$((PASS + 1))
  echo "  ✓ --limit non-numeric is rejected"
fi

echo ""
echo "[T-9e] Documented flags present in source"
# pattern は `\-\-{flag}\)` (case 句の閉じ括弧で固定) として cmd-line parse logic 自体を pin する。
# ERE escape (`\-\-`) でリテラル match させ、`--` を pattern token として誤認させない。
assert_file_contains "$WATCHDOG_SH" '\-\-dry-run\)' \
  "Script case clause handles --dry-run flag"
assert_file_contains "$WATCHDOG_SH" '\-\-reconcile\)' \
  "Script case clause handles --reconcile flag"
assert_file_contains "$WATCHDOG_SH" '\-\-limit\)' \
  "Script case clause handles --limit flag"
assert_file_contains "$WATCHDOG_SH" '\-\-quiet\)' \
  "Script case clause handles --quiet flag"
# header purpose marker
assert_file_contains "$WATCHDOG_SH" 'Status Mismatch Watchdog' \
  "header documents watchdog purpose"
# Detection logic: isDraft=false && Status="In Progress"
assert_file_contains "$WATCHDOG_SH" 'isDraft' \
  "Script checks PR isDraft"
assert_file_contains "$WATCHDOG_SH" 'In Progress' \
  "Script checks Status == 'In Progress'"

echo ""
echo "[T-9f] Behavioral: git-remote fast path resolves SSH alias origin, --repo threaded into gh pr list"
# Real git repo + SSH Host alias origin + deliberately-broken `gh repo view`:
# the run only succeeds if the git-remote fast path resolved owner/repo AND
# `gh pr list` received the exact resolved value via --repo. The shim fails
# loudly (MOCK ASSERTION FAILED) on a wrong/missing --repo — so a regression
# back to the shorthand (the bug) or to a wrong-repo resolution turns
# into a hard test failure instead of passing silently.
T9F_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-watchdog-t9f-XXXXXX")
trap 'rm -rf "$T9F_DIR"' EXIT
mkdir -p "$T9F_DIR/repo/bin"
( cd "$T9F_DIR/repo" && git init -q && git remote add origin "git@github.com-work:o/r.git" ) >/dev/null 2>&1
cat > "$T9F_DIR/repo/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML
cat > "$T9F_DIR/repo/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view")
    echo "should not be called - git-remote fast path must resolve first" >&2
    exit 1 ;;
  "pr list")
    if ! printf '%s\n' "$*" | grep -qE -- '--repo o/r( |$)'; then
      echo "MOCK ASSERTION FAILED: expected --repo o/r, got: $*" >&2
      exit 1
    fi
    echo "[]" ;;
  *) exit 0 ;;
esac
GH_SHIM
chmod +x "$T9F_DIR/repo/bin/gh"
set +e
t9f_out=$(cd "$T9F_DIR/repo" && PATH="$T9F_DIR/repo/bin:$PATH" bash "$WATCHDOG_SH" --dry-run --quiet 2>"$T9F_DIR/stderr.txt")
t9f_rc=$?
set -e
if [ "$t9f_rc" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "  ✓ run succeeds via git-remote fast path (exit 0)"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-9f: expected exit 0, got $t9f_rc; stderr: $(head -c 300 "$T9F_DIR/stderr.txt" | tr '\n' ' ')")
  echo "  ✗ run failed (exit $t9f_rc)" >&2
fi
if grep -qE 'MOCK ASSERTION FAILED|gh repo view failed' "$T9F_DIR/stderr.txt" 2>/dev/null; then
  FAIL=$((FAIL + 1)); FAILURES+=("T-9f: wrong --repo value or fallback to gh repo view: $(head -c 300 "$T9F_DIR/stderr.txt" | tr '\n' ' ')")
  echo "  ✗ wrong --repo value or gh repo view fallback was hit" >&2
else
  PASS=$((PASS + 1)); echo "  ✓ exact --repo o/r threaded to gh pr list, gh repo view never consulted"
fi

echo ""
echo "[T-9g] Behavioral: head -c preview neutralizes ESC/C1 bytes"
real_jq=$(command -v jq)
cat > "$T9F_DIR/repo/bin/jq" <<'JQ_SHIM'
#!/bin/bash
if [ "${1:-}" = "-c" ] && [ "${2:-}" = ".[]" ]; then
  printf 'bad\033esc\302\233utf8\233raw\n'
  exit 0
fi
exec "__REAL_JQ__" "$@"
JQ_SHIM
sed -i.bak "s|__REAL_JQ__|$real_jq|" "$T9F_DIR/repo/bin/jq"
chmod +x "$T9F_DIR/repo/bin/jq"
set +e
(cd "$T9F_DIR/repo" && PATH="$T9F_DIR/repo/bin:$PATH" \
  bash "$WATCHDOG_SH" --dry-run >"$T9F_DIR/t9g-stdout" 2>"$T9F_DIR/t9g-stderr")
t9g_rc=$?
set -e
t9g_preview_hex=$(LC_ALL=C grep -aF 'pr_entry preview:' "$T9F_DIR/t9g-stderr" \
  | od -An -tx1 | tr -d ' \n')
if [ "$t9g_rc" -eq 0 ] && [[ "$t9g_preview_hex" != *"1b"* ]] \
  && [[ "$t9g_preview_hex" != *"9b"* ]] \
  && [[ "$t9g_preview_hex" == *"6261643f657363c23f757466383f726177"* ]]; then
  PASS=$((PASS + 1)); echo "  ✓ preview preserves exit contract and replaces ESC/UTF-8 C1/raw C1"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-9g: preview leaked control bytes or changed exit contract")
  echo "  ✗ preview leaked control bytes or changed exit contract" >&2
fi

echo ""
echo "[T-04..T-07] Behavioral: two-rule detection over a fixture board"
# The rule fixtures run the watchdog out of a throwaway plugin root so the reconcile
# target (`$PLUGIN_ROOT/scripts/projects-status-update.sh`, an absolute path that PATH
# shimming cannot reach) can be replaced by a mock that asserts the status it receives.
# A single hardcoded "In Review" would push a Todo residue to the wrong column, so the
# per-rule target is pinned here rather than only in the report JSON.
RULES_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-watchdog-rules-XXXXXX")
trap 'rm -rf "$T9F_DIR" "$RULES_DIR"' EXIT
mkdir -p "$RULES_DIR/plugin/scripts" "$RULES_DIR/plugin/hooks/scripts/lib" "$RULES_DIR/repo/bin"
cp "$WATCHDOG_SH" "$RULES_DIR/plugin/scripts/watchdog-status-mismatch.sh"
cp "$REPO_ROOT/plugins/rite/hooks/control-char-neutralize.sh" "$RULES_DIR/plugin/hooks/"
cp "$REPO_ROOT/plugins/rite/hooks/scripts/lib/git-remote.sh" "$RULES_DIR/plugin/hooks/scripts/lib/"
cat > "$RULES_DIR/plugin/scripts/projects-status-update.sh" <<'RECON_SHIM'
#!/bin/bash
# Mock reconciler: records the status_name it was asked for so the caller's per-rule
# target can be asserted, then reports success.
printf '%s' "$1" | jq -r '.status_name' >> "$RITE_TEST_RECON_LOG"
echo '{"result":"updated","warnings":[]}'
RECON_SHIM
chmod +x "$RULES_DIR/plugin/scripts/projects-status-update.sh"
( cd "$RULES_DIR/repo" && git init -q && git remote add origin "git@github.com:o/r.git" ) >/dev/null 2>&1
cat > "$RULES_DIR/repo/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML

# The gh shim reads its two canned responses from files so each fixture can vary the PR
# list and the board Status without rewriting the shim.
cat > "$RULES_DIR/repo/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view")
    echo "MOCK ASSERTION FAILED: gh repo view must not be reached (git-remote fast path)" >&2
    exit 1 ;;
  "pr list")  cat "$RITE_TEST_PR_LIST" ;;
  "api graphql") cat "$RITE_TEST_BOARD" ;;
  *) exit 0 ;;
esac
GH_SHIM
chmod +x "$RULES_DIR/repo/bin/gh"

# $1=label $2=isDraft $3=Status-or-empty(<absent> = not on the board) $4=--reconcile|--dry-run
# Emits the watchdog's stdout JSON; leaves the reconcile log at $RULES_DIR/recon.log.
run_rule_fixture() {
  local is_draft="$1" status="$2" mode="$3"
  _closes='Closes #998' # drift-check-ignore
  printf '[{"number":1001,"isDraft":%s,"body":"%s","headRefName":"fix/issue-998-x"}]\n' \
    "$is_draft" "$_closes" > "$RULES_DIR/pr-list.json"
  if [ "$status" = "<absent>" ]; then
    echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' > "$RULES_DIR/board.json"
  else
    jq -n --arg s "$status" \
      '{data:{repository:{issue:{projectItems:{nodes:[{project:{number:1},fieldValues:{nodes:[{field:{name:"Status"},name:$s}]}}]}}}}}' \
      > "$RULES_DIR/board.json"
  fi
  : > "$RULES_DIR/recon.log"
  ( cd "$RULES_DIR/repo" \
    && PATH="$RULES_DIR/repo/bin:$PATH" \
       RITE_TEST_PR_LIST="$RULES_DIR/pr-list.json" \
       RITE_TEST_BOARD="$RULES_DIR/board.json" \
       RITE_TEST_RECON_LOG="$RULES_DIR/recon.log" \
       bash "$RULES_DIR/plugin/scripts/watchdog-status-mismatch.sh" "$mode" --quiet 2>/dev/null ) || true
}

# $1=json $2=jq filter $3=expected $4=description
assert_json() {
  local actual
  actual=$(printf '%s' "$1" | jq -r "$2" 2>/dev/null) || actual="<jq-failed>"
  if [ "$actual" = "$3" ]; then
    PASS=$((PASS + 1)); echo "  ✓ $4"
  else
    FAIL=$((FAIL + 1)); FAILURES+=("$4 (expected: $3, got: $actual)")
    echo "  ✗ $4 (expected: $3, got: $actual)" >&2
  fi
}

# Every fixture asserts prs_scanned first. Without it a shim that silently returns an
# empty PR list would make the mismatch assertions pass by never entering the loop.
echo "  -- T-04/T-05: Todo + draft PR"
out=$(run_rule_fixture true Todo --reconcile)
assert_json "$out" '.scan_summary.prs_scanned' '1' "the scan actually entered the detection loop"
assert_json "$out" '.scan_summary.mismatches_found' '1' "Todo residue on a draft PR is reported (isDraft is not a reason to exclude)"
assert_json "$out" '.mismatches[0].current_status' 'Todo' "the record carries the observed status"
assert_json "$out" '.mismatches[0].expected_status' 'In Progress' "the Todo rule expects In Progress"
recon_target=$(cat "$RULES_DIR/recon.log" 2>/dev/null | tr -d '\n')
if [ "$recon_target" = "In Progress" ]; then
  PASS=$((PASS + 1)); echo "  ✓ --reconcile drove the Todo residue to In Progress"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-04: reconcile target expected 'In Progress', got '$recon_target'")
  echo "  ✗ reconcile target expected 'In Progress', got '$recon_target'" >&2
fi

echo "  -- T-04b: Todo + ready PR (the rule says ANY open PR, not just drafts)"
# Without this the Todo arm can be narrowed to `isDraft=true` and every assertion stays
# green — the docblock would claim "draft included" while the ready-PR case, which is what
# a Todo residue looks like after /rite:ready runs, went unchecked.
out=$(run_rule_fixture false Todo --dry-run)
assert_json "$out" '.scan_summary.prs_scanned' '1' "the scan actually entered the detection loop"
assert_json "$out" '.scan_summary.mismatches_found' '1' "Todo residue on a ready PR is reported"
assert_json "$out" '.mismatches[0].expected_status' 'In Progress' "the Todo rule expects In Progress regardless of draft state"

echo "  -- T-06: In Progress + ready PR (non-regression)"
out=$(run_rule_fixture false "In Progress" --reconcile)
assert_json "$out" '.scan_summary.prs_scanned' '1' "the scan actually entered the detection loop"
assert_json "$out" '.scan_summary.mismatches_found' '1' "In Progress residue on a ready PR is still reported"
assert_json "$out" '.mismatches[0].expected_status' 'In Review' "the In Progress rule expects In Review"
recon_target=$(cat "$RULES_DIR/recon.log" 2>/dev/null | tr -d '\n')
if [ "$recon_target" = "In Review" ]; then
  PASS=$((PASS + 1)); echo "  ✓ --reconcile drove the In Progress residue to In Review"
else
  FAIL=$((FAIL + 1)); FAILURES+=("T-06: reconcile target expected 'In Review', got '$recon_target'")
  echo "  ✗ reconcile target expected 'In Review', got '$recon_target'" >&2
fi

echo "  -- T-06b: In Progress + draft PR is the correct state, not a mismatch"
out=$(run_rule_fixture true "In Progress" --dry-run)
assert_json "$out" '.scan_summary.prs_scanned' '1' "the scan actually entered the detection loop"
assert_json "$out" '.scan_summary.mismatches_found' '0' "In Progress during a draft is not reported"

echo "  -- T-07: Issue not on the project board"
out=$(run_rule_fixture true "<absent>" --dry-run)
assert_json "$out" '.scan_summary.prs_scanned' '1' "the scan actually entered the detection loop"
assert_json "$out" '.scan_summary.mismatches_found' '0' "an Issue absent from the board is never a mismatch"

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for msg in "${FAILURES[@]}"; do
    echo "  - $msg"
  done
  exit 1
fi
echo "All watchdog-status-mismatch checks passed."
