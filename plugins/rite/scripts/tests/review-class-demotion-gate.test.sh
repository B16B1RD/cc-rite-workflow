#!/bin/bash
# Tests for review-class-demotion-gate.sh (帰結クラス降格政策の決定論的後処理)
#
# 本 helper は「実体収束後に pin 精度・文言クラスの指摘だけが再生産される churn 尾部」を
# 人間の手動 freeze なしに終端させる第 2 降格軸の強制層である。本 suite は帰結クラス降格政策の
# 受入基準 (class A 維持 / 攻め側既定 / A=0 発動 / 非発動 / record / 判定不能の安全側) を
# 合成 fixture で固定する。既存ゲート非退行は既存 suite の実行で担保され、本ファイルの対象外。
#
# Usage: bash plugins/rite/scripts/tests/review-class-demotion-gate.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../review-class-demotion-gate.sh"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# helper 実行。stdout/stderr/rc を大域変数へ。
run_gate() {
  local input="$1" cls="$2"
  local err_file="$TEST_DIR/.stderr"
  GATE_STDOUT=$(bash "$TARGET" --input "$input" --classification "$cls" 2>"$err_file")
  GATE_RC=$?
  GATE_STDERR=$(cat "$err_file")
  return 0
}

# finding 1 件を組み立てる: id severity scope description [file] [measured] [category]
# file: 省略時 plugins/rite/hooks/foo.sh。TC-01 は tests/ 配下パスを渡す (パス分類禁止の回帰ガード)
# measured: "true" (default) / "false" = verification.measured に boolean を付与 /
#           "none" = verification キーなし
mk_finding() {
  local file="${5:-plugins/rite/hooks/foo.sh}"
  local measured="${6:-true}"
  local category="${7:-code_quality}"
  if [ "$measured" = "none" ]; then
    jq -n --arg id "$1" --arg sev "$2" --arg scope "$3" --arg desc "$4" --arg file "$file" --arg category "$category" \
      '{id:$id, reviewer:"code-quality-reviewer", category:$category, severity:$sev,
        file:$file, line:1, description:$desc, suggestion:"s",
        status:"open", scope:$scope}'
  else
    jq -n --arg id "$1" --arg sev "$2" --arg scope "$3" --arg desc "$4" --arg file "$file" --arg category "$category" --argjson measured "$measured" \
      '{id:$id, reviewer:"code-quality-reviewer", category:$category, severity:$sev,
        file:$file, line:1, description:$desc, suggestion:"s",
        status:"open", scope:$scope,
        verification:{measured:$measured, repro:"bash t.sh => observed failure", failing_test:null}}'
  fi
}

# review-result JSON を組み立てる: path <finding json...>
mk_json() {
  local path="$1"; shift
  printf '%s\n' "$@" | jq -s '{
    schema_version: "1.1.0",
    pr_number: 99,
    timestamp: "2026-08-11T00:00:00Z",
    commit_sha: "0123456789abcdef0123456789abcdef01234567",
    overall_assessment: "fix-needed",
    verdict: "fix-needed",
    reviewers: ["code-quality-reviewer", "test-reviewer"],
    findings: .,
    non_blocking_findings: [],
    guardrail_audit_log: []
  }' > "$path"
}

# classification map を組み立てる: path <entry json...>
mk_cls() {
  local path="$1"; shift
  if [ $# -eq 0 ]; then
    echo '{"classifications": []}' > "$path"
  else
    printf '%s\n' "$@" | jq -s '{classifications: .}' > "$path"
  fi
}

mk_entry() {
  jq -n --arg id "$1" --arg class "$2" --arg scenario "$3" \
    '{id:$id, class:$class, scenario:$scenario}'
}

# class B + 除外判定文。第 4 引数は classification map の exclusion（非空文字列）
mk_entry_excl() {
  jq -n --arg id "$1" --arg class "$2" --arg scenario "$3" --arg exclusion "$4" \
    '{id:$id, class:$class, scenario:$scenario, exclusion:$exclusion}'
}

echo "=== review-class-demotion-gate.sh tests ==="

# ---- TC-01 (T-01/AC-1): class A 指定の finding は blocking に残る ----
# fixture の file は tests/ 配下パス — テストへの指摘でも実行時帰結があれば class A であること
# (§4.4 MUST NOT: ファイルパスによる機械分類の禁止) の回帰ガードを兼ねる
echo "TC-01: class A の維持 (tests/ 配下でも実行時帰結があれば A — パス分類しない)"
f1=$(mk_finding "F-01" "HIGH" "current-pr" "clean fixture のため本番バグを検出できない" "plugins/rite/scripts/tests/foo.test.sh")
mk_json "$TEST_DIR/tc01.json" "$f1"
mk_cls "$TEST_DIR/tc01-cls.json" "$(mk_entry F-01 A "本番バグ混入時に suite green のまま merge される")"
run_gate "$TEST_DIR/tc01.json" "$TEST_DIR/tc01-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "rc=0" || fail "rc=$GATE_RC (expected 0)"
grep -q "CLASS_DEMOTION_GATE=not-triggered; class_a=1; class_b=0" <<<"$GATE_STDERR" \
  && pass "not-triggered marker" || fail "marker mismatch: $GATE_STDERR"
[ "$(jq -r '.findings[0].consequence_class' "$TEST_DIR/tc01.json")" = "A" ] \
  && pass "consequence_class=A recorded" || fail "consequence_class not A"
[ "$(jq -r '.findings | length' "$TEST_DIR/tc01.json")" = "1" ] \
  && pass "finding stays blocking" || fail "finding was moved"
[ "$(jq -r '.overall_assessment' "$TEST_DIR/tc01.json")" = "fix-needed" ] \
  && pass "assessment stays fix-needed" || fail "assessment changed"

# ---- TC-02 (T-02/AC-2): class B 指定の finding は B と記録される ----
echo "TC-02: class B の判定記録 (シナリオ無し指摘)"
f1=$(mk_finding "F-01" "HIGH" "current-pr" "実行時帰結あり")
f2=$(mk_finding "F-02" "MEDIUM" "current-pr" "コメント文言の同期漏れ")
mk_json "$TEST_DIR/tc02.json" "$f1" "$f2"
mk_cls "$TEST_DIR/tc02-cls.json" \
  "$(mk_entry F-01 A "放置すると helper が誤動作する")" \
  "$(mk_entry F-02 B "文書整合のみで実行時挙動は変わらない")"
run_gate "$TEST_DIR/tc02.json" "$TEST_DIR/tc02-cls.json"
[ "$(jq -r '.findings[1].consequence_class' "$TEST_DIR/tc02.json")" = "B" ] \
  && pass "consequence_class=B recorded" || fail "consequence_class not B"
[ "$(jq -r '.findings[1].consequence_scenario' "$TEST_DIR/tc02.json")" = "文書整合のみで実行時挙動は変わらない" ] \
  && pass "consequence_scenario recorded" || fail "scenario missing"

# ---- TC-03 (T-03/AC-3): A=0 で B 全降格 + mergeable ----
echo "TC-03: A=0 での B 全降格 + mergeable"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "pin 精度")
f2=$(mk_finding "F-02" "LOW" "follow-up" "文言")
f3=$(mk_finding "F-03" "LOW" "nit-noted" "nit")
mk_json "$TEST_DIR/tc03.json" "$f1" "$f2" "$f3"
mk_cls "$TEST_DIR/tc03-cls.json" \
  "$(mk_entry F-01 B "検出網の粒度に留まる")" \
  "$(mk_entry F-02 B "文書整合に留まる")"
run_gate "$TEST_DIR/tc03.json" "$TEST_DIR/tc03-cls.json"
grep -q "CLASS_DEMOTION_GATE=applied; class_a=0; class_b=2; demoted=2; assessment=mergeable" <<<"$GATE_STDERR" \
  && pass "applied marker" || fail "marker mismatch: $GATE_STDERR"
[ "$(jq -r '.overall_assessment' "$TEST_DIR/tc03.json")" = "mergeable" ] \
  && pass "assessment=mergeable" || fail "assessment not mergeable"
[ "$(jq -r '.verdict' "$TEST_DIR/tc03.json")" = "mergeable" ] \
  && pass "verdict=mergeable" || fail "verdict not mergeable"
[ "$(jq -r '.non_blocking_findings | length' "$TEST_DIR/tc03.json")" = "2" ] \
  && pass "both class B moved" || fail "move count wrong"
[ "$(jq -r '.findings | length' "$TEST_DIR/tc03.json")" = "1" ] \
  && pass "nit-noted stays in findings" || fail "findings count wrong"
