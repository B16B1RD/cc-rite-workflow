#!/bin/bash
# wiki-lint-descriptive-refs.test.sh
#
# Tests for wiki-lint-descriptive-refs.sh (wiki-lint/SKILL.md ステップ 7.5 delegation
# target). The helper counts descriptive Issue/PR number references left in Wiki page
# bodies and emits a marker block + WIKI_DESCRIPTIVE_REFS total + read_ok enum.
#
# Coverage:
#   TC-1   裸の番号トークンが hit する (委譲文法はキーワードを要求しない)
#   TC-2   (AC-3) `## ソース` 節の bullet も hit する (E2 撤廃)
#   TC-3   TODO / FIXME 行が hit しない
#   TC-4   インラインコードスパン内の literal 引用が hit しない
#   TC-5   コードフェンス内が hit しない / フェンス閉じ後は再び検出される
#   TC-6   委譲文法のスコープ (3-4 桁のみ / プレースホルダ・アンカー・opt-out の除外)
#   TC-7   旧 4 形 (括弧付き / see PR / #N で対応 / 詳細は #N) の検出が保たれる
#   TC-8   frontmatter は `sources:` ブロックのみ除外 (description 散文は hit する)
#   TC-9   marker block / WIKI_DESCRIPTIVE_REFS / read_ok の stdout 契約
#   TC-10  空 pages_list → hits 0, read_ok=true (Wiki 初期化直後の legitimate no-op)
#   TC-11  全ページ読出失敗 → read_ok=io_error (偽の 0 件を「解消済み」と読ませない)
#   TC-12  placeholder residue ({branch_strategy} / {wiki_branch} / {pages_list}) → exit 1
#   TC-13  partial pollution (.rite/wiki/raw/ 行混入) → exit 1 / log.md は完全一致で受理
#   TC-13b (AC-4) log.md を自力 discovery して走査する
#   TC-13c (AC-5) raw は gate と委譲先の二重で走査対象外
#   TC-14  unknown branch_strategy → exit 1 / separate_branch + 空 --wiki-branch → exit 2
#   TC-15  MUTATION 委譲先を無出力 stub にすると hits が 0 になる (計数の出どころ)
#          + 1 ページの複数 hit を行数として数える (rc の二値へ潰さない)
#   TC-16  MUTATION 本文フィルタを外すと TC-2 / TC-5 が落ちる (除外の識別力。E1 は TC-8、
#          E4 / E5 は終端アクション側にあり本 mutant の到達範囲外で TC-3 / TC-4 が pin)
#   TC-18  SKILL.md ステップ 7.5 が helper 委譲 + helper 不在 fallback を持つ (静的回帰)
#   TC-19  separate_branch (本番既定経路、git show) の positive path
#   TC-20  (AC-3) `## ソース` 節に除外が残っていない / (AC-2) リンク先パスは hit しない
#   TC-21  informational 契約の非回帰 (T-06 / T-07: n_warnings 不加算 / canonical Lint: 行不変)
#   TC-19b separate_branch の読出に cat fallback が無い (ブランチ分離の pin)
#   TC-22  helper が検出文法のコピーを持たず委譲先を名指しで呼ぶ
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
#   TC-48  index.md 終端アクションの診断 arity (3 値) を pin する (フィールドを減らす変異を弾く)
#   TC-19c separate_branch (既定) でも index.md 不在は read_errors に数えない (#2069 T-06)
#   TC-50  index-template.md 前文を entries に数えず、テーブル行は列解釈まで通る (配布テンプレート回帰)
#   TC-50b 記法例コメントを持つ index.md でコメント除去規則そのものを pin する (literal fixture)
#   TC-51  除外ブロック (コメント / フェンス) の未閉鎖を END で検出失敗へ倒す (部分欠損形も含む)
#   TC-49  表と箇条書きが混在する index.md でも行単位で形式を判別する (移行期の必然形状)
#   TC-52  index.md のリンク regex が orphans.sh と literal 一致 (共有定義の drift 検出)
#   TC-53  陳腐化 (stale) が lint_action / n_warnings の判定要素から外れ続ける
#          (散文 / bash if / residue gate / ingest 加算式・等式・内訳の 6 箇所を突合)
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
    resource: "raw/reviews/20260101T000000Z-pr-1300.md"
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

# fixture で hit すべき行は 10 行 — 本文 8 行:
#   PR #1300 / Issue #1284 / (refs #1150) / See PR #1149 / 詳細は #1151 /
#   #1152 で別途対応 / PR #2047 / PR #1301
# と `## ソース` 節の bullet 2 行 (E2 撤廃後は表示テキストも走査対象)。
# 除外が 1 つでも外れるとこの数を超える (TODO/FIXME 2 行・コードスパン 1 行・
# フェンス 1 行が混入するため)。
assert "TC-1/2/3/4/5 hits=10 (対象のみ)" "10" "$hits"

# ---- MUTATION の前提: mutant が実際に元と違うことを先に確かめる ---------------
# 生成が no-op のまま「差が出なかった」と読むと mutation test が無言で vacuous になる。
assert_mutated() {
  assert_mutant_changed "$1" "$SCRIPT" "$2"
}

# mutant は sandbox へ置かれるため、helper が `dirname "$BASH_SOURCE"` で解決する委譲先
# (number-reference-check.sh) が引けず fail-fast の exit 2 で死ぬ。委譲そのものを変異させる
# mutant 以外は、生成後に委譲先を実体の絶対パスへ固定してから走らせる。
# 固定しないと mutant が「出力なし」で終わり、mutation test が測るべき差分ではなく
# 起動失敗を見ることになる (無言で vacuous になる)。
REAL_NUMREF="$PLUGIN_ROOT/hooks/scripts/number-reference-check.sh"
pin_delegate() {
  # $1 = mutant path
  local m="$1" tmp="$1.pinned"
  awk -v real="$REAL_NUMREF" '
    /^_RITE_NUMREF_CHECK=/ { print "_RITE_NUMREF_CHECK=\"" real "\""; next }
    { print }
  ' "$m" > "$tmp" && mv "$tmp" "$m"
}

