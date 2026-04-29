#!/usr/bin/env bash
# comment-journal-check.sh
#
# Detect high-confidence "journal" narration patterns in plugins/rite/**/*.sh
# and plugins/rite/**/*.md. These are mechanical comment violations that
# accumulate when authors paste review-cycle / fix-history wording into
# in-tree comments instead of into commit messages or PR descriptions.
#
# Layered defense (Issue #702):
#   This script is the fast-fail layer below the LLM reviewers (Issues #700,
#   #701). The reviewers focus on WHY > WHAT semantic judgments; mechanical
#   100%-confidence patterns are killed here before they reach the reviewer
#   queue. Operationally invoked from /rite:lint (manual). PR review integration
#   is intentionally out of scope (Issue #702 採択方針: CI のみ運用).
#
# Detected patterns (4 regexes scanned in a single while-match awk loop, so
# multiple triggers on the same line are all reported — same multi-match
# discipline as bang-backtick-check.sh after the Issue #369 H-1 fix):
#
#   P1: verified-review cycle N
#       regex: verified-review cycle [0-9]+
#       semantics: leftover narration referring to a verified-review iteration.
#                  The iteration number drifts as soon as cycles add up; the
#                  reference becomes wrong-but-confident over time.
#
#   P2: 旧実装(は|では) - "the old implementation (was|did)"
#       regex: 旧実装(は|では)
#       semantics: comments that explain what the previous version did. The
#                  WHAT of removed code belongs in commit/PR history, not in
#                  the tree where it ages out of sync with the current code.
#
#   P3: PR #N cycle N fix
#       regex: PR #[0-9]+ cycle [0-9]+ fix
#       semantics: comments tagging a fix to a specific PR review cycle. PR
#                  numbers carry no meaning at read time; the cycle number
#                  is tied to a workflow run that no longer exists.
#
#   P4: cycle N F-N で(導入|確立|集約) - "introduced/established/consolidated in cycle N F-N"
#       regex: cycle [0-9]+ F-[0-9]+ で(導入|確立|集約)
#       semantics: comments referencing review-finding identifiers (F-NN).
#                  Finding IDs are scoped to one review run; the reference
#                  decays the moment that review is closed.
#
# Whitelist (initial — Issue #699 SoT integration is a future extension):
#
#   Lines containing any of the following markers are skipped entirely:
#     - <!-- example: ...    (markdown HTML-comment example marker)
#     - # example: ...        (shell / Python comment example marker)
#     - // example: ...       (TypeScript / JavaScript comment example marker)
#
#   Self-exclusion: this script's own regex literals would otherwise match.
#   When --all is requested the find walk skips this script's own path.
#
# Future extension: rite-config.yml workflow.lint.comment_journal.whitelist
# can list extra prefix tokens. Not implemented in this revision; the prefix
# markers above already cover SoT bad-example sections (Issue #699) when the
# author wraps the example with one of the three markers.
#
# Usage:
#   comment-journal-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = pattern detected, 2 = invocation error.

set -euo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: comment-journal-check.sh [options]

Options:
  --all              Scan plugins/rite/**/*.sh and plugins/rite/**/*.md
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr
  -h, --help         Show this help

Detected patterns:
  P1  verified-review cycle N
  P2  旧実装(は|では)
  P3  PR #N cycle N fix
  P4  cycle N F-N で(導入|確立|集約)

Whitelist markers (line-level skip):
  <!-- example:    /    # example:    /    // example:

Exit codes:
  0  No journal narration detected
  1  Pattern detected
  2  Invocation error
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target) TARGETS+=("$2"); shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [ "$USE_ALL" -eq 1 ]; then
  base="plugins/rite"
  if [ ! -d "$base" ]; then
    echo "ERROR: --all requested but $base does not exist under $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --target FILE explicitly" >&2
    exit 2
  fi
  self_abs="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  self_rel=""
  case "$self_abs" in
    "$REPO_ROOT"/*) self_rel="${self_abs#"$REPO_ROOT"/}" ;;
  esac
  while IFS= read -r f; do
    if [ -n "$self_rel" ] && [ "$f" = "$self_rel" ]; then
      continue
    fi
    TARGETS+=("$f")
  done < <(find "$base" -type f \( -name '*.sh' -o -name '*.md' \) 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

FINDINGS_FILE=""
_rite_journal_cleanup() {
  rm -f "${FINDINGS_FILE:-}"
}
trap 'rc=$?; _rite_journal_cleanup; exit $rc' EXIT
trap '_rite_journal_cleanup; exit 130' INT
trap '_rite_journal_cleanup; exit 143' TERM
trap '_rite_journal_cleanup; exit 129' HUP

FINDINGS_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }

# Single awk pass per file. Whitelist check happens up-front; the four pattern
# scans share the same while-match loop idiom so multi-match per line is
# preserved (parity with bang-backtick-check.sh post-#369).
check_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file" >&2
    return 0
  fi
  awk -v F="$file" '
    {
      line = $0
      # Whitelist: any line carrying an "example:" marker is skipped wholesale.
      if (line ~ /(<!--[[:space:]]*example:|#[[:space:]]+example:|\/\/[[:space:]]+example:)/) next

      # P1: verified-review cycle N
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /verified-review cycle [0-9]+/)) break
        print "[comment-journal][P1] " F ":" NR ": verified-review cycle reference: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }

      # P2: 旧実装(は|では)
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /旧実装(は|では)/)) break
        print "[comment-journal][P2] " F ":" NR ": legacy-impl narration: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }

      # P3: PR #N cycle N fix
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /PR #[0-9]+ cycle [0-9]+ fix/)) break
        print "[comment-journal][P3] " F ":" NR ": PR cycle fix narration: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }

      # P4: cycle N F-N で(導入|確立|集約)
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /cycle [0-9]+ F-[0-9]+ で(導入|確立|集約)/)) break
        print "[comment-journal][P4] " F ":" NR ": review-finding narration: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }
    }
  ' "$file" >> "$FINDINGS_FILE"
}

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  check_file "$t"
done

if [ -s "$FINDINGS_FILE" ]; then
  cat "$FINDINGS_FILE"
  total=$(wc -l < "$FINDINGS_FILE")
else
  total=0
fi
log "==> Total comment-journal findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
