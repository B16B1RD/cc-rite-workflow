#!/usr/bin/env bash
set -euo pipefail

pr=""
state_root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) pr=${2:-}; shift 2 ;;
    --state-root) state_root=${2:-}; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$pr" in ''|*[!0-9]*) echo "ERROR: --pr must be a positive integer" >&2; exit 2 ;; esac
[ -n "$state_root" ] || { echo "ERROR: --state-root is required" >&2; exit 2; }

results_dir="$state_root/.rite/review-results"
pin_dir="$state_root/.rite/state"
pin_file="$pin_dir/review-run-since-${pr}.txt"
mkdir -p "$pin_dir"
if [ ! -d "$results_dir" ]; then
  rm -f -- "$pin_file"
  exit 0
fi
if ! latest_json=$(find "$results_dir" -maxdepth 1 -type f -name "${pr}-*.json" | LC_ALL=C sort | tail -1); then
  echo "ERROR: review result JSON search failed for PR #$pr" >&2
  exit 1
fi
if [ -z "$latest_json" ]; then
  # JSON persistence is non-blocking.  With no usable prior result, an absent pin
  # makes review-cycle-scope.sh choose its fail-safe full/no_prev_json path.
  rm -f -- "$pin_file"
  exit 0
fi
tmp=$(mktemp "$pin_dir/.review-run-since-${pr}.tmp.XXXXXX")
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT HUP INT TERM
printf '%s\n' "$(basename "$latest_json")" > "$tmp"
mv -- "$tmp" "$pin_file"
trap - EXIT HUP INT TERM
