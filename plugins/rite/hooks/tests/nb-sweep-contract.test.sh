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
# T-14 extract → merge-into is idempotent: the first pass leaves one ledger section right before the count line with one blank line on each side, and the second pass is byte-identical; extract output never ends in a blank line; an in-place extract → merge-into leaves no consecutive blank lines
# T-15 --print-record-body: prints only the comment the write path would PATCH (CRLF → LF; durable id first); no record → empty stdout + absent; argument gates / resolution / lookup / body fetch / own login failures → rc=1, signal aborts → 128+n, each with a NONBLOCKING_RECORD_BODY=failed reason (pr_view_failed is never folded into related_issue_unresolved, including a headRefName read failure; a control character in pr= never forges a second marker line); never writes, never emits the terminal sentinel or NONBLOCKING_RECORD_FAILED, never touches pending markers
# T-16 with two record comments, collect excludes only the ledger of the comment the helper PATCHes; the four SKILL / reference readers read through --print-record-body once per site and never prefix-match the record heading
# T-17 6.1.d step 1.5 stops before the record helper when extract fails, the PR or its headRefName cannot be read, or the new body's first line is indented (merge-into body_marker_missing) (REJECTED_LEDGER_PRESERVE=failed, nothing written); an unresolvable related Issue continues with no ledger, but a pr= value carrying a forged reason=related_issue_unresolved does not (the reader anchors the reason at end of line)
# T-18 step 1.5 / step 3 / 8.0.3 agree on what follows REJECTED_LEDGER_PRESERVE=failed (judged by the last emitted value): no step 2; a merge-into body_* reason rewrites the body in step 1; any other failure re-runs step 1.5 once, then [review:error] shown in the same response; every re-run goes step 1 → step 1.5 → step 2 (output-diagnostics.md included)
# T-19 the {rejected_ledger} block run with the real helper: ok prints the rows; lookup / PR read / headRefName read / extract failures → REJECTED_LEDGER=failed + WARNING; an unresolvable related Issue → empty, but a pr= value carrying a forged reason=related_issue_unresolved → failed
# T-20 nb-sweep.md step 3 run with the real helper for both the read and the write: the PATCHed body carries the PATCH target's ledger plus this sweep's rows, and never an older record's or another author's ledger; the carried 4-column header becomes one 5-column header and this sweep's rows end with the source basename
# T-21 ledger source column: append writes a 5-column header, accepts only rows ending with a review JSON basename (suffix / trailing blanks / escaped pipes ok; otherwise entries_source_invalid with the ledger untouched), upgrades a 4-column header and separator once while keeping old rows byte-identical and in order; mixed ledgers survive extract → merge-into unchanged; the record helper count, header-only skip and collect exclusion read 5-column ledgers like 4-column ones; nb-sweep.md step 3 names the source column and its value source
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
printf '| F-01 | src/a.ts:10 | rejected | 本 PR のスコープ外（判定文） | 7-20260101120000.json |\n' > "$entries"
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
  # 記録 helper の読み取り専用モードが使う自 login / 関連 Issue body (durable id なし) / 単一コメント GET
  'api user '*) printf 'rite-bot\n' ;;
  'issue view '*) : ;;
  'api --paginate --slurp repos/test/repo/issues/42/comments')
    [ "${NB_TEST_FAIL:-0}" = 0 ] || exit 1
    cat "$NB_TEST_COMMENTS" ;;
  'api repos/test/repo/issues/comments/'*)
    jq --argjson id "${2##*/}" '[.[][] | select(.id == $id)][0]' "$NB_TEST_COMMENTS" ;;
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
# 字句順の末尾（F-NEW）の mtime を古くし、選び方が mtime 順へずれたら F-NEW を取り逃すようにする
touch -d '2020-01-02 00:00:00' "$pr_dir/1-20260102T000000.json" || touch -t 202001020000 "$pr_dir/1-20260102T000000.json"
touch -d '2020-03-03 00:00:00' "$pr_dir/1-20260101T000000.json" || touch -t 202003030000 "$pr_dir/1-20260101T000000.json"
pr_out=$("$COLLECT" --pr 1 --state-root "$sandbox/state" 2>"$sandbox/tpr.err") || pr_rc=$?
pr_rc=${pr_rc:-0}
assert "T-01 --pr rc=0" "0" "$pr_rc"
assert "T-01 --pr picks F-NEW" "F-NEW" "$(printf '%s' "$pr_out" | jq -r '.targets[0].id')"
pr_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"; }
assert "T-01 --pr fixture: lexical tail is not the mtime max" "1" \
  "$([ "$(pr_mtime "$pr_dir/1-20260101T000000.json")" -gt "$(pr_mtime "$pr_dir/1-20260102T000000.json")" ] && echo 1 || echo 0)"
assert "T-01 --pr record is the lexical tail" "1-20260102T000000.json" "$(printf '%s' "$pr_out" | jq -r '.record' | xargs basename)"

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
jq -n --rawfile body "$ledger_body" '[[{id:11,user:{login:"rite-bot"},body:$body}]]' > "$NB_TEST_COMMENTS"
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
jq -n --rawfile body "$crlf_ledger_body" '[[{id:11,user:{login:"rite-bot"},body:$body}]]' > "$NB_TEST_COMMENTS"
crlf_out=$("$COLLECT" --json "$live_json" --pr 1)
assert "CRLF ledger excludes the same three dispositions" "2" "$(printf '%s' "$crlf_out" | jq '.count')"
assert "CRLF targets equal LF targets" "$(printf '%s' "$live_out" | jq -cS '[.targets[] | {id, file, line}]')" "$(printf '%s' "$crlf_out" | jq -cS '[.targets[] | {id, file, line}]')"
assert "CRLF keeps the collision row outside the ledger" "1" "$(printf '%s' "$crlf_out" | jq '[.targets[] | select(.id=="collision")] | length')"
jq -n --rawfile body "$ledger_body" '[[{id:11,user:{login:"rite-bot"},body:$body}]]' > "$NB_TEST_COMMENTS"
NB_TEST_BRANCH_ONLY=1 "$COLLECT" --json "$live_json" --pr 1 > "$sandbox/branch.out"
assert "branch fallback gets same ledger" "$live_out" "$(cat "$sandbox/branch.out")"
assert_grep "ledger loaded from related Issue" "$NB_TEST_GH_LOG" 'repos/test/repo/issues/42/comments'
NB_TEST_FAIL=1 "$COLLECT" --json "$live_json" --pr 1 > /dev/null 2> "$sandbox/read-fail.err"
assert "ledger read failure rc=1" "1" "$?"
assert_grep "ledger read failure is loud" "$sandbox/read-fail.err" 'reason=comments_unreadable'
# 記録コメントを同定できない応答は「記録なし」に倒さず、読み取り失敗として止める
printf '[1]\n' > "$NB_TEST_COMMENTS"
"$COLLECT" --json "$live_json" --pr 1 > /dev/null 2> "$sandbox/invalid-ledger.err"
assert "invalid comment response rc=1" "1" "$?"
assert_grep "invalid comment response is loud" "$sandbox/invalid-ledger.err" 'reason=comments_unreadable'
assert_grep "invalid comment response surfaces the helper reason" "$sandbox/invalid-ledger.err" 'NONBLOCKING_RECORD_BODY=failed; pr=1; reason=lookup_failed'

# --- T-16: 記録コメントが 2 件あっても、helper が PATCH する 1 件の台帳だけを読む ---
# 古い記録 (id 11, 台帳 A) → 新しい記録 (id 13, 台帳 B) → 他人の同 marker コメント (id 99, 台帳 C) の順に並べる。
t16_body() {  # $1=finding_id $2=file:line
  printf '%s\n' "$MARKER" '' '### 却下台帳' '' '| finding_id | file:line | 判定 | 判定文 |' \
    '|------------|-----------|------|--------|' "| $1 | $2 | issued | #9 |" '' '📎 non_blocking_count: 0' '' "$SENTINEL"
}
jq -n --arg a "$(t16_body A-1 src/a.ts:1)" --arg b "$(t16_body B-1 src/b.ts:2)" --arg c "$(t16_body C-1 src/c.ts:3)" \
  '[[{id:11,user:{login:"rite-bot"},body:$a},{id:13,user:{login:"rite-bot"},body:$b}],[{id:99,user:{login:"someone-else"},body:$c}]]' \
  > "$NB_TEST_COMMENTS"
t16_json="$sandbox/t16.json"
jq -n '{non_blocking_findings:[{id:"A-1",file:"src/a.ts",line:1},{id:"B-1",file:"src/b.ts",line:2},{id:"C-1",file:"src/c.ts",line:3}]}' > "$t16_json"
t16_out=$("$COLLECT" --json "$t16_json" --pr 1 2> "$sandbox/t16.err")
assert "T-16 collect rc=0" "0" "$?"
assert "T-16 台帳 B (PATCH 先) の行だけを除外する" "A-1,C-1" "$(printf '%s' "$t16_out" | jq -r '[.targets[].id] | sort | join(",")')"
assert_grep "T-16 読み取りは PATCH 先 (id 13) を指す" "$sandbox/t16.err" 'NONBLOCKING_RECORD_BODY=found; pr=1; comment_id=13$'
assert_grep "T-16 重複した記録コメントを観測する" "$sandbox/t16.err" 'NONBLOCKING_DUPLICATE_RECORD=1; pr=1; count=2'

# --- rails pin (SKILL.md 機械レール) ---
ITERATE="$PLUGIN_ROOT/skills/iterate/SKILL.md"
# iterate の各ステップのシェル本体（marker_emit / helper 呼び出し）は iterate-step.sh にある。
# SKILL.md 側は分岐表・sentinel ルーティングの散文を持つ。
ITERATE_STEP="$PLUGIN_ROOT/scripts/iterate-step.sh"
FIX="$PLUGIN_ROOT/skills/fix/references/nb-sweep.md"
REVIEW="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
PROMPT="$PLUGIN_ROOT/skills/pr-review/references/reviewer-prompt-generator.md"
assert_grep "T-07 iterate mergeable→5.S" "$ITERATE" '\[review:mergeable\].*5\.S'
assert_grep "T-07 iterate sweep-done no re-review" "$ITERATE" '\[fix:sweep-done\].*ステップ 5'
assert_grep "T-07 iterate nb-sweep-error" "$ITERATE" '\[iterate:nb-sweep-error\]'
assert_grep "T-07 iterate --nb-sweep invoke" "$ITERATE" 'args: "--nb-sweep \{pr_number\}"'
assert_grep "T-07 iterate empty is noop" "$ITERATE_STEP" 'marker_emit ITERATE_NB_SWEEP noop'
assert_grep "T-07 iterate no second sweep" "$ITERATE" '同一 review JSON で 5\.S を 2 回'
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

