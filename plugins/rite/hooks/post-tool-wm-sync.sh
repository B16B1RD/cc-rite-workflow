#!/bin/bash
# rite workflow - PostToolUse Work Memory Sync Hook
# Auto-creates local work memory when missing during an active workflow.
# Also auto-syncs Issue comment work memory when phase changes.
# Fires after every Bash tool use; quick-exits in most cases.
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_POSTTOOL:-}" ] || exit 0
export _RITE_HOOK_RUNNING_POSTTOOL=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"

# Recursion guard
[ -z "${RITE_WM_HOOK_ACTIVE:-}" ] || exit 0
export RITE_WM_HOOK_ACTIVE=1

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Lightweight rite-project gate (subprocess-free early-exit).
# Before spawning state-path-resolve.sh (git rev-parse ×2) and flow-state.sh
# path below, cheaply check whether CWD is inside a rite project by walking up
# for a rite marker using bash built-ins only — no git / helper subprocess. A
# non-rite project has neither marker and exits here, so every Bash tool call in
# projects that do not use rite pays only this walk instead of the resolver
# spawns. The marker is `rite-config.yml` (a tracked file, so it is checked out
# in multi_session worktrees where the .rite state dir lives only in the main
# checkout) OR the `.rite` state dir (present in the main checkout). Whenever the
# resolver would have found an active flow-state, one of these markers exists at
# or above CWD, so the gate never skips real work. Parent-walk uses `${d%/*}`
# (not dirname) to stay subprocess-free. Read-only: no marker is written
# (MUST NOT). A permission-denied ancestor makes the `[ -f ]` / `[ -d ]`
# marker test false, but that requires the repo root itself to be unreadable
# mid-workflow, where the flow is already broken — the optimized path is the
# common non-rite one.
_rite_gate_dir="$CWD"
_rite_gate_found=0
while : ; do
  if [ -f "$_rite_gate_dir/rite-config.yml" ] || [ -d "$_rite_gate_dir/.rite" ]; then
    _rite_gate_found=1
    break
  fi
  [ "$_rite_gate_dir" = "/" ] && break
  _rite_gate_parent="${_rite_gate_dir%/*}"
  # `${x%/*}` leaves a slashless segment unchanged — for a relative CWD (e.g.
  # `a/b/c` reduced to `a`) there is no `/` to strip, so the value stops
  # changing. Break on no-progress to avoid an infinite loop; an empty result
  # means the segment sat directly under root, so continue from `/`. (The
  # harness supplies an absolute .cwd in practice, but a relative one would
  # otherwise spin forever here.)
  [ "$_rite_gate_parent" = "$_rite_gate_dir" ] && break
  _rite_gate_dir="${_rite_gate_parent:-/}"
done
[ "$_rite_gate_found" = "1" ] || exit 0

# Resolve state root (git root or CWD)
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Per-session state path resolution (v3 SoT): flow-state.sh path always
# returns the per-session file (`<root>/.rite/sessions/<session_id>.flow-state`)
# — the legacy single-file `.rite-flow-state` selection path was removed.
# The atomic write below (last_synced_phase update) targets the
# resolved per-session file, preserving per-session isolation.
if FLOW_STATE=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" path 2>/dev/null); then
  :
else
  # Resolver failed (helper deploy regression / path validation rejection).
  # stderr was suppressed above to keep the hook silent in the common case;
  # surface the failure under RITE_DEBUG so deploy regressions are observable.
  [ -n "${RITE_DEBUG:-}" ] && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] post-tool-wm-sync: flow-state.sh path resolution failed, skipping wm sync" \
    >> "$STATE_ROOT/.rite-flow-debug.log" 2>/dev/null || true
  FLOW_STATE=""
fi
[ -f "$FLOW_STATE" ] || exit 0

