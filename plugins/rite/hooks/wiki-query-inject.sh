#!/bin/bash
# rite workflow - Wiki Query Injector
#
# Deterministic keyword-based search over .rite/wiki/index.md. Prints a
# Markdown context block with the top-N matching Wiki pages, formatted for
# direct inclusion in an LLM prompt. This script is the Query primitive for
# the cycle described in docs/designs/experience-heuristics-persistence-layer.md
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
#   --min-score   Minimum raw keyword match count to include a page (default: 1)
#                 Note: compared against the unweighted keyword match count.
#                 Sorting uses the confidence-weighted score (raw_score *
#                 confidence_weight) separately — see "Score rows" section.
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

# Tempfile paths declared up front, trap set up before any mktemp, cleanup on
# both normal exit and signal termination. Mirrors the repo convention used in
# commands/pr/review.md Phase 2.2.1 and commands/pr/fix.md Phase 4.5.2 so that
# SIGINT/SIGTERM/SIGHUP cannot leave orphan files in /tmp.
_yaml_err=""
_index_err=""
_git_show_err=""
_git_show_err_failed=0
_awk_err=""
_rite_wiki_query_cleanup() {
  rm -f "${_yaml_err:-}" "${_index_err:-}" "${_git_show_err:-}" "${_awk_err:-}"
}
trap 'rc=$?; _rite_wiki_query_cleanup; exit $rc' EXIT
trap '_rite_wiki_query_cleanup; exit 130' INT
trap '_rite_wiki_query_cleanup; exit 143' TERM
trap '_rite_wiki_query_cleanup; exit 129' HUP

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
  --min-score   minimum raw keyword match count to include a page (default: 1)
                (sort order uses confidence-weighted score separately)
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

# Explicit empty-value check for each option. `${2:-<default>}` silently falls
# back on empty strings, so `--max-pages ""` would be indistinguishable from
# omitting the flag. Reject empty values so the user gets a real error.
_require_option_value() {
  if [[ -z "${2:-}" ]]; then
    echo "ERROR: $1 requires a value" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keywords)   _require_option_value "$1" "${2:-}"; KEYWORDS="$2"; shift 2 ;;
    --max-pages)  _require_option_value "$1" "${2:-}"; MAX_PAGES="$2"; shift 2 ;;
    --min-score)  _require_option_value "$1" "${2:-}"; MIN_SCORE="$2"; shift 2 ;;
    --format)     _require_option_value "$1" "${2:-}"; FORMAT="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$KEYWORDS" ]]; then
  echo "ERROR: --keywords is required" >&2
  exit 1
fi

# --max-pages / --min-score are both positive-integer semantics. `case` guards
# alone would accept `0`, which would cause `head -n 0` to emit nothing and the
# script would silently exit 0 with no output — worse UX than an explicit error.
case "$MAX_PAGES" in
  ''|*[!0-9]*) echo "ERROR: --max-pages must be a positive integer" >&2; exit 1 ;;
esac
if [ "$MAX_PAGES" -lt 1 ]; then
  echo "ERROR: --max-pages must be >= 1 (got: $MAX_PAGES)" >&2
  exit 1
fi
case "$MIN_SCORE" in
  ''|*[!0-9]*) echo "ERROR: --min-score must be a non-negative integer" >&2; exit 1 ;;
esac
case "$FORMAT" in
  full|compact) ;;
  *) echo "ERROR: --format must be 'full' or 'compact'" >&2; exit 1 ;;
esac

# --- Read wiki config (lenient; opt-out: default-on when key absent) ---
# Same YAML parse pattern as wiki-ingest-trigger.sh (F-23 compliant):
# awk + section range + inline-comment strip + quote strip.
#
# Default policy (#483): Wiki is opt-out. When `wiki:` section is absent
# or `wiki.enabled` key is not specified, treat as enabled. The downstream
# index.md fetch step exits silently with empty stdout when Wiki is not
# initialized, so opt-out remains non-blocking for fresh repositories.
#
# stderr capture rationale: silent-swallowing sed/awk failures (permission
# denied, binary corruption, IO error) must surface as WARNING rather than
# being conflated with the "key absent" default-on path. We mirror the
# sibling trigger script's pattern: capture stderr to a tempfile, continue
# on grep no-match (exit 0), but surface legitimate IO errors as a WARNING
# before falling through.
wiki_section=""
if [[ -f "rite-config.yml" ]]; then
  if ! _yaml_err=$(mktemp /tmp/rite-wiki-query-yaml-err-XXXXXX); then
    echo "WARNING: mktemp failed for YAML stderr capture; falling back to /dev/null" >&2
    echo "  対処: /tmp の permission / read-only / inode 枯渇を確認してください" >&2
    _yaml_err=""
  fi
  if wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>"${_yaml_err:-/dev/null}"); then
    :  # success (sed no-match still returns 0)
  else
    _sed_rc=$?
    echo "WARNING: failed to read wiki section from rite-config.yml (sed rc=$_sed_rc)" >&2
    [ -n "$_yaml_err" ] && [ -s "$_yaml_err" ] && head -3 "$_yaml_err" | sed 's/^/  /' >&2
    echo "  lenient fallback: treating wiki as disabled and exiting silently" >&2
    exit 0
  fi
