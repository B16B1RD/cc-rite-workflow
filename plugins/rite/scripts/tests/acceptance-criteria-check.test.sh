#!/bin/bash
# Tests for acceptance-criteria-check.sh (受入条件確認の機械検査)
#
# Coverage:
#   extract — テンプレート形式の AC 集合 / fenced block と別節の見出しを数えない / CRLF /
#             AC 節なし・別形式は skipped / 見出しあり 0 件と重複は失敗
#   table   — 正常 / AC-ID 欠落・余分・重複 / 0 行 / 見出し欠落 / 判定値不正 / 根拠空 /
#             未充足行に対応する [AC-N] 指摘の欠落・severity 不一致 / 推奨対応列の raw pipe
#   final   — 正常 / 全充足 / 行の欠落・重複 / 未充足 finding が non_blocking_findings[] にある /
#             finding 不在 / キー欠落 / skipped 形 / 対象判定と --expected・reviewers[] の矛盾 /
#             行の形式違反 / 入力を書き換えない / ゲート未適用 / 型の崩れた行・description (jq エラーで通さない)
#   chain   — 実測アンカーの無い未充足 finding を review-measured-gate.sh に通すと降格し、
#             final が失敗する (行は unmet のまま)。アンカー付きなら通る
#
# Usage: bash plugins/rite/scripts/tests/acceptance-criteria-check.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../acceptance-criteria-check.sh"
MGATE="$SCRIPT_DIR/../review-measured-gate.sh"
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

# helper 実行。stdout / stderr / rc を大域変数へ
run_check() {
  local err_file="$TEST_DIR/.stderr"
  CHECK_STDOUT=$(bash "$TARGET" "$@" 2>"$err_file")
  CHECK_RC=$?
  CHECK_STDERR=$(cat "$err_file")
  return 0
}

# 失敗 marker の reason と rc=1 を同時に固定する
expect_failure() {
  local label="$1" reason="$2"
  shift 2
  run_check "$@"
  if [ "$CHECK_RC" -eq 1 ] && grep -q "^\[CONTEXT\] ACCEPTANCE_CHECK_FAILED=1; mode=$1; reason=$reason\(;\|$\)" <<<"$CHECK_STDERR"; then
    pass "$label"
  else
    fail "$label (rc=$CHECK_RC stderr=$CHECK_STDERR)"
  fi
}

echo "=== extract ==="

cat > "$TEST_DIR/body-target.md" <<'EOF'
## 4. Implementation Details

### AC-8: 4 節の見出しは数えない

## 5. Acceptance Criteria

### AC-1: 一つ目

- **Then**: x

### AC-2

```markdown
### AC-9: fenced block 内は数えない
```

## 6. Test Specification

### AC-3: 6 節の見出しは数えない
EOF
run_check extract --body-file "$TEST_DIR/body-target.md"
if [ "$CHECK_RC" -eq 0 ] && [ "$CHECK_STDOUT" = "AC-1,AC-2" ] \
  && grep -Fxq '[CONTEXT] ACCEPTANCE_SCOPE=target; ids=AC-1,AC-2' <<<"$CHECK_STDERR"; then
  pass "extract: 5 節の AC-N だけを抽出する (fenced / 他節を除外)"
else fail "extract target (rc=$CHECK_RC out=$CHECK_STDOUT err=$CHECK_STDERR)"; fi

printf '## 5. Acceptance Criteria\r\n\r\n### AC-1: crlf\r\n\r\n### AC-2: crlf\r\n' > "$TEST_DIR/body-crlf.md"
run_check extract --body-file "$TEST_DIR/body-crlf.md"
if [ "$CHECK_RC" -eq 0 ] && [ "$CHECK_STDOUT" = "AC-1,AC-2" ]; then
  pass "extract: CRLF 本文でも抽出する"
else fail "extract crlf (rc=$CHECK_RC out=$CHECK_STDOUT)"; fi

printf '## 概要\n\nAC なし\n\n## 受入基準\n\n- AC-1: 別形式\n' > "$TEST_DIR/body-other.md"
run_check extract --body-file "$TEST_DIR/body-other.md"
if [ "$CHECK_RC" -eq 0 ] && [ -z "$CHECK_STDOUT" ] \
  && grep -Fxq '[CONTEXT] ACCEPTANCE_SCOPE=skipped; reason=no_ac_section; headings=受入基準' <<<"$CHECK_STDERR"; then
  pass "extract: 別形式の AC 節は skipped (見つかった見出しを通知)"
