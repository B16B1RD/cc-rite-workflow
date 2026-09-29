#!/bin/bash
# Contract tests for post-mergeable NB digest sweep helpers.
#
# T-01 collect NB targets (AC-1)
# T-02 ledger append with rationale (AC-2)
# T-03 merge-into preserves ledger across 6.1.d rewrite (AC-3)
# T-04 empty collect is no-op status (AC-4)
# T-05 nit-noted in findings[] is a target; new class-B is not a second sweep (AC-5)
# T-06 ledger write / merge fail-loud (AC-6)
# T-07 class A findings[] stay out of sweep targets (AC-7); the rails also pin the in-PR recommendation wiring (iterate check / mark and their order before the fix invoke, pr-review 7.2 registering the adoption verdict fix and its stop, fix 2.1 R-NN routing)
# T-08 body_count extraction expression matches between the fix-step.sh nb-sweep-persist step (called from fix/references/nb-sweep.md) and the record helper (AC-1..AC-3)
# T-09 a ledger-only body (0 findings, no existing comment) creates the record comment, including CRLF and degraded lookup
# T-10 nb-sweep.md record step (its fix-step.sh nb-sweep-persist call run through the dispatcher) succeeds only on created / updated and never reaches the done write otherwise
# T-11 a body without ledger entries keeps the no-op skip; count mismatch and uncountable ledger fail instead (the awk diagnostic surfaces with the awk: prefix above the awk-specific guidance, the pending marker is removed; an unknown _gh_err_detail label warns and falls back to the gh: prefix)
# T-12 an existing record comment is updated in place even when the body carries a ledger
# T-13 the record helper and nb-sweep-ledger.sh read the same ledger range (row counts agree on LF / CRLF / trailing-section bodies; extract and merge-into ignore a trailing CR, skip rows outside the section, splice before the count line; predicates pinned statically)
# T-14 extract → merge-into is idempotent: the first pass leaves one ledger section right before the count line with one blank line on each side, and the second pass is byte-identical; extract output never ends in a blank line; an in-place extract → merge-into leaves no consecutive blank lines
# T-15 --print-record-body: prints only the comment the write path would PATCH (CRLF → LF; durable id first); no record → empty stdout + absent; argument gates / resolution / lookup / body fetch / own login failures → rc=1, signal aborts → 128+n, each with a NONBLOCKING_RECORD_BODY=failed reason (pr_view_failed is never folded into related_issue_unresolved, including a headRefName read failure; a control character in pr= never forges a second marker line); never writes, never emits the terminal sentinel or NONBLOCKING_RECORD_FAILED, never touches pending markers
# T-16 with two record comments, collect excludes only the ledger of the comment the helper PATCHes; the four readers (two pr-review-step.sh steps, the two fix-step.sh steps the fix references call) read through --print-record-body once per site and never prefix-match the record heading
# T-17 6.1.d step 1.5 stops before the record helper when extract fails, the PR or its headRefName cannot be read, or the new body's first line is indented (merge-into body_marker_missing) (REJECTED_LEDGER_PRESERVE=failed, nothing written); an unresolvable related Issue continues with no ledger, but a pr= value carrying a forged reason=related_issue_unresolved does not (the helper's argument check stops it with exit 2 before any reader runs)
# T-18 step 1.5 / step 3 / 8.0.3 agree on what follows REJECTED_LEDGER_PRESERVE=failed (judged by the last emitted value): no step 2; a merge-into body_* reason rewrites the body in step 1; any other failure re-runs step 1.5 once, then [review:error] shown in the same response; every re-run goes step 1 → step 1.5 → step 2 (output-diagnostics.md included)
# T-19 the {rejected_ledger} call line run with the real helpers: ok prints the rows; lookup / PR read / headRefName read / extract failures → REJECTED_LEDGER=failed + WARNING; an unresolvable related Issue → empty, but a pr= value carrying a forged reason=related_issue_unresolved stops at the helper's argument check (exit 2, never empty)
# T-20 nb-sweep.md step 3 run with the real helper for both the read and the write: the PATCHed body carries the PATCH target's ledger plus this sweep's rows, and never an older record's or another author's ledger; the carried 4-column header becomes one 5-column header and this sweep's rows end with the source basename
# T-21 ledger source column: append writes a 5-column header, accepts only rows ending with a review JSON basename (suffix / trailing blanks / escaped pipes ok; otherwise entries_source_invalid with the ledger untouched), upgrades a 4-column header and separator once while keeping old rows byte-identical and in order; mixed ledgers survive extract → merge-into unchanged; the record helper count, header-only skip and collect exclusion read 5-column ledgers like 4-column ones; nb-sweep.md step 3 names the source column and its value source
# T-22 entries whose invalid rows exceed the pipe buffer still stop with rc=1, print the first three invalid rows in order and end stderr with exactly one reason=entries_source_invalid; the ledger is untouched
# T-23 after a failed ledger append, nb-sweep.md step 3 says to check every entries row, re-run only step 3 (not the step 2 issuance) and continue from the iterate 5.S sweep-done row after step 4 instead of re-running iterate, and both places limit that continuation to the conversation that stopped and forbid it even there when either `{sweep_origin}` or the `NB_SWEEP_RESULT` count cannot be read from the conversation; step 2 separates that re-run from a fresh sweep; iterate 5.S points any post-issuance persist stop there without narrowing by reason name; and the schema rejects the whole entries when any row is invalid
# T-24 the ledger as the sweep reads it after the adoption gate: an issued row excludes its target from any source, a REJECT / RESOLVED / LINK row only when its 出典 is the review JSON read now, legacy recorded / rejected rows never; the last REJECT / ADOPT row becomes the target's prior (premise = 判定文, escaped pipes kept) and matches the adoption helper's ledger row; an id-less target is matched by its anon key; tally counts REJECT / RESOLVED / LINK / recorded as recorded
# T-25 iterate 5.S tells how to resume a held sweep; nb-sweep.md step 2 stops before filing on a held gate and writes the filed number back as the record's tracker
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

# --- collect never decides adoption: severity and measurement change neither the output keys nor the targets ---
route_json="$sandbox/routes.json"
jq -n '{non_blocking_findings: [
  {id:"M-true",severity:"MEDIUM",verification:{measured:true,detail:"observed"}},
  {id:"M-false",severity:"MEDIUM",verification:{measured:false}},
  {id:"M-missing",severity:"MEDIUM"},
  {id:"L-true",severity:"LOW",verification:{measured:true}},
  {id:"H-true",severity:"HIGH",verification:{measured:true}},
  {id:"N-true",severity:"MEDIUM",scope:"nit-noted",verification:{measured:true}},
  {id:"",severity:"LOW",file:"src/anon.ts",line:4}
], findings:[{id:"nit",severity:"MEDIUM",scope:"nit-noted",verification:{measured:true}}]}' > "$route_json"
route_out=$("$COLLECT" --json "$route_json")
assert "collect output has no route (adoption is the gate's)" 0 "$(printf '%s' "$route_out" | jq '[.. | objects | select(has("route"))] | length')"
assert "every target is collected regardless of severity / measured" 8 "$(printf '%s' "$route_out" | jq '.targets | length')"
assert "verification evidence preserved" "observed" "$(printf '%s' "$route_out" | jq -r '.targets[] | select(.id=="M-true") | .verification.detail')"
assert "key is the id" "M-true" "$(printf '%s' "$route_out" | jq -r '.targets[] | select(.id=="M-true") | .key')"
assert "key of an id-less target is anon:<file>:<line>" "anon:src/anon.ts:4" "$(printf '%s' "$route_out" | jq -r '.targets[] | select(.id=="") | .key')"
# 重要度と実測だけを変えた同じ指摘は、重要度・実測以外の出力が変わらない
route_flip="$sandbox/routes-flip.json"
jq '.non_blocking_findings |= map(.severity = (if .severity == "MEDIUM" then "LOW" else "MEDIUM" end) | .verification = {measured: false})
    | .findings |= map(.severity = "HIGH" | .verification = {measured: false})' "$route_json" > "$route_flip"
flip_out=$("$COLLECT" --json "$route_flip")
assert "flipping severity / measured leaves the targets and keys unchanged" \
  "$(printf '%s' "$route_out" | jq -c '[.targets[] | del(.severity, .verification)]')" \
  "$(printf '%s' "$flip_out" | jq -c '[.targets[] | del(.severity, .verification)]')"

# Guardrail-only must not be mistaken for a completed/no-op sweep.
guard_json="$sandbox/guard.json"
jq '{guardrail_audit_log}' "$mix_json" > "$guard_json"
guard_out=$("$COLLECT" --json "$guard_json")
assert "guardrail-only status ok" "ok" "$(printf '%s' "$guard_out" | jq -r '.status')"
assert "guardrail-only count 1" "1" "$(printf '%s' "$guard_out" | jq -r '.count')"
assert "guardrail carries no route" "false" "$(printf '%s' "$guard_out" | jq -r '.already_rejected[0] | has("route")')"
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
assert "only the issued row excludes a target; legacy rejected / recorded rows do not (id collision retained)" "collision,old,rec" "$(printf '%s' "$live_out" | jq -r '[.targets[].id] | sort | join(",")')"
assert "legacy rows keep their target at the same location" "src/old.ts" "$(printf '%s' "$live_out" | jq -r '.targets[] | select(.id=="old") | .file')"
assert "legacy rows give no prior" 0 "$(printf '%s' "$live_out" | jq '[.targets[] | select(has("prior"))] | length')"
assert "guardrail ledger excluded" "0" "$(printf '%s' "$live_out" | jq '.already_rejected | length')"
assert "candidates are the targets with id=key, finding_id and the record of the JSON read" \
  "$(printf '%s' "$live_out" | jq -c '[.targets[] | . + {finding_id: .id, id: .key, record: "live.json"}]')" \
  "$(printf '%s' "$live_out" | jq -c '.candidates')"

