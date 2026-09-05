#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
audit="$ROOT/plugins/rite/skills/pr-review/references/promotion-audit-review-fix-loop.md"
review="$ROOT/plugins/rite/skills/pr-review/SKILL.md"
fix="$ROOT/plugins/rite/skills/fix/SKILL.md"
iterate="$ROOT/plugins/rite/skills/iterate/SKILL.md"
test_reviewer="$ROOT/plugins/rite/agents/test-reviewer.md"
error_reviewer="$ROOT/plugins/rite/agents/error-handling-reviewer.md"
failures=0

assert_grep() {
  local label=$1 file=$2 pattern=$3
  if grep -Fq -- "$pattern" "$file"; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

assert_eq() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s (expected=%s actual=%s)\n' "$label" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

assert_grep 'aggregate recommendation shelved' "$audit" '| `aggregate-recommendation-label-evasion` | shelve — already mechanized | recommendation classification and disposition gate |'
assert_grep 'fix drift shelved' "$audit" '| `fix-induced-drift-in-cumulative-defense` | shelve — already mechanized | `review-trend-divergence.sh` and the `iterate` circuit breaker |'
assert_grep 'likelihood evidence routed to follow-up' "$audit" '| `reviewer-likelihood-evidence-omission-induces-mechanical-demotion` | follow-up — producer enforcement incomplete |'
assert_grep 'convention escalation shelved' "$audit" '| `convention-escalation-has-no-terminus` | shelve — already mechanized | structured review JSON, helper gates, and fail-loud enum validation |'
assert_grep 'differential scope uses explicit restart' "$audit" '| `differential-scope-review-blind-outside-diff` | mechanized here | `iterate/SKILL.md` step 0.6 fresh-run pin and `review-cycle-scope.sh` full scope on explicit restart; breaker stops without an additional review |'
assert_grep 'breaker stops before another review or fix' "$iterate" '発火後は review / fix を invoke せず、停止 sentinel と通知を出して終了する'
assert_grep 'breaker mode routes directly to batch stop' "$iterate" '| `batch` | ステップ 6.1（failed sentinel emit）|'
assert_grep 'breaker mode routes directly to interactive stop' "$iterate" '| `interactive` | ステップ 6.2（機械的停止通知）|'
assert_grep 'breaker preserves batch sentinel' "$iterate" '<!-- [iterate:max-cycles-reached] -->'
assert_grep 'breaker preserves interactive sentinel' "$iterate" '<!-- [iterate:max-cycles-stopped] -->'
assert_grep 'explicit restart starts full scope' "$iterate" 'fresh entry として run 開始点を更新し full scope から始める'
assert_grep 'reset failure warning controls notice' "$iterate" 'その WARNING（`サーキットブレーカー発火時の cycle counter リセットと stop_reason 永続化に失敗`）を停止通知の注意行判定に使う'
assert_grep 'handoff risk needs both writes to fail' "$iterate" '**(c) `HANDOFF_CLEAR=failed` かつ 共有前段の atomic set 失敗**'
assert_grep 'successful second write suppresses handoff warning' "$iterate" '`HANDOFF_CLEAR=failed` のみ（共有前段の atomic set 成功）では**追加しない**'
assert_grep 'unresolved root notice applies to both modes' "$iterate" 'STATE_ROOT が `unresolved` の場合は両モードの停止通知に'
assert_grep 'unresolved root must retain stop sentinel' "$iterate" '停止 sentinel は省略しない'

state_dir=$(mktemp -d "${TMPDIR:-/tmp}/rite-breaker-test-XXXXXX")
trap 'rm -rf "$state_dir"' EXIT
# Execute the shared step 6 bash block from the skill, using the real state
# writer. The wrapper only records atomic writes and injects a write failure.
awk '/^## ステップ 6:/ {section=1; next} section && /^```bash$/ {code=1; next} code && /^```$/ {exit} code {print}' "$iterate" > "$state_dir/step6.template"
if [ ! -s "$state_dir/step6.template" ]; then
  fail 'step 6 shared block is present'
fi
cat > "$state_dir/wrapper.sh" <<'WRAPPER'
bash() {
  if [[ "$1" == */hooks/state-path-resolve.sh ]] && [ "${BREAKER_EMPTY_ROOT:-0}" = 1 ]; then
    return 0
  fi
  if [[ "$1" == */hooks/flow-state.sh ]] && [ "${2:-}" = set ]; then
    printf '%s\n' "$*" >> "$BREAKER_CALL_LOG"
    if [ "${BREAKER_FAIL_SET:-0}" = 1 ]; then
      echo 'injected atomic set failure' >&2
      return 1
    fi
  fi
  command bash "$@"
}
WRAPPER
source "$ROOT/plugins/rite/hooks/scripts/lib/context-marker.sh"
for reason in max-cycles divergence; do
  for mode in batch interactive; do
    for write_result in success failure; do
      case_dir="$state_dir/$reason-$mode-$write_result"
      mkdir -p "$case_dir/.rite/state"
      sid=breaker-contract
      flow="$ROOT/plugins/rite/hooks/flow-state.sh"
      env RITE_STATE_ROOT="$case_dir" CLAUDE_CODE_SESSION_ID="$sid" bash "$flow" set \
        --phase review --issue 2567 --branch issue-2567 --pr 2600 --next pending \
        --cycle-count 4 --handoff '/rite:pr-review 2600' >/dev/null
      if [ "$mode" = batch ]; then active=true; else active=false; fi
      jq -n --argjson active "$active" '{issues:[2567],cursor:0,active:$active}' \
        > "$case_dir/.rite/state/run-queue-$sid.json"
      sed -e "s|{plugin_root}|$ROOT/plugins/rite|g" -e 's/{issue_number}/2567/g' \
        -e 's/{branch_name}/issue-2567/g' -e 's/{pr_number}/2600/g' \
        -e "s/{cb_reason}/$reason/g" "$state_dir/step6.template" > "$case_dir/step6.sh"
      cat "$state_dir/wrapper.sh" "$case_dir/step6.sh" > "$case_dir/run.sh"
      if [ "$write_result" = failure ]; then fail_set=1; else fail_set=0; fi
      output=$(cd "$case_dir" && env RITE_STATE_ROOT="$case_dir" CLAUDE_CODE_SESSION_ID="$sid" \
        BREAKER_CALL_LOG="$case_dir/calls" BREAKER_FAIL_SET="$fail_set" bash "$case_dir/run.sh" 2>&1)
      label="$reason/$mode/$write_result"
      assert_eq "$label keeps terminal mode" "$mode" "$(printf '%s\n' "$output" | marker_get ITERATE_CB_MODE)"
      assert_eq "$label uses one atomic write" 1 "$(wc -l < "$case_dir/calls" | tr -d ' ')"
      assert_grep "$label reset and reason share the write" "$case_dir/calls" "--cycle-count 0 --stop-reason circuit-breaker:$reason"
      flow_file="$case_dir/.rite/sessions/$sid.flow-state"
      if [ "$write_result" = success ]; then
        assert_eq "$label resets counter" 0 "$(jq -r '.cycle_count // 0' "$flow_file")"
        assert_eq "$label persists failure reason" "circuit-breaker:$reason" "$(jq -r '.stop_reason' "$flow_file")"
        assert_eq "$label clears continuation handoff" '' "$(jq -r '.handoff // empty' "$flow_file")"
        if [[ "$output" == *'永続化に失敗'* ]]; then fail "$label has no failure warning"; else pass "$label has no failure warning"; fi
      else
        assert_eq "$label retains counter on failure" 4 "$(jq -r '.cycle_count // 0' "$flow_file")"
        assert_eq "$label retains handoff on failure" '/rite:pr-review 2600' "$(jq -r '.handoff' "$flow_file")"
        if [[ "$output" == *'WARNING: サーキットブレーカー発火時の cycle counter リセットと stop_reason 永続化に失敗'* ]] \
          && [[ "$output" == *'injected atomic set failure'* ]]; then
          pass "$label reports failure and diagnostic"
        else
          fail "$label reports failure and diagnostic"
        fi
      fi
    done
  done
done
# The resolver can return an empty root with rc=0: retain a stop marker and
# an explicit unresolved value rather than emitting an empty recovery target.
output=$(cd "$case_dir" && env RITE_STATE_ROOT="$case_dir" CLAUDE_CODE_SESSION_ID="$sid" \
  BREAKER_CALL_LOG="$case_dir/calls" BREAKER_EMPTY_ROOT=1 bash "$case_dir/run.sh" 2>&1)
assert_eq 'unresolved root retains terminal interactive route' interactive "$(printf '%s\n' "$output" | marker_get ITERATE_CB_MODE)"
assert_eq 'unresolved root is explicit in marker' unresolved "$(printf '%s\n' "$output" | marker_get ITERATE_CB_MODE --field STATE_ROOT)"
if [[ "$output" == *'WARNING: state root を解決できませんでした'* ]]; then
  pass 'unresolved root emits actionable warning'
else
  fail 'unresolved root emits actionable warning'
fi
assert_eq 'no intermediate breaker review subsection' 0 "$(grep -c '^### ステップ 6\.0:' "$iterate" || true)"
assert_grep 'scope split mechanized'  "$audit" '| `reviewer-scope-split-escalates-to-user` | mechanized here | Scope Split Gate below and `pr-review/SKILL.md` |'
assert_grep 'scope rejection mechanized' "$audit" '| `scope-creep-rejection-empirical-gate` | mechanized here | Rejection Evidence Gate below and `fix/SKILL.md` |'
assert_grep 'error-path regression mechanized' "$audit" '| `bugfix-new-error-path-needs-regression-test` | mechanized here | New Error-Path Regression Gate in reviewer prompts |'

assert_grep 'scope split detects both scopes' "$review" 'same root cause is assigned both `current-pr` and `follow-up` scope'
assert_grep 'scope split forbids mechanical collapse' "$review" 'severity の高い側・多数派へ機械統合しない'
assert_grep 'scope split uses debate for analysis' "$review" 'debate は論点整理と推奨 disposition の生成に使う'
assert_grep 'scope split always escalates' "$review" 'consensus の有無にかかわらず treatment の最終決定は AskUserQuestion'
assert_grep 'scope split records decision' "$review" '選択した disposition を Decision Log に記録する'
assert_grep 'follow-up semantics preserved' "$review" 'durable な follow-up Issue / destination が作成または指定されるまで解決済みにしない'
assert_grep 'assignee handoff is required with decision log' "$review" '既存 Issue #{N} を引き受け先とする場合は 7.4.4 を先に必須実行し、記録のみで完了扱いにしない'
assert_grep 'skip is a result of 別 Issue 作成' "$review" '既存 Issue #{N} への見送りなら 7.4.4 の後に 7.4.3'
assert_grep 'closed bounce re-asks 7.2 four options' "$review" '当該候補について 7.2 の既存 4 択を再掲'
assert_grep 'rejected skips 7.4.3 and 7.5' "$review" '`HANDOFF_COMMENT_REJECTED=1` のときは 7.4.3 / 7.5 へ進まない'
assert_grep 'handoff placeholders are declared' "$review" '見送り先として確定した既存 Issue 番号'
assert_grep 'assignee_issue is not source_issue_number' "$review" '`{source_issue_number}`（元 Issue）および 7.2 sentinel の `{N}`（candidate 総数）と混同しない'
assert_grep 'assignee handoff posts via body-file' "$review" 'gh issue comment "$assignee_issue" -R "$owner_repo" --body-file "$tmpfile"'
assert_grep 'assignee handoff posts summary' "$review" '### 指摘の要約'
assert_grep 'assignee handoff posts source PR' "$review" '### 元 PR'
assert_grep 'assignee handoff posts check points' "$review" '### 着手時の確認点'
assert_grep 'assignee handoff success is loud' "$review" 'HANDOFF_COMMENT_POSTED=1; issue=$assignee_issue'
assert_grep 'assignee handoff failure is fail-loud' "$review" 'HANDOFF_COMMENT_FAILED=1; issue=$assignee_issue; reason=gh_comment_failure'
assert_grep 'assignee handoff failure warning is pinned' "$review" 'WARNING: 引き受け先 Issue #${assignee_issue} への申し送りコメント投稿に失敗しました'
assert_grep 'assignee handoff failure listed in report' "$review" '失敗分は未投稿の申し送りとして列挙する'
assert_grep 'closed assignee is rejected' "$review" 'HANDOFF_COMMENT_REJECTED=1; issue=$assignee_issue; reason=closed'
assert_grep 'closed assignee bounces to 7.2' "$review" 'triage 判定を 7.2 へ差し戻す'
if grep -Fq '| 既存 Issue #{N} で対応（新規作成見送り） |' "$review"; then
  fail 'skip must not be a 5th User selection'
else
  pass 'skip is not a 5th User selection'
fi
assert_grep 'rejection evidence gate wired' "$fix" 'Rejection Evidence Gate (state mutation 前)'
assert_grep 'rejection reasons pinned' "$fix" '`scope-creep` / `out-of-scope` / `minor` / `user-override`'
assert_grep 'rejection classification required' "$fix" '構造化 enum から必ず選択'
assert_grep 'cross-validation required' "$fix" '別 reviewer の cross-validation'
assert_grep 'counterfactual evidence required' "$fix" 'empirical counterfactual/revert test'
assert_grep 'both rejection artifacts required' "$fix" '両方の artifact を Decision Log に記録する'
assert_grep 'invalid rejection cannot mutate' "$fix" '`status = acknowledged` override・reply・fingerprint block・commit trailer の**いずれにも到達せず**'
assert_grep 'user override is not bypass' "$fix" '`user-override` も evidence gate の例外ではない'
assert_grep 'rendered reason is canonical' "$fix" '`accept_reason_rendered` を `{accept_reason_class}: {accept_reason_detail}`'
assert_grep 'reply always records class' "$fix" '`; reason: {accept_reason_rendered}`'
assert_grep 'trailer uses rendered reason' "$fix" 'Step 1 で生成した `accept_reason_rendered`'
if grep -Fq 'user decision: accept (no reason given)' "$fix"; then
  printf 'FAIL: stale no-reason acceptance path remains\n' >&2
  failures=$((failures + 1))
else
  printf 'PASS: no stale no-reason acceptance path\n'
fi
assert_grep 'test reviewer checks new error paths' "$test_reviewer" 'non-vacuity check'
assert_grep 'test reviewer requires exact branch' "$test_reviewer" 'enters that exact new branch'
assert_grep 'test reviewer requires observable outcome' "$test_reviewer" 'asserts the observable outcome'
assert_grep 'test reviewer requires mutation failure' "$test_reviewer" 'equivalent mutation) must make the new test fail'
assert_grep 'error reviewer checks regression proof' "$error_reviewer" 'Regression proof for newly added paths'
assert_grep 'error reviewer reports missing proof' "$error_reviewer" 'Report missing proof as a current-PR finding'

gate_line=$(grep -n 'Rejection Evidence Gate (state mutation 前)' "$fix" | head -1 | cut -d: -f1)
mutation_line=$(grep -n 'finding state の override' "$fix" | head -1 | cut -d: -f1)
reply_line=$(grep -n 'reply 投稿' "$fix" | head -1 | cut -d: -f1)
persist_line=$(grep -n 'accept fingerprint 永続化' "$fix" | head -1 | cut -d: -f1)
trailer_line=$(grep -n 'Acknowledged-finding trailer (accept' "$fix" | head -1 | cut -d: -f1)
section_start=$(grep -n '^### 2\.1\.A accept' "$fix" | head -1 | cut -d: -f1)
section_end=$(awk -v start="$section_start" 'NR > start && /^### / { print NR; exit }' "$fix")
if [ -n "$gate_line" ] && [ -n "$mutation_line" ] && [ -n "$persist_line" ] \
  && [ -n "$reply_line" ] && [ -n "$trailer_line" ] && [ -n "$section_start" ] && [ -n "$section_end" ] \
  && [ "$section_start" -lt "$gate_line" ] && [ "$gate_line" -lt "$section_end" ] \
  && [ "$gate_line" -lt "$mutation_line" ] && [ "$gate_line" -lt "$reply_line" ] \
  && [ "$gate_line" -lt "$persist_line" ] && [ "$gate_line" -lt "$trailer_line" ]; then
  printf 'PASS: rejection gate precedes all mutation and durable-output steps\n'
else
  printf 'FAIL: rejection gate must remain in 2.1.A before mutation, reply, persistence, and trailer\n' >&2
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  printf '%s contract assertion(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All review/fix promotion contract assertions passed.\n'
