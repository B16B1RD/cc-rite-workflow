#!/bin/bash
# Tests for hooks/scripts/fix-report-diff-gate.sh
#
# Pins the completion-report diff gate: + hunk overlap, -U0 (not unified=3
# context), map_missing fail-loud, reply/accept/nit-noted out of scope,
# unknown action fail-loud, range overlap, hunk-level delete match, and
# section-limited SKILL pins for {fix_change_map} / 対応表なし / 4.6 / 5.1.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/fix-report-diff-gate.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

echo "=== fix-report-diff-gate.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  if [ -d /proc ]; then
    echo "  ❌ FAIL: fix-report-diff-gate floor: jq unavailable on Linux"
    echo "Results: 0 passed, 1 failed"
    exit 1
  fi
  echo "  ⏭️ SKIP: jq not available — fix-report-diff-gate requires jq"
  echo "SKIP: 1"
  exit 0
fi

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

git_c() { git -C "$REPO" -c user.email=t@test.local -c user.name=test "$@"; }

new_repo() {
  REPO=$(make_sandbox)
  cleanup_dirs+=("$REPO")
}

write_state() {
  local path="$1" before="$2" after="$3" addressed="$4"
  local older="${5:-}"
  mkdir -p "$(dirname "$path")"
  if [ -n "$older" ]; then
    jq -n --arg before "$before" --arg after "$after" --argjson addressed "$addressed" --argjson older "$older" '
      {pr_number: 1, cycles: ($older + [{
        cycle: 2,
        commit_sha_before: $before,
        commit_sha_after: $after,
        findings_fixed: 0,
        files_changed_by_fix: [],
        findings_addressed: $addressed
      }])}
    ' > "$path"
  else
    jq -n --arg before "$before" --arg after "$after" --argjson addressed "$addressed" '
      {pr_number: 1, cycles: [{
        cycle: 1,
        commit_sha_before: $before,
        commit_sha_after: $after,
        findings_fixed: 0,
        files_changed_by_fix: [],
        findings_addressed: $addressed
      }]}
    ' > "$path"
  fi
}

run_gate() {
  local state="$1"
  GATE_OUT=$(mktemp)
  GATE_ERR=$(mktemp)
  cleanup_dirs+=("$GATE_OUT" "$GATE_ERR")
  bash "$SCRIPT" --state-file "$state" --repo-root "$REPO" >"$GATE_OUT" 2>"$GATE_ERR"
  GATE_RC=$?
}

marker_line() {
  grep '^\[CONTEXT\] FIX_REPORT_DIFF_GATE=' "$GATE_ERR" | tail -1
}

# --- T-01: matching + hunk → passed + diff_verified true; write-back latest only ---
new_repo
seq 1 20 | sed 's/^/line /' > "$REPO/target.txt"
git_c add target.txt
git_c commit -q -m add-target
before=$(git -C "$REPO" rev-parse HEAD)
sed -i '12s/.*/CHANGED 12/' "$REPO/target.txt"
git_c add target.txt
git_c commit -q -m change-12
after=$(git -C "$REPO" rev-parse HEAD)

older_cycle=$(jq -nc --arg before "$before" '{
  cycle: 1,
  commit_sha_before: $before,
  commit_sha_after: $before,
  findings_fixed: 0,
  files_changed_by_fix: [],
  findings_addressed: [{"id":"F-OLD","action":"fix","changes":["target.txt:1"]}]
}')
write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-01","action":"fix","changes":["target.txt:12"]}]' \
  "[$older_cycle]"
run_gate "$REPO/state.json"
assert "T-01 rc=0" "0" "$GATE_RC"
assert "T-01 marker passed verified=1 unverified=0" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=passed; verified=1; unverified=0" \
  "$(marker_line)"
assert "T-01 F-01 diff_verified true" "true" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"
assert "T-01 older cycle has no diff_verified" "true" \
  "$(jq -r '.cycles[0].findings_addressed[0] | has("diff_verified") | not' "$REPO/state.json")"

