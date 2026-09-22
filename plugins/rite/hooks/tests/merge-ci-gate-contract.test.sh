#!/bin/bash
# Static contract tests for the fail-closed merge CI gate: /rite:merge must fail closed when CI is
# unhealthy, distinguish executed failures from jobs that never ran, and expose
# only an explicit override. Pending checks wait in-process (15s / 540s cap) then
# rejoin the same classifier. The skill is prose-driven, so grep-pin the routing
# and classification invariants that an LLM executes, and execute the extracted
# step-1 bash against gh/sleep stubs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

MERGE="$SCRIPT_DIR/../../skills/merge/SKILL.md"
READY="$SCRIPT_DIR/../../skills/ready/SKILL.md"
CLASSIFIER="$SCRIPT_DIR/../scripts/pr-checks-classify.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

echo "=== merge CI gate routing (T-08 / existing pins) ==="
assert_grep "canonical PR query includes the complete CI gate input" "$MERGE" \
  'gh pr view \{pr_number\} -R \{owner_repo\} --json mergeable,mergeStateStatus,isDraft,headRefName,statusCheckRollup'
assert_grep "force override defaults to disabled" "$MERGE" '^force_ci=false$'
assert_grep "force override parser is token-bounded and position-independent" "$MERGE" \
  '^case " \{arguments\} " in \*" --force-ci "\*\) force_ci=true ;; esac$'
assert_grep "healthy checks proceed to step 2" "$MERGE" 'checks が全件 healthy.*ステップ 2 へ'
assert_grep "MERGEABLE plus UNSTABLE is still not ready" "$MERGE" 'mergeStateStatus == "UNSTABLE".*\[merge:not-ready\]'
assert_grep "unhealthy default path forbids gh pr merge" "$MERGE" 'ステップ 2 の `gh pr merge` は実行しない'
assert_not_grep "pending checks no longer stop without a wait loop" "$MERGE" \
  '待機・自動 retry はしない'
assert_grep "pending CheckRun is classified before nullable conclusion validation" "$CLASSIFIER" '__typename == "CheckRun".*\.status != "COMPLETED"'
assert_grep "legacy StatusContext pending states are supported" "$CLASSIFIER" '__typename == "StatusContext".*\.state == "PENDING" or \.state == "EXPECTED"'
assert_grep "mixed pending plus unknown uses unknown precedence" "$CLASSIFIER" 'mixed pending\+unknown.*unknown を先に判定する'
unknown_line=$(grep -n 'elif any(.statusCheckRollup\[\];' "$CLASSIFIER" | sed -n '1p' | cut -d: -f1)
pending_line=$(grep -n 'elif any(.statusCheckRollup\[\];' "$CLASSIFIER" | sed -n '2p' | cut -d: -f1)
if [ -n "$unknown_line" ] && [ -n "$pending_line" ] && [ "$unknown_line" -lt "$pending_line" ]; then
  pass "unknown aggregate branch precedes pending (mixed fixture cannot be overridden)"
else
  fail "unknown aggregate branch must precede pending (unknown=$unknown_line pending=$pending_line)"
fi
assert_grep "explicit override can continue a pending PR" "$MERGE" 'checks が pending \+ `force_ci == true`'
assert_grep "merge calls the shared classifier" "$MERGE" 'bash "\{plugin_root\}/hooks/scripts/pr-checks-classify.sh"'
assert_not_grep "merge no longer owns aggregate classification" "$MERGE" 'elif any\(.statusCheckRollup'
assert_grep "healthy conclusions are an allowlist" "$CLASSIFIER" '\["SUCCESS", "NEUTRAL", "SKIPPED"\]'
assert_grep "malformed and unknown states fail closed" "$MERGE" 'checks_state == "unknown".*\[merge:not-ready\]'
assert_grep "unknown cannot use force override" "$MERGE" '`--force-ci` でも unknown は override しない'
assert_grep "classification failure is surfaced" "$MERGE" '分類不能.*原因を表示'
assert_grep "classification failure is fail closed" "$MERGE" '`force_ci == false` では必ず `\[merge:not-ready\]` へ倒す'
assert_grep "explicit force-ci override is documented" "$MERGE" '/rite:merge --force-ci \{pr_number\}'

