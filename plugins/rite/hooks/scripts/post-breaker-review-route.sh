#!/usr/bin/env bash
set -euo pipefail

result=${1:-}
mode=${2:-}
case "$mode" in batch|interactive) ;; *) exit 2 ;; esac
case "$result" in
  '[review:mergeable]') printf '%s\n' complete ;;
  \[review:fix-needed:[0-9]*\]) printf '%s\n' fix ;;
  '[review:error]'|'') printf 'stop-%s\n' "$mode" ;;
  *) printf 'stop-%s\n' "$mode" ;;
esac
