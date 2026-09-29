#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
audit="$ROOT/plugins/rite/skills/pr-review/references/promotion-audit-review-fix-loop.md"
review="$ROOT/plugins/rite/skills/pr-review/references/scope-triage.md"
review_main="$ROOT/plugins/rite/skills/pr-review/SKILL.md"
fix="$ROOT/plugins/rite/skills/fix/SKILL.md"
accept="$ROOT/plugins/rite/skills/fix/references/accept-finding.md"
iterate="$ROOT/plugins/rite/skills/iterate/SKILL.md"
iterate_step="$ROOT/plugins/rite/scripts/iterate-step.sh"
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
assert_grep 'explicit restart starts full scope' "$iterate" 'がある停止は通常の再実行では新 run にならない'
assert_grep 'reset failure warning controls notice' "$iterate" 'その WARNING（`サーキットブレーカー発火時の cycle counter リセットと stop_reason 永続化に失敗`）を停止通知の注意行判定に使う'
assert_grep 'handoff risk needs both writes to fail' "$iterate" '**(c) `HANDOFF_CLEAR=failed` かつ 共有前段の atomic set 失敗**'
assert_grep 'successful second write suppresses handoff warning' "$iterate" '`HANDOFF_CLEAR=failed` のみ（共有前段の atomic set 成功）では**追加しない**'
assert_grep 'unresolved root notice applies to both modes' "$iterate" 'STATE_ROOT が `unresolved` の場合は両モードの停止通知に'
assert_grep 'unresolved root must retain stop sentinel' "$iterate" '停止 sentinel は省略しない'

state_dir=$(mktemp -d "${TMPDIR:-/tmp}/rite-breaker-test-XXXXXX")
trap 'rm -rf "$state_dir"' EXIT
# Execute the shared step 6 body (step_breaker in iterate-step.sh, which the
# skill calls as `iterate-step.sh breaker`), using the real state writer. The
# wrapper only records atomic writes and injects a write failure.
awk '/^step_breaker\(\) \{$/ {body=1; next} body && /^}$/ {exit} body {print}' "$iterate_step" > "$state_dir/step6.template"
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
      # The breaker runs after fix; an unfinished review cannot reset its counter.
      env RITE_STATE_ROOT="$case_dir" CLAUDE_CODE_SESSION_ID="$sid" bash "$flow" set \
        --phase fix --issue 2567 --branch issue-2567 --pr 2600 --next pending \
        --cycle-count 4 --handoff '/rite:pr-review 2600' >/dev/null
      if [ "$mode" = batch ]; then active=true; else active=false; fi
      jq -n --argjson active "$active" '{issues:[2567],cursor:0,active:$active}' \
        > "$case_dir/.rite/state/run-queue-$sid.json"
      { printf 'plugin_root=%q\nissue_number=2567\nbranch_name=issue-2567\npr_number=2600\ncb_reason=%q\n' \
          "$ROOT/plugins/rite" "$reason"
        cat "$state_dir/step6.template"; } > "$case_dir/step6.sh"
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

assert_grep 'scope split detects both scopes' "$review_main" 'same root cause is assigned both `current-pr` and `follow-up` scope'
assert_grep 'scope split forbids mechanical collapse' "$review_main" 'severity の高い側・多数派へ機械統合しない'
assert_grep 'scope split uses debate for analysis' "$review_main" 'debate は論点整理と推奨 disposition の生成に使う'
assert_grep 'scope split always escalates' "$review_main" 'consensus の有無にかかわらず treatment の最終決定は AskUserQuestion'
assert_grep 'scope split records decision' "$review_main" '選択した disposition を Decision Log に記録する'
assert_grep 'follow-up semantics preserved' "$review_main" 'durable な follow-up Issue / destination が作成または指定されるまで解決済みにしない'
assert_grep 'LINK handoff is required with decision log' "$review" '| `record`（`LINK`） | 7.4.4（追跡先 `tracker` への申し送り）を先に必須実行し、記録のみで完了扱いにしない。その後 7.4.3（トークンなし）。'
assert_grep 'closed tracker returns to the adoption gate' "$review" '判定記録の `tracker` を直して 7.2 のゲートからやり直す'
assert_grep 'rejected skips 7.4.3 and 7.5' "$review" '`HANDOFF_COMMENT_REJECTED=1` のときは 7.4.3 / 7.5 へ進まない'
assert_grep 'handoff placeholders are declared' "$review" '`LINK` の判定の `tracker`（追跡先の既存 Issue 番号）'
assert_grep 'assignee_issue is not source_issue_number' "$review" '`{source_issue_number}`（元 Issue）および 7.2 sentinel の `{N}`（candidate 総数）と混同しない'
assert_grep 'assignee handoff posts via body-file' "$review" 'gh issue comment "$assignee_issue" -R "$owner_repo" --body-file "$tmpfile"'
assert_grep 'assignee handoff posts summary' "$review" '### 指摘の要約'
assert_grep 'assignee handoff posts source PR' "$review" '### 元 PR'
assert_grep 'assignee handoff posts check points' "$review" '### 着手時の確認点'
assert_grep 'assignee handoff success is loud' "$review" 'HANDOFF_COMMENT_POSTED=1; issue=$assignee_issue'
assert_grep 'assignee handoff failure is fail-loud' "$review" 'HANDOFF_COMMENT_FAILED=1; issue=$assignee_issue; reason=gh_comment_failure'
assert_grep 'assignee handoff failure warning is pinned' "$review" 'WARNING: 引き受け先 Issue #${assignee_issue} への申し送りコメント投稿に失敗しました'
assert_grep 'assignee handoff failure stops at 7.4.5' "$review" '投稿に失敗しても残りの 7.4 は続け、失敗は 7.4.5 の `{write_failures}` に数える'
assert_grep 'closed assignee is rejected' "$review" 'HANDOFF_COMMENT_REJECTED=1; issue=$assignee_issue; reason=closed'
assert_grep 'closed assignee bounces to 7.2' "$review" 'triage 判定を 7.2 へ差し戻す'
if grep -Fq '| 既存 Issue #{N} で対応（新規作成見送り） |' "$review"; then
  fail 'skip must not be a 5th User selection'
