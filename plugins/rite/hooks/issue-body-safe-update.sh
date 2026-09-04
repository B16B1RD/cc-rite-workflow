#!/bin/bash
# rite workflow - Issue Body Safe Update
# Deterministic script for the fetch/validate and validate/apply steps
# of the 3-step safe Issue body update pattern.
#
# The 3-step pattern:
#   Step 1 (fetch):  issue-body-safe-update.sh fetch --issue <number>
#   Step 2 (edit):   Claude reads tmpfile_read, writes updated body to tmpfile_write
#   Step 3 (apply):  issue-body-safe-update.sh apply --issue <number> \
#                      --tmpfile-read <path> --tmpfile-write <path> --original-length <n>
#
# Fetch mode outputs:
#   tmpfile_read=<path>
#   tmpfile_write=<path>
#   original_length=<n>
#
# Apply mode validates and applies the update:
#   - Rejects empty write file
#   - Rejects body shrinkage below 50% of original (body loss prevention)
#   - Uses --body-file for safe gh issue edit
#
# Options:
#   --issue           Issue number (required)
#   --tmpfile-read    Path to temp file with original body (apply mode)
#   --tmpfile-write   Path to temp file with updated body (apply mode)
#   --original-length Original body length in bytes (apply mode)
#   --parent          Indicate parent Issue update (accepted for backward compatibility — current
#                     err_level is WARNING for all callers; flag is reserved for future severity
#                     differentiation between parent / non-parent body updates)
#   --diff-check      Verify a change was actually made (skip apply if identical)
#
# Exit codes:
#   0: Success or skip (non-blocking)
#   1: Argument error
set -euo pipefail

# shellcheck source=control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"

# Persistent body-update failures must not vanish silently. The safety guards
# (empty write / <50% shrinkage / gh edit failure / diff IO error) all exit 0 so
# the caller's workflow continues, but the caller cannot detect a "guard tripped"
# outcome from the exit code alone — so surface a plain WARNING to stderr here and
# let the LLM surface it in the conversation context.
#
# The first argument (a stable label distinguishing safety-guard trips from
# API/IO failures) is kept in the WARNING text so triage can still tell a
# `body_shrinkage_guard_tripped` apart from an `issue_body_fetch_failed`.
_emit_body_update_incident() {
  local incident_type="$1" reason="$2" rc="$3" stderr_snippet="$4"
  echo "WARNING: issue-body-safe-update: Issue #${ISSUE:-unknown} ${MODE:-unknown} ${incident_type} (reason=$reason rc=$rc stderr=$stderr_snippet)" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Owner/repo resolution ---
# Without an explicit --repo, `gh issue view` / `gh issue edit` infer the target
# repo from the git remotes and fail with "none of the git remotes configured for
# this repository point to a known GitHub host" when `origin` is an SSH Host alias
# (e.g. git@github.com-work:owner/repo.git). gh expands such aliases by reading
# ~/.ssh/config, so the failure surfaces specifically where that read is denied —
# notably the sandboxed workflow environment, where every body update degraded to
# fetch_failure_reason=gh_view_failed. Resolving owner/repo ourselves and
# passing it explicitly bypasses gh's host inference entirely.
#
# Both paths are best-effort: when neither yields an owner/repo the caller keeps
# the previous behaviour (no --repo flag) rather than failing, per this script's
# non-blocking contract. The double failure is still surfaced as a WARNING so a
# genuinely unresolvable environment stays diagnosable instead of silently
# reverting to the broken path.
get_owner_repo() {
  local _err _rc=0 _out _git_err _git_or_line _git_owner _git_repo
  # git-remote parse first: works even when `origin` is an SSH Host alias that
  # gh's host allowlist rejects. Falls through to `gh repo view` when the
  # parse fails (no origin remote, unparseable URL).
  _git_err=$(mktemp "${TMPDIR:-/tmp}/rite-issue-body-remote-err-XXXXXX" 2>/dev/null) || _git_err=""
  _git_or_line=$(bash "$SCRIPT_DIR/scripts/lib/git-remote.sh" resolve-owner-repo 2>"${_git_err:-/dev/null}") || _git_or_line=""
  if [ -n "$_git_or_line" ]; then
    IFS=$'\t' read -r _git_owner _git_repo <<< "$_git_or_line"
    if [ -n "$_git_owner" ] && [ -n "$_git_repo" ]; then
      [ -n "$_git_err" ] && rm -f "$_git_err"
      printf '%s/%s' "$_git_owner" "$_git_repo"
      return
    fi
  fi
  _err=$(mktemp "${TMPDIR:-/tmp}/rite-issue-body-ghrepo-err-XXXXXX" 2>/dev/null) || _err=""
  _out=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>"${_err:-/dev/null}") || _rc=$?
  if [ "$_rc" -ne 0 ] || [ -z "$_out" ]; then
    echo "${err_level:-WARNING}: issue-body-safe-update: owner/repo を解決できません (gh repo view rc=$_rc)。--repo なしで続行します（SSH host alias 環境では gh 呼び出しが失敗する可能性があります）" >&2
    if [ -n "$_err" ] && [ -s "$_err" ]; then
      head -3 "$_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    # Surface why the git-remote fast path bailed too, or this WARNING would show
    # only the fallback's side of a two-sided failure.
    if [ -n "$_git_err" ] && [ -s "$_git_err" ]; then
      head -3 "$_git_err" | neutralize_ctrl --keep-newline | sed 's/^/  git-remote: /' >&2
    fi
    _out=""
  fi
  [ -n "$_err" ] && rm -f "$_err"
  [ -n "$_git_err" ] && rm -f "$_git_err"
  printf '%s' "$_out"
}

