#!/usr/bin/env bash
# Update fix work memory from a target checkout (cwd).
# Usage: fix-work-memory-update.sh --pr-body-file FILE --history-file FILE
#        --impl-status TEXT --test-status TEXT --doc-status TEXT
# Input files belong to the caller and are never removed. An empty/missing history
# file path represents preparation failure, evaluated only after progress succeeds.
# stdout: [CONTEXT] FIX_WM_UPDATE=success|skipped|failed; issue_number=N
#         N is empty until resolved. skipped means no_comment.
# stderr: diagnostics and existing WM_UPDATE_FAILED retained flags. The caller
#         owns the final [fix:*] outcome; this script does not emit it.
# Exit: 0 on success, no_comment, or retained soft failure; 1 on existing fatal
#       input/tempfile failures; 2 on invalid arguments; INT=130, TERM=143, HUP=129.
# A completion marker is emitted on EXIT after argument validation, including
# failures/signals. The caller detects startup failure when it is absent.

pr_body_tmp=""
history_tmp=""
impl_status=""
test_status=""
doc_status=""
seen=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr-body-file|--history-file|--impl-status|--test-status|--doc-status)
      if [ "$#" -lt 2 ]; then echo "ERROR: missing value for $1" >&2; exit 2; fi
      case "$1" in
        --pr-body-file) pr_body_tmp=$2; seen=$((seen | 1)) ;;
        --history-file) history_tmp=$2; seen=$((seen | 2)) ;;
        --impl-status) impl_status=$2; seen=$((seen | 4)) ;;
        --test-status) test_status=$2; seen=$((seen | 8)) ;;
        --doc-status) doc_status=$2; seen=$((seen | 16)) ;;
      esac
      shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ "$seen" -ne 31 ]; then echo "ERROR: all five input options are required" >&2; exit 2; fi
plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 2
source "$plugin_root/hooks/control-char-neutralize.sh" || exit 2
result=failed
issue_number=""
wm_emit_done=0
pr_body_grep_err=""
branch_grep_err=""
changed_files_tmp=""
diff_err=""
wm_sync_err=""
cleanup() {
  rm -f "${pr_body_grep_err:-}" "${branch_grep_err:-}" "${changed_files_tmp:-}" "${diff_err:-}" "${wm_sync_err:-}"
}
trap 'rc=$?; cleanup; printf "[CONTEXT] FIX_WM_UPDATE=%s; issue_number=%s\n" "$result" "$issue_number"; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [ ! -s "$pr_body_tmp" ]; then
  echo "ERROR: pr_body_tmp が空または存在しません: $pr_body_tmp" >&2
  echo "対処: PR body 自体が空であった可能性があります (gh pr view --json body の出力を確認)" >&2
  echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=pr_body_tmp_empty_or_missing; issue_number=${issue_number}" >&2
  exit 1
fi

pr_body_grep_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-pr-body-grep-err-XXXXXX") || {
  echo "ERROR: pr_body_grep_err 一時ファイルの作成に失敗" >&2
  echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_pr_body_grep_err" >&2
  exit 1
}
issue_number=""
if closes_raw=$(grep -oE '(Closes|Fixes|Resolves) #[0-9]+' "$pr_body_tmp" 2>"$pr_body_grep_err"); then
  issue_number=$(printf '%s\n' "$closes_raw" | head -1 | sed -n 's/.*#\([0-9][0-9]*\).*/\1/p')
else
  pr_body_grep_rc=$?
  case "$pr_body_grep_rc" in
    1)
      if [ -s "$pr_body_grep_err" ]; then
        echo "WARNING: pr_body grep が exit 1 (no match) で完了しましたが stderr に出力がありました:" >&2
        head -3 "$pr_body_grep_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      fi
      :
      ;;
    *)
      echo "ERROR: PR 本文の grep が IO/権限/構文エラーで失敗しました (rc=$pr_body_grep_rc)" >&2
      echo "詳細 (stderr 先頭 5 行):" >&2
      head -5 "$pr_body_grep_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      echo "  対処: 環境の grep バイナリと権限を確認後、再実行してください" >&2
      echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=pr_body_grep_io_error; rc=$pr_body_grep_rc" >&2
      wm_emit_done=1
      issue_number=""
      ;;
  esac
fi

if [[ -z "$issue_number" ]] && [ "$wm_emit_done" = "0" ]; then
  branch_grep_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-branch-grep-err-XXXXXX") || {
    echo "ERROR: branch_grep_err 一時ファイルの作成に失敗" >&2
    echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
    echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_branch_grep_err" >&2
    exit 1
  }
  if branch_name=$(git branch --show-current 2>"$branch_grep_err"); then
    issue_number=$(printf '%s\n' "$branch_name" | sed -n 's/.*issue-\([0-9][0-9]*\).*/\1/p')
  else
    branch_show_current_rc=$?
    echo "ERROR: branch 名取得 (git branch --show-current) が IO/権限エラーで失敗しました (rc=$branch_show_current_rc)" >&2
    echo "詳細 (stderr 先頭 5 行):" >&2
    head -5 "$branch_grep_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    echo "  対処: 環境の git バイナリと権限、cwd が git repo であることを確認後、再実行してください" >&2
    echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
    echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=branch_grep_io_error; rc=$branch_show_current_rc" >&2
    wm_emit_done=1
    issue_number=""
  fi
fi

