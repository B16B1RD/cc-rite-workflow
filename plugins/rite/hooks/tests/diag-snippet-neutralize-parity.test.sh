#!/bin/bash
# Tests for jq / コマンド stderr 診断スニペット emission site の
# control-char 中和の横展開 parity を静的に pin する。
#
# Purpose:
#   flow-state.sh で導入された「診断スニペットは
#   neutralize_ctrl を経由して emit する」規約を、hooks/ と scripts/ 配下の全
#   `head -3` emission site に対称適用したことを保証する
#   (Wiki 経験則 Asymmetric Fix Transcription — 対称位置への伝播漏れ防止)。
#   sweep は `head -3` 限定ではなく `head -N` / `head -n N` (任意行数・両綴り)
#   を対象とする — literal パターン限定の sweep は数値違い (head -5) や
#   綴り違い (head -n 10) の同型イディオムを構造的に見逃すことが
#   実証されている (Asymmetric Fix Transcription の変種)。
#   同じ理由で `tail -N` と `sed -n 'N,Mp'` (行範囲) も対象に含める。
#   将来 hook に新しい行指向 head / tail / sed 診断 site が中和なしで追加された
#   場合も TC-1 が検出する。
#
# Test cases:
#   TC-1: hooks/ と scripts/ 配下 (tests/ 除く) に neutralize_ctrl を経由しない
#         `head -N` / `tail -N` / `sed -n 'N,Mp'` 行指向 emission site が存在しない
#         (コメント行と、スクリプト自身のファイルを出す site は除外)。
#         sed 枝の式と sweep 式が `-n` / `-ne` / `-n -e` の各綴りに 1 件一致することを
#         self-test で固定する
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
#   TC-6: scripts/ の是正 site を実行し、ESC/C1 を含む複数行 stderr が
#         制御文字を残さず、行ごとの indent を維持する
#   TC-7: 同じ行の各出力を実 sweep と同じ述語で検査し、別の中和済み出力や
#         対象外コマンド・引用文・解析失敗で未中和出力が消えない
#   TC-8: 実sweep経路で引用引数・前置構文・置換内外の中和と既存対象外を確認
#
# Usage: bash plugins/rite/hooks/tests/diag-snippet-neutralize-parity.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HOOKS_DIR="$PLUGIN_ROOT/hooks"
SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
SWEEP_DIRS=("$HOOKS_DIR" "$SCRIPTS_DIR")

