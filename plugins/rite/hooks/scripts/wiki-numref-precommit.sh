#!/bin/bash
# rite workflow - Wiki number-reference pre-commit check
#
# Responsibility: fail-loud gate for uncommitted `.rite/wiki` diffs that still
# contain bare Issue/PR number tokens. Grammar lives only in
# number-reference-check.sh; this script prepares the tree (intent-to-add so
# untracked pages are in the diff, ignore-residue fail-loud) and calls that
# checker. Callers:
#   - skills/wiki-ingest/SKILL.md ステップ 5.0.n (LLM rewrite loop on hit)
#   - wiki-worktree-commit.sh (last write mouth; refuses to commit on hit/error)
#
# Usage:
#   bash wiki-numref-precommit.sh --repo-root <dir>
#
# --repo-root DIR  Walk DIR as the git tree that contains `.rite/wiki`
#                  (wiki worktree abs for separate_branch, `.` for same_branch).
#
# Output:
#   clean / hit → stdout  [CONTEXT] WIKI_INGEST_NUMREF=clean|hit
#   error       → stderr  [CONTEXT] WIKI_INGEST_NUMREF=error; reason=...
#   hit findings → stdout as file:line: matched line (from number-reference-check.sh)
#
# Exit codes:
#   0 clean
#   1 hit (number token in the uncommitted wiki diff)
#   2 error (sandbox-mask / stage_failed / ignored_paths / helper_missing /
#     check_failed / ignored_check_failed / usage)
# --- END HEADER ---

set -uo pipefail

REPO_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift; shift ;;
    --help|-h)
      sed -n '/^#/{/# --- END HEADER ---/q;p;}' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: wiki-numref-precommit.sh: unknown option: $1" >&2
      echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=usage" >&2
      exit 2
      ;;
  esac
done

case "$REPO_ROOT" in
  ''|"{"*"}")
    echo "ERROR: wiki-numref-precommit.sh: --repo-root が空か未置換です (repo-root='$REPO_ROOT')" >&2
    echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=usage" >&2
    exit 2
    ;;
esac

_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$_SCRIPT_DIR/number-reference-check.sh"
if [ ! -f "$check" ]; then
  echo "ERROR: number-reference-check.sh が見つかりません (path='$check')。検査せずに commit すると番号混入を止められないため中止します" >&2
  echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=helper_missing" >&2
  exit 2
fi

numref_tree="$REPO_ROOT"

# intent-to-add は git dir の index.lock を要する。sandbox が管理ディレクトリだけを read-only で
# マスクしていると stage_failed に落ち、その案内（.gitignore の negation）が原因と食い違うため先に判定する。
# git dir を解決できない木は解決失敗の診断を出したうえで、下の intent-to-add の失敗として報告する。
worktree_lib="$_SCRIPT_DIR/lib/worktree-git.sh"
if [ ! -f "$worktree_lib" ]; then
  echo "ERROR: lib/worktree-git.sh が見つかりません (path='$worktree_lib')。管理ディレクトリの書込可否を判定できないため中止します" >&2
  echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=helper_missing" >&2
  exit 2
fi
# shellcheck source=lib/worktree-git.sh
source "$worktree_lib"
numref_admin_rc=0
numref_admin_err=$(worktree_admin_writable "$numref_tree" 2>&1) || numref_admin_rc=$?
if [ "$numref_admin_rc" -ne 0 ]; then
  printf '%s\n' "$numref_admin_err" >&2
fi
if [ "$numref_admin_rc" -eq 1 ]; then
  echo "  原因候補: sandbox が git の管理ディレクトリを read-only でマスクしている" >&2
  echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=sandbox-mask" >&2
  exit 2
fi

