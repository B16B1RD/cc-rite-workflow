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
#   TC-16  MUTATION 除外フィルタを外すと TC-2..TC-5 が落ちる (除外の識別力)
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
#   TC-25..TC-26 index.md 不在時は従来どおり (read_errors 不加算 / stdout に index 行なし)
#   TC-27..TC-29 index.md のサマリー列だけを検出する (リンクテキスト列は対象外)
#   TC-30  OKF 箇条書き形式の index.md でも検出できる (形式移行で 0 件へ倒れない)
#   TC-31  列数が壊れた行は行全体へフォールバックせず行番号つき WARNING でスキップ
#   TC-32  エントリ行はあるのに全行の抽出に失敗したら行数ガードが WARNING を出す
#   TC-33..TC-34 gate の非回帰 (raw/ と `..` は fail-fast のまま、index.md は完全一致で受理・重複計上なし)
#   TC-35  ステップ 2.2 の pages_list に index.md を混ぜていない (他カテゴリの入力不変)
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
# **E1 (frontmatter 除去) は本 mutant では測れない** — mutant が frontmatter 除去を残す設計のため。
# E1 の識別力は TC-8 の fixture (description 散文 / sources ブロックの両方) が担う。mutant を拡張する際は
# 「どの除外がその mutant で到達不能か」を先に列挙すること。
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

# TC-17: 本文抽出フィルタ (_RITE_BODY_FILTER) は awk で走るため、そこに `\b` を持ち込むと
# gawk がバックスペースとして読んで永久に一致しなくなる。フィルタの TODO/FIXME 除外を
# `\b` 付きに変異させ、除外が沈黙する (= hits が増える) ことで危険を実証する。
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
assert_not_grep "TC-18 旧 inline 検出 regex が残っていない" "$LINT_MD" 'see PR\|See PR\) #\[0-9\]\+'

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

# ---- TC-25..TC-33: index.md 走査 (AC-1..AC-6) ------------------------------
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
assert "TC-25 (T-06) index.md 不在で read_errors=0" "0" "$(sed -n 's/^descriptive_refs_read_errors=//p' "$noidx_out")"
assert "TC-25 (T-06) index.md 不在で read_ok=true" "true" "$(sed -n 's/^descriptive_refs_read_ok=//p' "$noidx_out")"
assert "TC-26 (T-08) index.md 不在なら本文のみの hits" "1" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$noidx_out")"
assert_not_grep "TC-26 (T-08) index.md 不在なら marker block に index 行が出ない" "$noidx_out" 'index\.md'

# T-01 / T-02 / T-03: テーブル形式。サマリー列だけを対象にし、リンクテキスト列は対象外。
cat > "$IDXSBX/.rite/wiki/index.md" <<'IDXEOF'
# Wiki Index

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [PR #77 の教訓](pages/patterns/a.md) | patterns | 番号を持たない説明文 | 2026-01-01 | high |
| [番号なし](pages/patterns/b.md) | patterns | Issue #88 系譜の継続 | 2026-01-01 | high |
IDXEOF
tbl_out="$IDXSBX/tbl.out"; tmp_files+=("$tbl_out")
printf '%s\n' "$IDX_PAGE_REL" | idx_run > "$tbl_out" 2>/dev/null
assert "TC-27 (T-01) index.md の hits が合計に載る (本文 1 + index 1)" "2" "$(sed -n 's/^\[CONTEXT\] WIKI_DESCRIPTIVE_REFS=//p' "$tbl_out")"
assert_grep "TC-27 (T-01) marker block に page=.rite/wiki/index.md 行が出る" "$tbl_out" '^page=\.rite/wiki/index\.md; hits=1$'
assert "TC-27 (T-01) descriptive_refs_pages は hits を持つ対象ファイル数のまま" "2" "$(sed -n 's/^descriptive_refs_pages=//p' "$tbl_out")"
# TC-28/29 は同じ 2 行の表で「拾う列」と「拾わない列」を同時に測る。片方だけの fixture だと
# 「全列を走査している」変異と「サマリー列だけ走査している」実装を区別できない。
assert "TC-28 (T-03) サマリー列の番号は 1 hit として数える" "1" "$(sed -n 's/^page=\.rite\/wiki\/index\.md; hits=//p' "$tbl_out")"
onlylink=$(printf '# Wiki Index\n\n| ページ | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [PR #77 の教訓](pages/patterns/a.md) | patterns | 番号を持たない説明文 | 2026-01-01 | high |\n')
printf '%s' "$onlylink" > "$IDXSBX/.rite/wiki/index.md"
assert "TC-29 (T-02) リンクテキスト列のみの番号は hits に数えない" "1" "$(idx_hits "$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>/dev/null)")"

