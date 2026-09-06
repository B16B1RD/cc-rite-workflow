#!/usr/bin/env bash
# fix-report-diff-gate.sh
#
# Confirm that each action:fix finding in the latest fix-cycle-state cycle
# names a path:line (or path:start-end) that actually appears in
# `git diff -U0 <commit_sha_before>..HEAD`. One overlapping line with a +
# hunk is enough. A pure-delete hunk (no + side) is matched per hunk against
# the old-file line range, since a deleted line has no HEAD line to cite.
#
# reply / accept / nit-noted are out of scope: they are not verified and
# must not gain a diff_verified key.
#
# Writes diff_verified back onto the latest cycle only.
#
# Usage:
#   bash fix-report-diff-gate.sh --state-file PATH [--repo-root DIR]
#   bash fix-report-diff-gate.sh --pr N [--repo-root DIR]
#
# Marker (stderr):
#   [CONTEXT] FIX_REPORT_DIFF_GATE=passed; verified=N; unverified=0
#   [CONTEXT] FIX_REPORT_DIFF_GATE=unverified; verified=N; unverified=M; ids=F-01,F-03
#   [CONTEXT] FIX_REPORT_DIFF_GATE=error; reason=map_missing|state_unreadable|diff_failed|jq_missing
#
# Exit:
#   0  passed or unverified
#   1  error (map_missing / state_unreadable / diff_failed / jq_missing)
#   2  usage

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_FILE=""
PR_NUMBER=""
REPO_ROOT=""

usage() {
  cat <<'EOF'
Usage: fix-report-diff-gate.sh --state-file PATH [--repo-root DIR]
       fix-report-diff-gate.sh --pr N [--repo-root DIR]

Exit: 0 = passed|unverified, 1 = error, 2 = usage.
EOF
}

emit_error() {
  echo "[CONTEXT] FIX_REPORT_DIFF_GATE=error; reason=$1" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --state-file)
      [ -n "${2:-}" ] || { echo "ERROR: --state-file requires a value" >&2; usage >&2; exit 2; }
      STATE_FILE="$2"; shift 2 ;;
    --pr)
      [ -n "${2:-}" ] || { echo "ERROR: --pr requires a value" >&2; usage >&2; exit 2; }
      PR_NUMBER="$2"; shift 2 ;;
    --repo-root)
      [ -n "${2:-}" ] || { echo "ERROR: --repo-root requires a value" >&2; usage >&2; exit 2; }
      REPO_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  emit_error jq_missing
fi

if [ -z "$STATE_FILE" ]; then
  case "$PR_NUMBER" in
    ''|*[!0-9]*)
      echo "ERROR: --state-file or --pr <N> is required" >&2
      usage >&2
      exit 2
      ;;
  esac
  _state_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) || _state_root=""
  [ -n "$_state_root" ] || emit_error state_unreadable
  STATE_FILE="$_state_root/.rite/fix-cycle-state/${PR_NUMBER}.json"
fi

if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
  emit_error state_unreadable
fi
if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
  emit_error state_unreadable
fi
if ! jq -e '.cycles | type == "array" and length > 0' "$STATE_FILE" >/dev/null 2>&1; then
  emit_error state_unreadable
fi

if ! jq -e '.cycles[-1] | has("findings_addressed")' "$STATE_FILE" >/dev/null 2>&1; then
  emit_error map_missing
fi
if ! jq -e '.cycles[-1].findings_addressed | type == "array"' "$STATE_FILE" >/dev/null 2>&1; then
  emit_error map_missing
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
fi
[ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ] || emit_error diff_failed

before=$(jq -r '.cycles[-1].commit_sha_before // empty' "$STATE_FILE")
[ -n "$before" ] || emit_error diff_failed
if ! git -C "$REPO_ROOT" cat-file -e "${before}^{commit}" 2>/dev/null; then
  emit_error diff_failed
fi
if ! git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  emit_error diff_failed
fi

diff_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-report-diff-err-XXXXXX") || emit_error diff_failed
if ! diff_out=$(git -C "$REPO_ROOT" diff -U0 "${before}..HEAD" 2>"$diff_err"); then
  rm -f "$diff_err"
  emit_error diff_failed
fi
rm -f "$diff_err"