fi

# Note (#483): wiki_section may legitimately be empty when:
#   1. rite-config.yml does not exist
#   2. rite-config.yml has no `wiki:` section
# In both cases, opt-out policy treats wiki as enabled. The downstream
# index.md fetch step exits silently with empty stdout if the Wiki is not
# initialized, preserving non-blocking behavior for fresh repositories.

_extract_yaml_value() {
  local key="$1"
  local line
  line=$(printf '%s\n' "$wiki_section" | awk -v k="$key" '$0 ~ "^[[:space:]]+" k ":" { print; exit }')
  if [[ -z "$line" ]]; then
    printf ''
    return
  fi
  # Strip inline comment, extract value, remove surrounding whitespace/quotes.
  # Break tr arguments into staged invocations to avoid the fragile quad-quote
  # form `'[:space:]"'\''' `, which is easy to break during future maintenance.
  printf '%s' "$line" \
    | sed 's/[[:space:]]#.*//' \
    | sed "s/.*${key}:[[:space:]]*//" \
    | tr -d '[:space:]' \
    | tr -d '"' \
    | tr -d "'"
}

# Detect whether the wiki section actually contained an `enabled:` line so we
# can distinguish "key absent" (legitimate default-on, opt-out per #483) from
# "key present but parse failed" (should surface a WARNING rather than silently
# falling back).
#
# We need to distinguish THREE awk outcomes:
#   - exit 0: enabled line found (intentional success)
#   - exit 1: enabled line not found (intentional, via END block)
#   - exit >=2: awk runtime error (EPIPE / OOM / binary corruption) — must NOT
#     be silently conflated with "not found", otherwise a real parse failure
#     would degrade to the same silent-swallow pattern F-02 was meant to fix.
if ! _awk_err=$(mktemp /tmp/rite-wiki-query-awk-err-XXXXXX); then
  echo "WARNING: mktemp failed for awk stderr capture; falling back to /dev/null" >&2
  _awk_err=""
fi
wiki_enabled_line_present="false"
if printf '%s\n' "$wiki_section" \
    | awk '/^[[:space:]]+enabled:/ { found=1 } END { exit found ? 0 : 1 }' \
    2>"${_awk_err:-/dev/null}"; then
  wiki_enabled_line_present="true"
else
  _awk_rc=$?
  if [ "$_awk_rc" -ne 1 ]; then
    echo "WARNING: awk failed unexpectedly while detecting wiki.enabled line (rc=$_awk_rc)" >&2
    [ -n "$_awk_err" ] && [ -s "$_awk_err" ] && head -3 "$_awk_err" | sed 's/^/  /' >&2
    echo "  lenient fallback: treating wiki.enabled as absent" >&2
  fi
  # rc == 1 is the intentional "not found" path — no warning.
fi

wiki_enabled_raw=$(_extract_yaml_value "enabled")
wiki_enabled=$(printf '%s' "$wiki_enabled_raw" | tr '[:upper:]' '[:lower:]')

# If the enabled line exists but we could not extract a canonical value,
# that is a real parse failure — warn the user before falling back.
if [[ "$wiki_enabled_line_present" == "true" ]] && [[ -z "$wiki_enabled" ]]; then
  echo "WARNING: failed to parse wiki.enabled in rite-config.yml (raw value extracted as empty)" >&2
  echo "  treating wiki as disabled and exiting silently (non-blocking)" >&2
  exit 0
fi

case "$wiki_enabled" in
  false|no|0) wiki_enabled="false" ;;
  true|yes|1) wiki_enabled="true" ;;
  *)          wiki_enabled="true" ;;  # #483: opt-out default — key absent or unparseable variant
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
  # index.md is the gating resource for the whole query path. Capture stderr
  # to a tempfile so legitimate IO errors (permission denied / object corrupt
  # / submodule drift) surface as a WARNING with diagnostic detail, matching
  # the F-22 "silent-swallow to surface" policy applied elsewhere.
  if ! _index_err=$(mktemp /tmp/rite-wiki-query-index-err-XXXXXX); then
    echo "WARNING: mktemp failed for index.md stderr capture; falling back to /dev/null" >&2
    _index_err=""
  fi
  if ! index_content=$(git show "${wiki_branch}:.rite/wiki/index.md" 2>"${_index_err:-/dev/null}"); then
    _index_rc=$?
    echo "WARNING: cannot read index.md from branch '$wiki_branch' (git show rc=$_index_rc)" >&2
    [ -n "$_index_err" ] && [ -s "$_index_err" ] && head -3 "$_index_err" | sed 's/^/  /' >&2
    exit 0
  fi