# A sweep hold saved on another review JSON is carried into candidates on the JSON read now:
# its candidates keep the record they came from (nit-noted ones included) under the id <record>#<key>.
carry_root="$sandbox/carry"
mkdir -p "$carry_root/.rite/state"
carry_hold="$carry_root/.rite/state/adoption-hold-1-sweep.json"
printf '%s' "$live_out" | jq '{kind: "sweep", pr: 1, head: "aaaa", review_result: "/x/1-old.json", reason: "undecided",
  detail: "", held_ids: ["old"],
  candidates: ([.candidates[] | select(.id == "old")]
    + [{id: "rec", key: "rec", finding_id: "rec", source: "findings_nit_noted", file: "src/nit.ts", line: 5,
        severity: "LOW", scope: "nit-noted", description: "nit", suggestion: "", verification: null, record: "1-old.json"}]),
  resume: "r"}' > "$carry_hold"
carry_out=$("$COLLECT" --json "$live_json" --pr 1 --state-root "$carry_root")
assert "carry: a held candidate the targets still have is not duplicated" 1 \
  "$(printf '%s' "$carry_out" | jq '[.candidates[] | select(.file == "src/old.ts")] | length')"
assert "carry: a held nit-noted candidate the targets lack is carried with its own record" "1-old.json#rec|1-old.json|findings_nit_noted" \
  "$(printf '%s' "$carry_out" | jq -r '.candidates[] | select(.file == "src/nit.ts") | "\(.id)|\(.record)|\(.source)"')"
assert "carry: count includes the carried candidate" "$(( $(printf '%s' "$live_out" | jq '.count') + 1 ))" "$(printf '%s' "$carry_out" | jq '.count')"
assert "carry: targets are unchanged" "$(printf '%s' "$live_out" | jq -c '.targets')" "$(printf '%s' "$carry_out" | jq -c '.targets')"
empty_json="$sandbox/empty-review.json"
printf '{"non_blocking_findings": []}\n' > "$empty_json"
carry_empty=$("$COLLECT" --json "$empty_json" --pr 1 --state-root "$carry_root")
assert "carry: a hold makes a review JSON with no target ok, not empty" "ok|2" \
  "$(printf '%s' "$carry_empty" | jq -r '"\(.status)|\(.candidates | length)"')"
# The carried id is <record>#<key>: a hold that already carries candidates of two earlier JSONs next
# to a target of the same F-01 keeps every id unique, and carrying it again gives the same ids.
jq -n '{kind: "sweep", pr: 1, head: "b", review_result: "/x/1-b.json", reason: "undecided", detail: "", held_ids: [],
  resume: "r", candidates: [
    {id: "rec", key: "rec", finding_id: "rec", file: "src/b.ts", line: 1, description: "b", record: "1-b.json"},
    {id: "1-a.json#rec", key: "rec", finding_id: "rec", file: "src/a.ts", line: 1, description: "a", record: "1-a.json"}]}' \
  > "$carry_hold"
chain_out=$("$COLLECT" --json "$live_json" --pr 1 --state-root "$carry_root")
assert "carry: ids stay unique across chained holds" "true" \
  "$(printf '%s' "$chain_out" | jq '[.candidates[].id] | length == (unique | length)')"
assert "carry: chained carried ids are <record>#<key>" "1-a.json#rec,1-b.json#rec" \
  "$(printf '%s' "$chain_out" | jq -r '[.candidates[] | select(.id | contains("#")) | .id] | sort | join(",")')"
printf '{"candidates": [{"id": "x", "key": "x"}]}\n' > "$carry_hold"
"$COLLECT" --json "$live_json" --pr 1 --state-root "$carry_root" > /dev/null 2> "$sandbox/carry-bad.err"
assert "carry: a hold without the candidates' record stops the collect" 1 "$?"
assert_grep "carry: the unreadable hold is named" "$sandbox/carry-bad.err" 'reason=hold_unreadable'
assert_grep "carry: the unreadable hold's path is printed" "$sandbox/carry-bad.err" 'adoption-hold-1-sweep.json'

# CRLF body: the ledger section must be read exactly as the LF body (same targets, same section boundary).
crlf_ledger_body="$sandbox/live-ledger-crlf.md"
sed 's/$/\r/' "$ledger_body" > "$crlf_ledger_body"
assert "CRLF fixture contains CR" "yes" "$(grep -q $'\r' "$crlf_ledger_body" && echo yes || echo no)"
jq -n --rawfile body "$crlf_ledger_body" '[[{id:11,user:{login:"rite-bot"},body:$body}]]' > "$NB_TEST_COMMENTS"
crlf_out=$("$COLLECT" --json "$live_json" --pr 1)
assert "CRLF ledger excludes the same rows" "3" "$(printf '%s' "$crlf_out" | jq '.count')"
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
# nb-sweep.md の各手順のシェル本体は fix-step.sh の nb-sweep-* サブコマンドにある。
# nb-sweep.md 側は 1 行呼び出しと、停止・戻り方の散文を持つ。
FIX_STEP="$PLUGIN_ROOT/scripts/fix-step.sh"
# $1=関数名。fix-step.sh の関数本体を出す。本体の途中に列 0 の `}`（`|| {` の閉じ）があるため `^}` では切らず、
# `step_xxx() {` の次の行から、次の `# --- ` 見出し行の直前までを本体とする
fix_step_fn() {
  awk -v head="$1() {" '$0 == head {f=1; next} f && /^# --- / {exit} f' "$FIX_STEP"
}
fn_gate="$sandbox/fn-nb-sweep-gate.sh"
fn_file_issue="$sandbox/fn-nb-sweep-file-issue.sh"
fn_persist="$sandbox/fn-nb-sweep-persist.sh"
fix_step_fn step_nb_sweep_gate > "$fn_gate"
fix_step_fn step_nb_sweep_file_issue > "$fn_file_issue"
fix_step_fn step_nb_sweep_persist > "$fn_persist"
# nb-sweep.md の本文と、それが呼ぶ nb-sweep-* の関数本体を合わせたもの (手順全体に対する否定 pin 用)
fix_sweep_all="$sandbox/nb-sweep-with-steps.txt"
{
  cat "$FIX"
  for fn in step_nb_sweep_collect step_nb_sweep_gate step_nb_sweep_file_issue step_nb_sweep_persist step_nb_sweep_finish; do
    fix_step_fn "$fn"
  done
} > "$fix_sweep_all"
# $1=subcommand。nb-sweep.md の fix-step.sh 呼び出し (行末 `\` の継続行を含む) を 1 行にして出す
fix_call_of() {
  awk -v head="bash {plugin_root}/scripts/fix-step.sh $1 " '
    index($0, head) == 1 {f=1}
    f {line = line $0; if ($0 !~ /\\$/) {print line; exit}; sub(/\\$/, "", line)}
  ' "$FIX"
}
REVIEW="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
REVIEW_STEP="$PLUGIN_ROOT/scripts/pr-review-step.sh"
PROMPT="$PLUGIN_ROOT/skills/pr-review/references/reviewer-prompt-generator.md"
assert_grep "T-07 iterate mergeable→5.S" "$ITERATE" '\[review:mergeable\].*5\.S'
# 5.S → PR 内推奨の修正 → 完了前確認 の順序。見出しの並びで固定する（本文の語句一致では順序を検出できない）。
order=$(grep -nE '^### 5\.S 後の PR 内推奨の修正$|^### 5\.S 後の完了前確認' "$ITERATE" | cut -d: -f2 | tr '\n' '|')
if [ "$order" = "### 5.S 後の PR 内推奨の修正|### 5.S 後の完了前確認（目的整合）|" ] \
   && [ "$(grep -n '^## ステップ 5.S: NB digest sweep$' "$ITERATE" | cut -d: -f1)" -lt "$(grep -n '^### 5.S 後の PR 内推奨の修正$' "$ITERATE" | cut -d: -f1)" ]; then
  pass "T-07 iterate 5.S → in-PR recommendation fix → purpose check order"
else
  fail "T-07 iterate 5.S → in-PR recommendation fix → purpose check order (got: $order)"
fi
assert_grep_in_section "T-07 iterate sweep-done no re-review" "$ITERATE" \
  '^## ステップ 5\.S: NB digest sweep$' '^## ステップ 5: 完了通知' \
  '^\| `\[fix:sweep-done\]` \| PR 内推奨の修正。ステップ 1 に戻らない'
