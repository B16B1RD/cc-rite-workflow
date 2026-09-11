#!/bin/bash
# rite workflow - Post-Compact Hook
# Side effects after compaction: compact-state normalize (recovering→normal),
# PR/Projects Status reconciliation. Recovery text for the model is emitted by
# session-start.sh (source=compact); PostCompact plain stdout is not injected
# into model context (Claude Code docs).
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_POSTCOMPACT:-}" ] || exit 0
export _RITE_HOOK_RUNNING_POSTCOMPACT=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
SOURCE=$(echo "$INPUT" | jq -r '.source // "auto"' 2>/dev/null) || SOURCE="auto"
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD)
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Resolve the active flow-state file: always the per-session file (the legacy
# single-file selection path was removed). Stderr is captured via the
# canonical _mktemp-stderr-guard.sh helper (see session-start.sh for the same pattern)
# so resolver WARNING/ERROR lines don't get silently dropped — even on the
# success arm, where helper graceful-degrade paths still emit diagnostics.
_resolve_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
  "post-compact" \
  "resolve-flow-state-err" \
  "flow-state.sh path の WARNING/ERROR / jq parse error / indented 補助行が pass-through されません")
# SIGINT before the explicit rm below leaves `$_resolve_err` orphaned in /tmp;
# clean up on any exit signal so the path never leaks even if the script aborts
# mid-resolve.
trap '[ -n "${_resolve_err:-}" ] && rm -f "$_resolve_err" 2>/dev/null || true' EXIT INT TERM
# Single-pass branch (filter runs once regardless of resolver exit status).
_resolve_failed=0
FLOW_STATE=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" path 2>"${_resolve_err:-/dev/null}") || _resolve_failed=1
# Mirror of session-end.sh resolver stderr handler. The grep pins accepted prefixes;
# any new resolver prefix (INFO:/DIAG:/...) would silently drop without the counter.
if [ -n "$_resolve_err" ] && [ -s "$_resolve_err" ]; then
  if [ -n "${RITE_DEBUG:-}" ]; then
    neutralize_ctrl --keep-newline < "$_resolve_err" >&2
  else
    # `grep -c ''` agrees with the filter `grep -c` below regardless of trailing
    # newline; `wc -l` would undercount and let `_dropped` go negative.
    _pc_resolve_err_total=$(grep -c '' "$_resolve_err" 2>/dev/null) || _pc_resolve_err_total=0
    _pc_resolve_err_kept=$(grep -cE '^WARNING:|^ERROR:|^  |^jq: ' "$_resolve_err" 2>/dev/null) || _pc_resolve_err_kept=0
    grep -E '^WARNING:|^ERROR:|^  |^jq: ' "$_resolve_err" >&2 || true
    _pc_resolve_err_dropped=$((${_pc_resolve_err_total:-0} - ${_pc_resolve_err_kept:-0}))
    if [ "${_pc_resolve_err_dropped:-0}" -gt 0 ]; then
      echo "[rite] WARNING: post-compact: ${_pc_resolve_err_dropped} resolver stderr lines filtered (use RITE_DEBUG=1 for full output)" >&2
    fi
  fi
fi
if [ "$_resolve_failed" -eq 1 ]; then
  echo "[rite] WARNING: flow-state.sh path resolution failed — FLOW_STATE 不明、recovery を skip します" >&2
  FLOW_STATE=""
fi
[ -n "$_resolve_err" ] && rm -f "$_resolve_err"

# Derive the per-session compact-state path from the resolved flow-state path
# It must mirror pre-compact.sh so the snapshot written by PreCompact
# is the one consumed and normalized here. Falls back to the legacy shared path
# only when the session id is unresolvable.
if [ -n "$FLOW_STATE" ]; then
  COMPACT_STATE="${FLOW_STATE%.flow-state}.compact-state"
else
  COMPACT_STATE="$STATE_ROOT/.rite-compact-state"
fi
LOCKDIR="$COMPACT_STATE.lockdir"

# --- Cleanup helper ---
_cleanup_compact_state() {
  rm -f "$COMPACT_STATE" 2>/dev/null || true
  rm -rf "$LOCKDIR" 2>/dev/null || true
}

# --- No flow state: clean up and exit ---
if [ -z "$FLOW_STATE" ] || [ ! -f "$FLOW_STATE" ]; then
  _cleanup_compact_state
  exit 0
fi