else
  pass 'skip is not a 5th User selection'
fi
assert_grep 'rejection evidence gate wired' "$accept" 'Rejection Evidence Gate (state mutation 前)'
assert_grep 'rejection reasons pinned' "$accept" '`scope-creep` / `out-of-scope` / `minor` / `user-override`'
assert_grep 'rejection classification required' "$accept" '構造化 enum から必ず選択'
assert_grep 'cross-validation required' "$accept" '別 reviewer の cross-validation'
assert_grep 'counterfactual evidence required' "$accept" 'empirical counterfactual/revert test'
assert_grep 'both rejection artifacts required' "$accept" '両方の artifact を Decision Log に記録する'
assert_grep 'invalid rejection cannot mutate' "$accept" '`status = acknowledged` override・reply・fingerprint block・commit trailer の**いずれにも到達せず**'
assert_grep 'user override is not bypass' "$accept" '`user-override` も evidence gate の例外ではない'
assert_grep 'rendered reason is canonical' "$accept" '`accept_reason_rendered` を `{accept_reason_class}: {accept_reason_detail}`'
assert_grep 'reply always records class' "$accept" '`; reason: {accept_reason_rendered}`'
assert_grep 'trailer uses rendered reason' "$fix" 'Step 1 で生成した `accept_reason_rendered`'
if grep -Fq 'user decision: accept (no reason given)' "$fix" "$accept"; then
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

gate_line=$(grep -n 'Rejection Evidence Gate (state mutation 前)' "$accept" | head -1 | cut -d: -f1)
mutation_line=$(grep -n 'finding state の override' "$accept" | head -1 | cut -d: -f1)
reply_line=$(grep -n 'reply 投稿' "$accept" | head -1 | cut -d: -f1)
persist_line=$(grep -n 'accept fingerprint 永続化' "$accept" | head -1 | cut -d: -f1)
route_line=$(grep -n 'references/accept-finding.md' "$fix" | head -1 | cut -d: -f1)
trailer_line=$(grep -n 'Acknowledged-finding trailer (accept' "$fix" | head -1 | cut -d: -f1)
section_start=$(grep -n '^### 2\.1\.A accept' "$accept" | head -1 | cut -d: -f1)
section_end=$(awk -v start="$section_start" 'NR > start && /^### / { print NR; found=1; exit } END { if (!found) print NR+1 }' "$accept")
if [ -n "$gate_line" ] && [ -n "$mutation_line" ] && [ -n "$persist_line" ] \
  && [ -n "$reply_line" ] && [ -n "$trailer_line" ] && [ -n "$section_start" ] && [ -n "$section_end" ] \
  && [ "$section_start" -lt "$gate_line" ] && [ "$gate_line" -lt "$section_end" ] \
  && [ "$gate_line" -lt "$mutation_line" ] && [ "$gate_line" -lt "$reply_line" ] \
  && [ "$gate_line" -lt "$persist_line" ] && [ -n "$route_line" ] && [ "$route_line" -lt "$trailer_line" ]; then
  printf 'PASS: rejection gate precedes all mutation and durable-output steps\n'
else
  printf 'FAIL: rejection gate must remain in 2.1.A before mutation, reply, persistence, and trailer\n' >&2
  failures=$((failures + 1))
fi

# Scope triage (pr-review 7.2-7.4): the adoption exit decides each out-of-scope candidate.
triage_table() { awk -v head="$1" '$0 == head { f = 1 } f && /^$/ { exit } f { print }' "$review"; }
token_table=$(triage_table '| 候補 | `{deferred_token}` |')
assert_eq 'deferred token table keeps two rows' 4 "$(printf '%s\n' "$token_table" | grep -c '^|' || true)"
token_rows=$(printf '%s\n' "$token_table" | grep -F 'rite:deferred-defect' || true)
assert_eq 'one row carries the deferred token' 1 "$(printf '%s\n' "$token_rows" | grep -c . || true)"
if grep -Fq '| 採否ゲートの verdict が `file` |' <<< "$token_rows" && ! grep -Fq 'record' <<< "$token_rows"; then
  pass 'the deferred token goes only to the file verdict'
else
  fail "the deferred token row must name only the file verdict: $token_rows"
