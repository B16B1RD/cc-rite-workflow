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
# 記号ごとに、その記号だけを含む単独の入力で固定する（規則を外すと落ちる）
for sym_line in '手順書/参考資料を読む' '10~20 件を直す' '省略する...のです' '手順[3]を読む' '"既存の行" は変えない'; do
  run_check t01s ja "$sym_line"$'\n'
  expect_eq "T-01 単独の半角記号を検出する: $sym_line" "1:半角記号:$sym_line" "$OUT"
done
for ok_line in '2026/01/01 に実施する' 'plugins/rite/a.md を読む'; do
  run_check t01n ja "$ok_line"$'\n'
  expect_eq "T-01 日付とパスのスラッシュは通る: $ok_line" "0" "$RC"
done

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
# 日本語を含み、除外が無ければ検出される行で、除外ごとに固定する
for case_body in \
  $'```\n日本語(a)\n```\n' \
  $'詳細はhttps://example.com/a(b)です\n' \
  $'説明<a title="詳細">リンク</a>\n' \
  $'`a...b` を使う\n' \
  $'説明です <!-- 図なし(b) -->\n' \
  $'~~~\n日本語(a)\n~~~\n' \
  $'<!--\n図なし(a)\n-->\n' \
  $'---\ntitle: 日本語(a)\n---\n本文\n' \
  $'Co-Authored-By: 日本語(a) <a@b.c>\n'; do
  run_check t04x ja "$case_body"
  expect_eq "T-04 除外が効く: $(printf '%s' "$case_body" | head -n 2 | tr '\n' ' ')" "0" "$RC"
done
# 除外の内側の details やフェンス種別の混在で、以降の違反を見逃さない
run_check t04f ja $'本文\n```html\n<details>\n```\n違反(a)です\n'
expect_eq "T-04 フェンス内の details で走査が終わらない" "5:半角記号:違反(a)です" "$OUT"
run_check t04g ja $'本文\n```\n~~~\n```\n違反(a)です\n'
expect_eq "T-04 バッククォートのフェンスの中のチルダはフェンスを閉じない" "5:半角記号:違反(a)です" "$OUT"
run_check t04h ja $'<!--\n<details>\n-->\n違反(a)です\n'
expect_eq "T-04 コメント内の details で走査が終わらない" "4:半角記号:違反(a)です" "$OUT"
run_check t04i ja $'本文です\n```a``` と書く行\n```b``` とも書く行\n違反(a)です\n'
expect_eq "T-04 行頭のインラインコードはフェンスの開始にならない" "4:半角記号:違反(a)です" "$OUT"
run_check t04j ja $'本文\n````\n```\n日本語(a)\n````\n違反(b)です\n'
expect_eq "T-04 4 連のフェンスは内側の 3 連では閉じない" "6:半角記号:違反(b)です" "$OUT"
run_check t04k ja $'本文\n```\n```x\n日本語(a)\n```\n違反(b)です\n'
expect_eq "T-04 info string 付きの行ではフェンスが閉じない" "6:半角記号:違反(b)です" "$OUT"
run_check t04l ja $'<!-- 図なし: 文言のみ -->\n違反(a)です\n'
expect_eq "T-04 行頭の単行コメントの後ろの行を見逃さない" "2:半角記号:違反(a)です" "$OUT"

# T-05: 文書側の配線（段落ごとに 1 回）
section=$(awk '/^### 記号の作成前検査/{f=1;next} /^### /{f=0} f' "$STRUCTURE")
expect_eq "T-05 記号検査の節に helper 呼び出しが 1 回" "1" "$(printf '%s\n' "$section" | grep -c 'ja-symbol-check.sh')"
expect_eq "T-05 記号検査の節に作成 helper を呼ばず再生成する指示が 1 回" "1" "$(printf '%s\n' "$section" | grep -c '呼ばず')"
line_diagram=$(grep -n '^### 図の選択規則' "$STRUCTURE" | head -1 | cut -d: -f1 || true)
line_symbol=$(grep -n '^### 記号の作成前検査' "$STRUCTURE" | head -1 | cut -d: -f1 || true)
line_fold=$(grep -n '^### 契約層の折りたたみ' "$STRUCTURE" | head -1 | cut -d: -f1 || true)
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
expect_eq "T-05 節に WARNING で続行しない旨が 1 回" "1" "$(printf '%s\n' "$section" | grep -c 'WARNING で続行しない')"
# 経路ごとに、違反時は作成を呼ばず再生成する文があり、記号検査が読みやすさ点検より前にある
for site in "$ISSUE_CREATE" "$PR_CREATE"; do
  while IFS= read -r site_line; do
    # 記号検査を最初に述べる文（最初の句点まで）に限って照合する。同じ行の図検査の文に一致させない
    after_symbol=${site_line#*記号の作成前検査}
    symbol_sentence=${after_symbol%%。*}
    case "$symbol_sentence" in
      *呼ばず*再生成*) pass "T-05 記号検査の文に作成を呼ばず再生成する旨がある: ${site##*/}" ;;
      *) fail "T-05 記号検査の文に作成を呼ばず再生成する旨が無い: ${site##*/}: ${symbol_sentence:0:60}" ;;
    esac
    before_symbol=${site_line%%記号の作成前検査*}
    case "$before_symbol" in
      *読みやすさ点検*) fail "T-05 記号検査が読みやすさ点検より前に無い: ${site##*/}" ;;
      *) pass "T-05 記号検査が読みやすさ点検より前にある: ${site##*/}" ;;
    esac
  done < <(grep '記号の作成前検査' "$site")
