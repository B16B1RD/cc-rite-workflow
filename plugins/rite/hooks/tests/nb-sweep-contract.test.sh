#!/bin/bash
# Contract tests for post-mergeable NB digest sweep helpers.
#
# T-01 collect NB targets (AC-1)
# T-02 ledger append with rationale (AC-2)
# T-03 merge-into preserves ledger across 6.1.d rewrite (AC-3)
# T-04 empty collect is no-op status (AC-4)
# T-05 nit-noted in findings[] is a target; new class-B is not a second sweep (AC-5)
# T-06 ledger write / merge fail-loud (AC-6)
# T-07 class A findings[] stay out of sweep targets (AC-7)
# T-08 body_count extraction expression matches between fix/references/nb-sweep.md and the record helper (AC-1..AC-3)
# T-09 a ledger-only body (0 findings, no existing comment) creates the record comment, including CRLF and degraded lookup
# T-10 nb-sweep.md record step succeeds only on created / updated and never reaches the done write otherwise
# T-11 a body without ledger entries keeps the no-op skip; count mismatch and uncountable ledger fail instead (the awk diagnostic surfaces with the awk: prefix above the awk-specific guidance, the pending marker is removed; an unknown _gh_err_detail label warns and falls back to the gh: prefix)
# T-12 an existing record comment is updated in place even when the body carries a ledger
# T-13 the record helper and nb-sweep-ledger.sh read the same ledger range (row counts agree on LF / CRLF / trailing-section bodies; extract and merge-into ignore a trailing CR, skip rows outside the section, splice before the count line; predicates pinned statically)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
COLLECT="$PLUGIN_ROOT/hooks/scripts/nb-sweep-collect.sh"
LEDGER="$PLUGIN_ROOT/hooks/scripts/nb-sweep-ledger.sh"

echo "=== nb-sweep-collect.sh / nb-sweep-ledger.sh ==="

assert_file_exists_or_fail "collect helper exists" "$COLLECT" || true
assert_file_exists_or_fail "ledger helper exists" "$LEDGER" || true

sandbox=$(make_plain_sandbox)
trap 'rm -rf -- "$sandbox"' EXIT HUP INT TERM

MARKER='## 📜 rite 非実測指摘の記録 (non-blocking)'
SENTINEL='<!-- rite:nbr:v1 -->'

write_json() {
  local path=$1
  cat > "$path"
}

variant_a_body() {
  cat <<EOF
${MARKER}

以下の指摘は non-blocking に分類されました。

| レビュアー | 重要度 | ファイル:行 | 降格理由 |
|-----------|--------|------------|---------|
| code-quality | HIGH | src/a.ts:1 | 実測なし |

📎 non_blocking_count: 1
📎 reviewed_commit: abc123

${SENTINEL}
EOF
}

# --- T-01 (AC-1): NB 2 件を collect ---
nb_json="$sandbox/pr-1.json"
write_json "$nb_json" <<'JSON'
{
  "schema_version": "1.1.0",
  "pr_number": 1,
  "overall_assessment": "mergeable",
  "findings": [],
  "non_blocking_findings": [
    {"id":"F-01","severity":"HIGH","file":"src/a.ts","line":10,"scope":"current-pr","description":"nb high"},
    {"id":"F-02","severity":"MEDIUM","file":"src/b.ts","line":20,"scope":"follow-up","description":"nb medium"}
  ],
  "guardrail_audit_log": []
}
JSON
t01_out=$("$COLLECT" --json "$nb_json" 2>"$sandbox/t01.err") || t01_rc=$?
t01_rc=${t01_rc:-0}
assert "T-01 collect rc=0" "0" "$t01_rc"
assert "T-01 status=ok" "ok" "$(printf '%s' "$t01_out" | jq -r '.status')"
assert "T-01 count=2" "2" "$(printf '%s' "$t01_out" | jq -r '.count')"
assert_grep "T-01 CONTEXT ok" "$sandbox/t01.err" 'NB_SWEEP_COLLECT=ok; count=2'

# --- T-02 (AC-2): 却下判定文を台帳へ ---
ledger="$sandbox/ledger.md"
entries="$sandbox/entries.md"
printf '| F-01 | src/a.ts:10 | rejected | 本 PR のスコープ外（判定文） |\n' > "$entries"
"$LEDGER" append --ledger-file "$ledger" --entries-file "$entries" 2>"$sandbox/t02.err"
assert_grep "T-02 heading" "$ledger" '^### 却下台帳$'
assert_grep "T-02 rationale row" "$ledger" '本 PR のスコープ外（判定文）'
assert_grep "T-02 CONTEXT ok" "$sandbox/t02.err" 'NB_SWEEP_LEDGER=ok; op=append'

# --- T-03 (AC-3): 6.1.d rewrite 相当の merge-into が台帳を残す ---
body="$sandbox/body.md"
variant_a_body > "$body"
"$LEDGER" merge-into --body-file "$body" --ledger-file "$ledger" 2>"$sandbox/t03.err"
assert_grep "T-03 ledger after merge" "$body" '本 PR のスコープ外（判定文）'
assert_grep "T-03 count line kept" "$body" '^📎 non_blocking_count: 1$'
assert_grep "T-03 sentinel last nonempty" "$body" "^${SENTINEL}$"
# rewrite: new variant A without ledger, then merge-into again
variant_a_body > "$body"
"$LEDGER" merge-into --body-file "$body" --ledger-file "$ledger" 2>"$sandbox/t03b.err"
assert_grep "T-03 rewrite preserves ledger" "$body" '### 却下台帳'
first=$(head -n 1 "$body")
assert "T-03 first line still marker" "$MARKER" "$first"

# --- T-04 (AC-4): NB 0 件は empty ---
empty_json="$sandbox/pr-empty.json"
write_json "$empty_json" <<'JSON'
{
  "schema_version": "1.1.0",
  "pr_number": 2,
  "overall_assessment": "mergeable",
  "findings": [{"id":"F-10","severity":"HIGH","file":"src/c.ts","line":3,"scope":"current-pr","description":"blocking class A"}],
  "non_blocking_findings": [],
  "guardrail_audit_log": []
}
JSON
t04_out=$("$COLLECT" --json "$empty_json" 2>"$sandbox/t04.err") || t04_rc=$?
t04_rc=${t04_rc:-0}
assert "T-04 collect rc=0" "0" "$t04_rc"
assert "T-04 status=empty" "empty" "$(printf '%s' "$t04_out" | jq -r '.status')"
assert "T-04 count=0" "0" "$(printf '%s' "$t04_out" | jq -r '.count')"
assert_grep "T-04 CONTEXT empty" "$sandbox/t04.err" 'NB_SWEEP_COLLECT=empty; count=0'

# --- T-05 (AC-5): nit-noted は対象。class A は対象外。guardrail は already_rejected ---
mix_json="$sandbox/pr-mix.json"
write_json "$mix_json" <<'JSON'
{
  "schema_version": "1.1.0",
  "pr_number": 3,
  "overall_assessment": "mergeable",
  "findings": [
    {"id":"F-20","severity":"HIGH","file":"src/d.ts","line":4,"scope":"current-pr","description":"class A stays blocking"},
    {"id":"F-21","severity":"LOW","file":"src/e.ts","line":5,"scope":"nit-noted","description":"nit remainder"}
  ],
  "non_blocking_findings": [
    {"id":"F-22","severity":"MEDIUM","file":"src/f.ts","line":6,"scope":"current-pr","description":"nb"}
  ],
  "guardrail_audit_log": [
    {"reviewer":"code-quality-reviewer","filter_category":"Category #2","original_severity":"MEDIUM","file_line":"src/g.ts:7","description":"filtered","filter_reason":"hypothetical","verification":"なし"}
  ]
}
JSON
t05_out=$("$COLLECT" --json "$mix_json" 2>"$sandbox/t05.err")
ids=$(printf '%s' "$t05_out" | jq -r '[.targets[].id] | sort | join(",")')
assert "T-05 targets F-21,F-22 only" "F-21,F-22" "$ids"
assert "T-05 class A excluded" "0" "$(printf '%s' "$t05_out" | jq '[.targets[] | select(.id=="F-20")] | length')"
assert "T-05 already_rejected=1" "1" "$(printf '%s' "$t05_out" | jq '.already_rejected | length')"
assert "T-03 already_rejected reviewer" "code-quality-reviewer" "$(printf '%s' "$t05_out" | jq -r '.already_rejected[0].reviewer')"
assert "T-03 already_rejected file_line" "src/g.ts:7" "$(printf '%s' "$t05_out" | jq -r '.already_rejected[0].file_line')"
assert "T-03 already_rejected original_severity" "MEDIUM" "$(printf '%s' "$t05_out" | jq -r '.already_rejected[0].original_severity')"
assert "T-03 already_rejected description" "filtered" "$(printf '%s' "$t05_out" | jq -r '.already_rejected[0].description')"
assert "T-03 already_rejected filter_reason" "hypothetical" "$(printf '%s' "$t05_out" | jq -r '.already_rejected[0].filter_reason')"
assert_not_grep "collect has no filtered_suggestion fallback" "$COLLECT" 'filtered_suggestion'
assert_not_grep "collect has no failed_condition fallback" "$COLLECT" 'failed_condition'