# Unit separator (\x1f) prevents POSIX IFS from collapsing adjacent
# whitespace delimiters. With tab, .phase="" + non-empty .last_synced_phase
# would left-shift every field so _phase and _last_synced_phase swap,
# making the diff guard fire erroneously and sending the wrong value
# through issue-comment-wm-sync.sh --transform update-phase.
_flow_data=$(jq -r '[(.active // false | tostring), (.issue_number // "" | tostring), (.phase // "" | tostring), (.last_synced_phase // "" | tostring)] | join("\u001f")' "$FLOW_STATE" 2>/dev/null) || exit 0
IFS=$'\x1f' read -r _active issue_number _phase _last_synced_phase <<< "$_flow_data"
[ "$_active" = "true" ] || exit 0
[ -n "$issue_number" ] || exit 0
# Session ownership check: skip sync for other session's state.
#
# Note: $FLOW_STATE is always a per-session file, so
# `check_session_ownership` returns "own" via its per-session fast-path without
# invoking jq, and the `|| _ownership="own"` defensive default is dead code on
# that path. The default is retained as defense-in-depth for a non-resolver
# caller that bypasses the per-session fast-path (session-ownership.sh's
# foreign-path / 4-state fall-through), where extract_session_id /
# get_state_session_id may fail under environmental issues (jq error, IO error).
_ownership=$(check_session_ownership "$INPUT" "$FLOW_STATE") || _ownership="own"
[ "$_ownership" != "other" ] || exit 0
# Defense-in-depth: don't recreate WM for completed workflows
[ "$_phase" != "completed" ] || exit 0
[ "$_phase" != "cleanup" ] || exit 0

LOCAL_WM="$STATE_ROOT/.rite-work-memory/issue-${issue_number}.md"

# Debug logging (moved before LOCAL_WM check for use in both code paths)
log_debug() {
  [ -n "${RITE_DEBUG:-}" ] && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] post-tool-wm-sync: $1" \
    >> "$STATE_ROOT/.rite-flow-debug.log" 2>/dev/null || true
}

if [ ! -f "$LOCAL_WM" ]; then
  # --- Existing logic: auto-create local WM when missing ---
  log_debug "local WM missing for issue #${issue_number}, auto-creating"

  cd "$STATE_ROOT" || exit 0
  # source 失敗を RITE_DEBUG 環境変数の有無に依存させると、未設定時に WM 自動作成系の
  # syntax error / 不在を完全 silent に握り潰す。peer hook (session-end.sh 等) と揃え、
  # unconditional に WARNING を出して観測性を確保する。
  source "$SCRIPT_DIR/work-memory-update.sh" || {
    echo "[rite] WARNING: post-tool-wm-sync: failed to source work-memory-update.sh — local WM 自動作成を skip" >&2
    exit 0
  }
  export WM_PLUGIN_ROOT="${WM_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"

  # Unit separator (\x1f) keeps an empty .next_action from being collapsed by
  # IFS (tab/space would let read shift later fields into earlier columns).
  _wm_data=$(jq -r '[(.phase // "unknown"), (.next_action // "")] | join("\u001f")' "$FLOW_STATE" 2>/dev/null) || _wm_data=$'unknown\x1f'
  IFS=$'\x1f' read -r phase next_action <<< "$_wm_data"

  export WM_SOURCE="auto_hook"
  export WM_PHASE="$phase"
  export WM_PHASE_DETAIL="Auto-created by PostToolUse hook"
  export WM_NEXT_ACTION="$next_action"
  export WM_BODY_TEXT="Local work memory auto-created by PostToolUse hook."
  export WM_ISSUE_NUMBER="$issue_number"

  # update_local_work_memory rc: 0=success, 1=skip (no issue / flow-state未解決), 2=write failure。
  # work-memory-update.sh は rc=2 を lock contention / mkdir / mktemp / mv / state-read helper
  # 5 経路で共有する設計のため、WARNING に actual stderr 参照を含める
  # (rc=2 単独で原因を断定すると operator triage が誤誘導される)。
  if update_local_work_memory; then
    log_debug "local WM created successfully"
  else
    _wm_rc=$?
    case "$_wm_rc" in
      1)
        log_debug "update_local_work_memory skipped (rc=1)"
        ;;
      2)
        echo "[rite] WARNING: post-tool-wm-sync: local WM 作成失敗 (rc=2: lock 競合 / mkdir / mktemp / mv / state-read のいずれか — 直前の work-memory-update.sh stderr を参照; wm_write_failure_unspecified)。次の sync で再試行されます。" >&2
        ;;
      *)
        echo "[rite] WARNING: post-tool-wm-sync: local WM 作成が rc=$_wm_rc で失敗 (unexpected — work-memory-update.sh 仕様外の rc)。" >&2
        ;;
    esac
  fi
  exit 0
