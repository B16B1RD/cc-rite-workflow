#!/bin/bash
# rite workflow - Wiki Query Injector
#
# Deterministic keyword-based search over .rite/wiki/index.md. Prints a
# Markdown context block with the top-N matching Wiki pages, formatted for
# direct inclusion in an LLM prompt. This script is the Query primitive for
# the sycle described in docs/designs/experience-heuristics-persistence-layer.md
# (F3) — it is called from command markdown files (query.md, start.md,
# review.md, fix.md, implement.md) via Bash to fetch relevant experiential
# knowledge.
#
# The script does NOT perform any LLM work — keyword matching and scoring
# are purely mechanical. The LLM decides how to use the injected context
# downstream.
#
# Usage:
#   bash wiki-query-inject.sh --keywords "kw1,kw2,kw3" [--max-pages N]
#                             [--min-score N] [--format full|compact]
#
# Options:
#   --keywords    Comma-separated keywords to search (required)
#   --max-pages   Maximum pages to return (default: 5)
#   --min-score   Minimum match score to include a page (default: 1)
#   --format      full (include full page body) or compact (summary only, default)
#
# Output:
#   stdout: Markdown context block with matching pages, or empty if no matches
#   stderr: warnings (Wiki disabled, not initialized, parse failures)
#
# Exit codes:
#   0  success (including "no matches" and "Wiki disabled" — always non-blocking)
#   1  argument validation error
#
# Design notes:
#   - Always non-blocking: missing Wiki, disabled Wiki, uninitialized Wiki, or
#     zero matches all exit 0 with no stdout. The caller must treat empty
#     stdout as "no context to inject" and continue.
#   - Reads index.md via `git show` for separate_branch strategy, via direct
#     file read for same_branch strategy.
#   - Scoring is case-insensitive substring match across page title + domain
#     + summary, weighted by confidence (high=1.5, medium=1.0, low=0.5).
set -uo pipefail

KEYWORDS=""
MAX_PAGES=5
MIN_SCORE=1
FORMAT="compact"

usage() {
  cat <<'USAGE'
Usage: wiki-query-inject.sh --keywords "kw1,kw2,..." [--max-pages N] [--min-score N] [--format full|compact]

Searches .rite/wiki/index.md for pages matching the given keywords and prints
a Markdown context block to stdout. Silent (exit 0, no stdout) when Wiki is
disabled, uninitialized, or has no matches.

Required:
  --keywords    comma-separated keywords

Optional:
  --max-pages   maximum pages to return (default: 5)
  --min-score   minimum score to include (default: 1)
  --format      full | compact (default: compact)

Exit codes:
  0  success (always non-blocking)
  1  argument validation error
USAGE
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keywords)   KEYWORDS="${2:-}"; shift 2 ;;
    --max-pages)  MAX_PAGES="${2:-5}"; shift 2 ;;
    --min-score)  MIN_SCORE="${2:-1}"; shift 2 ;;
    --format)     FORMAT="${2:-compact}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$KEYWORDS" ]]; then
  echo "ERROR: --keywords is required" >&2
  exit 1
fi

case "$MAX_PAGES" in
  ''|*[!0-9]*) echo "ERROR: --max-pages must be a non-negative integer" >&2; exit 1 ;;
esac
case "$MIN_SCORE" in
  ''|*[!0-9]*) echo "ERROR: --min-score must be a non-negative integer" >&2; exit 1 ;;
esac
case "$FORMAT" in
  full|compact) ;;
  *) echo "ERROR: --format must be 'full' or 'compact'" >&2; exit 1 ;;
esac

# --- Read wiki config (lenient; silent exit on disabled / missing) ---
# Same YAML parse pattern as wiki-ingest-trigger.sh (F-23 compliant):
# awk + section range + inline-comment strip + quote strip.
if [[ ! -f "rite-config.yml" ]]; then
  exit 0
fi

wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
if [[ -z "$wiki_section" ]]; then
  exit 0
fi

