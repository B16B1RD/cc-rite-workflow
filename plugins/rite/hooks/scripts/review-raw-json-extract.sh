#!/usr/bin/env bash
# review-raw-json-extract.sh
#
# Read a /rite:pr-review PR comment body on stdin and print the JSON payload of
# its Raw JSON section on stdout.
#
# Which section wins
# ------------------
# Only sections after the first `---` separator are considered, and among those
# the **last** `### 📄 Raw JSON` heading is the one read.
#
# This protects against a finding that quotes the heading literally **before**
# the real payload — the common case, since the payload is appended at the end
# of the comment. It does not protect against a quotation that appears *after*
# the payload: there the quoted heading is the last one and wins. Reversing the
# rule would only move the hole to the other side; a robust fix needs a delimiter
# the write side controls, which is beyond what this extraction can decide.
#
# Note: this awk was moved here verbatim from the skill body, so the asymmetry
# is pre-existing behaviour, not something introduced by the extraction.
#
# Why this lives in a real file instead of the skill body
# ------------------------------------------------------
# The Skill loader rewrites positional-parameter references in a skill body to
# the invocation argument string — inside fenced code blocks too. An awk program
# that buffers the current record therefore arrives corrupted, and the failure
# is silent. Real script files are never passed through the loader. See
# hooks/scripts/dollar-zero-check.sh for the static check that keeps skill
# bodies free of the pattern.
#
# Usage:
#   review-raw-json-extract.sh < comment-body.md
#   printf '%s' "$body" | review-raw-json-extract.sh
#
# Output: the JSON text on stdout; empty when the body carries no Raw JSON
#         section (a legitimate legacy-format comment, not an error).
# Exit codes: 0 = extraction completed, non-zero = awk failed (IO / OOM).
#             Argument errors exit 2.

set -uo pipefail

if [ $# -ne 0 ]; then
  echo "ERROR: usage: review-raw-json-extract.sh < comment-body.md (reads stdin, takes no arguments)" >&2
  exit 2
fi

exec awk '
  /^---$/ { past_separator=1; next }
  past_separator && /^### 📄 Raw JSON/ { last_section_start=NR; next }
  past_separator { lines[NR] = $0 }
  END {
    if (last_section_start > 0) {
      flag = 0
      for (i = last_section_start + 1; i <= NR; i++) {
        if (lines[i] ~ /^```json$/) { flag = 1; continue }
        if (flag && lines[i] ~ /^```$/) { exit }
        if (flag) print lines[i]
      }
    }
  }
'