else fail "extract other format (rc=$CHECK_RC out=$CHECK_STDOUT err=$CHECK_STDERR)"; fi

printf '## 概要\n\n本文のみ\n' > "$TEST_DIR/body-none.md"
run_check extract --body-file "$TEST_DIR/body-none.md"
if [ "$CHECK_RC" -eq 0 ] && grep -Fxq '[CONTEXT] ACCEPTANCE_SCOPE=skipped; reason=no_ac_section; headings=none' <<<"$CHECK_STDERR"; then
  pass "extract: AC 節なしは skipped"
else fail "extract none (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

printf '## 5. Acceptance Criteria\n\n- AC-1: 小見出しなし\n\n## 6. Test\n' > "$TEST_DIR/body-noids.md"
expect_failure "extract: 見出しありで AC-N 0 件は失敗" no_ac_ids extract --body-file "$TEST_DIR/body-noids.md"

printf '## 5. Acceptance Criteria\n\n### AC-1: a\n\n### AC-1: b\n' > "$TEST_DIR/body-dup.md"
expect_failure "extract: AC-ID 重複は失敗" duplicate_ac_id extract --body-file "$TEST_DIR/body-dup.md"

echo "=== table ==="

# 正常形の reviewer 出力。$1 = 判定表の本文行、$2 = 指摘事項の本文行
write_output() {
  local file="$1" rows="$2" findings="$3"
  {
    printf '### 評価: 要修正\n### 所見\nx\n'
    printf '### 受入条件確認\n| AC | 判定 | 根拠 |\n|----|------|------|\n'
    [ -n "$rows" ] && printf '%s\n' "$rows"
    printf '### 指摘事項\n| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |\n|--------|----------|------------|------|----------|\n'
    [ -n "$findings" ] && printf '%s\n' "$findings"
    printf '### 監査ログ\nなし\n'
  } > "$file"
}
ROWS_OK='| AC-1 | 充足 | bash t.sh => PASS |
| AC-2 | 未充足 | 指摘事項 [AC-2] を参照 |
| AC-3 | 未検証 | 実環境が必要 |'
FINDING_OK='| CRITICAL | current-pr | a.sh | [AC-2] 壊れている<br>Likelihood-Evidence: runtime_observation bash a.sh<br>Verification: repro bash a.sh => exit 0 | 直す |'

write_output "$TEST_DIR/out-ok.md" "$ROWS_OK" "$FINDING_OK"
run_check table --expected AC-1,AC-2,AC-3 --input "$TEST_DIR/out-ok.md"
if [ "$CHECK_RC" -eq 0 ] \
  && [ "$(jq -c '[.[] | [.id, .status]]' <<<"$CHECK_STDOUT")" = '[["AC-1","satisfied"],["AC-2","unmet"],["AC-3","unverified"]]' ] \
  && grep -Fxq '[CONTEXT] ACCEPTANCE_TABLE=ok; rows=3; unmet=AC-2; unverified=AC-3' <<<"$CHECK_STDERR"; then
  pass "table: 正常形を英語 enum の行 JSON に変換する"
else fail "table ok (rc=$CHECK_RC out=$CHECK_STDOUT err=$CHECK_STDERR)"; fi

write_output "$TEST_DIR/out-missing-row.md" '| AC-1 | 充足 | ok |
| AC-3 | 未検証 | 実環境が必要 |' ""
run_check table --expected AC-1,AC-2,AC-3 --input "$TEST_DIR/out-missing-row.md"
if [ "$CHECK_RC" -eq 1 ] && grep -Fq 'reason=id_set_mismatch; missing=AC-2; extra=; duplicate=' <<<"$CHECK_STDERR"; then
  pass "table: AC-2 行の欠落を id_set_mismatch で拒否する"
else fail "table missing row (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