echo "=== reviewed-head and acceptance gate routing ==="
assert_grep "merge inspect uses reviewed-head helper" "$MERGE" \
  'ready-reviewed-head-gate.sh.*\\'
assert_grep "merge captures acceptance state" "$MERGE" \
  'reviewed_ac_state=\$\(printf.*REVIEWED_AC='
assert_grep "merge captures unverified IDs for attestation" "$MERGE" \
  'reviewed_ac_ids=.*ac='
assert_grep "merge blocks unmet acceptance" "$MERGE" \
  'reviewed_ac_state.*unmet'
assert_grep "merge e2e detection reads flow phase" "$MERGE" \
  'flow-state.sh" get --field phase'
assert_grep "merge e2e detection reads active run queue" "$MERGE" \
  'queue_active.*\.active // false'
assert_grep "merge e2e detection compares cursor issue" "$MERGE" \
  'queue_issue.*\.issues\[\.cursor // 0\]'
assert_grep "merge batch/e2e unverified path does not ask" "$MERGE" \
  'true` なら AskUserQuestion を挟まず `\[merge:not-ready\]`'
assert_grep "merge standalone path attests selected IDs" "$MERGE" \
  'attest "\$reviewed_ac_ids"'
assert_grep "merge final gate enforces acceptance" "$MERGE" \
  'plugin-root "\{plugin_root\}" --enforce-ac'
assert_grep "force-ci cannot bypass acceptance gate" "$MERGE" \
  '`--force-ci` は CI だけの override.*AC gate を迂回しない'
enforce_line=$(grep -n -- '--enforce-ac' "$MERGE" | tail -1 | cut -d: -f1)
merge_line=$(grep -n '^if gh pr merge ' "$MERGE" | head -1 | cut -d: -f1)
if [ -n "$enforce_line" ] && [ -n "$merge_line" ] && [ "$enforce_line" -lt "$merge_line" ]; then
  pass "acceptance enforce is ordered before gh pr merge"
else
  fail "acceptance enforce must precede gh pr merge (enforce=$enforce_line merge=$merge_line)"
fi
gate_calls=$(grep -c 'ready-reviewed-head-gate.sh' "$MERGE" || true)
gate_repo_calls=$(grep -c -- '--pr {pr_number} --repo {owner_repo} --plugin-root "{plugin_root}"' "$MERGE" || true)
if [ "$gate_calls" -gt 0 ] && [ "$gate_calls" = "$gate_repo_calls" ]; then
  pass "every merge reviewed-head call names the PR repository (n=$gate_calls)"
else
  fail "merge reviewed-head calls ($gate_calls) must all pass --repo {owner_repo} ($gate_repo_calls)"
fi
assert_grep "merge pins the verified PR head on the merge command itself" "$MERGE" \
  '^if gh pr merge \{pr_number\} -R \{owner_repo\} --squash --delete-branch=false --match-head-commit "\$verified_head" --subject "\$squash_subject" --body-file "\{squash_body_file\}" '
assert_grep "verified head extraction is anchored on the match marker" "$MERGE" \
  'READY_REVIEWED_HEAD=match; reviewed=\[0-9a-f\]\*; head='
ready_gate_calls=$(grep -c 'hooks/scripts/ready-reviewed-head-gate.sh' "$READY" || true)
ready_gate_repo_calls=$(grep -c -- '--pr "$ready_pr_number" --repo {owner_repo} --plugin-root "$plugin_root"' "$READY" || true)
# ready-pr-head-gate.sh shares the argv prefix, so it is part of the expected count.
ready_pr_head_calls=$(grep -c 'hooks/scripts/ready-pr-head-gate.sh' "$READY" || true)
if [ "$ready_gate_calls" -gt 0 ] && [ "$((ready_gate_calls + ready_pr_head_calls))" = "$ready_gate_repo_calls" ]; then
  pass "every ready reviewed-head call names the PR repository (n=$ready_gate_calls)"
else
  fail "ready reviewed-head calls ($ready_gate_calls) must all pass --repo {owner_repo} (argv matches=$ready_gate_repo_calls, pr-head calls=$ready_pr_head_calls)"
fi
assert_grep "ready inspect uses reviewed-head helper" "$READY" \
  'reviewed_gate_out=\$\(bash .*ready-reviewed-head-gate.sh'