# measured class B MEDIUM is moved by the real triage helper and consumed by the existing sweep.
FIX_SKILL="$PLUGIN_ROOT/skills/fix/SKILL.md"
medium_json="$sandbox/non-fatal-only.json"
write_json "$medium_json" <<'JSON'
{"pr_number":1,"findings":[
  {"id":"M-1","severity":"MEDIUM","scope":"current-pr","file":"src/a.ts","line":10,"verification":{"measured":true},"consequence_class":"B"},
  {"id":"M-2","severity":"MEDIUM","scope":"follow-up","file":"src/b.ts","line":20,"verification":{"measured":true},"consequence_class":"B"}
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
jq -r '.targets[] | "| \(.id) | \(.file):\(.line) | issued | fixture issue for \(.id) | 7-20260101120000.json |"' \
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
run_close_section=$(sed -n '/^### ステップ 5\.0\.1:/,/^### ステップ 5\.0\.2:/p' "$ITERATE")
assert "reply-only records deferred context" 1 "$(printf '%s\n' "$run_close_section" | grep -c '返信のみは `review-defer` で `deferred` として終了記録を保存')"
run_close_body=$(awk '/^step_run_close\(\) \{$/{f=1} f{print} f && /^}$/{exit}' "$ITERATE_STEP")
assert "reply-only defers through the flow-state helper" 1 "$(printf '%s\n' "$run_close_body" | grep -c 'bash "$plugin_root"/hooks/flow-state.sh review-defer')"
assert "reply-only emits deferred run-close state" 1 "$(printf '%s\n' "$run_close_body" | grep -c 'marker_emit ITERATE_RUN_CLOSE deferred')"
assert "interruption retains the unfinished run" 1 "$(printf '%s\n' "$run_close_section" | grep -c '中断は `retained` として未完了 run を閉じない')"
assert "stale reply-only retained wording is absent" 0 "$(printf '%s\n' "$run_close_section" | grep -c '中断・返信のみは `retained`')"
assert_grep "reentry and nested sweep cannot overwrite entry reason" "$ITERATE" '5\.S 再入時も保持値を使い、内部の `\[fix:sweep-done\]` や handoff で上書きしない'
assert "unknown entry cannot imply success" 1 "$(printf '%s\n' "$sweep_exit" | grep -c '^| 欠落 / その他 | `\[iterate:nb-sweep-error\]`')"
assert_grep "all successful sweep outcomes use entry routing" "$ITERATE" '5\.S の `done` / `noop` / `skipped`.*消化の成功だけ'
assert_grep "merge-mode batch still stops on reply-only" "$PLUGIN_ROOT/skills/batch-run/SKILL.md" '^\| `\[fix:replied-only\]` \+ `merge` \|.*ステップ 8'

# --- 却下台帳だけを持つ本文の記録（T-09〜T-12） ---
# 記録 helper 専用の gh stub。collect 用 stub（exit 97 で未知の呼び出しを落とす）とは別ディレクトリに置き、
# helper / sweep ブロックの実行中だけ PATH の先頭へ入れる。
nbr_bin="$sandbox/nbr-bin"
mkdir -p "$nbr_bin"
# 失敗注入: NBR_USER_FAIL (自 login) / NBR_PR_VIEW_FAIL (PR body・headRefName) / NBR_HEADREF_FAIL (headRefName だけ) /
# NBR_GET_FAIL (単一コメント GET)。
# NBR_ISSUE_BODY は関連 Issue body を返すファイル (durable id)。NBR_USER_READY を置くと自 login の取得で
# そのファイルを作ってから NBR_USER_SLEEP 秒待つ (signal のテスト用)。
cat > "$nbr_bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NBR_GH_LOG"
case "${1:-} ${2:-}" in
  'api user')
    [ "${NBR_USER_FAIL:-0}" = 0 ] || exit 1
    if [ -n "${NBR_USER_READY:-}" ]; then
      : > "$NBR_USER_READY"
      sleep "${NBR_USER_SLEEP:-1}"
    fi
    printf 'rite-bot\n'; exit 0 ;;
  'pr view')
    [ "${NBR_PR_VIEW_FAIL:-0}" = 0 ] || exit 1
    if [ "${NBR_HEADREF_FAIL:-0}" = 1 ]; then
      case " $* " in *" headRefName "*) exit 1 ;; esac
    fi
    if [ "${NBR_NO_ISSUE:-0}" = 1 ]; then
      case " $* " in *" headRefName "*) printf 'topic-branch\n' ;; *) printf 'no keyword\n' ;; esac
      exit 0
    fi
    case " $* " in *" headRefName "*) printf 'feat/issue-42-test\n' ;; *) printf 'Closes #42\n' ;; esac
    exit 0 ;;
  'issue view')
    [ -z "${NBR_ISSUE_BODY:-}" ] || cat "$NBR_ISSUE_BODY"
    exit 0 ;;
  'issue edit') exit 0 ;;
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
esac
case "${1:-} ${2:-}" in
  # 単一コメントの GET (読み取り専用モードが PATCH 先の本文を取る)
  'api repos/test/repo/issues/comments/'*)
    [ "${NBR_GET_FAIL:-0}" = 0 ] || exit 1
    jq --argjson id "${2##*/}" '[.[][] | select(.id == $id)][0]' "$NBR_COMMENTS"
    exit 0 ;;
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
printf '%s\n' '| NB-1 | src/a.ts:1 | recorded | severity=MEDIUM; measured=false | 7-20260101120000.json |' \
  '| NB-2 | src/b.ts:2 | recorded | severity=LOW; measured=false | 7-20260101120000.json |' > "$nbr_entries"
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
  || ! printf '%s\n' "$gh_err_detail_def" | grep -c >/dev/null 'case "\$_label" in'; then
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
    t13_out="$sandbox/t13-extract-$(basename "$t13_body")"
    t13_err="$sandbox/t13-extract-$(basename "$t13_body").err"
    t13_extract_rc=0
    "$LEDGER" extract --body-file "$t13_body" > "$t13_out" 2> "$t13_err" || t13_extract_rc=$?
    if [ "$t13_extract_rc" -ne 0 ]; then
      fail "T-13 extract failed ($(basename "$t13_body")) rc=$t13_extract_rc: $(tr '\n' ' ' < "$t13_err")"
      continue
    fi
    t13_extract=$(grep -E '^\| ' "$t13_out" | grep -v '^| finding_id ' | grep -cvE '^\|[-: |]+\|$')
    assert "T-13 台帳の件数が記録 helper と extract で一致 ($(basename "$t13_body"))" "$t13_record" "$t13_extract"
  done
fi
t13_crlf_out="$sandbox/t13-crlf-extract.md"
t13_crlf_err="$sandbox/t13-crlf-extract.err"
t13_crlf_rc=0
"$LEDGER" extract --body-file "$crlf_body" > "$t13_crlf_out" 2> "$t13_crlf_err" || t13_crlf_rc=$?
if [ "$t13_crlf_rc" -ne 0 ]; then
  fail "T-13 CRLF extract failed rc=$t13_crlf_rc: $(tr '\n' ' ' < "$t13_crlf_err")"
else
  assert "T-13 CRLF 本文の extract は台帳 2 件を返す" 2 "$(grep -c '^| NB-' "$t13_crlf_out")"
  assert "T-13 extract の出力に CR を残さない" 0 "$(grep -c $'\r' "$t13_crlf_out")"
fi
t13_outside_out="$sandbox/t13-outside-extract.md"
t13_outside_err="$sandbox/t13-outside-extract.err"
t13_outside_rc=0
"$LEDGER" extract --body-file "$outside_rows" > "$t13_outside_out" 2> "$t13_outside_err" || t13_outside_rc=$?
if [ "$t13_outside_rc" -ne 0 ]; then
  fail "T-13 outside extract failed rc=$t13_outside_rc: $(tr '\n' ' ' < "$t13_outside_err")"
else
  assert_not_grep "T-13 extract は台帳節の後の別の節の行を出さない" "$t13_outside_out" '^\| other '
fi

# merge-into: 既存台帳の後に別の節がある本文で、台帳節だけを置き換えて count 行の直前へ差し込む
t13_new_ledger="$sandbox/t13-new-ledger.md"
printf '%s\n' '| NB-9 | src/z.ts:9 | recorded | severity=LOW; measured=false | 7-20260101120000.json |' > "$sandbox/t13-entries.md"
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
assert "T-13 CRLF 本文の merge-into は台帳見出しを重複させない" 1 "$(grep -cE $'^### 却下台帳\r?$' "$t13_crlf_merge")"
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
# 手順 3 の既存記録コメントの読み取り (記録なし)
if [ "$1" = --print-record-body ]; then
  echo "[CONTEXT] NONBLOCKING_RECORD_BODY=absent; pr=7" >&2
  exit 0
fi
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

# --- T-14: extract → merge-into は冪等 (2 回かけても本文が変わらず、空行が増えない) ---
t14_src="$sandbox/t14-src.md"
# 既存本文の台帳の前後に空行が 2 行ずつある (旧形式の繰り返しで空行が積もった本文)
printf '%s\n' "$MARKER" '' '| レビュアー | 重要度 |' '|---|---|' '| r | HIGH |' '' '' '### 却下台帳' '' \
  '| finding_id | file:line | 判定 | 判定文 |' '|------------|-----------|------|--------|' \
  '| T14-1 | src/a.ts:1 | rejected | r1 |' '| T14-2 | src/b.ts:2 | issued | #9 |' '' '' \
  '📎 non_blocking_count: 1' '📎 reviewed_commit: abc' '' "$SENTINEL" > "$t14_src"
