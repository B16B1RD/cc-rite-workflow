#!/bin/bash
# Tests for hooks/scripts/review-save-json-verify.sh
#
# 本 helper は ステップ 8.0.4 の機械強制の **positive 層**である。marker の残存検査 (negative) は
# marker の設置 (5.3.0.M step 2) と解除 (6.1.a) の両方が「飛ばされる区間」の内側にあるため、
# 区間ごと skip した cycle を「6.1.a が完走して marker を消した」場合と区別できない。ここで固定
# するのは、その穴を塞ぐ判定 — 「現 run の results dir に、本 cycle の commit SHA を持つ結果 JSON が
# 実在するか」— の分岐と exit code、および fail 時の診断が「区間ごと未実行」と「本 cycle 分だけ
# 未保存」を切り分けられることである (Issue #2127 AC-1〜AC-6)。
#
# Convention (shared with the sibling suite): mktemp sandbox, no network, no gh,
# GNU/BSD portable (jq only)。--results-dir / --since を明示するため git repo は不要。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/review-save-json-verify.sh"

echo "=== review-save-json-verify.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  # Floor first (sibling review-trend-divergence.test.sh と同じ論拠): jq は全 leg の前提なので、
  # blocking gate 上での不在は「PATH から消えた/隠れた」であって「環境に無い」ではない。
  # skip するとこのファイルのカバレッジ全体が green のまま落ちる。
  if [ -d /proc ]; then
    echo "  ❌ FAIL: review-save-json-verify floor: jq unavailable on Linux (missing or shadowed on PATH?)"
    echo "Results: 0 passed, 1 failed"
    exit 1
  fi
  skip "review-save-json-verify: jq unavailable"
  print_summary "review-save-json-verify"
  exit $?
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
ERR="$SANDBOX/err.txt"
RC=0

# ---------------------------------------------------------------------------
# Fixture builder: commit_sha を指定した結果 JSON を 1 件生成する。
# ファイル名 `{pr}-{timestamp}.json` の LC_ALL=C 昇順 = 時系列昇順 (run pin の比較軸)。
# ---------------------------------------------------------------------------
make_result() {
  # $1 = dir, $2 = pr, $3 = seq (2 桁), $4 = commit_sha
  local dir="$1" pr="$2" seq="$3" sha="$4"
  jq -n --argjson pr "$pr" --arg sha "$sha" '
    {
      schema_version: "1.1.0",
      pr_number: $pr,
      timestamp: "2026-01-01T00:00:00+09:00",
      commit_sha: $sha,
      overall_assessment: "mergeable",
      findings: [],
      non_blocking_findings: []
    }' > "$dir/${pr}-202601010000${seq}.json"
}

# helper を実行し stderr を $ERR へ、exit code を $RC へ。
run_verify() {
  RC=0
  bash "$SCRIPT" "$@" >/dev/null 2>"$ERR" || RC=$?
}

# ---------------------------------------------------------------------------
# T-01: 正常系 — 本 cycle の commit SHA を持つ JSON が実在すれば pass (AC-1)
# ---------------------------------------------------------------------------
echo "--- T-01: 正常系の pass (AC-1) ---"

DIR_OK="$SANDBOX/ok"; mkdir -p "$DIR_OK"
make_result "$DIR_OK" 900 01 "aaaa111"
make_result "$DIR_OK" 900 02 "bbbb222"

run_verify --pr 900 --commit-sha "bbbb222" --results-dir "$DIR_OK" --since ""
assert "T-01a: 本 cycle の JSON が実在すれば rc=0" "0" "$RC"
assert_grep "T-01b: reason は marker 層の語彙をそのまま使う (下流 consumer を drift させない)" "$ERR" \
  'REVIEW_SAVE_GATE=pass; reason=save_pending_marker_absent'
assert_grep "T-01c: どのファイルで通ったかを result_json= で開示する" "$ERR" 'result_json=900-20260101000002.json'
assert_not_grep "T-01d: 正常系で GATE_FAILED を出さない" "$ERR" 'REVIEW_SAVE_GATE_FAILED'