# --- Argument parsing ---
MODE="${1:-}"
shift 2>/dev/null || true

ISSUE=""
TMPFILE_READ=""
TMPFILE_WRITE=""
ORIGINAL_LENGTH=""
IS_PARENT=false
DIFF_CHECK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)           ISSUE="$2"; shift 2 ;;
    --tmpfile-read)    TMPFILE_READ="$2"; shift 2 ;;
    --tmpfile-write)   TMPFILE_WRITE="$2"; shift 2 ;;
    --original-length) ORIGINAL_LENGTH="$2"; shift 2 ;;
    --parent)          IS_PARENT=true; shift ;;
    --diff-check)      DIFF_CHECK=true; shift ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validation ---
if [[ -z "$ISSUE" ]]; then
  echo "ERROR: --issue is required" >&2
  exit 1
fi

# All callers (parent / non-parent) treat body-update failures as non-blocking:
# checklist append for the working Issue and Sub-Issues section append for the
# parent are both fail-soft. The --parent flag is preserved in the arg parser
# for future severity differentiation but currently has no behavioral effect.
err_level="WARNING"

# Resolved once ahead of the mode dispatch: fetch and apply each issue exactly one
# gh call needing the flag, and resolution is identical for either mode. Empty
# array = pre- behaviour, so an unresolvable repo degrades instead of failing.
GH_REPO_ARGS=()
OWNER_REPO=$(get_owner_repo)
if [ -n "$OWNER_REPO" ]; then
  GH_REPO_ARGS=(--repo "$OWNER_REPO")
fi

