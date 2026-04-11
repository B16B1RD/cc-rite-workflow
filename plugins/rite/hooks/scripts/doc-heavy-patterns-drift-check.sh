#!/usr/bin/env bash
# doc-heavy-patterns-drift-check.sh
#
# Detect drift in `doc_file_patterns` across 3 files that MUST agree on the
# same set of glob tokens for tech-writer Activation / Doc-Heavy PR detection:
#
#   1. plugins/rite/skills/reviewers/tech-writer.md  (Activation section;
#      treated as the source of truth)
#   2. plugins/rite/commands/pr/review.md            (Phase 1.2.7
#      `doc_file_patterns` pseudo-code block)
#   3. plugins/rite/skills/reviewers/SKILL.md        (Reviewers table,
#      Technical Writer row)
#
# Issue #353 covers 系統 1 of the drift invariants catalogued in
# commands/pr/references/internal-consistency.md. 系統 2 (canonical category
# name literal match) and 系統 3 (review.md Phase 5.4 Doc-Heavy section 2-place
# duplication) are out of scope for this checker.
#
# The 3 files encode the same pattern list in 3 different textual forms (list
# with backticks / pseudo-code without backticks / Markdown table cell). This
# checker does NOT compare the raw text — it extracts glob tokens per file and
# compares the resulting sets. Syntactic differences (ordering, spacing, line
# breaks) are tolerated by design; only set-level drift is reported.
#
# --- Token extraction contract -----------------------------------------------
#
# A glob token is any substring matching the POSIX regex
#   [A-Za-z0-9/._-]*\*[A-Za-z0-9/._*-]*
# of length >= 3 characters (to exclude bare `*` / `**` artifacts). Tokens are
# extracted from a constrained section of each file so that unrelated glob-like
# text elsewhere in the file (other skills, other pseudo-code, Note paragraphs
# that repeat pattern examples) does NOT bleed into the comparison:
#
#   tech-writer.md : only lines starting with `- ` between `## Activation` and
#                    `### Conditional Activation`. The intro sentence and Note
#                    paragraphs within the section are deliberately skipped
#                    because they re-state patterns in prose form.
#   review.md      : only lines strictly between `doc_file_patterns = [` and
#                    the subsequent closing `]` at column 0.
#   SKILL.md       : only the single table row that begins with
#                    `| Technical Writer |`.
#
# Drift reporting is based on pairwise set difference (`comm -23`) across all 3
# pairs. Every token present in only one file of a pair is emitted as a
# finding. Exit code 1 when any finding is emitted, 0 when all 3 sets are
# identical.
#
# Usage:
#   doc-heavy-patterns-drift-check.sh --all [--repo-root DIR] [--quiet]
#
# Exit codes:
#   0  No drift detected across the 3 files
#   1  Drift detected (symmetric set difference non-empty)
#   2  Invocation error (bad args, missing files, empty section)

set -uo pipefail

REPO_ROOT=""
QUIET=0
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: doc-heavy-patterns-drift-check.sh --all [options]

Options:
  --all              Scan the 3 canonical doc_file_patterns files
                     (tech-writer.md / review.md / SKILL.md) under plugins/rite/.
                     This is the only supported mode; the 3-file invariant
                     has no meaning for arbitrary targets.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr
                     (per-finding output on stdout is preserved)
  -h, --help         Show this help

Exit codes:
  0  No drift detected across the 3 files
  1  Drift detected (symmetric set difference non-empty)
  2  Invocation error (bad args, missing files, empty section)
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$USE_ALL" -ne 1 ]; then
  echo "ERROR: --all is required (doc_file_patterns drift is a fixed 3-file check)" >&2
  usage >&2
  exit 2
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

TW_FILE="plugins/rite/skills/reviewers/tech-writer.md"
REVIEW_FILE="plugins/rite/commands/pr/review.md"
SKILL_FILE="plugins/rite/skills/reviewers/SKILL.md"

for f in "$TW_FILE" "$REVIEW_FILE" "$SKILL_FILE"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    echo "  Likely cause: invoked outside the rite plugin source tree (e.g. marketplace install layout)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --repo-root pointing there" >&2
    exit 2
  fi
done

