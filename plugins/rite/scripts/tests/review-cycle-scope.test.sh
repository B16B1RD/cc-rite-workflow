#!/bin/bash
# Tests for review-cycle-scope.sh (cycle 1 / cycle 2+ 差分スコープの決定)
#
# 本 helper は「cycle 2+ のレビュー対象を前回レビュー起点の差分に絞る」判定の唯一の実行層で、
# 判定を誤ると (a) cycle 1 相当のフルレビューが cycle 2+ でも走り続けて重複調査が残る、または
# (b) 起点が壊れているのに差分スコープへ入って未変更部が誰にも見られない、のどちらかになる。
# (b) は silent に品質を落とすため、本 suite は「情報が欠けた全経路で full へ倒れること」を
# reason ごとに個別に pin する (AC-3 / T-03)。
#
# Usage: bash plugins/rite/scripts/tests/review-cycle-scope.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../review-cycle-scope.sh"
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

# helper 実行。marker は stderr 契約なので stderr を検証対象にする。
run_scope() {
  local err_file="$TEST_DIR/.stderr"
  SCOPE_STDOUT=$(bash "$TARGET" "$@" 2>"$err_file")
  SCOPE_RC=$?
  SCOPE_STDERR=$(cat "$err_file")
  return 0
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label"; echo "     期待する部分文字列: $needle"; echo "     実際: $haystack" ;;
  esac
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) fail "$label"; echo "     出現してはならない部分文字列: $needle" ;;
    *) pass "$label" ;;
  esac
}

assert_rc() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label (expected rc=$expected, got rc=$actual)"; fi
}

# marker の `key=value` を **値として切り出して等値比較**する。
# `assert_contains "... prev_finders="` のような部分文字列 needle は marker 行に常に出現するため
# 「空であること」「特定の値であること」のどちらも検証できない (末尾に何が付いても PASS する)。
# 値を取り出して等値で見る形にしないと、既定値代入や余剰値の混入を素通りさせる。
# 値の終端は marker の区切り `; ` または行末。
marker_value_of() {
  local haystack="$1" key="$2" tail
  tail="${haystack##*${key}=}"
  tail="${tail%%; *}"
  printf '%s' "${tail%%$'\n'*}"
}

assert_marker_eq() {
  local label="$1" haystack="$2" key="$3" expected="$4" actual
  actual=$(marker_value_of "$haystack" "$key")
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label"
    echo "     期待値 ($key): '$expected'"
    echo "     実際:          '$actual'"
  fi
}

# review-result JSON を書く: path commit_sha reviewer...
mk_result_json() {
  local path="$1" sha="$2"; shift 2
  local findings="[]"
  if [ "$#" -gt 0 ]; then
    findings=$(printf '%s\n' "$@" | jq -R '{id:"F-01", reviewer:., category:"c", severity:"HIGH",
      file:"a.sh", line:1, description:"d", suggestion:"s", status:"open", scope:"current-pr"}' | jq -s '.')
  fi
  jq -n --arg sha "$sha" --argjson f "$findings" \
    '{schema_version:"1.0.0", pr_number:42, timestamp:"2026-08-06T00:00:00+09:00",
      commit_sha:$sha, overall_assessment:"fix-needed", findings:$f, non_blocking_findings:[]}' > "$path"
}

# 検証用の git リポジトリを用意し、2 コミット目の HEAD と 1 コミット目の sha を返す
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "test"
echo one > "$REPO/a.sh"
git -C "$REPO" add a.sh
git -C "$REPO" commit -qm "first"
FIRST_SHA=$(git -C "$REPO" rev-parse HEAD)
echo two >> "$REPO/a.sh"
git -C "$REPO" commit -qam "second"

RESULTS="$TEST_DIR/results"
mkdir -p "$RESULTS"

echo "=== TC-1: 前回 JSON が有効なら incremental (AC-1 / T-01) ==="
mk_result_json "$RESULTS/42-20260806-000000.json" "$FIRST_SHA" "code-quality-reviewer" "security-reviewer"
cd "$REPO" || exit 1
run_scope --pr 42 --results-dir "$RESULTS"
assert_rc "TC-1.1: rc=0" 0 "$SCOPE_RC"
assert_contains "TC-1.2: REVIEW_CYCLE_SCOPE=incremental" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
assert_marker_eq "TC-1.3: base_sha は前回 JSON の commit_sha" "$SCOPE_STDERR" "base_sha" "$FIRST_SHA"
assert_not_contains "TC-1.4: fallback marker を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE_FALLBACK"