[ "$(jq -r '.findings[0].id' "$TEST_DIR/tc03.json")" = "F-03" ] \
  && pass "remaining finding is nit-noted" || fail "wrong finding remained"
[ "$(jq -r '.findings[0] | has("consequence_class")' "$TEST_DIR/tc03.json")" = "false" ] \
  && pass "nit-noted not classified" || fail "nit-noted was classified"

# ---- TC-04 (T-04/AC-4): A>=1 で非発動 ----
echo "TC-04: A>=1 での非発動"
f1=$(mk_finding "F-01" "HIGH" "current-pr" "実行時帰結あり")
f2=$(mk_finding "F-02" "MEDIUM" "current-pr" "文言")
mk_json "$TEST_DIR/tc04.json" "$f1" "$f2"
mk_cls "$TEST_DIR/tc04-cls.json" \
  "$(mk_entry F-01 A "放置すると誤動作する")" \
  "$(mk_entry F-02 B "文書整合に留まる")"
run_gate "$TEST_DIR/tc04.json" "$TEST_DIR/tc04-cls.json"
grep -q "CLASS_DEMOTION_GATE=not-triggered; class_a=1; class_b=1; demoted=0; assessment=fix-needed" <<<"$GATE_STDERR" \
  && pass "not-triggered marker" || fail "marker mismatch: $GATE_STDERR"
[ "$(jq -r '.findings | length' "$TEST_DIR/tc04.json")" = "2" ] \
  && pass "all findings stay blocking" || fail "findings were moved"
[ "$(jq -r '.non_blocking_findings | length' "$TEST_DIR/tc04.json")" = "0" ] \
  && pass "no demotion" || fail "unexpected demotion"

# ---- TC-05 (T-05/AC-5): record + 監査フラグ ----
echo "TC-05: demotion record と監査フラグ"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "pin 精度")
mk_json "$TEST_DIR/tc05.json" "$f1"
mk_cls "$TEST_DIR/tc05-cls.json" "$(mk_entry F-01 B "検出網の粒度に留まる")"
run_gate "$TEST_DIR/tc05.json" "$TEST_DIR/tc05-cls.json"
[ "$(jq -r '.non_blocking_findings[0].demotion.policy' "$TEST_DIR/tc05.json")" = "class-b-demotion" ] \
  && pass "demotion.policy" || fail "demotion.policy missing"
[ "$(jq -r '.non_blocking_findings[0].demotion.reason' "$TEST_DIR/tc05.json")" = "検出網の粒度に留まる" ] \
  && pass "demotion.reason = 判定文" || fail "demotion.reason missing"
[ "$(jq -r '.non_blocking_findings[0].id' "$TEST_DIR/tc05.json")" = "F-01" ] \
  && pass "id preserved" || fail "id changed"
[ "$(jq -r '.non_blocking_findings[0].severity' "$TEST_DIR/tc05.json")" = "MEDIUM" ] \
  && pass "severity preserved" || fail "severity changed"
[ "$(jq -r '.non_blocking_findings[0].scope' "$TEST_DIR/tc05.json")" = "current-pr" ] \
  && pass "scope preserved" || fail "scope changed"
[ "$(jq -c '.class_demotion' "$TEST_DIR/tc05.json")" = '{"applied":true,"class_a":0,"class_b":1,"demoted":1}' ] \
  && pass "class_demotion audit flag" || fail "class_demotion wrong: $(jq -c '.class_demotion' "$TEST_DIR/tc05.json")"

# ---- TC-06 (T-06/AC-6): 判定不能 → A 扱い + WARNING ----
echo "TC-06: 判定不能の安全側 (欠落 / class 不正 / B の判定文欠落 / 重複)"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "エントリ欠落")
f2=$(mk_finding "F-02" "MEDIUM" "current-pr" "class 不正")
f3=$(mk_finding "F-03" "MEDIUM" "current-pr" "B で判定文なし")
f4=$(mk_finding "F-04" "MEDIUM" "current-pr" "重複エントリ")
mk_json "$TEST_DIR/tc06.json" "$f1" "$f2" "$f3" "$f4"
mk_cls "$TEST_DIR/tc06-cls.json" \
  "$(mk_entry F-02 C "不正クラス")" \
  "$(jq -n '{id:"F-03", class:"B", scenario:""}')" \
  "$(mk_entry F-04 B "1 回目")" \
  "$(mk_entry F-04 B "2 回目")"
run_gate "$TEST_DIR/tc06.json" "$TEST_DIR/tc06-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "rc=0 (per-finding fail-safe, not hard fail)" || fail "rc=$GATE_RC"
grep -q "CLASS_DEMOTION_UNCLASSIFIED=1; count=4" <<<"$GATE_STDERR" \
  && pass "UNCLASSIFIED marker count=4" || fail "marker mismatch: $GATE_STDERR"
grep -q "WARNING" <<<"$GATE_STDERR" && pass "WARNING emitted" || fail "no WARNING"
[ "$(jq -r '[.findings[] | select(.consequence_class == "A")] | length' "$TEST_DIR/tc06.json")" = "4" ] \
  && pass "all 4 treated as class A" || fail "not all class A"
[ "$(jq -r '.non_blocking_findings | length' "$TEST_DIR/tc06.json")" = "0" ] \
  && pass "no silent demotion" || fail "silent demotion occurred"
[ "$(jq -r '[.findings[] | select(has("consequence_scenario"))] | length' "$TEST_DIR/tc06.json")" = "0" ] \
  && pass "no scenario for unclassified" || fail "unexpected scenario"

# ---- TC-07: noop (blocking 0 件) + 降格発動後の冪等性 ----
echo "TC-07: noop と冪等性"
f1=$(mk_finding "F-01" "LOW" "nit-noted" "nit のみ")
mk_json "$TEST_DIR/tc07.json" "$f1"
mk_cls "$TEST_DIR/tc07-cls.json"
before=$(cat "$TEST_DIR/tc07.json")
run_gate "$TEST_DIR/tc07.json" "$TEST_DIR/tc07-cls.json"
grep -q "CLASS_DEMOTION_GATE=noop; reason=no_blocking" <<<"$GATE_STDERR" \
  && pass "noop marker" || fail "marker mismatch: $GATE_STDERR"
[ "$(cat "$TEST_DIR/tc07.json")" = "$before" ] \
  && pass "JSON unchanged on noop" || fail "JSON was modified"
# 降格発動後の JSON への再実行 → blocking 0 で noop (map 不在でも成功する)
run_gate "$TEST_DIR/tc03.json" "$TEST_DIR/nonexistent-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "re-run after demotion rc=0" || fail "re-run rc=$GATE_RC"
grep -q "CLASS_DEMOTION_GATE=noop" <<<"$GATE_STDERR" \
  && pass "re-run is noop (idempotent)" || fail "re-run not noop: $GATE_STDERR"

# ---- TC-08: preset 上書き (consequence_class の先書きは判定を変えない) ----
echo "TC-08: preset consequence_class は map の算出で上書きされる"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "preset 済み" | jq '. + {consequence_class: "B", consequence_scenario: "先書き"}')
mk_json "$TEST_DIR/tc08.json" "$f1"
mk_cls "$TEST_DIR/tc08-cls.json" "$(mk_entry F-01 A "放置すると誤動作する")"
run_gate "$TEST_DIR/tc08.json" "$TEST_DIR/tc08-cls.json"
[ "$(jq -r '.findings[0].consequence_class' "$TEST_DIR/tc08.json")" = "A" ] \
  && pass "preset overwritten by map" || fail "preset survived"
grep -q "CLASS_DEMOTION_GATE=not-triggered; class_a=1" <<<"$GATE_STDERR" \
  && pass "preset does not bypass gate" || fail "gate bypassed"

# ---- TC-09: 入力検証の hard fail ----
echo "TC-09: 入力検証 (classification 不在 / 構造不正)"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "desc")
mk_json "$TEST_DIR/tc09.json" "$f1"
run_gate "$TEST_DIR/tc09.json" "$TEST_DIR/nonexistent-cls.json"
[ "$GATE_RC" -eq 1 ] && pass "missing map rc=1" || fail "rc=$GATE_RC (expected 1)"
grep -q "CLASS_DEMOTION_GATE_FAILED=1; reason=classification_missing" <<<"$GATE_STDERR" \
  && pass "reason=classification_missing" || fail "reason mismatch: $GATE_STDERR"
