#!/bin/bash
# Loop-skill entry: resume only this session's recorded pause before other work.
# flow-state path is the canonical session/root resolver; resume retains the
# existing clock behavior. No phase, review-run, handoff or queue is rewritten.
# stdout: LOOP_ENTRY_RESUME=none|resumed. Nonzero resolution/removal errors stop entry.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -eq 0 ] || { echo "ERROR: loop-entry-resume: no arguments expected" >&2; exit 1; }
flow_path=$(bash "$SCRIPT_DIR/../flow-state.sh" path) || exit $?
[ -n "$flow_path" ] || { echo "ERROR: loop-entry-resume: empty flow-state path" >&2; exit 1; }
session_id=$(basename "$flow_path" .flow-state)
pause_record="$(dirname "$(dirname "$flow_path")")/state/pause-${session_id}.json"
if [ ! -e "$pause_record" ]; then
  echo "[CONTEXT] LOOP_ENTRY_RESUME=none"
  exit 0
fi
bash "$SCRIPT_DIR/../flow-state.sh" resume || exit $?
[ ! -e "$pause_record" ] || { echo "ERROR: loop-entry-resume: pause record remains after resume" >&2; exit 1; }
echo "[CONTEXT] LOOP_ENTRY_RESUME=resumed"
echo "rite: 同じセッションからの再入により一時停止を解除し、継続ガードを再開しました。"
