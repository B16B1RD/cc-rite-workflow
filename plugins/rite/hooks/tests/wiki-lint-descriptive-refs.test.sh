#!/bin/bash
# wiki-lint-descriptive-refs.test.sh
#
# Tests for wiki-lint-descriptive-refs.sh (wiki-lint/SKILL.md ステップ 7.5 delegation
# target). The helper counts descriptive Issue/PR number references left in Wiki page
# bodies and emits a marker block + WIKI_DESCRIPTIVE_REFS total + read_ok enum.
#
# Coverage:
#   TC-1   裸の `PR #N` / `Issue #N` が hit する (拡張の本体)
#   TC-2   `## ソース` 節の provenance ラベルが hit しない
#   TC-3   TODO / FIXME 行が hit しない
#   TC-4   インラインコードスパン内の literal 引用が hit しない
#   TC-5   コードフェンス内が hit しない / フェンス閉じ後は再び検出される
#   TC-6   語境界が文字クラスで表現されている (静的 pin。件数では測れないため)
#   TC-7   旧 4 形 (括弧付き / see PR / #N で対応 / 詳細は #N) の検出が保たれる
#   TC-8   frontmatter は `sources:` ブロックのみ除外 (description 散文は hit する)
#   TC-9   marker block / WIKI_DESCRIPTIVE_REFS / read_ok の stdout 契約
#   TC-10  空 pages_list → hits 0, read_ok=true (Wiki 初期化直後の legitimate no-op)
#   TC-11  全ページ読出失敗 → read_ok=io_error (偽の 0 件を「解消済み」と読ませない)
#   TC-12  placeholder residue ({branch_strategy} / {wiki_branch} / {pages_list}) → exit 1
#   TC-13  partial pollution (.rite/wiki/raw/ 行混入) → exit 1
#   TC-14  unknown branch_strategy → exit 1 / separate_branch + 空 --wiki-branch → exit 2
#   TC-15  MUTATION 拡張 regex を旧 4 形へ戻すと TC-1 が落ちる (拡張の識別力)
#   TC-16  MUTATION 本文フィルタを外すと TC-2 / TC-5 が落ちる (除外の識別力。E1 は TC-8、
#          E4 / E5 は終端アクション側にあり本 mutant の到達範囲外で TC-3 / TC-4 / TC-17 が pin)
#   TC-17  MUTATION 語境界を `\b` にすると gawk では never-match になる (silent 沈黙の実証)
#   TC-18  SKILL.md ステップ 7.5 が helper 委譲 + helper 不在 fallback を持つ (静的回帰)
#   TC-19  separate_branch (本番既定経路、git show) の positive path
#   TC-20  `## ソース` 除外が節スコープ (見出し以降 EOF まで打ち切らない)
#   TC-21  informational 契約の非回帰 (T-06 / T-07: n_warnings 不加算 / canonical Lint: 行不変)
#   TC-19b separate_branch の読出に cat fallback が無い (ブランチ分離の pin)
#   TC-22  2 検出器の R1 regex が literal 一致 (語彙 drift の検出)
#   TC-23  検出器の破損が read_errors / io_error へ伝播する (0 件を実測済みと名乗らない)
#   TC-24  traversal gate / 読出・検出失敗の WARNING / E1 ブロック終端
#   TC-11b 部分読出失敗は read_ok=true のまま read_errors だけ立つ
#   TC-25..TC-26 index.md 不在時は従来どおり (#2069 T-06: read_errors 不加算 / stdout に index 行なし)
#   TC-27..TC-29 index.md のサマリー列だけを検出する (リンクテキスト列は対象外)
#   TC-30  OKF 箇条書き形式の index.md でも検出できる (どちらか一方専用にしない)
#   TC-31  列数が壊れた行は行全体へフォールバックせず行番号つき WARNING でスキップ (#2069 T-07)
#   TC-32  一部行のみ抽出失敗でも欠損ガードが発火し、欠損行数が stdout に載る (read_errors に混ぜない)
#   TC-33..TC-34 gate の非回帰 (raw/ と `..` は fail-fast のまま、index.md は完全一致で受理・重複計上なし)
#   TC-35  ステップ 2.2 の pages_list に index.md を混ぜていない (separate_branch / same_branch の両経路)
#   TC-36  separate_branch (本番既定経路) でも index.md を走査する (存在プローブ + git show)
#   TC-37  サマリー列の位置をヘッダー行から決めている (位置固定 fallback への変異を弾く)
#   TC-38  index.md が存在するのに読めない場合は read_errors に計上する (不在との分離)
#   TC-39  サマリー列ヘッダー不検出のテーブル行は当てずっぽうで読まず skipped_rows で surface する
#   TC-40  `./pages/` / `../pages/` 形式のエントリも拾う (orphans.sh と同一定義)
#   TC-41  壊れた wiki ref は「index.md 不在」に畳まず io_error に倒れる
#   TC-42  ヘッダー判定がエントリ行を飲み込まない (サマリーに「サマリー」を含む行)
#   TC-43  E5 の欠落が skipped_rows に載る / コードスパン内引用は E4 で無効化される
#   TC-44  診断に外部入力 (--wiki-branch) の制御文字を素通ししない
#   TC-45  本文フィルタ (E3 コードフェンス等) が index.md にも適用される
#   TC-46  index.md が読めれば pages 全件失敗でも io_error ではなく部分失敗になる
#   TC-47  リンク行はあるが entries 0 件の index.md は検出失敗として計上する (stdin に依存しない)
#   TC-48  index.md 終端アクションの戻り値 arity (4 値) を pin する (フィールドを減らす変異を弾く)
#   TC-19c separate_branch (既定) でも index.md 不在は read_errors に数えない (#2069 T-06)
#   TC-50  index-template.md 前文を entries に数えず、検出失敗ガードを殺さない (配布テンプレート回帰)
#   TC-50b 記法例コメントを持つ index.md でコメント除去規則そのものを pin する (literal fixture)
#   TC-51  除外ブロック (コメント / フェンス) の未閉鎖を END で検出失敗へ倒す (部分欠損形も含む)
#   TC-49  表と箇条書きが混在する index.md でも行単位で形式を判別する (移行期の必然形状)
#   TC-52  index.md のリンク regex が orphans.sh と literal 一致 (共有定義の drift 検出)
#
# NOT covered (environment-dependent): mktemp failure on a read-only /tmp.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/wiki-lint-descriptive-refs.sh"
LINT_MD="$PLUGIN_ROOT/skills/wiki-lint/SKILL.md"

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: helper not found: $SCRIPT" >&2
  exit 1
fi

cleanup_dirs=()
tmp_files=()
cleanup() {
  local p
  for p in "${cleanup_dirs[@]:-}"; do [ -n "$p" ] && rm -rf "$p"; done
  for p in "${tmp_files[@]:-}"; do [ -n "$p" ] && rm -f "$p"; done
}
trap cleanup EXIT

SBX=$(make_plain_sandbox) && cleanup_dirs+=("$SBX") || { echo "ERROR: make_plain_sandbox failed, aborting" >&2; exit 1; }

# ---- fixture ---------------------------------------------------------------
# 1 ページに全 AC の対象・非対象を同居させる。除外が効かないと非対象側が hit に混ざるため、
# 1 本の fixture で「拾うべきものを拾い」「拾ってはならないものを拾わない」を同時に測れる。
PAGES_DIR="$SBX/.rite/wiki/pages/anti-patterns"
mkdir -p "$PAGES_DIR"
FIXTURE_REL=".rite/wiki/pages/anti-patterns/fixture.md"
cat > "$SBX/$FIXTURE_REL" <<'FIXTURE'
---
title: "fixture"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260101T000000Z-pr-1300.md"
---

# fixture