fi

# === Phase diff detection & Issue comment auto-sync ===
# Scope: phase changes only. next_action and loop_count changes are
# handled by explicit calls in command files (Phase 2 follow-up).
[ -n "$_phase" ] || exit 0
[ "$_phase" != "$_last_synced_phase" ] || exit 0

log_debug "phase changed: $_last_synced_phase -> $_phase, syncing to issue comment"

# --- 1. Phase update ---
# Run the python3|jq pipeline under pipefail with a captured stderr tempfile so a
# python3 crash (missing interpreter, traceback on malformed LOCAL_WM) surfaces as
# a WARNING instead of masquerading as a successful-but-empty parse that silently
# routes to the $_phase fallback. The stderr_capture=disabled tag distinguishes
# "no stderr emitted" from "we lost the stderr because /tmp is broken".
_phase_detail=""
_pd_err=$(mktemp 2>/dev/null) || _pd_err=""
_pd_rc=0
_phase_detail=$(set -o pipefail; python3 "$SCRIPT_DIR/work-memory-parse.py" "$LOCAL_WM" 2>"${_pd_err:-/dev/null}" \
  | jq -r '.data.phase_detail // ""' 2>>"${_pd_err:-/dev/null}") || _pd_rc=$?
if [ "$_pd_rc" -ne 0 ]; then
  _pd_tag=""
  [ -z "$_pd_err" ] && _pd_tag=" stderr_capture=disabled"
  echo "[rite] WARNING: post-tool-wm-sync: phase_detail 取得失敗 (rc=$_pd_rc${_pd_tag}) — phase 名に縮退" >&2
  [ -n "$_pd_err" ] && [ -s "$_pd_err" ] && head -3 "$_pd_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  _phase_detail=""
fi
[ -n "$_pd_err" ] && rm -f "$_pd_err"
[ -n "$_phase_detail" ] || _phase_detail="$_phase"

# Capture sync rc so a failed phase update does NOT advance last_synced_phase —
# advancing on failure makes the same phase skip its retry indefinitely until
# the user changes phase again, producing a silent drift in Issue comment work
# memory (gh auth expiry / rate limit / network failure all leave no trace
# under the previous `2>/dev/null || log_debug` swallow).
# Tag the WARNING with `stderr_capture=disabled` when mktemp fails so triagers
# can distinguish "sync failed AND we lost the root-cause stderr" from "sync
# failed and the captured stderr below tells us why". Without this flag a
# rate-limit / auth-expiry failure on a hardened CI runner (read-only /tmp,
# inode exhaustion, SELinux deny) is indistinguishable from "the helper
# emitted no stderr at all".
_phase_sync_err=$(mktemp 2>/dev/null) || _phase_sync_err=""
_phase_sync_stderr_tag=""
[ -z "$_phase_sync_err" ] && _phase_sync_stderr_tag=" stderr_capture=disabled"
_phase_sync_ok=0
if "$SCRIPT_DIR/issue-comment-wm-sync.sh" update \
    --issue "$issue_number" \
    --transform update-phase \
    --phase "$_phase" \
    --phase-detail "$_phase_detail" 2>"${_phase_sync_err:-/dev/null}"; then
  _phase_sync_ok=1
else
  _rc=$?
  echo "[rite] WARNING: post-tool-wm-sync: update-phase failed (rc=$_rc${_phase_sync_stderr_tag}) — last_synced_phase will NOT be advanced so next hook invocation retries" >&2
  [ -n "$_phase_sync_err" ] && [ -s "$_phase_sync_err" ] && head -3 "$_phase_sync_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi
[ -n "$_phase_sync_err" ] && rm -f "$_phase_sync_err"

