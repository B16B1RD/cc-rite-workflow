#!/bin/bash
# rite workflow - Session Start Hook
# Re-injects flow state after compact or resume.
# source=compact: recovery text (Issue/Phase/Branch/Next/Loop/PR + auto continue)
# is emitted here because SessionStart stdout is injected into model context.
# startup/resume/clear keep the interruption / recover notice.
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_SESSIONSTART:-}" ] || exit 0
export _RITE_HOOK_RUNNING_SESSIONSTART=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${RITE_DEBUG:-}" ]; then
  source "$SCRIPT_DIR/hook-preamble.sh" || true
else
  source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
fi

# Source session ownership helper for session_id extraction and ownership checks
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"
# shellcheck source=gitignore-ensure.sh
source "$SCRIPT_DIR/gitignore-ensure.sh"
# shellcheck source=relocated-state-migrate.sh
source "$SCRIPT_DIR/relocated-state-migrate.sh"

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# (Under set -e, a missing jq would exit 127 at the first jq call, before
# reaching -f; the comment describes the logical invariant, not the exit path.)
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# Plugin dual-load collision guard
# Only warn when this script is running from a local plugin-dir (not from
# the marketplace cache). Normal marketplace users should have it enabled.
# SCRIPT_DIR already set in preamble block above (replaces SCRIPT_PATH)
if [[ "$SCRIPT_DIR" != *"/.claude/plugins/cache/"* ]] && command -v jq &>/dev/null; then
  settings_file="$HOME/.claude/settings.json"
  if [ -f "$settings_file" ]; then
    rite_marketplace=$(jq -r '.enabledPlugins["rite@rite-marketplace"] // false' "$settings_file" 2>/dev/null)
    if [ "$rite_marketplace" = "true" ]; then
      echo "[rite] WARNING: rite@rite-marketplace が有効です。ローカル開発版が無視されます。" >&2
      echo "[rite] ~/.claude/settings.json で rite@rite-marketplace を false に設定してください。" >&2
    fi
  fi
fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"' 2>/dev/null) || SOURCE="startup"

# Pass extract_session_id stderr through so corrupt hook payload WARNINGs reach
# triage; suppressing them would hide cross-session classification failures.
SESSION_ID=$(extract_session_id "$INPUT") || SESSION_ID=""
if [ -z "$CWD" ]; then
  exit 0
fi
if [ ! -d "$CWD" ]; then
  # Dangling harness cwd: the session's working directory no longer
  # exists. When it looks like a reaped session worktree, the harness restored cwd
  # to a tree that rite's lazy reap (or a manual cleanup) removed — the exact shape
  # that makes `/clear` fail with `Path does not exist`. rite cannot repair the
  # harness's own cwd record, but it CAN tell the user how to recover. Best-effort:
  # emitted to stderr; if the harness aborts before this hook runs, the guidance is
  # delivered on the next startup in the same (still-dangling) cwd. Non-blocking.
  case "$CWD" in
    */worktrees/issue-*)
      echo "[rite] 作業ディレクトリ '$(printf '%s' "$CWD" | neutralize_ctrl)' が存在しません（session worktree が削除済みの可能性）。" >&2
      echo "[rite] /clear が 'Path does not exist' で失敗する場合の復旧: リポジトリ root で新しいセッションを開始するか、作業を続けるには有効なディレクトリで /rite:recover を実行してください。" >&2
      ;;
  esac
  exit 0
fi

