#!/usr/bin/env bash
# wiki-growth-check.sh
#
# Detect Wiki growth stalls — fires when the last commit on the `wiki` branch
# is older than `wiki.growth_check.threshold_prs` consecutive merged PRs on
# the development base branch (default: develop). This catches "Wiki ingest is
# silently broken" regressions where review/fix/close skip Phase X.X.W and the
# wiki branch never grows even though PRs are landing.
#
# Issue #524 (Wiki ingest silent skip 3層防御) — layer 3 (lint growth check).
# Companion to:
#   - layer 0: hooks/scripts/wiki-ingest-commit.sh — deterministic single-process
#              raw-source commit path invoked from review.md / fix.md / close.md
#              Phase X.X.W.2. This is the foundation that makes layer 3 a genuine
#              regression signal rather than a symptom of fragile LLM orchestration.
#   - layer 1: review.md / fix.md / close.md Phase X.X.W skip 不可化
#   - layer 2: workflow-incident-emit.sh の wiki_ingest_skipped / wiki_ingest_failed sentinel
#
# Usage:
#   wiki-growth-check.sh [--repo-root DIR] [--quiet] [--threshold N]
#                        [--pr-raw-threshold N] [-h|--help]
#
# Options:
#   --repo-root DIR        Repository root (default: git rev-parse --show-toplevel)
#   --quiet                Suppress informational output (still emits findings line)
#   --threshold N          Override growth-stall threshold from rite-config.yml
#   --pr-raw-threshold N   Override PR↔raw correspondence threshold (Issue #536)
#   -h, --help             Show this help
#
# Exit codes (drift-check と同一の非ブロッキング契約):
#   0  Wiki growth healthy (or wiki branch absent / wiki disabled — skip silently)
#   1  Wiki growth threshold exceeded (warning — caller MUST keep [lint:success])
#   2  Invocation error (bad args, missing repo, missing gh CLI)
#
# Output:
#   Always prints a `==> Total wiki-growth-check findings: N` line on stdout
#   (parsed by lint.md Phase 3.8 to populate `wiki_growth_finding_count`).
#
set -uo pipefail

# Signal-specific trap (canonical signal-specific trap pattern from references/bash-trap-patterns.md):
# - EXIT preserves the original exit code via `rc=$?`
# - INT/TERM/HUP exit with explicit POSIX-conventional codes (130/143/129)
# - Tempfiles registered via `_rite_wiki_growth_cleanup` are cleaned in all paths
gh_pr_list_err=""
git_log_err=""
jq_err=""
_rite_wiki_growth_cleanup() {
  rm -f "${gh_pr_list_err:-}" "${git_log_err:-}" "${jq_err:-}"
}
trap 'rc=$?; _rite_wiki_growth_cleanup; exit $rc' EXIT
trap '_rite_wiki_growth_cleanup; exit 130' INT
trap '_rite_wiki_growth_cleanup; exit 143' TERM
trap '_rite_wiki_growth_cleanup; exit 129' HUP

REPO_ROOT=""
QUIET=0
THRESHOLD_OVERRIDE=""
PR_RAW_THRESHOLD_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: wiki-growth-check.sh [options]

Options:
  --repo-root DIR          Repository root (default: git rev-parse --show-toplevel)
  --quiet                  Suppress informational output
  --threshold N            Override growth-stall threshold (default: read from
                           rite-config.yml, fallback 5)
  --pr-raw-threshold N     Override PR↔raw correspondence threshold (default:
                           read from rite-config.yml, fallback 3) (Issue #536)
  -h, --help               Show this help

Exit codes:
  0  No growth stall (or wiki disabled / wiki branch absent — skip silently)
  1  Growth threshold exceeded (warning, non-blocking)
  2  Invocation error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root)           REPO_ROOT="$2"; shift 2 ;;
    --quiet)               QUIET=1; shift ;;
    --threshold)           THRESHOLD_OVERRIDE="$2"; shift 2 ;;
    --pr-raw-threshold)    PR_RAW_THRESHOLD_OVERRIDE="$2"; shift 2 ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- Resolve repo root ---
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: not inside a git repository (git rev-parse --show-toplevel failed)" >&2
    echo "==> Total wiki-growth-check findings: 0"
    exit 2
  }
fi
cd "$REPO_ROOT" || {
  echo "ERROR: cannot cd to repo root: $REPO_ROOT" >&2
  echo "==> Total wiki-growth-check findings: 0"
  exit 2
}

log_info() {
  [ "$QUIET" -eq 0 ] && echo "$@"
}

# --- Read config ---
config_file="rite-config.yml"
if [ ! -f "$config_file" ]; then
  log_info "wiki-growth-check: rite-config.yml not found, skipping (exit 0)"
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi

