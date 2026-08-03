#!/bin/bash
# rite workflow - Wiki Query Injector
#
# Deterministic keyword-based search over .rite/wiki/index.md. Prints a
# Markdown context block with the top-N matching Wiki pages, formatted for
# direct inclusion in an LLM prompt. This script is the Query primitive for
# the cycle described in docs/designs/experience-heuristics-persistence-layer.md
# (F3) — it is called from command markdown files (query.md, pr-review.md, fix.md,
# implement.md) via Bash to fetch relevant experiential knowledge.
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
#                 confidence_weight) separately — see "Pass 2 + Score" section.
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
#   - OKF v0.1 2-pass: Pass 1 parses both catalog forms — the 5-column table
#     (page / domain / summary / updated / confidence) that wiki-ingest writes
#     today, and the OKF bullet form (`* [title](path) - description`) still
#     live in repos initialized under the earlier template. The table columns
#     are a copy — Pass 2 reads each candidate page's frontmatter for
#     domain/confidence/updated (Source of Truth). A candidate whose page
#     frontmatter is unreadable is skipped with a WARNING (non-blocking — the
#     index→page drift surfaces but other candidates render). Zero candidates
#     against an index that does carry `](pages/...)` links warns too, so a
#     future format drift is not mistaken for an empty wiki.
#   - Scoring is case-insensitive substring match across page title + domain
#     + description, weighted by confidence (high=1.5, medium=1.0, low=0.5).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"

# Resolve project root (git root anchored). Matches session-start.sh /
# state-path-resolve.sh convention. `$PWD`-based
# rite-config.yml lookup would silently miss the config file when this script
# is invoked from a subdirectory. This script is a CLI tool (not a Claude Code
# hook), so $PWD is used in place of the stdin-supplied CWD that hook scripts
# receive.
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$PWD" 2>/dev/null) || STATE_ROOT="$PWD"

# Tempfile paths declared up front, trap set up before any mktemp, cleanup on
# both normal exit and signal termination. Mirrors the repo convention used in
# skills/pr-review/SKILL.md ステップ 2.2.1 and skills/fix/SKILL.md ステップ 4.5.2 so that
# SIGINT/SIGTERM/SIGHUP cannot leave orphan files in /tmp.
_yaml_err=""
_index_err=""
_git_show_err=""
_git_show_err_failed=0
_awk_err=""
_drop_meta=""
_rite_wiki_query_cleanup() {
  rm -f "${_yaml_err:-}" "${_index_err:-}" "${_git_show_err:-}" "${_awk_err:-}" "${_drop_meta:-}"
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
# Default policy: Wiki is opt-out. When `wiki:` section is absent
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
if [[ -f "$STATE_ROOT/rite-config.yml" ]]; then
  if ! _yaml_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-query-yaml-err-XXXXXX"); then
    echo "WARNING: mktemp failed for YAML stderr capture; falling back to /dev/null" >&2
    echo "  対処: /tmp の permission / read-only / inode 枯渇を確認してください" >&2
    _yaml_err=""
  fi
  if wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' "$STATE_ROOT/rite-config.yml" 2>"${_yaml_err:-/dev/null}"); then
    :  # success (sed no-match still returns 0)
  else
    _sed_rc=$?
    echo "WARNING: failed to read wiki section from rite-config.yml (sed rc=$_sed_rc)" >&2
    [ -n "$_yaml_err" ] && [ -s "$_yaml_err" ] && head -3 "$_yaml_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    echo "  lenient fallback: treating wiki as disabled and exiting silently" >&2
    exit 0
  fi
fi

# Note: wiki_section may legitimately be empty when:
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
# can distinguish "key absent" (legitimate default-on, opt-out default) from
# "key present but parse failed" (should surface a WARNING rather than silently
# falling back).
#
# We need to distinguish THREE awk outcomes:
#   - exit 0: enabled line found (intentional success)
#   - exit 1: enabled line not found (intentional, via END block)
#   - exit >=2: awk runtime error (EPIPE / OOM / binary corruption) — must NOT
#     be silently conflated with "not found", otherwise a real parse failure
#     would degrade to the same silent-swallow pattern F-02 was meant to fix.
if ! _awk_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-query-awk-err-XXXXXX"); then
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
    [ -n "$_awk_err" ] && [ -s "$_awk_err" ] && head -3 "$_awk_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
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
  *)          wiki_enabled="true" ;;  # opt-out default — key absent or unparseable variant
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
# Select a readable ref (local wiki branch > origin/wiki).
# On fresh clones / separate worktrees, the local wiki branch may not exist
# even when origin/wiki is available. Reading content via the bare branch
# name (`git show wiki:...`) fails in that case with "fatal: invalid object
# name 'wiki'". Mirror the ref-selection pattern used by cleanup.md
# ステップ 9 (Wiki Ingest 条件付き、旧 Phase 4.W.1 Step 2) and wiki-growth-check.sh
# to fall back to origin.
ref=""
if [[ "$branch_strategy" == "separate_branch" ]]; then
  if git rev-parse --verify "$wiki_branch" >/dev/null 2>&1; then
    ref="$wiki_branch"
  elif git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1; then
    ref="origin/$wiki_branch"
  else
    echo "WARNING: wiki branch '$wiki_branch' not found — Wiki not initialized" >&2
    exit 0
  fi
  # index.md is the gating resource for the whole query path. Capture stderr
  # to a tempfile so legitimate IO errors (permission denied / object corrupt
  # / submodule drift) surface as a WARNING with diagnostic detail, matching
  # the F-22 "silent-swallow to surface" policy applied elsewhere.
  if ! _index_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-query-index-err-XXXXXX"); then
    echo "WARNING: mktemp failed for index.md stderr capture; falling back to /dev/null" >&2
    _index_err=""
  fi
  # `if ! var=$(git show ...)` collapses the exit status to 0 inside the
  # then-branch (POSIX `!`), masking the real git rc (128 = ref absent,
  # 129 = object corrupt). if/else preserves the diagnostic rc.
  if index_content=$(git show "${ref}:.rite/wiki/index.md" 2>"${_index_err:-/dev/null}"); then
    :
  else
    _index_rc=$?
    echo "WARNING: cannot read index.md from ref '$ref' (git show rc=$_index_rc)" >&2
    [ -n "$_index_err" ] && [ -s "$_index_err" ] && head -3 "$_index_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
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