PR #1300 は フォーマットを統一した
Issue #1284 系譜の継続
(refs #1150) の括弧形
See PR #1149 も同様
詳細は #1151
#1152 で別途対応
TODO: #9999 で対応予定
FIXME PR #9998 を追う
`refs #204` が `refs #2047` に一致する
PR #2047 の語境界

```bash
grep -E "PR #7777" fenced.md
```

PR #1301 フェンス後は再び検出される

## ソース

- [PR #1300 review results](../../raw/reviews/a.md)
- [Issue #1284 fix results](../../raw/fixes/b.md)
FIXTURE

run_helper() {
  # $1..: extra args; stdin: pages_list
  ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" "$@" )
}

OUT="$SBX/out.txt"
ERR="$SBX/err.txt"
printf '%s\n' "$FIXTURE_REL" | run_helper > "$OUT" 2> "$ERR"
rc=$?

# 実際に hit した本文行を取り出す (assert の根拠を 1 箇所に集約する)。
# helper は行内容を出さないため、helper と同じフィルタ + regex を再現するのではなく
# hits 数と marker block で判定する。行レベルの識別は comment-journal-check.test.sh が担う。
hits=$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$OUT")
pages=$(sed -n 's/^descriptive_refs_pages=//p' "$OUT")
read_ok=$(sed -n 's/^descriptive_refs_read_ok=//p' "$OUT")

echo "== wiki-lint-descriptive-refs.sh =="
assert "TC-9 exit code 0" "0" "$rc"
assert "TC-9 read_ok=true" "true" "$read_ok"
assert "TC-9 該当ページ数=1" "1" "$pages"
assert_grep "TC-9 marker block begin" "$OUT" '^---descriptive_refs_begin---$'
assert_grep "TC-9 marker block end" "$OUT" '^---descriptive_refs_end---$'
assert_grep "TC-9 marker block に page=/hits= 行" "$OUT" "^page=$FIXTURE_REL; hits=[0-9]+$"
assert_grep "TC-9 stderr に WikiDescriptiveRef 行" "$ERR" '^WikiDescriptiveRef: page=pages/anti-patterns/fixture\.md, hits=[0-9]+$'
# 1 枚だけだと descriptive_refs_pages が「hits>0 のページ数」でも定数 1 でも同じ値になる。
# hit する 2 枚 + clean 1 枚で識別力を出す (計上条件を -ge 0 に緩めた変異では 3 になる)。
cp "$SBX/$FIXTURE_REL" "$SBX/.rite/wiki/pages/anti-patterns/fixture2.md"
printf '# clean\n\n番号を含まない本文\n' > "$SBX/.rite/wiki/pages/anti-patterns/clean.md"
out9b=$(printf '%s\n%s\n%s\n' "$FIXTURE_REL" ".rite/wiki/pages/anti-patterns/fixture2.md" ".rite/wiki/pages/anti-patterns/clean.md" \
  | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null)
assert "TC-9 該当ページ数=2 (定数でも全件数でもない)" "2" "$(printf '%s' "$out9b" | sed -n 's/^descriptive_refs_pages=//p')"
assert "TC-9 marker block の page= 行数=2" "2" "$(printf '%s' "$out9b" | grep -c '^page=')"
rm -f "$SBX/.rite/wiki/pages/anti-patterns/fixture2.md" "$SBX/.rite/wiki/pages/anti-patterns/clean.md"

# fixture の本文で hit すべき行は 8 行:
#   PR #1300 / Issue #1284 / (refs #1150) / See PR #1149 / 詳細は #1151 /
#   #1152 で別途対応 / PR #2047 / PR #1301
# 除外が 1 つでも外れるとこの数を超える (TODO/FIXME 2 行・コードスパン 1 行・
# フェンス 1 行・ソース節 2 行が混入するため)。
assert "TC-1/2/3/4/5 hits=8 (対象のみ)" "8" "$hits"

# ---- MUTATION の前提: mutant が実際に元と違うことを先に確かめる ---------------
# 生成が no-op のまま「差が出なかった」と読むと mutation test が無言で vacuous になる。
assert_mutated() {
  local label="$1" mutant="$2"
  if diff -q "$SCRIPT" "$mutant" >/dev/null 2>&1; then
    fail "$label (mutant が元と同一 — 変換パターンが一致していない。この assert は無効)"
    return 1
  fi
  return 0
}

# ---- 除外の識別力を「フィルタを外した版」との差で測る (TC-16 の測定基盤) -------
# helper 内のフィルタを外した mutant を作り、除外が無いと hits が跳ね上がることを実証する。
# **本 mutant で到達不能な除外**: E1 (frontmatter 除去) は mutant が残す設計のため測れず、TC-8 の
# fixture (description 散文 / sources ブロックの両方) が担う。E4 (コードスパン) と E5 (TODO/FIXME) は
# 終端アクション側にあり本 mutant が差し替える本文フィルタに含まれないため測れず、E4 は TC-4、
# E5 は TC-3 / TC-17 が pin する。mutant を拡張する際は「どの除外がその mutant で到達不能か」を
# 先に列挙すること。
MUT_NOFILTER="$SBX/mutant-nofilter.sh"
# フィルタ本体 (_RITE_BODY_FILTER) を「frontmatter 除去のみ」に差し替える。
# 終端アクション (マスク + 計数) は _RITE_COUNT_ACTION が別に持つため、ここでは
# 落とす行の規則だけを置く (末尾に print を足すと計数用 awk の出力に混ざる)。
awk '
  /^_RITE_BODY_FILTER=.$/ { print "_RITE_BODY_FILTER='"'"'"; infilter=1; next }
  infilter && /^.$/ { print "NR==1 && /^---[[:space:]]*$/ { infm=1; next }"
                      print "infm && /^---[[:space:]]*$/  { infm=0; next }"
                      print "infm                        { next }"
                      print "'"'"'"; infilter=0; next }
  infilter { next }
  { print }
' "$SCRIPT" > "$MUT_NOFILTER"
if assert_mutated "TC-16 MUTATION mutant 生成" "$MUT_NOFILTER"; then
  mut_hits=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$MUT_NOFILTER" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')
  if [ "${mut_hits:-0}" -gt "$hits" ] 2>/dev/null; then
    pass "TC-16 MUTATION 除外フィルタ除去で hits が増える (${hits} → ${mut_hits}; 除外に識別力あり)"
  else
    fail "TC-16 MUTATION 除外フィルタ除去で hits が変わらない (${hits} → ${mut_hits}) — 除外が何も除外していない"
  fi
fi

# ---- 拡張 regex の識別力 (TC-15) -------------------------------------------
# 検出 regex を旧 4 形へ戻した mutant では、裸の PR #N / Issue #N が落ちて hits が減る。
MUT_OLDRE="$SBX/mutant-oldre.sh"
OLD_RE='[（(](Issue|PR|refs|Refs)[^)）]*#[0-9]+|(refs|Refs|see PR|See PR) #[0-9]+|(PR )?#[0-9]+ ?で(別途)?対応|詳細は ?#[0-9]+'
awk -v old_re="$OLD_RE" '
  /^_RITE_DESCRIPTIVE_RE=/ { print "_RITE_DESCRIPTIVE_RE='"'"'" old_re "'"'"'"; next }
  { print }
' "$SCRIPT" > "$MUT_OLDRE"
if assert_mutated "TC-15 MUTATION mutant 生成" "$MUT_OLDRE"; then
  old_hits=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$MUT_OLDRE" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')
  if [ "${old_hits:-0}" -lt "$hits" ] 2>/dev/null; then
    pass "TC-15 MUTATION 旧 4 形へ戻すと hits が減る (${hits} → ${old_hits}; 拡張に識別力あり)"
  else
    fail "TC-15 MUTATION 旧 4 形へ戻しても hits が変わらない (${hits} → ${old_hits}) — 拡張が何も広げていない"
  fi
fi

# ---- 個別 AC を単一行 fixture で pin する ----------------------------------
# 1 行だけのページを流し、hits が 1 / 0 のどちらになるかで対象・非対象を確定させる。
single_hits() {
  local body="$1" rel=".rite/wiki/pages/anti-patterns/single.md"
  printf '%s\n' "$body" > "$SBX/$rel"
  printf '%s\n' "$rel" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null \
    | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p'
}
assert "TC-1 裸の PR #N が hit"            "1" "$(single_hits 'PR #1300 は フォーマットを統一した')"
assert "TC-1 裸の Issue #N が hit"         "1" "$(single_hits 'Issue #1284 系譜の継続')"
assert "TC-7 括弧付き (refs #N) が hit"     "1" "$(single_hits '(refs #1150) の括弧形')"
assert "TC-7 See PR #N が hit"             "1" "$(single_hits 'See PR #1149 も同様')"
assert "TC-7 詳細は #N が hit"             "1" "$(single_hits '詳細は #1151')"
assert "TC-7 #N で別途対応 が hit"          "1" "$(single_hits '#1152 で別途対応')"
assert "TC-3 TODO 行は hit しない"          "0" "$(single_hits 'TODO: #9999 で対応予定')"
assert "TC-3 FIXME 行は hit しない"         "0" "$(single_hits 'FIXME PR #9998 を追う')"
assert "TC-4 コードスパン内は hit しない"    "0" "$(single_hits '`refs #204` が `refs #2047` に一致する')"
# span マスクは削除ではなく `_` 置換。削除するとキーワードと番号が隣接して**誤検出を製造する**
# 方向に倒れる (comment-journal-check.test.sh TC-4 と対称)。
assert "TC-4 span マスクがキーワードと番号を連結しない" "0" "$(single_hits 'PR `x` #1234')"
# 左語境界 (^|[^A-Za-z]): `refs` を語尾に持つ別語を弾く。cjc TC-16 と対称。
assert "TC-6 prefs #N は hit しない (左語境界)" "0" "$(single_hits 'prefs #12 を設定')"
assert "TC-6 hrefs #N は hit しない (左語境界)" "0" "$(single_hits 'hrefs #13 を確認')"
assert "TC-1 キーワードなし裸 #N は hit しない" "0" "$(single_hits '#1234 の単独形は対象外')"
# E1 は frontmatter 全体ではなく `sources:` ブロックのみを落とす。ref 値はファイルパスで
# 番号規則に一致しないため除外は防御的だが、`description:` / `title:` の散文は本物の
# 説明的参照を含む (実 wiki で 22 件)。両方を 1 つの fixture で測る。
tc8_fm=$(printf -- '---\ndescription: "PR #1300 の経緯"\nsources:\n  - type: "reviews"\n    ref: "raw/reviews/x-pr-1300.md"\ntags: ["a"]\n---\n\n# t\n\n本文に番号なし\n')
assert "TC-8 frontmatter description の番号参照は hit する" "1" "$(single_hits "$tc8_fm")"
# ref 値に `#N` を含ませる。ファイルパスに `#` は現れないため E1 は防御的除外だが、`#` を
# 持たない fixture では E1 を削除しても 0 のままで、この assert が何も pin しない。
tc8_src=$(printf -- '---\ntitle: "t"\nsources:\n  - type: "reviews"\n    ref: "raw/reviews/PR #1300.md"\n---\n\n# t\n\n本文に番号なし\n')
assert "TC-8 frontmatter sources ブロックは hit しない" "0" "$(single_hits "$tc8_src")"

# TC-2: `## ソース` 節のみを持つページ (本文に対象なし) は 0 件
src_only=$(printf '# t\n\n## ソース\n\n- [PR #1300 review results](../../raw/reviews/a.md)\n- [Issue #1284 fix results](../../raw/fixes/b.md)\n')
assert "TC-2 ソース節配下のラベル 2 行も hit しない" "0" "$(single_hits "$src_only")"

# TC-5: フェンス内は 0、フェンス閉じ後の行は検出される
fence_only=$(printf '# t\n\n```bash\ngrep -E "PR #7777" f.md\n```\n')
assert "TC-5 コードフェンス内は hit しない" "0" "$(single_hits "$fence_only")"
fence_then=$(printf '# t\n\n```bash\ngrep -E "PR #7777" f.md\n```\n\nPR #1301 フェンス後\n')
assert "TC-5 フェンス閉じ後は再び検出される" "1" "$(single_hits "$fence_then")"

# TC-6: 語境界。貪欲な `[0-9]+` により語境界の有無は件数メトリクスに現れないため、件数ベースでは
# 原理的に検出できない (実装から `([^0-9]|$)` を消しても hits は不変)。よって helper の regex 定義を
# 静的に pin する。行内容ベースの識別力は comment-journal-check.test.sh の TC-6 が担う。
# R1 側と R2 の `詳細は` 側にそれぞれ `([^0-9]|$)` があるため、単一の assert では片方だけで
# 充足してしまう。守りたい R1 側を語彙の末尾 (`[Rr]esolves`) から続く文脈込みで pin する。
assert_grep "TC-6 R1 の語境界が文字クラスで表現される" \
  "$SCRIPT" '_RITE_DESCRIPTIVE_RE=.*\[Rr\]esolves\) \*#\[0-9\]\+\(\[\^0-9\]\|\$\)'
assert_grep "TC-6 R2 詳細は 側の語境界も文字クラス" \
  "$SCRIPT" '_RITE_DESCRIPTIVE_RE=.*詳細は \?#\[0-9\]\+\(\[\^0-9\]\|\$\)'
assert_not_grep "TC-6 検出 regex に \\b を使っていない" "$SCRIPT" '_RITE_DESCRIPTIVE_RE=.*\[0-9\]\+.b'

# TC-17: 終端アクション (_RITE_COUNT_ACTION / _RITE_INDEX_COUNT_ACTION) は awk で走るため、
# そこに `\b` を持ち込むと gawk がバックスペースとして読んで永久に一致しなくなる。
# 終端アクションの TODO/FIXME 除外を `\b` 付きに変異させ (sed が 2 箇所を同時に叩く)、
# 除外が沈黙する (= hits が増える) ことで危険を実証する。
# awk 経路を実際に変異させるので、被テスト対象を実行しない always-pass にはならない。
MUT_AWKB="$SBX/mutant-awk-backslash-b.sh"
sed 's%/(TODO|FIXME)%/(TODO\\b|FIXME\\b)%' "$SCRIPT" > "$MUT_AWKB"
if assert_mutated "TC-17 MUTATION mutant 生成" "$MUT_AWKB"; then
  awkb_hits=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$MUT_AWKB" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')
  if [ "${awkb_hits:-0}" -gt "$hits" ] 2>/dev/null; then
    pass "TC-17 MUTATION awk フィルタに \\b を持ち込むと除外が沈黙する (${hits} → ${awkb_hits}; 文字クラス必須の実証)"
  else
    fail "TC-17 MUTATION awk フィルタの \\b 変異で hits が変わらない (${hits} → ${awkb_hits})"
  fi
fi

# ---- 契約・エラー経路 -------------------------------------------------------

# TC-10: 空 pages_list
empty_out=$(printf '' | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null)
assert "TC-10 空 pages_list → hits 0" "0" "$(printf '%s\n' "$empty_out" | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')"
assert "TC-10 空 pages_list → read_ok=true" "true" "$(printf '%s\n' "$empty_out" | sed -n 's/^descriptive_refs_read_ok=//p')"

# TC-11: 全ページ読出失敗 → io_error
io_out=$(printf '%s\n' ".rite/wiki/pages/does-not-exist.md" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null)
assert "TC-11 全ページ読出失敗 → read_ok=io_error" "io_error" "$(printf '%s\n' "$io_out" | sed -n 's/^descriptive_refs_read_ok=//p')"
assert "TC-11 全ページ読出失敗でも hits=0 を出す" "0" "$(printf '%s\n' "$io_out" | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')"

# TC-11b: 部分読出失敗 — read_ok は true を維持しつつ read_errors で件数を surface する。
# 完了レポートの note 展開は read_ok と read_errors の 2 値で決まるため、後者だけが
# 立つ経路に到達する assert が必要 (sibling wiki-lint-source-refs.test.sh と同じ形)。
partial_out=$(printf '%s\n%s\n' "$FIXTURE_REL" ".rite/wiki/pages/does-not-exist.md" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null)
assert "TC-11b 部分読出失敗 → read_ok=true を維持" "true" "$(printf '%s\n' "$partial_out" | sed -n 's/^descriptive_refs_read_ok=//p')"
assert "TC-11b 部分読出失敗 → read_errors=1" "1" "$(printf '%s\n' "$partial_out" | sed -n 's/^descriptive_refs_read_errors=//p')"
assert "TC-11b 読めた分の hits は計上される" "$hits" "$(printf '%s\n' "$partial_out" | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')"
assert "TC-9 read_errors=0 (全件読出成功時)" "0" "$(sed -n 's/^descriptive_refs_read_errors=//p' "$OUT")"

# TC-12: placeholder residue
# exit 1 だけを見ると、後段の「unknown branch_strategy」分岐や partial pollution gate も
# 同じ rc を返すため、当の gate を削除しても緑のままになる。sibling (wiki-lint-source-refs.test.sh)
# と同じく gate 固有の marker まで assert して、どの gate が発火したかを pin する。
p12_err="$SBX/p12.err"
tmp_files+=("$p12_err")
printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy '{branch_strategy}' --repo-root "$SBX" ) >/dev/null 2>"$p12_err"
assert "TC-12 {branch_strategy} 残留 → exit 1" "1" "$?"
assert_grep "TC-12 {branch_strategy} 残留 → gate 固有 marker" "$p12_err" 'LINT_PHASE_7_5_PLACEHOLDER_RESIDUE=1; reason=branch_strategy_unsubstituted'
printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch '{wiki_branch}' --repo-root "$SBX" ) >/dev/null 2>"$p12_err"
assert "TC-12 {wiki_branch} 残留 → exit 1" "1" "$?"
assert_grep "TC-12 {wiki_branch} 残留 → gate 固有 marker" "$p12_err" 'LINT_PHASE_7_5_PLACEHOLDER_RESIDUE=1; reason=wiki_branch_unsubstituted'
printf '%s\n' "{pages_list}" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) >/dev/null 2>"$p12_err"
assert "TC-12 {pages_list} 残留 → exit 1" "1" "$?"
assert_grep "TC-12 {pages_list} 残留 → gate 固有 marker" "$p12_err" 'LINT_PHASE_7_5_PLACEHOLDER_RESIDUE=1; reason=pages_list_unsubstituted'

# TC-13: partial pollution
printf '%s\n%s\n' "$FIXTURE_REL" ".rite/wiki/raw/reviews/x.md" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) >/dev/null 2>&1
assert "TC-13 raw/ 行混入 → exit 1" "1" "$?"

# TC-14: invocation errors
printf '' | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy bogus --repo-root "$SBX" ) >/dev/null 2>&1
assert "TC-14 unknown branch_strategy → exit 1" "1" "$?"
printf '' | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy separate_branch --repo-root "$SBX" ) >/dev/null 2>&1
assert "TC-14 separate_branch + 空 --wiki-branch → exit 2" "2" "$?"
printf '' | ( cd "$SBX" && bash "$SCRIPT" --repo-root "$SBX" ) >/dev/null 2>&1
assert "TC-14 --branch-strategy 欠落 → exit 2" "2" "$?"