# 中和済みの別コマンドや引用文で、同じ行の未中和出力を除外しない。
unneutralized_sites() {
  PYTHONDONTWRITEBYTECODE=1 python3 -c 'import re
import sys
import importlib
from pathlib import Path

mode = sys.argv[1]
if mode not in {"line", "byte", "cat"}:
    sys.exit(2)
sys.path.insert(0, sys.argv[2])
scope = importlib.import_module("review-fix-scope")


def target_args(words):
    index = scope._prefix_end(words)
    if index == len(words):
        return None
    word, args = words[index], scope._without_redirections(words[index + 1:])
    if mode == "cat":
        return (word, args, 0) if word == "cat" else None
    if word in {"head", "tail"}:
        if mode == "byte":
            if word == "head" and len(args) >= 2 and args[0] == "-c" and args[1].isdigit():
                return word, args, 2
        elif args and re.fullmatch(r"-\d+", args[0]):
            return word, args, 1
        elif len(args) >= 2 and args[0] == "-n" and args[1].isdigit():
            return word, args, 2
    if mode == "line" and word == "sed" and args and args[0] in {"-n", "-ne"}:
        count = 3 if len(args) > 1 and args[1] == "-e" else 2
        if len(args) >= count and re.match(r"\d+,\d+p", args[count - 1]):
            return word, args, count
    return None


def stdout_redirect(words):
    # fdの複製は、その時点の出力先を保持する。最後の記法だけでは判定しない。
    destinations = {}
    for index, word in enumerate(words):
        if not isinstance(word, scope._Redirection):
            continue
        match = re.fullmatch(r"([0-9]*|&)(>>|>&|>)(.*)", word)
        if match:
            target = match[3] or (words[index + 1] if index + 1 < len(words) else "")
            alias = {"/dev/stdin": 0, "/dev/stdout": 1, "/dev/stderr": 2}.get(target)
            fd_path = re.fullmatch(r"(?:/dev/fd/|/proc/self/fd/)([0-9]+)", target)
            if fd_path:
                alias = int(fd_path[1])
            if match[2] == ">&" and re.fullmatch(r"[0-9]+", target):
                alias = int(target)
            destination = destinations.get(alias, alias) if alias is not None else ("file", target)
            if "$" in target or marker_prefix in target:
                destination = ("unknown", target)
            if match[1] == "&":
                destinations[1] = destinations[2] = destination
            else:
                destinations[int(match[1] or "1")] = destination
    destination = destinations.get(1, 1)
    return None if destination == 1 else destination


def stdin_redirect(words):
    return any(isinstance(word, scope._Redirection) and
               re.match(r"0?<", word) for word in words)


def fragments(code, owner="", parent=None, slot=None):
    parts, outer, quote, index = [], [], None, 0
    while index < len(code):
        ch = code[index]
        if ch == "\\" and quote != "single":
            outer.append(code[index:index + 2])
            index += 2
            continue
        if quote is None and ch == "#" and (index == 0 or code[index - 1] in " \t;&|()"):
            outer.append(code[index:])
            break
        if quote != "single" and (code.startswith("$(", index) or ch == chr(96)):
            if ch == chr(96):
                end = code.find(chr(96), index + 1)
                if end < 0:
                    raise ValueError("unfinished command substitution")
                inner, end = code[index + 1:end], end + 1
            else:
                end = scope._substitution_end(code, index + 2)
                inner = code[index + 2:end - 1]
            marker = marker_prefix + str(index) + "__"
            assignment = re.search(r"(?:^|[;&|])\s*(lock_pid|stored_token)=\s*$", code[:index])
            inner_owner = assignment[1] if assignment and quote is None else ""
            parts.extend(fragments(inner, inner_owner, outer, marker))
            outer.append(marker)
            index = end
            continue
        if ch == chr(39) and quote != "double":
            quote = None if quote == "single" else "single"
        elif ch == chr(34) and quote != "single":
            quote = None if quote == "double" else "double"
        outer.append(ch)
        index += 1
    return parts + [(outer, "".join(outer), owner, parent, slot)]


for row in sys.stdin:
    row = row.rstrip("\n")
    if not row:
        continue
    match = re.match(r"(.*?):([0-9]+):(.*)", row)
    path, code = (match[1], match[3]) if match else ("fixture.sh", row)
    try:
        # 引用・escapeを取り除いても元入力と衝突しない置換slotを使う。
        original_letters = "".join(ch for ch in code if ch.isalnum() or ch == "_")
        marker_prefix = "__diag_sub_"
        while marker_prefix in original_letters:
            marker_prefix += "_"
        inherited, unsafe = {}, False
        for identity, fragment, owner, parent, slot in reversed(fragments(code)):
            inherited_safe = inherited.get((id(parent), slot), False)
            segments = scope.shell_segments(fragment)
            for index, (words, nested, before, after) in enumerate(segments):
                command_index = scope._prefix_end(words)
                command = words[command_index] if command_index < len(words) else ""
                downstream_safe, cursor = False, index
                while (cursor + 1 < len(segments) and segments[cursor][3] == "|"
                       and stdout_redirect(segments[cursor][0]) is None):
                    cursor += 1
                    downstream_words = segments[cursor][0]
                    first = scope._prefix_end(downstream_words)
                    if first < len(downstream_words) and downstream_words[first] == "neutralize_ctrl":
                        downstream_safe = True
                        break
                destination = stdout_redirect(words)
                safe = (inherited_safe or downstream_safe) and destination is None
                for word in words:
                    for marker in re.findall(re.escape(marker_prefix) + r"\d+__", word):
                        inherited[(id(identity), marker)] = safe or command == "neutralize_ctrl"
                target = target_args(words)
                if target is None:
                    continue
                word, args, count = target
                inputs = args[count:]
                if mode != "byte" and isinstance(destination, tuple) and destination[0] == "file":
                    continue
                if mode == "line" and inputs == ["\u0024{BASH_SOURCE[0]}"]:
                    continue
                if mode == "byte" and Path(path).name == "work-memory-lock.sh" and owner in {
                    "lock_pid", "stored_token"
                }:
                    continue
                if mode == "cat":
                    raw_args = words[command_index + 1:]
                    if (raw_args and isinstance(raw_args[0], scope._Redirection) and
                            raw_args[0] in {">&2", "1>&2"} and len(raw_args) > 1 and
                            isinstance(raw_args[1], scope._Redirection) and raw_args[1].startswith("<<")):
                        continue
                upstream_safe = False
                if index and before == "|" and not stdin_redirect(words):
                    prior = segments[index - 1][0]
                    first = scope._prefix_end(prior)
                    upstream_safe = first < len(prior) and prior[first] == "neutralize_ctrl"
                if not safe and not (word != "cat" and not inputs and upstream_safe):
                    unsafe = True
        if unsafe:
            print(row)
    except (ValueError, RuntimeError) as error:
        print(row)
        print(f"ERROR: diagnostic emission cannot be inspected: {path}: {error}", file=sys.stderr)
' "$1" "$PLUGIN_ROOT/hooks/scripts/lib"
}

