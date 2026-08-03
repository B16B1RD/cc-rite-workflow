#!/bin/bash
# Tests for jq / コマンド stderr 診断スニペット emission site の
# control-char 中和の横展開 parity を静的に pin する。
#
# Purpose:
#   flow-state.sh で導入された「診断スニペットは
#   neutralize_ctrl を経由して emit する」規約を、hooks/ 配下の全
#   `head -3` emission site に対称適用したことを保証する
#   (Wiki 経験則 Asymmetric Fix Transcription — 対称位置への伝播漏れ防止)。
#   sweep は `head -3` 限定ではなく `head -N` / `head -n N` (任意行数・両綴り)
#   を対象とする — literal パターン限定の sweep は数値違い (head -5) や
#   綴り違い (head -n 10) の同型イディオムを構造的に見逃すことが
#   実証されている (Asymmetric Fix Transcription の変種)。
#   将来 hook に新しい行指向 head 診断 site が中和なしで追加された
#   場合も TC-1 が検出する。
#
# Test cases:
#   TC-1: hooks/ 配下 (tests/ 除く) に neutralize_ctrl を経由しない
#         `head -N` 行指向 emission site が存在しない (コメント行は除外)
#   TC-2: neutralize_ctrl を call する全 hook ファイルが
#         control-char-neutralize.sh を source している
#         (定義元 control-char-neutralize.sh 自身は除外)
#   TC-3: `head -c N` byte 指向 inline 埋め込み (1 行 WARNING への embed) も
#         neutralize_ctrl を経由する (follow-up 横展開)
#   TC-4: `cat ... >&2` 形式の full-file 直接 emission も neutralize_ctrl
#         を経由する。TC-3 と対称の fail-closed sweep:
#         unquoted (`cat $f >&2`) / `1>&2` 綴り / 複数引数 (`cat "$a" "$b" >&2`)
#         も検出する。cat を command 位置に anchor して散文中の "cat" 語を構造的に
#         除外し、静的 heredoc は allowlist で除外する。subshell/group redirect 等の
#         構造的死角は TC-4 ブロックのコメント参照 (fail-open 余地の閉塞)
#   TC-5: `>&2` が log() / surface_git_warnings() 等の関数内部に隠れる emission
#         経路は静的 sweep で構造的に検出不能のため、既知 site を個別に pin する
#
# Usage: bash plugins/rite/hooks/tests/diag-snippet-neutralize-parity.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HOOKS_DIR="$PLUGIN_ROOT/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
  echo "ERROR: $HOOKS_DIR not found" >&2
  exit 1
fi

echo "=== TC-1: head/tail -N emission site は全て neutralize_ctrl を経由 ==="
# 除外: tests/ (fixture/assertion 内の出現)、コメント行、定義元 helper の usage コメント
# `head`/`tail` の `-[0-9]+` / `-n [0-9]+` (行指向 snippet、両綴り) を対象とする。
# `tail` を含めるのは、python3 の未捕捉例外のように**根因が最終行に載る** stderr を出す site が
# あるため — sweep 対象を head だけに絞ると、そこへ移行した瞬間に中和が無検出で外れる。
# `head -c` (byte 指向 inline 埋め込み) は 1 行 WARNING への embed で行構造が異なる
# 別イディオムのため本 sweep の対象外 — TC-3 が head -c 全行を fail-closed sweep する
# (非 emission site は明示 allowlist で除外、中和を横展開済み)。
# `>&2` が log() 等の関数内部に隠れて同一行に現れない emission 経路は静的 sweep で
# 構造的に検出できないため、TC-5 が既知 site を個別に pin する
# sweep 正規表現は floor guard と共有する。literal を二重に持つと、片方だけ腕を落とす変異を
# もう片方が検出できない (初版の floor guard が実際にそうだった)。
SWEEP_RE='(head|tail) (-[0-9]+|-n +[0-9]+) '
violations=$(grep -rnE "$SWEEP_RE" "$HOOKS_DIR" --include='*.sh' \
  | grep '>&2' \
  | grep -v "$HOOKS_DIR/tests/" \
  | grep -v 'neutralize_ctrl' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  || true)
assert "TC-1: un-neutralized head/tail -N emission sites" "" "$violations"
if [ -n "$violations" ]; then
  echo "  検出された未中和 site (head/tail -N の直後に '| neutralize_ctrl --keep-newline' を挿入すること):"
  printf '%s\n' "$violations" | sed 's/^/    /'
fi