echo '{"classifications": "not-an-array"}' > "$TEST_DIR/tc09-bad.json"
run_gate "$TEST_DIR/tc09.json" "$TEST_DIR/tc09-bad.json"
[ "$GATE_RC" -eq 1 ] && pass "non-array rc=1" || fail "rc=$GATE_RC (expected 1)"
grep -q "reason=classifications_not_array" <<<"$GATE_STDERR" \
  && pass "reason=classifications_not_array" || fail "reason mismatch: $GATE_STDERR"
# hard fail 経路では JSON が書き換えられない
[ "$(jq -r '.findings[0] | has("consequence_class")' "$TEST_DIR/tc09.json")" = "false" ] \
  && pass "JSON untouched on hard fail" || fail "JSON was modified on hard fail"

# ---- TC-10: 既存 non_blocking_findings の保持 (append 移送) ----
echo "TC-10: 実測ゲート降格分と共存 (append)"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "pin 精度")
mk_json "$TEST_DIR/tc10.json" "$f1"
existing_nb=$(mk_finding "F-90" "LOW" "current-pr" "実測ゲート降格分")
jq --argjson nb "$existing_nb" '.non_blocking_findings = [$nb]' "$TEST_DIR/tc10.json" > "$TEST_DIR/tc10.tmp" \
  && mv "$TEST_DIR/tc10.tmp" "$TEST_DIR/tc10.json"
mk_cls "$TEST_DIR/tc10-cls.json" "$(mk_entry F-01 B "検出網の粒度に留まる")"
run_gate "$TEST_DIR/tc10.json" "$TEST_DIR/tc10-cls.json"
[ "$(jq -r '.non_blocking_findings | length' "$TEST_DIR/tc10.json")" = "2" ] \
  && pass "existing entry preserved" || fail "existing entry lost"
[ "$(jq -r '.non_blocking_findings[0].id' "$TEST_DIR/tc10.json")" = "F-90" ] \
  && pass "measured-gate entry first" || fail "order changed"
[ "$(jq -r '.non_blocking_findings[0] | has("demotion")' "$TEST_DIR/tc10.json")" = "false" ] \
  && pass "measured-gate entry has no demotion key" || fail "demotion leaked"
[ "$(jq -r '.non_blocking_findings[1] | has("demotion")' "$TEST_DIR/tc10.json")" = "true" ] \
  && pass "class-b entry has demotion key" || fail "demotion missing"

# ---- TC-12: 実測未判定の gated finding は書き換え前に fail-loud ----
echo "TC-12: 実測未判定 → measured_undetermined で停止し JSON 不変"
f1=$(mk_finding "F-01" "HIGH" "current-pr" "実測判定を欠く CRITICAL 級指摘" "plugins/rite/hooks/foo.sh" "none")
f2=$(mk_finding "F-02" "MEDIUM" "current-pr" "実測済みの文言同期指摘")
mk_json "$TEST_DIR/tc12.json" "$f1" "$f2"
mk_cls "$TEST_DIR/tc12-cls.json" \
  "$(mk_entry F-01 B "文書整合に留まる")" \
  "$(mk_entry F-02 B "文書整合に留まる")"
cp "$TEST_DIR/tc12.json" "$TEST_DIR/tc12-before.json"
run_gate "$TEST_DIR/tc12.json" "$TEST_DIR/tc12-cls.json"
[ "$GATE_RC" -eq 1 ] && pass "rc=1" || fail "rc=$GATE_RC (expected 1)"
grep -q "CLASS_DEMOTION_GATE_FAILED=1; reason=measured_undetermined; count=1; findings=F-01" <<<"$GATE_STDERR" \
  && pass "reason/count/findings marker" || fail "marker mismatch: $GATE_STDERR"
grep -q "/rite:pr-review を再実行" <<<"$GATE_STDERR" \
  && pass "recovery hint emitted" || fail "recovery hint missing: $GATE_STDERR"
cmp -s "$TEST_DIR/tc12.json" "$TEST_DIR/tc12-before.json" \
  && pass "JSON byte-identical on measured error" || fail "JSON changed on measured error"
retired_marker="CLASS_DEMOTION_"'UNDETERMINED_MEASURED'
if grep -q "$retired_marker" <<<"$GATE_STDERR"; then
  fail "retired marker emitted"
else
  pass "retired marker absent"
fi

# classification map が同時に不在でも、修復不能な measured 契約違反を先に報告する。
run_gate "$TEST_DIR/tc12.json" "$TEST_DIR/nonexistent-cls.json"
grep -q "reason=measured_undetermined" <<<"$GATE_STDERR" \
  && pass "measured error precedes map validation" || fail "measured reason missing: $GATE_STDERR"
if grep -q "reason=classification_missing" <<<"$GATE_STDERR"; then
  fail "map retry reason won over measured error"
else
  pass "map retry reason not selected"
fi

echo "TC-12b: verification の空 object / measured=null も同じ reason で停止"
for shape in empty_object null_measured; do
  if [ "$shape" = "empty_object" ]; then
    boundary=$(mk_finding "F-03" "MEDIUM" "current-pr" "verification が空 object" "plugins/rite/hooks/foo.sh" "none" | jq '.verification = {}')
  else
    boundary=$(mk_finding "F-04" "MEDIUM" "current-pr" "measured が null" "plugins/rite/hooks/foo.sh" "none" | jq '.verification = {measured:null}')
  fi
  mk_json "$TEST_DIR/tc12-$shape.json" "$boundary"
  mk_cls "$TEST_DIR/tc12-$shape-cls.json" "$(mk_entry "$(jq -r '.id' <<<"$boundary")" B "文書整合に留まる")"
  cp "$TEST_DIR/tc12-$shape.json" "$TEST_DIR/tc12-$shape-before.json"
  run_gate "$TEST_DIR/tc12-$shape.json" "$TEST_DIR/tc12-$shape-cls.json"
  [ "$GATE_RC" -eq 1 ] && pass "$shape rc=1" || fail "$shape rc=$GATE_RC"
  grep -q "reason=measured_undetermined; count=1; findings=$(jq -r '.id' <<<"$boundary")" <<<"$GATE_STDERR" \
    && pass "$shape reason/id" || fail "$shape marker mismatch: $GATE_STDERR"
  cmp -s "$TEST_DIR/tc12-$shape.json" "$TEST_DIR/tc12-$shape-before.json" \
    && pass "$shape JSON unchanged" || fail "$shape JSON changed"
done

echo "TC-12c: measured=false は boolean、nit-noted の verification 欠落は対象外"
f1=$(mk_finding "F-05" "MEDIUM" "current-pr" "boolean false の gated finding" "plugins/rite/hooks/foo.sh" "false")
f2=$(mk_finding "F-06" "LOW" "nit-noted" "verification を持たない nit" "plugins/rite/hooks/foo.sh" "none")
mk_json "$TEST_DIR/tc12-bool.json" "$f1" "$f2"
mk_cls "$TEST_DIR/tc12-bool-cls.json" "$(mk_entry F-05 B "文書整合に留まる")"
run_gate "$TEST_DIR/tc12-bool.json" "$TEST_DIR/tc12-bool-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "boolean false and nit-noted accepted" || fail "rc=$GATE_RC: $GATE_STDERR"
grep -q "CLASS_DEMOTION_GATE=applied; class_a=0; class_b=1; demoted=1" <<<"$GATE_STDERR" \
  && pass "boolean false follows classification path" || fail "classification marker mismatch: $GATE_STDERR"
[ "$(jq -r '.findings[0].id' "$TEST_DIR/tc12-bool.json")" = "F-06" ] \
  && pass "nit-noted remains outside gate" || fail "nit-noted was gated"

# ---- TC-13: classification map の非 object 要素は専用 reason で fail-loud ----
# generic な jq_transform_failed (誤診断 + retry 対象外) に落とさない
echo "TC-13: map の非 object 要素 → classification_entry_not_object"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "desc")
mk_json "$TEST_DIR/tc13.json" "$f1"
printf '%s\n' '{"classifications": [{"id":"F-01","class":"B","scenario":"ok"}, "F-02 is class B"]}' > "$TEST_DIR/tc13-cls.json"
run_gate "$TEST_DIR/tc13.json" "$TEST_DIR/tc13-cls.json"
[ "$GATE_RC" -eq 1 ] && pass "rc=1" || fail "rc=$GATE_RC (expected 1)"
grep -q "reason=classification_entry_not_object" <<<"$GATE_STDERR" \
  && pass "reason=classification_entry_not_object" || fail "reason mismatch: $GATE_STDERR"
[ "$(jq -r '.findings[0] | has("consequence_class")' "$TEST_DIR/tc13.json")" = "false" ] \
  && pass "JSON untouched on entry-type fail" || fail "JSON was modified"