echo "=== TC-2: prev_finders は agent 名を reviewer_type へ正規化し unique 化する (AC-2) ==="
assert_marker_eq "TC-2.1: -reviewer サフィックスを除去して CSV 化" "$SCOPE_STDERR" "prev_finders" "code-quality,security"
mk_result_json "$RESULTS/42-20260806-000001.json" "$FIRST_SHA" "test-reviewer" "test-reviewer"
run_scope --pr 42 --results-dir "$RESULTS"
assert_marker_eq "TC-2.2: 同一 reviewer の重複は 1 件に畳まれる" "$SCOPE_STDERR" "prev_finders" "test"

echo "=== TC-3: 複数 JSON があれば最新 (ファイル名降順の先頭) を採る ==="
assert_contains "TC-3.1: 最新ファイルが prev_json に入る" "$SCOPE_STDERR" "42-20260806-000001.json"

echo "=== TC-4: blocking 0 件でも incremental を維持する (finder 空) ==="
EMPTY_RESULTS="$TEST_DIR/results-empty"
mkdir -p "$EMPTY_RESULTS"
mk_result_json "$EMPTY_RESULTS/42-20260806-000000.json" "$FIRST_SHA"
run_scope --pr 42 --results-dir "$EMPTY_RESULTS"
assert_contains "TC-4.1: findings[] が空でも incremental" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
assert_marker_eq "TC-4.2: prev_finders は空" "$SCOPE_STDERR" "prev_finders" ""

echo "=== TC-5: results dir 不在は cycle 1 の正常経路 — WARNING を出さない (AC-3 / T-03) ==="
run_scope --pr 42 --results-dir "$TEST_DIR/does-not-exist"
assert_rc "TC-5.1: rc=0" 0 "$SCOPE_RC"
assert_contains "TC-5.2: reason=no_prev_json で full" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=full; reason=no_prev_json"
assert_not_contains "TC-5.3: 正常経路なので fallback marker を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE_FALLBACK"
assert_not_contains "TC-5.4: 正常経路なので ⚠️ を出さない" "$SCOPE_STDERR" "⚠️"

echo "=== TC-6: 当該 PR の JSON が無い (別 PR のみ) も no_prev_json ==="
OTHER="$TEST_DIR/results-other"
mkdir -p "$OTHER"
mk_result_json "$OTHER/99-20260806-000000.json" "$FIRST_SHA"
run_scope --pr 42 --results-dir "$OTHER"
assert_contains "TC-6.1: 別 PR の JSON は拾わない" "$SCOPE_STDERR" "reason=no_prev_json"

echo "=== TC-7: 壊れた JSON は prev_json_unreadable で full + WARNING (AC-3 / T-03) ==="
BROKEN="$TEST_DIR/results-broken"
mkdir -p "$BROKEN"
printf '{ this is not json' > "$BROKEN/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$BROKEN"
assert_rc "TC-7.1: rc=0 (レビュー自体は止めない)" 0 "$SCOPE_RC"
assert_contains "TC-7.2: reason=prev_json_unreadable" "$SCOPE_STDERR" "reason=prev_json_unreadable"
assert_contains "TC-7.3: fallback marker を出す" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE_FALLBACK=1"
assert_contains "TC-7.4: 人間向け WARNING を出す (silent fallback 禁止)" "$SCOPE_STDERR" "⚠️ 差分スコープのフォールバック"

echo "=== TC-8: commit_sha 欠落は commit_sha_missing で full (AC-3 / T-03) ==="
NOSHA="$TEST_DIR/results-nosha"
mkdir -p "$NOSHA"
jq -n '{schema_version:"1.0.0", pr_number:42, findings:[], non_blocking_findings:[]}' > "$NOSHA/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$NOSHA"
assert_contains "TC-8.1: reason=commit_sha_missing" "$SCOPE_STDERR" "reason=commit_sha_missing"
assert_contains "TC-8.2: full へ倒れる" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=full"