# ---------------------------------------------------------------------------
# T-02: 区間ごと skip — JSON が 1 件も無ければ fail (AC-2。本 Issue が塞ぐ本命経路)
# ---------------------------------------------------------------------------
echo "--- T-02: 区間ごと skip の検出 (AC-2) ---"

DIR_EMPTY="$SANDBOX/empty"; mkdir -p "$DIR_EMPTY"

run_verify --pr 901 --commit-sha "cccc333" --results-dir "$DIR_EMPTY" --since ""
assert "T-02a: JSON が 1 件も無ければ rc=1 (差し戻し)" "1" "$RC"
assert_grep "T-02b: GATE_FAILED を reason 付きで emit する" "$ERR" \
  'REVIEW_SAVE_GATE_FAILED=1; reason=save_result_json_absent'
assert_grep "T-02c: 期待した commit SHA を marker に載せる" "$ERR" 'expected_sha=cccc333'
assert_not_grep "T-02d: fail 時に pass を emit しない" "$ERR" 'REVIEW_SAVE_GATE=pass'
# 差し戻し先が **step 0** であること自体が不変条件 — step 2 だけを名指しすると 8.0.3 の anchor
# (REVIEW_CYCLE_ID / NONBLOCKING_PENDING_MARKER) が前 cycle のまま残り 8.0.3 が再び誤 pass する。
assert_grep "T-02e: ACTION が 6.1.a step 0 からの再実行を指示する" "$ERR" 'step 0 から'
assert_grep "T-02f: marker が一度も無い場合の入口 (5.3.0.M step 2) も案内する" "$ERR" '5.3.0.M step 2'

# ---------------------------------------------------------------------------
# T-04: 前 cycle の JSON では pass しない (AC-4)
#       「ファイルが 1 件でもあれば pass」に退行すると本ケースが素通りする。
# ---------------------------------------------------------------------------
echo "--- T-04: commit SHA 一致で判定する (AC-4) ---"

DIR_STALE="$SANDBOX/stale"; mkdir -p "$DIR_STALE"
make_result "$DIR_STALE" 902 01 "old111"
make_result "$DIR_STALE" 902 02 "old222"

run_verify --pr 902 --commit-sha "new999" --results-dir "$DIR_STALE" --since ""
assert "T-04a: 前 cycle の JSON だけでは rc=1" "1" "$RC"
assert_grep "T-04b: reason は save_result_json_absent" "$ERR" 'reason=save_result_json_absent'

# 別 PR の JSON は同一 dir にあっても現 run の候補に入らない (ファイル名 prefix で絞る契約)。
make_result "$DIR_STALE" 903 03 "new999"
run_verify --pr 902 --commit-sha "new999" --results-dir "$DIR_STALE" --since ""
assert "T-04c: 別 PR の JSON が同 SHA を持っても pass しない" "1" "$RC"

# ---------------------------------------------------------------------------
# T-04': run 境界 — pin より古い JSON は現 run に含めない
#        breaker 発火後の再実行 (同一 HEAD のまま cycle 1) で前 run の JSON を拾わせない。
# ---------------------------------------------------------------------------
echo "--- T-04': run 開始点 pin による現 run の切り出し ---"

DIR_PIN="$SANDBOX/pin"; mkdir -p "$DIR_PIN"
make_result "$DIR_PIN" 904 01 "same777"   # 前 run の最終ファイル (= pin 自身)
make_result "$DIR_PIN" 904 02 "same777"   # 現 run で保存されたファイル

run_verify --pr 904 --commit-sha "same777" --results-dir "$DIR_PIN" --since "904-20260101000001.json"
assert "T-04'a: pin より新しい JSON があれば pass" "0" "$RC"
assert_grep "T-04'b: pass したのは pin より後ろのファイル" "$ERR" 'result_json=904-20260101000002.json'

DIR_PIN2="$SANDBOX/pin2"; mkdir -p "$DIR_PIN2"
make_result "$DIR_PIN2" 905 01 "same777"
run_verify --pr 905 --commit-sha "same777" --results-dir "$DIR_PIN2" --since "905-20260101000001.json"
assert "T-04'c: pin 自身 (前 run の最終ファイル) では pass しない" "1" "$RC"
assert_grep "T-04'd: pin を診断に出す" "$ERR" 'run 開始点 pin: 905-20260101000001.json'