# ---- TC-11: 他トップレベルキーの保持 ----
echo "TC-11: 変換がトップレベルの他キーを保持する"
[ "$(jq -r '.reviewers | length' "$TEST_DIR/tc10.json")" = "2" ] \
  && pass "reviewers preserved" || fail "reviewers lost"
[ "$(jq -r '.commit_sha' "$TEST_DIR/tc10.json")" = "0123456789abcdef0123456789abcdef01234567" ] \
  && pass "commit_sha preserved" || fail "commit_sha lost"
[ "$(jq -r 'has("guardrail_audit_log")' "$TEST_DIR/tc10.json")" = "true" ] \
  && pass "guardrail_audit_log preserved" || fail "guardrail_audit_log lost"

# ---- TC-14 (T-01/AC-1, T-04/AC-4): A=0 でも除外付き class B は blocking 維持 ----
# base 側 README 禁止文の削除は class B（実行時シナリオは書けない）でも降格しない。
echo "TC-14: A=0 の除外付き class B は blocking 維持 + 除外判定文を記録"
f1=$(mk_finding "F-01" "HIGH" "current-pr" "base 側 README の禁止文が本 PR で削除された")
mk_json "$TEST_DIR/tc14.json" "$f1"
mk_cls "$TEST_DIR/tc14-cls.json" \
  "$(mk_entry_excl F-01 B "文書整合に留まり実行時シナリオは書けない" "base 側 README の禁止文「X してはならない」が本 PR の diff で削除された")"
run_gate "$TEST_DIR/tc14.json" "$TEST_DIR/tc14-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "rc=0" || fail "rc=$GATE_RC (expected 0)"
grep -q "CLASS_DEMOTION_GATE=not-triggered; class_a=0; class_b=1; demoted=0; assessment=fix-needed" <<<"$GATE_STDERR" \
  && pass "not-triggered (excluded B remains blocking)" || fail "marker mismatch: $GATE_STDERR"
[ "$(jq -r '.findings | length' "$TEST_DIR/tc14.json")" = "1" ] \
  && pass "finding stays blocking" || fail "finding was moved"
[ "$(jq -r '.non_blocking_findings | length' "$TEST_DIR/tc14.json")" = "0" ] \
  && pass "not transferred to non_blocking" || fail "unexpected demotion"
[ "$(jq -r '.findings[0].consequence_class' "$TEST_DIR/tc14.json")" = "B" ] \
  && pass "stays class B" || fail "class changed"
[ "$(jq -r '.findings[0].consequence_exclusion' "$TEST_DIR/tc14.json")" = "base 側 README の禁止文「X してはならない」が本 PR の diff で削除された" ] \
  && pass "consequence_exclusion recorded" || fail "exclusion audit missing"
[ "$(jq -r '.overall_assessment' "$TEST_DIR/tc14.json")" = "fix-needed" ] \
  && pass "assessment stays fix-needed" || fail "assessment changed"

# ---- TC-15 (T-02/AC-2): 混在 — 除外なし B は降格、除外付き B は残る ----
echo "TC-15: A=0 混在 (除外なし B は降格 / 除外付き B は blocking)"
f1=$(mk_finding "F-01" "HIGH" "current-pr" "base 側禁止文の削除")
f2=$(mk_finding "F-02" "MEDIUM" "current-pr" "新規追加文の pin 精度")
mk_json "$TEST_DIR/tc15.json" "$f1" "$f2"
mk_cls "$TEST_DIR/tc15-cls.json" \
  "$(mk_entry_excl F-01 B "文書整合に留まる" "base 側の禁止文が本 PR の diff で削除された")" \
  "$(mk_entry F-02 B "検出網の粒度に留まる")"
run_gate "$TEST_DIR/tc15.json" "$TEST_DIR/tc15-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "rc=0" || fail "rc=$GATE_RC (expected 0)"
grep -q "CLASS_DEMOTION_GATE=applied; class_a=0; class_b=2; demoted=1; assessment=fix-needed" <<<"$GATE_STDERR" \
  && pass "applied demotes only non-excluded B" || fail "marker mismatch: $GATE_STDERR"
[ "$(jq -r '.findings | length' "$TEST_DIR/tc15.json")" = "1" ] \
  && pass "excluded B stays in findings" || fail "findings count wrong"
[ "$(jq -r '.findings[0].id' "$TEST_DIR/tc15.json")" = "F-01" ] \
  && pass "remaining finding is excluded B" || fail "wrong finding remained"
[ "$(jq -r '.non_blocking_findings | length' "$TEST_DIR/tc15.json")" = "1" ] \
  && pass "non-excluded B demoted" || fail "demote count wrong"
[ "$(jq -r '.non_blocking_findings[0].id' "$TEST_DIR/tc15.json")" = "F-02" ] \
  && pass "demoted id is F-02" || fail "wrong finding demoted"
[ "$(jq -r '.non_blocking_findings[0].demotion.policy' "$TEST_DIR/tc15.json")" = "class-b-demotion" ] \
  && pass "demotion.policy on wording finding" || fail "demotion missing on wording finding"
[ "$(jq -r '.findings[0] | has("demotion")' "$TEST_DIR/tc15.json")" = "false" ] \
  && pass "excluded B has no demotion key" || fail "demotion leaked onto excluded B"
[ "$(jq -c '.class_demotion' "$TEST_DIR/tc15.json")" = '{"applied":true,"class_a":0,"class_b":2,"demoted":1}' ] \
  && pass "class_demotion reflects partial demotion" || fail "class_demotion wrong: $(jq -c '.class_demotion' "$TEST_DIR/tc15.json")"

# ---- TC-16 (T-03/AC-3): exclusion 不正 → 判定不能 = class A + WARNING ----
echo "TC-16: exclusion 不正 (空文字 / 非文字列) は class A 扱い + WARNING"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "exclusion 空文字")
f2=$(mk_finding "F-02" "MEDIUM" "current-pr" "exclusion が数値")
mk_json "$TEST_DIR/tc16.json" "$f1" "$f2"
mk_cls "$TEST_DIR/tc16-cls.json" \
  "$(jq -n '{id:"F-01", class:"B", scenario:"文書整合に留まる", exclusion:""}')" \
  "$(jq -n '{id:"F-02", class:"B", scenario:"文書整合に留まる", exclusion:1}')"
run_gate "$TEST_DIR/tc16.json" "$TEST_DIR/tc16-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "rc=0 (per-finding fail-safe)" || fail "rc=$GATE_RC"
grep -q "CLASS_DEMOTION_UNCLASSIFIED=1; count=2" <<<"$GATE_STDERR" \
  && pass "UNCLASSIFIED marker count=2" || fail "marker mismatch: $GATE_STDERR"
grep -q "WARNING" <<<"$GATE_STDERR" && pass "WARNING emitted" || fail "no WARNING"
[ "$(jq -r '[.findings[] | select(.consequence_class == "A")] | length' "$TEST_DIR/tc16.json")" = "2" ] \
  && pass "both treated as class A" || fail "not all class A"
[ "$(jq -r '.non_blocking_findings | length' "$TEST_DIR/tc16.json")" = "0" ] \
  && pass "no silent demotion" || fail "silent demotion occurred"
[ "$(jq -r '[.findings[] | select(has("consequence_exclusion"))] | length' "$TEST_DIR/tc16.json")" = "0" ] \
  && pass "no exclusion recorded for unclassified" || fail "unexpected consequence_exclusion"

# ---- TC-17: number_reference は map B でも class A 固定 ----
echo "TC-17: number_reference の map B を class A に固定"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "番号入り追加行" "plugins/rite/skills/pr-review/SKILL.md" "true" "number_reference")
mk_json "$TEST_DIR/tc17.json" "$f1"
mk_cls "$TEST_DIR/tc17-cls.json" "$(mk_entry F-01 B "文書整合に留まる")"
run_gate "$TEST_DIR/tc17.json" "$TEST_DIR/tc17-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "rc=0" || fail "rc=$GATE_RC"
grep -q "CLASS_DEMOTION_GATE=not-triggered; class_a=1; class_b=0; demoted=0; assessment=fix-needed" <<<"$GATE_STDERR" \
  && pass "number_reference stays blocking" || fail "marker mismatch: $GATE_STDERR"
grep -q "CLASS_DEMOTION_CATEGORY_PINNED=1; count=1" <<<"$GATE_STDERR" \
  && pass "CATEGORY_PINNED marker" || fail "marker missing: $GATE_STDERR"