assert_grep "T-07 iterate nb-sweep-error" "$ITERATE" '\[iterate:nb-sweep-error\]'
assert_grep "T-07 iterate --nb-sweep invoke" "$ITERATE" 'args: "--nb-sweep \{pr_number\}"'
assert_grep "T-07 iterate empty is noop" "$ITERATE_STEP" 'marker_emit ITERATE_NB_SWEEP noop'
assert_grep "T-07 iterate no second sweep" "$ITERATE" '同一 review JSON で 5\.S を 2 回'
assert_grep "T-07 iterate sweep-done ステップ1禁止" "$ITERATE" 'ステップ 1 に戻らない'
assert_grep "T-07 fix --nb-sweep" "$FIX" '\-\-nb-sweep'
assert_grep "T-07 fix sweep-done sentinel" "$FIX" '\[fix:sweep-done\]'
assert_grep "T-07 fix persist uses body count" "$fn_persist" '\-\-count "\$body_count"'
assert_grep "T-07 fix record reads the terminal outcome" "$fn_persist" 'record_outcome=.*NONBLOCKING_RECORD_DONE=1; \.\*outcome='
assert_grep "T-07 fix record succeeds only on created / updated" "$fn_persist" '^[[:space:]]*0:created[|]0:updated\) ;;$'
assert_not_grep "T-07 fix record drops the failed-only check" "$fn_persist" 'NONBLOCKING_RECORD_FAILED=1[|]outcome=failed'
assert_grep "T-07 fix gates the sweep on the adoption exit" "$fn_gate" 'review-adoption-gate\.sh --pr "\$\{pr_number\}" --kind sweep'
assert_grep "T-07 fix files only verdict=file" "$FIX" '`verdict=file` の記録ごとに 1 件起票する'
assert_not_grep "T-07 fix has no severity route" "$fix_sweep_all" 'route=issued'
assert_grep "T-07 fix recorded machine rationale" "$FIX" 'severity=\{sev\}; measured=\{bool\}'
assert_grep "T-07 sweep forbids commits" "$FIX" 'コードを変更せず、commit / push を行わない'
assert_grep "T-07 pr-review rejected_ledger" "$REVIEW" '{rejected_ledger}'
assert_grep "T-07 pr-review merge-into" "$REVIEW_STEP" 'nb-sweep-ledger.sh merge-into'
assert_grep "T-07 pr-review extract" "$REVIEW" 'nb-sweep-ledger.sh extract'
assert_grep "T-07 pr-review REJECTED_LEDGER=failed" "$REVIEW_STEP" 'REJECTED_LEDGER=failed'
assert_grep "T-07 pr-review WARNING 却下台帳取得失敗" "$REVIEW_STEP" 'WARNING: 却下台帳取得失敗'
assert_grep "T-07 pr-review failed-path 注記" "$REVIEW_STEP" '台帳取得失敗 — 却下済み指摘の再訴訟の可能性'
assert_grep "T-07 prompt rejected_ledger" "$PROMPT" '{rejected_ledger}'

# PR 内推奨の配線。呼び出し行と停止行を節の範囲内で pin し、呼び出しの順序は行番号で固定する。
FIX_SKILL="$PLUGIN_ROOT/skills/fix/SKILL.md"
REC_START='^### 5[.]S 後の PR 内推奨の修正$'
REC_END='^### 5[.]S 後の完了前確認'
assert_grep_in_section "T-07 iterate recommendation check" "$ITERATE" "$REC_START" "$REC_END" \
  '^bash \{plugin_root\}/scripts/review-pr-recommendations\.sh check --pr \{pr_number\}$'
assert_grep_in_section "T-07 iterate recommendation check failure stops" "$ITERATE" "$REC_START" "$REC_END" \
  '非ゼロ終了 / marker 不在 \| 停止する'
assert_grep_in_section "T-07 iterate recommendation pending invokes fix after the record" "$ITERATE" "$REC_START" "$REC_END" \
  '`pending` \| 下の記録のあと `/rite:fix` を invoke'
assert_grep_in_section "T-07 iterate recommendation mark" "$ITERATE" "$REC_START" "$REC_END" \
  '^bash \{plugin_root\}/scripts/review-pr-recommendations\.sh mark --pr \{pr_number\}$'
assert_grep_in_section "T-07 iterate recommendation mark failure stops before fix" "$ITERATE" "$REC_START" "$REC_END" \
  '非ゼロ終了なら停止する（fix を invoke しない）'
assert_grep_in_section "T-07 iterate recommendation fix pushed returns to step 1" "$ITERATE" "$REC_START" "$REC_END" \
  '^\| `\[fix:pushed\]` / `\[fix:pushed-wm-stale\]` \| ステップ 1 に戻る'
assert_grep_in_section "T-07 iterate recommendation reply-only goes to purpose check" "$ITERATE" "$REC_START" "$REC_END" \
  '^\| `\[fix:replied-only\]` / `\[fix:non-fatal-only\]` \| 完了前確認.*再レビューしない'
assert_grep_in_section "T-07 iterate recommendation forbids a manual commit" "$ITERATE" "$REC_START" "$REC_END" \
  'MUST NOT: mergeable の後に手で commit する'
rec_order=$(awk -v s="$REC_START" -v e="$REC_END" '
  $0 ~ s { in_sec = 1; next }
  in_sec && $0 ~ e { exit }
  in_sec && /review-pr-recommendations\.sh check --pr/ { print "check" }
  in_sec && /review-pr-recommendations\.sh mark --pr/ { print "mark" }
  in_sec && /flow-state\.sh set/ { print "set" }
  in_sec && prev ~ /^skill: rite:fix$/ && /^args: "\{pr_number\}"$/ { print "fix" }
  { prev = $0 }' "$ITERATE" | tr '\n' '|')
assert "T-07 iterate recommendation order check → mark → set → fix" "check|mark|set|fix|" "$rec_order"

TRIAGE_MD="$PLUGIN_ROOT/skills/pr-review/references/scope-triage.md"
assert_grep "T-07 pr-review 7.2 registers the adoption verdict fix after the gate decided" "$TRIAGE_MD" \
  '^  bash \{plugin_root\}/scripts/review-pr-recommendations\.sh record --pr \{pr_number\} --review-result "\$review_json" \\$'
assert_grep "T-07 pr-review 7.2 stops when the registration fails" "$TRIAGE_MD" \
  '\|\| \{ echo "ERROR: PR 内推奨を登録できません（原因は直前の出力）" >&2; rc=2; \}'
assert "T-07 pr-review no longer registers by position" "0" "$(grep -c '5\.3\.0\.R\|recommendations-register\|registered_recommendation_positions' "$REVIEW" "$REVIEW_STEP" | awk -F: '{ n += $2 } END { print n }')"
assert_grep_in_section "T-07 fix 2.1 routes R-NN to the normal fix" "$FIX_SKILL" \
  '^### 2\.1 Confirm Fix Approach$' '^### 2\.1\.A ' \
  '`fatal_map\[id\] == true`、PR 内推奨の `R-NN`、現在の review context の `D-NN` だけが通常の修正'

# 採否ゲートと起票の停止を実行して確かめる。nb-sweep.md の 1 行呼び出しを fixture plugin の fix-step.sh で
# dispatch 経由に実行する。fixture は fix-step.sh の写しと、それが読む hook (stub / symlink) を並べる。
# 手順の停止は 1 行呼び出しの非ゼロ終了なので、止まる実行を `|| exit $?` で表す。
gate_call=$(fix_call_of nb-sweep-gate)
issue_call=$(fix_call_of nb-sweep-file-issue)
assert "gate guard extracted (nb-sweep.md calls the gate step once)" 1 \
  "$(grep -c '^bash {plugin_root}/scripts/fix-step\.sh nb-sweep-gate ' "$FIX")"
assert_grep "gate guard holds the held stop" "$fn_gate" 'nb_sweep_adoption_held'
assert_grep "gate guard holds the verdict check" "$fn_gate" 'nb_sweep_verdict_invalid'
assert "issue guard extracted (nb-sweep.md calls the filing step once)" 1 \
  "$(grep -c '^bash {plugin_root}/scripts/fix-step\.sh nb-sweep-file-issue ' "$FIX")"
assert_grep "issue guard holds the filing failure stop" "$fn_file_issue" 'nb_sweep_issue_failed'
# $1=fixture plugin。fix-step.sh の写しと、起動時に読む control-char-neutralize.sh を置く
fixture_fix_step() {
  mkdir -p "$1/scripts" "$1/hooks"
  cp "$FIX_STEP" "$1/scripts/fix-step.sh"
  ln -sf "$PLUGIN_ROOT/hooks/control-char-neutralize.sh" "$1/hooks/control-char-neutralize.sh"
}
stub_plugin="$sandbox/plugin"
mkdir -p "$stub_plugin/scripts" "$stub_plugin/hooks/scripts"
fixture_fix_step "$stub_plugin"
# 起票 stub: 呼ばれたことと引数を残す。NB_TEST_ISSUE_RESULT があればそれを起票結果として返し、無ければ失敗する
cat > "$stub_plugin/scripts/create-issue-with-projects.sh" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$NB_TEST_ISSUE_LOG"
printf '%s\n' "$1" > "$NB_TEST_ISSUE_LOG.args"
[ -n "${NB_TEST_ISSUE_RESULT:-}" ] || exit 1
printf '%s\n' "$NB_TEST_ISSUE_RESULT"
SH
cat > "$stub_plugin/hooks/state-path-resolve.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$NB_TEST_STATE"
SH
cat > "$stub_plugin/hooks/scripts/nb-sweep-collect.sh" <<'SH'
#!/usr/bin/env bash
jq -n --arg r "$NB_TEST_STATE/.rite/review-results/7-20260101120000.json" \
  '{id:"F-01",key:"F-01",file:"src/a.ts",line:1,description:"d"} as $t
   | {status:"ok",count:1,record:$r,targets:[$t],
      candidates:[$t + {finding_id:"F-01",record:"7-20260101120000.json"}],already_rejected:[]}'
SH
# ゲートは stub (出口ごとの stdout と exit) と実物 (判定記録が無いと hold する) の両方で通す
cat > "$stub_plugin/hooks/scripts/review-adoption-gate.sh" <<'SH'
#!/usr/bin/env bash
case "$NB_TEST_GATE" in
  held) printf '{"held": true, "reason": "undecided", "hold_file": "x"}\n'; exit 3 ;;
  missing) printf '{"held": false, "verdicts": [{"ids": ["F-01"]}]}\n' ;;
  unknown) printf '{"held": false, "verdicts": [{"ids": ["F-01"], "verdict": "hold"}]}\n' ;;
  error) exit 1 ;;
  decided) printf '{"held": false, "head": "h", "verdicts": [{"ids": ["F-01"], "verdict": "file"}]}\n' ;;