# Resolve state root (git root or CWD) — consistent with pre-compact.sh / session-end.sh
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Nested self-gitignore for the whole `.rite/` tree (`*` plus wiki negations).
# Covers runtime state even when /rite:setup has not listed each subdir in the
# consumer root .gitignore. mkdir is the caller's job; the helper will not create
# the directory. Failure is non-blocking (same WARNING form as the logs dir).
if mkdir_err=$(mkdir -p "$STATE_ROOT/.rite" 2>&1); then
  if ! _ensure_rite_nested_gitignore "$STATE_ROOT/.rite"; then
    echo "WARNING: session-start.sh: cannot create $(printf '%s' "$STATE_ROOT/.rite" | neutralize_ctrl)/.gitignore; verify by hand that this directory is excluded from git" >&2
    [ -n "$_RITE_GITIGNORE_ERROR" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
  fi
else
  echo "WARNING: session-start.sh: cannot create $(printf '%s' "$STATE_ROOT/.rite" | neutralize_ctrl); nested gitignore not written" >&2
  [ -n "$mkdir_err" ] && printf '%s\n' "$mkdir_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi

# Move root `.rite-*` runtime state under `.rite/` once.
_rite_run_relocated_state_migrate "$STATE_ROOT"

# Write plugin root for command-file consumption (version-independent)
_plugin_root="$(dirname "$SCRIPT_DIR")"
if [ -d "$_plugin_root/hooks" ]; then
  printf '%s' "$_plugin_root" > "$STATE_ROOT/.rite/plugin-root" 2>/dev/null || true
fi

# Save session_id to `.rite/session-id` ONLY as the env-absent fallback channel.
# When the runtime exposes CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID,
# that per-session env var is authoritative for flow-state.sh session_id resolution,
# so writing the single shared file would just let concurrent sessions
# clobber each other's value — the original flow-state contamination / worktree
# mis-reap. Skipping the write when env is present stops every session start from
# overwriting the shared file; env-absent runtimes (CI / headless / non-Code clients)
# still get the file as their sole resolution channel, preserving backward compat.
if [ -n "$SESSION_ID" ] && [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -z "${CLAUDE_SESSION_ID:-}" ]; then
  (umask 077; printf '%s' "$SESSION_ID" > "$STATE_ROOT/.rite/session-id") 2>/dev/null || {
    [ -n "${RITE_DEBUG:-}" ] && echo "[rite] WARNING: Failed to write .rite/session-id" >&2
    true
  }
fi

# Helper: remove stale compact-state when no active flow
# Called on startup when the flow-state is absent or inactive, to prevent stale
# "recovering" state from persisting across sessions.
#
# Cleans both the per-session compact-state (.rite/sessions/{sid}.compact-state,
# derived from the resolved STATE_FILE) and the legacy shared path
# (.rite-compact-state). Removing the legacy file here is the migration path for
# legacy residue: a leftover shared snapshot is no longer consumed by
# post-compact.sh (which now reads the per-session path), so it must be reaped
# here. Both are stale recovery snapshots once no active flow exists — there is
# no silent destruction of live state.
_cleanup_stale_compact() {
  local _legacy="$STATE_ROOT/.rite-compact-state"
  local _per_session=""
  [ -n "${STATE_FILE:-}" ] && _per_session="${STATE_FILE%.flow-state}.compact-state"
  local _cs
  for _cs in "$_per_session" "$_legacy"; do
    [ -n "$_cs" ] || continue
    if [ -f "$_cs" ]; then
      rm -f "$_cs" 2>/dev/null || true
      rm -rf "$_cs.lockdir" 2>/dev/null || echo "[CONTEXT] LOCKDIR_CLEANUP_FAILED=1; from=session_start_cleanup" >&2
    fi
  done
}

# Read a single top-level YAML key from a config file. Captures awk stderr so that
# permission denied / missing awk / malformed file surfaces a WARNING instead of
# silently degrading to "schema is up to date" and skipping the migration prompt.
_rite_read_yaml_key() {
  local _key="$1" _file="$2" _label="$3"
  local _err="" _rc=0 _val=""
  _err=$(mktemp 2>/dev/null) || _err=""
  # Use literal prefix match (`index() == 1`) instead of `$0 ~ k` so a future
  # YAML key containing regex metacharacters (`.` `*` `[` etc.) cannot cause
  # overmatching or silent no-match. Callers are not required to pre-escape.
  _val=$(set -o pipefail; awk -v k="${_key}:" 'index($0, k) == 1 {print $2}' "$_file" 2>"${_err:-/dev/null}" | tr -d '[:space:]"') || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "[rite] WARNING: session-start: ${_label} 読み取り失敗 (rc=$_rc) — ${_file}" >&2
    [ -n "$_err" ] && [ -s "$_err" ] && head -3 "$_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  [ -n "$_err" ] && rm -f "$_err"
  printf '%s' "$_val"
}

if [ "$SOURCE" = "startup" ]; then
  # --- Schema version check ---
  _rite_config="$STATE_ROOT/rite-config.yml"
  if [ -f "$_rite_config" ]; then
    _current_sv=$(_rite_read_yaml_key schema_version "$_rite_config" "schema_version (project)")
    if [ -z "$_current_sv" ] || ! [[ "$_current_sv" =~ ^[0-9]+$ ]]; then
      _current_sv=1
    fi

    _template_config="$SCRIPT_DIR/../templates/config/rite-config.yml"
    _latest_sv=1
    if [ -f "$_template_config" ]; then
      _latest_sv=$(_rite_read_yaml_key schema_version "$_template_config" "schema_version (template)")
      if [ -z "$_latest_sv" ] || ! [[ "$_latest_sv" =~ ^[0-9]+$ ]]; then
        _latest_sv=1
      fi
    fi

    if [ "$_current_sv" -lt "$_latest_sv" ]; then
      _sv_lang=$(_rite_read_yaml_key language "$_rite_config" "language")
      if [ "$_sv_lang" = "auto" ] || [ -z "$_sv_lang" ]; then
        # Detect from LANG environment variable (e.g., ja_JP.UTF-8 -> ja)
        case "${LANG:-}" in
          ja*) _sv_lang="ja" ;;
          *) _sv_lang="en" ;;
        esac
      fi
      case "$_sv_lang" in
        ja)
          echo "[rite] ⚠️ rite-config.yml のスキーマが古くなっています (v${_current_sv} → v${_latest_sv})。/rite:setup --upgrade を実行してください。" >&2
          ;;
        *)
          echo "[rite] ⚠️ rite-config.yml schema is outdated (v${_current_sv} → v${_latest_sv}). Run /rite:setup --upgrade to update." >&2
          ;;
      esac
    fi

    # --- Deprecated flow_state.schema_version: 1 warning ---
    # The legacy single-file (.rite-flow-state) selection path was removed in the
    # per-session unification; flow-state is always per-session now. An explicit
    # `flow_state.schema_version: 1` no longer selects single-file — it is ignored.
    # Warn once per session start (gated on SOURCE=startup → AC-3 "1 回のみ") so the
    # user removes the now-dead key (D-01). Section-absent or `: 2` stays silent
    # (AC-4). Reads the `flow_state:` sub-key directly (the top-level _rite_read_yaml_key
    # only matches column-0 keys, so it cannot see an indented sub-key). Read failure is
    # surfaced as a WARNING rather than silently degraded, matching the _rite_read_yaml_key
    # convention above (silent degradation would suppress the deprecation advisory). The
    # `_fs_sv=""` fallback keeps the startup hook non-blocking; pipefail makes the if-test
    # catch an awk failure even though the trailing `tr` would otherwise exit 0.
    _fs_sv_err=$(mktemp 2>/dev/null) || _fs_sv_err=""
    if _fs_sv=$(awk '
      /^[^[:space:]#]/ { in_fs = 0 }
      /^flow_state:[[:space:]]*(#.*)?$/ { in_fs = 1; next }
      in_fs && /^[[:space:]]+schema_version:/ {
        line = $0
        sub(/.*schema_version:[[:space:]]*/, "", line)
        sub(/[[:space:]]*#.*/, "", line)
        print line
        exit
      }
    ' "$_rite_config" 2>"${_fs_sv_err:-/dev/null}" | tr -d "[:space:]\"'"); then
      :
    else
      echo "[rite] WARNING: session-start: flow_state.schema_version 読み取り失敗 — ${_rite_config}" >&2
      [ -n "$_fs_sv_err" ] && [ -s "$_fs_sv_err" ] && head -3 "$_fs_sv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      _fs_sv=""
    fi
    [ -n "$_fs_sv_err" ] && rm -f "$_fs_sv_err"
    if [ "$_fs_sv" = "1" ]; then
      _fs_lang=$(_rite_read_yaml_key language "$_rite_config" "language")
      if [ "$_fs_lang" = "auto" ] || [ -z "$_fs_lang" ]; then
        case "${LANG:-}" in
          ja*) _fs_lang="ja" ;;
          *) _fs_lang="en" ;;
        esac
      fi
      case "$_fs_lang" in
        ja)
          echo "[rite] ⚠️ rite-config.yml の flow_state.schema_version: 1 は非推奨です。legacy single-file 形式は撤去され、flow-state は常に per-session で動作します。このキーは無視されます — rite-config.yml から削除してください。" >&2
          ;;
        *)
          echo "[rite] ⚠️ rite-config.yml flow_state.schema_version: 1 is deprecated. The legacy single-file format was removed; flow-state is always per-session now. This key is ignored — remove it from rite-config.yml." >&2
          ;;
      esac
    fi
  fi