# TC-18: SKILL.md ステップ 7.5 の委譲契約 (静的回帰)。
# TC-1..17 は helper (.sh) を、TC-18 は委譲元 SKILL.md の分岐を守る。
assert_grep "TC-18 SKILL.md が helper へ委譲している" "$LINT_MD" 'wiki-lint-descriptive-refs\.sh'
assert_grep "TC-18 helper 不在 fallback が marker block を出す" "$LINT_MD" '"---descriptive_refs_begin---"'
assert_grep "TC-18 helper 不在 fallback が WIKI_DESCRIPTIVE_REFS=0 を出す" "$LINT_MD" 'WIKI_DESCRIPTIVE_REFS=0'
assert_grep "TC-18 helper 不在 fallback の read_ok" "$LINT_MD" 'descriptive_refs_read_ok=skipped_helper_missing'
assert_grep "TC-18 helper 不在 fallback が read_errors=0 を出す" "$LINT_MD" 'descriptive_refs_read_errors=0'
# stdout 契約は本 PR で 5 フィールドになった。fallback が片方だけ追随しないと
# 「helper 経由か縮退経路かで stdout の形が変わる」状態になる
assert_grep "TC-18 helper 不在 fallback が skipped_rows=0 を出す" "$LINT_MD" 'descriptive_refs_skipped_rows=0'
# producer (上の emit) だけでなく **消費者** も pin する。新設フィールドは ステップ 9 note 展開表
# だけが読むため、展開表から skipped_rows 条件が消えると「index.md の行欠損があっても注記なしの
# N 件」を出す状態へ静かに戻る。emit 側の assert はその変更を 1 つも検出しない。
# 表を pin するときは「表が存在する」ではなく「各行が存在する」を測る。本 PR は展開表を 2 行から
# 4 行へ広げており、片方だけ pin すると新設したもう 1 行 (両欠損の共起) を削っても全緑を通る。
# 波括弧は ERE の interval 構文なのでエスケープする (GNU grep はリテラル扱いするが POSIX 未定義で、
# 実装によっては空 (sub)expression エラーで異常終了する)。
assert_grep "TC-18 note 展開に read_errors=0 かつ skipped_rows>0 の行がある" "$LINT_MD" 'read_errors=0` かつ `skipped_rows>0'
assert_grep "TC-18 note 展開に read_errors>0 かつ skipped_rows>0 の共起行がある" "$LINT_MD" 'read_errors>0` かつ `skipped_rows>0'
assert_grep "TC-18 部分欠損 note の本文が存在する" "$LINT_MD" '部分欠損: index\.md の \{descriptive_refs_skipped_rows\} 行'
assert_grep "TC-18 共起 note が未実測と部分欠損の両方を述べる" "$LINT_MD" '件の対象ファイルを読出または検出できず集計から除外 / 部分欠損'
assert_not_grep "TC-18 旧 inline 検出 regex が残っていない" "$LINT_MD" 'see PR\|See PR\) #\[0-9\]\+'
# ステップ 2.2 末尾の分岐契約。ページ / raw が 0 件でもステップ 7.5 だけは走らせる
# (index.md が単独で走査対象になりうるため)。develop 版の「ステップ 3-7 を skip し ステップ 9 に進む」
# へ戻ると index.md 走査そのものが起動せず、本 PR が塞いだ盲点が無言で再発する。
# 走査範囲を広げた helper 側だけをテストしても、この分岐が消えれば helper は呼ばれない。
assert_grep "TC-18 ページ/raw 0 件でもステップ 7.5 は skip しない" "$LINT_MD" 'ステップ 7\.5 → ステップ 9'
assert_not_grep "TC-18 旧 skip 範囲 (3-7) が残っていない" "$LINT_MD" 'ステップ 3-7 を skip'
# 上の anti-pattern を避ける過程で、実在しない見出しへの範囲参照 (`ステップ 3-7.4` = `## ステップ 7.4`
# は本ファイルに存在しない) を作らないこと。7.5 の除外は実在見出しだけを使って表現する
# (例: `ステップ 3-7 (7.5 を除く)`)。読み手が「7.4 という段階が別にあるのか」を推測で解く余地を残さない。
# 選択子は生の `|` で書く。assert_not_grep は grep -qE (ERE) なので `\|` は選択子ではなく
# literal のパイプ文字になり、「2 語をパイプで連結した 1 本の文字列」を探す常時緑の assertion に化ける。
assert_not_grep "TC-18 実在しない見出し (ステップ 7.4) への範囲参照がない" "$LINT_MD" 'ステップ 3-7\.4|ステップ 7\.4'

# ---- TC-19: separate_branch (本番既定経路) の positive path ----------------
# 44 assertion が same_branch (cat) に偏っており、rite-config.yml の既定 separate_branch
# (git show) は error 経路でしか踏まれていなかった。同じ fixture で同じ hits になることを pin する。
GITSBX=$(make_plain_sandbox) && cleanup_dirs+=("$GITSBX") || { echo "ERROR: make_plain_sandbox failed, aborting" >&2; exit 1; }
git_err=$(mktemp "${TMPDIR:-/tmp}/rite-tc19-git-err-XXXXXX") || { echo "WARNING: TC-19: git stderr 捕捉用 mktemp に失敗しました。sandbox 準備失敗時に git の stderr は surface されません" >&2; git_err=""; }
tmp_files+=("${git_err:-}")
# git の rc / stderr を捨てない: 周囲の global 設定 (commit.gpgsign 等) で commit が失敗すると、
# 捨てた場合は「検出器が壊れた」形の assert 失敗だけが出て原因が surface しない。
# 署名の影響は `-c` で切る (git config によるファイル書き込みも不要になる)。
if (
  cd "${GITSBX:?GITSBX unset}" || exit 1
  git init -q . || exit 1
  mkdir -p .rite/wiki/pages/anti-patterns
  cp "$SBX/$FIXTURE_REL" ".rite/wiki/pages/anti-patterns/fixture.md"
  git add -A || exit 1
  git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t commit -qm fixture || exit 1
  git branch -q wiki || exit 1
  # fixture を blob 限定にする: hits が blob から読めたことを示す (worktree に残すと、
  # どちらから読んでも同じ hits になり読出元が特定できない)。fallback 再導入の検出は
  # 下の TC-19b が担う。
  rm -f ".rite/wiki/pages/anti-patterns/fixture.md"
) 2>"${git_err:-/dev/null}"; then
  :
else
  git_rc=$?
  fail "TC-19 git sandbox の準備に失敗 (rc=$git_rc)"
  [ -n "$git_err" ] && [ -s "$git_err" ] && head -5 "$git_err" | sed 's/^/    /' >&2
fi
sb_hits=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$GITSBX" && bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch wiki --repo-root "$GITSBX" ) 2>/dev/null | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')
assert "TC-19 separate_branch (git show) で same_branch と同じ hits" "$hits" "$sb_hits"
sb_ok=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$GITSBX" && bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch wiki --repo-root "$GITSBX" ) 2>/dev/null | sed -n 's/^descriptive_refs_read_ok=//p')
assert "TC-19 separate_branch で read_ok=true" "true" "$sb_ok"

# TC-19c: index.md 不在の検証は same_branch (TC-25 の `[ -f ]`) だけでは足りない。存在プローブは
# branch_strategy ごとに別実装 (`git cat-file -e` と `[ -f ]`) で、separate_branch が既定かつ推奨
# (rite-config.yml / templates/config/rite-config.yml) のため、既定経路が無検証のまま残っていた。
# GITSBX の wiki ブランチは index.md を持たないまま TC-36 が意図的に残しているので追加準備は不要。
# 「不在を読出失敗として計上しない」ことまで見る (件数だけだと部分失敗で read_ok=true が維持され
# プローブを潰しても緑のままになる)。
sb_noidx_out="$GITSBX/sb-noidx.out"; tmp_files+=("$sb_noidx_out")
sb_noidx_err="$GITSBX/sb-noidx.err"; tmp_files+=("$sb_noidx_err")
printf '%s\n' "$FIXTURE_REL" | ( cd "$GITSBX" && bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch wiki --repo-root "$GITSBX" ) > "$sb_noidx_out" 2> "$sb_noidx_err"
assert "TC-19c (#2069 T-06) separate_branch で index.md 不在なら read_errors=0" "0" "$(sed -n 's/^descriptive_refs_read_errors=//p' "$sb_noidx_out")"
assert_not_grep "TC-19c index.md 不在なら marker block に index 行が出ない" "$sb_noidx_out" 'index\.md'
assert_not_grep "TC-19c index.md 不在を読出失敗として WARNING しない" "$sb_noidx_err" 'index\.md の読出に失敗'

