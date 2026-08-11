#!/usr/bin/env bash
# Blocks descriptive Issue/PR references introduced on added lines under
# plugins/rite/. Detection vocabulary and exclusions remain owned by
# comment-journal-check.sh P5/P6; this gate only supplies the diff boundary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
diff_file="$tmp_dir/diff.txt"
if ! git -c core.quotePath=false diff --find-renames=1% --unified=0 --no-color "$BASE_REF"...HEAD -- plugins/rite > "$diff_file"; then
  echo "ERROR: descriptive-number diff could not be read from $BASE_REF" >&2
  exit 2
fi

awk '
  /^diff --git / { rename_from=""; rename_to=""; next }
  /^rename from / { rename_from=substr($0,13); next }
  /^rename to / {
    rename_to=substr($0,11)
    if (rename_from ~ /(^|\/)tests\// && rename_to ~ /^plugins\/rite\// && rename_to !~ /(^|\/)tests\//) {
      print rename_to "\t*"
    }
    next
  }
  /^\+\+\+ b\// { file=substr($0,7); sub(/\t.*$/, "", file); next }
  /^@@ / {
    if (match($0, /\+[0-9]+/)) line=substr($0, RSTART+1, RLENGTH-1)+0
    next
  }
  /^\+/ && !/^\+\+\+/ {
    if (file ~ /^plugins\/rite\// && file !~ /(^|\/)tests\//) print file "\t" line
    line++; next
  }
  /^-/ { next }
  { if (file != "") line++ }
' "$diff_file" > "$added"

[ -s "$added" ] || { echo "Total descriptive-number diff findings: 0"; exit 0; }
cut -f1 "$added" | sort -u > "$tmp_dir/files.txt"
detector_out="$tmp_dir/detector.txt"
detector_rc=0
args=()
while IFS= read -r file; do args+=(--target "$file"); done < "$tmp_dir/files.txt"
bash "$SCRIPT_DIR/comment-journal-check.sh" --repo-root "$REPO_ROOT" --quiet "${args[@]}" > "$detector_out" 2>"$tmp_dir/detector.err" || detector_rc=$?
if [ "$detector_rc" -gt 1 ]; then
  cat "$tmp_dir/detector.err" >&2
  echo "ERROR: descriptive-number detector could not complete" >&2
  exit 2
fi

awk -F '\t' 'NR==FNR { if ($2 == "*") all[$1]=1; else added[$1 ":" $2]=1; next }
  /^\[comment-journal\]\[P[56]\] / {
    rest=$0; sub(/^\[comment-journal\]\[P[56]\] /, "", rest)
    if (match(rest, /:[0-9]+:/)) {
      key=substr(rest,1,RSTART+RLENGTH-2)
      path=substr(rest,1,RSTART-1)
      if (added[key] || all[path]) print $0
    }
  }
' "$added" "$detector_out" > "$tmp_dir/findings.txt"

count=$(wc -l < "$tmp_dir/findings.txt" | tr -d ' ')
if [ "$count" -gt 0 ]; then
  cat "$tmp_dir/findings.txt"
  echo "修正方針: 番号を削除し、番号が担っていた理由を自己完結した Why 散文で記述してください。"
fi
echo "Total descriptive-number diff findings: $count"
[ "$count" -eq 0 ] || exit 1
