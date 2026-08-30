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
# helper (issue-comment-wm-sync.sh) は CWD env を STATE_ROOT 解決に使う。export しないと
# subprocess の pwd が hook の起動ディレクトリのままになり、wm_replica が別 flow-state に書かれる。
export CWD

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
  [ -n "${RITE_DEBUG:-}" ] && mkdir -p "$STATE_ROOT/.rite/logs" 2>/dev/null && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] post-tool-wm-sync: flow-state.sh path resolution failed, skipping wm sync" \
    >> "$STATE_ROOT/.rite/logs/flow-debug.log" 2>/dev/null || true
  FLOW_STATE=""
fi
[ -f "$FLOW_STATE" ] || exit 0

# Unit separator (\x1f) prevents POSIX IFS from collapsing adjacent
# whitespace delimiters. With tab, .phase="" + non-empty .last_synced_phase
# would left-shift every field so _phase and _last_synced_phase swap,
# making the diff guard fire erroneously and sending the wrong value
# through issue-comment-wm-sync.sh --transform update-phase.
_flow_data=$(jq -r '[(.active // false | tostring), (.issue_number // "" | tostring), (.phase // "" | tostring), (.last_synced_phase // "" | tostring), (.wm_replica // "" | tostring)] | join("\u001f")' "$FLOW_STATE" 2>/dev/null) || exit 0
IFS=$'\x1f' read -r _active issue_number _phase _last_synced_phase _wm_replica <<< "$_flow_data"
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

_wm_new="$STATE_ROOT/.rite/work-memory/issue-${issue_number}.md"
_wm_old="$STATE_ROOT/.rite-work-memory/issue-${issue_number}.md"
if [ -f "$_wm_new" ]; then
  LOCAL_WM="$_wm_new"
elif [ -f "$_wm_old" ]; then
  LOCAL_WM="$_wm_old"
else
  LOCAL_WM="$_wm_new"
fi

# Debug logging (moved before LOCAL_WM check for use in both code paths)
log_debug() {
  [ -n "${RITE_DEBUG:-}" ] && mkdir -p "$STATE_ROOT/.rite/logs" 2>/dev/null && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] post-tool-wm-sync: $1" \
    >> "$STATE_ROOT/.rite/logs/flow-debug.log" 2>/dev/null || true
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

_phase_sync_ok=0
_sysmsg=""
_backup_file=""
_body_file=""
_updated_file=""
_changed_files_tmp=""
_obs_line=""

_rite_post_wm_cleanup() {
  [ -n "${_body_file:-}" ] && rm -f "$_body_file"
  [ -n "${_updated_file:-}" ] && rm -f "$_updated_file"
  [ -n "${_changed_files_tmp:-}" ] && rm -f "$_changed_files_tmp"
  return 0
}
# backup_file は失敗時 post-mortem 用に trap 対象外 (成功時のみ明示 rm)。
trap '_rite_post_wm_cleanup' EXIT

_set_sysmsg() { _sysmsg="$1"; }
_flush_sysmsg() {
  [ -z "$_sysmsg" ] && return 0
  jq -nc --arg m "$_sysmsg" '{systemMessage:$m}' 2>/dev/null || true
}

_gated_progress_phase() {
  case "$1" in
    phase5_lint|phase5_post_lint|phase5_post_execute|phase5_pr*|phase5_post_review|phase5_post_ready|implement|lint|pr|review|fix|completed)
      return 0 ;;
    *) return 1 ;;
  esac
}

_run_py_transform() {
  local transform="$1" infile="$2" outfile="$3"
  shift 3
  local py_err py_rc=0
  py_err=$(mktemp 2>/dev/null) || py_err=""
  ( set -o pipefail; cat "$infile" | python3 "$SCRIPT_DIR/issue-comment-wm-update.py" "$transform" "$@" > "$outfile" 2>"${py_err:-/dev/null}" ) || py_rc=$?
  if [ "$py_rc" -ne 0 ]; then
    echo "[rite] WARNING: post-tool-wm-sync: python transform $transform failed (rc=$py_rc). Backup: ${_backup_file:-none}" >&2
    [ -n "$py_err" ] && [ -s "$py_err" ] && head -3 "$py_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    [ -n "$py_err" ] && rm -f "$py_err"
    return "$py_rc"
  fi
  [ -n "$py_err" ] && rm -f "$py_err"
  return 0
}