# ---- 除外の識別力を「フィルタを外した版」との差で測る (TC-16 の測定基盤) -------
# helper 内のフィルタを外した mutant を作り、除外が無いと hits が跳ね上がることを実証する。
# **本 mutant で到達不能な除外**: E1 (frontmatter 除去) は mutant が残す設計のため測れず、TC-8 の
# fixture (description 散文 / sources ブロックの両方) が担う。E4 (コードスパン) と E5 (TODO/FIXME) は
# 終端アクション側にあり本 mutant が差し替える本文フィルタに含まれないため測れず、E4 は TC-4、
# E5 は TC-3 が pin する。mutant を拡張する際は「どの除外がその mutant で到達不能か」を
# 先に列挙すること。
MUT_NOFILTER="$SBX/mutant-nofilter.sh"
# フィルタ本体 (_RITE_BODY_FILTER) を「frontmatter 除去のみ」に差し替える。
# 終端アクション (マスク + 出力) は _RITE_EMIT_ACTION が別に持つため、ここでは
# 落とす行の規則だけを置く (末尾に print を足すと抽出結果に二重出力が混ざる)。
awk '
  /^_RITE_BODY_FILTER=.$/ { print "_RITE_BODY_FILTER='"'"'"; infilter=1; next }
  infilter && /^.$/ { print "NR==1 && /^---[[:space:]]*$/ { infm=1; next }"
                      print "infm && /^---[[:space:]]*$/  { infm=0; next }"
                      print "infm                        { next }"
                      print "'"'"'"; infilter=0; next }
  infilter { next }
  { print }
' "$SCRIPT" > "$MUT_NOFILTER"
# `pin_delegate` は必ず 1 行を書き換えるため、`assert_mutated` より先に呼ぶと
# 「変異セレクタが何にも一致しなかった」を検出する vacuity ガードが常に通ってしまう。
# 変異の有無を先に測ってから委譲先を固定する。
if assert_mutated "TC-16 MUTATION mutant 生成" "$MUT_NOFILTER"; then
  pin_delegate "$MUT_NOFILTER"
  mut_hits=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$MUT_NOFILTER" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')
  if [ "${mut_hits:-0}" -gt "$hits" ] 2>/dev/null; then
    pass "TC-16 MUTATION 除外フィルタ除去で hits が増える (${hits} → ${mut_hits}; 除外に識別力あり)"
  else
    fail "TC-16 MUTATION 除外フィルタ除去で hits が変わらない (${hits} → ${mut_hits}) — 除外が何も除外していない"
  fi
fi

# ---- 委譲が実体であることの識別力 (TC-15) -----------------------------------
# hits は委譲先が emit した findings 行数であって、本 helper 内の判定ではない。
# 委譲先を「何も出さない stub」へ差し替えた mutant で hits が 0 へ落ちることで、
# 計数の出どころが委譲先であることを実証する。落ちなければ helper 内に判定が残っている。
MUT_NODELEG="$SBX/mutant-nodelegate.sh"
STUB_CHECK="$SBX/stub-numref.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_CHECK"
awk -v stub="$STUB_CHECK" '
  /^_RITE_NUMREF_CHECK=/ { print "_RITE_NUMREF_CHECK=\"" stub "\""; next }
  { print }
' "$SCRIPT" > "$MUT_NODELEG"
if assert_mutated "TC-15 MUTATION mutant 生成" "$MUT_NODELEG"; then
  stub_hits=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$MUT_NODELEG" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')
  if [ "${stub_hits:-99}" -eq 0 ] 2>/dev/null && [ "$hits" -gt 0 ]; then
    pass "TC-15 MUTATION 委譲先を無出力 stub にすると hits が 0 になる (${hits} → ${stub_hits}; 計数は委譲先由来)"
  else
    fail "TC-15 MUTATION 委譲先を stub にしても hits が残る (${hits} → ${stub_hits}) — helper 内に判定のコピーがある"
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
# 1 ページに 2 hit 以上を数えられること。委譲先の exit code (0/1 の二値) を件数として
# 使う実装では、どのページも hits が最大 1 に潰れ、WIKI_DESCRIPTIVE_REFS の意味が
# 「hit 行数の合計」から「hit を持つページ数」へ無言で変わる。
multi=$(printf '# t\n\nPR #1300 の一行目\nIssue #1284 の二行目\n詳細は #1151 の三行目\n')
assert "TC-15 1 ページの複数 hit を行数として数える (rc の二値へ潰さない)" "3" "$(single_hits "$multi")"
assert "TC-1 裸の PR #N が hit"            "1" "$(single_hits 'PR #1300 は フォーマットを統一した')"
assert "TC-1 裸の Issue #N が hit"         "1" "$(single_hits 'Issue #1284 系譜の継続')"
assert "TC-7 括弧付き (refs #N) が hit"     "1" "$(single_hits '(refs #1150) の括弧形')"
assert "TC-7 See PR #N が hit"             "1" "$(single_hits 'See PR #1149 も同様')"
assert "TC-7 詳細は #N が hit"             "1" "$(single_hits '詳細は #1151')"
assert "TC-7 #N で別途対応 が hit"          "1" "$(single_hits '#1152 で別途対応')"
assert "TC-3 TODO 行は hit しない"          "0" "$(single_hits 'TODO: #9999 で対応予定')"
assert "TC-3 FIXME 行は hit しない"         "0" "$(single_hits 'FIXME PR #9998 を追う')"
assert "TC-4 コードスパン内は hit しない"    "0" "$(single_hits '`refs #204` が `refs #2047` に一致する')"
# span マスクは削除ではなく `_` 置換。削除するとスパンの前後が隣接して行の意味が変わる
# (comment-journal-check.test.sh TC-4 と対称)。委譲文法は番号トークン単独を見るため、
# `PR `x` #1234` はマスク後も番号が残って hit する — マスクの識別力はスパン**内側**の
# 番号 (上の assert) が測る。
assert "TC-4 span の外にある番号はマスク後も残る" "1" "$(single_hits 'PR `x` #1234')"
assert "TC-1 キーワードなし裸 #N も hit する (委譲文法はトークンを見る)" "1" "$(single_hits '#1234 の単独形')"
# E1 は frontmatter 全体ではなく `sources:` ブロックのみを落とす。ref 値はファイルパスで
# 番号規則に一致しないため除外は防御的だが、`description:` / `title:` の散文は本物の
# 説明的参照を含む (実 wiki で 22 件)。両方を 1 つの fixture で測る。
tc8_fm=$(printf -- '---\ndescription: "PR #1300 の経緯"\nsources:\n  - type: "reviews"\n    resource: "raw/reviews/x-pr-1300.md"\ntags: ["a"]\n---\n\n# t\n\n本文に番号なし\n')
assert "TC-8 frontmatter description の番号参照は hit する" "1" "$(single_hits "$tc8_fm")"
# ref 値に `#N` を含ませる。ファイルパスに `#` は現れないため E1 は防御的除外だが、`#` を
# 持たない fixture では E1 を削除しても 0 のままで、この assert が何も pin しない。
tc8_src=$(printf -- '---\ntitle: "t"\nsources:\n  - type: "reviews"\n    resource: "raw/reviews/PR #1300.md"\n---\n\n# t\n\n本文に番号なし\n')
assert "TC-8 frontmatter sources ブロックは hit しない" "0" "$(single_hits "$tc8_src")"

# TC-2 (AC-3): `## ソース` 節の bullet も走査対象 (E2 撤廃)。表示テキストは読者が読む散文で、
# 番号の受け皿は隣のリンク先である。
src_only=$(printf '# t\n\n## ソース\n\n- [PR #1300 review results](../../raw/reviews/a.md)\n- [Issue #1284 fix results](../../raw/fixes/b.md)\n')
assert "TC-2 (AC-3) ソース節配下のラベル 2 行が hit する" "2" "$(single_hits "$src_only")"
# 番号を落とした bullet は hit しない — retrofit 後の形が clean であることを対にして測る
# (「節を丸ごと数えている」実装と「番号を数えている」実装を分ける)。
src_clean=$(printf '# t\n\n## ソース\n\n- [レビュー結果](../../raw/reviews/a.md)\n- [fix 結果](../../raw/fixes/b.md)\n')
assert "TC-2 (AC-3) 番号を落としたソース bullet は hit しない" "0" "$(single_hits "$src_clean")"

# TC-5: フェンス内は 0、フェンス閉じ後の行は検出される
fence_only=$(printf '# t\n\n```bash\ngrep -E "PR #7777" f.md\n```\n')
assert "TC-5 コードフェンス内は hit しない" "0" "$(single_hits "$fence_only")"
fence_then=$(printf '# t\n\n```bash\ngrep -E "PR #7777" f.md\n```\n\nPR #1301 フェンス後\n')
assert "TC-5 フェンス閉じ後は再び検出される" "1" "$(single_hits "$fence_then")"

# TC-6: 委譲文法のスコープ。番号トークンは 3-4 桁のみが対象で、その外は Wiki 散文の
# 正当な用途 (上流トラッカ id・列挙条件・箇条番号) として残る。helper 側にコピーを置かず
# 委譲先の文法をそのまま受けていることを、境界の両側で測る。
assert "TC-6 2 桁の番号は対象外" "0" "$(single_hits '発生条件 #12 を満たす')"
assert "TC-6 1 桁の番号は対象外" "0" "$(single_hits 'CFIC #6 の系列')"
assert "TC-6 5 桁の番号は対象外 (上流トラッカ id)" "0" "$(single_hits 'upstream bug #10412 を追う')"
assert "TC-6 3 桁の番号は対象" "1" "$(single_hits 'PR #939 で導入')"
assert "TC-6 4 桁の番号は対象" "1" "$(single_hits 'PR #1939 で導入')"
# 委譲先の行レベル除外がそのまま効く。プレースホルダと見出しアンカーは番号参照ではない。
assert "TC-6 プレースホルダ #123 は対象外" "0" "$(single_hits 'Issue #123 はプレースホルダ')"
assert "TC-6 見出しアンカー (#NNN-letter) は対象外" "0" "$(single_hits '[節](doc.md#1234-heading) を参照')"
# 委譲先の opt-out マーカーは Wiki 本文にも効いてしまう。意図した挙動として pin し、
# Wiki ページで使ってはならない旨は helper header と rationale に書く。
assert "TC-6 drift-check-ignore 行は Wiki 本文でも免除される (Wiki では使わない)" \
  "0" "$(single_hits 'PR #1300 は統一した  drift-check-ignore')"

# TC-22 (旧 TC-6 静的 pin / 旧 TC-17 の `\b` 変異) は本 helper が regex を持たなくなったため
# 廃止した。文法の健全性は委譲先の number-reference-check.test.sh が測り、本ファイルは
# 「コピーを持たないこと」(下の TC-22) と「委譲の結果を数えていること」(下の TC-15) を測る。

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
# log.md は index.md と同じく完全一致で受理する (自力 discovery があるので渡す必要はないが、
# 渡しても gate が弾かない・重複計上しない)。prefix 一致へ緩めると raw 行も通ってしまうため、
# 受理は完全一致のままであることを raw 側の fail-fast と対にして測る。
printf '%s\n%s\n' "$FIXTURE_REL" ".rite/wiki/log.md" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) >/dev/null 2>&1
assert "TC-13 log.md 完全一致は gate を通る" "0" "$?"
printf '%s\n%s\n' "$FIXTURE_REL" ".rite/wiki/log.md.bak" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) >/dev/null 2>&1
assert "TC-13 log.md への prefix 一致は gate に弾かれる (完全一致のまま)" "1" "$?"

# ---- TC-13b (AC-4): log.md を走査対象にする --------------------------------
# ステップ 2.2 の pages_list は pages/ 配下しか列挙しないため、log.md は helper が自力で
# discovery しなければ届かない。stdin に渡さない状態で hit することを測る。
printf '# Directory Update Log\n\n## 2026-01-01\n* **Create**: [t](pages/x/a.md) — PR #686 cycle 1 review\n' > "$SBX/.rite/wiki/log.md"
log_out="$SBX/log.out"; tmp_files+=("$log_out")
printf '' | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) > "$log_out" 2>/dev/null
assert "TC-13b (AC-4) log.md の番号を hits に計上する (stdin に無くても discovery する)" \
  "1" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$log_out")"
assert_grep "TC-13b (AC-4) marker block に log.md 行が出る" "$log_out" '^page=\.rite/wiki/log\.md; hits=1$'
# 番号を落とした log 行は hit しない (「log.md を丸ごと数えている」実装と分ける)
printf '# Directory Update Log\n\n## 2026-01-01\n* **Create**: [t](pages/x/a.md) — raw/reviews/20260101T000000Z-pr-686.md を新規ページ化\n' > "$SBX/.rite/wiki/log.md"
assert "TC-13b (AC-4) 番号を落とした log 行は hit しない (raw パスの番号は `#` を持たない)" \
  "0" "$(printf '' | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')"
rm -f "$SBX/.rite/wiki/log.md"

# ---- TC-13c (AC-5): raw は走査対象外 ---------------------------------------
# 二重の保証を両方測る。(1) stdin に raw パスが現れたら gate が exit 1 で弾く (TC-13、
# 取り違えの検出なので「静かに 0 件」にしない)。(2) 仮に gate を越えても委譲先が同じパスを
# 除外するため findings は 0 になる。(2) を測らないと、gate を緩めた変異が
# 「raw の番号を数え始める」方向へ倒れても気付けない。
raw_probe=$(printf 'PR #1234 の生ログ\n' | bash "$PLUGIN_ROOT/hooks/scripts/number-reference-check.sh" \
  --stdin --label ".rite/wiki/raw/reviews/x-pr-1234.md" --quiet 2>/dev/null; echo "rc=$?")
assert "TC-13c (AC-5) 委譲先は raw パスの label を findings 0 で返す" "rc=0" "$raw_probe"
# 対照: 同じ本文でも pages/ の label なら hit する (label 除外が効いていることの識別力)
pages_probe=$(printf 'PR #1234 の本文\n' | bash "$PLUGIN_ROOT/hooks/scripts/number-reference-check.sh" \
  --stdin --label ".rite/wiki/pages/x/a.md" --quiet 2>/dev/null; echo "rc=$?")