echo "=== TC-9: commit_sha が null でも commit_sha_missing (旧形式互換) ==="
NULLSHA="$TEST_DIR/results-nullsha"
mkdir -p "$NULLSHA"
jq -n '{schema_version:"1.0.0", pr_number:42, commit_sha:null, findings:[], non_blocking_findings:[]}' > "$NULLSHA/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$NULLSHA"
assert_contains "TC-9.1: null は空扱いで commit_sha_missing" "$SCOPE_STDERR" "reason=commit_sha_missing"

echo "=== TC-10: 到達不能な commit_sha は commit_sha_unreachable (force-push/rebase, AC-3 / T-03) ==="
GONE="$TEST_DIR/results-gone"
mkdir -p "$GONE"
mk_result_json "$GONE/42-20260806-000000.json" "0000000000000000000000000000000000000000"
run_scope --pr 42 --results-dir "$GONE"
assert_contains "TC-10.1: reason=commit_sha_unreachable" "$SCOPE_STDERR" "reason=commit_sha_unreachable"
assert_contains "TC-10.2: full へ倒れる" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=full"

echo "=== TC-11: commit でない object (blob sha) を起点に採らない ==="
BLOB_SHA=$(git -C "$REPO" rev-parse HEAD:a.sh)
BLOB="$TEST_DIR/results-blob"
mkdir -p "$BLOB"
mk_result_json "$BLOB/42-20260806-000000.json" "$BLOB_SHA"
run_scope --pr 42 --results-dir "$BLOB"
assert_contains "TC-11.1: blob sha は commit_sha_unreachable" "$SCOPE_STDERR" "reason=commit_sha_unreachable"

echo "=== TC-12: usage error ==="
run_scope --results-dir "$RESULTS"
assert_rc "TC-12.1: --pr 欠落は rc=2" 2 "$SCOPE_RC"
run_scope --pr abc --results-dir "$RESULTS"
assert_rc "TC-12.2: 非数値 --pr は rc=2" 2 "$SCOPE_RC"
run_scope --pr 42 --bogus x
assert_rc "TC-12.3: 未知引数は rc=2" 2 "$SCOPE_RC"

echo "=== TC-14: gated scope の finding だけを prev_finders に採る (findings[] は blocking 集合ではない) ==="
# review-measured-gate.sh は scope=nit-noted をゲート対象外として非実測でも findings[] に残す。
# 絞らないと nit しか出していない reviewer が caller 側で mandatory 合流し cap 免除枠を占有する。
MIXED="$TEST_DIR/results-mixed"
mkdir -p "$MIXED"
jq -n --arg sha "$FIRST_SHA" '{
  schema_version:"1.0.0", pr_number:42, timestamp:"t", commit_sha:$sha,
  overall_assessment:"fix-needed",
  findings:[
    {id:"F-01", reviewer:"application-reviewer", category:"c", severity:"HIGH",
     file:"a.sh", line:1, description:"d", suggestion:"s", status:"open", scope:"current-pr"},
    {id:"F-02", reviewer:"tech-writer-reviewer", category:"c", severity:"LOW",
     file:"b.md", line:2, description:"d", suggestion:"s", status:"open", scope:"nit-noted"},
    {id:"F-03", reviewer:"devops-reviewer", category:"c", severity:"MEDIUM",
     file:"c.yml", line:3, description:"d", suggestion:"s", status:"open", scope:"follow-up"}
  ],
  non_blocking_findings:[]
}' > "$MIXED/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$MIXED"
assert_marker_eq "TC-14.1: nit-noted のみの reviewer は prev_finders に載らない" \
  "$SCOPE_STDERR" "prev_finders" "application,devops"

echo "=== TC-14b: non_blocking_findings[] へ移送された gated 指摘の reviewer も拾う ==="
# 実測必須ゲートは非実測の gated 指摘を findings[] から non_blocking_findings[] へ移送する。
# findings[] だけ見ると、その cycle の gated 指摘が全件非実測だった reviewer が mandatory 合流から
# 外れ、記録コメント (update-in-place) からも消える。
MOVED="$TEST_DIR/results-moved"
mkdir -p "$MOVED"
jq -n --arg sha "$FIRST_SHA" '{
  schema_version:"1.0.0", pr_number:42, commit_sha:$sha, overall_assessment:"mergeable",
  findings:[
    {id:"F-01", reviewer:"tech-writer-reviewer", category:"c", severity:"LOW",
     file:"a.md", line:1, description:"d", suggestion:"s", status:"open", scope:"nit-noted"}
  ],
  non_blocking_findings:[
    {id:"F-02", reviewer:"security-reviewer", category:"c", severity:"CRITICAL",
     file:"b.sh", line:2, description:"d", suggestion:"s", status:"open", scope:"current-pr"}
  ]
}' > "$MOVED/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$MOVED"
assert_marker_eq "TC-14b.1: 移送された gated 指摘の reviewer を拾い、nit のみの reviewer は除く" \
  "$SCOPE_STDERR" "prev_finders" "security"