# --- T-06 (AC-6): fail-loud ---
"$COLLECT" --json "$sandbox/missing.json" 2>"$sandbox/t06c.err"
t06c_rc=$?
assert "T-06 collect missing json rc=1" "1" "$t06c_rc"
assert_grep "T-06 collect failed marker" "$sandbox/t06c.err" 'NB_SWEEP_COLLECT=failed'

"$LEDGER" merge-into --body-file "$sandbox/no-such-body.md" --ledger-file "$ledger" 2>"$sandbox/t06m.err"
t06m_rc=$?
assert "T-06 merge missing body rc=1" "1" "$t06m_rc"
assert_grep "T-06 merge failed marker" "$sandbox/t06m.err" 'NB_SWEEP_LEDGER=failed; op=merge-into'

no_count="$sandbox/no-count.md"
printf '%s\n\nno count line\n%s\n' "$MARKER" "$SENTINEL" > "$no_count"
"$LEDGER" merge-into --body-file "$no_count" --ledger-file "$ledger" 2>"$sandbox/t06n.err"
t06n_rc=$?
assert "T-06 merge missing count rc=1" "1" "$t06n_rc"
assert_grep "T-06 count_line_missing" "$sandbox/t06n.err" 'reason=count_line_missing'

"$LEDGER" append --ledger-file "$sandbox/x.md" --entries-file "$sandbox/no-entries.md" 2>"$sandbox/t06a.err"
t06a_rc=$?
assert "T-06 append empty entries rc=1" "1" "$t06a_rc"

# --- T-07 (AC-7): class A ≥1 の JSON は sweep 対象に入らない（ループ非回帰の機械面） ---
assert "T-07 F-10 not a target" "0" "$(printf '%s' "$t04_out" | jq '[.targets[] | select(.id=="F-10")] | length')"
"$COLLECT" --json "$empty_json" >/dev/null 2>"$sandbox/t07.err"
assert_not_grep "T-07 no failed on class A JSON" "$sandbox/t07.err" 'NB_SWEEP_COLLECT=failed'

# unknown option
"$COLLECT" --bogus 1 2>"$sandbox/topt.err"
topt_rc=$?
assert "unknown option rc=2" "2" "$topt_rc"

# All live collect calls use a local gh stub; JSON-only calls remain offline.
mkdir -p "$sandbox/bin"
export NB_TEST_COMMENTS="$sandbox/comments.json"
export NB_TEST_GH_LOG="$sandbox/gh.log"
printf '[]\n' > "$NB_TEST_COMMENTS"
cat > "$sandbox/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NB_TEST_GH_LOG"
case "$*" in
  'repo view '*) printf 'test/repo\n' ;;
  'pr view '*--json\ body*)
    [ "${NB_TEST_BRANCH_ONLY:-0}" = 1 ] || printf 'Closes #42\n' ;;
  'pr view '*--json\ headRefName*) printf 'feat/issue-42-test\n' ;;
  'api --paginate --slurp repos/test/repo/issues/42/comments')
    [ "${NB_TEST_FAIL:-0}" = 0 ] || exit 1
    cat "$NB_TEST_COMMENTS" ;;
  *) exit 97 ;;
esac
SH
chmod +x "$sandbox/bin/gh"
export PATH="$sandbox/bin:$PATH"

# --- --pr は最新 JSON を採る（AC-1 MUST: 最新 review JSON） ---
pr_dir="$sandbox/state/.rite/review-results"
mkdir -p "$pr_dir"
cp "$nb_json" "$pr_dir/1-20260101T000000.json"
cat > "$pr_dir/1-20260102T000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":1,"overall_assessment":"mergeable","findings":[],"non_blocking_findings":[{"id":"F-NEW","severity":"HIGH","file":"src/n.ts","line":1,"scope":"current-pr","description":"newer"}],"guardrail_audit_log":[]}
JSON
pr_out=$("$COLLECT" --pr 1 --state-root "$sandbox/state" 2>"$sandbox/tpr.err") || pr_rc=$?
pr_rc=${pr_rc:-0}
assert "T-01 --pr rc=0" "0" "$pr_rc"
assert "T-01 --pr picks F-NEW" "F-NEW" "$(printf '%s' "$pr_out" | jq -r '.targets[0].id')"

# --- Routing preserves evidence and only issues boolean measured MEDIUM ---
route_json="$sandbox/routes.json"
jq -n '{non_blocking_findings: [
  {id:"M-true",severity:"MEDIUM",verification:{measured:true,detail:"observed"}},
  {id:"M-false",severity:"MEDIUM",verification:{measured:false}},
  {id:"M-missing",severity:"MEDIUM"},
  {id:"M-string",severity:"MEDIUM",verification:{measured:"true"}},
  {id:"M-number",severity:"MEDIUM",verification:{measured:1}},
  {id:"M-scalar",severity:"MEDIUM",verification:"none"},
  {id:"L-true",severity:"LOW",verification:{measured:true}},
  {id:"H-true",severity:"HIGH",verification:{measured:true}},
  {id:"N-true",severity:"MEDIUM",scope:"nit-noted",verification:{measured:true}}
], findings:[{id:"nit",severity:"MEDIUM",scope:"nit-noted",verification:{measured:true}}]}' > "$route_json"
route_out=$("$COLLECT" --json "$route_json")
assert "only measured boolean MEDIUM issued" "M-true" "$(printf '%s' "$route_out" | jq -r '[.targets[] | select(.route=="issued") | .id] | join(",")')"
assert "remaining routes recorded" "9" "$(printf '%s' "$route_out" | jq '[.targets[] | select(.route=="recorded")] | length')"
assert "verification evidence preserved" "observed" "$(printf '%s' "$route_out" | jq -r '.targets[] | select(.id=="M-true") | .verification.detail')"

# Guardrail-only must not be mistaken for a completed/no-op sweep.
guard_json="$sandbox/guard.json"
jq '{guardrail_audit_log}' "$mix_json" > "$guard_json"
guard_out=$("$COLLECT" --json "$guard_json")
assert "guardrail-only status ok" "ok" "$(printf '%s' "$guard_out" | jq -r '.status')"
assert "guardrail-only count 1" "1" "$(printf '%s' "$guard_out" | jq -r '.count')"
assert "guardrail route recorded" "recorded" "$(printf '%s' "$guard_out" | jq -r '.already_rejected[0].route')"
assert "guardrail measured false" "false" "$(printf '%s' "$guard_out" | jq -r '.already_rejected[0].verification.measured')"
assert "guardrail severity original" "MEDIUM" "$(printf '%s' "$guard_out" | jq -r '.already_rejected[0].severity')"

# Read legacy and new dispositions only inside the persisted ledger section.
ledger_body="$sandbox/live-ledger.md"
cat > "$ledger_body" <<EOF
${MARKER}

| collision | src/keep.ts:9 | recorded | outside ledger; must not exclude |
### 却下台帳

