#!/usr/bin/env bash
# wiki-growth-check.sh
#
# Detect Wiki growth stalls — fires when the last commit on the `wiki` branch
# is older than `wiki.growth_check.threshold_prs` consecutive merged PRs on
# the development base branch (default: develop). This catches "Wiki ingest is
# silently broken" regressions where review/fix/close skip Phase X.X.W and the
# wiki branch never grows even though PRs are landing.
#
# Issue #524 (Wiki ingest silent skip 3層防御) — layer 3 (lint growth check).
# Companion to:
#   - layer 1: review.md / fix.md / close.md Phase X.X.W skip 不可化
#   - layer 2: workflow-incident-emit.sh の wiki_ingest_skipped / wiki_ingest_failed sentinel
#
# Usage:
#   wiki-growth-check.sh [--repo-root DIR] [--quiet] [--threshold N] [-h|--help]
#
# Options:
#   --repo-root DIR   Repository root (default: git rev-parse --show-toplevel)
#   --quiet           Suppress informational output (still emits findings line)
#   --threshold N     Override threshold from rite-config.yml (testing/dry-run)
#   -h, --help        Show this help
#
# Exit codes (drift-check と同一の非ブロッキング契約):
#   0  Wiki growth healthy (or wiki branch absent / wiki disabled — skip silently)
#   1  Wiki growth threshold exceeded (warning — caller MUST keep [lint:success])
#   2  Invocation error (bad args, missing repo, missing gh CLI)
#
# Output:
#   Always prints a `==> Total wiki-growth-check findings: N` line on stdout
#   (parsed by lint.md Phase 3.8 to populate `wiki_growth_finding_count`).
#
set -uo pipefail

REPO_ROOT=""
QUIET=0
THRESHOLD_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: wiki-growth-check.sh [options]

Options:
  --repo-root DIR   Repository root (default: git rev-parse --show-toplevel)
  --quiet           Suppress informational output
  --threshold N     Override threshold (default: read from rite-config.yml,
                    fallback 5 when wiki.growth_check.threshold_prs is absent)
  -h, --help        Show this help

Exit codes:
  0  No growth stall (or wiki disabled / wiki branch absent — skip silently)
  1  Growth threshold exceeded (warning, non-blocking)
  2  Invocation error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root)  REPO_ROOT="$2"; shift 2 ;;
    --quiet)      QUIET=1; shift ;;
    --threshold)  THRESHOLD_OVERRIDE="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- Resolve repo root ---
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: not inside a git repository (git rev-parse --show-toplevel failed)" >&2
    echo "==> Total wiki-growth-check findings: 0"
    exit 2
  }
fi
cd "$REPO_ROOT" || {
  echo "ERROR: cannot cd to repo root: $REPO_ROOT" >&2
  echo "==> Total wiki-growth-check findings: 0"
  exit 2
}

log_info() {
  [ "$QUIET" -eq 0 ] && echo "$@"
}

# --- Read config ---
config_file="rite-config.yml"
if [ ! -f "$config_file" ]; then
  log_info "wiki-growth-check: rite-config.yml not found, skipping (exit 0)"
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi

# wiki.enabled (opt-out default true)
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' "$config_file" 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [ -n "$wiki_section" ]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' \
    | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in
  false|no|0) wiki_enabled="false" ;;
  true|yes|1) wiki_enabled="true" ;;
  *)          wiki_enabled="true" ;;  # opt-out default
esac

if [ "$wiki_enabled" = "false" ]; then
  log_info "wiki-growth-check: wiki.enabled=false, skipping (exit 0)"
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi

# Threshold: --threshold override > rite-config.yml > default 5
if [ -n "$THRESHOLD_OVERRIDE" ]; then
  threshold="$THRESHOLD_OVERRIDE"
else
  # Look for `growth_check:` section nested under `wiki:` and pick `threshold_prs:`
  threshold=$(printf '%s\n' "$wiki_section" \
    | awk '
      /^[[:space:]]+growth_check:/ { in_gc=1; next }
      in_gc && /^[[:space:]]+threshold_prs:/ { print; exit }
      in_gc && /^[[:space:]]+[a-z_]+:/ && !/^[[:space:]]+threshold_prs:/ { in_gc=0 }
    ' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*threshold_prs:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
fi
if [ -z "$threshold" ] || ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -lt 1 ]; then
  threshold=5
fi

# --- Wiki branch existence + last commit timestamp ---
# branch_name (default "wiki") from rite-config.yml
wiki_branch=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+branch_name:/ { print; exit }' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -z "$wiki_branch" ] && wiki_branch="wiki"

# Try local branch first, then remote tracking branch
last_wiki=""
if git rev-parse --verify "$wiki_branch" >/dev/null 2>&1; then
  last_wiki=$(git log -1 --format=%aI "$wiki_branch" 2>/dev/null)
elif git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1; then
  last_wiki=$(git log -1 --format=%aI "origin/$wiki_branch" 2>/dev/null)
fi

if [ -z "$last_wiki" ]; then
  log_info "wiki-growth-check: wiki branch '$wiki_branch' not found locally or on origin — skipping (exit 0)"
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi

# --- Determine base branch (default: develop, fallback: main) ---
base_branch=$(awk '
  /^branch:/ { in_branch=1; next }
  in_branch && /^[[:space:]]+base:/ { print; exit }
  in_branch && /^[a-zA-Z]/ { in_branch=0 }
' "$config_file" 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -z "$base_branch" ] && base_branch="develop"

# --- Count merged PRs since last wiki commit ---
if ! command -v gh >/dev/null 2>&1; then
  echo "WARNING: gh CLI not found — wiki-growth-check skipped" >&2
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi

# `merged:>YYYY-MM-DD` — gh search interprets full ISO 8601 timestamps too
merged_count=$(gh pr list \
  --state merged \
  --base "$base_branch" \
  --search "merged:>$last_wiki" \
  --json number \
  --limit 200 2>/dev/null | jq 'length' 2>/dev/null)

if [ -z "$merged_count" ] || ! [[ "$merged_count" =~ ^[0-9]+$ ]]; then
  echo "WARNING: gh pr list returned unexpected output — wiki-growth-check skipped" >&2
  echo "==> Total wiki-growth-check findings: 0"
  exit 0
fi

# --- Decision ---
if [ "$merged_count" -ge "$threshold" ]; then
  echo "==> Wiki growth stall detected: $merged_count merged PRs on '$base_branch' since last '$wiki_branch' commit ($last_wiki) — no raw sources ingested (threshold: $threshold)"
  echo "==> Hint: Phase X.X.W (Wiki Ingest Trigger) may be silently skipped in review/fix/close. Check WIKI_INGEST_DONE / WIKI_INGEST_SKIPPED context lines."
  echo "==> Total wiki-growth-check findings: 1"
  exit 1
fi

log_info "wiki-growth-check: healthy ($merged_count merged PRs since last '$wiki_branch' commit, threshold: $threshold)"
echo "==> Total wiki-growth-check findings: 0"
exit 0