has_ctrl_helper_call() {
  awk '
    /^[[:space:]]*#/ { next }
    /neutralize_ctrl|contains_ctrl/ { found = 1 }
    END { exit !found }
  ' "$1"
}

for sweep_dir in "${SWEEP_DIRS[@]}"; do
  if [ ! -d "$sweep_dir" ]; then
    echo "ERROR: $sweep_dir not found" >&2
    exit 1
  fi
done

echo "=== TC-1: head/tail -N / sed -n 'N,Mp' emission site は全て neutralize_ctrl を経由 ==="
# 除外: tests/ (fixture/assertion 内の出現)、コメント行、定義元 helper の usage コメント、
# スクリプト自身のファイル ("${BASH_SOURCE[0]}") だけを出す site (開発者が書いた静的テキストで
# 外部由来の制御文字を含まないため中和不要。usage() の自己ソース表示がこれに当たる)。
# `head`/`tail` の `-[0-9]+` / `-n [0-9]+` (行指向 snippet、両綴り) を対象とする。
# `tail` を含めるのは、python3 の未捕捉例外のように**根因が最終行に載る** stderr を出す site が
# あるため — sweep 対象を head だけに絞ると、そこへ移行した瞬間に中和が無検出で外れる。
# `sed -n 'N,Mp'` を含めるのは、不正行が多いとパイプバッファを超えて head が printf を SIGPIPE で
# 落とすため、入力を最後まで読む sed の行範囲へ置き換えた site があるため — head/tail だけを
# 数えると、その置き換えで中和が無検出で外れる。
# `head -c` (byte 指向 inline 埋め込み) は 1 行 WARNING への embed で行構造が異なる
# 別イディオムのため本 sweep の対象外 — TC-3 が head -c 全行を fail-closed sweep する
# (非 emission site は明示 allowlist で除外、中和を横展開済み)。
# `>&2` が log() 等の関数内部に隠れて同一行に現れない emission 経路は静的 sweep で
# 構造的に検出できないため、TC-5 が既知 site を個別に pin する
# sweep 正規表現と emission site の絞り込みは floor guard と共有する。literal を二重に持つと、
# 片方だけ腕を落とす変異・除外を広げる変異をもう片方が検出できない (初版の floor guard が
# 実際にそうだった)。共有しても、除外の拡大を floor guard が検出するのは腕の実 site がすべて
# 外れるときに限る。sed 枝は `-n` / `-ne` / `-n -e` の綴り違いも拾う。
SED_RANGE_RE='sed +-n?e? +(-e +)?.?[0-9]+,[0-9]+p'
SWEEP_RE="(head|tail) (-[0-9]+|-n +[0-9]+) |$SED_RANGE_RE"
# 実 site にこの綴り違いが無くても、式を旧形へ戻す変異を検出できるよう、sed 枝の式と合成後の
# sweep 式の両方で綴りごとに 1 件一致を確かめる。
for sed_spelling in "sed -n '1,3p'" "sed -ne '1,3p'" "sed -n -e '1,3p'"; do
  for sed_re_name in SED_RANGE_RE SWEEP_RE; do
    sed_spelling_hits=$(printf '%s\n' "$sed_spelling" | grep -cE "${!sed_re_name}") || sed_spelling_hits=0
    case "$sed_spelling_hits" in ''|*[!0-9]*) sed_spelling_hits=0 ;; esac
    if [ "$sed_spelling_hits" = 1 ]; then
      pass "$sed_re_name self-test: $sed_spelling に 1 件一致する"
    else
      fail "$sed_re_name self-test: $sed_spelling に 1 件一致しない (hits=$sed_spelling_hits) — sed 枝がこの綴りを拾えない"
    fi
  done
