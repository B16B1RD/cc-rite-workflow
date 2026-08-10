#!/bin/bash
# rite workflow - Session End Hook
# Saves final state when session ends
#
# Best-effort deactivation contract: this hook is Claude Code's
# SessionEnd lifecycle hook, so it only runs on exit paths the harness itself
# fires SessionEnd for. It does NOT run on a forced/abrupt termination of the
# session process (e.g. a killed/crashed process, or the hosting terminal
# being closed out from under it) — those paths never invoke this script, so
# the per-session flow-state is left exactly as last written, typically
# `active=true` with whatever `phase` was in progress. Deactivation
# (`.active = false` below) is therefore best-effort, NOT a guarantee.
#
# Consequently, code elsewhere that treats `active=true` as "do not touch —
# a live session still owns this" must not assume SessionEnd will eventually
# clear it. The actual safety net is the liveness TTL in
# pr-cycle-cleanup.sh's worktree/branch reap guard
# (`RITE_SESSION_LIVENESS_TTL_HOURS`, default 24h): an `active=true` holder is
# protected only while its flow-state `updated_at` is within that TTL, so a
# session whose termination skipped this hook eventually stops blocking reap
# instead of doing so forever.
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_SESSIONEND:-}" ] || exit 0
export _RITE_HOOK_RUNNING_SESSIONEND=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"
# session-ownership.sh provides the ownership guard consumed below. Sourcing is
# fail-open (2>/dev/null || true) so a missing or unparsable helper cannot block
# session-end's main job: persisting / deactivating the flow state.

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# (Under set -e, a missing jq would exit 127 at the first jq call, before
# reaching -f; the comment describes the logical invariant, not the exit path.)
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state file path using state-path-resolve.sh (consistent with other hooks)
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Resolve the active flow-state file: always the per-session file (the legacy
# single-file selection path was removed). Stderr is captured via the
# canonical _mktemp-stderr-guard.sh helper (see session-start.sh for the same pattern) so
# resolver WARNING/ERROR lines don't get silently dropped — even on the success
# arm, where helper graceful-degrade paths still emit diagnostics.
_resolve_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
  "session-end" \
  "resolve-flow-state-err" \
  "flow-state.sh path の WARNING/ERROR / jq parse error / indented 補助行が pass-through されません")
# Single-pass branch (filter runs once regardless of resolver exit status).
_resolve_failed=0
STATE_FILE=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" path 2>"${_resolve_err:-/dev/null}") || _resolve_failed=1
if [ -n "$_resolve_err" ] && [ -s "$_resolve_err" ]; then
  # Mirror of post-compact.sh resolver stderr handler. The grep below accepts only
  # WARNING:/ERROR:/jq:/indented continuation lines; any new prefix the resolver
  # adds (INFO:/DIAG:/Notice:/...) would be silently dropped without the counter.
  # RITE_DEBUG bypasses filtering entirely for triage.
  if [ -n "${RITE_DEBUG:-}" ]; then
    neutralize_ctrl --keep-newline < "$_resolve_err" >&2
  else
    # Use `grep -c ''` (matches every line, ignores trailing-newline differences)
    # so the total agrees with the filter `grep -c` below. `wc -l` undercounts
    # files without a trailing newline and would let `_resolve_err_dropped`
    # go negative when every line matches the keep-filter.
    _resolve_err_total=$(grep -c '' "$_resolve_err" 2>/dev/null) || _resolve_err_total=0
    # `$(cmd || echo 0)` is unsafe here: grep -c on no-match writes "0" to stdout
    # AND exits 1, so the `|| echo 0` appends a second "0" and the arithmetic
    # evaluation below explodes. Assignment + `|| var=0` keeps the value clean.
    _resolve_err_kept=$(grep -cE '^WARNING:|^ERROR:|^  |^jq: ' "$_resolve_err" 2>/dev/null) || _resolve_err_kept=0
    grep -E '^WARNING:|^ERROR:|^  |^jq: ' "$_resolve_err" >&2 || true
    _resolve_err_dropped=$((${_resolve_err_total:-0} - ${_resolve_err_kept:-0}))
    if [ "${_resolve_err_dropped:-0}" -gt 0 ]; then
      echo "[rite] WARNING: ${_resolve_err_dropped} resolver stderr lines filtered (use RITE_DEBUG=1 for full output)" >&2
    fi
  fi