# sweep 正規表現が tail site を実際に拾えていることを pin (TC-2 の floor guard と同型)。
# TC-1 は violations が空であることだけを assert する fail-closed sweep なので、式から tail が
# 落ちても Green のまま通る。$SWEEP_RE を共有して数えることで腕の消失が本 guard の失敗になる。
tail_pop=$(grep -rnE "$SWEEP_RE" "$HOOKS_DIR" --include='*.sh' \
  | grep '>&2' \
  | grep -v "$HOOKS_DIR/tests/" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -c 'tail ') || tail_pop=0
case "$tail_pop" in ''|*[!0-9]*) tail_pop=0 ;; esac
if [ "$tail_pop" -ge 1 ]; then
  pass "TC-1 floor: tail 腕が実 site を $tail_pop 件カバーしている"
else
  fail "TC-1 floor: tail 腕のカバー site が 0 件 — 正規表現から tail が落ちても violations は空のままで回帰が不可視になる"
fi

echo ""
echo "=== TC-2: neutralize_ctrl の caller は helper を source 済み ==="
# `neutralize_ctrl` / `contains_ctrl` を実行コードとして含むファイル一覧 (コメント行のみの言及は除外)
# 収集側も両関数対応にする — contains_ctrl のみを使う hook が将来追加された場合の検査漏れ防止
caller_files=$(grep -rlE 'neutralize_ctrl|contains_ctrl' "$HOOKS_DIR" --include='*.sh' \
  | grep -v "$HOOKS_DIR/tests/" \
  | grep -v '/control-char-neutralize.sh$' \
  || true)
checked=0
for f in $caller_files; do
  # コメント行を除いた実 call site があるファイルのみ検査 (収集側 grep -rlE と書式統一)
  if ! grep -vE '^[[:space:]]*#' "$f" | grep -qE 'neutralize_ctrl|contains_ctrl'; then
    continue
  fi
  checked=$((checked + 1))
  # source 行は `source "$SCRIPT_DIR/..."` と `source "$(dirname "${BASH_SOURCE[0]}")/..."`
  # の両形式 (path 内に入れ子クォートあり) を許容する
  assert_grep "TC-2: $(basename "$f") sources control-char-neutralize.sh" \
    "$f" 'source ".*control-char-neutralize\.sh"'
done
# sweep 自体が空回りしていないことを pin (rollout 対象は 24 ファイル以上)
if [ "$checked" -ge 24 ]; then
  pass "TC-2: sweep coverage ($checked caller files checked)"
else
  fail "TC-2: sweep coverage too small ($checked files — rollout 対象が grep から漏れている可能性)"
fi

echo ""
echo "=== TC-3: head -c byte 指向 embed site は全て neutralize_ctrl を経由 ==="
# `head -c N` snippet の大半は `var=$(... | head -c 200 ...)` の代入行で、emission の
# `>&2` は後続 echo 行に分離している — `>&2` 同一行条件では構造的に検出できない
# (mutation 検証で実証)。そのため head -c 全行を sweep し、非 emission の
# 既知 site のみ明示 allowlist で除外する fail-closed 設計とする。新規の head -c が
# 非 emission 用途なら本 allowlist に追記すること。
violations_c=$(grep -rnE 'head -c [0-9]+' "$HOOKS_DIR" --include='*.sh' \
  | grep -v "$HOOKS_DIR/tests/" \
  | grep -v 'neutralize_ctrl' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -v 'work-memory-lock.sh:.*lock_pid=' \
  | grep -v 'work-memory-lock.sh:.*stored_token=' \
  || true)
assert "TC-3: un-neutralized head -c emission sites" "" "$violations_c"
if [ -n "$violations_c" ]; then
  echo "  検出された未中和 site (head -c の直後に '| tr '\\''\\n'\\'' '\\'' '\\'' | neutralize_ctrl --c0-only' を挿入すること):"
  printf '%s\n' "$violations_c" | sed 's/^/    /'
fi