fi
assert_eq 'the record verdict gets an empty token' '| それ以外（verdict が `record`） | 空文字列 |' \
  "$(printf '%s\n' "$token_table" | grep -F '`record`' || true)"
route_table=$(triage_table '| verdict / exit | Action |')
assert_eq 'routing table has four rows' 6 "$(printf '%s\n' "$route_table" | grep -c '^|' || true)"
assert_eq 'routing: the token is written only for a file verdict with a source Issue' \
  '| `file`、`{source_issue_number}` あり | 7.4.3 を先送りトークン付きで実行する。起票は cleanup ステップ 6.0 の follow-up が行う（ここでは Issue を作らない） |' \
  "$(printf '%s\n' "$route_table" | grep -F 'トークン付き' || true)"
assert_eq 'routing: only a file verdict without a source Issue creates an Issue now' 1 \
  "$(printf '%s\n' "$route_table" | grep -F '7.4.1-7.4.2' | grep -c '^| `file`、`{source_issue_number}` が空 |' || true)"
assert_eq 'routing: no other row creates an Issue now' 1 "$(printf '%s\n' "$route_table" | grep -c '7.4.1-7.4.2' || true)"
assert_eq 'routing: record rows write no token' 2 \
  "$(printf '%s\n' "$route_table" | grep '^| `record`' | grep -c 'トークンなし' || true)"
assert_grep 'held writes nothing and skips 7.4-7.7 and step 8' "$review" \
  '| `3`（held） | 7.4（Decision Log・先送りトークン・Issue 作成・申し送り）から 7.7 までを一切実行しない。sentinel も出さない。下の採否保留の停止を実行し、ステップ 8（8.0.2 を含む）へ進まない |'
assert_grep 'the 7.7 gate does not run after a held gate' "$review" \
  '7.2 のゲートが held（`ADOPTION_GATE_RC=3`）を返したときは実行しない（採否保留の停止で終わる）'
assert_grep 'held candidates rejoin verbatim with a new id' "$review" \
  'その `candidates` の各候補を、id だけ次の `C-n` に振り直して内容は一字も変えずに候補集合へ加える（id を除く全欄が一致する候補が既にあれば加えない）'
assert_grep 'held candidates rejoin regardless of the commit' "$review" \
  'triage の hold ファイルがあれば、その `head` が本 cycle の review JSON の `commit_sha` と同じかどうかを問わず（commit を問わず）、その `candidates` の各候補を'
assert_grep 'a new commit re-judges the held candidates' "$review" \
  '新しい commit でも合流させて分類役が判定し直す（直っていれば `RESOLVED`）'
if grep -Fq 'があり、その `head` が本 cycle の review JSON の `commit_sha` と同じなら、その `candidates`' "$review"; then
  fail 'held candidates must not rejoin only on the same head'
else
  pass 'held candidates do not rejoin only on the same head'
fi
assert_grep 'the triage step skips only with no candidate and no hold file' "$review" \
  '7.1 の候補が 0 件かつ triage の hold ファイル `{state_root}/.rite/state/adoption-hold-{pr_number}-triage.json` が無いときだけステップ 7 を skip する（**7.7 も skip**）。hold ファイルがあれば候補 0 件でも下の手順でゲートを呼ぶ。'
assert_grep 'the triage state root is the resolver output' "$review" \
  '`{state_root}` は `bash {plugin_root}/hooks/state-path-resolve.sh` の出力。'
if grep -Fq '0 件: ステップ 7 を skip' "$review"; then
  fail 'zero candidates alone must not skip the triage step'
else
  pass 'zero candidates alone do not skip the triage step'
fi
assert_grep 'candidate_count counts held candidates regardless of the commit' "$review_main" \
  '`.rite/state/adoption-hold-{pr_number}-triage.json` があれば、commit（`head`）を問わず、その `candidates` のうち内容（`id` 以外の全欄）が一致する候補の無いものも数える'
assert_grep 'candidate_count resolves the state root' "$review_main" \
  '`{state_root}`（`bash {plugin_root}/hooks/state-path-resolve.sh` の出力）'
if grep -Fq '`head` が `{current_commit_sha}` と同じなら、その `candidates`' "$review_main"; then
  fail 'candidate_count must not count held candidates only on the same head'
else
  pass 'candidate_count does not count held candidates only on the same head'
fi
assert_grep 'step 7.2 skips only with no candidate and no hold file' "$review_main" \
  '`candidate_count == 0`（hold の候補を含む）かつ triage の hold ファイルが無いときだけ 7.2〜7.7 をスキップする。'
for stale in '推奨決定 + User Confirmation' 'モードに応じた確認' 'complete confirmation' 'ユーザー固有・不可逆' 'ユーザー確認のうえ'; do
  if grep -Fq "$stale" "$review_main" "$ROOT/plugins/rite/skills/pr-review/references/reviewer-prompt-generator.md"; then
    fail "per-candidate confirmation remains in pr-review: $stale"
  else
    pass "no per-candidate confirmation in pr-review: $stale"
  fi
done
assert_grep 'the held stop points at the hold file resume' "$review" \
  '--next "採否の出口待ち。{hold_file} の resume（ゲートの WARNING にも出る）に従って再開"'