grep -q "WARNING" <<<"$GATE_STDERR" && pass "WARNING emitted" || fail "WARNING missing"
[ "$(jq -r '.findings | length' "$TEST_DIR/tc17.json")" = "1" ] && pass "finding remains" || fail "finding moved"
[ "$(jq -r '.non_blocking_findings | length' "$TEST_DIR/tc17.json")" = "0" ] && pass "not demoted" || fail "finding demoted"
[ "$(jq -r '.findings[0].consequence_class' "$TEST_DIR/tc17.json")" = "A" ] && pass "consequence_class=A" || fail "class not pinned"

# 固定 A が同一 cycle の通常 B の降格も阻止する。
f2=$(mk_finding "F-02" "LOW" "current-pr" "通常の文書整合")
mk_json "$TEST_DIR/tc17-mixed.json" "$f1" "$f2"
mk_cls "$TEST_DIR/tc17-mixed-cls.json" "$(mk_entry F-01 B "文書整合に留まる")" "$(mk_entry F-02 B "文書整合に留まる")"
run_gate "$TEST_DIR/tc17-mixed.json" "$TEST_DIR/tc17-mixed-cls.json"
grep -q "CLASS_DEMOTION_GATE=not-triggered; class_a=1; class_b=1; demoted=0; assessment=fix-needed" <<<"$GATE_STDERR" \
  && pass "pinned A blocks ordinary B demotion" || fail "mixed marker mismatch: $GATE_STDERR"
[ "$(jq -r '.findings | length' "$TEST_DIR/tc17-mixed.json")" = "2" ] && pass "mixed findings remain" || fail "mixed finding moved"

# ---- TC-18: number_reference の map A は従来どおり ----
echo "TC-18: number_reference の map A で marker なし"
mk_json "$TEST_DIR/tc18.json" "$f1"
mk_cls "$TEST_DIR/tc18-cls.json" "$(mk_entry F-01 A "番号参照ゲートが見逃す")"
run_gate "$TEST_DIR/tc18.json" "$TEST_DIR/tc18-cls.json"
grep -q "CLASS_DEMOTION_GATE=not-triggered; class_a=1; class_b=0; demoted=0; assessment=fix-needed" <<<"$GATE_STDERR" \
  && pass "map A unchanged" || fail "marker mismatch: $GATE_STDERR"
! grep -q "CLASS_DEMOTION_CATEGORY_PINNED" <<<"$GATE_STDERR" && pass "no PINNED marker" || fail "unexpected PINNED marker"

# ---- TC-19: 他 category の class B は従来どおり降格 ----
echo "TC-19: code_quality の map B は降格"
f2=$(mk_finding "F-02" "LOW" "current-pr" "通常の文書整合")
mk_json "$TEST_DIR/tc19.json" "$f2"
mk_cls "$TEST_DIR/tc19-cls.json" "$(mk_entry F-02 B "文書整合に留まる")"
run_gate "$TEST_DIR/tc19.json" "$TEST_DIR/tc19-cls.json"
grep -q "CLASS_DEMOTION_GATE=applied; class_a=0; class_b=1; demoted=1; assessment=mergeable" <<<"$GATE_STDERR" \
  && pass "other category still demoted" || fail "marker mismatch: $GATE_STDERR"

# ---- TC-20: map 欠落は UNCLASSIFIED のみ ----
echo "TC-20: number_reference の map 欠落は UNCLASSIFIED のみ"
mk_json "$TEST_DIR/tc20.json" "$f1"
mk_cls "$TEST_DIR/tc20-cls.json"
run_gate "$TEST_DIR/tc20.json" "$TEST_DIR/tc20-cls.json"
grep -q "CLASS_DEMOTION_UNCLASSIFIED=1; count=1" <<<"$GATE_STDERR" && pass "UNCLASSIFIED marker" || fail "UNCLASSIFIED missing"
! grep -q "CLASS_DEMOTION_CATEGORY_PINNED" <<<"$GATE_STDERR" && pass "no PINNED marker" || fail "unexpected PINNED marker"
[ "$(jq -r '.findings[0].consequence_class' "$TEST_DIR/tc20.json")" = "A" ] && pass "missing map stays A" || fail "missing map class changed"

# ---- Static contract: pr-review routing と廃止語彙の全数除去 ----
# ---- 合意済み AC の実測済み未充足: acceptance_criteria[] の unmet 行が第 2 の除外入力源 ----
# $1 = JSON path, $2 = acceptance_criteria の JSON 値
set_ac() {
  jq --argjson ac "$2" '.acceptance_criteria = $ac' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ---- TC-21: map が class B・exclusion なしでも unmet 行の finding は blocking に残る ----
echo "TC-21: unmet 行が指す class B は blocking 維持 + ac_unmet を記録"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "README の手順が実装と同期していない")
mk_json "$TEST_DIR/tc21.json" "$f1"
set_ac "$TEST_DIR/tc21.json" '[{"id":"AC-1","status":"unmet","finding_id":"F-01","evidence":"指摘事項 [AC-1] を参照"}]'
mk_cls "$TEST_DIR/tc21-cls.json" "$(mk_entry F-01 B "文書整合に留まる")"
run_gate "$TEST_DIR/tc21.json" "$TEST_DIR/tc21-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "rc=0" || fail "rc=$GATE_RC (expected 0)"
grep -qxF "[CONTEXT] CLASS_DEMOTION_GATE=not-triggered; class_a=0; class_b=1; demoted=0; assessment=fix-needed" <<<"$GATE_STDERR" \
  && pass "marker not-triggered (exact)" || fail "marker mismatch: $GATE_STDERR"
[ "$(jq -c '[.findings[] | {id, scope, consequence_class, consequence_exclusion}]' "$TEST_DIR/tc21.json")" \
  = '[{"id":"F-01","scope":"current-pr","consequence_class":"B","consequence_exclusion":"ac_unmet:AC-1"}]' ] \
  && pass "finding stays blocking as class B with ac_unmet:AC-1" || fail "finding wrong: $(jq -c '.findings' "$TEST_DIR/tc21.json")"
[ "$(jq -r '"\(.verdict) \(.overall_assessment) \(.non_blocking_findings | length) \(.class_demotion.demoted)"' "$TEST_DIR/tc21.json")" = "fix-needed fix-needed 0 0" ] \
  && pass "verdict fix-needed, nothing demoted" || fail "verdict/demotion wrong"
[ "$(jq -c '.acceptance_criteria' "$TEST_DIR/tc21.json")" = '[{"id":"AC-1","status":"unmet","finding_id":"F-01","evidence":"指摘事項 [AC-1] を参照"}]' ] \
  && pass "acceptance_criteria preserved" || fail "acceptance_criteria changed"

# ---- TC-22: 部分降格 — 除外なし B は降格、unmet の B は残り final 検査を通る ----
echo "TC-22: unmet の B は残り、除外なし B だけ降格する (final 検査が通過する)"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "[AC-1] README の手順が実装と同期していない")
f2=$(mk_finding "F-02" "LOW" "current-pr" "新規追加文の pin 精度")
mk_json "$TEST_DIR/tc22.json" "$f1" "$f2"
jq '.reviewers += ["acceptance-reviewer"] | .findings[0].reviewer = "acceptance-reviewer" | .measured_gate = {commit_sha: .commit_sha}' "$TEST_DIR/tc22.json" > "$TEST_DIR/tc22.tmp" \
  && mv "$TEST_DIR/tc22.tmp" "$TEST_DIR/tc22.json"
set_ac "$TEST_DIR/tc22.json" '[{"id":"AC-1","status":"unmet","finding_id":"F-01","evidence":"指摘事項 [AC-1] を参照"}]'
mk_cls "$TEST_DIR/tc22-cls.json" "$(mk_entry F-01 B "文書整合に留まる")" "$(mk_entry F-02 B "検出網の粒度に留まる")"
run_gate "$TEST_DIR/tc22.json" "$TEST_DIR/tc22-cls.json"
grep -qxF "[CONTEXT] CLASS_DEMOTION_GATE=applied; class_a=0; class_b=2; demoted=1; assessment=fix-needed" <<<"$GATE_STDERR" \
  && pass "marker applied partial (exact)" || fail "marker mismatch: $GATE_STDERR"
[ "$(jq -c '[[.findings[].id], [.non_blocking_findings[].id]]' "$TEST_DIR/tc22.json")" = '[["F-01"],["F-02"]]' ] \
  && pass "F-01 blocking / F-02 demoted" || fail "sets wrong: $(jq -c '[[.findings[].id], [.non_blocking_findings[].id]]' "$TEST_DIR/tc22.json")"
