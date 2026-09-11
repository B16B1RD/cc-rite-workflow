#!/usr/bin/env bash
# Fetch and validate one PR issue comment, then write the fix handoff files.
# Called only by skills/fix/references/target-comment.md. The three phases retain
# their own traps and existing BLOCK_A/B/C_COMPLETE and FASTPATH_FETCH_FAILED
# markers. No later phase runs after failure; only the final handoff files survive.
# Usage: review-target-comment-fetch.sh --owner-repo OWNER/REPO --pr N --comment-id N
# Exit: 0 = handoff ready, 1 = fetch/validation/write failure, 2 = invalid arguments;
# signal exits retain 130/143/129. Diagnostics and markers go to stderr.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/control-char-neutralize.sh
source "$SCRIPT_DIR/../hooks/control-char-neutralize.sh" || exit 1

owner_repo=""
pr_number=""
target_comment_id=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --owner-repo) owner_repo="${2:-}"; shift; shift ;;
    --pr) pr_number="${2:-}"; shift; shift ;;
    --comment-id) target_comment_id="${2:-}"; shift; shift ;;
    -h|--help)
      echo "Usage: review-target-comment-fetch.sh --owner-repo OWNER/REPO --pr N --comment-id N"
      exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ ! "$owner_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
   [[ ! "$pr_number" =~ ^[0-9]+$ ]] || [[ ! "$target_comment_id" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --owner-repo OWNER/REPO, --pr N and --comment-id N are required" >&2
  exit 2
fi

# Phase A
(
: > "${TMPDIR:-/tmp}/rite-fix-confidence-override-${pr_number}.txt" 2>/dev/null || \
  echo "WARNING: ${TMPDIR:-/tmp}/rite-fix-confidence-override-${pr_number}.txt の truncate に失敗しました (read-only / permission denied?)" >&2

raw_json="${TMPDIR:-/tmp}/rite-fix-raw-${pr_number}-${target_comment_id}.json"
intermediate_body="${TMPDIR:-/tmp}/rite-fix-intermediate-body-${pr_number}-${target_comment_id}.txt"
intermediate_author="${TMPDIR:-/tmp}/rite-fix-intermediate-author-${pr_number}-${target_comment_id}.txt"
intermediate_skip="${TMPDIR:-/tmp}/rite-fix-intermediate-skip-${pr_number}-${target_comment_id}.txt"

gh_api_err=""
jq_err=""

blockA_committed=0
_rite_fix_blockA_cleanup() {
  rm -f "${gh_api_err:-}" "${jq_err:-}"
  if [ "$blockA_committed" = "0" ]; then
    rm -f "${raw_json:-}" "${intermediate_body:-}" "${intermediate_author:-}" "${intermediate_skip:-}"
  fi
}
trap 'rc=$?; _rite_fix_blockA_cleanup; exit $rc' EXIT
trap '_rite_fix_blockA_cleanup; exit 130' INT
trap '_rite_fix_blockA_cleanup; exit 143' TERM
trap '_rite_fix_blockA_cleanup; exit 129' HUP

gh_api_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-gh-api-err-XXXXXX") || {
  echo "エラー: gh_api_err 一時ファイルの作成に失敗しました" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=mktemp_failed_gh_api_err" >&2
  exit 1
}

if ! target_comment=$(gh api repos/${owner_repo}/issues/comments/${target_comment_id} 2>"$gh_api_err"); then
  echo "エラー: コメント #${target_comment_id} の取得に失敗しました" >&2
  echo "詳細 (gh api stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "対処: コメント URL が正しいか、削除されていないか、認証 (gh auth status) を確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi

if [ -z "$target_comment" ] || [ "$target_comment" = "null" ]; then
  echo "エラー: コメント #${target_comment_id} の取得結果が空です (gh api exit 0 だが本文なし)" >&2
  echo "対処: コメント ID と権限を確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=empty_stdout" >&2
  exit 1
fi

if ! printf '%s' "$target_comment" > "$raw_json"; then
  echo "エラー: raw JSON 一時ファイルの書き出しに失敗しました: $raw_json" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=raw_json_write_failed" >&2
  exit 1
fi

jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-jq-err-XXXXXX") || {
  echo "エラー: jq エラー一時ファイルの作成に失敗しました" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=mktemp_failed_jq_late_err" >&2
  exit 1
}

if ! target_body=$(printf '%s' "$target_comment" | jq -r '.body // empty' 2>"$jq_err"); then
  echo "エラー: gh api レスポンスの JSON パースに失敗しました (.body 抽出)" >&2
  echo "詳細: $(cat "$jq_err")" >&2
  echo "対処: jq バージョン (jq --version) と gh api の生レスポンスを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=jq_current_body_extract_failed" >&2
  exit 1
fi
if [ -z "$target_body" ]; then
  echo "エラー: コメント #${target_comment_id} の body が空です" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=current_body_empty" >&2
  exit 1
fi

if ! target_author=$(printf '%s' "$target_comment" | jq -r '.user.login // empty' 2>"$jq_err"); then
  echo "エラー: コメント #${target_comment_id} の author 抽出に失敗しました" >&2
  echo "詳細: $(cat "$jq_err")" >&2
  echo "対処: jq バージョン (jq --version) と gh api の生レスポンスを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=jq_author_extract_failed" >&2
  exit 1
fi

target_author_mention_skip="false"
if [ -z "$target_author" ]; then
  target_author=""
  target_author_mention_skip="true"
  echo "WARNING: コメント #${target_comment_id} の .user.login が空です。" >&2
  echo "  下流 phase の mention 生成は target_author_mention_skip=true を参照して省略されます。" >&2
fi

if ! printf '%s' "$target_body" > "$intermediate_body"; then
  echo "エラー: Block A: intermediate_body の一時ファイル書き出しに失敗しました: $intermediate_body" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=intermediate_write_failed" >&2
  exit 1
fi
if ! printf '%s' "$target_author" > "$intermediate_author"; then
  echo "エラー: Block A: intermediate_author の一時ファイル書き出しに失敗しました: $intermediate_author" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=intermediate_write_failed" >&2
  exit 1
fi
if ! printf '%s' "$target_author_mention_skip" > "$intermediate_skip"; then
  echo "エラー: Block A: intermediate_skip の一時ファイル書き出しに失敗しました: $intermediate_skip" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=intermediate_write_failed" >&2
  exit 1
fi

blockA_committed=1

echo "[CONTEXT] BLOCK_A_COMPLETE=1; pr_number=${pr_number}; target_comment_id=${target_comment_id}" >&2
)
phase_rc=$?
[ "$phase_rc" -eq 0 ] || exit "$phase_rc"

