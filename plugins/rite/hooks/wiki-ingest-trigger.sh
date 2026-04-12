#!/bin/bash
# rite workflow - Wiki Ingest Trigger
#
# Saves a Raw Source artifact under .rite/wiki/raw/{type}/ so that the
# /rite:wiki:ingest command can later read & integrate it into Wiki pages.
#
# This script is the staging primitive for the Ingest cycle described in
# docs/designs/experience-heuristics-persistence-layer.md (F2). It does not
# perform LLM integration itself — that responsibility belongs to
# /rite:wiki:ingest (commands/wiki/ingest.md). The script's only job is to
# write the Raw Source file with consistent naming and metadata.
#
# Usage:
#   bash wiki-ingest-trigger.sh \
#     --type {reviews|retrospectives|fixes} \
#     --source-ref "<short identifier, e.g. pr-123 or issue-469>" \
#     --content-file <path-to-file-containing-raw-source-body> \
#     [--pr-number 123] \
#     [--issue-number 469] \
#     [--title "Optional human-readable title"]
#
# Options:
#   --type           Raw Source type. Required. One of: reviews, retrospectives, fixes
#   --source-ref     Short identifier used in filename + frontmatter (required)
#   --content-file   Path to a file whose contents become the Raw Source body (required)
#   --pr-number      Optional PR number to embed in frontmatter
#   --issue-number   Optional Issue number to embed in frontmatter
#   --title          Optional one-line human-readable title
#
# Output:
#   stdout: relative path of the saved Raw Source file (single line)
#   stderr: validation errors / write failures
#
# Exit codes:
#   0  success
#   1  argument validation error
#   2  Wiki not initialized or wiki feature disabled
#   3  filesystem write failure
#
# Notes:
#   - The script does NOT perform git operations. Persistence to the wiki branch
#     (separate_branch strategy) is left to /rite:wiki:ingest, which has the
#     full branch-switching machinery.
#   - The script does NOT do any LLM work — it is a pure file-writing utility.
set -euo pipefail

TYPE=""
SOURCE_REF=""
CONTENT_FILE=""
PR_NUMBER=""
ISSUE_NUMBER=""
TITLE=""

usage() {
  cat <<'USAGE'
Usage: wiki-ingest-trigger.sh --type <type> --source-ref <ref> --content-file <path>
                              [--pr-number N] [--issue-number N] [--title "..."]

Saves a Raw Source artifact under .rite/wiki/raw/{type}/ for later
integration by /rite:wiki:ingest.

Required:
  --type           reviews | retrospectives | fixes
  --source-ref     short identifier (e.g. pr-123, issue-469)
  --content-file   path to file containing the raw body

Optional:
  --pr-number      PR number for frontmatter
  --issue-number   Issue number for frontmatter
  --title          one-line human-readable title

Exit codes:
  0  success (path of saved file printed to stdout)
  1  argument validation error
  2  Wiki disabled / not initialized
  3  filesystem write failure
USAGE
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)       usage; exit 0 ;;
    --type)          TYPE="${2:-}"; shift 2 ;;
    --source-ref)    SOURCE_REF="${2:-}"; shift 2 ;;
    --content-file)  CONTENT_FILE="${2:-}"; shift 2 ;;
    --pr-number)     PR_NUMBER="${2:-}"; shift 2 ;;
    --issue-number)  ISSUE_NUMBER="${2:-}"; shift 2 ;;
    --title)         TITLE="${2:-}"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# --- Validation ---
if [[ -z "$TYPE" ]]; then
  echo "ERROR: --type is required" >&2
  exit 1
fi
case "$TYPE" in
  reviews|retrospectives|fixes) ;;
  *)
    echo "ERROR: --type must be one of: reviews, retrospectives, fixes (got: '$TYPE')" >&2
    exit 1
    ;;
esac

if [[ -z "$SOURCE_REF" ]]; then
  echo "ERROR: --source-ref is required" >&2
  exit 1
fi
# F-07 fix: reject newlines / control chars to prevent YAML frontmatter injection
case "$SOURCE_REF" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    echo "ERROR: --source-ref must not contain newlines, carriage returns, or tabs" >&2
    echo "  reason: such characters can break YAML frontmatter (early --- close, key injection)" >&2
    exit 1
    ;;
esac

# F-09 fix: validate PR_NUMBER / ISSUE_NUMBER as positive integers BEFORE write
if [[ -n "$PR_NUMBER" ]]; then
  case "$PR_NUMBER" in
    ''|*[!0-9]*)
      echo "ERROR: --pr-number must be a positive integer (got: '$PR_NUMBER')" >&2
      exit 1
      ;;
  esac
fi
if [[ -n "$ISSUE_NUMBER" ]]; then
  case "$ISSUE_NUMBER" in
    ''|*[!0-9]*)
      echo "ERROR: --issue-number must be a positive integer (got: '$ISSUE_NUMBER')" >&2
      exit 1
      ;;
  esac
fi