bash "$SCRIPT_DIR/../acceptance-criteria-check.sh" final --expected AC-1 --input "$TEST_DIR/tc22.json" 2>"$TEST_DIR/tc22-final.err"
final_rc=$?
[ "$final_rc" -eq 0 ] && pass "acceptance-criteria-check final passes" || fail "final rc=$final_rc: $(cat "$TEST_DIR/tc22-final.err")"

# ---- TC-23: map の exclusion 文言は ac_unmet で上書きしない ----
echo "TC-23: map exclusion がある B は map の判定文を保持"
f1=$(mk_finding "F-01" "HIGH" "current-pr" "base 側禁止文の削除")
mk_json "$TEST_DIR/tc23.json" "$f1"
set_ac "$TEST_DIR/tc23.json" '[{"id":"AC-1","status":"unmet","finding_id":"F-01","evidence":"e"}]'
mk_cls "$TEST_DIR/tc23-cls.json" "$(mk_entry_excl F-01 B "文書整合に留まる" "base 側の禁止文が本 PR の diff で削除された")"
run_gate "$TEST_DIR/tc23.json" "$TEST_DIR/tc23-cls.json"
[ "$(jq -r '.findings[0].consequence_exclusion' "$TEST_DIR/tc23.json")" = "base 側の禁止文が本 PR の diff で削除された" ] \
  && pass "map exclusion kept" || fail "exclusion overwritten: $(jq -r '.findings[0].consequence_exclusion' "$TEST_DIR/tc23.json")"

# ---- TC-24: 同じ finding を指す複数の unmet 行は行順に連結する ----
echo "TC-24: 複数 unmet 行は ac_unmet:AC-3,AC-1 (行順)"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "文書同期")
mk_json "$TEST_DIR/tc24.json" "$f1"
set_ac "$TEST_DIR/tc24.json" '[{"id":"AC-3","status":"unmet","finding_id":"F-01","evidence":"e"},{"id":"AC-2","status":"satisfied","finding_id":null,"evidence":"e"},{"id":"AC-1","status":"unmet","finding_id":"F-01","evidence":"e"}]'
mk_cls "$TEST_DIR/tc24-cls.json" "$(mk_entry F-01 B "文書整合に留まる")"
run_gate "$TEST_DIR/tc24.json" "$TEST_DIR/tc24-cls.json"
[ "$(jq -r '.findings[0].consequence_exclusion' "$TEST_DIR/tc24.json")" = "ac_unmet:AC-3,AC-1" ] \
  && pass "row-order join" || fail "join wrong: $(jq -r '.findings[0].consequence_exclusion' "$TEST_DIR/tc24.json")"

# ---- TC-25: class A / 判定不能 / category 固定には ac_unmet を記録しない ----
echo "TC-25: unmet 行が class A・判定不能・number_reference を指しても記録なし、観測 marker 不変"
f1=$(mk_finding "F-01" "HIGH" "current-pr" "実行時に壊れる")
f2=$(mk_finding "F-02" "MEDIUM" "current-pr" "map エントリ欠落")
f3=$(mk_finding "F-03" "MEDIUM" "current-pr" "番号入り追加行" "plugins/rite/skills/pr-review/SKILL.md" "true" "number_reference")
mk_json "$TEST_DIR/tc25.json" "$f1" "$f2" "$f3"
set_ac "$TEST_DIR/tc25.json" '[{"id":"AC-1","status":"unmet","finding_id":"F-01","evidence":"e"},{"id":"AC-2","status":"unmet","finding_id":"F-02","evidence":"e"},{"id":"AC-3","status":"unmet","finding_id":"F-03","evidence":"e"}]'
mk_cls "$TEST_DIR/tc25-cls.json" "$(mk_entry F-01 A "実行時に壊れる")" "$(mk_entry F-03 B "文書整合に留まる")"
run_gate "$TEST_DIR/tc25.json" "$TEST_DIR/tc25-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "rc=0" || fail "rc=$GATE_RC (expected 0)"
grep -qxF "[CONTEXT] CLASS_DEMOTION_GATE=not-triggered; class_a=3; class_b=0; demoted=0; assessment=fix-needed" <<<"$GATE_STDERR" \
  && pass "marker not-triggered class_a=3 (exact)" || fail "marker mismatch: $GATE_STDERR"
grep -qxF "[CONTEXT] CLASS_DEMOTION_UNCLASSIFIED=1; count=1" <<<"$GATE_STDERR" \
  && pass "UNCLASSIFIED count=1" || fail "UNCLASSIFIED mismatch: $GATE_STDERR"
grep -qxF "[CONTEXT] CLASS_DEMOTION_CATEGORY_PINNED=1; count=1" <<<"$GATE_STDERR" \
  && pass "CATEGORY_PINNED count=1" || fail "CATEGORY_PINNED mismatch: $GATE_STDERR"
[ "$(jq -r '[.findings[] | select(has("consequence_exclusion"))] | length' "$TEST_DIR/tc25.json")" = "0" ] \
  && pass "no consequence_exclusion on class A" || fail "unexpected consequence_exclusion"

# ---- TC-26: 未充足行が無ければ変更前の helper と byte 一致で降格する ----
# golden は本 fixture を変更前の helper に通した出力 (stdout 側 JSON と stderr marker)。
echo "TC-26: satisfied のみ / finding_id=null の unmet / skip object / キー欠落は従来どおり降格"
cat > "$TEST_DIR/tc26-golden.json" <<'EOF'
{
  "schema_version": "1.1.0",
  "pr_number": 99,
  "timestamp": "2026-08-11T00:00:00Z",
  "commit_sha": "0123456789abcdef0123456789abcdef01234567",
  "overall_assessment": "mergeable",
  "verdict": "mergeable",
  "reviewers": [
    "code-quality-reviewer",
    "acceptance-reviewer"
  ],
  "findings": [],
  "non_blocking_findings": [
    {
      "id": "F-01",
      "reviewer": "acceptance-reviewer",
      "category": "code_quality",
      "severity": "MEDIUM",
      "file": "plugins/rite/hooks/foo.sh",
      "line": 1,
      "description": "[AC-1] 文書同期が未充足",
      "suggestion": "s",
      "status": "open",
      "scope": "current-pr",
      "verification": {
        "measured": true,
        "repro": "bash t.sh => observed failure",
        "failing_test": null
      },
      "consequence_class": "B",
      "consequence_scenario": "文書整合に留まる",
      "demotion": {
        "policy": "class-b-demotion",
        "reason": "文書整合に留まる"
      }
    }
  ],
  "guardrail_audit_log": [],
  "acceptance_criteria": [
    {
      "id": "AC-1",
      "status": "satisfied",
      "finding_id": null,
      "evidence": "e"
    }
  ],
  "class_demotion": {
    "applied": true,
    "class_a": 0,
    "class_b": 1,
    "demoted": 1
  }
}
EOF
tc26_marker="[CONTEXT] CLASS_DEMOTION_GATE=applied; class_a=0; class_b=1; demoted=1; assessment=mergeable"
tc26_input='{"schema_version":"1.1.0","pr_number":99,"timestamp":"2026-08-11T00:00:00Z","commit_sha":"0123456789abcdef0123456789abcdef01234567","overall_assessment":"fix-needed","verdict":"fix-needed","reviewers":["code-quality-reviewer","acceptance-reviewer"],"findings":[{"id":"F-01","reviewer":"acceptance-reviewer","category":"code_quality","severity":"MEDIUM","file":"plugins/rite/hooks/foo.sh","line":1,"description":"[AC-1] 文書同期が未充足","suggestion":"s","status":"open","scope":"current-pr","verification":{"measured":true,"repro":"bash t.sh => observed failure","failing_test":null}}],"non_blocking_findings":[],"guardrail_audit_log":[],"acceptance_criteria":[{"id":"AC-1","status":"satisfied","finding_id":null,"evidence":"e"}]}'
mk_cls "$TEST_DIR/tc26-cls.json" "$(mk_entry F-01 B "文書整合に留まる")"
printf '%s\n' "$tc26_input" > "$TEST_DIR/tc26-satisfied.json"
run_gate "$TEST_DIR/tc26-satisfied.json" "$TEST_DIR/tc26-cls.json"
cmp -s "$TEST_DIR/tc26-satisfied.json" "$TEST_DIR/tc26-golden.json" \
  && pass "satisfied-only output is byte-identical to the pre-change golden" || fail "satisfied-only output differs from golden"
