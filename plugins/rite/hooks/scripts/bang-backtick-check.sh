#!/usr/bin/env bash
# bang-backtick-check.sh
#
# Detect bang-backtick adjacent patterns in plugins/rite/{commands,skills,agents,
# references}/**/*.md that can trigger Skill loader history expansion and break
# Skill loading (Issue #365 / PR #367 — backtick+bang adjacency in inline code
# caused /rite:pr:fix Skill load failure). The agents/ and references/ scopes
# were added because P3 (no-space-before-! variant) revealed that any markdown
# the slash command parser may load — directly or transitively via Read — is
# vulnerable, not just commands/skills entry points.
#
# Detected patterns (both are matched within a single Markdown inline code span,
# i.e. text enclosed by paired single backticks). **All occurrences on a single
# line are reported** — the scanner uses a while-match loop, so multiple triggers
# on the same line never silently collapse to one finding.
#
#   P1: closing-backtick-preceded-by-space-bang
#       regex: ` [^`]* !`
#       semantics: inline code where the character right before the closing
#                  backtick is literal "space + bang" (tab and other whitespace
#                  are NOT matched — this is the exact shape that broke fix.md
#                  in Issue #365).
#       Example that matches:    backtick-if-space-bang-backtick   (the #365 pattern)
#       Example that does NOT:   backtick-if-space-bang-space-cmd-backtick
#                                  (bang is not adjacent to closing backtick)
#
#   P2: opening-backtick-followed-by-bang
#       regex: `![alnum or single ASCII space]
#       semantics: inline code where the character right after the opening
#                  backtick is literal bang, followed by an alphanumeric or a
#                  single ASCII space (captures bash history-expansion shapes
#                  like "bang+word" while intentionally excluding the Markdown
#                  image-reference shape "bang+backslash-bracket").
#
#   P3: bang-immediately-before-backtick (anywhere on the line)
#       regex: !`
#       semantics: any literal bang character immediately before any backtick,
#                  regardless of preceding context. This intentionally covers
#                  ALL bang+backtick adjacencies — whether the bang sits at
#                  the closing boundary of an inline code span (`!`),
#                  in Rustdoc inner-doc (//!), in command-suffix style (cmd!),
#                  or in any other position. P1 covers a more specific
#                  space+!+backtick variant; P3 is the generic catch-all that
#                  also matches the P1 cases (intentional double-counting —
#                  the slash command parser triggers on bang+backtick
#                  adjacency regardless of upstream whitespace). Empirically
#                  required after the cycle 35 fix series — the parser was
#                  still triggering on `` `!` `` lone-bang inline spans
#                  because they form bang+backtick adjacency at the closing
#                  boundary.
#
# These patterns were chosen conservatively to produce zero false positives on
# the existing commands/skills tree (verified at creation time on 70 files).
# Innocent patterns such as Rustdoc inner doc `slash-slash-bang`, Markdown image
# `bang-bracket-alt-paren-url`, regex literal `bang-backslash-bracket`, and
# bash negation `if-space-bang-space-cmd` are intentionally NOT matched.
#
# Safe equivalents (writing convention)
# -------------------------------------
# When this check flags a line, the canonical rewrite depends on **what the
# inline code span refers to**. Two styles have emerged from the #609-#611
# fix series and MUST be applied consistently:
#
#   Style A: full-width corner brackets (「!」)
#       Use when the span refers to the literal bang character itself as a
#       standalone token (e.g. "行頭を # または 「!」 から開始する").
#       Adopted in: commands/wiki/init.md L247, L547.
#
#   Style B: expansion form (`if ! cmd; then`)
#       Use when the span quotes a shell syntax fragment containing `!` as
#       an operator (e.g. "the `if ! cmd; then` rc capture is mandatory").
#       Expand the fragment to its full minimal form so `!` is no longer
#       adjacent to a closing backtick.
#       Adopted in: commands/pr/cleanup.md, commands/wiki/references/
#       bash-cross-boundary-state-transfer.md L153.
#
# Judgment flow
# -------------
#   1. Is the span referring to the `!` character itself (noun)? -> Style A.
#   2. Is the span quoting shell syntax that uses `!` as an operator (verb)?
#      -> Style B (expand to a runnable minimal fragment).
#   3. Ambiguous? Prefer Style B — expansion almost always reads naturally,
#      whereas Style A only fits when the sentence grammar demands a single
#      character literal.
#
# Both styles avoid the P1/P2 patterns above by construction:
#   - Style A replaces the backtick-bang adjacency with a non-backtick span
#     (full-width 「...」 does not interact with bash history expansion).
#   - Style B moves the 「!」 away from the closing backtick by adding the
#     command continuation (`cmd; then`), defeating the P1 space-bang-before-
#     closing-backtick shape.
#
# Out of scope: detecting the non-adjacent `if ! ` space-bang-space pattern.
# That extension is tracked separately (see the --strict mode proposal on
# Issue #613 Out of scope).
#
# Usage:
#   bang-backtick-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = pattern detected, 2 = invocation error.

