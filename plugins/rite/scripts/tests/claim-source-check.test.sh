#!/bin/bash
# Tests for claim-source-check.sh (主張と出典の照合の機械検査)
#
# Coverage:
#   extract — 文書ファイルの追加行だけを行にする (コードの追加行・アンカーリンクの行・出典の無い行は除外) /
#             未追跡の文書も対象 / 出典トークン 4 種 (Issue・path:line・SHA・節) を完全一致で抽出 /
#             PR 本文の検証主張の行と出典の行を行にする / PR 本文の取得失敗と base 解決失敗で止まる /
#             非 ASCII・空白を含む名前、++ / --- で始まる追加行、diff の prefix 設定 / 引用符付きの名前で止まる
#   facts   — Issue を閉じた PR・参照元 PR・closer (PR / コミット) / PR の変更ファイル / 切り捨ての印 /
#             path:line の実在・行内容・範囲外・不在 / ローカルのコミットの変更ファイル / GitHub に無い SHA /
#             存在しない番号 / 節の本文の切り出しと文書名の無い節 / gh 失敗・リポジトリ単位の NOT_FOUND・
#             JSON 以外の応答を止めずに error として記録する
#   table   — 正常 (件数・観点別の件数・報告行) / 見出し欠落 / ヘッダ不正 / ID 欠落・余剰・重複 /
#             判定値不正 / 観点不正 / 支持で観点が欠ける / 主張なしの観点 / 根拠空 /
#             不支持で Verification: が無い / 判定不能で Measurement-Blocked: が無い
#
# 番号を含む入力は fixtures/claim-source/ に置く。本ファイルが書く番号は mock の応答ファイルを選ぶ
# 2 桁の値だけで、number-reference-check.sh の検出対象 (3-4 桁) に入らない。
#
# Usage: bash plugins/rite/scripts/tests/claim-source-check.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../claim-source-check.sh"
FIX="$SCRIPT_DIR/fixtures/claim-source"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

for tool in jq git python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required" >&2; exit 1; }
done

MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"
ln -s "$SCRIPT_DIR/mock-gh.sh" "$MOCK_BIN/gh"
export MOCK_CSC_DIR="$FIX"
# 利用者の git 設定 (diff.* など) から隔離する。設定を注入するケースは明示的に作る
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

new_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
  git -C "$1" config commit.gpgsign false
}

REPO="$TEST_DIR/repo"
mkdir -p "$REPO/src" "$REPO/docs" "$REPO/sub/.hidden"
new_repo "$REPO"
printf '# repo\n' > "$REPO/README.md"
cp "$FIX/logger.in" "$REPO/src/logger.js"
cp "$FIX/spec.in" "$REPO/docs/spec.md"
printf '# hidden\n' > "$REPO/sub/.hidden/x.md"
seq 1 30 > "$REPO/docs/long.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
git -C "$REPO" tag base
cp "$FIX/ledger.in" "$REPO/docs/ledger.md"
cp "$FIX/app.in" "$REPO/src/app.js"
git -C "$REPO" add -A
git -C "$REPO" commit -qm ledger
cp "$FIX/notes.in" "$REPO/docs/notes.md"

# helper を repo の中で実行する。stdout / stderr / rc を大域変数へ
run_helper() {
  local scenario="$1"; shift
  OUT=$(cd "${HELPER_REPO:-$REPO}" && MOCK_GH_SCENARIO="$scenario" PATH="$MOCK_BIN:$PATH" bash "$TARGET" "$@" 2>"$TEST_DIR/stderr")
  RC=$?
  ERR=$(cat "$TEST_DIR/stderr")
}

echo "=== extract ==="

run_helper csc_fixture extract --base base --out "$TEST_DIR/rows.json"
if [ "$RC" -eq 0 ] && grep -q '^\[CONTEXT\] CLAIM_SOURCE_ROWS=5; ids=CLAIM-1,CLAIM-2,CLAIM-3,CLAIM-4,CLAIM-5$' <<<"$OUT"; then
  pass "extract: 文書の追加行と未追跡の文書から 5 行"