fi

# --- Plugin version check + legacy hook cleanup on startup ---
if [ "$SOURCE" = "startup" ]; then
  _version_file="$STATE_ROOT/.rite/initialized-version"
  _hooks_cleaned_marker="$STATE_ROOT/.rite/settings-hooks-cleaned"
  _version_read="$_version_file"
  [ -f "$_version_read" ] || [ ! -f "$STATE_ROOT/.rite-initialized-version" ] || _version_read="$STATE_ROOT/.rite-initialized-version"
  _hooks_read="$_hooks_cleaned_marker"
  [ -f "$_hooks_read" ] || [ ! -f "$STATE_ROOT/.rite-settings-hooks-cleaned" ] || _hooks_read="$STATE_ROOT/.rite-settings-hooks-cleaned"

  _needs_cleanup=false
  _installed_ver=""
  _current_ver=""

  if [ -f "$_version_read" ]; then
    _installed_ver=$(tr -d '[:space:]' < "$_version_read" 2>/dev/null)
    _plugin_json="$SCRIPT_DIR/../.claude-plugin/plugin.json"
    _current_ver=$(jq -r '.version // empty' "$_plugin_json" 2>/dev/null)
    if [ -n "$_installed_ver" ] && [ -n "$_current_ver" ] && [ "$_installed_ver" != "$_current_ver" ]; then
      _needs_cleanup=true
    fi
  fi

  # One-time migration: clean up settings.local.json hooks even if versions match
  if [ ! -f "$_hooks_read" ]; then
    _needs_cleanup=true
  fi

  if [ "$_needs_cleanup" = "true" ]; then
    # i18n: language is read with the same minimal awk pattern used elsewhere so
    # malformed YAML in adjacent keys cannot poison the value.
    _lang="en"
    _rite_config="$STATE_ROOT/rite-config.yml"
    if [ -f "$_rite_config" ]; then
      _cfg_lang=$(_rite_read_yaml_key language "$_rite_config" "language (cleanup)")
      [ -n "$_cfg_lang" ] && _lang="$_cfg_lang"
    fi

    # Remove rite hook entries from settings.local.json (hooks.json handles them natively).
    # The JSON transform (rite-hook detection via RITE_HOOK_RE + selective removal) is
    # delegated to the shared scripts/settings-local-rite-hook-cleanup.py — the same
    # single-source script the .sh wrapper uses — so the regex lives in exactly one place
    # rather than being duplicated as an inline python3 copy of both the regex and
    # the whole transform. Its documented exit codes are reused here: 0 = rite hooks removed
    # (cleaned JSON on stdout → captured into _repair_tmp), 1 = intentional no-op (no
    # hooks key / no rite entries), 2 = invalid JSON. Distinguishing the no-op (rc=1) from
    # real failures (rc=2, etc.) is required so settings.local.json corruption surfaces
    # instead of silently retrying on every session start.
    _auto_cleaned=false
    _settings_local="$STATE_ROOT/.claude/settings.local.json"
    if [ -f "$_settings_local" ] && command -v python3 &>/dev/null; then
      _repair_tmp=$(mktemp "${_settings_local}.XXXXXX" 2>/dev/null) || _repair_tmp=""
      _py_err=$(mktemp 2>/dev/null) || _py_err=""
      if [ -n "$_repair_tmp" ]; then
        # python3 must run in a set -e-exempt context (an if-condition) so a non-zero
        # exit (rc=1 no-op / rc=2 invalid JSON / missing script) does NOT abort the
        # whole hook before the rc branches below run. A bare statement here would trip
        # `set -euo pipefail` and turn the entire else branch into dead code.
        if python3 "$SCRIPT_DIR/scripts/settings-local-rite-hook-cleanup.py" \
          < "$_settings_local" > "$_repair_tmp" 2>"${_py_err:-/dev/null}"; then
          _py_rc=0
        else
          _py_rc=$?
        fi
        if [ "$_py_rc" -eq 0 ]; then
          # mv must capture both rc and stderr so EXDEV / EACCES / ENOSPC / EROFS
          # / SELinux deny is distinguishable; silent failure here would leave
          # _auto_cleaned=false and the rite hook config would re-fire repair on
          # every session start with no diagnosable cause.
          _settings_mv_err=$(mktemp 2>/dev/null) || _settings_mv_err=""
          if mv "$_repair_tmp" "$_settings_local" 2>"${_settings_mv_err:-/dev/null}"; then
            _auto_cleaned=true
          else
            _mv_rc=$?
            rm -f "$_repair_tmp" 2>/dev/null
            echo "rite: session-start: mv settings.local.json repair failed (rc=$_mv_rc)" >&2
            [ -n "$_settings_mv_err" ] && [ -s "$_settings_mv_err" ] && head -3 "$_settings_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
          fi
          [ -n "$_settings_mv_err" ] && rm -f "$_settings_mv_err"
        else
          rm -f "$_repair_tmp" 2>/dev/null
          # rc=1 is the intentional no-op branch (no hooks key / no rite entries).
          # Any other rc indicates a real failure — report whenever rc != 1, and also
          # when stderr is non-empty, letting the user disambiguate corruption from the no-op.
          if [ "$_py_rc" -ne 1 ] || { [ -n "$_py_err" ] && [ -s "$_py_err" ]; }; then
            echo "rite: session-start: settings.local.json repair python3 failed (rc=$_py_rc)" >&2
            if [ -n "$_py_err" ] && [ -s "$_py_err" ]; then
              # Non-empty stderr means python3 itself failed (missing/unreadable cleanup
              # script, import error) — surface its diagnostic but NOT the JSON hint, which
              # would misdirect: the fault is not the settings.local.json content.
              head -3 "$_py_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
            elif [ "$_py_rc" -eq 2 ]; then
              # The cleanup script ran, returned 2, and wrote nothing to stderr → invalid
              # JSON (its only rc=2 path). This is the one case where the JSON hint is correct.
              echo "  hint: settings.local.json の JSON 形式 / encoding を確認してください" >&2
            fi
          fi
        fi
      fi
      [ -n "$_py_err" ] && rm -f "$_py_err"
    fi

    # Write cleanup marker when: (1) cleanup succeeded, or (2) no settings.local.json / no rite hooks
    # Do NOT write marker when python3 is unavailable but settings.local.json has rite hooks (allow retry)
    if [ "$_auto_cleaned" = "true" ] || [ ! -f "$_settings_local" ]; then
      echo "cleaned" > "$_hooks_cleaned_marker" 2>/dev/null || true
    fi

    if [ "$_auto_cleaned" = "true" ]; then
      [ -n "$_current_ver" ] && echo "$_current_ver" > "$_version_file" 2>/dev/null || true
      case "$_lang" in
        ja)
          echo "[rite] レガシー hook 設定を settings.local.json から削除しました（hooks.json で管理）。" >&2
          ;;
        *)
          echo "[rite] Removed legacy hook entries from settings.local.json (managed by hooks.json)." >&2
          ;;
      esac
    elif [ -n "$_installed_ver" ] && [ -n "$_current_ver" ] && [ "$_installed_ver" != "$_current_ver" ]; then
      echo "$_current_ver" > "$_version_file" 2>/dev/null || true
      case "$_lang" in
        ja)
          echo "[rite] プラグインが更新されました (v${_installed_ver} -> v${_current_ver})。" >&2
          ;;
        *)
          echo "[rite] Plugin updated (v${_installed_ver} -> v${_current_ver})." >&2
          ;;
      esac
    fi
  fi
