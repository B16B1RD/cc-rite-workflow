#!/usr/bin/env bash
# sentinel-contract-check.sh
#
# Detect drift between the sentinel SoT (plugins/rite/references/sentinel-contract.md
# `## Sentinel 一覧` table) and the actual emitter/consumer skill files under
# plugins/rite/skills/. Sentinels (`[skill:action]` literal strings) are the
# implicit string-matching contract sub-skills use to hand off control; a
# rename in one file without the others causes silent orchestration breakage
# that only surfaces at runtime.
#
# Invariants checked:
#   I1  Each SoT-declared sentinel's literal string is present in its
#       declared Emitter skill's SKILL.md (orphan SoT entry otherwise).
#   I2  Each SoT-declared sentinel's literal string is present in each of its
#       declared Consumer skills' SKILL.md (drifted consumer otherwise).
#       Sentinels whose Consumer cell is a parenthetical note (e.g.
#       "(run 内部完結)", "(terminal、consumer なし)") have no external
#       consumer to check and are skipped for I2.
#   I3  Every sentinel-shaped literal (`[a-z...:a-z0-9...]`) found under
#       plugins/rite/skills/ (recursive, *.md) or directly under
#       plugins/rite/hooks/ (*.sh, non-recursive — hook helper scripts that
#       emit sentinels at runtime, e.g. review-comment-post.sh) is declared
#       in the SoT (after normalizing a trailing numeric segment, e.g.
#       `:123]` -> `:N]`), except for the fixed NON_SENTINEL_DENYLIST
#       (documented non-sentinel look-alikes — see sentinel-contract.md
#       "Non-Sentinel な類似記法"). hooks/scripts/ and hooks/tests/ are
#       intentionally excluded from the hooks/ scan — they hold lint-check
#       utilities and test fixtures, not runtime sentinel emitters, and
#       scanning them pulls in unrelated bracket-literal examples in
#       comments/test data (§2 In Scope: "SoT と skills/hooks
#       実体の一致を検証").
#
# Usage:
#   sentinel-contract-check.sh --all [--repo-root DIR] [--quiet]
#
# Exit codes:
#   0  No drift detected (or not applicable — SoT file absent, e.g. a
#      consumer repo installing rite as a marketplace plugin only)
#   1  Drift detected (any invariant violated)
#   2  Invocation error (bad args, SoT file malformed)

# `-e` intentionally omitted: a no-match grep (rc=1) inside a pre-guard block
# must not abort the script before its own exit-code contract routes it —
# same rationale as reviewer-registry-drift-check.sh.
set -uo pipefail

REPO_ROOT=""
QUIET=0
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: sentinel-contract-check.sh --all [options]

Options:
  --all              Check the canonical sentinel SoT sync points
                     (references/sentinel-contract.md <-> skills/**/*.md).
                     This is the only supported mode; the invariant has no
                     meaning for arbitrary targets.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr
                     (per-finding output on stdout is preserved)
  -h, --help         Show this help

