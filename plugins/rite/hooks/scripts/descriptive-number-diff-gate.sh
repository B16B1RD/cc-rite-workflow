#!/usr/bin/env bash
# Blocks descriptive Issue/PR references introduced on added lines under
# plugins/rite/. Detection vocabulary and exclusions remain owned by
# comment-journal-check.sh P5/P6; this gate only supplies the diff boundary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"
REPO_ROOT=""
BASE_REF=""
BASE_BRANCH=""

usage() {
  echo "Usage: descriptive-number-diff-gate.sh [--base-ref REF | --base-branch NAME] [--repo-root DIR]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base-ref) BASE_REF=${2:-}; shift 2 ;;
    --base-branch) BASE_BRANCH=${2:-}; shift 2 ;;
    --repo-root) REPO_ROOT=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$REPO_ROOT" ] || REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "ERROR: repository root could not be resolved" >&2
  exit 2
}
cd "$REPO_ROOT" || exit 2

if [ -z "$BASE_REF" ]; then
  if [ -z "$BASE_BRANCH" ]; then
    BASE_BRANCH=$(awk '/^branch:/{in_branch=1; next} in_branch && /^[^[:space:]]/{in_branch=0} in_branch && /^[[:space:]]+base:/{gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' rite-config.yml 2>/dev/null || true)
    [ -n "$BASE_BRANCH" ] || BASE_BRANCH=main
  fi
  if git rev-parse --verify "origin/${BASE_BRANCH}^{commit}" >/dev/null 2>&1; then
    BASE_REF="origin/$BASE_BRANCH"
  elif git rev-parse --verify "${BASE_BRANCH}^{commit}" >/dev/null 2>&1; then
    BASE_REF="$BASE_BRANCH"
  else
    echo "ERROR: descriptive-number diff base could not be resolved: $BASE_BRANCH" >&2
    exit 2
  fi
elif ! git rev-parse --verify "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  echo "ERROR: descriptive-number diff base is invalid: $BASE_REF" >&2
  exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/rite-number-diff-gate-XXXXXX") || exit 2
trap 'rm -rf "$tmp_dir"' EXIT INT TERM HUP
added="$tmp_dir/added.tsv"
files_nul="$tmp_dir/files.nul"
status_nul="$tmp_dir/status.nul"
if ! git diff --find-renames=1% --name-only -z "$BASE_REF"...HEAD -- plugins/rite > "$files_nul" ||
   ! git diff --find-renames=1% --name-status -z "$BASE_REF"...HEAD -- plugins/rite > "$status_nul"; then
  echo "ERROR: descriptive-number diff could not be read from $BASE_REF" >&2
  exit 2
fi

force_all="$tmp_dir/force-all.txt"
: > "$force_all"
declare -A rename_old_by_new=()
while IFS= read -r -d '' status; do
  case "$status" in
    R*|C*)
      IFS= read -r -d '' old_path || exit 2
      IFS= read -r -d '' new_path || exit 2
      if [[ "$old_path" == */tests/* && "$new_path" == plugins/rite/* && "$new_path" != */tests/* ]]; then
        printf '%s\n' "$new_path" >> "$force_all"
      elif [[ "$old_path" == plugins/rite/* && "$old_path" != */tests/* && "$new_path" == plugins/rite/* && "$new_path" != */tests/* ]]; then
        rename_old_by_new["$new_path"]="$old_path"
      fi
      ;;
    *) IFS= read -r -d '' _path || exit 2 ;;
  esac
done < "$status_nul"

: > "$tmp_dir/findings.txt"
while IFS= read -r -d '' file; do
  case "$file" in plugins/rite/*/tests/*|plugins/rite/tests/*) continue ;; esac
  [ -f "$file" ] || continue
  case "$file" in *$'\n'*|*:*)
    echo "ERROR: descriptive-number gate cannot safely represent path: $file" >&2
    exit 2
    ;;
  esac

  lines="$tmp_dir/lines"
  if grep -Fxq -- "$file" "$force_all"; then
    printf '*\n' > "$lines"
  else
    per_diff="$tmp_dir/per-file.diff"
    if ! git -c core.quotePath=false diff --find-renames=1% --unified=0 --no-color "$BASE_REF"...HEAD -- "$file" > "$per_diff"; then
      echo "ERROR: descriptive-number diff could not be read for path: $file" >&2
      exit 2
    fi
    awk '
      /^@@ / { if (match($0, /\+[0-9]+/)) line=substr($0,RSTART+1,RLENGTH-1)+0; next }
      /^\+/ && !/^\+\+\+/ { print line; line++; next }
      /^-/ { next }
      { if (line > 0) line++ }
    ' "$per_diff" > "$lines"
    if [ -n "${rename_old_by_new[$file]:-}" ]; then
      old_snapshot="$tmp_dir/old-file"
      filtered_lines="$tmp_dir/filtered-lines"
      if ! git show "$BASE_REF:${rename_old_by_new[$file]}" > "$old_snapshot" 2>/dev/null; then
        echo "ERROR: descriptive-number rename source could not be read: ${rename_old_by_new[$file]}" >&2
        exit 2
      fi
      awk '
        FILENAME == ARGV[1] { old[$0]++; next }
        FILENAME == ARGV[2] { wanted[$1]=1; next }
        FILENAME == ARGV[3] && wanted[FNR] {
          if (old[$0] > 0) old[$0]--
          else print FNR
        }
      ' "$old_snapshot" "$lines" "$file" > "$filtered_lines"
      mv "$filtered_lines" "$lines"
    fi
  fi
  [ -s "$lines" ] || continue

  detector_out="$tmp_dir/detector.txt"
  detector_rc=0
  bash "$SCRIPT_DIR/comment-journal-check.sh" --repo-root "$REPO_ROOT" --quiet --target "$file" > "$detector_out" 2>"$tmp_dir/detector.err" || detector_rc=$?
  if [ "$detector_rc" -gt 1 ]; then
    neutralize_ctrl --keep-newline < "$tmp_dir/detector.err" >&2
    echo "ERROR: descriptive-number detector could not complete" >&2
    exit 2
  fi
  awk 'NR==FNR { if ($1=="*") all=1; else wanted[$1]=1; next }
    /^\[comment-journal\]\[P[56]\] / {
      if (match($0, /:[0-9]+:/)) {
        n=substr($0,RSTART+1,RLENGTH-2)+0
        if (all || wanted[n]) print $0
      }
    }
  ' "$lines" "$detector_out" >> "$tmp_dir/findings.txt"
done < "$files_nul"

count=$(wc -l < "$tmp_dir/findings.txt" | tr -d ' ')
if [ "$count" -gt 0 ]; then
  cat "$tmp_dir/findings.txt"
  echo "修正方針: 番号を削除し、番号が担っていた理由を自己完結した Why 散文で記述してください。"
fi
echo "Total descriptive-number diff findings: $count"
[ "$count" -eq 0 ] || exit 1