# --- T-02: line outside -U0 hunk (would be U3 context) → unverified; mixed 1+1 ---
new_repo
seq 1 40 | sed 's/^/line /' > "$REPO/target.txt"
git_c add target.txt
git_c commit -q -m add-target
before=$(git -C "$REPO" rev-parse HEAD)
sed -i '20s/.*/CHANGED 20/' "$REPO/target.txt"
git_c add target.txt
git_c commit -q -m change-20
after=$(git -C "$REPO" rev-parse HEAD)

write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-03","action":"fix","changes":["target.txt:17"]}]'
run_gate "$REPO/state.json"
assert "T-02 rc=0" "0" "$GATE_RC"
assert "T-02 marker unverified ids=F-03" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=unverified; verified=0; unverified=1; ids=F-03" \
  "$(marker_line)"
assert "T-02 F-03 diff_verified false" "false" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"

write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-01","action":"fix","changes":["target.txt:20"]},{"id":"F-03","action":"fix","changes":["target.txt:17"]}]'
run_gate "$REPO/state.json"
assert "T-02 mixed marker" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=unverified; verified=1; unverified=1; ids=F-03" \
  "$(marker_line)"
assert "T-02 mixed F-01 true" "true" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"
assert "T-02 mixed F-03 false" "false" \
  "$(jq -r '.cycles[-1].findings_addressed[1].diff_verified' "$REPO/state.json")"

# --- T-03: missing findings_addressed AND empty changes on action:fix ---
new_repo
before=$(git -C "$REPO" rev-parse HEAD)
jq -n --arg before "$before" '{pr_number:1,cycles:[{cycle:1,commit_sha_before:$before,commit_sha_after:$before,findings_fixed:0,files_changed_by_fix:[]}]}' \
  > "$REPO/state.json"
run_gate "$REPO/state.json"
assert "T-03 missing key rc!=0" "1" "$GATE_RC"
assert "T-03 missing key reason=map_missing" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=error; reason=map_missing" \
  "$(marker_line)"

write_state "$REPO/state.json" "$before" "$before" \
  '[{"id":"F-01","action":"fix","changes":[]}]'
run_gate "$REPO/state.json"
assert "T-03 empty changes rc!=0" "1" "$GATE_RC"
assert "T-03 empty changes reason=map_missing" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=error; reason=map_missing" \
  "$(marker_line)"

# --- T-04: reply / accept / nit-noted out of scope (incl. skip-shaped HEAD=HEAD) ---
new_repo
before=$(git -C "$REPO" rev-parse HEAD)
write_state "$REPO/state.json" "$before" "$before" \
  '[{"id":"F-04","action":"reply","changes":[]},{"id":"F-05","action":"accept","changes":[]},{"id":"F-06","action":"nit-noted","changes":[]}]'
run_gate "$REPO/state.json"
assert "T-04 rc=0" "0" "$GATE_RC"
assert "T-04 marker passed verified=0" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=passed; verified=0; unverified=0" \
  "$(marker_line)"
assert "T-04 reply has no diff_verified" "true" \
  "$(jq -r '.cycles[-1].findings_addressed[0] | has("diff_verified") | not' "$REPO/state.json")"
assert "T-04 accept has no diff_verified" "true" \
  "$(jq -r '.cycles[-1].findings_addressed[1] | has("diff_verified") | not' "$REPO/state.json")"
assert "T-04 nit-noted has no diff_verified" "true" \
  "$(jq -r '.cycles[-1].findings_addressed[2] | has("diff_verified") | not' "$REPO/state.json")"

# --- T-04b: unknown action is fail-loud, not a silent skip ---
write_state "$REPO/state.json" "$before" "$before" \
  '[{"id":"F-UNK","action":"Fix","changes":["a:1"]}]'
run_gate "$REPO/state.json"
assert "T-04b unknown action rc!=0" "1" "$GATE_RC"
assert "T-04b unknown action reason=map_missing" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=error; reason=map_missing" \
  "$(marker_line)"

write_state "$REPO/state.json" "$before" "$before" \
  '[{"id":"F-OK","action":"reply","changes":[]},{"id":"F-UNK2","action":"deferred","changes":[]}]'