esac
SH
real_gate_plugin="$sandbox/plugin-real-gate"
mkdir -p "$real_gate_plugin/hooks/scripts"
fixture_fix_step "$real_gate_plugin"
cp "$stub_plugin/hooks/state-path-resolve.sh" "$real_gate_plugin/hooks/"
cp "$stub_plugin/hooks/scripts/nb-sweep-collect.sh" "$real_gate_plugin/hooks/scripts/"
ln -s "$PLUGIN_ROOT/hooks/scripts/review-adoption-gate.sh" "$real_gate_plugin/hooks/scripts/review-adoption-gate.sh"
export NB_TEST_ISSUE_LOG="$sandbox/issue.log"
export NB_TEST_STATE="$sandbox/gate-state"
mkdir -p "$NB_TEST_STATE/.rite/review-results" "$NB_TEST_STATE/.rite/state"
printf '{"commit_sha": "0123456789abcdef0123456789abcdef01234567"}\n' > "$NB_TEST_STATE/.rite/review-results/7-20260101120000.json"
# The tail stands for everything after the gate (filing, entries, ledger persist, done marker):
# a stop must never reach it.
export NB_TEST_LEDGER="$ledger"
ledger_before=$(cksum "$ledger")
head_before=$(git -C "$PLUGIN_ROOT" rev-parse HEAD)
gate_tail="$sandbox/gate-tail.sh"
cat > "$gate_tail" <<'SH'
bash "$NB_TEST_PLUGIN/scripts/create-issue-with-projects.sh" '{}'
printf 'unexpected persist\n' >> "$NB_TEST_LEDGER"
printf '| F-01 | src/a.ts:1 | issued | #1 | 7-20260101120000.json |\n' > "$NB_TEST_STATE/.rite/state/nb-sweep-entries-7.md"
printf 'done 7-20260101120000.json\n' > "$NB_TEST_STATE/.rite/state/nb-sweep-done-7.txt"
SH
run_gate_guard() {  # $1=plugin $2=gate mode $3=label
  {
    printf '%s || exit $?\n' "$gate_call" \
      | sed -e "s|{plugin_root}|$1|g" -e 's|{pr_number}|7|g' -e 's|{base_branch}|develop|g' -e 's|{owner_repo}|test/repo|g'
    cat "$gate_tail"
  } > "$sandbox/gate-$3.sh"
  ( cd "$sandbox" && NB_TEST_PLUGIN="$stub_plugin" NB_TEST_GATE="$2" bash "$sandbox/gate-$3.sh" ) \
    > "$sandbox/gate-$3.out" 2> "$sandbox/gate-$3.err"
  echo $? > "$sandbox/gate-$3.rc"
}
for gate_case in "$stub_plugin|held|held|nb_sweep_adoption_held" "$real_gate_plugin||real-held|nb_sweep_adoption_held" \
                 "$stub_plugin|missing|missing|nb_sweep_verdict_invalid" "$stub_plugin|unknown|unknown|nb_sweep_verdict_invalid" \
                 "$stub_plugin|error|error|nb_sweep_adoption_gate_failed"; do
  IFS='|' read -r gate_plugin gate_mode gate_label gate_reason <<< "$gate_case"
  run_gate_guard "$gate_plugin" "$gate_mode" "$gate_label"
  assert "gate $gate_label stops" 1 "$(cat "$sandbox/gate-$gate_label.rc")"
  # stdout の [fix:error] 行はその reason の 1 行だけ (別の停止へ落ちて 2 行目が出る経路を通さない)
  assert "gate $gate_label emits [fix:error] with its reason" "[fix:error] reason=$gate_reason" \
    "$(grep '\[fix:error\]' "$sandbox/gate-$gate_label.out")"
  assert "gate $gate_label prints no gate JSON on stdout" 0 "$(grep -cE '"(held|verdicts)"' "$sandbox/gate-$gate_label.out")"
  assert "gate $gate_label never calls the issue helper" "no" "$([ -e "$NB_TEST_ISSUE_LOG" ] && echo yes || echo no)"
  assert "gate $gate_label writes no entries" "no" "$([ -e "$NB_TEST_STATE/.rite/state/nb-sweep-entries-7.md" ] && echo yes || echo no)"
  assert "gate $gate_label writes no done marker" "no" "$([ -e "$NB_TEST_STATE/.rite/state/nb-sweep-done-7.txt" ] && echo yes || echo no)"
done
assert "held / invalid verdicts leave the ledger unchanged" "$ledger_before" "$(cksum "$ledger")"
assert_grep "real gate without records holds with no_records" "$sandbox/gate-real-held.err" 'ADOPTION_GATE=held; kind=sweep; reason=no_records; held=1'
assert "real gate saves the held candidate in full" "src/a.ts:d" \
  "$(jq -r '.candidates[0] | "\(.file):\(.description)"' "$NB_TEST_STATE/.rite/state/adoption-hold-7-sweep.json" 2>/dev/null)"
# The same tail is reached once the gate decides, so the stops above are observations, not a dead tail.
cp "$ledger" "$sandbox/ledger-before-decided.md"
run_gate_guard "$stub_plugin" decided decided
assert "decided gate continues" 0 "$(grep -c '\[fix:error\]' "$sandbox/gate-decided.out")"
assert_grep "decided gate prints the verdicts" "$sandbox/gate-decided.out" '"verdict": "file"'
assert_grep "decided gate reaches the filing tail" "$NB_TEST_ISSUE_LOG" '^called$'
cp "$sandbox/ledger-before-decided.md" "$ledger"
rm -f "$NB_TEST_ISSUE_LOG" "$NB_TEST_ISSUE_LOG.args" "$NB_TEST_STATE/.rite/state/nb-sweep-entries-7.md" "$NB_TEST_STATE/.rite/state/nb-sweep-done-7.txt"
# 起票の 1 行呼び出し。タイトルは 2 行のファイル (1 行目だけがタイトル)、本文は Write tool が書く本文ファイルに当たる
issue_title_file="$sandbox/issue-title.md"
issue_body_file="$sandbox/issue-body.md"
printf '%s\n' 'fix: write the tracker back' 'second line is not the title' > "$issue_title_file"
printf '%s\n' '**Type**: fix' '**Complexity**: S' '' '## 概要' '' 'overview' > "$issue_body_file"
render_issue_call() {  # $1=plugin
  printf '%s || exit $?\n' "$issue_call" | sed -e "s|{plugin_root}|$1|g" -e 's|{pr_number}|7|g' \
    -e "s|{issue_title_file}|$issue_title_file|g" -e "s|{issue_body_file}|$issue_body_file|g" \
    -e 's|{record_ids}|["F-01","F-02"]|g' -e 's|{projects_enabled}|false|g' -e 's|{project_number}|0|g' \
    -e 's|{owner}|test|g'
}
issue_guard="$sandbox/issue-guard.sh"
{
  render_issue_call "$stub_plugin"
  printf 'printf "unexpected persist\\n" >> "$NB_TEST_LEDGER"\n'
} > "$issue_guard"
assert "issue call placeholders are all substituted" 0 "$(grep -cE '\{[a-z_]+\}' "$issue_guard")"
bash "$issue_guard" > "$sandbox/issue-guard.out" 2> "$sandbox/issue-guard.err"
assert "issue helper failure exits" "1" "$?"
assert_grep "issue failure fix:error" "$sandbox/issue-guard.out" '\[fix:error\]'
assert_grep "issue failure names its reason" "$sandbox/issue-guard.err" 'reason=nb_sweep_issue_failed'
assert_grep "issue stub was called" "$NB_TEST_ISSUE_LOG" '^called$'
assert "failure paths leave ledger unchanged" "$ledger_before" "$(cksum "$ledger")"
assert "failure paths leave HEAD unchanged" "$head_before" "$(git -C "$PLUGIN_ROOT" rev-parse HEAD)"

# --- T-08 (AC-1..AC-3): body_count の抽出式が producer (fix-step.sh nb-sweep-persist) と validator (helper) で一致する ---
# nb-sweep.md 1.3.S の手順 3（台帳 persist）が呼ぶ fix-step.sh nb-sweep-persist は抽出した値を helper へ `--count` として渡し、helper は
# 同じ行を自前の式で再検査する。片側だけを書き換えると producer が通した body を validator が
# count_body_mismatch で落とす。この不一致は実行時にしか現れないため、両者の式を突き合わせて
# 固定する。期待値はテスト内にハードコードせず helper 側から抽出する。
NBR_SH="$PLUGIN_ROOT/hooks/review-nonblocking-record.sh"
assert_file_exists_or_fail "T-08 nonblocking record helper exists" "$NBR_SH" || true

# 右辺の被演算子はファイル変数名だけが異なる (helper=$CONTENT_FILE / nb-sweep-persist=$body)。
# 共通プレースホルダへ正規化してから突合する (TC-5b の __CYCLE__ 正規化と同型)。
# 被演算子の手前で needle を切り詰めると `| tail -1 | grep -oE '[0-9]+'` が pin から外れ、
# パイプライン後段の drift を取り逃す空振り経路が残るため、右辺は全体を対象にする。
_t08_helper_lines=$(grep -cE '^body_count=' "$NBR_SH" || true)
_t08_skill_lines=$(grep -cE '^[[:space:]]*body_count=' "$fn_persist" || true)
assert "T-08 helper の body_count= 代入は 1 行 (head -1 による黙殺を防ぐ)" "1" "$_t08_helper_lines"
assert "T-08 fix-step.sh nb-sweep-persist の body_count= 代入は 1 行" "1" "$_t08_skill_lines"

# 上の 2 assert が代入 1 行を保証するため、以下の head -1 は値の選択ではなく、行数が崩れた
# 実行でも診断値を 1 つに定めるための保険。fail() は加算のみで停止しないので後続まで進む。
_t08_helper_rhs=$(sed -n 's/^body_count=\(.*\)$/\1/p' "$NBR_SH" | head -1 \
  | sed 's/"\$CONTENT_FILE"/__BODY_FILE__/')