# Phase B
(
raw_json="${TMPDIR:-/tmp}/rite-fix-raw-${pr_number}-${target_comment_id}.json"
intermediate_body="${TMPDIR:-/tmp}/rite-fix-intermediate-body-${pr_number}-${target_comment_id}.txt"
intermediate_author="${TMPDIR:-/tmp}/rite-fix-intermediate-author-${pr_number}-${target_comment_id}.txt"
intermediate_skip="${TMPDIR:-/tmp}/rite-fix-intermediate-skip-${pr_number}-${target_comment_id}.txt"

jq_err=""

_rite_fix_blockB_cleanup() {
  rm -f "${jq_err:-}"
}
_rite_fix_blockB_invalidate_upstream() {
  rm -f "${raw_json:-}" "${intermediate_body:-}" "${intermediate_author:-}" "${intermediate_skip:-}"
}
trap 'rc=$?; _rite_fix_blockB_cleanup; if [ "$rc" -ne 0 ]; then _rite_fix_blockB_invalidate_upstream; fi; exit $rc' EXIT
trap '_rite_fix_blockB_cleanup; _rite_fix_blockB_invalidate_upstream; exit 130' INT
trap '_rite_fix_blockB_cleanup; _rite_fix_blockB_invalidate_upstream; exit 143' TERM
trap '_rite_fix_blockB_cleanup; _rite_fix_blockB_invalidate_upstream; exit 129' HUP

if [ ! -s "$raw_json" ]; then
  echo "エラー: Block A の raw JSON 一時ファイルが存在しないか空です: $raw_json" >&2
  echo "  Block A が失敗しているか、並列実行で削除された可能性があります" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=raw_json_missing_at_block_b" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
fi

jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-jq-err-XXXXXX") || {
  echo "エラー: jq エラー一時ファイルの作成に失敗しました" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=mktemp_failed_jq_block_b" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
}

if ! comment_issue_url=$(jq -r '.issue_url // empty' "$raw_json" 2>"$jq_err"); then
  echo "エラー: gh api レスポンスから .issue_url の抽出に失敗しました" >&2
  echo "詳細: $(cat "$jq_err")" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=jq_comment_id_extract_failed" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
fi
if [ -z "$comment_issue_url" ]; then
  echo "エラー: コメント #${target_comment_id} のレスポンスに .issue_url フィールドがありません" >&2
  echo "対処: gh api の生レスポンスを確認してください (GitHub API のスキーマ変更の可能性)" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=missing_issue_url" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
fi

if ! grep -qE '^[0-9]+$' <<< "${pr_number}"; then
  echo "エラー: pr_number が数字以外を含んでいます: '${pr_number}'" >&2
  echo "  ステップ 1.0 で正規化された pr_number は数字のみのはずですが、何らかの経路で異常値が混入しました" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=issue_number_not_found" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
fi