assert_grep 'a held-then-corrected record set is resumed, not rewritten' "$review" \
  'その `head` が本 cycle の review JSON の `commit_sha` と同じなら、その記録（保留後に直された記録）から始める'
assert_grep 'an Issue that already tracks the root cause becomes the tracker' "$review" \
  '既存の Issue（前回この手順で作った Issue を含む）が同じ根因を追跡していれば `tracker` に入れる'
assert_grep 'any other gate result stops with review error' "$review" '| それ以外 | `[review:error]` を出して停止する（ステップ 8 へ進まない） |'

# Execute the real gate-call block with a stub gate: it must write the records under the reviewed
# commit, pass the triage arguments and surface the gate's exit code.
triage_dir="$state_dir/triage"
mkdir -p "$triage_dir/plugin/hooks/scripts" "$triage_dir/root/.rite/review-results"
awk '/^### 7\.2-7\.3 / { s=1 } s && /^```bash$/ { a=1; blk=""; next }
  a && /^```$/ { a=0; if (index(blk, "--kind triage")) { printf "%s", blk; exit } next }
  a { blk = blk $0 "\n" }' "$review" > "$triage_dir/block.sh"
assert_grep 'gate block calls the triage gate' "$triage_dir/block.sh" 'review-adoption-gate.sh --pr {pr_number} --kind triage'
printf '#!/bin/bash\nprintf "%%s\\n" "$TRIAGE_ROOT"\n' > "$triage_dir/plugin/hooks/state-path-resolve.sh"
cat > "$triage_dir/plugin/hooks/scripts/review-adoption-gate.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$TRIAGE_ARGS"
exit "$TRIAGE_GATE_RC"
STUB
printf '{"commit_sha": "c0ffee"}\n' > "$triage_dir/root/.rite/review-results/5-20260101T000000.json"
triage_records='[{"ids": ["C-1"]}]'
triage_candidates='{"candidates": [{"id": "C-1", "content": "full text"}]}'
run_triage_block() {
  local issue=$1 code
  code=$(cat "$triage_dir/block.sh")
  code=${code//\{plugin_root\}/$triage_dir/plugin}
  code=${code//\{pr_number\}/5}
  code=${code//\{base_branch\}/develop}
  code=${code//\{source_issue_number\}/$issue}
  code=${code//\{records\}/$triage_records}
  code=${code//\{candidates\}/$triage_candidates}
  rm -f "$triage_dir/args"
  TRIAGE_ROOT="$triage_dir/root" TRIAGE_ARGS="$triage_dir/args" TRIAGE_GATE_RC="$TRIAGE_GATE_RC" \
    bash -c "$code" 2>&1 || true
}
out=$(TRIAGE_GATE_RC=3 run_triage_block 7)
assert_eq 'gate block surfaces the held exit code' '[CONTEXT] ADOPTION_GATE_RC=3' "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ADOPTION_GATE_RC=' || true)"
assert_eq 'records are written with their candidates under the reviewed commit' \
  '{"adoption":{"head":"c0ffee","candidates":[{"id":"C-1","content":"full text"}],"records":[{"ids":["C-1"]}]}}' \
  "$(jq -c . "$triage_dir/root/.rite/state/adoption-5-triage.json" 2>/dev/null || true)"
args=$(paste -sd ' ' "$triage_dir/args" 2>/dev/null || true)
case "$args" in
  *"--kind triage"*"--review-result $triage_dir/root/.rite/review-results/5-20260101T000000.json --base origin/develop --issue 7") pass 'gate receives the triage arguments' ;;
  *) fail "gate arguments: $args" ;;
esac
rm -f "$triage_dir/root/.rite/state/adoption-hold-5-triage.json"
out=$(TRIAGE_GATE_RC=0 run_triage_block '')
assert_eq 'gate block surfaces the decided exit code' '[CONTEXT] ADOPTION_GATE_RC=0' "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ADOPTION_GATE_RC=' || true)"
assert_eq 'the gate block names the review JSON 7.4.5 records as the source' '[CONTEXT] TRIAGE_REVIEW_JSON=5-20260101T000000.json' \
  "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] TRIAGE_REVIEW_JSON=' || true)"
# A decided run keeps its candidates in the hold until 7.4.5 releases it, even with no earlier hold.
assert_eq 'a decided run keeps its candidates in the triage hold' 'triage|c0ffee|[{"id":"C-1","content":"full text"}]' \
  "$(jq -r '"\(.kind)|\(.head)|\(.candidates | tojson)"' "$triage_dir/root/.rite/state/adoption-hold-5-triage.json" 2>/dev/null || true)"
case "$(paste -sd ' ' "$triage_dir/args" 2>/dev/null)" in
  *--issue*) fail 'an empty source Issue must not pass --issue' ;;
  *) pass 'an empty source Issue passes no --issue' ;;
esac
# A tracker 7.4.2 wrote back survives a rerun on a new HEAD: it moves to the record whose candidate has the
# same full text as the candidate the previous record's ids named (kept in the record file itself), so the
# gate links it instead of filing it again.
state="$triage_dir/root/.rite/state"
prev_records() { printf '{"adoption": {"head": "old", "candidates": %s, "records": %s}}\n' "$1" "$2" > "$state/adoption-5-triage.json"; }
printf '{"candidates": [{"id": "C-1", "content": "full text"}, {"id": "C-2", "content": "other"}]}\n' > "$state/adoption-hold-5-triage.json"
prev_records '[{"id": "C-1", "content": "full text"}, {"id": "C-2", "content": "other"}]' '[{"ids": ["C-1"], "tracker": 77}, {"ids": ["C-2"]}]'
printf '{"commit_sha": "beef"}\n' > "$triage_dir/root/.rite/review-results/5-20260102000000.json"
triage_candidates='{"candidates": [{"id": "C-3", "content": "full text"}, {"id": "C-4", "content": "other"}]}'
triage_records='[{"ids": ["C-3"]}, {"ids": ["C-4"]}]'
out=$(TRIAGE_GATE_RC=0 run_triage_block 7)
assert_eq 'a written-back tracker moves to the same candidate on a new HEAD' 'beef|77|null' \
  "$(jq -r '"\(.adoption.head)|\(.adoption.records[0].tracker)|\(.adoption.records[1].tracker)"' "$state/adoption-5-triage.json" 2>/dev/null || true)"
# A run that stopped between the record write and the hold write leaves a hold whose ids mean other
# candidates. The ids are read back from the record file, so the tracker stays with its own candidate.
printf '{"candidates": [{"id": "C-1", "content": "other"}, {"id": "C-2", "content": "full text"}]}\n' > "$state/adoption-hold-5-triage.json"
prev_records '[{"id": "C-1", "content": "full text"}, {"id": "C-2", "content": "other"}]' '[{"ids": ["C-1"], "tracker": 77}, {"ids": ["C-2"]}]'
triage_candidates='{"candidates": [{"id": "C-2", "content": "other"}, {"id": "C-3", "content": "full text"}]}'
triage_records='[{"ids": ["C-2"]}, {"ids": ["C-3"]}]'
out=$(TRIAGE_GATE_RC=0 run_triage_block 7)
assert_eq 'a hold from another run does not move the tracker to another candidate' 'null|77' \
  "$(jq -r '"\(.adoption.records[0].tracker)|\(.adoption.records[1].tracker)"' "$state/adoption-5-triage.json" 2>/dev/null || true)"
# A held candidate that carried a tracker but is missing from this run's candidates stops the run instead of
# dropping the tracker (step 1 merges every hold candidate verbatim).
printf '{"candidates": [{"id": "C-1", "content": "full text"}]}\n' > "$state/adoption-hold-5-triage.json"
prev_records '[{"id": "C-1", "content": "full text"}]' '[{"ids": ["C-1"], "tracker": 77}]'
triage_candidates='{"candidates": [{"id": "C-3", "content": "reworded text"}]}'
triage_records='[{"ids": ["C-3"]}]'
out=$(TRIAGE_GATE_RC=0 run_triage_block 7)
assert_eq 'a tracker whose held candidate was dropped stops before the gate' '[CONTEXT] ADOPTION_GATE_RC=2' \
  "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ADOPTION_GATE_RC=' || true)"
assert_eq 'the dropped tracker stays in the record file' '77' "$(jq -r '.adoption.records[0].tracker' "$state/adoption-5-triage.json" 2>/dev/null || true)"
# A record file without candidates cannot carry a tracker: stop instead of guessing.
printf '{"adoption": {"head": "old", "records": [{"ids": ["C-1"], "tracker": 77}]}}\n' > "$state/adoption-5-triage.json"
triage_candidates='{"candidates": [{"id": "C-3", "content": "full text"}]}'
out=$(TRIAGE_GATE_RC=0 run_triage_block 7)
assert_eq 'a record file without candidates stops before the gate' '[CONTEXT] ADOPTION_GATE_RC=2' \
  "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ADOPTION_GATE_RC=' || true)"
# The classifier's own tracker is kept.
prev_records '[{"id": "C-1", "content": "full text"}]' '[{"ids": ["C-1"], "tracker": 77}]'
triage_records='[{"ids": ["C-3"], "tracker": 90}]'
out=$(TRIAGE_GATE_RC=0 run_triage_block 7)
assert_eq "the classifier's tracker is not overwritten" '90' "$(jq -r '.adoption.records[0].tracker' "$state/adoption-5-triage.json" 2>/dev/null || true)"
# No hold means nothing to carry.
rm -f "$state/adoption-hold-5-triage.json"
prev_records '[{"id": "C-1", "content": "full text"}]' '[{"ids": ["C-1"], "tracker": 77}]'
triage_records='[{"ids": ["C-3"]}]'
out=$(TRIAGE_GATE_RC=0 run_triage_block 7)
assert_eq 'without a previous hold no tracker is carried' 'null' "$(jq -r '.adoption.records[0].tracker' "$state/adoption-5-triage.json" 2>/dev/null || true)"
# Two different trackers for one record cannot be resolved: stop instead of picking one.
printf '{"candidates": [{"id": "C-1", "content": "full text"}, {"id": "C-2", "content": "new"}]}\n' > "$state/adoption-hold-5-triage.json"
prev_records '[{"id": "C-1", "content": "full text"}, {"id": "C-2", "content": "new"}]' '[{"ids": ["C-1"], "tracker": 77}, {"ids": ["C-2"], "tracker": 78}]'
triage_candidates='{"candidates": [{"id": "C-3", "content": "full text"}, {"id": "C-4", "content": "new"}]}'
triage_records='[{"ids": ["C-3", "C-4"]}]'
out=$(TRIAGE_GATE_RC=0 run_triage_block 7)
assert_eq 'conflicting previous trackers stop before the gate' '[CONTEXT] ADOPTION_GATE_RC=2' "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ADOPTION_GATE_RC=' || true)"
# A decided run that cannot keep its candidates in the hold stops instead of going on to 7.4.
rm -f "$state/adoption-hold-5-triage.json" "$state/adoption-5-triage.json"
triage_records='[{"ids": ["C-3"]}]'
mkdir "$state/adoption-hold-5-triage.json.tmp"
out=$(TRIAGE_GATE_RC=0 run_triage_block 7)
assert_eq 'a decided run that cannot write the hold stops' '[CONTEXT] ADOPTION_GATE_RC=2' "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ADOPTION_GATE_RC=' || true)"
rmdir "$state/adoption-hold-5-triage.json.tmp"
triage_records='[{"ids": ["C-1"]}]'
triage_candidates='{"candidates": [{"id": "C-1", "content": "full text"}]}'
rm -f "$triage_dir/root/.rite/review-results/"*.json
out=$(TRIAGE_GATE_RC=0 run_triage_block 7)
assert_eq 'a missing review JSON stops before the gate' '[CONTEXT] ADOPTION_GATE_RC=2' "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ADOPTION_GATE_RC=' || true)"
if [ -e "$triage_dir/args" ]; then fail 'the gate must not run without a review JSON'; else pass 'the gate does not run without a review JSON'; fi

# 7.4.5: the record verdicts of triage go to the rejected ledger under [reviewer, file_line], and the
# triage hold is released only after the ledger record succeeds.
assert_grep 'step 2 copies the ledger prior keyed by reviewer and file_line' "$review" \
  '候補の `reviewer` と `file_line` が行の `finding_id` と `file:line` に一致する行のうち、最後の `REJECT` / `ADOPT` 行をその候補の記録の `prior`'
assert_grep 'every disposition is followed by 7.4.5 once' "$review" '全判定記録の処分を終えたら 7.4.5（台帳への記録と保留の解除）を 1 回実行する。'
# A candidate without file_line has no unique ledger key: it is neither written nor given a prior.
assert_grep 'step 2 copies no prior to a candidate without file_line' "$review" '`file_line` が空の候補には prior を写さない'
assert_grep '7.4.5 writes no row for a candidate without file_line' "$review" '`file_line` が空の候補は台帳のキーが一意にならないので書かない'
ledger_dir="$triage_dir/ledger"
mkdir -p "$ledger_dir/plugin/hooks/scripts" "$ledger_dir/root/.rite/state"
awk '/^#### 7\.4\.5 / { s=1 } s && /^```bash$/ { a=1; next } a && /^```$/ { exit } a { print }' "$review" > "$ledger_dir/block.sh"
assert_grep '7.4.5 block releases the triage hold' "$ledger_dir/block.sh" 'adoption-hold-{pr_number}-triage.json'
printf '#!/bin/bash\nprintf "%%s\\n" "$LEDGER_ROOT"\n' > "$ledger_dir/plugin/hooks/state-path-resolve.sh"
ln -s "$ROOT/plugins/rite/hooks/scripts/nb-sweep-ledger.sh" "$ledger_dir/plugin/hooks/scripts/nb-sweep-ledger.sh"
ln -s "$ROOT/plugins/rite/hooks/control-char-neutralize.sh" "$ledger_dir/plugin/hooks/control-char-neutralize.sh"
printf '#!/bin/bash\nexit 0\n' > "$ledger_dir/plugin/hooks/flow-state.sh"
# --print-record-body: LEDGER_BODY names the stored record comment (empty = no comment yet);
# LEDGER_BODY_FAIL makes the read fail with that reason.
cat > "$ledger_dir/plugin/hooks/review-nonblocking-record.sh" <<'STUB'
#!/bin/bash
if [ "$1" = --print-record-body ]; then
  if [ -n "${LEDGER_BODY_FAIL:-}" ]; then
    echo "[CONTEXT] NONBLOCKING_RECORD_BODY=failed; pr=5; reason=$LEDGER_BODY_FAIL" >&2
    exit 1
  fi
  [ -n "${LEDGER_BODY:-}" ] && cat "$LEDGER_BODY"
  exit 0
fi
while [ "$#" -gt 0 ]; do [ "$1" = --content-file ] && cp "$2" "$LEDGER_POSTED"; shift; done
echo "[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=5; outcome=$LEDGER_OUTCOME; count=0; iteration_id=triage-5; comment_id=1; degraded=0" >&2
STUB
# The row the next cycle's step 2 reads back is built from the 7.4.5 row format, so a changed key column fails the round trip.
row_format=$(grep -oF '行形式は `| {reviewer} | {file_line} | {exit} | {判定文} | {review_json_basename} |`' "$review" | head -1 \
  | sed -e 's/^行形式は `//' -e 's/`$//' || true)