t14_new="$sandbox/t14-new.md"
printf '%s\n' "$MARKER" '' '| レビュアー | 重要度 |' '|---|---|' '| r | HIGH |' '' \
  '📎 non_blocking_count: 1' '📎 reviewed_commit: def' '' "$SENTINEL" > "$t14_new"
t14_pass() {  # $1=既存本文 $2=新本文 (書き換える)
  "$LEDGER" extract --body-file "$1" > "$sandbox/t14-ledger.md" 2>/dev/null \
    && "$LEDGER" merge-into --body-file "$2" --ledger-file "$sandbox/t14-ledger.md" 2>/dev/null
}
cp "$t14_new" "$sandbox/t14-p1.md"
if t14_pass "$t14_src" "$sandbox/t14-p1.md"; then
  pass "T-14 1 回目の extract → merge-into が成功する"
else
  fail "T-14 1 回目の extract → merge-into が失敗した"
fi
assert "T-14 1 回目: 台帳見出しは 1 つ" 1 "$(grep -c '^### 却下台帳$' "$sandbox/t14-p1.md")"
assert "T-14 1 回目: 行 T14-1 は 1 回" 1 "$(grep -c '^| T14-1 ' "$sandbox/t14-p1.md")"
assert "T-14 1 回目: 行 T14-2 は 1 回" 1 "$(grep -c '^| T14-2 ' "$sandbox/t14-p1.md")"
t14_head=$(grep -n '^### 却下台帳$' "$sandbox/t14-p1.md" | head -1 | cut -d: -f1)
t14_last=$(grep -n '^| T14-2 ' "$sandbox/t14-p1.md" | head -1 | cut -d: -f1)
t14_count=$(grep -n '^📎 non_blocking_count:' "$sandbox/t14-p1.md" | head -1 | cut -d: -f1)
if [ -n "$t14_head" ] && [ -n "$t14_last" ] && [ -n "$t14_count" ] \
  && [ "$t14_count" -eq $((t14_last + 2)) ] && [ -z "$(sed -n "$((t14_last + 1))p" "$sandbox/t14-p1.md")" ] \
  && [ -z "$(sed -n "$((t14_head - 1))p" "$sandbox/t14-p1.md")" ] \
  && [ -n "$(sed -n "$((t14_head - 2))p" "$sandbox/t14-p1.md")" ]; then
  pass "T-14 1 回目: 台帳は count 行の直前にあり、前後の空行はちょうど 1 行"
else
  fail "T-14 1 回目: 台帳の位置か前後の空行が違う (head=${t14_head:-none} last=${t14_last:-none} count=${t14_count:-none})"
fi
assert "T-14 1 回目: 連続する空行が無い" 0 "$(awk 'prev == "" && $0 == "" && NR > 1 { n++ } { prev = $0 } END { print n + 0 }' "$sandbox/t14-p1.md")"
cp "$sandbox/t14-p1.md" "$sandbox/t14-p2.md"
t14_pass "$sandbox/t14-p1.md" "$sandbox/t14-p2.md"
if cmp -s "$sandbox/t14-p1.md" "$sandbox/t14-p2.md"; then
  pass "T-14 2 回目は本文を変えない (byte 一致)"
else
  fail "T-14 2 回目で本文が変わった"
fi
# 新本文へ引き継ぐ経路 (6.1.d / fix) も、2 cycle 目で 1 cycle 目と同じ本文になる
cp "$t14_new" "$sandbox/t14-p3.md"
t14_pass "$sandbox/t14-p1.md" "$sandbox/t14-p3.md"
if cmp -s "$sandbox/t14-p1.md" "$sandbox/t14-p3.md"; then
  pass "T-14 新本文への 2 cycle 目の引き継ぎも 1 cycle 目と同じ本文になる"
else
  fail "T-14 新本文への 2 cycle 目の引き継ぎで本文が変わった"
fi
# extract 単体: 台帳の後に空行が 2 行ある本文でも、出力は空行で終わらない
"$LEDGER" extract --body-file "$t14_src" > "$sandbox/t14-extract.md" 2>/dev/null
if [ -s "$sandbox/t14-extract.md" ] && [ -n "$(tail -n 1 "$sandbox/t14-extract.md")" ]; then
  pass "T-14 extract の出力は節末尾の空行を含まない"
else
  fail "T-14 extract の出力が空行で終わる (または空)"
fi
# 同じ本文への extract → merge-into (NB sweep 手順 3 の形): 台帳の前に積もった空行も 1 行に揃う
cp "$t14_src" "$sandbox/t14-inplace.md"
t14_pass "$sandbox/t14-inplace.md" "$sandbox/t14-inplace.md"
assert "T-14 同じ本文への extract → merge-into で連続する空行が無い" 0 "$(awk 'prev == "" && $0 == "" && NR > 1 { n++ } { prev = $0 } END { print n + 0 }' "$sandbox/t14-inplace.md")"
assert "T-14 同じ本文への extract → merge-into で行 T14-1 は 1 回" 1 "$(grep -c '^| T14-1 ' "$sandbox/t14-inplace.md")"

# --- T-15: --print-record-body (読み取り専用モード) ---
t15_tmp="$sandbox/t15-tmp"
mkdir -p "$t15_tmp"
: > "$t15_tmp/rite-nbr-pending-x"
run_print() {  # 追加引数をそのまま渡す
  : > "$NBR_GH_LOG"
  print_rc=0
  TMPDIR="$t15_tmp" PATH="$nbr_bin:$PATH" bash "$NBR_SH" --print-record-body --pr 7 --owner-repo test/repo "$@" \
    > "$sandbox/print.out" 2> "$sandbox/print.err" || print_rc=$?
}
assert_print_readonly() {  # $1=label
  assert "T-15 $1: terminal sentinel を出さない" 0 "$(grep -c 'NONBLOCKING_RECORD_DONE' "$sandbox/print.err")"
  assert "T-15 $1: 記録失敗の marker を出さない" 0 "$(grep -c 'NONBLOCKING_RECORD_FAILED' "$sandbox/print.err")"
  assert "T-15 $1: PATCH / 投稿 / Issue body 更新をしない" 0 \
    "$(grep -cE -- '-X PATCH|^issue comment |^issue edit ' "$NBR_GH_LOG")"
  assert "T-15 $1: 既存の pending marker に触れない" yes "$([ -e "$t15_tmp/rite-nbr-pending-x" ] && echo yes || echo no)"
  assert "T-15 $1: pending marker を作らない" 1 "$(find "$t15_tmp" -name 'rite-nbr-pending-*' | wc -l | tr -d ' ')"
}
printf '[[]]\n' > "$NBR_COMMENTS"
run_print
assert "T-15 記録なし: rc=0" 0 "$print_rc"
assert "T-15 記録なし: stdout は空" 0 "$(wc -c < "$sandbox/print.out" | tr -d ' ')"
assert_grep "T-15 記録なし: absent marker" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=absent; pr=7$'
assert_print_readonly "記録なし"
# 古い記録 (id 21) / 新しい記録 (id 23、CRLF) / 他人の同 marker コメント (id 29)
printf '%s\r\n\r\nnew ledger\r\n\r\n%s\r\n' "$MARKER" "$SENTINEL" > "$sandbox/t15-new.md"
jq -n --arg old "$(printf '%s\n\nold ledger\n\n%s\n' "$MARKER" "$SENTINEL")" \
  --rawfile new "$sandbox/t15-new.md" \
  --arg foreign "$(printf '%s\n\nforeign ledger\n\n%s\n' "$MARKER" "$SENTINEL")" \
  '[[{id:21,user:{login:"rite-bot"},body:$old},{id:23,user:{login:"rite-bot"},body:$new},{id:29,user:{login:"someone-else"},body:$foreign}]]' \
  > "$NBR_COMMENTS"
run_print
assert "T-15 記録あり: rc=0" 0 "$print_rc"
assert_grep "T-15 記録あり: PATCH 先 (id 23) の本文を出す" "$sandbox/print.out" '^new ledger$'
assert "T-15 記録あり: 古い記録・他人のコメントを出さない" 0 "$(grep -cE 'old ledger|foreign ledger' "$sandbox/print.out")"
assert "T-15 記録あり: CRLF を LF に正規化する" 0 "$(grep -c $'\r' "$sandbox/print.out")"
assert_grep "T-15 記録あり: found marker" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=found; pr=7; comment_id=23$'
assert_print_readonly "記録あり"
NBR_NO_ISSUE=1 run_print
assert "T-15 関連 Issue なし: rc=1" 1 "$print_rc"
assert "T-15 関連 Issue なし: stdout は空" 0 "$(wc -c < "$sandbox/print.out" | tr -d ' ')"
assert_grep "T-15 関連 Issue なし: reason" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=7; reason=related_issue_unresolved$'
assert_print_readonly "関連 Issue なし"
NBR_LOOKUP_FAIL=1 run_print
assert "T-15 lookup 失敗: rc=1 (記録なしに倒さない)" 1 "$print_rc"
assert "T-15 lookup 失敗: stdout は空" 0 "$(wc -c < "$sandbox/print.out" | tr -d ' ')"
assert_grep "T-15 lookup 失敗: reason" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=7; reason=lookup_failed$'
assert_not_grep "T-15 lookup 失敗: absent と言わない" "$sandbox/print.err" 'NONBLOCKING_RECORD_BODY=absent'
assert_print_readonly "lookup 失敗"
run_print --count 1
assert "T-15 記録経路の引数との併用: rc=1" 1 "$print_rc"
assert_grep "T-15 記録経路の引数との併用: reason" "$sandbox/print.err" 'NONBLOCKING_RECORD_BODY=failed; pr=7; reason=conflicting_options'
assert "T-15 記録経路の引数との併用: gh を呼ばない" 0 "$(wc -l < "$NBR_GH_LOG" | tr -d ' ')"
# 引数 gate も読み取り専用モードでは NONBLOCKING_RECORD_BODY=failed で返す (書き込み経路の marker を出さない)
assert_print_gate() {  # $1=label $2=reason
  assert "T-15 $1: rc=1" 1 "$print_rc"
  assert "T-15 $1: stdout は空" 0 "$(wc -c < "$sandbox/print.out" | tr -d ' ')"
  assert "T-15 $1: reason=$2 の failed marker を 1 回" 1 \
    "$(grep -c "^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=[^;]*; reason=$2\$" "$sandbox/print.err")"
  assert "T-15 $1: 記録失敗の marker を出さない" 0 "$(grep -c 'NONBLOCKING_RECORD_FAILED' "$sandbox/print.err")"
  assert "T-15 $1: terminal sentinel を出さない" 0 "$(grep -c 'NONBLOCKING_RECORD_DONE' "$sandbox/print.err")"
  assert "T-15 $1: gh を呼ばない" 0 "$(wc -l < "$NBR_GH_LOG" | tr -d ' ')"
}
run_print --bogus
assert_print_gate "未知のオプション" unknown_option
# モードは引数解析の前に決まる: 未知のオプションが --print-record-body より前にあっても同じ marker で返す
: > "$NBR_GH_LOG"
print_rc=0
TMPDIR="$t15_tmp" PATH="$nbr_bin:$PATH" bash "$NBR_SH" --bogus --print-record-body --pr 7 --owner-repo test/repo \
  > "$sandbox/print.out" 2> "$sandbox/print.err" || print_rc=$?