case "$MODE" in
  fetch)
    # The script's non-blocking contract requires exit 0 on transient failure,
    # but unguarded mktemp under `set -euo pipefail` would abort silently when
    # /tmp is exhausted. Surface mktemp failure as a normal fetch_failure_reason
    # so the caller can branch on it instead of getting a mute exit.
    tmpfile_read=$(mktemp "${TMPDIR:-/tmp}/rite-issue-body-read-XXXXXX") || {
      echo "${err_level}: issue-body-safe-update fetch: mktemp tmpfile_read failed (disk full / inode / permission?)" >&2
      echo "fetch_failure_reason=mktemp_failed"
      _emit_body_update_incident "issue_body_fetch_failed" "mktemp_failed" "1" "tmpfile_read mktemp failed"
      exit 0
    }
    tmpfile_write=$(mktemp "${TMPDIR:-/tmp}/rite-issue-body-write-XXXXXX") || {
      echo "${err_level}: issue-body-safe-update fetch: mktemp tmpfile_write failed" >&2
      echo "fetch_failure_reason=mktemp_failed"
      _emit_body_update_incident "issue_body_fetch_failed" "mktemp_failed" "1" "tmpfile_write mktemp failed"
      rm -f "$tmpfile_read"
      exit 0
    }
    tmpfile_err=$(mktemp "${TMPDIR:-/tmp}/rite-issue-body-err-XXXXXX") || {
      echo "${err_level}: issue-body-safe-update fetch: mktemp tmpfile_err failed" >&2
      echo "fetch_failure_reason=mktemp_failed"
      _emit_body_update_incident "issue_body_fetch_failed" "mktemp_failed" "1" "tmpfile_err mktemp failed"
      rm -f "$tmpfile_read" "$tmpfile_write"
      exit 0
    }
    trap 'rm -f "$tmpfile_read" "$tmpfile_write" "$tmpfile_err"' EXIT

    # `if ! cmd; then rc=$?` forces rc=0 inside the then-branch (POSIX `!` inverts
    # status). Use the else-branch to preserve gh's real exit code so the WARNING
    # details accurately attribute auth / rate-limit / 404 failures.
    rc=0
    if gh issue view "$ISSUE" "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" --json body --jq '.body' >"$tmpfile_read" 2>"$tmpfile_err"; then
      :
    else
      rc=$?
      err_snippet=$(head -c 500 "$tmpfile_err" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | neutralize_ctrl --c0-only || echo "")
      echo "${err_level}: gh issue view 失敗 (rc=$rc): ${err_snippet}" >&2
      echo "fetch_failure_reason=gh_view_failed"
      _emit_body_update_incident "issue_body_fetch_failed" "gh_view_failed" "$rc" "$err_snippet"
      exit 0
    fi

    if [ ! -s "$tmpfile_read" ]; then
      echo "${err_level}: Issue body が空。更新をスキップします" >&2
      echo "fetch_failure_reason=body_empty"
      exit 0
    fi

    original_length=$(wc -c < "$tmpfile_read")
    echo "original_length=$original_length"
    echo "tmpfile_read=$tmpfile_read"
    echo "tmpfile_write=$tmpfile_write"

    # err tmpfile は fetch 内で完結するため、persist は read/write のみ。
    rm -f "$tmpfile_err"
    # Disable trap so read/write files persist for Step 2/3
    trap - EXIT
    ;;

  apply)
    if [[ -z "$TMPFILE_READ" || -z "$TMPFILE_WRITE" || -z "$ORIGINAL_LENGTH" ]]; then
      echo "ERROR: apply mode requires --tmpfile-read, --tmpfile-write, --original-length" >&2
      exit 1
    fi

    # Defensive validation of --original-length. Under `set -euo pipefail`, the
    # later arithmetic `$(( ${ORIGINAL_LENGTH:-1} / 2 ))` would abort the whole
    # script (breaking the non-blocking exit-0 contract and leaking the tmp
    # files) if a caller passed a non-numeric value (e.g. via a wc failure
    # producing whitespace). Catch it here as a body_shrinkage_guard_tripped
    # failure with a distinct hint so triage doesn't conflate it with a real
    # safety-net trip.
    if ! [[ "$ORIGINAL_LENGTH" =~ ^[0-9]+$ ]]; then
      echo "${err_level}: --original-length が非数値 ('$ORIGINAL_LENGTH') — apply をスキップ" >&2
      _emit_body_update_incident "body_shrinkage_guard_tripped" "original_length_invalid" "0" "ORIGINAL_LENGTH='$ORIGINAL_LENGTH' (caller passed non-numeric — likely wc failure upstream)"
      rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
      exit 0
    fi

    # Empty / shrinkage safety guards exit 0 so the caller's workflow continues,
    # but surface a WARNING directly here — caller cannot detect a "safety
    # guard tripped" outcome from exit code alone, so a silent skip would erase
    # the audit trail for accidental body destruction.
    if [ ! -s "$TMPFILE_WRITE" ]; then
      echo "${err_level}: 更新内容が空。更新をスキップします" >&2
      _emit_body_update_incident "body_shrinkage_guard_tripped" "empty_write" "0" "tmpfile_write is empty (0 bytes)"
      rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
      exit 0
    fi

    updated_length=$(wc -c < "$TMPFILE_WRITE")
    if [[ "${updated_length:-0}" -lt $(( ${ORIGINAL_LENGTH:-1} / 2 )) ]]; then
      echo "${err_level}: 更新後の body が元の50%未満 (${updated_length}/${ORIGINAL_LENGTH})。body 消失の可能性があるためスキップします" >&2
      _emit_body_update_incident "body_shrinkage_guard_tripped" "shrinkage_below_50pct" "0" "updated=${updated_length} original=${ORIGINAL_LENGTH}"
      rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
      exit 0
    fi

    # `diff -q ... 2>&1` collapses rc=0 (identical), rc=1 (different), and rc>=2 (IO
    # error / missing file / permission) into one branch. Branch on the rc explicitly
    # so transient IO failures don't masquerade as "different, proceed to gh edit".
    if [[ "$DIFF_CHECK" == true ]]; then
      set +e
      diff -q "$TMPFILE_READ" "$TMPFILE_WRITE" > /dev/null 2>&1
      _diff_rc=$?
      set -e
      case $_diff_rc in
        0)
          echo "INFO: 変更なし（既に更新済み）"
          rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
          exit 0
          ;;
        1) : ;;
        *)
          echo "${err_level}: diff コマンドが IO エラー (rc=$_diff_rc) — apply をスキップ" >&2
          _emit_body_update_incident "issue_body_fetch_failed" "diff_io_error" "$_diff_rc" "diff -q rc=$_diff_rc (file unreadable / permission)"
          rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
          exit 0
          ;;
      esac
    fi

    # Capture gh issue edit stderr so failures (auth / network / 404) can be
    # attributed in the WARNING rather than reported as "API failed, reason
    # unknown". The script is non-blocking, so mktemp failure degrades to
    # "no stderr capture" rather than aborting the caller's workflow.
    apply_err=$(mktemp "${TMPDIR:-/tmp}/rite-issue-body-apply-err-XXXXXX") || {
      echo "${err_level}: issue-body-safe-update apply: mktemp apply_err failed; stderr capture disabled" >&2
      _emit_body_update_incident "issue_body_fetch_failed" "mktemp_failed" "1" "apply_err mktemp failed"
      apply_err=""
    }
    trap 'rm -f "$apply_err" 2>/dev/null || true' EXIT
    rc=0
    if gh issue edit "$ISSUE" "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" --body-file "$TMPFILE_WRITE" 2>"${apply_err:-/dev/null}"; then
      :
    else
      rc=$?
      err_snippet=$(head -c 500 "${apply_err:-/dev/null}" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | neutralize_ctrl --c0-only || echo "")
      echo "${err_level}: gh issue edit 失敗 (rc=$rc): ${err_snippet}" >&2
      echo "apply_failure_reason=gh_edit_failed"
      _emit_body_update_incident "issue_body_fetch_failed" "gh_edit_failed" "$rc" "$err_snippet"
      rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
      exit 0
    fi

    rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
    ;;

  *)
    echo "ERROR: Unknown mode: $MODE (expected: fetch, apply)" >&2
    exit 1
    ;;
esac