# Parse unified=0:
#   plus_hunks  = "path:start:end" inclusive new-file ranges (new_count > 0)
#   minus_hunks = "path:start:end" inclusive old-file ranges of pure-delete
#                 hunks only (new_count == 0). A hunk that also adds lines is
#                 matched through plus_hunks, so a modified line's old number
#                 never verifies a citation.
plus_hunks=""
minus_hunks=""
current_file=""
current_src=""

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    diff\ --git\ *)
      current_file=""
      current_src=""
      ;;
    ---\ a/*)
      current_src=${line#--- a/}
      current_src=${current_src%%$'\t'*}
      ;;
    ---\ /dev/null)
      current_src=""
      ;;
    +++\ b/*)
      dest=${line#+++ b/}
      dest=${dest%%$'\t'*}
      current_file="$dest"
      ;;
    +++\ /dev/null)
      current_file="$current_src"
      ;;
    @@\ *)
      [ -n "$current_file" ] || continue
      minus=${line#@@ -}
      minus=${minus%% *}
      old_start=${minus%%,*}
      if [ "$minus" = "$old_start" ]; then
        old_count=1
      else
        old_count=${minus#*,}
      fi
      case "$old_start" in ''|*[!0-9]*) old_start="" ;; esac
      case "$old_count" in ''|*[!0-9]*) old_start="" ;; esac
      plus=${line#* +}
      plus=${plus%% *}
      new_start=${plus%%,*}
      if [ "$plus" = "$new_start" ]; then
        new_count=1
      else
        new_count=${plus#*,}
      fi
      case "$new_start" in ''|*[!0-9]*) continue ;; esac
      case "$new_count" in ''|*[!0-9]*) continue ;; esac
      if [ "$new_count" -gt 0 ]; then
        new_end=$((new_start + new_count - 1))
        plus_hunks="${plus_hunks}${current_file}:${new_start}:${new_end}"$'\n'
      elif [ -n "$old_start" ] && [ "$old_count" -gt 0 ]; then
        old_end=$((old_start + old_count - 1))
        minus_hunks="${minus_hunks}${current_file}:${old_start}:${old_end}"$'\n'
      fi
      ;;
  esac
done <<< "$diff_out"

range_overlaps() {
  local hunks="$1" f="$2" start="$3" end="$4" rec h_start h_end rest
  while IFS= read -r rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    case "$rec" in
      "$f":*)
        rest=${rec#"$f":}
        h_start=${rest%%:*}
        h_end=${rest#*:}
        if [ "$start" -le "$h_end" ] && [ "$h_start" -le "$end" ]; then
          return 0
        fi
        ;;
    esac
  done <<EOF
$hunks
EOF
  return 1
}

parse_change() {
  # Sets CHANGE_PATH CHANGE_START CHANGE_END. Returns 1 if unparseable.
  local spec="$1"
  CHANGE_PATH=""
  CHANGE_START=""
  CHANGE_END=""
  if [[ "$spec" =~ ^(.+):([0-9]+)-([0-9]+)$ ]]; then
    CHANGE_PATH="${BASH_REMATCH[1]}"
    CHANGE_START="${BASH_REMATCH[2]}"
    CHANGE_END="${BASH_REMATCH[3]}"
  elif [[ "$spec" =~ ^(.+):([0-9]+)$ ]]; then
    CHANGE_PATH="${BASH_REMATCH[1]}"
    CHANGE_START="${BASH_REMATCH[2]}"
    CHANGE_END="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  if [ "$CHANGE_START" -gt "$CHANGE_END" ]; then
    local tmp=$CHANGE_START
    CHANGE_START=$CHANGE_END
    CHANGE_END=$tmp
  fi
  return 0
}

change_matches() {
  local spec="$1"
  parse_change "$spec" || return 1
  if range_overlaps "$plus_hunks" "$CHANGE_PATH" "$CHANGE_START" "$CHANGE_END"; then
    return 0
  fi
  # Deletion: the cited range is covered by a - hunk (old-file numbering), so no
  # + hunk can exist for it. Judged per hunk, not per file, so that a file mixing
  # deletions and additions still verifies its delete-side changes.
  if range_overlaps "$minus_hunks" "$CHANGE_PATH" "$CHANGE_START" "$CHANGE_END"; then
    return 0
  fi
  return 1
}

n=$(jq '.cycles[-1].findings_addressed | length' "$STATE_FILE")
flags_json='{}'
verified=0
unverified=0
unverified_ids=""
i=0
while [ "$i" -lt "$n" ]; do
  id=$(jq -r ".cycles[-1].findings_addressed[$i].id // empty" "$STATE_FILE")
  action=$(jq -r ".cycles[-1].findings_addressed[$i].action // empty" "$STATE_FILE")
  [ -n "$id" ] || emit_error state_unreadable

  case "$action" in
    reply|accept|nit-noted)
      i=$((i + 1))
      continue
      ;;
    fix) ;;
    *)
      # Unknown action: an unrecognized value must not silently bypass the gate.
      emit_error map_missing
      ;;
  esac

  if ! jq -e ".cycles[-1].findings_addressed[$i].changes | type == \"array\" and length > 0" "$STATE_FILE" >/dev/null 2>&1; then
    emit_error map_missing
  fi

  n_changes=$(jq ".cycles[-1].findings_addressed[$i].changes | length" "$STATE_FILE")
  j=0
  finding_ok=0
  while [ "$j" -lt "$n_changes" ]; do
    spec=$(jq -r ".cycles[-1].findings_addressed[$i].changes[$j] // empty" "$STATE_FILE")
    if [ -z "$spec" ]; then
      emit_error map_missing
    fi
    if change_matches "$spec"; then
      finding_ok=1
    fi
    j=$((j + 1))
  done

  if [ "$finding_ok" -eq 1 ]; then
    verified=$((verified + 1))
    flags_json=$(printf '%s' "$flags_json" | jq --arg id "$id" '. + {($id): true}')
  else
    unverified=$((unverified + 1))
    if [ -n "$unverified_ids" ]; then
      unverified_ids="${unverified_ids},${id}"
    else
      unverified_ids="$id"
    fi
    flags_json=$(printf '%s' "$flags_json" | jq --arg id "$id" '. + {($id): false}')
  fi
  i=$((i + 1))
done

tmp=$(mktemp "${TMPDIR:-/tmp}/rite-fix-report-diff-state-XXXXXX") || emit_error state_unreadable
if ! jq --argjson flags "$flags_json" '
  .cycles[-1].findings_addressed |= map(
    if .action == "fix" then
      . + {diff_verified: ($flags[.id] // false)}
    else
      del(.diff_verified)
    end
  )
' "$STATE_FILE" > "$tmp"; then
  rm -f "$tmp"
  emit_error state_unreadable
fi
if ! mv "$tmp" "$STATE_FILE"; then
  rm -f "$tmp"
  emit_error state_unreadable
fi

if [ "$unverified" -gt 0 ]; then
  echo "[CONTEXT] FIX_REPORT_DIFF_GATE=unverified; verified=$verified; unverified=$unverified; ids=$unverified_ids" >&2
else
  echo "[CONTEXT] FIX_REPORT_DIFF_GATE=passed; verified=$verified; unverified=0" >&2
fi
exit 0