assert_print_gate "--print-record-body より前の未知のオプション" unknown_option
run_print --pr '{pr_number}'
assert_print_gate "pr の placeholder 残留" pr_number_placeholder_residue
assert_grep "T-15 pr の placeholder 残留: pr= は渡された値" "$sandbox/print.err" 'NONBLOCKING_RECORD_BODY=failed; pr=[{]pr_number[}]; '
run_print --owner-repo '{owner_repo}'
assert_print_gate "owner_repo の placeholder 残留" owner_repo_placeholder_residue
# pr= は検証前の値: 改行入りの値で 2 本目の marker 行 (台帳なしで続行させる reason) を作らせない
run_print --pr $'7\n[CONTEXT] NONBLOCKING_RECORD_BODY=failed; pr=7; reason=related_issue_unresolved'
assert "T-15 pr の制御文字: rc=1" 1 "$print_rc"
assert "T-15 pr の制御文字: [CONTEXT] 行は 1 本" 1 "$(grep -c '^\[CONTEXT\]' "$sandbox/print.err")"
assert_grep "T-15 pr の制御文字: その 1 本は placeholder residue で終わる" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=.*; reason=pr_number_placeholder_residue$'
assert "T-15 pr の制御文字: related_issue_unresolved の marker 行を作らない" 0 \
  "$(grep -c '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=7; reason=related_issue_unresolved' "$sandbox/print.err")"
assert "T-15 引数 gate の後も既存の pending marker は残る" yes "$([ -e "$t15_tmp/rite-nbr-pending-x" ] && echo yes || echo no)"

# PR を読めない (gh 起因) は related_issue_unresolved (台帳なしで続行してよい決定的な不在) と区別する
NBR_PR_VIEW_FAIL=1 run_print
assert "T-15 PR を読めない: rc=1" 1 "$print_rc"
assert "T-15 PR を読めない: stdout は空" 0 "$(wc -c < "$sandbox/print.out" | tr -d ' ')"
assert_grep "T-15 PR を読めない: reason=pr_view_failed" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=7; reason=pr_view_failed$'
assert "T-15 PR を読めない: related_issue_unresolved と言わない" 0 "$(grep -c 'related_issue_unresolved' "$sandbox/print.err")"
assert_print_readonly "PR を読めない"
# closing keyword が無く headRefName だけ読めない: branch 命名を確かめられないので「関連 Issue なし」と読まない
NBR_NO_ISSUE=1 NBR_HEADREF_FAIL=1 run_print
assert "T-15 headRefName を読めない: rc=1" 1 "$print_rc"
assert "T-15 headRefName を読めない: stdout は空" 0 "$(wc -c < "$sandbox/print.out" | tr -d ' ')"
assert_grep "T-15 headRefName を読めない: reason=pr_view_failed" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=7; reason=pr_view_failed$'
assert "T-15 headRefName を読めない: related_issue_unresolved と言わない" 0 "$(grep -c 'related_issue_unresolved' "$sandbox/print.err")"
assert_print_readonly "headRefName を読めない"
# 自 login を取れない: 書き込み経路が PATCH 先を決められないので「記録なし」と読まない
NBR_USER_FAIL=1 run_print
assert "T-15 自 login なし: rc=1" 1 "$print_rc"
assert "T-15 自 login なし: stdout は空" 0 "$(wc -c < "$sandbox/print.out" | tr -d ' ')"
assert_grep "T-15 自 login なし: reason" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=7; reason=own_login_unavailable$'
assert_not_grep "T-15 自 login なし: absent と言わない" "$sandbox/print.err" 'NONBLOCKING_RECORD_BODY=absent'
assert_print_readonly "自 login なし"
# PATCH 先は決まったが本文を取れない
NBR_GET_FAIL=1 run_print
assert "T-15 本文取得失敗: rc=1" 1 "$print_rc"
assert "T-15 本文取得失敗: stdout は空" 0 "$(wc -c < "$sandbox/print.out" | tr -d ' ')"
assert_grep "T-15 本文取得失敗: reason" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=7; reason=body_fetch_failed$'
assert_not_grep "T-15 本文取得失敗: absent / found と言わない" "$sandbox/print.err" 'NONBLOCKING_RECORD_BODY=(absent|found)'
assert_print_readonly "本文取得失敗"
# durable id: 関連 Issue body の id が古い記録 (id 21) を指すときは、書き込み経路と同じくそれを読む
jq '[.[] | map(. + {issue_url: "https://api.github.com/repos/test/repo/issues/42"})]' "$NBR_COMMENTS" > "$NBR_COMMENTS.tmp"
mv "$NBR_COMMENTS.tmp" "$NBR_COMMENTS"
printf '## 概要\n\n<!-- rite:nbr:comment-id:21 -->\n' > "$sandbox/t15-issue-body.md"
NBR_ISSUE_BODY="$sandbox/t15-issue-body.md" run_print
assert "T-15 durable id: rc=0" 0 "$print_rc"
assert_grep "T-15 durable id: id 21 を PATCH 先として読む" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=found; pr=7; comment_id=21$'
assert_grep "T-15 durable id: 古い記録の本文を出す" "$sandbox/print.out" '^old ledger$'
assert "T-15 durable id: 本文照合の候補 (id 23)・他人のコメントを出さない" 0 "$(grep -cE 'new ledger|foreign ledger' "$sandbox/print.out")"
assert "T-15 durable id: id で解決できている (fallback しない)" 0 "$(grep -c 'NONBLOCKING_ID_UNRESOLVED' "$sandbox/print.err")"
assert_print_readonly "durable id"
# signal: 中断は failed で返し、stderr の一時ファイルを残さない
t15_ready="$sandbox/t15-user-ready"
rm -f "$t15_ready"
: > "$NBR_GH_LOG"
NBR_USER_READY="$t15_ready" NBR_USER_SLEEP=1 TMPDIR="$t15_tmp" PATH="$nbr_bin:$PATH" \
  bash "$NBR_SH" --print-record-body --pr 7 --owner-repo test/repo > "$sandbox/print.out" 2> "$sandbox/print.err" &
t15_pid=$!
for _t15_wait in $(seq 1 200); do
  [ -e "$t15_ready" ] && break
  sleep 0.05
done
assert "T-15 signal: 中断前は stderr の一時ファイルがある" 1 "$(find "$t15_tmp" -name 'rite-p61d-lookup-err-*' | wc -l | tr -d ' ')"
kill -TERM "$t15_pid"
print_rc=0
wait "$t15_pid" || print_rc=$?
assert "T-15 signal: rc=143" 143 "$print_rc"
assert "T-15 signal: stdout は空" 0 "$(wc -c < "$sandbox/print.out" | tr -d ' ')"
assert_grep "T-15 signal: reason" "$sandbox/print.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=7; reason=signal_aborted$'
assert "T-15 signal: stderr の一時ファイルを残さない" 0 "$(find "$t15_tmp" -name 'rite-p61d-lookup-err-*' | wc -l | tr -d ' ')"
assert_print_readonly "signal"

# --- T-16 (静的): SKILL / reference の読み手は site ごとに --print-record-body を 1 回呼び、前方一致で読まない ---
# $1=file $2=needle。needle を含む bash fence (字下げ付きを含む) を 1 つ取り出す
extract_block_of() {
  awk -v needle="$2" '
    /^[[:space:]]*```bash$/ {inside=1; block=""; next}
    /^[[:space:]]*```$/ {if (inside && index(block, needle)) {printf "%s", block; exit}; inside=0}
    inside {block=block $0 "\n"}
  ' "$1"
}
NFR="$PLUGIN_ROOT/skills/fix/references/non-fatal-record.md"
for t16_file in "$REVIEW" "$NFR" "$FIX"; do
  assert "T-16 ${t16_file#"$PLUGIN_ROOT"/} は記録見出しを前方一致で読まない" 0 \
    "$(grep -cF 'startswith("## 📜 rite 非実測指摘の記録")' "$t16_file")"
done
for t16_site in "$REVIEW|rite-rejected-src" "$REVIEW|rite-nb-existing" "$NFR|nonblocking_record_ledger_fetch_failed" "$FIX|nb_sweep_ledger_fetch_failed"; do
  t16_block=$(extract_block_of "${t16_site%%|*}" "${t16_site##*|}")
  if [ -z "$t16_block" ]; then
    fail "T-16 ${t16_site##*|} の bash block を抽出できない"
    continue
  fi
  assert "T-16 ${t16_site##*|} の block は --print-record-body を 1 回呼ぶ" 1 \
    "$(printf '%s' "$t16_block" | grep -cF 'review-nonblocking-record.sh --print-record-body')"
  assert "T-16 ${t16_site##*|} の block はコメント一覧を直接読まない" 0 \
    "$(printf '%s' "$t16_block" | grep -cE 'issues/[^ ]*/comments')"
done

