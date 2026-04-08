#!/bin/bash
# rite workflow - Measure Review Findings
# Extract structured findings statistics from /rite:pr:review PR comments.
#
# Purpose: Provide a quantitative measurement tool for review quality
#          (used by Phase D quantitative validation in Issue #355).
#
# Usage:
#   bash measure-review-findings.sh --pr <pr_number> [--owner <owner>] [--repo <repo>]
#   bash measure-review-findings.sh --file <local_md_file>
#   bash measure-review-findings.sh --help
#
# Output (stdout, JSON):
#   {
#     "source": "pr:350" | "file:./review.md",
#     "cycles": [
#       {
#         "cycle": 1,
#         "total": 14,
#         "by_severity": { "CRITICAL": 2, "HIGH": 4, "MEDIUM": 6, "LOW": 2 },
#         "by_reviewer": { "prompt-engineer": 5, "tech-writer": 4, "code-quality": 5 }
#       }
#     ],
#     "totals": {
#       "total_findings": 20,
#       "total_cycles": 3,
#       "by_severity": { "CRITICAL": 2, "HIGH": 5, "MEDIUM": 11, "LOW": 2 }
#     }
#   }
#
# Exit codes:
#   0  Success
#   1  Invalid arguments or missing required dependency (jq, python3)
#   2  GitHub API or file read error
#   3  Parse failure (no review comments found)

set -euo pipefail

show_help() {
  cat <<'HELP'
measure-review-findings.sh — Extract findings statistics from rite review comments

USAGE:
  measure-review-findings.sh --pr <number> [--owner <owner>] [--repo <repo>]
  measure-review-findings.sh --file <path>
  measure-review-findings.sh --help

OPTIONS:
  --pr <number>      PR number to fetch review comments from (uses gh api)
  --owner <owner>    Repository owner (default: detected from `gh repo view`)
  --repo <repo>      Repository name (default: detected from `gh repo view`)
  --file <path>      Read review comment(s) from a local markdown file instead
  --help             Show this help message

EXAMPLES:
  # Measure all review cycles on PR #350
  measure-review-findings.sh --pr 350

  # Measure from a saved review comment dump
  measure-review-findings.sh --file /tmp/saved-review.md

NOTES:
  - The script extracts data from "## 📜 rite レビュー結果" comment headers
  - Cycle counts come from the "レビュー経緯" table per-cycle row
  - Severity buckets come from the "レビュアー合意状況" reviewer rows
  - Output is JSON for downstream tooling (jq, dashboards, hooks)
HELP
}

# --- Argument parsing ---
PR_NUMBER=""
OWNER=""
REPO=""
LOCAL_FILE=""

require_arg() {
  if [ $# -lt 2 ]; then
    echo "ERROR: $1 requires an argument" >&2
    show_help >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)    require_arg "$@"; PR_NUMBER="$2"; shift 2 ;;
    --owner) require_arg "$@"; OWNER="$2";     shift 2 ;;
    --repo)  require_arg "$@"; REPO="$2";      shift 2 ;;
    --file)  require_arg "$@"; LOCAL_FILE="$2"; shift 2 ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; show_help >&2; exit 1 ;;
  esac
done

if [ -z "$PR_NUMBER" ] && [ -z "$LOCAL_FILE" ]; then
  echo "ERROR: --pr or --file is required" >&2
  show_help >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found in PATH" >&2
  exit 1
fi

# --- Source acquisition ---
# Path-first-declare → trap-first-set → mktemp-last order to eliminate the
# race window between mktemp success and trap registration where SIGTERM/SIGINT
# could leave an orphan tempfile (matches review.md / fix.md project pattern).
# All mktemp results below MUST be assigned to a variable that is already
# tracked by this trap.
tmpfile=""
gh_err_file=""
separator_tmp=""
trap 'rm -f "${tmpfile:-}" "${gh_err_file:-}" "${separator_tmp:-}"' EXIT
gh_err_file=$(mktemp)
tmpfile=$(mktemp)

if [ -n "$LOCAL_FILE" ]; then
  if [ ! -f "$LOCAL_FILE" ]; then
    echo "ERROR: file not found: $LOCAL_FILE" >&2
    exit 2
  fi
  cp "$LOCAL_FILE" "$tmpfile"
  source_label="file:$LOCAL_FILE"