echo "=== TC-19: scope / reviewer の欠落は無音で捨てず full へ倒す ==="
# select は条件に合わない要素を無音で捨てるため、部分欠落だと結果が正常系と見分けがつかない。
# 最も危険なのは「2 件中 1 件だけ欠落」— 出力が非空なので異常に見えない。
PARTIAL="$TEST_DIR/results-partial-scope"
mkdir -p "$PARTIAL"
jq -n --arg sha "$FIRST_SHA" '{
  schema_version:"1.0.0", pr_number:42, commit_sha:$sha, overall_assessment:"fix-needed",
  findings:[
    {id:"F-01", reviewer:"security-reviewer", severity:"CRITICAL", file:"a.sh", line:1},
    {id:"F-02", reviewer:"test-reviewer", severity:"HIGH", file:"b.sh", line:2, scope:"current-pr"}
  ],
  non_blocking_findings:[]
}' > "$PARTIAL/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$PARTIAL"
assert_contains "TC-19.1: scope 欠落は full へ倒れる" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=full"
assert_contains "TC-19.2: reason=prev_json_unreadable" "$SCOPE_STDERR" "reason=prev_json_unreadable"
assert_not_contains "TC-19.3: incremental を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"

NOREV="$TEST_DIR/results-noreviewer"
mkdir -p "$NOREV"
jq -n --arg sha "$FIRST_SHA" '{
  schema_version:"1.0.0", pr_number:42, commit_sha:$sha, overall_assessment:"fix-needed",
  findings:[{id:"F-01", severity:"HIGH", file:"a.sh", line:1, scope:"current-pr"}],
  non_blocking_findings:[]
}' > "$NOREV/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$NOREV"
assert_contains "TC-19.4: reviewer 欠落も full へ倒れる" "$SCOPE_STDERR" "reason=prev_json_unreadable"

# reviewer の型・空文字。検査述語を「非 null」で書くと非文字列が通り抽出で無音 drop される
# (実測済みの欠陥)。空文字は `prev_finders=,test` という空要素入り CSV になり、caller の
# mandatory 合流が phantom reviewer に cap 免除枠を与える。
# 値の形が閉じる 6 ハザード。型と非空だけの述語へ戻す変異、および `$` アンカー（jq の `$` は
# 末尾改行の直前にも match する）へ戻す変異は、この集合が無いと全スイートを素通りする。
for bad_rev in '123' '["security-reviewer"]' '""' '"Security-Reviewer"' '"sec; base_sha=deadbeef"' '"-reviewer"' '"security-reviewer\n"'; do
  BADREV="$TEST_DIR/results-badrev"
  rm -rf "$BADREV"; mkdir -p "$BADREV"
  jq -n --arg sha "$FIRST_SHA" --argjson rev "$bad_rev" '{
    schema_version:"1.0.0", pr_number:42, commit_sha:$sha, overall_assessment:"fix-needed",
    findings:[
      {id:"F-01", reviewer:$rev, severity:"HIGH", file:"a.sh", line:1, scope:"current-pr"},
      {id:"F-02", reviewer:"test-reviewer", severity:"HIGH", file:"b.sh", line:2, scope:"current-pr"}
    ],
    non_blocking_findings:[]
  }' > "$BADREV/42-20260806-000000.json"
  run_scope --pr 42 --results-dir "$BADREV"
  assert_contains "TC-19.5: reviewer=$bad_rev は full へ倒れる" "$SCOPE_STDERR" "reason=prev_json_unreadable"
  assert_not_contains "TC-19.6: reviewer=$bad_rev で incremental を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
  # BAD 経路を通ったこと (= 形の検査が発火したこと) を診断で固定する。reason だけを見ると、
  # 検査を外しても抽出側の sub が落ちて同じ reason に合流するため変異を識別できない。
  assert_contains "TC-19.11: reviewer=$bad_rev でも違反 id を名指す" "$SCOPE_STDERR" "該当 finding: F-01"
