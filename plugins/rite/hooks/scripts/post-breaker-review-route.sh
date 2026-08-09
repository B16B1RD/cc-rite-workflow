#!/usr/bin/env bash
set -euo pipefail

result=${1:-}
mode=${2:-}
case "$mode" in batch|interactive) ;; *) exit 2 ;; esac
case "$result" in
  '[review:mergeable]') printf '%s\n' complete ;;
  '[review:error]'|'') printf 'stop-%s\n' "$mode" ;;
  *)
    if [[ "$result" =~ ^\[review:fix-needed:[0-9]+\]$ ]]; then
      printf '%s\n' fix
    else
      printf 'stop-%s\n' "$mode"
    fi
    ;;
esac