# ---- TC-20: `## ソース` 除外の節スコープ ------------------------------------
# 見出し以降 EOF まで打ち切ると、wiki-ingest が後ろに追記する `## 補強:` 等の本文が盲点になる。
post_src=$(printf '# t\n\n## ソース\n\n- [PR #1400 review results](../../raw/reviews/a.md)\n\n## 補強: 節\n\nPR #1500 はソース節の後の本文\n')
assert "TC-20 ソース節の後に続く本文は hit する (節スコープ)" "1" "$(single_hits "$post_src")"
# wiki-ingest は `## ソース（追記分）` / `## ソース（追記分 N）` を生成する (実測 13 箇所)。
# 見出しを厳密一致にすると、これらが節の開始として認識されないまま「次の見出し」としては
# 認識され、直前の節の除外を打ち切って provenance ラベルを走査対象に戻す。
appendix_src=$(printf '# t\n\n## ソース\n\n- [PR #1400 review results](../../raw/a.md)\n\n## ソース（追記分）\n\n- [PR #1500 review results](../../raw/b.md)\n\n## ソース(追記分 2)\n\n- [PR #1600 review results](../../raw/c.md)\n')
assert "TC-20 追記分ソース節の provenance ラベルも hit しない (全角・半角括弧)" "0" "$(single_hits "$appendix_src")"
appendix_then=$(printf '# t\n\n## ソース（追記分）\n\n- [PR #1500 review results](../../raw/b.md)\n\n## 補強: 節\n\nPR #1700 は追記分ソース節の後の本文\n')
assert "TC-20 追記分ソース節の後の本文は hit する" "1" "$(single_hits "$appendix_then")"
assert "TC-20 ソース節内の provenance ラベルは hit しない" "0" \
  "$(single_hits "$(printf '# t\n\n## ソース\n\n- [PR #1400 review results](../../raw/reviews/a.md)\n')")"

# ---- TC-21: informational 契約の非回帰 (Issue の T-06 / T-07) ---------------
# 実測で確認しただけでは非回帰は担保されない。SKILL.md 側を静的に pin する。
assert_grep "TC-21 (T-06) n_descriptive_refs は n_warnings に加算しない" "$LINT_MD" \
  'n_descriptive_refs.*n_warnings.*加算しない'
assert_grep "TC-21 (T-07) canonical Lint: summary 行の形式が不変" "$LINT_MD" \
  '^Lint: contradictions=\{n_contradictions\}, stale=\{n_stale\}, orphans=\{n_orphans\}, missing_concept=\{n_missing_concept\}, unregistered_raw=\{n_unregistered_raw\}, broken_refs=\{n_broken_refs\}$'
assert_not_grep "TC-21 (T-07) Lint: 行に descriptive フィールドが混入していない" "$LINT_MD" \
  '^Lint: .*descriptive'

# ---- TC-23: 検出器の破損が read_errors へ伝播すること -----------------------
# 本 helper の read_ok enum は「0 件が実体を反映していない」状況を surface するためにある。
# 検出器そのものが壊れた場合だけがその enum をすり抜けると、完了レポートに「実測済みの 0 件」
# として載る。検出 regex を不正にした mutant で、0 件ではなく io_error に倒れることを測る。
MUT_BADRE="$SBX/mutant-badre.sh"
sed "s%^_RITE_DESCRIPTIVE_RE='.*'$%_RITE_DESCRIPTIVE_RE='([unclosed'%" "$SCRIPT" > "$MUT_BADRE"
if assert_mutated "TC-23 MUTATION mutant 生成" "$MUT_BADRE"; then
  mut_out=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$MUT_BADRE" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null)
  mut_hits=$(printf '%s' "$mut_out" | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')
  mut_ok=$(printf '%s' "$mut_out" | sed -n 's/^descriptive_refs_read_ok=//p')
  mut_err=$(printf '%s' "$mut_out" | sed -n 's/^descriptive_refs_read_errors=//p')
  assert "TC-23 検出器破損時は read_ok=io_error (0 件を実測済みと名乗らない)" "io_error" "$mut_ok"
  assert "TC-23 検出器破損時は read_errors が立つ" "1" "$mut_err"
  assert "TC-23 検出器破損時の hits は 0" "0" "$mut_hits"
fi

# ---- TC-19b: separate_branch の読出に cat fallback が無いこと ----------------
# 旧 inline 実装は `git show ... || cat "$page"` を持っており、wiki ブランチに無いページを
# ワークツリーから読んでブランチ分離を無言で破っていた。worktree にのみ存在するページで
# io_error に倒れることを測る (fallback を再導入すると hits>0 / read_ok=true になる)。
fb_out=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$GITSBX" && cp "$SBX/$FIXTURE_REL" "$FIXTURE_REL" 2>/dev/null; bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch nonexistent-branch --repo-root "$GITSBX" ) 2>/dev/null)
fb_ok=$(printf '%s' "$fb_out" | sed -n 's/^descriptive_refs_read_ok=//p')
fb_hits=$(printf '%s' "$fb_out" | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')
assert "TC-19b worktree にページが在っても git show 失敗は io_error (cat fallback なし)" "io_error" "$fb_ok"
assert "TC-19b cat fallback が無いので hits は 0" "0" "$fb_hits"

# ---- TC-24: cycle 5 で足した診断・gate の pin --------------------------------
# traversal gate: `.rite/wiki/pages/` prefix を持つため default arm に落ちず、専用 arm が要る。
tv_err="$SBX/tv.err"; tmp_files+=("$tv_err")
printf '%s\n' ".rite/wiki/pages/../../../etc/passwd" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) >/dev/null 2>"$tv_err"
assert "TC-24 traversal パスは exit 1" "1" "$?"
assert_grep "TC-24 traversal は専用の理由を出す" "$tv_err" 'パストラバーサル遮断'
assert_grep "TC-24 traversal 診断が違反行を出す (定数 1 でない)" "$tv_err" '検出行: \.rite/wiki/pages/\.\./'

# 読出失敗 / 検出失敗の WARNING は、cycle 4 security 指摘が要求した観測性そのもの。
rd_err="$SBX/rd.err"; tmp_files+=("$rd_err")
printf '%s\n' ".rite/wiki/pages/anti-patterns/missing.md" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) >/dev/null 2>"$rd_err"
assert_grep "TC-24 読出失敗が WARNING で観測できる" "$rd_err" 'の読出に失敗しました'
assert_not_grep "TC-24 読出失敗を検出失敗と取り違えない" "$rd_err" '検出 awk が失敗'

# E1 のブロック終端: `sources:` の後ろに来るキーが走査対象へ戻ること。
tc8_after=$(printf -- '---\nsources:\n  - ref: "raw/reviews/x.md"\nnote: "PR #1301 の経緯"\n---\n\n# t\n\n本文に番号なし\n')
assert "TC-24 sources ブロックの後ろのキーは走査対象へ戻る" "1" "$(single_hits "$tc8_after")"

# ---- TC-25..TC-46: index.md 走査 (AC-1..AC-6) ------------------------------
# 既存 TC はすべて index.md を持たない sandbox で走るため、そのままでは新経路を 1 行も通らない。
# index.md を持つ専用 sandbox を立て、対象列・除外・不在時の縮退・gate の非回帰を測る。
IDXSBX=$(make_plain_sandbox) && cleanup_dirs+=("$IDXSBX") || { echo "ERROR: make_plain_sandbox failed" >&2; exit 1; }
mkdir -p "$IDXSBX/.rite/wiki/pages/patterns"
IDX_PAGE_REL=".rite/wiki/pages/patterns/p.md"
printf '# p\n\nPR #1300 は本文側の 1 件\n' > "$IDXSBX/$IDX_PAGE_REL"

