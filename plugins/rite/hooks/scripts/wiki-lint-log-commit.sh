#!/usr/bin/env bash
# wiki-lint-log-commit.sh
#
# Commit the log.md entry appended by wiki/lint.md ステップ 8.3. The skill writes
# the commit message to a file with the Write tool and calls this helper in one
# line, so the commit logic stays out of the skill body.
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --mode ARGS          lint skill arguments; `--auto` means called from ingest (required, may be empty)
#   --message-file ABS   commit message written by the skill (required)
#
# Behavior:
#   --auto + separate_branch: wiki-worktree-commit.sh --commit-only (ingest ステップ 8.6 pushes)
#   standalone + separate_branch: wiki-worktree-commit.sh (commit + push)
#   same_branch: git add .rite/wiki/log.md + git-commit-file.sh
#
# Exit codes:
#   0  done, or a commit failure reported as WARNING (lint is non-blocking)
#   1  fail-fast: placeholder residue / missing or empty message file /
#      unsubstituted message / unknown branch_strategy
#   2  invocation error (unknown option / missing option)
#
# The message file is removed on every exit except rc=6 from
# wiki-worktree-commit.sh (sandbox-mask): the retry re-runs only this helper,
# so the file must still exist.
#
# NOTE on shell flags: per-command rc handling, so `set -e` is intentionally not set.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"
branch_strategy=""
mode=""
mode_set=false
message_file=""

usage() {
  cat <<'EOF'
Usage: wiki-lint-log-commit.sh --branch-strategy STRATEGY --mode ARGS --message-file ABS

Commits the log.md entry appended by /rite:wiki-lint ステップ 8.3.

Options:
  --branch-strategy STRATEGY  separate_branch | same_branch (required)
  --mode ARGS                 lint skill arguments (`--auto` or empty; required)
  --message-file ABS          commit message file written by the skill (required)
  -h, --help                  Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --branch-strategy) branch_strategy="${2-}"; shift 2 || { usage >&2; exit 2; } ;;
    --mode) mode="${2-}"; mode_set=true; shift 2 || { usage >&2; exit 2; } ;;
    --message-file) message_file="${2-}"; shift 2 || { usage >&2; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

keep_message=false
cleanup() {
  [ "$keep_message" = true ] && return 0
  case "$message_file" in
    ""|"{"*"}") ;;
    *) rm -f -- "$message_file" ;;
  esac
  return 0
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

if [ -z "$branch_strategy" ] || [ "$mode_set" != true ] || [ -z "$message_file" ]; then
  echo "ERROR: --branch-strategy / --mode / --message-file are required" >&2
  usage >&2
  exit 2
fi

for pair in "branch_strategy=$branch_strategy" "mode=$mode" "message_file=$message_file"; do
  case "${pair#*=}" in
    "{"*"}")
      echo "ERROR: ステップ 8.3 の {${pair%%=*}} placeholder が literal substitute されていません (値: '${pair#*=}')" >&2
      exit 1
      ;;
  esac
done

if [ ! -s "$message_file" ]; then
  echo "ERROR: commit メッセージファイルが存在しないか空です: $message_file" >&2
  echo "  対処: ステップ 8.3 の Write でメッセージを書いてから helper を呼んでください" >&2
  exit 1
fi
message=$(cat -- "$message_file") || { echo "ERROR: commit メッセージファイルを読めません: $message_file" >&2; exit 1; }
case "$message" in
  "{"*"}"|*"{log_entry}"*)
    echo "ERROR: ステップ 8.3 の commit message が未置換です" >&2
    exit 1
    ;;
esac

if printf '%s' "$mode" | grep -qE '(^|[[:space:]])--auto([[:space:]]|$)'; then
  auto_mode=true
else
  auto_mode=false
fi

case "$branch_strategy" in
  separate_branch)
    if [ "$auto_mode" = "true" ]; then
      # Called from ingest: ingest ステップ 8.6 pushes once for the whole run.
      commit_out=$(bash "$SCRIPT_DIR/wiki-worktree-commit.sh" --commit-only --message-file "$message_file")
    else
      # Standalone lint is its own flow, so it commits and pushes now.
      commit_out=$(bash "$SCRIPT_DIR/wiki-worktree-commit.sh" --message-file "$message_file")
    fi
    commit_rc=$?
    echo "$commit_out"
    # Non-blocking: every rc is a WARNING. A number-reference hit also returns
    # rc=1 without committing, which is the safe outcome.
    case "$commit_rc" in
      0) : ;;
      2) echo "[CONTEXT] WIKI_LINT_COMMIT=skipped; reason=wiki-disabled-or-no-pending" >&2 ;;
      3) echo "WARNING: wiki-worktree-commit.sh で git 操作失敗 (rc=3)。log.md 追記は非ブロッキングのため継続します" >&2 ;;
      4) echo "WARNING: wiki-worktree-commit.sh で commit landed but push 失敗 (rc=4)。次回再 push が必要 (standalone 実行時のみ到達 — --commit-only は push を行わない)" >&2 ;;
      6)
        keep_message=true
        echo "WARNING: wiki worktree の管理ディレクトリに書き込めないため commit しませんでした (rc=6, reason=sandbox-mask)。実行エージェントはこの helper 呼び出しの 1 文だけを別の Bash tool call で dangerouslyDisableSandbox: true を付けて 1 回だけ再実行する (確認不要。log.md の Edit と Write はやり直さない)。再実行でも rc=6 なら sandbox 起因ではないため再試行せず、stderr の管理ディレクトリの権限・容量を確認する" >&2
        ;;
      *) echo "WARNING: wiki-worktree-commit.sh が予期しない rc=$commit_rc で失敗しました。log.md 追記は非ブロッキングのため継続します" >&2 ;;
    esac
    ;;
  same_branch)
    add_err=$(mktemp "${TMPDIR:-/tmp}/rite-lint-add-err-XXXXXX" 2>/dev/null) || add_err=""
    commit_err=$(mktemp "${TMPDIR:-/tmp}/rite-lint-commit-err-XXXXXX" 2>/dev/null) || commit_err=""
    [ -n "$add_err" ] && [ -n "$commit_err" ] || echo "WARNING: stderr 退避 tempfile の mktemp に失敗しました。git の詳細エラー情報は失われます" >&2
    if ! git add .rite/wiki/log.md 2>"${add_err:-/dev/null}"; then
      echo "WARNING: git add .rite/wiki/log.md に失敗しました" >&2
      [ -n "$add_err" ] && [ -s "$add_err" ] && head -3 "$add_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      echo "  対処: index lock / permission denied / path error のいずれかを確認してください" >&2
    elif ! bash "$SCRIPT_DIR/git-commit-file.sh" --file "$message_file" -- --quiet 2>"${commit_err:-/dev/null}"; then
      echo "WARNING: log.md のコミットに失敗しました" >&2
      [ -n "$commit_err" ] && [ -s "$commit_err" ] && head -3 "$commit_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      echo "  対処: pre-commit hook / gpg sign / author config / permission のいずれかを確認してください" >&2
    fi
    rm -f -- "${add_err:-}" "${commit_err:-}"
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 8.3)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac
exit 0