# --- 2. Progress table + changed files update (per-commit and post-implementation phases) ---
# Flat phase `implement` fires for every commit during implementation (so the
# progress table can track files added/modified incrementally); legacy
# `phase5_post_execute` is the pre-flat equivalent. lint/pr/review/fix/completed
# trigger end-of-cycle refresh.
case "$_phase" in
  phase5_lint|phase5_post_lint|phase5_post_execute|phase5_pr*|phase5_post_review|phase5_post_ready|implement|lint|pr|review|fix|completed)
    cd "$STATE_ROOT" || { log_debug "cd STATE_ROOT failed"; exit 0; }

    # base branch を rite-config.yml から awk で抽出する。grep|sed の pipe では pipefail 無し
    # で sed の rc が握り潰され、config 不在 / permission denied / `base:` key 欠落の全てが
    # silent な `develop` fallback に集約されていた。awk の rc を独立 capture し fallback
    # 発動を RITE_DEBUG 時に観測可能にする。
    _base_rc=0
    _base_branch=$(awk '/^[[:space:]]+base:/ { sub(/^[[:space:]]+base:[[:space:]]*/, ""); gsub(/["'"'"'\r]/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$STATE_ROOT/rite-config.yml" 2>/dev/null) || _base_rc=$?
    if [ -z "$_base_branch" ] || [ "$_base_rc" -ne 0 ]; then
      _base_branch="develop"
      [ -n "${RITE_DEBUG:-}" ] && log_debug "rite-config.yml の base 取得が rc=$_base_rc / 空。default 'develop' にフォールバック"
    fi

    # mktemp fallback uses $$ + $RANDOM to avoid TOCTOU collision when two
    # Claude Code sessions share a PID; pure $$ on /tmp is race-prone.
    _changed_files_tmp=$(mktemp 2>/dev/null) || _changed_files_tmp="${TMPDIR:-/tmp}/rite-wm-sync-files.$$.${RANDOM}"
    _git_diff_err=$(mktemp 2>/dev/null) || _git_diff_err=""
    # State access uses STATE_ROOT (shared main checkout, via the `cd` above), but
    # the progress-table diff MUST run in the SESSION's working tree: under
    # multi-session, STATE_ROOT resolves to the main checkout while the session's
    # commits live in its linked worktree ($CWD). `git -C "$CWD"` targets that
    # tree (design §1). Non-worktree sessions have $CWD inside the same checkout,
    # so diff output (repo-root-relative paths) is unchanged.
    _diff_raw=$(git -C "$CWD" diff --name-status "origin/${_base_branch}...HEAD" 2>"${_git_diff_err:-/dev/null}") || _diff_raw=""
    if [ -n "$_git_diff_err" ] && [ -s "$_git_diff_err" ]; then
      echo "[rite] WARNING: post-tool-wm-sync: git diff failed — progress table may show stale or empty file list:" >&2
      head -3 "$_git_diff_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    [ -n "$_git_diff_err" ] && rm -f "$_git_diff_err"

    echo "$_diff_raw" | while IFS=$'\t' read -r status file; do
      [ -n "$status" ] || continue
      case "$status" in
        A) echo "- \`$file\` - 追加" ;;
        M) echo "- \`$file\` - 変更" ;;
        D) echo "- \`$file\` - 削除" ;;
        R*) echo "- \`$file\` - 名前変更" ;;
      esac
    done > "$_changed_files_tmp" 2>/dev/null || true

    _diff_files=$(echo "$_diff_raw" | awk -F'\t' '{print $2}')
    _impl_status="✅ 完了"
    _test_status="⬜ 未着手"
    _doc_status="⬜ 未着手"
    # Here-string avoids SIGPIPE from `grep -q` early-exit reaching the upstream `echo`.
    grep -qE '\.(test|spec)\.|test_|tests/' <<< "$_diff_files" 2>/dev/null && _test_status="✅ 完了"
    grep -qE '(docs/.*\.md|README\.md|CHANGELOG\.md|API\.md)' <<< "$_diff_files" 2>/dev/null && _doc_status="✅ 完了"

    _progress_sync_err=$(mktemp 2>/dev/null) || _progress_sync_err=""
    _progress_sync_stderr_tag=""
    [ -z "$_progress_sync_err" ] && _progress_sync_stderr_tag=" stderr_capture=disabled"
    # `if ! cmd; then _rc=$?` forces rc=0 inside the then-branch (POSIX `!` inverts
    # status). Use the else-branch to preserve the real exit code so triage logs
    # show `rc=N` (auth=1, rate-limit=4 etc.), not the misleading `rc=0`.
    if "$SCRIPT_DIR/issue-comment-wm-sync.sh" update \
        --issue "$issue_number" \
        --transform update-progress \
        --impl-status "$_impl_status" \
        --test-status "$_test_status" \
        --doc-status "$_doc_status" \
        --changed-files-file "$_changed_files_tmp" 2>"${_progress_sync_err:-/dev/null}"; then
      :
    else
      _rc=$?
      echo "[rite] WARNING: post-tool-wm-sync: update-progress failed (rc=$_rc${_progress_sync_stderr_tag}) — last_synced_phase will NOT be advanced" >&2
      [ -n "$_progress_sync_err" ] && [ -s "$_progress_sync_err" ] && head -3 "$_progress_sync_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      _phase_sync_ok=0
    fi
    [ -n "$_progress_sync_err" ] && rm -f "$_progress_sync_err"

    rm -f "$_changed_files_tmp"

    _plan_sync_err=$(mktemp 2>/dev/null) || _plan_sync_err=""
    _plan_sync_stderr_tag=""
    [ -z "$_plan_sync_err" ] && _plan_sync_stderr_tag=" stderr_capture=disabled"
    if "$SCRIPT_DIR/issue-comment-wm-sync.sh" update \
        --issue "$issue_number" \
        --transform update-plan-status 2>"${_plan_sync_err:-/dev/null}"; then
      :
    else
      _rc=$?
      echo "[rite] WARNING: post-tool-wm-sync: update-plan-status failed (rc=$_rc${_plan_sync_stderr_tag}) — last_synced_phase will NOT be advanced" >&2
      [ -n "$_plan_sync_err" ] && [ -s "$_plan_sync_err" ] && head -3 "$_plan_sync_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      _phase_sync_ok=0
    fi
    [ -n "$_plan_sync_err" ] && rm -f "$_plan_sync_err"

    log_debug "progress sync completed"
    ;;