[ "$GATE_STDERR" = "$tc26_marker" ] && pass "satisfied-only stderr is exactly the golden marker" || fail "stderr differs: $GATE_STDERR"
golden_rest=$(jq -S 'del(.acceptance_criteria)' "$TEST_DIR/tc26-golden.json")
for variant in 'unmet-null|[{"id":"AC-1","status":"unmet","finding_id":null,"evidence":"e"}]' \
               'no-issue|{"skipped":"no_issue"}' \
               'no-ac-section|{"skipped":"no_ac_section"}' \
               'absent|'; do
  name="${variant%%|*}"; ac="${variant#*|}"
  if [ -z "$ac" ]; then
    printf '%s\n' "$tc26_input" | jq 'del(.acceptance_criteria)' > "$TEST_DIR/tc26-$name.json"
  else
    printf '%s\n' "$tc26_input" | jq --argjson ac "$ac" '.acceptance_criteria = $ac' > "$TEST_DIR/tc26-$name.json"
  fi
  ac_before=$(jq -cS '.acceptance_criteria' "$TEST_DIR/tc26-$name.json")
  run_gate "$TEST_DIR/tc26-$name.json" "$TEST_DIR/tc26-cls.json"
  [ "$(jq -S 'del(.acceptance_criteria)' "$TEST_DIR/tc26-$name.json")" = "$golden_rest" ] \
    && pass "$name: output equals golden outside acceptance_criteria" || fail "$name: output differs from golden"
  [ "$(jq -cS '.acceptance_criteria' "$TEST_DIR/tc26-$name.json")" = "$ac_before" ] \
    && pass "$name: acceptance_criteria unchanged" || fail "$name: acceptance_criteria changed"
  [ "$GATE_STDERR" = "$tc26_marker" ] && pass "$name: stderr is exactly the golden marker" || fail "$name: stderr differs: $GATE_STDERR"
done

# ---- TC-27: findings[] に無い finding_id は無視して警告し、他 finding の判定は変わらない ----
echo "TC-27: 存在しない finding_id の unmet 行は WARNING + marker suffix"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "文書同期")
f2=$(mk_finding "F-02" "LOW" "current-pr" "pin 精度")
mk_json "$TEST_DIR/tc27.json" "$f1" "$f2"
set_ac "$TEST_DIR/tc27.json" '[{"id":"AC-1","status":"unmet","finding_id":"F-01","evidence":"e"},{"id":"AC-2","status":"unmet","finding_id":"F-98","evidence":"e"},{"id":"AC-3","status":"unmet","finding_id":"F-99","evidence":"e"}]'
mk_cls "$TEST_DIR/tc27-cls.json" "$(mk_entry F-01 B "文書整合に留まる")" "$(mk_entry F-02 B "検出網の粒度に留まる")"
run_gate "$TEST_DIR/tc27.json" "$TEST_DIR/tc27-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "rc=0" || fail "rc=$GATE_RC (expected 0)"
grep -qxF "[CONTEXT] CLASS_DEMOTION_GATE=applied; class_a=0; class_b=2; demoted=1; assessment=fix-needed; warning=ac_unmet_finding_missing; rows=AC-2:F-98,AC-3:F-99" <<<"$GATE_STDERR" \
  && pass "marker carries the missing rows (exact)" || fail "marker mismatch: $GATE_STDERR"
[ "$(grep -c '^WARNING: acceptance_criteria の未充足行' <<<"$GATE_STDERR")" = "1" ] \
  && pass "one WARNING line" || fail "WARNING count wrong: $GATE_STDERR"
[ "$(jq -c '[[.findings[] | "\(.id)=\(.consequence_exclusion)"], [.non_blocking_findings[].id]]' "$TEST_DIR/tc27.json")" = '[["F-01=ac_unmet:AC-1"],["F-02"]]' ] \
  && pass "F-01 excluded by AC-1, F-02 demoted as usual" || fail "sets wrong: $(jq -c '[.findings, .non_blocking_findings]' "$TEST_DIR/tc27.json")"

# ---- TC-28: acceptance_criteria の形が崩れていれば停止し、JSON を変えない ----
echo "TC-28: 不正な acceptance_criteria は acceptance_criteria_invalid で停止"
f1=$(mk_finding "F-01" "MEDIUM" "current-pr" "文書同期")
mk_cls "$TEST_DIR/tc28-cls.json" "$(mk_entry F-01 B "文書整合に留まる")"
tc28_i=0
for bad in '"x"' '1' 'null' '{}' '{"skipped":1}' '{"skipped":"foo"}' '{"skipped":"no_issue","extra":1}' '[1]' \
           '[{"id":"AC-1","finding_id":null}]' \
           '[{"id":"AC-1","status":"unmet","finding_id":5}]' \
           '[{"id":"AC-1","status":"unmet","finding_id":""}]'; do
  tc28_i=$((tc28_i + 1))
  mk_json "$TEST_DIR/tc28-$tc28_i.json" "$f1"
  set_ac "$TEST_DIR/tc28-$tc28_i.json" "$bad"
  cp "$TEST_DIR/tc28-$tc28_i.json" "$TEST_DIR/tc28-$tc28_i.before"
  run_gate "$TEST_DIR/tc28-$tc28_i.json" "$TEST_DIR/tc28-cls.json"
  if [ "$GATE_RC" -eq 1 ] \
    && grep -q "CLASS_DEMOTION_GATE_FAILED=1; reason=acceptance_criteria_invalid" <<<"$GATE_STDERR" \
    && cmp -s "$TEST_DIR/tc28-$tc28_i.json" "$TEST_DIR/tc28-$tc28_i.before"; then
    pass "rejects $bad (rc=1, JSON unchanged)"
  else
    fail "did not reject $bad (rc=$GATE_RC): $GATE_STDERR"
  fi
done
# 判定順: measured 未判定 > 不正な acceptance_criteria > classification map
mk_json "$TEST_DIR/tc28-nomap.json" "$f1"
set_ac "$TEST_DIR/tc28-nomap.json" '{}'
run_gate "$TEST_DIR/tc28-nomap.json" "$TEST_DIR/no-such-map.json"
grep -q "reason=acceptance_criteria_invalid" <<<"$GATE_STDERR" \
  && pass "invalid acceptance_criteria wins over missing map" || fail "precedence wrong: $GATE_STDERR"
mk_json "$TEST_DIR/tc28-measured.json" "$(mk_finding "F-01" "MEDIUM" "current-pr" "文書同期" "plugins/rite/hooks/foo.sh" "none")"
set_ac "$TEST_DIR/tc28-measured.json" '{}'
run_gate "$TEST_DIR/tc28-measured.json" "$TEST_DIR/tc28-cls.json"
grep -q "reason=measured_undetermined" <<<"$GATE_STDERR" \
  && pass "measured_undetermined wins over invalid acceptance_criteria" || fail "precedence wrong: $GATE_STDERR"
# blocking 0 件は従来どおり no-op (acceptance_criteria を検査しない)
mk_json "$TEST_DIR/tc28-noop.json" "$(mk_finding "F-01" "LOW" "nit-noted" "nit")"
set_ac "$TEST_DIR/tc28-noop.json" '{}'
run_gate "$TEST_DIR/tc28-noop.json" "$TEST_DIR/no-such-map.json"
[ "$GATE_RC" -eq 0 ] && [ "$GATE_STDERR" = "[CONTEXT] CLASS_DEMOTION_GATE=noop; reason=no_blocking" ] \
  && pass "blocking 0 stays noop" || fail "noop changed (rc=$GATE_RC): $GATE_STDERR"

# ---- TC-29: acceptance_criteria キー欠落の not-triggered marker に suffix が付かない ----
echo "TC-29: キー欠落入力の not-triggered marker は従来形のまま"
mk_json "$TEST_DIR/tc29.json" "$(mk_finding "F-01" "HIGH" "current-pr" "実行時に壊れる")"
mk_cls "$TEST_DIR/tc29-cls.json" "$(mk_entry F-01 A "実行時に壊れる")"
run_gate "$TEST_DIR/tc29.json" "$TEST_DIR/tc29-cls.json"
[ "$GATE_STDERR" = "[CONTEXT] CLASS_DEMOTION_GATE=not-triggered; class_a=1; class_b=0; demoted=0; assessment=fix-needed" ] \
  && pass "not-triggered marker exact" || fail "marker changed: $GATE_STDERR"

echo "Static contract: measured error は再試行せず停止し、廃止語彙を残さない"
pr_review_skill="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
retry_row=$(grep -F 'reason=classification_missing' "$pr_review_skill" | head -1)
stop_row=$(grep -F '上記 4 種以外' "$pr_review_skill" | head -1)
if grep -q 'measured_undetermined' <<<"$retry_row"; then
  fail "measured error entered map retry row"
else
  pass "measured error excluded from map retry row"