fi

# Auto-migrate any v1/v2 state files to v3 via flow-state.sh migrate subcommand.
# Non-blocking: errors surface to stderr but the hook continues. Idempotent: files
# already at schema_version=3 are skipped.
# Only stdout is silenced (the "Migration complete: N" summary), which Claude reads
# as the active-workflow injection payload. stderr is intentionally passed through:
# _migrate_file emits an unconditional `migrated:` line per actually-migrated file
# (AC-8, silent skip forbidden), so a real migration is always announced here while
# quiet session starts (only v3 files → verbose-gated skip) stay silent.
RITE_STATE_ROOT="$STATE_ROOT" bash "$SCRIPT_DIR/flow-state.sh" migrate >/dev/null || true

# --- Best-effort lazy reap of orphaned session worktrees (multi-session §8) ---
# Only when the session starts at the main checkout root (CWD == shared root):
# sessions start at the repo root (D-1), so a worktree-rooted CWD means we are
# inside a linked worktree and must NOT drive the reap (cannot remove a worktree
# you are standing in — though the reap's own gates already protect live/dirty
# trees). pr-cycle-cleanup.sh resolves repo_root to the main checkout and reaps
# only stale + clean `.rite/worktrees/issue-{N}` trees. Fully non-blocking:
# `|| true` keeps a slow/failed GC from blocking session start.
#
# Output is redirected to a log file (overwritten each run — no rotation) rather
# than discarded, since silent skip reasons (dirty/liveness/corpse-age-guard/
# manifest-bypass WARNINGs) were previously unobservable and slowed diagnosis
# (#1966's investigation). A self-contained `.gitignore` (`*`) is written into
# the log dir on first creation so it never leaks into the repo even in
# downstream consuming repos. Nested `$STATE_ROOT/.rite/.gitignore` (`*` plus
# wiki negations) also covers `.rite/sessions/`, `.rite/worktrees/`,
# `.rite/review-results/`, and `.rite/logs/` without a root listing. If the
# dir can't be created,
# fall back to discarding output — this hook must never block session start on
# a log-write failure.
if [ "$CWD" = "$STATE_ROOT" ]; then
  _reap_log_dir="$STATE_ROOT/.rite/logs"
  # Test writability (not just dir creation) before committing to the log path:
  # mkdir -p succeeds on a pre-existing read-only dir, and a later `>` open
  # failure would otherwise skip reap entirely (no fallback, no log) instead of
  # degrading to discard. The truncate below doubles as the "overwritten each
  # run" reset, so the reap output is appended after it.
  if mkdir -p "$_reap_log_dir" 2>/dev/null && { : > "$_reap_log_dir/pr-cycle-cleanup.log"; } 2>/dev/null; then
    if ! _ensure_dir_gitignore "$_reap_log_dir"; then
      echo "WARNING: session-start.sh: cannot create $(printf '%s' "$_reap_log_dir" | neutralize_ctrl)/.gitignore; verify by hand that this directory is excluded from git" >&2
      [ -n "$_RITE_GITIGNORE_ERROR" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
    fi
    ( cd "$CWD" && bash "$SCRIPT_DIR/scripts/pr-cycle-cleanup.sh" ) >>"$_reap_log_dir/pr-cycle-cleanup.log" 2>&1 || true
  else
    ( cd "$CWD" && bash "$SCRIPT_DIR/scripts/pr-cycle-cleanup.sh" ) >/dev/null 2>&1 || true
  fi
fi

# Resolve active flow-state file path.
# `flow-state.sh path` always returns the per-session file
# (`.rite/sessions/<sid>.flow-state`) — the legacy single-file `.rite-flow-state`
# selection path was removed. The empty-string fallback below keeps
# the hook non-blocking under helper deploy regression (e.g. chmod -x or partial
# install) by skipping recovery rather than reading a single-file form.
#
# Stderr pass-through for diagnostic visibility, via canonical
# helper `_mktemp-stderr-guard.sh`.
# - mktemp 失敗時に 3 行 WARNING を emit (silent fall-through 解消)
# - chmod 600 / TMPDIR 尊重を helper 経由で取得
# - filter は flow-state.sh の cross-session guard pass-through (3-pattern:
#   `^WARNING:|^  |^jq: `) を `^ERROR:` で superset 化した 4-pattern 拡張版。
#   `flow-state.sh path` は `_validate-helpers.sh` / `_validate-state-root.sh`
#   経由で `ERROR:` 行を emit する (resolver self-validation contract) ため、
#   reader-side filter より広い範囲を要求する。indented continuation 行と
#   raw `jq:` parse error は flow-state.sh と同じく pass-through する
# - success arm でも tempfile を inspect する (`flow-state.sh path`
#   が graceful-degrade で exit 0 を返す経路、例えば `_resolve-session-id-from-file.sh`
#   A tr IO failure can produce empty SID + WARNING 出力 + exit 0 経路で
#   inner helper の WARNING を silent drop しないため)
_resolve_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
  "session-start" \
  "resolve-flow-state-err" \
  "flow-state.sh path の WARNING/ERROR / jq parse error / indented 補助行が pass-through されません")