done
sweep_emission_sites() {
  case "${1:-line}" in
    line)
      grep -rnE "$SWEEP_RE" "${SWEEP_DIRS[@]}" --include='*.sh' \
      | grep '>&2' \
      | grep -vE '^[^:]+/tests/' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
      ;;
    byte)
      grep -rnE 'head -c [0-9]+' "${SWEEP_DIRS[@]}" --include='*.sh' \
      | grep -vE '^[^:]+/tests/' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
      || true
      ;;
    cat)
      grep -rnE '(^[[:space:]]*|[;|&{][[:space:]]*)cat [^|;&]*(1)?>&2' "${SWEEP_DIRS[@]}" --include='*.sh' \
      | grep -vE '^[^:]+/tests/' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
      || true
      ;;
    *) return 2 ;;
  esac
}

# 実 sweep と合成ファイルの検査に同じ収集・判定経路を使う。
inspect_emission_sites() {
  sweep_emission_sites "$1" | unneutralized_sites "$1"
}

emission_sites=$(sweep_emission_sites || true)
if ! violations=$(inspect_emission_sites line); then
  fail "TC-1: diagnostic emission inspection failed"
fi
assert "TC-1: un-neutralized head/tail -N / sed -n 'N,Mp' emission sites" "" "$violations"
if [ -n "$violations" ]; then
  echo "  検出された未中和 site (head/tail -N / sed -n 'N,Mp' の直後に '| neutralize_ctrl --keep-newline' を挿入すること):"
  printf '%s\n' "$violations" | sed 's/^/    /'
fi

# 各腕が実 site を拾えていることを pin (TC-2 の floor guard と同型)。TC-1 は violations が空で
# あることだけを assert する fail-closed sweep なので、式から腕が落ちても、除外が広がって実 site
# まで外れても Green のまま通る。violations と同じ絞り込みで数えることで、腕が落ちる変異と、除外が
# 腕の実 site をすべて外すまで広がる変異は本 guard の失敗になる。下限は 1 件なので、腕の実 site の
# 一部だけを外す拡大 (scripts/ の一部だけを外す拡大を含む) は検出しない。scripts/ の母集団は、
# SWEEP_DIRS から "$SCRIPTS_DIR" を削る変異を violations の偶然の空集合に依存せず検出するために数える。
tail_pop=$(printf '%s\n' "$emission_sites" | grep -c 'tail ') || tail_pop=0
case "$tail_pop" in ''|*[!0-9]*) tail_pop=0 ;; esac
if [ "$tail_pop" -ge 1 ]; then
  pass "TC-1 floor: tail 腕が実 site を $tail_pop 件カバーしている"
else
  fail "TC-1 floor: tail 腕のカバー site が 0 件 — 正規表現から tail が落ちても、除外が広がっても violations は空のままで回帰が不可視になる"
fi

sed_pop=$(printf '%s\n' "$emission_sites" | grep -cE "$SED_RANGE_RE") || sed_pop=0
case "$sed_pop" in ''|*[!0-9]*) sed_pop=0 ;; esac
if [ "$sed_pop" -ge 1 ]; then
  pass "TC-1 floor: sed 腕が実 site を $sed_pop 件カバーしている"
else
  fail "TC-1 floor: sed 腕のカバー site が 0 件 — 正規表現から sed -n 'N,Mp' が落ちても、除外が広がっても violations は空のままで回帰が不可視になる"
fi

scripts_pop=$(printf '%s\n' "$emission_sites" | grep -cF "$SCRIPTS_DIR/") || scripts_pop=0
case "$scripts_pop" in ''|*[!0-9]*) scripts_pop=0 ;; esac
if [ "$scripts_pop" -ge 1 ]; then
  pass "TC-1 floor: scripts/ sweep が実 site を $scripts_pop 件カバーしている"
else
  fail "TC-1 floor: scripts/ のカバー site が 0 件 — SWEEP_DIRS から scripts/ を外す回帰が不可視になる"
fi