# ---------------------------------------------------------------------------
# T-05: 診断が「区間ごと未実行」と「本 cycle 分だけ未保存」を切り分けられる (AC-5)
# ---------------------------------------------------------------------------
echo "--- T-05: fail 時の診断 (AC-5) ---"

run_verify --pr 902 --commit-sha "new999" --results-dir "$DIR_STALE" --since ""
assert_grep "T-05a: 期待した commit_sha を人間可読に出す" "$ERR" '期待した commit_sha'
assert_grep "T-05b: 実在ファイルを basename + commit_sha で列挙する" "$ERR" '902-20260101000001\.json \(commit_sha=old111\)'
assert_grep "T-05c: 実在件数を出す" "$ERR" '現 run に実在する JSON \(2 件\)'
assert_grep "T-05d: 切り分けの指針を出す" "$ERR" '切り分け:'

run_verify --pr 901 --commit-sha "cccc333" --results-dir "$DIR_EMPTY" --since ""
assert_grep "T-05e: 一覧が空のときは「(なし)」と明示する (無言で省略しない)" "$ERR" '^ +\(なし\)$'
assert_grep "T-05f: 空のときも件数を 0 と出す" "$ERR" '現 run に実在する JSON \(0 件\)'

# ---------------------------------------------------------------------------
# T-06: 判定不能は degraded — 黙って pass にしない (AC-6)
# ---------------------------------------------------------------------------
echo "--- T-06: 判定不能時の degraded (AC-6) ---"

run_verify --pr 906 --commit-sha "aaa111" --results-dir "$SANDBOX/does-not-exist" --since ""
assert "T-06a: results dir 不在は非致命 (rc=0)" "0" "$RC"
assert_grep "T-06b: degraded を reason 付きで emit する" "$ERR" \
  'REVIEW_SAVE_GATE=degraded; reason=save_result_json_undecidable'
assert_grep "T-06c: WARNING で原因を名指しする" "$ERR" 'レビュー結果ディレクトリが存在しません'
assert_not_grep "T-06d: degraded を pass に読み替えない" "$ERR" 'REVIEW_SAVE_GATE=pass'

# 置換漏れ: fail にすると差し戻し先 (6.1.a) を何度実行しても直らず非収束ループになるため degraded。
run_verify --pr "{pr_number}" --commit-sha "aaa111" --results-dir "$DIR_OK" --since ""
assert "T-06e: {pr_number} 置換漏れは rc=0 (非収束ループを作らない)" "0" "$RC"
assert_grep "T-06f: 置換漏れの原因を名指しする" "$ERR" '\{pr_number\}'
assert_grep "T-06g: 置換漏れも degraded に載る" "$ERR" 'reason=save_result_json_undecidable'

run_verify --pr 900 --commit-sha "{current_commit_sha}" --results-dir "$DIR_OK" --since ""
assert "T-06h: {current_commit_sha} 置換漏れは rc=0" "0" "$RC"
assert_grep "T-06i: ステップ 1.2.5 の置換漏れとして案内する" "$ERR" '1.2.5'
assert_grep "T-06j: 置換漏れも degraded に載る" "$ERR" 'reason=save_result_json_undecidable'

run_verify --pr 900 --commit-sha "" --results-dir "$DIR_OK" --since ""
assert "T-06k: --commit-sha 空も degraded (空を「一致なし」と読んで fail にしない)" "0" "$RC"
assert_grep "T-06l: 空も degraded に載る" "$ERR" 'reason=save_result_json_undecidable'

# jq 不在: 入力検査の直後・外部コマンド使用前に評価されるため PATH を潰して到達できる。
RC=0
# bash 自身は絶対パスで起動する — PATH 経由だと bash の lookup が先に落ちて rc=127 になり、
# helper の degraded 経路を一度も実行しないまま assertion が判定されてしまう。
BASH_ABS=$(command -v bash)
PATH=/nonexistent "$BASH_ABS" "$SCRIPT" --pr 900 --commit-sha "bbbb222" --results-dir "$DIR_OK" --since "" \
  >/dev/null 2>"$ERR" || RC=$?