# --- T-17: 6.1.d step 1.5 は extract が失敗したら記録 helper の前で止まる ---
step15=$(extract_block_of "$REVIEW" 'rite-nb-existing')
t17_tmp="$sandbox/t17-tmp"
t17_plugin="$sandbox/t17-plugin"
mkdir -p "$t17_tmp" "$t17_plugin/hooks/scripts"
# 読み取りは実 helper (同じディレクトリの依存を並べる)。台帳 helper だけ extract を失敗させ、呼び出しを記録する
for t17_dep in review-nonblocking-record.sh control-char-neutralize.sh _mktemp-stderr-guard.sh; do
  ln -sf "$PLUGIN_ROOT/hooks/$t17_dep" "$t17_plugin/hooks/$t17_dep"
done
cat > "$t17_plugin/hooks/scripts/nb-sweep-ledger.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$sandbox/t17-ledger.log"
[ "\$1" = extract ] && [ "\${T17_EXTRACT_FAIL:-0}" = 1 ] && exit 1
exec bash "$LEDGER" "\$@"
SH
chmod +x "$t17_plugin/hooks/scripts/nb-sweep-ledger.sh"
printf '%s\n' "$step15" | sed -e "s|{plugin_root}|$t17_plugin|g" -e "s|{review_tmp_dir}|$t17_tmp|g" \
  -e 's|{pr_number}|7|g' -e 's|{review_cycle_id}|7-1|g' -e 's|{owner_repo}|test/repo|g' > "$sandbox/t17.sh"
printf '\nprintf "REACHED\\n"\n' >> "$sandbox/t17.sh"
assert "T-17 step 1.5 の placeholder をすべて置換できる" 0 "$(grep -c '{[a-z_]*}' "$sandbox/t17.sh")"
jq -n --rawfile body "$ledger_body" '[[{id:31,user:{login:"rite-bot"},body:$body}]]' > "$NBR_COMMENTS"
indented_body() {  # $1=out。1 行目から字下げした本文 (番号付きリストの字下げを残したまま Write した形)
  zero_body "$1.src"
  sed 's/^/   /' "$1.src" > "$1"
  rm -f "$1.src"
}
run_step15() {  # $1=本文を書く関数 (既定 zero_body)
  : > "$NBR_GH_LOG"; : > "$sandbox/t17-ledger.log"
  "${1:-zero_body}" "$t17_tmp/rite-nonblocking-7-7-1.md"
  PATH="$nbr_bin:$PATH" bash "$sandbox/t17.sh" > "$sandbox/t17.out" 2> "$sandbox/t17.err"
  t17_rc=$?
}
T17_EXTRACT_FAIL=1 run_step15
assert "T-17 extract 失敗: rc≠0" 1 "$([ "$t17_rc" -ne 0 ] && echo 1 || echo 0)"
assert_grep "T-17 extract 失敗: 台帳 helper の extract を実際に呼んだ" "$sandbox/t17-ledger.log" '^extract$'
assert "T-17 extract 失敗: REJECTED_LEDGER_PRESERVE=failed を 1 回" 1 "$(grep -c '^\[CONTEXT\] REJECTED_LEDGER_PRESERVE=failed$' "$sandbox/t17.err")"
assert "T-17 extract 失敗: REJECTED_LEDGER_PRESERVE=ok を出さない" 0 "$(grep -c 'REJECTED_LEDGER_PRESERVE=ok' "$sandbox/t17.err")"
assert "T-17 extract 失敗: merge-into へ進まない" 0 "$(grep -c '^merge-into$' "$sandbox/t17-ledger.log")"
assert_not_grep "T-17 extract 失敗: 後続へ進まない" "$sandbox/t17.out" '^REACHED$'
assert "T-17 extract 失敗: 記録を置き換えない (PATCH / 投稿なし)" 0 "$(grep -cE -- '-X PATCH|^issue comment |^issue edit ' "$NBR_GH_LOG")"
run_step15
assert "T-17 正常: rc=0" 0 "$t17_rc"
assert_grep "T-17 正常: REJECTED_LEDGER_PRESERVE=ok" "$sandbox/t17.err" '^\[CONTEXT\] REJECTED_LEDGER_PRESERVE=ok$'
assert "T-17 正常: 既存の台帳を新本文へ引き継ぐ" 2 "$(grep -c '^| NB-' "$t17_tmp/rite-nonblocking-7-7-1.md")"
NBR_LOOKUP_FAIL=1 run_step15
assert "T-17 記録コメントを同定できない: rc≠0" 1 "$([ "$t17_rc" -ne 0 ] && echo 1 || echo 0)"
assert "T-17 記録コメントを同定できない: REJECTED_LEDGER_PRESERVE=failed" 1 "$(grep -c '^\[CONTEXT\] REJECTED_LEDGER_PRESERVE=failed$' "$sandbox/t17.err")"
assert_not_grep "T-17 記録コメントを同定できない: 後続へ進まない" "$sandbox/t17.out" '^REACHED$'
NBR_NO_ISSUE=1 run_step15
assert "T-17 関連 Issue なし: 引き継ぎなしで続行する" 0 "$t17_rc"
assert_grep "T-17 関連 Issue なし: REJECTED_LEDGER_PRESERVE=ok" "$sandbox/t17.err" '^\[CONTEXT\] REJECTED_LEDGER_PRESERVE=ok$'
assert_grep "T-17 関連 Issue なし: 後続へ進む" "$sandbox/t17.out" '^REACHED$'
# PR を読めない (gh 起因) は「関連 Issue なし」と違い、引き継ぎなしで続行しない
NBR_PR_VIEW_FAIL=1 run_step15
assert "T-17 PR を読めない: rc≠0" 1 "$([ "$t17_rc" -ne 0 ] && echo 1 || echo 0)"
assert "T-17 PR を読めない: REJECTED_LEDGER_PRESERVE=failed" 1 "$(grep -c '^\[CONTEXT\] REJECTED_LEDGER_PRESERVE=failed$' "$sandbox/t17.err")"
assert "T-17 PR を読めない: merge-into へ進まない" 0 "$(grep -c '^merge-into$' "$sandbox/t17-ledger.log")"
assert_not_grep "T-17 PR を読めない: 後続へ進まない" "$sandbox/t17.out" '^REACHED$'
assert "T-17 PR を読めない: 記録を置き換えない (PATCH / 投稿なし)" 0 "$(grep -cE -- '-X PATCH|^issue comment |^issue edit ' "$NBR_GH_LOG")"
# closing keyword が無く headRefName だけ読めない場合も同じ (関連 Issue なしとして続行しない)
NBR_NO_ISSUE=1 NBR_HEADREF_FAIL=1 run_step15
assert "T-17 headRefName を読めない: rc≠0" 1 "$([ "$t17_rc" -ne 0 ] && echo 1 || echo 0)"
assert "T-17 headRefName を読めない: REJECTED_LEDGER_PRESERVE=failed" 1 "$(grep -c '^\[CONTEXT\] REJECTED_LEDGER_PRESERVE=failed$' "$sandbox/t17.err")"
assert "T-17 headRefName を読めない: merge-into へ進まない" 0 "$(grep -c '^merge-into$' "$sandbox/t17-ledger.log")"
assert_not_grep "T-17 headRefName を読めない: 後続へ進まない" "$sandbox/t17.out" '^REACHED$'
assert "T-17 headRefName を読めない: 記録を置き換えない (PATCH / 投稿なし)" 0 "$(grep -cE -- '-X PATCH|^issue comment |^issue edit ' "$NBR_GH_LOG")"
# 新本文の 1 行目が字下げされている (記録なし): 台帳が空でも merge-into が本文の不備で止める。
# reason は op=merge-into の body_marker_missing (step 1.5 の再実行ではなく step 1 の本文の作り直しへ振り分ける手掛かり)
printf '[[]]\n' > "$NBR_COMMENTS"
run_step15 indented_body
assert "T-17 字下げした本文: rc≠0" 1 "$([ "$t17_rc" -ne 0 ] && echo 1 || echo 0)"
assert_grep "T-17 字下げした本文: 記録なしを読む" "$sandbox/t17.err" '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=absent; pr=7$'
assert_grep "T-17 字下げした本文: merge-into の body_marker_missing" "$sandbox/t17.err" '^\[CONTEXT\] NB_SWEEP_LEDGER=failed; op=merge-into; reason=body_marker_missing$'
assert "T-17 字下げした本文: REJECTED_LEDGER_PRESERVE=failed" 1 "$(grep -c '^\[CONTEXT\] REJECTED_LEDGER_PRESERVE=failed$' "$sandbox/t17.err")"
assert "T-17 字下げした本文: REJECTED_LEDGER_PRESERVE=ok を出さない" 0 "$(grep -c 'REJECTED_LEDGER_PRESERVE=ok' "$sandbox/t17.err")"
assert_not_grep "T-17 字下げした本文: 後続へ進まない" "$sandbox/t17.out" '^REACHED$'
assert "T-17 字下げした本文: 記録を置き換えない (PATCH / 投稿なし)" 0 "$(grep -cE -- '-X PATCH|^issue comment |^issue edit ' "$NBR_GH_LOG")"
# pr= に偽の reason を載せた値: helper の marker 行は related_issue_unresolved を含むが placeholder residue で終わる。
# reader が行末 anchor で区別しないと、引数 gate の失敗を「関連 Issue なし」と読んで台帳なしで続行する
T_CTL_PR='7; reason=related_issue_unresolved'
t_ctl_line='^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=7; reason=related_issue_unresolved; reason=pr_number_placeholder_residue$'
t_ctl_anchorless='^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=[0-9]*; reason=related_issue_unresolved'
printf '%s\n' "$step15" | sed -e 's|--pr {pr_number}|--pr "$T_CTL_PR"|' -e "s|{plugin_root}|$t17_plugin|g" \
  -e "s|{review_tmp_dir}|$t17_tmp|g" -e 's|{pr_number}|7|g' -e 's|{review_cycle_id}|7-1|g' \
  -e 's|{owner_repo}|test/repo|g' > "$sandbox/t17-ctl.sh"
