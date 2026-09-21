#!/bin/bash
# rite workflow - Wiki Branch Init
#
# Responsibility: ステップ 2 で working tree に展開済みの `.rite/wiki/` を
# branch_strategy に応じて初期コミットする。
#   - separate_branch: orphan の wiki ブランチを作成して push し、元ブランチへ復帰する
#     (dirty tree は stash 退避/復帰、異常終了時も trap で元ブランチ復帰を保証)
#   - same_branch:     現在のブランチへそのままコミットする
#
# Called from:
#   - skills/wiki-init/SKILL.md ステップ 3.1 (旧 ~95 行 inline block を委譲)
#
# Usage:
#   bash wiki-branch-init.sh --branch-strategy <separate_branch|same_branch> --wiki-branch <name> [--message-file ABS]
#
# Output (stdout):
#   成功: "✅ Wiki ブランチ '<wiki_branch>' を作成しました" (separate_branch)
#         "✅ Wiki を現在のブランチに初期化しました" (same_branch)
#   失敗: "ERROR: ..." を stderr に出力
#
# Exit codes:
#   0  初期コミット完了
#   1  git 操作失敗 / 未知の branch_strategy / 引数異常 (leading-`-` の wiki_branch 拒否を
#      含む; 旧 inline block と同じ blocking 契約)
#
# Notes:
#   - 旧 inline block と同じく global `set -e` は使わない (各 git 操作の失敗を
#     個別メッセージ + exit 1 で明示ハンドリングする)。
#   - separate_branch の orphan 作成は untracked な `.rite/wiki/` がブランチ切替を
#     生き延びる git の挙動に依存する (stash push は untracked を退避しない)。
set -u

export GIT_TERMINAL_PROMPT=0
# Mirror wiki-worktree-commit.sh: avoid hangs on hosts without an ssh agent.
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

# --- 引数解析 (shift; shift — 値なしフラグ無限ループ素因を回避) ---
branch_strategy=""
wiki_branch=""
MESSAGE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch-strategy) branch_strategy="${2:-}"; shift; shift ;;
    --wiki-branch)     wiki_branch="${2:-}";     shift; shift ;;
    --message-file)    MESSAGE_FILE="${2:-}";    shift; shift ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: wiki-branch-init.sh --branch-strategy <separate_branch|same_branch> --wiki-branch <name> [--message-file ABS]" >&2
      exit 1
      ;;
  esac
done

# --- Leading-dash fail-fast gate ---
# wiki_branch は rite-config.yml の wiki.branch_name 由来 (開発者管理) だが、leading-`-` の
# 値は `git push origin` で refspec ではなく option として解釈される (例: `--force`; 実測)。
# `git checkout --orphan` 側は git 自身の branch name validation で fail するため実害はないが、
# エラー文言が本 helper の契約外経路になる。両 call site への到達前にここで引数異常として
# 統一的に fail-fast する (wiki-lint-skipped-refs.sh の placeholder residue gate と同型)。
case "$wiki_branch" in
  -*)
    echo "ERROR: --wiki-branch が '-' で始まる値は受け付けられません (値: '$wiki_branch')" >&2
    echo "  対処: rite-config.yml の wiki.branch_name を確認してください" >&2
    exit 1
    ;;
esac

# 共通の初期コミットメッセージ (separate_branch / same_branch で同一 — 旧 inline block から verbatim)
# 規約ファイルがあるときは --message-file 必須。解釈は LLM 側。orphan checkout の前に解決する。
_WIKI_INIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIKI_INIT_DEFAULT="feat(wiki): initialize Wiki structure