# OKF 箇条書き形式。テーブル専用にすると、template と wiki-ingest が生成するこの形式へ
# 移行した時点で検出が無言で 0 件へ倒れる (本 helper が塞ごうとしている盲点と同型)。
printf '# Wiki Index\n\n* [Issue #99 を含むタイトル](pages/patterns/a.md) - 番号を持たない説明文\n* [番号なし](pages/patterns/b.md) - 詳細は #1151\n' > "$IDXSBX/.rite/wiki/index.md"
assert "TC-30 OKF 箇条書き形式でもサマリーだけを検出する" "1" "$(printf '%s' "$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>/dev/null)" | sed -n 's/^page=\.rite\/wiki\/index\.md; hits=//p')"

# T-07: 列数が壊れた行は「行全体を対象にする」のではなくスキップし、行番号つき WARNING を出す。
# 行全体へフォールバックするとリンクテキスト由来の番号が混ざり、誤検出で件数が膨らむ。
printf '# Wiki Index\n\n| ページ | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [PR #77 の教訓](pages/patterns/a.md) | patterns | 番号なし | broken |\n' > "$IDXSBX/.rite/wiki/index.md"
brk_err="$IDXSBX/brk.err"; tmp_files+=("$brk_err")
brk_out=$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>"$brk_err")
assert "TC-31 (T-07) 列数が壊れた行は hits に数えない" "1" "$(idx_hits "$brk_out")"
assert_grep "TC-31 (T-07) 列崩れは行番号つき WARNING で観測できる" "$brk_err" 'index\.md [0-9]+ 行目: テーブルの列数'

# 行数ガード: エントリ行はあるのに 1 件も抽出できない = 形式変更。無言の 0 件にせず WARNING を出す
# (位置依存の列パースが列の増減で全行 skip へ倒れる既知の失敗形。wiki: positional-parse-row-count-guard)。
printf '# Wiki Index\n\n| ページ | ドメイン | サマリー | 更新日 | 確信度 |\n|---|---|---|---|---|\n| [a](pages/patterns/a.md) | x |\n| [b](pages/patterns/b.md) | y |\n' > "$IDXSBX/.rite/wiki/index.md"
guard_err="$IDXSBX/guard.err"; tmp_files+=("$guard_err")
printf '%s\n' "$IDX_PAGE_REL" | idx_run >/dev/null 2>"$guard_err"
assert_grep "TC-32 全行の抽出に失敗したら行数ガードが WARNING を出す" "$guard_err" 'サマリーを 1 件も抽出できませんでした'

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
assert "TC-34 stdin 経由でも二重計上しない" "$(idx_hits "$(printf '%s\n' "$IDX_PAGE_REL" | idx_run 2>/dev/null)")" "$(idx_hits "$stdin_out")"

# T-09: 他カテゴリの非回帰は測定ではなく構成で担保する。ステップ 2.2 の pages_list は
# `pages/` 配下だけを拾ったままでなければならない。ここに index.md を混ぜると孤児検出
# (index 登録ページ ∖ pages_list) が index.md 自身を孤児として数え、AC-6 が即座に崩れる。
step22_re=$(grep -oE "grep -E '\^\\\\\.rite/wiki/pages/[^']*'" "$LINT_MD" | head -1)
if [ -z "$step22_re" ]; then
  fail "TC-35 (T-09) SKILL.md ステップ 2.2 の pages_list 抽出 regex を特定できなかった"
elif printf '%s' "$step22_re" | grep -q 'index'; then
  fail "TC-35 (T-09) ステップ 2.2 の pages_list に index.md が混ざっている (孤児 / 陳腐化の件数が変わる)"
else
  pass "TC-35 (T-09) ステップ 2.2 の pages_list は pages/ 配下のみ (他カテゴリの入力が不変)"
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

if ! print_summary "$(basename "$0")" \
  "drift: wiki-lint-descriptive-refs.sh の検出 / 除外が変わった可能性。SKILL.md ステップ 7.5 の委譲契約と helper 冒頭の検出 2 規則・除外 E1-E5 の記述を参照。"; then
  exit 1
fi