write_output "$TEST_DIR/out-extra-row.md" "$ROWS_OK
| AC-4 | 充足 | ok |" "$FINDING_OK"
run_check table --expected AC-1,AC-2,AC-3 --input "$TEST_DIR/out-extra-row.md"
if [ "$CHECK_RC" -eq 1 ] && grep -Fq 'reason=id_set_mismatch; missing=; extra=AC-4;' <<<"$CHECK_STDERR"; then
  pass "table: Issue に無い AC 行を拒否する"
else fail "table extra row (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

write_output "$TEST_DIR/out-dup-row.md" "$ROWS_OK
| AC-1 | 充足 | again |" "$FINDING_OK"
run_check table --expected AC-1,AC-2,AC-3 --input "$TEST_DIR/out-dup-row.md"
if [ "$CHECK_RC" -eq 1 ] && grep -Fq 'duplicate=AC-1' <<<"$CHECK_STDERR"; then
  pass "table: 同じ AC の重複行を拒否する"
else fail "table dup row (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

write_output "$TEST_DIR/out-empty.md" "" ""
expect_failure "table: 判定行 0 件は失敗" table_empty table --expected AC-1 --input "$TEST_DIR/out-empty.md"

printf '### 評価: 可\n### 指摘事項\n| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |\n|---|---|---|---|---|\n' > "$TEST_DIR/out-noheading.md"
expect_failure "table: 見出し欠落は失敗" table_missing table --expected AC-1 --input "$TEST_DIR/out-noheading.md"

write_output "$TEST_DIR/out-badstatus.md" '| AC-1 | 概ね充足 | ok |' ""
expect_failure "table: 判定 3 値以外は失敗" status_invalid table --expected AC-1 --input "$TEST_DIR/out-badstatus.md"

write_output "$TEST_DIR/out-noevidence.md" '| AC-1 | 未検証 |  |' ""
expect_failure "table: 根拠が空の行は失敗" evidence_missing table --expected AC-1 --input "$TEST_DIR/out-noevidence.md"

write_output "$TEST_DIR/out-nofinding.md" "$ROWS_OK" ""
expect_failure "table: 未充足行に [AC-N] 指摘が無ければ失敗" unmet_finding_missing table --expected AC-1,AC-2,AC-3 --input "$TEST_DIR/out-nofinding.md"

write_output "$TEST_DIR/out-highfinding.md" "$ROWS_OK" "${FINDING_OK/CRITICAL/HIGH}"
expect_failure "table: 未充足の指摘が CRITICAL でなければ失敗" unmet_finding_missing table --expected AC-1,AC-2,AC-3 --input "$TEST_DIR/out-highfinding.md"

write_output "$TEST_DIR/out-pipe-suggestion.md" "$ROWS_OK" "${FINDING_OK/| 直す |/| bash a.sh || exit 1 |}"
run_check table --expected AC-1,AC-2,AC-3 --input "$TEST_DIR/out-pipe-suggestion.md"
if [ "$CHECK_RC" -eq 0 ] && grep -Fq 'ACCEPTANCE_TABLE=ok; rows=3; unmet=AC-2' <<<"$CHECK_STDERR"; then
  pass "table: 推奨対応列に raw pipe を含む未充足指摘も認識する"
else fail "table pipe in suggestion (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

echo "=== final ==="

write_result() {
  # $1 = file, $2 = findings JSON, $3 = non_blocking JSON, $4 = acceptance_criteria JSON, $5 = reviewers JSON (省略時は acceptance-reviewer を含む 2 名)
  jq -n --argjson f "$2" --argjson nb "$3" --argjson ac "$4" --argjson rv "${5:-[\"acceptance-reviewer\",\"test-reviewer\"]}" \
    '{schema_version: "1.1.0", reviewers: $rv, findings: $f, non_blocking_findings: $nb, acceptance_criteria: $ac,
      measured_gate: {commit_sha: "abc1234", applied_at: "2026-01-01T00:00:00Z", blocking: 0, demoted: 0, anchor_undetermined: 0}}' > "$1"
}
F_UNMET='{"id":"F-01","reviewer":"acceptance-reviewer","scope":"current-pr","severity":"CRITICAL","description":"[AC-2] 壊れている"}'
AC_ROWS='[{"id":"AC-1","status":"satisfied","finding_id":null,"evidence":"ok"},{"id":"AC-2","status":"unmet","finding_id":"F-01","evidence":"x"},{"id":"AC-3","status":"unverified","finding_id":null,"evidence":"実環境"}]'
AC3=AC-1,AC-2,AC-3