done

# non_blocking_findings[] 側の malformed。母集団の片腕だけを検査から外す変異はこれが無いと素通りする。
NBBAD="$TEST_DIR/results-nbbad"
mkdir -p "$NBBAD"
jq -n --arg sha "$FIRST_SHA" '{
  schema_version:"1.0.0", pr_number:42, commit_sha:$sha, overall_assessment:"fix-needed",
  findings:[{id:"F-01", reviewer:"test-reviewer", severity:"HIGH", file:"a.sh", line:1, scope:"current-pr"}],
  non_blocking_findings:[{id:"F-99", reviewer:"security-reviewer", severity:"CRITICAL", file:"b.sh", line:2}]
}' > "$NBBAD/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$NBBAD"
assert_contains "TC-19.7: non_blocking 側の scope 欠落も full へ倒れる" "$SCOPE_STDERR" "reason=prev_json_unreadable"
assert_not_contains "TC-19.8: 同上で incremental を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
# 不正 finding が JSON 内に固定される以上、以後毎 cycle 恒久的に full へ倒れ続ける。
# どの finding が原因かを WARNING が名指さないと、運用者は世代蓄積した数十件から手で探すことになる。
assert_contains "TC-19.9: 違反 finding の id を surface する" "$SCOPE_STDERR" "F-99"
assert_contains "TC-19.10: 対象パスも surface する" "$SCOPE_STDERR" "$NBBAD/42-20260806-000000.json"

echo "=== TC-20: commit_sha の抽出失敗とキー欠落を別 reason に分ける ==="
# 抽出失敗 (トップレベルが object でない) を commit_sha_missing = 良性の旧形式 として
# 報告すると、破損が旧形式互換の顔をして無視される。
NOTOBJ="$TEST_DIR/results-notobject"
mkdir -p "$NOTOBJ"
printf '[]' > "$NOTOBJ/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$NOTOBJ"
assert_contains "TC-20.1: 非 object は prev_json_unreadable" "$SCOPE_STDERR" "reason=prev_json_unreadable"
assert_contains "TC-20.2: jq のエラー本文を出す" "$SCOPE_STDERR" "Cannot index array"
assert_contains "TC-20.3: 対象パスを出す" "$SCOPE_STDERR" "$NOTOBJ/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$NOSHA"
assert_contains "TC-20.4: キー欠落は commit_sha_missing のまま" "$SCOPE_STDERR" "reason=commit_sha_missing"
assert_contains "TC-20.5: キー欠落の WARNING も対象パスを出す" "$SCOPE_STDERR" "$NOSHA/42-20260806-000000.json"

echo "=== TC-15: prev_finders の jq 失敗は silent に incremental を維持しない (loud fail-safe) ==="
# findings が iterable だが要素が object でない → .reviewer 参照で jq rc=5。
# 空の prev_finders= は「blocking 0 件」の正常系とバイト単位で同一のため、fallback すると
# 「前サイクル finder の無条件再起動」が無音で破れたまま差分スコープへ入る。
BADF="$TEST_DIR/results-badfindings"
mkdir -p "$BADF"
jq -n --arg sha "$FIRST_SHA" '{
  schema_version:"1.0.0", pr_number:42, commit_sha:$sha,
  overall_assessment:"fix-needed",
  findings:["code-quality-reviewer"],
  non_blocking_findings:[]
}' > "$BADF/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$BADF"
assert_rc "TC-15.1: rc=0 (レビュー自体は止めない)" 0 "$SCOPE_RC"
assert_contains "TC-15.2: incremental を維持せず full へ倒れる" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=full"
assert_contains "TC-15.3: reason=prev_json_unreadable" "$SCOPE_STDERR" "reason=prev_json_unreadable"
assert_contains "TC-15.4: fallback marker を出す" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE_FALLBACK=1"
# AC-3 が守るのは「full へ倒れること」ではなく「full **だけ**になること」。
# emit_full の exit を局所的に落とす変異は、この負の assertion が無いと素通りする。
assert_not_contains "TC-15.5: fail-safe 後に incremental を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
# どの handler が発火したかを固定する。結果 (full / reason / fallback marker) だけを見る
# assertion は、fail-safe を無音 fallback へ書き換えても別経路が同じ結果を出せば素通りする。
assert_contains "TC-15.6: 抽出 fail-safe が発火したことを文言で固定" "$SCOPE_STDERR" "前回 finder を抽出できません"