else
  fail "extract: 行数 marker (rc=$RC out=$OUT err=$ERR)"
fi
if [ "$(jq -S '[.rows[] | {id, origin, refs}]' "$TEST_DIR/rows.json")" = "$(jq -S '.' "$FIX/expected-extract.json")" ]; then
  pass "extract: CLAIM-ID と出典トークンの組が完全一致 (コード・アンカーリンク・出典なしの行は除外)"
else
  fail "extract: 組の不一致: $(jq -c '[.rows[] | {id, origin, refs}]' "$TEST_DIR/rows.json")"
fi

run_helper csc_fixture extract --base base --out "$TEST_DIR/rows-pr.json" --pr 1 --repo o/r
body_rows=$(jq -c '[.rows[] | select(.source == "pr_body") | {origin, claim: (.verification_claim // false), kinds: [.refs[].kind]}]' "$TEST_DIR/rows-pr.json")
if [ "$RC" -eq 0 ] && [ "$body_rows" = '[{"origin":"PR本文:3","claim":true,"kinds":[]},{"origin":"PR本文:4","claim":false,"kinds":["issue"]}]' ]; then
  pass "extract: PR 本文の検証主張の行と出典の行を CLAIM-6/7 として追加"
else
  fail "extract: PR 本文の行 (rc=$RC rows=$body_rows err=$ERR)"
fi
if [ "$(jq -r '.rows[-1].id' "$TEST_DIR/rows-pr.json")" = "CLAIM-7" ]; then
  pass "extract: PR 本文の行は文書の行の後に連番"
else
  fail "extract: PR 本文の行の ID"
fi

run_helper csc_fail extract --base base --out "$TEST_DIR/x.json" --pr 1 --repo o/r
if [ "$RC" -eq 1 ] && grep -q 'reason=pr_body_fetch_failed' <<<"$OUT"; then
  pass "extract: PR 本文の取得失敗で止まる"
else
  fail "extract: PR 本文の取得失敗 (rc=$RC out=$OUT)"
fi

run_helper csc_fixture extract --base no-such-ref --out "$TEST_DIR/x.json"
if [ "$RC" -eq 1 ] && grep -q 'reason=base_unresolved' <<<"$OUT"; then
  pass "extract: base を解決できなければ止まる"
else
  fail "extract: base 解決失敗 (rc=$RC out=$OUT)"
fi

run_helper csc_fixture extract --base base
if [ "$RC" -eq 2 ]; then pass "extract: --out 欠落は invocation error"; else fail "extract: --out 欠落 rc=$RC"; fi

# 非 ASCII のファイル名 (git 既定では引用符付きパスになる) と、利用者の diff の prefix 設定
JA_REPO="$TEST_DIR/repo-ja"
new_repo "$JA_REPO"
printf '# repo\n' > "$JA_REPO/README.md"
git -C "$JA_REPO" add -A
git -C "$JA_REPO" commit -qm base
git -C "$JA_REPO" tag base
mkdir -p "$JA_REPO/docs"
cp "$FIX/ledger.in" "$JA_REPO/docs/継続先台帳.md"
git -C "$JA_REPO" add -A
git -C "$JA_REPO" commit -qm ledger
cp "$FIX/notes.in" "$JA_REPO/docs/メモ.md"
expected_ja='["docs/継続先台帳.md:5","docs/継続先台帳.md:6","docs/継続先台帳.md:7","docs/継続先台帳.md:8","docs/メモ.md:3"]'
HELPER_REPO="$JA_REPO" run_helper csc_fixture extract --base base --out "$TEST_DIR/rows-ja.json"
if [ "$RC" -eq 0 ] && [ "$(jq -c '[.rows[].origin]' "$TEST_DIR/rows-ja.json")" = "$expected_ja" ]; then
  pass "extract: 非 ASCII のファイル名の文書も commit 済み・未追跡の両方から抜き出す"