| finding_id | file:line | 判定 | 判定文 |
| old | src/old.ts:1 | rejected | legacy |
| rec | src/rec.ts:2 | recorded | measured=false |
| iss | src/iss.ts:3 | issued | follow-up #99 |
| code-quality-reviewer | src/g.ts:7 | recorded | guardrail |
📎 non_blocking_count: 4
${SENTINEL}
EOF
jq -n --rawfile body "$ledger_body" '[[{body:$body}]]' > "$NB_TEST_COMMENTS"
live_json="$sandbox/live.json"
jq -n --slurpfile guard "$guard_json" '{non_blocking_findings:[
{id:"old",file:"src/old.ts",line:1}, {id:"rec",file:"src/rec.ts",line:2},
{id:"iss",file:"src/iss.ts",line:3}, {id:"old",file:"src/different.ts",line:1},
{id:"collision",file:"src/keep.ts",line:9}
],guardrail_audit_log:$guard[0].guardrail_audit_log}' > "$live_json"
live_out=$("$COLLECT" --json "$live_json" --pr 1)
assert "all three ledger dispositions excluded, id collision retained" "2" "$(printf '%s' "$live_out" | jq '.count')"
assert "guardrail ledger excluded" "0" "$(printf '%s' "$live_out" | jq '.already_rejected | length')"
assert "same id different location retained" "src/different.ts" "$(printf '%s' "$live_out" | jq -r '.targets[] | select(.id=="old") | .file')"

# CRLF body: the ledger section must be read exactly as the LF body (same targets, same section boundary).
crlf_ledger_body="$sandbox/live-ledger-crlf.md"
sed 's/$/\r/' "$ledger_body" > "$crlf_ledger_body"
assert "CRLF fixture contains CR" "yes" "$(grep -q $'\r' "$crlf_ledger_body" && echo yes || echo no)"
jq -n --rawfile body "$crlf_ledger_body" '[[{body:$body}]]' > "$NB_TEST_COMMENTS"
crlf_out=$("$COLLECT" --json "$live_json" --pr 1)
assert "CRLF ledger excludes the same three dispositions" "2" "$(printf '%s' "$crlf_out" | jq '.count')"
assert "CRLF targets equal LF targets" "$(printf '%s' "$live_out" | jq -cS '[.targets[] | {id, file, line}]')" "$(printf '%s' "$crlf_out" | jq -cS '[.targets[] | {id, file, line}]')"
assert "CRLF keeps the collision row outside the ledger" "1" "$(printf '%s' "$crlf_out" | jq '[.targets[] | select(.id=="collision")] | length')"
jq -n --rawfile body "$ledger_body" '[[{body:$body}]]' > "$NB_TEST_COMMENTS"
NB_TEST_BRANCH_ONLY=1 "$COLLECT" --json "$live_json" --pr 1 > "$sandbox/branch.out"
assert "branch fallback gets same ledger" "$live_out" "$(cat "$sandbox/branch.out")"
assert_grep "ledger loaded from related Issue" "$NB_TEST_GH_LOG" 'repos/test/repo/issues/42/comments'
NB_TEST_FAIL=1 "$COLLECT" --json "$live_json" --pr 1 > /dev/null 2> "$sandbox/read-fail.err"
assert "ledger read failure rc=1" "1" "$?"
assert_grep "ledger read failure is loud" "$sandbox/read-fail.err" 'reason=comments_unreadable'
printf '{}\n' > "$NB_TEST_COMMENTS"
"$COLLECT" --json "$live_json" --pr 1 > /dev/null 2> "$sandbox/invalid-ledger.err"
assert "invalid comment response rc=1" "1" "$?"
assert_grep "invalid ledger response is loud" "$sandbox/invalid-ledger.err" 'reason=ledger_invalid'

# --- rails pin (SKILL.md 機械レール) ---
ITERATE="$PLUGIN_ROOT/skills/iterate/SKILL.md"
FIX="$PLUGIN_ROOT/skills/fix/references/nb-sweep.md"
REVIEW="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
PROMPT="$PLUGIN_ROOT/skills/pr-review/references/reviewer-prompt-generator.md"
assert_grep "T-07 iterate mergeable→5.S" "$ITERATE" '\[review:mergeable\].*5\.S'
assert_grep "T-07 iterate sweep-done no re-review" "$ITERATE" '\[fix:sweep-done\].*ステップ 5'
assert_grep "T-07 iterate nb-sweep-error" "$ITERATE" '\[iterate:nb-sweep-error\]'
assert_grep "T-07 iterate --nb-sweep invoke" "$ITERATE" 'args: "--nb-sweep \{pr_number\}"'
assert_grep "T-07 iterate empty is noop" "$ITERATE" 'marker_emit ITERATE_NB_SWEEP noop'
assert_grep "T-07 iterate no second sweep" "$ITERATE" '同一 PR で 5\.S を 2 回'
assert_grep "T-07 iterate sweep-done ステップ1禁止" "$ITERATE" 'ステップ 1 に戻らない'
assert_grep "T-07 fix --nb-sweep" "$FIX" '\-\-nb-sweep'
assert_grep "T-07 fix sweep-done sentinel" "$FIX" '\[fix:sweep-done\]'
assert_grep "T-07 fix persist uses body count" "$FIX" '\-\-count "\$body_count"'
assert_grep "T-07 fix record reads the terminal outcome" "$FIX" 'record_outcome=.*NONBLOCKING_RECORD_DONE=1; \.\*outcome='
assert_grep "T-07 fix record succeeds only on created / updated" "$FIX" '^[[:space:]]*0:created[|]0:updated\) ;;$'
assert_not_grep "T-07 fix record drops the failed-only check" "$FIX" 'NONBLOCKING_RECORD_FAILED=1[|]outcome=failed'
assert_grep "T-07 fix issued route" "$FIX" 'route=issued'
assert_grep "T-07 fix recorded machine rationale" "$FIX" 'severity=\{sev\}; measured=\{bool\}'
assert_grep "T-07 sweep forbids commits" "$FIX" 'コードを変更せず、commit / push を行わない'
assert_grep "T-07 pr-review rejected_ledger" "$REVIEW" '{rejected_ledger}'
assert_grep "T-07 pr-review merge-into" "$REVIEW" 'nb-sweep-ledger.sh merge-into'
assert_grep "T-07 pr-review extract" "$REVIEW" 'nb-sweep-ledger.sh extract'
assert_grep "T-07 pr-review REJECTED_LEDGER=failed" "$REVIEW" 'REJECTED_LEDGER=failed'
assert_grep "T-07 pr-review WARNING 却下台帳取得失敗" "$REVIEW" 'WARNING: 却下台帳取得失敗'
assert_grep "T-07 pr-review failed-path 注記" "$REVIEW" '台帳取得失敗 — 却下済み指摘の再訴訟の可能性'
assert_grep "T-07 prompt rejected_ledger" "$PROMPT" '{rejected_ledger}'

# Execute the actual skill error guards, with local stubs for mutations.
extract_fix_block() {
  awk -v needle="$1" '
    /^```bash$/ {inside=1; block=""; next}
    /^```$/ {if (inside && index(block, needle)) {printf "%s", block; exit}; inside=0}
    inside {block=block $0 "\n"}
  ' "$FIX"
}
route_guard="$sandbox/route-guard.sh"
issue_guard="$sandbox/issue-guard.sh"
extract_fix_block 'reason=nb_sweep_route_missing' > "$route_guard"
extract_fix_block 'reason=nb_sweep_issue_failed' > "$issue_guard"
assert_grep "route guard extracted" "$route_guard" 'nb_sweep_route_missing'
assert_grep "issue guard extracted" "$issue_guard" 'nb_sweep_issue_failed'
stub_plugin="$sandbox/plugin"
mkdir -p "$stub_plugin/scripts"
cat > "$stub_plugin/scripts/create-issue-with-projects.sh" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$NB_TEST_ISSUE_LOG"
exit 1
SH
export NB_TEST_ISSUE_LOG="$sandbox/issue.log"
sed "s|{plugin_root}|$stub_plugin|g" "$issue_guard" > "$sandbox/issue-guard-resolved.sh"
mv "$sandbox/issue-guard-resolved.sh" "$issue_guard"
# A tail mutation represents subsequent persist: exits must prevent reaching it.
export NB_TEST_LEDGER="$ledger"
ledger_before=$(cksum "$ledger")
head_before=$(git -C "$PLUGIN_ROOT" rev-parse HEAD)
printf '\nprintf "unexpected persist\\n" >> "$NB_TEST_LEDGER"\n' >> "$route_guard"
printf '\nprintf "unexpected persist\\n" >> "$NB_TEST_LEDGER"\n' >> "$issue_guard"
for route_case in missing unknown; do
  if [ "$route_case" = missing ]; then
    collect_out='{"targets":[{"id":"x"}]}'
  else
    collect_out='{"targets":[{"id":"x","route":"fix"}]}'
  fi
  export collect_out
  bash "$route_guard" > "$sandbox/route-$route_case.out" 2>&1
  assert "route $route_case fails" "1" "$?"
  assert_grep "route $route_case fix:error" "$sandbox/route-$route_case.out" '\[fix:error\]'