assert_grep "ready Phase 1 override keeps acceptance enforcement" "$READY" \
  'plugin-root "\$plugin_root" \{reviewed_head_inspect_args\} 2>&1'
assert_grep "ready captures unverified IDs for attestation" "$READY" \
  'reviewed_ac_ids=.*ac='
assert_grep "ready standalone path attests selected IDs" "$READY" \
  'attest "\$reviewed_ac_ids"'
assert_grep "ready e2e unverified path stops without a question" "$READY" \
  'in_e2e_flow=true.*質問せず.*\[ready:error\]'
assert_grep "ready invalid AC states never reach attestation" "$READY" \
  'unmet / missing / malformed.*standalone.*質問や attest に送らない'
assert_grep "ready final gate enforces acceptance" "$READY" \
  'plugin-root "\$plugin_root" --enforce-ac'
assert_grep "ready unmet branch uses an exact blocking comparison" "$READY" \
  '^if \[ "\$reviewed_ac_state" = "unmet" \] \|\| \[ "\$reviewed_ac_state" = "missing" \] \|\| \[ "\$reviewed_ac_state" = "malformed" \]; then$'
assert_grep "explicit reviewed-head override preserves AC enforcement" "$READY" \
  '.*--enforce-ac \{reviewed_head_override_arg\}'
ready_enforce_line=$(grep -n -- '--enforce-ac' "$READY" | tail -1 | cut -d: -f1)
ready_call_line=$(grep -n '^gh pr ready ' "$READY" | head -1 | cut -d: -f1)
if [ -n "$ready_enforce_line" ] && [ -n "$ready_call_line" ] && [ "$ready_enforce_line" -lt "$ready_call_line" ]; then
  pass "ready acceptance enforce is ordered before gh pr ready"
else
  fail "ready acceptance enforce must precede gh pr ready (enforce=$ready_enforce_line ready=$ready_call_line)"
fi

echo "=== job classification facts ==="
assert_grep "jobs API is the classification input" "$MERGE" 'actions/runs/\{run_id\}/jobs --paginate'
assert_grep "never-run predicate uses empty runner and zero steps" "$MERGE" '`runner_name` が空、かつ `steps \| length == 0`'
assert_grep "cancelled with execution evidence is a real failure" "$MERGE" '`conclusion == "cancelled"` でも runner/steps が存在すればこちら'
assert_grep "display strings are named explicitly" "$MERGE" '`gh pr checks` の表示文字列'
assert_grep "display strings are not classification evidence" "$MERGE" '（`fail` 等）は分類根拠に使わない'

echo "=== no-check compatibility and operator guidance (T-08) ==="
assert_grep "repositories without checks preserve existing behavior" "$MERGE" 'checks 0 件.*従来どおりステップ 2 へ'
assert_grep "never-run jobs surface a concrete rerun command" "$MERGE" 'gh run rerun \{run_id\} -R \{owner_repo\} --failed'
assert_grep "all-never-run case says no CI signal exists" "$MERGE" 'CI シグナルが存在しない'
assert_grep "automatic rerun is prohibited" "$MERGE" '自動で rerun してはならない'

echo "=== pending wait loop pins (T-04/T-06/T-09) ==="
assert_grep "wait loop emits MERGE_CHECKS_WAIT started" "$MERGE" \
  '\[CONTEXT\] MERGE_CHECKS_WAIT=started pending='
assert_grep "wait loop sleeps 15 seconds" "$MERGE" '^    sleep 15$'
assert_grep "wait budget increments by 15" "$MERGE" 'waited=\$\(\(waited \+ 15\)\)'
assert_grep "wait budget cap is 540" "$MERGE" 'waited" -lt 540'
assert_grep "timeout cap emit is merge not-ready" "$MERGE" 'CI checks still pending after 540s'
assert_grep "force-ci pending path skips the wait loop" "$MERGE" \
  'checks が pending \+ `force_ci == true`.*待ち loop に入らない'