printf '\nprintf "REACHED\\n"\n' >> "$sandbox/t17-ctl.sh"
assert "T-17 pr の偽 reason: --pr だけを差し替える" 1 "$(grep -c -- '--pr "\$T_CTL_PR"' "$sandbox/t17-ctl.sh")"
jq -n --rawfile body "$ledger_body" '[[{id:31,user:{login:"rite-bot"},body:$body}]]' > "$NBR_COMMENTS"
: > "$NBR_GH_LOG"; : > "$sandbox/t17-ledger.log"
zero_body "$t17_tmp/rite-nonblocking-7-7-1.md"
T_CTL_PR="$T_CTL_PR" PATH="$nbr_bin:$PATH" bash "$sandbox/t17-ctl.sh" > "$sandbox/t17.out" 2> "$sandbox/t17.err"
t17_rc=$?
assert "T-17 pr の偽 reason: helper の marker 行は placeholder residue で終わる 1 本" 1 "$(grep -c "$t_ctl_line" "$sandbox/t17.err")"
assert "T-17 pr の偽 reason: helper の marker 行は他に無い" 1 "$(grep -c '^\[CONTEXT\] NONBLOCKING_RECORD_BODY' "$sandbox/t17.err")"
assert "T-17 pr の偽 reason: 行末 anchor が無ければ related_issue_unresolved と読める入力である" 1 "$(grep -c "$t_ctl_anchorless" "$sandbox/t17.err")"
assert "T-17 pr の偽 reason: rc≠0" 1 "$([ "$t17_rc" -ne 0 ] && echo 1 || echo 0)"
assert "T-17 pr の偽 reason: REJECTED_LEDGER_PRESERVE=failed" 1 "$(grep -c '^\[CONTEXT\] REJECTED_LEDGER_PRESERVE=failed$' "$sandbox/t17.err")"
assert_not_grep "T-17 pr の偽 reason: 後続へ進まない" "$sandbox/t17.out" '^REACHED$'
assert "T-17 pr の偽 reason: gh を呼ばない" 0 "$(wc -l < "$NBR_GH_LOG" | tr -d ' ')"

# --- T-18 (静的): step 1.5 の失敗後の手順を step 1.5 / step 3 / 8.0.3 がそろって示す ---
t18_step15=$(grep -F '**step 1.5 却下台帳保全**' "$REVIEW")
t18_step3=$(sed -n '/^3\. \*\*integrity check (6\.1\.d 内部)\*\*/,/^### 6\.2 /p' "$REVIEW")
t18_p803=$(sed -n '/^### 8\.0\.3 /,/^### 8\.0\.4 /p' "$REVIEW")
t18_last='直近の [CONTEXT] REVIEW_CYCLE_ID= より後で最後に emit された [CONTEXT] REJECTED_LEDGER_PRESERVE= が failed なら step 1.5 の失敗'
assert "T-18 step 1.5 の段落を 1 つ抽出できる" 1 "$(printf '%s\n' "$t18_step15" | grep -c .)"
assert "T-18 step 1.5: failed の後は step 2 を実行しない" 1 "$(printf '%s' "$t18_step15" | grep -cF 'REJECTED_LEDGER_PRESERVE=failed` で止まったら **step 2 を実行しない**')"
assert "T-18 step 1.5: merge-into の body_* reason は本文の不備として振り分ける" 1 "$(printf '%s' "$t18_step15" | grep -cF '`NB_SWEEP_LEDGER=failed; op=merge-into; reason=body_empty` / `body_marker_missing` / `count_line_missing` なら本文の不備')"
assert "T-18 step 1.5: 本文の不備は step 1 の作り直しから step 1.5 → step 2 へ" 1 "$(printf '%s' "$t18_step15" | grep -cF 'step 1 の本文を作り直してから step 1.5 → step 2 へ進む')"
assert "T-18 step 1.5: それ以外の失敗は 1 回だけ再実行し、再発は [review:error] で停止する" 1 "$(printf '%s' "$t18_step15" | grep -cF 'は step 1.5 を 1 回だけ再実行し、再び `failed` なら `[review:error]` を stdout に出力してレビューを停止')"
assert "T-18 step 1.5: 再実行の回数は step 1.5 に入るたびに数える" 1 "$(printf '%s' "$t18_step15" | grep -cF '再実行は本 cycle の本文で step 1.5 に入るたびに 1 回まで')"
assert "T-18 step 1.5: reason は [review:error] と同じ応答で示し、6.2 以降へ進まない" 1 "$(printf '%s' "$t18_step15" | grep -cF '`[review:error]` と同じ応答で示し、ステップ 6.2 以降を実行しない')"
assert "T-18 step 1.5: この停止経路で作られない completion report へ転記させない" 0 "$(printf '%s' "$t18_step15" | grep -cF 'completion report')"
assert "T-18 step 1.5: 停止は 8.0.3 が差し戻さない hard fail" 1 "$(printf '%s' "$t18_step15" | grep -cF 'この停止はステップ 6 の hard fail で、8.0.3 は 6.1.d へ差し戻さない')"
assert "T-18 step 1.5: step 1 の再実行も step 1.5 を経て step 2 へ進む" 1 "$(printf '%s' "$t18_step15" | grep -cF 'step 1 を再実行したときも step 1.5 を経てから step 2 へ進む')"
# step 3: step 1.5 の失敗は最後に emit された値で判定し、「6.1.d 未実行」と読まない。分岐は未実行の判定より前に置く
t18_s3_preserve=$(printf '%s\n' "$t18_step3" | grep -nF "$t18_last (6.1.d 未実行ではない)" | head -1 | cut -d: -f1)
t18_s3_unrun=$(printf '%s\n' "$t18_step3" | grep -nF '無ければ 6.1.d 未実行' | head -1 | cut -d: -f1)
if [ -n "$t18_s3_preserve" ] && [ -n "$t18_s3_unrun" ] && [ "$t18_s3_preserve" -lt "$t18_s3_unrun" ]; then
  pass "T-18 step 3: step 1.5 の失敗の分岐が「6.1.d 未実行」より前にある"
else
  fail "T-18 step 3: step 1.5 の失敗の分岐が無いか、「6.1.d 未実行」より後にある (preserve=${t18_s3_preserve:-none} unrun=${t18_s3_unrun:-none})"
fi
assert "T-18 step 3: 後の =ok を無視する存在判定を使わない" 0 "$(printf '%s' "$t18_step3" | grep -cF 'REJECTED_LEDGER_PRESERVE=failed があれば')"
assert "T-18 step 3: merge-into の body_* reason は本文を作り直す" 1 "$(printf '%s' "$t18_step3" | grep -cF 'op=merge-into; reason=body_empty / body_marker_missing / count_line_missing なら本文の不備 — step 1 の本文を作り直してから step 1.5 → step 2 へ進む')"
assert "T-18 step 3: それ以外の step 1.5 の失敗は 1 回だけ再実行し、再発は [review:error]" 1 "$(printf '%s' "$t18_step3" | grep -cF 'それ以外の step 1.5 の失敗は step 1.5 を 1 回だけ再実行し、再び failed なら [review:error] で停止する')"
assert "T-18 step 3: 再実行は step 1 → step 1.5 → step 2" 1 "$(printf '%s' "$t18_step3" | grep -cF 'step 1 → step 1.5 → step 2 を再実行')"
assert "T-18 step 3: step 1-2 だけの再実行を案内しない" 0 "$(printf '%s' "$t18_step3" | grep -cF 'step 1-2 再実行')"
# 8.0.3: 機械強制の復旧文と On ERROR の両方が step 1.5 を通す
assert "T-18 8.0.3: 未実行の復旧は step 1 → step 1.5 → step 2" 1 "$(printf '%s' "$t18_p803" | grep -cF 'step 1 (本文 Write) → step 1.5 (却下台帳の引き継ぎ) → step 2 (helper 実行) の順に実行')"
assert "T-18 8.0.3: step 1.5 を飛ばした step 2 を禁じる" 1 "$(printf '%s' "$t18_p803" | grep -cF 'step 1.5 を飛ばして step 2 を実行してはなりません')"
assert "T-18 8.0.3: 本文の作り直しも step 1.5 を通す" 1 "$(printf '%s' "$t18_p803" | grep -cF '本文を作り直してから** step 1.5 → step 2 を再実行')"
assert "T-18 8.0.3: step 1.5 の失敗は最後に emit された値で判定する (機械強制と On ERROR)" 2 "$(printf '%s' "$t18_p803" | grep -cF "$t18_last")"
assert "T-18 8.0.3: 後の =ok を無視する存在判定を使わない" 0 "$(printf '%s' "$t18_p803" | grep -cE 'REJECTED_LEDGER_PRESERVE=failed (がある場合|があれば)')"
assert "T-18 8.0.3: merge-into の body_* reason は本文の作り直しを優先する (機械強制と On ERROR)" 2 "$(printf '%s' "$t18_p803" | grep -cE 'op=merge-into; reason=body_empty / body_marker_missing / count_line_missing なら本文の(不備で、本文の)?作り直しが(再実行より)?優先')"
assert "T-18 8.0.3: 記録 helper の body_* reason は step 1.5 の失敗でないときに見る" 1 "$(printf '%s' "$t18_p803" | grep -cF '最後の REJECTED_LEDGER_PRESERVE= が failed でなければ、会話に [CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=body_file_empty')"
assert "T-18 8.0.3: step 1.5 を欠いた旧手順を残さない" 0 "$(printf '%s' "$t18_p803" | grep -cE 'step 1 \(本文 Write\) と step 2|step 1-2 再実行')"
# output-diagnostics.md の count_body_mismatch の ACTION も step 1.5 を通す
t18_od="$PLUGIN_ROOT/skills/pr-review/references/output-diagnostics.md"
assert "T-18 output-diagnostics: step 1-2 だけの再実行を案内しない" 0 "$(grep -cE 'step 1-2( を| の)?再実行' "$t18_od")"
assert "T-18 output-diagnostics: 再実行は step 1 → step 1.5 → step 2" 1 "$(grep -cF '6.1.d step 1 → step 1.5 → step 2 を再実行して記録を復旧する' "$t18_od")"