echo ""
echo "=== TC-4: cat full-file 直接 emission site は全て neutralize_ctrl を経由 ==="
# `cat <fileargs> >&2` 形式の full-file stderr 直接 emission (RITE_DEBUG triage 経路等)
# を sweep する。中和版は `neutralize_ctrl --keep-newline < "$file" >&2`。
#
# 旧 fail-open 版 (`cat "[^"]+" *>&2`) は double-quote 単一引数 + `>&2` 形のみ検出し、
# unquoted (`cat $f >&2`) / `1>&2` 綴り / 複数引数 (`cat "$a" "$b" >&2`) の同型 idiom を
# 構造的に見逃した。TC-3 と対称の fail-closed 設計へ拡張: `cat ... (>&2|1>&2)`
# を広く sweep し、非 emission の既知 site のみ明示 allowlist で除外する。新規の cat emission
# が非中和なら必ず検出され、非該当パターンを追加する場合は本 allowlist に追記すること。
#
# regex `(^[[:space:]]*|[;|&{][[:space:]]*)cat [^|;&]*(1)?>&2`:
#   - cat を **コマンド位置** に anchor する。すなわち content 行頭 (インデント許容) または
#     command 区切り (`;` / `|` / `&` / `{`) の直後にある cat のみを対象とする
#     (`grep -rnE` の regex は `path:line:` prefix を含まない **ファイル内容** に適用されるため
#     `^` は content 行頭を指す)。これにより `echo "...cat 成功だが..." >&2` のような
#     **散文中の "cat" 語** (cat コマンドではない) を構造的に除外でき、content-keyed allowlist を
#     増やす whack-a-mole を回避する。
#   - `[^|;&]*` で cat の後続 redirect が cat 自身のもの (後続コマンドの redirect でない) ことを
#     保証する (pipe/semicolon/ampersand を跨がない)。末尾 `(1)?>&2` で `>&2` / `1>&2` 両綴りを受ける。
#
# 既知の構造的死角 (cat-anchored sweep の限界、本 sweep では検出不能):
#   - subshell / group redirect: `(cat "$f") >&2` / `{ cat "$f"; } >&2` — redirect が cat ではなく
#     subshell / brace-group に付くため、cat 直後の `[^|;&]*(1)?>&2` 経路で `>&2` に到達しない。
#     これらは「散文」ではなく **本物の full-file emission** だが anchor では捕捉できない。
#     (一方 `{ cat "$f" >&2; }` のように redirect が cat に付く形は `{` 区切り経由で検出される)
#   - keyword 前置 inline: `then cat "$f" >&2` / `do cat "$f" >&2` — `then`/`do` は command 区切り
#     文字 (`;|&{`) でないため anchor から漏れる。
#   現状コードベースに上記 3 形の cat emission site はゼロ (grep 全数確認済)。将来追加された場合は
#   TC-5 と同様に個別 pin する必要がある (anchor に `(` 等を足すと散文除外と両立しないため非採用)。
#
# allowlist (非 emission の既知 site):
#   - `>&2[[:space:]]*<<`: 静的 heredoc の **redirect-first 綴り** (`cat >&2 <<EOF`)。開発者記述の
#     静的リテラルで untrusted control-char を含まないため中和不要。
#     なお body-first 綴り (`cat <<EOF >&2`) は本 allowlist では除外されず false positive になるが、
#     現状 hooks の **stderr 向け cat heredoc** は全て redirect-first のため実害はない
#     (stdout / tmpfile 向けの body-first heredoc は主 regex の `>&2` 要件で元々マッチしない。
#     追加で stderr 向け body-first heredoc を書く場合は本 allowlist を拡張する)。
violations_cat=$(grep -rnE '(^[[:space:]]*|[;|&{][[:space:]]*)cat [^|;&]*(1)?>&2' "$HOOKS_DIR" --include='*.sh' \
  | grep -v "$HOOKS_DIR/tests/" \
  | grep -v 'neutralize_ctrl' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE 'cat [^|;&]*(1)?>&2[[:space:]]*<<' \
  || true)
assert "TC-4: un-neutralized cat full-file emission sites" "" "$violations_cat"
if [ -n "$violations_cat" ]; then
  echo "  検出された未中和 site ('neutralize_ctrl --keep-newline < \"\$file\" >&2' へ置換すること):"
  printf '%s\n' "$violations_cat" | sed 's/^/    /'
fi

echo ""
echo "=== TC-5: 関数内 >&2 経由の既知 emission site は個別 pin ==="
# log() / surface_git_warnings() 内部の >&2 は同一行 sweep で構造的に検出できない。
# 中和を適用した既知 site が回帰しないことを行単位で pin する。
assert_grep "TC-5: wiki-ingest-commit.sh surface_git_warnings" \
  "$HOOKS_DIR/scripts/wiki-ingest-commit.sh" \
  'grep -iE .\^\(warning\|hint\|error\):. \| neutralize_ctrl --keep-newline'

if ! print_summary "$(basename "$0")" \
  "診断スニペット emission site を hook に追加するときは control-char-neutralize.sh を source し、emission site の構造に応じて中和を挿入すること: \
TC-1 (head/tail -N 行指向) は直後に '| neutralize_ctrl --keep-newline'; \
TC-3 (head -c byte 指向 embed) は '| tr '\\''\\n'\\'' '\\'' '\\'' | neutralize_ctrl --c0-only'; \
TC-4 (cat full-file 直接 emission) は 'neutralize_ctrl --keep-newline < \"\$file\" >&2' へ置換; \
TC-5 (log()/surface_git_warnings() 等の関数内 >&2) は静的 sweep で検出不能のため中和適用後に本テストへ個別 pin を追記すること"; then
  exit 1
fi
