#!/bin/bash
# session worktree 入場後に隔離ガードがシェルブロックを拒否したとき、各スキルから既存の退路へ
# 到達できることを固定する。退路の手順そのものは git-worktree-patterns.md が SoT であり、
# スキル側は 1 行のポインタだけを持つ（複製すると drift 面が対象スキル数だけ増える）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

SKILLS_DIR="$SCRIPT_DIR/../../skills"
CONTRACT="$SCRIPT_DIR/../../references/git-worktree-patterns.md"

# 退路の手順本文を構成する語。スキル側の複製禁止（下のループ）と、契約側の実在
# （すぐ下）の両方に同じ配列を使う。片方だけで定義すると、契約の退路節が改稿されて
# 句が消えたとき複製禁止 assert が緑のまま無意味化する。
CLAUSES=(
  '置き場所はスクラッチ領域に限る'
  'bash \{script_path\}'
  'スクリプトファイルを書き出せない'
  'さらなる代替形を試さず停止'
)

# ポインタの指す先が実在すること（リンク切れ・節名変更の検出）。
# 契約が読めないまま進むと、契約側 assert が全件 file-not-found で埋まり欠損 1 件が
# assert 件数ぶんの fail に増幅して原因が埋もれる（`assert_file_exists_or_fail` の
# docstring が述べる増幅）。ここで止めると ❌ 1 行と rc=1 だけが残る（print_summary を
# 通らないため FAIL 集計行は出ない）。
assert_file_exists_or_fail "worktree execution contract exists" "$CONTRACT" || exit 1
assert_grep "contract has the Host worktree execution anchor" "$CONTRACT" \
  '^### Host worktree execution$'
assert_grep "contract carries the post-entry guard-refusal escape" "$CONTRACT" \
  '入場後のガード拒否の退路'
# 手順の各句はファイル全体ではなく退路節の内側に実在させる。ファイル全体を見ると、節を
# 丸ごと削っても判定表の行に残る同じ語を拾って緑のままになる。
# 節の開始は契約側の太字ラベル行に一致させる。`^### Host worktree execution$` を開始に
# 使うと、awk の範囲パターンでは開始行自身が終了パターン `^###[^#]` にも一致して範囲が
# 1 行に潰れる。
ESCAPE_SECTION='^\*\*入場後のガード拒否の退路\*\*'
for clause in "${CLAUSES[@]}"; do
  assert_grep_in_section "contract still defines the escape step ($clause)" "$CONTRACT" \
    "$ESCAPE_SECTION" '^###[^#]' "$clause"
done

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
  for clause in "${CLAUSES[@]}"; do
    assert_not_grep "$skill does not duplicate the escape procedure ($clause)" "$f" "$clause"
  done
done

# ポインタ検査が vacuous green でないこと: 行を落とした mutant で不在が検出できる。
#
# mutant の削除条件は $POINTER と独立させる（固定文字列で落とす）。同じパターンで削って
# 同じパターンで不在を確かめると grep -v の定義上つねに真になり、$POINTER が退路ポインタ
# 行ではなく別の行（全スキル共有の Host Runtime Contract 行など）に誤って一致していても
# 緑のままになる。独立させると、その取り違えは「削ったのに $POINTER がまだ一致する」
# として fail に現れる。
MUTANT_SRC="$SKILLS_DIR/iterate/SKILL.md"
MUTANT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-guard-pointer-mutant-XXXXXX") || MUTANT_DIR=""
if [ -n "$MUTANT_DIR" ]; then
  MUTANT="$MUTANT_DIR/SKILL.md"
  grep -Fv '「入場後のガード拒否の退路」に従う。' "$MUTANT_SRC" > "$MUTANT"
  if assert_mutant_changed "iterate pointer removal" "$MUTANT_SRC" "$MUTANT"; then
    if grep -qE "$POINTER" "$MUTANT"; then
      fail "iterate pointer removal is detected by the pointer assertion (POINTER が退路ポインタ行以外に一致している)"
    else
      pass "iterate pointer removal is detected by the pointer assertion"
    fi
  fi
  rm -rf "$MUTANT_DIR"
else
  fail "mutant workspace could not be created (mktemp -d)"
fi

if ! print_summary "$(basename "$0")" \
  "隔離ガード退路へのポインタの散文契約。退路の手順本体は plugins/rite/references/git-worktree-patterns.md が SoT。"; then
  exit 1
fi
