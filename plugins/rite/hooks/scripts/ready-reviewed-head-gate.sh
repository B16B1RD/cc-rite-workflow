#!/bin/bash
# Block Ready when HEAD is not the latest reviewed commit.
# Reviewed commit := .commit_sha of the newest .rite/review-results/{pr}-*.json
# (schema field; PR-comment marker name is reviewed_commit). Archive is not
# a current result, so this helper never reads it.
set -u
pr_number=""; plugin_root=""; results_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)
      [ "$#" -ge 2 ] || { echo "ERROR: Ready reviewed-head gate: --pr requires a value" >&2; exit 2; }
      pr_number="$2"; shift 2 ;;
    --plugin-root)
      [ "$#" -ge 2 ] || { echo "ERROR: Ready reviewed-head gate: --plugin-root requires a value" >&2; exit 2; }
      plugin_root="$2"; shift 2 ;;
    --results-dir)
      [ "$#" -ge 2 ] || { echo "ERROR: Ready reviewed-head gate: --results-dir requires a value" >&2; exit 2; }
      results_dir="$2"; shift 2 ;;
    *) echo "ERROR: Ready reviewed-head gate: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$pr_number" in ''|*[!0-9]*) echo "ERROR: Ready reviewed-head gate: PR number is required" >&2; exit 2 ;; esac
if [ -z "$results_dir" ]; then
  [ -n "$plugin_root" ] || { echo "ERROR: Ready reviewed-head gate: --plugin-root is required when --results-dir is omitted" >&2; exit 2; }
  [ -x "$plugin_root/hooks/state-path-resolve.sh" ] || {
    echo "ERROR: Ready reviewed-head gate: state-path-resolve.sh not found. 照合不能のため Ready 化を拒否します。" >&2
    exit 1
  }
  results_dir=$(bash "$plugin_root/hooks/state-path-resolve.sh")/.rite/review-results || {
    echo "ERROR: Ready reviewed-head gate: state root を解決できません。照合不能のため Ready 化を拒否します。" >&2
    exit 1
  }
fi

if ! head_sha=$(git rev-parse HEAD); then
  echo "ERROR: Ready reviewed-head gate: git rev-parse HEAD に失敗しました。照合不能のため Ready 化を拒否します。" >&2
  echo "[CONTEXT] READY_REVIEWED_HEAD=rev_parse_failed; pr=$pr_number" >&2
  exit 1
fi
head_sha=$(printf '%s' "$head_sha" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
case "$head_sha" in
  ''|*[!0-9a-f]*)
    echo "ERROR: Ready reviewed-head gate: HEAD が SHA ではありません (received: '$head_sha')。照合不能のため Ready 化を拒否します。" >&2
    echo "[CONTEXT] READY_REVIEWED_HEAD=rev_parse_failed; pr=$pr_number" >&2
    exit 1
    ;;
esac

_sha_matches() {
  [ "${#1}" -ge 7 ] && [ "${#2}" -ge 7 ] || return 1
  case "$2" in "$1"*) return 0 ;; esac
  case "$1" in "$2"*) return 0 ;; esac
  return 1
}

latest=""
if [ -d "$results_dir" ]; then
  find_raw=$(find "$results_dir" -maxdepth 1 -type f -name "${pr_number}-*.json") || {
    echo "ERROR: Ready reviewed-head gate: review JSON を検索できません ($results_dir)。照合不能のため Ready 化を拒否します。" >&2
    echo "[CONTEXT] READY_REVIEWED_HEAD=find_failed; pr=$pr_number" >&2
    exit 1
  }
  latest=$(printf '%s\n' "$find_raw" | LC_ALL=C sort -r | head -n 1)
fi
if [ -z "$latest" ] || [ ! -f "$latest" ]; then
  echo "ERROR: Ready reviewed-head gate: PR #$pr_number の review JSON がありません（レビュー未実施、または archive 済み）。Ready 化を拒否します。" >&2
  echo "  探索先: $results_dir/${pr_number}-*.json" >&2
  echo "  次の行動: /rite:iterate $pr_number" >&2
  echo "[CONTEXT] READY_REVIEWED_HEAD=missing_json; pr=$pr_number" >&2
  exit 1
fi

if ! reviewed=$(jq -r '.commit_sha // empty' "$latest"); then
  echo "ERROR: Ready reviewed-head gate: $latest から commit_sha を読めません。照合不能のため Ready 化を拒否します。" >&2
  echo "[CONTEXT] READY_REVIEWED_HEAD=jq_failed; pr=$pr_number; file=$latest" >&2
  exit 1
fi
reviewed=$(printf '%s' "$reviewed" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
case "$reviewed" in
  ''|*[!0-9a-f]*)
    echo "ERROR: Ready reviewed-head gate: $latest の commit_sha が空または SHA ではありません (received: '$reviewed')。照合不能のため Ready 化を拒否します。" >&2
    echo "  次の行動: /rite:iterate $pr_number" >&2
    echo "[CONTEXT] READY_REVIEWED_HEAD=missing_sha; pr=$pr_number; file=$latest" >&2
    exit 1
    ;;
esac

if _sha_matches "$reviewed" "$head_sha"; then
  echo "[CONTEXT] READY_REVIEWED_HEAD=match; reviewed=$reviewed; head=$head_sha" >&2
  exit 0
fi

echo "ERROR: Ready reviewed-head gate: 最終レビュー済み commit と HEAD が不一致です" >&2
echo "  reviewed_commit (review JSON の commit_sha): $reviewed" >&2
echo "  HEAD: $head_sha" >&2
echo "  意味: レビュー後に未レビューの commit が積まれているため、Ready 化を拒否します。" >&2
echo "  次の行動: /rite:iterate $pr_number" >&2
echo "  強行する場合: ユーザーが「未レビューのまま Ready 化を強行」と明示した再実行のみ（既定では拒否）。" >&2
echo "[CONTEXT] READY_REVIEWED_HEAD=mismatch; reviewed=$reviewed; head=$head_sha" >&2
exit 1