if [ "$_wm_replica" = "absent" ]; then
  # 負キャッシュ済みなら gh を呼ばず last_synced_phase だけ進める (round_trips=0)。
  # ただし黙って進めない: `absent` の解除経路は replica の作成成功だけなので、init が
  # unverified / gh 失敗で終わるとこの分岐に永久に留まり、replica 同期が一度も行われないまま
  # debug ログ以外に何も出ない状態が続く (#2463)。劣化していることが phase 変化のたびに
  # ユーザーへ届くよう systemMessage を出す (gh 往復は増やさない)。
  log_debug "wm_replica=absent; skip gh; round_trips=0"
  _set_sysmsg "作業メモリの Issue コメント replica が無いため同期をスキップしています（Issue #${issue_number}）。/rite:open の replica 作成が失敗した可能性があります。同期を再開するには /rite:open を実行してください。"
  _phase_sync_ok=1
else
  # phase_detail: local WM から。失敗は phase 名に縮退 (既存契約)。
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

  _body_file=$(mktemp 2>/dev/null) || _body_file=""
  if [ -z "$_body_file" ]; then
    echo "[rite] WARNING: post-tool-wm-sync: body_file mktemp 失敗 — last_synced_phase will NOT be advanced" >&2
    _set_sysmsg "作業メモリ同期用の一時ファイルを作成できませんでした。ディスク容量を確認してください。"
  else
    _fetch_err=$(mktemp 2>/dev/null) || _fetch_err=""
    _fetch_rc=0
    _fetch_line=""
    # `if ! cmd; then _rc=$?` は POSIX `!` で rc が潰れるため else で実 rc を残す。
    if _fetch_line=$("$SCRIPT_DIR/issue-comment-wm-sync.sh" fetch \
        --issue "$issue_number" --out "$_body_file" 2>"${_fetch_err:-/dev/null}"); then
      :
    else
      _fetch_rc=$?
      echo "[rite] WARNING: post-tool-wm-sync: fetch failed (rc=$_fetch_rc) — last_synced_phase will NOT be advanced" >&2
    fi
    [ -n "$_fetch_err" ] && [ -s "$_fetch_err" ] && head -3 "$_fetch_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    [ -n "$_fetch_err" ] && rm -f "$_fetch_err"

    _fetch_status="${_fetch_line%%;*}"
    _fetch_status="${_fetch_status#status=}"
    _fetch_reason=""
    case "$_fetch_line" in
      *reason=*) _fetch_reason="${_fetch_line#*reason=}" ;;
    esac

    if [ "$_fetch_rc" -ne 0 ]; then
      _set_sysmsg "作業メモリ replica の取得に失敗しました。認証とネットワークを確認してください。次のツール実行時に再試行されます。"
    elif [ "$_fetch_status" = "skipped" ] && [ "$_fetch_reason" = "no_comment" ]; then
      # AC-4: 初回検知。fetch 側が wm_replica=absent を記録済み。legitimate no-op なので phase は進める。
      log_debug "fetch no_comment; round_trips=1 path=fetch"
      _set_sysmsg "作業メモリの Issue コメント replica が見つかりません。/rite:open が未実行か init に失敗しています。/rite:open を実行して replica を作成してください。"
      _phase_sync_ok=1
    elif [ "$_fetch_status" = "skipped" ] && [ "$_fetch_reason" = "body_fetch_failed" ]; then
      _set_sysmsg "作業メモリ replica の取得に失敗しました。認証・rate limit・ネットワークを確認してください。次のツール実行時に再試行されます。"
    elif [ "$_fetch_status" = "success" ]; then
      log_debug "fetch success; applying local transforms then one PATCH"
      _backup_file="${TMPDIR:-/tmp}/rite-wm-backup-${issue_number}-$(date +%s).md"
      cp "$_body_file" "$_backup_file" || true
      _orig_len=$(wc -c < "$_body_file" | tr -d ' ')
      _updated_file=$(mktemp 2>/dev/null) || _updated_file=""
      _xf_ok=1
      _last_transform="update-phase"

      if [ -z "$_updated_file" ]; then
        _xf_ok=0
        _set_sysmsg "作業メモリ同期用の一時ファイルを作成できませんでした。ディスク容量を確認してください。"
        echo "[rite] WARNING: post-tool-wm-sync: updated_file mktemp 失敗 — last_synced_phase will NOT be advanced" >&2
      elif ! _run_py_transform update-phase "$_body_file" "$_updated_file" \
          --phase "$_phase" --phase-detail "$_phase_detail"; then
        _xf_ok=0
        _set_sysmsg "作業メモリの変換に失敗したため更新を中止しました。バックアップを保持しています。"
        echo "[rite] WARNING: post-tool-wm-sync: update-phase transform failed — last_synced_phase will NOT be advanced" >&2
      else
        cp "$_updated_file" "$_body_file"

        _skip_progress=0
        if _gated_progress_phase "$_phase"; then
          cd "$STATE_ROOT" || { log_debug "cd STATE_ROOT failed"; _flush_sysmsg; exit 0; }

          _base_rc=0
          _base_branch=$(awk '/^[[:space:]]+base:/ { sub(/^[[:space:]]+base:[[:space:]]*/, ""); gsub(/["'"'"'\r]/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$STATE_ROOT/rite-config.yml" 2>/dev/null) || _base_rc=$?
          if [ -z "$_base_branch" ] || [ "$_base_rc" -ne 0 ]; then
            _sym=""
            _sym=$(git -C "$CWD" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) || _sym=""
            _base_branch="${_sym#refs/remotes/origin/}"
            if [ -z "$_base_branch" ] || [ "$_base_branch" = "$_sym" ]; then
              _skip_progress=1
              _base_branch=""
              _set_sysmsg "rite-config.yml の branch.base も origin/HEAD も解決できないため、進捗テーブルの更新をスキップしました。branch.base を設定するか git remote set-head origin --auto を実行してください。"
              log_debug "base-branch unresolved; skip update-progress (no develop fallback)"
            fi
          fi

          if [ "$_skip_progress" -eq 0 ]; then
            _changed_files_tmp=$(mktemp 2>/dev/null) || _changed_files_tmp="${TMPDIR:-/tmp}/rite-wm-sync-files.$$.${RANDOM}"
            _git_diff_err=$(mktemp 2>/dev/null) || _git_diff_err=""
            _diff_rc=0
            # State access uses STATE_ROOT (shared main checkout, via the `cd` above), but
            # the progress-table diff MUST run in the SESSION's working tree: under
            # multi-session, STATE_ROOT resolves to the main checkout while the session's
            # commits live in its linked worktree ($CWD). `git -C "$CWD"` targets that
            # tree (design §1). Non-worktree sessions have $CWD inside the same checkout,
            # so diff output (repo-root-relative paths) is unchanged.
            _diff_raw=$(git -C "$CWD" diff --name-status "origin/${_base_branch}...HEAD" 2>"${_git_diff_err:-/dev/null}") || _diff_rc=$?
            if [ "$_diff_rc" -ne 0 ] || { [ -n "$_git_diff_err" ] && [ -s "$_git_diff_err" ]; }; then
              _skip_progress=1
              _set_sysmsg "git diff に失敗したため進捗テーブルを更新できませんでした。origin の base ブランチが fetch 済みか確認してください。"
              echo "[rite] WARNING: post-tool-wm-sync: git diff failed — progress table not updated:" >&2
              [ -n "$_git_diff_err" ] && [ -s "$_git_diff_err" ] && head -3 "$_git_diff_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
            fi
            [ -n "$_git_diff_err" ] && rm -f "$_git_diff_err"
          fi

          if [ "$_skip_progress" -eq 0 ]; then
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
            grep -qE '\.(test|spec)\.|test_|tests/' <<< "$_diff_files" 2>/dev/null && _test_status="✅ 完了"
            grep -qE '(docs/.*\.md|README\.md|CHANGELOG\.md|API\.md)' <<< "$_diff_files" 2>/dev/null && _doc_status="✅ 完了"

            if ! _run_py_transform update-progress "$_body_file" "$_updated_file" \
                --impl-status "$_impl_status" \
                --test-status "$_test_status" \
                --doc-status "$_doc_status" \
                --changed-files-file "$_changed_files_tmp"; then
              _xf_ok=0
              _set_sysmsg "作業メモリの変換に失敗したため更新を中止しました。バックアップを保持しています。"
              echo "[rite] WARNING: post-tool-wm-sync: update-progress transform failed — last_synced_phase will NOT be advanced" >&2
            else
              cp "$_updated_file" "$_body_file"
              _last_transform="update-progress"
            fi
            rm -f "$_changed_files_tmp"
            _changed_files_tmp=""
          fi

          if [ "$_xf_ok" -eq 1 ]; then
            if ! _run_py_transform update-plan-status "$_body_file" "$_updated_file"; then
              _xf_ok=0
              _set_sysmsg "作業メモリの変換に失敗したため更新を中止しました。バックアップを保持しています。"
              echo "[rite] WARNING: post-tool-wm-sync: update-plan-status transform failed — last_synced_phase will NOT be advanced" >&2
            else
              cp "$_updated_file" "$_body_file"
              _last_transform="update-plan-status"
            fi
          fi
          log_debug "progress sync completed"
        fi
      fi

      if [ "$_xf_ok" = "1" ]; then
        _patch_err=$(mktemp 2>/dev/null) || _patch_err=""
        _patch_rc=0
        _patch_line=""
        if _patch_line=$("$SCRIPT_DIR/issue-comment-wm-sync.sh" patch \
            --issue "$issue_number" \
            --in "$_body_file" \
            --original-length "$_orig_len" \
            --transform-label "$_last_transform" 2>"${_patch_err:-/dev/null}"); then
          :
        else
          _patch_rc=$?
          echo "[rite] WARNING: post-tool-wm-sync: patch failed (rc=$_patch_rc) — last_synced_phase will NOT be advanced" >&2
        fi
        [ -n "$_patch_err" ] && [ -s "$_patch_err" ] && head -3 "$_patch_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
        [ -n "$_patch_err" ] && rm -f "$_patch_err"

        _patch_status="${_patch_line%%;*}"
        _patch_status="${_patch_status#status=}"
        if [ "$_patch_rc" -eq 0 ] && [ "$_patch_status" = "success" ]; then
          rm -f "$_backup_file"
          _backup_file=""
          _phase_sync_ok=1
          _obs_line="status=success round_trips=2"
          log_debug "round_trips=2 path=fetch+patch"
        else
          _set_sysmsg "作業メモリ replica の更新に失敗しました。バックアップを保持しています。認証とネットワークを確認してください。"
          echo "[rite] WARNING: post-tool-wm-sync: PATCH non-success (line=${_patch_line:-empty}) — last_synced_phase will NOT be advanced" >&2
        fi
      fi
    else
      # owner/repo 未解決等: status 行なし + exit 0。成功扱いすると last_synced_phase が進み
      # 同一 phase の再試行が消え、stderr WARNING は PostToolUse ではモデルに届かない。
      log_debug "fetch empty-status rc=${_fetch_rc}; treating as sync failure"
      _set_sysmsg "作業メモリ replica の取得先リポジトリを解決できませんでした。git remote と gh auth status を確認してください。次のツール実行時に再試行されます。"
    fi
  fi
fi

# --- Update last_synced_phase only when ALL sync calls succeeded ---
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

_flush_sysmsg
# PostToolUse stdout は JSON 1 object。systemMessage があるときは観測行を出さない。
if [ -z "${_sysmsg:-}" ] && [ -n "${_obs_line:-}" ]; then
  printf '%s\n' "$_obs_line"
fi
log_debug "phase sync completed ($_last_synced_phase -> $_phase)"
exit 0