fi
if [ "$_resolve_failed" -eq 1 ]; then
  STATE_FILE=""
  echo "[rite] WARNING: flow-state.sh path resolution failed — skip" >&2
fi
[ -n "$_resolve_err" ] && rm -f "$_resolve_err"

# Get current branch. Capture git stderr so that corrupt .git / permission denied
# / missing git binary surface a WARNING instead of collapsing into an empty
# BRANCH (which would silently hide the issue number from the session summary).
_br_err=$(mktemp 2>/dev/null) || _br_err=""
_br_rc=0
BRANCH=$(cd "$CWD" && git branch --show-current 2>"${_br_err:-/dev/null}") || _br_rc=$?
if [ "$_br_rc" -ne 0 ]; then
  echo "[rite] WARNING: session-end: git branch --show-current 失敗 (rc=$_br_rc — corrupt .git / permission denied / git unavailable の可能性)" >&2
  [ -n "$_br_err" ] && [ -s "$_br_err" ] && head -3 "$_br_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  BRANCH=""
fi
[ -n "$_br_err" ] && rm -f "$_br_err"

# Default-init ISSUE_NUMBER so `${ISSUE_NUMBER:+...}` expansions later in the
# script don't trip `set -u` when the branch is not an issue branch.
ISSUE_NUMBER=""
if [[ "$BRANCH" =~ issue-([0-9]+) ]]; then
    ISSUE_NUMBER="${BASH_REMATCH[1]}"
    echo "rite: Saving final state for Issue #$ISSUE_NUMBER"
fi

# Deactivate flow state if it exists
if [ -f "$STATE_FILE" ]; then
    # Session ownership check: only deactivate own/legacy/stale state.
    # Other session's fresh state (within 2h) must not be modified.
    # See pre-compact.sh: caller-side `2>/dev/null` would mute the corrupt-
    # state WARNING that exists to flag state-overwrite risk against another
    # active session.
    _ownership=$(check_session_ownership "$INPUT" "$STATE_FILE") || _ownership="own"
    if [ "$_ownership" = "other" ]; then
        # Another session's active state — do not modify
        echo "rite: skipping deactivation (state belongs to another session)" >&2
        exit 0
    fi

    # Lifecycle unfinished warnings for create_* / cleanup_* phases.
    # If the session is ending mid-lifecycle (active=true with a non-terminal phase),
    # emit an informational warning so the user knows what flow did NOT complete and
    # how to recover. session-end always proceeds with deactivation regardless.
    # Phase classification is an inline glob match on the phase name (the elif
    # branches below). The `type … >/dev/null` guards would defer to a sourced
    # phase-classifier helper if one were loaded; none ships today, so the glob
    # fallback is the active path.
    # corrupt JSON を silent 流すと lifecycle WARN_MSG が空 phase で抑制され、user は
    # create_*/cleanup_* の中断を知らないまま次セッションへ進む。stderr を capture して
    # operator が原因にたどり着けるようにする。
    _lifecycle_phase_err=$(mktemp 2>/dev/null) || _lifecycle_phase_err=""
    _state_phase=$(jq -r '.phase // empty' "$STATE_FILE" 2>"${_lifecycle_phase_err:-/dev/null}") || _state_phase=""
    if [ -n "$_lifecycle_phase_err" ] && [ -s "$_lifecycle_phase_err" ]; then
        echo "rite: session-end: WARNING: jq parse of .phase failed (STATE_FILE may be corrupt) — lifecycle WARN suppressed" >&2
        head -3 "$_lifecycle_phase_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    [ -n "$_lifecycle_phase_err" ] && rm -f "$_lifecycle_phase_err"
    _lifecycle_active_err=$(mktemp 2>/dev/null) || _lifecycle_active_err=""
    _state_active=$(jq -r '.active // false' "$STATE_FILE" 2>"${_lifecycle_active_err:-/dev/null}") || _state_active="false"
    if [ -n "$_lifecycle_active_err" ] && [ -s "$_lifecycle_active_err" ]; then
        echo "rite: session-end: WARNING: jq parse of .active failed (STATE_FILE may be corrupt)" >&2
        head -3 "$_lifecycle_active_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    [ -n "$_lifecycle_active_err" ] && rm -f "$_lifecycle_active_err"
    _lifecycle_unfinished_kind=""
    if [ "$_state_active" = "true" ]; then
        if type rite_phase_is_create_lifecycle_in_progress >/dev/null 2>&1; then
            if rite_phase_is_create_lifecycle_in_progress "$_state_phase"; then
                _lifecycle_unfinished_kind="create"
            fi
        elif [[ "$_state_phase" == create_* ]] && [ "$_state_phase" != "create_completed" ]; then
            _lifecycle_unfinished_kind="create"
        fi
        if [ -z "$_lifecycle_unfinished_kind" ]; then
            if type rite_phase_is_cleanup_lifecycle_in_progress >/dev/null 2>&1; then
                if rite_phase_is_cleanup_lifecycle_in_progress "$_state_phase"; then
                    _lifecycle_unfinished_kind="cleanup"
                fi
            elif [[ "$_state_phase" == "cleanup" || "$_state_phase" == cleanup_* ]] && [ "$_state_phase" != "cleanup_completed" ]; then
                # `cleanup*` (underscore なし) は将来 `cleanupXYZ` 等の派生 phase を誤検出するリスクがあるため、
                # `cleanup` 完全一致 / `cleanup_*` のみを対象に精密化 (create_* 側との対称性)
                _lifecycle_unfinished_kind="cleanup"
            fi
        fi
    fi
    case "$_lifecycle_unfinished_kind" in
        create)
            cat >&2 <<WARN_MSG