echo "=== TC-16: fail-safe 時に対象と原因を surface する (診断を捨てない) ==="
run_scope --pr 42 --results-dir "$BROKEN"
assert_contains "TC-16.1: 壊れた JSON のパスを出す" "$SCOPE_STDERR" "$BROKEN/42-20260806-000000.json"
assert_contains "TC-16.2: jq の parse error 本文を出す" "$SCOPE_STDERR" "parse error"
run_scope --pr 42 --results-dir "$GONE"
assert_contains "TC-16.3: 到達不能 sha の値を出す" "$SCOPE_STDERR" "base_sha=0000000000000000000000000000000000000000"

echo "=== TC-17: jq 不在は full へ fail-safe する (AC-3、環境欠陥でレビューを止めない) ==="
NOJQ_BIN="$TEST_DIR/nojq-bin"
mkdir -p "$NOJQ_BIN"
for _b in bash find sort git head sed basename dirname mktemp rm cat printf; do
  _p=$(command -v "$_b" 2>/dev/null) && ln -sf "$_p" "$NOJQ_BIN/$_b"
done
NOJQ_STDERR="$TEST_DIR/.nojq-stderr"
PATH="$NOJQ_BIN" bash "$TARGET" --pr 42 --results-dir "$RESULTS" 2>"$NOJQ_STDERR"
NOJQ_RC=$?
NOJQ_OUT=$(cat "$NOJQ_STDERR")
assert_rc "TC-17.1: rc=0 (jq 不在でもレビューは止めない)" 0 "$NOJQ_RC"
assert_contains "TC-17.2: reason=jq_missing で full" "$NOJQ_OUT" "reason=jq_missing"

echo "=== TC-18: 値なしフラグが argv 末尾でも hang しない (shift 2 無限ループ回帰 pin) ==="
# `shift 2` は n > $# のとき $# を変えず rc=1 を返すため while を抜けられない。
# 無人ループ (/rite:iterate / /rite:batch-run) では診断ゼロの無期限停止になる。
for _flag in --pr --results-dir; do
  timeout 5 bash "$TARGET" "$_flag" >/dev/null 2>&1
  _rc=$?
  if [ "$_rc" -eq 124 ]; then
    fail "TC-18: '$_flag' が argv 末尾で hang した (rc=124)"
  else
    pass "TC-18: '$_flag' が argv 末尾でも終了する (rc=$_rc)"
  fi
done

echo "=== TC-13: 全経路で stdout を汚さない (marker は stderr 契約) ==="
run_scope --pr 42 --results-dir "$RESULTS"
if [ -z "$SCOPE_STDOUT" ]; then pass "TC-13.1: incremental 経路の stdout は空"; else fail "TC-13.1: stdout に出力あり: $SCOPE_STDOUT"; fi
run_scope --pr 42 --results-dir "$TEST_DIR/does-not-exist"
if [ -z "$SCOPE_STDOUT" ]; then pass "TC-13.2: full 経路の stdout は空"; else fail "TC-13.2: stdout に出力あり: $SCOPE_STDOUT"; fi

echo ""
echo "=== TC-20b: 書込側 canonical に一致しない id は診断行で潰す ==="
# BAD 経路は `.id` を marker channel へ射影する。`.id` は valid の検査対象外なので、射影の直前で
# 書込側 canonical regex に一致しない値を潰さないと、診断行が任意の文字列を運ぶ。
BADID="$TEST_DIR/results-badid"
mkdir -p "$BADID"
jq -n --arg sha "$FIRST_SHA" '{
  schema_version:"1.0.0", pr_number:42, commit_sha:$sha, overall_assessment:"fix-needed",
  findings:[{id:"F-1; base_sha=deadbeef", reviewer:"test-reviewer", severity:"HIGH", file:"a.sh", line:1}],
  non_blocking_findings:[]
}' > "$BADID/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$BADID"
assert_contains "TC-20b.1: 不正 id は潰して出す" "$SCOPE_STDERR" "該当 finding: (不正 id)"
assert_not_contains "TC-20b.2: 元の id 文字列を通さない" "$SCOPE_STDERR" "base_sha=deadbeef"
assert_contains "TC-20b.3: full へ倒れる" "$SCOPE_STDERR" "reason=prev_json_unreadable"