done
assert "invalid route never calls issue helper" "no" "$([ -e "$NB_TEST_ISSUE_LOG" ] && echo yes || echo no)"
issue_args='{"options":{"source":"pr_review"}}' bash "$issue_guard" > "$sandbox/issue-guard.out" 2>&1
assert "issue helper failure exits" "1" "$?"
assert_grep "issue failure fix:error" "$sandbox/issue-guard.out" '\[fix:error\]'
assert_grep "issue stub was called" "$NB_TEST_ISSUE_LOG" '^called$'
assert "failure paths leave ledger unchanged" "$ledger_before" "$(cksum "$ledger")"
assert "failure paths leave HEAD unchanged" "$head_before" "$(git -C "$PLUGIN_ROOT" rev-parse HEAD)"

# --- T-08 (AC-1..AC-3): body_count の抽出式が producer (nb-sweep.md) と validator (helper) で一致する ---
# nb-sweep.md 1.3.S の手順 3（台帳 persist）は抽出した値を helper へ `--count` として渡し、helper は
# 同じ行を自前の式で再検査する。片側だけを書き換えると producer が通した body を validator が
# count_body_mismatch で落とす。この不一致は実行時にしか現れないため、両者の式を突き合わせて
# 固定する。期待値はテスト内にハードコードせず helper 側から抽出する。
NBR_SH="$PLUGIN_ROOT/hooks/review-nonblocking-record.sh"
assert_file_exists_or_fail "T-08 nonblocking record helper exists" "$NBR_SH" || true

# 右辺の被演算子はファイル変数名だけが異なる (helper=$CONTENT_FILE / nb-sweep.md=$body)。
# 共通プレースホルダへ正規化してから突合する (TC-5b の __CYCLE__ 正規化と同型)。
# 被演算子の手前で needle を切り詰めると `| tail -1 | grep -oE '[0-9]+'` が pin から外れ、
# パイプライン後段の drift を取り逃す空振り経路が残るため、右辺は全体を対象にする。
_t08_helper_lines=$(grep -cE '^body_count=' "$NBR_SH" || true)
_t08_skill_lines=$(grep -cE '^[[:space:]]*body_count=' "$FIX" || true)
assert "T-08 helper の body_count= 代入は 1 行 (head -1 による黙殺を防ぐ)" "1" "$_t08_helper_lines"
assert "T-08 nb-sweep.md の body_count= 代入は 1 行" "1" "$_t08_skill_lines"

# 上の 2 assert が代入 1 行を保証するため、以下の head -1 は値の選択ではなく、行数が崩れた
# 実行でも診断値を 1 つに定めるための保険。fail() は加算のみで停止しないので後続まで進む。
_t08_helper_rhs=$(sed -n 's/^body_count=\(.*\)$/\1/p' "$NBR_SH" | head -1 \
  | sed 's/"\$CONTENT_FILE"/__BODY_FILE__/')
_t08_skill_rhs=$(sed -n 's/^[[:space:]]*body_count=\(.*\)$/\1/p' "$FIX" | head -1 \
  | sed 's/"\$body"/__BODY_FILE__/')

if [ -z "$_t08_helper_rhs" ] || [ -z "$_t08_skill_rhs" ]; then
  # 抽出失敗 (代入形の drift) は silent pass させない。空同士の等値で緑になる経路を塞ぐ。
  fail "T-08 body_count= の右辺を抽出できない (代入形の drift。helper='$_t08_helper_rhs' skill='$_t08_skill_rhs')"
else
  # 本 assert は symmetry pin であって value pin ではない。両側を同時に同じ形へ書き換えた
  # drift は等値が保たれるため検出できない (それを検出するには期待式をテスト内へ
  # ハードコードする必要があり、helper 側から抽出する方針と衝突する)。
  assert "T-08 body_count 抽出式が producer (nb-sweep.md) と validator (helper) で一致" \
    "$_t08_helper_rhs" "$_t08_skill_rhs"
fi

# 上の正規化は 2 つの被演算子が同じファイルを指すことを前提に両者を同一視する。その前提自体は
# 抽出式の比較では確かめられないため、producer が数えた本文をそのまま helper へ渡していることを
# 別途固定する。ここが外れると producer は $body から数え helper は別ファイルを検査するため、
# 式が完全に一致していても production では count_body_mismatch が出る。
assert_grep "T-08 fix が数えた本文をそのまま helper へ渡す" "$FIX" '\-\-content-file "\$body"'

# measured MEDIUM is moved by the real triage helper and consumed by the existing sweep.
FIX_SKILL="$PLUGIN_ROOT/skills/fix/SKILL.md"
medium_json="$sandbox/non-fatal-only.json"
write_json "$medium_json" <<'JSON'
{"pr_number":1,"findings":[
  {"id":"M-1","severity":"MEDIUM","scope":"current-pr","file":"src/a.ts","line":10,"verification":{"measured":true}},
  {"id":"M-2","severity":"MEDIUM","scope":"follow-up","file":"src/b.ts","line":20,"verification":{"measured":true}}
],"non_blocking_findings":[]}
JSON
bash "$PLUGIN_ROOT/scripts/review-findings-maps.sh" --review-source explicit_file \
  --review-source-path "$medium_json" > "$sandbox/medium.maps" 2> "$sandbox/medium.triage"
assert "non-fatal triage succeeds" 0 "$?"
assert_grep "measured MEDIUM → fatal=0 moved=2" "$sandbox/medium.triage" 'FIX_FATAL_TRIAGE=applied; fatal=0; moved=2'
assert "triage removes blocking input" 0 "$(jq '.findings | length' "$medium_json")"
assert "triage preserves measured evidence" true "$(jq 'all(.non_blocking_findings[]; .verification.measured == true and .demotion_reason == "non_fatal")' "$medium_json")"
medium_collect=$("$COLLECT" --json "$medium_json")
assert "sweep sees both moved findings" 2 "$(jq '.count' <<< "$medium_collect")"
assert "measured MEDIUM keeps existing issued route" true "$(jq 'all(.targets[]; .route == "issued")' <<< "$medium_collect")"
medium_entries="$sandbox/medium-entries.md"
jq -r '.targets[] | "| \(.id) | \(.file):\(.line) | issued | fixture issue for \(.id) |"' \
  <<< "$medium_collect" > "$medium_entries"
"$LEDGER" append --ledger-file "$sandbox/medium-ledger.md" --entries-file "$medium_entries"
assert "sweep persists two digest rows" 2 "$(grep -c '^| M-' "$sandbox/medium-ledger.md")"

# Triage counts describe the input classification, including fatal findings answered without a push.
mixed_json="$sandbox/mixed-replies.json"
jq '.findings += [{id:"F-03",severity:"HIGH",scope:"current-pr",file:"src/c.ts",line:30,verification:{measured:true}}]' \
  <(jq '.findings = .non_blocking_findings | .non_blocking_findings = []' "$medium_json") > "$mixed_json"
bash "$PLUGIN_ROOT/scripts/review-findings-maps.sh" --review-source explicit_file \
  --review-source-path "$mixed_json" > "$sandbox/mixed.maps" 2> "$sandbox/mixed.triage"
