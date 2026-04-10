#!/usr/bin/env bash
# distributed-fix-drift-check.sh
#
# Detect "distributed fix drift" patterns in large rite-workflow procedural
# markdown files (fix.md, review.md, tech-writer.md, etc.).
#
# This is the static lint counterpart to LLM agent-based review, which has
# been observed to miss distributed/asymmetric fix patterns (PR #350 / Issue #361).
#
# Patterns:
#   1. retained-flag coverage  — `exit 1` without preceding `[CONTEXT] *_FAILED=1` emit
#   2. reason-table drift       — markdown reason table vs actual `reason=...` emit
#   3. if-wrap drift            — `cat <<'EOF' > "$tmpfile"` not wrapped by `if !`
#   4. anchor drift             — markdown `[text](path#anchor)` resolving to non-existent heading
#   5. eval-table list drift    — evaluation-order table parenthesized list vs emit
#
# Usage:
#   distributed-fix-drift-check.sh [--all] [--target FILE]... [--pattern N]
#                                  [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = drift detected, 2 = invocation error.

set -uo pipefail

REPO_ROOT=""
QUIET=0
PATTERN_FILTER=""
declare -a TARGETS=()
USE_ALL=0

# Default target set when --all is given.
DEFAULT_ALL_TARGETS=(
  "plugins/rite/commands/pr/fix.md"
  "plugins/rite/commands/pr/review.md"
  "plugins/rite/agents/tech-writer.md"
)

usage() {
  cat <<'EOF'
Usage: distributed-fix-drift-check.sh [options]

Options:
  --all              Check the default target set (fix.md, review.md, tech-writer.md)
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --pattern N        Only run pattern N (1-5). Default: all patterns.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress per-finding output (still exit non-zero on drift)
  -h, --help         Show this help

Combining --all and --target:
  --all and --target can be used together. When both are specified, the
  default target set is merged with explicitly specified targets.
  Duplicate entries are automatically deduplicated.

Exit codes:
  0  No drift detected
  1  Drift detected
  2  Invocation error (bad args, missing files)
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }
out() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target) TARGETS+=("$2"); shift 2 ;;
    --pattern) PATTERN_FILTER="$2"; shift 2 ;;
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
  TARGETS+=("${DEFAULT_ALL_TARGETS[@]}")
fi

# Deduplicate TARGETS (preserving order)
if [ "${#TARGETS[@]}" -gt 0 ]; then
  declare -A _seen=()
  declare -a _unique=()
  for _t in "${TARGETS[@]}"; do
    if [ -z "${_seen[$_t]+x}" ]; then
      _seen[$_t]=1
      _unique+=("$_t")
    fi
  done
  TARGETS=("${_unique[@]}")
  unset _seen _unique _t
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

DRIFT_COUNT_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'rm -f "$DRIFT_COUNT_FILE"' EXIT
echo 0 > "$DRIFT_COUNT_FILE"
report() {
  # report PATTERN FILE LINE MESSAGE
  local pattern="$1" file="$2" line="$3" msg="$4"
  out "[drift][P${pattern}] ${file}:${line}: ${msg}"
  local n
  n=$(<"$DRIFT_COUNT_FILE")
  echo $((n + 1)) > "$DRIFT_COUNT_FILE"
}

run_pattern() {
  local n="$1"
  [ -z "$PATTERN_FILTER" ] || [ "$PATTERN_FILTER" = "$n" ]
}