- 3-layer structure: Raw Sources / Wiki Pages / Schema
- Templates: SCHEMA.md, index.md, log.md
- Directories: raw/{reviews,retrospectives,fixes}, pages/{patterns,heuristics,anti-patterns}"
_default_file=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-init-default-XXXXXX") || {
  echo "ERROR: 既定メッセージ用一時ファイルを作成できません" >&2
  exit 1
}
_resolved_file=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-init-msg-XXXXXX") || {
  echo "ERROR: コミットメッセージ用一時ファイルを作成できません" >&2
  rm -f "$_default_file"
  exit 1
}
_rite_wiki_init_msg_cleanup() { rm -f "${_default_file:-}" "${_resolved_file:-}"; }
trap '_rite_wiki_init_msg_cleanup' EXIT INT TERM HUP
printf '%s\n' "$WIKI_INIT_DEFAULT" > "$_default_file"
_msg_args=(--default-file "$_default_file")
[ -n "$MESSAGE_FILE" ] && _msg_args+=(--message-file "$MESSAGE_FILE")
if ! bash "$_WIKI_INIT_DIR/commit-convention-message.sh" "${_msg_args[@]}" > "$_resolved_file"; then
  echo "ERROR: Wiki 初期コミットのメッセージを解決できません" >&2
  exit 1
fi
WIKI_INIT_COMMIT_MSG=$(cat "$_resolved_file")
_wiki_init_commit() {
  bash "$_WIKI_INIT_DIR/git-commit-file.sh" --file "$_resolved_file" || {
    echo "ERROR: git commit failed" >&2
    return 1
  }
}

if [ "$branch_strategy" = "separate_branch" ]; then
  if [ -z "$wiki_branch" ]; then
    echo "ERROR: --wiki-branch is required for separate_branch strategy" >&2
    exit 1
  fi

  current_branch=$(git branch --show-current)

  # cleanup trap: 異常終了時に元のブランチに復帰を保証
  # canonical signal-specific trap パターン (references/bash-trap-patterns.md 準拠)
  _rite_wiki_init_cleanup() {
    git checkout "$current_branch" 2>/dev/null || true
    if [ "${stash_needed:-false}" = true ]; then
      git stash pop 2>/dev/null || echo "WARNING: git stash pop failed in cleanup — manual recovery needed: git stash list" >&2
    fi
    _rite_wiki_init_msg_cleanup
  }
  trap 'rc=$?; _rite_wiki_init_cleanup; exit $rc' EXIT
  trap '_rite_wiki_init_cleanup; exit 130' INT
  trap '_rite_wiki_init_cleanup; exit 143' TERM
  trap '_rite_wiki_init_cleanup; exit 129' HUP

  # dirty tree チェック（未コミットの変更を保護）
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
    echo "WARNING: 未コミットの変更があります。git stash で退避します。"
    git stash push -m "rite-wiki-init-stash"
    stash_needed=true
  else
    stash_needed=false
  fi

  # orphan ブランチを作成
  git checkout --orphan "$wiki_branch" || {
    echo "ERROR: git checkout --orphan '$wiki_branch' failed" >&2
    exit 1
  }
  git rm -rf . 2>/dev/null || true

  # Wiki ファイルのみをステージング
  git add .rite/wiki/ || {
    echo "ERROR: git add .rite/wiki/ failed" >&2
    exit 1
  }

  _wiki_init_commit || exit 1

  git push origin "$wiki_branch" || {
    echo "ERROR: git push failed for branch '$wiki_branch'" >&2
    echo "  対処: gh auth status / ネットワーク接続 / リモートリポジトリの権限を確認してください" >&2
    exit 1
  }

  # 元のブランチに戻る
  git checkout "$current_branch" || {
    echo "ERROR: git checkout '$current_branch' failed — wiki ブランチ上に残っている可能性があります" >&2
    exit 1
  }

  # stash した場合のみ pop
  if [ "$stash_needed" = true ]; then
    git stash pop
    stash_needed=false  # EXIT trap での二重 pop を防止
  fi

  # cleanup trap を解除（正常完了時は不要）
  trap - EXIT INT TERM HUP

  echo "✅ Wiki ブランチ '$wiki_branch' を作成しました"

elif [ "$branch_strategy" = "same_branch" ]; then
  git add .rite/wiki/ || {
    echo "ERROR: git add .rite/wiki/ failed" >&2
    exit 1
  }

  _wiki_init_commit || exit 1

  echo "✅ Wiki を現在のブランチに初期化しました"

else
  echo "ERROR: 未知の branch_strategy: '$branch_strategy'" >&2
  echo "  受け付け可能な値: separate_branch / same_branch" >&2
  echo "  対処: rite-config.yml の wiki.branch_strategy を確認してください" >&2
  exit 1
fi

exit 0