done
# 節の bash ブロックを実際に実行する: 違反で非ゼロ、適合で 0、入力不正は再生成ではなく入力の修正を案内する
sym_script=$(printf '%s\n' "$section" | awk '/^```bash/{f=1;next} /^```/{f=0} f')
run_section() { # body_file language -> stdout+stderr と rc を SECTION_OUT / SECTION_RC に返す
  local s="${sym_script//\{plugin_root\}/$PLUGIN_ROOT}"
  s="${s//\{body_file\}/$1}"
  s="${s//\{language\}/$2}"
  SECTION_RC=0
  SECTION_OUT=$(bash -c "$s" 2>&1) || SECTION_RC=$?
}
printf '変更内容(詳細)\n' > "$TMP/s_bad.md"; printf '変更内容（詳細）\n' > "$TMP/s_ok.md"
run_section "$TMP/s_bad.md" ja
expect_eq "T-05 節の bash: 違反で exit 1" "1" "$SECTION_RC"
case "$SECTION_OUT" in *'記号規定の違反'*) pass "T-05 節の bash: 違反の案内を出す" ;; *) fail "T-05 節の bash: 違反の案内が無い [$SECTION_OUT]" ;; esac
run_section "$TMP/s_ok.md" ja
expect_eq "T-05 節の bash: 適合で exit 0" "0" "$SECTION_RC"
run_section "relative.md" ja
expect_eq "T-05 節の bash: 入力不正で exit 1" "1" "$SECTION_RC"
case "$SECTION_OUT" in *'入力不正'*) pass "T-05 節の bash: 入力不正の案内を出す" ;; *) fail "T-05 節の bash: 入力不正の案内が無い [$SECTION_OUT]" ;; esac

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
: > "$TMP/zero_len.md"
rc=0; bash "$CHECK" --body-file "$TMP/zero_len.md" --language ja >/dev/null 2>&1 || rc=$?
expect_eq "T-07 空ファイルは exit 2" "2" "$rc"
rc=0; (cd "$TMP" && bash "$CHECK" --body-file t06c.md --language ja >/dev/null 2>&1) || rc=$?
expect_eq "T-07 相対パスは exit 2" "2" "$rc"
rc=0; bash "$CHECK" --language ja >/dev/null 2>&1 || rc=$?
expect_eq "T-07 body-file 欠落は exit 2" "2" "$rc"
printf '\xff\xfe日本語(a)\n' > "$TMP/bad_utf8.md"
rc=0; bash "$CHECK" --body-file "$TMP/bad_utf8.md" --language ja >/dev/null 2>&1 || rc=$?
expect_eq "T-07 不正な UTF-8 は exit 2（検査を素通りしない）" "2" "$rc"
rc=0; bash "$CHECK" --body-file "$TMP/t06c.md" --language ja --bogus >/dev/null 2>&1 || rc=$?
expect_eq "T-07 未知のオプションは exit 2" "2" "$rc"
rc=0; bash "$CHECK" --language ja --body-file >/dev/null 2>&1 || rc=$?
expect_eq "T-07 値の無い --body-file は exit 2" "2" "$rc"
mkdir -p "$TMP/nopython"
rc=0; PATH="$TMP/nopython" "$(command -v bash)" "$CHECK" --body-file "$TMP/t06c.md" --language ja >/dev/null 2>&1 || rc=$?
expect_eq "T-07 python3 が無ければ exit 2" "2" "$rc"
# エラーメッセージ（原因語）も固定する
err_of() { bash "$CHECK" "$@" 2>&1 >/dev/null || true; }
case "$(err_of --body-file "$TMP/none.md" --language ja)" in *'ERROR:'*missing*) pass "T-07 不在のメッセージに原因語 missing" ;; *) fail "T-07 不在のメッセージ" ;; esac
case "$(err_of --body-file "$TMP/zero_len.md" --language ja)" in *'ERROR:'*empty*) pass "T-07 空のメッセージに原因語 empty" ;; *) fail "T-07 空のメッセージ" ;; esac
case "$(cd "$TMP" && err_of --body-file t06c.md --language ja)" in *'ERROR:'*absolute*) pass "T-07 相対パスのメッセージに原因語 absolute" ;; *) fail "T-07 相対パスのメッセージ" ;; esac
case "$(err_of --body-file "$TMP/bad_utf8.md" --language ja)" in *'ERROR:'*'cannot read'*) pass "T-07 不正な UTF-8 のメッセージに原因語 cannot read" ;; *) fail "T-07 不正な UTF-8 のメッセージ" ;; esac
case "$(err_of --body-file "$TMP/t06c.md" --language ja --bogus)" in *'ERROR:'*unknown*) pass "T-07 未知のオプションのメッセージに原因語 unknown" ;; *) fail "T-07 未知のオプションのメッセージ" ;; esac
case "$(err_of --language ja --body-file)" in *'ERROR:'*'requires a value'*) pass "T-07 値の無い --body-file のメッセージに原因語 requires a value" ;; *) fail "T-07 値の無い --body-file のメッセージ" ;; esac
rc=0; bash "$CHECK" --body-file "$TMP/t06c.md" --language >/dev/null 2>&1 || rc=$?
expect_eq "T-07 値の無い --language は exit 2" "2" "$rc"
case "$(err_of --body-file "$TMP/t06c.md" --language)" in *'ERROR:'*'requires a value'*) pass "T-07 値の無い --language のメッセージに原因語 requires a value" ;; *) fail "T-07 値の無い --language のメッセージ" ;; esac
case "$(PATH="$TMP/nopython" "$(command -v bash)" "$CHECK" --body-file "$TMP/t06c.md" --language ja 2>&1 >/dev/null || true)" in *'ERROR:'*python3*) pass "T-07 python3 不在のメッセージに原因語 python3" ;; *) fail "T-07 python3 不在のメッセージ" ;; esac

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