echo ""
echo "=== TC-2: neutralize_ctrl の caller は helper を source 済み ==="
# call-site 判定は大きなファイルでも入力を最後まで消費し、pipefail 下で producer を
# SIGPIPE にしない。先頭で一致した後も pipe buffer を超える入力を流して回帰を固定する。
tc2_probe=$(mktemp "${TMPDIR:-/tmp}/rite-diag-parity-tc2-XXXXXX")
{
  printf '%s\n' 'neutralize_ctrl "$value"'
  awk 'BEGIN { for (i = 0; i < 20000; i++) print "value=plain_text" }'
} > "$tc2_probe"
if has_ctrl_helper_call "$tc2_probe"; then
  pass "TC-2: call-site detection consumes large input without SIGPIPE"
else
  fail "TC-2: call-site detection lost a real caller under pipefail"
fi
rm -f "$tc2_probe"

# `neutralize_ctrl` / `contains_ctrl` を実行コードとして含むファイル一覧 (コメント行のみの言及は除外)
# 収集側も両関数対応にする — contains_ctrl のみを使う hook が将来追加された場合の検査漏れ防止
caller_files=$(grep -rlE 'neutralize_ctrl|contains_ctrl' "${SWEEP_DIRS[@]}" --include='*.sh' \
  | grep -v '/tests/' \
  | grep -v '/control-char-neutralize.sh$' \
  || true)
checked=0
for f in $caller_files; do
  # コメント行を除いた実 call site があるファイルのみ検査 (収集側 grep -rlE と書式統一)
  if ! has_ctrl_helper_call "$f"; then
    continue
  fi
  checked=$((checked + 1))
  # source 行は `source "$SCRIPT_DIR/..."` / `source "$(dirname "${BASH_SOURCE[0]}")/..."`
  # (path 内に入れ子クォートあり) / `source "$plugin_root"/hooks/...` (変数だけを引用し
  # path 末尾はクォートの外) の 3 形式を許容する
  assert_grep "TC-2: $(basename "$f") sources control-char-neutralize.sh" \
    "$f" 'source ".*control-char-neutralize\.sh"?'
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
if ! violations_c=$(inspect_emission_sites byte); then
  fail "TC-3: diagnostic emission inspection failed"
fi
assert "TC-3: un-neutralized head -c emission sites" "" "$violations_c"
if [ -n "$violations_c" ]; then
  echo "  検出された未中和 site (診断値を emission 前に default 'neutralize_ctrl' へ通すこと。新規 --c0-only は使用しない):"
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
if ! violations_cat=$(inspect_emission_sites cat); then
  fail "TC-4: diagnostic emission inspection failed"
fi
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
assert_grep "TC-5: flow-state unknown phase inline value is neutralized" \
  "$HOOKS_DIR/flow-state.sh" \
  'unknown phase: .*"\$phase" \| neutralize_ctrl\)'

echo ""
echo "=== TC-6: scripts/ 実 site は制御文字を中和し複数行 indent を維持 ==="
tc6_dir=$(mktemp -d "${TMPDIR:-/tmp}/rite-diag-parity-tc6-XXXXXX")
tc6_cleanup() { rm -rf -- "$tc6_dir"; }
trap tc6_cleanup EXIT
mkdir -p "$tc6_dir/bin" "$tc6_dir/repo/.git"
cat > "$tc6_dir/repo/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML
cat > "$tc6_dir/bin/gh" <<'SH'
#!/bin/bash
printf 'gh-esc\033one\ngh-c1\302\233two\ngh-raw\233three\n' >&2
exit 1
SH
chmod +x "$tc6_dir/bin/gh"
set +e
(cd "$tc6_dir/repo" && PATH="$tc6_dir/bin:$PATH" \
  bash "$SCRIPTS_DIR/watchdog-status-mismatch.sh" >"$tc6_dir/stdout" 2>"$tc6_dir/stderr")
tc6_rc=$?
set -e
assert "TC-6: watchdog failure contract preserved" "1" "$tc6_rc"
tc6_ctrl_hex=$(LC_ALL=C od -An -tx1 "$tc6_dir/stderr" | tr -d ' \n' \
  | grep -oE '(1b|9b)' || true)
assert "TC-6: ESC/C1 bytes are absent" "" "$tc6_ctrl_hex"
assert_grep "TC-6: ESC line remains indented" "$tc6_dir/stderr" '^  gh-esc\?one$'
tc6_stderr_hex=$(LC_ALL=C od -An -tx1 "$tc6_dir/stderr" | tr -d ' \n')
if [[ "$tc6_stderr_hex" == *"202067682d6331c23f74776f0a"* ]]; then
  pass "TC-6: UTF-8 C1 line remains indented"