assert "mixed triage succeeds" 0 "$?"
assert_grep "mixed triage retains fatal=1 moved=2" "$sandbox/mixed.triage" 'FIX_FATAL_TRIAGE=applied; fatal=1; moved=2'
assert "fatal finding remains after triage" F-03 "$(jq -r '.findings[0].id' "$mixed_json")"
assert "sweep consumes transfers without consuming fatal replies" 2 "$("$COLLECT" --json "$mixed_json" | jq '.count')"

# Pin the actual prompt routing, including precedence and the outer batch success gate.
assert_grep "fix retains fatal and moved counts" "$FIX_SKILL" '\{fatal_count\}=N.*\{non_fatal_moved_count\}=M'
assert_grep "non-fatal-only requires no push/accept, fatal=0 and moved>0" "$FIX_SKILL" '^\| 4\.5 \| Push なし.*accept 決定なし.*\{fatal_count\}=0.*\{non_fatal_moved_count\}>0.*All findings replied.*\[fix:non-fatal-only\]'
assert_grep "reply-only includes mixed transfers but requires no push/accept and all replies" "$FIX_SKILL" '^\| 5 \| Push なし かつ 本 cycle 内で accept 決定なし \(上記 2 マーカーがいずれも非出現\) かつ All findings replied \| `\[fix:replied-only\]`'
assert_grep "unhandled input still ends in error" "$FIX_SKILL" '^\| 6 \| Unexpected state / error \| `\[fix:error\]`'
assert_grep "fatal error flags remain distinct from triage count" "$FIX_SKILL" '^\| 1 \(最優先\).*FIX_FALLBACK_FAILED=1.*\[fix:error\]'
assert_grep "failed replies retain error precedence" "$FIX_SKILL" '^\| 2 \|.*REPLY_POST_FAILED=1.*\[fix:error\]'
assert "error, WM, push/accept retain precedence" '1 1.5 1.6 2 2.5 3 4 4.5 5 6' \
  "$(awk '/^\| 評価順 \|/{table=1;next} table && /^\| [0-9]/{printf "%s%s", sep, $2; sep=" "} table && !/^\|/{exit}' "$FIX_SKILL")"
assert_grep "non-fatal-only sets FINALIZE" "$FIX_SKILL" '\-\-handoff "FINALIZE:fix:non-fatal-only:\{pr_number\}"'
assert_grep "iterate routes non-fatal-only to 5.S, not full review" "$ITERATE" '^\| `\[fix:non-fatal-only\]` \| ステップ 5\.S.*ステップ 1 に戻らない'
assert_grep "batch success only after successful sweep" "$ITERATE" '\[fix:non-fatal-only\].*5\.S が `done` / `noop` / `skipped` で成功した後だけ.*外向きに `\[review:mergeable\]`'
assert_grep "failed sweep cannot report success" "$ITERATE" 'sweep 失敗時は `\[iterate:nb-sweep-error\]` のまま停止し、成功 sentinel を返さない'

# Extract the connected entry and exit tables rather than matching unrelated mentions.
reply_entry=$(sed -n '/^## ステップ 4: fix sentinel を判定/,/^## ステップ 5.S:/p' "$ITERATE")
sweep_exit=$(sed -n '/^### sweep 後の終了理由/,/^### 正常終了/p' "$ITERATE")
assert "reply-only enters sweep before completion" 1 "$(printf '%s\n' "$reply_entry" | grep -c '^| `\[fix:replied-only\]` | ステップ 5\.S.*返信のみで完了通知')"
assert "successful sweep keeps reply-only exit" 1 "$(printf '%s\n' "$sweep_exit" | grep -c '^| `\[fix:replied-only\]` | `\[fix:replied-only\]`.*mergeable へ昇格しない')"
assert "other successful entries remain mergeable" 1 "$(printf '%s\n' "$sweep_exit" | grep -c '^| `\[review:mergeable\]` / `\[fix:non-fatal-only\]` | `\[review:mergeable\]` |')"
assert_grep "reentry and nested sweep cannot overwrite entry reason" "$ITERATE" '5\.S 再入時も保持値を使い、内部の `\[fix:sweep-done\]` や handoff で上書きしない'
assert "unknown entry cannot imply success" 1 "$(printf '%s\n' "$sweep_exit" | grep -c '^| 欠落 / その他 | `\[iterate:nb-sweep-error\]`')"
assert_grep "all successful sweep outcomes use entry routing" "$ITERATE" '5\.S の `done` / `noop` / `skipped`.*消化の成功だけ'
assert_grep "merge-mode batch still stops on reply-only" "$PLUGIN_ROOT/skills/batch-run/SKILL.md" '^\| `\[fix:replied-only\]` \+ `merge` \|.*ステップ 8'

# --- 却下台帳だけを持つ本文の記録（T-09〜T-12） ---
# 記録 helper 専用の gh stub。collect 用 stub（exit 97 で未知の呼び出しを落とす）とは別ディレクトリに置き、
# helper / sweep ブロックの実行中だけ PATH の先頭へ入れる。
nbr_bin="$sandbox/nbr-bin"
mkdir -p "$nbr_bin"
cat > "$nbr_bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NBR_GH_LOG"
case "${1:-} ${2:-}" in
  'api user') printf 'rite-bot\n'; exit 0 ;;
  'pr view')
    case " $* " in *" headRefName "*) printf 'feat/issue-42-test\n' ;; *) printf 'Closes #42\n' ;; esac
    exit 0 ;;
  'issue view'|'issue edit') exit 0 ;;
  'issue comment')
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      [ "${args[$i]}" = --body-file ] && cp "${args[$((i + 1))]}" "$NBR_POSTED"
    done
    printf 'https://github.com/test/repo/issues/42#issuecomment-4242\n'
    exit 0 ;;
  'api --paginate')
    [ "${NBR_LOOKUP_FAIL:-0}" = 0 ] || exit 1
    cat "$NBR_COMMENTS"
    exit 0 ;;
esac
case " $* " in
  *" -X PATCH "*) jq -j '.body' > "$NBR_POSTED"; exit 0 ;;
  # nb-sweep.md 手順 3 の既存記録コメント取得。記録コメントなしを返す
  *" --paginate --jq "*) exit 0 ;;
esac
exit 97
SH
chmod +x "$nbr_bin/gh"
export NBR_GH_LOG="$sandbox/nbr-gh.log"
export NBR_POSTED="$sandbox/nbr-posted.md"
export NBR_COMMENTS="$sandbox/nbr-comments.json"
nbr_err="$sandbox/nbr.err"

run_nbr_helper() {  # $1=count $2=content-file
  : > "$NBR_GH_LOG"
  rm -f "$NBR_POSTED"
  nbr_rc=0
  PATH="${NBR_EXTRA_PATH:+$NBR_EXTRA_PATH:}$nbr_bin:$PATH" bash "$NBR_SH" --pr 7 --owner-repo test/repo \
    --count "$1" --iteration-id nbr-contract --content-file "$2" 2>"$nbr_err" || nbr_rc=$?
  nbr_outcome=$(sed -n 's/^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1; .*outcome=\([^;]*\);.*/\1/p' "$nbr_err" | tail -1)
}

# sweep が組む本文と同じ形（0 件の既定本文に台帳を merge-into）を実際の ledger helper で作る
zero_body() {  # $1=out
  printf '%s\n\n%s\n\n%s\n%s\n\n%s\n' "$MARKER" '本 cycle の非実測指摘: 0 件' \
    '📎 non_blocking_count: 0' '📎 reviewed_commit: unknown' "$SENTINEL" > "$1"
}
nbr_entries="$sandbox/nbr-entries.md"
printf '%s\n' '| NB-1 | src/a.ts:1 | recorded | severity=MEDIUM; measured=false |' \
  '| NB-2 | src/b.ts:2 | recorded | severity=LOW; measured=false |' > "$nbr_entries"
