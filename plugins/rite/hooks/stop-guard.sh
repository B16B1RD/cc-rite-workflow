#!/bin/bash
# rite workflow - Stop Guard Hook
# Prevents Claude from stopping during an active rite workflow
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_STOP:-}" ] || exit 0
export _RITE_HOOK_RUNNING_STOP=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true
source "$SCRIPT_DIR/phase-transition-whitelist.sh" 2>/dev/null || true

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# (Under set -e, a missing jq would exit 127 at the first jq call, before
# reaching -f; the comment describes the logical invariant, not the exit path.)
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
# Extract session_id from hook JSON for ownership checks and diagnostic logging (#173)
SESSION_ID=$(extract_session_id "$INPUT" 2>/dev/null) || SESSION_ID=""
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD) — consistent with pre-compact.sh / session-end.sh
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Debug logging (enabled by RITE_DEBUG env var, zero overhead when disabled)
log_debug() {
  [ -n "${RITE_DEBUG:-}" ] && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] stop-guard: $1" >> "$STATE_ROOT/.rite-flow-debug.log" 2>/dev/null || true
}

# Diagnostic logging (always enabled, exit points only, ~100 bytes per entry)
# Output: $STATE_ROOT/.rite-stop-guard-diag.log (ring buffer: 50 lines max)
# .gitignore の *.log で自動除外済み
log_diag() {
  local diag_file="$STATE_ROOT/.rite-stop-guard-diag.log"
  local _tmp_diag=""
  trap '[ -n "$_tmp_diag" ] && rm -f "$_tmp_diag" 2>/dev/null; true' RETURN
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $1" >> "$diag_file" 2>/dev/null || true
  # Ring buffer: truncate to last 50 lines (mapfile avoids wc -l subshell)
  if [ -f "$diag_file" ]; then
    local -a _lines
    mapfile -t _lines < "$diag_file" 2>/dev/null || true
    if [ "${#_lines[@]}" -gt 50 ]; then
      # fallback to PID-based name if mktemp fails (e.g., disk full, permission denied)
      _tmp_diag=$(mktemp "${diag_file}.XXXXXX" 2>/dev/null) || _tmp_diag="${diag_file}.tmp.$$"
      printf '%s\n' "${_lines[@]: -50}" > "$_tmp_diag" 2>/dev/null && mv "$_tmp_diag" "$diag_file" 2>/dev/null || { rm -f "$_tmp_diag" 2>/dev/null; true; }
    fi
  fi
}

# Check for active workflow
STATE_FILE="$STATE_ROOT/.rite-flow-state"
if [ ! -f "$STATE_FILE" ]; then
  log_debug "no state file"
  log_diag "EXIT:0 reason=no_state_file session_id=${SESSION_ID:-unknown}"
  exit 0
fi

# Fail-closed helper: block stop when state file is corrupt/unreadable
# (fail-open was a source of intermittent flow interruptions)
fail_closed() {
  log_debug "$1"
  log_diag "EXIT:2 reason=fail_closed detail=$1 session_id=${SESSION_ID:-unknown}"
  cat >&2 <<'STOP_MSG'
[rite] Normal operation — stop prevented (state unreadable).
ACTION: Read .rite-flow-state and continue the active workflow. Do NOT stop.
STOP_MSG
  exit 2
}

ACTIVE=$(jq -r '.active // false' "$STATE_FILE" 2>/dev/null) || \
  fail_closed "state parse error on .active"
if [ "$ACTIVE" != "true" ]; then
  log_debug "workflow not active"
  log_diag "EXIT:0 reason=not_active session_id=${SESSION_ID:-unknown}"
  exit 0
fi

# parse_iso8601_to_epoch is now provided by session-ownership.sh (sourced above)

# Session ownership check (#173): if state belongs to another session, allow stop
# (this session should not be blocked by another session's active workflow)
_ownership=$(check_session_ownership "$INPUT" "$STATE_FILE" 2>/dev/null) || _ownership="own"
if [ "$_ownership" = "other" ]; then
  log_debug "state belongs to another session, allowing stop"
  log_diag "EXIT:0 reason=other_session session_id=${SESSION_ID:-unknown}"
  exit 0
fi

# Check staleness (over 2 hours = likely abandoned; extended from 1h to accommodate
# multi-reviewer reviews which can take 60-90 minutes, fixes #719)
UPDATED_AT=$(jq -r '.updated_at // empty' "$STATE_FILE" 2>/dev/null) || \
  fail_closed "state parse error on .updated_at"
if [ -z "$UPDATED_AT" ]; then
  log_debug "no updated_at"
  log_diag "EXIT:0 reason=no_updated_at session_id=${SESSION_ID:-unknown}"
  exit 0
fi

CURRENT=$(date +%s)

