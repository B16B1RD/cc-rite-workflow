#!/bin/bash
# Tests for review-measured-gate.sh (実測必須ゲートの決定論的後処理)
#
# 本 helper は「非実測指摘が blocking のまま残り review-fix loop が収束しない」障害
# (PR #2070 で 9 サイクル / 8 時間超) を機械的に閉じる層である。したがって本 suite は
# 合成 fixture だけでなく **当該 PR の実レビュー結果 JSON 9 本** (fixtures/pr-2070/) を
# 回帰入力として持つ (TC-06)。合成入力だけにすると、実データが持つ description の
# 長さ・改行・記号分布が検出 regex に与える影響を取りこぼす。
#
# Usage: bash plugins/rite/scripts/tests/review-measured-gate.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../review-measured-gate.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/pr-2070"
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

# helper 実行。stdout/stderr/rc を大域変数へ。第 2 引数以降は helper へそのまま渡す。
run_gate() {
  local input="$1"
  local err_file="$TEST_DIR/.stderr"
  shift
  GATE_STDOUT=$(bash "$TARGET" --input "$input" "$@" 2>"$err_file")
  GATE_RC=$?
  GATE_STDERR=$(cat "$err_file")
  return 0
}

# finding 1 件を組み立てる: id severity scope description
mk_finding() {
  jq -n --arg id "$1" --arg sev "$2" --arg scope "$3" --arg desc "$4" \
    '{id:$id, reviewer:"code-quality-reviewer", category:"code_quality", severity:$sev,
      file:"plugins/rite/hooks/foo.sh", line:1, description:$desc, suggestion:"s",
      status:"open", scope:$scope}'
}

# review-result JSON を組み立てる: path <finding json...>
mk_json() {
  local path="$1"; shift
  printf '%s\n' "$@" | jq -s '{
    schema_version: "1.0.0",
    pr_number: 99,
    timestamp: "__RITE_TS_PLACEHOLDER_7f3a9b2c__",
    commit_sha: "0123456789abcdef0123456789abcdef01234567",
    overall_assessment: "fix-needed",
    findings: .,
    non_blocking_findings: []
  }' > "$path"
}

echo "=== review-measured-gate.sh tests ==="
echo ""

# ---------------------------------------------------------------------------
# TC-01 (AC-1): アンカーを持たない finding は measured=false で non_blocking へ移送される
# ---------------------------------------------------------------------------
echo "--- TC-01: アンカーなし finding の降格 (AC-1) ---"
f="$TEST_DIR/tc01.json"
mk_json "$f" \
  "$(mk_finding F-01 HIGH current-pr '散文の精度が実装と食い違う。文言を実体へ合わせるべき。')" \
  "$(mk_finding F-02 MEDIUM follow-up '別 Issue で扱うべき設計の歪み。')" \
  "$(mk_finding F-03 CRITICAL current-pr 'ここは壊れる可能性がある (実測なし)。')"
run_gate "$f"
if [ "$GATE_RC" -eq 0 ]; then pass "rc=0"; else fail "rc=$GATE_RC (期待 0)"; fi
if [ "$(jq '.findings | length' "$f")" = "0" ]; then pass "findings[] から 3 件すべて除去"; else fail "findings=$(jq '.findings|length' "$f") (期待 0)"; fi
if [ "$(jq '.non_blocking_findings | length' "$f")" = "3" ]; then pass "non_blocking_findings[] へ 3 件移送"; else fail "non_blocking=$(jq '.non_blocking_findings|length' "$f") (期待 3)"; fi
if [ "$(jq '[.non_blocking_findings[] | select(.verification.measured == false)] | length' "$f")" = "3" ]; then
  pass "移送 3 件すべてに verification.measured=false"
else fail "measured=false が 3 件でない"; fi
if [ "$(jq -r '[.non_blocking_findings[] | "\(.id):\(.severity):\(.scope)"] | join(",")' "$f")" = "F-01:HIGH:current-pr,F-02:MEDIUM:follow-up,F-03:CRITICAL:current-pr" ]; then
  pass "severity / scope / id が移送後も保存される"
else fail "移送時に severity/scope/id が失われた: $(jq -c '[.non_blocking_findings[]|{id,severity,scope}]' "$f")"; fi
if grep -q 'MEASURED_DEMOTED_ON_ANCHOR' <<<"$GATE_STDERR"; then
  fail "アンカー文字列が無い正常系で MEASURED_DEMOTED_ON_ANCHOR が発火した (形式違反と区別できなくなる)"