⚠️  rite: /rite:issue-create lifecycle was not completed (phase=$_state_phase).
    `create_*` phase は legacy sub-skill chain 時代の遺物で、現在の flat workflow は
    terminal phase=completed のみを書き込みます。この state file が残っているのは
    旧形式のセッションが中断したまま終わったことを意味します。
    /rite:recover または /rite:issue-create の再実行で回復できます。
WARN_MSG
            ;;
        cleanup)
            cat >&2 <<WARN_MSG
⚠️  rite: /rite:cleanup lifecycle was not completed (phase=$_state_phase).
    cleanup.md はフラットな ステップ 1-12 構造で、途中で中断されると flow-state に
    phase=cleanup, active=true が残ります。legacy phase 値 (cleanup_pre_ingest /
    cleanup_post_ingest / ingest_pre_lint / ingest_post_lint) は旧 ring 機構で書き込まれた
    state の resume routing 用途のみ残存しており、現行の cleanup.md / ingest.md は
    これらの transient phase を書き込みません。
    Re-run /rite:cleanup or use /rite:recover to recover.
WARN_MSG
            ;;
    esac

    # PID-based fallback so a broken mktemp (e.g. /tmp readonly) still produces
    # a unique sibling path instead of clobbering the state file via a fixed name.
    TMP_FILE=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null) || TMP_FILE="${STATE_FILE}.tmp.$$"
    # trap is inside this block: only active when STATE_FILE exists and TMP_FILE is created
    trap 'rm -f "$TMP_FILE" 2>/dev/null' EXIT TERM INT
    # SessionEnd stderr は次セッションの会話 context に流入しない経路があるため、jq / mv 失敗を
    # stderr に出しても次セッションの orchestrator からは grep されない。代替として diag log に
    # 持続化することで、次回 session-start の defensive reset が cause を surface できる。
    _deact_jq_err=$(mktemp 2>/dev/null) || _deact_jq_err=""
    if jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
       '.active = false | .updated_at = $ts' "$STATE_FILE" > "$TMP_FILE" 2>"${_deact_jq_err:-/dev/null}"; then
        _deact_mv_err=$(mktemp 2>/dev/null) || _deact_mv_err=""
        if mv "$TMP_FILE" "$STATE_FILE" 2>"${_deact_mv_err:-/dev/null}"; then
          :
        else
          _mv_rc=$?
          rm -f "$TMP_FILE"
          if command -v _log_flow_diag >/dev/null 2>&1; then
            _log_flow_diag "session_end_mv_failed rc=$_mv_rc state=$STATE_FILE"
          fi
          echo "rite: session-end: mv deactivation state failed (rc=$_mv_rc)" >&2
          [ -n "$_deact_mv_err" ] && [ -s "$_deact_mv_err" ] && head -3 "$_deact_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
        fi
        [ -n "$_deact_mv_err" ] && rm -f "$_deact_mv_err"
    else
        _deact_jq_rc=$?
        if command -v _log_flow_diag >/dev/null 2>&1; then
            _log_flow_diag "session_end_jq_failed rc=$_deact_jq_rc state=$STATE_FILE"
        fi
        # state_file path を WARNING に含めることで、Issue 番号が解決できない経路 (detached HEAD /
        # non-issue branch / git 未初期化) でも debug 情報を残せる。
        echo "rite: session-end: WARNING: failed to deactivate state file (jq rc=$_deact_jq_rc): $STATE_FILE${ISSUE_NUMBER:+ (Issue #$ISSUE_NUMBER)}" >&2
        [ -n "$_deact_jq_err" ] && [ -s "$_deact_jq_err" ] && head -3 "$_deact_jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
        rm -f "$TMP_FILE"
    fi
    [ -n "$_deact_jq_err" ] && rm -f "$_deact_jq_err"

    # AC-10: clean up per-session flow-state file on session end.
    # Note: this block also runs after the jq deactivation `else` arm above —
    # i.e. when the .active=false update failed. The per-session file is unique
    # to this session, so even a corrupt one has no value post-termination, and
    # leaving it would only confuse the next session-start defensive reset.
    # Detection: STATE_FILE matches `*/.rite/sessions/*.flow-state` (the per-session
    # path returned by `flow-state.sh path`, now the only resolved form).
    # A residual legacy `.rite-flow-state` single-file (left over from a pre-v3
    # checkout) is intentionally preserved here so the next session-start's
    # `flow-state.sh migrate` can absorb it into per-session/v3 rather than have it
    # silently deleted.
    # Stale-file cleanup (long-running sessions / crash leftovers) is out of scope
    # for this Issue (handled by a follow-up).
    if [[ "$STATE_FILE" == *"/.rite/sessions/"*".flow-state" ]] && [ -f "$STATE_FILE" ]; then
        # Surface rm failure (readonly fs / permission denied) so the next
        # session doesn't silently read stale state.
        rm -f "$STATE_FILE" 2>/dev/null || echo "[rite] WARNING: session-end: failed to remove per-session state file: $STATE_FILE" >&2
    fi
fi

# Clean up stale temporary files (older than 1 minute to avoid deleting in-progress writes).
# Mirrors the same find command in session-start.sh (the canonical source).
# `-not -name '.rite-flow-state.legacy.*'` defensively preserves any pre-v3
# `.rite-flow-state.legacy.*` backup as a manual-recovery source. The v3 in-place
# migrate does NOT create one — this only matters for files left over from the
# pre-v3 rename-based migration (the now-removed `flow-state-update.sh` design).
# DRY caveat: this cleanup is duplicated across session-start.sh and session-end.sh.
# If you change one, change the other — past fixes to one-side-only have produced
# CRITICAL regressions.
if [ -d "$CWD" ]; then
    find "$CWD" -maxdepth 1 \( -name ".rite-flow-state.tmp.*" -o -name ".rite-flow-state.??????*" \) -not -name ".rite-flow-state.legacy.*" -type f -mmin +1 -delete 2>/dev/null || true
fi