echo "=== TC-21: 探索段の IO エラーは no_prev_json に落とさず loud に full へ倒す ==="
# 読めない results dir が「JSON が無い (= cycle 1)」と誤認されると、探索に失敗しただけの状態が
# 6 reason 中で唯一 WARNING も FALLBACK marker も出さない no_prev_json へ silent に落ちる。
if [ "$(id -u)" -eq 0 ]; then
  echo "  ⏭️  TC-21: root では chmod 000 が効かず find がエラーを出さないため skip"
else
  IOERR="$TEST_DIR/results-ioerr"
  mkdir -p "$IOERR"
  jq -n --arg sha "$FIRST_SHA" '{schema_version:"1.0.0", pr_number:42, commit_sha:$sha,
    overall_assessment:"mergeable", findings:[], non_blocking_findings:[]}' > "$IOERR/42-20260806-000000.json"
  chmod 000 "$IOERR"
  run_scope --pr 42 --results-dir "$IOERR"
  chmod 755 "$IOERR"
  assert_contains "TC-21.1: 探索エラーは prev_json_unreadable" "$SCOPE_STDERR" "reason=prev_json_unreadable"
  assert_contains "TC-21.2: 人間向け WARNING を出す" "$SCOPE_STDERR" "⚠️ 差分スコープのフォールバック"
  assert_not_contains "TC-21.3: no_prev_json へ落とさない" "$SCOPE_STDERR" "reason=no_prev_json"
fi

echo "=== TC-22: 差分ゼロ行 (前回起点から新規 commit なし) は empty_diff で full へ倒す ==="
# /rite:fix の accept-only cycle では base_sha == HEAD となり必ず成立する。rc だけを見ると成功に
# 見えるため、そのまま incremental を宣言すると審査対象も解消検証の材料も空の prompt になる。
EMPTYD="$TEST_DIR/results-emptydiff"
mkdir -p "$EMPTYD"
head_sha=$(git -C "$REPO" rev-parse HEAD)
jq -n --arg sha "$head_sha" '{schema_version:"1.0.0", pr_number:42, commit_sha:$sha,
  overall_assessment:"fix-needed",
  findings:[{id:"F-01", reviewer:"test-reviewer", severity:"HIGH", file:"a.sh", line:1, scope:"current-pr"}],
  non_blocking_findings:[]}' > "$EMPTYD/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$EMPTYD"
assert_contains "TC-22.1: reason=empty_diff" "$SCOPE_STDERR" "reason=empty_diff"
assert_contains "TC-22.2: full へ倒れる" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=full"
assert_not_contains "TC-22.3: incremental を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
assert_contains "TC-22.4: 起点 sha を surface する" "$SCOPE_STDERR" "$head_sha"

echo "=== TC-23: run 開始点 pin より古い JSON は現 run のものとみなさない ==="
# .rite/review-results/ は /rite:cleanup まで同一 PR の複数 run を同居させる。pin を見ないと
# ブレーカー発火後に人間が再実行した run の cycle 1 が前 run の最終 JSON を拾って incremental に
# なり、MUST NOT「cycle 1 の挙動を変えない」が破れる（失敗方向が禁じられた狭い側）。
PINDIR="$TEST_DIR/results-pin"
mkdir -p "$PINDIR"
jq -n --arg sha "$FIRST_SHA" '{schema_version:"1.0.0", pr_number:42, commit_sha:$sha,
  overall_assessment:"fix-needed",
  findings:[{id:"F-01", reviewer:"application-reviewer", severity:"HIGH", file:"a.sh", line:1, scope:"current-pr"}],
  non_blocking_findings:[]}' > "$PINDIR/42-20260101-000000.json"
# pin = その JSON 自身 → pin より新しいファイルは 1 件も無い = 現 run の初回
run_scope --pr 42 --results-dir "$PINDIR" --since "42-20260101-000000.json"
assert_contains "TC-23.1: pin 以前しか無ければ no_prev_json" "$SCOPE_STDERR" "reason=no_prev_json"
assert_not_contains "TC-23.2: incremental を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
# pin より新しい JSON があれば従来どおり incremental
jq -n --arg sha "$FIRST_SHA" '{schema_version:"1.0.0", pr_number:42, commit_sha:$sha,
  overall_assessment:"fix-needed",
  findings:[{id:"F-02", reviewer:"security-reviewer", severity:"HIGH", file:"b.sh", line:2, scope:"current-pr"}],
  non_blocking_findings:[]}' > "$PINDIR/42-20260202-000000.json"