# compact_state check: PostCompact hook handles auto-recovery (#133).
# When compact_state is "recovering", PostCompact will auto-restore context.
# Block stop briefly to let PostCompact process. If recovering persists > 120s
# (PostCompact failure), allow stop as a safety valve.
COMPACT_STATE="$STATE_ROOT/.rite-compact-state"
if [ -f "$COMPACT_STATE" ]; then
  COMPACT_VAL=$(jq -r '.compact_state // "normal"' "$COMPACT_STATE" 2>/dev/null) || COMPACT_VAL="unknown"
  if [ "$COMPACT_VAL" = "recovering" ]; then
    COMPACT_TS=$(jq -r '.compact_state_set_at // empty' "$COMPACT_STATE" 2>/dev/null) || COMPACT_TS=""
    if [ -n "$COMPACT_TS" ]; then
      COMPACT_EPOCH=$(parse_iso8601_to_epoch "$COMPACT_TS")
      COMPACT_AGE=$(( CURRENT - COMPACT_EPOCH ))
      if [ "$COMPACT_AGE" -gt 120 ]; then
        log_debug "compact_state=recovering for ${COMPACT_AGE}s (>120s), allowing stop (PostCompact failure fallback)"
        log_diag "EXIT:0 reason=compact_recovering_timeout age=${COMPACT_AGE}s session_id=${SESSION_ID:-unknown}"
        cat >&2 <<'STOP_MSG'
[rite] PostCompact タイムアウト — stop を許可します。
/rite:resume で作業を再開してください。
STOP_MSG
        exit 0
      fi
    fi
    log_debug "compact_state=recovering, blocking stop (PostCompact will handle)"
  fi
fi

STATE_TS=$(parse_iso8601_to_epoch "$UPDATED_AT")
AGE=$(( CURRENT - STATE_TS ))
if [ "$AGE" -gt 7200 ]; then
  log_debug "stale workflow (age=${AGE}s)"
  log_diag "EXIT:0 reason=stale age=${AGE}s session_id=${SESSION_ID:-unknown}"
  exit 0
fi

# Extract all fields in a single jq call for efficiency.
# Fail-closed: if jq/read fails, use safe defaults so the stop is still blocked.
# error_count is incremented on each blocked stop; it resets to 0 on each patch-mode
# phase transition (flow-state-update.sh, since #294), at the start of the next workflow
# (when /rite:issue:start regenerates .rite-flow-state), or when manually reset.
#
# cycle 10 CRITICAL F-01: delimiter に tab ($'\t') を使うと POSIX whitespace IFS collapse
# により previous_phase="" のとき隣接 tab が単一区切り扱いになり、全フィールドが 1 つ左 shift
# して ERROR_COUNT が empty string になる silent corruption を起こす。cycle 1 (#490) 以降
# 潜伏していた bug で、9 件の "pre-existing test failures" (ERROR_COUNT-THRESHOLD 比較の
# `[ "" -ge "$THRESHOLD" ]` 整数エラー) が症状として発現していた。unit separator (\x1f / U+001F)
# は non-whitespace のため adjacent-delimiter を empty field として preserve する POSIX 準拠挙動となる。
# (line-number 参照を避ける理由は cycle 8 F-05 参照)
IFS=$'\x1f' read -r PHASE PREV_PHASE NEXT ISSUE PR ERROR_COUNT < <(jq -r '[(.phase // "unknown"), (.previous_phase // ""), (.next_action // "unknown"), (.issue_number // 0 | tostring), (.pr_number // 0 | tostring), (.error_count // 0 | tostring)] | join("\u001f")' "$STATE_FILE" 2>/dev/null) || {
  PHASE="unknown"
  PREV_PHASE=""
  NEXT="Read .rite-flow-state and continue the active workflow. Do NOT stop."
  ISSUE="0"
  PR="0"
  ERROR_COUNT="0"
}

# Phase transition whitelist verification (#490).
# Load overrides from rite-config.yml if the helper was sourced.
# Do NOT suppress stderr/exit — failure to load overrides must be visible so
# users can diagnose why their rite-config.yml override silently did not apply
# (error-handling HIGH — 旧実装では `2>/dev/null || true` で stderr + rc を黙殺していたが、
#  下方の `_rite_load_whitelist_overrides ... || log_diag` に変更済み。
#  Do NOT re-introduce stderr suppression or `|| true` on this invocation).
if type _rite_load_whitelist_overrides >/dev/null 2>&1 && [ -f "$STATE_ROOT/rite-config.yml" ]; then
  _rite_load_whitelist_overrides "$STATE_ROOT/rite-config.yml" || \
    log_diag "override_load_failed rc=$? session_id=${SESSION_ID:-unknown}"
fi
# Detect cases where the whitelist helper was NOT loaded (bash < 4.2, sourcing failure,
# etc.). Record via diag log so the silent-disabled state is recoverable
# (devops HIGH — declare -gA incompat, error-handling HIGH — forward-compat bypass).
if ! type rite_phase_transition_allowed >/dev/null 2>&1; then
  log_diag "whitelist_helper_unavailable — phase transition verification disabled session_id=${SESSION_ID:-unknown}"
fi
INVALID_TRANSITION=""
if type rite_phase_transition_allowed >/dev/null 2>&1; then
  if ! rite_phase_transition_allowed "$PREV_PHASE" "$PHASE"; then
    EXPECTED=$(rite_phase_expected_next "$PREV_PHASE" 2>/dev/null || true)
    INVALID_TRANSITION="prev=$PREV_PHASE curr=$PHASE expected_next=${EXPECTED:-unknown}"
  elif [ -n "$PREV_PHASE" ] && type rite_phase_is_known >/dev/null 2>&1 && \
       ! rite_phase_is_known "$PREV_PHASE"; then
    # Forward-compat path was taken (prev phase not in whitelist).
    # Record for diagnosis so typos like `phase2_post_workmemory` don't silently bypass
    # the whitelist (error-handling HIGH — forward-compat typo silent bypass).
    log_diag "forward_compat_accepted prev=$PREV_PHASE curr=$PHASE session_id=${SESSION_ID:-unknown}"
  fi