# wiki.enabled (opt-out default true)
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' "$config_file" 2>/dev/null) || wiki_section=""

# wiki section が空 (rite-config.yml に wiki: セクション自体がない) なら早期 exit
# (L-4 修正: 後続の branch_name 抽出等を無駄に試みない)
if [ -z "$wiki_section" ]; then
  log_info "wiki-growth-check: wiki section absent in rite-config.yml — skipping (exit 0)"
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi

wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' \
  | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled" in
  false|no|0) wiki_enabled="false" ;;
  true|yes|1) wiki_enabled="true" ;;
  *)          wiki_enabled="true" ;;  # opt-out default
esac

if [ "$wiki_enabled" = "false" ]; then
  log_info "wiki-growth-check: wiki.enabled=false, skipping (exit 0)"
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi

# Threshold: --threshold override > rite-config.yml > default 5
if [ -n "$THRESHOLD_OVERRIDE" ]; then
  threshold="$THRESHOLD_OVERRIDE"
else
  # Look for `growth_check:` section nested under `wiki:` and pick `threshold_prs:`
  # Section の終了は indent レベル (2 スペース) で判定する。
  # `growth_check:` 配下に `threshold_prs:` 以外の sibling key (例: `enabled:`,
  # `base_branch_override:`) が先に追加されると section を抜けたと誤判定して silent fail
  # する欠陥があった。section 終了は「同 indent (4 スペース) 以外の non-empty 行」、
  # かつ「より浅い indent (2 スペース wiki: 直下の sibling)」で判定する。
  threshold=$(printf '%s\n' "$wiki_section" \
    | awk '
      /^[[:space:]]+growth_check:/ { in_gc=1; gc_indent=match($0, /[^[:space:]]/); next }
      in_gc {
        # 空行は section 内とみなす (YAML の慣習)
        if ($0 ~ /^[[:space:]]*$/) next
        # 現在行の indent を取得
        cur_indent=match($0, /[^[:space:]]/)
        # growth_check: と同じか浅い indent の non-empty key 行が出たら section 終了
        if (cur_indent <= gc_indent) { in_gc=0; next }
        # section 内かつ threshold_prs: 行ならマッチ
        if ($0 ~ /^[[:space:]]+threshold_prs:/) { print; exit }
      }
    ' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*threshold_prs:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
fi
if [ -z "$threshold" ] || ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -lt 1 ]; then
  threshold=5
fi

# --- Wiki branch existence + last commit timestamp ---
# branch_name (default "wiki") from rite-config.yml
wiki_branch=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+branch_name:/ { print; exit }' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -z "$wiki_branch" ] && wiki_branch="wiki"

# Try local branch first, then remote tracking branch
# git log の stderr を tempfile に退避し、permission/repo corruption 等の
# 失敗を「branch not found」と誤報告する経路を排除する
last_wiki=""
git_log_err=$(mktemp /tmp/rite-wiki-growth-git-err-XXXXXX 2>/dev/null) || git_log_err=""
if [ -z "$git_log_err" ]; then
  echo "WARNING: mktemp が失敗しました — git log 失敗時の stderr 詳細が surface できません" >&2
fi
git_log_target=""
if git rev-parse --verify "$wiki_branch" >/dev/null 2>&1; then
  git_log_target="$wiki_branch"
elif git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1; then
  git_log_target="origin/$wiki_branch"
fi

if [ -n "$git_log_target" ]; then
  if last_wiki=$(git log -1 --format=%aI "$git_log_target" 2>"${git_log_err:-/dev/null}"); then
    : # success
  else
    git_log_rc=$?
    echo "WARNING: git log on '$git_log_target' failed (rc=$git_log_rc) — wiki-growth-check skipped" >&2
    [ -n "$git_log_err" ] && [ -s "$git_log_err" ] && head -3 "$git_log_err" | sed 's/^/  /' >&2
    echo "  対処: repository の整合性 (.git permission / corrupt object) を確認してください" >&2
    [ -n "$git_log_err" ] && rm -f "$git_log_err"
    git_log_err=""
    echo "==> Total wiki-growth-check findings: 0"
    exit 0
  fi
fi
[ -n "$git_log_err" ] && rm -f "$git_log_err"
git_log_err=""

if [ -z "$last_wiki" ]; then
  log_info "wiki-growth-check: wiki branch '$wiki_branch' not found locally or on origin — skipping (exit 0)"
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi

# --- Determine base branch (default: develop, fallback: main) ---
base_branch=$(awk '
  /^branch:/ { in_branch=1; next }
  in_branch && /^[[:space:]]+base:/ { print; exit }
  in_branch && /^[a-zA-Z]/ { in_branch=0 }
' "$config_file" 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -z "$base_branch" ] && base_branch="develop"

# --- Count merged PRs since last wiki commit ---
if ! command -v gh >/dev/null 2>&1; then
  echo "WARNING: gh CLI not found — wiki-growth-check skipped" >&2
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: jq not found — wiki-growth-check skipped" >&2
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi

# `merged:>YYYY-MM-DD` — gh search interprets full ISO 8601 timestamps too
# gh pr list の stderr を tempfile に退避し、auth error / network error / rate limit を可視化する
gh_pr_list_err=$(mktemp /tmp/rite-wiki-growth-gh-err-XXXXXX 2>/dev/null) || gh_pr_list_err=""
if [ -z "$gh_pr_list_err" ]; then
  echo "WARNING: mktemp が失敗しました — gh pr list 失敗時の stderr 詳細が surface できません" >&2
fi
gh_json_out=""
if gh_json_out=$(gh pr list \
    --state merged \
    --base "$base_branch" \
    --search "merged:>$last_wiki" \
    --json number \
    --limit 200 2>"${gh_pr_list_err:-/dev/null}"); then
  : # success
else
  gh_rc=$?
  echo "WARNING: gh pr list failed (rc=$gh_rc) — wiki-growth-check skipped" >&2
  [ -n "$gh_pr_list_err" ] && [ -s "$gh_pr_list_err" ] && head -5 "$gh_pr_list_err" | sed 's/^/  /' >&2
  echo "  対処: gh auth status (auth error) / network 接続 / rate limit を確認してください" >&2
  [ -n "$gh_pr_list_err" ] && rm -f "$gh_pr_list_err"
  gh_pr_list_err=""
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi
[ -n "$gh_pr_list_err" ] && rm -f "$gh_pr_list_err"
gh_pr_list_err=""

# jq stderr を tempfile に退避し、parse error 等を surface する
jq_err=$(mktemp /tmp/rite-wiki-growth-jq-err-XXXXXX 2>/dev/null) || jq_err=""
if [ -z "$jq_err" ]; then
  echo "WARNING: mktemp が失敗しました — jq 失敗時の stderr 詳細が surface できません" >&2
fi
merged_count=$(printf '%s' "$gh_json_out" | jq 'length' 2>"${jq_err:-/dev/null}")
jq_rc=$?

if [ -z "$merged_count" ] || ! [[ "$merged_count" =~ ^[0-9]+$ ]]; then
  echo "WARNING: gh pr list の JSON 解析に失敗しました (jq rc=$jq_rc) — wiki-growth-check skipped" >&2
  [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | sed 's/^/  jq: /' >&2
  echo "  raw stdout (先頭 200 文字): $(printf '%s' "$gh_json_out" | head -c 200)" >&2
  [ -n "$jq_err" ] && rm -f "$jq_err"
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi
[ -n "$jq_err" ] && rm -f "$jq_err"

# --- Decision: growth stall check (existing) ---
findings=0

if [ "$merged_count" -ge "$threshold" ]; then
  echo "==> Wiki growth stall detected: $merged_count merged PRs on '$base_branch' since last '$wiki_branch' commit ($last_wiki) — no raw sources ingested (threshold: $threshold)"
  echo "==> Hint: Phase X.X.W (Wiki Ingest Trigger) may be silently skipped in review/fix/close. Check WIKI_INGEST_DONE / WIKI_INGEST_SKIPPED / WIKI_INGEST_FAILED context lines."
  findings=$((findings + 1))
else
  log_info "wiki-growth-check: growth-stall: healthy ($merged_count merged PRs since last '$wiki_branch' commit, threshold: $threshold)"
fi

# --- PR ↔ raw source correspondence check (Issue #536) ---
# For each of the last N merged PRs, check whether at least one raw source
# file exists on the wiki branch with a matching `pr-{number}` in its name.
# This detects regressions where PRs are merged but Phase X.X.W never fires,
# even when the wiki branch is otherwise receiving commits from other sources.

check_pr_raw_correspondence() {
  # Read pr_raw_threshold: CLI override > rite-config.yml > default 3
  local pr_raw_thresh
  if [ -n "$PR_RAW_THRESHOLD_OVERRIDE" ]; then
    pr_raw_thresh="$PR_RAW_THRESHOLD_OVERRIDE"
  else
    pr_raw_thresh=$(printf '%s\n' "$wiki_section" \
    | awk '
      /^[[:space:]]+growth_check:/ { in_gc=1; gc_indent=match($0, /[^[:space:]]/); next }
      in_gc {
        if ($0 ~ /^[[:space:]]*$/) next
        cur_indent=match($0, /[^[:space:]]/)
        if (cur_indent <= gc_indent) { in_gc=0; next }
        if ($0 ~ /^[[:space:]]+pr_raw_threshold:/) { print; exit }
      }
    ' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*pr_raw_threshold:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
  fi
  if [ -z "$pr_raw_thresh" ] || ! [[ "$pr_raw_thresh" =~ ^[0-9]+$ ]] || [ "$pr_raw_thresh" -lt 1 ]; then
    pr_raw_thresh=3
  fi

  # Get the last `threshold` merged PRs (reuse existing threshold for the window size)
  local recent_prs_json recent_pr_numbers
  local gh_pr_err
  gh_pr_err=$(mktemp /tmp/rite-wiki-growth-pr-err-XXXXXX 2>/dev/null) || gh_pr_err=""
  recent_prs_json=$(gh pr list \
    --state merged \
    --base "$base_branch" \
    --json number \
    --limit "$threshold" 2>"${gh_pr_err:-/dev/null}") || {
    echo "WARNING: wiki-growth-check: pr-raw-correspondence: gh pr list failed, skipping" >&2
    [ -n "$gh_pr_err" ] && [ -s "$gh_pr_err" ] && head -3 "$gh_pr_err" | sed 's/^/  /' >&2
    [ -n "$gh_pr_err" ] && rm -f "$gh_pr_err"
    return 0
  }
  [ -n "$gh_pr_err" ] && rm -f "$gh_pr_err"

  local jq_pr_err
  jq_pr_err=$(mktemp /tmp/rite-wiki-growth-jq-err-XXXXXX 2>/dev/null) || jq_pr_err=""
  recent_pr_numbers=$(printf '%s' "$recent_prs_json" | jq -r '.[].number' 2>"${jq_pr_err:-/dev/null}") || {
    echo "WARNING: wiki-growth-check: pr-raw-correspondence: jq parse failed, skipping" >&2
    [ -n "$jq_pr_err" ] && [ -s "$jq_pr_err" ] && head -3 "$jq_pr_err" | sed 's/^/  /' >&2
    [ -n "$jq_pr_err" ] && rm -f "$jq_pr_err"
    return 0
  }
  [ -n "$jq_pr_err" ] && rm -f "$jq_pr_err"

  if [ -z "$recent_pr_numbers" ]; then
    log_info "wiki-growth-check: pr-raw-correspondence: no recent merged PRs found"
    return 0
  fi

  # Get all raw source filenames from the wiki branch (local or remote)
  local raw_files
  raw_files=$(git ls-tree --name-only -r "$git_log_target" -- .rite/wiki/raw/ 2>/dev/null) || raw_files=""

  # Extract unique PR numbers that have raw sources
  local raw_pr_numbers
  raw_pr_numbers=$(printf '%s\n' "$raw_files" | grep -oE 'pr-[0-9]+' | sed 's/pr-//' | sort -u)

  # Count how many recent PRs have NO corresponding raw source
  local missing_count=0
  local missing_prs=""
  local total_checked=0
  while IFS= read -r pr_num; do
    [ -z "$pr_num" ] && continue
    total_checked=$((total_checked + 1))
    if ! printf '%s\n' "$raw_pr_numbers" | grep -qx "$pr_num"; then
      missing_count=$((missing_count + 1))
      missing_prs="${missing_prs:+$missing_prs, }#$pr_num"
    fi
  done <<< "$recent_pr_numbers"

  if [ "$total_checked" -eq 0 ]; then
    log_info "wiki-growth-check: pr-raw-correspondence: no PRs to check"
    return 0
  fi

  if [ "$missing_count" -ge "$pr_raw_thresh" ]; then
    echo "==> PR↔raw correspondence gap: $missing_count of $total_checked recent merged PRs have no raw source on '$wiki_branch' (threshold: $pr_raw_thresh)"
    echo "==> Missing PRs: $missing_prs"
    echo "==> Hint: Phase X.X.W (Wiki Ingest Trigger) may not be firing for these PRs. Verify review.md Phase 6.5.W.2 / fix.md Phase 4.6.W.2 / close.md Phase 4.4.W.2 execution."
    return 1
  fi

  log_info "wiki-growth-check: pr-raw-correspondence: healthy ($missing_count of $total_checked recent PRs missing raw, threshold: $pr_raw_thresh)"
  return 0
}

if ! check_pr_raw_correspondence; then
  findings=$((findings + 1))
fi

# --- Final result ---
echo "==> Total wiki-growth-check findings: $findings"
if [ "$findings" -gt 0 ]; then
  exit 1
fi
exit 0
