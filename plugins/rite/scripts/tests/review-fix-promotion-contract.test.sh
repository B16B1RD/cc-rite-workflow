#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
audit="$ROOT/plugins/rite/skills/pr-review/references/promotion-audit-review-fix-loop.md"
review="$ROOT/plugins/rite/skills/pr-review/SKILL.md"
fix="$ROOT/plugins/rite/skills/fix/SKILL.md"
iterate="$ROOT/plugins/rite/skills/iterate/SKILL.md"
post_breaker_prepare="$ROOT/plugins/rite/hooks/scripts/post-breaker-full-review-prepare.sh"
post_breaker_route="$ROOT/plugins/rite/hooks/scripts/post-breaker-review-route.sh"
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
assert_grep 'differential scope mechanized' "$audit" '| `differential-scope-review-blind-outside-diff` | mechanized here | `iterate/SKILL.md` post-breaker full review transition and normal review routing |'
assert_grep 'post-breaker full review transition exists' "$iterate" '### ステップ 6.0: post-breaker full review'
assert_grep 'post-breaker run boundary is pinned' "$iterate" 'review-run-since-{pr_number}.txt'
assert_grep 'post-breaker full pass is single-shot' "$iterate" '同一発火に対し full review を 2 回以上 invoke する'
assert_grep 'post-breaker preparation runs in shared block' "$iterate" 'post-breaker-full-review-prepare.sh'
assert_grep 'post-breaker mergeable uses normal completion' "$iterate" 'ステップ 5.S（NB digest sweep。完了通知の前）'
assert_grep 'post-breaker findings use normal fix routing' "$iterate" 'ステップ 3 の `/rite:fix` へ'
assert_grep 'post-breaker failure preserves batch sentinel' "$iterate" '<!-- [iterate:max-cycles-reached] -->'
assert_grep 'post-breaker failure preserves interactive sentinel' "$iterate" '<!-- [iterate:max-cycles-stopped] -->'

state_dir=$(mktemp -d "${TMPDIR:-/tmp}/rite-post-breaker-test-XXXXXX")
trap 'rm -rf "$state_dir"' EXIT
mkdir -p "$state_dir/.rite/review-results"
touch "$state_dir/.rite/review-results/2195-20260809-100000.json"
touch "$state_dir/.rite/review-results/2195-20260809-110000.json"
if bash "$post_breaker_prepare" --pr 2195 --state-root "$state_dir"; then
  actual_pin=$(cat "$state_dir/.rite/state/review-run-since-2195.txt")
  assert_eq 'post-breaker producer pins latest review' '2195-20260809-110000.json' "$actual_pin"
else
  fail 'post-breaker producer succeeds with review results'
fi
printf '%s\n' stale.json > "$state_dir/.rite/state/review-run-since-9999.txt"
if bash "$post_breaker_prepare" --pr 9999 --state-root "$state_dir"; then
  if [ ! -e "$state_dir/.rite/state/review-run-since-9999.txt" ]; then
    pass 'post-breaker producer clears stale pin without review results'
  else
    fail 'post-breaker producer clears stale pin without review results'
  fi
else
  fail 'post-breaker producer accepts no-results full-review path'
fi
assert_eq 'mergeable routes to completion' complete "$(bash "$post_breaker_route" '[review:mergeable]' batch)"
assert_eq 'findings route to fix' fix "$(bash "$post_breaker_route" '[review:fix-needed:2]' batch)"
assert_eq 'malformed findings sentinel fails closed' stop-batch "$(bash "$post_breaker_route" '[review:fix-needed:2oops]' batch)"
assert_eq 'zero findings sentinel fails closed' stop-batch "$(bash "$post_breaker_route" '[review:fix-needed:0]' batch)"
assert_eq 'review error preserves batch stop' stop-batch "$(bash "$post_breaker_route" '[review:error]' batch)"
assert_eq 'missing sentinel preserves interactive stop' stop-interactive "$(bash "$post_breaker_route" '' interactive)"
invoke_count=$(awk '/### ステップ 6.0:/{inside=1} /### ステップ 6.1:/{inside=0} inside' "$iterate" | grep -Fc '`/rite:pr-review {pr_number}` を 1 回 invoke' || true)
assert_eq 'post-breaker review invocation is specified exactly once' 1 "$invoke_count"
assert_grep 'scope split mechanized' "$audit" '| `reviewer-scope-split-escalates-to-user` | mechanized here | Scope Split Gate below and `pr-review/SKILL.md` |'
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
