#!/usr/bin/env bash
# pr-review-post-comment-read.sh
#
# Read `pr_review.post_comment` from a rite-config.yml and print the normalized
# scalar (lowercased, comment- and quote-stripped) on stdout.
#
# Why this lives in a real file instead of the skill body
# ------------------------------------------------------
# The Skill loader rewrites positional-parameter references in a skill body to
# the invocation argument string — inside fenced code blocks too. An awk program
# that reads the current record therefore arrives corrupted, and the failure is
# silent: the reader returns empty and the caller's default absorbs it. Real
# script files are never passed through the loader, so the program is safe here.
# See hooks/scripts/dollar-zero-check.sh for the static check that keeps skill
# bodies free of the pattern.
#
# Single-awk by contract: a multi-stage pipeline can lose the value to SIGPIPE
# (rc=141), which silently degrades post_comment to false. Do not reintroduce
# `grep | sed | tr` staging here.
#
# Usage:
#   pr-review-post-comment-read.sh <config-file>
#
# Output: the raw scalar on stdout (may be empty when the key is absent — an
#         empty result is a legitimate "not configured", not an error).
# Exit codes: 0 = read completed, non-zero = awk failed (IO / binary error).
#             Argument errors exit 2.

set -uo pipefail

if [ $# -ne 1 ]; then
  echo "ERROR: usage: pr-review-post-comment-read.sh <config-file>" >&2
  exit 2
fi

config_file="$1"

if [ ! -f "$config_file" ]; then
  echo "ERROR: config file not found: $config_file" >&2
  exit 2
fi

# `[[:space:]]#` as the comment boundary follows YAML: `#` only starts an inline
# comment when preceded by whitespace.
exec awk '
  /^pr_review:/ { in_section=1; next }
  in_section && /^[a-zA-Z]/ { exit }
  in_section && /^[[:space:]]+post_comment[[:space:]]*:/ {
    line = $0
    sub(/[[:space:]]#.*/, "", line)
    sub(/.*post_comment[[:space:]]*:[[:space:]]*/, "", line)
    gsub(/[[:space:]]/, "", line)
    gsub(/"/, "", line)
    print tolower(line)
    exit
  }
' "$config_file"