fi
if grep -q 'measured_undetermined' <<<"$stop_row" && grep -q '\[review:error\]' <<<"$stop_row"; then
  pass "measured error routed to review:error"
else
  fail "measured error missing from stop row: $stop_row"
fi
if grep -q 'acceptance_criteria_invalid' <<<"$stop_row" && ! grep -q 'acceptance_criteria_invalid' <<<"$retry_row"; then
  pass "acceptance_criteria_invalid routed to review:error, not map retry"
else
  fail "acceptance_criteria_invalid routing drift: stop=$stop_row"
fi
ac_key_row=$(grep -F '`acceptance_criteria` を常に書く' "$pr_review_skill" | head -1)
reviewers_row=$(grep -F '`reviewers[]` = 本 cycle' "$pr_review_skill" | head -1)
if grep -qF '読むだけで書き換えない' <<<"$ac_key_row" && ! grep -qF '本キーに触れない' <<<"$ac_key_row" \
   && grep -qF '本キーに触れない' <<<"$reviewers_row"; then
  pass "acceptance_criteria is read by the gate helper; reviewers stays untouched"
else
  fail "helper key-touch wording drift"
fi
class_section=$(awk '/^#### 5\.3\.0\.C 帰結クラス降格政策実行手順/{s=1; print; next} s && /^#### /{exit} s' "$pr_review_skill")
suffix_literal='; warning=ac_unmet_finding_missing; rows='
if [ "$(grep -cF '合意済み AC の実測済み未充足' <<<"$class_section")" -ge 2 ] \
   && grep -qF '既存記述の削除/弱体化が観測できるなら `exclusion` を省略してはならない' <<<"$class_section" \
   && grep -qF '成功 marker 末尾の warning suffix (下記) は行の一致判定に含めない' <<<"$class_section" \
   && grep -qF "$suffix_literal" <<<"$class_section"; then
  pass "5.3.0.C documents the acceptance exclusion and marker suffix"
else
  fail "5.3.0.C acceptance exclusion or suffix wording missing"
fi
if grep -qF "gate_warning=\"$suffix_literal" "$TARGET" \
   && grep -F -- '- **ステップ 5.3.0.C** は' "$pr_review_skill" | grep -qF "$suffix_literal"; then
  pass "documented suffix matches helper output"
else
  fail "documented suffix diverges from helper output"
fi

# 文書に字義どおり従う実行者の誤動作を実行で観測した指摘は class A。分類を書く 3 か所が同じ規則を持つ
doc_follower_rule='記述に字義どおり従う実行者が誤動作に至ることを、記述された手順（仕様書が記述する実装を含む）の実行で観測した指摘'
# 判定句は規則文より後ろで最初に現れる class A / class B で見る (同じ行の既存の class A に一致させない)。
# SKILL.md は 5.3.0.C 節の中に限る。但し書き自体が class B を含むため、判定句と限定の主語を取る前に除く
doc_follower_exemption='不確実を理由に class B へ倒さない'
doc_follower_missing=""
doc_follower_narrowing_missing=""
doc_follower_exemption_missing=""
doc_follower_exemption_tail_drift=""
for f in "$pr_review_skill" "$PLUGIN_ROOT/skills/fix/references/assessment-rules.md" "$PLUGIN_ROOT/references/severity-levels.md"; do
  # exemption_rest は tail の後ろに続いてよい部分 (case パターンとして展開する)。assessment-rules.md は
  # 但し書きの閉じ括弧で行末に達するので空 (完全一致) にし、括弧の後ろに足した反転文も検出する
  case "$f" in
    "$pr_review_skill") exemption_tail='（上の既定より優先する）'; exemption_rest='*' ;;
    */assessment-rules.md) exemption_tail=')'; exemption_rest='' ;;
    */severity-levels.md) exemption_tail='（上の表の既定より優先する）'; exemption_rest='*' ;;
  esac
  if [ "$f" = "$pr_review_skill" ]; then body=$class_section; else body=$(cat "$f"); fi
  line=$(printf '%s\n' "$body" | grep -F -- "$doc_follower_rule" || true)
  rest=${line#*"$doc_follower_rule"}
  verdict=$(printf '%s\n' "${rest//"$doc_follower_exemption"/}" | grep -oE 'class [AB]' | head -1)
  if [ -z "$line" ]; then
    doc_follower_missing="$doc_follower_missing $f(no rule)"
  elif [ "$verdict" != "class A" ]; then
    doc_follower_missing="$doc_follower_missing $f(${verdict:-no verdict})"
  fi
  # 規則文の後ろに「不確実を理由に class B へ倒さない」が同じ行で続く (一般の B 倒し既定より優先する)。
  # 但し書きの直後は、assessment-rules.md では tail で行末まで完全一致、SKILL.md / severity-levels.md では
  # tail の後ろに本文が続くため tail の前方一致で照合し、否定化や優先関係の反転を検出する
  case "$rest" in
    *"$doc_follower_exemption"*)
      exemption_after=${rest#*"$doc_follower_exemption"}
      case "$exemption_after" in
        "$exemption_tail"$exemption_rest) ;;
        *) doc_follower_exemption_tail_drift="$doc_follower_exemption_tail_drift $f(${exemption_after:0:20})" ;;
      esac
      ;;
    *) doc_follower_exemption_missing="$doc_follower_exemption_missing $f" ;;
  esac
  # class B の「文書整合」は字面整合クラス (テキスト差分だけの観測) に限る。限定句より前で最後に現れる
  # class A / class B が class B であること (但し書きを除いて見るので、限定が class A 規則の後ろへ
  # 移る変更や主語「class B の」を消す変更も検出する)
  nline=$(printf '%s\n' "$body" | grep -F -- 'テキスト差分だけを観測' | grep -F '字面整合クラス' | head -1)
  pre=${nline%%テキスト差分だけを観測*}
  subject=$(printf '%s\n' "${pre//"$doc_follower_exemption"/}" | grep -oE 'class [AB]' | tail -1)
  if [ "$subject" != "class B" ]; then
    doc_follower_narrowing_missing="$doc_follower_narrowing_missing $f(${subject:-no narrowing})"
  fi
done
if [ -z "$doc_follower_missing" ]; then
  pass "doc-follower malfunction is class A in all three classification sites"
else
  fail "doc-follower rule is not class A:$doc_follower_missing"
fi
if [ -z "$doc_follower_exemption_missing" ]; then
  pass "doc-follower rule is not demoted on uncertainty in all three sites"
else
  fail "uncertainty exemption missing:$doc_follower_exemption_missing"
fi
if [ -z "$doc_follower_exemption_tail_drift" ]; then
  pass "uncertainty exemption ends with the expected precedence in all three sites"
else
  fail "uncertainty exemption tail drift:$doc_follower_exemption_tail_drift"
fi
# class B の既定「不確実なら B へ倒す」の直後に、散文への実行観測の指摘を除く句が隣接して続く
class_b_lines=$(grep -F -- '- **class B** —' "$PLUGIN_ROOT/skills/fix/references/assessment-rules.md" || true)
if [ "$(printf '%s\n' "$class_b_lines" | grep -c .)" -eq 1 ] \
   && grep -qF '不確実な場合も class B へ倒す (上の散文への実行観測の指摘を除く。' <<<"$class_b_lines"; then
  pass "class B default keeps the prose-observation exclusion adjacent"
else
  fail "class B default exclusion clause missing or class B line not unique"
fi
if [ -z "$doc_follower_narrowing_missing" ]; then
  pass "class B document consistency is narrowed to the literal-consistency class in all three sites"
else
  fail "literal-consistency narrowing missing:$doc_follower_narrowing_missing"
fi

repo_root=$(cd "$PLUGIN_ROOT/../.." && pwd)
# SPEC の class B 定義も同じ但し書きを持つ (規則文と同じく仕様書が記述する実装を含む)
if grep -qF 'uncertain cases fall to B, except a prose finding whose repro executes the described procedure or the implementation a spec describes' "$repo_root/docs/SPEC.md"; then
  pass "SPEC keeps the doc-follower uncertainty exemption"
else
  fail "SPEC uncertainty exemption missing"
fi
old_phrase_one="blocking のまま"'残した形'
old_phrase_two="3 値モデルの保証を"'第 2 軸'
old_terms=$(grep -R -n -F -e "$old_phrase_one" -e "$old_phrase_two" -e "$retired_marker" \
  "$PLUGIN_ROOT" "$repo_root/docs" 2>/dev/null || true)
if [ -z "$old_terms" ]; then
  pass "retired wording and marker absent"
else
  fail "retired wording or marker remains: $old_terms"
fi

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