else
  fail "TC-6: UTF-8 C1 line lost byte-wise replacement or indentation"
fi
assert_grep "TC-6: raw C1 line remains indented" "$tc6_dir/stderr" '^  gh-raw\?three$'
tc6_cleanup
trap - EXIT

echo ""
echo "=== TC-7: 同じ行の別コマンドは中和の証拠にしない ==="
for snippet in 'head -3' 'tail -n 3' "sed -n '1,3p'"; do
  mixed="$snippet \"\$safe\" | neutralize_ctrl >&2; $snippet \"\$raw\" >&2"
  actual=$(printf '%s\n' "$mixed" | unneutralized_sites line)
  assert "TC-7: mixed $snippet remains a violation" "$mixed" "$actual"
done
for mode in line byte cat; do
  case "$mode" in
    line) raw='head -3 "$raw" >&2'; safe='head -3 "$safe" | neutralize_ctrl >&2' ;;
    byte) raw='"$(head -c 20 "$raw")"'; safe='"$(head -c 20 "$safe" | neutralize_ctrl)"' ;;
    cat) raw='cat "$raw" >&2'; safe='neutralize_ctrl < "$safe" >&2' ;;
  esac
  mixed="$safe; $raw"
  actual=$(printf '%s\n' "$mixed" | unneutralized_sites "$mode")
  assert "TC-7: $mode mixed output remains a violation" "$mixed" "$actual"
  actual=$(printf '%s\n' "$safe; $safe" | unneutralized_sites "$mode")
  assert "TC-7: $mode fully neutralized output passes" "" "$actual"
  for marker in ' # neutralize_ctrl' '; printf "%s" "neutralize_ctrl"'; do
    marked="$raw$marker"
    actual=$(printf '%s\n' "$marked" | unneutralized_sites "$mode")
    assert "TC-7: $mode marker text cannot hide output: $marker" "$marked" "$actual"
  done
done
for excluded in 'head -3 "${BASH_SOURCE[0]}" >&2' 'lock_pid=$(head -c 20 "$lockdir/pid" 2>/dev/null)' 'cat >&2 <<EOF'; do
  case "$excluded" in
    head*) mode=line; unsafe='head -3 "$raw" >&2'; row_prefix='fixture.sh:1:' ;;
    lock_pid*) mode=byte; unsafe='value=$(head -c 20 "$raw")'; row_prefix='work-memory-lock.sh:1:' ;;
    cat*) mode=cat; unsafe='cat "$raw" >&2'; row_prefix='fixture.sh:1:' ;;
  esac
  actual=$(printf '%s\n' "$row_prefix$excluded" | unneutralized_sites "$mode")
  assert "TC-7: $mode known non-emission still passes" "" "$actual"
  mixed="$row_prefix$excluded; $unsafe"
  actual=$(printf '%s\n' "$mixed" | unneutralized_sites "$mode")
  assert "TC-7: $mode excluded command cannot hide another output" "$mixed" "$actual"
done
upstream='neutralize_ctrl < "$safe" | head -c 20'
actual=$(printf '%s\n' "$upstream" | unneutralized_sites byte)
assert "TC-7: upstream-neutralized stdin passes" "" "$actual"
raw_file='neutralize_ctrl < "$safe" | head -c 20 "$raw"'
actual=$(printf '%s\n' "$raw_file" | unneutralized_sites byte)
assert "TC-7: upstream neutralization cannot sanitize an independent file" "$raw_file" "$actual"
redirected='head -3 "$raw" >&2 | neutralize_ctrl'
actual=$(printf '%s\n' "$redirected" | unneutralized_sites line)
assert "TC-7: redirect before neutralization remains a violation" "$redirected" "$actual"
parse_bad='head -3 "$raw >&2 # neutralize_ctrl'
actual=$(printf '%s\n' "$parse_bad" | unneutralized_sites line 2>/dev/null)
assert "TC-7: parse failure remains a violation" "$parse_bad" "$actual"
if printf '%s\n' 'head -3 "$raw" >&2' | unneutralized_sites unknown >/dev/null 2>&1; then
  fail "TC-7: inspection failure must return nonzero"
else
  pass "TC-7: inspection failure returns nonzero"
fi


