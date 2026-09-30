#!/bin/bash
# Reap other-session run-queue files whose owner session has gone away.
#
# Resume is same-session only. A queue is reaped when its updated_at is older
# than 2h (or missing / unparsable) and its owner session is not live. The
# queue's updated_at moves only at batch start and cursor advance, so a live
# session routinely exceeds 2h on one Issue. Liveness is the owner's
# flow-state updated_at, which moves on every phase transition, within the
# same 2h window. An owner flow-state that is not a readable JSON object keeps
# the queue with a WARNING. One without a parsable updated_at cannot prove
# liveness, so the queue's own staleness decides and the reason is printed.
# Own-session files are never touched.
#
# Neither timestamp moves while the owner is paused (e.g. by a usage limit),
# so 2h without an update does not mean the owner has ended. session-end.sh
# marks an ended owner with `run-queue-{sid}.ended`; only a marked queue is
# reaped. A queue without the marker is never reaped, however long it has been
# idle: a usage-limit pause can outlast any age bound. Such a queue that has
# passed the checks above is announced on stdout (one line per queue) so it
# does not linger unseen; the SessionStart hook passes that line to the model.
#
# Stale failed[] / outstanding[] are printed to stderr one item per line
# before deletion — the record must not vanish silently.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$HOOKS_DIR/control-char-neutralize.sh"
# shellcheck source=../session-ownership.sh
source "$HOOKS_DIR/session-ownership.sh"
# shellcheck source=../state-path-resolve.sh
source "$HOOKS_DIR/state-path-resolve.sh"

OWN_SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      [ $# -ge 2 ] || { echo "ERROR: run-queue-reap: --session requires a value" >&2; exit 1; }
      OWN_SID="$2"
      shift 2
      ;;
    *)
      echo "ERROR: run-queue-reap: unknown argument: $(printf '%s' "$1" | neutralize_ctrl)" >&2
      exit 1
      ;;
  esac
done

if [ -n "${RITE_STATE_ROOT:-}" ] && [ -d "$RITE_STATE_ROOT" ]; then
  STATE_ROOT="$RITE_STATE_ROOT"
elif [ -n "${STATE_ROOT:-}" ] && [ -d "$STATE_ROOT" ]; then
  :
else
  STATE_ROOT=$(resolve_state_root) || STATE_ROOT=""
fi

if [ -z "$OWN_SID" ]; then
  echo "WARNING: run-queue-reap: --session is required; skip (own queue must not be deleted by mistake)" >&2
  exit 0
fi
if [ -z "$STATE_ROOT" ] || [ ! -d "$STATE_ROOT" ]; then
  echo "WARNING: run-queue-reap: state root unresolved; skip" >&2
  exit 0
fi

queue_dir="$STATE_ROOT/.rite/state"
[ -d "$queue_dir" ] || exit 0

# Leftover records may contain UTF-8 (Japanese detail). C1 neutralize would
# smash continuation bytes. Strip C0 per line and emit our own newline so
# "one item per line" stays intact.
_emit_leftover_items() {
  local expr="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    printf '%s' "$line" | neutralize_ctrl --c0-only >&2
    printf '\n' >&2
  done < <(jq -r "$expr" "$q")
}

STALE_SECONDS=7200
now_epoch=$(date +%s)
shopt -s nullglob
for q in "$queue_dir"/run-queue-*.json; do
  [ -f "$q" ] || continue
  base=$(basename "$q" .json)
  sid="${base#run-queue-}"
  [ "$sid" = "$OWN_SID" ] && continue

  q_disp=$(printf '%s' "$q" | neutralize_ctrl)
  if ! jq -e . "$q" >/dev/null 2>&1; then
    echo "WARNING: run-queue-reap: unreadable queue, skip: $q_disp" >&2
    continue
  fi

  updated_at=$(jq -r '.updated_at // empty' "$q")
  state_epoch=0
  [ -n "$updated_at" ] && state_epoch=$(parse_iso8601_to_epoch "$updated_at")
  if [ "$state_epoch" -ne 0 ] && [ $((now_epoch - state_epoch)) -le "$STALE_SECONDS" ]; then
    continue
  fi

  fs="$STATE_ROOT/.rite/sessions/${sid}.flow-state"
  fs_epoch=0
  if [ -f "$fs" ]; then
    fs_disp=$(printf '%s' "$fs" | neutralize_ctrl)
    if ! jq -e 'type == "object"' "$fs" >/dev/null 2>&1; then
      echo "WARNING: run-queue-reap: owner flow-state unreadable, keep queue: $q_disp (flow-state: $fs_disp)" >&2
      continue
    fi
    fs_updated=$(jq -r '.updated_at // empty' "$fs")
    [ -n "$fs_updated" ] && fs_epoch=$(parse_iso8601_to_epoch "$fs_updated")
    if [ "$fs_epoch" -ne 0 ] && [ $((now_epoch - fs_epoch)) -le "$STALE_SECONDS" ]; then
      continue
    fi
  fi

  ended="$queue_dir/run-queue-${sid}.ended"
  if [ ! -e "$ended" ]; then
    sid_disp=$(printf '%s' "$sid" | neutralize_ctrl)
    # The announcement is for a person to act on: keep UTF-8 in the path (C1 neutralize would break it).
    q_show=$(printf '%s' "$q" | neutralize_ctrl --c0-only)
    progress=$(jq -r '"\(if (.cursor | type) == "number" then .cursor else 0 end)/\(if (.issues | type) == "array" then (.issues | length) else 0 end)"' "$q")
    echo "[rite] Batch: 終了の印が無い他セッションの run-queue を回収せず残しています (cursor ${progress}): ${q_show} — 持ち主のセッション ${sid_disp} を再開し、引数なしの /rite:batch-run で続行できます。不要なら run-queue-${sid_disp}.json と .watchdog を削除してください。"
    continue
  fi

  if [ -f "$fs" ] && [ "$fs_epoch" -eq 0 ]; then
    echo "WARNING: run-queue-reap: owner flow-state updated_at missing or unparsable, reap stale queue: $q_disp (flow-state: $fs_disp)" >&2
  fi

  failed_n=$(jq '(.failed // []) | length' "$q")
  outstanding_n=$(jq '(.outstanding // []) | length' "$q")
  if [ "$failed_n" -gt 0 ] || [ "$outstanding_n" -gt 0 ]; then
    echo "WARNING: run-queue-reap: leftover failed/outstanding before delete: $q_disp" >&2
    _emit_leftover_items '(.failed // [])[] | "run-queue-reap: failed=\(.)"'
    _emit_leftover_items '(.outstanding // [])[] | "run-queue-reap: outstanding=\(.)"'
  fi

  watchdog="$queue_dir/run-queue-${sid}.watchdog"
  rm -f "$q" "$watchdog" "$ended"
done
exit 0