ledger_body="$sandbox/nbr-ledger-body.md"
zero_body "$ledger_body"
"$LEDGER" append --ledger-file "$sandbox/nbr-ledger.md" --entries-file "$nbr_entries" 2>/dev/null
"$LEDGER" merge-into --body-file "$ledger_body" --ledger-file "$sandbox/nbr-ledger.md" 2>/dev/null
assert "fixture: 台帳 2 件を持つ 0 件本文" 2 "$(grep -c '^| NB-' "$ledger_body")"
printf '[[]]\n' > "$NBR_COMMENTS"

# T-09: 既存なし・count 0・台帳 2 件 → 台帳を含む記録コメントを作成する
nbr_tmp="$sandbox/nbr-tmp"
mkdir -p "$nbr_tmp"
TMPDIR="$nbr_tmp" run_nbr_helper 0 "$ledger_body"
assert "T-09 台帳のみの本文は outcome=created" created "$nbr_outcome"
# 台帳集計の stderr 一時ファイルは成功経路で消す。後続の投稿用 gh_err 代入で上書きされると trap が回収できない
assert "T-09 台帳集計の stderr 一時ファイルを残さない" 0 "$(find "$nbr_tmp" -name 'rite-p61d-ledger-err-*' | wc -l | tr -d ' ')"
assert_grep "T-09 issue comment で作成する" "$NBR_GH_LOG" '^issue comment 42 '
if [ -f "$NBR_POSTED" ] && cmp -s "$ledger_body" "$NBR_POSTED"; then
  pass "T-09 投稿本文が content-file と一致"
else
  fail "T-09 投稿本文が content-file と一致しない"
fi
crlf_body="$sandbox/nbr-ledger-body-crlf.md"
sed 's/$/\r/' "$ledger_body" > "$crlf_body"
run_nbr_helper 0 "$crlf_body"
assert "T-09 CRLF 本文でも台帳を数えて outcome=created" created "$nbr_outcome"
NBR_LOOKUP_FAIL=1 run_nbr_helper 0 "$ledger_body"
assert "T-09 lookup 失敗でも台帳ありなら outcome=created" created "$nbr_outcome"
assert_grep "T-09 lookup 失敗は degraded=1" "$nbr_err" 'NONBLOCKING_RECORD_DONE=1; .*degraded=1'
assert_grep "T-09 degraded create の重複警告" "$nbr_err" '既存の記録コメントを特定できないまま新規作成した'

# T-11: 台帳エントリ 0 件の本文は既存どおり投稿しない
plain_body="$sandbox/nbr-plain.md"
zero_body "$plain_body"
run_nbr_helper 0 "$plain_body"
assert "T-11 台帳なし・0 件・既存なしは outcome=skipped" skipped "$nbr_outcome"
assert_not_grep "T-11 台帳なしは投稿しない" "$NBR_GH_LOG" '^issue comment '
header_only="$sandbox/nbr-header-only.md"
printf '%s\n\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n' "$MARKER" '### 却下台帳' \
  '| finding_id | file:line | 判定 | 判定文 |' '|------------|-----------|------|--------|' \
  '📎 non_blocking_count: 0' '📎 reviewed_commit: unknown' "$SENTINEL" > "$header_only"
run_nbr_helper 0 "$header_only"
assert "T-11 見出しと列ヘッダだけの台帳は outcome=skipped" skipped "$nbr_outcome"
assert_not_grep "T-11 見出しだけの台帳は投稿しない" "$NBR_GH_LOG" '^issue comment '
outside_rows="$sandbox/nbr-outside-rows.md"
printf '%s\n\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n%s\n\n%s\n' "$MARKER" '### 却下台帳' \
  '| finding_id | file:line | 判定 | 判定文 |' '|------------|-----------|------|--------|' \
  '### 別の節' '| other | src/x.ts:1 | note | 台帳ではない |' \
  '📎 non_blocking_count: 0' '| tail | src/y.ts:2 | note | count 行より後 |' \
  '📎 reviewed_commit: unknown' "$SENTINEL" > "$outside_rows"
run_nbr_helper 0 "$outside_rows"
assert "T-11 台帳節の外にある表の行は数えない" skipped "$nbr_outcome"
mismatch_body="$sandbox/nbr-mismatch.md"
sed 's/^📎 non_blocking_count: 0$/📎 non_blocking_count: 2/' "$ledger_body" > "$mismatch_body"
run_nbr_helper 0 "$mismatch_body"
assert "T-11 count 不一致は台帳より先に outcome=failed" failed "$nbr_outcome"
assert_grep "T-11 count 不一致の reason" "$nbr_err" 'reason=count_body_mismatch'
assert_not_grep "T-11 count 不一致は投稿しない" "$NBR_GH_LOG" '^issue comment '
awk_fail_bin="$sandbox/awk-fail-bin"
mkdir -p "$awk_fail_bin"
printf '#!/usr/bin/env bash\ncase "$*" in *却下台帳*) echo SIMULATED_AWK_DIAG >&2; exit 2 ;; esac\nexec %q "$@"\n' "$(command -v awk)" > "$awk_fail_bin/awk"
chmod +x "$awk_fail_bin/awk"
awk_fail_marker="${TMPDIR:-/tmp}/rite-nbr-pending-nbr-contract"
: > "$awk_fail_marker"
NBR_EXTRA_PATH="$awk_fail_bin" run_nbr_helper 0 "$ledger_body"
assert "T-11 台帳を数えられないときは skipped にしない" failed "$nbr_outcome"
assert_grep "T-11 台帳を数えられない reason" "$nbr_err" 'reason=body_check_unavailable'
assert_not_grep "T-11 台帳を数えられないときは投稿しない" "$NBR_GH_LOG" '^issue comment '
assert_grep "T-11 awk の stderr 診断を awk: 接頭辞で表示する" "$nbr_err" '^  awk: SIMULATED_AWK_DIAG'
assert_not_grep "T-11 awk の stderr 診断を gh: 接頭辞で表示しない" "$nbr_err" 'gh: SIMULATED_AWK_DIAG'
assert_grep "T-11 awk 用の案内を出す" "$nbr_err" '^  対処: awk の実行環境'
assert_not_grep "T-11 awk の失敗に jq の案内を出さない" "$nbr_err" 'jq --version'
# 案内は「上の awk の診断」を指すため、診断行が案内行より前に出ることを行番号で固定する。
# 案内行は対処行に限って当てる (後続の「awk の実行環境側の問題です」行に乗り換えて pass させない)
awk_diag_line=$(grep -n '^  awk: SIMULATED_AWK_DIAG' "$nbr_err" | head -1 | cut -d: -f1)
awk_hint_line=$(grep -n '^  対処: awk の実行環境' "$nbr_err" | head -1 | cut -d: -f1)
if [ -n "$awk_diag_line" ] && [ -n "$awk_hint_line" ] && [ "$awk_diag_line" -lt "$awk_hint_line" ]; then
  pass "T-11 awk の診断行が awk 用の案内行より前に出る"
else
  fail "T-11 awk の診断行が awk 用の案内行より前にない (diag=${awk_diag_line:-none} hint=${awk_hint_line:-none})"
fi
if [ -e "$awk_fail_marker" ]; then
  rm -f "$awk_fail_marker"
  fail "T-11 台帳を数えられないときに pending marker が残る（環境起因は差し戻さない）"
else
  pass "T-11 台帳を数えられないときは pending marker を消す"
fi
printf '#!/usr/bin/env bash\ncase "$*" in *却下台帳*) echo not-a-number; exit 0 ;; esac\nexec %q "$@"\n' "$(command -v awk)" > "$awk_fail_bin/awk"
NBR_EXTRA_PATH="$awk_fail_bin" run_nbr_helper 0 "$ledger_body"
assert "T-11 数値以外の集計結果は outcome=failed" failed "$nbr_outcome"
assert_grep "T-11 数値以外の集計結果の reason" "$nbr_err" 'reason=body_check_unavailable'
assert_not_grep "T-11 数値以外の集計結果では投稿しない" "$NBR_GH_LOG" '^issue comment '
# 一時ファイルは awk 実行より前に gh_err へ代入し、実行中の signal でも EXIT trap の回収対象にする
# （signal のタイミングを突くテストは racy なため、行の順序で固定する）
ledger_assign_line=$(grep -n 'gh_err="\$_ledger_awk_err"' "$NBR_SH" | head -1 | cut -d: -f1)
ledger_awk_line=$(grep -n 'ledger_entry_count=\$(awk' "$NBR_SH" | head -1 | cut -d: -f1)
if [ -n "$ledger_assign_line" ] && [ -n "$ledger_awk_line" ] && [ "$ledger_assign_line" -lt "$ledger_awk_line" ]; then
  pass "T-11 台帳集計の gh_err 代入が awk 実行より前"