assert "T-06m: jq 不在は rc=0 (degraded)" "0" "$RC"
assert_grep "T-06n: jq 不在を名指しして degraded に倒す" "$ERR" 'jq が PATH 上にありません'

# state root を解決できない環境 (helper だけをコピーし state-path-resolve.sh を置かない)。
# --results-dir も --since も省略した本番形の呼び出しで degraded に倒れることを見る。
ISO="$SANDBOX/iso"; mkdir -p "$ISO/hooks/scripts"
cp "$SCRIPT" "$ISO/hooks/scripts/"
RC=0
bash "$ISO/hooks/scripts/review-save-json-verify.sh" --pr 900 --commit-sha "bbbb222" \
  >/dev/null 2>"$ERR" || RC=$?
assert "T-06o: state root を解決できない環境でも rc=0 (degraded)" "0" "$RC"
assert_grep "T-06p: state root 解決失敗を degraded として告知する" "$ERR" 'reason=save_result_json_undecidable'

# ---------------------------------------------------------------------------
# T-08': caller 契約違反 (未知オプション) は loud に落とす
#        skill 定義のバグであり、degraded で握り潰すと置換漏れと区別できなくなる。
# ---------------------------------------------------------------------------
echo "--- T-08': caller 契約違反 ---"

run_verify --pr 900 --commit-sha "bbbb222" --results-dir "$DIR_OK" --bogus x
assert "T-08'a: 未知オプションは rc=2" "2" "$RC"
assert_grep "T-08'b: 未知オプションを名指しする" "$ERR" "unknown argument '--bogus'"

# ---------------------------------------------------------------------------
# T-07: mutation check — positive 検査を「ファイルが 1 件でもあれば pass」へ退行させると
#       T-04 が落ちることを実測で固定する (AC-7)。静的 pin は「判定式がある」しか言えない。
# ---------------------------------------------------------------------------
echo "--- T-07: 判定軸を有無へ退行させる変異の検出 (AC-7) ---"

MUT="$SANDBOX/mutant.sh"
# `[ "$sha" = "$commit_sha" ]` を落として「読めた JSON があれば found」にする変異。
sed 's/if \[ -n "\$sha" \] && \[ "\$sha" = "\$commit_sha" \]; then/if [ -n "$sha" ]; then/' \
  "$SCRIPT" > "$MUT"
if ! cmp -s "$SCRIPT" "$MUT"; then
  pass "T-07a: 変異を適用できる (commit SHA 一致判定が想定の形で存在する)"
  RC=0
  bash "$MUT" --pr 902 --commit-sha "new999" --results-dir "$DIR_STALE" --since "" >/dev/null 2>"$ERR" || RC=$?
  if [ "$RC" -eq 0 ]; then
    pass "T-07b: 変異版は前 cycle の JSON で誤 pass する (= T-04 が本当に SHA 一致を見ている)"
  else
    fail "T-07b: 変異版でも fail した — T-04 が SHA 一致以外の理由で落ちている疑い (恒真 assertion)"
  fi
else
  fail "T-07a: 変異を適用できない — commit SHA 一致判定の形が drift した (T-04 が空虚になる)"
fi

# ---------------------------------------------------------------------------
# T-02': SKILL.md ステップ 8.0.4 との配線 (helper 単体 green でも呼ばれなければ無意味)
# ---------------------------------------------------------------------------
echo "--- T-02': ステップ 8.0.4 からの呼び出し配線 ---"