else
  if [ -z "$OWNER" ] && [ -z "$REPO" ]; then
    repo_info=$(gh repo view --json owner,name 2>"$gh_err_file") || {
      echo "ERROR: gh repo view failed: $(cat "$gh_err_file")" >&2
      echo "  hint: specify --owner and --repo explicitly to bypass auto-detect" >&2
      exit 2
    }
    # Use `// empty` so jq returns "" instead of the literal string "null"
    # when a field is missing — `${OWNER:-...}` would otherwise treat "null"
    # as a non-empty value and propagate it into the gh api URL.
    OWNER="${OWNER:-$(echo "$repo_info" | jq -r '.owner.login // empty')}"
    REPO="${REPO:-$(echo "$repo_info" | jq -r '.name // empty')}"
    if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
      echo "ERROR: could not resolve repository owner/name from gh repo view output" >&2
      exit 2
    fi
  elif [ -z "$OWNER" ] || [ -z "$REPO" ]; then
    echo "ERROR: --owner and --repo must be specified together (or both omitted to auto-detect)" >&2
    exit 1
  fi
  # `--paginate` is required because GitHub API defaults to 30 comments per
  # page; PRs with many review cycles (e.g. PR #350 with 16+ cycles) would
  # silently truncate without it. Capture stderr to a file so error messages
  # surface the actual gh diagnostic instead of a generic "failed to fetch".
  gh api --paginate "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" \
    --jq '.[] | select(.body | contains("📜 rite レビュー結果")) | .body' \
    > "$tmpfile" 2>"$gh_err_file" || {
      echo "ERROR: gh api failed for PR #${PR_NUMBER}: $(cat "$gh_err_file")" >&2
      exit 2
    }
  # `--paginate` returns a stream of bodies (one per matched comment, separated
  # by newlines). Insert the parser separator between bodies so the Python
  # parser can split them later. We rebuild the file in-place via a second
  # tempfile to avoid feeding awk both stdin and stdout of the same path.
  # `separator_tmp` is declared at top-level and tracked by the EXIT trap.
  separator_tmp=$(mktemp)
  awk 'NR > 1 && /^## 📜 rite レビュー結果/ { printf "\n---REVIEW-COMMENT-SEPARATOR---\n" } { print }' \
    "$tmpfile" > "$separator_tmp"
  mv "$separator_tmp" "$tmpfile"
  separator_tmp=""
  source_label="pr:${PR_NUMBER}"
fi

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: no rite review comments found in source" >&2
  exit 3
fi

# --- Parse comments ---
# Extract findings statistics from the markdown comment(s).
# Strategy:
#   1. Find each "## 📜 rite レビュー結果" header and extract cycle number
#   2. Within each comment, parse the "レビュアー合意状況" table for per-reviewer counts
#   3. Sum across reviewers to compute severity totals per cycle
#   4. Aggregate across cycles for totals

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not found in PATH" >&2
  exit 1
fi

python3 - "$tmpfile" "$source_label" <<'PYTHON'
import json
import re
import sys

path, source_label = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    text = fh.read()

# Split into individual review comments
comments = text.split("---REVIEW-COMMENT-SEPARATOR---")
if len(comments) == 1 and "📜 rite レビュー結果" not in comments[0]:
    print(json.dumps({
        "error": "no rite review comments parsed",
        "source": source_label
    }), file=sys.stdout)
    sys.exit(3)

cycles = []
header_re = re.compile(r"## 📜 rite レビュー結果(?:\s*\(Cycle\s*(\d+)\))?")
reviewer_row_re = re.compile(
    r"^\|\s*([a-zA-Z][\w\-]*)\s*\|\s*([^|]+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*$"
)

cycle_seq = 0
for comment in comments:
    comment = comment.strip()
    if not comment or "📜 rite レビュー結果" not in comment:
        continue

    cycle_seq += 1
    cycle_match = header_re.search(comment)
    if cycle_match and cycle_match.group(1):
        cycle_num = int(cycle_match.group(1))
    else:
        # Header omits "(Cycle N)" — fall back to position in the comment list
        cycle_num = cycle_seq

    # Locate "### レビュアー合意状況" section
    consensus_idx = comment.find("レビュアー合意状況")
    if consensus_idx < 0:
        continue
    consensus_section = comment[consensus_idx:]
    # Stop at the next ### heading
    end_idx = consensus_section.find("\n### ", 1)
    if end_idx > 0:
        consensus_section = consensus_section[:end_idx]

    by_reviewer = {}
    by_severity = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0}
    for line in consensus_section.splitlines():
        m = reviewer_row_re.match(line.strip())
        if not m:
            continue
        reviewer = m.group(1)
        # Skip the English "Reviewer" header row. The Japanese "レビュアー"
        # header is filtered out structurally because reviewer_row_re's first
        # group only matches ASCII identifiers ([a-zA-Z][\w\-]*), so non-ASCII
        # headers never reach this point.
        if reviewer.lower() == "reviewer":
            continue
        crit, high, med, low = (int(m.group(i)) for i in (3, 4, 5, 6))
        reviewer_total = crit + high + med + low
        by_reviewer[reviewer] = reviewer_total
        by_severity["CRITICAL"] += crit
        by_severity["HIGH"] += high
        by_severity["MEDIUM"] += med
        by_severity["LOW"] += low

    total = sum(by_severity.values())
    cycles.append({
        "cycle": cycle_num,
        "total": total,
        "by_severity": by_severity,
        "by_reviewer": by_reviewer,
    })

totals_by_severity = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0}
for c in cycles:
    for sev, n in c["by_severity"].items():
        totals_by_severity[sev] += n

result = {
    "source": source_label,
    "cycles": cycles,
    "totals": {
        "total_findings": sum(totals_by_severity.values()),
        "total_cycles": len(cycles),
        "by_severity": totals_by_severity,
    },
}
print(json.dumps(result, ensure_ascii=False, indent=2))
PYTHON