echo ""
echo "=== TC-8: 引用・前置構文・置換結果を実 sweep から検査 ==="
tc8_dir=$(mktemp -d "${TMPDIR:-/tmp}/rite-diag-sweep-XXXXXX")
tc8_cleanup() { rm -rf "$tc8_dir"; }
trap tc8_cleanup EXIT
check_sweep_fixture() {
  local fixture_mode=$1 expectation=$2 label=$3 code=$4 result
  printf '%s\n' "$code" > "$tc8_dir/emission.sh"
  if [[ "$code" == *'<<EOF'* ]]; then
    printf '%s\n' 'static text' 'EOF' >> "$tc8_dir/emission.sh"
  fi
  bash -n "$tc8_dir/emission.sh"
  result=$(SWEEP_DIRS=("$tc8_dir"); inspect_emission_sites "$fixture_mode")
  if [ "$expectation" = violation ]; then
    assert "$label" "$tc8_dir/emission.sh:1:$code" "$result"
  else
    assert "$label" "" "$result"
  fi
}
for code in 'if head -3 "$raw" >&2; then :; fi' 'if false; then :; elif head -3 "$raw" >&2; then :; fi' 'while head -3 "$raw" >&2; do :; break; done' 'until head -3 "$raw" >&2; do :; break; done' '! head -3 "$raw" >&2' 'command head -3 "$raw" >&2'; do
  check_sweep_fixture line violation "TC-8: prefixed line output $code" "$code"
done
check_sweep_fixture byte violation 'TC-8: command-prefixed substitution' 'value=$(command head -c 20 "$raw")'
check_sweep_fixture byte violation 'TC-8: backtick output remains a violation' 'echo "`head -c 20 "$raw"`" >&2'
check_sweep_fixture line violation 'TC-8: self source cannot exclude an independent file' 'head -3 "${BASH_SOURCE[0]}" "$raw" >&2'
for code in 'cat >&2 <<EOF' 'cat 1>&2 <<EOF'; do
  check_sweep_fixture cat safe "TC-8: static heredoc $code" "$code"
  check_sweep_fixture cat violation 'TC-8: static heredoc cannot hide raw cat' "$code; cat \"\$raw\" >&2"
done
for snippet in 'head -3' 'tail -n 3' "sed -n '1,3p'"; do
  quoted="$snippet \"\$raw\" \"|\" \"neutralize_ctrl\" >&2"
  check_sweep_fixture line violation "TC-8: quoted arguments $snippet" "$quoted"
  check_sweep_fixture line violation "TC-8: safe neighbor cannot hide quoted $snippet" "head -3 \"\$safe\" | neutralize_ctrl >&2; $quoted"
done
check_sweep_fixture byte violation 'TC-8: quoted byte arguments' 'head -c 20 "$raw" "|" "neutralize_ctrl" >&2'
for syntax in '$(head -c 20 "$safe")' '`head -c 20 "$safe"`'; do
  safe_outer="printf \"%s\" \"$syntax\" | neutralize_ctrl >&2"
  check_sweep_fixture byte safe 'TC-8: outer pipeline neutralizes captured stdout' "$safe_outer"
  check_sweep_fixture byte violation 'TC-8: outer pipeline cannot hide a separate raw capture' "$safe_outer; value=\$(head -c 20 \"\$raw\")"