_t08_skill_rhs=$(sed -n 's/^[[:space:]]*body_count=\(.*\)$/\1/p' "$fn_persist" | head -1 \
  | sed 's/"\$body"/__BODY_FILE__/')

if [ -z "$_t08_helper_rhs" ] || [ -z "$_t08_skill_rhs" ]; then
  # 抽出失敗 (代入形の drift) は silent pass させない。空同士の等値で緑になる経路を塞ぐ。
  fail "T-08 body_count= の右辺を抽出できない (代入形の drift。helper='$_t08_helper_rhs' skill='$_t08_skill_rhs')"
else
  # 本 assert は symmetry pin であって value pin ではない。両側を同時に同じ形へ書き換えた
  # drift は等値が保たれるため検出できない (それを検出するには期待式をテスト内へ
  # ハードコードする必要があり、helper 側から抽出する方針と衝突する)。
  assert "T-08 body_count 抽出式が producer (fix-step.sh nb-sweep-persist) と validator (helper) で一致" \
    "$_t08_helper_rhs" "$_t08_skill_rhs"
fi

# 上の正規化は 2 つの被演算子が同じファイルを指すことを前提に両者を同一視する。その前提自体は
# 抽出式の比較では確かめられないため、producer が数えた本文をそのまま helper へ渡していることを
# 別途固定する。ここが外れると producer は $body から数え helper は別ファイルを検査するため、
# 式が完全に一致していても production では count_body_mismatch が出る。
assert_grep "T-08 fix が数えた本文をそのまま helper へ渡す" "$fn_persist" '\-\-content-file "\$body"'

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
assert "measured MEDIUM carries no route" false "$(jq 'any(.targets[]; has("route"))' <<< "$medium_collect")"
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

# A class B the demotion gate kept blocking stays fatal; only the plain class B moves to the sweep.
excluded_json="$sandbox/excluded-class-b.json"
write_json "$excluded_json" <<'JSON'
{"pr_number":1,"findings":[
  {"id":"X-1","severity":"MEDIUM","scope":"current-pr","file":"src/a.ts","line":10,"verification":{"measured":true},"consequence_class":"B","consequence_exclusion":"ac_unmet:AC-1"},
  {"id":"B-1","severity":"MEDIUM","scope":"current-pr","file":"src/b.ts","line":20,"verification":{"measured":true},"consequence_class":"B"},
  {"id":"X-2","severity":"LOW","scope":"follow-up","file":"src/c.ts","line":30,"verification":{"measured":true},"consequence_class":"B","consequence_exclusion":"既存の禁止文を削除"}
],"non_blocking_findings":[]}
JSON
bash "$PLUGIN_ROOT/scripts/review-findings-maps.sh" --review-source explicit_file \
  --review-source-path "$excluded_json" > "$sandbox/excluded.maps" 2> "$sandbox/excluded.triage"
assert "excluded class B triage succeeds" 0 "$?"
assert_grep "excluded class B → fatal=2 moved=1" "$sandbox/excluded.triage" 'FIX_FATAL_TRIAGE=applied; fatal=2; moved=1'
assert "fatal_map splits excluded from plain class B" '{"B-1":false,"X-1":true,"X-2":true}' "$(jq -cS '.fatal_map' "$sandbox/excluded.maps")"
assert "excluded class B stays blocking in input order" 'X-1,X-2' "$(jq -r '[.findings[].id] | join(",")' "$excluded_json")"
assert "retained findings carry no demotion reason" false "$(jq 'any(.findings[]; has("demotion_reason"))' "$excluded_json")"
assert "only plain class B moves as non_fatal" 'B-1:non_fatal' "$(jq -r '[.non_blocking_findings[] | "\(.id):\(.demotion_reason)"] | join(",")' "$excluded_json")"

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
# 手順 3 は fix-step.sh nb-sweep-persist の 1 行呼び出し。fixture plugin の fix-step.sh で dispatch 経由に実行し、
# 非ゼロ終了で止まる実行を `|| exit $?` で表す
persist_call=$(fix_call_of nb-sweep-persist)
record_block="$sandbox/record-block.sh"
if [ -z "$persist_call" ] || ! grep -q 'review-nonblocking-record.sh' "$fn_persist"; then
  fail "T-10 nb-sweep.md の手順 3 の呼び出しか、fix-step.sh の記録の本体を抽出できない"
else
  sweep_plugin="$sandbox/sweep-plugin"
  mkdir -p "$sweep_plugin/hooks/scripts" "$sandbox/sweep-tmp"
  fixture_fix_step "$sweep_plugin"
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
  printf '%s || exit $?\n' "$persist_call" | sed -e "s|{plugin_root}|$sweep_plugin|g" -e 's|{pr_number}|7|g' \
    -e 's|{owner_repo}|test/repo|g' > "$record_block.resolved"
  printf 'printf "REACHED\\n"\n' >> "$record_block.resolved"
  # 手順 3 は entries を state root の .rite/state/ から読む。resolver だけ sandbox を指す stub にする
  mkdir -p "$sandbox/sweep-state/.rite/state"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$sandbox/sweep-state" > "$sweep_plugin/hooks/state-path-resolve.sh"
  cp "$nbr_entries" "$sandbox/sweep-state/.rite/state/nb-sweep-entries-7.md"
  run_record_block() {  # $1=outcome (none = DONE 行なし) $2=rc
    : > "$NBR_GH_LOG"
    printf '{"kind":"sweep","pr":7,"candidates":[]}\n' > "$sandbox/sweep-state/.rite/state/adoption-hold-7-sweep.json"
    SWEEP_STUB_OUTCOME="$1" SWEEP_STUB_RC="$2" TMPDIR="$sandbox/sweep-tmp" PATH="$nbr_bin:$PATH" \
      bash "$record_block.resolved" > "$sandbox/record-block.out" 2> "$sandbox/record-block.err"
  }
  for record_case in skipped:0 failed:0 aborted:0 none:0 created:1; do
    run_record_block "${record_case%%:*}" "${record_case##*:}"
    assert_grep "T-10 $record_case は [fix:error]" "$sandbox/record-block.out" '\[fix:error\]'
    assert_grep "T-10 $record_case の reason" "$sandbox/record-block.err" 'reason=nb_sweep_ledger_record_failed'
    assert_not_grep "T-10 $record_case は後続へ進まない" "$sandbox/record-block.out" '^REACHED$'
    assert "T-10 $record_case は entries を残す (起票済みの記録が戻り先になる)" 1 \
      "$([ -s "$sandbox/sweep-state/.rite/state/nb-sweep-entries-7.md" ] && echo 1 || echo 0)"
    assert "T-10 $record_case は sweep の hold を残す (持ち越し候補が再実行の候補に戻る)" 1 \
      "$([ -e "$sandbox/sweep-state/.rite/state/adoption-hold-7-sweep.json" ] && echo 1 || echo 0)"
  done
  for record_case in created:0 updated:0; do
    run_record_block "${record_case%%:*}" "${record_case##*:}"
    assert_grep "T-10 $record_case は後続へ進む" "$sandbox/record-block.out" '^REACHED$'
    assert_not_grep "T-10 $record_case は [fix:error] を出さない" "$sandbox/record-block.out" '\[fix:error\]'
    assert "T-10 $record_case は台帳の記録の後に sweep の hold を消す" 0 \
      "$([ -e "$sandbox/sweep-state/.rite/state/adoption-hold-7-sweep.json" ] && echo 1 || echo 0)"
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
# $1=file $2=needle。needle を含む helper の関数本体 (`step_*() {` から列 0 の `}` まで) を 1 つ取り出す
extract_fn_of() {
  awk -v needle="$2" '
    /^step_[a-z0-9_]+\(\) \{$/ {inside=1; block=""; next}
    /^}$/ {if (inside && index(block, needle)) {printf "%s", block; exit}; inside=0}
    inside {block=block $0 "\n"}
  ' "$1"
}
NFR="$PLUGIN_ROOT/skills/fix/references/non-fatal-record.md"
for t16_file in "$REVIEW" "$REVIEW_STEP" "$NFR" "$FIX" "$FIX_STEP"; do
  assert "T-16 ${t16_file#"$PLUGIN_ROOT"/} は記録見出しを前方一致で読まない" 0 \
    "$(grep -cF 'startswith("## 📜 rite 非実測指摘の記録")' "$t16_file")"
done
# fix の 2 つの読み手は reference の 1 行呼び出しが dispatch する fix-step.sh の関数にある
assert "T-16 non-fatal-record.md は fix-step.sh non-fatal-record を 1 回呼ぶ" 1 \
  "$(grep -c '^bash {plugin_root}/scripts/fix-step\.sh non-fatal-record ' "$NFR")"
assert "T-16 nb-sweep.md は手順 3 で fix-step.sh nb-sweep-persist を 1 回呼ぶ" 1 \
  "$(grep -c '^bash {plugin_root}/scripts/fix-step\.sh nb-sweep-persist ' "$FIX")"
for t16_site in "$REVIEW_STEP|rite-rejected-src" "$REVIEW_STEP|rite-nb-existing" \
                "step_non_fatal_record|nonblocking_record_ledger_fetch_failed" "step_nb_sweep_persist|nb_sweep_ledger_fetch_failed"; do
  t16_needle="${t16_site##*|}"
  case "${t16_site%%|*}" in
    step_*)
      t16_block=$(fix_step_fn "${t16_site%%|*}")
      grep -qF -- "$t16_needle" <<< "$t16_block" || t16_block="" ;;
    *) t16_block=$(extract_fn_of "${t16_site%%|*}" "$t16_needle") ;;
  esac
  if [ -z "$t16_block" ]; then
    fail "T-16 $t16_needle の関数本体を抽出できない"
    continue
  fi
  assert "T-16 $t16_needle の block は --print-record-body を 1 回呼ぶ" 1 \
    "$(printf '%s' "$t16_block" | grep -cF 'review-nonblocking-record.sh --print-record-body')"
  assert "T-16 $t16_needle の block はコメント一覧を直接読まない" 0 \
    "$(printf '%s' "$t16_block" | grep -cE 'issues/[^ ]*/comments')"