fi

# Read error threshold from rite-config.yml (safety.repeated_failure_threshold, default: 3)
THRESHOLD=3
RITE_CONFIG="$STATE_ROOT/rite-config.yml"
if [ -f "$RITE_CONFIG" ]; then
  # awk: ^safety: セクション内を動的に抽出（次のトップレベルキーまで）
  cfg_val=$(awk '/^safety:/{f=1;next} f && /^[^[:space:]]/{exit} f && /repeated_failure_threshold/' "$RITE_CONFIG" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]' 2>/dev/null || echo "")
  if [[ "$cfg_val" =~ ^[0-9]+$ ]]; then
    THRESHOLD="$cfg_val"
  fi
fi
# Enforce minimum threshold of 1 to prevent accidental always-allow
# (threshold=0 would fire immediately and never block any stops).
[ "$THRESHOLD" -lt 1 ] && THRESHOLD=3

# Allow stop when error_count has reached the threshold — the workflow is stuck in an error loop.
# If the underlying cause was an invalid phase transition, surface it in the message so the
# diagnostic trail is preserved (error-handling HIGH — threshold path erases invalid_transition).
if [ "$ERROR_COUNT" -ge "$THRESHOLD" ]; then
  log_debug "error_count=$ERROR_COUNT >= threshold=$THRESHOLD, allowing stop"
  log_diag "EXIT:0 reason=error_threshold error_count=$ERROR_COUNT threshold=$THRESHOLD invalid_transition=${INVALID_TRANSITION:-none} session_id=${SESSION_ID:-unknown}"
  if [ -n "$INVALID_TRANSITION" ]; then
    cat >&2 <<STOP_MSG
[rite] Error threshold reached (${ERROR_COUNT} consecutive blocked stops, threshold: ${THRESHOLD}) — stop allowed.
Phase: $PHASE | Previous: $PREV_PHASE | Issue: #$ISSUE | PR: #$PR
ROOT CAUSE: invalid phase transition ($INVALID_TRANSITION).
The whitelist detected the transition as invalid on every retry, but error_count exhausted the
threshold. The workflow is now unblocked, but the underlying phase-skip bug remains.
Action: correct the phase marker in the failing Pre-write block, then reset
.rite-flow-state.error_count to 0 (or re-run /rite:resume).
STOP_MSG
  else
    cat >&2 <<STOP_MSG
[rite] Error threshold reached (${ERROR_COUNT} consecutive blocked stops, threshold: ${THRESHOLD}) — stop allowed.
Phase: $PHASE | Issue: #$ISSUE | PR: #$PR
The workflow appears stuck in an error loop. Stopping to prevent infinite repetition.
Reset .rite-flow-state error_count to 0 or set active to false to restore normal stop-guard behavior.
STOP_MSG
  fi
  exit 0
fi

# Atomically increment error_count before blocking.
# If the write fails (disk full, permissions), skip silently — the primary goal is protection.
TMP_STATE=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null) || TMP_STATE="${STATE_FILE}.tmp.$$"
# F-02 / F-05 (#636 cycle 7): SIGHUP 追加 + _mv_err を cleanup 対象に含める。
# flow-state-update.sh の EXIT/TERM/INT/HUP trap と対称化 (flow-state-update.sh の
# _log_flow_diag() 直前の TMP_STATE trap 宣言が canonical)。SSH disconnect (SIGHUP) 到来時の
# $TMP_STATE / $_mv_err orphan を防ぐ。_mv_err は下で mktemp されるが `${_mv_err:-}` で
# 未定義時も safe に no-op となる。
# (line-number 参照を避ける理由は cycle 8 F-05 参照 — #636 cycle 10 F-02 対応)
trap 'rm -f "$TMP_STATE" "${_mv_err:-}" 2>/dev/null' EXIT TERM INT HUP
if jq --argjson cnt "$((ERROR_COUNT + 1))" '.error_count = $cnt' "$STATE_FILE" > "$TMP_STATE" 2>/dev/null; then
  # F-07 / #636: mv 失敗 path も F-08 jq_write_failed と対称に diag log 記録。
  # jq が tmp に json を書いた後、mv のみ permission denied / disk full / TOCTOU で失敗した場合、
  # state 実値と HINT 上の error_count 想定値が乖離する結末は jq 失敗時と同一だが、従来は片方だけ
  # diag log に残り他方は silent だった。対称的に log_diag を追加して silent-failure-hunter 一貫化。
  # F-11 (#636 cycle 6): mv の stderr を tempfile に退避して errno を diag log に含める。
  # 旧実装 `mv ... 2>/dev/null` は Permission denied / No space left / EXDEV の区別を永久喪失
  # させていた (発生は知れるが原因が知れない partial surface)。root cause 特定を可能にする。
  _mv_err=$(mktemp 2>/dev/null) || _mv_err=""
  if ! mv "$TMP_STATE" "$STATE_FILE" 2>"${_mv_err:-/dev/null}"; then
    _mv_reason=""
    if [ -n "$_mv_err" ] && [ -s "$_mv_err" ]; then
      _mv_reason=" reason=$(head -1 "$_mv_err" | tr -d '\n' | head -c 200)"
    fi
    log_diag "error_count_mv_failed phase=$PHASE error_count=$ERROR_COUNT${_mv_reason} session_id=${SESSION_ID:-unknown}"
    rm -f "$TMP_STATE"
  fi
  [ -n "$_mv_err" ] && rm -f "$_mv_err"