# Single-pass branch: capture resolver outcome, then run filter once regardless
# of success/failure (helper may graceful-degrade exit 0 with WARNING in stderr,
# e.g., empty SID via tr IO failure — both paths require pass-through).
_resolve_failed=0
STATE_FILE=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" path 2>"${_resolve_err:-/dev/null}") || _resolve_failed=1
if [ -n "$_resolve_err" ] && [ -s "$_resolve_err" ]; then
  grep -E '^WARNING:|^ERROR:|^  |^jq: ' "$_resolve_err" >&2 || true
fi
if [ "$_resolve_failed" -eq 1 ]; then
  echo "[rite] WARNING: flow-state.sh path resolution failed — STATE_FILE 不明、recovery を skip します" >&2
  STATE_FILE=""
fi
[ -n "$_resolve_err" ] && rm -f "$_resolve_err"

if [ -z "$STATE_FILE" ] || [ ! -f "$STATE_FILE" ]; then
  # Clean stale compact state on startup/clear when no flow state exists
  _cleanup_stale_compact
  exit 0
fi

# --- Dangling session-worktree self-heal (multi-session §8) ---
# If the recorded `worktree` path no longer exists (e.g. it was reaped by another
# session's lazy GC while this session was paused), null the field so neither the
# orchestrator's re-entry path (open.md Step 0.5 / recover.md) nor a later
# EnterWorktree is aimed at a dead directory. The harness's own /clear cwd-restore
# cannot be intercepted by rite, so this is the SECONDARY defense (the primary is
# the reap-side cross-session liveness guard in pr-cycle-cleanup.sh). Runs on both
# startup and clear, for active and inactive state alike (a dangling reference is
# harmful to a later resume regardless of `active`). `flow-state.sh clear-worktree`
# resolves the same session_id as `path` above (same .rite-session-id + RITE_STATE_ROOT),
# so it targets THIS session's own state file. Non-blocking: failures WARN and the
# hook continues (AC-5).
_recorded_wt_err=$(mktemp 2>/dev/null) || _recorded_wt_err=""
_recorded_wt=$(jq -r '.worktree // ""' "$STATE_FILE" 2>"${_recorded_wt_err:-/dev/null}") || _recorded_wt=""
if [ -n "$_recorded_wt_err" ] && [ -s "$_recorded_wt_err" ]; then
  echo "rite: session-start: WARNING: jq read of .worktree failed (STATE_FILE may be corrupt)" >&2
  head -3 "$_recorded_wt_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi
[ -n "$_recorded_wt_err" ] && rm -f "$_recorded_wt_err"
if [ -n "$_recorded_wt" ] && [ ! -d "$_recorded_wt" ]; then
  if RITE_STATE_ROOT="$STATE_ROOT" bash "$SCRIPT_DIR/flow-state.sh" clear-worktree >/dev/null 2>&1; then
    echo "[rite] worktree '$(printf '%s' "$_recorded_wt" | neutralize_ctrl)' が存在しないため flow-state から参照をクリアしました（再入場は試みません）。" >&2
    echo "[rite] この worktree で /clear が 'Path does not exist' を出していた場合、参照クリアにより次回以降は解消されます。" >&2
  else
    echo "[rite] WARNING: session-start: dangling worktree 参照のクリアに失敗しました（非blocking で継続します）。" >&2
  fi
fi

_active_err=$(mktemp 2>/dev/null) || _active_err=""
ACTIVE=$(jq -r '.active // false' "$STATE_FILE" 2>"${_active_err:-/dev/null}") || ACTIVE=false
if [ -n "$_active_err" ] && [ -s "$_active_err" ]; then
  # silent fallback to "inactive" だと corrupt JSON が見えず post-compact recovery が消失する
  # 経路を operator が triage できない。stderr を expose する。
  echo "rite: session-start: WARNING: jq parse of .active failed (STATE_FILE may be corrupt)" >&2
  head -3 "$_active_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi
[ -n "$_active_err" ] && rm -f "$_active_err"
if [ "$ACTIVE" != "true" ]; then
  _cleanup_stale_compact
  exit 0
fi

# --- Stop-reason phrasing (#2045) ---
# flow-state の `stop_reason` は「ワークフローが失敗として止まった」ことの durable な記録
# (`skills/iterate/SKILL.md` ステップ 6 共有前段が書く)。キーが無い state は「単なる中断」
# (Ctrl+C / セッション終了) を意味する。両者はキー不在のとき phase=review / active=true という
# バイト的に同一の形で残るため、この関数の出力の有無だけが再開案内で両者を分ける手がかりになる。
#
# 既知トークンは**明示列挙**し、未知の値は `*)` で既定文面へ silent に吸収させない — トークン
# 名前空間を広げたとき分岐漏れがエラーにならず誤った案内が出続けるため (Wiki: prefix 分岐 case の
# `*)` catch-all は未知の将来 prefix を silent に default 動作へ吸収する)。未知値は raw を
# neutralize して見せ、operator が「知らない停止理由が来た」と気付ける形にする。
#
# stdout に 1 行返す (空 = 停止理由なし = 通常の中断)。呼び出し側はこの戻り値を案内文へ挿す。
_rite_stop_reason_phrase() {
  local _sr="$1"
  [ -z "$_sr" ] && return 0
  case "$_sr" in
    circuit-breaker:max-cycles)
      echo "サーキットブレーカー発火 (review⇄fix cycle が上限に到達)" ;;
    circuit-breaker:divergence)
      echo "サーキットブレーカー発火 (収束トレンドの発散を検出)" ;;
    *)
      echo "未知の停止理由トークン '$(printf '%s' "$_sr" | neutralize_ctrl)' (rite の更新で追加された可能性)" ;;
  esac
}