# ----- Pattern 1: retained-flag coverage -------------------------------------
# For every `exit 1` line, look at the preceding 5 lines (within the same code
# block). If none of them contain `[CONTEXT] *_FAILED=1` and the line itself is
# not inside a `trap` cleanup or a best-effort warning-only handler, flag it.
check_pattern_1() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk -v F="$file" '
    BEGIN { in_block = 0; line_no = 0 }
    {
      line_no++
      # Maintain a 5-line lookback buffer
      buf6 = buf5; buf5 = buf4; buf4 = buf3; buf3 = buf2; buf2 = buf1; buf1 = $0
      bln6 = bln5; bln5 = bln4; bln4 = bln3; bln3 = bln2; bln2 = bln1; bln1 = line_no
      if ($0 ~ /^[[:space:]]*exit 1[[:space:]]*$/) {
        # Check 5 preceding lines for retained flag emit
        has_flag = 0
        for (i = 2; i <= 6; i++) {
          v = (i==2?buf2:(i==3?buf3:(i==4?buf4:(i==5?buf5:buf6))))
          if (v ~ /\[CONTEXT\][^"]*_FAILED=1/) { has_flag = 1; break }
        }
        # Best-effort exclusions: trap cleanup or best-effort warnings
        is_excluded = 0
        for (i = 2; i <= 6; i++) {
          v = (i==2?buf2:(i==3?buf3:(i==4?buf4:(i==5?buf5:buf6))))
          if (v ~ /trap[[:space:]]/) { is_excluded = 1; break }
          if (v ~ /(best-effort|[[:space:]]+\|\|[[:space:]]+true|2>\/dev\/null)/) { is_excluded = 1; break }
        }
        if (!has_flag && !is_excluded) {
          printf "%d\n", line_no
        }
      }
    }
  ' "$file" | while read -r ln; do
    report 1 "$file" "$ln" "exit 1 without preceding [CONTEXT] *_FAILED=1 emit"
  done
}

# ----- Pattern 2: reason-table drift -----------------------------------------
# Markdown table cells like `| `reason_name` ...` vs `reason=reason_name` emits.
check_pattern_2() {
  local file="$1"
  [ -f "$file" ] || return 0
  local table_reasons emit_reasons missing extra
  table_reasons=$(awk '
    /^\| `[a-z_][a-z0-9_]*`/ {
      gsub(/[|`]/, " ")
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[a-z_][a-z0-9_]*$/) { print $i; break }
      }
    }
  ' "$file" | sort -u)
  emit_reasons=$(grep -oE 'reason=[a-z_][a-z0-9_]*' "$file" 2>/dev/null \
    | sed 's/reason=//' | sort -u)
  # If the file has no reason table at all, Pattern-2 does not apply.
  # Skipping here prevents false "never emitted" flags for emit-only files.
  [ -z "$table_reasons" ] && return 0
  # If the file has a table but no emits, all table entries are unused — still a drift,
  # so we continue through to the comm comparison below.
  # Drift = symmetric difference
  missing=$(comm -23 <(printf '%s\n' "$emit_reasons") <(printf '%s\n' "$table_reasons"))
  extra=$(comm -13 <(printf '%s\n' "$emit_reasons") <(printf '%s\n' "$table_reasons"))
  if [ -n "$missing" ]; then
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      report 2 "$file" 0 "reason '$r' emitted but not in reason table"
    done <<< "$missing"
  fi
  if [ -n "$extra" ]; then
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      report 2 "$file" 0 "reason '$r' in reason table but never emitted"
    done <<< "$extra"
  fi
}

# ----- Pattern 3: if-wrap drift ----------------------------------------------
# `cat <<'XXEOF' > "$tmpfile"` should be wrapped by `if ! cat ...; then`.
check_pattern_3() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    BEGIN { line_no = 0; prev1 = ""; curr = "" }
    {
      line_no++
      prev1 = curr; curr = $0
      if (curr ~ /cat[[:space:]]+<<[\x27]?[A-Z_]+[\x27]?[[:space:]]*>[[:space:]]*"\$tmpfile"/) {
        wrapped = 0
        if (curr ~ /^[[:space:]]*if[[:space:]]+!/) wrapped = 1
        if (prev1 ~ /^[[:space:]]*if[[:space:]]+!/ && prev1 ~ /cat/) wrapped = 1
        # Exclusions: testing/example tmpfiles inside fenced explanatory blocks
        if (!wrapped) printf "%d\n", line_no
      }
    }
  ' "$file" | while read -r ln; do
    report 3 "$file" "$ln" "cat <<'EOF' > \"\$tmpfile\" not wrapped by 'if !'"
  done
}

# ----- Pattern 4: anchor drift -----------------------------------------------
# Extract [text](path#anchor) and verify the anchor exists in path's headings,
# using GitHub's anchor conversion: lowercase, spaces->-, drop most punctuation.
github_anchor() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9 _-]//g' -e 's/ /-/g'
}

check_pattern_4() {
  local file="$1"
  [ -f "$file" ] || return 0
  local file_dir
  file_dir="$(dirname "$file")"
  # Extract markdown links with #anchor. `|| true` makes no-match explicit
  # (prevents pipefail from propagating grep exit 1 if callers enable it).
  { grep -oE '\[[^]]*\]\([^)]+\)' "$file" 2>/dev/null || true; } \
    | { grep -oE '\([^)]*#[^)]+\)' || true; } \
    | sed -e 's/^(//' -e 's/)$//' \
    | while IFS= read -r ref; do
        local target_path anchor abs_path
        target_path="${ref%%#*}"
        anchor="${ref#*#}"
        # Skip URL-style links and self-only anchors here (handled separately if needed)
        case "$target_path" in
          ""|http*|mailto:*) continue ;;
          /*) abs_path="$REPO_ROOT$target_path" ;;
          *)  abs_path="$file_dir/$target_path" ;;
        esac
        [ -f "$abs_path" ] || continue
        # Build heading anchor list
        local headings
        headings=$(grep -E '^#{1,6}[[:space:]]' "$abs_path" 2>/dev/null \
          | sed -E 's/^#+[[:space:]]+//' \
          | while IFS= read -r h; do github_anchor "$h"; done)
        # Skip files with no markdown headings (e.g. pure code files) to avoid
        # false positives where every anchor would be reported as unresolved.
        [ -z "$headings" ] && continue
        if ! grep -Fxq "$anchor" <<< "$headings"; then
          report 4 "$file" 0 "anchor '#$anchor' not found in $target_path"
        fi
      done
}

# ----- Pattern 5: eval-table parenthesized list drift ------------------------
# `( `a` / `b` / `c` )` style enumerations inside markdown tables vs actual
# `reason=...` emits in the same file.
check_pattern_5() {
  local file="$1"
  [ -f "$file" ] || return 0
  local table_words emit_reasons missing
  # Extract `xxx` words inside `( ... / ... / ... )` groups
  table_words=$(grep -oE '\([^)]*`[a-z_][a-z0-9_]*`[^)]*\)' "$file" 2>/dev/null \
    | grep -oE '`[a-z_][a-z0-9_]*`' \
    | tr -d '`' | sort -u)
  emit_reasons=$(grep -oE 'reason=[a-z_][a-z0-9_]*' "$file" 2>/dev/null \
    | sed 's/reason=//' | sort -u)
  # Short-circuit when either side is empty to avoid comm's environment-dependent
  # behavior with empty/unsorted input. A file without an eval-table or without
  # any emits is out of scope for Pattern-5.
  [ -z "$table_words" ] && return 0
  [ -z "$emit_reasons" ] && return 0
  missing=$(comm -23 <(printf '%s\n' "$emit_reasons") <(printf '%s\n' "$table_words"))
  if [ -n "$missing" ]; then
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      report 5 "$file" 0 "reason '$r' emitted but not in eval-table parenthesized list"
    done <<< "$missing"
  fi
}

for file in "${TARGETS[@]}"; do
  log "Checking $file ..."
  run_pattern 1 && check_pattern_1 "$file"
  run_pattern 2 && check_pattern_2 "$file"
  run_pattern 3 && check_pattern_3 "$file"
  run_pattern 4 && check_pattern_4 "$file"
  run_pattern 5 && check_pattern_5 "$file"
done

DRIFT_COUNT=$(<"$DRIFT_COUNT_FILE")
if [ "$DRIFT_COUNT" -gt 0 ]; then
  log "==> Total drift findings: $DRIFT_COUNT"
  exit 1
fi
log "==> No drift detected"
exit 0