else
  fail "extract: 非 ASCII のファイル名 (rc=$RC out=$OUT err=$ERR)"
fi
for prefix_config in diff.mnemonicPrefix diff.noprefix; do
  OUT=$(cd "$JA_REPO" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="$prefix_config" GIT_CONFIG_VALUE_0=true \
    bash "$TARGET" extract --base base --out "$TEST_DIR/rows-prefix.json" 2>"$TEST_DIR/stderr")
  RC=$?
  if [ "$RC" -eq 0 ] && [ "$(jq -c '[.rows[].origin]' "$TEST_DIR/rows-prefix.json")" = "$expected_ja" ]; then
    pass "extract: $prefix_config=true でも同じ行を抜き出す"
  else
    fail "extract: $prefix_config (rc=$RC out=$OUT err=$(cat "$TEST_DIR/stderr"))"
  fi
done

# git の出力の形に依存する箇所: 空白を含む名前 (+++ 行の末尾にタブが付く) と、本文が ++ / --- で始まる追加行
SP_REPO="$TEST_DIR/repo-space"
new_repo "$SP_REPO"
printf '# repo\n' > "$SP_REPO/README.md"
git -C "$SP_REPO" add -A
git -C "$SP_REPO" commit -qm base
git -C "$SP_REPO" tag base
mkdir -p "$SP_REPO/docs"
printf '# 例\n+++ b/x は #12 の例\n--- a/y も #13\n++ fixed in #14\nsee #15 here\n' > "$SP_REPO/docs/my notes.md"
git -C "$SP_REPO" add -A
git -C "$SP_REPO" commit -qm notes
printf 'x #16\n' > "$SP_REPO/docs/new note.md"
expected_sp='["docs/my notes.md:2","docs/my notes.md:3","docs/my notes.md:4","docs/my notes.md:5","docs/new note.md:1"]'
HELPER_REPO="$SP_REPO" run_helper csc_fixture extract --base base --out "$TEST_DIR/rows-sp.json"
if [ "$RC" -eq 0 ] && [ "$(jq -c '[.rows[].origin]' "$TEST_DIR/rows-sp.json")" = "$expected_sp" ]; then
  pass "extract: 空白を含む名前と、++ / --- で始まる追加行も正しい行番号で抜き出す"
else
  fail "extract: 空白・++ 行 (rc=$RC out=$OUT err=$ERR rows=$(jq -c '[.rows[].origin]' "$TEST_DIR/rows-sp.json" 2>/dev/null))"
fi

# quotePath=false でも git が引用符で囲む名前 (") は、黙って捨てずに止まる
QT_REPO="$TEST_DIR/repo-quote"
new_repo "$QT_REPO"
printf '# repo\n' > "$QT_REPO/README.md"
git -C "$QT_REPO" add -A
git -C "$QT_REPO" commit -qm base
git -C "$QT_REPO" tag base
printf 'see #12\n' > "$QT_REPO/a\"b.md"
git -C "$QT_REPO" add -A
git -C "$QT_REPO" commit -qm quoted
HELPER_REPO="$QT_REPO" run_helper csc_fixture extract --base base --out "$TEST_DIR/rows-qt.json"
if [ "$RC" -eq 1 ] && grep -q 'reason=diff_header_unexpected' <<<"$OUT"; then
  pass "extract: 引用符付きになる名前の文書は diff_header_unexpected で止まる"
else
  fail "extract: 引用符付きの名前 (rc=$RC out=$OUT err=$ERR)"
fi

echo "=== facts ==="

run_helper csc_fixture facts --rows "$TEST_DIR/rows.json" --repo o/r --out "$TEST_DIR/facts.json"
F="$TEST_DIR/facts.json"
if [ "$RC" -eq 0 ] && grep -q '^\[CONTEXT\] CLAIM_SOURCE_FACTS=ok; refs=3; errors=0$' <<<"$OUT"; then
  pass "facts: 出典 3 件 (Issue・path:line・SHA) を error なしで収集"
else
  fail "facts: marker (rc=$RC out=$OUT err=$ERR)"
