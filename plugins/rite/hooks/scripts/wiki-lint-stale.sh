#!/usr/bin/env bash
# wiki-lint-stale.sh
#
# Detect stale Wiki pages for wiki/lint.md ステップ 4 (陳腐化検出). Read each
# page from stdin (pages_list), extract the `generated.at` frontmatter field,
# compare against the cutoff (now - stale_days), and emit the stale set inside
# a marker block alongside a stale_check_ok enum + [CONTEXT] sentinel.
#
# Why a helper:
#   The inline implementation in lint.md ステップ 4 was a per-page bash loop
#   the LLM had to drive manually. A lint run that never executes the loop can
#   still claim "stale=0" — the count is unverifiable from the transcript.
#   Delegating the whole category to this helper makes the count
#   machine-produced: the LLM only transcribes the emitted numbers
#   (same structural guarantee as wiki-lint-skipped-refs.sh /
#   wiki-lint-source-refs.sh for ステップ 6.0 / 6.2).
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --wiki-branch BRANCH                              (required for separate_branch)
#   --stale-days N                                    (default: 90)
#   --repo-root DIR                                   (default: git rev-parse --show-toplevel)
#   stdin: pages_list (改行区切り、`.rite/wiki/pages/...` 形式。空なら 0 件)
#
# stdout contract (LLM holds these in conversation context; lint.md ステップ 4 の
# issues[] append と ステップ 9 完了レポートが参照する):
#   n_stale={n}
#   ---stale_pages_begin---
#   {page}|{updated}|{days_since_update}   # 0..N lines
#   ---stale_pages_end---
#   stale_check_ok={true|skipped_no_gnu_date}
#   [CONTEXT] WIKI_LINT_STALE={n}
#
# stale_check_ok enum:
#   true                 通常実行 (n_stale は信頼可能)
#   skipped_no_gnu_date  GNU date 非互換環境 (macOS/BSD)。n_stale=0 のまま skip
#                        (旧 lint.md の GNU date 事前検査を本 helper に内包)
#
# Exit codes:
#   0  正常 (GNU date 非互換 skip 含む — 非ブロッキング契約)
#   1  fail-fast (placeholder residue / unknown branch_strategy)
#   2  invocation error (引数欠落 / repo-root cd 失敗 / stale-days 非整数)
#
# NOTE on shell flags: sibling helpers (wiki-lint-skipped-refs.sh) と同じく
# per-command rc 管理のため `set -e` は意図的に設定しない。

# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"
branch_strategy=""
wiki_branch=""
stale_days="90"
REPO_ROOT=""

usage() {
  cat <<'EOF'
Usage: wiki-lint-stale.sh --branch-strategy STRATEGY [--wiki-branch BRANCH] [--stale-days N] [--repo-root DIR] < pages_list

Reads pages_list from stdin, compares each page's `generated.at` frontmatter
against the cutoff, and emits the stale set marker block + stale_check_ok
enum + [CONTEXT] sentinel on stdout.

Options:
  --branch-strategy STRATEGY  separate_branch | same_branch (required)
  --wiki-branch BRANCH        Wiki branch ref (required for separate_branch)
  --stale-days N              Staleness threshold in days (default: 90)
  --repo-root DIR             Repository root (default: git rev-parse --show-toplevel)
  -h, --help                  Show this help

Exit codes:
  0  Normal (incl. GNU-date-incompatible skip)
  1  Fail-fast (placeholder residue / unknown branch_strategy)
  2  Invocation error
EOF
}

# 値なしフラグが末尾に来た場合の無限ループ防止のため `shift; shift` を使う
# (wiki-lint-skipped-refs.sh と同じ引数消費規約)。
while [ $# -gt 0 ]; do
  case "$1" in
    --branch-strategy) branch_strategy="${2:-}"; shift; shift ;;
    --wiki-branch) wiki_branch="${2:-}"; shift; shift ;;
    --stale-days) stale_days="${2:-}"; shift; shift ;;
    --repo-root) REPO_ROOT="${2:-}"; shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$branch_strategy" ]; then
  echo "ERROR: --branch-strategy は必須です" >&2
  usage >&2
  exit 2
fi

# ---- Placeholder residue fail-fast gate -------------------------------------
# (sibling helpers と対称。LLM が `{branch_strategy}` / `{wiki_branch}` /
#  `{stale_days}` を literal substitute せずに helper を呼んだ場合の検出。)
case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: ステップ 4 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    echo "  LLM は ステップ 1.1 の stdout から会話コンテキストに保持された branch_strategy 値を literal substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_4_PLACEHOLDER_RESIDUE=1; reason=branch_strategy_unsubstituted; value=$branch_strategy" >&2
    exit 1
    ;;