# --- Pass 1: Parse the index catalog for candidates ---
# Pass 1 understands both catalog forms the wiki has been written in:
#   table  : | [{title}]({path}) | {domain} | {summary} | {updated} | {confidence} |
#   bullet : * [{title}]({path}) - {description}
# The table is what wiki-ingest writes today (see skills/wiki-ingest/SKILL.md
# ステップ 6 for the column contract); the bullet form is still live in repos
# initialized while the template emitted the OKF bullet catalog. Reading only
# one of them silently drops half the corpus, so both are parsed. The table
# columns are a copy — per-page metadata (domain / confidence / updated) lives
# in each page's frontmatter (Source of Truth). Pass 1 extracts the candidates;
# Pass 2 (in the scoring loop below) reads each candidate page's frontmatter for
# the metadata.
#
# awk extracts: title | path | description, separated by unit separator (\x1f).
# Only links whose target contains `pages/` are kept (the orphan-link grep
# contract — see wiki-lint-orphans.sh — relies on the same
# `pages/{domain}/{slug}.md` target), which is also what makes the table header
# row (`| ページ | ドメイン | ... |`) fall out without a dedicated rule.
#
# Table cells escape a literal `|` as `\|` (the cell separator would otherwise
# split the row), so the row is split with the escapes swapped out for \x01 and
# swapped back per field — splitting first would cut a title/summary in half and
# shift every later column. Only the FIRST link in the page cell is taken: real
# summaries carry cross-links to other pages, and taking the last match would
# make a row point at whichever page it happens to cite.
#
# HTML comment blocks (`<!-- ... -->`) are skipped so that illustrative examples
# inside an index prologue are NOT parsed as real candidates (otherwise such an
# index would yield a phantom candidate whose page does not exist, emitting a
# misleading "index.md may be stale" WARNING on every query).
_drop_meta=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-query-drop-XXXXXX" 2>/dev/null) || _drop_meta=""
candidates=$(printf '%s\n' "$index_content" | awk -v dropmeta="$_drop_meta" '
  # Pipes inside inline code spans are NOT escaped by the writer, so they would
  # split the row at the wrong place. Swap them for the same \x01 placeholder the
  # backslash escapes use, preserving length and content so cell offsets hold.
  function protect_code_span_pipes(s,   out, rest, seg) {
    out = ""; rest = s
    while (match(rest, /`[^`]*`/)) {
      seg = substr(rest, RSTART, RLENGTH)
      gsub(/\|/, "\001", seg)
      out = out substr(rest, 1, RSTART - 1) seg
      rest = substr(rest, RSTART + RLENGTH)
    }
    return out rest
  }
  # Both halves anchor on the `](` that actually separates text from target. The
  # obvious forms break on real titles:
  # a bare /\([^)]*\)/ takes the LEFTMOST parenthesis group, so a title carrying
  # its own parentheses ("... (assert_not_grep) は…") yields a title fragment as
  # the path (54 of 362 live rows), and /\[[^]]*\]/ stops at the first `]`, so a
  # title containing brackets ("[CONTEXT] sentinel", "`[[:cntrl:]]`") loses its
  # tail and the target with it (4 more rows).
  function link_target(link,   t) {
    t = ""
    if (match(link, /\]\([^)]*\)$/)) t = substr(link, RSTART + 2, RLENGTH - 3)
    return t
  }
  function link_text(link,   t) {
    t = ""
    if (match(link, /^\[.*\]\(/)) t = substr(link, 2, RLENGTH - 3)
    return t
  }
  function emit(title, path, desc) {
    if (path == "" || index(path, "pages/") == 0) {
      # A row that carries a registration link but produced no candidate is a
      # parse failure, not a header row — count it so the partial loss is
      # reported instead of silently shrinking the corpus.
      if (index($0, "](pages/") > 0) {
        dropped++
        if (dropped <= 3) dropped_sample[dropped] = substr($0, 1, 110)
      }
      return
    }
    gsub(/\001/, "|", title); gsub(/\001/, "|", desc)      # restore protected pipes
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", title)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", desc)
    printf "%s\037%s\037%s\n", title, path, desc
  }
  # Anchored at line start: an unanchored /<!--/ also fires on rows that merely
  # quote the comment syntax inside a cell, swallowing real entries.
  /^[[:space:]]*<!--/ { in_comment=1 }
  in_comment { if (index($0, "-->") > 0) in_comment=0; next }
  /^[[:space:]]*\|/ {
    line = $0
    if (line ~ /^[[:space:]]*\|[[:space:]]*:?-+:?[[:space:]]*\|/) next   # separator row
    gsub(/\\\|/, "\001", line)
    line = protect_code_span_pipes(line)
    sub(/^[[:space:]]*\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
    n = split(line, cells, "|")
    # The catalog contract is exactly 5 columns, so any other count means the
    # row did not split where the writer intended. Route through emit() rather
    # than `next` so the drop counter sees it: skipping here would make a
    # miscounted row the one shape that vanishes with neither stdout nor a
    # warning. `n > 5` matters as much as `n < 3` — an unescaped pipe in the
    # summary silently truncates that cell, so the page still renders but with
    # more than half its text gone. Re-joining the cells would paper over a
    # writer-side escape violation instead of surfacing it.
    if (n != 5) { emit("", "", ""); next }
    title = ""; path = ""
    if (match(cells[1], /\[([^]]|\][^(])*\]\([^)]*\)/)) {
      link = substr(cells[1], RSTART, RLENGTH)
      title = link_text(link)
      path = link_target(link)
    }
    emit(title, path, cells[3])
    next
  }
  /^[[:space:]]*[*-][[:space:]]+\[/ {
    line = $0
    title = ""; path = ""; desc = ""
    if (match(line, /\[([^]]|\][^(])*\]\([^)]*\)/)) {
      link = substr(line, RSTART, RLENGTH)
      rest = substr(line, RSTART + RLENGTH)   # text after the markdown link
      title = link_text(link)
      path = link_target(link)
      # description = text after the " - " separator following the link
      if (match(rest, /^[[:space:]]*-[[:space:]]+/)) {
        desc = substr(rest, RSTART + RLENGTH)
      }
    }
    emit(title, path, desc)
  }
  END {
    # Written to a file, not straight to stderr: the samples are raw index bytes
    # and every other diagnostic in this script routes them through
    # neutralize_ctrl first. Emitting here would put ESC/OSC sequences on the
    # developer terminal, and the parity test that pins that rule anchors on the
    # `head ... | neutralize_ctrl` shape, so an awk-internal write slips past it.
    if (dropped > 0 && dropmeta != "") {
      printf "%d\n", dropped > dropmeta
      for (i = 1; i <= dropped && i <= 3; i++) printf "%s\n", dropped_sample[i] > dropmeta
    }
  }
')

# Render the partial-drop report: fixed Japanese text straight to stderr, raw
# index samples only after neutralize_ctrl (same idiom as the other diagnostics
# in this file). Samples degrade to `?` for multibyte content — the documented
# trade-off in control-char-neutralize.sh.
if [[ -n "$_drop_meta" && -s "$_drop_meta" ]]; then
  _drop_n=$(head -1 "$_drop_meta")
  echo "WARNING: index.md の ${_drop_n} 行が登録リンク (](pages/...)) を持ちながら候補になりませんでした" >&2
  tail -n +2 "$_drop_meta" | neutralize_ctrl --keep-newline | sed 's/^/    /' >&2
  echo "  カタログ行の形状が Pass 1 の想定 (5 列テーブル / OKF 箇条書き) と異なる可能性があります" >&2
fi

if [[ -z "$candidates" ]]; then
  # Separate "the catalog has entries this parser cannot read" from "the wiki has
  # no pages yet". Both exit 0 with no stdout, so without this the first case is
  # indistinguishable from a legitimately empty wiki and a format drift stays
  # invisible for as long as it lasts.
  #
  # Comment blocks are dropped with the SAME rule Pass 1 uses (line-anchored
  # start, closed on the first `-->`), not `sed '/<!--/,/-->/d'`: sed's range
  # treats a self-closing `<!-- ... -->` as a range START and deletes on to the
  # next `-->`, which removed 41 live rows from the live index. Two different
  # comment semantics in one file make the guard inspect a different corpus than
  # the parser it guards.
  #
  # Captured into a variable rather than piped into `grep -q`: grep exits at the
  # first match, the upstream writer dies of SIGPIPE, and `set -o pipefail` turns
  # that into rc=141 so the `if` reads false and the WARNING never prints. That
  # only happens past the pipe buffer — measured silent above ~89 KB, and the
  # live index is 375 KB, so the guard was dead exactly at the scale that needs
  # it. Same failure class this PR fixes in read_page_meta below.
  stripped=$(awk '
    /^[[:space:]]*<!--/ { in_comment=1 }
    in_comment { if (index($0, "-->") > 0) in_comment=0; next }
    { print }
  ' <<< "$index_content")
  if grep -q '](pages/' <<< "$stripped"; then
    echo "WARNING: .rite/wiki/index.md に登録リンク (](pages/...)) を含む行がありますが、候補を 1 件も抽出できませんでした" >&2
    echo "  カタログの形式が Pass 1 の対応形式 (5 列テーブル / OKF 箇条書き) と異なる可能性があります" >&2
    # Also on stdout. Five of the six callers invoke this script with
    # `2>/dev/null` (pr-review, fix, issue-implement, issue-create, unknowns);
    # only the manual `/rite:wiki-query` path keeps stderr. So in every path
    # that runs inside a workflow the line above reaches nobody — and an empty
    # stdout is exactly
    # what "no matching pages" looks like, which is the misattribution this
    # guard exists to break. One line, marked as a notice rather than content,
    # so a reader of the injected block can tell the wiki was not consulted.
    printf '> ⚠️ Wiki index に登録行がありますが、そこから候補を抽出できませんでした（カタログ形式が Pass 1 の対応形式と異なる可能性）。今回、Wiki 経験則は注入されていません。\n'
  fi
  exit 0
fi

# Read a candidate page's frontmatter metadata (domain / confidence / updated).
# Returns "domain\x1f confidence\x1f updated" on stdout, or exit 1 on read
# failure (the caller treats failure as a non-blocking skip — AC-8). Reads via
# the same `ref` (separate_branch) / working-tree (same_branch) selection used
# for index.md and per-page body reads, keeping origin/wiki fallback consistent.
read_page_meta() {
  local p="$1" body=""
  if [[ "$branch_strategy" == "separate_branch" ]]; then
    body=$(git show "${ref}:.rite/wiki/${p}" 2>/dev/null) || return 1
  else
    [[ -f ".rite/wiki/${p}" ]] || return 1
    body=$(cat ".rite/wiki/${p}" 2>/dev/null) || return 1
  fi
  [[ -z "$body" ]] && return 1
  # here-string, not `printf | awk`: the awk below exits at the frontmatter
  # terminator, so on a page whose body exceeds the pipe buffer the writer is
  # still mid-write and dies of SIGPIPE. Under `set -o pipefail` that makes the
  # pipeline return 141 and the caller reports a perfectly readable page as
  # unreadable. Measured on a 61 KB page (rc=141) against a 14 KB page (rc=0).
  awk '
    BEGIN { d=""; c=""; u=""; infm=0 }
    NR == 1 && /^---[[:space:]]*$/ { infm=1; next }
    infm && /^---[[:space:]]*$/ { exit }
    infm && /^domain:/     { v=$0; sub(/^domain:[[:space:]]*/,"",v);     gsub(/^["'\'']|["'\'']$/,"",v); d=v }
    infm && /^confidence:/ { v=$0; sub(/^confidence:[[:space:]]*/,"",v); gsub(/^["'\'']|["'\'']$/,"",v); c=v }
    infm && /^updated:/    { v=$0; sub(/^updated:[[:space:]]*/,"",v);    gsub(/^["'\'']|["'\'']$/,"",v); u=v }
    END { printf "%s\037%s\037%s", d, c, u }
  ' <<< "$body"
}

# --- Pass 2 + Score ---
# For each candidate, read its page frontmatter (Pass 2) for domain/confidence/
# updated, then count case-insensitive substring matches across
# title + domain + description for each keyword. Weight by confidence.
IFS=',' read -r -a kw_array <<< "$KEYWORDS"

# Normalize the keywords once, not once per candidate. Pass 1 now yields the
# whole catalog (360 candidates on the live wiki when measured, up from 0 before
# table support),
# so anything inside the loop is multiplied by the corpus size: the per-candidate
# `sed`+`tr` alone cost 7,220 subprocesses for 10 keywords, and the query went
# from 0.04 s to 13.2 s.
kw_norm=()
for kw in "${kw_array[@]}"; do
  kw_trim=$(printf '%s' "$kw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
  [[ -n "$kw_trim" ]] && kw_norm+=("$kw_trim")
done

# Build scored list: "score<US>title<US>path<US>domain<US>summary<US>updated<US>confidence"
# (`summary` slot carries the OKF index description, keeping the render section
# below unchanged.)
scored=""
while IFS=$'\x1f' read -r title path description; do
  [[ -z "$path" ]] && continue
  # Pass 2: read page frontmatter for metadata. Non-blocking — a candidate whose
  # page is unreadable (stale index → page drift) is skipped with a WARNING and
  # the remaining candidates still render (AC-8).
  if ! meta=$(read_page_meta "$path"); then
    # `path` comes from index.md too, so it goes through the same neutralizer as
    # the drop samples above (this site became reachable for 360 candidates once
    # table rows started producing candidates).
    printf 'WARNING: cannot read frontmatter of %s — skipping candidate (index.md may be stale)\n' "$path" \
      | neutralize_ctrl --keep-newline >&2
    continue
  fi
  IFS=$'\x1f' read -r domain confidence updated <<< "$meta"
  [[ -z "$confidence" ]] && confidence="medium"  # default mirrors page-template.md
  haystack=$(printf '%s %s %s' "$title" "$domain" "$description" | tr '[:upper:]' '[:lower:]')
  raw_score=0
  for kw_trim in "${kw_norm[@]}"; do
    # Counted in-shell rather than by spawning awk per keyword per candidate:
    # same substring semantics, no subprocess in the hot loop.
    rest="$haystack"
    while [[ "$rest" == *"$kw_trim"* ]]; do
      raw_score=$((raw_score + 1))
      rest="${rest#*"$kw_trim"}"
    done
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
    # cycle 11 HIGH F-02: delimiter を \x1f に統一 (awk printf 出力 / IFS read と整合)
    scored+=$(printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "${weighted_score}" "${title}" "${path}" "${domain}" "${description}" "${updated}" "${confidence}")$'\n'
  fi
done <<< "$candidates"

if [[ -z "$scored" ]]; then
  exit 0
fi

# Sort by score descending, take top N.
# Split `sort` and `head` into independent invocations so that a sort
# failure (e.g. unit separator boundary mismatch, OOM) surfaces as a WARNING instead
# of being masked by the downstream `head` closing the pipe early and
# returning a benign exit 0 to the caller.
if ! sorted=$(printf '%s' "$scored" | sort -t$'\x1f' -k1,1 -nr); then
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

while IFS=$'\x1f' read -r score title path domain summary updated confidence; do
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
        if ! _git_show_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-query-gitshow-err-XXXXXX"); then
          echo "WARNING: mktemp failed for git show stderr capture; falling back to /dev/null for the rest of this run" >&2
          _git_show_err=""
          _git_show_err_failed=1
        fi
      elif [ -n "${_git_show_err:-}" ]; then
        : > "$_git_show_err"  # truncate between iterations
      fi
      # Use the `ref` selected above so origin/wiki fallback
      # stays consistent between index.md (line 282) and per-page reads.
      if page_body=$(git show "${ref}:.rite/wiki/${path}" 2>"${_git_show_err:-/dev/null}"); then
        :
      else
        _git_show_rc=$?
        echo "WARNING: cannot read ${path} from ref '${ref}' — index.md may be stale (git show rc=${_git_show_rc})" >&2
        [ -n "$_git_show_err" ] && [ -s "$_git_show_err" ] && head -3 "$_git_show_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
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
