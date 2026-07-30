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
#   TC-8   frontmatter 散文に書かれた番号参照が hit しない (E1 の識別力)
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

SBX=$(make_plain_sandbox)
cleanup_dirs+=("$SBX")

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
# E1 の識別力は TC-8 の fixture (frontmatter 散文に番号参照を置く) が担う。mutant を拡張する際は
# 「どの除外がその mutant で到達不能か」を先に列挙すること。
MUT_NOFILTER="$SBX/mutant-nofilter.sh"
# フィルタ本体 (_RITE_BODY_FILTER) を「frontmatter 除去のみ」に差し替える
awk '
  /^_RITE_BODY_FILTER=.$/ { print "_RITE_BODY_FILTER='"'"'"; infilter=1; next }
  infilter && /^.$/ { print "NR==1 && /^---[[:space:]]*$/ { infm=1; next }"
                      print "infm && /^---[[:space:]]*$/  { infm=0; next }"
                      print "infm                        { next }"
                      print "{ print }"
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
assert "TC-1 キーワードなし裸 #N は hit しない" "0" "$(single_hits '#1234 の単独形は対象外')"
tc8_fm=$(printf -- '---\nnote: "PR #1300 の経緯"\n---\n\n# t\n\n本文に番号なし\n')
assert "TC-8 frontmatter 散文の番号参照は hit しない" "0" "$(single_hits "$tc8_fm")"

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
if make_mutant_sed() { sed "$1" "$SCRIPT" > "$2"; }; then :; fi
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
printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy '{branch_strategy}' --repo-root "$SBX" ) >/dev/null 2>&1
assert "TC-12 {branch_strategy} 残留 → exit 1" "1" "$?"
printf '%s\n' "$FIXTURE_REL" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy separate_branch --wiki-branch '{wiki_branch}' --repo-root "$SBX" ) >/dev/null 2>&1
assert "TC-12 {wiki_branch} 残留 → exit 1" "1" "$?"
printf '%s\n' "{pages_list}" | ( cd "$SBX" && bash "$SCRIPT" --branch-strategy same_branch --repo-root "$SBX" ) >/dev/null 2>&1
assert "TC-12 {pages_list} 残留 → exit 1" "1" "$?"

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
GITSBX=$(make_plain_sandbox)
cleanup_dirs+=("$GITSBX")
git_err=$(mktemp "${TMPDIR:-/tmp}/rite-tc19-git-err-XXXXXX") || git_err=""
tmp_files+=("${git_err:-}")
# git の rc / stderr を捨てない: 周囲の global 設定 (commit.gpgsign 等) で commit が失敗すると、
# 捨てた場合は「検出器が壊れた」形の assert 失敗だけが出て原因が surface しない。
# 署名の影響は `-c` で切る (git config によるファイル書き込みも不要になる)。
if (
  cd "$GITSBX" || exit 1
  git init -q . || exit 1
  mkdir -p .rite/wiki/pages/anti-patterns
  cp "$SBX/$FIXTURE_REL" ".rite/wiki/pages/anti-patterns/fixture.md"
  git add -A || exit 1
  git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t commit -qm fixture || exit 1
  git branch -q wiki || exit 1
  # fixture を blob 限定にする: ワークツリーに残すと --repo-root 配下で cat fallback でも
  # 同じ hits が取れてしまい、git show 経路を壊しても緑のままになる。
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

if ! print_summary "$(basename "$0")" \
  "drift: wiki-lint-descriptive-refs.sh の検出 / 除外が変わった可能性。SKILL.md ステップ 7.5 の委譲契約と helper 冒頭の検出 2 規則・除外 E1-E5 の記述を参照。"; then
  exit 1
fi