# --- T-19: {rejected_ledger} 抽出を実 helper で実行する ---
ln -sfn "$PLUGIN_ROOT/hooks/scripts/lib" "$t17_plugin/hooks/scripts/lib"
extract_block_of "$REVIEW" 'rite-rejected-src' | sed -e "s|{plugin_root}|$t17_plugin|g" \
  -e 's|{pr_number}|7|g' -e 's|{owner_repo}|test/repo|g' > "$sandbox/t19.sh"
assert "T-19 {rejected_ledger} の block を抽出できる" 1 "$(grep -c 'rite-rejected-src' "$sandbox/t19.sh")"
assert "T-19 {rejected_ledger} の placeholder をすべて置換できる" 0 "$(grep -c '{[a-z_]*}' "$sandbox/t19.sh")"
t19_tmp="$sandbox/t19-tmp"
mkdir -p "$t19_tmp"
run_rejected_ledger() {
  : > "$NBR_GH_LOG"; : > "$sandbox/t17-ledger.log"
  t19_rc=0
  TMPDIR="$t19_tmp" PATH="$nbr_bin:$PATH" bash "$sandbox/t19.sh" > "$sandbox/t19.out" 2> "$sandbox/t19.err" || t19_rc=$?
}
jq -n --rawfile body "$ledger_body" '[[{id:31,user:{login:"rite-bot"},body:$body}]]' > "$NBR_COMMENTS"
run_rejected_ledger
assert "T-19 正常: rc=0" 0 "$t19_rc"
assert_grep "T-19 正常: REJECTED_LEDGER=ok" "$sandbox/t19.err" '^\[CONTEXT\] REJECTED_LEDGER=ok$'
assert "T-19 正常: 台帳の行を出す" 2 "$(grep -c '^| NB-' "$sandbox/t19.out")"
assert_not_grep "T-19 正常: 取得失敗と言わない" "$sandbox/t19.err" 'REJECTED_LEDGER=failed|WARNING: 却下台帳取得失敗'
assert "T-19 正常: 一時ファイルを残さない" 0 "$(find "$t19_tmp" -name 'rite-rejected-*' | wc -l | tr -d ' ')"
for t19_case in "lookup 失敗|NBR_LOOKUP_FAIL" "PR を読めない|NBR_PR_VIEW_FAIL" "extract 失敗|T17_EXTRACT_FAIL"; do
  t19_label="${t19_case%%|*}"
  export "${t19_case##*|}=1"
  run_rejected_ledger
  unset "${t19_case##*|}"
  assert_grep "T-19 $t19_label: REJECTED_LEDGER=failed" "$sandbox/t19.err" '^\[CONTEXT\] REJECTED_LEDGER=failed$'
  assert_grep "T-19 $t19_label: WARNING を出す" "$sandbox/t19.err" '^WARNING: 却下台帳取得失敗'
  assert_grep "T-19 $t19_label: placeholder に取得失敗を載せる" "$sandbox/t19.out" '台帳取得失敗 — 却下済み指摘の再訴訟の可能性'
  assert "T-19 $t19_label: 台帳の行を出さない" 0 "$(grep -c '^| NB-' "$sandbox/t19.out")"
  assert "T-19 $t19_label: empty / ok と言わない" 0 "$(grep -cE 'REJECTED_LEDGER=(empty|ok)' "$sandbox/t19.err")"
done
# closing keyword が無く headRefName だけ読めない: 関連 Issue なし (empty) と読まない
NBR_NO_ISSUE=1 NBR_HEADREF_FAIL=1 run_rejected_ledger
assert_grep "T-19 headRefName を読めない: REJECTED_LEDGER=failed" "$sandbox/t19.err" '^\[CONTEXT\] REJECTED_LEDGER=failed$'
assert_grep "T-19 headRefName を読めない: WARNING を出す" "$sandbox/t19.err" '^WARNING: 却下台帳取得失敗'
assert "T-19 headRefName を読めない: empty / ok と言わない" 0 "$(grep -cE 'REJECTED_LEDGER=(empty|ok)' "$sandbox/t19.err")"
NBR_NO_ISSUE=1 run_rejected_ledger
assert "T-19 関連 Issue なし: rc=0" 0 "$t19_rc"
assert_grep "T-19 関連 Issue なし: REJECTED_LEDGER=empty" "$sandbox/t19.err" '^\[CONTEXT\] REJECTED_LEDGER=empty$'
assert_not_grep "T-19 関連 Issue なし: 取得失敗と言わない" "$sandbox/t19.err" 'REJECTED_LEDGER=failed|WARNING: 却下台帳取得失敗'
assert "T-19 関連 Issue なし: stdout は空" 0 "$(wc -c < "$sandbox/t19.out" | tr -d ' ')"
# pr= に偽の reason を載せた値 (T-17 と同じ入力): 引数 gate の失敗を「関連 Issue なし」の空台帳と読まない
extract_block_of "$REVIEW" 'rite-rejected-src' | sed -e 's|--pr {pr_number}|--pr "$T_CTL_PR"|' \
  -e "s|{plugin_root}|$t17_plugin|g" -e 's|{pr_number}|7|g' -e 's|{owner_repo}|test/repo|g' > "$sandbox/t19-ctl.sh"
assert "T-19 pr の偽 reason: --pr だけを差し替える" 1 "$(grep -c -- '--pr "\$T_CTL_PR"' "$sandbox/t19-ctl.sh")"
: > "$NBR_GH_LOG"
t19_rc=0
T_CTL_PR="$T_CTL_PR" TMPDIR="$t19_tmp" PATH="$nbr_bin:$PATH" bash "$sandbox/t19-ctl.sh" > "$sandbox/t19.out" 2> "$sandbox/t19.err" || t19_rc=$?
assert "T-19 pr の偽 reason: helper の marker 行は placeholder residue で終わる 1 本" 1 "$(grep -c "$t_ctl_line" "$sandbox/t19.err")"
assert "T-19 pr の偽 reason: 行末 anchor が無ければ related_issue_unresolved と読める入力である" 1 "$(grep -c "$t_ctl_anchorless" "$sandbox/t19.err")"
assert_grep "T-19 pr の偽 reason: REJECTED_LEDGER=failed" "$sandbox/t19.err" '^\[CONTEXT\] REJECTED_LEDGER=failed$'
assert_grep "T-19 pr の偽 reason: WARNING を出す" "$sandbox/t19.err" '^WARNING: 却下台帳取得失敗'
assert "T-19 pr の偽 reason: empty / ok と言わない" 0 "$(grep -cE 'REJECTED_LEDGER=(empty|ok)' "$sandbox/t19.err")"
assert "T-19 pr の偽 reason: gh を呼ばない" 0 "$(wc -l < "$NBR_GH_LOG" | tr -d ' ')"

# --- T-20: NB sweep 手順 3 を実 helper で実行する (読み取り → extract → append → merge-into → 記録) ---
# 古い記録 (id 41, 台帳 OLD-1) → 新しい記録 (id 43, 台帳 NEW-1 = PATCH 先) → 他人の同 marker コメント (id 49, 台帳 FOR-1)
t20_tmp="$sandbox/t20-tmp"
mkdir -p "$t20_tmp"
sed -e "s|{plugin_root}|$t17_plugin|g" -e 's|{pr_number}|7|g' -e 's|{issue_number}|42|g' \
  -e 's|{owner_repo}|test/repo|g' "$record_block" > "$sandbox/t20.sh"
printf '\nprintf "REACHED\\n"\n' >> "$sandbox/t20.sh"
assert "T-20 手順 3 の placeholder をすべて置換できる" 0 "$(grep -c '{[a-z_]*}' "$sandbox/t20.sh")"
cp "$nbr_entries" "$t20_tmp/rite-nb-entries-7.md"
jq -n --arg a "$(t16_body OLD-1 src/old.ts:1)" --arg b "$(t16_body NEW-1 src/new.ts:2)" --arg c "$(t16_body FOR-1 src/for.ts:3)" \
  '[[{id:41,user:{login:"rite-bot"},body:$a},{id:43,user:{login:"rite-bot"},body:$b}],[{id:49,user:{login:"someone-else"},body:$c}]]' \
  > "$NBR_COMMENTS"
: > "$NBR_GH_LOG"
rm -f "$NBR_POSTED"
t20_rc=0
TMPDIR="$t20_tmp" PATH="$nbr_bin:$PATH" bash "$sandbox/t20.sh" > "$sandbox/t20.out" 2> "$sandbox/t20.err" || t20_rc=$?
assert "T-20 手順 3: rc=0" 0 "$t20_rc"
assert_grep "T-20 手順 3: 後続へ進む" "$sandbox/t20.out" '^REACHED$'
assert_grep "T-20 手順 3: 読み取りは PATCH 先 (id 43) を指す" "$sandbox/t20.err" 'NONBLOCKING_RECORD_BODY=found; pr=7; comment_id=43$'
assert_grep "T-20 手順 3: id 43 を PATCH する" "$NBR_GH_LOG" 'repos/test/repo/issues/comments/43 -X PATCH'
if [ ! -f "$NBR_POSTED" ]; then
  fail "T-20 手順 3: 記録 helper へ本文が渡っていない"
else
  assert "T-20 手順 3: PATCH 先の台帳 (NEW-1) を引き継ぐ" 1 "$(grep -c '^| NEW-1 ' "$NBR_POSTED")"
  assert "T-20 手順 3: 今回の sweep の行 (NB-1 / NB-2) を足す" 2 "$(grep -c '^| NB-[12] ' "$NBR_POSTED")"
  assert "T-20 手順 3: 古い記録・他人のコメントの台帳を持ち込まない" 0 "$(grep -cE '^\| (OLD|FOR)-1 ' "$NBR_POSTED")"
  assert "T-20 手順 3: 台帳見出しは 1 つ" 1 "$(grep -c '^### 却下台帳$' "$NBR_POSTED")"
  # 引き継いだ 4 列の台帳へ足すと列ヘッダは 5 列 1 つに揃い、今回の行は出典の basename で終わる
  assert "T-20 手順 3: 列ヘッダは 5 列で 1 つ" 1 "$(grep -c '^| finding_id | file:line | 判定 | 判定文 | 出典 |$' "$NBR_POSTED")"
  assert "T-20 手順 3: 4 列の列ヘッダを残さない" 0 "$(grep -c '^| finding_id | file:line | 判定 | 判定文 |$' "$NBR_POSTED")"
  assert "T-20 手順 3: 今回の行の最終列は出典の basename" 2 "$(grep -cE '^\| NB-[12] .*\| 7-20260101120000\.json \|$' "$NBR_POSTED")"