else pass "アンカー無しの正常系では MEASURED_DEMOTED_ON_ANCHOR を出さない"; fi

# ---------------------------------------------------------------------------
# TC-02 (AC-2): 正規形アンカー付き finding は findings[] に残り内容が転記される
# ---------------------------------------------------------------------------
echo "--- TC-02: 正規形アンカーの保持と転記 (AC-2) ---"
f="$TEST_DIR/tc02.json"
mk_json "$f" \
  "$(mk_finding F-01 HIGH current-pr 'WHAT + WHY 叙述。<br>Verification: repro bash hooks/flow-state.sh get --field x => ERROR: invalid field name')" \
  "$(mk_finding F-02 MEDIUM current-pr 'WHAT + WHY 叙述。
Verification: failing_test hooks/tests/test-flow-state.sh => TC-07 FAILED: expected 0 got 1')"
run_gate "$f"
if [ "$(jq '.findings | length' "$f")" = "2" ]; then pass "アンカー付き 2 件が findings[] に残存"; else fail "findings=$(jq '.findings|length' "$f") (期待 2)"; fi
if [ "$(jq '[.findings[] | select(.verification.measured == true)] | length' "$f")" = "2" ]; then
  pass "2 件とも measured=true"
else fail "measured=true が 2 件でない: $(jq -c '[.findings[].verification]' "$f")"; fi
if [ "$(jq -r '.findings[0].verification.repro' "$f")" = "bash hooks/flow-state.sh get --field x => ERROR: invalid field name" ]; then
  pass "repro アンカーの内容が転記される"
else fail "repro 転記が不一致: $(jq -r '.findings[0].verification.repro' "$f")"; fi
if [ "$(jq -r '.findings[0].verification.failing_test' "$f")" = "null" ]; then pass "repro 時の failing_test は null"; else fail "failing_test が null でない"; fi
if [ "$(jq -r '.findings[1].verification.failing_test' "$f")" = "hooks/tests/test-flow-state.sh => TC-07 FAILED: expected 0 got 1" ]; then
  pass "failing_test アンカーの内容が転記される"
else fail "failing_test 転記が不一致: $(jq -r '.findings[1].verification.failing_test' "$f")"; fi
if [ "$(jq -r '.overall_assessment' "$f")" = "fix-needed" ]; then pass "blocking 残存で fix-needed"; else fail "assessment=$(jq -r '.overall_assessment' "$f") (期待 fix-needed)"; fi

# ---------------------------------------------------------------------------
# TC-03 (AC-3): 全件降格で mergeable
# ---------------------------------------------------------------------------
echo "--- TC-03: 全件降格で mergeable (AC-3) ---"
f="$TEST_DIR/tc03.json"
mk_json "$f" \
  "$(mk_finding F-01 HIGH current-pr 'アンカーなし 1')" \
  "$(mk_finding F-02 MEDIUM current-pr 'アンカーなし 2')"
run_gate "$f"
if [ "$(jq -r '.overall_assessment' "$f")" = "mergeable" ]; then pass "overall_assessment=mergeable"; else fail "assessment=$(jq -r '.overall_assessment' "$f")"; fi
if [ "$(jq '.findings | length' "$f")" = "0" ]; then pass "findings[] が空"; else fail "findings が空でない"; fi
if grep -q 'MEASURED_GATE=applied; blocking=0; demoted=2;' <<<"$GATE_STDERR"; then
  pass "[CONTEXT] MEASURED_GATE marker が blocking=0 / demoted=2 を報告"
else fail "marker 不一致: $GATE_STDERR"; fi

# nit-noted は本ゲートの対象外 (D-03: mergeable 判定は blocking 部分集合の空で行う)
echo "--- TC-03b: nit-noted は移送せず、blocking 0 なら mergeable (D-03) ---"
f="$TEST_DIR/tc03b.json"
mk_json "$f" \
  "$(mk_finding F-01 LOW nit-noted 'nit。アンカーなし')" \
  "$(mk_finding F-02 MEDIUM current-pr 'アンカーなし')"
run_gate "$f"
if [ "$(jq -r '[.findings[].id] | join(",")' "$f")" = "F-01" ]; then pass "nit-noted は findings[] に残る"; else fail "findings=$(jq -c '[.findings[].id]' "$f")"; fi
if [ "$(jq -r '.overall_assessment' "$f")" = "mergeable" ]; then
  pass "findings[] が非空でも blocking 0 なら mergeable"
