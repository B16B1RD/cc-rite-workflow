#!/bin/bash
# shellcheck shell=bash
# rite workflow - rite-config.yml path resolver
#
# Resolves which rite-config.yml a command should read. A linked session
# worktree only carries the file when it is tracked; an untracked config lives
# in the main checkout alone. The worktree toplevel wins so that a tracked
# config reflects the branch being worked on; the main checkout root is the
# fallback. Outside a Git repository only the given directory is checked.
#
# Usage:
#   source this file and call `rite_config_path [dir]`, or execute it directly
#   (`bash rite-config-path.sh [--or-devnull] [dir]`). `dir` defaults to the
#   current directory. `--or-devnull` is described at the bottom of this file.
#
# Contract (no stderr output on success, so callers may capture with 2>&1):
#   rc=0  the absolute path on stdout
#   rc=1  no file found; stderr names every path tried, stdout is empty
#   rc=2  a file exists but is unreadable, or the main checkout root cannot be
#         resolved; stderr names the cause. Never falls through to the next
#         candidate, so an unreadable config is not replaced by defaults.
#
# Function-only when sourced: no shell options are changed. The main checkout
# root comes from state-path-resolve.sh run as a subprocess, because sourcing
# it would impose its `set -euo pipefail` on the caller.

rite_config_path() {
  local dir="${1:-$PWD}" top main cand tried="" resolver rc
  top=$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -z "$top" ]; then
    set -- "$dir/rite-config.yml"
  else
    resolver="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/state-path-resolve.sh"
    main=$(bash "$resolver" "$dir") && [ -n "$main" ] || {
      rc=$?
      printf 'main checkout root を解決できません (state-path-resolve.sh rc=%s, dir=%s)\n' "$rc" "$dir" >&2
      return 2
    }
    if [ "$main" = "$top" ]; then
      set -- "$top/rite-config.yml"
    else
      set -- "$top/rite-config.yml" "$main/rite-config.yml"
    fi
  fi
  for cand in "$@"; do
    if [ -e "$cand" ]; then
      if [ -f "$cand" ] && [ -r "$cand" ]; then
        printf '%s\n' "$cand"
        return 0
      fi
      printf 'rite-config.yml を読めません: %s\n' "$cand" >&2
      return 2
    fi
    tried="${tried:+$tried, }$cand"
  done
  printf 'rite-config.yml が見つかりません (試したパス: %s)\n' "$tried" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # --or-devnull: for readers that continue with defaults. A missing file prints
  # a WARNING naming the tried paths and `/dev/null` (rc=0), so the caller's
  # parser reads an empty config; an unreadable file stays an ERROR with rc=2.
  if [ "${1:-}" = "--or-devnull" ]; then
    shift
    _rc=0
    _out=$(rite_config_path "$@" 2>&1) || _rc=$?
    case "$_rc" in
      0) printf '%s\n' "$_out" ;;
      1) printf 'WARNING: %s。既定値で続行します\n' "$_out" >&2; printf '/dev/null\n' ;;
      *) printf 'ERROR: %s\n' "$_out" >&2; exit 2 ;;
    esac
    exit 0
  fi
  rite_config_path "$@"
fi
