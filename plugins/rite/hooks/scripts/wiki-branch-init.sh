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
#      含む; 旧 inline block と同じ blocking 契約) / stash push が新しい entry を作らない /
#      自分の stash entry が見つからない・pop できない / submodule に変更または未追跡
#      ファイルがある / 終了時の submodule の状態が実行前と一致しない (いずれも separate_branch)
#
# Notes:
#   - 旧 inline block と同じく global `set -e` は使わない (各 git 操作の失敗を
#     個別メッセージ + exit 1 で明示ハンドリングする)。
#   - separate_branch の orphan 作成は untracked な `.rite/wiki/` がブランチ切替を
#     生き延びる git の挙動に依存する (stash push は untracked を退避しない)。
#   - separate_branch は submodule の作業ツリーに触れない (gitlink を index からだけ外す)。
#     submodule に変更または未追跡ファイルがあるときは、何も変更せずに止まる。
#   - stash は全 worktree で共有されるため、push 時に記録した SHA の entry だけを pop する。
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
    --message-file)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "ERROR: --message-file requires a value" >&2
        exit 1
      fi
      MESSAGE_FILE="$2"
      shift 2
      ;;
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
_default_file=""
_resolved_file=""
_rite_wiki_init_msg_cleanup() { rm -f "${_default_file:-}" "${_resolved_file:-}"; return 0; }
trap 'rc=$?; _rite_wiki_init_msg_cleanup; exit $rc' EXIT
trap '_rite_wiki_init_msg_cleanup; exit 130' INT
trap '_rite_wiki_init_msg_cleanup; exit 143' TERM
trap '_rite_wiki_init_msg_cleanup; exit 129' HUP
_default_file=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-init-default-XXXXXX") || {
  echo "ERROR: 既定メッセージ用一時ファイルを作成できません" >&2
  exit 1
}
_resolved_file=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-init-msg-XXXXXX") || {
  echo "ERROR: コミットメッセージ用一時ファイルを作成できません" >&2
  exit 1
}
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

  # stash は submodule の変更を退避せず、git diff は submodule 内の未追跡ファイルを変更と見なさない。
  # 何かを変更する前に両方を検出して止める。利用者の設定で検出が外れないよう、submodule の ignore 設定と
  # 未追跡ファイルの非表示設定をこの呼び出しに限って上書きする (-c は submodule 側の status にも届く)
  status_v2=$(git -c status.showUntrackedFiles=normal status --porcelain=v2 --ignore-submodules=none) || {
    echo "ERROR: git status failed — submodule の変更を確認できないため停止します" >&2
    exit 1
  }
  changed_submodules=$(printf '%s\n' "$status_v2" | awk '
    ($1 == "1" || $1 == "2" || $1 == "u") && $3 ~ /^S/ {
      n = ($1 == "1") ? 8 : ($1 == "2") ? 9 : 10
      for (i = 0; i < n; i++) $0 = substr($0, index($0, " ") + 1)
      sub(/\t.*/, "")
      print
    }')
  if [ -n "$changed_submodules" ]; then
    echo "ERROR: submodule に変更または未追跡ファイルがあります。ブランチ・作業ツリー・stash を変更せずに停止します" >&2
    printf '%s\n' "$changed_submodules" | sed 's/^/  対象: /' >&2
    echo "  原因: submodule の変更は git stash で退避できず、ブランチの切り替えで失われうるため、変更がある状態では初期化しません" >&2
    echo "  対処: 変更を残すなら submodule の変更（未追跡ファイルは commit するか submodule の外へ移す）と親の新しい参照先を commit し、残さないなら submodule を記録済みの commit と中身に戻して、git status --ignore-submodules=none に submodule が表示されなくなってから再実行してください" >&2
    exit 1
  fi
  submodules_before=$(git submodule status) || {
    echo "ERROR: git submodule status failed — submodule の状態を記録できないため停止します" >&2
    echo "  対処: 上の git の出力を確認してください。.gitmodules に登録の無い submodule が index にある場合は、登録するか index から外してから再実行してください" >&2
    exit 1
  }

  # 元のブランチへ戻ったあと、submodule が実行前と同じ commit で展開されていることを確かめる。
  # signal trap の exit で EXIT trap も走るため、照合の前に verify_needed を下ろして 2 回目を防ぐ
  verify_needed=true
  _rite_wiki_init_verify_submodules() {
    local after
    [ "$verify_needed" = true ] || return 0
    verify_needed=false
    if ! after=$(git submodule status) || [ "$after" != "$submodules_before" ]; then
      echo "ERROR: submodule の状態が実行前と一致しません" >&2
      echo "  復旧: git submodule status で確認し、git submodule update で記録済みの commit を展開し直してください" >&2
      return 1
    fi
  }

  stash_needed=false
  # stash は全 worktree で共有され、並行セッションが上に積みうる。自分の entry は push 時の SHA で特定する
  stash_sha=""

  # SHA が一致する stash@{n} だけを pop する。見つからなければほかの entry に触れず失敗を返す
  _rite_wiki_init_pop_own_stash() {
    local ref
    ref=$(git stash list --format='%gd %H' | awk -v s="$stash_sha" '$2 == s {print $1; exit}')
    if [ -z "$ref" ]; then
      echo "ERROR: 退避した変更 (stash $stash_sha) が stash に見つかりません。ほかの stash entry には触れずに停止します" >&2
      echo "  確認: git stash list --format='%gd %H %gs'" >&2
      return 1
    fi
    if ! git stash pop "$ref"; then
      echo "ERROR: 退避した変更 ($ref, $stash_sha) を戻せませんでした — 手動で復旧してください" >&2
      echo "  確認: git stash list --format='%gd %H %gs' で SHA が一致する entry を探し、衝突を解消してから pop します" >&2
      return 1
    fi
  }

  # cleanup trap: 異常終了時に元のブランチに復帰を保証
  # canonical signal-specific trap パターン (references/bash-trap-patterns.md 準拠)
  # pop は元のブランチへ戻れたときだけ行う (wiki ブランチ上に自分の変更を展開しない)。
  # signal trap の exit で EXIT trap も走るため、pop の前に stash_needed を下ろして 2 回目を防ぐ
  _rite_wiki_init_cleanup() {
    if git checkout "$current_branch" 2>/dev/null; then
      if [ "$stash_needed" = true ]; then
        stash_needed=false
        _rite_wiki_init_pop_own_stash
      fi
      _rite_wiki_init_verify_submodules
    elif [ "$stash_needed" = true ]; then
      echo "WARNING: '$current_branch' へ戻れなかったため、退避した変更 (stash $stash_sha) を戻していません" >&2
      echo "  復旧: git checkout '$current_branch' のあと、git stash list --format='%gd %H %gs' で SHA が一致する entry を pop します" >&2
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
    stash_before=$(git rev-parse -q --verify refs/stash) || stash_before=""
    git stash push -m "rite-wiki-init-stash" || {
      echo "ERROR: git stash push failed" >&2
      exit 1
    }
    stash_sha=$(git rev-parse -q --verify refs/stash) || stash_sha=""
    # 何も退避しなかった push は refs/stash をほかの entry に残す。それを戻すと他人の変更を展開する
    if [ -z "$stash_sha" ] || [ "$stash_sha" = "$stash_before" ]; then
      echo "ERROR: git stash push が新しい entry を作りませんでした。自分の退避なしには続行しません" >&2
      exit 1
    fi
    stash_needed=true
  fi

  # orphan ブランチを作成
  git checkout --orphan "$wiki_branch" || {
    echo "ERROR: git checkout --orphan '$wiki_branch' failed" >&2
    exit 1
  }
  # git rm は submodule の作業ツリーを中身ごと消し、元のブランチへ戻っても再展開されない。
  # gitlink は index からだけ外し、作業ツリーには触れさせない。
  # path は NUL 区切りで読む (行出力は " や \ を含む path を引用し、index の entry と一致しなくなる)
  while IFS= read -r -d '' index_entry; do
    case "$index_entry" in
      160000\ *)
        git update-index --force-remove -- "${index_entry#*$'\t'}" || {
          echo "ERROR: submodule '${index_entry#*$'\t'}' を index から外せませんでした" >&2
          exit 1
        }
        ;;
    esac
  done < <(git ls-files -s -z)
  # update-index は対象の entry が無くても成功を返し、上の読み取りの失敗はループからは見えない。
  # gitlink が残ったまま git rm へ進まないよう、index を読み直して確かめる
  remaining_entries=$(git ls-files -s) || {
    echo "ERROR: git ls-files failed — submodule を index から外せたか確認できないため停止します" >&2
    exit 1
  }
  case $'\n'"$remaining_entries" in
    *$'\n160000 '*)
      echo "ERROR: submodule を index から外せませんでした。作業ツリーを消さずに停止します" >&2
      exit 1
      ;;
  esac
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
    stash_needed=false  # 成否によらず EXIT trap での二重 pop を防止
    _rite_wiki_init_pop_own_stash || exit 1
  fi

  _rite_wiki_init_msg_cleanup
  # cleanup trap を解除（正常完了時は不要）
  trap - EXIT INT TERM HUP

  _rite_wiki_init_verify_submodules || exit 1

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