done

# --- T-17: 6.1.d step 1.5 は extract が失敗したら記録 helper の前で止まる ---
# step 1.5 は helper の 1 行呼び出し。非ゼロ終了で止まる実行を `|| exit` で表す
step15="$(grep -m1 -E '^[[:space:]]*bash \{plugin_root\}/scripts/pr-review-step\.sh ledger-preserve ' "$REVIEW" | sed 's/^[[:space:]]*//') || exit \$?"
t17_tmp="$sandbox/t17-tmp"
t17_plugin="$sandbox/t17-plugin"
mkdir -p "$t17_tmp" "$t17_plugin/hooks/scripts" "$t17_plugin/scripts"
ln -sf "$REVIEW_STEP" "$t17_plugin/scripts/pr-review-step.sh"
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
assert "T-17 pr の偽 reason: 引数 gate が exit 2 で止める" 2 "$t17_rc"
assert_grep "T-17 pr の偽 reason: --pr を数値でないと報告する" "$sandbox/t17.err" '^ERROR: pr-review-step\.sh: --pr must be a number: 7; reason=related_issue_unresolved$'
assert "T-17 pr の偽 reason: 記録の読み手を呼ばない" 0 "$(grep -c '^\[CONTEXT\] NONBLOCKING_RECORD_BODY' "$sandbox/t17.err")"
assert "T-17 pr の偽 reason: related_issue_unresolved と読める marker を出さない" 0 "$(grep -c "$t_ctl_anchorless" "$sandbox/t17.err")"
assert "T-17 pr の偽 reason: REJECTED_LEDGER_PRESERVE=ok を出さない" 0 "$(grep -c 'REJECTED_LEDGER_PRESERVE=ok' "$sandbox/t17.err")"
assert_not_grep "T-17 pr の偽 reason: 後続へ進まない" "$sandbox/t17.out" '^REACHED$'
assert "T-17 pr の偽 reason: gh を呼ばない" 0 "$(wc -l < "$NBR_GH_LOG" | tr -d ' ')"

# --- T-18 (静的): step 1.5 の失敗後の手順を step 1.5 / step 3 / 8.0.3 がそろって示す ---
t18_step15=$(grep -F '**step 1.5 却下台帳保全**' "$REVIEW")
t18_step3=$(sed -n '/^3\. \*\*integrity check (6\.1\.d 内部)\*\*/,/^### 6\.2 /p' "$REVIEW")
t18_p803="$(sed -n '/^### 8\.0\.3 /,/^### 8\.0\.4 /p' "$REVIEW")
$(extract_fn_of "$REVIEW_STEP" 'NONBLOCKING_GATE_FAILED=1; reason=pending_marker_present')"
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
rejected_call=$(grep -m1 -E '^bash \{plugin_root\}/scripts/pr-review-step\.sh rejected-ledger ' "$REVIEW")
printf '%s\n' "$rejected_call" | sed -e "s|{plugin_root}|$t17_plugin|g" \
  -e 's|{pr_number}|7|g' -e 's|{owner_repo}|test/repo|g' > "$sandbox/t19.sh"
assert "T-19 {rejected_ledger} の block を抽出できる" 1 "$(grep -c 'pr-review-step\.sh rejected-ledger' "$sandbox/t19.sh")"
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
printf '%s\n' "$rejected_call" | sed -e 's|--pr {pr_number}|--pr "$T_CTL_PR"|' \
  -e "s|{plugin_root}|$t17_plugin|g" -e 's|{pr_number}|7|g' -e 's|{owner_repo}|test/repo|g' > "$sandbox/t19-ctl.sh"
assert "T-19 pr の偽 reason: --pr だけを差し替える" 1 "$(grep -c -- '--pr "\$T_CTL_PR"' "$sandbox/t19-ctl.sh")"
: > "$NBR_GH_LOG"
t19_rc=0
T_CTL_PR="$T_CTL_PR" TMPDIR="$t19_tmp" PATH="$nbr_bin:$PATH" bash "$sandbox/t19-ctl.sh" > "$sandbox/t19.out" 2> "$sandbox/t19.err" || t19_rc=$?
assert "T-19 pr の偽 reason: 引数 gate が exit 2 で止める" 2 "$t19_rc"
assert_grep "T-19 pr の偽 reason: --pr を数値でないと報告する" "$sandbox/t19.err" '^ERROR: pr-review-step\.sh: --pr must be a number: 7; reason=related_issue_unresolved$'
assert "T-19 pr の偽 reason: 記録の読み手を呼ばない" 0 "$(grep -c '^\[CONTEXT\] NONBLOCKING_RECORD_BODY' "$sandbox/t19.err")"
assert "T-19 pr の偽 reason: related_issue_unresolved と読める marker を出さない" 0 "$(grep -c "$t_ctl_anchorless" "$sandbox/t19.err")"
assert "T-19 pr の偽 reason: empty / ok と言わない" 0 "$(grep -cE 'REJECTED_LEDGER=(empty|ok)' "$sandbox/t19.err")"
assert "T-19 pr の偽 reason: gh を呼ばない" 0 "$(wc -l < "$NBR_GH_LOG" | tr -d ' ')"

# --- T-20: NB sweep 手順 3 を実 helper で実行する (読み取り → extract → append → merge-into → 記録) ---
# 古い記録 (id 41, 台帳 OLD-1) → 新しい記録 (id 43, 台帳 NEW-1 = PATCH 先) → 他人の同 marker コメント (id 49, 台帳 FOR-1)
t20_tmp="$sandbox/t20-tmp"
mkdir -p "$t20_tmp"
# 手順 3 の 1 行呼び出しを、実 helper を並べた fixture plugin の fix-step.sh で dispatch 経由に実行する
fixture_fix_step "$t17_plugin"
printf '%s || exit $?\n' "$persist_call" | sed -e "s|{plugin_root}|$t17_plugin|g" -e 's|{pr_number}|7|g' \
  -e 's|{owner_repo}|test/repo|g' > "$sandbox/t20.sh"
printf 'printf "REACHED\\n"\n' >> "$sandbox/t20.sh"
assert "T-20 手順 3 の placeholder をすべて置換できる" 0 "$(grep -c '{[a-z_]*}' "$sandbox/t20.sh")"
mkdir -p "$sandbox/t20-state/.rite/state"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$sandbox/t20-state" > "$t17_plugin/hooks/state-path-resolve.sh"
cp "$nbr_entries" "$sandbox/t20-state/.rite/state/nb-sweep-entries-7.md"
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
# cleanup の follow-up が処分した先送り欠陥の行は出典 <pr>-deferred を持つ
printf '%s\n' '| D-01 | - | LINK | 追跡先 #7 | 7-deferred |' > "$sandbox/t21-entries-deferred.md"
t21_def_rc=0
"$LEDGER" append --ledger-file "$sandbox/t21-new.md" --entries-file "$sandbox/t21-entries-deferred.md" 2>/dev/null || t21_def_rc=$?
assert "T-21 先送り欠陥の出典 <pr>-deferred を受理" 0 "$t21_def_rc"
# 壊れて改名されたレビュー結果に残る指摘の行は、その名前 (.json.corrupt-<epoch>) を出典に持つ
printf '%s\n' '| NB-8 | src/h.ts:8 | REJECT | 前提 | 7-20260101120000.json.corrupt-1700000000 |' > "$sandbox/t21-entries-corrupt.md"
t21_cor_rc=0
"$LEDGER" append --ledger-file "$sandbox/t21-new.md" --entries-file "$sandbox/t21-entries-corrupt.md" 2>/dev/null || t21_cor_rc=$?
assert "T-21 壊れて改名された JSON の名前の出典を受理" 0 "$t21_cor_rc"
# 出典を欠く・形が合わない行を 1 行でも含む entries は何も書かない
cp "$sandbox/t21-new.md" "$sandbox/t21-before.md"
for t21_bad in '| NB-7 | src/g.ts:7 | recorded | severity=LOW; measured=false |' \
               '| D-02 | - | LINK | 追跡先 #7 | deferred |' \
               '| NB-7 | src/g.ts:7 | recorded | severity=LOW; measured=false | review.json |' \
               '| NB-7 | src/g.ts:7 | recorded | severity=LOW; measured=false | 7-20260101120000.json.corrupt- |'; do
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
assert "T-21 手順 3 の行形式は出典列で終わる" 1 "$(grep -cF '行形式 `| {key} | {file}:{line} | {判定} | {判定文} | {record_basename} |`' "$FIX")"
assert "T-21 手順 3 は出典の値源を collect の record= に置く" 1 "$(grep -cF '`[CONTEXT] NB_SWEEP_COLLECT=ok; ...; record=` の値の basename' "$FIX")"

# --- T-22: パイプバッファを超える量の不正行でも、拒否理由を必ず出して台帳を変えない ---
{
  printf '%s\n' "$t21_row"
  for t22_i in $(seq 1 5000); do
    printf '| NB-%d | src/g.ts:%d | recorded | severity=LOW; measured=false |\n' "$t22_i" "$t22_i"
  done
} > "$sandbox/t22-entries.md"
t22_bad_bytes=$(tail -n +2 "$sandbox/t22-entries.md" | wc -c | tr -d ' ')
if [ "$t22_bad_bytes" -gt 65536 ]; then
  pass "T-22 不正行はパイプバッファ (64 KiB) を超える"
else
  fail "T-22 不正行はパイプバッファ (64 KiB) を超える (${t22_bad_bytes} bytes)"