write_result "$TEST_DIR/r-ok.json" "[$F_UNMET]" '[]' "$AC_ROWS"
cp "$TEST_DIR/r-ok.json" "$TEST_DIR/r-ok.before"
run_check final --expected "$AC3" --input "$TEST_DIR/r-ok.json"
if [ "$CHECK_RC" -eq 0 ] && grep -Fxq '[CONTEXT] ACCEPTANCE_FINAL=ok; unmet=AC-2; unverified=AC-3' <<<"$CHECK_STDERR" \
  && cmp -s "$TEST_DIR/r-ok.json" "$TEST_DIR/r-ok.before"; then
  pass "final: 未充足 finding が blocking に残れば通過し、未検証 AC を報告する (入力不変)"
else fail "final ok (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

write_result "$TEST_DIR/r-all.json" '[]' '[]' '[{"id":"AC-1","status":"satisfied","finding_id":null,"evidence":"ok"},{"id":"AC-2","status":"satisfied","finding_id":null,"evidence":"ok"}]'
run_check final --expected AC-1,AC-2 --input "$TEST_DIR/r-all.json"
if [ "$CHECK_RC" -eq 0 ] && grep -Fxq '[CONTEXT] ACCEPTANCE_FINAL=ok; unmet=; unverified=' <<<"$CHECK_STDERR"; then
  pass "final: 全充足は unmet / unverified とも空で通過する"
else fail "final all satisfied (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

write_result "$TEST_DIR/r-missing-row.json" '[]' '[]' '[{"id":"AC-1","status":"satisfied","finding_id":null,"evidence":"ok"}]'
run_check final --expected "$AC3" --input "$TEST_DIR/r-missing-row.json"
if [ "$CHECK_RC" -eq 1 ] && grep -Fq 'reason=id_set_mismatch; missing=AC-2,AC-3; extra=; duplicate=' <<<"$CHECK_STDERR"; then
  pass "final: 書き写しで落ちた行を id_set_mismatch で拒否する"
else fail "final missing row (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

write_result "$TEST_DIR/r-dup-row.json" '[]' '[]' '[{"id":"AC-1","status":"satisfied","finding_id":null,"evidence":"ok"},{"id":"AC-1","status":"unverified","finding_id":null,"evidence":"x"}]'
run_check final --expected AC-1 --input "$TEST_DIR/r-dup-row.json"
if [ "$CHECK_RC" -eq 1 ] && grep -Fq 'reason=id_set_mismatch; missing=; extra=; duplicate=AC-1' <<<"$CHECK_STDERR"; then
  pass "final: 同じ AC の重複行を拒否する"
else fail "final dup row (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

write_result "$TEST_DIR/r-demoted.json" '[]' "[$F_UNMET]" "$AC_ROWS"
cp "$TEST_DIR/r-demoted.json" "$TEST_DIR/r-demoted.before"
run_check final --expected "$AC3" --input "$TEST_DIR/r-demoted.json"
if [ "$CHECK_RC" -eq 1 ] && grep -Fq 'reason=unmet_finding_not_blocking; lost=AC-2:F-01' <<<"$CHECK_STDERR" \
  && cmp -s "$TEST_DIR/r-demoted.json" "$TEST_DIR/r-demoted.before" \
  && [ "$(jq -r '.acceptance_criteria[1].status' "$TEST_DIR/r-demoted.json")" = "unmet" ]; then
  pass "final: 未充足 finding が non_blocking_findings[] にあれば失敗し、行を unverified に書き換えない"
else fail "final demoted (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

write_result "$TEST_DIR/r-absent.json" '[]' '[]' "$AC_ROWS"
expect_failure "final: 未充足 finding が存在しなければ失敗" unmet_finding_not_blocking final --expected "$AC3" --input "$TEST_DIR/r-absent.json"

write_result "$TEST_DIR/r-wrongprefix.json" "[${F_UNMET/\[AC-2\]/[AC-5]}]" '[]' "$AC_ROWS"
expect_failure "final: finding の [AC-N] が行と一致しなければ失敗" unmet_finding_not_blocking final --expected "$AC3" --input "$TEST_DIR/r-wrongprefix.json"

