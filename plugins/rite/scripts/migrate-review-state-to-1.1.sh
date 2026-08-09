#!/usr/bin/env bash
# migrate-review-state-to-1.1.sh
#
# Migrate review-result JSON files in `.rite/review-results/` from schema
# 1.0 / 1.0.0 / missing to canonical 1.1.0.
#
# Migration adds the two fields introduced in 1.1.0:
#   - findings[].scope        — default mapping from severity
#                                 (CRITICAL/HIGH/MEDIUM → current-pr,
#                                  LOW-MEDIUM/LOW       → nit-noted)
#   - findings[].pre_existing — initialized to false (revert-test result
#                                 unknown for migrated findings; reviewer
#                                 must update manually if applicable)
#
# Additionally initializes per-PR accepted-fingerprints state files
# (`.rite/state/accepted-fingerprints-{pr}.txt`) as empty files when missing.
#
# Idempotency: jq `has(...)` guards ensure repeated runs are no-ops once a
# file is already 1.1.0. Files with schema_version already 1.1.0 are skipped.
#
# Usage:
#   migrate-review-state-to-1.1.sh                     # apply (default REPO_ROOT)
#   migrate-review-state-to-1.1.sh --dry-run           # detect only
#   REPO_ROOT="/path/to/repo" migrate-review-state-to-1.1.sh
#
# Exit codes:
#   0 — migration completed (including no-op / dry-run / empty target set)
#   1 — migration failed (atomic write or jq parse error on a file)

# `-e` を意図的に省略する: 個別ファイルの jq parse 失敗で全体停止させず、
# FAILED_FILES 配列に集約してから末尾で exit 1 する設計 (post-review-state-verify.sh の
# `set -uo pipefail` と同パターン)。pipefail は維持して pipeline 失敗を捕捉する。
set -uo pipefail

_mig_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/control-char-neutralize.sh
source "$_mig_script_dir/../hooks/control-char-neutralize.sh"

# --- Signal-specific trap setup ---
# canonical pattern: references/bash-trap-patterns.md#signal-specific-trap-template
# SIGINT/SIGTERM/SIGHUP で中断時に per-file mktemp tempfile (`${file}.XXXXXX`) を残さない。
# 配列で trap action を管理し、migrate_file 内で `_orphan_tmps+=("$tmp")` を追加する。
declare -a _orphan_tmps=()
_migrate_cleanup() {
  for t in "${_orphan_tmps[@]:-}"; do
    [ -n "$t" ] && [ -e "$t" ] && rm -f "$t"
  done
}
trap 'rc=$?; _migrate_cleanup; exit $rc' EXIT
trap '_migrate_cleanup; exit 130' INT
trap '_migrate_cleanup; exit 143' TERM
trap '_migrate_cleanup; exit 129' HUP

# --- Argument parsing ---
DRY_RUN=false
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  '') ;;
  *) echo "ERROR: unknown argument: $1 (expected: --dry-run)" >&2; exit 1 ;;
esac

# --- REPO_ROOT resolution ---
# 既定は state-path-resolve 基準 (review-result-save.sh / review-schema-version-check.sh と同じ
# anchor)。--show-toplevel はセッション worktree 内で worktree root を返すため、writer が main
# root に置いた JSON を miss して migration が silent no-op 化する。REPO_ROOT env 明示は従来
# どおり優先。git repo 外では resolver を呼ばず (非 git cwd でも cwd を正常出力するため)、
# 従来どおり下の ERROR ガードで fail-fast させる。
if [ -z "${REPO_ROOT:-}" ] && git rev-parse --show-toplevel >/dev/null 2>&1; then
  if _mig_state_root=$("$_mig_script_dir/../hooks/state-path-resolve.sh" 2>/dev/null) && [ -n "$_mig_state_root" ]; then
    REPO_ROOT="$_mig_state_root"
  else
    echo "WARNING: state-path-resolve.sh の解決に失敗。git toplevel をフォールバック使用します" >&2
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
  fi
fi
if [ -z "${REPO_ROOT:-}" ] || [ ! -d "$REPO_ROOT" ]; then
  echo "ERROR: REPO_ROOT could not be resolved (not in a git repo and REPO_ROOT env unset)" >&2
  exit 1
fi

REVIEW_DIR="$REPO_ROOT/.rite/review-results"
STATE_DIR="$REPO_ROOT/.rite/state"