run_scope --pr 42 --results-dir "$PINDIR" --since "42-20260101-000000.json"
assert_contains "TC-23.3: pin より新しい JSON があれば incremental" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
assert_marker_eq "TC-23.4: 現 run の JSON だけを finder 母集団にする" "$SCOPE_STDERR" "prev_finders" "security"
# pin 不在 (空文字) は全件を現 run とみなす = 新規 PR の正常系
run_scope --pr 42 --results-dir "$PINDIR" --since ""
assert_contains "TC-23.5: pin 空なら全件を現 run とみなす" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"

echo "=== TC-24: production 経路 (--since / --results-dir とも省略) で既定 pin 読取が効く ==="
# consumer (pr-review ステップ 1.2.4) は `--pr {n}` のみで起動する。TC-23 が固定するのは
# `--since` 明示経路で、production が通る既定読取（state root 解決 → pin ファイル）は別経路。
# ここを外すと、ブレーカー発火後の再実行の cycle 1 が前 run の JSON を拾って incremental になる。
PRODROOT="$TEST_DIR/prod-repo"
mkdir -p "$PRODROOT"
git -C "$PRODROOT" init -q 2>/dev/null || git init -q "$PRODROOT"
git -C "$PRODROOT" config user.email t@example.com
git -C "$PRODROOT" config user.name t
echo one > "$PRODROOT/a.txt"
git -C "$PRODROOT" add -A
git -C "$PRODROOT" commit -qm one
prod_first=$(git -C "$PRODROOT" rev-parse HEAD)
echo two > "$PRODROOT/b.txt"
git -C "$PRODROOT" add -A
git -C "$PRODROOT" commit -qm two
mkdir -p "$PRODROOT/.rite/review-results" "$PRODROOT/.rite/state"
jq -n --arg sha "$prod_first" '{schema_version:"1.0.0", pr_number:42, commit_sha:$sha,
  overall_assessment:"fix-needed",
  findings:[{id:"F-01", reviewer:"security-reviewer", severity:"HIGH", file:"a.sh", line:1, scope:"current-pr"}],
  non_blocking_findings:[]}' > "$PRODROOT/.rite/review-results/42-20260101-000000.json"

# (a) pin ファイル不在 → 全件を現 run とみなす（新規 PR の正常系）
SCOPE_STDERR=$(cd "$PRODROOT" && bash "$TARGET" --pr 42 2>&1) || true
assert_contains "TC-24.1: pin 不在なら全件を現 run とみなす" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"

# (b) pin = その JSON 自身 → pin より新しいファイルが無い = 現 run の初回 = cycle 1
printf '%s\n' "42-20260101-000000.json" > "$PRODROOT/.rite/state/review-run-since-42.txt"
SCOPE_STDERR=$(cd "$PRODROOT" && bash "$TARGET" --pr 42 2>&1) || true
assert_contains "TC-24.2: 既定 pin 読取が効き cycle 1 は full" "$SCOPE_STDERR" "reason=no_prev_json"
assert_not_contains "TC-24.3: incremental を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"

# (c) pin が存在するが読めない → 不在と区別して広い側へ倒す（狭い側へ倒さない）
if [ "$(id -u)" -eq 0 ]; then
  echo "  ⏭️  TC-24.4: root では chmod 000 が効かないため skip"
else
  chmod 000 "$PRODROOT/.rite/state/review-run-since-42.txt"
  SCOPE_STDERR=$(cd "$PRODROOT" && bash "$TARGET" --pr 42 2>&1) || true
  chmod 644 "$PRODROOT/.rite/state/review-run-since-42.txt"
  assert_contains "TC-24.4: 読めない pin は run_pin_unreadable" "$SCOPE_STDERR" "reason=run_pin_unreadable"
  assert_not_contains "TC-24.5: 読めない pin で incremental へ倒さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
fi

# (d) --since 明示は pin より優先される
SCOPE_STDERR=$(cd "$PRODROOT" && bash "$TARGET" --pr 42 --since "" 2>&1) || true
assert_contains "TC-24.6: --since 明示が既定 pin を上書きする" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