WORK_DIR="$(mktemp -d)" || { echo "ERROR: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Section extractors ------------------------------------------------------

# tech-writer.md: list items (`- ...`) between `## Activation` and
# `### Conditional Activation`. The Note paragraphs inside the section
# re-state patterns in prose and would otherwise pollute the token set with
# duplicates and bare `i18n/**`-style fragments — exclude them by gating on the
# list-item marker.
extract_tw() {
  awk '
    /^## Activation/ { in_sec = 1; next }
    /^### Conditional Activation/ { in_sec = 0 }
    in_sec && /^- / { print }
  ' "$TW_FILE"
}

# review.md: the Phase 1.2.7 pseudo-code block between `doc_file_patterns = [`
# and the next line consisting of `]` at column 0.
extract_review() {
  awk '
    /^doc_file_patterns = \[/ { in_sec = 1; next }
    in_sec && /^\]/ { in_sec = 0; next }
    in_sec { print }
  ' "$REVIEW_FILE"
}

# SKILL.md: the single Technical Writer row of the Reviewers table.
extract_skill() {
  grep -E '^\| Technical Writer \|' "$SKILL_FILE"
}

# --- Token extraction --------------------------------------------------------
#
# awk scans each line and emits every substring matching the glob-token regex
# of length >= 3. The while/match/substr idiom (rather than a one-shot match)
# captures multiple tokens per line (e.g. `- \`docs/**\`, \`documentation/**\`
# ` yields two tokens).
extract_tokens() {
  awk '
    {
      line = $0
      pos = 1
      while (pos <= length(line)) {
        sub_s = substr(line, pos)
        if (!match(sub_s, /[A-Za-z0-9/._-]*\*[A-Za-z0-9/._*-]*/)) break
        tok = substr(sub_s, RSTART, RLENGTH)
        if (length(tok) >= 3) print tok
        pos = pos + RSTART + RLENGTH
        if (RLENGTH == 0) pos = pos + 1
      }
    }
  '
}

# --- Normalization -----------------------------------------------------------
normalize_set() {
  sort -u
}

# --- Run extractors ----------------------------------------------------------

extract_tw     | extract_tokens | normalize_set > "$WORK_DIR/tw.set"
extract_review | extract_tokens | normalize_set > "$WORK_DIR/review.set"
extract_skill  | extract_tokens | normalize_set > "$WORK_DIR/skill.set"

tw_count=$(wc -l < "$WORK_DIR/tw.set")
review_count=$(wc -l < "$WORK_DIR/review.set")
skill_count=$(wc -l < "$WORK_DIR/skill.set")

log "tech-writer.md   : ${tw_count} glob tokens"
log "review.md        : ${review_count} glob tokens"
log "SKILL.md         : ${skill_count} glob tokens"

# Each section is expected to define at least 10 glob tokens (the canonical
# list has 18 as of this writing). An empty or undersized set almost always
# means the section markers changed and extraction fell off the end, so fail
# fast with an invocation error rather than silently reporting a large drift.
for kv in "tech-writer.md:${tw_count}" "review.md:${review_count}" "SKILL.md:${skill_count}"; do
  file="${kv%:*}"
  count="${kv##*:}"
  if [ "$count" -lt 10 ]; then
    echo "ERROR: $file extracted only $count glob tokens (expected >= 10)" >&2
    echo "  Likely cause: section markers changed and extractor fell through" >&2
    echo "  Recovery: inspect the section boundaries in doc-heavy-patterns-drift-check.sh" >&2
    exit 2
  fi
done

# --- Diff report -------------------------------------------------------------

diff_count=0

report_diff() {
  local a="$1" a_label="$2" b="$3" b_label="$4"
  local only_in_a
  only_in_a=$(comm -23 "$a" "$b")
  if [ -n "$only_in_a" ]; then
    echo "[doc-heavy-patterns-drift] only in ${a_label} (missing in ${b_label}):"
    while IFS= read -r tok; do
      echo "  - ${tok}"
      diff_count=$((diff_count + 1))
    done <<< "$only_in_a"
  fi
}

report_diff "$WORK_DIR/tw.set"     "tech-writer.md Activation" \
            "$WORK_DIR/review.set" "review.md Phase 1.2.7 doc_file_patterns"
report_diff "$WORK_DIR/review.set" "review.md Phase 1.2.7 doc_file_patterns" \
            "$WORK_DIR/tw.set"     "tech-writer.md Activation"

report_diff "$WORK_DIR/tw.set"     "tech-writer.md Activation" \
            "$WORK_DIR/skill.set"  "SKILL.md Technical Writer row"
report_diff "$WORK_DIR/skill.set"  "SKILL.md Technical Writer row" \
            "$WORK_DIR/tw.set"     "tech-writer.md Activation"

report_diff "$WORK_DIR/review.set" "review.md Phase 1.2.7 doc_file_patterns" \
            "$WORK_DIR/skill.set"  "SKILL.md Technical Writer row"
report_diff "$WORK_DIR/skill.set"  "SKILL.md Technical Writer row" \
            "$WORK_DIR/review.set" "review.md Phase 1.2.7 doc_file_patterns"

log "==> Total doc-heavy-patterns-drift findings: ${diff_count}"

if [ "$diff_count" -gt 0 ]; then
  exit 1
fi
exit 0