else
  # verified-review F-08 / #636: jq write 失敗 (disk full / permission denied / TOCTOU)
  # を silent に握りつぶさず diag log に残す。HINT 上の error_count 想定値と state file
  # 実値が乖離する可能性を surface する (silent failure-hunter 対応)。
  log_diag "error_count_write_failed phase=$PHASE error_count=$ERROR_COUNT session_id=${SESSION_ID:-unknown}"
  rm -f "$TMP_STATE"
fi

# Block the stop (exit 2 + stderr = Claude Code stops the end_turn and feeds stderr to assistant)
log_debug "blocking stop (phase=$PHASE, next=$NEXT, error_count=$((ERROR_COUNT + 1))/$THRESHOLD)"
log_diag "EXIT:2 reason=blocking phase=$PHASE issue=#$ISSUE error_count=$((ERROR_COUNT + 1))/$THRESHOLD session_id=${SESSION_ID:-unknown}"

if [ -n "$INVALID_TRANSITION" ]; then
  # Invalid phase transition detected via whitelist (#490). Surface the mismatch
  # so the LLM re-enters the missing intermediate phase rather than pressing on.
  log_diag "EXIT:2 reason=invalid_transition $INVALID_TRANSITION session_id=${SESSION_ID:-unknown}"
  EXPECTED_LIST=$(rite_phase_expected_next "$PREV_PHASE" 2>/dev/null || echo "")
  cat >&2 <<STOP_MSG
[rite] Invalid phase transition detected — stop prevented.
Phase: $PHASE | Previous: $PREV_PHASE | Issue: #$ISSUE | PR: #$PR
PROBLEM: Transition $PREV_PHASE → $PHASE is not in the whitelist.
EXPECTED NEXT FROM $PREV_PHASE: ${EXPECTED_LIST:-(unknown)}
ACTION: Do NOT proceed with $PHASE. Return to the expected next phase above
and execute its Pre-write + main procedure + Mandatory After block as
defined in plugins/rite/commands/issue/start.md. Do NOT stop.
STOP_MSG
  exit 2
fi

