# shellcheck shell=bash
# rite workflow - git status filtered for sandbox write-block ghost mounts
#
# Responsibility: wrap `git status --porcelain -z` and drop untracked (`??`)
# entries whose path is actually a Bash tool sandbox write-block bind mount
# (a persistent character-device /dev/null mount placed over a real path
# such as .bashrc or .claude/agents to block writes there), not a genuine
# untracked file. These mounts are invisible to the harness's own git-status
# snapshot but visible from inside the Bash tool, so they show up as
# spurious `??` entries in every `git status --porcelain` call made from a
# sandboxed Bash command even though nothing in the working tree actually
# changed (#1936). Detection is mechanism-based (`test -c`), never a
# filename allowlist, so it survives whatever set of paths a given sandbox
# config happens to block.
#
# Scope: only `??` (untracked) entries are ever dropped, and only when the
# path is a character device. Every other status code (staged / unstaged /
# unmerged / renamed / copied) passes through unchanged — this is a
# display-layer filter, not a substitute for real conflict or dirty-state
# detection.
#
# -z is used on the read side (not the traditional non-`-z` porcelain v1)
# so paths with special characters parse unambiguously via NUL delimiters
# instead of relying on quote-escaping; the output is re-rendered as plain
# porcelain v1 text (newline-separated) so existing callers that already
# expect `git status --porcelain` output need no changes beyond swapping
# the command.
#
# Usage (standalone subprocess only — this file is not meant to be
# sourced). Do not redirect stderr to /dev/null on the call site — that
# discards this script's own diagnostic WARNING (see Output contract
# below) and, combined with a caller that also skips the exit-code check,
# recreates the exact silent-failure bug this script exists to prevent:
#   dirty=$(bash lib/git-status-filtered.sh) || dirty="<non-empty fallback, e.g. treat as dirty>"
#
# Output contract: on success, stdout is porcelain v1 text ("XY path" /
# "XY orig -> new" lines, newline-separated, empty when clean) and exit is
# 0. On failure (not a git repository, or git itself errors), stderr gets
# one WARNING line and exit is non-zero — callers must not treat empty
# stdout as "no changes" without checking the exit code, since that would
# silently mask a genuine detection failure as a clean tree.

set -uo pipefail

tmp_out=$(mktemp) && tmp_err=$(mktemp) || {
  echo "WARNING: git-status-filtered: mktemp failed" >&2
  exit 1
}
trap 'rm -f "$tmp_out" "$tmp_err"' EXIT

if ! git status --porcelain -z >"$tmp_out" 2>"$tmp_err"; then
  echo "WARNING: git-status-filtered: 'git status --porcelain -z' failed (not a git repository, or git itself errored): $(cat "$tmp_err" 2>/dev/null)" >&2
  exit 1
fi

result=""
while IFS= read -r -d '' entry; do
  [ -z "$entry" ] && continue
  code="${entry:0:2}"
  path="${entry:3}"
  case "${code:0:1}" in
    R | C)
      # Rename/copy: -z emits the new path (with status) first, then the
      # bare original path as the next NUL-terminated field.
      IFS= read -r -d '' orig_path || orig_path=""
      result+="$code $orig_path -> $path"$'\n'
      ;;
    *)
      if [ "$code" = "??" ] && [ -c "$path" ]; then
        continue # sandbox write-block ghost mount — drop
      fi
      result+="$code $path"$'\n'
      ;;
  esac
done <"$tmp_out"

printf '%s' "$result"