# --- Defensive reset helper ---
# Shared by startup and clear blocks. Resets active=false on phase != completed.
#
# When the state is owned by another active session (check_session_ownership
# returns "other"), skip the reset — overwriting another session's active state
# would clobber its in-flight work memory: the peer session would see an
# externally mutated .active=false flag and either silently advance past its
# in-flight phase or fall through to create-mode init on the next hook fire.
# For "own" / "legacy" / "stale" / fail-safe paths, proceed with reset
# (crash-recovery and backward-compat take priority over multi-instance protection).
#
# Regression note: a prior commit moved the check_session_ownership call
# inside an RITE_DEBUG block as a "performance" optimization, silently disabling
# multi-instance protection in normal runs. DO NOT re-enclose check_session_ownership
# in conditional gates — it must run on every reset path so the "other" branch can fire.
#
# Note: This function always terminates via exit 0 — it never returns to the caller.
# When issue_number is empty (e.g., state file has no issue), exits silently without message.
_reset_active_state() {
  local _phase _issue _branch _stop_reason _stop_phrase _ownership
  # 4 field を single composite jq read で読む。個別 read に分けると mid-write 中断などで
  # .phase だけ valid / .issue_number 以降が corrupt な partial-failure を WARNING の有無で
  # 区別できなくなり、reset reason の triage が不能になる経路ができる。
  # IFS=$'\t' + @tsv collapses empty fields under POSIX whitespace rules: an empty
  # issue_number shifts _branch's value into _issue, leaving _branch empty. The
  # unit separator \x1f preserves empty fields safely (see post-compact.sh / the
  # ACTIVE-fallback read below for the same convention).
  local _reset_jq_err _composite
  _reset_jq_err=$(mktemp 2>/dev/null) || _reset_jq_err=""
  _composite=$(jq -r '[(.phase // ""), (.issue_number // "" | tostring), (.branch // ""), (.stop_reason // "")] | join("\u001f")' \
    "$STATE_FILE" 2>"${_reset_jq_err:-/dev/null}") || _composite=$'\x1f\x1f\x1f'
  if [ -n "$_reset_jq_err" ] && [ -s "$_reset_jq_err" ]; then
    echo "rite: session-start: WARNING: _reset_active_state jq read failed (STATE_FILE may be corrupt)" >&2
    head -3 "$_reset_jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  [ -n "$_reset_jq_err" ] && rm -f "$_reset_jq_err"
  IFS=$'\x1f' read -r _phase _issue _branch _stop_reason <<< "$_composite"

  # Session ownership check runs on the normal execution path, not just RITE_DEBUG.
  # Fail-safe: if the helper isn't sourced or returns non-zero, treat as "unknown"
  # and proceed with reset — crash-recovery takes priority over multi-instance protection.
  if command -v check_session_ownership >/dev/null 2>&1; then
    _ownership=$(check_session_ownership "$INPUT" "$STATE_FILE") || _ownership="unknown"
  else
    _ownership="unknown"
    [ -n "${RITE_DEBUG:-}" ] && echo "[rite] ownership check unavailable (check_session_ownership not sourced)" >&2
  fi

  if [ "$_ownership" = "other" ]; then
    [ -n "${RITE_DEBUG:-}" ] && echo "[rite] Skipping reset (state owned by other session)" >&2
    exit 0
  fi

  [ -n "${RITE_DEBUG:-}" ] && echo "[rite] Resetting active state (ownership: $_ownership)" >&2

  # Atomic write: jq to temp file, then mv. No trap — explicit cleanup on failure.
  # Silent jq failure here leaves .active=true forever and ALL operators (user
  # waiting for /rite:recover, peer sessions checking ownership) see a permanent
  # "another session is active" block with no diagnosable cause. Capture stderr.
  local _tmp _reset_jq_err _reset_mv_err
  _tmp=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null) || _tmp="${STATE_FILE}.tmp.$$"
  _reset_jq_err=$(mktemp 2>/dev/null) || _reset_jq_err=""
  if jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
     '.active = false | .updated_at = $ts' "$STATE_FILE" > "$_tmp" 2>"${_reset_jq_err:-/dev/null}"; then
    _reset_mv_err=$(mktemp 2>/dev/null) || _reset_mv_err=""
    if mv "$_tmp" "$STATE_FILE" 2>"${_reset_mv_err:-/dev/null}"; then
      :
    else
      _mv_rc=$?
      rm -f "$_tmp" 2>/dev/null
      echo "rite: session-start: mv defensive reset failed (rc=$_mv_rc)" >&2
      [ -n "$_reset_mv_err" ] && [ -s "$_reset_mv_err" ] && head -3 "$_reset_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    [ -n "$_reset_mv_err" ] && rm -f "$_reset_mv_err"
  else
    _reset_jq_rc=$?
    echo "rite: session-start: jq defensive reset failed (rc=$_reset_jq_rc; STATE_FILE may be corrupt)" >&2
    [ -n "$_reset_jq_err" ] && [ -s "$_reset_jq_err" ] && head -3 "$_reset_jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    rm -f "$_tmp" 2>/dev/null
  fi
  [ -n "$_reset_jq_err" ] && rm -f "$_reset_jq_err"
  _cleanup_stale_compact
  # Silent reset for completed workflows: no message, no /rite:recover suggestion
  if [ "$_phase" = "completed" ]; then
    exit 0
  fi
  if [ -n "$_issue" ]; then
    _stop_phrase=$(_rite_stop_reason_phrase "$_stop_reason")
    if [ -n "$_stop_phrase" ]; then
      echo "rite: 失敗停止した rite workflow の状態をリセットしました (Issue #${_issue}, branch: ${_branch}, 理由: ${_stop_phrase})。再開するには /rite:recover を使用してください。"
    else
      echo "rite: 前回のセッション状態が残っていたためリセットしました (Issue #${_issue}, branch: ${_branch})。再開するには /rite:recover を使用してください。"
    fi
  fi
  exit 0
}

# --- Defensive reset on new session startup ---
if [ "$SOURCE" = "startup" ]; then
  _reset_active_state
fi

# --- Defensive reset on /clear ---
if [ "$SOURCE" = "clear" ]; then
  _reset_active_state
fi

# Clean up stale temporary files (older than 1 minute to avoid deleting in-progress writes).
# `.rite-flow-state.??????*` is intended to match mktemp tempfiles
# (`.rite-flow-state.<6-hex>`), but its `??????*` glob matches **any suffix
# of 6 or more chars**, which would also match a `.rite-flow-state.legacy.*`
# file. The v3 in-place migrate (`flow-state.sh` `_migrate_file`) does NOT
# create such backups (it rewrites the file in place via `_atomic_write`), but a
# pre-v3 rename-based migration (the now-removed `flow-state-update.sh` design)
# may have left one across an upgrade. `-not -name '.rite-flow-state.legacy.*'`
# defensively preserves any such legacy backup as a manual-recovery source
# rather than auto-deleting it.
find "$STATE_ROOT" -maxdepth 1 \( -name ".rite-flow-state.tmp.*" -o -name ".rite-flow-state.??????*" \) -not -name ".rite-flow-state.legacy.*" -type f -mmin +1 -delete 2>/dev/null || true