else
  if [[ ! -f ".rite/wiki/index.md" ]]; then
    echo "WARNING: .rite/wiki/index.md not found — Wiki not initialized" >&2
    exit 0
  fi
  # Guard against TOCTOU races / permission denied / IO errors — do not let
  # `cat` silently collapse to an empty string, which would be indistinguishable
  # from "matched zero pages".
  if ! index_content=$(cat .rite/wiki/index.md); then
    echo "WARNING: cannot read .rite/wiki/index.md (permission denied / IO error)" >&2
    exit 0
  fi
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
    # Strip leading/trailing whitespace from each field in-place, then bind to
    # named locals exactly once. Previously the fields were bound, trimmed in
    # place, and then re-bound — the first binding was entirely dead code and
    # invited misreadings about which version of the values was in use.
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
    # Defensive default: an awk failure returns empty under `set -u` without
    # `-e`, and the following arithmetic would break. Normalize empty to 0.
    count=${count:-0}
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

# Sort by score descending, take top N.
# Split `sort` and `head` into independent invocations so that a sort
# failure (e.g. TAB boundary mismatch, OOM) surfaces as a WARNING instead
# of being masked by the downstream `head` closing the pipe early and
# returning a benign exit 0 to the caller.
if ! sorted=$(printf '%s' "$scored" | sort -t$'\t' -k1,1 -nr); then
  echo "WARNING: sort of scored rows failed — skipping output (non-blocking)" >&2
  exit 0
fi
top_rows=$(printf '%s' "$sorted" | head -n "$MAX_PAGES")
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

  # Non-blocking: page body read failures below are WARNING-only and always
  # fall through with page_body="". `--format compact` does not enter this
  # branch at all — the compact output contains only the tabular row data.
  if [[ "$FORMAT" == "full" ]]; then
    page_body=""
    if [[ "$branch_strategy" == "separate_branch" ]]; then
      # Capture git show stderr — an index.md referencing a missing/corrupt
      # page file indicates an index↔page drift that the caller should know
      # about. Silent fall-through would hide the drift entirely.
      #
      # Lifecycle: the tempfile is lazily allocated on the first loop
      # iteration that enters this branch, then truncated (`: > $f`) on every
      # subsequent iteration. At most one tempfile exists per script
      # invocation and the EXIT trap cleans it up. If the first mktemp fails
      # the `_git_show_err_failed` flag suppresses re-tries so the user gets
      # exactly one WARNING instead of one per loop iteration under /tmp
      # pressure.
      if [ -z "${_git_show_err:-}" ] && [ "${_git_show_err_failed:-0}" -eq 0 ]; then
        if ! _git_show_err=$(mktemp /tmp/rite-wiki-query-gitshow-err-XXXXXX); then
          echo "WARNING: mktemp failed for git show stderr capture; falling back to /dev/null for the rest of this run" >&2
          _git_show_err=""
          _git_show_err_failed=1
        fi
      elif [ -n "${_git_show_err:-}" ]; then
        : > "$_git_show_err"  # truncate between iterations
      fi
      if page_body=$(git show "${wiki_branch}:.rite/wiki/${path}" 2>"${_git_show_err:-/dev/null}"); then
        :
      else
        _git_show_rc=$?
        echo "WARNING: cannot read ${path} from wiki branch '${wiki_branch}' — index.md may be stale (git show rc=${_git_show_rc})" >&2
        [ -n "$_git_show_err" ] && [ -s "$_git_show_err" ] && head -3 "$_git_show_err" | sed 's/^/  /' >&2
        page_body=""
      fi
    else
      if [[ -f ".rite/wiki/${path}" ]]; then
        if ! page_body=$(cat ".rite/wiki/${path}"); then
          echo "WARNING: cannot read .rite/wiki/${path} (permission denied / IO error)" >&2
          page_body=""
        fi
      else
        echo "WARNING: .rite/wiki/${path} not found — index.md may be stale" >&2
        page_body=""  # explicit reset mirrors the separate_branch branch above
      fi
    fi
    if [[ -n "$page_body" ]]; then
      # Strip YAML frontmatter (first --- block) for cleaner injection.
      # `in_fm` transitions 0 -> 1 on opening marker, 1 -> 0 on closing marker.
      body_no_fm=$(printf '%s\n' "$page_body" | awk '
        BEGIN { in_fm = 0 }
        NR == 1 && /^---$/ { in_fm = 1; next }
        in_fm && /^---$/ { in_fm = 0; next }
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