Exit codes:
  0  No drift detected (or not applicable)
  1  Drift detected (any invariant violated)
  2  Invocation error (bad args, SoT file malformed)
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --repo-root)
      [ $# -ge 2 ] || { echo "ERROR: --repo-root requires a value" >&2; usage >&2; exit 2; }
      REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$USE_ALL" -ne 1 ]; then
  echo "ERROR: --all is required (sentinel contract drift is a fixed sync-point check)" >&2
  usage >&2
  exit 2
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

SOT_FILE="plugins/rite/references/sentinel-contract.md"
SKILLS_DIR="plugins/rite/skills"
HOOKS_DIR="plugins/rite/hooks"

if [ ! -f "$SOT_FILE" ] && [ ! -d "$SKILLS_DIR" ]; then
  # Consumer repo installing rite as a marketplace plugin only (no
  # plugins/rite/ source tree) — nothing to compare, clean skip. Same
  # precedent as reviewer-registry-drift-check.sh / bang-backtick-check.sh.
  log "[sentinel-contract] not applicable: neither $SOT_FILE nor $SKILLS_DIR found under $REPO_ROOT — clean skip"
  exit 0
fi

if [ ! -f "$SOT_FILE" ]; then
  echo "ERROR: required file not found: $SOT_FILE" >&2
  echo "  Likely cause: the SoT file was moved/renamed without updating this checker" >&2
  exit 2
fi
if [ ! -d "$SKILLS_DIR" ]; then
  echo "ERROR: required directory not found: $SKILLS_DIR" >&2
  exit 2
fi

# Denylist of documented non-sentinel bracket look-alikes (must stay in sync
# with sentinel-contract.md "Non-Sentinel な類似記法" section). Only entries
# reachable within the I3 scan scope (*.md under plugins/rite/skills/) belong
# here — e.g. generic placeholder names used only in hooks/tests/*.sh fixtures
# are already out of scope and would never need a denylist entry.
NON_SENTINEL_DENYLIST=(
  "[file:line]"
  "[tag:value]"
)

# --- Signal-specific trap (canonical pattern, references/bash-trap-patterns.md) ---
WORK_DIR=""
_cleanup() {
  [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

if ! WORK_DIR=$(mktemp -d 2>/dev/null); then
  echo "ERROR: mktemp -d failed (disk full / permission denied?)" >&2
  exit 2
fi

# --- Step 1: extract the SoT table rows within "## Sentinel 一覧" section ---
sed -n '/^## Sentinel 一覧/,/^## /p' "$SOT_FILE" | grep -E '^\| `\[' > "$WORK_DIR/sot_rows.txt" || true

n_rows=$(wc -l < "$WORK_DIR/sot_rows.txt" | tr -d '[:space:]')
if [ "${n_rows:-0}" -eq 0 ]; then
  echo "ERROR: no sentinel rows extracted from $SOT_FILE (## Sentinel 一覧 section empty or malformed)" >&2
  exit 2
fi

n_findings=0
: > "$WORK_DIR/sot_sentinels.txt"

while IFS='|' read -r _ sentinel_cell emitter_cell consumer_cell _rest; do
  sentinel=$(printf '%s' "$sentinel_cell" | sed -E 's/^[[:space:]]*`(\[[^]]+\])`[[:space:]]*$/\1/')
  emitter=$(printf '%s' "$emitter_cell" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  consumer=$(printf '%s' "$consumer_cell" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

  printf '%s\n' "$sentinel" >> "$WORK_DIR/sot_sentinels.txt"

  # I1: emitter file must contain the sentinel. Numbered sentinels (":N]"
  # suffix) are checked with a pattern match instead of a literal grep,
  # because the emitter's own SKILL.md documents the emitted value with a
  # bash-substitution placeholder (e.g. "{pr_number}"), not the literal "N"
  # — "N" is a consumer-side documentation convention for "any number"
  # (see sentinel-contract.md "Numbered Sentinel" note).
  emitter_file="$SKILLS_DIR/$emitter/SKILL.md"
  if [ ! -f "$emitter_file" ]; then
    echo "FAIL: $sentinel declares emitter '$emitter' but $emitter_file does not exist"
    n_findings=$((n_findings + 1))
  else
    case "$sentinel" in
      *:N\])
        prefix="${sentinel%N]}"
        prefix_escaped=$(printf '%s' "$prefix" | sed -E 's/[][\.^$*+?(){}|]/\\&/g')
        pattern="${prefix_escaped}(\\{[A-Za-z_]+\\}|[0-9]+|N)\\]"
        if ! grep -qE -- "$pattern" "$emitter_file"; then
          echo "FAIL: $sentinel not found (pattern: $pattern) in declared emitter $emitter_file"
          n_findings=$((n_findings + 1))
        fi
        ;;
      *)
        if ! grep -qF -- "$sentinel" "$emitter_file"; then
          echo "FAIL: $sentinel not found (literal) in declared emitter $emitter_file"
          n_findings=$((n_findings + 1))
        fi
        ;;
    esac
  fi

  # I2: each declared consumer must literally contain the sentinel.
  # Parenthetical cells ("(run 内部完結)", "(terminal、consumer なし)", etc.)
  # denote no external consumer to verify.
  case "$consumer" in
    \(*\))
      : # no external consumer — I2 not applicable
      ;;
    *)
      IFS=',' read -ra consumer_list <<< "$consumer"
      for c in "${consumer_list[@]}"; do
        c=$(printf '%s' "$c" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        [ -z "$c" ] && continue
        consumer_file="$SKILLS_DIR/$c/SKILL.md"
        if [ ! -f "$consumer_file" ]; then
          echo "FAIL: $sentinel declares consumer '$c' but $consumer_file does not exist"
          n_findings=$((n_findings + 1))
        elif ! grep -qF -- "$sentinel" "$consumer_file"; then
          echo "FAIL: $sentinel not found (literal) in declared consumer $consumer_file"
          n_findings=$((n_findings + 1))
        fi
      done
      ;;
  esac
done < "$WORK_DIR/sot_rows.txt"

# --- Step 2 (I3): scan for undeclared sentinel-shaped literals ---
# Colon-required, lowercase-start pattern excludes `[CONTEXT]`/`[DEBUG]` (upper
# first letter) and bare regex character classes (no colon) by construction.
#
# grep exit code is captured directly (no pipe) so a genuine scan failure
# (permission denied / corrupt symlink / grep implementation error, rc > 1)
# is distinguished from a legitimate no-match (rc=1) and does not silently
# collapse to "0 findings" — I1/I2 above already guard their own extraction
# this way via the `n_rows -eq 0` check; I3 lacked the symmetric guard.
grep -rn --include='*.md' -oE '\[[a-z][a-z_-]*:[a-zA-Z0-9_:-]*\]' "$SKILLS_DIR" \
  > "$WORK_DIR/found_raw_lines.txt" 2>"$WORK_DIR/scan.err"
scan_rc=$?
if [ "$scan_rc" -gt 1 ]; then
  echo "ERROR: scan of $SKILLS_DIR for undeclared sentinel-shaped literals failed (rc=$scan_rc)" >&2
  echo "  $(cat "$WORK_DIR/scan.err" 2>/dev/null)" >&2
  exit 2
fi

# Also scan runtime hook helper scripts directly under $HOOKS_DIR (non-recursive
# — hooks/scripts/ and hooks/tests/ are lint-check utilities and test fixtures,
# not sentinel emitters, and are intentionally excluded; see I3 doc comment
# above). Guarded by `-d` since a marketplace-consumer repo may lack this dir
# even when $SKILLS_DIR is present (defense-in-depth, not expected in this repo).
if [ -d "$HOOKS_DIR" ]; then
  grep -n -oE '\[[a-z][a-z_-]*:[a-zA-Z0-9_:-]*\]' "$HOOKS_DIR"/*.sh \
    >> "$WORK_DIR/found_raw_lines.txt" 2>"$WORK_DIR/hooks_scan.err"
  hooks_scan_rc=$?
  if [ "$hooks_scan_rc" -gt 1 ]; then
    echo "ERROR: scan of $HOOKS_DIR/*.sh for undeclared sentinel-shaped literals failed (rc=$hooks_scan_rc)" >&2
    echo "  $(cat "$WORK_DIR/hooks_scan.err" 2>/dev/null)" >&2
    exit 2
  fi
fi
# Split each `file:line:[token]` grep -n hit into a `file:line<TAB>[token]` pair
# (file/line prefix is separated from the token by the first two colons; the
# token itself may contain further colons, e.g. `[skill:action:123]`).
sed -E 's/^([^:]+:[0-9]+):/\1\t/' "$WORK_DIR/found_raw_lines.txt" > "$WORK_DIR/found_with_loc.txt"

# Normalize a trailing numeric segment to N (e.g. [pr:created:123] -> [pr:created:N])
# so concrete example instances collapse onto their canonical SoT form, while
# keeping the first-seen file:line per normalized token so a FAIL message can
# report a concrete location (§4.5: "FAIL + 該当ファイル:行を報告").
awk -F'\t' '{ token = $2; sub(/:[0-9]+\]$/, ":N]", token); if (!(token in loc)) { loc[token] = $1; order[++n] = token } }
  END { for (i = 1; i <= n; i++) print order[i] "\t" loc[order[i]] }' \
  "$WORK_DIR/found_with_loc.txt" > "$WORK_DIR/found_normalized_with_loc.txt"

sort -u "$WORK_DIR/sot_sentinels.txt" > "$WORK_DIR/sot_sentinels_sorted.txt"

while IFS=$'\t' read -r tok loc; do
  [ -z "$tok" ] && continue
  is_denied=0
  for d in "${NON_SENTINEL_DENYLIST[@]}"; do
    [ "$tok" = "$d" ] && { is_denied=1; break; }
  done
  [ "$is_denied" -eq 1 ] && continue
  if ! grep -qxF -- "$tok" "$WORK_DIR/sot_sentinels_sorted.txt"; then
    echo "FAIL: undeclared sentinel-shaped literal found: $tok at $loc (not in $SOT_FILE)"
    n_findings=$((n_findings + 1))
  fi
done < "$WORK_DIR/found_normalized_with_loc.txt"

log "[sentinel-contract] checked $n_rows SoT sentinel(s)"
log "==> Total sentinel-contract findings: ${n_findings}"

if [ "$n_findings" -gt 0 ]; then
  exit 1
fi
exit 0