assert "TC-13c (AC-5) 対照: pages/ の label なら同じ本文が hit する" "rc=1" "$(printf '%s' "$pages_probe" | tail -1)"

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
# 撤廃した除外が SKILL.md の記述に残っていないこと。helper だけ直して記述が古いままだと、
# 次の作業者は「ソース節は除外される」を前提に読む。
assert_not_grep "TC-18 SKILL.md が log.md を走査対象外と書いていない" "$LINT_MD" '走査しないファイル（意図的除外）: `log.md`'
assert_grep "TC-18 SKILL.md が委譲先を名指ししている" "$LINT_MD" '検出文法は `number-reference-check.sh` に委譲する'

# ---- TC-18b (AC-6): wiki-ingest が commit 前に検査するレールを持つ -----------
# wiki-lint は informational (n_warnings 不加算) で書き込みを止めない。混入を止めるゲートは
# 書き込み側にしか置けないため、ingest の commit 前にあることを pin する。
# 静的 grep だけでは heredoc 終端 / case の esac / fi が壊れる変異を素通しするので、TC-53 と同型に
# ブロックを抽出して `bash -n` にかけ、placeholder を実値へ置換して実際に走らせる。
INGEST_MD_RAIL="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"
assert_grep "TC-18b (AC-6) ingest が commit 前検査ステップを持つ" "$INGEST_MD_RAIL" '^### 5\.0\.n commit 前の番号参照検査'
assert_grep "TC-18b (AC-6) 検査は number-reference-check.sh へ委譲する" "$INGEST_MD_RAIL" 'bash "\$check" --repo-root "\$numref_tree" --diff HEAD --path \.rite/wiki --quiet'
assert_grep "TC-18b (AC-6) 新規ページを差分へ載せてから検査する" "$INGEST_MD_RAIL" 'git -C "\$numref_tree" add -N -- \.rite/wiki'
assert_grep "TC-18b (AC-6) intent-to-add 失敗は fail-loud で止まる" "$INGEST_MD_RAIL" 'WIKI_INGEST_NUMREF=error; reason=stage_failed'
assert_grep "TC-18b (AC-6) 検査対象は .rite/wiki 配下の未 commit 差分" "$INGEST_MD_RAIL" '検査対象は `\.rite/wiki` 配下の未 commit 差分'
assert_grep "TC-18b (AC-6) 対象もラベルも LLM が選ばない" "$INGEST_MD_RAIL" '対象の列挙もラベルも LLM が選ばない'
assert_grep "TC-18b (AC-6) hit は書き直してから再検査する (直せなければ停止)" "$INGEST_MD_RAIL" '再実行で `clean` にできなければ commit せず停止'
assert_grep "TC-18b (AC-6) index.md の行は Edit せず helper を呼び直す" "$INGEST_MD_RAIL" '`index\.md` の行は Edit しない'
assert_grep "TC-18b (AC-6) helper 不在は fail-loud で停止する" "$INGEST_MD_RAIL" 'WIKI_INGEST_NUMREF=error; reason=helper_missing'
assert_grep "TC-18b (AC-6) placeholder 残留は fail-loud で停止する" "$INGEST_MD_RAIL" 'WIKI_INGEST_NUMREF=error; reason=placeholder_residue'
assert_grep "TC-18b (AC-6) ignore 残存検査の rc 失敗は fail-loud で停止する" "$INGEST_MD_RAIL" 'WIKI_INGEST_NUMREF=error; reason=ignored_check_failed'
# causes の取得は stderr を混ぜない (混ぜると git の診断が「効いている exclude ルール」として
# 見出しの下に並ぶ)。出力側の assert は健全 fixture では恒真なので、source 側で決定的に測る
assert_not_grep "TC-18b (AC-6) causes 取得は check-ignore の stderr を併合しない" \
  "$INGEST_MD_RAIL" 'check-ignore -v --stdin 2>&1'
assert_grep "TC-18b (AC-6) causes 取得は rc を捕捉する" "$INGEST_MD_RAIL" '\|\| numref_ci_rc=\$\?'
# commit ステップ側が marker を機械的に読むゲートを持つこと
# (散文で名指しするだけでは 5.0.n を飛ばしても commit が成功してしまう)
assert "TC-18b (AC-6) ゲートは hit を commit させない (canonical + 5.1 + 5.2 の 3 箇所)" "3" \
  "$(grep -c '番号参照が残ったままです。commit しません' "$INGEST_MD_RAIL")"

# --- 5.0.n ブロックの実行検証 (TC-53 と同型: 抽出 → bash -n → placeholder 置換して実行) ---
# 片付けは他 sandbox (SBX / GITSBX / IDXSBX) と同じ cleanup_dirs に寄せる。インライン rm だけだと
# 途中で fail した回に temp git repo が残る。
p18b_dir=$(mktemp -d "${TMPDIR:-/tmp}/rite-tc18b-XXXXXX")
cleanup_dirs+=("$p18b_dir")
# 5.0.n 見出し直後の最初の fenced bash ブロックを取り出す
awk '
  /^### 5\.0\.n commit 前の番号参照検査/ { insec=1; next }
  insec && /^```bash$/ { infence=1; next }
  infence && /^```$/ { exit }
  infence { print }
' "$INGEST_MD_RAIL" > "$p18b_dir/block.sh"
if [ ! -s "$p18b_dir/block.sh" ]; then
  fail "TC-18b (AC-6) 5.0.n の bash ブロックを抽出できなかった (見出し / fence の drift)"
  skip "TC-18b (AC-6) 5.0.n 実行 assert 群 (8 経路) をブロック抽出失敗により gate"