else
  fail "T-11 台帳集計の gh_err 代入が awk 実行より前にない (assign=${ledger_assign_line:-none} awk=${ledger_awk_line:-none})"
fi
# 診断接頭辞の未知ラベルは内部エラーとして知らせ、gh に倒す。今ある呼び出しは gh / jq / awk だけで
# helper 経由では到達できないため、関数定義を helper から抽出して直接呼ぶ。この分岐は sed 置換部へ
# 任意文字列が入らないよう抑える役も兼ねる
gh_err_detail_def=$(sed -n '/^_gh_err_detail() {/,/^}/p' "$NBR_SH")
# 範囲の終端がずれて途中までしか取れない / EOF まで取り込む drift を、空でないことだけで通さない
if [ "$(printf '%s\n' "$gh_err_detail_def" | grep -c '^_gh_err_detail() {')" != 1 ] \
  || [ "$(printf '%s\n' "$gh_err_detail_def" | tail -1)" != '}' ] \
  || ! printf '%s\n' "$gh_err_detail_def" | grep -q 'case "\$_label" in'; then
  fail "T-11 _gh_err_detail の定義を helper から抽出できない (定義形の drift)"
else
  unknown_label_diag="$sandbox/unknown-label-diag.txt"
  unknown_label_err="$sandbox/unknown-label.err"
  printf 'SIMULATED_UNKNOWN_LABEL_DIAG\n' > "$unknown_label_diag"
  (
    # shellcheck source=../control-char-neutralize.sh
    source "$PLUGIN_ROOT/hooks/control-char-neutralize.sh"
    eval "$gh_err_detail_def"
    declare -F _gh_err_detail neutralize_ctrl >/dev/null || { echo "UNKNOWN_LABEL_SETUP_FAILED"; exit 0; }
    gh_err="$unknown_label_diag"
    _gh_err_detail 'bogus/label'
  ) > "$unknown_label_err.out" 2> "$unknown_label_err"
  assert_not_grep "T-11 未知ラベルのテスト用に関数を定義できる" "$unknown_label_err.out" 'UNKNOWN_LABEL_SETUP_FAILED'
  assert_grep "T-11 未知ラベルは内部エラーを出す" "$unknown_label_err" "^WARNING: 内部エラー: _gh_err_detail に未知のラベル 'bogus/label'"
  assert_grep "T-11 未知ラベルの詳細行は gh: 接頭辞に倒す" "$unknown_label_err" '^  gh: SIMULATED_UNKNOWN_LABEL_DIAG$'
  assert_not_grep "T-11 未知ラベルを詳細行の接頭辞に使わない" "$unknown_label_err" 'bogus/label: '
fi

# T-12: 既存の記録コメントがあれば台帳ありでも update-in-place する
jq -n --rawfile body "$plain_body" '[[{id: 555, user: {login: "rite-bot"}, body: $body}]]' > "$NBR_COMMENTS"
run_nbr_helper 0 "$ledger_body"
assert "T-12 既存コメントありは outcome=updated" updated "$nbr_outcome"
assert_grep "T-12 既存コメントを PATCH する" "$NBR_GH_LOG" 'repos/test/repo/issues/comments/555 -X PATCH'
assert_not_grep "T-12 新規作成しない" "$NBR_GH_LOG" '^issue comment '
if [ -f "$NBR_POSTED" ] && cmp -s "$ledger_body" "$NBR_POSTED"; then
  pass "T-12 PATCH 本文が content-file と一致"
else
  fail "T-12 PATCH 本文が content-file と一致しない"
fi

# T-13: 記録 helper と ledger helper が同じ本文で台帳節を同じ範囲と読む
# 記録 helper が台帳ありと数えて投稿した本文を、次の cycle の extract / merge-into が読めないと台帳が失われる。
# 2 実装は分けてあるため、記録 helper の集計 awk を source から抜き出し、同じ fixture で件数を突き合わせる。
t13_prog=$(sed -n "/ledger_entry_count=\$(awk -v head=/,/' \"\$CONTENT_FILE\"/p" "$NBR_SH" | sed '1d;$d')
t13_outside_crlf="$sandbox/t13-outside-crlf.md"
sed 's/$/\r/' "$outside_rows" > "$t13_outside_crlf"
if [ -z "$t13_prog" ]; then
  fail "T-13 記録 helper の台帳集計 awk を抽出できない (代入形の drift)"
else
  for t13_body in "$ledger_body" "$crlf_body" "$outside_rows" "$t13_outside_crlf" "$header_only"; do
    t13_record=$(awk -v head='### 却下台帳' "$t13_prog" "$t13_body")
    t13_extract=$("$LEDGER" extract --body-file "$t13_body" 2>/dev/null | grep -E '^\| ' | grep -v '^| finding_id ' | grep -cvE '^\|[-: |]+\|$')
    assert "T-13 台帳の件数が記録 helper と extract で一致 ($(basename "$t13_body"))" "$t13_record" "$t13_extract"
  done
fi
t13_crlf_out="$sandbox/t13-crlf-extract.md"
"$LEDGER" extract --body-file "$crlf_body" > "$t13_crlf_out" 2>/dev/null
assert "T-13 CRLF 本文の extract は台帳 2 件を返す" 2 "$(grep -c '^| NB-' "$t13_crlf_out")"
assert "T-13 extract の出力に CR を残さない" 0 "$(grep -c $'\r' "$t13_crlf_out")"
"$LEDGER" extract --body-file "$outside_rows" > "$sandbox/t13-outside-extract.md" 2>/dev/null
assert_not_grep "T-13 extract は台帳節の後の別の節の行を出さない" "$sandbox/t13-outside-extract.md" '^\| other '

# merge-into: 既存台帳の後に別の節がある本文で、台帳節だけを置き換えて count 行の直前へ差し込む
t13_new_ledger="$sandbox/t13-new-ledger.md"
printf '%s\n' '| NB-9 | src/z.ts:9 | recorded | severity=LOW; measured=false |' > "$sandbox/t13-entries.md"
"$LEDGER" append --ledger-file "$t13_new_ledger" --entries-file "$sandbox/t13-entries.md" 2>/dev/null
t13_merge="$sandbox/t13-merge.md"
printf '%s\n\n%s\n\n%s\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n%s\n\n%s\n' "$MARKER" '### 却下台帳' \
  '| finding_id | file:line | 判定 | 判定文 |' '|------------|-----------|------|--------|' \
  '| NB-1 | src/a.ts:1 | recorded | severity=LOW; measured=false |' \
  '### 別の節' '| other | src/x.ts:1 | note | 台帳ではない |' \
  '📎 non_blocking_count: 0' '| tail | src/y.ts:2 | note | count 行より後 |' \
  '📎 reviewed_commit: unknown' "$SENTINEL" > "$t13_merge"
