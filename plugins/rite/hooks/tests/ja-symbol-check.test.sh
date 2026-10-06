#!/bin/bash
# ja-symbol-check.test.sh
#
# 日本語の記号の作成前検査（ja-symbol-check.sh）を pin する。
#   T-01 日本語行の半角括弧を検出する（出力は行番号:種別:該当行の完全一致）
#   T-02 ラベル直後の半角コロンを検出する
#   T-03 句点で区切ったラベルを検出する
#   T-04 コード・URL・英字行・固定行は検出しない。同一行の混在は本文側だけ検出する
#   T-05 作成前検査の文書側配線を段落ごとに pin する
#   T-06 --language の判定（en は検査しない、auto は検査する、不正値は exit 2）
#   T-07 入力不正は exit 2
# run-tests.sh は *.test.sh の glob で本ファイルを自動検出する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$SCRIPT_DIR/../scripts/ja-symbol-check.sh"
STRUCTURE="$PLUGIN_ROOT/templates/issue/template-structure.md"
ISSUE_CREATE="$PLUGIN_ROOT/skills/issue-create/SKILL.md"
PR_CREATE="$PLUGIN_ROOT/skills/pr-create/SKILL.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
expect_eq() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected=[$2] actual=[$3])"; fi
}

for f in "$CHECK" "$STRUCTURE" "$ISSUE_CREATE" "$PR_CREATE"; do
  [ -f "$f" ] || { echo "ERROR: missing target: $f" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ja-symbol-check-test-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# run_check <name> <language> <body>: 本文をファイルに書いて検査し、stdout と rc を返す
OUT=""; RC=0
run_check() {
  printf '%s' "$3" > "$TMP/$1.md"
  RC=0
  OUT=$(bash "$CHECK" --body-file "$TMP/$1.md" --language "$2" 2>/dev/null) || RC=$?
}

echo "=== ja-symbol-check tests ==="

# T-01
run_check t01 ja $'## 要約\n\n変更内容(詳細)を直す\n'
expect_eq "T-01 半角括弧: 出力は行番号:種別:該当行" "3:半角記号:変更内容(詳細)を直す" "$OUT"
expect_eq "T-01 半角括弧: exit 1" "1" "$RC"
run_check t01b ja $'本文はここ\n矯正済みの（詳細）\n/ 区切り(a)と説明/補足(b)\n'
expect_eq "T-01 違反行が複数なら全行を出力する" "3:半角記号:/ 区切り(a)と説明/補足(b)" "$OUT"
run_check t01c ja $'一行目(a)\n二行目(b)\n'
expect_eq "T-01 2 行とも出力される" $'1:半角記号:一行目(a)\n2:半角記号:二行目(b)' "$OUT"

# T-02
run_check t02 ja $'前置き\n- **用語**: 説明\n'
expect_eq "T-02 ラベルの半角コロン" "2:ラベルの半角コロン:- **用語**: 説明" "$OUT"
expect_eq "T-02 exit 1" "1" "$RC"
run_check t02b ja $'- **用語**：説明\n- 手順：実行\n'
expect_eq "T-02 全角コロンは通る" "0" "$RC"

# T-03
run_check t03 ja $'前置き\n- **用語**。説明\n'
expect_eq "T-03 ラベルの句点区切り" "2:ラベルの句点区切り:- **用語**。説明" "$OUT"
expect_eq "T-03 exit 1" "1" "$RC"

# T-04
run_check t04a ja $'```\na(b)\nhttps://example.com/a:b\n```\n**Type**: feat\n'
expect_eq "T-04 コード・URL・英字ラベルは出力なし" "" "$OUT"
expect_eq "T-04 exit 0" "0" "$RC"
run_check t04b ja $'**用語**:\n- [ ] 手順を確認する\n[手順書](plugins/rite/a.md)を読む\n<!-- 図なし: 文言・数値のみの修正 -->\n| 列 | 列 |\n|---|---|\n`a(b)` を使う。パスは plugins/rite/x.md と ~/.claude/y\n'
expect_eq "T-04 固定行・チェックボックス・リンク・コメント・表・パスは出力なし" "" "$OUT"
expect_eq "T-04 固定行の exit 0" "0" "$RC"
run_check t04c ja $'`a(b)` と説明(補足)\n'
expect_eq "T-04 コードスパンと本文の混在は本文側 1 件だけ" "1:半角記号:\`a(b)\` と説明(補足)" "$OUT"
run_check t04d ja $'前置き\n<details>\n<summary>契約</summary>\n\n- **Given**: 日本語(a)\n- 2026-01-01 D-01: 決定 / Reason: 理由\n</details>\n'
expect_eq "T-04 契約層（details 以降）の固定行は検査しない" "0" "$RC"
run_check t04e ja $'English only (text)\n'
expect_eq "T-04 日本語を含まない行は検査しない" "0" "$RC"

# T-05: 文書側の配線（段落ごとに 1 回）
section=$(awk '/^### 記号の作成前検査/{f=1;next} /^### /{f=0} f' "$STRUCTURE")
expect_eq "T-05 記号検査の節に helper 呼び出しが 1 回" "1" "$(printf '%s\n' "$section" | grep -c 'ja-symbol-check.sh')"
expect_eq "T-05 記号検査の節に作成 helper を呼ばず再生成する指示が 1 回" "1" "$(printf '%s\n' "$section" | grep -c '呼ばず')"
line_diagram=$(grep -n '^### 図の選択規則' "$STRUCTURE" | head -1 | cut -d: -f1)
line_symbol=$(grep -n '^### 記号の作成前検査' "$STRUCTURE" | head -1 | cut -d: -f1)
line_fold=$(grep -n '^### 契約層の折りたたみ' "$STRUCTURE" | head -1 | cut -d: -f1)
if [ -n "$line_diagram" ] && [ -n "$line_symbol" ] && [ -n "$line_fold" ] \
   && [ "$line_diagram" -lt "$line_symbol" ] && [ "$line_symbol" -lt "$line_fold" ]; then
  pass "T-05 記号検査の節は図の選択規則の後・契約層の折りたたみの前にある"
else
  fail "T-05 記号検査の節の位置 (diagram=$line_diagram symbol=$line_symbol fold=$line_fold)"
fi
expect_eq "T-05 記号検査の bash は図検査と別の block（先頭が body_file 代入ではない）" "0" \
  "$(printf '%s\n' "$section" | awk '/^```bash/{getline; print}' | grep -c '^body_file=')"
expect_eq "T-05 issue-create の記号検査参照が単一・分解の両経路に 2 回" "2" \
  "$(grep -c 'ja-symbol-check.sh\|記号の作成前検査' "$ISSUE_CREATE")"
expect_eq "T-05 pr-create の記号検査参照が 1 回" "1" \
  "$(grep -c 'ja-symbol-check.sh\|記号の作成前検査' "$PR_CREATE")"

# T-06
run_check t06a en $'変更内容(詳細)\n'
expect_eq "T-06 en は検査せず exit 0" "0" "$RC"
run_check t06b auto $'変更内容(詳細)\n'
expect_eq "T-06 auto は日本語行を検査する" "1" "$RC"
printf '変更内容(詳細)\n' > "$TMP/t06c.md"
rc=0; bash "$CHECK" --body-file "$TMP/t06c.md" --language fr >/dev/null 2>&1 || rc=$?
expect_eq "T-06 不正な language は exit 2" "2" "$rc"
rc=0; bash "$CHECK" --body-file "$TMP/t06c.md" >/dev/null 2>&1 || rc=$?
expect_eq "T-06 language 欠落は exit 2" "2" "$rc"
rc=0; LC_ALL=C bash "$CHECK" --body-file "$TMP/t06c.md" --language ja >/dev/null 2>&1 || rc=$?
expect_eq "T-06 LC_ALL=C でも日本語行を検出する" "1" "$rc"

# T-07
rc=0; bash "$CHECK" --body-file "$TMP/none.md" --language ja >/dev/null 2>&1 || rc=$?
expect_eq "T-07 ファイル不在は exit 2" "2" "$rc"
: > "$TMP/empty.md"
rc=0; bash "$CHECK" --body-file "$TMP/empty.md" --language ja >/dev/null 2>&1 || rc=$?
expect_eq "T-07 空ファイルは exit 2" "2" "$rc"
rc=0; (cd "$TMP" && bash "$CHECK" --body-file t06c.md --language ja >/dev/null 2>&1) || rc=$?
expect_eq "T-07 相対パスは exit 2" "2" "$rc"
rc=0; bash "$CHECK" --language ja >/dev/null 2>&1 || rc=$?
expect_eq "T-07 body-file 欠落は exit 2" "2" "$rc"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