else fail "assessment=$(jq -r '.overall_assessment' "$f") (期待 mergeable。配列全体の空判定に退行している)"; fi

# ---------------------------------------------------------------------------
# TC-04 (AC-4): 非正規形アンカーの不受理と WARNING
# ---------------------------------------------------------------------------
echo "--- TC-04: 非正規形アンカーの不受理 (AC-4) ---"
f="$TEST_DIR/tc04.json"
mk_json "$f" \
  "$(mk_finding F-01 HIGH current-pr '装飾付き<br>**Verification:** repro bash x.sh => boom')" \
  "$(mk_finding F-02 HIGH current-pr 'バッククォート<br>`Verification`: repro bash x.sh => boom')" \
  "$(mk_finding F-03 HIGH current-pr '全角コロン<br>Verification： repro bash x.sh => boom')" \
  "$(mk_finding F-04 HIGH current-pr '空 RHS<br>Verification: repro bash x.sh =>')" \
  "$(mk_finding F-05 HIGH current-pr 'raw pipe<br>Verification: repro printf x | jq -e . => false')" \
  "$(mk_finding F-06 HIGH current-pr '種別ラベル欠落<br>Verification: bash x.sh => ERROR')" \
  "$(mk_finding F-07 HIGH current-pr 'ラベル取り違え<br>Verification: runtime_observation bash x.sh => ERROR')"
run_gate "$f"
if [ "$(jq '.findings | length' "$f")" = "0" ]; then pass "非正規形 7 種すべてが降格"; else fail "残存: $(jq -c '[.findings[].id]' "$f")"; fi
if grep -q '\[CONTEXT\] MEASURED_DEMOTED_ON_ANCHOR=1; count=7; cause=anchor_unparseable' <<<"$GATE_STDERR"; then
  pass "MEASURED_DEMOTED_ON_ANCHOR=1; count=7 を emit"
else fail "MEASURED_DEMOTED_ON_ANCHOR の count が 7 でない: $GATE_STDERR"; fi
if grep -q 'WARNING: Verification: アンカーはあるが検出 regex に match しない' <<<"$GATE_STDERR"; then
  pass "形式違反の WARNING を emit"
else fail "WARNING 不在"; fi

# ---------------------------------------------------------------------------
# TC-05 (AC-5): 境界 — 空 findings / 既存 non_blocking への append / 冪等
# ---------------------------------------------------------------------------
echo "--- TC-05: 境界と冪等性 (AC-5) ---"
f="$TEST_DIR/tc05-empty.json"
mk_json "$f"
run_gate "$f"
if [ "$GATE_RC" -eq 0 ] && [ "$(jq -r '.overall_assessment' "$f")" = "mergeable" ] && [ "$(jq '.non_blocking_findings|length' "$f")" = "0" ]; then
  pass "findings[] 空入力は移送 0 件で mergeable"
else fail "空入力の挙動が不正: rc=$GATE_RC assess=$(jq -r '.overall_assessment' "$f")"; fi

f="$TEST_DIR/tc05-append.json"
mk_json "$f" "$(mk_finding F-02 HIGH current-pr 'アンカーなし')"
jq '.non_blocking_findings = [{id:"F-01", reviewer:"r", category:"c", severity:"LOW",
     file:"x.sh", line:null, description:"前 cycle の降格分", suggestion:"s", status:"open",
     scope:"current-pr", verification:{measured:false, repro:null, failing_test:null}}]' "$f" > "$f.n" && mv "$f.n" "$f"
run_gate "$f"
if [ "$(jq -r '[.non_blocking_findings[].id] | join(",")' "$f")" = "F-01,F-02" ]; then
  pass "既存 non_blocking_findings[] を保持して append"
else fail "append が不正: $(jq -c '[.non_blocking_findings[].id]' "$f")"; fi

f="$TEST_DIR/tc05-idem.json"
mk_json "$f" \
  "$(mk_finding F-01 HIGH current-pr 'アンカーなし')" \
  "$(mk_finding F-02 HIGH current-pr 'あり<br>Verification: repro bash x.sh => boom')" \
  "$(mk_finding F-03 LOW nit-noted 'nit')"