run_gate "$REPO/state.json"
assert "T-04b unknown action after valid one rc!=0" "1" "$GATE_RC"
assert "T-04b unknown action after valid one reason=map_missing" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=error; reason=map_missing" \
  "$(marker_line)"

# --- T-07: range 10-14 overlaps hunk 12; 20-24 does not ---
new_repo
seq 1 30 | sed 's/^/line /' > "$REPO/target.txt"
git_c add target.txt
git_c commit -q -m add-target
before=$(git -C "$REPO" rev-parse HEAD)
sed -i '12s/.*/CHANGED 12/' "$REPO/target.txt"
git_c add target.txt
git_c commit -q -m change-12
after=$(git -C "$REPO" rev-parse HEAD)

write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-07","action":"fix","changes":["target.txt:10-14"]}]'
run_gate "$REPO/state.json"
assert "T-07 range 10-14 true" "true" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"
assert "T-07 range 10-14 passed" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=passed; verified=1; unverified=0" \
  "$(marker_line)"

write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-07b","action":"fix","changes":["target.txt:20-24"]}]'
run_gate "$REPO/state.json"
assert "T-07 range 20-24 false" "false" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"
assert "T-07 range 20-24 unverified" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=unverified; verified=0; unverified=1; ids=F-07b" \
  "$(marker_line)"

# --- T-08: invalid base SHA → diff_failed ---
new_repo
write_state "$REPO/state.json" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
  "$(git -C "$REPO" rev-parse HEAD)" \
  '[{"id":"F-01","action":"fix","changes":["a:1"]}]'
run_gate "$REPO/state.json"
assert "T-08 rc!=0" "1" "$GATE_RC"
assert "T-08 reason=diff_failed" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=error; reason=diff_failed" \
  "$(marker_line)"

# --- delete-only: file-level match ---
new_repo
printf 'gone\n' > "$REPO/gone.txt"
git_c add gone.txt
git_c commit -q -m add-gone
before=$(git -C "$REPO" rev-parse HEAD)
git_c rm -q gone.txt
git_c commit -q -m rm-gone
after=$(git -C "$REPO" rev-parse HEAD)
write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-DEL","action":"fix","changes":["gone.txt:1"]}]'
run_gate "$REPO/state.json"
assert "delete-only file-level true" "true" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"
assert "delete-only passed" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=passed; verified=1; unverified=0" \
  "$(marker_line)"

# --- delete hunk in a file that also gains + hunks (hunk granularity, not file) ---
new_repo
seq 1 30 | sed 's/^/line /' > "$REPO/mixed.txt"
git_c add mixed.txt
git_c commit -q -m add-mixed
before=$(git -C "$REPO" rev-parse HEAD)
sed -i '25s/.*/CHANGED 25/' "$REPO/mixed.txt"
sed -i '5,6d' "$REPO/mixed.txt"
git_c add mixed.txt
git_c commit -q -m mixed-delete-and-add
after=$(git -C "$REPO" rev-parse HEAD)

write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-MIX","action":"fix","changes":["mixed.txt:5-6"]}]'
run_gate "$REPO/state.json"
assert "mixed delete hunk true" "true" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"
assert "mixed delete hunk passed" \
  "[CONTEXT] FIX_REPORT_DIFF_GATE=passed; verified=1; unverified=0" \
  "$(marker_line)"

write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-MIXB","action":"fix","changes":["mixed.txt:10"]}]'
run_gate "$REPO/state.json"
assert "mixed untouched line false" "false" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"

# --- multi-element changes: any match verifies, order-independent ---
write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-ANY","action":"fix","changes":["mixed.txt:10","mixed.txt:23"]}]'
run_gate "$REPO/state.json"
assert "multi changes any-match true" "true" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"

write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-ANYR","action":"fix","changes":["mixed.txt:23","mixed.txt:10"]}]'
run_gate "$REPO/state.json"
assert "multi changes reverse order true" "true" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"