# Best-effort hint for sub-skill return phases (#525, #552, #604).
# When the LLM stops implicitly after a sub-skill return, surface a phase-specific
# continuation hint so the next prompt re-entry makes the correct continuation
# obvious.
#
# Sentinel → observed caller phase mapping:
#   - Sub-skill return sentinels (caller phase is a pre-transition phase):
#     * [interview:skipped] / [interview:completed] → caller phase: create_post_interview
#     * [create:completed:{N}]                        → caller phase: create_delegation / create_post_delegation
#     * [lint:completed:auto] (auto-lint return)      → caller phase: ingest_pre_lint (#618)
#     * [ingest:completed]                            → caller phase: cleanup_pre_ingest / ingest_post_lint / ingest_completed
#   - Caller-emitted terminal sentinel (caller emits it themselves at terminal phase):
#     * [cleanup:completed]                           → caller phase: cleanup_post_ingest → cleanup_completed
#
# Additionally (#552), capture the helper's sentinel line and echo it to
# stderr (the same channel as STOP_MSG). In Claude Code, stop-hook stderr is
# fed back to the assistant via the exit-2 contract, so emitting the sentinel
# to stderr guarantees Phase 5.4.4.1 sees it in the next context cycle.
# This is best-effort — helper missing / failure is recorded to diag log but
# does NOT change the block decision below.
#
# WORKFLOW_HINT / WORKFLOW_INCIDENT_TYPE は汎用名 (#604)。
# 旧 CREATE_HINT / CREATE_INCIDENT_TYPE は create_* 専用だったが、cleanup_* も
# 同型のため一般化した (#608 follow-up: ingest_* は廃止済み)。
WORKFLOW_HINT=""
WORKFLOW_INCIDENT_TYPE=""
case "$PHASE" in
  create_interview)
    # Issue #622: /rite:issue:create Delegation to Interview Pre-write recorded create_interview
    # but the interview sub-skill Defense-in-Depth patch (create_post_interview) did not fire
    # yet (either the sub-skill has not been invoked, is mid-execution, or its Pre-flight bash
    # block was skipped — the Bug Fix / Chore preset path in create-interview.md Phase 0.4.1
    # is the most likely offender since it skips Phase 0.5 and historically inlined the
    # Defense-in-Depth bash block at the end of the markdown only). stop-guard must block in
    # either position so the workflow does not silently end the turn before delegation.
    # DRIFT-CHECK ANCHOR (semantic): create-interview.md 🚨 MANDATORY Pre-flight section /
    # phase-transition-whitelist.sh create_interview entry と 3 site 対称。
    WORKFLOW_HINT="HINT: /rite:issue:create Delegation to Interview Pre-write recorded create_interview. The block may have fired immediately before the rite:issue:create-interview Skill invoke, OR while the interview sub-skill is mid-execution (create-interview.md MUST write create_post_interview via its 🚨 MANDATORY Pre-flight section before returning). In either case, do NOT stop. Continue: if interview has not been invoked yet, invoke it; if interview has returned <!-- [interview:skipped] --> or <!-- [interview:completed] --> but .rite-flow-state.phase is still create_interview, the sub-skill Pre-flight patch was skipped — run 🚨 Mandatory After Interview Step 0 (Immediate Bash Action: bash plugins/rite/hooks/flow-state-update.sh patch --phase create_post_interview --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 0.6. Do NOT stop.' --if-exists --preserve-error-count) → Step 1 (idempotent re-patch) → Phase 0.6 → Delegation Routing → terminal sub-skill in the SAME response turn. Grep recent context for '[CONTEXT] INTERVIEW_DONE=1' to confirm sub-skill return completed. Also grep for '[CONTEXT] PREFLIGHT_PATCH_FAILED=1' / '[CONTEXT] PREFLIGHT_CREATE_FAILED=1' / '[CONTEXT] INTERVIEW_RETURN_PATCH_FAILED=1' — if any present, the sub-skill Pre-flight / Return Output re-patch encountered disk full / permission denied; caller Step 0 / Step 1 serve as redundant retry. DO NOT stop before <!-- [create:completed:{N}] --> is output."
    # Issue #634 escalation: re-entry detected when error_count >= 1.
    if [ "${ERROR_COUNT:-0}" -ge 1 ]; then
      WORKFLOW_HINT="$WORKFLOW_HINT RE-ENTRY DETECTED (error_count=$((ERROR_COUNT + 1))): previous block did not advance the phase. Execute the above bash block NOW as your next tool call before any narrative output."
    fi
    ;;
  create_post_interview)
    # Issue #634: accumulated regression N+1 after #525/#444/#475/#552/#561/#622/#628.
    # Root cause hypothesis (Issue body §3): Bug Fix / Chore preset 経路では sub-skill 側処理が
    # 軽く return 直後の LLM turn-boundary heuristic が発火しやすい。HINT を more concrete に
    # し、orchestrator が consume すべき specific bash 名を含めることで「次に何をすべきか」の
    # cognitive load を最小化する。
    # DRIFT-CHECK ANCHOR (semantic): create.md 🚨 Mandatory After Interview Step 0 Immediate
    # Bash Action / create-interview.md Return Output [CONTEXT] INTERVIEW_DONE=1 marker と
    # 3 site 対称。
    WORKFLOW_HINT="HINT: Sub-skill rite:issue:create-interview returned. The return tag is a CONTINUATION TRIGGER, not a turn boundary. Immediately run 🚨 Mandatory After Interview Step 0 (Immediate Bash Action: bash plugins/rite/hooks/flow-state-update.sh patch --phase create_post_interview --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 0.6. Do NOT stop.' --if-exists --preserve-error-count) → Step 1 (re-patch timestamp) → Phase 0.6 (Task Decomposition Decision) → Delegation Routing Pre-write → invoke rite:issue:create-register (or create-decompose) in the SAME response turn. Grep recent context for '[CONTEXT] INTERVIEW_DONE=1' to confirm the sub-skill completed its return output. Also grep for '[CONTEXT] STEP_0_PATCH_FAILED=1' / '[CONTEXT] STEP_1_PATCH_FAILED=1' / '[CONTEXT] PREFLIGHT_PATCH_FAILED=1' / '[CONTEXT] PREFLIGHT_CREATE_FAILED=1' / '[CONTEXT] INTERVIEW_RETURN_PATCH_FAILED=1' — if any present, a patch site failed (disk full / permission denied); the 2 重 patch defense-in-depth (Step 0 + Step 1 + Pre-flight + Return Output re-patch) means at least one site should have succeeded, but if all 5 are concurrently failing you must resolve the underlying disk/permission issue before retrying. No GitHub Issue has been created yet."
    # Issue #634 escalation: error_count-based reminder. 2 回目以降の block では
    # LLM が recovery path を取っていない signal とみなして HINT を更に明示化。
    # verified-review F-12 / #636: bash 例の --next 引数を create.md Step 0 canonical と一致させ、
    # HINT 通り実行した際に flow-state の next_action が短縮版で上書きされる drift を防ぐ。
    if [ "${ERROR_COUNT:-0}" -ge 1 ]; then
      WORKFLOW_HINT="$WORKFLOW_HINT RE-ENTRY DETECTED (error_count=$((ERROR_COUNT + 1))): previous block did not result in continuation. If you are reading this HINT, execute the following bash block NOW as your next tool call (before any other text output): \`bash plugins/rite/hooks/flow-state-update.sh patch --phase create_post_interview --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 0.6. Do NOT stop.' --if-exists --preserve-error-count\`. After the bash block succeeds, proceed to Phase 0.6 in the SAME response turn."
    fi
    ;;
  create_delegation)
    WORKFLOW_HINT="HINT: Delegation sub-skill is in-flight. When it returns [create:completed:{N}], run Mandatory After Delegation self-check (Step 1/2 are no-ops if marker present) in the SAME response turn. DO NOT stop before the completion marker is output."
    ;;
  create_post_delegation)
    WORKFLOW_HINT="HINT: Terminal sub-skill returned without [create:completed:{N}] (defense-in-depth path). Run Mandatory After Delegation Step 2 (deactivate flow state) and Step 3 (output next-steps) in the SAME response turn to force the workflow into the terminal state."
    ;;
  cleanup)
    WORKFLOW_HINT="HINT: /rite:pr:cleanup Phase 1.0 (Activate Flow State) just recorded phase=cleanup, and Phase 1-4 have not completed yet. Continue executing the cleanup phases (state verification → branch operations → wiki ingest decision in Phase 4.W.1) in the SAME response turn. DO NOT stop before reaching at least cleanup_pre_ingest (Phase 4.W.2) or cleanup_completed (Phase 5)."
    ;;
  cleanup_pre_ingest)
    # cycle 10 F-05: 末尾 `[cleanup:completed]` を `<!-- [cleanup:completed] -->` に統一
    # (cleanup_post_ingest HINT と asymmetry を解消、#561 bare-sentinel 対策を full 達成)
    # Issue #650: Step 0 Immediate Bash Action pattern を HINT に literal として含め、
    # ingest sub-skill return 直後の canonical continuation 手順を明示する。
    # DRIFT-CHECK ANCHOR (semantic — Issue #650): 本 HINT 内の bash block literal は
    # cleanup.md 🚨 Mandatory After Wiki Ingest Step 0 (Immediate Bash Action) / wiki/ingest.md
    # Phase 9.1 Step 3 (terminal patch ingest_completed, active=false) と **3 site 対称**。
    # いずれか 1 site を更新する際は他 2 site も同時更新する必要がある。特に bash 引数
    # (--phase / --next / --preserve-error-count) の symmetry が崩れると error_count reset loop
    # (create.md verified-review cycle 3 F-01 と同型) が再発する。
    WORKFLOW_HINT="HINT: /rite:pr:cleanup Phase 4.W.2 phase recorded. The block may have fired immediately before the rite:wiki:ingest Skill invoke, OR while the ingest sub-skill is mid-execution (ingest.md does not write its own flow-state directly via cleanup_* phases, but the caller phase remains pinned during sub-skill invocation modulo the ring structure for ingest_pre_lint / ingest_post_lint / ingest_completed). In either case, do NOT stop. Continue: if ingest has not been invoked yet, invoke it; if ingest has returned <!-- [ingest:completed] --> (grep -F '[ingest:completed]') or [CONTEXT] WIKI_INGEST_DONE=1 (grep -F '[CONTEXT] WIKI_INGEST_DONE='), immediately run 🚨 Mandatory After Wiki Ingest Step 0 (Immediate Bash Action: \`bash plugins/rite/hooks/flow-state-update.sh patch --phase cleanup_post_ingest --active true --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 5 Completion Report. Do NOT stop.' --if-exists --preserve-error-count\`) → Step 1 (idempotent re-patch) → Step 2 (Phase 5 Completion Report: user-visible message + cleanup_completed deactivate + <!-- [cleanup:completed] --> sentinel as absolute last line) in the SAME response turn. Grep recent context for '[CONTEXT] STEP_0_PATCH_FAILED=1' / '[CONTEXT] STEP_1_PATCH_FAILED=1' — if either present, a patch site failed (disk full / permission denied); the 2 重 patch defense-in-depth (Step 0 + Step 1) means at least one site should have succeeded. DO NOT stop before <!-- [cleanup:completed] --> is output."
    # Issue #650 escalation: error_count-based reminder. 2 回目以降の block では
    # LLM が recovery path を取っていない signal とみなして HINT を更に明示化 (create.md
    # create_post_interview case arm と同型パターン、#634 / #636 cycle 8 F-07 参照)。
    if [ "${ERROR_COUNT:-0}" -ge 1 ]; then
      WORKFLOW_HINT="$WORKFLOW_HINT RE-ENTRY DETECTED (error_count=$((ERROR_COUNT + 1))): previous block did not advance the phase. If you are reading this HINT, execute the following bash block NOW as your next tool call (before any other text output): \`bash plugins/rite/hooks/flow-state-update.sh patch --phase cleanup_post_ingest --active true --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 5 Completion Report. Do NOT stop.' --if-exists --preserve-error-count\`. After the bash block succeeds, proceed to Phase 5 Completion Report in the SAME response turn."
    fi
    ;;
  cleanup_post_ingest)
    # cycle 9 F-13: instruction 語順を cleanup.md Phase 5.3 Output ordering (Step 1 deactivate
    # → Step 2 sentinel) と揃える (旧語順は sentinel → deactivate で逆順、LLM が sentinel を
    # 先に emit すると bash 後続 output で sentinel が最終行でなくなる bare-sentinel 類似 bug
    # #561 の再発リスクがあった)。TC-608-H pinned phrase (rite:wiki:ingest returned /
    # Phase 5 Completion Report has NOT been output) は維持。
    # Issue #650: bash block literal 追加で canonical continuation 手順を明示。HINT が
    # 「何をすべきか」を abstract に述べるだけでなく、LLM が直接実行可能な bash 呼び出しを
    # 含むことで cognitive load を最小化する (create.md create_post_interview case arm と同型)。
    # DRIFT-CHECK ANCHOR (semantic — Issue #650): 本 HINT 内の bash block literal は
    # cleanup.md 🚨 Mandatory After Wiki Ingest Step 0 (Immediate Bash Action) / wiki/ingest.md
    # Phase 9.1 Step 3 (terminal patch ingest_completed, active=false) と **3 site 対称**。
    # cleanup_pre_ingest case arm と同じく bash 引数 symmetry を死守する必要あり。
    WORKFLOW_HINT="HINT: rite:wiki:ingest returned and cleanup_post_ingest is recorded. Phase 5 Completion Report has NOT been output yet. In the SAME response turn, output the cleanup completion message + next-steps block (user-visible content), THEN deactivate flow state (cleanup_completed, active: false via \`bash plugins/rite/hooks/flow-state-update.sh patch --phase cleanup_completed --next none --active false --if-exists\`), THEN output <!-- [cleanup:completed] --> HTML comment sentinel as the absolute last line of the response. Grep recent context for '[CONTEXT] STEP_0_PATCH_FAILED=1' / '[CONTEXT] STEP_1_PATCH_FAILED=1' — if either present, the previous Step 0 / Step 1 patch failed (disk full / permission denied); Phase 5 Completion Report will still execute, but the terminal deactivate patch (cleanup_completed) must succeed or the next session will see stale active=true state (session-end.sh cleanup lifecycle WARN will surface it). DO NOT stop before <!-- [cleanup:completed] --> is output."
    # Issue #650 escalation: error_count-based reminder (cleanup_pre_ingest case arm と対称)。
    if [ "${ERROR_COUNT:-0}" -ge 1 ]; then
      WORKFLOW_HINT="$WORKFLOW_HINT RE-ENTRY DETECTED (error_count=$((ERROR_COUNT + 1))): previous block did not result in Phase 5 continuation. If you are reading this HINT, execute the following bash block NOW as your next tool call (before any other text output): \`bash plugins/rite/hooks/flow-state-update.sh patch --phase cleanup_completed --next none --active false --if-exists\`. After the bash block succeeds, output the Phase 5 Completion Report user-visible message + <!-- [cleanup:completed] --> HTML comment sentinel as absolute last line in the SAME response turn."
    fi
    ;;
  ingest_pre_lint)
    # Issue #618 (reverts the #608 follow-up YAGNI removal): ingest.md Phase 8.2 Pre-write
    # patches this phase before invoking `rite:wiki:lint --auto`. If the block fires here,
    # the LLM tried to end the turn either immediately before the lint Skill invoke or
    # while the lint sub-skill is mid-execution. The only valid continuation is to run
    # 🚨 Mandatory After Auto-Lint Step 1 (patch ingest_post_lint) → Phase 8.3 (Lint parse)
    # → 8.4/8.5 → Phase 9 (Completion Report + caller continuation HTML comment + sentinel).
    # DRIFT-CHECK ANCHOR (semantic): ingest.md 🚨 Mandatory After Auto-Lint section /
    # phase-transition-whitelist.sh ingest_pre_lint entry と 3 site 対称。
    WORKFLOW_HINT="HINT: /rite:wiki:ingest Phase 8.2 Pre-write recorded ingest_pre_lint. The block may have fired immediately before the rite:wiki:lint --auto Skill invoke, OR while the lint sub-skill is mid-execution. Do NOT stop. Continue: if lint has not been invoked yet, invoke it; if lint has returned (check recent output for <!-- [lint:completed:auto] --> HTML comment sentinel or Lint: 6-field line), run 🚨 Mandatory After Auto-Lint Step 1 (patch ingest_post_lint) → Step 2 (Phase 8.3 Lint parse → 8.4/8.5 → Phase 9 Completion Report) → Step 3 (output caller continuation HTML comment + <!-- [ingest:completed] --> sentinel as absolute last line) in the SAME response turn. DO NOT stop before <!-- [ingest:completed] --> is output."
    ;;
  ingest_post_lint)
    # Issue #618: ingest.md 🚨 Mandatory After Auto-Lint Step 1 patched ingest_post_lint
    # but Phase 8.3-9 have NOT been output yet. TC-618 pinned phrase (rite:wiki:lint --auto
    # returned / Phase 9 Completion Report has NOT been output) is the semantic analogue of
    # cleanup_post_ingest TC-608-H pin.
    WORKFLOW_HINT="HINT: rite:wiki:lint --auto returned and ingest_post_lint is recorded. Phase 9 Completion Report has NOT been output yet. In the SAME response turn, execute Phase 8.3 (Lint result parse) → Phase 8.4 (Ingest 完了レポート統合) → Phase 8.5 (n_warnings 加算) → Phase 9 (user-visible completion message), THEN output caller continuation HTML comment (<!-- continuation: caller MUST proceed ... -->), THEN deactivate flow state (ingest_completed, active:false via Phase 9.1 Step 3 bash block), THEN output <!-- [ingest:completed] --> HTML comment sentinel as the absolute last line of the response. DO NOT stop."
    ;;