if ! command -v jq >/dev/null 2>&1; then
  echo "[rite] ERROR: jq is required for migrate-review-state-to-1.1.sh but was not found in PATH" >&2
  exit 1
fi

# --- Helper: severity → default scope mapping (1.1.0 schema doc Table) ---
# CRITICAL / HIGH / MEDIUM → current-pr
# LOW-MEDIUM / LOW         → nit-noted
# unknown severity         → current-pr (conservative — surface in fix loop)
DEFAULT_SCOPE_FILTER='
  if .severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM" then "current-pr"
  elif .severity == "LOW-MEDIUM" or .severity == "LOW" then "nit-noted"
  else "current-pr"
  end
'

# --- Migration filter: only fills missing fields (idempotent) ---
# Outer guard: if schema_version already "1.1.0", emit unchanged.
# Otherwise: bump schema_version to "1.1.0", and per-finding fill scope only
# when absent (has(...) guard preserves explicit values).
#
# pre_existing は default mapping を **適用しない** (フィールドを欠落させたまま保持)。
# review-result-schema.md §後方互換性 (line 197-203) が canonical SoT:
#   - revert test (reviewer による mental revert) なしに severity 等から推論不可
#   - 欠落のままで Cross-field invariant #5 (pre_existing=false × scope=nit-noted) が
#     発火しない (`null != false`)
#   - 1.0/1.0.0 JSON の finding は invariant #5 auto-correct 対象外となり後方互換が保たれる
# `.pre_existing = false` を初期化してはならない。初期化すると migrated LOW finding が
# scope=nit-noted + pre_existing=false の組合せになり、read 側 invariant #5 で scope を
# current-pr に書き換えてしまう後方互換破壊を招く。
MIGRATE_FILTER='
  if (.schema_version // "") == "1.1.0" then .
  else
    .schema_version = "1.1.0"
    | .findings |= map(
        (if has("scope") then . else .scope = ('"$DEFAULT_SCOPE_FILTER"') end)
      )
  end
'

MIGRATED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
FAILED_FILES=()

migrate_file() {
  local file="$1"
  local tmp parsed_ver

  if ! jq empty "$file" 2>/dev/null; then
    echo "[rite] ERROR: $file is not valid JSON — skipping" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$file")
    return
  fi

  parsed_ver=$(jq -r '.schema_version // "missing"' "$file" 2>/dev/null) || parsed_ver="missing"

  case "$parsed_ver" in
    "1.1.0")
      # Already canonical — no-op (idempotency)
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      return
      ;;
    "1.0.0"|"1.0"|"missing")
      : # proceed
      ;;
    *)
      echo "[rite] WARNING: $file has unknown schema_version='$parsed_ver' — skipping (manual review required)" >&2
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      return
      ;;
  esac

  if [ "$DRY_RUN" = "true" ]; then
    echo "[rite] dry-run: would migrate $file (schema_version='$parsed_ver' → 1.1.0)" >&2
    MIGRATED_COUNT=$((MIGRATED_COUNT + 1))
    return
  fi

  # Atomic write: jq → tempfile → mv
  tmp=$(mktemp "${file}.XXXXXX") || {
    echo "[rite] ERROR: mktemp failed for $file" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$file")
    return
  }
  # Signal-aware orphan tracking: SIGINT/SIGTERM/SIGHUP で中断時に
  # `${file}.XXXXXX` が `.rite/review-results/` 直下に残らないよう trap 配列に登録。
  _orphan_tmps+=("$tmp")

  # jq の stderr (parse error の line/column / locale 起因の異常 / OOM 等) を捕捉。
  # 完全 silent にすると failed_files の root cause がユーザに見えず再 migration 時に再現できない。
  local _jq_err
  _jq_err=$(mktemp 2>/dev/null) || _jq_err=""
  if ! jq "$MIGRATE_FILTER" "$file" > "$tmp" 2>"${_jq_err:-/dev/null}"; then
    local _jq_rc=$?
    echo "[rite] ERROR: jq migration filter failed for $file (rc=$_jq_rc)" >&2
    [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    [ -n "$_jq_err" ] && rm -f "$_jq_err"
    rm -f "$tmp"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$file")
    return
  fi
  [ -n "$_jq_err" ] && rm -f "$_jq_err"

  if [ ! -s "$tmp" ]; then
    echo "[rite] ERROR: migrated output empty for $file (jq produced no output)" >&2
    rm -f "$tmp"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$file")
    return
  fi

  # mv の rc と stderr を両方 capture して errno 詳細 (EXDEV / EACCES / ENOSPC / EROFS /
  # SELinux deny) を triage 可能にする。bare mv + `if !` は rc を 0/1 に collapse し
  # operator は failed_files に積み上がる root cause を判別できない。
  local _mig_mv_err _mig_mv_rc=0
  _mig_mv_err=$(mktemp 2>/dev/null) || _mig_mv_err=""
  if mv "$tmp" "$file" 2>"${_mig_mv_err:-/dev/null}"; then
    :
  else
    _mig_mv_rc=$?
    echo "[rite] ERROR: atomic mv failed for $file (rc=$_mig_mv_rc, tmp=$tmp left behind for inspection)" >&2
    [ -n "$_mig_mv_err" ] && [ -s "$_mig_mv_err" ] && head -3 "$_mig_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    [ -n "$_mig_mv_err" ] && rm -f "$_mig_mv_err"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_FILES+=("$file (tmp=$tmp)")
    return
  fi
  [ -n "$_mig_mv_err" ] && rm -f "$_mig_mv_err"
  # mv 成功後: orphan 配列から該当 tmp を除外 (二重 rm 回避 / failure 時の inspection 用に preserve)
  # 配列から要素を削除する portable な方法: tmp が一致する要素のみ skip して新配列を作る
  declare -a _new_orphans=()
  for t in "${_orphan_tmps[@]:-}"; do
    [ "$t" = "$tmp" ] || _new_orphans+=("$t")
  done
  _orphan_tmps=("${_new_orphans[@]:-}")
  unset _new_orphans

  echo "[rite] migrated: $file ($parsed_ver → 1.1.0)" >&2
  MIGRATED_COUNT=$((MIGRATED_COUNT + 1))
}

