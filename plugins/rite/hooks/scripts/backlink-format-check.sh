#!/usr/bin/env bash
# backlink-format-check.sh
#
# Detect bidirectional backlink format invariant violations in rite-workflow
# files. PR #620 (Issue #620) established **colon notation** as the canonical
# format for `Downstream reference:` comments, and PR #626 unified all 9
# existing sites to the canonical form. This lint check detects future
# regressions back to the PR #605 / PR #619 dialects.
#
# Canonical format (PR #620) is described in the wiki canonical page:
#     .rite/wiki/pages/patterns/drift-check-anchor-semantic-name.md
# and uses the shape `reference-keyword filepath-colon-phase-number`.
#
# Expected canonical pattern (grep-verifiable) — see the wiki page above for
# the exact regex. This script detects the two legacy dialects that PR #620
# replaced:
#
#   P1: space-separated (PR #605 old dialect)
#       semantics: the file path and Phase token are separated by a SPACE
#                  instead of a COLON. Canonical uses colon; this dialect
#                  uses a space.
#
#   P2: parenthetical (PR #619 old dialect)
#       semantics: the backlink includes a parenthetical qualifier naming
#                  the DRIFT-CHECK anchor. PR #620 dropped this qualifier
#                  because filepath-colon-phase already uniquely identifies
#                  the anchor within each Phase.
#
# Exact regex literals are kept INSIDE the awk program below (not in this
# header) so the script does not flag itself when run with --all over
# hooks/scripts/. Same header-comment policy as bang-backtick-check.sh.
#
# Lines where `Downstream reference:` is not followed by any Phase number
# (e.g. free-prose references to Hint messages) are neither canonical nor
# NG — both patterns intentionally require a `Phase` token, so such lines
# silently pass. This is by design: they reference different semantic
# targets and are not covered by the PR #620 invariant.
#
# Out of scope:
#   - Wiki canonical pages under `.rite/wiki/` — not on the development
#     branch (separate `wiki` branch via worktree). Intentional scope
#     boundary per Issue #627 "(backticks 内の example は除外)" note.
#   - `Downstream reference:` lines inside Markdown code fences. Lines
#     *inside* fenced blocks are still scanned because lint.md Phase 3.5-3.9
#     scripts treat them uniformly — see bang-backtick-check.sh for the
#     same policy precedent. If false positives surface in wiki pages that
#     get committed to the dev branch, add a fence-aware mode in a follow-up.
#
# Usage:
#   backlink-format-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#
# Exit codes:
#   0  No backlink format violations
#   1  Violation pattern detected
#   2  Invocation error (bad args, missing directories)

set -uo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: backlink-format-check.sh [options]

Options:
  --all              Scan plugins/rite/commands/**/*.md, plugins/rite/hooks/scripts/**/*.sh,
                     and the repository-root .gitignore
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr (per-finding
                     output on stdout is preserved; still exits non-zero on
                     detection).
  -h, --help         Show this help

Exit codes:
  0  No violations detected
  1  Violation pattern detected
  2  Invocation error (bad args, missing directories)
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

# Resolve --all target list. Explicitly check directory existence so marketplace
# installs (where hooks/scripts lives separately from the plugin commands/) get
# a clear diagnostic instead of the generic "no targets specified" fallback.
if [ "$USE_ALL" -eq 1 ]; then
  commands_dir="plugins/rite/commands"
  scripts_dir="plugins/rite/hooks/scripts"
  gitignore_path=".gitignore"
  found_any=0
  if [ -d "$commands_dir" ]; then
    found_any=1
  else
    echo "WARNING: $commands_dir not found under $REPO_ROOT (skipped)" >&2
  fi
  if [ -d "$scripts_dir" ]; then
    found_any=1
  else
    echo "WARNING: $scripts_dir not found under $REPO_ROOT (skipped)" >&2
  fi
  if [ -f "$gitignore_path" ]; then
    found_any=1
  else
    echo "WARNING: $gitignore_path not found under $REPO_ROOT (skipped)" >&2
  fi
  if [ "$found_any" -eq 0 ]; then
    echo "ERROR: --all requested but none of $commands_dir, $scripts_dir, or $gitignore_path exist under $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --target FILE explicitly" >&2
    exit 2
  fi
  if [ -d "$commands_dir" ]; then
    while IFS= read -r f; do
      TARGETS+=("$f")
    done < <(find "$commands_dir" -type f -name '*.md' 2>/dev/null | sort)
  fi
  # Self-exclusion: the awk regex literals in this script would match
  # themselves when scanned. Compute the script's own path relative to
  # REPO_ROOT and skip it in --all mode. --target still accepts explicit
  # self-reference so test harnesses can verify behaviour deliberately.
  self_abs="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  self_rel=""
  case "$self_abs" in
    "$REPO_ROOT"/*) self_rel="${self_abs#"$REPO_ROOT"/}" ;;
  esac
  if [ -d "$scripts_dir" ]; then
    while IFS= read -r f; do
      if [ -n "$self_rel" ] && [ "$f" = "$self_rel" ]; then
        continue
      fi
      TARGETS+=("$f")
    done < <(find "$scripts_dir" -type f -name '*.sh' 2>/dev/null | sort)
  fi
  if [ -f "$gitignore_path" ]; then
    TARGETS+=("$gitignore_path")
  fi
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

FINDINGS_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'rm -f "$FINDINGS_FILE"' EXIT

# ----- Scan one file for both patterns ---------------------------------------
#
# Uses awk `while (match(...))` so multiple violations on a single line are
# all reported. Each P1/P2 occurrence emits a dedicated finding line.
check_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file" >&2
    return 0
  fi
  awk -v F="$file" '
    {
      line = $0
      # P1: space-separated dialect.
      #   "Downstream reference: " + <non-space-run> + " Phase " + <digits>.<digits>
      # The [^ ]+ run must NOT itself end in ":Phase" — otherwise
      #   "Downstream reference: lint.md:Phase 8.3, same file:Phase 5.1"
      # would match at the "same file Phase 5.1" substring (false positive).
      # We guard this by requiring the token right before " Phase " to not
      # contain ":Phase" already.
      pos = 1
      while (pos <= length(line)) {
        sub_s = substr(line, pos)
        if (!match(sub_s, /Downstream reference: [^ ]+ Phase [0-9]+\.[0-9.]*[0-9]/)) break
        hit = substr(sub_s, RSTART, RLENGTH)
        # False-positive filter: canonical sequences include "Phase X.Y, same file:Phase Z.W".
        # Extract the token between "reference: " and " Phase" — if it contains ":Phase"
        # (e.g. "lint.md:Phase 8.3,") the hit is the tail of a canonical comma-separated
        # list, not a space-separated dialect.
        tail = substr(hit, length("Downstream reference: ") + 1)
        sp_idx = index(tail, " Phase")
        token = substr(tail, 1, sp_idx - 1)
        if (index(token, ":Phase") == 0) {
          print "[backlink-format][P1] " F ":" NR ": space-separated dialect (expected colon): " hit
        }
        pos = pos + RSTART + RLENGTH - 1
      }
      # P2: parenthetical DRIFT-CHECK ANCHOR qualifier on a Downstream reference line.
      if (match(line, /Downstream reference:.*\(DRIFT-CHECK ANCHOR:/)) {
        print "[backlink-format][P2] " F ":" NR ": parenthetical (DRIFT-CHECK ANCHOR: ...) qualifier"
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
log "==> Total backlink-format findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