idx_run() { ( cd "$IDXSBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$IDXSBX" "$@" ); }
idx_hits() { printf '%s' "$1" | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p'; }

# T-06 / T-08: index.md 不在時は従来どおり。read_errors を増やさず、stdout に index 行も出さない。
# 走査対象へ入れる前に存在を確かめないと、不在 (Wiki 初期化直後の legitimate な状態) が
# 読出失敗と同じ非ゼロ rc に潰れ、TC-10 の「空 pages_list → read_ok=true」まで io_error に倒れる。
noidx_out="$IDXSBX/noidx.out"; tmp_files+=("$noidx_out")
printf '%s\n' "$IDX_PAGE_REL" | idx_run > "$noidx_out" 2>/dev/null
assert "TC-25 (#2069 T-06) index.md 不在で read_errors=0" "0" "$(sed -n 's/^descriptive_refs_read_errors=//p' "$noidx_out")"
assert "TC-25 (#2069 T-06) index.md 不在で read_ok=true" "true" "$(sed -n 's/^descriptive_refs_read_ok=//p' "$noidx_out")"
assert "TC-26 (T-08) index.md 不在なら本文のみの hits" "1" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$noidx_out")"
assert_not_grep "TC-26 (T-08) index.md 不在なら marker block に index 行が出ない" "$noidx_out" 'index\.md'

# T-01 / T-02 / T-03: テーブル形式。サマリー列だけを対象にし、リンクテキスト列は対象外。
# 3-4 行目はリンクテキスト内の素のパイプ / サマリー内のエスケープ済みパイプで、awk の
# 2 種のマスク (リンクスパン / `\|`) に識別力を持たせる fixture。どちらのマスクを外しても
# 列数が合わなくなり hits が減って skipped_rows が立つ
cat > "$IDXSBX/.rite/wiki/index.md" <<'IDXEOF'
# Wiki Index

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [PR #77 の教訓](pages/patterns/a.md) | patterns | 番号を持たない説明文 | 2026-01-01 | high |
| [番号なし](pages/patterns/b.md) | patterns | Issue #88 系譜の継続 | 2026-01-01 | high |
| [grep -c || echo 0 の罠](pages/patterns/c.md) | patterns | 詳細は #1151 | 2026-01-01 | high |
| [番号なし](pages/patterns/d.md) | patterns | 詳細は #1152 \| 補足あり | 2026-01-01 | high |
IDXEOF
tbl_out="$IDXSBX/tbl.out"; tmp_files+=("$tbl_out")
printf '%s\n' "$IDX_PAGE_REL" | idx_run > "$tbl_out" 2>/dev/null
assert "TC-27 (T-01) index.md の hits が合計に載る (本文 1 + index 3)" "4" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$tbl_out")"
assert_grep "TC-27 (T-01) marker block に page=.rite/wiki/index.md 行が出る" "$tbl_out" '^page=\.rite/wiki/index\.md; hits=3$'
assert "TC-27 (T-01) descriptive_refs_pages は hits を持つ対象ファイル数のまま" "2" "$(sed -n 's/^descriptive_refs_pages=//p' "$tbl_out")"
# TC-28/29 は同じ 2 行の表で「拾う列」と「拾わない列」を同時に測る。片方だけの fixture だと
# 「全列を走査している」変異と「サマリー列だけ走査している」実装を区別できない。
assert "TC-28 (T-03) サマリー列の番号を数える (通常 1 + 素パイプ行 1 + エスケープ行 1)" "3" "$(sed -n 's/^page=\.rite\/wiki\/index\.md; hits=//p' "$tbl_out")"
# マスクが効いていれば列崩れは 0 件。どちらかを外すと該当行が skip されて値が立つ
assert "TC-28 2 種のマスクが効いて列崩れ 0 件" "0" "$(sed -n 's/^descriptive_refs_skipped_rows=//p' "$tbl_out")"
onlylink=$(printf '# Wiki Index\n\n| ページ | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [PR #77 の教訓](pages/patterns/a.md) | patterns | 番号を持たない説明文 | 2026-01-01 | high |\n')
printf '%s' "$onlylink" > "$IDXSBX/.rite/wiki/index.md"
assert "TC-29 (T-02) リンクテキスト列のみの番号は hits に数えない" "1" "$(idx_hits "$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>/dev/null)")"

# OKF 箇条書き形式。箇条書きテンプレートが配布されていた期間に初期化された bundle の index.md は
# 箇条書きのまま残り移行を促す producer もいないため、テーブル専用にするとそれらの bundle で
# 検出が無言で 0 件へ倒れる (本 helper が塞ごうとしている盲点と同型)。
#
# fixture の「意地悪さ」をテーブル経路と揃える。テーブル側は生パイプ入りタイトル (TC-27) と
# コードスパン入りサマリー (TC-50) でマスク相互作用を pin しているのに、箇条書き側が素朴な形しか
# 持たないと以下 2 つの変異が全 assertion 緑のまま生き残る:
#   3 行目 (サマリーに生パイプ): 形式 dispatch の行頭 anchor を外す変異。anchor が無いと
#     「パイプを含む行」= テーブル行と誤判定され、ヘッダー不在で skipped へ倒れる (hits が無言で減る)
#   4 行目 (リンクテキストにコードスパン): summary 抽出の match をマスク前の行へ向ける変異。
#     マスクで行長が縮むため RSTART がずれ、substr の切り出し位置が後ろへ飛んで番号を取り落とす
printf '# Wiki Index\n\n* [Issue #99 を含むタイトル](pages/patterns/a.md) - 番号を持たない説明文\n* [番号なし](pages/patterns/b.md) - 詳細は #1151\n* [番号なし2](pages/patterns/c.md) - 詳細は #1234 | 補足あり\n* [`grep -c` の罠](pages/patterns/d.md) - 詳細は #1789\n' > "$IDXSBX/.rite/wiki/index.md"
bul_out="$IDXSBX/bul.out"; tmp_files+=("$bul_out")
printf '%s\n' "$IDX_PAGE_REL" | idx_run > "$bul_out" 2>/dev/null
assert "TC-30 OKF 箇条書き形式でもサマリーだけを検出する" "3" "$(sed -n 's/^page=\.rite\/wiki\/index\.md; hits=//p' "$bul_out")"
assert "TC-30 箇条書きは生パイプを含む行でもテーブル扱いにならない (列崩れ 0 件)" "0" "$(sed -n 's/^descriptive_refs_skipped_rows=//p' "$bul_out")"

# 形式判別は **行単位** で行う (ファイル単位で先頭一致から決め打ちしない)。ingest はテーブル行を
# 追記するが節の外の旧箇条書き行を削除も移送もしないため、箇条書きのまま残る bundle では
# 1 ファイル内に両形式が混在する。単一形式の fixture しか無いと、判別をファイル単位へ
# 寄せる変異が全 assertion 緑のまま生き残る。表 1 行 + 箇条書き 1 行を同居させ、両方の
# サマリーが数えられること (合計 = 本文 1 + index 2) を pin する。箇条書き側はリンクテキストにも
# 番号を置き、混在時も AC-2 (リンクテキスト列は対象外) が保たれることを同時に測る。
cat > "$IDXSBX/.rite/wiki/index.md" <<'IDXEOF'
# Wiki Index

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|---|---|---|---|---|
| [番号なし](pages/patterns/a.md) | patterns | 詳細は #1151 | 2026-01-01 | high |

* [PR #77 のタイトル](pages/patterns/b.md) - Issue #88 系譜の継続
IDXEOF
mix_out="$IDXSBX/mix.out"; tmp_files+=("$mix_out")
printf '%s\n' "$IDX_PAGE_REL" | idx_run > "$mix_out" 2>/dev/null
assert "TC-49 表と箇条書きが混在しても両形式のサマリーを数える (本文 1 + index 2)" "3" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$mix_out")"
assert "TC-49 混在 index.md の hits は表 1 + 箇条書き 1 (リンクテキストの番号は非計上)" "2" "$(sed -n 's/^page=\.rite\/wiki\/index\.md; hits=//p' "$mix_out")"
assert "TC-49 混在形式でも列崩れ扱いにならない" "0" "$(sed -n 's/^descriptive_refs_skipped_rows=//p' "$mix_out")"

# T-07: 列数が壊れた行は「行全体を対象にする」のではなくスキップし、行番号つき WARNING を出す。
# 行全体へフォールバックするとリンクテキスト由来の番号が混ざり、誤検出で件数が膨らむ。
# ズレた位置 (4 列目 = 通常はサマリー列) に番号を置く: 「行全体へフォールバックする変異」と
# 「黙って違う列を読む変異」の両方を 1 本の fixture で弾く
printf '# Wiki Index\n\n| ページ | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [番号なし](pages/patterns/a.md) | patterns | 番号なし | 詳細は #1151 |\n' > "$IDXSBX/.rite/wiki/index.md"
brk_err="$IDXSBX/brk.err"; tmp_files+=("$brk_err")
brk_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>"$brk_err")
assert "TC-31 (#2069 T-07) 列数が壊れた行は hits に数えない" "1" "$(idx_hits "$brk_out")"
assert_grep "TC-31 (#2069 T-07) 列崩れは行番号つき WARNING で観測できる" "$brk_err" 'index\.md [0-9]+ 行目: テーブルの列数'
# T-07 の「列数が壊れた行」は両方向。上の fixture は列数 < ヘッダー だけなので、判定を
# `fn != sumncol` から `fn < sumncol` へ緩める変異が生き残る。over-column 方向 (サマリー本文に
# コードスパンで包まない生パイプがある行) を 1 本足して方向を分離する。緩めた実装ではこの行が
# skip されずヘッダー由来の位置で別列を黙って読み、skipped_rows が 1 → 0 に落ちて WARNING も消える。
printf '# Wiki Index\n\n| ページ | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [番号なし](pages/patterns/a.md) | patterns | 生パイプ | 二本 | を含む 詳細は #1151 | 2026-01-01 | high |\n' > "$IDXSBX/.rite/wiki/index.md"
over_err="$IDXSBX/over.err"; tmp_files+=("$over_err")
over_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>"$over_err")
assert "TC-31 (#2069 T-07) 列数がヘッダーより多い行も skip する (over-column 方向)" "1" "$(printf '%s' "$over_out" | sed -n 's/^descriptive_refs_skipped_rows=//p')"
assert_grep "TC-31 (#2069 T-07) over-column も列数つき WARNING で観測できる" "$over_err" '列数=7, ヘッダー=5'

# 欠損ガード: エントリ行はあるのに抽出できない行がある = 形式変更。無言の過少集計にせず
# WARNING + stdout の descriptive_refs_skipped_rows で surface する
# (`/rite:wiki-query positional-parse-row-count-guard`)。
# 発火条件を「全行 skip」にしないのは、`parsed == 0` では「形式 drift」と「まだ登録が無い
# カタログ」を区別できないから (前文はリンク行を持たないため、テンプレ前文だけの
# index も parsed == 0 になる)。**一部行のみ失敗**する fixture で pin し、ガードを
# `parsed == 0` へ弱める変異を kill できるようにする。
printf '# Wiki Index\n\n| ページ | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [a](pages/patterns/a.md) | x |\n| [b](pages/patterns/b.md) | patterns | 詳細は #1151 | 2026-01-01 | high |\n' > "$IDXSBX/.rite/wiki/index.md"
guard_err="$IDXSBX/guard.err"; tmp_files+=("$guard_err")
guard_out="$IDXSBX/guard.out"; tmp_files+=("$guard_out")
printf '%s\n' "$IDX_PAGE_REL" | idx_run > "$guard_out" 2>"$guard_err"
assert_grep "TC-32 一部行のみ抽出失敗でも欠損ガードが WARNING を出す" "$guard_err" 'からサマリーを抽出できませんでした'
# 分母が「エントリ行数」であることまで pin する (NR 等へ化ける変異を kill)
assert_grep "TC-32 欠損ガードの分母が実エントリ数" "$guard_err" 'エントリ行 2 件中 1 件'
assert "TC-32 欠損行数が stdout に載る (stderr だけに閉じない)" "1" "$(sed -n 's/^descriptive_refs_skipped_rows=//p' "$guard_out")"
assert "TC-32 抽出できた行の hits は残る (本文 1 + index 1)" "2" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$guard_out")"
assert "TC-32 行単位の欠損は read_errors (ファイル単位) に混ぜない" "0" "$(sed -n 's/^descriptive_refs_read_errors=//p' "$guard_out")"

# T-04 / T-05: gate の非回帰。index.md を完全一致で許容しても raw/ と `..` は fail-fast のまま。
# prefix (`.rite/wiki/*`) へ緩めると raw_list 取り違えの検出という gate 本来の目的が消える。
printf '# Wiki Index\n\n* [t](pages/patterns/a.md) - 詳細は #1151\n' > "$IDXSBX/.rite/wiki/index.md"
printf '%s\n%s\n' "$IDX_PAGE_REL" ".rite/wiki/raw/reviews/x.md" | idx_run >/dev/null 2>&1
assert "TC-33 (T-04) index.md 許容後も raw/ 行の混入は exit 1" "1" "$?"
printf '%s\n' ".rite/wiki/pages/../raw/x.md" | idx_run >/dev/null 2>&1
assert "TC-33 (T-05) index.md 許容後も traversal は exit 1" "1" "$?"
# stdin 経由の index.md は受理し、自力発見分と二重計上しない。
stdin_out=$(printf '%s\n%s\n' "$IDX_PAGE_REL" ".rite/wiki/index.md" | idx_run 2>/dev/null); stdin_rc=$?
assert "TC-34 stdin の index.md は gate を通る" "0" "$stdin_rc"
# 期待値は絶対値に固定する (両辺をライブ実行から取ると index 走査が 0 に潰れる変異で両辺 1 になり緑のまま通る)
assert "TC-34 stdin 経由でも二重計上しない (本文 1 + index 1)" "2" "$(idx_hits "$stdin_out")"

# ---- TC-36: separate_branch (本番既定経路) の index.md 走査 ------------------
# TC-25..TC-35 は全て same_branch (cat) で、既存 GITSBX には index.md が無い。よって
# git cat-file -e の存在プローブと git show 経由の index 読出が 1 行も実行されていなかった
# (存在プローブを index_present=no 固定に変異させても全 TC が緑のまま通ることを実測済)。
# 既存 `wiki` ブランチは index なしのまま残す (TC-19 の等値 assert が壊れるため)。
if (
  cd "${GITSBX:?GITSBX unset}" || exit 1
  # fixture を自分で置き直す: TC-19 が意図的に rm し TC-19b が診断目的で cp し戻す副作用へ
  # 暗黙依存すると、TC-19b を触っただけで TC-36 が原因の読めない形で落ちる
  cp "$SBX/$FIXTURE_REL" ".rite/wiki/pages/anti-patterns/fixture.md" || exit 1
  printf '# Wiki Index\n\n| ページ | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [番号なし](pages/patterns/x.md) | patterns | 詳細は #1151 | 2026-01-01 | high |\n' > .rite/wiki/index.md
  git add -A || exit 1
  git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t commit -qm index || exit 1
  git branch -q wiki-with-index || exit 1
  rm -f .rite/wiki/index.md
) 2>"${git_err:-/dev/null}"; then
  wi_out="$GITSBX/wi.out"; tmp_files+=("$wi_out")
  printf '%s\n' "$FIXTURE_REL" | ( cd "$GITSBX" && bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch wiki-with-index --repo-root "$GITSBX" ) > "$wi_out" 2>/dev/null
  assert "TC-36 separate_branch で index.md の hits が合計に載る (本文 $hits + index 1)" "$((hits + 1))" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$wi_out")"
  assert_grep "TC-36 separate_branch でも marker block に page=.rite/wiki/index.md" "$wi_out" '^page=\.rite/wiki/index\.md; hits=1$'
  # 準備失敗を「合計が合わない」ではなく「読出に失敗した」として localize する
  assert "TC-36 separate_branch で read_errors=0 (準備失敗の localize)" "0" "$(sed -n 's/^descriptive_refs_read_errors=//p' "$wi_out")"
else
  git_rc=$?
  fail "TC-36 git sandbox (wiki-with-index) の準備に失敗 (rc=$git_rc)"
  [ -n "$git_err" ] && [ -s "$git_err" ] && head -5 "$git_err" | sed 's/^/    /' >&2
fi