# --- Step 1: Migrate review-result JSON files ---
if [ -d "$REVIEW_DIR" ]; then
  while IFS= read -r -d '' f; do
    migrate_file "$f"
  done < <(find "$REVIEW_DIR" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
else
  echo "[rite] info: review-results directory not present ($REVIEW_DIR) — skipping JSON migration" >&2
fi

# --- Step 2: Initialize per-PR accepted-fingerprints state files ---
# Enumerate PR numbers from `.rite/review-results/{pr}-*.json` and ensure
# `.rite/state/accepted-fingerprints-{pr}.txt` exists (empty if newly created).
INIT_COUNT=0
if [ -d "$REVIEW_DIR" ]; then
  pr_numbers=$(find "$REVIEW_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
    | sed 's|.*/||; s|-.*||' \
    | grep -E '^[0-9]+$' \
    | sort -u)

  if [ -n "$pr_numbers" ]; then
    if [ "$DRY_RUN" != "true" ] && [ ! -d "$STATE_DIR" ]; then
      mkdir -p "$STATE_DIR" 2>/dev/null || {
        echo "[rite] WARNING: failed to create state directory $STATE_DIR — accepted-fingerprints init skipped" >&2
        pr_numbers=""
      }
    fi

    while IFS= read -r pr; do
      [ -z "$pr" ] && continue
      state_file="$STATE_DIR/accepted-fingerprints-${pr}.txt"
      if [ ! -f "$state_file" ]; then
        if [ "$DRY_RUN" = "true" ]; then
          echo "[rite] dry-run: would initialize empty $state_file" >&2
        else
          : > "$state_file" || {
            echo "[rite] WARNING: failed to initialize $state_file" >&2
            continue
          }
          echo "[rite] initialized: $state_file (empty)" >&2
        fi
        INIT_COUNT=$((INIT_COUNT + 1))
      fi
    done <<< "$pr_numbers"
  fi
fi

# --- Summary ---
if [ "$DRY_RUN" = "true" ]; then
  echo "[rite] dry-run summary: would migrate=$MIGRATED_COUNT, skip=$SKIPPED_COUNT, fail=$FAILED_COUNT, init-fingerprint-files=$INIT_COUNT" >&2
else
  echo "[rite] migration summary: migrated=$MIGRATED_COUNT, skipped=$SKIPPED_COUNT, failed=$FAILED_COUNT, init-fingerprint-files=$INIT_COUNT" >&2
fi

if [ "$FAILED_COUNT" -gt 0 ]; then
  echo "[rite] failed files:" >&2
  for f in "${FAILED_FILES[@]}"; do
    echo "  - $f" >&2
  done
  exit 1
fi

exit 0