timeout_prev=$(awk '
  /^## ステップ 1: mergeable 判定$/ { s=1 }
  s && /^```bash$/ { print prev; exit }
  { prev = $0 }
' "$MERGE")
if printf '%s\n' "$timeout_prev" | grep -c >/dev/null 'timeout: 600000'; then
  pass "T-09 timeout: 600000 is the line immediately before the step-1 bash fence"
else
  fail "T-09 timeout: 600000 must be the line immediately before the step-1 bash fence (got: $timeout_prev)"
fi
view_n=$(grep -c 'gh pr view {pr_number}' "$MERGE" || true)
field_n=$(grep -c -- '--json mergeable,mergeStateStatus,isDraft,headRefName,statusCheckRollup' "$MERGE" || true)
if [ "$view_n" -gt 0 ] && [ "$view_n" = "$field_n" ]; then
  pass "every gh pr view carries the full CI-gate --json field set (n=$view_n)"
else
  fail "gh pr view count ($view_n) must equal full --json field-set count ($field_n)"
fi

# --- extracted step-1 execution against gh/sleep stubs ---

extract_step1_bash() {
  awk '
    /^## ステップ 1: mergeable 判定$/ { s=1 }
    s && /^```bash$/ { f=1; next }
    f && /^```$/ { exit }
    f { print }
  ' "$MERGE"
}

run_step1() {
  # args: scenario_csv, arguments_placeholder, out_var_name, err_var_name, rc_var_name
  local scenario="$1" arguments="$2"
  local sandbox stub_dir script
  sandbox=$(mktemp -d "${TMPDIR:-/tmp}/merge-ci-gate-XXXXXX") || {
    echo "ERROR: mktemp failed" >&2
    return 1
  }
  stub_dir="$sandbox/bin"
  mkdir -p "$stub_dir"
  : > "$sandbox/gh.log"
  : > "$sandbox/sleep.log"
  echo 0 > "$sandbox/gh.count"
  printf '%s\n' "$scenario" > "$sandbox/scenario"
  cat > "$stub_dir/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$MERGE_CI_SANDBOX/gh.log"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  n=$(cat "$MERGE_CI_SANDBOX/gh.count")
  n=$((n + 1))
  echo "$n" > "$MERGE_CI_SANDBOX/gh.count"
  IFS=, read -r -a seq < "$MERGE_CI_SANDBOX/scenario"
  idx=$((n - 1))
  last=$(( ${#seq[@]} - 1 ))
  [ "$idx" -le "$last" ] || idx=$last
  mode="${seq[$idx]}"
  if [ "$mode" = "fail" ]; then
    echo "simulated gh failure" >&2
    exit 1
  fi
  case "$mode" in
    pending2)
      printf '%s\n' '{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","isDraft":false,"headRefName":"fix/x","statusCheckRollup":[{"__typename":"CheckRun","name":"tests","status":"IN_PROGRESS","conclusion":null},{"__typename":"CheckRun","name":"lint","status":"QUEUED","conclusion":null}]}'
      ;;
    healthy2)
      printf '%s\n' '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false,"headRefName":"fix/x","statusCheckRollup":[{"__typename":"CheckRun","name":"tests","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}]}'
      ;;
    unhealthy)
      printf '%s\n' '{"mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","isDraft":false,"headRefName":"fix/x","statusCheckRollup":[{"__typename":"CheckRun","name":"tests","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}]}'
      ;;
    malformed)
      printf '%s\n' '{"mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","isDraft":false,"headRefName":"fix/x","statusCheckRollup":[{"__typename":"CheckRun","name":"tests","conclusion":"SUCCESS"}]}'
      ;;
    empty)
      printf '%s\n' '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false,"headRefName":"fix/x","statusCheckRollup":[]}'
      ;;
    mixed)
      printf '%s\n' '{"mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","isDraft":false,"headRefName":"fix/x","statusCheckRollup":[{"__typename":"CheckRun","name":"tests","status":"IN_PROGRESS","conclusion":null},{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]}'
      ;;
    *)
      echo "unknown fixture: $mode" >&2
      exit 1
      ;;
  esac
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  echo "merge-called" >> "$MERGE_CI_SANDBOX/gh.log"
  exit 99
fi
exit 0
STUB
  cat > "$stub_dir/sleep" <<'STUB'
#!/bin/bash
echo "$*" >> "$MERGE_CI_SANDBOX/sleep.log"
exit 0
STUB
  chmod +x "$stub_dir/gh" "$stub_dir/sleep"
  script="$sandbox/step1.sh"
  extract_step1_bash \
    | sed -e "s|{pr_number}|1|g" -e "s|{owner_repo}|owner/repo|g" -e "s|{arguments}|$arguments|g" -e "s|{plugin_root}|$PLUGIN_ROOT|g" \
    > "$script"
  local rc
  MERGE_CI_SANDBOX="$sandbox" PATH="$stub_dir:$PATH" \
    _timeout 8 bash "$script" > "$sandbox/stdout" 2>"$sandbox/stderr"
  rc=$?
  # GNU timeout uses 124 on deadline; treat that as a hang (sleep stub leaked).
  if [ "$rc" -eq 124 ]; then
    echo "ERROR: extracted step-1 bash exceeded _timeout 8s (sleep stub leak?)" >&2
    cat "$sandbox/stdout" >&2
    cat "$sandbox/stderr" >&2
  fi
  STEP1_OUT=$(cat "$sandbox/stdout")
  STEP1_ERR=$(cat "$sandbox/stderr")
  STEP1_RC=$rc
  STEP1_SLEEP=$(wc -l < "$sandbox/sleep.log" | tr -d ' ')
  STEP1_GH=$(wc -l < "$sandbox/gh.log" | tr -d ' ')
  STEP1_VIEW=$(grep -c 'pr view' "$sandbox/gh.log" || true)
  STEP1_MERGE=$(grep -c 'merge-called' "$sandbox/gh.log" || true)
  STEP1_SANDBOX="$sandbox"
}

last_state() {
  printf '%s\n' "$STEP1_OUT" | sed -n 's/^\[CONTEXT\] MERGE_CHECKS_STATE=//p' | tail -1
}
state_count() {
  printf '%s\n' "$STEP1_OUT" | grep -c '^\[CONTEXT\] MERGE_CHECKS_STATE=' || true
}
wait_count() {
  printf '%s\n' "$STEP1_OUT" | grep -c '^\[CONTEXT\] MERGE_CHECKS_WAIT=started' || true
}

echo "=== extracted step-1 execution (T-01/T-03/T-04/T-05/T-06/T-07) ==="

run_step1 "pending2,healthy2" "1"
assert "T-01 last MERGE_CHECKS_STATE is healthy" "healthy" "$(last_state)"
if [ "$(wait_count)" -ge 1 ]; then
  pass "T-01 MERGE_CHECKS_WAIT=started was emitted"
else
  fail "T-01 MERGE_CHECKS_WAIT=started missing"
fi
if [ "$STEP1_SLEEP" -ge 1 ]; then
  pass "T-01 sleep ran at least once (n=$STEP1_SLEEP)"
else
  fail "T-01 sleep did not run (pending→healthy must wait once)"
fi
assert "T-01 gh pr view ran twice" "2" "$STEP1_VIEW"
assert "T-01 gh pr merge was not called" "0" "$STEP1_MERGE"
rm -rf "$STEP1_SANDBOX"

run_step1 "pending2,unhealthy" "1"
assert "T-03 last MERGE_CHECKS_STATE is unhealthy" "unhealthy" "$(last_state)"
assert "T-03 sleep ran once then stopped" "1" "$STEP1_SLEEP"
assert "T-03 gh pr merge was not called" "0" "$STEP1_MERGE"
rm -rf "$STEP1_SANDBOX"

run_step1 "pending2" "1"
if printf '%s\n' "$STEP1_OUT" | grep -c >/dev/null '\[merge:not-ready\]'; then
  pass "T-04 timeout emits [merge:not-ready]"
else
  fail "T-04 timeout did not emit [merge:not-ready] (out=$STEP1_OUT)"
fi
if printf '%s\n' "$STEP1_ERR" | grep -c >/dev/null 'tests' && printf '%s\n' "$STEP1_ERR" | grep -c >/dev/null 'lint'; then
  pass "T-04 timeout stderr lists pending check names"
else
  fail "T-04 timeout stderr missing pending check names (err=$STEP1_ERR)"
fi
assert "T-04 sleep ran 36 times (540/15)" "36" "$STEP1_SLEEP"
assert "T-04 last MERGE_CHECKS_STATE is pending" "pending" "$(last_state)"
assert "T-04 gh pr merge was not called" "0" "$STEP1_MERGE"
rm -rf "$STEP1_SANDBOX"

run_step1 "pending2,malformed" "1"
assert "T-05 last MERGE_CHECKS_STATE is unknown" "unknown" "$(last_state)"
assert "T-05 sleep ran once then stopped (unknown does not wait)" "1" "$STEP1_SLEEP"
rm -rf "$STEP1_SANDBOX"

run_step1 "pending2" "--force-ci 1"
assert "T-06 force_ci+pending last state is pending" "pending" "$(last_state)"
assert "T-06 force_ci+pending sleep count is 0" "0" "$STEP1_SLEEP"
assert "T-06 force_ci+pending does not emit MERGE_CHECKS_WAIT" "0" "$(wait_count)"
rm -rf "$STEP1_SANDBOX"

run_step1 "healthy2" "1"
assert "T-07 first healthy last state is healthy" "healthy" "$(last_state)"
assert "T-07 first healthy MERGE_CHECKS_STATE emitted once" "1" "$(state_count)"
assert "T-07 first healthy sleep count is 0" "0" "$STEP1_SLEEP"
assert "T-07 first healthy does not emit MERGE_CHECKS_WAIT" "0" "$(wait_count)"
rm -rf "$STEP1_SANDBOX"

run_step1 "empty" "1"
assert "T-08 checks 0 last state is none" "none" "$(last_state)"
assert "T-08 checks 0 sleep count is 0" "0" "$STEP1_SLEEP"
rm -rf "$STEP1_SANDBOX"

run_step1 "pending2,fail" "1"
if printf '%s\n' "$STEP1_OUT" | grep -c >/dev/null '\[merge:not-ready\]'; then
  pass "loop-mid gh failure emits [merge:not-ready]"
else
  fail "loop-mid gh failure missing [merge:not-ready] (out=$STEP1_OUT)"
fi
if printf '%s\n' "$STEP1_ERR" | grep -c >/dev/null 'PR/CI 状態を取得できないためマージしません'; then
  pass "loop-mid gh failure uses the existing ERROR text"
else
  fail "loop-mid gh failure missing existing ERROR text (err=$STEP1_ERR)"
fi
rm -rf "$STEP1_SANDBOX"

run_step1 "mixed,unhealthy" "1"
assert "mixed pending+FAILURE last state is unhealthy (waited, not fail-fast)" "unhealthy" "$(last_state)"
if [ "$STEP1_SLEEP" -ge 1 ]; then
  pass "mixed pending+FAILURE continued to sleep (not fail-fast to unhealthy)"
else
  fail "mixed pending+FAILURE must not fail-fast (sleep=$STEP1_SLEEP)"
fi
first_state=$(printf '%s\n' "$STEP1_OUT" | sed -n 's/^\[CONTEXT\] MERGE_CHECKS_STATE=//p' | sed -n '1p')
assert "mixed pending+FAILURE first state is pending" "pending" "$first_state"
rm -rf "$STEP1_SANDBOX"

# --- extracted step-2 execution: the merge target is the head the final gate verified ---

extract_step2_bash() {
  awk '
    /^## ステップ 2: マージ実行$/ { s=1 }
    s && /^```bash$/ { f=1; next }
    f && /^```$/ { exit }
    f { print }
  ' "$MERGE"
}

run_step2() {
  # args: reviewed_sha, head_at_gate, head_at_merge
  local reviewed="$1" head_at_gate="$2" head_at_merge="$3"
  local sandbox
  sandbox=$(mktemp -d "${TMPDIR:-/tmp}/merge-head-pin-XXXXXX") || { echo "ERROR: mktemp failed" >&2; return 1; }
  mkdir -p "$sandbox/bin" "$sandbox/plugin/hooks/scripts" "$sandbox/state/.rite/review-results"
  cp "$SCRIPT_DIR/../scripts/ready-reviewed-head-gate.sh" "$sandbox/plugin/hooks/scripts/"
  printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$sandbox/state" > "$sandbox/plugin/hooks/state-path-resolve.sh"
  chmod +x "$sandbox/plugin/hooks/state-path-resolve.sh" "$sandbox/plugin/hooks/scripts/ready-reviewed-head-gate.sh"
  jq -n --arg sha "$reviewed" '{commit_sha:$sha, acceptance_criteria:{skipped:"no_ac_section"}}' \
    > "$sandbox/state/.rite/review-results/1-20260101000000.json"
  : > "$sandbox/gh.log"
  cat > "$sandbox/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$MERGE_PIN_SANDBOX/gh.log"
if [ "$1 $2" = "pr view" ]; then printf '%s\n' "$MERGE_PIN_HEAD_AT_GATE"; exit 0; fi
if [ "$1 $2" = "pr merge" ]; then
  pinned=""
  while [ "$#" -gt 0 ]; do [ "$1" = "--match-head-commit" ] && pinned="${2:-}"; shift; done
  # GitHub refuses the merge when the pinned OID is not the PR head at merge time.
  [ "$pinned" = "$MERGE_PIN_HEAD_AT_MERGE" ] && exit 0
  echo "head commit does not match" >&2
  exit 1
fi
exit 0
STUB
  chmod +x "$sandbox/bin/gh"
  printf 'squash-subject-text\n' > "$sandbox/squash-subject.txt"
  extract_step2_bash \
    | sed -e "s|{pr_number}|1|g" -e "s|{owner_repo}|owner/repo|g" -e "s|{plugin_root}|$sandbox/plugin|g" \
      -e "s|{squash_subject_file}|$sandbox/squash-subject.txt|g" \
    > "$sandbox/step2.sh"
  MERGE_PIN_SANDBOX="$sandbox" MERGE_PIN_HEAD_AT_GATE="$head_at_gate" MERGE_PIN_HEAD_AT_MERGE="$head_at_merge" \
    PATH="$sandbox/bin:$PATH" _timeout 8 bash "$sandbox/step2.sh" > "$sandbox/stdout" 2>"$sandbox/stderr"
  STEP2_RC=$?
  STEP2_OUT=$(cat "$sandbox/stdout")
  STEP2_MERGE_ARGV=$(grep '^pr merge ' "$sandbox/gh.log" || true)
  rm -rf "$sandbox"
}

echo "=== extracted step-2 execution (verified PR head is the merge target) ==="
PIN_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PIN_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

run_step2 "$PIN_A" "$PIN_A" "$PIN_A"
assert "stable head: step 2 succeeds" "0" "$STEP2_RC"
assert "stable head: merge is pinned to the verified head" \
  "pr merge 1 -R owner/repo --squash --delete-branch=false --match-head-commit $PIN_A --subject squash-subject-text --body-file {squash_body_file}" "$STEP2_MERGE_ARGV"

run_step2 "$PIN_A" "$PIN_A" "$PIN_B"
assert "head moved after the gate: merge still carries only the verified head" \
  "pr merge 1 -R owner/repo --squash --delete-branch=false --match-head-commit $PIN_A --subject squash-subject-text --body-file {squash_body_file}" "$STEP2_MERGE_ARGV"
# The step reports a refused merge through its sentinel, not through the exit code.
if printf '%s\n' "$STEP2_OUT" | grep -c >/dev/null '^\[merge:error\]$' \
  && ! printf '%s\n' "$STEP2_OUT" | grep -c >/dev/null 'merge:returned-to-caller'; then
  pass "head moved after the gate: the refused merge surfaces [merge:error] and no success signal"
else
  fail "head moved after the gate must end in [merge:error] without a success signal (out=$STEP2_OUT)"
fi

run_step2 "$PIN_A" "$PIN_B" "$PIN_B"
assert "unreviewed PR head: gh pr merge is never called" "" "$STEP2_MERGE_ARGV"
if [ "$STEP2_RC" -ne 0 ] && printf '%s\n' "$STEP2_OUT" | grep -c >/dev/null '^\[merge:not-ready\]$'; then
  pass "unreviewed PR head: step 2 stops with [merge:not-ready]"
else
  fail "unreviewed PR head must stop with [merge:not-ready] (rc=$STEP2_RC out=$STEP2_OUT)"
fi

if ! print_summary "$(basename "$0")" "mergeStateStatus の CI gate・pending wait loop・jobs API 分類・明示 override contract (T-01〜T-09)"; then
  exit 1
fi