# ---- TC-37: サマリー列の位置をヘッダーから決めていること ---------------------
# 既存 fixture は全て `サマリー` が 4 番目 = ハードコード fallback (col=4) と同値のため、
# 位置決めをヘッダー由来から固定値へ変異させても検出できなかった。列を 1 本増やして pin する。
printf '# Wiki Index\n\n| ページ | 種別 | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|---|\n| [番号なし](pages/patterns/a.md) | heuristic | patterns | 詳細は #1151 | 2026-01-01 | high |\n' > "$IDXSBX/.rite/wiki/index.md"
hdr_err="$IDXSBX/hdr.err"; tmp_files+=("$hdr_err")
hdr_out="$IDXSBX/hdr.out"; tmp_files+=("$hdr_out")
printf '' | idx_run > "$hdr_out" 2>"$hdr_err"
assert "TC-37 6 列テーブルでもヘッダー由来の列位置でサマリーを拾う" "1" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$hdr_out")"
assert "TC-37 6 列テーブルで skipped_rows=0 (列崩れ扱いしない)" "0" "$(sed -n 's/^descriptive_refs_skipped_rows=//p' "$hdr_out")"
assert_not_grep "TC-37 6 列テーブルで列崩れ WARNING を出さない" "$hdr_err" 'index\.md [0-9]+ 行目: テーブルの列数'

# ---- TC-38: index.md が存在するのに読めない場合は read_errors に計上する -----
# 存在プローブを読出より前に置く設計判断 (不在 = 静かに落とす / 読出失敗 = read_errors) の
# 後者だけがテストされていなかった。プローブを `[ -f ] && [ -r ]` へ変異させても緑のまま通る。
printf '# Wiki Index\n\n* [t](pages/patterns/a.md) - 詳細は #1151\n' > "$IDXSBX/.rite/wiki/index.md"
if [ "$(id -u)" -eq 0 ]; then
  skip "TC-38 (root では chmod 000 が read を阻めないため測定不能)"
else
  chmod 000 "$IDXSBX/.rite/wiki/index.md"
  unread_out="$IDXSBX/unread.out"; tmp_files+=("$unread_out")
  unread_err="$IDXSBX/unread.err"; tmp_files+=("$unread_err")
  printf '%s\n' "$IDX_PAGE_REL" | idx_run > "$unread_out" 2>"$unread_err"
  chmod 644 "$IDXSBX/.rite/wiki/index.md"
  assert "TC-38 読めない index.md は read_errors に計上する" "1" "$(sed -n 's/^descriptive_refs_read_errors=//p' "$unread_out")"
  assert "TC-38 部分失敗のため read_ok=true は維持" "true" "$(sed -n 's/^descriptive_refs_read_ok=//p' "$unread_out")"
  assert "TC-38 本文分の hits は残る" "1" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$unread_out")"
  assert_grep "TC-38 読出失敗が WARNING で観測できる" "$unread_err" 'の読出に失敗しました'
fi

# ---- TC-39: サマリー列ヘッダーを検出できない場合の縮退 ----------------------
# 見出し語が `サマリー` から drift すると列位置が確定できない。既定列を当てずっぽうで読むと
# 「別列を黙って走査して hits が 0 になる」無言の縮退になるため、スキップして surface する。
printf '# Wiki Index\n\n| ページ | ドメイン | 説明 | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [t](pages/patterns/a.md) | patterns | 詳細は #1151 | 2026-01-01 | high |\n' > "$IDXSBX/.rite/wiki/index.md"
hdrfb_out="$IDXSBX/hdrfb.out"; tmp_files+=("$hdrfb_out")
hdrfb_err="$IDXSBX/hdrfb.err"; tmp_files+=("$hdrfb_err")
printf '' | idx_run > "$hdrfb_out" 2>"$hdrfb_err"
assert "TC-39 ヘッダー不検出のテーブル行は別列を当てずっぽうで読まない" "0" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$hdrfb_out")"
assert "TC-39 スキップは skipped_rows として surface される (無言の縮退にしない)" "1" "$(sed -n 's/^descriptive_refs_skipped_rows=//p' "$hdrfb_out")"
assert_grep "TC-39 ヘッダー不検出を WARNING で明示する" "$hdrfb_err" 'サマリー列ヘッダーを検出できない'
# 箇条書き形式は列を持たないためヘッダー不在の影響を受けない
printf '# Wiki Index\n\n* [t](pages/patterns/a.md) - 詳細は #1151\n' > "$IDXSBX/.rite/wiki/index.md"
hdrbul_out="$IDXSBX/hdrbul.out"; tmp_files+=("$hdrbul_out")
printf '' | idx_run > "$hdrbul_out" 2>/dev/null
assert "TC-39 箇条書きはヘッダー不在でも従来どおり拾う" "1" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$hdrbul_out")"

# ---- TC-40: `./pages/` / `../pages/` 形式のエントリも拾う ---------------------
# 同じ index.md を読む wiki-lint-orphans.sh は相対形式に対応済み。本 helper だけが
# bare `pages/` に限ると、その形式の index で本 helper だけが無言で 0 件へ倒れる。
printf '# Wiki Index\n\n* [A](./pages/patterns/a.md) - 詳細は #1151\n* [B](../pages/patterns/b.md) - 詳細は #1152\n' > "$IDXSBX/.rite/wiki/index.md"
rel_out="$IDXSBX/rel.out"; tmp_files+=("$rel_out")
printf '' | idx_run > "$rel_out" 2>/dev/null
assert "TC-40 ./pages/ と ../pages/ 形式のエントリを拾う (orphans.sh と同一定義)" "2" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$rel_out")"

# ---- TC-41: 壊れた wiki ref は「index.md 不在」に畳まない ---------------------
# git cat-file -e は「ref が無い」と「ref 内に path が無い」をどちらも rc=128 で返す。
# 畳むと壊れた ref が静かな 0 件になり、pages_list が空だと stderr すら出ない。
badref_out="$IDXSBX/badref.out"; tmp_files+=("$badref_out")
badref_err="$IDXSBX/badref.err"; tmp_files+=("$badref_err")
printf '' | ( cd "$IDXSBX" && bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch no-such-branch-xyz --repo-root "$IDXSBX" ) > "$badref_out" 2>"$badref_err"
assert "TC-41 壊れた wiki ref は io_error に倒れる (静かな 0 件にしない)" "io_error" "$(sed -n 's/^descriptive_refs_read_ok=//p' "$badref_out")"
assert "TC-41 壊れた wiki ref は read_errors に計上される" "1" "$(sed -n 's/^descriptive_refs_read_errors=//p' "$badref_out")"
assert_grep "TC-41 ref 解決失敗を WARNING で明示する" "$badref_err" 'wiki ブランチ ref .* を解決できません'

# ---- TC-42: ヘッダー判定がエントリ行を飲み込まない ---------------------------
# ヘッダー語が drift した表で、あるデータ行のサマリー本文に「サマリー」の語が含まれると、
# その行自身がヘッダーとして消費され hits にも skipped_rows にも計上されず WARNING も出ない
# (TC-39 が守るはずの契約が破れるのに全 TC が緑になる経路)。
printf '# Wiki Index\n\n| ページ | ドメイン | 説明 | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [a](pages/patterns/a.md) | patterns | サマリーの書き方は 詳細は #1151 | 2026-01-01 | high |\n| [b](pages/patterns/b.md) | patterns | 詳細は #1152 | 2026-01-01 | high |\n' > "$IDXSBX/.rite/wiki/index.md"
hdreat_out="$IDXSBX/hdreat.out"; tmp_files+=("$hdreat_out")
printf '' | idx_run > "$hdreat_out" 2>/dev/null
assert "TC-42 エントリ行はヘッダーとして消費されない (2 行とも skip される)" "2" "$(sed -n 's/^descriptive_refs_skipped_rows=//p' "$hdreat_out")"
assert "TC-42 skip した行から hit を拾わない" "0" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$hdreat_out")"

# ---- TC-43: E5 (TODO/FIXME) の欠落が skipped_rows に載る ---------------------
# 本文フィルタ段で TODO 行を落とすと、index.md ではエントリ行が entries にも skipped にも
# 計上されないまま消え、新設した skipped_rows が構造的に観測できない唯一の穴になる。
# コードスパン内に引用された TODO は E4 のマスクで無効化されるため hit として残る (下の 2 行目)。
printf '# Wiki Index\n\n* [a](pages/patterns/a.md) - TODO: 詳細は #1151\n* [b](pages/patterns/b.md) - `TODO` を引用しただけ 詳細は #1152\n' > "$IDXSBX/.rite/wiki/index.md"
e5_out="$IDXSBX/e5.out"; tmp_files+=("$e5_out")
printf '' | idx_run > "$e5_out" 2>/dev/null
# E5 は意図的除外 (前方追跡ポインタの維持) であって抽出失敗ではないため skipped_rows には載せない。
# entries には計上されるので END の分母には含まれる
assert "TC-43 E5 は意図的除外なので skipped_rows (抽出失敗) に載せない" "0" "$(sed -n 's/^descriptive_refs_skipped_rows=//p' "$e5_out")"
assert "TC-43 コードスパン内に引用された TODO は E4 で無効化され hit として残る" "1" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$e5_out")"
# pages 側は E5 を行単位 (マスク前) で判定するため同じテキストでも行ごと落ちる。
# 非対称は意図であり、両経路の判定順序を揃える変更が無検出で通らないよう pin する
assert "TC-43 pages 側はコードスパン内 TODO でも行ごと落とす (index と非対称)" "0" "$(single_hits "$(printf '\140TODO\140 の扱いは 詳細は #1152\n')")"

# index 側の E5 判定単位が「エントリのサマリー」であることを pin する (helper の `summary ~ /TODO/`)。
# 上の 2 行目 fixture は TODO がサマリー内にあるため、判定対象を行全体へ揃える変異でも同じ結果に
# なり単位の違いが現れない。リンクテキスト側にだけ TODO を置くと、行全体判定では hit が消え
# サマリー判定では残る — かつ消えても entries には計上済みで skipped_rows も WARNING も立たない
# ため、本 PR が塞ごうとしている無言の過少集計そのものになる。
printf '# Wiki Index\n\n* [TODO 管理の教訓](pages/patterns/a.md) - 詳細は #1151\n' > "$IDXSBX/.rite/wiki/index.md"
e5unit_out="$IDXSBX/e5unit.out"; tmp_files+=("$e5unit_out")
printf '' | idx_run > "$e5unit_out" 2>/dev/null
assert "TC-43 index 側の E5 はサマリー単位で判定する (リンクテキストの TODO で行を落とさない)" "1" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$e5unit_out")"
assert "TC-43 リンクテキスト TODO の行は抽出失敗でもない (skipped_rows 0)" "0" "$(sed -n 's/^descriptive_refs_skipped_rows=//p' "$e5unit_out")"

# index 側の E4 マスクが「削除ではなく `_` 置換」であることを pin する (ページ側 TC-4 と対称)。
# 削除するとキーワードと番号が隣接し、R1 が許容する空白 2 個以内に収まって**誤検出を製造する**。
printf '# Wiki Index\n\n* [t](pages/patterns/a.md) - PR `x` #1234 で導入\n' > "$IDXSBX/.rite/wiki/index.md"
e4mask_out="$IDXSBX/e4mask.out"; tmp_files+=("$e4mask_out")
printf '' | idx_run > "$e4mask_out" 2>/dev/null
assert "TC-43 index 側の span マスクがキーワードと番号を連結しない" "0" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$e4mask_out")"

# ---- TC-44: 診断に外部入力の制御文字を素通ししない --------------------------
# ref 解決失敗 WARNING は外部入力 (--wiki-branch) を埋め込む。中和しないと
# rite-config.yml の wiki.branch_name に置かれた ESC が operator 端末へそのまま届く。
esc_err="$IDXSBX/esc.err"; tmp_files+=("$esc_err")
printf '' | ( cd "$IDXSBX" && bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch "$(printf 'bad\033[2Kbranch')" --repo-root "$IDXSBX" ) >/dev/null 2>"$esc_err"
assert_not_grep "TC-44 診断に生の ESC を素通ししない" "$esc_err" "$(printf '\033')"
assert_grep "TC-44 中和後も ref 解決失敗は WARNING で観測できる" "$esc_err" 'wiki ブランチ ref .* を解決できません'