echo '{"reviewers":["acceptance-reviewer","test-reviewer"],"findings":[],"non_blocking_findings":[],"measured_gate":{"commit_sha":"abc1234"}}' > "$TEST_DIR/r-nokey.json"
expect_failure "final: acceptance_criteria 欠落は失敗" acceptance_criteria_missing final --expected "$AC3" --input "$TEST_DIR/r-nokey.json"

jq 'del(.reviewers)' "$TEST_DIR/r-ok.json" > "$TEST_DIR/r-noreviewers.json"
expect_failure "final: reviewers が配列でなければ失敗" json_invalid final --expected "$AC3" --input "$TEST_DIR/r-noreviewers.json"

for reason in no_issue no_ac_section; do
  write_result "$TEST_DIR/r-skip.json" '[]' '[]' "{\"skipped\":\"$reason\"}" '["code-quality-reviewer","test-reviewer"]'
  run_check final --expected "" --input "$TEST_DIR/r-skip.json"
  if [ "$CHECK_RC" -eq 0 ] && grep -Fxq "[CONTEXT] ACCEPTANCE_FINAL=skipped; reason=$reason" <<<"$CHECK_STDERR"; then
    pass "final: skipped=$reason は通過する"
  else fail "final skipped $reason (rc=$CHECK_RC err=$CHECK_STDERR)"; fi
done

expect_failure "final: Issue に AC があるのに skipped は失敗" acceptance_scope_mismatch final --expected "$AC3" --input "$TEST_DIR/r-skip.json"

write_result "$TEST_DIR/r-skip-named.json" '[]' '[]' '{"skipped":"no_ac_section"}'
expect_failure "final: skipped なのに reviewers に acceptance-reviewer がいれば失敗" acceptance_scope_mismatch final --expected "" --input "$TEST_DIR/r-skip-named.json"

write_result "$TEST_DIR/r-skip-finding.json" '[]' "[$F_UNMET]" '{"skipped":"no_ac_section"}' '["code-quality-reviewer","test-reviewer"]'
expect_failure "final: skipped なのに acceptance-reviewer の指摘があれば失敗" acceptance_scope_mismatch final --expected "" --input "$TEST_DIR/r-skip-finding.json"

write_result "$TEST_DIR/r-skip-finding-blocking.json" "[$F_UNMET]" '[]' '{"skipped":"no_ac_section"}' '["code-quality-reviewer","test-reviewer"]'
expect_failure "final: skipped なのに acceptance-reviewer の blocking 指摘があれば失敗" acceptance_scope_mismatch final --expected "" --input "$TEST_DIR/r-skip-finding-blocking.json"

expect_failure "final: 対象外 cycle なのに判定行があれば失敗" acceptance_scope_mismatch final --expected "" --input "$TEST_DIR/r-ok.json"

write_result "$TEST_DIR/r-unnamed.json" "[$F_UNMET]" '[]' "$AC_ROWS" '["code-quality-reviewer","test-reviewer"]'
expect_failure "final: 判定行なのに reviewers に acceptance-reviewer がいなければ失敗" acceptance_scope_mismatch final --expected "$AC3" --input "$TEST_DIR/r-unnamed.json"

write_result "$TEST_DIR/r-badrow.json" '[]' '[]' '[{"id":"AC-1","status":"unmet","finding_id":null,"evidence":"x"}]'
expect_failure "final: 未充足行の finding_id 欠落は失敗" acceptance_row_invalid final --expected AC-1 --input "$TEST_DIR/r-badrow.json"

write_result "$TEST_DIR/r-emptyrows.json" '[]' '[]' '[]'
expect_failure "final: 判定行 0 件は失敗" acceptance_row_invalid final --expected AC-1 --input "$TEST_DIR/r-emptyrows.json"

jq 'del(.measured_gate)' "$TEST_DIR/r-ok.json" > "$TEST_DIR/r-ungated.json"
expect_failure "final: 降格ゲート適用前の JSON は失敗" gate_not_applied final --expected "$AC3" --input "$TEST_DIR/r-ungated.json"