# 新規ページ (untracked) を差分へ載せる。内容は stage しない intent-to-add で、
# index にはエントリだけが載り `git diff --cached` は空のまま。
numref_stage_rc=0
git -C "$numref_tree" add -N -- .rite/wiki || numref_stage_rc=$?
if [ "$numref_stage_rc" -ne 0 ]; then
  echo "ERROR: .rite/wiki の intent-to-add に失敗しました (rc=$numref_stage_rc)。新規ページが検査されないため commit しません" >&2
  echo "  原因候補: same_branch 戦略で .gitignore に '!.rite/wiki/' negation が未設定の可能性" >&2
  echo "  対処: root .gitignore に '!.rite/wiki/' と '!.rite/wiki/**' を追記する" >&2
  echo "    (置く位置は '.rite/wiki/' 除外行より後ろ。anchor '# <<< gitignore-wiki-section-end'" >&2
  echo "     があればその直後、無ければ末尾。前に置くと後勝ちで negation が効かない)" >&2
  echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=stage_failed; rc=$numref_stage_rc" >&2
  exit 2
fi

numref_ig_rc=0
numref_ignored=$(git -C "$numref_tree" -c core.quotePath=false ls-files --others --ignored --exclude-standard -- .rite/wiki) || numref_ig_rc=$?
if [ "$numref_ig_rc" -ne 0 ]; then
  echo "ERROR: ignore 残存の検査に失敗しました (git ls-files rc=$numref_ig_rc)。検査結果が不明なまま commit しません" >&2
  echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=ignored_check_failed; rc=$numref_ig_rc" >&2
  exit 2
fi
if [ -n "$numref_ignored" ]; then
  echo "ERROR: .rite/wiki 配下に gitignore されたままのファイルがあります。検査にも commit にも載らないため中止します" >&2
  numref_shown=$(printf '%s\n' "$numref_ignored" | head -5)
  printf '%s\n' "$numref_shown" | sed 's/^/    /' >&2
  [ "$(printf '%s\n' "$numref_ignored" | grep -c .)" -gt 5 ] && \
    echo "    (先頭 5 件のみ表示。直して再実行すると残りが出ます)" >&2
  numref_ci_rc=0
  numref_causes=$(printf '%s\n' "$numref_shown" \
    | git -C "$numref_tree" -c core.quotePath=false check-ignore -v --stdin) || numref_ci_rc=$?
  if [ -n "$numref_causes" ]; then
    echo "  原因: 以下の exclude ルールが効いています (<source>:<行>:<パターン> <TAB> <パス>)" >&2
    printf '%s\n' "$numref_causes" | sed 's/^/    /' >&2
  else
    echo "  原因: check-ignore が一致を返しませんでした (rc=$numref_ci_rc)。ls-files が ignore と" >&2
    echo "        判定した集合と食い違っています。git が診断を出していれば上の stderr にあります" >&2
    echo "        手動: git -C $numref_tree check-ignore -v -- <上記のファイル>" >&2
  fi
  numref_shown_n=$(printf '%s\n' "$numref_shown" | grep -c .)
  numref_cause_n=0
  [ -n "$numref_causes" ] && numref_cause_n=$(printf '%s\n' "$numref_causes" | grep -c .)
  if [ "$numref_ci_rc" -ne 0 ] || [ "$numref_cause_n" -lt "$numref_shown_n" ]; then
    echo "  注意: 表示 $numref_shown_n 件のうち $numref_cause_n 件しか原因を名指しできていません (check-ignore rc=$numref_ci_rc)" >&2
  fi
  echo "  対処: 名指しされた source を直す。nested .rite/.gitignore なら 3 行構成 '*' / '!wiki/' /" >&2
  echo "        '!wiki/**' へ戻す。root .gitignore なら '.rite/wiki/' 除外行より後ろに negation を" >&2
  echo "        追記する (root への追記では nested の '*' は解除できない)。source が" >&2
  echo "        .git/info/exclude や core.excludesFile なら、その該当行を外す" >&2
  echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=ignored_paths" >&2
  exit 2
fi

numref_rc=0
bash "$check" --repo-root "$numref_tree" --diff HEAD --path .rite/wiki --quiet || numref_rc=$?
case "$numref_rc" in
  0)
    echo "[CONTEXT] WIKI_INGEST_NUMREF=clean"
    exit 0
    ;;
  1)
    echo "[CONTEXT] WIKI_INGEST_NUMREF=hit"
    exit 1
    ;;
  *)
    echo "ERROR: number-reference-check.sh の実行に失敗しました (rc=$numref_rc)。検査結果が不明なまま commit しません" >&2
    echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=check_failed; rc=$numref_rc" >&2
    exit 2
    ;;
esac