done
check_sweep_fixture byte violation 'TC-8: stderr in capture bypasses outer neutralization' 'printf "%s" "$(head -c 20 "$raw" >&2)" | neutralize_ctrl >&2'
check_sweep_fixture line safe 'TC-8: discarded output cannot invalidate a safe diagnostic' 'head -3 "$raw" >/dev/null; head -3 "$safe" | neutralize_ctrl >&2'
check_sweep_fixture line violation 'TC-8: discarded output cannot hide raw diagnostic' 'head -3 "$raw" >/dev/null; head -3 "$raw" >&2'
check_sweep_fixture line violation 'TC-8: last stdout redirect determines diagnostic output' 'head -3 "$raw" >/dev/null >&2'
check_sweep_fixture cat safe 'TC-8: discarded cat cannot invalidate static heredoc' 'cat "$raw" >/dev/null; cat >&2 <<EOF'
check_sweep_fixture cat violation 'TC-8: discarded cat cannot hide raw cat' 'cat "$raw" >/dev/null; cat "$raw" >&2'
check_sweep_fixture byte violation 'TC-8: stdin redirect replaces neutralized upstream' 'neutralize_ctrl < "$safe" | head -c 20 < "$raw" >&2'
check_sweep_fixture byte safe 'TC-8: unchanged neutralized upstream passes' 'neutralize_ctrl < "$safe" | head -c 20 >&2'
check_sweep_fixture byte violation 'TC-8: intermediate stderr bypasses downstream neutralization' 'printf "%s" "$(head -c 20 "$raw")" | sed "s/^/  /" >&2 | neutralize_ctrl'
check_sweep_fixture byte safe 'TC-8: intermediate stdout reaches downstream neutralization' 'printf "%s" "$(head -c 20 "$safe")" | sed "s/^/  /" | neutralize_ctrl >&2'
for literal in '"__diag_sub_6__"' '__diag_\sub_6__' "'__diag_'\"sub_6__\""; do
  check_sweep_fixture byte violation 'TC-8: literal cannot neutralize a different capture' "echo \"\$(head -c 20 \"\$raw\")\" >&2; head -c 20 \"\$safe\" | neutralize_ctrl >&2; printf \"%s\" $literal | neutralize_ctrl >&2"
  check_sweep_fixture byte safe 'TC-8: literal cannot invalidate a neutralized capture' "echo \"\$(head -c 20 \"\$safe\")\" | neutralize_ctrl >&2; printf \"%s\" $literal >&2"
done
for snippet in 'head -3' 'tail -n 3' "sed -n '1,3p'"; do
  check_sweep_fixture line violation "TC-8: literal cannot hide a $snippet capture" "echo \"\$($snippet \"\$raw\")\" >&2; printf \"%s\" \"__diag_sub_6__\" | neutralize_ctrl >&2"
done
for snippet in 'head -3' 'tail -n 3' "sed -n '1,3p'" 'cat'; do
  case "$snippet" in cat) mode=cat ;; *) mode=line ;; esac
  for destination in '> /dev/stderr' '>&02' '>&1' '> /dev/fd/2' '> /proc/self/fd/2'; do
    raw_alias="$snippet \"\$raw\" >&2 $destination"
    check_sweep_fixture "$mode" violation "TC-8: stderr alias remains a diagnostic $snippet $destination" "$raw_alias"
    check_sweep_fixture "$mode" violation 'TC-8: safe neighbor cannot hide stderr alias' "head -3 \"\$safe\" | neutralize_ctrl >&2; $raw_alias"
  done
done
check_sweep_fixture line safe 'TC-8: stdout self-duplication still reaches neutralization' 'head -3 "$safe" >&1 | neutralize_ctrl >&2'
check_sweep_fixture line safe 'TC-8: fd alias uses the destination at duplication time' 'head -3 "$raw" 2>/dev/null >&2; head -3 "$safe" | neutralize_ctrl >&2'
check_sweep_fixture line violation 'TC-8: copied stderr fd remains diagnostic' 'head -3 "$raw" 3>&2 >&3'
check_sweep_fixture line violation 'TC-8: unresolved fd cannot prove non-diagnostic output' 'fd=2; head -3 "$raw" >&2 >&"$fd"'
check_sweep_fixture line violation 'TC-8: unresolved path cannot prove non-diagnostic output' 'dest=/dev/stderr; head -3 "$raw" >&2 >"$dest"'
check_sweep_fixture line violation 'TC-8: captured path cannot prove non-diagnostic output' 'head -3 "$raw" >&2 >"$(printf "%s" /dev/stderr)"'
tc8_cleanup
trap - EXIT

if ! print_summary "$(basename "$0")" \
  "診断スニペット emission site を hooks/ または scripts/ に追加するときは control-char-neutralize.sh を source し、emission site の構造に応じて中和を挿入すること: \
TC-1 (head/tail -N / sed -n 'N,Mp' 行指向) は直後に '| neutralize_ctrl --keep-newline'; \
TC-3 (head -c byte 指向 embed) は改行を整形後に default '| neutralize_ctrl' (新規 --c0-only は禁止); \
TC-4 (cat full-file 直接 emission) は 'neutralize_ctrl --keep-newline < \"\$file\" >&2' へ置換; \
TC-5 (log()/surface_git_warnings() 等の関数内 >&2) は静的 sweep で検出不能のため中和適用後に本テストへ個別 pin を追記すること"; then
  exit 1
fi
