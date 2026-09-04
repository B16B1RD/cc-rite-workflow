#!/usr/bin/env bash
# reviewer-registry-drift-check.sh
#
# Detect drift across the 3 places that MUST stay in sync when a reviewer is
# added to (or removed from) the rite reviewer registry:
#
#   1. plugins/rite/agents/*-reviewer.md            (named-subagent profile
#      files — one per reviewer; `_reviewer-base.md` is shared principles,
#      not a reviewer, and is excluded by the `*-reviewer.md` glob)
#   2. plugins/rite/skills/reviewers/SKILL.md       `## Available Reviewers`
#      table (Agent column — file-pattern-driven reviewers)
#   3. plugins/rite/skills/reviewers/SKILL.md       `## Reviewer Type
#      Identifiers` table (reviewer_type slug + Agent column — ALL reviewers)
#
# Invariants checked (see CONTRIBUTING.md "Adding a New Reviewer"):
#
#   I1  agents/ file set == Type Identifiers table Agent set (bidirectional).
#       An agent profile without a Type Identifiers row is unreachable
#       (`rite:{type}-reviewer` cannot be display-name-resolved); a row
#       without a profile spawns a nonexistent subagent.
#   I2  Available Reviewers table Agent set ⊆ Type Identifiers table Agent
#       set. The reverse direction is intentionally NOT checked: reviewers
#       selected by logic instead of file patterns (e.g. code-quality, the
#       fallback / co-reviewer) have no Available Reviewers row by design.
#   I3  Each Type Identifiers row satisfies `{reviewer_type}-reviewer.md` ==
#       Agent cell. The slug is how `skills/pr-review/SKILL.md` derives the
#       subagent name, so a mismatched cell silently breaks spawning.
#
# Keyword-driven activation lists in `skills/pr-review/SKILL.md` ステップ 2.3 are
# free-form prose and are NOT machine-checked here; the CONTRIBUTING.md
# procedure covers them as a manual checklist item.
#
# Token extraction is constrained to table rows (`|`-prefixed lines) inside
# each `## `-delimited section so prose that mentions agent filenames (Notes,
# cross-references) does not bleed into the comparison.
#
# Usage:
#   reviewer-registry-drift-check.sh --all [--repo-root DIR] [--quiet]
#
# Exit codes:
#   0  No drift detected across the 3 sync points (or not applicable —
#      invoked outside the rite plugin source tree, e.g. marketplace/consumer
#      install)
#   1  Drift detected (any invariant violated)
#   2  Invocation error (bad args, empty extraction)

# `-e` is intentionally omitted: a `-euo` "correction" would let a no-match
# grep pipeline (rc=1) inside a pre-guard block kill the script before the
# >= N extraction guard runs, misclassifying an invocation error (rc=2
# contract) as drift detected (rc=1).
set -uo pipefail

REPO_ROOT=""
QUIET=0
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: reviewer-registry-drift-check.sh --all [options]

Options:
  --all              Check the canonical reviewer registry sync points
                     (agents/ directory + reviewers/SKILL.md 2 tables).
                     This is the only supported mode; the invariant
                     has no meaning for arbitrary targets.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr
                     (per-finding output on stdout is preserved)
  -h, --help         Show this help

