#!/usr/bin/env bash
# review-schema-version-check.sh
#
# Detect schema_version drift in review-result JSON files.
#
# Accept list (canonical SoT: review-result-schema.md §Schema Version):
#   "1.0.0" — canonical 1.0
#   "1.0"   — legacy semver MAJOR.MINOR alias (accepted until v2.0)
#   "1.1.0" — canonical 1.1
#
# Any other value (including missing schema_version) is reported as drift via:
#   [CONTEXT] REVIEW_SCHEMA_VERSION_DRIFT=1; file=<path>; schema_version=<value>
#
# Invoked from `scripts/fix-step.sh schema-drift-check` (`fix/SKILL.md` ステップ 3.1.1 pre-commit gate),
# and can be run standalone for ad-hoc inspection.
#
# Usage:
#   review-schema-version-check.sh --target FILE [--target FILE]...
#   review-schema-version-check.sh --all              # scan .rite/review-results/*.json
#   REPO_ROOT="/path/to/repo" review-schema-version-check.sh --all
#
# Exit codes:
#   0 — all targets within accept list (or no targets)
#   1 — drift detected on at least one target
#   2 — invocation error (bad args / jq missing)

set -uo pipefail

ACCEPT_LIST=("1.0.0" "1.0" "1.1.0")

usage() {
  cat <<'EOF'
Usage: review-schema-version-check.sh [options]

Options:
  --all              Scan .rite/review-results/*.json in REPO_ROOT
  --target FILE      Check FILE (repeatable). Path may be absolute or relative.
  --repo-root DIR    Repository root (default: state-path-resolve.sh resolution;
                     falls back to git rev-parse --show-toplevel with a WARNING)
  --quiet            Suppress per-file drift output (exit code still reflects state)
  -h, --help         Show this help

Exit: 0 = clean, 1 = drift detected, 2 = invocation error.
EOF
}

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target)
      if [ -z "${2:-}" ]; then
        echo "ERROR: --target requires a value" >&2
        exit 2
      fi
      TARGETS+=("$2"); shift 2 ;;
    --repo-root)
      if [ -z "${2:-}" ]; then
        echo "ERROR: --repo-root requires a value" >&2
        exit 2
      fi
      REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "[rite] ERROR: jq is required for review-schema-version-check.sh but was not found in PATH" >&2
  exit 2
fi

if [ "$USE_ALL" -eq 0 ] && [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

# Resolve REPO_ROOT only when --all is used (per-target paths are resolved as-is).
# review-results は state-path-resolve 基準の共有 root に保存される (review-result-save.sh と
# 同じ anchor)。--show-toplevel はセッション worktree 内で worktree root を返すため、writer と
# 読取先が分裂して本チェックが silent no-op 化する。--repo-root 明示指定は従来どおり優先。
if [ "$USE_ALL" -eq 1 ]; then
  # git repo 外では resolver を呼ばない: state-path-resolve.sh は非 git cwd でも cwd を正常出力
  # として返すため、無条件に採用すると従来の ERROR exit 2 が silent success (exit 0 clean) に
  # 化ける。repo 外の ad-hoc 実行は従来どおり下の ERROR ガードで fail-fast させる。
  if [ -z "$REPO_ROOT" ] && git rev-parse --show-toplevel >/dev/null 2>&1; then
    _check_script_dir="$(dirname "${BASH_SOURCE[0]}")"
    if _check_state_root=$("$_check_script_dir/../state-path-resolve.sh" 2>/dev/null) && [ -n "$_check_state_root" ]; then
      REPO_ROOT="$_check_state_root"
    else
      echo "WARNING: state-path-resolve.sh の解決に失敗。git toplevel をフォールバック使用します" >&2
      REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
    fi
  fi
  if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
    echo "ERROR: REPO_ROOT could not be resolved (not in a git repo and --repo-root unset)" >&2
    exit 2
  fi
  REVIEW_DIR="$REPO_ROOT/.rite/review-results"
  if [ ! -d "$REVIEW_DIR" ]; then
    # No review results yet — clean.
    exit 0
  fi
  while IFS= read -r -d '' f; do
    TARGETS+=("$f")
  done < <(find "$REVIEW_DIR" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  # Nothing to check — clean.
  exit 0
fi

DRIFT_COUNT=0

is_in_accept_list() {
  local v="$1"
  local accepted
  for accepted in "${ACCEPT_LIST[@]}"; do
    if [ "$v" = "$accepted" ]; then
      return 0
    fi
  done
  return 1
}

# Emit drift marker (DRY helper):
# 3 drift reason (missing file / invalid JSON / version mismatch) で同形式の
# `[CONTEXT] REVIEW_SCHEMA_VERSION_DRIFT=1; file=...; schema_version=...` を emit する。
emit_drift() {
  local f="$1"
  local v="$2"
  [ "$QUIET" -eq 0 ] && echo "[CONTEXT] REVIEW_SCHEMA_VERSION_DRIFT=1; file=$f; schema_version=$v" >&2
  DRIFT_COUNT=$((DRIFT_COUNT + 1))
}

for file in "${TARGETS[@]}"; do
  if [ ! -f "$file" ]; then
    emit_drift "$file" "__missing_file__"
    continue
  fi

  if ! jq empty "$file" 2>/dev/null; then
    emit_drift "$file" "__invalid_json__"
    continue
  fi

  version=$(jq -r '.schema_version // "__missing__"' "$file" 2>/dev/null) || version="__missing__"

  if is_in_accept_list "$version"; then
    continue
  fi

  emit_drift "$file" "$version"
done

if [ "$DRIFT_COUNT" -gt 0 ]; then
  [ "$QUIET" -eq 0 ] && echo "[rite] review-schema-version-check: $DRIFT_COUNT drift(s) detected (accept list: ${ACCEPT_LIST[*]})" >&2
  exit 1
fi

exit 0