# F-08 fix: reject newlines / CR / tab in TITLE to prevent YAML scalar break
if [[ -n "$TITLE" ]]; then
  case "$TITLE" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "ERROR: --title must not contain newlines, carriage returns, or tabs" >&2
      exit 1
      ;;
  esac
  # reject odd trailing backslashes (escape ambiguity)
  trailing=${TITLE##*[^\\]}
  trailing_len=${#trailing}
  if (( trailing_len % 2 == 1 )); then
    echo "ERROR: --title must not end with an odd number of backslashes (escape ambiguity)" >&2
    exit 1
  fi
fi

if [[ -z "$CONTENT_FILE" ]]; then
  echo "ERROR: --content-file is required" >&2
  exit 1
fi
if [[ ! -f "$CONTENT_FILE" ]]; then
  echo "ERROR: --content-file '$CONTENT_FILE' does not exist or is not a regular file" >&2
  exit 1
fi
if [[ ! -s "$CONTENT_FILE" ]]; then
  echo "ERROR: --content-file '$CONTENT_FILE' is empty" >&2
  exit 1
fi

# --- Wiki enable check (best-effort: only checks rite-config.yml in CWD) ---
# This guard is intentionally lenient: when rite-config.yml is absent, we
# proceed and let /rite:wiki:ingest handle the strict validation later. The
# trigger only refuses when wiki.enabled is explicitly false.
#
# F-01 fix: avoid `set -euo pipefail` × `grep no-match` silent abort.
# When `wiki:` section or `enabled:` key is missing, grep returns exit 1, which
# under pipefail aborts the entire script. We split the pipeline into stages and
# explicitly tolerate empty results so missing keys lenient-fall-through to "not false".
if [[ -f "rite-config.yml" ]]; then
  wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
  wiki_enabled_line=""
  if [[ -n "$wiki_section" ]]; then
    # awk -- skip non-matches gracefully (exit 0 even with no output)
    wiki_enabled_line=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }') || wiki_enabled_line=""
  fi
  wiki_enabled=""
  if [[ -n "$wiki_enabled_line" ]]; then
    wiki_enabled=$(printf '%s' "$wiki_enabled_line" | sed 's/#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'\''' | tr '[:upper:]' '[:lower:]')
  fi
  case "$wiki_enabled" in
    false|no|0)
      echo "ERROR: wiki.enabled is false in rite-config.yml — refusing to stage Raw Source" >&2
      echo "  hint: set wiki.enabled: true and run /rite:wiki:init first" >&2
      exit 2
      ;;
  esac
fi

# --- Slugify source-ref for filename ---
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-60
}
slug=$(slugify "$SOURCE_REF")
if [[ -z "$slug" ]]; then
  echo "ERROR: --source-ref '$SOURCE_REF' produced an empty slug after sanitization" >&2
  exit 1
fi

# --- Compute target path ---
target_dir=".rite/wiki/raw/${TYPE}"
timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
timestamp_compact=$(date -u +"%Y%m%dT%H%M%SZ")
target_file="${target_dir}/${timestamp_compact}-${slug}.md"

# Ensure directory exists (for separate_branch strategy this only takes effect
# when /rite:wiki:ingest is later run from the wiki branch; on the dev branch
# the directory may not exist yet, so we create it on demand).
#
# F-13 fix: do NOT silently suppress mkdir stderr. Surface root cause
# (permission denied / read-only filesystem / ancestor not a directory).
if ! mkdir -p "$target_dir"; then
  echo "ERROR: failed to create directory '$target_dir'" >&2
  echo "  hint: check filesystem permissions and ancestor path types" >&2
  exit 3
fi

# F-08 fix: properly escape backslash before double-quote in TITLE
#   - escape backslash first (otherwise the next escape doubles them)
#   - then escape double quote
if [[ -n "$TITLE" ]]; then
  escaped_title=${TITLE//\\/\\\\}
  escaped_title=${escaped_title//\"/\\\"}
fi

# --- Write Raw Source with YAML frontmatter ---
{
  printf -- '---\n'
  printf 'type: %s\n' "$TYPE"
  printf 'source_ref: %s\n' "$SOURCE_REF"
  printf 'captured_at: "%s"\n' "$timestamp_iso"
  if [[ -n "$PR_NUMBER" ]]; then
    printf 'pr_number: %s\n' "$PR_NUMBER"
  fi
  if [[ -n "$ISSUE_NUMBER" ]]; then
    printf 'issue_number: %s\n' "$ISSUE_NUMBER"
  fi
  if [[ -n "$TITLE" ]]; then
    printf 'title: "%s"\n' "$escaped_title"
  fi
  printf 'ingested: false\n'
  printf -- '---\n\n'
  cat "$CONTENT_FILE"
  # Ensure trailing newline
  printf '\n'
} > "$target_file" || {
  echo "ERROR: failed to write '$target_file'" >&2
  exit 3
}

if [[ ! -s "$target_file" ]]; then
  echo "ERROR: '$target_file' was created but is empty" >&2
  exit 3
fi

# F-21 fix: integrity verification — partial-write 検出
# (frontmatter のみが書き込まれて body 部分が欠落する truncated 書き込みを catch)
#   1. frontmatter の closing `---` の **後** に少なくとも 1 つの非空行が存在することを確認
#   2. 末尾の trailing newline (printf '\n') が書き込まれていることを確認
expected_min_lines=$(awk 'BEGIN { fm_close=0 } /^---$/ { fm_close++; next } fm_close == 2 && NF > 0 { body_seen=1; exit } END { exit !(fm_close == 2 && body_seen) }' "$target_file" && echo "ok" || echo "incomplete")
if [ "$expected_min_lines" = "incomplete" ]; then
  echo "ERROR: '$target_file' integrity check failed (frontmatter present but body missing/truncated)" >&2
  echo "  対処: ファイルを削除して再実行してください: rm '$target_file'" >&2
  exit 3
fi

# Print the relative path so callers (e.g. /rite:wiki:ingest) can pick it up
printf '%s\n' "$target_file"
