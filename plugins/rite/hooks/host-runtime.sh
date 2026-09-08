#!/bin/bash
# Explicit lifecycle boundaries for hosts without verified automatic hook wiring.
# This dispatches fixed helpers; it never executes a proposed tool command or
# grants host permission. auto leaves dispatch to the verified native hook.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/control-char-neutralize.sh"
source "$SCRIPT_DIR/session-identity.sh"
source "$SCRIPT_DIR/scripts/lib/tempfile.sh"
rite_tempfile_init

fail() { echo "ERROR: host-runtime: $*" >&2; exit 1; }
EVENT="${1:-}"
[ "$#" -gt 0 ] && shift
MODE=""; RUNTIME_CWD=""; OVERRIDE=""; PAYLOAD_FILE=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || fail "missing value for $1"
  case "$1" in
    --mode) MODE="$2" ;;
    --cwd) RUNTIME_CWD="$2" ;;
    --session) OVERRIDE="$2" ;;
    --payload-file) PAYLOAD_FILE="$2" ;;
    *) fail "unknown argument $1" ;;
  esac
  shift 2
done
case "$EVENT" in init|checkpoint|next|before-bash|before-edit|after-edit) ;; *) fail "unknown boundary" ;; esac
case "$MODE" in auto|explicit) ;; *) fail "--mode auto|explicit is required" ;; esac
case "$RUNTIME_CWD" in /*) ;; *) fail "--cwd must be absolute" ;; esac
[ -d "$RUNTIME_CWD" ] || fail "--cwd does not exist"
contains_ctrl "$RUNTIME_CWD" && fail "--cwd contains control characters"
RUNTIME_CWD=$(cd "$RUNTIME_CWD" && pwd -P)
if [ -n "$OVERRIDE" ]; then
  validate_session_id_path "$OVERRIDE" "--session" || exit 1
  if [[ "$OVERRIDE" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    OVERRIDE=$(printf '%s' "$OVERRIDE" | tr 'A-F' 'a-f')
  fi
fi
SID=""; ID_RC=0
SID=$(resolve_runtime_session_id) || ID_RC=$?
case "$ID_RC" in
  0)
    if [ -n "$OVERRIDE" ]; then
      [ "$OVERRIDE" = "$SID" ] || fail "--session does not match runtime identity"
    fi
    ;;
  2)
    [ -n "$OVERRIDE" ] || fail "current runtime ID or --session is required; shared marker is not an identity"
    SID="$OVERRIDE"
    # Process-local compatibility for a host whose ID is supplied by its API.
    export RITE_HOST=claude CLAUDE_CODE_SESSION_ID="$SID"
    ;;
  *) exit 1 ;;
esac

PAYLOAD='{}'
case "$EVENT" in
  before-bash|before-edit|after-edit)
    case "$PAYLOAD_FILE" in /*) ;; *) fail "--payload-file must be an absolute JSON file path" ;; esac
    [ -f "$PAYLOAD_FILE" ] || fail "payload file is missing"
    # Only the normalized hook contract is accepted. Raw camelCase events must
    # be translated and verified by the host adapter before reaching this entry.
    jq -e --arg sid "$SID" --arg cwd "$RUNTIME_CWD" '
      type == "object" and
      ((keys - ["tool_name","tool_input","cwd","session_id","subagent_type","agent_type","transcript_path"]) | length == 0) and
      (.tool_name | type == "string") and (.tool_input | type == "object") and
      ((has("cwd") | not) or .cwd == $cwd) and
      ((has("session_id") | not) or .session_id == $sid) and
      all(.transcript_path, .subagent_type, .agent_type; . == null or type == "string")
    ' "$PAYLOAD_FILE" >/dev/null 2>&1 || fail "invalid normalized hook payload or mismatched cwd/session"
    PAYLOAD=$(cat "$PAYLOAD_FILE")
    if [ "$EVENT" = "before-bash" ]; then
      jq -e '.tool_name == "Bash" and (.tool_input.command | type == "string" and length > 0)' "$PAYLOAD_FILE" >/dev/null || fail "before-bash requires Bash and a nonempty command"
    else
      jq -e '.tool_name as $t | (["Edit","Write","MultiEdit","NotebookEdit"] | index($t)) != null' "$PAYLOAD_FILE" >/dev/null || fail "edit boundary requires a mutating file tool"
      jq -e '(.tool_input.file_path // .tool_input.notebook_path) | type == "string" and startswith("/") and (test("[\u0000-\u001f\u007f]") | not)' "$PAYLOAD_FILE" >/dev/null || fail "edit target must be an absolute path without control characters"
    fi
    ;;
  *) [ -z "$PAYLOAD_FILE" ] || fail "payload is only valid at tool boundaries" ;;
esac

if [ "$MODE" = "auto" ]; then
  printf 'host-runtime: boundary=%s mode=auto; explicit dispatch skipped; verify native event completion\n' "$EVENT"
  exit 0
fi

cd "$RUNTIME_CWD"
export CWD="$RUNTIME_CWD"
STATE_ROOT=$(bash "$SCRIPT_DIR/state-path-resolve.sh" "$CWD")
export RITE_STATE_ROOT="$STATE_ROOT" RITE_RUNTIME_EXPLICIT=1
# Use the distribution that was resolved and validated by this caller.
export _RITE_HOOK_REDIRECTED=1
PAYLOAD=$(printf '%s' "$PAYLOAD" | jq -c --arg sid "$SID" --arg cwd "$CWD" '. + {session_id:$sid,cwd:$cwd}')
rite_tempfile_new OUTPUT host-runtime-output
run_hook() {
  local helper="$1" rc=0
  [ -f "$helper" ] || fail "required helper is missing: $helper"
  printf '%s' "$PAYLOAD" | bash "$helper" >"$OUTPUT" || rc=$?
  cat "$OUTPUT"
  [ "$rc" -eq 0 ] || return "$rc"
  if [ "$EVENT" = "before-bash" ] || [ "$EVENT" = "before-edit" ]; then
    # Native deny JSON commonly exits zero. Explicit callers must receive a
    # failing status and stop before the proposed tool executes.
    if [ -s "$OUTPUT" ]; then
      jq -e . "$OUTPUT" >/dev/null || fail "guard returned malformed output"
      if jq -e '.hookSpecificOutput.permissionDecision == "deny" or .decision == "block"' "$OUTPUT" >/dev/null; then
        return 2
      fi
      jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUTPUT" >/dev/null || fail "guard did not explicitly allow the tool"
    fi
  fi
}
read_state() {
  FLOW_STATE=$(bash "$SCRIPT_DIR/flow-state.sh" path) || return $?
  if [ ! -f "$FLOW_STATE" ]; then
    printf 'host-runtime: no flow state for current session\n'
    return 2
  fi
  jq -e --arg sid "$SID" 'type == "object" and .session_id == $sid and
    (.active | type == "boolean") and (.phase | type == "string") and
    (.next_action == null or (.next_action | type == "string"))' "$FLOW_STATE" >/dev/null || fail "flow state is corrupt or belongs to another session"
}
show_next() {
  local rc=0
  read_state || rc=$?
  [ "$rc" -ne 2 ] || return 0
  [ "$rc" -eq 0 ] || return "$rc"
  jq '{active,issue_number,phase,pr_number,branch,worktree,next_action,handoff,stop_reason}' "$FLOW_STATE"
}
case "$EVENT" in
  init)
    PAYLOAD=$(printf '%s' "$PAYLOAD" | jq -c '.source="explicit"')
    run_hook "$SCRIPT_DIR/session-start.sh"
    show_next
    ;;
  next) show_next ;;
  checkpoint)
    read_state
    if jq -e '.active != true or .phase == "cleanup" or .phase == "completed"' "$FLOW_STATE" >/dev/null; then
      show_next
      exit 0
    fi
    ISSUE=$(jq -r '.issue_number' "$FLOW_STATE")
    [[ "$ISSUE" =~ ^[0-9]+$ ]] || fail "invalid issue_number in flow state"
    PHASE=$(jq -r '.phase' "$FLOW_STATE")
    NEXT=$(jq -r '.next_action // ""' "$FLOW_STATE")
    LOCAL_WM="$STATE_ROOT/.rite/work-memory/issue-$ISSUE.md"
    [ -f "$LOCAL_WM" ] || LOCAL_WM="$STATE_ROOT/.rite-work-memory/issue-$ISSUE.md"
    CURRENT_BRANCH=$(git -C "$CWD" branch --show-current)
    CURRENT_COMMIT=$(git -C "$CWD" rev-parse --short HEAD)
    UPDATE_LOCAL=1
    if [ -f "$LOCAL_WM" ]; then
      WM_DATA=$(python3 "$SCRIPT_DIR/work-memory-parse.py" "$LOCAL_WM")
      if printf '%s' "$WM_DATA" | jq -e --slurpfile state "$FLOW_STATE" --arg branch "$CURRENT_BRANCH" --arg commit "$CURRENT_COMMIT" '
        .data as $wm | $state[0] as $s |
        $wm.phase == $s.phase and $wm.next_action == ($s.next_action // "") and
        $wm.branch == $branch and $wm.last_commit == $commit and
        ($wm.pr_number // 0 | tostring) == ($s.pr_number // 0 | tostring) and
        ($wm.loop_count // 0 | tostring) == ($s.loop_count // 0 | tostring)
      ' >/dev/null; then UPDATE_LOCAL=0; fi
    fi
    if [ "$UPDATE_LOCAL" = 1 ]; then
      (cd "$STATE_ROOT" && WM_PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")" WM_SOURCE=explicit_checkpoint \
        WM_ISSUE_NUMBER="$ISSUE" WM_PHASE="$PHASE" WM_PHASE_DETAIL="$PHASE" \
        WM_NEXT_ACTION="$NEXT" WM_BODY_TEXT="Workflow checkpoint." WM_REQUIRE_FLOW_STATE=true \
        WM_BRANCH_OVERRIDE="$CURRENT_BRANCH" WM_LAST_COMMIT_OVERRIDE="$CURRENT_COMMIT" WM_READ_FROM_FLOW_STATE=true \
        bash "$SCRIPT_DIR/local-wm-update.sh")
    fi
    PAYLOAD=$(printf '%s' "$PAYLOAD" | jq -c '.tool_name="Bash"')
    run_hook "$SCRIPT_DIR/post-tool-wm-sync.sh"
    show_next
    ;;
  before-bash) run_hook "$SCRIPT_DIR/pre-tool-bash-guard.sh" ;;
  before-edit) run_hook "$SCRIPT_DIR/pre-tool-edit-guard.sh" ;;
  after-edit) run_hook "$SCRIPT_DIR/scripts/bang-backtick-edit-hook.sh" ;;
esac