fi
issue_fact=$(jq -c '.refs | to_entries[] | select(.key | startswith("issue:")) | .value | {type, state, closing: [.closing_prs[] | .files], truncated: [.closing_prs[] | .files_truncated], closing_prs_truncated, timeline_truncated, closer: .closer.number}' "$F")
if [ "$issue_fact" = '{"type":"issue","state":"CLOSED","closing":[["src/other.js"]],"truncated":[true],"closing_prs_truncated":true,"timeline_truncated":true,"closer":15}' ]; then
  pass "facts: Issue を閉じた PR の変更ファイル一覧 (主張の src/logger.js を含まない)・切り捨ての印 (変更ファイル・閉じた PR・タイムライン)・closer を記録"
else
  fail "facts: Issue の事実 $issue_fact"
fi
line_fact=$(jq -c '.refs["file_line:src/logger.js:3"].candidates[0] | {path, in_range, lines}' "$F")
if [ "$line_fact" = '{"path":"src/logger.js","in_range":true,"lines":["  console.log(message);"]}' ]; then
  pass "facts: path:line の HEAD 上の行内容"
else
  fail "facts: path:line $line_fact"
fi
sha_fact=$(jq -c '.refs | to_entries[] | select(.key | startswith("sha:")) | .value.exists' "$F")
if [ "$sha_fact" = "false" ]; then
  pass "facts: ローカルにも GitHub にも無い SHA は exists=false"
else
  fail "facts: 存在しない SHA $sha_fact"
fi
section_fact=$(jq -c '.sections["CLAIM-2"][0] | {doc, found, first: .body[0], has_next: (.body | any(. == "## 監視"))}' "$F")
if [ "$section_fact" = '{"doc":"docs/spec.md","found":true,"first":"## 再試行","has_next":false}' ]; then
  pass "facts: 行が名指す文書の節の本文を次の見出しの手前まで切り出す"
else
  fail "facts: 節 $section_fact"
fi
if [ "$(jq -c '.sections["CLAIM-4"]' "$F")" = '[{"section":"§4.2","doc":null}]' ]; then
  pass "facts: 文書名の無い節は doc=null (検証 agent が解決する)"
else
  fail "facts: 文書名の無い節 $(jq -c '.sections["CLAIM-4"]' "$F")"
fi

head_sha=$(git -C "$REPO" rev-parse --short=12 HEAD)
jq -n --arg sha "$head_sha" '{rows: [
  {id: "CLAIM-1", origin: "x.md:1", text: "t", refs: [{kind: "file_line", token: "src/logger.js:99"}]},
  {id: "CLAIM-2", origin: "x.md:2", text: "t", refs: [{kind: "file_line", token: "src/missing.js:1"}]},
  {id: "CLAIM-3", origin: "x.md:3", text: "t", refs: [{kind: "sha", token: $sha}]},
  {id: "CLAIM-4", origin: "x.md:4", text: "t", refs: [{kind: "issue", token: "#15"}]},
  {id: "CLAIM-5", origin: "x.md:5", text: "t", refs: [{kind: "issue", token: "#13"}]},
  {id: "CLAIM-6", origin: "x.md:6", text: "t", refs: [{kind: "issue", token: "#99"}]},
  {id: "CLAIM-7", origin: "x.md:7", text: "t", refs: [{kind: "file_line", token: ".hidden/x.md:1"}]},
  {id: "CLAIM-8", origin: "x.md:8", text: "t", refs: [{kind: "file_line", token: "docs/long.txt:1-25"}]},
  {id: "CLAIM-9", origin: "x.md:9", text: "t", refs: [{kind: "issue", token: "#14"}]}
]}' > "$TEST_DIR/rows-edge.json"
run_helper csc_fixture facts --rows "$TEST_DIR/rows-edge.json" --repo o/r --out "$TEST_DIR/facts-edge.json"
E="$TEST_DIR/facts-edge.json"
if [ "$RC" -eq 0 ] && grep -q 'refs=9; errors=0$' <<<"$OUT"; then
  pass "facts: 存在しない番号 (GraphQL NOT_FOUND・exit 1) を error に数えない"
