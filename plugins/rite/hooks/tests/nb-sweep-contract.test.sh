#!/bin/bash
# Contract tests for post-mergeable NB digest sweep helpers (#2409).
#
# T-01 collect NB targets (AC-1)
# T-02 ledger append with rationale (AC-2)
# T-03 merge-into preserves ledger across 6.1.d rewrite (AC-3)
# T-04 empty collect is no-op status (AC-4)
# T-05 nit-noted in findings[] is a target; new class-B is not a second sweep (AC-5)
# T-06 ledger write / merge fail-loud (AC-6)
# T-07 class A findings[] stay out of sweep targets (AC-7)
# T-08 body_count extraction expression matches between fix/SKILL.md and the record helper (#2480 AC-1..AC-3)
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

# --- rails pin (SKILL.md 機械レール) ---
ITERATE="$PLUGIN_ROOT/skills/iterate/SKILL.md"
FIX="$PLUGIN_ROOT/skills/fix/SKILL.md"
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
assert_grep "T-07 fix record failed is error" "$FIX" 'outcome=failed'
assert_grep "T-07 fix class-B issueize" "$FIX" '新規 class-B'
assert_grep "T-07 fix 判定文必須" "$FIX" '判定文必須'
assert_grep "T-07 pr-review rejected_ledger" "$REVIEW" '{rejected_ledger}'
assert_grep "T-07 pr-review merge-into" "$REVIEW" 'nb-sweep-ledger.sh merge-into'
assert_grep "T-07 pr-review extract" "$REVIEW" 'nb-sweep-ledger.sh extract'
assert_grep "T-07 pr-review REJECTED_LEDGER=failed" "$REVIEW" 'REJECTED_LEDGER=failed'
assert_grep "T-07 pr-review WARNING 却下台帳取得失敗" "$REVIEW" 'WARNING: 却下台帳取得失敗'
assert_grep "T-07 pr-review failed-path 注記" "$REVIEW" '台帳取得失敗 — 却下済み指摘の再訴訟の可能性'
assert_grep "T-07 prompt rejected_ledger" "$PROMPT" '{rejected_ledger}'

# --- T-08 (#2480 AC-1..AC-3): body_count の抽出式が producer (fix/SKILL.md) と validator (helper) で一致する ---
# fix/SKILL.md ステップ 1.3.S step 3 は抽出した値を helper へ `--count` として渡し、helper は
# 同じ行を自前の式で再検査する。片側だけを書き換えると producer が通した body を validator が
# count_body_mismatch で落とす。この不一致は実行時にしか現れないため、両者の式を突き合わせて
# 固定する。期待値はテスト内にハードコードせず helper 側から抽出する。
NBR_SH="$PLUGIN_ROOT/hooks/review-nonblocking-record.sh"
assert_file_exists_or_fail "T-08 nonblocking record helper exists" "$NBR_SH" || true

# 右辺の被演算子はファイル変数名だけが異なる (helper=$CONTENT_FILE / SKILL=$body)。
# 共通プレースホルダへ正規化してから突合する (TC-5b の __CYCLE__ 正規化と同型)。
# 被演算子の手前で needle を切り詰めると `| tail -1 | grep -oE '[0-9]+'` が pin から外れ、
# パイプライン後段の drift を取り逃す空振り経路が残るため、右辺は全体を対象にする。
_t08_helper_lines=$(grep -cE '^body_count=' "$NBR_SH" || true)
_t08_skill_lines=$(grep -cE '^[[:space:]]*body_count=' "$FIX" || true)
assert "T-08 helper の body_count= 代入は 1 行 (head -1 による黙殺を防ぐ)" "1" "$_t08_helper_lines"
assert "T-08 fix/SKILL.md の body_count= 代入は 1 行" "1" "$_t08_skill_lines"

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
  assert "T-08 body_count 抽出式が producer (fix/SKILL.md) と validator (helper) で一致" \
    "$_t08_helper_rhs" "$_t08_skill_rhs"
fi

# 上の正規化は 2 つの被演算子が同じファイルを指すことを前提に両者を同一視する。その前提自体は
# 抽出式の比較では確かめられないため、producer が数えた本文をそのまま helper へ渡していることを
# 別途固定する。ここが外れると producer は $body から数え helper は別ファイルを検査するため、
# 式が完全に一致していても production では count_body_mismatch が出る。
assert_grep "T-08 fix が数えた本文をそのまま helper へ渡す" "$FIX" '\-\-content-file "\$body"'

if ! print_summary "$(basename "$0")" "nb-sweep helper contract drift — check SKILL.md 5.S / 6.1.d preserve"; then
  exit 1
fi
