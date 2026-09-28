#!/bin/bash
# /rite:pr-review のシェルブロックが、native 入場した session worktree の隔離ガードを通る形
# （top-level の単一 `bash <file> <literal args>` 呼び出し）に留まっていることを固定する。
# ステップ本体は scripts/pr-review-step.sh が持ち、SKILL.md は 1 行呼び出しと marker 分岐表だけを持つ。
# 番号付きリスト内のブロックは字下げされた fence に入るため、字下げ付きの fence も検査する。
# 形の規則は references/git-worktree-patterns.md の「入場後のガード拒否の退路」節が SoT。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$SCRIPT_DIR/../.."
REVIEW="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
STEP="$PLUGIN_ROOT/scripts/pr-review-step.sh"

assert_file_exists_or_fail "pr-review/SKILL.md exists" "$REVIEW" || exit 1
assert_file_exists_or_fail "pr-review-step.sh exists" "$STEP" || exit 1

# ```bash ブロックごとに、コメント行を除き `\` 継続を連結した 1 論理行を出す（ブロック間は空行）。
blocks_of() {
  awk '
    function flush() { if (cur != "") { out = out (out == "" ? "" : "\n") cur }; cur = "" }
    /^[[:space:]]*```bash$/ { inb = 1; out = ""; cur = ""; cont = 0; next }
    inb && /^[[:space:]]*```$/ { flush(); print (out == "" ? "<empty>" : out); print ""; inb = 0; next }
    inb && (/^[[:space:]]*#/ || /^[[:space:]]*$/) { next }
    inb {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (cont) { cur = cur line } else { flush(); cur = line }
      cont = 0
      if (cur ~ /\\$/) { sub(/[[:space:]]*\\$/, " ", cur); cont = 1 }
    }
  ' "$1"
}

# 1 行 = 1 呼び出し。引数は空白を含まない literal / 単一引用符 / `$`・backquote を含まない二重引用符に限る。
SHAPE='^bash \{plugin_root\}/[A-Za-z0-9_./-]+\.sh( ([^ ;&|$()`<>'"'"'"]+|'"'"'[^'"'"']*'"'"'|"[^"$`]*"))*( 2>&1)?( \|\| (true|exit [0-9]+))?$'

# 形に合わないブロックを 1 行ずつ出す（0 行なら全ブロック適合）。
shape_violations() {
  blocks_of "$1" | awk 'BEGIN { RS = ""; FS = "\n" } { n = NF; gsub(/\n/, " ; "); print n "\t" $0 }' |
    while IFS=$'\t' read -r nlines body; do
      if [ "$nlines" -ne 1 ] || ! grep -qE "$SHAPE" <<< "$body"; then
        printf '%s\n' "$body" | head -1
      fi
    done
}

block_count() {
  blocks_of "$1" | awk 'BEGIN { RS = "" } END { print NR }'
}

skill_subcommands() {
  grep -oE '^[[:space:]]*bash \{plugin_root\}/scripts/pr-review-step\.sh [a-z0-9-]+' "$1" | awk '{ print $NF }' | sort -u
}

# dispatch は最後の列 0 の `case "$subcommand" in`（手前の同形は引数検査の分岐）。
step_subcommands() {
  awk '/^case "\$subcommand" in$/ { s = 1; out = ""; next } s && /^esac$/ { s = 0 }
       s && /^  [a-z0-9-]+\)/ { sub(/^  /, ""); sub(/\).*/, ""); out = out $0 "\n" }
       END { printf "%s", out }' "$1" | sort -u
}

# --- 現行ファイルの形 ------------------------------------------------------------

n_blocks=$(block_count "$REVIEW")
# 下限は移設時点の ```bash ブロック数。0 件（抽出の空振り）や大量削除を fail にする。
if [ "$n_blocks" -ge 55 ]; then
  pass "pr-review/SKILL.md has all bash blocks ($n_blocks)"
else
  fail "pr-review/SKILL.md bash blocks dropped below 55 ($n_blocks)"
fi

violations=$(shape_violations "$REVIEW")
assert "every pr-review bash block is a single top-level bash call" "" "$violations"

skill_subs=$(skill_subcommands "$REVIEW")
step_subs=$(step_subcommands "$STEP")
if [ -n "$step_subs" ]; then
  pass "pr-review-step.sh dispatch lists subcommands"
else
  fail "pr-review-step.sh dispatch lists subcommands (case \"\$subcommand\" の抽出が空)"
fi
assert "SKILL.md calls exactly the subcommands pr-review-step.sh dispatches" "$step_subs" "$skill_subs"

# --- mutation: 検査が空振りしていないこと ----------------------------------------

MUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-pr-review-shape-XXXXXX") || MUT_DIR=""
if [ -n "$MUT_DIR" ]; then
  trap 'rm -rf "$MUT_DIR"' EXIT

  # 2 文のブロック（source + 呼び出し）を注入すると形の違反になる。
  awk '{ print } /^bash \{plugin_root\}\/scripts\/pr-review-step\.sh head-sha$/ { print "source {plugin_root}/hooks/scripts/lib/context-marker.sh" }' \
    "$REVIEW" > "$MUT_DIR/two-statements.md"
  if assert_mutant_changed "two-statement block" "$REVIEW" "$MUT_DIR/two-statements.md"; then
    if [ -n "$(shape_violations "$MUT_DIR/two-statements.md")" ]; then
      pass "a two-statement block is reported"
    else
      fail "a two-statement block is reported"
    fi
  fi

  # 字下げした fence 内の 2 文も違反になる（番号付きリスト内のブロックを検査から漏らさない）。
  awk '{ print } /^   bash \{plugin_root\}\/scripts\/pr-review-step\.sh tmp-dir$/ { print "   echo extra" }' \
    "$REVIEW" > "$MUT_DIR/indented.md"
  if assert_mutant_changed "indented two-statement block" "$REVIEW" "$MUT_DIR/indented.md"; then
    if [ -n "$(shape_violations "$MUT_DIR/indented.md")" ]; then
      pass "a two-statement block inside an indented fence is reported"
    else
      fail "a two-statement block inside an indented fence is reported"
    fi
  fi

  # 1 行でもコマンド置換を含めば違反になる。
  sed 's#^bash {plugin_root}/scripts/pr-review-step\.sh head-sha$#x=$(bash {plugin_root}/scripts/pr-review-step.sh head-sha)#' \
    "$REVIEW" > "$MUT_DIR/substitution.md"
  if assert_mutant_changed "command substitution" "$REVIEW" "$MUT_DIR/substitution.md"; then
    if [ -n "$(shape_violations "$MUT_DIR/substitution.md")" ]; then
      pass "a command substitution is reported"
    else
      fail "a command substitution is reported"
    fi
  fi

  # dispatch に無いサブコマンドを呼ぶと集合が一致しない。
  sed 's#^bash {plugin_root}/scripts/pr-review-step\.sh head-sha$#bash {plugin_root}/scripts/pr-review-step.sh head-sha-typo#' \
    "$REVIEW" > "$MUT_DIR/unknown-sub.md"
  if assert_mutant_changed "unknown subcommand" "$REVIEW" "$MUT_DIR/unknown-sub.md"; then
    if [ "$(skill_subcommands "$MUT_DIR/unknown-sub.md")" != "$step_subs" ]; then
      pass "an unregistered subcommand is reported"
    else
      fail "an unregistered subcommand is reported"
    fi
  fi
else
  fail "mutant workspace could not be created (mktemp -d)"
fi

# --- pr-review-step.sh の fail-loud ----------------------------------------------

run_step() {
  bash "$STEP" "$@" >/dev/null 2>&1
}

run_step; assert "no subcommand exits 2" "2" "$?"
run_step no-such-step; assert "unknown subcommand exits 2" "2" "$?"
run_step pr-view --owner-repo o/r; assert "missing required --pr exits 2" "2" "$?"
run_step pr-view --owner-repo; assert "option without a value exits 2" "2" "$?"
placeholder_err=$(bash "$STEP" pr-view --owner-repo o/r --pr '{pr_number}' 2>&1 >/dev/null)
assert "unsubstituted placeholder exits 2" "2" "$?"
case "$placeholder_err" in
  *"--pr received an unsubstituted placeholder"*) pass "the placeholder check names the option" ;;
  *) fail "the placeholder check names the option (stderr: $placeholder_err)" ;;
esac
run_step pr-view --owner-repo o/r --pr 12a; assert "non-numeric --pr exits 2" "2" "$?"
run_step pr-view --owner-repo o/r --pr 1 --bogus x; assert "unknown option exits 2" "2" "$?"
run_step state-update --result done --pr 1 --next x; assert "an unknown --result exits 2" "2" "$?"
# 数値検査の案内は実在するオプション名を出す（案内どおりに直せば再実行が通る）
numeric_err=$(bash "$STEP" wm-comment --owner-repo o/r --issue abc 2>&1 >/dev/null)
assert "a non-numeric --issue exits 2" "2" "$?"
case "$numeric_err" in
  *"--issue must be a number: abc"*) pass "the numeric check names --issue" ;;
  *) fail "the numeric check names --issue (stderr: $numeric_err)" ;;
esac
# 次のステップ節を空で置き換えないよう、--next-file が無ければどの更新よりも前に止まる
next_err=$(bash "$STEP" wm-record --issue 1 --next-file /nonexistent/rite-next-step.md 2>&1 >/dev/null)
assert "wm-record with a missing --next-file exits 2" "2" "$?"
case "$next_err" in
  *"--next-file is missing or empty: /nonexistent/rite-next-step.md"*) pass "wm-record names the missing --next-file" ;;
  *) fail "wm-record names the missing --next-file (stderr: $next_err)" ;;
esac

# 未置換・空値を自分の reason で報告する option は引数検査を通し、step が degraded を出す。
exempt_err=$(bash "$STEP" nonblocking-gate --pending-marker '{pending_marker}' 2>&1 >/dev/null)
assert "an exempt option keeps its placeholder for the step" "0" "$?"
case "$exempt_err" in
  *"NONBLOCKING_GATE=degraded; reason=pending_marker_placeholder_residue"*) pass "the step reports the placeholder residue itself" ;;
  *) fail "the step reports the placeholder residue itself (stderr: $exempt_err)" ;;
esac
empty_err=$(bash "$STEP" nonblocking-gate --pending-marker '' 2>&1 >/dev/null)
assert "an exempt option accepts an empty value" "0" "$?"
case "$empty_err" in
  *"NONBLOCKING_GATE=degraded; reason=pending_marker_unavailable"*) pass "the step reports the empty value itself" ;;
  *) fail "the step reports the empty value itself (stderr: $empty_err)" ;;
esac

if ! print_summary "$(basename "$0")" \
  "pr-review のシェルブロック形の契約。ステップ本体は plugins/rite/scripts/pr-review-step.sh、形の規則は plugins/rite/references/git-worktree-patterns.md が SoT。"; then
  exit 1
fi