# --- Flow not active: clean up and exit ---
# jq の stderr を tempfile capture し、peer hook (pre-compact.sh / session-start.sh) と
# 同じく WARNING で corrupt JSON を expose する。silent fallback だと recovery のチャンスを失う。
_flow_active_err=$(mktemp 2>/dev/null) || _flow_active_err=""
FLOW_ACTIVE=$(jq -r '.active // false' "$FLOW_STATE" 2>"${_flow_active_err:-/dev/null}") || FLOW_ACTIVE="false"
if [ -n "$_flow_active_err" ] && [ -s "$_flow_active_err" ]; then
  echo "[rite] WARNING: post-compact: jq parse of .active failed (FLOW_STATE may be corrupt)" >&2
  head -3 "$_flow_active_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi
[ -n "$_flow_active_err" ] && rm -f "$_flow_active_err"
if [ "$FLOW_ACTIVE" != "true" ]; then
  _cleanup_compact_state
  exit 0
fi

# --- No compact state or not recovering: nothing to do ---
if [ ! -f "$COMPACT_STATE" ]; then
  exit 0
fi
_compact_val_err=$(mktemp 2>/dev/null) || _compact_val_err=""
_compact_val_rc=0
COMPACT_VAL=$(jq -r '.compact_state // "normal"' "$COMPACT_STATE" 2>"${_compact_val_err:-/dev/null}") || _compact_val_rc=$?
# Surface jq failure regardless of whether mktemp succeeded. A broken /tmp would
# otherwise let COMPACT_VAL="unknown" route silently to the non-recovering
# branch with no audit trail, masking the underlying corruption.
if [ "$_compact_val_rc" -ne 0 ]; then
  COMPACT_VAL="unknown"
  _compact_val_tag=""
  [ -z "$_compact_val_err" ] && _compact_val_tag=" stderr_capture=disabled"
  echo "[rite] WARNING: post-compact: jq parse of .compact_state failed (rc=$_compact_val_rc — COMPACT_STATE may be corrupt${_compact_val_tag})" >&2
  [ -n "$_compact_val_err" ] && [ -s "$_compact_val_err" ] && head -3 "$_compact_val_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi
[ -n "$_compact_val_err" ] && rm -f "$_compact_val_err"
if [ "$COMPACT_VAL" != "recovering" ]; then
  exit 0
fi

# --- Source work-memory-lock for acquire/release helpers ---
source "$SCRIPT_DIR/work-memory-lock.sh"