_extract_yaml_value() {
  local key="$1"
  local line
  line=$(printf '%s\n' "$wiki_section" | awk -v k="$key" '$0 ~ "^[[:space:]]+" k ":" { print; exit }') || line=""
  if [[ -z "$line" ]]; then
    printf ''
    return
  fi
  printf '%s' "$line" \
    | sed 's/[[:space:]]#.*//' \
    | sed "s/.*${key}:[[:space:]]*//" \
    | tr -d '[:space:]"'\'''
}

wiki_enabled=$(_extract_yaml_value "enabled" | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled" in
  true|yes|1) wiki_enabled="true" ;;
  *)          wiki_enabled="false" ;;
esac

if [[ "$wiki_enabled" != "true" ]]; then
  exit 0
fi

branch_strategy=$(_extract_yaml_value "branch_strategy")
branch_strategy="${branch_strategy:-separate_branch}"
wiki_branch=$(_extract_yaml_value "branch_name")
wiki_branch="${wiki_branch:-wiki}"

# --- Fetch index.md content ---
index_content=""
if [[ "$branch_strategy" == "separate_branch" ]]; then
  if ! git rev-parse --verify "$wiki_branch" >/dev/null 2>&1 \
     && ! git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1; then
    echo "WARNING: wiki branch '$wiki_branch' not found — Wiki not initialized" >&2
    exit 0
  fi
  index_content=$(git show "${wiki_branch}:.rite/wiki/index.md" 2>/dev/null) || {
    echo "WARNING: cannot read index.md from branch '$wiki_branch'" >&2
    exit 0
  }
else
  if [[ ! -f ".rite/wiki/index.md" ]]; then
    echo "WARNING: .rite/wiki/index.md not found — Wiki not initialized" >&2
    exit 0
  fi
  index_content=$(cat .rite/wiki/index.md)
fi

if [[ -z "$index_content" ]]; then
  exit 0
fi

# --- Parse index.md table rows ---
# Row format: | [{title}]({path}) | {domain} | {summary} | {updated} | {confidence} |
#
# awk extracts:
#   title | path | domain | summary | updated | confidence
# separated by TAB.
rows=$(printf '%s\n' "$index_content" | awk -F'|' '
  BEGIN { in_table=0 }
  /^\| ページ \| ドメイン/ { in_table=1; next }
  /^\|[-| ]+\|$/ { next }
  in_table == 1 && /^\|/ && NF >= 6 {
    page_cell = $2
    domain    = $3
    summary   = $4
    updated   = $5
    confidence = $6

    # Strip leading/trailing whitespace from each field
    for (i = 2; i <= 6; i++) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
    }
    page_cell = $2; domain = $3; summary = $4; updated = $5; confidence = $6

    # Extract title and path from Markdown link [title](path)
    title = page_cell
    path  = ""
    if (match(page_cell, /\[[^]]*\]\([^)]*\)/)) {
      m = substr(page_cell, RSTART, RLENGTH)
      # title
      if (match(m, /\[[^]]*\]/)) {
        title = substr(m, RSTART + 1, RLENGTH - 2)
      }
      # path
      if (match(m, /\([^)]*\)/)) {
        path = substr(m, RSTART + 1, RLENGTH - 2)
      }
    }

    if (path == "") next  # skip malformed rows
    printf "%s\t%s\t%s\t%s\t%s\t%s\n", title, path, domain, summary, updated, confidence
  }
  /^## / && in_table == 1 { in_table=0 }
')

if [[ -z "$rows" ]]; then
  exit 0
fi

# --- Score rows ---
# For each row, count case-insensitive substring matches across
# title + domain + summary for each keyword. Weight by confidence.
IFS=',' read -r -a kw_array <<< "$KEYWORDS"

# Build scored list: "score<TAB>title<TAB>path<TAB>domain<TAB>summary<TAB>updated<TAB>confidence"
scored=""
while IFS=$'\t' read -r title path domain summary updated confidence; do
  [[ -z "$path" ]] && continue
  haystack=$(printf '%s %s %s' "$title" "$domain" "$summary" | tr '[:upper:]' '[:lower:]')
  raw_score=0
  for kw in "${kw_array[@]}"; do
    kw_trim=$(printf '%s' "$kw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
    [[ -z "$kw_trim" ]] && continue
    # Count occurrences (portable: awk)
    count=$(printf '%s' "$haystack" | awk -v k="$kw_trim" '
      BEGIN { n = 0 }
      {
        s = $0
        while ((i = index(s, k)) > 0) { n++; s = substr(s, i + length(k)) }
      }
      END { print n }
    ')
    raw_score=$((raw_score + count))
  done

  # Confidence weight (integer math ×10 to avoid floats)
  case "$confidence" in
    high)   weight=15 ;;
    medium) weight=10 ;;
    low)    weight=5  ;;
    *)      weight=10 ;;
  esac
  weighted_score=$((raw_score * weight))

  if (( raw_score >= MIN_SCORE )); then
    scored+="${weighted_score}	${title}	${path}	${domain}	${summary}	${updated}	${confidence}
"
  fi
done <<< "$rows"

if [[ -z "$scored" ]]; then
  exit 0
fi

# Sort by score descending, take top N
top_rows=$(printf '%s' "$scored" | sort -t$'\t' -k1,1 -nr | head -n "$MAX_PAGES")
if [[ -z "$top_rows" ]]; then
  exit 0
fi

# --- Render output ---
printf '\n'
printf '### 📚 Wiki 経験則（自動参照）\n\n'
printf 'キーワード: `%s`\n\n' "$KEYWORDS"

while IFS=$'\t' read -r score title path domain summary updated confidence; do
  [[ -z "$path" ]] && continue
  printf '#### %s\n' "$title"
  printf '%s\n' "- **ドメイン**: ${domain} / **確信度**: ${confidence} / **更新日**: ${updated}"
  printf '%s\n' "- **サマリー**: ${summary}"

  if [[ "$FORMAT" == "full" ]]; then
    page_body=""
    if [[ "$branch_strategy" == "separate_branch" ]]; then
      page_body=$(git show "${wiki_branch}:.rite/wiki/${path}" 2>/dev/null) || page_body=""
    else
      [[ -f ".rite/wiki/${path}" ]] && page_body=$(cat ".rite/wiki/${path}")
    fi
    if [[ -n "$page_body" ]]; then
      # Strip YAML frontmatter (first --- block) for cleaner injection
      body_no_fm=$(printf '%s\n' "$page_body" | awk '
        BEGIN { in_fm = 0; done_fm = 0 }
        NR == 1 && /^---$/ { in_fm = 1; next }
        in_fm && /^---$/ { in_fm = 0; done_fm = 1; next }
        in_fm { next }
        { print }
      ')
      printf '\n%s\n\n' "$body_no_fm"
    fi
  fi
  printf '\n'
done <<< "$top_rows"

printf '> これらの経験則は `.rite/wiki/` から自動抽出されました。判断の参考にしてください。\n\n'

exit 0