# ---- TC-45: 除外規則 (本文フィルタ) が index.md にも適用される -------------
# TC-25..TC-44 の index fixture はどれも frontmatter / コードフェンス / `## ソース` 節を
# 持たないため、index 経路から本文フィルタを外す変異が全 assert を素通りしていた。
printf '# Wiki Index\n\n```\n* [例](pages/patterns/x.md) - 詳細は #9999\n```\n\n* [t](pages/patterns/a.md) - 番号なし\n' > "$IDXSBX/.rite/wiki/index.md"
fence_out="$IDXSBX/fence.out"; tmp_files+=("$fence_out")
printf '' | idx_run > "$fence_out" 2>/dev/null
assert "TC-45 コードフェンス内のエントリ記法例は hit に数えない (E3 が index にも適用される)" "0" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$fence_out")"
assert "TC-45 フェンス内行はエントリ判定に到達しないため skipped_rows にも載らない" "0" "$(sed -n 's/^descriptive_refs_skipped_rows=//p' "$fence_out")"

# ---- TC-46: index.md が読める限り pages 全件失敗でも io_error にしない ------
# index.md が走査母数に入ったことで io_error (全対象ファイル読出失敗) の発火条件が変わった。
# 本番構成では wiki-init が index.md を無条件生成するため、この形状が既定になる。
printf '# Wiki Index\n\n* [t](pages/patterns/a.md) - 詳細は #1151\n' > "$IDXSBX/.rite/wiki/index.md"
allfail_out="$IDXSBX/allfail.out"; tmp_files+=("$allfail_out")
printf '%s\n%s\n' ".rite/wiki/pages/patterns/gone1.md" ".rite/wiki/pages/patterns/gone2.md" | idx_run > "$allfail_out" 2>/dev/null
assert "TC-46 index.md が読めれば pages 全件失敗でも read_ok=true (部分失敗)" "true" "$(sed -n 's/^descriptive_refs_read_ok=//p' "$allfail_out")"
assert "TC-46 失敗した pages は read_errors に計上される" "2" "$(sed -n 's/^descriptive_refs_read_errors=//p' "$allfail_out")"
assert "TC-46 index.md 分の hits は残る" "1" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$allfail_out")"

# T-09: 他カテゴリの非回帰は測定ではなく構成で担保する。ステップ 2.2 の pages_list は
# `pages/` 配下だけを拾ったままでなければならない。ここに index.md を混ぜると孤児検出
# (pages_list ∖ index 登録ページ) が index.md 自身を未登録の孤児として数え、AC-6 が即座に崩れる。
# pages_list は branch_strategy ごとに **2 経路** で組み立てられる (separate_branch は git
# ls-tree + grep、same_branch は find)。片方だけを pin すると、pin していない側に index.md を
# 混ぜる変異が緑のまま通り、構成による担保という前提そのものが崩れる。両経路を独立に検査する。
step22_re=$(grep -oE "grep -E '\^\\\\\.rite/wiki/pages/[^']*'" "$LINT_MD" | head -1)
if [ -z "$step22_re" ]; then
  fail "TC-35 (T-09) SKILL.md ステップ 2.2 separate_branch の pages_list 抽出 regex を特定できなかった"
elif printf '%s' "$step22_re" | grep -q 'index'; then
  fail "TC-35 (T-09) separate_branch の pages_list に index.md が混ざっている (孤児 / 陳腐化の件数が変わる)"
else
  pass "TC-35 (T-09) separate_branch の pages_list は pages/ 配下のみ (他カテゴリの入力が不変)"
fi

# same_branch 側 (find 経路)。探索根が `pages/` より上へ広がる変異も、抽出が
# `find .rite/wiki/pages` に anchor しているため空抽出として弾かれる。
step22_find=$(grep -oE 'pages_list=\$\(find [^)]*' "$LINT_MD" | head -1)
if [ -z "$step22_find" ]; then
  fail "TC-35 (T-09) SKILL.md ステップ 2.2 same_branch の pages_list find 式を特定できなかった"
elif printf '%s' "$step22_find" | grep -q 'index'; then
  fail "TC-35 (T-09) same_branch の pages_list に index.md が混ざっている (孤児 / 陳腐化の件数が変わる)"
elif ! printf '%s' "$step22_find" | grep -q '\.rite/wiki/pages'; then
  fail "TC-35 (T-09) same_branch の pages_list の探索根が pages/ 配下ではない (他カテゴリの入力が変わる)"
else
  pass "TC-35 (T-09) same_branch の pages_list は pages/ 配下のみ (他カテゴリの入力が不変)"
fi

# ---- TC-22: 2 検出器の検出 regex が literal 一致すること -------------------
# 同じ規則を 2 実装に持つため、語彙を 1 語足すたび両方の同期が要る。実装の共通化は
# しない (読出元も計数単位も違う) 代わりに、literal のバイト一致を pin して drift を検出する。
CJC="$PLUGIN_ROOT/hooks/scripts/comment-journal-check.sh"
# 語彙の alternation (`[Ii]ssues?|…|[Rr]esolves`) だけを両ファイルから抜き、一致を見る。
# regex 全体を突き合わせるとエスケープが複雑になり、抽出側の破損と drift を混同しやすい。
# 語彙 alternation だけを抜くと両端 (先頭への挿入・末尾への追記) の drift を取り逃がす。
# R1 全体 (左境界 + 語彙 + 番号規則 + 右境界) を 1 単位として比較する。
# コメント行を落としてから抽出する。ヘッダコメントは語彙を `…` で省略した同形を持つため、
# 素で grep すると 2 ファイルの**コメント同士**を比較して drift を 1 クラスも検出しなくなる。
vocab_of() { grep -v '^[[:space:]]*#' "$1" | grep -oE '\(\^\|\[\^A-Za-z\]\)\([^)]*\) \*#\[0-9\]\+\(\[\^0-9\]\|\$\)' | head -1; }
helper_vocab=$(vocab_of "$SCRIPT")
cjc_vocab=$(vocab_of "$CJC")
if [ -z "$helper_vocab" ]; then
  fail "TC-22 helper から R1 regex を抽出できなかった (実装構造が変わった可能性)"
elif [ -z "$cjc_vocab" ]; then
  fail "TC-22 comment-journal-check.sh から R1 regex を抽出できなかった"
elif [ "$helper_vocab" = "$cjc_vocab" ]; then
  pass "TC-22 2 検出器の R1 regex が一致 (drift なし)"
else
  fail "TC-22 2 検出器の R1 regex が drift している
    helper: $helper_vocab
    cjc   : $cjc_vocab"
fi

# ---- TC-52: index.md のリンク regex が orphans.sh と literal 一致すること ----
# helper のコメントが「`wiki-lint-orphans.sh` と同一定義にする」と宣言している共有 regex を
# TC-22 と同型に pin する。TC-40 は本 helper 側で `./pages/` / `../pages/` を拾えることしか
# 測らないため、広げる方向 (例: `(wiki\/)?` セグメント追加) と orphans.sh 側の drift を
# 1 件も検出しない。片側だけ drift すると entries が部分的にしか減らず entries>=1 が保たれ、
# 検出失敗ガード (entries==0 && linkrows>0) も skipped_rows も発火しないまま hits が
# 無言で過少集計になる — 本 helper が塞ぐ silent-0 と同型。
# 正規化: 本 helper の regex は awk プログラム内リテラルのため `pages\/`、orphans.sh は
# grep -oE のため `pages/` と表記が違う。バイト比較の前に `\/` を `/` へ畳む。
ORPHANS="$PLUGIN_ROOT/hooks/scripts/wiki-lint-orphans.sh"
linkre_of() {
  grep -v '^[[:space:]]*#' "$1" \
    | grep -oE '\(\\\.\{0,2\}\\/\?pages\\?/\[\^\)\]\+\)' \
    | head -1 \
    | sed 's|\\/|/|g'
}
helper_linkre=$(linkre_of "$SCRIPT")
orphans_linkre=$(linkre_of "$ORPHANS")
if [ -z "$helper_linkre" ]; then
  fail "TC-52 helper からリンク regex を抽出できなかった (共有 regex の形状が変わった可能性)"
elif [ -z "$orphans_linkre" ]; then
  fail "TC-52 wiki-lint-orphans.sh からリンク regex を抽出できなかった (共有 regex の形状が変わった可能性)"
elif [ "$helper_linkre" = "$orphans_linkre" ]; then
  pass "TC-52 index.md のリンク regex が orphans.sh と一致 (drift なし)"
else
  fail "TC-52 index.md のリンク regex が orphans.sh と drift している
    helper : $helper_linkre
    orphans: $orphans_linkre"
fi

# ---- TC-47: index.md を読めたのにエントリ行を 1 件も認識できない = 検出失敗 --
# skipped は「エントリと認識できた行の抽出失敗」しか数えないため、リンク形式が想定と
# 食い違うと entries=0 / skipped=0 / hits=0 になり、実測 230 hits 以上が丸ごと落ちても
# 「0 件 (実測済み)」として read_ok=true で通る。TC-25..TC-46 の index fixture は
# どれもフェンス外に最低 1 本の `](pages/...)` を含むため、この経路へ到達しなかった。
# fixture はリンク形状の行を持つがリンク先が pages/ と認識できない形 (`](../../pages/…)`) =
# 「形式 drift」。ガードの発火条件はこれであって、stdin (pages_list) の非空性ではない。
printf '# Wiki Index\n\n* [t](../../pages/patterns/a.md) - 詳細は #1151\n' > "$IDXSBX/.rite/wiki/index.md"
noent_err="$IDXSBX/noent.err"; tmp_files+=("$noent_err")
noent_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>"$noent_err")
assert "TC-47 リンク行はあるが entries 0 件なら検出失敗として read_errors に計上する" "1" "$(printf '%s' "$noent_out" | sed -n 's/^descriptive_refs_read_errors=//p')"
assert_grep "TC-47 検出失敗は WARNING で観測できる" "$noent_err" 'エントリ行を 1 件も認識できませんでした'
assert "TC-47 検出失敗した index.md 分は hits に混ぜない (本文側の 1 件のみ)" "1" "$(idx_hits "$noent_out")"

# 発火条件が index.md 自身の内容であることの pin (本 TC 群の核)。
# stdin が空でも同じ drift は同じく検出失敗になる — ステップ 2.2 は pages_list が空でも
# ステップ 7.5 を実行する契約なので、そこを条件にするとガードが必要な経路でだけ無効化される。
noent_nostdin_err="$IDXSBX/noent-nostdin.err"; tmp_files+=("$noent_nostdin_err")
noent_nostdin_out=$(printf '' | idx_run 2>"$noent_nostdin_err")
assert "TC-47 pages_list 空でも drift は検出失敗として計上する (stdin に依存しない)" "1" "$(printf '%s' "$noent_nostdin_out" | sed -n 's/^descriptive_refs_read_errors=//p')"
assert_grep "TC-47 pages_list 空でも WARNING は出る" "$noent_nostdin_err" 'エントリ行を 1 件も認識できませんでした'

# 否定側: リンク形状の行が 1 行も無い index は「まだ登録が無いカタログ」であって drift ではない。
# この 1 本が無いと「linkrows 条件の削除」(= 全ての空 index を検出失敗にする変異) が生き残る。
printf '# Wiki Index\n\nまだ登録がありません。方針は #1151 を参照。\n' > "$IDXSBX/.rite/wiki/index.md"
nolink_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>/dev/null)
assert "TC-47 リンク行が 0 なら検出失敗に計上しない (登録前のカタログは正当)" "0" "$(printf '%s' "$nolink_out" | sed -n 's/^descriptive_refs_read_errors=//p')"