# --- Read flow state ---
# IFS=$'\t' + @tsv collapses empty fields under POSIX whitespace rules: an empty
# next_action shifts every subsequent column left, contaminating the PR field with
# the branch name. The unit separator \x1f preserves empty fields safely.
_flow_data_err=$(mktemp 2>/dev/null) || _flow_data_err=""
FLOW_DATA=$(jq -r '[
  (.issue_number // "unknown" | tostring),
  (.phase // "unknown"),
  (.next_action // ""),
  (.loop_count // 0 | tostring),
  (.pr_number // 0 | tostring),
  (.branch // "")
] | join("\u001f")' "$FLOW_STATE" 2>"${_flow_data_err:-/dev/null}") || FLOW_DATA=""
if [ -n "$_flow_data_err" ] && [ -s "$_flow_data_err" ]; then
  # .active / .compact_state は通過したが本 composite jq だけ失敗した場合 (部分 corruption /
  # concurrent writer race) を、上流 WARNING ではカバーできない経路として独立に expose する。
  # silent fall-through すると recovery が phase=unknown で再開する。
  echo "[rite] WARNING: post-compact: jq parse of flow-state composite fields failed (FLOW_STATE may be partially corrupt)" >&2
  head -3 "$_flow_data_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi
[ -n "$_flow_data_err" ] && rm -f "$_flow_data_err"

if [ -z "$FLOW_DATA" ]; then
  _cleanup_compact_state
  exit 0
fi

IFS=$'\x1f' read -r ISSUE PHASE NEXT_ACTION LOOP PR BRANCH <<< "$FLOW_DATA"

# --- Transition compact_state to normal (inside lock) ---
TMP_COMPACT=""
cleanup() {
  # `_resolve_err` の synchronous rm は trap install より前で実行される (resolver 直後)
  # ため、ここで cleanup() に含める必要はない (dead code)。trap が発火する時点では既に
  # 削除済みで no-op となる。trap install 前の race window は同期 rm 自身でカバーされる。
  # Surface rm failure (disk full / readonly fs / inode shortage) as a WARNING.
  # Trap cleanup must not fatal-exit on this — it would mask the underlying
  # failure being cleaned up after.
  rm -f "$TMP_COMPACT" 2>/dev/null || echo "[rite] WARNING: post-compact cleanup: failed to remove $TMP_COMPACT (disk full / readonly fs / permission?)" >&2
  release_wm_lock "$LOCKDIR"
}
trap cleanup EXIT TERM INT

if acquire_wm_lock "$LOCKDIR"; then
  TMP_COMPACT=$(mktemp "${COMPACT_STATE}.XXXXXX" 2>/dev/null) || TMP_COMPACT="${COMPACT_STATE}.tmp.$$"
  # Preserve trigger so SessionStart(compact) can distinguish auto vs manual
  # after this normalize. Missing field (old compact-state) falls back to this
  # hook's SOURCE (auto|manual), then to auto.
  _pc_trigger=$(jq -r '.trigger // empty' "$COMPACT_STATE" 2>/dev/null) || _pc_trigger=""
  [ -n "$_pc_trigger" ] || _pc_trigger="$SOURCE"
  case "$_pc_trigger" in
    manual) ;;
    *) _pc_trigger="auto" ;;
  esac
  # jq stderr is captured so a binary-missing / locale-broken date / disk-full
  # failure surfaces as a diagnosable WARNING. Silent fall-through here would
  # leave compact_state stuck at "recovering" forever and trigger an infinite
  # PostCompact side-effect loop on every subsequent compact.
  _jq_norm_err=$(mktemp 2>/dev/null) || _jq_norm_err=""
  if jq -n \
    --arg state "normal" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg trigger "$_pc_trigger" \
    '{compact_state: $state, compact_state_set_at: $ts, trigger: $trigger}' \
    > "$TMP_COMPACT" 2>"${_jq_norm_err:-/dev/null}"; then
    _mv_err=$(mktemp 2>/dev/null) || _mv_err=""
    if mv "$TMP_COMPACT" "$COMPACT_STATE" 2>"${_mv_err:-/dev/null}"; then
      TMP_COMPACT=""
    else
      _mv_rc=$?
      rm -f "$TMP_COMPACT"
      TMP_COMPACT=""
      echo "rite: post-compact: mv compact_state failed (rc=$_mv_rc)" >&2
      [ -n "$_mv_err" ] && [ -s "$_mv_err" ] && head -3 "$_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    [ -n "$_mv_err" ] && rm -f "$_mv_err"
  else
    _jq_norm_rc=$?
    echo "rite: post-compact: jq normalize compact_state failed (rc=$_jq_norm_rc)" >&2
    [ -n "$_jq_norm_err" ] && [ -s "$_jq_norm_err" ] && head -3 "$_jq_norm_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    rm -f "$TMP_COMPACT"
    TMP_COMPACT=""
  fi
  [ -n "$_jq_norm_err" ] && rm -f "$_jq_norm_err"
  release_wm_lock "$LOCKDIR"
fi

# --- PR Ready/Status mismatch reconciliation safety net ---
# When workflow active + PR exists + PR is Ready (isDraft=false) + Status != In Review,
# attempt reconciliation by re-invoking projects-status-update.sh. On failure, print a
# plain WARNING to stderr so a silent Status mismatch never persists past compaction.
#
# Stderr policy: every gh / jq / projects-status-update.sh invocation in this block
# captures stderr to its own tempfile so the resulting WARNING can distinguish
# auth / rate-limit / network / permission / JSON-parse failures instead of
# reporting a generic "command failed".
if [ "${PR:-0}" != "0" ] && [ "${PR:-0}" != "null" ] && [ -n "${PR:-}" ]; then
  PLUGIN_ROOT_PC="$(dirname "$SCRIPT_DIR")"
  # Sub-shell + pipefail + signal-specific trap pattern, paired with the
  # watchdog-status-mismatch hook. Capture the reconcile script's stderr so a
  # gh API failure surfaces as a WARNING with root cause rather than a silent
  # fall-through.
  (
    set -o pipefail
    pr_view_err=""
    repo_view_err=""
    git_remote_err=""
    jq_owner_err=""
    jq_name_err=""
    gql_err=""
    jq_err=""
    reconcile_err=""
    reconcile_jq_err=""
    reconcile_parse_err=""
    _pc_cleanup() {
      # The `[ -n "$f" ]` guard is defense-in-depth: even though the `2>/dev/null`
      # redirect below already suppresses BSD `rm -f ""` stderr noise
      # (`rm: '': No such file or directory`), a future refactor that drops
      # the redirect would let that diagnostic leak into triage and
      # mask real cleanup failures. The guard keeps the cleanup silent
      # regardless.
      for f in "${pr_view_err:-}" "${repo_view_err:-}" "${git_remote_err:-}" \
               "${jq_owner_err:-}" "${jq_name_err:-}" \
               "${gql_err:-}" "${jq_err:-}" "${reconcile_err:-}" \
               "${reconcile_jq_err:-}" "${reconcile_parse_err:-}"; do
        [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
      done
    }
    trap 'rc=$?; _pc_cleanup; exit $rc' EXIT
    trap '_pc_cleanup; exit 130' INT
    trap '_pc_cleanup; exit 143' TERM
    trap '_pc_cleanup; exit 129' HUP
    # When mktemp fails (disk full / inode shortage / /tmp readonly), gh's stderr
    # would silently route to /dev/null and the root cause (auth/rate-limit/
    # permission) would vanish from the WARNING. Tag the failure so the WARNING
    # can distinguish "gh returned no stderr" from "we couldn't capture it".
    stderr_capture_disabled=0
    pr_view_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-pr-err-XXXXXX") || { pr_view_err=""; stderr_capture_disabled=1; echo "[rite] WARNING: post-compact: mktemp failed for pr_view_err; gh pr view stderr will not be captured" >&2; }
    repo_view_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-repo-err-XXXXXX") || { repo_view_err=""; stderr_capture_disabled=1; echo "[rite] WARNING: post-compact: mktemp failed for repo_view_err; gh repo view stderr will not be captured" >&2; }
    git_remote_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-git-remote-err-XXXXXX") || { git_remote_err=""; stderr_capture_disabled=1; }
    jq_owner_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-jq-owner-err-XXXXXX") || { jq_owner_err=""; stderr_capture_disabled=1; }
    jq_name_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-jq-name-err-XXXXXX") || { jq_name_err=""; stderr_capture_disabled=1; }
    gql_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-gql-err-XXXXXX") || { gql_err=""; stderr_capture_disabled=1; }
    jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-jq-err-XXXXXX") || { jq_err=""; stderr_capture_disabled=1; }

    # Test STATE_ROOT existence up front and warn about state_root_inaccessible
    # directly. If we instead chained `cd ... 2>/dev/null && gh pr view ...`,
    # a cd failure would silently lose its stderr and the gh command would
    # never run — leaving the failure misattributed to gh.
    if [ ! -d "$STATE_ROOT" ]; then
      echo "[rite] WARNING: post-compact: Issue #$ISSUE — STATE_ROOT inaccessible ($STATE_ROOT); gh pr view skipped, PR Status reconciliation could not run (state_root_inaccessible)" >&2
      exit 0
    fi

    # Resolve REPO_OWNER/REPO_NAME before the `gh pr view` call below so it can
    # pass `--repo` explicitly. `gh pr view` is a shorthand command that
    # resolves the target repo from `origin` the same way `gh repo view`
    # does — under an SSH Host alias origin this fails with the exact error
    # fixes elsewhere, gating this whole reconciliation block shut
    # before PR_IS_DRAFT can even be determined.
    #
    # git-remote parse first: works even when `origin` is an SSH Host alias
    # unrecognized by gh's host allowlist. Falls through to the existing
    # `gh repo view` + stderr-attribution path whenever the parse fails
    # (no origin remote, unparseable URL, charset-rejected) — its stderr is
    # captured so a two-sided failure can be attributed on both sides.
    # Both paths run inside `cd "$STATE_ROOT"` so the
    # resolved repo always matches what `gh api graphql` below operates on —
    # a bare git-remote call in the ambient process cwd would silently
    # resolve a different repository when cwd != STATE_ROOT, bypassing the
    # auth/network cascade guard further down.
    REPO_OWNER=""
    REPO_NAME=""
    _git_or_line=$(cd "$STATE_ROOT" 2>/dev/null && bash "$SCRIPT_DIR/scripts/lib/git-remote.sh" resolve-owner-repo 2>"${git_remote_err:-/dev/null}") || _git_or_line=""
    if [ -n "$_git_or_line" ]; then
      IFS=$'\t' read -r REPO_OWNER REPO_NAME <<< "$_git_or_line"
    fi
    if [ -n "$REPO_OWNER" ] && [ -n "$REPO_NAME" ]; then
      REPO_INFO="git:${REPO_OWNER}/${REPO_NAME}"
    else
      # Capture gh repo view stderr so failures get attributed to auth/network/
      # permission rather than misclassified as missing data. This pattern is
      # paired with watchdog-status-mismatch; if those two sites diverge in error
      # capture, the same root cause produces asymmetric WARNING details and
      # becomes harder to diagnose.
      #
      # cd stderr is captured separately (same TOCTOU discrimination as the
      # `gh pr view` subshell below): a cd failure here would otherwise leave
      # repo_view_err empty and get misattributed to gh.
      _ri_cd_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
        "post-compact" \
        "repo-cd-err" \
        "TOCTOU cd failure must be distinguished from gh repo view failure inside the same subshell") || _ri_cd_err=""
      if REPO_INFO=$(cd "$STATE_ROOT" 2>"${_ri_cd_err:-/dev/null}" && gh repo view --json owner,name 2>"${repo_view_err:-/dev/null}"); then
        :
      else
        repo_rc=$?
        repo_err_oneline=$(head -c 200 "${repo_view_err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl --c0-only)
        ri_cd_err_oneline=$(head -c 200 "${_ri_cd_err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl --c0-only)
        REPO_INFO=""
      fi
      [ -n "$_ri_cd_err" ] && rm -f "$_ri_cd_err"
      # Capture jq stderr separately so JSON parse failure (gh succeeded but JSON
      # is corrupt or a field is null) gets attributed in the WARNING details.
      REPO_OWNER=$(printf '%s' "$REPO_INFO" | jq -r '.owner.login // empty' 2>"${jq_owner_err:-/dev/null}") || REPO_OWNER=""
      REPO_NAME=$(printf '%s' "$REPO_INFO" | jq -r '.name // empty' 2>"${jq_name_err:-/dev/null}") || REPO_NAME=""
    fi
    _pc_repo_flag=()
    [ -n "$REPO_OWNER" ] && [ -n "$REPO_NAME" ] && _pc_repo_flag=(--repo "$REPO_OWNER/$REPO_NAME")

    # `cd ... && gh ... 2>FILE` attaches the redirect to gh only — a TOCTOU
    # cd failure (dir removed between the `-d` check above and the cd) leaks no
    # stderr and gets misclassified as a gh failure. Capture cd stderr to a
    # separate file inside the same subshell so the parent shell can branch on
    # which stage actually failed, attributing it as the distinct
    # `state_root_toctou_race` type instead of a vague `gh_pr_view_failed`.
    _pr_cd_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
      "post-compact" \
      "pr-cd-err" \
      "TOCTOU cd failure must be distinguished from gh pr view failure inside the same subshell") || _pr_cd_err=""
    if PR_IS_DRAFT=$(cd "$STATE_ROOT" 2>"${_pr_cd_err:-/dev/null}" && gh pr view "$PR" "${_pc_repo_flag[@]+"${_pc_repo_flag[@]}"}" --json isDraft --jq '.isDraft // null' 2>"${pr_view_err:-/dev/null}"); then
      :
    else
      pr_rc=$?
      pr_view_err_oneline=$(head -c 200 "${pr_view_err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl --c0-only)
      pr_cd_err_oneline=$(head -c 200 "${_pr_cd_err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl --c0-only)
      if [ -n "$pr_cd_err_oneline" ]; then
        echo "[rite] WARNING: post-compact: Issue #$ISSUE — cd STATE_ROOT failed inside gh pr view subshell (rc=$pr_rc, stderr=$pr_cd_err_oneline); TOCTOU race between -d check and cd (state_root_toctou_race)" >&2
      else
        # PR が close/merge/delete された legitimate な終了状態 (gh CLI の
        # `Could not resolve to a PullRequest` CamelCase 連結 stderr) と
        # auth/network/permission 失敗を区別して WARNING に出す。前者は false positive。
        if printf '%s' "$pr_view_err_oneline" | grep -qiE 'could not resolve.*pull\s*request|no.*pull\s*request found'; then
          pr_root_cause_hint="pr_deleted_or_inaccessible"
        else
          pr_root_cause_hint="post_compact_gh_pr_view_failed"
        fi
        stderr_flag=""
        [ "$stderr_capture_disabled" = "1" ] && stderr_flag=" stderr_capture=disabled"
        echo "[rite] WARNING: post-compact: Issue #$ISSUE — gh pr view failed (rc=$pr_rc, stderr=$pr_view_err_oneline${stderr_flag}); PR Status reconciliation could not run ($pr_root_cause_hint)" >&2
      fi
      PR_IS_DRAFT=""
    fi
    [ -n "$_pr_cd_err" ] && rm -f "$_pr_cd_err"

    if [ "$PR_IS_DRAFT" = "false" ]; then
      # REPO_OWNER / REPO_NAME / REPO_INFO are already resolved above (before
      # the `gh pr view` call) so that call could pass `--repo` explicitly.
      # REPO_INFO is only ever checked for emptiness downstream (never parsed
      # as JSON again), so the git-remote success path's non-JSON
      # "git:owner/repo" sentinel is sufficient to signal "already resolved".
      #
      # Capture awk stderr for rite-config.yml parsing. A silent empty fallback
      # here would let broken Projects integration go unnoticed by the user.
      awk_pe_err=""
      awk_pn_err=""
      awk_pe_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-awk-pe-err-XXXXXX") || { awk_pe_err=""; stderr_capture_disabled=1; }
      awk_pn_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-awk-pn-err-XXXXXX") || { awk_pn_err=""; stderr_capture_disabled=1; }
      # awk rc を独立 capture することで「awk parse 失敗 (config file 不正)」と「Projects 無効
      # 設定」を区別する。両者が silent に同一視されると、permission denied や IO error で
      # Projects 整合性チェックが skip された事実が operator に届かない。
      awk_pe_rc=0
      awk_pn_rc=0
      PROJECTS_ENABLED=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' "$STATE_ROOT/rite-config.yml" 2>"${awk_pe_err:-/dev/null}") || awk_pe_rc=$?
      PROJECT_NUMBER=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    project_number:/{print $2; exit}' "$STATE_ROOT/rite-config.yml" 2>"${awk_pn_err:-/dev/null}") || awk_pn_rc=$?
      awk_parse_failed=0
      if [ "$awk_pe_rc" -ne 0 ] || { [ -n "${awk_pe_err:-}" ] && [ -s "$awk_pe_err" ]; }; then
        awk_pe_oneline=""
        [ -n "${awk_pe_err:-}" ] && [ -s "$awk_pe_err" ] && awk_pe_oneline=$(head -c 200 "$awk_pe_err" | tr '\n' ' ' | neutralize_ctrl --c0-only)
        echo "[rite] WARNING: post-compact: awk parse of projects.enabled failed (rc=$awk_pe_rc, stderr=$awk_pe_oneline)" >&2
        awk_parse_failed=1
      fi
      if [ "$awk_pn_rc" -ne 0 ] || { [ -n "${awk_pn_err:-}" ] && [ -s "$awk_pn_err" ]; }; then
        awk_pn_oneline=""
        [ -n "${awk_pn_err:-}" ] && [ -s "$awk_pn_err" ] && awk_pn_oneline=$(head -c 200 "$awk_pn_err" | tr '\n' ' ' | neutralize_ctrl --c0-only)
        echo "[rite] WARNING: post-compact: awk parse of projects.project_number failed (rc=$awk_pn_rc, stderr=$awk_pn_oneline)" >&2
        awk_parse_failed=1
      fi
      # awk 自体が失敗した場合は config 解析不能を WARNING で surface する。後段の
      # PROJECTS_ENABLED check は false fallback で Projects skip するが、その判定根拠が
      # 「config 解析失敗」だった事実を operator に届ける。
      if [ "$awk_parse_failed" = "1" ]; then
        echo "[rite] WARNING: post-compact: Issue #$ISSUE — rite-config.yml awk parse failed (pe_rc=$awk_pe_rc pn_rc=$awk_pn_rc); Projects reconciliation skipped without verifying config (post_compact_config_parse_failed)" >&2
      fi
      rm -f "${awk_pe_err:-}" "${awk_pn_err:-}"
      # Cascade guard: once we warn about the upstream repo failure, downstream
      # graphql attempts would just produce a second (duplicated, less specific)
      # warning. _owner_repo_ok=0 short-circuits them.
      _owner_repo_ok=1
      # Trip on either an empty REPO_INFO or null-valued owner/name fields.
      # The latter covers gh's auth-scope-degraded path where the call succeeds
      # but returns nulls — silently treating that as "no project" would skip
      # reconciliation entirely.
      if [ "$PROJECTS_ENABLED" = "true" ] && { [ -z "$REPO_INFO" ] || [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; }; then
        echo "[rite] ⚠️ post-compact: gh repo view failed or parse empty — reconciliation safety net unavailable" >&2
        _owner_repo_ok=0
        jq_owner_err_oneline=""
        jq_name_err_oneline=""
        [ -n "${jq_owner_err:-}" ] && [ -s "$jq_owner_err" ] && jq_owner_err_oneline=$(head -c 200 "$jq_owner_err" | tr '\n' ' ' | neutralize_ctrl --c0-only)
        [ -n "${jq_name_err:-}" ] && [ -s "$jq_name_err" ] && jq_name_err_oneline=$(head -c 200 "$jq_name_err" | tr '\n' ' ' | neutralize_ctrl --c0-only)
        if [ -z "$REPO_INFO" ]; then
          # git-remote fast path's stderr rides along: when BOTH resolution
          # paths failed, showing only gh's side would hide why the fast path
          # bailed (the side most likely to matter under an alias origin).
          git_remote_err_oneline=""
          [ -n "${git_remote_err:-}" ] && [ -s "$git_remote_err" ] && git_remote_err_oneline=$(head -c 200 "$git_remote_err" | tr '\n' ' ' | neutralize_ctrl --c0-only)
          if [ -n "${ri_cd_err_oneline:-}" ]; then
            echo "[rite] WARNING: post-compact: Issue #$ISSUE — cd STATE_ROOT failed inside gh repo view subshell (rc=${repo_rc:-NA}, stderr=$ri_cd_err_oneline); TOCTOU race between -d check and cd (state_root_toctou_race)" >&2
          else
            echo "[rite] WARNING: post-compact: Issue #$ISSUE — gh repo view failed (rc=${repo_rc:-NA}, stderr=${repo_err_oneline:-NA}, git_remote_stderr=${git_remote_err_oneline:-NA}); PR Status reconciliation could not run (post_compact_gh_repo_view_failed)" >&2
          fi
        else
          echo "[rite] WARNING: post-compact: Issue #$ISSUE — gh repo view returned null fields (owner=$REPO_OWNER name=$REPO_NAME jq_owner_stderr=$jq_owner_err_oneline jq_name_stderr=$jq_name_err_oneline); PR Status reconciliation could not run (post_compact_gh_repo_view_returned_null)" >&2
        fi
        # Equivalent to `if _owner_repo_ok != "1"; then exit 0; fi`. Exit
        # directly so we cannot accidentally fall through into the graphql path
        # below and double-warn with a less specific message.
        exit 0
      fi
      if [ "$PROJECTS_ENABLED" = "true" ] && [ -n "$PROJECT_NUMBER" ] && [ -n "$REPO_OWNER" ] && [ -n "$REPO_NAME" ] && [ "$ISSUE" != "unknown" ]; then
        if CURRENT_STATUS=$(cd "$STATE_ROOT" && gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes {
          project { number }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { name } }
                name
              }
            }
          }
        }
      }
    }
  }
}' -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F number="$ISSUE" 2>"${gql_err:-/dev/null}" \
          | jq -r --argjson pn "$PROJECT_NUMBER" \
            '[.data.repository.issue.projectItems.nodes[] | select(.project.number == $pn) | .fieldValues.nodes[] | select(.field.name == "Status") | .name][0] // empty' 2>"${jq_err:-/dev/null}"); then
          :
        else
          gql_rc=$?
          gql_err_oneline=$(head -c 200 "${gql_err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl --c0-only)
          jq_err_oneline=$(head -c 200 "${jq_err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl --c0-only)
          echo "[rite] WARNING: post-compact: Issue #$ISSUE — gh api graphql failed (rc=$gql_rc, gh_stderr=$gql_err_oneline, jq_stderr=$jq_err_oneline); PR Status reconciliation could not run (post_compact_gh_api_failed)" >&2
          CURRENT_STATUS=""
        fi

        # Done / Cancelled are the terminal Status set (references/projects-integration.md,
        # "Terminal Status Set"). A terminal row is finished, so pulling it back to
        # In Review would undo a deliberate decision — Cancelled is excluded for exactly
        # the same reason Done always has been.
        if [ -n "$CURRENT_STATUS" ] && [ "$CURRENT_STATUS" != "In Review" ] && [ "$CURRENT_STATUS" != "Done" ] && [ "$CURRENT_STATUS" != "Cancelled" ]; then
          echo "[rite] ⚠️ post-compact mismatch detected: Issue #$ISSUE PR=#$PR isDraft=false Status=\"$CURRENT_STATUS\" (expected In Review)" >&2
          # STATE_ROOT existence is already enforced at the top of the sub-shell
          # (early state_root_inaccessible WARNING + exit 0), so this reconciliation
          # block can call reconcile directly without re-checking.
          # jq -n payload を別変数で capture することで、command substitution 内の jq 失敗
          # (引数 unsubstituted / type mismatch 等) が空文字列として projects-status-update.sh
          # へ silent 流入する経路を遮断する。command substitution は pipeline ではないため
          # `set -o pipefail` は内部 jq の rc を outer rc に伝播しない。
          reconcile_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-reconcile-err-XXXXXX") || reconcile_err=""
          reconcile_parse_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-reconcile-parse-err-XXXXXX") || reconcile_parse_err=""
          reconcile_jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-reconcile-jq-err-XXXXXX") || reconcile_jq_err=""
          RECONCILE_RESULT=""
          RECONCILE_RC=0
          JQ_PAYLOAD=""
          JQ_PAYLOAD_RC=0
          JQ_PAYLOAD=$(jq -n \
            --argjson issue "$ISSUE" --arg owner "$REPO_OWNER" --arg repo "$REPO_NAME" \
            --argjson project_number "$PROJECT_NUMBER" --arg status "In Review" \
            --argjson auto_add false --argjson non_blocking true \
            '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}' 2>"${reconcile_jq_err:-/dev/null}") || JQ_PAYLOAD_RC=$?
          if [ "$JQ_PAYLOAD_RC" -ne 0 ] || [ -z "$JQ_PAYLOAD" ]; then
            jq_err_oneline=$(head -c 200 "${reconcile_jq_err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl --c0-only)
            echo "[rite] ❌ post-compact reconciliation jq payload build failed (rc=$JQ_PAYLOAD_RC, jq_stderr=$jq_err_oneline, post_compact_jq_payload_build_failed)" >&2
          else
            RECONCILE_RESULT=$(cd "$STATE_ROOT" && bash "$PLUGIN_ROOT_PC/scripts/projects-status-update.sh" "$JQ_PAYLOAD" 2>"${reconcile_err:-/dev/null}") || RECONCILE_RC=$?
            RECONCILE_STATUS=$(printf '%s' "$RECONCILE_RESULT" | jq -r '.result // empty' 2>"${reconcile_parse_err:-/dev/null}") || RECONCILE_STATUS=""
            if [ "$RECONCILE_STATUS" = "updated" ]; then
              echo "[rite] ✅ post-compact reconciliation succeeded: Issue #$ISSUE Status → In Review" >&2
            else
              reconcile_err_oneline=$(head -c 200 "${reconcile_err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl --c0-only)
              # RECONCILE_STATUS が空で RECONCILE_RESULT が非空なら、reconcile script は応答したが
              # result field を抽出できなかった (= JSON shape drift)。これは reconcile 自体の失敗とは
              # 別の triage が必要なので、empty/non-empty で区別する。
              if [ -z "$RECONCILE_STATUS" ] && [ -n "$RECONCILE_RESULT" ]; then
                parse_err_snippet=""
                [ -n "$reconcile_parse_err" ] && [ -s "$reconcile_parse_err" ] && parse_err_snippet=$(head -c 200 "$reconcile_parse_err" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl --c0-only)
                echo "[rite] ❌ post-compact reconciliation result parse failed (jq err=$parse_err_snippet, stdout snippet=$(printf '%s' "$RECONCILE_RESULT" | head -c 200 | tr '\n' ' ' | neutralize_ctrl --c0-only))" >&2
                RECONCILE_STATUS="parse_failed"
              else
                RECONCILE_STATUS="${RECONCILE_STATUS:-failed}"
                echo "[rite] ❌ post-compact reconciliation failed (rc=$RECONCILE_RC result=$RECONCILE_STATUS, post_compact_reconciliation_failed)" >&2
              fi
            fi
          fi
          [ -n "$reconcile_jq_err" ] && rm -f "$reconcile_jq_err"
          [ -n "$reconcile_parse_err" ] && rm -f "$reconcile_parse_err"
        fi
      fi
    fi
  )
fi

# --- stderr: user-facing notification (not injected into model context) ---
echo "[rite] compact 後の自動復帰を実行中 (Issue #${ISSUE}, Phase: ${PHASE})" >&2
# Recovery text and batch frame are emitted by session-start.sh (source=compact).