write_result "$TEST_DIR/r-strrow.json" '[]' '[]' '["AC-1"]'
expect_failure "final: object でない判定行は失敗 (jq エラーで通さない)" acceptance_row_invalid final --expected AC-1 --input "$TEST_DIR/r-strrow.json"

write_result "$TEST_DIR/r-numid.json" '[]' '[]' '[{"id":5,"status":"satisfied","finding_id":null,"evidence":"ok"}]'
expect_failure "final: 数値の AC-ID は失敗" acceptance_row_invalid final --expected AC-1 --input "$TEST_DIR/r-numid.json"

write_result "$TEST_DIR/r-numdesc.json" "[${F_UNMET/\"\[AC-2\] 壊れている\"/7}]" '[]' "$AC_ROWS"
expect_failure "final: 未充足 finding の description が文字列でなければ失敗" unmet_finding_not_blocking final --expected "$AC3" --input "$TEST_DIR/r-numdesc.json"

expect_failure "final: --expected が AC-N 形式でなければ失敗" expected_invalid final --expected "{acceptance_ids}" --input "$TEST_DIR/r-ok.json"

echo "=== chain: review-measured-gate.sh → final ==="

# 実測アンカーを欠く未充足 finding は実測必須ゲートで降格し、final が拾う
chain_json() {
  # $1 = file, $2 = description
  jq -n --arg d "$2" --argjson ac "$AC_ROWS" '{
    schema_version: "1.1.0", pr_number: 1, timestamp: "__RITE_TS_PLACEHOLDER_7f3a9b2c__",
    commit_sha: "abc1234", overall_assessment: "fix-needed", reviewers: ["acceptance-reviewer", "test-reviewer"],
    findings: [{id: "F-01", reviewer: "acceptance-reviewer", category: "acceptance", severity: "CRITICAL",
      scope: "current-pr", file: "a.sh", line: null, description: $d, suggestion: "直す", status: "open"}],
    non_blocking_findings: [], guardrail_audit_log: [], acceptance_criteria: $ac}' > "$1"
}
chain_json "$TEST_DIR/chain-noanchor.json" "[AC-2] 壊れている<br>Likelihood-Evidence: runtime_observation bash a.sh"
bash "$MGATE" --input "$TEST_DIR/chain-noanchor.json" --reject-preset-verification 2>/dev/null
run_check final --expected "$AC3" --input "$TEST_DIR/chain-noanchor.json"
if [ "$CHECK_RC" -eq 1 ] && grep -Fq 'reason=unmet_finding_not_blocking' <<<"$CHECK_STDERR" \
  && [ "$(jq -r '.acceptance_criteria[1].status' "$TEST_DIR/chain-noanchor.json")" = "unmet" ]; then
  pass "chain: アンカー欠落の未充足は実測ゲートで降格し final が失敗する (acceptance_criteria は保持され unmet のまま)"
else fail "chain noanchor (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

chain_json "$TEST_DIR/chain-anchor.json" "[AC-2] 壊れている<br>Likelihood-Evidence: runtime_observation bash a.sh<br>Verification: repro bash a.sh => exit 0"
bash "$MGATE" --input "$TEST_DIR/chain-anchor.json" --reject-preset-verification 2>/dev/null
run_check final --expected "$AC3" --input "$TEST_DIR/chain-anchor.json"
if [ "$CHECK_RC" -eq 0 ] && [ "$(jq -r '.verdict' "$TEST_DIR/chain-anchor.json")" = "fix-needed" ]; then
  pass "chain: アンカー付きの未充足は blocking に残り final が通過する"
else fail "chain anchor (rc=$CHECK_RC err=$CHECK_STDERR)"; fi

echo "=== invocation ==="
run_check bogus
[ "$CHECK_RC" -eq 2 ] && pass "未知 subcommand は rc=2" || fail "bogus subcommand rc=$CHECK_RC"
run_check final
[ "$CHECK_RC" -eq 2 ] && pass "final の --input 欠落は rc=2" || fail "final no input rc=$CHECK_RC"
run_check final --input "$TEST_DIR/r-ok.json"
[ "$CHECK_RC" -eq 2 ] && pass "final の --expected 欠落は rc=2" || fail "final no expected rc=$CHECK_RC"

echo ""
echo "PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