fi
cp "$sandbox/t21-new.md" "$sandbox/t22-before.md"
t22_rc=0
"$LEDGER" append --ledger-file "$sandbox/t21-new.md" --entries-file "$sandbox/t22-entries.md" 2>"$sandbox/t22.err" || t22_rc=$?
assert "T-22 rc=1 で止まる (SIGPIPE の 141 ではない)" 1 "$t22_rc"
assert "T-22 拒否理由はちょうど 1 回" 1 "$(grep -c 'NB_SWEEP_LEDGER=failed; op=append; reason=entries_source_invalid' "$sandbox/t22.err")"
assert "T-22 拒否理由は stderr の最終行" '[CONTEXT] NB_SWEEP_LEDGER=failed; op=append; reason=entries_source_invalid' "$(tail -n 1 "$sandbox/t22.err")"
assert "T-22 診断は不正行の先頭 3 行を順に示す" "$(sed -n '2,4p' "$sandbox/t22-entries.md" | sed 's/^/  /')" "$(grep '^  ' "$sandbox/t22.err")"
if cmp -s "$sandbox/t22-before.md" "$sandbox/t21-new.md"; then
  pass "T-22 大量の不正行を含む entries は台帳を変えない"
else
  fail "T-22 大量の不正行を含む entries は台帳を変えない"
fi

# --- T-23: 追記失敗後の戻り方と拒否の単位 (nb-sweep.md 手順 2・3 / iterate 5.S / schema) ---
t23_step3=$(awk '/^3\. \*\*台帳 persist\*\*/{s=1} /^4\. \*\*完了\*\*/{s=0} s && /^```/{f=!f; next} s && !f' "$FIX")
for t23_phrase in 'entries（`.rite/state/nb-sweep-entries-{pr_number}.md`）を stderr の理由に合わせて直し' '手順 2 の起票をやり直さない' \
                  '手順 3 だけを再実行する' '起票済みの Issue は entries の issued 行が持つ' \
                  'entries の全行について最終列がその行の candidate の `record`（`already_rejected` は手順 1 の `record=` の basename）になっているかを確かめ、欠けた行には最終列として足す。別の record を名指す行は書き換えない' \
                  'この会話で続けられないときは entries を直したうえで `/rite:iterate {pr_number}` を再実行する（別の会話からでもよい）' \
                  'iterate のステップ 0.7 が再レビューを回さずに 5.S へ戻し、手順 1 が `NB_SWEEP_ENTRIES=present` を出すので手順 2 を飛ばして手順 3 から続く' \
                  '1 行でもあれば、append は entries 全体を `reason=entries_source_invalid` で拒否し、台帳を変更しない'; do
  assert "T-23 手順 3 の fence 外に復旧手順・拒否単位がある ($t23_phrase)" 1 "$(printf '%s\n' "$t23_step3" | grep -cF -- "$t23_phrase")"
done
assert "T-23 手順 2 は手順 3 の再実行で同じ sweep の entries を直して使う" 1 \
  "$(grep -cF '全件成功後に entries を生成する（手順 3 を再実行するときは、同じ sweep の entries を直して使う。' "$FIX")"
assert "T-23 手順 3 は別の record の出典を今回の record へ書き換えさせない" 0 \
  "$(printf '%s\n' "$t23_step3" | grep -cF '値の違う行はその値に直す')"
assert "T-23 手順 1 の stale は別の record を名指す行を書き換えずに元の出典で台帳へ載せさせる" 1 \
  "$(grep -F '1 行目が別の record を名指す entries の行は、前回の sweep が起票したまま台帳に載せられなかった記録であり、1 行目も行の出典も今回の record に書き換えてはならない' "$FIX" | grep -cF '書き換えずに手順 3 の bash だけを実行して元の出典のまま台帳へ載せ、成功したら entries を消して `/rite:iterate {pr_number}` を再実行する')"
assert "T-23 手順 1 の stale は台帳に既に載っている行で手順 3 を再実行させない" 1 \
  "$(grep -F '別の record を名指す entries の行は' "$FIX" | grep -F '同じ id・位置・出典の行が既にあれば、手順 3 は成功済みなので再実行しない' | grep -cF 'entries を消して `/rite:iterate {pr_number}` を再実行する。無ければ書き換えずに')"
assert "T-23 手順 2 は前回の sweep の entries を今回の起票済みとして使わない" 1 \
  "$(grep -cF '前回の sweep の entries を今回の起票済みとして使わない' "$FIX")"
assert "T-23 手順 1 は entries が残っていれば起票せず手順 3 から続けさせる" 1 \
  "$(grep -F '`NB_SWEEP_ENTRIES=present` なら' "$FIX" | grep -F '手順 2 を実行せず' | grep -cF '手順 3 から続ける')"
t23_iterate_row=$(grep -E '^\| `\[fix:error\]` / その他 / sentinel 不在 \|' "$PLUGIN_ROOT/skills/iterate/SKILL.md")
assert "T-23 iterate 5.S の停止行は起票後の台帳 persist の停止を復旧手順へ導き、iterate の再実行で戻らせる" 1 \
  "$(printf '%s\n' "$t23_iterate_row" | grep -F '手順 2 の起票後に台帳 persist' | grep -F 'entries を直してから `/rite:iterate {pr_number}` を再実行する' | grep -cF 'nb-sweep.md')"
assert "T-23 iterate 5.S の停止行は同じ会話でも別の会話でも同じ経路で戻す" 1 \
  "$(printf '%s\n' "$t23_iterate_row" | grep -F '同じ会話でも別の会話でも同じ経路で' | grep -F 'ステップ 0.7 が再レビューを回さずに 5.S へ戻し' | grep -cF 'fix は起票をやり直さず手順 3 から続ける')"
assert "T-23 旧文面 (別の会話からは停止のまま) が停止行と手順 3 に残らない" 0 \
  "$(printf '%s\n%s\n' "$t23_iterate_row" "$t23_step3" | grep -cF '別の会話からは続けず')"
assert "T-23 iterate 5.S の停止行は理由名の接頭辞で対象を絞らない" 0 "$(printf '%s\n' "$t23_iterate_row" | grep -cF 'nb_sweep_ledger_')"
t23_schema=$(grep -F 'entries_source_invalid' "$PLUGIN_ROOT/references/review-result-schema.md")
assert "T-23 schema は 1 行でも不正なら全体を拒否すると書く" 1 "$(printf '%s\n' "$t23_schema" | grep -F '1 行でも' | grep -cF '台帳を変更しない')"
assert "T-23 schema に行単位の拒否と読める旧文言が無い" 0 "$(printf '%s\n' "$t23_schema" | grep -cF '出典を欠く行を `entries_source_invalid` で拒否し')"

# --- T-24: 採否ゲート後の台帳の読み方 (除外 / prior / 旧行) と tally ---
t24_cur="1-20260301000000.json"
t24_json="$sandbox/$t24_cur"
jq -n '{non_blocking_findings:[
  {id:"R-1",file:"src/r.ts",line:1}, {id:"R-2",file:"src/r.ts",line:2}, {id:"R-3",file:"src/r.ts",line:3},
  {id:"S-1",file:"src/s.ts",line:1}, {id:"S-2",file:"src/s.ts",line:2}, {id:"L-1",file:"src/l.ts",line:1},
  {id:"I-1",file:"src/i.ts",line:1}, {id:"A-1",file:"src/a.ts",line:1}, {id:"O-1",file:"src/o.ts",line:1},
  {id:"O-2",file:"src/o.ts",line:2}, {id:"",file:"src/n.ts",line:7}
]}' > "$t24_json"
t24_body="$sandbox/t24-body.md"
{
  printf '%s\n' "$MARKER" '' '### 却下台帳' '' '| finding_id | file:line | 判定 | 判定文 | 出典 |' '|------------|-----------|------|--------|------|'
  printf '%s\n' \
    '| R-1 | src/r.ts:1 | REJECT | 旧い前提 | 1-20260101000000.json |' \
    '| R-1 | src/r.ts:1 | REJECT | X が真である間は不要 | 1-20260201000000.json |' \
    "| R-2 | src/r.ts:2 | REJECT | 今回の sweep が記録済み | $t24_cur |" \
    '| R-3 | src/r.ts:3 | REJECT | a \| b の間は不要 | 1-20260101000000.json |' \
    "| S-1 | src/s.ts:1 | RESOLVED | 解消の根拠 | $t24_cur |" \
    '| S-2 | src/s.ts:2 | RESOLVED | 前の cycle で解消 | 1-20260101000000.json |' \
    "| L-1 | src/l.ts:1 | LINK | 追跡先 #5 | $t24_cur |" \
    '| I-1 | src/i.ts:1 | issued | #9 https://example.test/issues/9 | 1-20260101000000.json |' \
    '| A-1 | src/a.ts:1 | ADOPT | 採用の前提 | 1-20260101000000.json |' \
    '| O-1 | src/o.ts:1 | recorded | severity=LOW; measured=false | 1-20260101000000.json |' \
    "| O-2 | src/o.ts:2 | rejected | 旧形式の却下 | $t24_cur |" \
    '| anon:src/n.ts:7 | src/n.ts:7 | issued | #3 https://example.test/issues/3 | 1-20260101000000.json |'
  printf '%s\n' '' '📎 non_blocking_count: 0' '' "$SENTINEL"
} > "$t24_body"
jq -n --rawfile body "$t24_body" '[[{id:11,user:{login:"rite-bot"},body:$body}]]' > "$NB_TEST_COMMENTS"
t24_out=$("$COLLECT" --json "$t24_json" --pr 1 2> "$sandbox/t24.err")
assert "T-24 collect rc=0" 0 "$?"
assert "T-24 targets: issued (any source) and this sweep's REJECT / RESOLVED / LINK are excluded; others remain" \
  "A-1,O-1,O-2,R-1,R-3,S-2" "$(printf '%s' "$t24_out" | jq -r '[.targets[].key] | sort | join(",")')"