run_gate "$f"
cp "$f" "$f.once"
run_gate "$f"
if cmp -s "$f" "$f.once"; then pass "再実行で出力がバイト一致 (冪等)"; else fail "再実行で出力が変化した: $(diff "$f.once" "$f" | head -5)"; fi
if grep -q 'MEASURED_GATE=applied; blocking=1; demoted=0;' <<<"$GATE_STDERR"; then
  pass "再実行時は demoted=0 (既に移送済み)"
else fail "再実行の marker が不正: $GATE_STDERR"; fi

# 既存 verification.measured (boolean) は上書きしない (§4.5)
echo "--- TC-05b: 既存 verification.measured を上書きしない (§4.5) ---"
f="$TEST_DIR/tc05b.json"
mk_json "$f" "$(mk_finding F-01 HIGH current-pr 'アンカーは無いが前段で measured=true と判定済み')"
jq '.findings[0].verification = {measured:true, repro:"bash x.sh => boom", failing_test:null}' "$f" > "$f.n" && mv "$f.n" "$f"
run_gate "$f"
if [ "$(jq -r '.findings[0].verification.measured' "$f")" = "true" ] && [ "$(jq '.non_blocking_findings|length' "$f")" = "0" ]; then
  pass "既存 measured=true を保持し降格しない"
else fail "既存値が上書きされた: $(jq -c '.findings[0].verification' "$f")"; fi
if grep -q 'WARNING: 既存 verification.measured と description のアンカー有無が矛盾' <<<"$GATE_STDERR"; then
  pass "既存値と description の矛盾を WARNING で surface"
else fail "矛盾 WARNING が出ていない"; fi

# verification: {} / measured: null は「未判定」形であり「設定済み」ではない
echo "--- TC-05c: verification 未判定形 ({} / null) は算出対象 ---"
f="$TEST_DIR/tc05c.json"
mk_json "$f" \
  "$(mk_finding F-01 HIGH current-pr 'アンカーなし (verification: {})')" \
  "$(mk_finding F-02 HIGH current-pr 'アンカーなし (measured: null)')"
jq '.findings[0].verification = {} | .findings[1].verification = {measured:null}' "$f" > "$f.n" && mv "$f.n" "$f"
run_gate "$f"
if [ "$(jq '[.non_blocking_findings[] | select(.verification.measured == false)] | length' "$f")" = "2" ]; then
  pass "{} / measured:null は未判定として算出され降格される"
else fail "未判定形が設定済み扱いになっている: $(jq -c '[.non_blocking_findings[].verification]' "$f")"; fi

# ---------------------------------------------------------------------------
# TC-06 (AC-6): PR #2070 実 JSON の回帰
#
# 実データの内訳 (fixture を jq で実測。Issue #2072 §1 の「45 件すべてが非実測」は
# description 列のアンカーだけを見た測定であり、JSON の verification キーまでは見ていない):
#   - 全 9 cycle 合計 45 件。**45 件すべてが description に Verification: アンカーを持たない**
#   - cycle 1 (2070-20260731095828.json、12 件) のみ verification キー自体が無い
#   - cycle 2-9 (33 件) は write 側 (LLM) が verification.measured=true を実 repro 文字列付きで
#     JSON へ直接書いている。§4.5「既存値を正として上書きしない」により本 helper は降格せず、
#     description と食い違う旨を WARNING で surface する
#
# したがって本ゲートの回帰的意味は「cycle 1 で mergeable に到達し、cycle 2-9 が**そもそも
# 発生しない**」ことにある。cycle 2-9 の 33 件は起きなかったはずのサイクルの産物なので、
# 「45 件すべてを降格する」ではなく「cycle 1 で loop が終わる」を固定するのが正しい回帰である。
# ---------------------------------------------------------------------------
echo "--- TC-06: PR #2070 実データ回帰 (AC-6) ---"
if [ ! -d "$FIXTURE_DIR" ]; then
  fail "fixture ディレクトリが無い: $FIXTURE_DIR"