if [[ -z "$issue_number" ]] && [ "$wm_emit_done" = "0" ]; then
  echo "⚠️ Issue 番号が特定できないため作業メモリ更新をスキップしました" >&2
  echo "  PR 本文に Closes/Fixes/Resolves #XX が含まれていないか、ブランチ名に issue-{number} パターンがありません。" >&2
  echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
  echo "  対処: ステップ 5.1 で WM_UPDATE_FAILED=1 を context に set し、[fix:pushed-wm-stale] を出力する" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=issue_number_not_found" >&2
  wm_emit_done=1
fi

[ "$wm_emit_done" = "0" ] || exit 0

base_branch=$(grep -E '^\s*base:' rite-config.yml 2>/dev/null | head -1 \
  | sed 's/.*base:[[:space:]]*"\?\([^"]*\)"\?.*/\1/')
[ -z "$base_branch" ] && base_branch="develop"

git_diff_failed=0
if ! changed_files_tmp=$(mktemp); then
  echo "ERROR: changed-files-file の mktemp に失敗 (git diff 不能)" >&2
  echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=git_diff_failed; issue_number=${issue_number}" >&2
  git_diff_failed=1
fi
if [ "$git_diff_failed" -eq 0 ]; then
  diff_err=$(mktemp 2>/dev/null) || diff_err=""
  if changed_files_raw=$(git diff --name-status "origin/${base_branch}...HEAD" 2>"${diff_err:-/dev/null}"); then
    printf '%s\n' "$changed_files_raw" | while IFS=$'\t' read -r status file; do
      [ -z "$status" ] && continue
      case "$status" in
        A) echo "- \`${file}\` - 追加" ;;
        M) echo "- \`${file}\` - 変更" ;;
        D) echo "- \`${file}\` - 削除" ;;
        R*) echo "- \`${file}\` - 名前変更" ;;
        *) echo "- \`${file}\` - ${status}" ;;
      esac
    done > "$changed_files_tmp"
  else
    echo "WARNING: git diff --name-status \"origin/${base_branch}...HEAD\" が失敗しました。" >&2
    [ -n "$diff_err" ] && [ -s "$diff_err" ] && head -3 "$diff_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    echo "  考えられる原因: shallow clone (base branch 未 fetch) / 無効な base branch 名 / git リポジトリ外" >&2
    echo "  対処: git fetch origin ${base_branch} を実行後に再試行、または rite-config.yml の branch.base を確認" >&2
    echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
    echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=git_diff_failed; issue_number=${issue_number}" >&2
    git_diff_failed=1
  fi
  [ -n "$diff_err" ] && rm -f "$diff_err"
fi

wm_state_of() { printf '%s\n' "$1" | sed -n 's/^status=\([a-z]*\).*/\1/p' | head -1; }
wm_reason_of() { printf '%s\n' "$1" | sed -n 's/.*reason=\([a-z_]*\).*/\1/p' | head -1; }

if [ "$git_diff_failed" -eq 0 ]; then
  wm_sync_err=$(mktemp 2>/dev/null) || wm_sync_err=""
  wm_progress_out=$(bash "$plugin_root/hooks/issue-comment-wm-sync.sh" update \
    --issue "${issue_number}" \
    --transform update-progress \
    --impl-status "${impl_status}" --test-status "${test_status}" --doc-status "${doc_status}" \
    --changed-files-file "$changed_files_tmp" 2>"${wm_sync_err:-/dev/null}")
  wm_p_state=$(wm_state_of "$wm_progress_out")
  wm_p_reason=$(wm_reason_of "$wm_progress_out")

  if [ "$wm_p_state" != "success" ] && [ "$wm_p_reason" != "no_comment" ]; then
    echo "ERROR: 進捗サマリー更新 (issue-comment-wm-sync update-progress) が失敗 (helper status: $wm_progress_out)" >&2
    [ -n "$wm_sync_err" ] && [ -s "$wm_sync_err" ] && { echo "  helper stderr (root-cause、先頭 5 行):" >&2; head -5 "$wm_sync_err" | neutralize_ctrl --keep-newline | sed 's/^/    /' >&2; }
    echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
    echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_sync_progress_failed; issue_number=${issue_number}" >&2
  elif [ "$wm_p_reason" = "no_comment" ]; then
    result=skipped
    echo "INFO: work memory comment が未検出のため WM 更新を skip (legitimate no-op)" >&2
  else
    if [ -n "$history_tmp" ] && [ -r "$history_tmp" ] && [ -f "$history_tmp" ]; then
      wm_history_out=$(bash "$plugin_root/hooks/issue-comment-wm-sync.sh" update \
        --issue "${issue_number}" \
        --transform append-section --section "レビュー対応履歴" --content-file "$history_tmp" 2>"${wm_sync_err:-/dev/null}")
      wm_h_state=$(wm_state_of "$wm_history_out")
      wm_h_reason=$(wm_reason_of "$wm_history_out")
      if [ "$wm_h_state" != "success" ] && [ "$wm_h_reason" != "no_comment" ]; then
        echo "ERROR: レビュー対応履歴の追記 (issue-comment-wm-sync append-section) が失敗 (helper status: $wm_history_out)" >&2
        [ -n "$wm_sync_err" ] && [ -s "$wm_sync_err" ] && { echo "  helper stderr (root-cause、先頭 5 行):" >&2; head -5 "$wm_sync_err" | neutralize_ctrl --keep-newline | sed 's/^/    /' >&2; }
        echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
        echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_sync_history_failed; issue_number=${issue_number}" >&2
      elif [ "$wm_h_reason" = "no_comment" ]; then
        result=skipped
      else
        result=success
      fi
    else
      echo "ERROR: レビュー対応履歴 content-file を準備できませんでした。追記できません" >&2
      echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_sync_history_failed; issue_number=${issue_number}" >&2
    fi
  fi
fi