assert "T-24 legacy recorded / rejected rows are not terminal and give no prior" 0 \
  "$(printf '%s' "$t24_out" | jq '[.targets[] | select(.key == "O-1" or .key == "O-2") | select(has("prior"))] | length')"
assert "T-24 a REJECT row from an earlier cycle becomes the prior (the last row wins)" \
  '{"finding_id":"R-1","file_line":"src/r.ts:1","disposition":"REJECT","premise":"X が真である間は不要"}' \
  "$(printf '%s' "$t24_out" | jq -c '.targets[] | select(.key == "R-1") | .prior')"
assert "T-24 the premise keeps an escaped pipe" 'a \| b の間は不要' "$(printf '%s' "$t24_out" | jq -r '.targets[] | select(.key == "R-3") | .prior.premise')"
assert "T-24 an ADOPT row becomes the prior" "ADOPT" "$(printf '%s' "$t24_out" | jq -r '.targets[] | select(.key == "A-1") | .prior.disposition')"
assert "T-24 RESOLVED gives no prior" "false" "$(printf '%s' "$t24_out" | jq -r '.targets[] | select(.key == "S-2") | has("prior")')"
assert "T-24 ledger[] carries the issued / LINK / REJECT rows as read (for a candidate whose id or position changed)" \
  "I-1:issued,L-1:LINK,R-1:REJECT,R-1:REJECT,R-2:REJECT,R-3:REJECT,anon:src/n.ts:7:issued" \
  "$(printf '%s' "$t24_out" | jq -r '[.ledger[] | "\(.id):\(.disposition)"] | sort | join(",")')"
assert "T-24 an issued row in ledger[] keeps the Issue number" "#9 https://example.test/issues/9" \
  "$(printf '%s' "$t24_out" | jq -r '.ledger[] | select(.id == "I-1") | .premise')"
if grep -qF '既存の Issue が今回の候補と同じ根因を追跡していれば、文面・位置・id が変わっていても記録の `tracker` にその番号を入れる' "$FIX" \
  && grep -qF '`REJECT` 行が同じ根因・同じ前提の候補を処分していれば、その行を記録の `prior`' "$FIX"; then
  pass "T-24 step 2 has the classifier link changed candidates from ledger[]"
else
  fail "T-24 step 2 must have the classifier link changed candidates from ledger[]"
fi
# prior は採否判定 helper が照合する台帳行と同じ (finding_id, file:line, 判定) を指す
"$LEDGER" extract --body-file "$t24_body" > "$sandbox/t24-ledger.md" 2>/dev/null
printf '%s' "$t24_out" | jq -c '[.targets[] | select(has("prior")) | .prior]' > "$sandbox/t24-priors.json"
t24_match=$(python3 - "$PLUGIN_ROOT/hooks/scripts/lib/review-adoption.py" "$sandbox/t24-ledger.md" "$sandbox/t24-priors.json" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("review_adoption", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
rows = module.ledger_rows(open(sys.argv[2], encoding="utf-8").read())
priors = json.load(open(sys.argv[3], encoding="utf-8"))
print(sum((p["finding_id"], p["file_line"], p["disposition"]) in rows and p["premise"].strip() != "" for p in priors), len(priors))
PY
)
assert "T-24 every prior matches a helper ledger row with a premise" "3 3" "$t24_match"
printf '%s\n' \
  '| F-1 | src/a.ts:1 | issued | #5 https://example.test/5 | 7-20260101120000.json |' \
  '| F-2 | src/b.ts:2 | issued | #5 https://example.test/5 | 7-20260101120000.json |' \
  '| F-3 | src/c.ts:3 | REJECT | 前提 a \| b | 7-20260101120000.json |' \
  '| F-4 | src/d.ts:4 | RESOLVED | 解消の根拠 | 7-20260101120000.json |' \
  '| F-5 | src/e.ts:5 | LINK | 追跡先 #6 | 7-20260101120000.json |' \
  '| code-quality-reviewer | src/g.ts:7 | recorded | severity=MEDIUM; measured=false | 7-20260101120000.json |' > "$sandbox/t24-entries.md"
assert "T-24 tally counts REJECT / RESOLVED / LINK / recorded as recorded" "issued=2; recorded=4" \
  "$("$LEDGER" tally --entries-file "$sandbox/t24-entries.md" 2>/dev/null)"

# --- T-25: 保留した sweep の戻り方と、起票番号の tracker への書き戻し ---
t25_row=$(grep -E '^\| `\[fix:error\]` / その他 / sentinel 不在 \|' "$PLUGIN_ROOT/skills/iterate/SKILL.md")
assert "T-25 iterate 5.S の停止行は保留 (held) の sweep の再開を示す" 1 \
  "$(printf '%s\n' "$t25_row" | grep -F 'reason=nb_sweep_adoption_held' | grep -F 'hold ファイルの resume（ゲートの WARNING にも出る）に従って再開する' | grep -cF 'HEAD が変わらない再開では、同じ経路で fix は手順 2 の判定記録から続く')"
assert "T-25 nb-sweep.md の held は hold ファイルの resume に従って再開する" 1 \
  "$(grep -F 'reason=nb_sweep_adoption_held` は出口の出ていない候補がある' "$FIX" | grep -cF '保留を REJECT や処分済みに書き換えず、hold ファイルの resume（ゲートの WARNING にも出る）に従って再開する')"
t25_step2=$(awk '/^2\. \*\*採否ゲートと起票\*\*/{s=1} /^3\. \*\*台帳 persist\*\*/{s=0} s' "$FIX")
# 手順 2 の中で、ゲートの呼び出し → held で止まる指示 → 起票の呼び出し の順に並ぶ
t25_gate=$(printf '%s\n' "$t25_step2" | grep -n '^bash {plugin_root}/scripts/fix-step\.sh nb-sweep-gate ' | head -1 | cut -d: -f1)
t25_held=$(printf '%s\n' "$t25_step2" | grep -n 'reason=nb_sweep_adoption_held` は出口の出ていない候補がある' | head -1 | cut -d: -f1)
t25_issue=$(printf '%s\n' "$t25_step2" | grep -n '^bash {plugin_root}/scripts/fix-step\.sh nb-sweep-file-issue ' | head -1 | cut -d: -f1)
if [ -n "$t25_gate" ] && [ -n "$t25_held" ] && [ -n "$t25_issue" ] && [ "$t25_gate" -lt "$t25_held" ] && [ "$t25_held" -lt "$t25_issue" ]; then
  pass "T-25 held の停止は起票より前"
else
  fail "T-25 held の停止は起票より前 (gate=$t25_gate held=$t25_held issue=$t25_issue)"
fi
# 起票の 1 行呼び出しを、起票結果を返す stub と判定記録の state root を並べた fixture plugin で実行する
t25_state="$sandbox/t25-state"
t25_plugin="$sandbox/t25-plugin"
mkdir -p "$t25_state/.rite/state"
fixture_fix_step "$t25_plugin"
cp "$stub_plugin/scripts/create-issue-with-projects.sh" "$t25_plugin/scripts/"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$t25_state" > "$t25_plugin/hooks/state-path-resolve.sh"
t25_tracker="$sandbox/t25-tracker.sh"
render_issue_call "$t25_plugin" > "$t25_tracker"
assert "T-25 起票の呼び出しの placeholder をすべて置換できる" 0 "$(grep -cE '\{[a-z_]+\}' "$t25_tracker")"
t25_result='{"issue_number":12,"issue_url":"https://x/12"}'
run_t25() {  # $1=out 名
  NB_TEST_ISSUE_RESULT="$t25_result" bash "$t25_tracker" > "$sandbox/$1.out" 2> "$sandbox/$1.err"
}
jq -n '{adoption: {head: "h", records: [{ids: ["F-01", "F-02"], tracker: null}, {ids: ["F-03"], tracker: null}]}}' > "$t25_state/.rite/state/adoption-7-sweep.json"
run_t25 t25
assert "T-25 書き戻しは成功する" 0 "$?"
assert "T-25 起票した番号はその記録の tracker に書かれ、他の記録は変わらない" '[12,null]' \
  "$(jq -c '[.adoption.records[].tracker]' "$t25_state/.rite/state/adoption-7-sweep.json")"
assert "T-25 成功時の stdout は起票結果の JSON" "$t25_result" "$(jq -c . "$sandbox/t25.out" 2>/dev/null)"
assert "T-25 起票にはタイトルファイルの 1 行目と本文ファイルのパスを渡す" "fix: write the tracker back|$issue_body_file" \
  "$(jq -r '"\(.issue.title)|\(.issue.body_file)"' "$NB_TEST_ISSUE_LOG.args" 2>/dev/null)"
rm -f "$t25_state/.rite/state/adoption-7-sweep.json"
run_t25 t25-fail
assert "T-25 書き戻せなければ止まる" 1 "$?"
assert_grep "T-25 書き戻せなければ理由を出す" "$sandbox/t25-fail.err" 'reason=nb_sweep_tracker_write_failed'
jq -n '{adoption: {head: "h", records: [{ids: ["F-03"], tracker: null}]}}' > "$t25_state/.rite/state/adoption-7-sweep.json"
run_t25 t25-nomatch
assert "T-25 一致する記録が無い書き戻しは止まる" 1 "$?"
assert_grep "T-25 一致する記録が無い書き戻しも理由を出す" "$sandbox/t25-nomatch.err" 'reason=nb_sweep_tracker_write_failed'

if ! print_summary "$(basename "$0")" "nb-sweep helper contract drift — check iterate SKILL.md / iterate-step.sh 5.S / 6.1.d preserve"; then
  exit 1
fi