else
  total_findings=0
  anchored_in_desc=0
  for fx in "$FIXTURE_DIR"/*.json; do
    total_findings=$((total_findings + $(jq '.findings | length' "$fx")))
    anchored_in_desc=$((anchored_in_desc + $(jq '[.findings[] | select(.description | test("(?m)(?:^|<br\\s*/?>|[\\s|>(])[-[:space:]]*Verification:[[:space:]]*(repro|failing_test)[[:space:]]+(?:(?!=>|<br)[^|])+=>[ \t]*(?!<br)[^|[:space:]]"))] | length' "$fx")))
  done
  if [ "$total_findings" -eq 45 ] && [ "$anchored_in_desc" -eq 0 ]; then
    pass "fixture 9 本 = 45 findings / description のアンカー 0 件 (Issue の実測前提)"
  else fail "fixture の実測が前提と異なる: findings=$total_findings anchored=$anchored_in_desc (期待 45 / 0)"; fi

  # cycle 1: verification 未設定の 12 件が全件降格し mergeable になる = loop はここで終わる
  work="$TEST_DIR/cycle1.json"
  cp "$FIXTURE_DIR/2070-20260731095828.json" "$work"
  before=$(jq '.findings | length' "$work")
  nb_before=$(jq '.non_blocking_findings | length' "$work")
  run_gate "$work"
  if [ "$before" -eq 12 ] && [ "$(jq '.findings | length' "$work")" = "0" ]; then
    pass "cycle 1 の blocking 12 件が全件降格 (12→0)"
  else fail "cycle 1 の降格が不完全: before=$before after=$(jq '.findings|length' "$work")"; fi
  if [ "$(jq '.non_blocking_findings | length' "$work")" = "$((nb_before + 12))" ]; then
    pass "cycle 1 の 12 件が既存 $nb_before 件へ append される"
  else fail "cycle 1 の non_blocking 件数が不正"; fi
  if [ "$(jq -r '.overall_assessment' "$work")" = "mergeable" ]; then
    pass "cycle 1 が mergeable — 初回レビューで [review:mergeable] に到達し cycle 2-9 は発生しない"
  else fail "cycle 1 が mergeable にならない: $(jq -r '.overall_assessment' "$work")"; fi

  # cycle 2-9: write 側が書いた measured=true を上書きせず、description との矛盾を WARNING で出す
  conflict_warned=0
  conflict_total=0
  for fx in "$FIXTURE_DIR"/*.json; do
    [ "$(basename "$fx")" = "2070-20260731095828.json" ] && continue
    work="$TEST_DIR/late-$(basename "$fx")"
    cp "$fx" "$work"
    before=$(jq '.findings | length' "$work")
    run_gate "$work"
    [ "$(jq '.findings | length' "$work")" = "$before" ] || conflict_total=-999
    conflict_total=$((conflict_total + before))
    grep -q 'WARNING: 既存 verification.measured と description のアンカー有無が矛盾' <<<"$GATE_STDERR" && conflict_warned=$((conflict_warned + 1))
  done
  if [ "$conflict_total" -eq 33 ]; then
    pass "cycle 2-9 の 33 件は既存 measured=true を保持し降格しない (§4.5)"
  else fail "cycle 2-9 で既存値が上書きされた (conflict_total=$conflict_total)"; fi
  if [ "$conflict_warned" -eq 8 ]; then
    pass "cycle 2-9 の全 8 本で description との矛盾 WARNING を surface"
  else fail "矛盾 WARNING が $conflict_warned/8 本でしか出ていない"; fi
fi

# ---------------------------------------------------------------------------
# TC-07 (AC-8): 後方互換 — 必須フィールドと timestamp sentinel の保存
# ---------------------------------------------------------------------------
echo "--- TC-07: 必須フィールド / timestamp sentinel の保存 (AC-8) ---"
f="$TEST_DIR/tc07.json"
mk_json "$f" \
  "$(mk_finding F-01 HIGH current-pr 'アンカーなし')" \
  "$(mk_finding F-02 HIGH current-pr 'あり<br>Verification: repro bash x.sh => boom')"
run_gate "$f"
if [ "$(jq -r '.timestamp' "$f")" = "__RITE_TS_PLACEHOLDER_7f3a9b2c__" ]; then
  pass "timestamp sentinel がバイト等価で残る (review-result-save.sh の注入が成立)"
else fail "timestamp sentinel が壊れた: $(jq -r '.timestamp' "$f")"; fi
if [ "$(jq -r 'has("schema_version") and has("pr_number") and has("timestamp") and has("commit_sha") and has("overall_assessment") and has("findings") and has("non_blocking_findings")' "$f")" = "true" ]; then
  pass "schema 必須フィールドが全て保存される"
else fail "必須フィールドが欠落した"; fi
if [ "$(jq -r '.schema_version' "$f")" = "1.0.0" ]; then pass "schema_version を変更しない (verification は additive)"; else fail "schema_version が変更された"; fi
if [ "$(jq -r '[.findings[].id, .non_blocking_findings[].id] | (length == (unique | length))' "$f")" = "true" ]; then
  pass "id が 2 配列の和集合で一意 (振り直しをしない)"
else fail "id の和集合一意性が壊れた"; fi
if [ "$(jq -r '.findings[0].suggestion' "$f")" = "s" ] && [ "$(jq -r '.non_blocking_findings[0].description' "$f")" = "アンカーなし" ]; then
  pass "finding のフィールドが移送・保持の両経路で保存される"
else fail "finding のフィールドが失われた"; fi

# ---------------------------------------------------------------------------
# TC-08: エラー経路 — fail-fast (silent fallback 禁止)
# ---------------------------------------------------------------------------
echo "--- TC-08: エラー経路の fail-fast (§4.5) ---"
run_gate "$TEST_DIR/does-not-exist.json"
if [ "$GATE_RC" -eq 1 ] && grep -q 'MEASURED_GATE_FAILED=1; reason=input_missing' <<<"$GATE_STDERR"; then
  pass "入力不在で exit 1 + reason=input_missing"
else fail "入力不在の扱いが不正: rc=$GATE_RC stderr=$GATE_STDERR"; fi

printf 'not json at all {' > "$TEST_DIR/broken.json"
run_gate "$TEST_DIR/broken.json"
if [ "$GATE_RC" -eq 1 ] && grep -q 'MEASURED_GATE_FAILED=1; reason=json_invalid' <<<"$GATE_STDERR"; then
  pass "parse 不能で exit 1 + reason=json_invalid"
else fail "parse 不能の扱いが不正: rc=$GATE_RC stderr=$GATE_STDERR"; fi

printf '{"findings": "not-an-array"}' > "$TEST_DIR/badfindings.json"
run_gate "$TEST_DIR/badfindings.json"
if [ "$GATE_RC" -eq 1 ] && grep -q 'reason=findings_not_array' <<<"$GATE_STDERR"; then
  pass "findings 非配列で exit 1 + reason=findings_not_array"
else fail "findings 非配列の扱いが不正: rc=$GATE_RC stderr=$GATE_STDERR"; fi

printf '{"findings": [], "non_blocking_findings": 3}' > "$TEST_DIR/badnb.json"
run_gate "$TEST_DIR/badnb.json"
if [ "$GATE_RC" -eq 1 ] && grep -q 'reason=non_blocking_not_array' <<<"$GATE_STDERR"; then
  pass "non_blocking_findings 非配列で exit 1 + reason=non_blocking_not_array"
else fail "non_blocking 非配列の扱いが不正: rc=$GATE_RC stderr=$GATE_STDERR"; fi

GATE_STDOUT=$(bash "$TARGET" --input "$TEST_DIR/tc07.json" --unknown-flag x 2>/dev/null); rc=$?
if [ "$rc" -eq 2 ]; then pass "未知フラグで exit 2 (invocation error)"; else fail "未知フラグの rc=$rc (期待 2)"; fi

# --reject-preset-verification: caller 契約 (「verification は書かない」) の機械的強制
echo "--- TC-08b: --reject-preset-verification による caller 契約の強制 ---"
f="$TEST_DIR/tc08b.json"
mk_json "$f" "$(mk_finding F-01 HIGH current-pr 'アンカー無しなのに measured=true を先書きした形 (ゲート迂回)')"
jq '.findings[0].verification = {measured:true, repro:"x => y", failing_test:null}' "$f" > "$f.n" && mv "$f.n" "$f"
cp "$f" "$f.orig"
run_gate "$f" --reject-preset-verification
if [ "$GATE_RC" -eq 1 ] && grep -q 'MEASURED_GATE_FAILED=1; reason=verification_preset_by_caller' <<<"$GATE_STDERR"; then
  pass "アンカーと矛盾する先書き verification で exit 1 + reason=verification_preset_by_caller"
else fail "先書き verification が弾かれない: rc=$GATE_RC stderr=$GATE_STDERR"; fi
if cmp -s "$f" "$f.orig"; then pass "契約違反時は JSON を書き換えない"; else fail "契約違反なのに JSON が書き換えられた"; fi

# PR #2070 cycle 2 の実データも同経路で弾かれる (回帰の実証)
work="$TEST_DIR/tc08b-real.json"
cp "$FIXTURE_DIR/2070-20260731125341.json" "$work"
run_gate "$work" --reject-preset-verification
if [ "$GATE_RC" -eq 1 ] && grep -q 'reason=verification_preset_by_caller' <<<"$GATE_STDERR"; then
  pass "PR #2070 cycle 2 の実 JSON も caller 契約違反として弾かれる"
else fail "実データの先書き verification が弾かれない: rc=$GATE_RC"; fi

# 冪等性はフラグ有無に依らない: ゲート適用後の JSON は矛盾を含まないため再実行しても発火しない
f="$TEST_DIR/tc08b-idem.json"
mk_json "$f" \
  "$(mk_finding F-01 HIGH current-pr 'アンカーなし')" \
  "$(mk_finding F-02 HIGH current-pr 'あり<br>Verification: repro bash x.sh => boom')" \
  "$(mk_finding F-03 LOW nit-noted 'nit')"
run_gate "$f" --reject-preset-verification
cp "$f" "$f.once"
run_gate "$f" --reject-preset-verification
if [ "$GATE_RC" -eq 0 ] && cmp -s "$f" "$f.once"; then
  pass "フラグ指定下でも再実行が rc=0 かつバイト一致 (冪等性を壊さない)"
else fail "フラグ指定下で冪等性が壊れた: rc=$GATE_RC"; fi

f="$TEST_DIR/tc08-preserve.json"
mk_json "$f" "$(mk_finding F-01 HIGH current-pr 'アンカーなし')"
cp "$f" "$f.orig"
chmod 444 "$f"
run_gate "$f"
chmod 644 "$f"
if [ "$GATE_RC" -eq 0 ] || cmp -s "$f" "$f.orig"; then
  pass "書き込み失敗経路でも入力を破壊しない (atomic write)"
else fail "書き込み失敗で入力が破壊された"; fi

# ---------------------------------------------------------------------------
# TC-09: 検出 regex と抽出 regex の等価性
#
# helper は SoT (assessment-rules.md §5.3.0.M) の Anchor detection regex に capture group と
# RHS 末尾消費を足した 1 本を使う。「足しても受理集合は変わらない」という主張を、SoT 形と
# capture 形の双方を入力マトリクスに当てて機械的に固定する。ここが崩れると、SoT を読んで
# 正しいと信じた形が helper では no-match になる (逆も然り) 状態が無検出で入り込む。
# ---------------------------------------------------------------------------
echo "--- TC-09: SoT 検出 regex との等価性 ---"
re_detect='(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Verification:[[:space:]]*(repro|failing_test)[[:space:]]+(?:(?!=>|<br)[^|])+=>[ \t]*(?!<br)[^|[:space:]]'
re_extract='(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Verification:[[:space:]]*(?<label>repro|failing_test)[[:space:]]+(?<lhs>(?:(?!=>|<br)[^|])+)=>[ \t]*(?<rhs>(?!<br)[^|[:space:]](?:(?!<br)[^|])*)'
cat > "$TEST_DIR/matrix.json" <<'EOF'
[
  "Verification: repro bash x.sh => boom",
  "prose<br>Verification: repro bash x.sh => boom",
  "prose\nVerification: failing_test t.sh => TC-01 FAILED",
  "(Verification: repro bash x.sh => boom)",
  "- Verification: repro bash x.sh => boom",
  "**Verification:** repro bash x.sh => boom",
  "Verification： repro bash x.sh => boom",
  "Verification: repro bash x.sh =>",
  "Verification: repro bash x.sh => <br>next",
  "Verification: repro printf x | jq . => false",
  "Verification: bash x.sh => ERROR",
  "Verification: runtime_observation bash x.sh => ERROR",
  "cell | Verification: repro bash x.sh => boom",
  "no anchor at all",
  "verification : repro bash x.sh => boom"
]
EOF
mismatch=$(jq -r --arg d "$re_detect" --arg e "$re_extract" \
  '[.[] | select((test($d)) != ((capture($e) | true) // false))] | length' "$TEST_DIR/matrix.json" 2>/dev/null)
if [ "$mismatch" = "0" ]; then
  pass "入力 15 種で SoT 検出 regex と抽出 regex の判定が一致"
else fail "SoT 形と capture 形で判定が食い違う入力が $mismatch 件ある"; fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
