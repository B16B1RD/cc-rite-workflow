#!/bin/bash
# session worktree 入場後に隔離ガードがシェルブロックを拒否したとき、各スキルから既存の退路へ
# 到達できることを固定する。退路の手順そのものは git-worktree-patterns.md が SoT であり、
# スキル側は 1 行のポインタだけを持つ（複製すると drift 面が対象スキル数だけ増える）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

SKILLS_DIR="$SCRIPT_DIR/../../skills"
CONTRACT="$SCRIPT_DIR/../../references/git-worktree-patterns.md"

# ポインタの指す先が実在すること（リンク切れ・節名変更の検出）
assert_file_exists_or_fail "worktree execution contract exists" "$CONTRACT"
assert_grep "contract has the Host worktree execution anchor" "$CONTRACT" \
  '^### Host worktree execution$'
assert_grep "contract carries the post-entry guard-refusal escape" "$CONTRACT" \
  '入場後のガード拒否の退路'

POINTER='^> セッション worktree 入場後にシェルブロックがホストの隔離ガードに拒否されたら、\[共通作業先契約\]\(\.\./\.\./references/git-worktree-patterns\.md#host-worktree-execution\) の「入場後のガード拒否の退路」に従う。$'

# 対象は session worktree へ入場する、または入場後の作業先固定下でシェルブロックを回すスキル。
# ready / merge / pr-create は入場記述を持たない（worktree 配下の cwd 相対コピーを読まない旨のみ）。
# batch-run は sandbox 書込拒否に対する別系統の退路を既に持つ。
# cleanup は worktree 内でシェルを回すが、隔離ガードに対して委譲モード（CLEANUP_DELEGATED=1 で
# main checkout での再実行へ委ねる）という別系統の対処を設計済みのため、冒頭ポインタを重ねない。
SKILLS=(
  iterate
  pr-review
  fix
  open
  recover
  issue-implement
)

for skill in "${SKILLS[@]}"; do
  f="$SKILLS_DIR/$skill/SKILL.md"
  assert_file_exists_or_fail "$skill/SKILL.md" "$f" || continue
  assert_grep "$skill references the post-entry guard-refusal escape" "$f" "$POINTER"
  # 退路の手順は contract 側が SoT。スキルへ複製しない（複製すると drift 面が対象スキル数だけ増える）。
  # 禁止句は contract の退路節（箇条書き 6 点）から、手順の核を成す語を明示列挙する。
  for clause in \
    '置き場所はスクラッチ領域に限る' \
    'bash \{script_path\}' \
    'スクリプトファイルを書き出せない' \
    'さらなる代替形を試さず停止'; do
    assert_not_grep "$skill does not duplicate the escape procedure ($clause)" "$f" "$clause"
  done
done

# ポインタ検査が vacuous green でないこと: 行を落とした mutant で不在が検出できる
MUTANT_SRC="$SKILLS_DIR/iterate/SKILL.md"
MUTANT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-guard-pointer-mutant-XXXXXX") || MUTANT_DIR=""
if [ -n "$MUTANT_DIR" ]; then
  MUTANT="$MUTANT_DIR/SKILL.md"
  grep -vE "$POINTER" "$MUTANT_SRC" > "$MUTANT"
  if assert_mutant_changed "iterate pointer removal" "$MUTANT_SRC" "$MUTANT"; then
    if grep -qE "$POINTER" "$MUTANT"; then
      fail "iterate pointer removal is detected by the pointer assertion"
    else
      pass "iterate pointer removal is detected by the pointer assertion"
    fi
  fi
  rm -rf "$MUTANT_DIR"
else
  fail "mutant workspace could not be created (mktemp -d)"
fi