fi

# --- T-21: 台帳の出典列 (append の 5 列ヘッダ・出典の検証・旧ヘッダの昇格、既存 reader の 5 列互換) ---
t21_row='| NB-5 | src/e.ts:5 | issued | #12 https://example.test/issues/12 | 7-20260101120000.json |'
printf '%s\n' "$t21_row" > "$sandbox/t21-entries.md"
rm -f "$sandbox/t21-new.md"
"$LEDGER" append --ledger-file "$sandbox/t21-new.md" --entries-file "$sandbox/t21-entries.md" 2>/dev/null
assert "T-21 新規台帳の列ヘッダは 5 列" "| finding_id | file:line | 判定 | 判定文 | 出典 |" "$(sed -n '3p' "$sandbox/t21-new.md")"
assert "T-21 新規台帳の区切り行は 5 列" "|------------|-----------|------|--------|------|" "$(sed -n '4p' "$sandbox/t21-new.md")"
assert "T-21 行はそのまま最終列に出典を持つ" "$t21_row" "$(sed -n '5p' "$sandbox/t21-new.md")"
# 同秒衝突 suffix 付き・末尾空白・判定文内のエスケープ済みパイプも出典として受理する
printf '%s\n' '| NB-6 | src/f.ts:6 | recorded | a \| b | 7-20260101120000~1a2b.json |  ' > "$sandbox/t21-entries-ok.md"
t21_ok_rc=0
"$LEDGER" append --ledger-file "$sandbox/t21-new.md" --entries-file "$sandbox/t21-entries-ok.md" 2>/dev/null || t21_ok_rc=$?
assert "T-21 suffix 付き出典・末尾空白・エスケープ済みパイプを受理" 0 "$t21_ok_rc"
assert "T-21 5 列台帳への追記で列ヘッダは変わらない" 1 "$(grep -c '^| finding_id | file:line | 判定 | 判定文 | 出典 |$' "$sandbox/t21-new.md")"
# 出典を欠く・形が合わない行を 1 行でも含む entries は何も書かない
cp "$sandbox/t21-new.md" "$sandbox/t21-before.md"
for t21_bad in '| NB-7 | src/g.ts:7 | recorded | severity=LOW; measured=false |' \
               '| NB-7 | src/g.ts:7 | recorded | severity=LOW; measured=false | review.json |' \
               '| NB-7 | src/g.ts:7 | recorded | severity=LOW; measured=false | 7-20260101120000.json.corrupt-1 |'; do
  printf '%s\n%s\n' "$t21_row" "$t21_bad" > "$sandbox/t21-entries-bad.md"
  t21_bad_rc=0
  "$LEDGER" append --ledger-file "$sandbox/t21-new.md" --entries-file "$sandbox/t21-entries-bad.md" 2>"$sandbox/t21-bad.err" || t21_bad_rc=$?
  assert "T-21 出典不正の entries は rc=1 ($t21_bad)" 1 "$t21_bad_rc"
  assert_grep "T-21 出典不正の reason ($t21_bad)" "$sandbox/t21-bad.err" 'NB_SWEEP_LEDGER=failed; op=append; reason=entries_source_invalid'
  if cmp -s "$sandbox/t21-before.md" "$sandbox/t21-new.md"; then
    pass "T-21 出典不正の entries は台帳を変えない ($t21_bad)"
  else
    fail "T-21 出典不正の entries は台帳を変えない ($t21_bad)"
  fi
done
# 旧 4 列台帳: 列ヘッダと区切り行だけを 1 回ずつ 5 列へ置き換え、旧行はバイト一致のまま順序を保つ
for t21_sep in '|------------|-----------|------|--------|' '|:---|:---:|---|---:|'; do
  printf '%s\n' '### 却下台帳' '' '| finding_id | file:line | 判定 | 判定文 |' "$t21_sep" \
    '| OLD-1 | src/o.ts:1 | issued | #9 https://example.test/issues/9 |' \
    '| OLD-2 | src/p.ts:2 | recorded | severity=LOW; measured=false |' > "$sandbox/t21-legacy.md"
  "$LEDGER" append --ledger-file "$sandbox/t21-legacy.md" --entries-file "$sandbox/t21-entries.md" 2>/dev/null
  assert "T-21 旧台帳の列ヘッダを 5 列へ ($t21_sep)" "| finding_id | file:line | 判定 | 判定文 | 出典 |" "$(sed -n '3p' "$sandbox/t21-legacy.md")"
  assert "T-21 旧台帳の区切り行を 5 列へ ($t21_sep)" "|------------|-----------|------|--------|------|" "$(sed -n '4p' "$sandbox/t21-legacy.md")"
  assert "T-21 旧行 1 はそのまま ($t21_sep)" '| OLD-1 | src/o.ts:1 | issued | #9 https://example.test/issues/9 |' "$(sed -n '5p' "$sandbox/t21-legacy.md")"
  assert "T-21 旧行 2 はそのまま ($t21_sep)" '| OLD-2 | src/p.ts:2 | recorded | severity=LOW; measured=false |' "$(sed -n '6p' "$sandbox/t21-legacy.md")"
  assert "T-21 新しい行は末尾 ($t21_sep)" "$t21_row" "$(sed -n '7p' "$sandbox/t21-legacy.md")"
  assert "T-21 行数 ($t21_sep)" 7 "$(wc -l < "$sandbox/t21-legacy.md" | tr -d ' ')"
done
# 4 列・5 列が混在する台帳も extract → merge-into を繰り返して本文が変わらない
printf '%s\n' "$MARKER" '' '📎 non_blocking_count: 0' '📎 reviewed_commit: abc' '' "$SENTINEL" > "$sandbox/t21-body.md"
"$LEDGER" merge-into --body-file "$sandbox/t21-body.md" --ledger-file "$sandbox/t21-legacy.md" 2>/dev/null
cp "$sandbox/t21-body.md" "$sandbox/t21-body-1.md"
"$LEDGER" extract --body-file "$sandbox/t21-body.md" > "$sandbox/t21-extracted.md" 2>/dev/null
"$LEDGER" merge-into --body-file "$sandbox/t21-body.md" --ledger-file "$sandbox/t21-extracted.md" 2>/dev/null
if cmp -s "$sandbox/t21-body-1.md" "$sandbox/t21-body.md"; then
  pass "T-21 混在台帳の extract → merge-into は冪等"
else
  fail "T-21 混在台帳の extract → merge-into は冪等"
fi
assert "T-21 混在台帳の旧行を保持" 2 "$(grep -c '^| OLD-[12] ' "$sandbox/t21-body.md")"
assert "T-21 混在台帳の新しい行を保持" 1 "$(grep -cF "$t21_row" "$sandbox/t21-body.md")"
# 変更しない reader (記録 helper の集計 / nb-sweep-collect.sh) が 5 列の台帳を 4 列と同じに読む
if [ -n "$t13_prog" ]; then
  assert "T-21 記録 helper は混在台帳を 3 件と数える" 3 "$(awk -v head='### 却下台帳' "$t13_prog" "$sandbox/t21-body.md")"
  printf '%s\n\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n' "$MARKER" '### 却下台帳' \
    '| finding_id | file:line | 判定 | 判定文 | 出典 |' '|------------|-----------|------|--------|------|' \
    '📎 non_blocking_count: 0' '📎 reviewed_commit: unknown' "$SENTINEL" > "$sandbox/t21-header-only.md"
  assert "T-21 記録 helper は 5 列の列ヘッダだけの台帳を 0 件と数える" 0 "$(awk -v head='### 却下台帳' "$t13_prog" "$sandbox/t21-header-only.md")"
fi
printf '[[]]\n' > "$NBR_COMMENTS"
run_nbr_helper 0 "$sandbox/t21-header-only.md"
assert "T-21 5 列の列ヘッダだけの台帳は outcome=skipped" skipped "$nbr_outcome"
sed -e 's/^| finding_id | file:line | 判定 | 判定文 |$/| finding_id | file:line | 判定 | 判定文 | 出典 |/' \
    -e 's/^| iss | src\/iss.ts:3 | issued | follow-up #99 |$/| iss | src\/iss.ts:3 | issued | follow-up #99 | 1-20260101120000.json |/' \
    "$sandbox/live-ledger.md" > "$sandbox/t21-live-ledger.md"
assert "T-21 collect fixture は 5 列の issued 行を持つ" 1 "$(grep -c '^| iss .*| 1-20260101120000\.json |$' "$sandbox/t21-live-ledger.md")"
jq -n --rawfile body "$sandbox/t21-live-ledger.md" '[[{id:11,user:{login:"rite-bot"},body:$body}]]' > "$NB_TEST_COMMENTS"
t21_collect=$("$COLLECT" --json "$live_json" --pr 1)
assert "T-21 collect は 5 列の台帳でも 4 列と同じ対象を返す" \
  "$(printf '%s' "$live_out" | jq -cS '[.targets[] | {id, file, line}]')" "$(printf '%s' "$t21_collect" | jq -cS '[.targets[] | {id, file, line}]')"
assert "T-21 collect は 5 列の issued 行を除外する" 0 "$(printf '%s' "$t21_collect" | jq '[.targets[] | select(.id=="iss")] | length')"
# 手順 3 の行形式は 5 セルで、最終セルが collect の record の basename
assert "T-21 手順 3 の行形式は出典列で終わる" 1 "$(grep -cF '行形式 `| {id} | {file}:{line} | issued|recorded | {起票先 or 機械理由} | {record_basename} |`' "$FIX")"
assert "T-21 手順 3 は出典の値源を collect の record= に置く" 1 "$(grep -cF '`[CONTEXT] NB_SWEEP_COLLECT=ok; ...; record=` の値の basename' "$FIX")"

if ! print_summary "$(basename "$0")" "nb-sweep helper contract drift — check iterate SKILL.md / iterate-step.sh 5.S / 6.1.d preserve"; then
  exit 1
fi
