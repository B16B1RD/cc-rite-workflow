#!/bin/bash
# rite workflow - StopFailure Hook
# Freezes the end of this session's open review-clock segment when a turn ends
# on an API error (usage limit, overload, ...).
#
# The review-clock-close recipe (references/review-stagnation.md) stamps
# ended_at with the time it runs. A session stopped by a usage limit resumes
# hours later in the same conversation and reaches that close, so without this
# hook the whole pause would count as work time and trip the stagnation
# diagnosis. Writing ended_at here, at the moment work stopped, makes close and
# recover keep that time (both leave an existing ended_at and kind unchanged).
# Work done after the resume until the next close is not counted.
#
# Claude Code ignores this hook's output and exit code, so every failure is a
# stderr WARNING with the path involved and the hook exits 0.
set -euo pipefail

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"
# shellcheck source=session-identity.sh
source "$SCRIPT_DIR/session-identity.sh"
# shellcheck source=session-ownership.sh
source "$SCRIPT_DIR/session-ownership.sh"

INPUT=$(cat) || INPUT=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

sid=$(extract_session_id "$INPUT") || sid=""
if [ -z "$sid" ]; then
  echo "[rite] WARNING: stop-failure: payload has no session_id; the open review clock (if any) keeps counting until close" >&2
  exit 0
fi
validate_session_id_path "$sid" "StopFailure payload" || exit 0
if [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  sid=$(printf '%s' "$sid" | tr 'A-F' 'a-f')
fi

STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD") || {
  echo "[rite] WARNING: stop-failure: cannot resolve the state root for $(printf '%s' "$CWD" | neutralize_ctrl); the open review clock (if any) keeps counting until close" >&2
  exit 0
}
clock_file="$STATE_ROOT/.rite/state/review-clock-${sid}.json"
[ -e "$clock_file" ] || exit 0

if ! jq -e 'type == "object"' "$clock_file" >/dev/null 2>&1; then
  echo "[rite] WARNING: stop-failure: review clock record is not a JSON object; left unchanged: $(printf '%s' "$clock_file" | neutralize_ctrl)" >&2
  exit 0
fi
jq -e 'has("ended_at")' "$clock_file" >/dev/null && exit 0

clock_tmp=""
trap 'rm -f "${clock_tmp:-}"' EXIT
if ! clock_tmp=$(mktemp "$clock_file.XXXXXX") \
  || ! jq --arg end "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '.ended_at = $end' "$clock_file" > "$clock_tmp" \
  || ! mv "$clock_tmp" "$clock_file"; then
  echo "[rite] WARNING: stop-failure: failed to stamp ended_at on the review clock; the pause will count as work time: $(printf '%s' "$clock_file" | neutralize_ctrl)" >&2
fi
exit 0