# Extract the fields used by the interruption notice in a single jq call.
# Unit separator (\x1f) is used instead of tab: POSIX IFS treats adjacent
# whitespace delimiters as one separator and trims leading/trailing whitespace,
# which collapses an empty leading field like issue_number="" — silent data
# corruption. A non-whitespace IFS preserves empty fields per POSIX.
# Defense-in-depth: ACTIVE check (earlier in this script) already catches invalid JSON (jq
# fails → ACTIVE=false → exit 0). This fallback handles the unlikely case where
# the file becomes corrupt between the two jq reads (e.g., race condition,
# partial write). It is not reachable by normal unit tests.
_tsv_err=$(mktemp 2>/dev/null) || _tsv_err=""
_tsv_rc=0
_tsv_output=$(jq -r '[
  (.issue_number // "" | tostring),
  (.phase // "unknown"),
  (.stop_reason // ""),
  (.next_action // ""),
  (.loop_count // 0 | tostring),
  (.pr_number // 0 | tostring),
  (.branch // "")
] | join("\u001f")' "$STATE_FILE" 2>"${_tsv_err:-/dev/null}") || _tsv_rc=$?
if [ "$_tsv_rc" -ne 0 ]; then
  echo "rite: Warning - state file contains invalid JSON. Use /rite:recover to recover." >&2
  [ -n "$_tsv_err" ] && [ -s "$_tsv_err" ] && head -3 "$_tsv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  [ -n "$_tsv_err" ] && rm -f "$_tsv_err"
  exit 0
fi
[ -n "$_tsv_err" ] && rm -f "$_tsv_err"
IFS=$'\x1f' read -r ISSUE PHASE STOP_REASON NEXT_ACTION LOOP PR BRANCH <<< "$_tsv_output"

# Validate that critical fields are not null/empty
if [ -z "$ISSUE" ]; then
  echo "rite: Warning - state file exists but issue_number is missing. Use /rite:recover to recover."
  exit 0
fi

# Quiet interruption notice (degraded from the former multi-line CRITICAL block).
# Cross-turn recovery is preserved: /rite:recover reconstructs phase / next_action /
# loop from flow-state. The former coercive multi-line directive ("IMPORTANT: First
# inform the user ... Use bash {plugin_root}/...") was removed in v0.7 because it
# contaminated unrelated /goal turns whenever a session started in a rite-active cwd.
STOP_PHRASE=$(_rite_stop_reason_phrase "$STOP_REASON")
# batch 稼働中は recover 誘導を出さず /rite:batch-run 継続を案内する（非稼働時は現行 1 行を無変更）。
_ss_sid=$(basename "$STATE_FILE" .flow-state)
_ss_qf="$STATE_ROOT/.rite/state/run-queue-${_ss_sid}.json"
_ss_batch=false
_ss_queue_unreadable=false
if [ -n "$_ss_sid" ] && [ -f "$_ss_qf" ]; then
  if jq -e . "$_ss_qf" >/dev/null 2>&1; then
    _ss_ba=$(jq -r '.active // false' "$_ss_qf")
    _ss_bc=$(jq -r '.cursor // 0' "$_ss_qf")
    _ss_bt=$(jq -r '.issues | length' "$_ss_qf")
    if [ "$_ss_ba" = "true" ] && [ "${_ss_bc:-0}" -lt "${_ss_bt:-0}" ] 2>/dev/null; then
      _ss_batch=true
    fi
  else
    echo "WARNING: run-queue が破損しています ($_ss_qf)" >&2
    _ss_queue_unreadable=true
  fi
fi
if [ "$SOURCE" = "compact" ]; then
  # SessionStart stdout is injected into model context. Auto vs manual comes from
  # compact-state.trigger (written by pre-compact, preserved by post-compact).
  # Missing field (old compact-state) is expected absence → auto.
  _ss_cs="${STATE_FILE%.flow-state}.compact-state"
  _ss_trigger="auto"
  if [ -f "$_ss_cs" ]; then
    _ss_trigger=$(jq -r '.trigger // "auto"' "$_ss_cs" 2>/dev/null) || _ss_trigger="auto"
  fi
  case "$_ss_trigger" in
    manual) ;;
    *) _ss_trigger="auto" ;;
  esac
  if [ "$_ss_trigger" = "auto" ]; then
    cat <<EOF
[rite] Auto-compact recovery: Issue #${ISSUE}, Phase: ${PHASE}, Branch: ${BRANCH}
Next action: ${NEXT_ACTION}
Loop: ${LOOP} | PR: #${PR}
Use \`bash {plugin_root}/hooks/flow-state.sh get --field <field>\` for full state details. Also consult .rite/work-memory/issue-${ISSUE}.md, then continue.
EOF
  else
    cat <<EOF
[rite] Compact recovery: Issue #${ISSUE}, Phase: ${PHASE}, Branch: ${BRANCH}
Next action: ${NEXT_ACTION}
Loop: ${LOOP} | PR: #${PR}
EOF
  fi
  if [ "$_ss_batch" = "true" ]; then
    _ss_mode=$(jq -r '.mode // "default"' "$_ss_qf")
    _ss_issue=$(jq -r --argjson c "${_ss_bc:-0}" '.issues[$c] // empty' "$_ss_qf" 2>/dev/null) || _ss_issue=""
    [ -n "$_ss_issue" ] || _ss_issue="$ISSUE"
    echo "[rite] Batch: run-queue active — mode=${_ss_mode} cursor=${_ss_bc}/${_ss_bt} current_issue=#${_ss_issue} pr=#${PR} queue_file=${_ss_qf}"
    echo "Continue /rite:batch-run from the step matching Phase above."
  elif [ "$_ss_queue_unreadable" = "true" ]; then
    echo "[rite] Batch: run-queue unreadable — cannot decide batch continuation. queue_file=${_ss_qf}"
  fi
elif [ "$_ss_batch" = "true" ]; then
  echo "rite: /rite:batch-run が稼働中です (Issue #${ISSUE}, phase: ${PHASE})。停止せず /rite:batch-run を該当ステップから続行してください。Do not run /rite:recover while the batch is active."
elif [ "$_ss_queue_unreadable" = "true" ]; then
  echo "rite: run-queue が破損しているため batch 稼働判定ができません (Issue #${ISSUE}, phase: ${PHASE})。queue を直すまで batch を再開しないでください。"
elif [ -n "$STOP_PHRASE" ]; then
  echo "rite: 失敗停止した rite workflow を検出しました (Issue #${ISSUE}, phase: ${PHASE}, 理由: ${STOP_PHRASE})。再開前に状態を確認するには /rite:recover を実行してください。"
else
  echo "rite: 中断した rite workflow を検出しました (Issue #${ISSUE}, phase: ${PHASE})。再開するには /rite:recover を実行してください。"
fi

# --- Session ID notification ---
# session_id is now auto-read from .rite-session-id by flow-state.sh.
# stdout output removed to prevent Claude from fabricating inconsistent values
# via the {session_id} placeholder.