if ! grep -qE "/(pull|issues)/${pr_number}$" <<< "$comment_issue_url"; then
  echo "エラー: コメント #${target_comment_id} は PR #${pr_number} に属していません (silent misclassification 検出)" >&2
  echo "  実際の所属: $comment_issue_url" >&2
  echo "  期待値: /pull/${pr_number} または /issues/${pr_number} で終わる URL" >&2
  echo "  対処: comment URL の pull/{N} 部分と #issuecomment-{ID} の整合性を確認してください。" >&2
  echo "         GitHub UI で comment URL を再コピーすることを推奨します。" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=pr_number_mismatch" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
fi

echo "[CONTEXT] BLOCK_B_COMPLETE=1; pr_number=${pr_number}; target_comment_id=${target_comment_id}" >&2
)
phase_rc=$?
[ "$phase_rc" -eq 0 ] || exit "$phase_rc"

# Phase C
(
raw_json="${TMPDIR:-/tmp}/rite-fix-raw-${pr_number}-${target_comment_id}.json"
intermediate_body="${TMPDIR:-/tmp}/rite-fix-intermediate-body-${pr_number}-${target_comment_id}.txt"
intermediate_author="${TMPDIR:-/tmp}/rite-fix-intermediate-author-${pr_number}-${target_comment_id}.txt"
intermediate_skip="${TMPDIR:-/tmp}/rite-fix-intermediate-skip-${pr_number}-${target_comment_id}.txt"

body_file="${TMPDIR:-/tmp}/rite-fix-target-body-${pr_number}-${target_comment_id}.txt"
author_file="${TMPDIR:-/tmp}/rite-fix-target-author-${pr_number}-${target_comment_id}.txt"
skip_file="${TMPDIR:-/tmp}/rite-fix-target-author-skip-${pr_number}-${target_comment_id}.txt"

handoff_committed=0
_rite_fix_blockC_cleanup() {
  if [ "$handoff_committed" = "0" ]; then
    rm -f "${body_file:-}" "${author_file:-}" "${skip_file:-}"
  fi
  rm -f "${raw_json:-}" "${intermediate_body:-}" "${intermediate_author:-}" "${intermediate_skip:-}"
}
trap 'rc=$?; _rite_fix_blockC_cleanup; exit $rc' EXIT
trap '_rite_fix_blockC_cleanup; exit 130' INT
trap '_rite_fix_blockC_cleanup; exit 143' TERM
trap '_rite_fix_blockC_cleanup; exit 129' HUP

if [ ! -s "$intermediate_body" ] || [ ! -f "$intermediate_author" ] || [ ! -s "$intermediate_skip" ] || [ ! -s "$raw_json" ]; then
  echo "エラー: Block A/B の intermediate ファイルが存在しないか空です" >&2
  echo "  body=$intermediate_body ($([ -s "$intermediate_body" ] && echo ok || echo empty_or_missing))" >&2
  echo "  author=$intermediate_author ($([ -f "$intermediate_author" ] && echo ok || echo missing))" >&2
  echo "  skip=$intermediate_skip ($([ -s "$intermediate_skip" ] && echo ok || echo empty_or_missing))" >&2
  echo "  raw_json=$raw_json ($([ -s "$raw_json" ] && echo ok || echo empty_or_missing))" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=intermediate_missing_at_block_c" >&2
  exit 1
fi

if ! cat "$intermediate_body" > "$body_file"; then
  echo "エラー: Block C: handoff コピーに失敗しました (intermediate_body → body_file): $body_file" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=paste_io_error" >&2
  exit 1
fi
if ! cat "$intermediate_author" > "$author_file"; then
  echo "エラー: Block C: handoff コピーに失敗しました (intermediate_author → author_file): $author_file" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=paste_io_error" >&2
  exit 1
fi
if ! cat "$intermediate_skip" > "$skip_file"; then
  echo "エラー: Block C: handoff コピーに失敗しました (intermediate_skip → skip_file): $skip_file" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=paste_io_error" >&2
  exit 1
fi

if [ ! -s "$body_file" ]; then
  echo "エラー: body_file の post-condition check に失敗: $body_file が空または存在しません" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=pr_body_tmp_empty_or_missing" >&2
  exit 1
fi
if [ ! -f "$author_file" ]; then
  echo "エラー: author_file の post-condition check に失敗: $author_file が存在しません" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=author_file_missing_at_post_condition" >&2
  exit 1
fi
if [ ! -s "$skip_file" ]; then
  echo "エラー: skip_file の post-condition check に失敗: $skip_file が空または存在しません" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=skip_file_empty_at_post_condition" >&2
  exit 1
fi

handoff_committed=1

echo "[CONTEXT] BLOCK_C_COMPLETE=1; pr_number=${pr_number}; target_comment_id=${target_comment_id}; body_file=$body_file; author_file=$author_file; skip_file=$skip_file" >&2
)
phase_rc=$?
[ "$phase_rc" -eq 0 ] || exit "$phase_rc"
