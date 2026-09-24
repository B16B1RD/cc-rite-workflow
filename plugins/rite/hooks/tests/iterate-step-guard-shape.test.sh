#!/bin/bash
# /rite:iterate のシェルブロックが、native 入場した session worktree の隔離ガードを通る形
# （top-level の単一 `bash <file> <literal args>` 呼び出し）に留まっていることを固定する。
# ステップ本体は scripts/iterate-step.sh が持ち、SKILL.md は 1 行呼び出しと marker 分岐表だけを持つ。
# 形の規則は references/git-worktree-patterns.md の「入場後のガード拒否の退路」節が SoT。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$SCRIPT_DIR/../.."
ITERATE="$PLUGIN_ROOT/skills/iterate/SKILL.md"
STEP="$PLUGIN_ROOT/scripts/iterate-step.sh"

assert_file_exists_or_fail "iterate/SKILL.md exists" "$ITERATE" || exit 1
assert_file_exists_or_fail "iterate-step.sh exists" "$STEP" || exit 1

# ```bash ブロックごとに、コメント行を除き `\` 継続を連結した 1 論理行を出す（ブロック間は空行）。
blocks_of() {
  awk '
    function flush() { if (cur != "") { out = out (out == "" ? "" : "\n") cur }; cur = "" }
    /^```bash$/ { inb = 1; out = ""; cur = ""; cont = 0; next }
    inb && /^```$/ { flush(); print (out == "" ? "<empty>" : out); print ""; inb = 0; next }
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
  grep -oE '^bash \{plugin_root\}/scripts/iterate-step\.sh [a-z0-9-]+' "$1" | awk '{ print $3 }' | sort -u
}

step_subcommands() {
  awk '/^case "\$subcommand" in$/ { s = 1; next } s && /^esac$/ { exit }
       s && /^  [a-z0-9-]+\)/ { sub(/^  /, ""); sub(/\).*/, ""); print }' "$1" | sort -u
}

# --- 現行ファイルの形 ------------------------------------------------------------

n_blocks=$(block_count "$ITERATE")
# 下限は移設時点の ```bash ブロック数。0 件（抽出の空振り）や大量削除を fail にする。
if [ "$n_blocks" -ge 15 ]; then
  pass "iterate/SKILL.md has all bash blocks ($n_blocks)"
else
  fail "iterate/SKILL.md bash blocks dropped below 15 ($n_blocks)"
fi

violations=$(shape_violations "$ITERATE")
assert "every iterate bash block is a single top-level bash call" "" "$violations"

skill_subs=$(skill_subcommands "$ITERATE")
step_subs=$(step_subcommands "$STEP")
if [ -n "$step_subs" ]; then
  pass "iterate-step.sh dispatch lists subcommands"
else
  fail "iterate-step.sh dispatch lists subcommands (case \"\$subcommand\" の抽出が空)"
fi
assert "SKILL.md calls exactly the subcommands iterate-step.sh dispatches" "$step_subs" "$skill_subs"

# --- mutation: 検査が空振りしていないこと ----------------------------------------

MUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-iterate-shape-XXXXXX") || MUT_DIR=""
if [ -n "$MUT_DIR" ]; then
  trap 'rm -rf "$MUT_DIR"' EXIT

  # 2 文のブロック（source + 呼び出し）を注入すると形の違反になる。
  awk '{ print } /^bash \{plugin_root\}\/scripts\/iterate-step\.sh restore$/ { print "source {plugin_root}/hooks/scripts/lib/context-marker.sh" }' \
    "$ITERATE" > "$MUT_DIR/two-statements.md"
  if assert_mutant_changed "two-statement block" "$ITERATE" "$MUT_DIR/two-statements.md"; then
    if [ -n "$(shape_violations "$MUT_DIR/two-statements.md")" ]; then
      pass "a two-statement block is reported"
    else
      fail "a two-statement block is reported"
    fi
  fi

  # 1 行でもコマンド置換を含めば違反になる。
  sed 's#^bash {plugin_root}/scripts/iterate-step\.sh restore$#x=$(bash {plugin_root}/scripts/iterate-step.sh restore)#' \
    "$ITERATE" > "$MUT_DIR/substitution.md"
  if assert_mutant_changed "command substitution" "$ITERATE" "$MUT_DIR/substitution.md"; then
    if [ -n "$(shape_violations "$MUT_DIR/substitution.md")" ]; then
      pass "a command substitution is reported"
    else
      fail "a command substitution is reported"
    fi
  fi

  # dispatch に無いサブコマンドを呼ぶと集合が一致しない。
  sed 's#^bash {plugin_root}/scripts/iterate-step\.sh restore$#bash {plugin_root}/scripts/iterate-step.sh restore-typo#' \
    "$ITERATE" > "$MUT_DIR/unknown-sub.md"
  if assert_mutant_changed "unknown subcommand" "$ITERATE" "$MUT_DIR/unknown-sub.md"; then
    if [ "$(skill_subcommands "$MUT_DIR/unknown-sub.md")" != "$step_subs" ]; then
      pass "an unregistered subcommand is reported"
    else
      fail "an unregistered subcommand is reported"
    fi
  fi
else
  fail "mutant workspace could not be created (mktemp -d)"
fi

# --- iterate-step.sh の fail-loud ------------------------------------------------

run_step() {
  bash "$STEP" "$@" >/dev/null 2>&1
}

run_step; assert "no subcommand exits 2" "2" "$?"
run_step no-such-step; assert "unknown subcommand exits 2" "2" "$?"
run_step nb-sweep-collect; assert "missing required --pr exits 2" "2" "$?"
run_step nb-sweep-collect --pr; assert "option without a value exits 2" "2" "$?"
run_step nb-sweep-collect --pr '{pr_number}'; assert "unsubstituted placeholder exits 2" "2" "$?"
run_step nb-sweep-collect --pr 12a; assert "non-numeric --pr exits 2" "2" "$?"
run_step nb-sweep-collect --pr 1 --bogus x; assert "unknown option exits 2" "2" "$?"

if ! print_summary "$(basename "$0")" \
  "iterate のシェルブロック形の契約。ステップ本体は plugins/rite/scripts/iterate-step.sh、形の規則は plugins/rite/references/git-worktree-patterns.md が SoT。"; then
  exit 1
fi
