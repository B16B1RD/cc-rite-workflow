#!/usr/bin/env bash
# number-reference-check.sh
#
# Detect Issue/PR number references (`#NNN`, `Issue #NNN`, `PR #NNN`) that have
# crept back into the documentation surface this project keeps number-free.
# Project policy is to drop descriptive Issue/PR numbers and state the rationale
# directly as prose; this check guards the cleaned surface against recurrence.
#
# Why a separate hook:
#   Manual removal alone recurs — command docs accrete `Issue #NNN` provenance
#   over time. A static check surfaces re-introduction at lint time instead of
#   at the next manual audit. Findings are warnings (non-blocking); the
#   convention is enforced progressively, not by gating CI.
#
# What is detected:
#   A 3-4 digit hash-number token: `#[0-9]{3,4}` at a word boundary. This
#   subsumes the `Issue #NNN` / `PR #NNN` prose forms (the `#NNN` substring is
#   what matches). 1-2 digit refs (`#1`, `#42`) and 5+ digit tokens are NOT
#   matched — the former are short task-list refs, the latter are not Issue/PR
#   numbers in this repo.
#
# What is NOT matched (structural — no allowlist needed):
#   - Functional code: `{issue_number}` placeholder, `issue-[0-9]+` branch-name
#     extraction, `/issues/123/` API paths — none contain a literal `#NNN`.
#   - Markdown step/phase headings: `## 3.19`, `### 4.4.W` — the `#` is followed
#     by another `#` or a space, never directly by a digit.
#
# Exclusions (file / line level):
#   - plugins/rite/hooks/tests/ (fixtures intentionally embed bad refs).
#   - Any line containing the marker `drift-check-ignore`.
#
# Scope (--all): the number-free surface this project guarantees and guards —
#   plugins/rite/skills/lint/SKILL.md. CHANGELOG.md / CHANGELOG.ja.md record
#   Issue numbers as pointers and are outside this surface (repository
#   documents, not marketplace-distributed plugin files). The wider
#   comment/doc cleanup is handled by sibling work; as those land, their cleaned
#   paths can be appended to DEFAULT_TARGETS below.
#
# Usage:
#   number-reference-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = reference detected, 2 = invocation error.

set -uo pipefail

# The number-free surface guarded by --all (repo-relative paths).
# CHANGELOG.md / CHANGELOG.ja.md are omitted: they are repository documents
# that keep Issue numbers as pointers, not the marketplace number-free set.
DEFAULT_TARGETS=(
  "plugins/rite/skills/lint/SKILL.md"
)

# Reference grammar: `#` + 3-4 digits at a trailing word boundary.
REF_RE='#[0-9]{3,4}\b'

REPO_ROOT=""
QUIET=0
USE_ALL=0
declare -a TARGETS=()

usage() {
  cat <<'EOF'
Usage: number-reference-check.sh [options]

Options:
  --all              Scan the number-free surface (plugins/rite/skills/lint/SKILL.md)
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary output on stderr
  -h, --help         Show this help

Detected: Issue/PR number references (#NNN / Issue #NNN / PR #NNN), 3-4 digits.
Exclusions: hooks/tests/ / lines containing 'drift-check-ignore'.

Exit codes:
  0  No reference detected
  1  Reference detected
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
if [ ! -d "$REPO_ROOT" ]; then
  echo "ERROR: repo-root not a directory: $REPO_ROOT" >&2
  exit 2
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [ "$USE_ALL" -eq 1 ]; then
  for f in "${DEFAULT_TARGETS[@]}"; do
    [ -f "$f" ] || continue                       # absent surface file — skip silently
    TARGETS+=("$f")
  done
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

total=0
check_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file" >&2
    return 0
  fi
  # Test fixtures intentionally embed bad refs — never report them.
  case "$file" in plugins/rite/hooks/tests/*) return 0 ;; esac
  local lineno content token
  while IFS= read -r numbered; do
    lineno="${numbered%%:*}"
    content="${numbered#*:}"
    case "$content" in *drift-check-ignore*) continue ;; esac
    token="$(grep -oE "$REF_RE" <<< "$content" | head -1)"
    printf '[number-ref] %s:%s: %s — Issue/PR number reference (state the rationale in prose instead)\n' \
      "$file" "$lineno" "${token:-#NNN}"
    total=$((total + 1))
  done < <(grep -nE "$REF_RE" "$file" 2>/dev/null || true)
}

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  check_file "$t"
done

log "==> Total number-ref findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