esac
case "$wiki_branch" in
  "{"*"}")
    echo "ERROR: ステップ 4 の {wiki_branch} placeholder が literal substitute されていません (値: '$wiki_branch')" >&2
    exit 1
    ;;
esac
case "$stale_days" in
  "{"*"}")
    echo "ERROR: ステップ 4 の {stale_days} placeholder が literal substitute されていません (値: '$stale_days')" >&2
    exit 1
    ;;
  ''|*[!0-9]*)
    echo "ERROR: --stale-days は非負整数である必要があります (値: '$stale_days')" >&2
    exit 2
    ;;
esac

case "$branch_strategy" in
  separate_branch|same_branch) ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 4)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac

# separate_branch では --wiki-branch が必須 (空だと git show ":path" が index を
# 読む別 semantics に陥る — sibling helpers と同じ runtime enforcement)。
if [ "$branch_strategy" = "separate_branch" ] && [ -z "$wiki_branch" ]; then
  echo "ERROR: branch_strategy=separate_branch では --wiki-branch が必須です (空のため fail-fast)" >&2
  usage >&2
  exit 2
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root '$REPO_ROOT'" >&2; exit 2; }

# ---- GNU date 事前検査 (旧 lint.md の GNU date 事前検査ステップを内包) --------
# `date -d "ISO 8601"` は GNU coreutils 拡張。macOS/BSD では silent に誤動作
# しないよう skip し、enum で skip 理由を機械可読にする (非ブロッキング契約)。
if ! date -d "2025-01-01" +%s >/dev/null 2>&1; then
  echo "WARNING: GNU date 非互換環境を検出しました。陳腐化検出 (ステップ 4) を skip します" >&2
  echo "  対処: macOS/BSD 環境では coreutils (gdate) のインストールを検討してください" >&2
  echo "n_stale=0"
  echo "---stale_pages_begin---"
  echo "---stale_pages_end---"
  echo "stale_check_ok=skipped_no_gnu_date"
  echo "[CONTEXT] WIKI_LINT_STALE=0"
  exit 0
fi

current_epoch=$(date +%s)
cutoff_epoch=$((current_epoch - stale_days * 86400))

# ---- 走査本体 (旧 lint.md ステップ 4 inline loop の faithful port) -------------
n_stale=0
stale_lines=""

while IFS= read -r page_path; do
  [ -z "$page_path" ] && continue

  case "$branch_strategy" in
    separate_branch)
      page_content=$(git show "${wiki_branch}:$page_path" 2>/dev/null) || page_content=""
      ;;
    same_branch)
      page_content=$(cat "$page_path" 2>/dev/null) || page_content=""
      ;;
  esac
  if [ -z "$page_content" ]; then
    echo "WARNING: $page_path を読み出せません。陳腐化判定を skip します" >&2
    continue
  fi

  updated_str=$(printf '%s' "$page_content" | awk '
    /^generated:/ || /^[[:space:]]+at:[[:space:]]*/ {
      v=$0
      sub(/.*at:[[:space:]]*/, "", v)
      gsub(/[",}[:space:]]/, "", v)
      if (v != "") { print v; exit }
    }
  ')

  if [ -z "$updated_str" ]; then
    echo "WARNING: $page_path に generated.at フィールドが存在しません。陳腐化判定を skip します" >&2
    continue
  fi

  if ! updated_epoch=$(date -d "$updated_str" +%s 2>/dev/null); then
    echo "WARNING: $page_path の generated.at フィールド '$updated_str' をパースできません。陳腐化判定を skip します" >&2
    echo "  対処: ISO 8601 形式（例: 2025-01-01T00:00:00+09:00）で記述してください" >&2
    continue
  fi

  if [ "$updated_epoch" -lt "$cutoff_epoch" ]; then
    days_diff=$(( (current_epoch - updated_epoch) / 86400 ))
    n_stale=$((n_stale + 1))
    stale_lines="${stale_lines}${page_path}|${updated_str}|${days_diff}
"
  fi
done

# 集合本体を marker block で stdout 出力。0 件でも begin/end marker は必ず出力する
# (検査ステップが実行されたことの positive confirmation —
#  canonical: skills/wiki-lint/references/bash-cross-boundary-state-transfer.md Pattern 2)。
echo "n_stale=$n_stale"
echo "---stale_pages_begin---"
[ -n "$stale_lines" ] && printf '%s' "$stale_lines"
echo "---stale_pages_end---"
echo "stale_check_ok=true"
echo "[CONTEXT] WIKI_LINT_STALE=$n_stale"