# TC-50: 上の TC-47 fixture はどれも手書きの index で、`/rite:wiki-init` が配る
# index-template.md の**前文を持たない**。現行テンプレートの前文は記法例コメントを持たないが、
# 箇条書きテンプレートが配布されていた期間に初期化された bundle の index.md には箇条書きの記法例
# `* [ページタイトル](pages/{domain}/{slug}.md) - …` がコメント内に残っており、コメントを
# 落とさない実装ではその記法例が実エントリとして数えられ entries>=1 が恒久化して、それらの
# index.md では検出失敗ガードが**構造的に発火しなくなる**。TC-47 の fixture では通ってしまう
# 経路なので、配布テンプレートを実際にコピーした fixture で pin する (テンプレが変わっても
# 追随するよう literal 複製ではなく実ファイルを cp する)。記法例コメントを持つ形式そのものの
# pin は、現行テンプレートに記法例が無いため本 TC では担保できず literal fixture が別途要る。
cp "$PLUGIN_ROOT/templates/wiki/index-template.md" "$IDXSBX/.rite/wiki/index.md"
printf '\n* [A](../../pages/patterns/a.md) - 詳細は #1151\n' >> "$IDXSBX/.rite/wiki/index.md"
tmpl_err="$IDXSBX/tmpl.err"; tmp_files+=("$tmpl_err")
tmpl_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>"$tmpl_err")
assert "TC-50 template 前文つき index.md でも drift は検出失敗として計上する" "1" "$(printf '%s' "$tmpl_out" | sed -n 's/^descriptive_refs_read_errors=//p')"
assert_grep "TC-50 template 前文つきでも検出失敗 WARNING が出る" "$tmpl_err" 'エントリ行を 1 件も認識できませんでした'
# 前文だけ (エントリ 0 本) は「登録前のカタログ」であって drift ではない。記法例を entries に
# 数えない = linkrows にも数えない、の両方が効いていることをここで押さえる。
cp "$PLUGIN_ROOT/templates/wiki/index-template.md" "$IDXSBX/.rite/wiki/index.md"
tmpl_only_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>/dev/null)
assert "TC-50 template 前文のみ (未登録) は検出失敗に計上しない" "0" "$(printf '%s' "$tmpl_only_out" | sed -n 's/^descriptive_refs_read_errors=//p')"
assert "TC-50 配布テンプレート前文は hits に数えない (本文側の 1 件のみ)" "1" "$(idx_hits "$tmpl_only_out")"
# TC-50b: 上の cp fixture は「配布テンプレートが将来 entries を汚す形へ変わったら気づく」回帰検知で、
# **コメント除去規則そのものの pin ではない** — 現行テンプレートは記法例コメントを持たないため、
# 除去規則を殺す変異 (`in_comment` 分岐の `next` 落とし) が cp fixture では生き残る。規則の pin は
# 記法例コメントを持つ形式を literal で書いて担保する (箇条書きテンプレートが配布されていた期間に
# 初期化された bundle の index.md がこの形状で残る)。同型の pin を literal fixture で行う先例:
# hooks/tests/wiki-query-inject.test.sh TC-5。
printf '# Wiki Index\n\n<!-- 登録箇条書きの形式例（ingest が自動追記。このコメント行は登録ではない）:\n\n     * [ページタイトル](pages/{domain}/{slug}.md) - 詳細は #1151\n-->\n\n* [A](pages/patterns/a.md) - PR #792 の知見\n' > "$IDXSBX/.rite/wiki/index.md"
legacy_err="$IDXSBX/legacy.err"; tmp_files+=("$legacy_err")
legacy_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>"$legacy_err")
# 合計は本文 1 + index の実エントリ 1 = 2。除去規則を殺すとコメント内の記法例も数えて 3 になる。
assert "TC-50b 記法例コメント内のサマリーは hits に数えない (本文 1 + 実エントリ 1)" "2" "$(idx_hits "$legacy_out")"
assert "TC-50b 記法例コメントを持つ index でも検出失敗に計上しない (実エントリがある)" "0" "$(printf '%s' "$legacy_out" | sed -n 's/^descriptive_refs_read_errors=//p')"
# 逆方向の pin: サマリー本文中に `<!-- -->` を**引用している実エントリ行**は落とさない。
# コメント開始の行頭 anchor を外す変異 (`/<!--/`) を kill する。実測で現行 wiki の index.md に
# 該当行が 2 件あり、anchor を外すと該当 2 行分 hits が減る（実測時 230 → 228。絶対値はスナップショット）。
printf '# Wiki Index\n\n| ページ | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [t](pages/patterns/a.md) | x | `<!-- c -->` 挿入は PR #792 で禁忌と判明 | 2026-01-01 | high |\n' > "$IDXSBX/.rite/wiki/index.md"
quoted_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>/dev/null)
assert "TC-50 サマリーが <!-- --> を引用する実エントリ行は落とさない" "1" "$(printf '%s' "$quoted_out" | sed -n 's/^page=\.rite\/wiki\/index\.md; hits=//p')"

# TC-51: 除外ブロック (HTML コメント / コードフェンス) が閉じないまま EOF に達すると、ラッチが
# 立ったまま以降の全行が落ちる。この状態は entries / linkrows / skipped のどれにも現れないため、
# END で検査しないと「実在する参照が丸ごと落ちたのに 0 件 (実測済み)」で通る。
# **判定を `entries == 0` にしてはならない** — 形状 (c) はエントリを 1 件数えた後にラッチが立つため
# entries >= 1 になり、entries を条件にした実装では取り逃す。この 3 形状 + 対照で、
# 「ラッチ変数自身を見る実装」と「entries を見る実装」を識別する。
unc_err="$IDXSBX/unc.err"; tmp_files+=("$unc_err")
unc_run() { printf '%s' "$1" > "$IDXSBX/.rite/wiki/index.md"; printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>"$unc_err"; }

# (a) 未閉鎖 <!-- が全エントリより前 → 全滅形
unc_a=$(unc_run '# Wiki Index

<!-- 廃止メモ

* [A](pages/patterns/a.md) - 詳細は #1151
* [B](pages/patterns/b.md) - PR #1300 で確立
')
assert "TC-51 (a) 未閉鎖 HTML コメントは検出失敗として read_errors に計上する" "1" "$(printf '%s' "$unc_a" | sed -n 's/^descriptive_refs_read_errors=//p')"
assert_grep "TC-51 (a) 未閉鎖は専用 WARNING で原因を名指しする" "$unc_err" 'HTML コメントが閉じられないままファイル終端'
assert "TC-51 (a) 落ちた index.md 分は hits に混ぜない (本文側の 1 件のみ)" "1" "$(idx_hits "$unc_a")"
# END の `exit` を pin する。`exit` を外すと 4 値 print が 2 回走って awk が 8 フィールドを返し、
# 呼出側は arity 検査に捕まる。stdout も read_errors も同値のままなので上の 3 assert は緑を維持し、
# 変わるのは診断だけ — 検出失敗ガードの WARNING が消え、作者が破っていない arity 契約を名指しする
# 2 行に化ける。原因を名指しする WARNING を価値として掲げる本 TC 群としては、その診断連鎖の後半も
# pin する必要がある。
assert_grep "TC-51 (a) 検出失敗ガードの WARNING まで到達する (END の exit を pin)" "$unc_err" 'エントリ行を 1 件も認識できませんでした'
assert_not_grep "TC-51 (a) arity 契約違反として誤診されない" "$unc_err" '4 値を返しませんでした'

# (b) 対照: 閉じていれば通常どおり数える (ラッチ検査が過剰発火していないこと)
unc_b=$(unc_run '# Wiki Index

<!-- 廃止メモ -->

* [A](pages/patterns/a.md) - 詳細は #1151
* [B](pages/patterns/b.md) - PR #1300 で確立
')
assert "TC-51 (b) 対照: 閉じたコメントなら index の 2 件を数える" "2" "$(printf '%s' "$unc_b" | sed -n 's/^page=\.rite\/wiki\/index\.md; hits=//p')"
assert "TC-51 (b) 対照: read_errors は増えない" "0" "$(printf '%s' "$unc_b" | sed -n 's/^descriptive_refs_read_errors=//p')"

# (c) 部分欠損: エントリ 1 件の後に未閉鎖 → entries>=1 のため entries 条件の実装は取り逃す
unc_c=$(unc_run '# Wiki Index

* [A](pages/patterns/a.md) - 詳細は #1151
<!-- 廃止メモ
* [B](pages/patterns/b.md) - PR #1300 で確立
')
assert "TC-51 (c) 部分欠損 (entries>=1) でも検出失敗として計上する" "1" "$(printf '%s' "$unc_c" | sed -n 's/^descriptive_refs_read_errors=//p')"
assert "TC-51 (c) 部分的に数えた hits は実測済みとして計上しない" "1" "$(idx_hits "$unc_c")"

# (d) 閉じ --> がコードフェンス内 → 本文フィルタに先に食われて解除行が状態機械に届かない
unc_d=$(unc_run '# Wiki Index

<!-- 廃止メモ
```
-->
```

* [A](pages/patterns/a.md) - 詳細は #1151
')
assert "TC-51 (d) 閉じ --> がフェンス内でも検出失敗として計上する" "1" "$(printf '%s' "$unc_d" | sed -n 's/^descriptive_refs_read_errors=//p')"

# (e) 未閉鎖コードフェンス → 同じラッチ問題を別の除外ブロックで起こす
unc_e=$(unc_run '# Wiki Index

```
未閉鎖フェンス

* [A](pages/patterns/a.md) - 詳細は #1151
')
assert "TC-51 (e) 未閉鎖コードフェンスも検出失敗として計上する" "1" "$(printf '%s' "$unc_e" | sed -n 's/^descriptive_refs_read_errors=//p')"
assert_grep "TC-51 (e) フェンス側は原因をフェンスと名指しする" "$unc_err" 'コードフェンスが閉じられないままファイル終端'

# ---- TC-48: index.md 終端アクションの戻り値 arity (4 値) を pin する ---------
# 終端アクションのフィールドを減らす変異は、フィールド数がずれたまま個別値の case サニタイザが
# 未束縛を 0 / -1 へ正規化するため、TC-47 の検出失敗ガードを無言で殺す。
# 位置依存パースの規約 (`/rite:wiki-query positional-parse-row-count-guard`) が要求する
# 「回帰 TC で pin する」の充足。mutant は helper の `source ../control-char-neutralize.sh` が
# 解決するよう 1 階層下に置き、依存を同じ相対位置へ複製する (既存 TC-15/16/17/23 は sandbox
# 直下に置いており source が silent に失敗する。そちらへ揃えると欠陥を伝播させるため逸脱する)。
mkdir -p "$IDXSBX/mut"
cp "$PLUGIN_ROOT/hooks/control-char-neutralize.sh" "$IDXSBX/control-char-neutralize.sh" || {
  fail "TC-48 control-char-neutralize.sh の複製に失敗 (mutant の source が解決できず assert が無効化される)"
}
MUT_ARITY="$IDXSBX/mut/mutant-arity.sh"
sed 's/print n+0, skipped+0, entries+0, linkrows+0/print n+0, skipped+0, entries+0/' "$SCRIPT" > "$MUT_ARITY"
if assert_mutated "TC-48 MUTATION mutant 生成" "$MUT_ARITY"; then
  printf '# Wiki Index\n\n* [t](pages/patterns/a.md) - 詳細は #1151\n' > "$IDXSBX/.rite/wiki/index.md"
  arity_err="$IDXSBX/arity.err"; tmp_files+=("$arity_err")
  arity_out=$(printf '%s\n' "$IDX_PAGE_REL" \
    | ( cd "$IDXSBX" && bash "$MUT_ARITY" --branch-strategy same_branch --repo-root "$IDXSBX" ) 2>"$arity_err")
  assert "TC-48 戻り値が 4 値でなければ検出失敗として計上する" "1" "$(printf '%s' "$arity_out" | sed -n 's/^descriptive_refs_read_errors=//p')"
  assert_grep "TC-48 arity 不一致は WARNING で観測できる" "$arity_err" '検出アクションが 4 値を返しませんでした'
  assert "TC-48 arity 不一致の index.md 分は hits に混ぜない" "1" "$(idx_hits "$arity_out")"
fi

if ! print_summary "$(basename "$0")" \
  "drift: wiki-lint-descriptive-refs.sh の検出 / 除外が変わった可能性。SKILL.md ステップ 7.5 の委譲契約と helper 冒頭の検出 2 規則・除外 E1-E5 の記述を参照。"; then
  exit 1
fi
