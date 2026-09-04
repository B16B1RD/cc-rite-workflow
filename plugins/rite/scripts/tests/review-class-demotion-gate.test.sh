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
# measured: "true" (default) = verification.measured=true 付与 (分類対象) /
#           "none" = verification キーなし (実測未判定 — 分類対象外で class A 固定)
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
    jq -n --arg id "$1" --arg sev "$2" --arg scope "$3" --arg desc "$4" --arg file "$file" --arg category "$category" \
      '{id:$id, reviewer:"code-quality-reviewer", category:$category, severity:$sev,
        file:$file, line:1, description:$desc, suggestion:"s",
        status:"open", scope:$scope,
        verification:{measured:true, repro:"bash t.sh => observed failure", failing_test:null}}'
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

# ---- TC-12: 実測未判定の gated finding は分類対象外で class A 固定 ----
# 5.3.0.M が形式崩れアンカーを blocking のまま残した形 (verification キーなし)。
# class B の well-formed map エントリがあっても降格されない — 「判定不能を降格に丸めない」
# 3 値モデルの保証を第 2 軸でも保つ (本政策の入力は宣言どおり実測付き blocking に限る)。
# fixture は measured 済み class B と**共存**させる (class_b >= 1 を成立させ、not-triggered の
# 結論が「未判定が class A に算入されて降格を阻止した」ことのみに依存する形にする —
# 未判定 1 件のみだと発動条件のもう一方の連言 class_b >= 1 で結論が過剰決定される)
echo "TC-12: 実測未判定 → 分類対象外で class A 固定 (measured class B と共存し降格を阻止)"
f1=$(mk_finding "F-01" "HIGH" "current-pr" "書式崩れアンカーで未判定の CRITICAL 級指摘" "plugins/rite/hooks/foo.sh" "none")
f2=$(mk_finding "F-02" "MEDIUM" "current-pr" "実測済みの文言同期指摘")
mk_json "$TEST_DIR/tc12.json" "$f1" "$f2"
mk_cls "$TEST_DIR/tc12-cls.json" \
  "$(mk_entry F-01 B "文書整合に留まる (と主張する誤分類)")" \
  "$(mk_entry F-02 B "文書整合に留まる")"
run_gate "$TEST_DIR/tc12.json" "$TEST_DIR/tc12-cls.json"
[ "$GATE_RC" -eq 0 ] && pass "rc=0" || fail "rc=$GATE_RC (expected 0)"
grep -q "CLASS_DEMOTION_GATE=not-triggered; class_a=1; class_b=1; demoted=0" <<<"$GATE_STDERR" \
  && pass "undetermined blocks demotion (not-triggered, class_a=1 class_b=1)" || fail "marker mismatch: $GATE_STDERR"
grep -q "CLASS_DEMOTION_UNDETERMINED_MEASURED=1; count=1" <<<"$GATE_STDERR" \
  && pass "UNDETERMINED_MEASURED marker" || fail "marker missing: $GATE_STDERR"
grep -q "判定不能を降格に丸めない 3 値モデルの保証" <<<"$GATE_STDERR" \
  && pass "undetermined WARNING emitted" || fail "WARNING missing: $GATE_STDERR"
[ "$(jq -r '.findings | length' "$TEST_DIR/tc12.json")" = "2" ] \
  && pass "both stay blocking (class B not demoted)" || fail "findings were demoted"
[ "$(jq -r '.non_blocking_findings | length' "$TEST_DIR/tc12.json")" = "0" ] \
  && pass "no demotion occurred" || fail "unexpected demotion"
[ "$(jq -r '.findings[0].consequence_class' "$TEST_DIR/tc12.json")" = "A" ] \
  && pass "consequence_class=A fixed" || fail "consequence_class not A"
[ "$(jq -r '.findings[0] | has("consequence_scenario")' "$TEST_DIR/tc12.json")" = "false" ] \
  && pass "no scenario for undetermined" || fail "unexpected scenario"
[ "$(jq -r '.overall_assessment' "$TEST_DIR/tc12.json")" = "fix-needed" ] \
  && pass "assessment stays fix-needed" || fail "assessment changed"

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

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