esac

# Consolidate sentinel type: every active workflow blocked here is treated as a
# manual fallback candidate. If a future phase needs a different sentinel type,
# switch to case-based assignment (see F-17 resolution).
if [ -n "$WORKFLOW_HINT" ]; then
  WORKFLOW_INCIDENT_TYPE="manual_fallback_adopted"
else
  WORKFLOW_INCIDENT_TYPE=""
fi

# #552 / #604: Emit workflow_incident sentinel when stop-guard blocks a
# recognised workflow phase. The sentinel is captured from the helper's stdout,
# then echoed to stderr so it reaches the assistant via the exit-2 feedback
# contract (same channel as STOP_MSG below). Phase 5.4.4.1 grep-detects it in
# the next context cycle.
# Non-blocking per #552 design: helper failure is recorded to diag log but does
# not alter the stop-block decision.
if [ -n "$WORKFLOW_INCIDENT_TYPE" ]; then
  INCIDENT_HELPER="$SCRIPT_DIR/workflow-incident-emit.sh"
  if [ -f "$INCIDENT_HELPER" ]; then
    if [ ! -x "$INCIDENT_HELPER" ]; then
      log_diag "incident_helper_not_executable path=$INCIDENT_HELPER session_id=${SESSION_ID:-unknown}"
    fi
    # capture stdout (sentinel line) and stderr (validation errors) separately.
    # mktemp failure is recorded to diag log (not silent fallback — #552 cycle 2 F-04).
    _emit_stderr=""
    if _emit_stderr=$(mktemp 2>/dev/null); then
      # register tempfile for trap cleanup (trap scope: EXIT/INT/TERM).
      # NOTE: this **replaces** the existing TMP_STATE trap installed immediately after the
      # `TMP_STATE=$(mktemp ...)` for the error_count increment block (above this block,
      # `trap 'rm -f "$TMP_STATE" 2>/dev/null' EXIT TERM INT`) with a new handler that cleans
      # up BOTH TMP_STATE and _emit_stderr. bash trap cannot append actions to an existing
      # handler — the new `trap '...'` declaration overwrites the previous one for the same
      # signal set. The replacement keeps `rm -f "$TMP_STATE"` explicit so TMP_STATE cleanup
      # still happens. (line-number 参照を避ける理由は cycle 8 F-05 参照)
      # F-02 (#636 cycle 7): SIGHUP 追加で上の trap と対称化 (SSH disconnect 時 orphan 防止)。
      # `_mv_err` はこの scope では既に使用終了しているが、正常 path 実行順の前提で `${_mv_err:-}`
      # を引き続き cleanup 対象に含めても害なし (trap 非対称による silent leak の再発防止)。
      trap 'rm -f "$TMP_STATE" "${_emit_stderr:-}" "${_mv_err:-}" 2>/dev/null' EXIT TERM INT HUP
    else
      log_diag "incident_emit_stderr_mktemp_failed session_id=${SESSION_ID:-unknown}"
      # _emit_stderr stays empty; stderr will be redirected to /dev/null below
    fi
    # CRITICAL (#552 cycle 2 F-01): capture exit code via `if` form, NOT `|| true`.
    # `cmd || true` causes $? to always be 0 (true's exit), making helper failure detection dead.
    # Using `if ! cmd; then rc=$?; else rc=0` correctly captures the helper's own exit code.
    _emit_rc=0
    if [ -n "$_emit_stderr" ]; then
      if ! _sentinel_line=$(bash "$INCIDENT_HELPER" \
          --type "$WORKFLOW_INCIDENT_TYPE" \
          --details "stop-guard blocked implicit stop in phase=$PHASE (issue=#$ISSUE)" \
          --pr-number "${PR:-0}" 2>"$_emit_stderr"); then
        _emit_rc=$?
      fi
    else
      # stderr unavailable (mktemp failure) — discard helper stderr but still capture rc
      if ! _sentinel_line=$(bash "$INCIDENT_HELPER" \
          --type "$WORKFLOW_INCIDENT_TYPE" \
          --details "stop-guard blocked implicit stop in phase=$PHASE (issue=#$ISSUE)" \
          --pr-number "${PR:-0}" 2>/dev/null); then
        _emit_rc=$?
      fi
    fi
    if [ -n "$_sentinel_line" ]; then
      # echo to stderr so Claude Code feeds it back via exit-2 contract
      echo "$_sentinel_line" >&2
    fi
    log_diag "incident_emit type=$WORKFLOW_INCIDENT_TYPE rc=$_emit_rc sentinel_captured=$([ -n "$_sentinel_line" ] && echo 1 || echo 0) phase=$PHASE session_id=${SESSION_ID:-unknown}"
    # helper validation errors: record stderr whenever non-empty (decoupled from rc check
    # per #552 cycle 2 F-05 — empty-stdout-with-rc=0 is also anomalous and deserves surfacing).
    if [ -n "$_emit_stderr" ] && [ -s "$_emit_stderr" ]; then
      log_diag "incident_emit_stderr rc=$_emit_rc first_line=$(head -1 "$_emit_stderr" | tr -d '\n' | head -c 200)"
    fi
    # anomalous empty-stdout path: helper exited 0 but produced no sentinel.
    if [ "$_emit_rc" -eq 0 ] && [ -z "$_sentinel_line" ]; then
      log_diag "incident_emit_empty_stdout type=$WORKFLOW_INCIDENT_TYPE phase=$PHASE session_id=${SESSION_ID:-unknown}"
    fi
    if [ -n "$_emit_stderr" ]; then
      rm -f "$_emit_stderr" 2>/dev/null
      _emit_stderr=""  # clear before trap fires to avoid double-rm warning
    fi
  else
    log_diag "incident_helper_not_found path=$INCIDENT_HELPER session_id=${SESSION_ID:-unknown}"
  fi
fi

if [ -n "$WORKFLOW_HINT" ]; then
  cat >&2 <<STOP_MSG
[rite] Normal operation — stop prevented.
Phase: $PHASE | Issue: #$ISSUE | PR: #$PR
ACTION: $NEXT
$WORKFLOW_HINT
Do NOT re-invoke any completed skill. Do NOT stop.
STOP_MSG
else
  cat >&2 <<STOP_MSG
[rite] Normal operation — stop prevented.
Phase: $PHASE | Issue: #$ISSUE | PR: #$PR
ACTION: $NEXT
Do NOT re-invoke any completed skill. Do NOT stop.
STOP_MSG
fi
exit 2