REVIEW_MD="$SCRIPT_DIR/../../skills/pr-review/SKILL.md"
if [ -f "$REVIEW_MD" ]; then
  _sec_804=$(awk '/^### 8\.0\.4 /{f=1} f&&/^### 8\.1 /{exit} f{print}' "$REVIEW_MD")
  # 散文の言及 (設計説明) と実際の呼び出しを区別する — `-cF` で数えると散文が増えるたび件数が
  # ずれ、呼び出しを消しても散文が残っていれば緑のままになる。行頭 anchor + `bash` 起動形で絞る。
  assert "T-02'a: 8.0.4 区間から helper が 1 回だけ**実行**される" "1" \
    "$(printf '%s\n' "$_sec_804" | grep -cE '^[[:space:]]*bash \{plugin_root\}/hooks/scripts/review-save-json-verify\.sh' || true)"
  # 引数が欠けると helper は degraded に倒れ、gate が恒久的に機械強制を失う (silent no-op 化)。
  assert "T-02'b: --pr と --commit-sha の両方を渡している" "1" \
    "$(printf '%s\n' "$_sec_804" | grep -cE 'review-save-json-verify\.sh --pr "\{pr_number\}" --commit-sha "\{current_commit_sha\}"' || true)"
  # 非ゼロを握り潰すと fail が pass に化ける — 本 gate の load-bearing な 1 語。
  assert "T-02'c: helper の非ゼロを exit 1 へ伝播している" "1" \
    "$(printf '%s\n' "$_sec_804" | grep -cF 'review-save-json-verify.sh --pr "{pr_number}" --commit-sha "{current_commit_sha}" || exit 1' || true)"
  # marker 残存の判定を通過した **後** に呼ぶ (順序が逆だと marker 残存 cycle の reason が
  # save_result_json_absent に丸められ「6.1.a が途中で落ちた」原因情報が失われる)。
  _line_marker=$(printf '%s\n' "$_sec_804" | grep -nF 'REVIEW_SAVE_GATE_FAILED=1; reason=save_pending_marker_present' | head -1 | cut -d: -f1)
  _line_helper=$(printf '%s\n' "$_sec_804" | grep -nE '^[[:space:]]*bash \{plugin_root\}/hooks/scripts/review-save-json-verify\.sh' | head -1 | cut -d: -f1)
  if [ -n "$_line_marker" ] && [ -n "$_line_helper" ] && [ "$_line_marker" -lt "$_line_helper" ]; then
    pass "T-02'd: marker 残存検査の後に positive 検査を呼ぶ (reason の粒度を保つ)"
  else
    fail "T-02'd: positive 検査が marker 残存検査より前にある (marker=$_line_marker helper=$_line_helper)"
  fi
  # 旧実装 (marker 不在で無条件 pass) へ戻す変異の検出。8.0.4 区間が pass を直接 emit していたら、
  # helper を呼ばずに通せる経路が復活している。
  assert "T-02'e: 8.0.4 区間は pass marker を直接 emit しない (helper 経由に一本化)" "0" \
    "$(printf '%s\n' "$_sec_804" | grep -cE '^[[:space:]]*echo "\[CONTEXT\] REVIEW_SAVE_GATE=pass' || true)"
  # reason 語彙の複製箇所 (SKILL.md の reasons 表 / Eval-order enumeration) への同時登録。
  # 片方だけに載せると、後から enumeration を根拠に「4 件のはず」と読んだ編集が新 reason を消す。
  for _r in save_result_json_absent save_result_json_undecidable; do
    assert "T-02'f: 新 reason $_r が reasons 表に登録されている" "1" \
      "$(grep -cE "^\| \`$_r\` \|" "$REVIEW_MD" || true)"
    assert "T-02'g: 新 reason $_r が Eval-order enumeration に登録されている" "1" \
      "$(grep -c "ステップ 8.0.4 (機械強制) emit = .*$_r" "$REVIEW_MD" || true)"
  done
  assert "T-02'h: Eval-order enumeration の 8.0.4 件数が 6 件に更新されている" "1" \
    "$(grep -c 'ステップ 8.0.4 (機械強制) emit = .*— 6 件' "$REVIEW_MD" || true)"
else
  fail "T-02': skills/pr-review/SKILL.md が見つからない ($REVIEW_MD)"
fi

if ! print_summary "$(basename "$0")" \
  "drift: hooks/scripts/review-save-json-verify.sh の判定 (commit SHA 一致 / run pin による現 run 切り出し / degraded の条件) か、skills/pr-review/SKILL.md ステップ 8.0.4 からの配線・reason 語彙が変更された可能性。helper の docstring と SKILL.md ステップ 8.0.4 を確認すること。"; then
  exit 1
fi