else
  if bash -n "$p18b_dir/block.sh" 2>/dev/null; then
    pass "TC-18b (AC-6) 5.0.n の bash ブロックが構文的に妥当"
  else
    fail "TC-18b (AC-6) 5.0.n の bash ブロックが bash -n を通らない"
  fi
  # placeholder を実値へ置換して 8 経路を実行する。走査対象は使い捨ての git リポジトリで、
  # 番号を含む / 含まない未 commit 差分と、まだ追跡されていない新規ページを作って与える。
  p18b_render() {
    # $1 = numref_tree の実値、$2 = plugin_root の実値。空文字ならその placeholder を残す
    # (残留ゲートが両方の変数を守っていることを片方ずつ測るため)。
    local sed_args=()
    [ -n "$2" ] && sed_args+=(-e "s#{plugin_root}#$2#g")
    [ -n "$1" ] && sed_args+=(-e "s#{numref_tree}#$1#g")
    if [ ${#sed_args[@]} -eq 0 ]; then cat "$p18b_dir/block.sh"; else sed "${sed_args[@]}" "$p18b_dir/block.sh"; fi
  }
  p18b_tree=$(mktemp -d "${TMPDIR:-/tmp}/rite-tc18b-tree-XXXXXX")
  cleanup_dirs+=("$p18b_tree")
  p18b_setup_rc=0
  (
    cd "$p18b_tree" || exit 1
    git init -q . || exit 1
    git config user.email t@e.st || exit 1
    git config user.name t || exit 1
    mkdir -p .rite/wiki/pages/x || exit 1
    printf '# t\n\n番号なしの本文\n' > .rite/wiki/pages/x/p.md || exit 1
    printf '番号なしのコード側ファイル\n' > outside.md || exit 1
    git add -A || exit 1
    git commit -qm init || exit 1
  ) > "$p18b_dir/setup.out" 2>&1 || p18b_setup_rc=$?
  if [ "$p18b_setup_rc" -ne 0 ]; then
    # セットアップ失敗を「clean を返さない」等の別 assert 失敗に化けさせない (原因を隠さない)
    fail "TC-18b (AC-6) 使い捨て git リポジトリのセットアップに失敗 (rc=$p18b_setup_rc)"
    head -5 "$p18b_dir/setup.out" | sed 's/^/    /' >&2
    # 無計上で落とすと baseline との PASS 差だけが残り「何が走らなかったか」がサマリから読めない
    skip "TC-18b (AC-6) 5.0.n 実行 assert 群 (8 経路) を sandbox 準備失敗により gate"
  else
    # (1) clean: 未 commit 差分に番号が無い
    (cd "$p18b_tree" && printf '# t\n\n番号なしの本文\n追記した番号なし行\n' > .rite/wiki/pages/x/p.md)
    p18b_render "$p18b_tree" "$PLUGIN_ROOT" | bash > "$p18b_dir/clean.out" 2>&1
    assert_grep "TC-18b (AC-6) 番号なしの差分は clean を返す" "$p18b_dir/clean.out" 'WIKI_INGEST_NUMREF=clean'
    # (2) hit: 未 commit 差分に 3-4 桁の番号がある
    (cd "$p18b_tree" && printf '# t\n\n番号なしの本文\nPR #1300 を参照\n' > .rite/wiki/pages/x/p.md)
    p18b_render "$p18b_tree" "$PLUGIN_ROOT" | bash > "$p18b_dir/hit.out" 2>&1
    assert_grep "TC-18b (AC-6) 番号を含む差分は hit を返す" "$p18b_dir/hit.out" 'WIKI_INGEST_NUMREF=hit'
    # hit テーブルのアクションは「stdout の file:line が指す行を書き直す」ことに依存する。
    # verdict だけを測ると、委譲先の findings 出力が失われても緑のままになる。
    assert_grep "TC-18b (AC-6) hit は書き直し対象を file:line で名指しする" "$p18b_dir/hit.out" \
      '\.rite/wiki/pages/x/p\.md:[0-9]+:'
    # (3) 新規ページ (untracked): ingest が Write した直後の状態。git diff は untracked を含まないため、
    #     intent-to-add を外すとここが clean に落ちる (混入の主経路が素通りする)。
    (cd "$p18b_tree" && git checkout -q -- .rite/wiki/pages/x/p.md && mkdir -p .rite/wiki/pages/new \
       && printf '# new\n\nPR #1301 を参照\n' > .rite/wiki/pages/new/n.md)
    p18b_render "$p18b_tree" "$PLUGIN_ROOT" | bash > "$p18b_dir/untracked.out" 2>&1
    assert_grep "TC-18b (AC-6) 未追跡の新規ページに番号があれば hit を返す" "$p18b_dir/untracked.out" 'WIKI_INGEST_NUMREF=hit'
    assert_grep "TC-18b (AC-6) 新規ページの hit も file:line で名指しする" "$p18b_dir/untracked.out" \
      '\.rite/wiki/pages/new/n\.md:[0-9]+:'
    # (4) 走査範囲は .rite/wiki 配下に限定される (same_branch で dev ツリー全体を母数にしない)
    (cd "$p18b_tree" && rm -rf .rite/wiki/pages/new && printf '番号なしのコード側ファイル\nPR #1302 を参照\n' > outside.md)
    p18b_render "$p18b_tree" "$PLUGIN_ROOT" | bash > "$p18b_dir/outside.out" 2>&1
    assert_grep "TC-18b (AC-6) .rite/wiki 外の番号は hit にしない (走査範囲 = commit 範囲)" \
      "$p18b_dir/outside.out" 'WIKI_INGEST_NUMREF=clean'
    (cd "$p18b_tree" && git checkout -q -- outside.md)
    # (5) placeholder 残留: 未置換のまま走らせても clean にならず fail-loud で止まる。
    #     ゲートは 2 変数を守るので、片方ずつ残して両方が測られていることを示す。
    p18b_render "" "$PLUGIN_ROOT" | bash > "$p18b_dir/residue-tree.out" 2>&1
    assert_not_grep "TC-18b (AC-6) numref_tree 未置換は clean を名乗らない" "$p18b_dir/residue-tree.out" 'WIKI_INGEST_NUMREF=clean'
    assert_grep "TC-18b (AC-6) numref_tree 未置換は placeholder_residue で止まる" "$p18b_dir/residue-tree.out" 'reason=placeholder_residue'
    p18b_render "$p18b_tree" "" | bash > "$p18b_dir/residue-root.out" 2>&1
    assert_grep "TC-18b (AC-6) plugin_root 未置換も placeholder_residue で止まる (helper_missing に誤診しない)" \
      "$p18b_dir/residue-root.out" 'reason=placeholder_residue'
    # (6) check_failed: commit が 1 つも無いツリー (初回 ingest 直後の wiki ブランチ) では
    #     委譲先が base ref を解決できず rc=2 を返す。`*)` が fail-loud で受けること。
    p18b_bare=$(mktemp -d "${TMPDIR:-/tmp}/rite-tc18b-bare-XXXXXX")
    cleanup_dirs+=("$p18b_bare")
    p18b_bare_rc=0
    ( cd "$p18b_bare" && git init -q . && mkdir -p .rite/wiki/pages ) > "$p18b_dir/bare.out" 2>&1 || p18b_bare_rc=$?
    if [ "$p18b_bare_rc" -ne 0 ]; then
      # 非 repo のまま走らせると add -N が落ちて stage_failed に化け、check_failed を測れない
      fail "TC-18b (AC-6) commit 無しツリーのセットアップに失敗 (rc=$p18b_bare_rc)"
      head -5 "$p18b_dir/bare.out" | sed 's/^/    /' >&2
      skip "TC-18b (AC-6) check_failed 経路の assert を sandbox 準備失敗により gate"
    else
      p18b_render "$p18b_bare" "$PLUGIN_ROOT" | bash > "$p18b_dir/failed.out" 2>&1
      assert_not_grep "TC-18b (AC-6) HEAD 不在で clean を名乗らない" "$p18b_dir/failed.out" 'WIKI_INGEST_NUMREF=clean'
      assert_grep "TC-18b (AC-6) 委譲先の実行失敗は check_failed で止まる" "$p18b_dir/failed.out" 'reason=check_failed'
    fi
    # (7) stage_failed: .rite ごと gitignore されたツリーでは add -N が非 0 を返す。
    #     guard を外すと差分が空 = 無言の clean になるので、rc を見るゲートを実行で pin する。
    p18b_ign=$(mktemp -d "${TMPDIR:-/tmp}/rite-tc18b-ign-XXXXXX")
    cleanup_dirs+=("$p18b_ign")
    p18b_ign_rc=0
    (
      cd "$p18b_ign" || exit 1
      git init -q . || exit 1
      git config user.email t@e.st || exit 1
      git config user.name t || exit 1
      printf '.rite/wiki/\n' > .gitignore || exit 1
      git add -A || exit 1
      git commit -qm init || exit 1
      mkdir -p .rite/wiki/pages || exit 1
      printf '# t\n\nPR #1303 を参照\n' > .rite/wiki/pages/p.md || exit 1
    ) > "$p18b_dir/ign.out" 2>&1 || p18b_ign_rc=$?
    if [ "$p18b_ign_rc" -ne 0 ]; then
      fail "TC-18b (AC-6) gitignore ツリーのセットアップに失敗 (rc=$p18b_ign_rc)"
      head -5 "$p18b_dir/ign.out" | sed 's/^/    /' >&2
      skip "TC-18b (AC-6) stage_failed 経路の assert を sandbox 準備失敗により gate"
    else
      p18b_render "$p18b_ign" "$PLUGIN_ROOT" | bash > "$p18b_dir/stage.out" 2>&1
      assert_not_grep "TC-18b (AC-6) gitignore された Wiki で clean を名乗らない" "$p18b_dir/stage.out" 'WIKI_INGEST_NUMREF=clean'
      assert_grep "TC-18b (AC-6) intent-to-add の失敗は stage_failed で止まる" "$p18b_dir/stage.out" 'reason=stage_failed'
      # stage_failed 固有の文言まで見る。案内文字列だけだと ignored_paths 側でも同じ語が出るため、
      # rc ゲートを弱めて別分岐へ落ちた変異を識別できない
      assert_grep "TC-18b (AC-6) stage_failed は intent-to-add の失敗として報告する" \
        "$p18b_dir/stage.out" 'intent-to-add に失敗しました'
      assert_grep "TC-18b (AC-6) stage_failed は root .gitignore への negation 追加を案内する" \
        "$p18b_dir/stage.out" "root .gitignore に '!\.rite/wiki/' と '!\.rite/wiki/\*\*' を追記"
      # 経路 (8) の assert_not_grep 'gitignore-wiki-section-end' が恒真でないことの positive control。
      # 生成元と同じブロックに置く (別ブロックから読むと、この経路が gate された回に偽 FAIL 化する)
      assert_grep "TC-18b (AC-6) positive control: stage_failed 側には root anchor 案内が出る" \
        "$p18b_dir/stage.out" 'gitignore-wiki-section-end'
      # 案内どおり negation を足すと解消すること (手当てが実効性を持つことの pin)
      (cd "$p18b_ign" && printf '.rite/wiki/\n!.rite/wiki/\n!.rite/wiki/**\n' > .gitignore)
      p18b_render "$p18b_ign" "$PLUGIN_ROOT" | bash > "$p18b_dir/stage-fixed.out" 2>&1
      assert_not_grep "TC-18b (AC-6) 案内どおり直すと stage_failed が消える" \
        "$p18b_dir/stage-fixed.out" 'reason=stage_failed'
      assert_grep "TC-18b (AC-6) 案内どおり直すと番号を検出できる (母数が空にならない)" \
        "$p18b_dir/stage-fixed.out" 'WIKI_INGEST_NUMREF=hit'
    fi
    # (8) ignored_paths: ディレクトリは非 ignore・配下ファイルだけ ignore のドリフト。
    #     add -N は rc=0 で何も stage しないため、rc だけを見るゲートでは silent clean になる。
    p18b_drift=$(mktemp -d "${TMPDIR:-/tmp}/rite-tc18b-drift-XXXXXX")
    cleanup_dirs+=("$p18b_drift")
    p18b_drift_rc=0
    (
      cd "$p18b_drift" || exit 1
      git init -q . || exit 1
      git config user.email t@e.st || exit 1
      git config user.name t || exit 1
      mkdir -p .rite/wiki/pages || exit 1
      # `*` + `!wiki/` で `!wiki/**` を欠く形 = gitignore-health-check が検出する nested drift
      printf '*\n!wiki/\n' > .rite/.gitignore || exit 1
      printf 'seed\n' > seed.md || exit 1
      git add -A || exit 1
      git commit -qm init || exit 1
      printf '# t\n\nPR #1304 を参照\n' > .rite/wiki/pages/p.md || exit 1
      # 非 ASCII ページ名を含める。core.quotePath 既定では ls-files が octal escape で返すため
      # 残存一覧が読めなくなる (check-ignore --stdin は入力を自前で unquote するので照合は通る)
      printf '# t\n\nPR #1306 を参照\n' > .rite/wiki/pages/日本語ページ.md || exit 1
      # 2 ファイル目。先頭 1 件しか名指ししない実装だと原因行が 1 本しか出ない
      mkdir -p .rite/wiki/other || exit 1
      printf '# t\n\nPR #1307 を参照\n' > .rite/wiki/other/q.md || exit 1
    ) > "$p18b_dir/drift.out" 2>&1 || p18b_drift_rc=$?
    if [ "$p18b_drift_rc" -ne 0 ]; then
      fail "TC-18b (AC-6) nested drift ツリーのセットアップに失敗 (rc=$p18b_drift_rc)"
      head -5 "$p18b_dir/drift.out" | sed 's/^/    /' >&2
      skip "TC-18b (AC-6) ignored_paths 経路の assert を sandbox 準備失敗により gate"
    else
      p18b_render "$p18b_drift" "$PLUGIN_ROOT" | bash > "$p18b_dir/ignored.out" 2>&1
      assert_not_grep "TC-18b (AC-6) 配下だけ ignore のドリフトで clean を名乗らない" "$p18b_dir/ignored.out" 'WIKI_INGEST_NUMREF=clean'
      assert_grep "TC-18b (AC-6) ignore 残存は ignored_paths で止まる (rc は 0 なので実体で見る)" \
        "$p18b_dir/ignored.out" 'reason=ignored_paths'
      # nested drift は root への negation では解けない。原因を check-ignore で名指しすること、
      # および stage_failed 用の root anchor 案内へ逆戻りしていないことを対で pin する
      # (否定側の文字列は経路 (7) の stage.out に実在する = 恒真ではない。その positive control は
      #  生成元と同じブロックに置く — ここから読むと (7) が gate された回に file-not-found で落ちる)
      assert_grep "TC-18b (AC-6) ignored_paths は効いている .gitignore を check-ignore で名指しする" \
        "$p18b_dir/ignored.out" '\.gitignore:[0-9]+:'
      # 残存ファイルの一覧行 (先頭 4 スペース + パス) に限定して測る。原因行側は
      # check-ignore が自前で unquote するため、一覧行の quoting を識別できない
      assert_grep "TC-18b (AC-6) 残存一覧が非 ASCII のページ名を生のまま出す (quotePath=false)" \
        "$p18b_dir/ignored.out" '^    \.rite/wiki/pages/日本語ページ\.md$'
      assert_not_grep "TC-18b (AC-6) 原因の見出しだけが出て中身が空にならない" \
        "$p18b_dir/ignored.out" '原因を特定できませんでした'
      # 原因欄に git の診断が並ぶのは stderr を causes へ混ぜた形の再導入を意味する。
      # 健全な fixture では check-ignore が stderr を出さないのでこの出力側 assert だけでは
      # 恒真になる — 決定的なキラーは下の source 側 pin と経路 (9) の shim が担う
      assert_not_grep "TC-18b (AC-6) 原因欄に git の警告 / エラーを原因として載せない" \
        "$p18b_dir/ignored.out" '^    (warning|fatal|error):'
      # 原因行の path 欄も生のまま出ること (check-ignore 側の quotePath=false を測る)
      assert_grep "TC-18b (AC-6) 原因行の path 欄も非 ASCII を生で出す" \
        "$p18b_dir/ignored.out" '\.gitignore:[0-9]+:.*[[:space:]]\.rite/wiki/pages/日本語ページ\.md$'
      # 残存が複数ある回に先頭 1 件しか名指ししないと、直して再実行しても同じ reason で止まる。
      # 表示件数 (head -5) と原因行数が一致することで「全件に対して引いた」ことを測る
      # 原因行 (`<source>:<line>:<pattern>\t<path>`) も `    .rite/wiki/...` で始まりうるので、
      # 一覧行だけを数えるためコロンを含まない行に限定する
      p18b_ig_shown=$(grep -cE '^    \.rite/wiki/[^:]+$' "$p18b_dir/ignored.out")
      p18b_ig_causes=$(grep -cE '^    [^ ]*\.gitignore:[0-9]+:' "$p18b_dir/ignored.out")
      assert "TC-18b (AC-6) 表示した残存ファイル全件について原因を名指しする" \
        "$p18b_ig_shown" "$p18b_ig_causes"
      assert_not_grep "TC-18b (AC-6) ignored_paths は stage_failed 用の root anchor 案内へ戻っていない" \
        "$p18b_dir/ignored.out" 'gitignore-wiki-section-end'
    fi
  # (9) check-ignore が失敗した回。git の PATH shim で check-ignore だけを rc=128 + stderr に
  #     差し替える。健全な fixture では check-ignore が必ず一致を返すため、else arm と
  #     「stderr を混ぜない」性質はこの経路でしか実行で測れない
  p18b_shim="$p18b_dir/shim"
  mkdir -p "$p18b_shim"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$a" = "check-ignore" ]; then\n'
    printf '    echo "fatal: shimmed check-ignore failure" >&2\n'
    printf '    exit 128\n'
    printf '  fi\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$(command -v git)"
  } > "$p18b_shim/git"
  chmod +x "$p18b_shim/git"
  if [ ! -x "$p18b_shim/git" ]; then
    fail "TC-18b (AC-6) git shim を作成できなかった"
    skip "TC-18b (AC-6) check-ignore 失敗経路の assert を shim 作成失敗により gate"
  else
    p18b_render "$p18b_drift" "$PLUGIN_ROOT" > "$p18b_dir/block9.sh"
    PATH="$p18b_shim:$PATH" bash "$p18b_dir/block9.sh" > "$p18b_dir/shim.out" 2>&1
    # 失敗しても verdict は変わらない (ignore 残存は ls-files が確定済み)
    assert_grep "TC-18b (AC-6) check-ignore が落ちても ignored_paths で止まる" \
      "$p18b_dir/shim.out" 'reason=ignored_paths'
    # else arm へ入り、rc を添えて「一致を返しませんでした」と報告する
    assert_grep "TC-18b (AC-6) check-ignore 失敗時は rc を添えて報告する" \
      "$p18b_dir/shim.out" '一致を返しませんでした \(rc=128\)'
    assert_grep "TC-18b (AC-6) check-ignore 失敗時は手動再現コマンドを案内する" \
      "$p18b_dir/shim.out" '手動: git -C .* check-ignore -v'
    # git の診断は素通しされ、原因としてラベル (4 スペース字下げ) されない
    assert_grep "TC-18b (AC-6) git の診断自体は surface される" \
      "$p18b_dir/shim.out" 'fatal: shimmed check-ignore failure'
    assert_not_grep "TC-18b (AC-6) git の診断を原因欄へ字下げして載せない" \
      "$p18b_dir/shim.out" '^    fatal: shimmed check-ignore failure'
    # 名指しできた件数が表示件数に満たないことを明示する
    assert_grep "TC-18b (AC-6) 名指しできた件数が表示件数に満たないことを明示する" \
      "$p18b_dir/shim.out" '注意: 表示 [0-9]+ 件のうち 0 件しか原因を名指しできていません'
  fi
  fi
fi
# --- TC-18c (AC-6): commit ステップの numref_verdict ゲートを実行で pin する ---
# 出現回数 (grep -c = 3) は順序も意味論も測らない。`clean) exit 1` や、ゲートを commit 呼び出しの
# 後ろへ移す変異はカウントを変えないため、抽出して実際に走らせる。
p18c_dir=$(mktemp -d "${TMPDIR:-/tmp}/rite-tc18c-XXXXXX")
cleanup_dirs+=("$p18c_dir")
# canonical gate 節の fenced bash を取り出す (5.1 / 5.2 は literal 一致が規約)
awk '
  /^#### canonical numref_verdict gate/ { insec=1; next }
  insec && /^```bash$/ { infence=1; next }
  infence && /^```$/ { exit }
  infence { print }
' "$INGEST_MD_RAIL" > "$p18c_dir/gate.sh"
if [ ! -s "$p18c_dir/gate.sh" ]; then
  fail "TC-18c (AC-6) canonical numref_verdict gate の bash ブロックを抽出できなかった"
  skip "TC-18c (AC-6) ゲート実行 assert 群 (4 値) を抽出失敗により gate"
else
  p18c_run() { sed "s#{numref_verdict}#$1#g" "$p18c_dir/gate.sh" | bash > "$p18c_dir/out" 2>&1; }
  p18c_run clean; p18c_rc=$?
  assert "TC-18c (AC-6) clean は commit へ進む (exit 0)" "0" "$p18c_rc"
  p18c_run hit; p18c_rc=$?
  assert "TC-18c (AC-6) hit は commit させない (exit 1)" "1" "$p18c_rc"
  assert_grep "TC-18c (AC-6) hit は理由を名指しする" "$p18c_dir/out" '番号参照が残ったままです。commit しません'
  # 未置換 (placeholder のまま) は「判定を受け取れていない」= 検査を飛ばした実行
  bash "$p18c_dir/gate.sh" > "$p18c_dir/out" 2>&1; p18c_rc=$?
  assert "TC-18c (AC-6) numref_verdict 未置換は commit させない (exit 1)" "1" "$p18c_rc"
  assert_grep "TC-18c (AC-6) 未置換は判定不在として止まる" "$p18c_dir/out" '判定を受け取れていません'
  p18c_run bogus; p18c_rc=$?
  assert "TC-18c (AC-6) 未知値は commit させない (exit 1)" "1" "$p18c_rc"
fi
# canonical / 5.1 / 5.2 の 3 ブロックを byte 一致で比較する。件数 (grep -c) は意味論を測らず、
# 片側の case arm を弱める変異 (`clean|hit) ;;` 等) を素通しする。
# ブロックごとに awk が直接ファイルへ書き出す。csplit -z は GNU 固有で、coreutils を入れない
# macOS leg では pin ごと失われる。境界 sentinel も不要になる。
# 比較範囲は canonical 節が「literal 一致させる」と宣言する fenced block 全体に合わせ、
# ゲート冒頭のコメント行から `esac` までを取る (コメントだけ片側で乖離する変更も弾く)。
p18c_gate_count=$(awk -v outdir="$p18c_dir" '
  BEGIN { n = 0 }
  /^# ステップ 5\.0\.n の判定を機械的に受ける/ { ing=1; f=outdir "/gate-" n ".txt" }
  ing { print > f }
  ing && /^esac$/ { ing=0; n++; close(f) }
  END { print n }
' "$INGEST_MD_RAIL")
assert "TC-18c (AC-6) canonical + 5.1 + 5.2 の 3 箇所にゲート case ブロックがある" "3" "$p18c_gate_count"
# count を印字する awk 自身が gate-N.txt を書くので、count=3 は 3 ファイルの存在を含意する
# (出力ファイルを開けなければ awk は fatal 終了し END に到達せず count が出ない = 上の assert が赤)
if [ "$p18c_gate_count" = "3" ]; then
  if cmp -s "$p18c_dir/gate-0.txt" "$p18c_dir/gate-1.txt"; then
    pass "TC-18c (AC-6) 5.1 のゲートが canonical と byte 一致"
  else
    fail "TC-18c (AC-6) 5.1 のゲートが canonical と一致しない"
  fi
  if cmp -s "$p18c_dir/gate-0.txt" "$p18c_dir/gate-2.txt"; then
    pass "TC-18c (AC-6) 5.2 のゲートが canonical と byte 一致"
  else
    fail "TC-18c (AC-6) 5.2 のゲートが canonical と一致しない"
  fi
fi
# ゲートは commit 呼び出しより**前**になければ意味を持たない。存在数は順序を測らないので、
# 5.1 / 5.2 それぞれで「ゲートの行番号 < commit を起動する行番号」を pin する。
p18c_line_gate_51=$(awk '/^### 5\.1 separate_branch/ { s=1 } s && /^numref_verdict="\{numref_verdict\}"$/ { print NR; exit }' "$INGEST_MD_RAIL")
p18c_line_commit_51=$(awk '/^### 5\.1 separate_branch/ { s=1 } s && /^  commit_out=\$\(bash /  { print NR; exit }' "$INGEST_MD_RAIL")
p18c_line_gate_52=$(awk '/^### 5\.2 same_branch/ { s=1 } s && /^numref_verdict="\{numref_verdict\}"$/ { print NR; exit }' "$INGEST_MD_RAIL")
p18c_line_commit_52=$(awk '/^### 5\.2 same_branch/ { s=1 } s && /^  if ! git add \.rite\/wiki\/ / { print NR; exit }' "$INGEST_MD_RAIL")
for _pair in "5.1:$p18c_line_gate_51:$p18c_line_commit_51" "5.2:$p18c_line_gate_52:$p18c_line_commit_52"; do
  _site=${_pair%%:*}; _rest=${_pair#*:}; _g=${_rest%%:*}; _c=${_rest#*:}
  if [ -z "$_g" ] || [ -z "$_c" ]; then
    fail "TC-18c (AC-6) ステップ $_site のゲート / commit 行を特定できなかった (gate='$_g' commit='$_c')"
  elif [ "$_g" -lt "$_c" ]; then
    pass "TC-18c (AC-6) ステップ $_site のゲートが commit 呼び出しより前にある"
  else
    fail "TC-18c (AC-6) ステップ $_site のゲートが commit 呼び出しより後ろにある (gate=$_g commit=$_c)"
  fi
done

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

# ---- TC-20 (AC-3): `## ソース` 節に除外が残っていないこと --------------------
# 旧実装は見出しから次の `##` までを節スコープで落としていた。撤廃したので、節の内側も
# 外側も同じ規則で数える。見出しの表記ゆれ (`## ソース（追記分）` / 半角括弧) ごとに
# 除外が復活していないかを、同じ 1 ページ内で並べて測る。
post_src=$(printf '# t\n\n## ソース\n\n- [PR #1400 review results](../../raw/reviews/a.md)\n\n## 補強: 節\n\nPR #1500 はソース節の後の本文\n')
assert "TC-20 (AC-3) ソース節の内側と後続本文をどちらも数える" "2" "$(single_hits "$post_src")"
appendix_src=$(printf '# t\n\n## ソース\n\n- [PR #1400 review results](../../raw/a.md)\n\n## ソース（追記分）\n\n- [PR #1500 review results](../../raw/b.md)\n\n## ソース(追記分 2)\n\n- [PR #1600 review results](../../raw/c.md)\n')
assert "TC-20 (AC-3) 追記分ソース節の bullet も全て数える (全角・半角括弧)" "3" "$(single_hits "$appendix_src")"
appendix_then=$(printf '# t\n\n## ソース（追記分）\n\n- [PR #1500 review results](../../raw/b.md)\n\n## 補強: 節\n\nPR #1700 は追記分ソース節の後の本文\n')
assert "TC-20 (AC-3) 追記分ソース節とその後続本文をどちらも数える" "2" "$(single_hits "$appendix_then")"
assert "TC-20 (AC-3) ソース節内の provenance ラベル単独でも数える" "1" \
  "$(single_hits "$(printf '# t\n\n## ソース\n\n- [PR #1400 review results](../../raw/reviews/a.md)\n')")"
# リンク先パスは走査対象に残る。raw ファイル名の `-pr-1400` は `#` を持たないため
# 委譲文法に一致せず、bullet を clean にしてもリンク先を書き換える必要はない (AC-2)。
assert "TC-20 (AC-2) リンク先パスの番号は hit しない (href を書き換える必要がない)" "0" \
  "$(single_hits "$(printf '# t\n\n## ソース\n\n- [レビュー結果](../../raw/reviews/20260101T000000Z-pr-1400.md)\n')")"

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
# として載る。委譲先が実行エラー (rc=2) を返した場合に、0 件ではなく io_error に倒れる
# ことを測る。委譲先を「常に rc=2 を返す stub」へ差し替える。rc 2 は検出できなかった
# 証拠であり、0 件として計上してはならない。
MUT_BADRE="$SBX/mutant-badre.sh"
BADCHECK="$SBX/bad-numref.sh"
printf '#!/usr/bin/env bash\necho "ERROR: scanner exploded" >&2\nexit 2\n' > "$BADCHECK"
awk -v bad="$BADCHECK" '
  /^_RITE_NUMREF_CHECK=/ { print "_RITE_NUMREF_CHECK=\"" bad "\""; next }
  { print }
' "$SCRIPT" > "$MUT_BADRE"
if assert_mutated "TC-23 MUTATION mutant 生成" "$MUT_BADRE"; then
  mut_out=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$MUT_BADRE" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null)
  mut_hits=$(printf '%s' "$mut_out" | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')
  mut_ok=$(printf '%s' "$mut_out" | sed -n 's/^descriptive_refs_read_ok=//p')
  mut_err=$(printf '%s' "$mut_out" | sed -n 's/^descriptive_refs_read_errors=//p')
  assert "TC-23 検出器破損時は read_ok=io_error (0 件を実測済みと名乗らない)" "io_error" "$mut_ok"
  assert "TC-23 検出器破損時は read_errors が立つ" "1" "$mut_err"
  assert "TC-23 検出器破損時の hits は 0" "0" "$mut_hits"
fi

# ---- TC-23b: rc と件数の矛盾が検出失敗へ倒れること --------------------------
# 委譲先の exit code は clean/hit/error の信号であって件数ではない。件数側だけを見ると、
# hit (rc=1) を主張しながら findings を 1 行も出さない状態 (計数経路の破損 — たとえば
# findings の出力先が stdout から外れる) が「実測済みの 0 件」として read_ok=true で通る。
# TC-23 の stub は rc=2 で直上の arm に捕まるため、この象限は rc=1 + 空 stdout でしか踏めない。
MUT_SILENT="$SBX/mutant-silent0.sh"
SILENTCHECK="$SBX/silent-numref.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SILENTCHECK"
awk -v bad="$SILENTCHECK" '
  /^_RITE_NUMREF_CHECK=/ { print "_RITE_NUMREF_CHECK=\"" bad "\""; next }
  { print }
' "$SCRIPT" > "$MUT_SILENT"
if assert_mutated "TC-23b MUTATION mutant 生成" "$MUT_SILENT"; then
  s0_out=$(printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$MUT_SILENT" --branch-strategy same_branch --repo-root "$SBX" ) 2>/dev/null)
  s0_ok=$(printf '%s' "$s0_out" | sed -n 's/^descriptive_refs_read_ok=//p')
  s0_err=$(printf '%s' "$s0_out" | sed -n 's/^descriptive_refs_read_errors=//p')
  s0_hits=$(printf '%s' "$s0_out" | sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p')
  assert "TC-23b rc=1 かつ findings 空は read_ok=io_error (0 件を実測済みと名乗らない)" "io_error" "$s0_ok"
  assert "TC-23b rc=1 かつ findings 空で read_errors が立つ" "1" "$s0_err"
  assert "TC-23b rc=1 かつ findings 空の hits は 0" "0" "$s0_hits"
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
tc8_after=$(printf -- '---\nsources:\n  - resource: "raw/reviews/x.md"\nnote: "PR #1301 の経緯"\n---\n\n# t\n\n本文に番号なし\n')
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
| [PR #770 の教訓](pages/patterns/a.md) | patterns | 番号を持たない説明文 | 2026-01-01 | high |
| [番号なし](pages/patterns/b.md) | patterns | Issue #880 系譜の継続 | 2026-01-01 | high |
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
onlylink=$(printf '# Wiki Index\n\n| ページ | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [PR #770 の教訓](pages/patterns/a.md) | patterns | 番号を持たない説明文 | 2026-01-01 | high |\n')
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
printf '# Wiki Index\n\n* [Issue #990 を含むタイトル](pages/patterns/a.md) - 番号を持たない説明文\n* [番号なし](pages/patterns/b.md) - 詳細は #1151\n* [番号なし2](pages/patterns/c.md) - 詳細は #1234 | 補足あり\n* [`grep -c` の罠](pages/patterns/d.md) - 詳細は #1789\n' > "$IDXSBX/.rite/wiki/index.md"
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

* [PR #770 のタイトル](pages/patterns/b.md) - Issue #880 系譜の継続
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
# 自力 discovery の対象は index.md と log.md の 2 件。ref が引けないと存在を判定できないため
# 両方が読出失敗として計上される (不在なら 0 件に落ちるので、この 2 は「不在に畳んでいない」証拠)。
assert "TC-41 壊れた wiki ref は自力 discovery の 2 件を read_errors に計上する" "2" "$(sed -n 's/^descriptive_refs_read_errors=//p' "$badref_out")"
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

# index 側の E4 マスクが効いていることを pin する (ページ側 TC-4 と対称)。委譲文法は番号
# トークン単独を見るため、識別力を持つのはスパン**内側**の番号 — マスクを外すとこれが hit する。
printf '# Wiki Index\n\n* [t](pages/patterns/a.md) - `詳細は #1234` を参照\n' > "$IDXSBX/.rite/wiki/index.md"
e4mask_out="$IDXSBX/e4mask.out"; tmp_files+=("$e4mask_out")
printf '' | idx_run > "$e4mask_out" 2>/dev/null
assert "TC-43 index 側のコードスパン内の番号は hit しない" "0" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$e4mask_out")"
# マスクは削除ではなく `_` 置換。削除するとスパンの前後が連結して列構造が崩れる。
printf '# Wiki Index\n\n* [t](pages/patterns/a.md) - PR `x` #1234 で導入\n' > "$IDXSBX/.rite/wiki/index.md"
e4keep_out="$IDXSBX/e4keep.out"; tmp_files+=("$e4keep_out")
printf '' | idx_run > "$e4keep_out" 2>/dev/null
assert "TC-43 index 側の span の外にある番号はマスク後も残る" "1" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$e4keep_out")"

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

# ---- TC-22: helper が検出文法のコピーを持たないこと -------------------------
# 文法の SoT は number-reference-check.sh。helper 側に番号パターンが再出現したら、
# 二重管理が復活していて片方が黙って古くなる。コメント行を落とした live コードだけを見る
# (ヘッダは委譲の説明で `#[0-9]` 相当の表記を持ちうる)。
helper_live=$(grep -v '^[[:space:]]*#' "$SCRIPT")
if printf '%s' "$helper_live" | grep -q '#\[0-9\]'; then
  fail "TC-22 helper の live コードに番号パターンが再出現している (検出文法は number-reference-check.sh のみが持つ)
$(printf '%s' "$helper_live" | grep -n '#\[0-9\]' | head -3)"
else
  pass "TC-22 helper の live コードに番号パターンのコピーが無い"
fi
assert_not_grep "TC-22 旧 _RITE_DESCRIPTIVE_RE が残っていない" "$SCRIPT" '^_RITE_DESCRIPTIVE_RE='
# 委譲先を名指しで呼んでいること。呼び出しが消えれば上の否定 pin だけでは全ページ 0 件の
# silent-clean を素通しする (否定 pin と肯定 pin を対にする)。
assert_grep "TC-22 委譲先 number-reference-check.sh を --stdin --label で呼ぶ" \
  "$SCRIPT" 'bash "\$_RITE_NUMREF_CHECK" --stdin --label "\$page"'
assert_grep "TC-22 委譲先が不在なら fail-fast する (0 件を clean と読ませない)" \
  "$SCRIPT" 'ERROR: 検出文法の委譲先'

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
# 上の 2 fixture は配布テンプレートの**前文**しか見ておらず、`## ページ一覧` のヘッダー行に到達する
# assertion が 1 本も無い。テーブル行のサマリー抽出はヘッダー行から導出した列位置に依存するため、
# ヘッダーの列名が変わる / 表ブロックごと消える変異は、前文だけを見る fixture では全 assertion 緑の
# まま通る (テンプレートは lint 実行前に新規 bundle へ配布されるので CI で捕捉する経路が要る)。
# cp した上でテーブル行を 1 本足し、その行のサマリーが数えられることと列崩れ 0 件を pin する。
# 実測: ヘッダー列名の改称でも表ブロック削除でも hits 2 -> 1 / skipped 0 -> 1 に落ちる。
cp "$PLUGIN_ROOT/templates/wiki/index-template.md" "$IDXSBX/.rite/wiki/index.md"
printf '| [A](pages/patterns/a.md) | patterns | 詳細は #1151 | 2026-01-01 | high |\n' >> "$IDXSBX/.rite/wiki/index.md"
tmpl_row_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>/dev/null)
assert "TC-50 配布テンプレートのテーブル行はサマリーが数えられる (本文 1 + index 1)" "2" "$(idx_hits "$tmpl_row_out")"
assert "TC-50 配布テンプレートのヘッダーで 5 列が解釈できる (列崩れ 0 件)" "0" "$(printf '%s' "$tmpl_row_out" | sed -n 's/^descriptive_refs_skipped_rows=//p')"
# TC-50b: 上の cp fixture は「配布テンプレートが将来 entries を汚す形へ変わったら気づく」回帰検知で、
# **コメント除去規則そのものの pin ではない** — 現行テンプレートは記法例コメントを持たないため、
# 除去規則を殺す変異 (`in_comment` 分岐の `next` 落とし) が cp fixture では生き残る。規則の pin は
# 記法例コメントを持つ形式を literal で書いて担保する (箇条書きテンプレートが配布されていた期間に
# 初期化された bundle の index.md がこの形状で残る)。同型の pin を literal fixture で行う先例:
# hooks/tests/wiki-query-inject.test.sh TC-5。
printf '# Wiki Index\n\n<!-- 登録箇条書きの形式例（ingest が自動追記。このコメント行は登録ではない）:\n\n     * [ページタイトル](pages/{domain}/{slug}.md) - 詳細は #1151\n-->\n\n* [A](pages/patterns/a.md) - PR #792 の知見\n' > "$IDXSBX/.rite/wiki/index.md"
legacy_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>/dev/null)
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
# END の `exit` を pin する。`exit` を外すと診断の printf が 2 回走り、2 回目が 1 回目に追記されて
# 診断ファイルが 6 フィールドになる。呼出側は arity 検査 (3 値ちょうど) に捕まり、検出失敗ガードの
# WARNING の代わりに arity 契約違反を名指しする診断へ化ける。stdout も read_errors も同値のままなので
# 上の 3 assert は緑を維持し、変わるのは診断だけ。原因を名指しする WARNING を価値として掲げる本 TC 群
# としては、その診断連鎖の後半も pin する必要がある。
assert_grep "TC-51 (a) 検出失敗ガードの WARNING まで到達する (END の exit を pin)" "$unc_err" 'エントリ行を 1 件も認識できませんでした'
assert_not_grep "TC-51 (a) arity 契約違反として誤診されない" "$unc_err" '3 値を返しませんでした'

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

# ---- TC-48: index.md 終端アクションの診断 arity (3 値) を pin する ---------
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
sed 's/printf "%d %d %d\\n", skipped+0, entries+0, linkrows+0 > diagfile/printf "%d %d\\n", skipped+0, entries+0 > diagfile/' "$SCRIPT" > "$MUT_ARITY"
# pin_delegate は TC-16 と同じ理由で assert_mutated の後に呼ぶ (vacuity ガードを潰さない)
if assert_mutated "TC-48 MUTATION mutant 生成" "$MUT_ARITY"; then
  pin_delegate "$MUT_ARITY"
  printf '# Wiki Index\n\n* [t](pages/patterns/a.md) - 詳細は #1151\n' > "$IDXSBX/.rite/wiki/index.md"
  arity_err="$IDXSBX/arity.err"; tmp_files+=("$arity_err")
  arity_out=$(printf '%s\n' "$IDX_PAGE_REL" \
    | ( cd "$IDXSBX" && bash "$MUT_ARITY" --branch-strategy same_branch --repo-root "$IDXSBX" ) 2>"$arity_err")
  assert "TC-48 戻り値が 3 値でなければ検出失敗として計上する" "1" "$(printf '%s' "$arity_out" | sed -n 's/^descriptive_refs_read_errors=//p')"
  assert_grep "TC-48 arity 不一致は WARNING で観測できる" "$arity_err" '検出アクションが 3 値を返しませんでした'
  assert "TC-48 arity 不一致の index.md 分は hits に混ぜない" "1" "$(idx_hits "$arity_out")"
fi

# ---- TC-53: staleness の informational 降格が判定経路から外れ続けること -------
# 陳腐化は「経過時間の計上」であって構造的欠陥ではないため lint_action / n_warnings の
# 判定要素から外した。否定 pin だけでは 8.1 の節ごと消滅で空振りするので、残る 4 変数の集合を
# 6 箇所 (wiki-lint の散文 / bash if / residue gate、wiki-ingest の加算式 / 等式 / 内訳文言)
# から抽出して相互一致も測る。片側だけに n_stale が残る drift と、判定ロジックごと消す変異の
# 両方を弾く。
INGEST_MD="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"

# --- 否定 pin: 判定サイトから n_stale が消えている (件数表示・Lint: 行の n_stale は対象外) ---
assert_not_grep "TC-53 residue gate ループに n_stale が残っていない" "$LINT_MD" \
  '^for _n_var in .*n_stale'
assert_not_grep "TC-53 bash の if 条件に n_stale が残っていない" "$LINT_MD" \
  '\[ "\$n_stale" -gt 0 \]'
assert_not_grep "TC-53 判定基準散文が 5 種のままになっていない" "$LINT_MD" \
  'ブロッキングカテゴリ 5 種'
assert_not_grep "TC-53 (AC-5) generated.at の手動更新案内が残っていない" "$LINT_MD" \
  '手動で generated.at フィールドを更新'

# --- positive pin: 除外が意図的であることと 4 種への縮小が明示されている ---
assert_grep "TC-53 判定基準散文がブロッキング 4 種になっている" "$LINT_MD" \
  'ブロッキングカテゴリ 4 種'
assert_grep "TC-53 n_stale は参考コメントとして意図的除外が明示されている" "$LINT_MD" \
  '# 参考: n_stale=\{n_stale\} — informational のため判定式から意図的に除外'

# --- 6 箇所の変数集合が一致する (片側だけ改変すると落ちる) ---
# 抽出は開いた regex にする。whitelist の alternation にすると「whitelist ∩ 各サイト」しか
# 測れず、whitelist 外の名前を 1 箇所にだけ足す変異が全 assert を素通りする (AC-7 が要求する
# 「3 箇所が同一の変数集合を指す」が成立しなくなる)。
EXPECT_VARS='n_broken_refs n_contradictions n_missing_concept n_orphans'
# 左境界を要求して `min_count` のような語からの偽収穫を防ぎ、末尾に数字を許して
# `n_orphans2` のような数字サフィックス改名が `n_orphans` へ丸まらないようにする。
extract_sorted() {
  grep -oE '(^|[^a-z0-9_])n_[a-z0-9_]+' | grep -oE 'n_[a-z0-9_]+' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# 散文の「4 種」は数詞なので数字ワイルドカードで受ける。literal を要求すると語が変わったとき
# capture が空になり、集合不一致ではなく「空 vs 4 種」として落ちて診断が原因を指さない。
prose_vars=$(sed -n 's/^- `lint:clean`: ブロッキングカテゴリ [0-9] 種 (\(.*\)) \*\*すべてが 0\*\*.*/\1/p' "$LINT_MD" | extract_sorted)
assert "TC-53 判定基準散文の変数集合が 4 種ちょうど" "$EXPECT_VARS" "$prose_vars"

if_vars=$(sed -n '/^if \[ "\$n_contradictions" -gt 0 \]/,/^  lint_action="lint:warning"$/p' "$LINT_MD" | extract_sorted)
assert "TC-53 bash if 条件の変数集合が散文と一致" "$EXPECT_VARS" "$if_vars"

gate_vars=$(sed -n 's/^for _n_var in \(.*\); do$/\1/p' "$LINT_MD" | extract_sorted)
assert "TC-53 residue gate の変数集合が散文と一致" "$EXPECT_VARS" "$gate_vars"

# AC-6 の canonical `Lint:` 6 フィールド行不変は TC-21 (T-07) が pin 済み (重複させない)。

# --- ingest 側: 加算式 / 等式 / 内訳文言の 3 箇所が同じ 4 項集合で一致する ---
assert_not_grep "TC-53 (AC-4) ingest の n_warnings 加算式に n_stale がない" "$INGEST_MD" \
  '^n_warnings \+= .*n_stale'
assert_not_grep "TC-53 (AC-4) ingest の n_warnings 等式に n_stale がない" "$INGEST_MD" \
  '\*\*等式\*\*: `n_warnings = .*n_stale'

add_vars=$(sed -n 's/^n_warnings += \(.*\)$/\1/p' "$INGEST_MD" | extract_sorted)
assert "TC-53 ingest 加算式の項集合が 4 種ちょうど" "$EXPECT_VARS" "$add_vars"

# 等式・内訳とも n_lint_anomaly は加算式に無い項なので capture 範囲から落とす。開いた regex に
# したため、除去しないと集合に混ざる。
# 非項の除去は**位置ではなく名指し**で行う。位置で範囲を狭めると、狭めた外側に counter が
# 混入した変異を素通しする (実測: 内訳文言で「（内訳:」以降へ絞ると、その左に n_stale を
# 挿入した変異が検出されない)。
eq_vars=$(sed -n 's/^\*\*等式\*\*: `n_warnings = \([^`]*\)`.*/\1/p' "$INGEST_MD" \
  | sed 's/n_lint_anomaly//' | extract_sorted)
assert "TC-53 ingest 等式の項集合が加算式と一致" "$EXPECT_VARS" "$eq_vars"

# 内訳文言は `{n_warnings} 件（内訳: ...）` の形。左辺の n_warnings は当該行に 1 回しか
# 現れないので名指しで落とす。
breakdown_vars=$(grep -F 'Wiki 品質警告: {n_warnings} 件（内訳:' "$INGEST_MD" \
  | sed -e 's/{n_warnings}//' -e 's/n_lint_anomaly//' | extract_sorted)
assert "TC-53 ingest 内訳文言の項集合が加算式と一致" "$EXPECT_VARS" "$breakdown_vars"

# --- ステップ 8.1 bash の実行時挙動 (T-01 / T-02 / T-05) ---
# 静的 pin だけでは block の構文健全性を測れない。判定は継続行を含む if-chain なので、
# `; then` を落とすような変異は集合一致 assert を素通りする。抽出して構文検査し実行する。
extract_phase81() {
  awk '/^# ステップ 8.1 canonical lint_action decision logic/{f=1} f{print} f && /^echo "\[CONTEXT\] lint_action=\$lint_action"$/{exit}' "$LINT_MD"
}
PHASE81_RAW="$SBX/phase81-raw.sh"
extract_phase81 > "$PHASE81_RAW"

# 抽出結果の検査は 2 群に分け、**診断文面を分ける**。抽出の破損と契約の消失は原因も対処も
# 別物で、後者を「アンカーが変更された可能性」と報じると、本テストが検出すべき退行そのものを
# テスト側の問題へ誤帰属させる。
phase81_block_ok=1

# 群 1: 抽出の構造健全性。block 冒頭と awk の終了パターンが揃っているかを見る。
# 終端行は awk の終了条件と lint_action emit 契約を兼ねており、抽出結果からは両者を判別
# できない。文面はどちらの原因も名乗る (片方に決め打つと、残った方の退行がテスト側の
# 問題として報じられる)。開始アンカーは awk の開始条件と同一文字列で、出力が非空なら必ず
# 一致するため検査しない — 空出力は set -o pipefail 側が捕捉する。
for _required in '^set -o pipefail$' '^echo "\[CONTEXT\] lint_action=\$lint_action"$'; do
  if ! grep -q "$_required" "$PHASE81_RAW"; then
    fail "TC-53 ステップ 8.1 bash の抽出に失敗 ('$_required' 不在。抽出アンカーが変更されたか、SKILL.md 側の該当行が削除された可能性)"
    phase81_block_ok=0
  fi
done

# 群 2: 契約行の存在。**群 1 が通ったときだけ**評価する — 抽出が壊れていれば契約行も当然
# 見つからず、「削除された」と名乗るのは偽の主張になる。
if [ "$phase81_block_ok" = 1 ]; then
  if ! grep -q '^for _n_var in ' "$PHASE81_RAW"; then
    fail "TC-53 ステップ 8.1 の契約が消失 (residue gate の for ループが削除された)"
    phase81_block_ok=0
  fi
fi

if [ "$phase81_block_ok" = 1 ]; then
  # placeholder を実値へ差し替えて実行可能にする。置換対象は placeholder 文字列なので
  # 集合変数からは組めず counter 名を literal で並べるが、その列挙は phase81_write の 1 箇所に
  # 集約する (構文検査・実行・residue のどれもここを通す)。gate ループとの一致は上の集合突合
  # assert が別途担保しており、そちらが落ちればここの列挙ずれも表面化する。
  phase81_write() {
    # $1..$4: n_contradictions n_orphans n_missing_concept n_broken_refs の値
    # $5: n_stale の値 (参考コメント側。判定に影響しないことを測る)
    # $6: 出力先
    sed -e "s/{n_contradictions}/$1/g" -e "s/{n_orphans}/$2/g" \
        -e "s/{n_missing_concept}/$3/g" -e "s/{n_broken_refs}/$4/g" \
        -e "s/{n_stale}/$5/g" -e "s/{n_unregistered_raw}/0/g" \
        "$PHASE81_RAW" > "$6"
  }
  phase81_run() {
    phase81_write "$1" "$2" "$3" "$4" "$5" "$SBX/phase81.sh"
    bash "$SBX/phase81.sh" 2>&1
  }

  # 構文健全性 (`; then` 落ち等の変異を検出する)
  phase81_write 0 0 0 0 0 "$SBX/phase81-syntax.sh"
  if bash -n "$SBX/phase81-syntax.sh" 2>"$SBX/phase81-syntax.err"; then
    pass "TC-53 ステップ 8.1 bash が構文的に妥当"
  else
    fail "TC-53 ステップ 8.1 bash の構文検査に失敗: $(head -1 "$SBX/phase81-syntax.err")"
  fi

  # T-01: n_stale > 0 かつ他 4 変数 0 → lint:clean (AC-1)
  assert "TC-53 (T-01/AC-1) n_stale=41・他 4 変数 0 で lint:clean" \
    "[CONTEXT] lint_action=lint:clean" "$(phase81_run 0 0 0 0 41)"

  # T-02: 4 変数それぞれが > 0 のとき lint:warning (AC-2)
  assert "TC-53 (T-02/AC-2) n_contradictions=1 で lint:warning" \
    "[CONTEXT] lint_action=lint:warning" "$(phase81_run 1 0 0 0 0)"
  assert "TC-53 (T-02/AC-2) n_orphans=1 で lint:warning" \
    "[CONTEXT] lint_action=lint:warning" "$(phase81_run 0 1 0 0 0)"
  assert "TC-53 (T-02/AC-2) n_missing_concept=1 で lint:warning" \
    "[CONTEXT] lint_action=lint:warning" "$(phase81_run 0 0 1 0 0)"
  assert "TC-53 (T-02/AC-2) n_broken_refs=1 で lint:warning" \
    "[CONTEXT] lint_action=lint:warning" "$(phase81_run 0 0 0 1 0)"

  # T-05: residue gate は 4 変数それぞれの未置換で exit 1 (AC-7 / 4.5)
  # 全置換したうえで当該変数の代入行だけ placeholder へ戻す
  for _name in n_contradictions n_orphans n_missing_concept n_broken_refs; do
    phase81_write 0 0 0 0 0 "$SBX/phase81-residue-base.sh"
    sed "s/^${_name}=0\$/${_name}={${_name}}/" "$SBX/phase81-residue-base.sh" > "$SBX/phase81-residue.sh"
    _residue_out=$(bash "$SBX/phase81-residue.sh" 2>&1); _residue_rc=$?
    assert "TC-53 (T-05) ${_name} 未置換で exit 1" "1" "$_residue_rc"
    case "$_residue_out" in
      *"LINT_PHASE_8_1_PLACEHOLDER_RESIDUE=1; variable=${_name}"*)
        pass "TC-53 (T-05) ${_name} 未置換で residue marker を emit" ;;
      *)
        fail "TC-53 (T-05) ${_name} 未置換で residue marker が出ない: $(printf '%s' "$_residue_out" | head -1)" ;;
    esac
  done
else
  # 実行 assert 群を丸ごと落とすので計上する。無計上で消すと、baseline との PASS 差だけが
  # 残り「何が走らなかったか」がサマリから読めない (_test-helpers.sh の skip 規約)。
  skip "TC-53 ステップ 8.1 の実行 assert 群 (構文検査 / T-01 / T-02 / T-05) を抽出失敗または契約消失により gate"
fi

if ! print_summary "$(basename "$0")" \
  "drift: wiki-lint-descriptive-refs.sh の検出 / 除外が変わった可能性。SKILL.md ステップ 7.5 の委譲契約と helper 冒頭の検出 2 規則・除外 E1-E5 の記述を参照。"; then
  exit 1
fi