"$LEDGER" merge-into --body-file "$t13_merge" --ledger-file "$t13_new_ledger" 2>/dev/null
assert "T-13 merge-into は旧台帳の行を残さない" 0 "$(grep -c '^| NB-1 ' "$t13_merge")"
assert "T-13 merge-into は新台帳の行を 1 件入れる" 1 "$(grep -c '^| NB-9 ' "$t13_merge")"
assert "T-13 merge-into は台帳見出しを 1 つにする" 1 "$(grep -c '^### 却下台帳$' "$t13_merge")"
assert "T-13 merge-into は別の節を残す" 1 "$(grep -c '^| other ' "$t13_merge")"
assert "T-13 merge-into は count 行より後の行を残す" 1 "$(grep -c '^| tail ' "$t13_merge")"
t13_other_line=$(grep -n '^### 別の節$' "$t13_merge" | head -1 | cut -d: -f1)
t13_head_line=$(grep -n '^### 却下台帳$' "$t13_merge" | head -1 | cut -d: -f1)
t13_row_line=$(grep -n '^| NB-9 ' "$t13_merge" | head -1 | cut -d: -f1)
t13_count_line=$(grep -n '^📎 non_blocking_count:' "$t13_merge" | head -1 | cut -d: -f1)
if [ -n "$t13_other_line" ] && [ -n "$t13_head_line" ] && [ -n "$t13_row_line" ] && [ -n "$t13_count_line" ] \
  && [ "$t13_other_line" -lt "$t13_head_line" ] && [ "$t13_head_line" -lt "$t13_row_line" ] \
  && [ "$t13_count_line" -eq $((t13_row_line + 2)) ] \
  && [ -z "$(sed -n "$((t13_row_line + 1))p" "$t13_merge")" ]; then
  pass "T-13 merge-into は台帳を別の節の後・count 行の直前 (空行 1 行を挟む) へ差し込む"
else
  fail "T-13 merge-into の差し込み位置が違う (other=${t13_other_line:-none} head=${t13_head_line:-none} row=${t13_row_line:-none} count=${t13_count_line:-none})"
fi

# merge-into: CRLF 本文の既存台帳も見出しとして読み、置き換える
t13_crlf_merge="$sandbox/t13-crlf-merge.md"
cp "$crlf_body" "$t13_crlf_merge"
"$LEDGER" merge-into --body-file "$t13_crlf_merge" --ledger-file "$t13_new_ledger" 2>/dev/null
assert "T-13 CRLF 本文の merge-into は台帳見出しを重複させない" 1 "$(grep -c '^### 却下台帳$' "$t13_crlf_merge")"
assert "T-13 CRLF 本文の merge-into は旧台帳の行を残さない" 0 "$(grep -c '^| NB-[12] ' "$t13_crlf_merge")"
assert "T-13 CRLF 本文の merge-into は新台帳の行を 1 件入れる" 1 "$(grep -c '^| NB-9 ' "$t13_crlf_merge")"
assert "T-13 台帳を差し込んだ merge-into の本文に CR を残さない" 0 "$(grep -c $'\r' "$t13_crlf_merge")"
t13_noop="$sandbox/t13-noop.md"
cp "$crlf_body" "$t13_noop"
: > "$sandbox/t13-empty-ledger.md"
"$LEDGER" merge-into --body-file "$t13_noop" --ledger-file "$sandbox/t13-empty-ledger.md" 2>/dev/null
if cmp -s "$crlf_body" "$t13_noop"; then
  pass "T-13 空台帳の merge-into は本文を書き換えない"
else
  fail "T-13 空台帳の merge-into が本文を書き換えた"
fi

# 判定式の静的 pin: macOS の awk は `==` をロケール照合で比べ、見出しの正規表現が一致しない実装差がある。
# macOS の CI ジョブは失敗しても止まらないため、実行結果ではなく式の形で固定する
# denylist は空白の有無・被演算子の順序に依らない形で書く（`$0==head` / `head == $0` / `$0 ~ "^### "` も捕捉する）
assert_not_grep "T-13 ledger helper は見出しを == / != で比べない" "$LEDGER" '\$0[[:space:]]*[!=]=[[:space:]]*head|head[[:space:]]*[!=]=[[:space:]]*\$0|~[[:space:]]*"\^### "'
assert_not_grep "T-13 ledger helper は節境界を正規表現で判定しない" "$LEDGER" '/\^### /|/\^📎 non_blocking_count:/|~ count'
assert "T-13 ledger helper の行末 CR 除去は extract / merge-into の 2 か所" 2 "$(grep -cF 'sub(/\r$/, "")' "$LEDGER")"
assert "T-13 ledger helper の見出し判定式は extract / merge-into の 2 か所" 2 "$(grep -cF 'index($0, head) == 1 && length($0) == length(head)' "$LEDGER")"
# 使う側の肯定 pin: 代入行が残っていても、使う側が `==` 比較へ戻れば件数が動く
assert "T-13 extract の開始規則は is_head を使う" 1 "$(grep -cF 'is_head { in_sec=1 }' "$LEDGER")"
assert "T-13 merge-into の skip 規則は is_head を使う" 1 "$(grep -cF 'is_head { skip=1; next }' "$LEDGER")"
assert "T-13 extract の節境界式は index で判定する" 1 "$(grep -cF 'index($0, "### ") == 1 && !is_head' "$LEDGER")"
assert "T-13 merge-into の count 判定式は index で判定する" 1 "$(grep -cF 'is_count = (index($0, count) == 1)' "$LEDGER")"
assert "T-13 記録 helper の行末 CR 除去は 1 か所" 1 "$(grep -cF 'sub(/\r$/, "")' "$NBR_SH")"
assert "T-13 記録 helper の見出し判定式は ledger helper と同じ式で 1 か所" 1 "$(grep -cF 'index($0, head) == 1 && length($0) == length(head)' "$NBR_SH")"

# T-10: nb-sweep.md 手順 3 の成否判定。created / updated 以外で後続（done 書込）へ進まない
record_block="$sandbox/record-block.sh"
extract_fix_block 'reason=nb_sweep_ledger_record_failed' > "$record_block"
if [ ! -s "$record_block" ] || ! grep -q 'review-nonblocking-record.sh' "$record_block"; then
  fail "T-10 nb-sweep.md から記録ブロックを抽出できない"
else
  sweep_plugin="$sandbox/sweep-plugin"
  mkdir -p "$sweep_plugin/hooks/scripts" "$sandbox/sweep-tmp"
  ln -sf "$LEDGER" "$sweep_plugin/hooks/scripts/nb-sweep-ledger.sh"
  cat > "$sweep_plugin/hooks/review-nonblocking-record.sh" <<'SH'
#!/usr/bin/env bash
[ "$SWEEP_STUB_OUTCOME" = none ] ||
  echo "[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=7; outcome=$SWEEP_STUB_OUTCOME; count=0; iteration_id=nb-sweep-7; comment_id=; degraded=0" >&2
exit "$SWEEP_STUB_RC"
SH
  sed -e "s|{plugin_root}|$sweep_plugin|g" -e 's|{pr_number}|7|g' -e 's|{issue_number}|42|g' \
    -e 's|{owner_repo}|test/repo|g' "$record_block" > "$record_block.resolved"
  printf '\nprintf "REACHED\\n"\n' >> "$record_block.resolved"
  cp "$nbr_entries" "$sandbox/sweep-tmp/rite-nb-entries-7.md"
  run_record_block() {  # $1=outcome (none = DONE 行なし) $2=rc
    : > "$NBR_GH_LOG"
    SWEEP_STUB_OUTCOME="$1" SWEEP_STUB_RC="$2" TMPDIR="$sandbox/sweep-tmp" PATH="$nbr_bin:$PATH" \
      bash "$record_block.resolved" > "$sandbox/record-block.out" 2> "$sandbox/record-block.err"
  }
  for record_case in skipped:0 failed:0 aborted:0 none:0 created:1; do
    run_record_block "${record_case%%:*}" "${record_case##*:}"
    assert_grep "T-10 $record_case は [fix:error]" "$sandbox/record-block.out" '\[fix:error\]'
    assert_grep "T-10 $record_case の reason" "$sandbox/record-block.err" 'reason=nb_sweep_ledger_record_failed'
    assert_not_grep "T-10 $record_case は後続へ進まない" "$sandbox/record-block.out" '^REACHED$'
  done
  for record_case in created:0 updated:0; do
    run_record_block "${record_case%%:*}" "${record_case##*:}"
    assert_grep "T-10 $record_case は後続へ進む" "$sandbox/record-block.out" '^REACHED$'
    assert_not_grep "T-10 $record_case は [fix:error] を出さない" "$sandbox/record-block.out" '\[fix:error\]'
  done
fi

if ! print_summary "$(basename "$0")" "nb-sweep helper contract drift — check SKILL.md 5.S / 6.1.d preserve"; then
  exit 1
fi