esac

# --- 3. Update last_synced_phase only when ALL sync calls succeeded ---
# Advancing on partial failure would silently lose retry opportunity for the
# subset that failed; gating on _phase_sync_ok ensures the next hook invocation
# re-attempts every transformer that has not yet succeeded for this phase.
if [ "$_phase_sync_ok" = "1" ]; then
  _tmp_fs=$(mktemp "${FLOW_STATE}.tmp.XXXXXX" 2>/dev/null) || _tmp_fs="${FLOW_STATE}.tmp.$$.${RANDOM}"
  # jq の stderr を捕捉する: silent 失敗だと last_synced_phase が進まず、次回 hook で同じ phase
  # の全 transformer が再実行される。これを "sync 失敗" と "jq 失敗" で区別できないと triage が
  # 詰まる (root cause が見えないと operator が retry を諦める)。
  _last_phase_jq_err=$(mktemp 2>/dev/null) || _last_phase_jq_err=""
  if jq --arg p "$_phase" '.last_synced_phase = $p' "$FLOW_STATE" > "$_tmp_fs" 2>"${_last_phase_jq_err:-/dev/null}"; then
    # Silent mv failure would leave last_synced_phase un-advanced; the next
    # invocation would then re-run every transformer for this phase, masking
    # the underlying mv error. Capture stderr so errno detail surfaces.
    _lp_mv_err=$(mktemp 2>/dev/null) || _lp_mv_err=""
    if mv "$_tmp_fs" "$FLOW_STATE" 2>"${_lp_mv_err:-/dev/null}"; then
      :
    else
      _mv_rc=$?
      rm -f "$_tmp_fs"
      echo "rite: post-tool-wm-sync: mv last_synced_phase failed (rc=$_mv_rc)" >&2
      [ -n "$_lp_mv_err" ] && [ -s "$_lp_mv_err" ] && head -3 "$_lp_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    [ -n "$_lp_mv_err" ] && rm -f "$_lp_mv_err"
  else
    _last_phase_jq_rc=$?
    rm -f "$_tmp_fs"
    echo "rite: post-tool-wm-sync: WARNING: jq write of last_synced_phase failed (rc=$_last_phase_jq_rc) — next hook invocation will re-run all transformers" >&2
    [ -n "$_last_phase_jq_err" ] && [ -s "$_last_phase_jq_err" ] && head -3 "$_last_phase_jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  [ -n "$_last_phase_jq_err" ] && rm -f "$_last_phase_jq_err"
fi

log_debug "phase sync completed ($_last_synced_phase -> $_phase)"
exit 0