else
  fail "facts: edge marker (rc=$RC out=$OUT err=$ERR)"
fi
if [ "$(jq -c '.refs["issue:#99"]' "$E")" = '{"exists":false,"repo":"o/r","number":99}' ]; then
  pass "facts: 存在しない Issue/PR 番号は exists=false"
else
  fail "facts: 存在しない番号 $(jq -c '.refs["issue:#99"]' "$E")"
fi
if [ "$(jq -c '.refs["issue:#13"] | {closing: .closing_prs, referencing: [.referencing_prs[] | {number, base, files}]}' "$E")" = '{"closing":[],"referencing":[{"number":16,"base":"develop","files":["src/logger.js"]}]}' ]; then
  pass "facts: 既定ブランチ以外へ入った PR は timeline の参照元として変更ファイルを記録 (Issue からの参照は除く)"
else
  fail "facts: 参照元 PR $(jq -c '.refs["issue:#13"]' "$E")"
fi
if [ "$(jq -c '.refs["issue:#14"] | {closing: .closing_prs, referencing: .referencing_prs, closer}' "$E")" = '{"closing":[],"referencing":[],"closer":{"type":"commit","sha":"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c"}}' ]; then
  pass "facts: コミットが閉じた Issue は closer にコミットを記録"
else
  fail "facts: コミットの closer $(jq -c '.refs["issue:#14"]' "$E")"
fi

jq -n '{rows: [
  {id: "CLAIM-1", origin: "x.md:1", text: "t", refs: [{kind: "issue", token: "x/y#98"}]},
  {id: "CLAIM-2", origin: "x.md:2", text: "t", refs: [{kind: "issue", token: "#97"}]}
]}' > "$TEST_DIR/rows-err.json"
run_helper csc_fixture facts --rows "$TEST_DIR/rows-err.json" --repo o/r --out "$TEST_DIR/facts-err.json"
if [ "$RC" -eq 0 ] && grep -q 'refs=2; errors=2$' <<<"$OUT" \
    && [ "$(jq -c '[.refs["issue:x/y#98"], .refs["issue:#97"]] | map(has("error") and (has("exists") | not))' "$TEST_DIR/facts-err.json")" = '[true,true]' ]; then
  pass "facts: リポジトリ単位の NOT_FOUND と JSON 以外の応答は不在と断定せず error に残す"
else
  fail "facts: リポジトリ単位の NOT_FOUND・JSON 以外 (rc=$RC out=$OUT facts=$(jq -c '.refs' "$TEST_DIR/facts-err.json" 2>/dev/null))"
fi
if [ "$(jq -c '.refs["file_line:.hidden/x.md:1"].candidates[0] | {path, lines}' "$E")" = '{"path":"sub/.hidden/x.md","lines":["# hidden"]}' ]; then
  pass "facts: ドットで始まるディレクトリの部分パスを解決する"
else
  fail "facts: ドット始まりの部分パス $(jq -c '.refs["file_line:.hidden/x.md:1"]' "$E")"
fi
if [ "$(jq -c '.refs["file_line:docs/long.txt:1-25"].candidates[0] | {n: (.lines | length), lines_truncated}' "$E")" = '{"n":20,"lines_truncated":true}' ]; then
  pass "facts: 行の上限で切った内容に切り捨ての印を付ける"
else
  fail "facts: 行の切り捨て $(jq -c '.refs["file_line:docs/long.txt:1-25"]' "$E")"
fi
if [ "$(jq -c '.refs["file_line:src/logger.js:99"].candidates[0].in_range' "$E")" = "false" ]; then
  pass "facts: 行番号が範囲外なら in_range=false"
else
  fail "facts: 範囲外"
fi
if [ "$(jq -c '.refs["file_line:src/missing.js:1"].exists' "$E")" = "false" ]; then
  pass "facts: HEAD に無いファイルは exists=false"
else
  fail "facts: 不在ファイル"
fi
if [ "$(jq -c --arg k "sha:$head_sha" '.refs[$k] | {where, files}' "$E")" = '{"where":"local","files":["docs/ledger.md","src/app.js"]}' ]; then
  pass "facts: ローカルのコミットの変更ファイル"
else
  fail "facts: ローカルのコミット $(jq -c --arg k "sha:$head_sha" '.refs[$k]' "$E")"
fi
if [ "$(jq -c '.refs["issue:#15"] | {type, files, files_truncated, files_total}' "$E")" = '{"type":"pull_request","files":["src/other.js"],"files_truncated":true,"files_total":101}' ]; then
  pass "facts: PR 参照は PR の変更ファイル (上限で切れた一覧には印と総数)"
else
  fail "facts: PR 参照"
fi

run_helper csc_fail facts --rows "$TEST_DIR/rows.json" --repo o/r --out "$TEST_DIR/facts-fail.json"
issue_error=$(jq -r '.refs | to_entries[] | select(.key | startswith("issue:")) | .value.error' "$TEST_DIR/facts-fail.json")
if [ "$RC" -eq 0 ] && grep -q 'errors=2' <<<"$OUT" && [ -n "$issue_error" ] && [ "$issue_error" != "null" ] \
    && grep -q '^WARNING: claim-source facts: issue:' <<<"$ERR"; then
  pass "facts: gh 失敗は止めずに出典ごとの error と WARNING に残す"
else
  fail "facts: gh 失敗 (rc=$RC out=$OUT err=$ERR)"
fi

echo "=== table ==="

table_input() {
  { printf '### 評価\n\n### 主張と出典の照合\n'; cat; printf '\n### 所見\nなし\n'; } > "$TEST_DIR/table.md"
}
HEADER=$'| ID | 判定 | 観点 | 根拠 |\n|----|------|------|------|'
OK_ROWS=$'| CLAIM-1 | 不支持 | 実在・内容・含意 | Verification: repro gh pr view <closing> --json files => src/logger.js を含まない |\n| CLAIM-2 | 支持 | 実在・内容・含意 | docs/spec.md の再試行の節に回数がある |\n| CLAIM-3 | 判定不能 | 実在 | Measurement-Blocked: gh api repos/o/r/commits/<sha> => HTTP 503 |\n| CLAIM-4 | 支持 | 実在/内容/含意 | 仕様の節に閾値がある |\n| CLAIM-5 | 主張なし | - | 未追跡のメモの例文で、PR の主張ではない |'

printf '%s\n%s\n' "$HEADER" "$OK_ROWS" | table_input
run_helper csc_fixture table --rows "$TEST_DIR/rows.json" --input "$TEST_DIR/table.md"
if [ "$RC" -eq 0 ] && grep -q '^\[CONTEXT\] CLAIM_SOURCE_TABLE=ok; total=5; judged=4; supported=2; unsupported=1; undetermined=1; no_claim=1; existence=4; content=3; implication=3$' <<<"$OUT"; then
  pass "table: 件数 (N 件中 M 件) と観点別の件数"
else
  fail "table: marker (rc=$RC out=$OUT)"
fi
reported=$(sed -n 's/^CLAIM_SOURCE_ROWS_JSON=//p' <<<"$OUT" | jq -c '[.[] | {id, verdict, origin}]')
if [ "$reported" = '[{"id":"CLAIM-1","verdict":"不支持","origin":"docs/ledger.md:5"},{"id":"CLAIM-3","verdict":"判定不能","origin":"docs/ledger.md:7"}]' ]; then
  pass "table: 不支持と判定不能の行だけを出所つきで返す"
else
  fail "table: 報告行 $reported"
fi

# 表の 1 行を差し替えて失敗理由を確かめる
expect_reason() {
  local name="$1" reason="$2" rows="$3"
  printf '%s\n%s\n' "$HEADER" "$rows" | table_input
  run_helper csc_fixture table --rows "$TEST_DIR/rows.json" --input "$TEST_DIR/table.md"
  if [ "$RC" -eq 1 ] && grep -q "reason=$reason" <<<"$OUT"; then
    pass "table: $name → $reason"
  else
    fail "table: $name (rc=$RC out=$OUT)"
  fi
}
drop_row() { grep -v "^| $1 |" <<<"$OK_ROWS"; }
swap_row() { sed "s/^| $1 |.*$/$2/" <<<"$OK_ROWS"; }

EQ_ROWS=$(swap_row CLAIM-1 "| CLAIM-1 | 不支持 | 実在・内容・含意 | Verification: repro gh api graphql -f query=@q.graphql -F n=15 => files に src\/logger.js が無い |" \
  | sed "s/^| CLAIM-3 |.*$/| CLAIM-3 | 判定不能 | 実在 | Measurement-Blocked: gh api graphql -F n=12 --jq '.a == 1' => HTTP 503 |/")
printf '%s\n%s\n' "$HEADER" "$EQ_ROWS" | table_input
run_helper csc_fixture table --rows "$TEST_DIR/rows.json" --input "$TEST_DIR/table.md"
if [ "$RC" -eq 0 ] && grep -q 'unsupported=1; undetermined=1' <<<"$OUT"; then
  pass "table: コマンドに = を含む根拠 (-f query= / --jq の ==) を受理する"
else
  fail "table: = を含む根拠 (rc=$RC out=$OUT)"
fi

expect_reason "ID 欠落" id_set_mismatch "$(drop_row CLAIM-5)"
expect_reason "ID 余剰" id_set_mismatch "$OK_ROWS"$'\n| CLAIM-9 | 支持 | 実在・内容・含意 | x |'
expect_reason "ID 重複" id_set_mismatch "$OK_ROWS"$'\n| CLAIM-2 | 支持 | 実在・内容・含意 | x |'
expect_reason "判定値不正" verdict_invalid "$(swap_row CLAIM-2 '| CLAIM-2 | 一致 | 実在・内容・含意 | x |')"
expect_reason "観点が列挙外" perspective_invalid "$(swap_row CLAIM-2 '| CLAIM-2 | 支持 | 実在・形式・含意 | x |')"
expect_reason "支持で含意を見ていない" perspective_invalid "$(swap_row CLAIM-2 '| CLAIM-2 | 支持 | 実在・内容 | x |')"
expect_reason "主張なしに観点" perspective_invalid "$(swap_row CLAIM-5 '| CLAIM-5 | 主張なし | 実在 | x |')"
expect_reason "根拠空" evidence_missing "$(swap_row CLAIM-2 '| CLAIM-2 | 支持 | 実在・内容・含意 |  |')"
expect_reason "不支持に実測アンカーなし" anchor_missing "$(swap_row CLAIM-1 '| CLAIM-1 | 不支持 | 含意 | 閉じた PR は別のファイルを変えた |')"
expect_reason "判定不能に実測阻害アンカーなし" anchor_missing "$(swap_row CLAIM-3 '| CLAIM-3 | 判定不能 | 実在 | 取得できなかった |')"

{ printf '### 所見\nなし\n'; } > "$TEST_DIR/table.md"
run_helper csc_fixture table --rows "$TEST_DIR/rows.json" --input "$TEST_DIR/table.md"
if [ "$RC" -eq 1 ] && grep -q 'reason=table_missing' <<<"$OUT"; then pass "table: 見出し欠落 → table_missing"; else fail "table: 見出し欠落 (rc=$RC)"; fi

printf '| ID | 判定 | 根拠 |\n|----|------|------|\n| CLAIM-1 | 支持 | x |\n' | table_input
run_helper csc_fixture table --rows "$TEST_DIR/rows.json" --input "$TEST_DIR/table.md"
if [ "$RC" -eq 1 ] && grep -q 'reason=table_malformed' <<<"$OUT"; then pass "table: ヘッダ不正 → table_malformed"; else fail "table: ヘッダ不正 (rc=$RC)"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