assert_eq '7.4.5 keys ledger rows by reviewer and file_line' '| {reviewer} | {file_line} | {exit} | {判定文} | {review_json_basename} |' "$row_format"
ledger_row=$row_format
ledger_row=${ledger_row//\{reviewer\}/code-quality-reviewer}
ledger_row=${ledger_row//\{file_line\}/tool.sh:3}
ledger_row=${ledger_row//\{exit\}/REJECT}
ledger_row=${ledger_row//\{判定文\}/the usage text is intentional}
ledger_row=${ledger_row//\{review_json_basename\}/5-20260101000000.json}
run_ledger_block() {
  local code
  code=$(cat "$ledger_dir/block.sh")
  code=${code//\{plugin_root\}/$ledger_dir/plugin}
  code=${code//\{pr_number\}/5}
  code=${code//\{owner_repo\}/o/r}
  code=${code//\{rows\}/$ledger_row}
  code=${code//\{write_failures\}/${2:-0}}
  code=${code//\{untracked_issues\}/${3:-}}
  printf '{"kind":"triage","pr":5,"candidates":[],"resume":"old"}\n' > "$ledger_dir/root/.rite/state/adoption-hold-5-triage.json"
  rm -f "$ledger_dir/posted.md"
  LEDGER_ROOT="$ledger_dir/root" LEDGER_POSTED="$ledger_dir/posted.md" LEDGER_OUTCOME="$1" bash -c "$code" 2>&1
}
out=$(run_ledger_block updated)
assert_grep 'the REJECT row built from the 7.4.5 row format reaches the ledger' "$ledger_dir/posted.md" \
  '| code-quality-reviewer | tool.sh:3 | REJECT | the usage text is intentional | 5-20260101000000.json |'
if [ -e "$ledger_dir/root/.rite/state/adoption-hold-5-triage.json" ]; then
  fail 'a recorded ledger must release the triage hold'
else
  pass 'a recorded ledger releases the triage hold'
fi
out=$(run_ledger_block skipped || true)
assert_eq 'a failed ledger record stops the review' '[review:error]' "$(printf '%s\n' "$out" | grep -x '\[review:error\]' || true)"
if [ -e "$ledger_dir/root/.rite/state/adoption-hold-5-triage.json" ]; then
  pass 'a failed ledger record keeps the triage hold'
else
  fail 'a failed ledger record must keep the triage hold'
fi
assert_eq 'a failed ledger record stops without the retried generic error' \
  '[CONTEXT] REVIEW_STOP=adoption_held; kind=triage; hold_file='"$ledger_dir/root/.rite/state/adoption-hold-5-triage.json" \
  "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] REVIEW_STOP=' || true)"
# A failed Issue creation / Decision Log append / handoff earlier in 7.4 keeps the hold as well, writes no
# ledger row, and rewrites the hold's resume to the failed writes instead of the records.
out=$(run_ledger_block updated 1 || true)
assert_eq 'an incomplete 7.4 write stops the review' '[review:error]' "$(printf '%s\n' "$out" | grep -x '\[review:error\]' || true)"
if [ -e "$ledger_dir/posted.md" ]; then fail 'an incomplete 7.4 write must not record the ledger'; else pass 'an incomplete 7.4 write records no ledger'; fi
assert_grep 'an incomplete 7.4 write keeps the hold with a resume for the writes' \
  "$ledger_dir/root/.rite/state/adoption-hold-5-triage.json" '7.4 の外部への書き込み（writes_incomplete）が済んでいない'
if grep -qF 'tracker に書き戻せていない' "$ledger_dir/root/.rite/state/adoption-hold-5-triage.json"; then
  fail 'a resume without untracked Issues must not name any'
else
  pass 'a resume without untracked Issues names none'
fi
out=$(run_ledger_block updated 1 '#77' || true)
assert_grep 'a created Issue that was not written back is named in the resume' \
  "$ledger_dir/root/.rite/state/adoption-hold-5-triage.json" 'ただし #77 は tracker に書き戻せていない'
# When the hold cannot take the new resume either, the resume still reaches the stop's stderr.
mkdir "$ledger_dir/root/.rite/state/adoption-hold-5-triage.json.tmp"
out=$(run_ledger_block updated 1 '#77' || true)
rmdir "$ledger_dir/root/.rite/state/adoption-hold-5-triage.json.tmp"
case "$out" in
  *'再開方法: '*'ただし #77 は tracker に書き戻せていない'*) pass 'an unwritable hold still prints the resume with the untracked Issue' ;;
  *) fail "an unwritable hold must print the resume: $out" ;;
esac

# 7.4.2: a failed Issue creation is counted for 7.4.5, and a created Issue is written back as the record's tracker.
awk '/^#### 7\.4\.2 / { s=1 } s && /^```bash$/ { a=1; next } a && /^```$/ { exit } a { print }' "$review" > "$ledger_dir/create.sh"
assert_grep '7.4.2 block creates the Issue' "$ledger_dir/create.sh" 'create-issue-with-projects.sh'
mkdir -p "$ledger_dir/plugin/scripts"
cat > "$ledger_dir/plugin/scripts/create-issue-with-projects.sh" <<'STUB'
#!/bin/bash
cat > /dev/null
if [ "$CREATE_FAIL" = 1 ]; then
  echo '{"issue_url":"","issue_number":0,"project_registration":"failed","warnings":["gh issue create failed: HTTP 502"]}'
  exit 1
fi
echo '{"issue_url":"https://example.test/issues/77","issue_number":77,"project_registration":"ok","warnings":[]}'
STUB
run_create_block() {
  local code
  code=$(cat "$ledger_dir/create.sh")
  code=${code//\{plugin_root\}/$ledger_dir/plugin}
  code=${code//\{pr_number\}/5}
  code=${code//\{record_ids\}/${2:-[\"C-1\"]}}
  code=${code//\{projects_enabled\}/false}
  code=${code//\{project_number\}/1}
  for ph in acceptance complexity contract description evidence file iteration_mode line original_comment owner \
            priority reviewer_type severity source_label summary type; do
    code=${code//\{$ph\}/x}
  done
  printf '{"adoption":{"head":"c0ffee","records":[{"ids":["C-1"],"tracker":null}]}}\n' > "$ledger_dir/root/.rite/state/adoption-5-triage.json"
  [ "${3:-}" != blocked ] || mkdir "$ledger_dir/root/.rite/state/adoption-5-triage.json.tmp"
  LEDGER_ROOT="$ledger_dir/root" CREATE_FAIL="$1" bash -c "$code" 2>&1
}
out=$(run_create_block 1 || true)
assert_eq 'a failed Issue creation is counted for 7.4.5' '[CONTEXT] ISSUE_CREATE_FAILED=1; reason=create_failed' \
  "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ISSUE_CREATE_FAILED=' || true)"
out=$(run_create_block 0)
assert_eq 'a created Issue is written back as the record tracker' '77' \
  "$(jq -r '.adoption.records[0].tracker' "$ledger_dir/root/.rite/state/adoption-5-triage.json")"
out=$(run_create_block 0 '["C-9"]' || true)
assert_eq 'a write-back that matches no record fails with the created number' \
  '[CONTEXT] ISSUE_CREATE_FAILED=1; reason=tracker_write_failed; issue=77' \
  "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ISSUE_CREATE_FAILED=' || true)"
out=$(run_create_block 0 '["C-1"]' blocked || true)
rmdir "$ledger_dir/root/.rite/state/adoption-5-triage.json.tmp"
assert_eq 'a write-back that cannot be saved fails with the created number' \
  '[CONTEXT] ISSUE_CREATE_FAILED=1; reason=tracker_write_failed; issue=77' \
  "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ISSUE_CREATE_FAILED=' || true)"
if grep -qF '手動追記してください' "$review"; then
  fail '7.4.3 must not ask for a manual append the rerun would repeat'
else
  pass '7.4.3 asks for no manual append'
fi

# Step 2 reads the ledger the classifier copies priors from. No record comment yet is not a failure.
awk '/^### 7\.2-7\.3 / { s=1 } s && /^```bash$/ { a=1; blk=""; next }
  a && /^```$/ { a=0; if (index(blk, "TRIAGE_LEDGER=absent")) { printf "%s", blk; exit } next }
  a { blk = blk $0 "\n" }' "$review" > "$ledger_dir/step2.sh"
assert_grep 'step 2 block reads the ledger' "$ledger_dir/step2.sh" 'nb-sweep-ledger.sh extract'
run_step2() {
  local code
  code=$(cat "$ledger_dir/step2.sh")
  code=${code//\{plugin_root\}/$ledger_dir/plugin}
  code=${code//\{pr_number\}/5}
  code=${code//\{owner_repo\}/o/r}
  bash -c "$code" 2>&1
}
out=$(LEDGER_BODY= run_step2)
assert_eq 'step 2 treats a missing record comment as no ledger' '[CONTEXT] TRIAGE_LEDGER=absent; reason=no_record_comment' \
  "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] TRIAGE_LEDGER=' || true)"
# Round trip: the body 7.4.5 recorded is what the next cycle's step 2 reads the REJECT from.
run_ledger_block updated > /dev/null
out=$(LEDGER_BODY="$ledger_dir/posted.md" run_step2)
assert_eq 'step 2 reads the REJECT row 7.4.5 recorded' \
  '| code-quality-reviewer | tool.sh:3 | REJECT | the usage text is intentional | 5-20260101000000.json |' \
  "$(printf '%s\n' "$out" | grep -F '| code-quality-reviewer |' || true)"
out=$(LEDGER_BODY_FAIL=comments_unreadable run_step2 || true)
assert_eq 'step 2 stops on an unreadable ledger' '[review:error]' "$(printf '%s\n' "$out" | grep -x '\[review:error\]' || true)"
out=$(LEDGER_BODY_FAIL=related_issue_unresolved run_step2)
assert_eq 'step 2 goes on without a related Issue' '[CONTEXT] TRIAGE_LEDGER=absent; reason=related_issue_unresolved' \
  "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] TRIAGE_LEDGER=' || true)"

if [ "$failures" -ne 0 ]; then
  printf '%s contract assertion(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All review/fix promotion contract assertions passed.\n'