set -uo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: bang-backtick-check.sh [options]

Options:
  --all              Scan plugins/rite/{commands,skills,agents,references}/**/*.md
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr (per-finding
                     output on stdout is preserved; still exits non-zero on
                     detection). Use for CI log noise reduction while keeping
                     findings machine-readable.
  -h, --help         Show this help

Exit codes:
  0  No bang-backtick adjacency detected
  1  Pattern detected
  2  Invocation error (bad args, missing files)
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

# Resolve --all target list. Explicitly check that at least one of the scan
# directories exists so marketplace-install environments (where hooks/scripts
# lives in a different tree than the plugin commands/) get a clear diagnostic
# instead of the generic "no targets specified" fallback.
if [ "$USE_ALL" -eq 1 ]; then
  declare -a scan_dirs=()
  for d in \
    "plugins/rite/commands" \
    "plugins/rite/skills" \
    "plugins/rite/agents" \
    "plugins/rite/references"
  do
    if [ -d "$d" ]; then
      scan_dirs+=("$d")
    else
      echo "WARNING: $d not found under $REPO_ROOT (skipped)" >&2
    fi
  done
  if [ "${#scan_dirs[@]}" -eq 0 ]; then
    echo "ERROR: --all requested but no scan directory exists under $REPO_ROOT" >&2
    echo "  Expected one or more of: plugins/rite/{commands,skills,agents,references}" >&2
    echo "  Likely cause: this script was invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --target FILE explicitly" >&2
    exit 2
  fi
  while IFS= read -r f; do
    TARGETS+=("$f")
  done < <(find "${scan_dirs[@]}" -type f -name '*.md' 2>/dev/null | sort)
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
# Uses awk's `while (match(...))` idiom so that multiple triggers on a single
# line are all reported (fixes per-line undercounting bug — Issue #369 code-quality
# H-1). Each P1/P2 occurrence emits a dedicated finding line, eliminating the
# post-processing case dispatch the previous revision needed. Append directly
# to FINDINGS_FILE so the outer loop can count and print at the end.
check_file() {
  local file="$1"
  # Non-existent targets must be reported as diagnostics — a silent `return 0` gives
  # users false confidence when a typo'd `--target` path is passed (Issue #369 code-quality
  # cycle 2 L-NEW1). The `--all` path is unaffected because find(1) never produces
  # missing entries.
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file" >&2
    return 0
  fi
  awk -v F="$file" '
    {
      line = $0
      # P1: space+! immediately before a closing backtick inside inline code.
      # Loop with substr/match to capture every occurrence on the same line.
      pos = 1
      while (pos <= length(line)) {
        sub_s = substr(line, pos)
        if (!match(sub_s, /`[^`]* !`/)) break
        print "[bang-backtick][P1] " F ":" NR ": closing backtick preceded by space+!"
        pos = pos + RSTART + RLENGTH - 1
      }
      # P2: opening backtick immediately followed by ! + alnum/space.
      # Same multi-match loop.
      pos = 1
      while (pos <= length(line)) {
        sub_s = substr(line, pos)
        if (!match(sub_s, /`![[:alnum:] ]/)) break
        print "[bang-backtick][P2] " F ":" NR ": opening backtick followed by ! + word/space"
        pos = pos + RSTART + RLENGTH - 1
      }
      # P3: bang-immediately-before-backtick anywhere on the line. Catches
      # the slash command parser actual !+backtick adjacency trigger
      # regardless of whether the bang sits inside an inline code span
      # (lone-bang, Rustdoc //!, cmd!) or appears as a bare !+backtick
      # prefix. P1 covers the space-before-! variant; P3 covers the
      # no-space-before-! variants (lone, suffix-of-token).
      # NOTE: comments in awk script must avoid ASCII apostrophe (single
      # quote) because the awk script is bash single-quote delimited.
      pos = 1
      while (pos <= length(line)) {
        sub_s = substr(line, pos)
        if (!match(sub_s, /!`/)) break
        print "[bang-backtick][P3] " F ":" NR ": ! immediately before backtick (parser inline-bash trigger)"
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
log "==> Total bang-backtick findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