Exit codes:
  0  No drift detected across the 3 sync points (or not applicable)
  1  Drift detected (any invariant violated)
  2  Invocation error (bad args, empty extraction)
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --repo-root)
      # Consume-before-validate would hit `set -u` unbound $2 and exit 1,
      # misclassifying bad args as "drift detected" — keep bad args on exit 2.
      [ $# -ge 2 ] || { echo "ERROR: --repo-root requires a value" >&2; usage >&2; exit 2; }
      REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$USE_ALL" -ne 1 ]; then
  echo "ERROR: --all is required (reviewer registry drift is a fixed 3-point check)" >&2
  usage >&2
  exit 2
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

AGENTS_DIR="plugins/rite/agents"
SKILL_FILE="plugins/rite/skills/reviewers/SKILL.md"

if [ ! -d "$AGENTS_DIR" ] && [ ! -f "$SKILL_FILE" ]; then
  # Neither registry sync point exists: this is not the rite plugin source
  # tree (e.g. a consumer repo that installs rite as a marketplace plugin
  # only, with no plugins/rite/ registry to check). Treat as a clean skip
  # rather than an invocation error, matching bang-backtick-check.sh's
  # --skip-if-no-target precedent — this check has nothing to compare.
  log "[reviewer-registry-drift] not applicable: neither $AGENTS_DIR nor $SKILL_FILE found under $REPO_ROOT — clean skip"
  exit 0
fi

if [ ! -d "$AGENTS_DIR" ]; then
  echo "ERROR: required directory not found: $AGENTS_DIR" >&2
  echo "  Likely cause: partial checkout, or the directory was moved/renamed without updating this checker" >&2
  echo "  Recovery: verify both $AGENTS_DIR and $SKILL_FILE exist, or pass --repo-root pointing to a complete rite plugin source tree" >&2
  exit 2
fi
if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: required file not found: $SKILL_FILE" >&2
  echo "  Likely cause: partial checkout, or the file was moved/renamed without updating this checker" >&2
  echo "  Recovery: verify both $AGENTS_DIR and $SKILL_FILE exist, or pass --repo-root pointing to a complete rite plugin source tree" >&2
  exit 2
fi

# Canonical signal-specific trap pattern (repo convention — see
# references/bash-trap-patterns.md): declare path before mktemp,
# set trap before mktemp, and guard the cleanup with ${var:-} so an early
# signal (between path declaration and mktemp completion) cannot dereference
# an unset variable. Signals return conventional exit codes (INT=130,
# TERM=143, HUP=129) so callers can distinguish the cause.
WORK_DIR=""
_cleanup() {
  [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

WORK_DIR="$(mktemp -d)" || { echo "ERROR: mktemp -d failed" >&2; exit 2; }

# --- Section extractor ---------------------------------------------------
#
# Emit only the table rows (`|`-prefixed lines) of the `## `-section whose
# heading matches $1, so agent filenames mentioned in surrounding prose do
# not bleed into the sets.
extract_section_rows() {
  local heading="$1"
  awk -v h="## ${heading}" '
    $0 == h { in_sec = 1; next }
    in_sec && /^## / { in_sec = 0 }
    in_sec && /^\|/ { print }
  ' "$SKILL_FILE"
}

# --- Set extraction -------------------------------------------------------
#
# Agent filename tokens are `{type}-reviewer.md` (lowercase + hyphens +
# digits). The leading `[a-z]` excludes `_reviewer-base.md`-style shared
# files, and header / separator rows contain no such token so they drop out
# naturally. `[a-z0-9-]*` (not `[a-z-]*`) so digit-bearing slugs (e.g.
# `web3-reviewer.md`) are captured instead of silently dropping out of all 3
# sets + the I3 row filter (which would let that reviewer's drift pass with
# rc=0). `[.]` (not `\.`) keeps the regex portable between grep -E and awk -v,
# where the latter would re-interpret the backslash and warn.
AGENT_RE='[a-z][a-z0-9-]*-reviewer[.]md'

# Set 1: agent profile files on disk. find's stderr is captured (not
# discarded) so a real access error (e.g. EACCES) surfaces instead of being
# indistinguishable from "no matching files".
find "$AGENTS_DIR" -maxdepth 1 -name '*-reviewer.md' -type f 2>"$WORK_DIR/find.err" \
  | while IFS= read -r f; do basename "$f"; done \
  | grep -E "^${AGENT_RE}$" \
  | sort -u > "$WORK_DIR/agents.set"

# Set 2: Available Reviewers table Agent column.
extract_section_rows "Available Reviewers" \
  | grep -oE "$AGENT_RE" | sort -u > "$WORK_DIR/available.set"

# Set 3: Reviewer Type Identifiers table Agent column. Rows are cached to
# identifiers.rows so the I3 check below reuses them instead of re-invoking
# extract_section_rows (which re-parses SKILL_FILE with awk).
extract_section_rows "Reviewer Type Identifiers" > "$WORK_DIR/identifiers.rows"
grep -oE "$AGENT_RE" "$WORK_DIR/identifiers.rows" | sort -u > "$WORK_DIR/identifiers.set"

# Arithmetic expansion strips the leading blanks BSD `wc` pads its output with;
# these counts go straight into human-facing diagnostics below, so on macOS the
# raw form reads as `extracted only        0 reviewers`.
agents_count=$(( $(wc -l < "$WORK_DIR/agents.set") ))
available_count=$(( $(wc -l < "$WORK_DIR/available.set") ))
identifiers_count=$(( $(wc -l < "$WORK_DIR/identifiers.set") ))

log "agents/ profiles           : ${agents_count} reviewers"
log "Available Reviewers table  : ${available_count} reviewers"
log "Type Identifiers table     : ${identifiers_count} reviewers"

# Each sync point is expected to hold at least 6 reviewers (the registry has
# 8-9 as of this writing — 9 agents / Type Identifiers rows, 8 Available
# Reviewers rows after the consolidation). An empty or undersized set
# almost always means
# extraction fell through, so fail fast with an invocation error rather than
# silently reporting a large drift. The likely cause differs by source: the
# agents/ directory is a find + glob over the filesystem (unrelated to
# SKILL.md headings), while the 2 table sources depend on section boundaries
# in SKILL_FILE — so each gets its own diagnostic instead of one shared
# "heading changed" message that would misdirect for the agents/ source.
for kv in "${AGENTS_DIR}:${agents_count}" \
          "Available-Reviewers-table:${available_count}" \
          "Type-Identifiers-table:${identifiers_count}"; do
  src="${kv%:*}"
  count="${kv##*:}"
  if [ "$count" -lt 6 ]; then
    echo "ERROR: $src extracted only $count reviewers (expected >= 6)" >&2
    case "$src" in
      "$AGENTS_DIR")
        echo "  Likely cause: directory renamed/moved, agent filenames no longer match *-reviewer.md, or the directory is unreadable" >&2
        if [ -s "$WORK_DIR/find.err" ]; then
          echo "  find stderr:" >&2
          sed 's/^/    /' "$WORK_DIR/find.err" >&2
        fi
        echo "  Recovery: verify $AGENTS_DIR exists, check its permissions, and confirm agent filenames match *-reviewer.md" >&2
        ;;
      *)
        echo "  Likely cause: section heading or table format changed and extraction fell through" >&2
        echo "  Recovery: inspect the section boundaries in reviewer-registry-drift-check.sh" >&2
        ;;
    esac
    exit 2
  fi
done

# --- Diff report -----------------------------------------------------------

diff_count=0

report_diff() {
  local a="$1" a_label="$2" b="$3" b_label="$4"
  local only_in_a
  only_in_a=$(comm -23 "$a" "$b")
  if [ -n "$only_in_a" ]; then
    echo "[reviewer-registry-drift] only in ${a_label} (missing in ${b_label}):"
    while IFS= read -r tok; do
      echo "  - ${tok}"
      diff_count=$((diff_count + 1))
    done <<< "$only_in_a"
  fi
}

# I1: agents/ files <-> Type Identifiers table (bidirectional).
report_diff "$WORK_DIR/agents.set"      "${AGENTS_DIR}/ profiles" \
            "$WORK_DIR/identifiers.set" "Type Identifiers table"
report_diff "$WORK_DIR/identifiers.set" "Type Identifiers table" \
            "$WORK_DIR/agents.set"      "${AGENTS_DIR}/ profiles"

# I2: Available Reviewers table -> Type Identifiers table (one direction only;
# logic-selected reviewers like code-quality legitimately have no pattern row).
report_diff "$WORK_DIR/available.set"   "Available Reviewers table" \
            "$WORK_DIR/identifiers.set" "Type Identifiers table"

# I3: reviewer_type slug consistency within each Type Identifiers row.
# Columns: | reviewer_type | 日本語表示名 | Agent |  ->  $2=slug, $4=agent.
# The positional parse silently no-ops if a table-format change (e.g. a column
# inserted before Agent) shifts the agent token away from $4 — every row would
# fail the regex filter, get skipped, and the check would false-pass with
# exit 0. Count the rows that pass the filter and fail fast when the count
# collapses, symmetric with the >= 6 set-extraction guard above.
# Reuses identifiers.rows (cached above) instead of re-invoking
# extract_section_rows, which would re-parse SKILL_FILE with awk a second time.
i3_out=$(awk -F'|' -v re="^${AGENT_RE}$" '
  {
    slug = $2; agent = $4
    gsub(/[[:space:]`]/, "", slug)
    gsub(/[[:space:]`]/, "", agent)
    if (agent !~ re) next   # header / separator rows carry no agent token
    checked++
    expected = slug "-reviewer.md"
    if (expected != agent)
      printf "  - slug %s expects %s but Agent cell is %s\n", slug, expected, agent
  }
  END { printf "I3_CHECKED=%d\n", checked }
' "$WORK_DIR/identifiers.rows")
i3_checked=$(printf '%s\n' "$i3_out" | sed -n 's/^I3_CHECKED=//p')
slug_findings=$(printf '%s\n' "$i3_out" | grep -v '^I3_CHECKED=' || true)
if [ "${i3_checked:-0}" -lt 6 ]; then
  echo "ERROR: I3 slug check evaluated only ${i3_checked:-0} rows (expected >= 6)" >&2
  echo "  Likely cause: Type Identifiers table format changed (Agent cell no longer in column 4)" >&2
  echo "  Recovery: inspect the I3 column positions in reviewer-registry-drift-check.sh" >&2
  exit 2
fi
if [ -n "$slug_findings" ]; then
  echo "[reviewer-registry-drift] Type Identifiers slug/Agent mismatch:"
  printf '%s\n' "$slug_findings"
  slug_count=$(printf '%s\n' "$slug_findings" | wc -l)
  diff_count=$((diff_count + slug_count))
fi

log "==> Total reviewer-registry-drift findings: ${diff_count}"

if [ "$diff_count" -gt 0 ]; then
  exit 1
fi
exit 0