write_state "$REPO/state.json" "$before" "$after" \
  '[{"id":"F-NONE","action":"fix","changes":["mixed.txt:10","mixed.txt:12"]}]'
run_gate "$REPO/state.json"
assert "multi changes none match false" "false" \
  "$(jq -r '.cycles[-1].findings_addressed[0].diff_verified' "$REPO/state.json")"

# --- T-05 / T-06 / 4.6 static pins ---
FIX_SKILL="$PLUGIN_ROOT/skills/fix/SKILL.md"
PR_SKILL="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
VERIF="$PLUGIN_ROOT/skills/pr-review/references/reviewer-prompt-verification.md"

assert_file_exists_or_fail "T-05 verification template" "$VERIF" || true
assert_file_exists_or_fail "T-05 pr-review SKILL" "$PR_SKILL" || true
assert_file_exists_or_fail "T-06/4.6 fix SKILL" "$FIX_SKILL" || true

if [ -f "$VERIF" ]; then
  awk '
    /\{previous_findings_table\}/ { seen=1 }
    seen && /\{fix_change_map\}/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$VERIF"
  _rc=$?
  assert "T-05 {fix_change_map} after {previous_findings_table} in Part 1" "0" "$_rc"
fi
if [ -f "$PR_SKILL" ]; then
  awk '
    /^### 4\.5\.1 / { insec=1 }
    insec && /^### / && !/^### 4\.5\.1 / { insec=0 }
    insec && /\{fix_change_map\}/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$PR_SKILL"
  _rc=$?
  assert "T-05 4.5.1 placeholder table has {fix_change_map}" "0" "$_rc"
  awk '
    /^### 4\.5\.1 / { insec=1 }
    insec && /^### / && !/^### 4\.5\.1 / { insec=0 }
    insec && /対応表なし/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$PR_SKILL"
  _rc=$?
  assert "T-06 missing-replacement 対応表なし in 4.5.1" "0" "$_rc"
  awk '
    /^### 4\.5\.1 / { insec=1 }
    insec && /^### / && !/^### 4\.5\.1 / { insec=0 }
    insec && /❌/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$PR_SKILL"
  _rc=$?
  assert "T-06 4.5.1 marks diff_verified:false with ❌" "0" "$_rc"
fi
if [ -f "$FIX_SKILL" ]; then
  awk '
    /^### 4\.6 / { insec=1 }
    insec && /^### / && !/^### 4\.6 / { insec=0 }
    insec && /\| 指摘 \| 対応 \| 変更箇所 \| 差分確認 \|/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$FIX_SKILL"
  _rc=$?
  assert "4.6 table headers 指摘/対応/変更箇所/差分確認" "0" "$_rc"
  awk '
    /^### 4\.6 / { insec=1 }
    insec && /^### / && !/^### 4\.6 / { insec=0 }
    insec && /未対応:/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$FIX_SKILL"
  _rc=$?
  assert "4.6 未対応: N件 (IDs)" "0" "$_rc"
  awk '
    /^### 4\.6 / { insec=1 }
    insec && /^### / && !/^### 4\.6 / { insec=0 }
    insec && /diff_verified: true/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$FIX_SKILL"
  _rc=$?
  assert "4.6 passed marker counts diff_verified: true" "0" "$_rc"
  awk '
    /^## ステップ 5/ { insec=1 }
    insec && /^## / && !/^## ステップ 5/ { insec=0 }
    insec && /FIX_REPORT_DIFF_GATE=error/ && /\[fix:error\]/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$FIX_SKILL"
  _rc=$?
  assert "5.1 eval-order maps FIX_REPORT_DIFF_GATE=error to [fix:error]" "0" "$_rc"
fi

assert "usage unknown arg exits 2" "2" "$(bash "$SCRIPT" --bogus >/dev/null 2>&1; echo $?)"
assert "no args exits 2" "2" "$(bash "$SCRIPT" >/dev/null 2>&1; echo $?)"

if ! print_summary "$(basename "$0")" "fix-report-diff-gate marker/schema drift"; then
  exit 1
fi
